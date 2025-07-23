const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const Runtime = @import("../Runtime.zig");
const Reactor = @import("../Reactor.zig");
const types = @import("../utils/types.zig");

const log = std.log.scoped(.Fibers);
const assert = std.debug.assert;

const Fibers = @This();

allocator: std.mem.Allocator,

// We save this just so we can join
threads: []Thread,

// Free threads, we can
free_threads: struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList(*Thread),
},

detached_tasks: struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList(*Task.Detached),
},

shutdown: struct {
    task_count: std.atomic.Value(usize),
    requested: std.atomic.Value(bool),

    cond: std.Thread.Condition,
    mutex: std.Thread.Mutex,
},

reactor: Reactor,
const rt_vtable: Runtime.VTable = .{
    .spawn = spawn,
    .joinTask = joinTask,
    .select = select,
    .join = join,

    .openFile = openFile,
    .closeFile = closeFile,
    .pread = pread,
    .pwrite = pwrite,
    .sleep = sleep,
};

const exec_vtable: Reactor.Executer.VTable = .{
    .getThreadContext = getThreadContext,
    .getWaker = getWaker,
    .wake = wake,
    .@"suspend" = @"suspend",
};

pub fn init(allocator: std.mem.Allocator, reactor: Reactor) !*Fibers {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const threads = try allocator.alloc(Thread, cpu_count);

    const rt = allocator.create(Fibers) catch unreachable;
    rt.* = .{
        .allocator = allocator,

        .threads = threads,

        .free_threads = .{
            .mutex = .{},
            .list = .init(allocator),
        },

        .detached_tasks = .{
            .mutex = .{},
            .list = .init(allocator),
        },

        .reactor = reactor,

        .shutdown = .{
            .task_count = .init(0),
            .requested = .init(false),

            .cond = .{},
            .mutex = .{},
        },
    };

    var thread_id: usize = 0;
    for (threads) |*thread| {
        thread.handle = std.Thread.spawn(.{}, Thread.entry, .{ rt, thread_id }) catch |err| {
            log.err("failed to spawn thread: {s}", .{@errorName(err)});
            unreachable;
        };
        thread_id += 1;
    }

    return rt;
}

pub fn deinit(self: *Fibers) void {
    // Signal shutdown to all threads

    self.shutdown.requested.store(true, .release);

    self.shutdown.mutex.lock();
    self.shutdown.cond.wait(&self.shutdown.mutex);
    self.shutdown.mutex.unlock();

    // Wake up all threads so they can see the shutdown signal
    for (self.threads) |*thread| {
        self.reactor.vtable.wakeThread(self.reactor.ctx, null, thread.io_ctx);
    }

    // Now join all threads
    for (self.threads) |thread| {
        thread.handle.join();
    }

    self.free_threads.list.deinit();

    for (self.detached_tasks.list.items) |task| {
        task.deinit(self.allocator);
        self.allocator.destroy(task);
    }
    self.detached_tasks.list.deinit();
    self.allocator.free(self.threads);
    self.allocator.destroy(self);
}

pub fn runtime(self: *Fibers) Runtime {
    return .{
        .vtable = &rt_vtable,
        .ctx = @ptrCast(self),
    };
}

pub fn executer(self: *Fibers) Reactor.Executer {
    return .{
        .vtable = &exec_vtable,
        .ctx = @ptrCast(self),
    };
}

const Context = switch (builtin.cpu.arch) {
    .x86_64 => packed struct {
        rsp: u64 = 0,
        rbp: u64 = 0,
        rip: u64 = 0,

        fn init(entry_rip: usize, stack: usize) @This() {
            return .{
                .rsp = stack - 8,
                .rbp = 0,
                .rip = entry_rip,
            };
        }
    },
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
};

fn contextSwitch(old_ctx: *Context, new_ctx: *const Context) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
        // Save current context
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq $ret, 16(%%rax)

            // Restore new context
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx) // jump to RIP
            \\ ret:
            :
            : [old] "{rax}" (old_ctx),
              [new] "{rcx}" (new_ctx),
            : "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "fpsr", "fpcr", "mxcsr", "rflags", "dirflag", "memory"
        ),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    }
}

fn reschedule(rt: *Fibers, task: *Task.Detached) void {
    if (task.state.cmpxchgStrong(.Idle, .Queued, .acq_rel, .acquire) == null) {
        rt.schedule(task);
        return;
    }

    _ = task.state.cmpxchgStrong(.Running, .Rerun, .acq_rel, .acquire);
}

fn schedule(rt: *Fibers, task: *Task.Detached) void {
    rt.free_threads.mutex.lock();
    const maybe_thread: ?*Thread = rt.free_threads.list.pop();
    rt.free_threads.mutex.unlock();

    if (maybe_thread) |thread| {
        log.info("pushing to free thread", .{});
        thread.push(task);

        rt.reactor.vtable.wakeThread(rt.reactor.ctx, if (Thread.self) |self| self.io_ctx else null, @ptrCast(thread.io_ctx));
    } else if (Thread.self) |t| {
        log.info("pushing to current thread", .{});
        t.push(task);
    } else {
        log.info("no thread to push to, using main thread", .{});
        rt.threads[0].push(task);
    }
}

const Task = union(enum) {
    detached: *Detached,
    @"async": *Async,

    const Detached = struct {
        fiber: Fiber,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
        context_buf: []u8,
        context_alignment: std.mem.Alignment,
        result_buf: []u8,
        result_alignment: std.mem.Alignment,

        state: std.atomic.Value(TaskState),

        waiter: std.atomic.Value(?*Detached),

        const TaskState = enum(u8) {
            Idle,
            Queued,
            Running,
            Rerun,
            Completed,
        };

        fn call(task: *Detached) void {
            task.start(@ptrCast(task.context_buf.ptr), @ptrCast(task.result_buf.ptr));
            const thread = Thread.current();
            const rt = thread.rt;

            _ = task.state.store(.Completed, .release);

            if (task.waiter.load(.acquire)) |w| {
                rt.reschedule(w);
            }

            const task_count = rt.shutdown.task_count.fetchSub(1, .acq_rel);
            log.info("task count: {any}", .{task_count});
            if (task_count == 1) {
                log.info("last task finished, signaling shutdown", .{});
                rt.shutdown.mutex.lock();
                rt.shutdown.cond.signal();
                rt.shutdown.mutex.unlock();
            }
        }

        fn deinit(task: *Detached, allocator: std.mem.Allocator) void {
            task.fiber.deinit(allocator);
            if (task.context_buf.len > 0) {
                allocator.rawFree(task.context_buf, task.context_alignment, @returnAddress());
            }
            if (task.result_buf.len > 0) {
                allocator.rawFree(task.result_buf, task.result_alignment, @returnAddress());
            }
        }
    };

    const Async = struct {
        fiber: Fiber,
        start: *const fn (arg: *anyopaque) void,
        arg: *anyopaque,

        waiter: Task,
        finished: bool = false,

        fn call(task: *Async) void {
            task.start(task.arg);
            task.finished = true;
        }

        fn deinit(task: *Async, allocator: std.mem.Allocator) void {
            task.fiber.deinit(allocator);
        }
    };

    threadlocal var cur: ?Task = null;

    fn current() Task {
        return cur.?;
    }

    fn fiber(task: Task) *Fiber {
        switch (task) {
            .detached => |t| {
                return &t.fiber;
            },
            .@"async" => |t| {
                return &t.fiber;
            },
        }
    }

    fn yeild(old_task: Task) void {
        const old_fiber = old_task.fiber();
        const new_ctx = ctx: switch (old_task) {
            .detached => &Thread.current().idle_context,
            .@"async" => |t| {
                Task.cur = t.waiter;
                break :ctx &t.waiter.fiber().ctx;
            },
        };
        contextSwitch(&old_fiber.ctx, new_ctx);
    }
};

/// A single fiber, with its own stack and saved context.
const Fiber = struct {
    ctx: Context,
    stack: []usize,

    /// Initialize a Fiber: alloc a stack, set up a context that will
    fn init(
        allocator: std.mem.Allocator,
        stack_size: usize,
    ) !Fiber {
        const stack = try allocator.alloc(usize, @divExact(stack_size, @sizeOf(usize)));

        const top = @intFromPtr(stack.ptr) + stack.len * @sizeOf(usize);

        return .{
            .ctx = .init(@intFromPtr(&trampoline), top),
            .stack = stack,
        };
    }

    fn trampoline() callconv(.C) noreturn {
        const task = Task.current();
        switch (task) {
            .detached => |t| {
                t.call();
            },
            .@"async" => |t| {
                t.call();
            },
        }
        log.info("task finished", .{});

        task.yeild();

        unreachable;
    }

    pub fn deinit(fiber: *Fiber, allocator: std.mem.Allocator) void {
        allocator.free(fiber.stack);
    }
};

// For now a thread is basiclly a detached fiber, later on we can make it steal work from other threads
const Thread = struct {
    rt: *Fibers,

    // The handle is set by the runtime, we dont touch it
    handle: std.Thread,

    idle_context: Context,

    io_ctx: ?*anyopaque,

    ready_mutex: std.Thread.Mutex,
    ready_queue: std.fifo.LinearFifo(*Task.Detached, .Dynamic),

    current_task: ?*Task.Detached,

    thread_id: usize,

    threadlocal var self: ?*Thread = null;

    fn current() *Thread {
        return self.?;
    }

    // Only push a task to a thread if it is idle!!!
    fn push(t: *Thread, task: *Task.Detached) void {
        t.ready_mutex.lock();
        t.ready_queue.writeItem(task) catch unreachable;
        t.ready_mutex.unlock();
    }

    // Only the owning thread can pop a task from the queue, we dont steal work here...
    fn pop(t: *Thread) ?*Task.Detached {
        t.ready_mutex.lock();
        const task = t.ready_queue.readItem();
        t.ready_mutex.unlock();
        return task;
    }

    fn entry(rt: *Fibers, thread_id: usize) void {
        // initialize thread, dont touch the handle field

        const thread = &rt.threads[thread_id];

        thread.rt = rt;
        thread.ready_queue = .init(rt.allocator);
        thread.current_task = null;
        thread.idle_context = .{};
        thread.io_ctx = rt.reactor.vtable.createContext(rt.reactor.ctx);
        thread.thread_id = thread_id;

        self = thread;

        while (true) {
            while (thread.pop()) |t| {
                const old_state = t.state.cmpxchgStrong(.Queued, .Running, .acq_rel, .acquire);
                if (old_state == .Completed) {
                    continue;
                }
                thread.current_task = t;
                Task.cur = .{
                    .detached = t,
                };
                contextSwitch(&Thread.current().idle_context, &t.fiber.ctx);
                const new_state = t.state.cmpxchgStrong(.Running, .Idle, .acq_rel, .acquire);
                log.info("task finished: {any}", .{new_state});

                if (new_state == .Rerun) {
                    log.info("rerunning task", .{});
                    t.state.store(.Queued, .release);
                    thread.push(t);
                }
            }

            if (rt.shutdown.task_count.load(.acquire) == 0) {
                if (rt.shutdown.requested.load(.acquire)) {
                    log.info("shutting down", .{});
                    break;
                }
            }

            rt.free_threads.mutex.lock();
            for (rt.free_threads.list.items) |item| {
                if (item == thread) {
                    break;
                }
            } else {
                rt.free_threads.list.append(thread) catch |err| {
                    log.err("failed to append thread to free list: {s}", .{@errorName(err)});
                    unreachable;
                };
            }
            thread.current_task = null;
            rt.free_threads.mutex.unlock();

            if (rt.shutdown.task_count.load(.acquire) == 0) {
                if (rt.shutdown.requested.load(.acquire)) {
                    log.info("shutting down", .{});
                    break;
                }
            }
            rt.reactor.vtable.onPark(rt.reactor.ctx, rt.executer());
        }

        rt.reactor.vtable.destroyContext(rt.reactor.ctx, thread.io_ctx);

        // After we get the exit signal, there are no tasks that can accsess our queue
        thread.ready_queue.deinit();
    }
};

// Places fiber on current thread
fn wake(ctx: ?*anyopaque, waker: *anyopaque) void {
    _ = ctx;
    const task: *Task.Detached = @alignCast(@ptrCast(waker));

    const t = Thread.current();
    t.push(task);

    _ = task.state.cmpxchgStrong(.Idle, .Queued, .acq_rel, .acquire);
}

fn getWaker(ctx: ?*anyopaque) *anyopaque {
    _ = ctx;
    return @ptrCast(Thread.current().current_task.?);
}

fn getThreadContext(ctx: ?*anyopaque) ?*anyopaque {
    _ = ctx;
    return Thread.current().io_ctx;
}

/// simply set ourselves to blocking, this is similar to returning Poll::Pending in rust
fn @"suspend"(ctx: ?*anyopaque) void {
    _ = ctx;
    Task.yeild(Task.current());
}

fn openFile(ctx: ?*anyopaque, path: []const u8, flags: Runtime.File.OpenFlags) Runtime.File.OpenError!Runtime.File {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.openFile(rt.reactor.ctx, rt.executer(), path, flags);
}

fn closeFile(ctx: ?*anyopaque, file: Runtime.File) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    rt.reactor.vtable.closeFile(rt.reactor.ctx, rt.executer(), file);
}

fn pread(ctx: ?*anyopaque, file: Runtime.File, buffer: []u8, offset: std.posix.off_t) Runtime.File.PReadError!usize {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.pread(rt.reactor.ctx, rt.executer(), file, buffer, offset);
}

fn pwrite(ctx: ?*anyopaque, file: Runtime.File, buffer: []const u8, offset: std.posix.off_t) Runtime.File.PWriteError!usize {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.pwrite(rt.reactor.ctx, rt.executer(), file, buffer, offset);
}

fn sleep(ctx: ?*anyopaque, ms: u64) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    rt.reactor.vtable.sleep(rt.reactor.ctx, rt.executer(), ms);
}

fn spawn(
    ctx: ?*anyopaque,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) *Runtime.AnySpawnHandle {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));

    const context_buf: []u8 = if (context.len > 0)
        (rt.allocator.rawAlloc(context.len, context_alignment, @returnAddress()) orelse unreachable)[0..context.len]
    else
        &[_]u8{};
    const result_buf: []u8 = if (result_len > 0)
        (rt.allocator.rawAlloc(result_len, result_alignment, @returnAddress()) orelse unreachable)[0..result_len]
    else
        &[_]u8{};

    @memcpy(context_buf, context);

    const task: *Task.Detached = rt.allocator.create(Task.Detached) catch unreachable;

    task.* = .{
        .fiber = Fiber.init(
            rt.allocator,
            1024 * 1024 * 10,
        ) catch unreachable,
        .start = start,
        .context_buf = context_buf,
        .context_alignment = context_alignment,
        .result_buf = result_buf,
        .result_alignment = result_alignment,
        .state = .init(.Queued),
        .waiter = .init(null),
    };

    rt.detached_tasks.mutex.lock();
    rt.detached_tasks.list.append(task) catch unreachable;
    rt.detached_tasks.mutex.unlock();

    _ = rt.shutdown.task_count.fetchAdd(1, .acq_rel);

    rt.schedule(task);

    return @ptrCast(task);
}

fn joinTask(ctx: ?*anyopaque, handle: *Runtime.AnySpawnHandle, result: []u8) void {
    _ = ctx;
    const task: *Task.Detached = @alignCast(@ptrCast(handle));

    task.waiter.store(Thread.current().current_task.?, .release);

    while (task.state.load(.acquire) != .Completed) {
        log.info("waiting for task to complete", .{});
        Task.yeild(Task.current());
    }

    @memcpy(result, task.result_buf);
}

fn select(
    ctx: ?*anyopaque,
    futures: []const Runtime.AnyFuture,
) usize {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    const me = Task.current();

    const tasks = rt.allocator.alloc(Task.Async, futures.len) catch unreachable;
    defer rt.allocator.free(tasks);

    var i: usize = 0;
    for (futures) |afut| {
        const fiber = Fiber.init(
            rt.allocator,
            1024 * 1024 * 10,
        ) catch unreachable;
        tasks[i] = .{
            .fiber = fiber,

            .arg = @ptrCast(afut.arg),
            .start = afut.start,
            .waiter = me,
        };

        i += 1;
    }

    const result = outer: while (true) {
        i = 0;
        for (tasks) |*task| {
            Task.cur = .{
                .@"async" = task,
            };
            if (task.finished) {
                break :outer i;
            }
            contextSwitch(&me.fiber().ctx, &task.fiber.ctx);
            if (task.finished) {
                break :outer i;
            }
            i += 1;
        }
        Task.yeild(me);
    };

    for (tasks) |*task| {
        task.deinit(rt.allocator);
    }

    return result;
}

fn join(ctx: ?*anyopaque, futures: []const Runtime.AnyFuture) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    const me = Task.current();

    const tasks = rt.allocator.alloc(Task.Async, futures.len) catch unreachable;
    defer rt.allocator.free(tasks);

    var i: usize = 0;
    for (futures) |afut| {
        const fiber = Fiber.init(
            rt.allocator,
            1024 * 1024 * 10,
        ) catch unreachable;
        tasks[i] = .{
            .fiber = fiber,

            .arg = @ptrCast(afut.arg),
            .start = afut.start,
            .waiter = me,
            .finished = false,
        };

        i += 1;
    }

    while (true) {
        var all_finished = true;
        i = 0;
        for (tasks) |*task| {
            if (!task.finished) {
                Task.cur = .{
                    .@"async" = task,
                };
                contextSwitch(&me.fiber().ctx, &task.fiber.ctx);
                if (!task.finished) {
                    all_finished = false;
                }
            }
            i += 1;
        }
        if (all_finished) {
            break;
        }

        Task.yeild(me);
    }

    for (tasks) |*task| {
        if (!task.finished) {
            unreachable;
        }
        task.deinit(rt.allocator);
    }
}

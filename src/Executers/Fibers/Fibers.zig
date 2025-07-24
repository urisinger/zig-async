const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const Alignment = std.mem.Alignment;

const Runtime = @import("../../Runtime.zig");
const Reactor = @import("../../Reactor.zig");
const Context = @import("./context.zig").Context;
const contextSwitch = @import("./context.zig").contextSwitch;
const Cancelable = Runtime.Cancelable;

const log = std.log.scoped(.Fibers);
const assert = std.debug.assert;

const Fibers = @This();
// 10MB
const stack_size = 1024 * 1024 * 10;
const page_size = std.heap.pageSize();
const page_align = Alignment.fromByteUnits(page_size);

const page_size_min = std.heap.page_size_min;

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
    .cancel = cancel,
    .joinTask = joinTask,
    .select = select,
    .join = join,

    .openFile = openFile,
    .closeFile = closeFile,
    .pread = pread,
    .awaitRead = awaitRead,
    .pwrite = pwrite,
    .awaitWrite = awaitWrite,
    .sleep = sleep,

    .createSocket = createSocket,
    .awaitCreateSocket = awaitCreateSocket,
    .closeSocket = closeSocket,
    .bind = bind,
    .listen = listen,
    .connect = connect,
    .awaitConnect = awaitConnect,
    .accept = accept,
    .awaitAccept = awaitAccept,
    .send = send,
    .awaitSend = awaitSend,
    .recv = recv,
    .awaitRecv = awaitRecv,

    .getStdIn = getStdIn,
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
    if (self.shutdown.task_count.load(.acquire) > 0) {
        self.shutdown.mutex.lock();
        self.shutdown.cond.wait(&self.shutdown.mutex);
        self.shutdown.mutex.unlock();
    }

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
        task.deinit();
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

fn reschedule(rt: *Fibers, task: *Task.Detached) void {
    if (task.state.cmpxchgStrong(.Idle, .Queued, .acq_rel, .acquire) == null and !task.completed.load(.acquire)) {
        rt.schedule(task);
        return;
    }

    _ = task.state.store(.Rerun, .release);
}

fn schedule(rt: *Fibers, task: *Task.Detached) void {
    rt.free_threads.mutex.lock();
    const maybe_thread: ?*Thread = rt.free_threads.list.pop();
    rt.free_threads.mutex.unlock();

    if (maybe_thread) |thread| {
        thread.push(task);

        rt.reactor.vtable.wakeThread(rt.reactor.ctx, if (Thread.self) |self| self.io_ctx else null, @ptrCast(thread.io_ctx));
    } else if (Thread.self) |t| {
        t.push(task);
    } else {
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
        context_alignment: Alignment,
        result_buf: []u8,
        result_alignment: Alignment,

        state: std.atomic.Value(TaskState),
        canceled: std.atomic.Value(bool),

        completed: std.atomic.Value(bool),

        waiter: std.atomic.Value(?*Detached),

        const TaskState = enum(u8) {
            Idle = 0,
            Queued = 1,
            Running = 2,
            Rerun = 3,
        };

        pub fn init(
            start: *const fn (context: *const anyopaque, result: *anyopaque) void,
            context: []const u8,
            context_alignment: Alignment,
            result_len: usize,
            result_alignment: Alignment,
        ) !*Detached {
            const stack_mem = std.heap.PageAllocator.map(stack_size, page_align) orelse return error.OutOfMemory;
            const stack_bottom = @intFromPtr(stack_mem);
            var stack_top = stack_bottom + stack_size;

            // Calculate space needed for structures (placed at top, stack grows down)
            const detached_size = @sizeOf(Detached);
            const detached_align = Alignment.fromByteUnits(@alignOf(Detached));

            // Align context size and position
            const task_ptr = detached_align.backward(stack_top - detached_size);
            stack_top = task_ptr;

            const context_ptr = if (context.len > 0)
                context_alignment.backward(stack_top - context.len)
            else
                stack_top;
            stack_top = context_ptr;

            const result_ptr = if (result_len > 0)
                result_alignment.backward(stack_top - result_len)
            else
                stack_top;
            stack_top = result_ptr;

            stack_top = std.mem.alignBackward(usize, stack_top, 16);

            // Ensure we have minimum stack space
            const min_stack_space = 1024;
            if (stack_top < stack_bottom + min_stack_space) {
                std.heap.PageAllocator.unmap(@alignCast(stack_mem[0..stack_size]));
                return error.OutOfMemory;
            }

            // Create pointers to structures
            const task: *Detached = @ptrFromInt(task_ptr);

            const context_buf: []u8 = if (context.len > 0)
                @as([*]u8, @ptrFromInt(context_ptr))[0..context.len]
            else
                &[_]u8{};

            const result_buf: []u8 = if (result_len > 0)
                @as([*]u8, @ptrFromInt(result_ptr))[0..result_len]
            else
                &[_]u8{};

            @memcpy(context_buf, context);

            // Initialize task - stack grows down from stack_top
            const aligned_ptr: [*]align(4096) u8 = @alignCast(stack_mem);
            const aligned_stack: []align(4096) u8 = aligned_ptr[0..stack_size];
            task.* = .{
                .fiber = .{
                    .stack = aligned_stack, // Store properly aligned slice
                    .ctx = .init(@intFromPtr(&Task.trampoline), stack_top),
                },
                .start = start,
                .context_buf = context_buf,
                .context_alignment = context_alignment,
                .result_buf = result_buf,
                .result_alignment = result_alignment,
                .state = .init(.Queued),
                .waiter = .init(null),
                .completed = .init(false),
                .canceled = .init(false),
            };

            return task;
        }

        fn call(task: *Detached) void {
            task.start(@ptrCast(task.context_buf.ptr), @ptrCast(task.result_buf.ptr));
            const thread = Thread.current();
            const rt = thread.rt;

            _ = task.completed.store(true, .release);

            if (task.waiter.load(.acquire)) |w| {
                rt.reschedule(w);
            }

            const task_count = rt.shutdown.task_count.fetchSub(1, .acq_rel);
            if (task_count == 1) {
                rt.shutdown.mutex.lock();
                rt.shutdown.cond.signal();
                rt.shutdown.mutex.unlock();
            }
        }

        fn deinit(task: *Detached) void {
            std.heap.PageAllocator.unmap(task.fiber.stack);
        }
    };

    const Async = struct {
        fiber: Fiber,
        start: *const fn (arg: *anyopaque) void,
        arg: *anyopaque,

        waiter: Task,
        finished: bool = false,
        canceled: bool = false,

        pub const Node = struct {
            task: Async,
            next: ?*Node,
        };

        fn init(
            start: *const fn (arg: *anyopaque) void,
            arg: *anyopaque,
            waiter: Task,
        ) !*Node {
            // Use aligned allocation for consistency with Detached tasks
            const stack_mem = std.heap.PageAllocator.map(stack_size, page_align) orelse return error.OutOfMemory;
            const stack_bottom = @intFromPtr(stack_mem);
            var stack_top = stack_bottom + stack_size;

            const async_size = @sizeOf(Node);
            const async_align = Alignment.fromByteUnits(@alignOf(Node));

            const task_ptr = async_align.backward(stack_top - async_size);
            stack_top = task_ptr;

            stack_top = std.mem.alignBackward(usize, stack_top, 16);

            const node: *Node = @ptrFromInt(task_ptr);
            node.* = .{
                .task = .{
                    .fiber = .{
                        .ctx = .init(@intFromPtr(&Task.trampoline), stack_top),
                        .stack = @alignCast(stack_mem[0..stack_size]),
                    },
                    .start = start,
                    .arg = arg,
                    .waiter = waiter,
                    .finished = false,
                },
                .next = null,
            };
            return node;
        }

        fn call(task: *Async) void {
            task.start(task.arg);
            task.finished = true;
        }

        fn deinit(task: *Async) void {
            std.heap.PageAllocator.unmap(task.fiber.stack);
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

    fn yeild(old_task: Task) bool {
        const old_fiber = old_task.fiber();
        const new_ctx = ctx: switch (old_task) {
            .detached => &Thread.current().idle_context,
            .@"async" => |t| {
                Task.cur = t.waiter;
                break :ctx &t.waiter.fiber().ctx;
            },
        };
        contextSwitch(&old_fiber.ctx, new_ctx);
        switch (old_task) {
            .detached => |t| {
                return t.canceled.load(.acquire);
            },
            .@"async" => |t| {
                return t.canceled;
            },
        }
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

        _ = task.yeild();
        unreachable;
    }
};

/// A single fiber, with its own stack and saved context.
const Fiber = struct {
    ctx: Context,
    stack: []align(4096) u8,
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
                _ = t.state.cmpxchgStrong(.Queued, .Running, .acq_rel, .acquire);
                if (t.completed.load(.acquire)) {
                    continue;
                }
                thread.current_task = t;
                Task.cur = .{
                    .detached = t,
                };
                contextSwitch(&Thread.current().idle_context, &t.fiber.ctx);
                const new_state = t.state.cmpxchgStrong(.Running, .Idle, .acq_rel, .acquire);

                if (new_state == .Rerun and !t.completed.load(.acquire)) {
                    t.state.store(.Queued, .release);
                    rt.reschedule(t);
                }
            }

            if (rt.shutdown.task_count.load(.acquire) == 0) {
                if (rt.shutdown.requested.load(.acquire)) {
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

fn spawn(
    ctx: ?*anyopaque,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) *Runtime.AnySpawnHandle {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));

    const task = Task.Detached.init(
        start,
        context,
        context_alignment,
        result_len,
        result_alignment,
    ) catch unreachable;

    rt.detached_tasks.mutex.lock();
    rt.detached_tasks.list.append(task) catch unreachable;
    rt.detached_tasks.mutex.unlock();

    _ = rt.shutdown.task_count.fetchAdd(1, .acq_rel);

    rt.schedule(task);

    return @ptrCast(task);
}

fn cancel(ctx: ?*anyopaque, handle: *Runtime.AnySpawnHandle) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    const task: *Task.Detached = @alignCast(@ptrCast(handle));
    task.canceled.store(true, .release);
    if (task.completed.load(.acquire)) {
        log.info("task already completed", .{});
        return;
    }
    rt.reschedule(task);
}

fn joinTask(ctx: ?*anyopaque, handle: *Runtime.AnySpawnHandle, result: []u8) Cancelable!void {
    _ = ctx;
    const task: *Task.Detached = @alignCast(@ptrCast(handle));

    task.waiter.store(Thread.current().current_task.?, .release);

    while (!task.completed.load(.acquire)) {
        if (Task.current().yeild()) {
            return error.Canceled;
        }
    }

    @memcpy(result, task.result_buf);
}

fn select(
    ctx: ?*anyopaque,
    futures: []const Runtime.AnyFuture,
) Cancelable!usize {
    _ = ctx;
    const me = Task.current();

    // Create linked list of task nodes
    var head: ?*Task.Async.Node = null;
    var current: ?*Task.Async.Node = null;

    var i: usize = 0;
    for (futures) |afut| {
        const node = Task.Async.init(
            afut.start,
            @ptrCast(afut.arg),
            me,
        ) catch unreachable;

        // Add to linked list
        if (head == null) {
            head = node;
            current = node;
        } else {
            current.?.next = node;
            current = node;
        }

        i += 1;
    }

    const result = outer: while (true) {
        // Iterate through linked list
        var node = head;
        var index: usize = 0;
        while (node) |current_node| {
            Task.cur = .{
                .@"async" = &current_node.task,
            };
            if (current_node.task.finished) {
                break :outer index;
            }
            contextSwitch(&me.fiber().ctx, &current_node.task.fiber.ctx);
            if (current_node.task.finished) {
                break :outer index;
            }
            node = current_node.next;
            index += 1;
        }
        if (Task.current().yeild()) {
            return error.Canceled;
        }
    };

    // Clean up linked list
    var node = head;
    while (node) |current_node| {
        const next = current_node.next;
        current_node.task.deinit();
        node = next;
    }

    return result;
}

fn join(ctx: ?*anyopaque, futures: []const Runtime.AnyFuture) Cancelable!void {
    _ = ctx;
    const me = Task.current();

    // Create linked list of task nodes
    var head: ?*Task.Async.Node = null;
    var current: ?*Task.Async.Node = null;

    var i: usize = 0;
    for (futures) |afut| {
        const node = Task.Async.init(
            afut.start,
            @ptrCast(afut.arg),
            me,
        ) catch unreachable;

        // Add to linked list
        if (head == null) {
            head = node;
            current = node;
        } else {
            current.?.next = node;
            current = node;
        }

        i += 1;
    }

    while (true) {
        var all_finished = true;

        // Iterate through linked list
        var node = head;
        while (node) |current_node| {
            if (!current_node.task.finished) {
                Task.cur = .{
                    .@"async" = &current_node.task,
                };
                contextSwitch(&me.fiber().ctx, &current_node.task.fiber.ctx);
                if (!current_node.task.finished) {
                    all_finished = false;
                }
            }
            node = current_node.next;
        }

        if (all_finished) {
            break;
        }

        if (Task.current().yeild()) {
            return error.Canceled;
        }
    }

    // Clean up linked list and verify all tasks finished
    var node = head;
    while (node) |current_node| {
        if (!current_node.task.finished) {
            unreachable;
        }
        const next = current_node.next;
        current_node.task.deinit();
        node = next;
    }
}

// Places fiber on current thread
fn wake(ctx: ?*anyopaque, waker: *anyopaque) void {
    _ = ctx;
    const task: *Task.Detached = @alignCast(@ptrCast(waker));

    const t = Thread.current();

    // If the task isnt already queued or set to rerun, queue it
    const old_state = task.state.cmpxchgStrong(.Idle, .Queued, .acq_rel, .acquire);
    if (old_state == null) {
        t.push(task);
    }
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
fn @"suspend"(ctx: ?*anyopaque) bool {
    _ = ctx;
    return Task.current().yeild();
}

fn openFile(ctx: ?*anyopaque, path: []const u8, flags: Runtime.File.OpenFlags) Runtime.File.OpenError!Runtime.File {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.openFile(rt.reactor.ctx, rt.executer(), path, flags);
}

fn closeFile(ctx: ?*anyopaque, file: Runtime.File) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    rt.reactor.vtable.closeFile(rt.reactor.ctx, rt.executer(), file);
}

fn pread(ctx: ?*anyopaque, file: Runtime.File, buffer: []u8, offset: std.posix.off_t) *Runtime.File.AnyReadHandle {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.pread(rt.reactor.ctx, rt.executer(), file, buffer, offset);
}

fn awaitRead(ctx: ?*anyopaque, handle: *Runtime.File.AnyReadHandle) Runtime.File.PReadError!usize {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.awaitRead(rt.reactor.ctx, rt.executer(), handle);
}

fn pwrite(ctx: ?*anyopaque, file: Runtime.File, buffer: []const u8, offset: std.posix.off_t) *Runtime.File.AnyWriteHandle {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.pwrite(rt.reactor.ctx, rt.executer(), file, buffer, offset);
}

fn awaitWrite(ctx: ?*anyopaque, handle: *Runtime.File.AnyWriteHandle) Runtime.File.PWriteError!usize {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.awaitWrite(rt.reactor.ctx, rt.executer(), handle);
}

fn sleep(ctx: ?*anyopaque, ms: u64) Cancelable!void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    try rt.reactor.vtable.sleep(rt.reactor.ctx, rt.executer(), ms);
}

fn createSocket(ctx: ?*anyopaque, domain: Runtime.Socket.Domain, protocol: Runtime.Socket.Protocol) *Runtime.Socket.AnyCreateHandle {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.createSocket(rt.reactor.ctx, rt.executer(), domain, protocol);
}

fn awaitCreateSocket(ctx: ?*anyopaque, handle: *Runtime.Socket.AnyCreateHandle) Runtime.Socket.CreateError!Runtime.Socket {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.awaitCreateSocket(rt.reactor.ctx, rt.executer(), handle);
}

fn closeSocket(ctx: ?*anyopaque, socket: Runtime.Socket) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    rt.reactor.vtable.closeSocket(rt.reactor.ctx, rt.executer(), socket);
}

fn bind(ctx: ?*anyopaque, socket: Runtime.Socket, address: *const Runtime.Socket.Address, length: u32) Runtime.Socket.BindError!void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    try rt.reactor.vtable.bind(rt.reactor.ctx, rt.executer(), socket, address, length);
}

fn listen(ctx: ?*anyopaque, socket: Runtime.Socket, backlog: u32) Runtime.Socket.ListenError!void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    try rt.reactor.vtable.listen(rt.reactor.ctx, rt.executer(), socket, backlog);
}

fn connect(ctx: ?*anyopaque, socket: Runtime.Socket, address: *const Runtime.Socket.Address) *Runtime.Socket.AnyConnectHandle {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.connect(rt.reactor.ctx, rt.executer(), socket, address);
}

fn awaitConnect(ctx: ?*anyopaque, handle: *Runtime.Socket.AnyConnectHandle) Runtime.Socket.ConnectError!void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.awaitConnect(rt.reactor.ctx, rt.executer(), handle);
}

fn accept(ctx: ?*anyopaque, socket: Runtime.Socket) *Runtime.Socket.AnyAcceptHandle {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.accept(rt.reactor.ctx, rt.executer(), socket);
}

fn awaitAccept(ctx: ?*anyopaque, handle: *Runtime.Socket.AnyAcceptHandle) Runtime.Socket.AcceptError!Runtime.Socket {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.awaitAccept(rt.reactor.ctx, rt.executer(), handle);
}

fn send(ctx: ?*anyopaque, socket: Runtime.Socket, buffer: []const u8, flags: Runtime.Socket.SendFlags) *Runtime.Socket.AnySendHandle {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.send(rt.reactor.ctx, rt.executer(), socket, buffer, flags);
}

fn awaitSend(ctx: ?*anyopaque, handle: *Runtime.Socket.AnySendHandle) Runtime.Socket.SendError!usize {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.awaitSend(rt.reactor.ctx, rt.executer(), handle);
}

fn recv(ctx: ?*anyopaque, socket: Runtime.Socket, buffer: []u8, flags: Runtime.Socket.RecvFlags) *Runtime.Socket.AnyRecvHandle {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.recv(rt.reactor.ctx, rt.executer(), socket, buffer, flags);
}

fn awaitRecv(ctx: ?*anyopaque, handle: *Runtime.Socket.AnyRecvHandle) Runtime.Socket.RecvError!usize {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.awaitRecv(rt.reactor.ctx, rt.executer(), handle);
}

fn getStdIn(ctx: ?*anyopaque) Runtime.File {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    return rt.reactor.vtable.getStdIn(rt.reactor.ctx, rt.executer());
}

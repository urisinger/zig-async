const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("Runtime.zig");
const Cancelable = Runtime.Cancelable;
const Io = @import("Io.zig");
const types = @import("types.zig");
const EitherPtr = types.EitherPtr;

const log = std.log.scoped(.Fibers);
const assert = std.debug.assert;

const Fibers = @This();

allocator: std.mem.Allocator,
// We save this just so we can join
threads: struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList(std.Thread),
},

threads_to_exit: struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList(*Thread),
},

task_count: std.atomic.Value(usize),

// Free threads, we can
free_threads: struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList(*Thread),
},

detached_fibers: struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList(*Fiber),
},

io: Io,
const vtable: Runtime.VTable = .{
    .@"async" = @"async",
    .asyncDetached = asyncDetached,
    .@"await" = @"await",
    .@"suspend" = @"suspend",
    .cancel = cancel,
    .select = select,
    .wake = wake,
    .getWaker = getWaker,
    .getLocalContext = getLocalContext,
};

pub fn init(allocator: std.mem.Allocator, io: Io) Fibers {
    return .{
        .allocator = allocator,

        .threads = .{
            .mutex = .{},
            .list = .init(allocator),
        },

        .free_threads = .{
            .mutex = .{},
            .list = .init(allocator),
        },

        .threads_to_exit = .{
            .mutex = .{},
            .list = .init(allocator),
        },

        .detached_fibers = .{
            .mutex = .{},
            .list = .init(allocator),
        },

        .task_count = std.atomic.Value(usize).init(0),

        .io = io,
    };
}

pub fn deinit(self: *Fibers) void {
    self.threads.mutex.lock();
    self.threads.list.deinit();
    self.threads.mutex.unlock();

    self.free_threads.mutex.lock();
    self.free_threads.list.deinit();
    self.free_threads.mutex.unlock();

    self.detached_fibers.mutex.lock();
    for (self.detached_fibers.list.items) |fiber| {
        fiber.deinit(self.allocator);
        self.allocator.destroy(fiber);
    }
    self.detached_fibers.list.deinit();
    self.detached_fibers.mutex.unlock();
}

pub fn join(self: *Fibers) void {
    self.threads.mutex.lock();
    const threads_copy = self.threads.list.clone() catch unreachable;
    self.threads.mutex.unlock();

    for (threads_copy.items) |thread| {
        thread.join();

        log.info("joined thread", .{});
    }

    threads_copy.deinit();
}

pub fn runtime(self: *Fibers) Runtime {
    return .{
        .vtable = &vtable,
        .ctx = @ptrCast(self),
        .io = self.io,
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

fn contextSwitch(old_ctx: *Context, new_ctx: *const Context) callconv(switch (builtin.cpu.arch) {
    .x86_64 => .{ .x86_64_sysv = .{} },
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
}) void {
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
            : "rax", "rcx", "rbx", "r12", "r13", "r14", "r15", "memory"
        ),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    }
}

noinline fn schedule(rt: *Fibers, fiber: *Fiber) void {
    const state = fiber.state.cmpxchgStrong(.Idle, .Queued, .acq_rel, .acquire);
    log.info("state: {?}", .{state});
    if (state != null) {
        log.info("fiber already running", .{});
        return;
    }

    rt.free_threads.mutex.lock();
    const maybe_thread: ?*Thread = rt.free_threads.list.pop();
    rt.free_threads.mutex.unlock();

    if (maybe_thread) |thread| {
        thread.push(fiber);

        rt.io.vtable.wakeThread(rt.io.ctx, rt.runtime(), @ptrCast(thread.io_ctx));
    } else {
        const thread = std.Thread.spawn(.{}, Thread.entry, .{ rt, fiber }) catch |err| {
            log.err("failed to spawn thread: {s}", .{@errorName(err)});
            unreachable;
        };
        rt.threads.mutex.lock();
        rt.threads.list.append(thread) catch |err| {
            log.err("failed to append thread to thread list: {s}", .{@errorName(err)});
            unreachable;
        };
        rt.threads.mutex.unlock();
    }
}

/// A single fiber, with its own stack and saved context.
const Fiber = struct {
    ctx: Context,
    stack: []usize,

    context_buf: []u8,
    context_alignment: std.mem.Alignment,

    result_slice: []u8,
    result_alignment: std.mem.Alignment,

    entry: *const fn (arg: *anyopaque) void,
    arg: *anyopaque,

    // Use atomics for these, shared across threads
    canceled: std.atomic.Value(bool),

    state: std.atomic.Value(FiberState),
    const FiberState = enum(u8) {
        Idle,
        Queued,
        Completed,
    };

    /// Initialize a Fiber: alloc a stack, set up a context that will
    fn init(
        allocator: std.mem.Allocator,
        stack_size: usize,
        entry: *const fn (*anyopaque) void,
        arg: *anyopaque,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        result: []const u8,
        result_alignment: std.mem.Alignment,
    ) !Fiber {
        const stack = try allocator.alloc(usize, @divExact(stack_size, @sizeOf(usize)));

        const top = @intFromPtr(stack.ptr) + stack.len * @sizeOf(usize);

        const result_slice: []u8 = if (result.len == 0)
            &[_]u8{}
        else
            (allocator.rawAlloc(result.len, result_alignment, @returnAddress()) orelse unreachable)[0..result.len];

        const context_buf: []u8 = if (context.len == 0)
            &[_]u8{}
        else
            (allocator.rawAlloc(context.len, context_alignment, @returnAddress()) orelse unreachable)[0..context.len];

        @memcpy(context_buf, context);

        return .{
            .ctx = .init(@intFromPtr(&trampoline), top),
            .stack = stack,
            .context_buf = context_buf,
            .context_alignment = context_alignment,
            .result_slice = result_slice,
            .result_alignment = result_alignment,
            .entry = entry,
            .arg = arg,
            .state = .init(.Idle),
            .canceled = .init(false),
        };
    }

    fn cancel(self: *Fiber) void {
        self.canceled.store(true, .release);
        self.wake();
    }

    fn isCanceled(self: *Fiber) bool {
        return self.canceled.load(.acquire);
    }

    fn trampoline() callconv(.C) void {
        const t = Thread.current();
        const fib = t.current_fiber.?;
        fib.entry(fib.arg);

        if (t.rt.task_count.fetchSub(1, .acq_rel) == 1) {
            t.rt.threads_to_exit.mutex.lock();
            for (t.rt.threads_to_exit.list.items) |thread| {
                t.rt.io.vtable.signalExit(t.rt.io.ctx, t.rt.runtime(), thread.io_ctx);
            }
            t.rt.threads_to_exit.list.clearAndFree();
            t.rt.threads_to_exit.mutex.unlock();
        }

        _ = fib.state.cmpxchgStrong(.Queued, .Completed, .acq_rel, .acquire);

        t.yeild(&fib.ctx, t.pop());
    }

    pub fn deinit(self: *Fiber, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);

        if (self.context_buf.len > 0) {
            allocator.rawFree(self.context_buf, self.context_alignment, @returnAddress());
        }
        if (self.result_slice.len > 0) {
            allocator.rawFree(self.result_slice, self.result_alignment, @returnAddress());
        }
    }

    pub fn block() bool {
        const t = Thread.current();
        const fiber = t.current_fiber.?;
        if (fiber.isCanceled()) {
            return true;
        }
        t.yeild(&fiber.ctx, t.pop());

        return fiber.canceled.load(.acquire);
    }

    pub fn wake(fiber: *Fiber) void {
        Thread.current().rt.schedule(fiber);
    }

    pub fn current() ?*Fiber {
        return Thread.current().current_fiber;
    }
};

// For now a thread is basiclly a detached fiber, later on we can make it steal work from other threads
const Thread = struct {
    rt: *Fibers,

    idle_context: Context,

    io_ctx: ?*anyopaque,

    ready_mutex: std.Thread.Mutex,
    ready_queue: std.fifo.LinearFifo(*Fiber, .Dynamic),

    current_fiber: ?*Fiber,

    threadlocal var self: *Thread = undefined;

    fn current() *Thread {
        return self;
    }

    fn push(t: *Thread, fib: *Fiber) void {
        t.ready_mutex.lock();
        t.ready_queue.writeItem(fib) catch unreachable;
        t.ready_mutex.unlock();
    }

    fn pop(t: *Thread) ?*Fiber {
        t.ready_mutex.lock();
        const fiber = t.ready_queue.readItem();
        t.ready_mutex.unlock();
        return fiber;
    }

    // Allows the next fiber to run
    fn yeild(t: *Thread, old_ctx: *Context, new_fiber: ?*Fiber) void {
        const new_ctx = if (new_fiber) |fib| &fib.ctx else &t.idle_context;

        if (t.current_fiber) |fib| {
            // If we are running, set ourselves to idle
            _ = fib.state.cmpxchgStrong(.Queued, .Idle, .acq_rel, .acquire);
        }

        t.current_fiber = new_fiber;
        contextSwitch(old_ctx, new_ctx);
    }

    fn entry(rt: *Fibers, fiber: *Fiber) void {
        var t: Thread =
            .{
                .rt = rt,
                .ready_mutex = .{},
                .ready_queue = .init(rt.allocator),
                .current_fiber = null,
                .idle_context = .{},
                .io_ctx = rt.io.vtable.createContext(rt.io.ctx),
            };

        t.rt.threads_to_exit.mutex.lock();
        t.rt.threads_to_exit.list.append(&t) catch unreachable;
        t.rt.threads_to_exit.mutex.unlock();

        self = &t;

        t.push(fiber);
        t.current_fiber = fiber;

        while (true) {
            while (t.pop()) |f| {
                t.yeild(&t.idle_context, f);
            }

            rt.free_threads.mutex.lock();
            rt.free_threads.list.append(&t) catch |err| {
                log.err("failed to append thread to free list: {s}", .{@errorName(err)});
                unreachable;
            };
            rt.free_threads.mutex.unlock();
            t.current_fiber = null;
            if (rt.io.vtable.onPark(rt.io.ctx, rt.runtime())) {
                break;
            }
        }

        rt.io.vtable.destroyContext(rt.io.ctx, rt.runtime(), t.io_ctx);

        // After we get the exit signal, there are no tasks that can accsess our queue
        t.ready_mutex.lock();
        t.ready_queue.deinit();
        t.ready_mutex.unlock();
    }
};

// Places fiber on current thread
fn wake(ctx: ?*anyopaque, waker: *anyopaque) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));
    const fiber: *Fiber = @alignCast(@ptrCast(waker));

    schedule(rt, fiber);
}

fn getWaker(ctx: ?*anyopaque) *anyopaque {
    _ = ctx;
    return @ptrCast(Thread.current().current_fiber.?);
}

fn getLocalContext(ctx: ?*anyopaque) ?*anyopaque {
    _ = ctx;
    return Thread.current().io_ctx;
}

const AsyncTask = struct {
    fiber: Fiber,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,

    // Either a pointer to fiber, or whether the task is finished
    waiter: std.atomic.Value(EitherPtr(*Fiber, bool)) = .init(.initValue(false)),

    fn call(arg: *anyopaque) void {
        const task: *AsyncTask = @alignCast(@ptrCast(arg));
        task.start(@ptrCast(task.fiber.context_buf.ptr), @ptrCast(task.fiber.result_slice.ptr));

        if (task.finish()) |w| {
            w.wake();
        }
    }

    // set waiter to 1 (finished)
    fn finish(self: *AsyncTask) ?*Fiber {
        return self.waiter.swap(.initValue(true), .acq_rel).asPtr();
    }

    // returns true if finished
    fn setWaiter(self: *AsyncTask, waiter: *Fiber) bool {
        return self.waiter.swap(.initPtr(waiter), .acq_rel).asValue() == true;
    }

    fn isFinished(self: *AsyncTask) bool {
        return self.waiter.load(.acquire).asValue() == true;
    }

    fn deinit(self: *AsyncTask, allocator: std.mem.Allocator) void {
        self.fiber.deinit(allocator);
    }
};

/// —————————————————————————————————————————————————————————————————————
/// async: spawn a fiber on the main thread
/// —————————————————————————————————————————————————————————————————————
noinline fn @"async"(
    ctx: ?*anyopaque,
    result: []u8,
    ra: std.mem.Alignment,
    context: []const u8,
    ca: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Runtime.AnyFuture {
    log.info("hi from here", .{});
    const rt: *Fibers = @alignCast(@ptrCast(ctx.?));

    var task = rt.allocator.create(Fibers.AsyncTask) catch unreachable;
    task.* = .{
        .fiber = Fiber.init(
            rt.allocator,
            1024 * 1024,
            AsyncTask.call,
            @ptrCast(task),
            context,
            ca,
            result,
            ra,
        ) catch unreachable,
        .start = start,
    };

    _ = rt.task_count.fetchAdd(1, .acq_rel);
    rt.schedule(&task.fiber);

    return @ptrCast(task);
}

/// —————————————————————————————————————————————————————————————————————
/// await: park current fiber until its task completes
/// —————————————————————————————————————————————————————————————————————
fn @"await"(
    ctx: ?*anyopaque,
    any_future: *Runtime.AnyFuture,
    result: []u8,
    ra: std.mem.Alignment,
) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx.?));
    const task: *AsyncTask = @alignCast(@ptrCast(any_future));
    _ = ra;

    const me = Fiber.current().?;
    // If task hasnt finished yet, we block until its done
    if (!task.setWaiter(me)) {
        log.info("blocking", .{});
        if (Fiber.block()) {
            task.fiber.cancel();
        }
    }

    // when resumed, result has been written in-place:
    @memcpy(result, task.fiber.result_slice);

    // Only now can we free the task.
    task.deinit(rt.allocator);
    rt.allocator.destroy(task);
}

fn startDetached(arg: *anyopaque) void {
    const t = Thread.current();
    const rt = t.rt;
    const fiber = t.current_fiber.?;
    const start: *const fn (context: *const anyopaque) void = @alignCast(@ptrCast(arg));

    start(fiber.context_buf.ptr);

    log.info("deiniting fiber", .{});

    fiber.deinit(rt.allocator);

    log.info("deiniting fiber done", .{});
    rt.allocator.destroy(fiber);
}

/// asyncDetached: fire‑and‑forget on a real thread
fn asyncDetached(
    ctx: ?*anyopaque,
    context: []const u8,
    ca: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));

    const fiber: *Fiber = rt.allocator.create(Fiber) catch unreachable;

    // We const cast becuase we know startDetached will use arg in a const way
    fiber.* = Fiber.init(
        rt.allocator,
        1024 * 1024,
        start,
        // just a temporary pointer to the fiber, we will set arg to the context_buf.ptr
        @ptrCast(fiber),
        context,
        ca,
        &[_]u8{},
        .@"1",
    ) catch unreachable;

    fiber.arg = @ptrCast(fiber.context_buf.ptr);

    rt.detached_fibers.mutex.lock();
    rt.detached_fibers.list.append(fiber) catch unreachable;
    rt.detached_fibers.mutex.unlock();

    _ = rt.task_count.fetchAdd(1, .acq_rel);
    rt.schedule(fiber);
}

/// simply set ourselves to blocking, we wont unblock until we get woken up
fn @"suspend"(ctx: ?*anyopaque) Cancelable!void {
    _ = ctx;
    if (Fiber.block()) {
        return error.Canceled;
    }
}

fn cancel(ctx: ?*anyopaque, any_future: *Runtime.AnyFuture, result: []u8, ra: std.mem.Alignment) void {
    _ = ra;
    const rt: *Fibers = @alignCast(@ptrCast(ctx.?));

    const task: *AsyncTask = @alignCast(@ptrCast(any_future));

    const me = Fiber.current().?;
    if (!task.setWaiter(me)) {
        task.fiber.cancel();

        _ = Fiber.block();
    }

    // when resumed, result has been written in-place:
    @memcpy(result, task.fiber.result_slice);

    // Only now can we free the task.
    task.deinit(rt.allocator);
    rt.allocator.destroy(task);
}

/// wait on multiple futures
fn select(
    ctx: ?*anyopaque,
    futures: []const *Runtime.AnyFuture,
) usize {
    _ = ctx;
    const me = Fiber.current().?;

    var i: usize = 0;
    for (futures) |afut| {
        const t: *AsyncTask = @alignCast(@ptrCast(afut));
        if (t.setWaiter(me)) {
            return i;
        }
        i += 1;
    }
    _ = Fiber.block();

    i = 0;
    for (futures) |afut| {
        const t: *AsyncTask = @alignCast(@ptrCast(afut));

        if (t.isFinished()) {
            return i;
        }
        i += 1;
    }
    unreachable;
}

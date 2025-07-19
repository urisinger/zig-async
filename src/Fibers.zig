const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("Runtime.zig");
const Cancelable = Runtime.Cancelable;
const Io = @import("Io.zig");

const log = std.log.scoped(.Fibers);
const assert = std.debug.assert;

const Fibers = @This();

allocator: std.mem.Allocator,
// We save this just so we can join
threads: struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList(std.Thread),
},

// Free threads, we can
free_threads: struct {
    mutex: std.Thread.Mutex,
    list: std.ArrayList(*Thread),
},

// Signal to all threads to exit
should_exit: std.atomic.Value(bool),

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

        .should_exit = std.atomic.Value(bool).init(false),

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
}

pub fn shutdown(self: *Fibers) void {
    // Signal all threads to exit
    self.should_exit.store(true, .release);

    // Wake up all idle threads by sending them wake signals
    self.free_threads.mutex.lock();
    const free_threads = self.free_threads.list.clone() catch unreachable;
    self.free_threads.mutex.unlock();

    free_threads.deinit();
}

pub fn join(self: *Fibers) void {
    // First shutdown threads
    self.shutdown();

    self.threads.mutex.lock();
    const threads_copy = self.threads.list.clone() catch unreachable;
    self.threads.mutex.unlock();

    for (threads_copy.items) |thread| {
        thread.join();
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

fn schedule(rt: *Fibers, fiber: *Fiber) void {
    rt.free_threads.mutex.lock();
    const maybe_thread: ?*Thread = rt.free_threads.list.pop();
    rt.free_threads.mutex.unlock();

    if (maybe_thread) |thread| {
        fiber.thread = thread;
        rt.io.vtable.wakeThread(rt.io.ctx, rt.runtime(), @ptrCast(thread), @ptrCast(fiber));
    } else {
        const t = rt.allocator.create(Thread) catch unreachable;
        t.* = .{
            .rt = rt,
            .running_queue = fiber,
            .idle_context = .{},
            .io_ctx = rt.io.vtable.createContext(rt.io.ctx),
        };
        fiber.thread = t;
        const thread = std.Thread.spawn(.{}, Thread.entry, .{ rt, t }) catch |err| {
            std.log.err("failed to spawn thread: {s}", .{@errorName(err)});
            unreachable;
        };
        rt.threads.mutex.lock();
        rt.threads.list.append(thread) catch |err| {
            std.log.err("failed to append thread to thread list: {s}", .{@errorName(err)});
            unreachable;
        };
        rt.threads.mutex.unlock();
    }
}

/// A single fiber, with its own stack and saved context.
const Fiber = struct {
    ctx: Context,
    stack: []usize,
    entry: *const fn (arg: *anyopaque) void,
    arg: *anyopaque,

    thread: ?*Thread,

    // A fiber forms a circular queue
    next_fiber: *Fiber,
    prev_fiber: *Fiber,

    // Use atomics for these, shared across threads
    state: State = .running,
    // Use atomics for these, shared across threads
    canceled: bool = false,

    const State = enum {
        running,
        waiting,
        finished,
    };

    /// Initialize a Fiber: alloc a stack, set up a context that will
    fn init(
        self: *Fiber,
        allocator: std.mem.Allocator,
        stack_size: usize,
        entry: *const fn (*anyopaque) void,
        arg: *anyopaque,
    ) !void {
        const stack = try allocator.alloc(usize, @divExact(stack_size, @sizeOf(usize)));
        self.stack = stack;
        self.entry = entry;
        self.arg = arg;

        const top = @intFromPtr(stack.ptr) + stack.len * @sizeOf(usize);
        self.ctx = .init(@intFromPtr(&trampoline), top);
        self.state = .running;

        self.next_fiber = self;
        self.prev_fiber = self;
    }

    pub fn cancel(self: *Fiber) void {
        @atomicStore(bool, &self.canceled, true, .monotonic);
    }

    pub fn isCanceled(self: *Fiber) bool {
        return @atomicLoad(bool, &self.canceled, .monotonic);
    }

    fn trampoline() callconv(.C) void {
        const t = Thread.current();
        const fib = t.running_queue.?;
        std.log.info("running fiber", .{});
        fib.entry(fib.arg);

        // Remove us from the running queue
        t.running_queue = fib.remove();

        contextSwitch(&fib.ctx, t.currentContext());
    }

    pub fn deinit(self: *Fiber, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
    }

    pub fn block(fiber: *Fiber) void {
        // Remove ourselves from the running queue
        const new_head = fiber.remove();

        // only update the head if we are currently running
        if (fiber.thread.?.running_queue == fiber) {
            fiber.thread.?.running_queue = new_head;
        }

        fiber.state = .waiting;

        fiber.thread.?.yeild(&fiber.ctx);
    }

    pub fn wake(fiber: *Fiber) void {
        fiber.thread.?.rt.io.vtable.wakeThread(
            fiber.thread.?.rt.io.ctx,
            fiber.thread.?.rt.runtime(),
            @ptrCast(fiber.thread.?.io_ctx),
            @ptrCast(fiber),
        );
    }

    pub fn current() ?*Fiber {
        return Thread.current().running_queue;
    }

    /// Insert `new_fiber` *after* `self` in the circular doubly-linked list.
    pub fn insert(self: *Fiber, new_fiber: *Fiber) void {
        const next = self.next_fiber;

        new_fiber.prev_fiber = self;
        new_fiber.next_fiber = next;

        next.prev_fiber = new_fiber;
        self.next_fiber = new_fiber;
    }

    pub fn insertBefore(self: *Fiber, new_fiber: *Fiber) void {
        const prev = self.prev_fiber;

        new_fiber.next_fiber = self;
        new_fiber.prev_fiber = prev;

        prev.next_fiber = new_fiber;
        self.prev_fiber = new_fiber;
    }

    /// Remove `self` from its circular list.
    /// If `self` was the only node, returns null.
    /// Otherwise returns the new head (the next fiber after `self`).
    pub fn remove(self: *Fiber) ?*Fiber {
        if (self.next_fiber == self) {
            return null;
        }

        self.prev_fiber.next_fiber = self.next_fiber;
        self.next_fiber.prev_fiber = self.prev_fiber;

        return self.next_fiber;
    }
};

// For now a thread is basiclly a detached fiber, later on we can make it steal work from other threads
const Thread = struct {
    rt: *Fibers,

    running_queue: ?*Fiber,

    idle_context: Context,

    io_ctx: ?*anyopaque,

    threadlocal var self: *Thread = undefined;

    fn current() *Thread {
        return self;
    }

    fn insertFiber(t: *Thread, fib: *Fiber) void {
        if (t.running_queue) |running_queue| {
            running_queue.insertBefore(fib);
        } else {
            fib.next_fiber = fib;
            fib.prev_fiber = fib;
            t.running_queue = fib;
        }
    }

    fn currentContext(t: *Thread) *Context {
        if (t.running_queue) |fib| {
            return &fib.ctx;
        } else {
            return &t.idle_context;
        }
    }

    // Allows the next fiber to run
    fn yeild(t: *Thread, old_ctx: *Context) void {
        if (t.running_queue) |fiber| {
            const new_ctx = &fiber.next_fiber.ctx;

            t.running_queue = fiber.next_fiber;

            contextSwitch(old_ctx, new_ctx);
        } else {
            // No tasks to run, we go to idle loop
            const new_ctx = &t.idle_context;
            contextSwitch(old_ctx, new_ctx);
        }
    }

    fn entry(rt: *Fibers, t: *Thread) void {
        self = t;
        while (true) {
            if (self.running_queue) |fiber| {
                const old_ctx = &self.idle_context;
                const new_ctx = &fiber.ctx;

                std.log.info("switching to fiber", .{});

                contextSwitch(old_ctx, new_ctx);

                rt.free_threads.mutex.lock();
                rt.free_threads.list.append(t) catch |err| {
                    std.log.err("failed to append thread to free list: {s}", .{@errorName(err)});
                    unreachable;
                };
                rt.free_threads.mutex.unlock();
            }

            rt.io.vtable.onPark(rt.io.ctx, rt.runtime());
        }

        //rt.allocator.rawFree(context_buf, ca, @returnAddress());
    }
};

// May only wake on the current thread
fn wake(ctx: ?*anyopaque, waker: *anyopaque) void {
    _ = ctx;
    const fiber: *Fiber = @alignCast(@ptrCast(waker));

    std.log.info("waking fiber", .{});

    if (fiber.state == .waiting) {
        fiber.thread.?.insertFiber(fiber);
        fiber.state = .running;
    }
}

fn getWaker(ctx: ?*anyopaque) *anyopaque {
    _ = ctx;
    return @ptrCast(Thread.current().running_queue.?);
}

fn getLocalContext(ctx: ?*anyopaque) ?*anyopaque {
    _ = ctx;
    return Thread.current().io_ctx;
}

const AsyncTask = struct {
    fiber: Fiber,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    result_slice: []u8,
    context_buf: []u8,
    context_alignment: std.mem.Alignment,
    waiter: ?*Fiber,

    fn call(arg: *anyopaque) void {
        const task: *AsyncTask = @alignCast(@ptrCast(arg));
        task.start(@ptrCast(task.context_buf.ptr), @ptrCast(task.result_slice.ptr));

        if (task.waiter) |w| {
            std.log.info("task finished, waking up", .{});
            w.wake();
        }
        task.waiter = null;
        task.fiber.state = .finished;
    }

    fn deinit(self: *AsyncTask, allocator: std.mem.Allocator, result_alignment: std.mem.Alignment) void {
        self.fiber.deinit(allocator);
        allocator.rawFree(self.result_slice, result_alignment, @returnAddress());
        allocator.rawFree(self.context_buf, self.context_alignment, @returnAddress());
    }
};

/// —————————————————————————————————————————————————————————————————————
/// async: spawn a fiber on the main thread
/// —————————————————————————————————————————————————————————————————————
fn @"async"(
    ctx: ?*anyopaque,
    result: []u8,
    ra: std.mem.Alignment,
    context: []const u8,
    ca: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Runtime.AnyFuture {
    const rt: *Fibers = @alignCast(@ptrCast(ctx.?));

    var task = rt.allocator.create(Fibers.AsyncTask) catch unreachable;

    task.result_slice = if (result.len == 0)
        &[_]u8{}
    else
        (rt.allocator.rawAlloc(result.len, ra, @returnAddress()) orelse unreachable)[0..result.len];

    task.context_buf = if (context.len == 0)
        &[_]u8{}
    else
        (rt.allocator.rawAlloc(context.len, ca, @returnAddress()) orelse unreachable)[0..context.len];

    @memcpy(task.context_buf, context);

    task.waiter = null;
    task.start = start;

    task.context_alignment = ca;

    task.fiber.init(rt.allocator, 1024 * 1024, AsyncTask.call, @ptrCast(task)) catch unreachable;

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

    // If task hasnt finished yet, we block until its done
    if (task.fiber.state != .finished) {
        const me = Fiber.current().?;
        task.waiter = me;
        me.block();
    }

    // when resumed, result has been written in-place:
    @memcpy(result, task.result_slice);

    // Only now can we free the task.
    task.deinit(rt.allocator, ra);
    rt.allocator.destroy(task);
}

/// asyncDetached: fire‑and‑forget on a real thread
fn asyncDetached(
    ctx: ?*anyopaque,
    context: []const u8,
    ca: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx));

    const context_buf: []u8 = if (context.len == 0)
        &[_]u8{}
    else
        (rt.allocator.rawAlloc(context.len, ca, @returnAddress()) orelse unreachable)[0..context.len];

    @memcpy(context_buf, context);

    var fiber: *Fiber = rt.allocator.create(Fiber) catch unreachable;
    fiber.init(rt.allocator, 1024 * 1024, start, @ptrCast(context_buf.ptr)) catch unreachable;

    rt.schedule(fiber);
}

/// simply set ourselves to blocking, we wont unblock until we get woken up
fn @"suspend"(ctx: ?*anyopaque) Cancelable!void {
    _ = ctx;
    const me = Fiber.current().?;
    me.block();

    if (me.isCanceled()) {
        return error.Canceled;
    }
}

fn cancel(ctx: ?*anyopaque, any_future: *Runtime.AnyFuture, result: []u8, ra: std.mem.Alignment) void {
    const rt: *Fibers = @alignCast(@ptrCast(ctx.?));

    const task: *AsyncTask = @alignCast(@ptrCast(any_future));

    if (task.fiber.state != .finished) {
        // set fiber to canceled
        task.fiber.cancel();
        task.fiber.wake();

        const me = Fiber.current().?;
        task.waiter = me;

        me.block();
    }
    // when resumed, result has been written in-place:
    @memcpy(result, task.result_slice);

    // Only now can we free the task.
    task.deinit(rt.allocator, ra);
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
        t.waiter = me;
        i += 1;
    }
    me.block();

    i = 0;
    for (futures) |afut| {
        const t: *AsyncTask = @alignCast(@ptrCast(afut));

        if (t.fiber.state == .finished) {
            return i;
        }
        i += 1;
    }
    unreachable;
}

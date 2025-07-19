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
}

pub fn join(self: *Fibers) void {
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

noinline fn schedule(rt: *Fibers, fiber: *Fiber) void {
    rt.free_threads.mutex.lock();
    const maybe_thread: ?*Thread = rt.free_threads.list.pop();
    rt.free_threads.mutex.unlock();

    if (maybe_thread) |thread| {
        fiber.running.store(true, .release);
        thread.push(fiber);

        rt.io.vtable.wakeThread(rt.io.ctx, rt.runtime(), @ptrCast(thread.io_ctx));
    } else {
        fiber.running.store(true, .release);

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
    entry: *const fn (arg: *anyopaque) void,
    arg: *anyopaque,

    // Use atomics for these, shared across threads
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
    }

    fn cancel(self: *Fiber) void {
        self.canceled.store(true, .release);
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
                t.rt.io.vtable.exitThread(t.rt.io.ctx, t.rt.runtime(), thread.io_ctx);
            }
            t.rt.threads_to_exit.list.clearAndFree();
            t.rt.threads_to_exit.mutex.unlock();
        }

        t.yeild(&fib.ctx, t.pop());
    }

    pub fn deinit(self: *Fiber, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
    }

    pub fn block() bool {
        const fiber = Thread.current().current_fiber.?;
        if (fiber.canceled.load(.acquire)) {
            return true;
        }

        const t = Thread.current();
        t.yeild(&fiber.ctx, t.pop());

        return fiber.canceled.load(.acquire);
    }

    pub fn wake(fiber: *Fiber) void {
        if (fiber.running.load(.acquire)) {
            log.info("fiber already running", .{});
            return;
        }

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
        fib.running.store(true, .release);
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
            fib.running.store(false, .release);
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

        log.info("finished thread", .{});

        //rt.allocator.rawFree(context_buf, ca, @returnAddress());
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
    result_slice: []u8,
    context_buf: []u8,
    context_alignment: std.mem.Alignment,

    // Pointer to fiber, 0 if not awaited, 1 if finished
    waiter: std.atomic.Value(usize) = .init(0),
    canceled: std.atomic.Value(bool) = .init(false),

    fn call(arg: *anyopaque) void {
        const task: *AsyncTask = @alignCast(@ptrCast(arg));
        task.start(@ptrCast(task.context_buf.ptr), @ptrCast(task.result_slice.ptr));

        if (task.finish()) |w| {
            w.wake();
        }
    }

    // set waiter to 1 (finished)
    fn finish(self: *AsyncTask) ?*Fiber {
        switch (self.waiter.swap(1, .acq_rel)) {
            0 | 1 => return null,
            else => |waiter| return @ptrFromInt(waiter),
        }
    }

    // returns true if finished
    fn setWaiter(self: *AsyncTask, waiter: *Fiber) bool {
        const last_waiter = self.waiter.swap(@intFromPtr(waiter), .acq_rel);
        return last_waiter == 1;
    }

    fn isFinished(self: *AsyncTask) bool {
        return self.waiter.load(.acquire) == 1;
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

    task.waiter.store(0, .release);
    task.start = start;

    task.context_alignment = ca;

    task.fiber.init(rt.allocator, 1024 * 1024, AsyncTask.call, @ptrCast(task)) catch unreachable;

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

    const me = Fiber.current().?;
    // If task hasnt finished yet, we block until its done
    if (!task.setWaiter(me)) {
        log.info("blocking", .{});
        if (Fiber.block()) {
            task.fiber.cancel();
        }
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
    const rt: *Fibers = @alignCast(@ptrCast(ctx.?));

    const task: *AsyncTask = @alignCast(@ptrCast(any_future));

    const me = Fiber.current().?;
    if (!task.setWaiter(me)) {
        task.fiber.cancel();
        task.fiber.wake();

        _ = Fiber.block();
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

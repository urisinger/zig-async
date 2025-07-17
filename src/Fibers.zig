const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("Runtime.zig");
const Io = @import("Io.zig");

const log = std.log.scoped(.Fibers);
const assert = std.debug.assert;

const Fibers = @This();

allocator: std.mem.Allocator,

threads: struct {
    mutex: std.Thread.Mutex,
    list: []std.Thread,
},

io: Io,
const vtable: Runtime.VTable = .{
    .@"async" = @"async",
    .asyncDetached = asyncDetached,
    .@"await" = @"await",
    .@"suspend" = @"suspend",
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
            .list = &[_]std.Thread{},
        },

        .io = io,
    };
}

pub fn deinit(self: *Fibers) void {
    self.threads.mutex.lock();
    self.allocator.free(self.threads.list);
    self.threads.mutex.unlock();
}

pub fn join(self: *Fibers) void {
    self.threads.mutex.lock();
    const threads_copy = self.allocator.dupe(std.Thread, self.threads.list) catch unreachable;
    self.threads.mutex.unlock();

    for (threads_copy) |thread| {
        thread.join();
    }

    self.allocator.free(threads_copy);
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
        rbx: u64 = 0,
        r12: u64 = 0,
        r13: u64 = 0,
        r14: u64 = 0,
        r15: u64 = 0,

        fn init(entry_rip: usize, stack: usize) @This() {
            return .{
                .rsp = stack - 8,
                .rbp = 0,
                .rip = entry_rip,
                .rbx = 0,
                .r12 = 0,
                .r13 = 0,
                .r14 = 0,
                .r15 = 0,
            };
        }
    },
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
};
const CallingConvention = std.builtin.CallingConvention;

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
            \\ movq %%rbx, 24(%%rax)
            \\ movq %%r12, 32(%%rax)
            \\ movq %%r13, 40(%%rax)
            \\ movq %%r14, 48(%%rax)
            \\ movq %%r15, 56(%%rax)

            // Restore new context
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ movq 24(%%rcx), %%rbx
            \\ movq 32(%%rcx), %%r12
            \\ movq 40(%%rcx), %%r13
            \\ movq 48(%%rcx), %%r14
            \\ movq 56(%%rcx), %%r15
            \\ jmpq *16(%%rcx) // jump to RIP
            \\ ret:
            :
            : [old] "{rax}" (old_ctx),
              [new] "{rcx}" (new_ctx),
            : "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "memory"
        ),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    }
}

/// A single fiber, with its own stack and saved context.
const Fiber = struct {
    ctx: Context,
    stack: []usize,
    entry: *const fn (arg: *anyopaque) void,
    arg: *anyopaque,

    // A fiber forms a circular queue
    next_fiber: *Fiber,
    prev_fiber: *Fiber,

    /// Initialize a Fiber: alloc a stack, set up a context that will
    pub fn init(
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
        self.ctx = .init(@intFromPtr(&fiberTrampoline), top);

        self.next_fiber = self;
        self.prev_fiber = self;
    }

    pub fn deinit(self: *Fiber, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
    }

    pub fn block(fiber: *Fiber) void {
        // Remove ourselves from the running queue
        const t = Thread.current();

        const new_head = fiber.remove();

        // only update the head if we are currently running
        if (t.running_queue == fiber) {
            t.running_queue = new_head;
        }

        t.yeild(&fiber.ctx);
    }

    pub fn wake(fiber: *Fiber) void {
        // Remove ourselves from the blocking queue
        const t = Thread.current();

        t.insertFiber(fiber);
    }

    pub fn current() ?*Fiber {
        return Thread.current().running_queue;
    }

    // Reuse a fiber, set a new entry point and create a new context.
    pub fn recycle(fiber: *Fiber, entry: *const fn (*anyopaque) void, arg: *anyopaque) void {
        fiber.entry = entry;
        fiber.arg = arg;

        const stack = fiber.buf;
        const top = @intFromPtr(stack[stack.len..].ptr);
        fiber.ctx.* = .init(@intFromPtr(fiberTrampoline), top);
        fiber.next_fiber = fiber;
        fiber.prev_fiber = fiber;
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

fn fiberTrampoline() callconv(.C) void {
    const t = Thread.current();
    const fib = t.running_queue.?;
    fib.entry(fib.arg);

    // Remove us from the running queue
    t.running_queue = fib.remove();

    contextSwitch(&fib.ctx, t.currentContext());
}

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

    fn entry(rt: *Fibers, context_buf: []u8, ca: std.mem.Alignment, start: *const fn (context: *const anyopaque) void) void {
        var main_fiber: Fiber = undefined;
        main_fiber.init(rt.allocator, 1024 * 1024, start, @ptrCast(context_buf.ptr)) catch unreachable;

        var t: Thread = .{
            .rt = rt,
            .running_queue = &main_fiber,
            .idle_context = .{},
            .io_ctx = rt.io.vtable.createContext(rt.io.ctx),
        };
        self = &t;

        while (t.running_queue) |fiber| {
            const old_ctx = &self.idle_context;
            const new_ctx = &fiber.ctx;

            contextSwitch(old_ctx, new_ctx);

            rt.io.vtable.onPark(rt.io.ctx, rt.runtime());
        }

        rt.allocator.rawFree(context_buf, ca, @returnAddress());
        main_fiber.deinit(rt.allocator);
    }
};

fn wake(ctx: ?*anyopaque, waker: *anyopaque) void {
    _ = ctx;
    const fiber: *Fiber = @alignCast(@ptrCast(waker));

    fiber.wake();
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

    finished: bool = false,

    fn call(arg: *anyopaque) void {
        const task: *AsyncTask = @alignCast(@ptrCast(arg));
        task.start(@ptrCast(task.context_buf.ptr), @ptrCast(task.result_slice.ptr));

        if (task.waiter) |w| {
            w.wake();
        }
        task.waiter = null;
        task.finished = true;
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

    var fiber: Fiber = undefined;
    fiber.init(rt.allocator, 1024 * 1024, AsyncTask.call, @ptrCast(task)) catch unreachable;
    task.fiber = fiber;
    task.context_alignment = ca;

    task.finished = false;

    const t = Thread.current();
    t.insertFiber(&task.fiber);

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
    if (!task.finished) {
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

/// —————————————————————————————————————————————————————————————————————
/// asyncDetached: fire‑and‑forget on a real thread
/// —————————————————————————————————————————————————————————————————————
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

    const thread = std.Thread.spawn(.{}, Thread.entry, .{
        rt,
        context_buf,
        ca,
        start,
    }) catch unreachable;
    rt.threads.mutex.lock();
    const thread_id = rt.threads.list.len;
    if (rt.threads.list.len != 0) {
        rt.threads.list = rt.allocator.realloc(rt.threads.list, rt.threads.list.len + 1) catch unreachable;
    } else {
        rt.threads.list = rt.allocator.alloc(std.Thread, 1) catch unreachable;
    }
    rt.threads.list[thread_id] = thread;
    rt.threads.mutex.unlock();
}

/// —————————————————————————————————————————————————————————————————————
/// suspend: simply set ourselves to blocking, we wont unblock until we get woken up
/// —————————————————————————————————————————————————————————————————————
fn @"suspend"(ctx: ?*anyopaque) void {
    _ = ctx;
    const me = Fiber.current().?;
    me.block();
}

/// —————————————————————————————————————————————————————————————————————
/// select: wait on multiple futures
/// —————————————————————————————————————————————————————————————————————
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
    // find the one that completed
    for (futures) |afut| {
        const t: *AsyncTask = @alignCast(@ptrCast(afut));

        if (t.finished) {
            return i;
        }
        i += 1;
    }
    unreachable;
}

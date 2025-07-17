const std = @import("std");
const builtin = @import("builtin");
const Exec = @import("Exec.zig");

const assert = std.debug.assert;

const EventLoop = @This();

pub const Io = struct {
    ctx: ?*anyopaque,

    // This function gets called when an execution thread blocks.
    onPark: *const fn (ctx: ?*anyopaque, wake: *const fn (fut: *Exec.AnyFuture) void) void,
};

allocator: std.mem.Allocator,

free_fibers: struct {
    mutex: std.Thread.Mutex,
    list: ?*Fiber,
},

io: Io,

const vtable: Exec.VTable = .{
    .@"async" = asyncImpl,
    .asyncDetached = asyncDetachedImpl,
    .@"await" = awaitImpl,
    .@"suspend" = suspendImpl,
    .select = selectImpl,
};

pub fn init(allocator: std.mem.Allocator, io: Io) EventLoop {
    return .{
        .allocator = allocator,

        .free_fibers = .{
            .mutex = .{},
            .list = null,
        },

        .io = io,
    };
}

pub fn exec(self: *EventLoop) Exec {
    return .{
        .vtable = &vtable,
        .ctx = @ptrCast(self),
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
        allocator: std.mem.Allocator,
        stack_size: usize,
        entry: *const fn (*anyopaque) void,
        arg: *anyopaque,
    ) !*Fiber {
        const stack = try allocator.alloc(usize, @divExact(stack_size, @sizeOf(usize)));
        var f = try allocator.create(Fiber);
        f.stack = stack;
        f.entry = entry;
        f.arg = arg;

        const top = @intFromPtr(stack.ptr) + stack.len * @sizeOf(usize);
        f.ctx = .init(@intFromPtr(&fiberTrampoline), top);

        f.next_fiber = f;
        f.prev_fiber = f;
        return f;
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
        std.log.debug("finished block", .{});
    }

    pub fn wake(fiber: *Fiber) void {
        // Remove ourselves from the blocking queue
        const t = Thread.current();

        std.log.debug("waking up fiber", .{});
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

        std.log.info("added fiber", .{});
        self.print();
    }

    pub fn insertBefore(self: *Fiber, new_fiber: *Fiber) void {
        const prev = self.prev_fiber;

        new_fiber.next_fiber = self;
        new_fiber.prev_fiber = prev;

        prev.next_fiber = new_fiber;
        self.prev_fiber = new_fiber;

        std.log.info("added fiber before current", .{});
        self.print();
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

        std.log.info("removed fiber", .{});
        self.next_fiber.print();
        return self.next_fiber;
    }

    fn print(self: *Fiber) void {
        var cur = self;
        while (true) {
            std.log.info("fiber: rip=0x{x}, rsp=0x{x}", .{ cur.ctx.rip, cur.ctx.rsp });
            cur = cur.next_fiber;

            if (cur == self)
                break;
        }
    }
};

fn fiberTrampoline() callconv(.C) void {
    const t = Thread.current();
    const fib = t.running_queue.?;
    fib.entry(fib.arg);

    std.log.info("finished fiber", .{});
    // Remove us from the running queue
    t.running_queue = fib.remove();

    if (t.running_queue) |running_queue| {
        running_queue.print();
    }

    contextSwitch(&fib.ctx, t.currentContext());
}

// For now a thread is basiclly a detached fiber, later on we can make it steal work from other threads
const Thread = struct {
    thread: std.Thread,
    el: *EventLoop,
    running_queue: ?*Fiber,

    idle_context: Context,

    threadlocal var self: *Thread = undefined;

    fn current() *Thread {
        return self;
    }

    fn insertFiber(t: *Thread, fib: *Fiber) void {
        if (t.running_queue) |running_queue| {
            running_queue.insert(fib);
        } else {
            t.running_queue = fib;
        }
    }

    fn currentContext(t: *Thread) *Context {
        if (t.running_queue) |fib| {
            return &fib.ctx;
        } else {
            std.log.info("idle thread", .{});
            return &t.idle_context;
        }
    }

    // Allows the next fiber to run
    fn yeild(t: *Thread, old_ctx: *Context) void {
        if (t.running_queue) |fiber| {
            const new_ctx = &fiber.next_fiber.ctx;

            t.running_queue = fiber.next_fiber;

            contextSwitch(old_ctx, new_ctx);

            std.log.info("end", .{});
        } else {
            // No tasks to run, we go to idle loop
            const new_ctx = &t.idle_context;
            contextSwitch(old_ctx, new_ctx);
        }
    }

    fn entry(t: *Thread) void {
        self = t;
        const el = t.el;

        while (t.running_queue) |fiber| {
            const old_ctx = &self.idle_context;
            const new_ctx = &fiber.ctx;

            contextSwitch(old_ctx, new_ctx);

            el.io.onPark(el.io.ctx, wakeFut);
        }
    }
};

fn wakeFut(fut: *Exec.AnyFuture) void {
    const task: *AsyncTask = @alignCast(@ptrCast(fut));

    task.fiber.wake();
}

const AsyncTask = struct {
    fiber: *Fiber,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    result_slice: []u8,
    context_buf: []u8,
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

        std.log.info("finished task", .{});
    }
};

/// —————————————————————————————————————————————————————————————————————
/// async: spawn a fiber on the main thread
/// —————————————————————————————————————————————————————————————————————
fn asyncImpl(
    ctx: ?*anyopaque,
    result: []u8,
    ra: std.mem.Alignment,
    context: []const u8,
    ca: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Exec.AnyFuture {
    const el: *EventLoop = @alignCast(@ptrCast(ctx.?));

    var task = el.allocator.create(EventLoop.AsyncTask) catch unreachable;

    task.result_slice = if (result.len == 0)
        &[_]u8{}
    else
        (el.allocator.rawAlloc(result.len, ra, 0) orelse unreachable)[0..result.len];

    task.context_buf = if (context.len == 0)
        &[_]u8{}
    else
        (el.allocator.rawAlloc(context.len, ca, 0) orelse unreachable)[0..context.len];

    @memcpy(task.context_buf, context);

    task.waiter = null;
    task.start = start;

    task.fiber = Fiber.init(el.allocator, 1024 * 1024, AsyncTask.call, @ptrCast(task)) catch unreachable;
    task.finished = false;

    const t = Thread.current();
    t.insertFiber(task.fiber);

    return @ptrCast(task);
}

/// —————————————————————————————————————————————————————————————————————
/// await: park current fiber until its task completes
/// —————————————————————————————————————————————————————————————————————
fn awaitImpl(
    ctx: ?*anyopaque,
    any_future: *Exec.AnyFuture,
    result: []u8,
    ra: std.mem.Alignment,
) void {
    _ = ra;
    const ev: *EventLoop = @alignCast(@ptrCast(ctx.?));
    const task: *AsyncTask = @alignCast(@ptrCast(any_future));
    
    // If task hasnt finished yet, we block until its done
    if (!task.finished){
        const me = Fiber.current().?;
        task.waiter = me;
        me.block();
    }


    // when resumed, result has been written in-place:
    @memcpy(result, task.result_slice);

    // Only now can we free the fiber.
    ev.free_fibers.mutex.lock();
    {
        if (ev.free_fibers.list) |free_fibers| {
            free_fibers.insert(task.fiber);
        } else {
            ev.free_fibers.list = task.fiber;
        }
    }
    ev.free_fibers.mutex.unlock();

    ev.allocator.destroy(task);
}

const DetachedTask = struct {
    fiber: *Fiber,
    start: *const fn (context: *const anyopaque) void,
    context_buf: []u8,

    fn call(arg: *anyopaque) void {
        const task: *DetachedTask = @alignCast(@ptrCast(arg));

        task.start(@ptrCast(task.context_buf.ptr));

        task.fiber.block();
    }
};

/// —————————————————————————————————————————————————————————————————————
/// asyncDetached: fire‑and‑forget on a real thread
/// —————————————————————————————————————————————————————————————————————
fn asyncDetachedImpl(
    ctx: ?*anyopaque,
    context: []const u8,
    ca: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    const el: *EventLoop = @alignCast(@ptrCast(ctx));

    var t = el.allocator.create(DetachedTask) catch unreachable;

    if (context.len == 0) {
        t.context_buf = &[_]u8{};
    } else {
        t.context_buf = (el.allocator.rawAlloc(context.len, ca, @returnAddress()) orelse unreachable)[0..context.len];
    }
    @memcpy(t.context_buf, context);

    t.start = start;

    t.fiber = Fiber.init(el.allocator, 1024 * 1024, DetachedTask.call, @ptrCast(t)) catch unreachable;

    const thread: *Thread = el.allocator.create(Thread) catch unreachable;

    thread.el = el;
    thread.running_queue = t.fiber;
    thread.idle_context = .{};

    thread.thread = std.Thread.spawn(.{ .allocator = el.allocator }, Thread.entry, .{thread}) catch unreachable;
}

/// —————————————————————————————————————————————————————————————————————
/// suspend: simply set ourselves to blocking, we wont unblock until we get woken up
/// —————————————————————————————————————————————————————————————————————
fn suspendImpl(ctx: ?*anyopaque) void {
    _ = ctx;
    const me = Fiber.current().?;
    me.block();
}

/// —————————————————————————————————————————————————————————————————————
/// select: wait on multiple futures
/// —————————————————————————————————————————————————————————————————————
fn selectImpl(
    ctx: ?*anyopaque,
    futures: []const *Exec.AnyFuture,
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

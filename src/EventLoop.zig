const std = @import("std");
const builtin = @import("builtin");
const Exec = @import("Exec.zig");

const assert = std.debug.assert;

const EventLoop = @This();

allocator: std.mem.Allocator,

free_fibers: struct {
    mutex: std.Thread.Mutex,
    list: ?*Fiber,
},

io: ?Exec.Io,

const vtable: Exec.VTable = .{
    .@"async" = asyncImpl,
    .asyncDetached = asyncDetachedImpl,
    .@"await" = awaitImpl,
    .@"suspend" = suspendImpl,
    .select = selectImpl,
    .setIo = setIoImpl,
};

pub fn init(allocator: std.mem.Allocator) EventLoop {
    return .{
        .allocator = allocator,

        .free_fibers = .{
            .mutex = .{},
            .list = null,
        },

        .io = null,
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

        fn init(entry_rip: usize, stack: usize) @This() {
            return .{ .rsp = stack, .rbp = 0, .rip = entry_rip };
        }

    },
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
};

fn contextSwitch(old_ctx: *Context, new_ctx: *const Context) callconv(.SysV) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            // Save our current state
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            // Restore old state
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            // Jump to new contex, pass the current fiber in rdi
            \\ jmpq *16(%%rcx)
            \\0:
            :
            : [old] "{rax}" (old_ctx),
              [new] "{rcx}" (new_ctx),
            : "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "rbx", "r11", "r12", "r13", "r14", "r15", "memory"
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
    
    state: State,

    const State = enum { running, blocking, free };

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
        f.state = .running;

        const top = @intFromPtr(stack[stack.len..].ptr);
        f.ctx = .init(@intFromPtr(&fiberTrampoline), top);

        f.next_fiber = f;
        f.prev_fiber = f;
        return f;
    }

    pub fn block(fiber: *Fiber) void{
        if (fiber.state == .blocking){
            @panic("attempt to block blocked fiber");
        }
        fiber.state = .blocking;

        // Remove ourselves from the running queue
        const t = Thread.current();
        
        const new_head = fiber.remove();
        
        // only update the head if we are currently running
        if (t.running_queue == fiber) {
            t.running_queue = new_head;
        }

        t.yeild(&fiber.ctx);
    }

    pub fn wake(fiber: *Fiber) void{
        if (fiber.state == .running){
            @panic("attempt to run already running fiber");
        }
        fiber.state = .running;


        // Remove ourselves from the blocking queue 
        const t = Thread.current();
        
        if (t.running_queue) |running_queue|{
            running_queue.insert(fiber);
        } else{
            t.running_queue = fiber;
        }

    }

    pub fn current() ?*Fiber {
        return Thread.current().running_queue;
    }

    // Reuse a fiber, set a new entry point and create a new context.
    pub fn recycle(fiber: *Fiber, entry: *const fn (*anyopaque) void, arg: *anyopaque) void {
        fiber.entry = entry;
        fiber.arg = arg;

        fiber.state = .running;

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

const fiberTrampoline = switch (builtin.cpu.arch) {
    .x86_64 => fiberTrampolineX86_64,
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
};

fn fiberTrampolineX86_64() void {
    const t = Thread.current();
    const fib = t.running_queue.?;
    fib.entry(fib.arg);

    // Remove us from the running queue
    t.running_queue = fib.remove();

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


    fn currentContext(t: *Thread) *Context{
       if (t.running_queue) |fib| {
            return &fib.ctx;
       } else {
            return &t.idle_context;
       }
    }

    // Allows the next fiber to run
    fn yeild(t: *Thread, old_ctx: *Context) void {
        if (t.running_queue) |fiber|{
            const new_ctx = &fiber.next_fiber.ctx;
            
            t.running_queue = fiber.next_fiber;
            contextSwitch(old_ctx, new_ctx);
        } else{
            // No tasks to run, we go to idle loop
            const new_ctx = &t.idle_context;
            contextSwitch(old_ctx, new_ctx);
        }
    }

    fn entry(t: *Thread) void {
        self = t;
        const el = t.el;

        while (t.running_queue) |fiber|{
            const old_ctx = &self.idle_context;
            const new_ctx = &fiber.ctx;
            
            contextSwitch(old_ctx, new_ctx);

            if (el.io) |io| {
                io.onPark(io.ctx, wakeFut);
            } 
        }
    }
};

fn wakeFut(fut: *Exec.AnyFuture) void {
    const task: *AsyncTask = @alignCast(@ptrCast(fut));

    task.fiber.wake();
}

const AsyncTask = struct {
    fiber: *Fiber,
    start: *const fn(context: *const anyopaque, result: *anyopaque) void,
    result_slice: []u8,
    context_buf: []u8,
    waiter: ?*Fiber,

   fn call(arg: *anyopaque) void {
        const task: *AsyncTask = @alignCast(@ptrCast(arg));
        task.start(@ptrCast(task.context_buf.ptr), @ptrCast(task.result_slice.ptr));

        if (task.waiter) |w| {
            w.state = .running;
        }
        task.waiter = null;
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

    var t = el.allocator.create(EventLoop.AsyncTask) catch unreachable;

    t.result_slice = (el.allocator.rawAlloc(result.len, ra ,@returnAddress()) orelse unreachable)[0..result.len];
    t.context_buf = (el.allocator.rawAlloc(context.len, ca ,@returnAddress()) orelse unreachable)[0..context.len];
    @memcpy(t.context_buf, context);

    t.waiter = null;
    t.start = start;

    t.fiber = Fiber.init(el.allocator, 32 * 1024, AsyncTask.call, @ptrCast(t)) catch unreachable;

    return @ptrCast(t);
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
    // park us:
    const me = Fiber.current().?;
    task.waiter = me;
    me.block();

    // when resumed, result has been written in-place:
    @memcpy(result, task.result_slice);
    
    // Only now can we free the fiber.
    ev.free_fibers.mutex.lock();
    {
        if (ev.free_fibers.list) |free_fibers|{
            free_fibers.insert(task.fiber);
        }else{
            ev.free_fibers.list = task.fiber;
        }
    }
    ev.free_fibers.mutex.unlock();
    task.fiber.state = .free;

    ev.allocator.free(task.context_buf);
    ev.allocator.destroy(task);
}

const DetachedTask = struct {
    fiber: *Fiber,
    start: *const fn(context: *const anyopaque) void,
    context_buf: []u8,

   fn call(arg: *anyopaque) void {
        const task: *DetachedTask = @alignCast(@ptrCast(arg));
        task.start(@ptrCast(task.context_buf.ptr));
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

    if (context.len == 0){
        t.context_buf = &[_]u8{};
    } else{
        t.context_buf = (el.allocator.rawAlloc(context.len, ca ,@returnAddress()) orelse unreachable )[0..context.len];
    }
    @memcpy(t.context_buf, context);

    t.start = start;

    t.fiber = Fiber.init(el.allocator, 32 * 1024, DetachedTask.call, @ptrCast(t)) catch unreachable;

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
    for (futures) |afut| {
        const t: *AsyncTask = @alignCast(@ptrCast(afut));
        t.waiter = me;
    }
    me.block();

    // find the one that completed
    var i: usize = 0; 
    for (futures) |afut| {
        const t: *AsyncTask = @alignCast(@ptrCast(afut));
        if (t.waiter == null){
            return i;
        }
        i += 1;
    }
    unreachable;
}

/// —————————————————————————————————————————————————————————————————————
/// setIo: allow user to install an Io.onPark if desired
/// —————————————————————————————————————————————————————————————————————
fn setIoImpl(ctx: ?*anyopaque, io: Exec.Io) void {
    const self: *EventLoop = @alignCast(@ptrCast(ctx.?));
    self.io = io;
}

const std = @import("std");
const log = std.log.scoped(.EventLoop);

const Runtime = @import("../../Runtime.zig");
const Reactor = @import("../../Reactor.zig");
const fs = @import("./fs.zig");
const net = @import("./net.zig");

const IoUring = std.os.linux.IoUring;
const Allocator = std.mem.Allocator;

const EventLoop = @This();

const io_uring_entries = 64;

allocator: Allocator,

pub const ThreadContext = struct {
    event_loop: *EventLoop,
    io_uring: IoUring,
    ops_buffer: std.heap.MemoryPool(Operation),

    sqe_overflow: std.fifo.LinearFifo(std.os.linux.io_uring_sqe, .Dynamic),

    wake_fd: std.os.linux.fd_t,

    pub fn init(event_loop: *EventLoop) ThreadContext {
        const wake_fd = std.os.linux.eventfd(0, 0);
        return .{
            .io_uring = IoUring.init(io_uring_entries, 0) catch unreachable,
            .event_loop = event_loop,
            .wake_fd = @intCast(wake_fd),
            .ops_buffer = std.heap.MemoryPool(Operation).init(event_loop.allocator),
            .sqe_overflow = std.fifo.LinearFifo(std.os.linux.io_uring_sqe, .Dynamic).init(event_loop.allocator),
        };
    }

    pub fn deinit(self: *ThreadContext) void {
        self.io_uring.deinit();
        self.ops_buffer.deinit();
        self.sqe_overflow.deinit();
    }

    pub fn getSqe(self: *ThreadContext) !*std.os.linux.io_uring_sqe {
        return self.io_uring.get_sqe() catch {
            try self.sqe_overflow.ensureUnusedCapacity(1);

            var tail = self.sqe_overflow.count;
            tail &= self.sqe_overflow.buf.len - 1;

            self.sqe_overflow.update(1);
            return &self.sqe_overflow.buf[tail];
        };
    }

    pub fn getOp(self: *ThreadContext) !*Operation {
        return self.ops_buffer.create();
    }

    pub fn destroyOp(self: *ThreadContext, op: *Operation) void {
        self.ops_buffer.destroy(op);
    }
};

pub fn createContext(global_ctx: ?*anyopaque) ?*anyopaque {
    const event_loop: *EventLoop = @alignCast(@ptrCast(global_ctx));

    const thread_ctx = event_loop.allocator.create(ThreadContext) catch unreachable;
    thread_ctx.* = ThreadContext.init(event_loop);

    return @ptrCast(thread_ctx);
}

pub fn destroyContext(global_ctx: ?*anyopaque, context: ?*anyopaque) void {
    const event_loop: *EventLoop = @alignCast(@ptrCast(global_ctx));
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(context));
    thread_ctx.deinit();
    event_loop.allocator.destroy(thread_ctx);
}

pub fn init(allocator: Allocator) EventLoop {
    return .{
        .allocator = allocator,
    };
}

// File operation structures for async operations
pub const Operation = struct {
    waker: ?*anyopaque,
    result: i32,
    has_result: bool = false,
};

const vtable: Reactor.VTable = .{
    .createContext = createContext,
    .destroyContext = destroyContext,
    .onPark = onPark,
    .openFile = fs.openFile,
    .closeFile = fs.closeFile,
    .pread = fs.pread,
    .awaitRead = fs.awaitRead,
    .pwrite = fs.pwrite,
    .awaitWrite = fs.awaitWrite,
    .wakeThread = wakeThread,
    .sleep = sleep,
    .createSocket = net.createSocket,
    .awaitCreateSocket = net.awaitCreateSocket,
    .closeSocket = net.closeSocket,
    .bind = net.bind,
    .listen = net.listen,
    .connect = net.connect,
    .awaitConnect = net.awaitConnect,
    .accept = net.accept,
    .awaitAccept = net.awaitAccept,
    .send = net.send,
    .awaitSend = net.awaitSend,
    .recv = net.recv,
    .awaitRecv = net.awaitRecv,
};

pub fn reactor(el: *EventLoop) Reactor {
    return .{
        .ctx = el,
        .vtable = &vtable,
    };
}

fn sleep(ctx: ?*anyopaque, exec: Reactor.Executer, ms: u64) void {
    _ = ctx;

    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    // Get SQE and operation from ring buffer
    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };
    const op = thread_ctx.getOp() catch {
        @panic("failed to get op");
    };

    op.* = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
    };

    var ts: std.os.linux.kernel_timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1000000),
    };
    sqe.prep_timeout(&ts, 0, 0);
    sqe.user_data = @intFromPtr(op);

    while (true) {
        exec.@"suspend"();
        if (op.has_result) {
            switch (errno(op.result)) {
                .SUCCESS => {
                    op.has_result = false;
                },
                .TIME => {
                    break;
                },
                else => |err| {
                    log.err("sleep failed: {any}", .{err});
                    unreachable;
                },
            }
        }
    }
    thread_ctx.destroyOp(op);
}

fn wakeThread(global_ctx: ?*anyopaque, cur_thread_ctx: ?*anyopaque, other_thread_ctx: ?*anyopaque) void {
    _ = global_ctx;
    if (cur_thread_ctx) |thread| {
        const cur_thread: *ThreadContext = @alignCast(@ptrCast(thread));
        const other_thread: *ThreadContext = @alignCast(@ptrCast(other_thread_ctx));

        const sqe = cur_thread.getSqe() catch {
            @panic("failed to get sqe");
        };
        const op = cur_thread.getOp() catch {
            @panic("failed to get op");
        };

        op.* = .{ .waker = null, .result = 0, .has_result = true };

        sqe.prep_rw(
            .MSG_RING,
            other_thread.io_uring.fd,
            0,
            0,
            0,
        );
        sqe.user_data = @intFromPtr(op);
    } else {
        const other_thread: *ThreadContext = @alignCast(@ptrCast(other_thread_ctx));

        const number: u64 = 1;
        const buffer: [8]u8 = @bitCast(number);

        _ = std.os.linux.write(other_thread.wake_fd, &buffer, buffer.len);
    }
}

fn onPark(global_ctx: ?*anyopaque, exec: Reactor.Executer) void {
    while (true) {
        const event_loop: *EventLoop = @alignCast(@ptrCast(global_ctx));
        _ = event_loop;
        const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

        const io_uring = &thread_ctx.io_uring;

        var wake_buffer: [8]u8 = undefined;

        if (thread_ctx.io_uring.get_sqe() catch null) |sqe| {
            sqe.prep_read(thread_ctx.wake_fd, &wake_buffer, 0);
            sqe.user_data = 0;
        }

        // We flush our dynamic submission queue to the static one.
        while (thread_ctx.sqe_overflow.count > 0) {
            const free_sqe = io_uring.get_sqe() catch {
                break;
            };
            free_sqe.* = thread_ctx.sqe_overflow.readItem().?;
        }

        // Submit pending operations and wait for at least one completion
        _ = thread_ctx.io_uring.submit() catch unreachable;

        // Wait for completion events
        var cqes: [io_uring_entries]std.os.linux.io_uring_cqe = undefined;
        const completed = while (true) {
            break io_uring.copy_cqes(&cqes, 1) catch {
                continue;
            };
        };

        var should_wake: bool = false;
        // Process completed operations
        for (cqes[0..completed]) |cqe| {
            if (cqe.user_data == 0) {
                should_wake = true;
                continue;
            }

            // user_data points to an Operation in the buffer
            const op: *Operation = @ptrFromInt(cqe.user_data);
            if (op.has_result) {
                thread_ctx.destroyOp(op);
                continue;
            }

            // Set the result based on the completion event
            op.result = cqe.res;
            op.has_result = true;
            should_wake = true;

            // Wake up the suspended future if there's a waker
            if (op.waker) |waker| {
                exec.wake(waker);
            }
        }

        if (should_wake) {
            break;
        }
    }
}

pub fn errno(signed: i32) std.os.linux.E {
    return std.posix.errno(@as(isize, signed));
}

const std = @import("std");
const Runtime = @import("../Runtime.zig");
const Reactor = @import("../Reactor.zig");
const types = @import("../utils/types.zig");
const EitherPtr = types.EitherPtr;

const log = std.log.scoped(.EventLoop);

const IoUring = std.os.linux.IoUring;
const Allocator = std.mem.Allocator;

const EventLoop = @This();

const io_uring_entries = 64;

allocator: Allocator,

const ThreadContext = struct {
    event_loop: *EventLoop,
    io_uring: IoUring,

    wake_fd: std.os.linux.fd_t,

    pub fn init(event_loop: *EventLoop) ThreadContext {
        const wake_fd = std.os.linux.eventfd(0, 0);
        std.log.info("init thread context, wake_fd: {d}", .{wake_fd});
        return .{
            .io_uring = IoUring.init(io_uring_entries, 0) catch unreachable,
            .event_loop = event_loop,
            .wake_fd = @intCast(wake_fd),
        };
    }

    pub fn deinit(self: *ThreadContext) void {
        self.io_uring.deinit();
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
const Operation = struct {
    waker: *anyopaque,
    result: i32,
    has_result: bool = false,
};

// Either a pointer to an operation,
const Message = EitherPtr(*Operation, MessageEvent);

const MessageEvent = enum(u2) {
    Wake,
    Noop,
};

const vtable: Reactor.VTable = .{
    .createContext = createContext,
    .destroyContext = destroyContext,
    .onPark = onPark,
    .openFile = openFile,
    .closeFile = closeFile,
    .pread = pread,
    .pwrite = pwrite,
    .wakeThread = wakeThread,
    .sleep = sleep,
};

pub fn reactor(el: *EventLoop) Reactor {
    return .{
        .ctx = el,
        .vtable = &vtable,
    };
}

// Open file asynchronously
pub fn openFile(ctx: ?*anyopaque, exec: Reactor.Executer, path: []const u8, flags: Runtime.File.OpenFlags) Runtime.File.OpenError!Runtime.File {
    _ = ctx;
    _ = exec;
    var os_flags: std.posix.O = .{
        .ACCMODE = switch (flags.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
    };

    if (@hasField(std.posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) os_flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) os_flags.NOCTTY = !flags.allow_ctty;

    const fd = try std.posix.open(path, os_flags, 0);

    return .{
        .handle = fd,
    };
}

// Async file read
pub fn pread(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File, buffer: []u8, offset: std.posix.off_t) Runtime.File.PReadError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    // Create read operation
    var read_op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
    };

    const message = Message.initPtr(&read_op);

    // Submit read operation to io_uring
    const sqe = thread_ctx.io_uring.get_sqe() catch {
        return error.SystemResources;
    };

    sqe.prep_read(file.handle, buffer, @bitCast(offset));
    sqe.user_data = message.toInner();

    while (!read_op.has_result) {
        exec.@"suspend"();
    }

    switch (errno(read_op.result)) {
        .SUCCESS => return @as(u32, @bitCast(read_op.result)),
        .INTR => unreachable,
        .CANCELED => return error.Canceled,

        .INVAL => unreachable,
        .FAULT => unreachable,
        .NOENT => return error.ProcessNotFound,
        .AGAIN => return error.WouldBlock,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

// Async file write
pub fn pwrite(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File, buffer: []const u8, offset: std.posix.off_t) Runtime.File.PWriteError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    var write_op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
    };

    const message = Message.initPtr(&write_op);

    // Submit write operation to io_uring
    const sqe = thread_ctx.io_uring.get_sqe() catch {
        return error.SystemResources;
    };
    sqe.prep_write(file.handle, buffer, @bitCast(offset));
    sqe.user_data = message.toInner();

    // Suspend until the operation completes
    while (!write_op.has_result) {
        exec.@"suspend"();
    }

    switch (errno(write_op.result)) {
        .SUCCESS => return @as(u32, @bitCast(write_op.result)),
        .INTR => unreachable,
        .INVAL => unreachable,
        .FAULT => unreachable,
        .AGAIN => unreachable,
        .BADF => return error.NotOpenForWriting, // can be a race condition.
        .DESTADDRREQ => unreachable, // `connect` was never called.
        .DQUOT => return error.DiskQuota,
        .FBIG => return error.FileTooBig,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .PERM => return error.AccessDenied,
        .PIPE => return error.BrokenPipe,
        .NXIO => return error.Unseekable,
        .SPIPE => return error.Unseekable,
        .OVERFLOW => return error.Unseekable,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

// Close file
pub fn closeFile(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File) void {
    _ = ctx;
    _ = exec;
    std.posix.close(file.handle);
}

fn sleep(ctx: ?*anyopaque, exec: Reactor.Executer, ms: u64) void {
    _ = ctx;

    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    const timeout_sqe = thread_ctx.io_uring.get_sqe() catch {
        @panic("failed to get sqe");
    };

    var timeout_op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
    };
    const timeout_message = Message.initPtr(&timeout_op);
    var ts: std.os.linux.kernel_timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1000000),
    };
    timeout_sqe.prep_timeout(&ts, 1, 0);
    timeout_sqe.user_data = timeout_message.toInner();

    while (!timeout_op.has_result) {
        log.info("sleeping", .{});
        exec.@"suspend"();
        switch (errno(timeout_op.result)) {
            .SUCCESS => {},
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

fn wakeThread(global_ctx: ?*anyopaque, cur_thread_ctx: ?*anyopaque, other_thread_ctx: ?*anyopaque) void {
    _ = global_ctx;
    log.info("wakeThread", .{});
    if (cur_thread_ctx) |thread| {
        const cur_thread: *ThreadContext = @alignCast(@ptrCast(thread));
        const other_thread: *ThreadContext = @alignCast(@ptrCast(other_thread_ctx));

        const sqe = cur_thread.io_uring.get_sqe() catch {
            @panic("failed to get sqe");
        };

        const message = Message.initValue(.Wake);

        sqe.prep_rw(.MSG_RING, other_thread.io_uring.fd, 0, 0, message.toInner());
        sqe.user_data = Message.initValue(.Noop).toInner();
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

        const sqe = thread_ctx.io_uring.get_sqe() catch {
            @panic("failed to get sqe");
        };

        sqe.prep_read(thread_ctx.wake_fd, &wake_buffer, 0);
        sqe.user_data = Message.initValue(.Wake).toInner();

        // Submit pending operations and wait for at least one completion
        _ = thread_ctx.io_uring.submit() catch unreachable;

        // Wait for completion events
        var cqes: [io_uring_entries]std.os.linux.io_uring_cqe = undefined;
        const completed = while (true) {
            break io_uring.copy_cqes(&cqes, 1) catch {
                //log.err("Failed to get completion events {any}", .{err});
                continue;
            };
        };

        var noop_count: u32 = 0;
        // Process completed operations
        for (cqes[0..completed]) |cqe| {
            if (cqe.user_data == 0) {
                log.info("noop: {any}", .{cqe});
                noop_count += 1;
                unreachable;
            }

            const message = Message.fromValue(@as(usize, cqe.user_data));

            switch (message.asUnion()) {
                .value => |event| {
                    switch (event) {
                        .Wake => {
                            continue;
                        },
                        .Noop => {
                            noop_count += 1;
                        },
                    }
                },
                .ptr => |op| {
                    // Set the result based on the completion event
                    op.result = cqe.res;
                    op.has_result = true;
                    // Wake up the suspended future
                    exec.wake(op.waker);
                },
            }
        }

        if (noop_count == completed) {
            log.info("noop_count == completed", .{});
            continue;
        }

        break;
    }
}

fn errno(signed: i32) std.os.linux.E {
    return std.posix.errno(@as(isize, signed));
}

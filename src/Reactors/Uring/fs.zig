const std = @import("std");

const Runtime = @import("../../Runtime.zig");
const Reactor = @import("../../Reactor.zig");

const Uring = @import("./Uring.zig");
const ThreadContext = Uring.ThreadContext;
const Operation = Uring.Operation;
const errno = Uring.errno;

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

pub fn getStdIn(ctx: ?*anyopaque, exec: Reactor.Executer) Runtime.File {
    _ = ctx;
    _ = exec;
    return .{ .handle = std.os.linux.STDIN_FILENO };
}

// Async file read
pub fn pread(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File, buffer: []u8, offset: std.posix.off_t) Runtime.Poller(Runtime.File.PReadError!usize) {
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
        .waker = null,
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_read(file.handle, buffer, @bitCast(offset));
    sqe.user_data = @intFromPtr(op);

    return .{
        .poll = @ptrCast(&pollRead),
        .poller_ctx = @ptrCast(op),
        .result = undefined,
    };
}

pub fn pollRead(poller_ctx: ?*anyopaque) ?Runtime.File.ReadError!usize {
    const sqe_op: *Operation = @alignCast(@ptrCast(poller_ctx));

    if (!sqe_op.has_result) {
        const exec = sqe_op.exec.?;
        sqe_op.waker = exec.getWaker();
        if (exec.isCanceled()) {
            return error.Canceled;
        }
        return null;
    }

    const result = sqe_op.result;
    return switch (errno(result)) {
        .SUCCESS => @as(usize, @intCast(result)),
        .INTR => unreachable,
        .CANCELED => error.Canceled,

        .INVAL => unreachable,
        .FAULT => unreachable,
        .NOENT => error.ProcessNotFound,
        .AGAIN => error.WouldBlock,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

// Async file write
pub fn pwrite(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File, buffer: []const u8, offset: std.posix.off_t) Runtime.Poller(Runtime.File.PWriteError!usize) {
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
        .waker = null,
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_write(file.handle, buffer, @bitCast(offset));
    sqe.user_data = @intFromPtr(op);

    return .{
        .poll = @ptrCast(&pollWrite),
        .poller_ctx = @ptrCast(op),
        .result = undefined,
    };
}

pub fn pollWrite(poller_ctx: ?*anyopaque) ?Runtime.File.PWriteError!usize {
    const sqe_op: *Operation = @alignCast(@ptrCast(poller_ctx));

    // Suspend until the operation completes
    if (!sqe_op.has_result) {
        const exec = sqe_op.exec.?;
        sqe_op.waker = exec.getWaker();
        if (exec.isCanceled()) {
            return error.Canceled;
        }
        return null;
    }

    const result = sqe_op.result;
    return switch (errno(result)) {
        .SUCCESS => @as(u32, @bitCast(result)),
        .INTR => unreachable,
        .INVAL => unreachable,
        .FAULT => unreachable,
        .AGAIN => unreachable,
        .BADF => error.NotOpenForWriting, // can be a race condition.
        .DESTADDRREQ => unreachable, // `connect` was never called.
        .DQUOT => error.DiskQuota,
        .FBIG => error.FileTooBig,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .PERM => error.AccessDenied,
        .PIPE => error.BrokenPipe,
        .NXIO => error.Unseekable,
        .SPIPE => error.Unseekable,
        .OVERFLOW => error.Unseekable,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

// Close file
pub fn closeFile(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File) void {
    _ = ctx;
    _ = exec;
    std.posix.close(file.handle);
}

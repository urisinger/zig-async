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

// Async file read
pub fn pread(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File, buffer: []u8, offset: std.posix.off_t) *Runtime.File.AnyReadHandle {
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
    };

    sqe.prep_read(file.handle, buffer, @bitCast(offset));
    sqe.user_data = @intFromPtr(op);

    return @ptrCast(op);
}

pub fn awaitRead(ctx: ?*anyopaque, exec: Reactor.Executer, handle: *Runtime.File.AnyReadHandle) Runtime.File.ReadError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));
    const sqe_op: *Operation = @alignCast(@ptrCast(handle));
    defer thread_ctx.destroyOp(sqe_op);
    sqe_op.waker = exec.getWaker();

    while (!sqe_op.has_result) {
        exec.@"suspend"();
    }

    switch (errno(sqe_op.result)) {
        .SUCCESS => return @as(u32, @bitCast(sqe_op.result)),
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
pub fn pwrite(ctx: ?*anyopaque, exec: Reactor.Executer, file: Runtime.File, buffer: []const u8, offset: std.posix.off_t) *Runtime.File.AnyWriteHandle {
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
    };

    sqe.prep_write(file.handle, buffer, @bitCast(offset));
    sqe.user_data = @intFromPtr(op);

    return @ptrCast(op);
}

pub fn awaitWrite(ctx: ?*anyopaque, exec: Reactor.Executer, handle: *Runtime.File.AnyWriteHandle) Runtime.File.PWriteError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));
    const sqe_op: *Operation = @alignCast(@ptrCast(handle));
    defer thread_ctx.destroyOp(sqe_op);
    sqe_op.waker = exec.getWaker();

    // Suspend until the operation completes
    while (!sqe_op.has_result) {
        exec.@"suspend"();
    }

    switch (errno(sqe_op.result)) {
        .SUCCESS => return @as(u32, @bitCast(sqe_op.result)),
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

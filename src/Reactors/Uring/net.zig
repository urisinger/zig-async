const std = @import("std");

const root = @import("zig_io");
const Runtime = root.Runtime;
const Reactor = root.Reactor;

const posix = std.posix;

const Uring = @import("./Uring.zig");
const ThreadContext = Uring.ThreadContext;
const Operation = Uring.Operation;
const errno = Uring.errno;

fn createSocketAsync(exec: Reactor.Executer, thread_ctx: *ThreadContext, domain: u32, sock_type: u32, protocol: u32) Runtime.Server.ListenError!posix.socket_t {
    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };

    const op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_socket(domain, sock_type, protocol, 0);
    sqe.user_data = @intFromPtr(&op);

    while (true) {
        if (exec.@"suspend"()) {
            return error.Canceled;
        }
        if (op.has_result) {
            const result = op.result;
            switch (errno(result)) {
                .SUCCESS => return @bitCast(result),
                .ACCES => return error.PermissionDenied,
                .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                .INVAL => return error.ProtocolFamilyNotAvailable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .PROTONOSUPPORT => return error.ProtocolNotSupported,
                .PROTOTYPE => return error.SocketTypeNotSupported,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }
}

pub fn listen(ctx: ?*anyopaque, exec: Reactor.Executer, address: Runtime.net.Address, options: Runtime.net.Server.ListenOptions) Runtime.net.Server.ListenError!Runtime.net.Server {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
    const proto: u32 = if (address.any.family == std.posix.AF.UNIX) 0 else std.posix.IPPROTO.TCP;

    const socket = try createSocketAsync(exec, thread_ctx, address.any.family, sock_flags, proto);
    errdefer std.posix.close(socket);

    if (options.reuse_address) {
        try std.posix.setsockopt(
            socket,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );
        if (@hasDecl(std.posix.SO, "REUSEPORT") and address.any.family != std.posix.AF.UNIX) {
            try std.posix.setsockopt(
                socket,
                std.posix.SOL.SOCKET,
                std.posix.SO.REUSEPORT,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        }
    }

    const socklen = address.getOsSockLen();

    try std.posix.bind(socket, &address.any, socklen);

    try std.posix.listen(socket, options.kernel_backlog);

    return .{ .handle = socket };
}

pub fn accept(ctx: ?*anyopaque, exec: Reactor.Executer, server: Runtime.net.Server) Runtime.net.Server.AcceptError!Runtime.net.Stream {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };

    var op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_accept(server.handle, null, null, 0);
    sqe.user_data = @intFromPtr(&op);

    while (true) {
        if (exec.@"suspend"()) {
            return error.Canceled;
        }

        if (op.has_result) {
            const result = op.result;
            switch (errno(result)) {
                .SUCCESS => return .{ .handle = @bitCast(result) },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF => unreachable, // always a race condition
                .CONNABORTED => return error.ConnectionAborted,
                .FAULT => unreachable,
                .INVAL => return error.SocketNotListening,
                .NOTSOCK => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .OPNOTSUPP => unreachable,
                .PROTO => return error.ProtocolFailure,
                .PERM => return error.BlockedByFirewall,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }
}

pub fn readStream(ctx: ?*anyopaque, exec: Reactor.Executer, stream: Runtime.net.Stream, buffer: []u8) Runtime.net.Stream.ReadError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };

    var op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_read(stream.handle, buffer, 0);
    sqe.user_data = @intFromPtr(&op);

    while (true) {
        if (exec.@"suspend"()) {
            return error.Canceled;
        }
        if (op.has_result) {
            const result = op.result;
            switch (errno(result)) {
                .SUCCESS => return @intCast(result),
                .INTR => continue,
                .INVAL => unreachable,
                .FAULT => unreachable,
                .NOENT => return error.ProcessNotFound,
                .AGAIN => return error.WouldBlock,
                .CANCELED => return error.Canceled,
                .BADF => return error.NotOpenForReading, // Can be a race condition.
                .IO => return error.InputOutput,
                .ISDIR => return error.IsDir,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .NOTCONN => return error.SocketNotConnected,
                .CONNRESET => return error.ConnectionResetByPeer,
                .TIMEDOUT => return error.ConnectionTimedOut,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }
}

pub fn readvStream(ctx: ?*anyopaque, exec: Reactor.Executer, stream: Runtime.net.Stream, iovecs: []const Runtime.net.Stream.iovec) Runtime.net.Stream.ReadError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };

    var op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_readv(stream.handle, iovecs, 0);
    sqe.user_data = @intFromPtr(&op);

    while (true) {
        if (exec.@"suspend"()) {
            return error.Canceled;
        }
        if (op.has_result) {
            const result = op.result;
            switch (errno(result)) {
                .SUCCESS => return @intCast(result),
                .INTR => continue,
                .INVAL => unreachable,
                .FAULT => unreachable,
                .NOENT => return error.ProcessNotFound,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.NotOpenForReading, // can be a race condition
                .IO => return error.InputOutput,
                .ISDIR => return error.IsDir,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .NOTCONN => return error.SocketNotConnected,
                .CONNRESET => return error.ConnectionResetByPeer,
                .TIMEDOUT => return error.ConnectionTimedOut,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }
}

pub fn writeStream(ctx: ?*anyopaque, exec: Reactor.Executer, stream: Runtime.net.Stream, buffer: []const u8) Runtime.net.Stream.WriteError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };

    var op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_write(stream.handle, buffer, 0);
    sqe.user_data = @intFromPtr(&op);

    while (true) {
        if (exec.@"suspend"()) {
            return error.Canceled;
        }

        if (op.has_result) {
            const result = op.result;
            switch (errno(result)) {
                .SUCCESS => return @intCast(result),
                .INTR => continue,
                .INVAL => return error.InvalidArgument,
                .FAULT => unreachable,
                .NOENT => return error.ProcessNotFound,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.NotOpenForWriting, // can be a race condition.
                .DESTADDRREQ => unreachable, // `connect` was never called.
                .DQUOT => return error.DiskQuota,
                .FBIG => return error.FileTooBig,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .ACCES => return error.AccessDenied,
                .PERM => return error.AccessDenied,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .BUSY => return error.DeviceBusy,
                .NXIO => return error.NoDevice,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }
}

pub fn writevStream(ctx: ?*anyopaque, exec: Reactor.Executer, stream: Runtime.net.Stream, iovecs: []const Runtime.net.Stream.iovec_const) Runtime.net.Stream.WriteError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };

    var op: Operation = .{
        .waker = exec.getWaker(),
        .result = 0,
        .has_result = false,
        .exec = exec,
    };

    sqe.prep_writev(stream.handle, iovecs, 0);
    sqe.user_data = @intFromPtr(&op);

    while (true) {
        if (exec.@"suspend"()) {
            return error.Canceled;
        }
        if (op.has_result) {
            const result = op.result;
            switch (errno(result)) {
                .SUCCESS => return @intCast(result),
                .INTR => continue,
                .INVAL => return error.InvalidArgument,
                .FAULT => unreachable,
                .NOENT => return error.ProcessNotFound,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.NotOpenForWriting, // Can be a race condition.
                .DESTADDRREQ => unreachable, // `connect` was never called.
                .DQUOT => return error.DiskQuota,
                .FBIG => return error.FileTooBig,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .PERM => return error.AccessDenied,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .BUSY => return error.DeviceBusy,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }
}
pub fn closeStream(ctx: ?*anyopaque, exec: Reactor.Executer, stream: Runtime.net.Stream) void {
    _ = ctx;
    _ = exec;
    std.posix.close(stream.handle);
}

pub fn closeServer(ctx: ?*anyopaque, exec: Reactor.Executer, server: Runtime.net.Server) void {
    _ = ctx;
    _ = exec;
    std.posix.close(server.handle);
}

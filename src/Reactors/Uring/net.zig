const std = @import("std");

const Runtime = @import("../../Runtime.zig");
const Reactor = @import("../../Reactor.zig");

const Uring = @import("./Uring.zig");
const ThreadContext = Uring.ThreadContext;
const Operation = Uring.Operation;
const CreateError = Runtime.Socket.CreateError;
const errno = Uring.errno;

pub fn createSocket(ctx: ?*anyopaque, exec: Reactor.Executer, domain: Runtime.Socket.Domain, protocol: Runtime.Socket.Protocol) Runtime.Poller(Runtime.Socket.CreateError!Runtime.Socket) {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

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

    const domain_int: u32 = switch (domain) {
        .ipv4 => std.os.linux.AF.INET,
        .ipv6 => std.os.linux.AF.INET6,
        .unix => std.os.linux.AF.UNIX,
    };

    const protocol_int: u32 = switch (protocol) {
        .tcp => std.os.linux.IPPROTO.TCP,
        .udp => std.os.linux.IPPROTO.UDP,
        .default => std.os.linux.IPPROTO.IP,
    };
    const type_int: u32 = switch (protocol) {
        .tcp => std.os.linux.SOCK.STREAM,
        .udp => std.os.linux.SOCK.DGRAM,
        .default => std.os.linux.SOCK.DGRAM,
    };

    sqe.prep_socket(domain_int, type_int, protocol_int, 0);
    sqe.user_data = @intFromPtr(op);

    return .{
        .poll = @ptrCast(&pollCreateSocket),
        .poller_ctx = @ptrCast(op),
        .result = undefined,
    };
}

pub fn pollCreateSocket(poller_ctx: ?*anyopaque) ?Runtime.Socket.CreateError!Runtime.Socket {
    const op: *Operation = @ptrCast(@alignCast(poller_ctx));

    if (!op.has_result) {
        const exec = op.exec.?;

        op.waker = exec.getWaker();
        if (exec.isCanceled()) {
            return error.Canceled;
        }
        return null;
    }

    const result = op.result;
    return .{
        .handle = switch (errno(result)) {
            .SUCCESS => @bitCast(result),
            .ACCES => return error.PermissionDenied,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .INVAL => return error.ProtocolFamilyNotAvailable,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolNotSupported,
            .PROTOTYPE => return error.SocketTypeNotSupported,
            else => |err| return std.posix.unexpectedErrno(err),
        },
    };
}

pub fn closeSocket(ctx: ?*anyopaque, exec: Reactor.Executer, socket: Runtime.Socket) void {
    _ = ctx;
    _ = exec;
    std.posix.close(socket.handle);
}

pub fn bind(ctx: ?*anyopaque, exec: Reactor.Executer, socket: Runtime.Socket, address: *const Runtime.Socket.Address, length: u32) Runtime.Socket.BindError!void {
    _ = ctx;
    _ = exec;
    try std.posix.bind(socket.handle, address, length);
}

pub fn listen(ctx: ?*anyopaque, exec: Reactor.Executer, socket: Runtime.Socket, backlog: u32) Runtime.Socket.ListenError!void {
    _ = ctx;
    _ = exec;
    try std.posix.listen(socket.handle, @truncate(backlog));
}

pub fn connect(ctx: ?*anyopaque, exec: Reactor.Executer, socket: Runtime.Socket, address: *const Runtime.Socket.Address) Runtime.Poller(Runtime.Socket.ConnectError!void) {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

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

    sqe.prep_connect(socket.handle, address, @sizeOf(Runtime.Socket.Address));
    sqe.user_data = @intFromPtr(op);

    return .{
        .poll = @ptrCast(&pollConnect),
        .poller_ctx = @ptrCast(op),
        .result = undefined,
    };
}

pub fn pollConnect(poller_ctx: ?*anyopaque) ?Runtime.Socket.ConnectError!void {
    const op: *Operation = @ptrCast(@alignCast(poller_ctx));

    if (!op.has_result) {
        const exec = op.exec.?;

        op.waker = exec.getWaker();
        if (exec.isCanceled()) {
            return error.Canceled;
        }
        return null;
    }

    const result = op.result;

    return switch (errno(result)) {
        .SUCCESS => {},
        .ACCES => return error.PermissionDenied,
        .PERM => return error.PermissionDenied,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .AGAIN, .INPROGRESS => return error.WouldBlock,
        .ALREADY => return error.ConnectionPending,
        .BADF => unreachable, // sockfd is not a valid open file descriptor.
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .FAULT => unreachable, // The socket structure address is outside the user's address space.
        .INTR => unreachable,
        .ISCONN => unreachable, // The socket is already connected.
        .HOSTUNREACH => return error.NetworkUnreachable,
        .NETUNREACH => return error.NetworkUnreachable,
        .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
        .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
        .TIMEDOUT => return error.ConnectionTimedOut,
        .NOENT => return error.FileNotFound, // Returned when socket is AF.UNIX and the given path does not exist.
        .CONNABORTED => unreachable, // Tried to reuse socket that previously received error.ConnectionRefused.
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

pub fn accept(ctx: ?*anyopaque, exec: Reactor.Executer, socket: Runtime.Socket) Runtime.Poller(Runtime.Socket.AcceptError!Runtime.Socket) {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

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

    sqe.prep_accept(socket.handle, null, null, 0);
    sqe.user_data = @intFromPtr(op);

    return .{
        .poll = @ptrCast(&pollAccept),
        .poller_ctx = @ptrCast(op),
        .result = undefined,
    };
}

pub fn pollAccept(poller_ctx: ?*anyopaque) ?Runtime.Socket.AcceptError!Runtime.Socket {
    const op: *Operation = @ptrCast(@alignCast(poller_ctx));

    if (!op.has_result) {
        const exec = op.exec.?;

        op.waker = exec.getWaker();
        if (exec.isCanceled()) {
            return error.Canceled;
        }
        return null;
    }

    const result = op.result;

    return switch (errno(result)) {
        .SUCCESS => .{ .handle = @bitCast(result) },
        .INTR => unreachable,
        .AGAIN => return error.WouldBlock,
        .BADF => unreachable, // always a race condition
        .CONNABORTED => error.ConnectionAborted,
        .FAULT => unreachable,
        .INVAL => error.SocketNotListening,
        .NOTSOCK => unreachable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS => error.SystemResources,
        .NOMEM => error.SystemResources,
        .OPNOTSUPP => unreachable,
        .PROTO => error.ProtocolFailure,
        .PERM => error.BlockedByFirewall,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn send(ctx: ?*anyopaque, exec: Reactor.Executer, socket: Runtime.Socket, buffer: []const u8, flags: Runtime.Socket.SendFlags) Runtime.Poller(Runtime.Socket.SendError!usize) {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

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

    var flags_int: u32 = 0;
    if (flags.more) flags_int |= std.os.linux.MSG.MORE;
    if (flags.nosignal) flags_int |= std.os.linux.MSG.NOSIGNAL;

    sqe.prep_send(socket.handle, buffer, flags_int);
    sqe.user_data = @intFromPtr(op);

    return .{
        .poll = @ptrCast(&pollSend),
        .poller_ctx = @ptrCast(op),
        .result = undefined,
    };
}

pub fn pollSend(poller_ctx: ?*anyopaque) ?Runtime.Socket.SendError!usize {
    const op: *Operation = @ptrCast(@alignCast(poller_ctx));

    if (!op.has_result) {
        const exec = op.exec.?;

        op.waker = exec.getWaker();
        if (exec.isCanceled()) {
            return error.Canceled;
        }
        return null;
    }

    const result = op.result;
    return switch (errno(result)) {
        .SUCCESS => @as(usize, @intCast(result)),
        .ACCES => return error.AccessDenied,
        .AGAIN => return error.WouldBlock,
        .ALREADY => return error.FastOpenAlreadyInProgress,
        .BADF => unreachable, // always a race condition
        .CONNRESET => error.ConnectionResetByPeer,
        .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
        .FAULT => unreachable, // An invalid user space address was specified for an argument.
        .INTR => unreachable,
        .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
        .MSGSIZE => error.MessageTooBig,
        .NOBUFS => error.SystemResources,
        .NOMEM => error.SystemResources,
        .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
        .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
        .PIPE => error.BrokenPipe,
        .HOSTUNREACH => error.NetworkUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .NETDOWN => error.NetworkSubsystemFailed,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn recv(ctx: ?*anyopaque, exec: Reactor.Executer, socket: Runtime.Socket, buffer: []u8, flags: Runtime.Socket.RecvFlags) Runtime.Poller(Runtime.Socket.RecvError!usize) {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getThreadContext()));

    const sqe = thread_ctx.getSqe() catch {
        @panic("failed to get sqe");
    };
    const op = thread_ctx.getOp() catch {
        @panic("failed to get op");
    };

    op.* = .{
        .waker = null,
        .exec = exec,
        .result = 0,
        .has_result = false,
    };

    var flags_int: u32 = 0;
    if (flags.peek) flags_int |= std.os.linux.MSG.PEEK;
    if (flags.waitall) flags_int |= std.os.linux.MSG.WAITALL;

    sqe.prep_recv(socket.handle, buffer, flags_int);
    sqe.user_data = @intFromPtr(op);

    return .{
        .poll = @ptrCast(&pollRecv),
        .poller_ctx = @ptrCast(op),
        .result = undefined,
    };
}

pub fn pollRecv(poller_ctx: ?*anyopaque) ?Runtime.Socket.RecvError!usize {
    const op: *Operation = @ptrCast(@alignCast(poller_ctx));

    if (!op.has_result) {
        const exec = op.exec.?;

        op.waker = exec.getWaker();
        if (exec.isCanceled()) {
            return error.Canceled;
        }
        return null;
    }

    const result = op.result;

    return switch (errno(result)) {
        .SUCCESS => return @as(usize, @intCast(result)),
        .BADF => unreachable, // always a race condition
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOTCONN => return error.SocketNotConnected,
        .NOTSOCK => unreachable,
        .INTR => unreachable,
        .AGAIN => return error.WouldBlock,
        .NOMEM => return error.SystemResources,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .TIMEDOUT => return error.ConnectionTimedOut,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub fn setsockopt(ctx: ?*anyopaque, exec: Reactor.Executer, socket: Runtime.Socket, option: Runtime.Socket.Option) Runtime.Socket.SetOptError!void {
    _ = ctx;
    _ = exec;

    switch (option) {
        .reuseaddr => |value| {
            const int_value: c_int = if (value) 1 else 0;
            try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&int_value));
        },
        .reuseport => |value| {
            const int_value: c_int = if (value) 1 else 0;
            try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&int_value));
        },
        .keepalive => |value| {
            const int_value: c_int = if (value) 1 else 0;
            try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&int_value));
        },
        .rcvbuf => |value| {
            const int_value: c_int = @intCast(value);
            try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&int_value));
        },
        .sndbuf => |value| {
            const int_value: c_int = @intCast(value);
            try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&int_value));
        },
        .rcvtimeo => |value| {
            const timeval = std.posix.timeval{
                .sec = @intCast(value / 1000),
                .usec = @intCast((value % 1000) * 1000),
            };
            try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval));
        },
        .sndtimeo => |value| {
            const timeval = std.posix.timeval{
                .sec = @intCast(value / 1000),
                .usec = @intCast((value % 1000) * 1000),
            };
            try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeval));
        },
        .nodelay => |value| {
            const int_value: c_int = if (value) 1 else 0;
            try std.posix.setsockopt(socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&int_value));
        },
        .broadcast => |value| {
            const int_value: c_int = if (value) 1 else 0;
            try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&int_value));
        },
    }
}

const std = @import("std");
const posix = std.posix;

const Runtime = @import("../Runtime.zig");
const Cancelable = Runtime.Cancelable;
const Stream = @import("../net.zig").Stream;

const Server = @This();

handle: Handle,

pub const Handle = posix.socket_t;

pub const Address = std.net.Address;

pub const ListenError = Cancelable || posix.SocketError || posix.BindError || posix.ListenError ||
    posix.SetSockOptError || posix.GetSockNameError;

pub const AcceptError = Cancelable || error{
    ConnectionAborted,

    /// The file descriptor sockfd does not refer to a socket.
    FileDescriptorNotASocket,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Not enough free memory.  This often means that the memory allocation  is  limited
    /// by the socket buffer limits, not by the system memory.
    SystemResources,

    /// Socket is not listening for new connections.
    SocketNotListening,

    ProtocolFailure,

    /// Firewall rules forbid connection.
    BlockedByFirewall,

    /// This error occurs when no global event loop is configured,
    /// and accepting from the socket would block.
    WouldBlock,

    /// An incoming connection was indicated, but was subsequently terminated by the
    /// remote peer prior to accepting the call.
    ConnectionResetByPeer,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The referenced socket is not a type that supports connection-oriented service.
    OperationNotSupported,
} || posix.UnexpectedError;

pub const ListenOptions = struct {
    /// How many connections the kernel will accept on the application's behalf.
    /// If more than this many connections pool in the kernel, clients will start
    /// seeing "Connection refused".
    kernel_backlog: u31 = 128,
    /// Sets SO_REUSEADDR and SO_REUSEPORT on POSIX.
    /// Sets SO_REUSEADDR on Windows, which is roughly equivalent.
    reuse_address: bool = false,
};

pub fn accept(server: Server, rt: Runtime) AcceptError!Stream {
    return rt.vtable.accept(rt.ctx, server);
}

pub fn close(server: Server, rt: Runtime) void {
    return rt.vtable.closeServer(rt.ctx, server);
}

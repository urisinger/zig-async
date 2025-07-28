const std = @import("std");
const posix = std.posix;
pub const Address = std.net.Address;

const Runtime = @import("Runtime.zig");
pub const Server = @import("net/Server.zig");
const Cancelable = Runtime.Cancelable;

// A copy of the Stream struct in std.net.Stream
pub const Stream = struct {
    handle: Handle,

    pub const Handle = posix.socket_t;

    pub const WriteError = Cancelable || posix.WriteError;
    pub const ReadError = Cancelable || posix.ReadError;

    pub const iovec = std.posix.iovec;
    pub const iovec_const = std.posix.iovec_const;

    pub fn write(stream: Stream, rt: Runtime, buffer: []const u8) WriteError!usize {
        return rt.vtable.writeStream(rt.ctx, stream, buffer);
    }

    pub fn read(stream: Stream, rt: Runtime, buffer: []u8) ReadError!usize {
        return rt.vtable.readStream(rt.ctx, stream, buffer);
    }

    pub fn writev(stream: Stream, rt: Runtime, iovecs: []const iovec_const) WriteError!usize {
        return rt.vtable.writevStream(rt.ctx, stream, iovecs);
    }

    pub fn writevAll(stream: Stream, rt: Runtime, iovecs: []iovec_const) WriteError!void {
        if (iovecs.len == 0) return;

        var i: usize = 0;
        while (true) {
            var amt = try stream.writev(rt, iovecs[i..]);
            while (amt >= iovecs[i].len) {
                amt -= iovecs[i].len;
                i += 1;
                if (i >= iovecs.len) return;
            }
            iovecs[i].base += amt;
            iovecs[i].len -= amt;
        }

    }

    pub fn readv(stream: Stream, rt: Runtime, iovecs: []const iovec) ReadError!usize {
        return rt.vtable.readvStream(rt.ctx, stream, iovecs);
    }


    pub fn close(stream: Stream, rt: Runtime) void {
        return rt.vtable.closeStream(rt.ctx, stream);
    }
};

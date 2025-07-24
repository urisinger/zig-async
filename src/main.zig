const std = @import("std");
const log = std.log.scoped(.main);
const Runtime = @import("Runtime.zig");
const Future = Runtime.Future;
const Fibers = @import("Executers/Fibers/Fibers.zig");
const Uring = @import("Reactors/Uring/Uring.zig");

const os = std.os;

// Function to manage CTRL + C
fn sigintHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    std.debug.print("SIGINT received\n", .{});
}

pub fn main() !void {
    const act = os.linux.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = os.linux.empty_sigset,
        .flags = 0,
    };

    if (os.linux.sigaction(os.linux.SIG.INT, &act, null) != 0) {
        return error.SignalHandlerError;
    }
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var event_loop = Uring.init(gpa.allocator());
    var fibers = try Fibers.init(allocator, event_loop.reactor());
    defer fibers.deinit();

    const rt = fibers.runtime();

    _ = rt.spawn(run, .{rt});
}

pub const Client = struct {
    socket: Runtime.Socket,
    buffer: [1024]u8,
};

// Select style api.
pub fn run(rt: Runtime) i32 {
    const socket = rt.createSocket(.ipv4, .tcp) catch |err| {
        log.err("create socket error: {any}", .{err});
        return 1;
    };

    defer socket.close(rt);

    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080);
    const os_address = address.any;
    const os_address_len = address.getOsSockLen();
    socket.bind(rt, &os_address, os_address_len) catch |err| {
        log.err("bind error: {any}", .{err});
        return 1;
    };

    socket.listen(rt, 10) catch |err| {
        log.err("listen error: {any}", .{err});
        return 1;
    };

    while (true) {
        const accept = socket.accept(rt).@"await"(rt) catch |err| {
            log.err("accept error: {any}", .{err});
            continue;
        };
        _ = rt.spawn(client_task, .{ rt, accept });
    }

    return 0;
}

pub fn client_task(rt: Runtime, socket: Runtime.Socket) void {
    var buffer: [1024]u8 = undefined;
    while (true) {
        const bytes = socket.recv(rt, &buffer, .{}).@"await"(rt) catch |err| {
            log.err("recv error: {any}", .{err});
            break;
        };
        if (bytes == 0) {
            break;
        }
        log.info("recv {d} bytes", .{bytes});
        const send = socket.send(rt, buffer[0..bytes], .{}).@"await"(rt) catch |err| {
            log.err("send error: {any}", .{err});
            break;
        };
        log.info("send {d} bytes", .{send});
    }
}

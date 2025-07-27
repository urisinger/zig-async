const root = @import("zig_io");
const Runtime = root.Runtime;
const Fibers = root.Fibers;
const Uring = root.Uring;

const std = @import("std");
const log = std.log.scoped(.echo);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var event_loop = Uring.init(gpa.allocator());
    var fibers = try Fibers.init(allocator, event_loop.reactor());
    defer fibers.deinit();

    const rt = fibers.runtime();

    const handle = rt.spawn(run, .{rt});

    const stdin = std.io.getStdIn().reader();
    var buffer: [1024]u8 = undefined;

    while (true) {
        const result = try stdin.readUntilDelimiter(&buffer, '\n');

        if (std.mem.eql(u8, result, "stop")) {
            log.info("stopping", .{});
            handle.cancel(rt);
            break;
        }
    }

    fibers.cancelAll();
}

// Echo server implementation
fn run(rt: Runtime) i32 {
    log.info("Starting echo server on 127.0.0.1:8080", .{});

    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080);
    const options = Runtime.net.Server.ListenOptions{
        .kernel_backlog = 128,
        .reuse_address = true,
    };

    var server = rt.listen(address, options) catch |err| {
        log.err("listen error: {any}", .{err});
        return 1;
    };
    defer server.close(rt);

    log.info("Echo server listening, type 'stop' to shutdown", .{});

    while (true) {
        const stream = server.accept(rt) catch |err| {
            log.err("accept error: {any}", .{err});
            break;
        };

        _ = rt.spawn(clientHandler, .{ rt, stream });
    }

    return 0;
}

fn clientHandler(rt: Runtime, stream: Runtime.net.Stream) void {
    defer stream.close(rt);
    log.info("New client connected", .{});

    var buffer: [1024]u8 = undefined;
    while (true) {
        const bytes_read = stream.read(rt, &buffer) catch |err| {
            log.err("read error: {any}", .{err});
            break;
        };

        if (bytes_read == 0) {
            log.info("Client disconnected", .{});
            break;
        }

        log.info("Received {d} bytes: {s}", .{ bytes_read, buffer[0..bytes_read] });

        const bytes_written = stream.write(rt, buffer[0..bytes_read]) catch |err| {
            log.err("write error: {any}", .{err});
            break;
        };

        log.info("Echoed {d} bytes", .{bytes_written});
    }
}

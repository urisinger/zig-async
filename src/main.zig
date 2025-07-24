const std = @import("std");
const log = std.log.scoped(.main);
const Runtime = @import("Runtime.zig");
const Future = Runtime.Future;
const Fibers = @import("Executers/Fibers/Fibers.zig");
const Uring = @import("Reactors/Uring/Uring.zig");

const os = std.os;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var event_loop = Uring.init(gpa.allocator());
    var fibers = try Fibers.init(allocator, event_loop.reactor());
    defer fibers.deinit();

    const rt = fibers.runtime();

    const handle = rt.spawn(run, .{ rt, allocator });

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
    log.info("stopped", .{});
}

pub fn test1(rt: Runtime, sleep_amount: u64) void {
    const read_bytes = 10;
    const num_reads = 10;
    var read_buffers: [num_reads][read_bytes]u8 = undefined;
    var read_handles: [num_reads]*Runtime.File.AnyReadHandle = undefined;

    const file: Runtime.File = rt.open("/dev/urandom", .{ .mode = .read_only }) catch |err| {
        log.err("open error: {any}", .{err});
        return;
    };

    rt.sleep(sleep_amount) catch |err| {
        log.err("sleep error: {any}", .{err});
        return;
    };

    log.info("sleeping for {d}ms", .{sleep_amount});

    for (0..num_reads) |i| {
        read_handles[i] = file.read(rt, &read_buffers[i]);
    }

    for (read_handles) |handle| {
        const result = handle.@"await"(rt) catch |err| {
            log.err("read error: {any}", .{err});
            return;
        };
        log.info("read {d} bytes", .{result});
    }
}

// Select style api.
pub fn run(rt: Runtime, allocator: std.mem.Allocator) i32 {
    var fut1 = Future(test1).init(.{ rt, 1000 });
    var fut2 = Future(test1).init(.{ rt, 100 });

    const result = rt.select(.{ &fut2, &fut1 });

    log.info("result: {any}", .{result});

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

    var tasks = std.ArrayList(Runtime.SpawnHandle(void)).init(allocator);
    defer tasks.deinit();

    while (true) {
        const accept = socket.accept(rt).@"await"(rt) catch |err| {
            log.err("accept error: {any}", .{err});
            break;
        };
        const task = rt.spawn(client_task, .{ rt, accept });
        tasks.append(task) catch |err| {
            log.err("spawn error: {any}", .{err});
            break;
        };
    }

    for (tasks.items) |task| {
        task.cancel(rt);
    }

    for (tasks.items) |task| {
        task.join(rt) catch {
            return 0;
        };
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

const std = @import("std");
const log = std.log.scoped(.main);
const Runtime = @import("Runtime.zig");
const Future = Runtime.Future;
const Fibers = @import("Executers/Fibers.zig");
const EventLoop = @import("Reactors/EventLoop.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var event_loop = EventLoop.init(gpa.allocator());
    var fibers = try Fibers.init(allocator, event_loop.reactor());
    defer fibers.deinit();

    const rt = fibers.runtime();

    _ = rt.spawn(run, .{rt});
}

pub fn run(rt: Runtime) i32 {
    log.info("hi", .{});
    {
        var fu1: Future(sleep) = .init(.{rt});
        var fu2: Future(write) = .init(.{rt});
        var fu3: Future(read) = .init(.{rt});
        // Join just waits for all the tasks to finish.
        const result = rt.join(.{ &fu1, &fu2, &fu3 });
        log.info("result: {any}", .{result});
    }

    {
        var fu1: Future(sleep) = .init(.{rt});
        var fu2: Future(write) = .init(.{rt});
        var fu3: Future(read) = .init(.{rt});
        // Select is a bit more complicated,
        const result = rt.select(.{ &fu1, &fu2, &fu3 });
        log.info("result: {}", .{result});
    }

    log.info("main finished", .{});
    return 0;
}

pub fn sleep(rt: Runtime) i32 {
    log.info("future 1 running", .{});
    const handle1 = rt.spawn(write, .{rt});

    const handle2 = rt.spawn(read, .{rt});
    _ = handle1.join(rt);
    _ = handle2.join(rt);

    return 1;
}

pub fn write(rt: Runtime) i32 {
    const file = rt.open("/dev/null", .{ .mode = .write_only }) catch unreachable;
    const write_count = 10;
    const write_size = 1000;
    var res: [write_count][write_size]u8 = undefined;
    var write_handles: [write_count]*Runtime.File.AnyWriteHandle = undefined;
    var write_sum: usize = 0;
    log.info("writing", .{});
    for (0..write_count) |i| {
        write_handles[i] = file.write(rt, &res[i]);
    }

    for (write_handles) |write_handle| {
        const bytes_written = write_handle.@"await"(rt) catch return 0;
        log.info("written: {} bytes", .{bytes_written});
        write_sum += bytes_written;
    }

    return 2;
}

pub fn read(rt: Runtime) usize {
    log.info("future 3 running", .{});

    const file = rt.open("/dev/random", .{ .mode = .read_only }) catch unreachable;
    const read_count = 10;
    const read_size = 1000;
    var res: [read_count][read_size]u8 = undefined;
    var read_handles: [read_count]*Runtime.File.AnyReadHandle = undefined;
    var read_sum: usize = 0;
    log.info("reading", .{});
    for (0..read_count) |i| {
        read_handles[i] = file.read(rt, &res[i]);
    }
    for (read_handles) |read_handle| {
        const bytes_read = read_handle.@"await"(rt) catch return 0;
        log.info("read: {} bytes", .{bytes_read});
        read_sum += bytes_read;
    }

    file.close(rt);

    return read_sum;
}

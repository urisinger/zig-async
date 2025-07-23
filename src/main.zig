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

    const rt = fibers.runtime();

    _ = rt.spawn(run, .{rt});

    fibers.deinit();
}

pub fn run(rt: Runtime) i32 {
    log.info("hi", .{});
    {
        var fu1: Future(run1) = .init(.{rt});
        var fu2: Future(run2) = .init(.{rt});
        var fu3: Future(run3) = .init(.{rt});
        const result = rt.join(.{ &fu1, &fu2, &fu3 });
        log.info("result: {any}", .{result});
    }

    {
        var fu1: Future(run1) = .init(.{rt});
        var fu2: Future(run2) = .init(.{rt});
        var fu3: Future(run3) = .init(.{rt});
        const result = rt.select(.{ &fu1, &fu2, &fu3 });
        log.info("result: {}", .{result});
    }

    const handle = rt.spawn(run4, .{rt});
    log.info("result: {any}", .{handle.join(rt)});

    log.info("main finished", .{});
    return 0;
}

pub fn run1(rt: Runtime) i32 {
    _ = rt;
    log.info("future 1 running", .{});

    return 1;
}

pub fn run2(rt: Runtime) i32 {
    _ = rt;
    log.info("future 2 running", .{});

    return 2;
}

pub fn run3(rt: Runtime) usize {
    log.info("future 3 running", .{});

    const file = rt.open("/dev/random", .{ .mode = .read_only }) catch unreachable;
    var res: [10]u8 = undefined;
    @memset(&res, 1);
    const read = file.read(rt, &res) catch |e| {
        switch (e) {
            error.Canceled => {
                log.info("canceled", .{});
                return 0;
            },
            else => return 0,
        }
    };

    file.close(rt);

    log.info("read: {} bytes", .{read});

    for (res) |c| {
        log.info("{}", .{c});
    }

    std.log.info("h", .{});
    return read;
}

pub fn run4(rt: Runtime) void {
    _ = rt;
    log.info("future 4 running", .{});
}

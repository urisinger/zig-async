const std = @import("std");
const log = std.log.scoped(.main);
const Runtime = @import("Runtime.zig");
const Fibers = @import("Fibers.zig");
const EventLoop = @import("EventLoop.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;

    const allocator = gpa.allocator();

    var event_loop = EventLoop.init(gpa.allocator());
    var fibers = Fibers.init(allocator, event_loop.io());

    const rt = fibers.runtime();

    rt.asyncDetached(run, .{rt});

    std.log.info("hi form", .{});
    fibers.join();

    fibers.deinit();
}

pub fn run(rt: Runtime) void {
    var fut1 = rt.@"async"(run1, .{rt});
    log.info("hi", .{});
    var fut2 = rt.@"async"(run2, .{rt});
    var fut3 = rt.@"async"(run3, .{rt});

    _ = fut3.cancel(rt);

    _ = fut1.@"await"(rt);
    _ = fut2.@"await"(rt);

    log.info("main finished", .{});
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
    const read = file.read(
        &res,
    ) catch |e| {
        switch (e) {
            error.Canceled => {
                log.info("canceled", .{});
                return 0;
            },
            else => return 0,
        }
    };

    file.close();

    log.info("read: {} bytes", .{read});

    for (res) |c| {
        log.info("{}", .{c});
    }
    return read;
}

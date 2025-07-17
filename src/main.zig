const std = @import("std");
const log = std.log.scoped(.main);
const Exec = @import("Exec.zig");
const Fibers = @import("Fibers.zig");
const EventLoop = @import("EventLoop.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;

    const allocator = gpa.allocator();

    var event_loop = EventLoop.init(gpa.allocator());
    var runtime = Fibers.init(allocator, event_loop.io());

    const exec = runtime.exec();

    exec.asyncDetached(run, .{exec});

    runtime.join();

    runtime.deinit();

    const check = gpa.deinit();
    if (check == .leak) {
        std.log.err("leak", .{});
    }
}

pub fn run(exec: Exec) void {
    var fut1 = exec.@"async"(run1, .{exec});
    var fut2 = exec.@"async"(run2, .{exec});
    var fut3 = exec.@"async"(run3, .{exec});

    _ = fut3.@"await"(exec);
    _ = fut1.@"await"(exec);
    _ = fut2.@"await"(exec);

    log.info("main finished", .{});
}

pub fn run1(exec: Exec) i32 {
    _ = exec;
    log.info("future 1 running", .{});

    return 1;
}

pub fn run2(exec: Exec) i32 {
    _ = exec;
    log.info("future 2 running", .{});

    return 2;
}

pub fn run3(exec: Exec) usize {
    log.info("future 3 running", .{});

    const file = exec.open("/dev/random", .{ .mode = .read_only }) catch unreachable;
    var res: [10]u8 = undefined;
    @memset(&res, 1);
    const read = file.read(
        &res,
    ) catch unreachable;

    file.close();

    log.info("read: {} bytes", .{read});

    for (res) |c| {
        log.info("{}", .{c});
    }
    return read;
}

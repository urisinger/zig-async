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

    std.Thread.sleep(100000000);
}

pub fn run(exec: Exec) void {

    const file = EventLoop.openFile(exec, "/dev/random", .{ .ACCMODE = .RDWR}, 0) catch unreachable;

    var res: [10]u8 = undefined;
    @memset(&res, 1);
    const read = EventLoop.readFile(exec, file, &res, 0) catch unreachable;

    log.info("{} read: {}", .{res[0], read});

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

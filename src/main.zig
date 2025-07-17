const std = @import("std");
const Exec = @import("Exec.zig");
const EventLoop = @import("EventLoop.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;

    const allocator = gpa.allocator();
    var event_loop = EventLoop.init(allocator, .{ .ctx = null, .onPark = ioHandler });

    const exec = event_loop.exec();

    std.log.info("normal addres: 0x{x}", .{@intFromPtr(&main)});

    exec.asyncDetached(run, .{exec});

    std.Thread.sleep(100000000);
}

pub fn ioHandler(ctx: ?*anyopaque, wake: *const fn (fut: *Exec.AnyFuture) void) void {
    _ = ctx;
    _ = wake;
    std.log.info("parking", .{});
}

pub fn run(exec: Exec) void {
    var fut1 = exec.@"async"(run1, .{exec});
    var fut2 = exec.@"async"(run2, .{exec});

    const res = exec.select(.{ .fut1 = &fut1, .fut2 = &fut2 });

    switch (res) {
        .fut1 => std.log.info("fut1 finished first", .{}),
        .fut2 => std.log.info("fut2 finished first", .{}),
    }
}

pub fn run1(exec: Exec) i32 {
    _ = std.io.getStdIn().writer().write("hello 1\n") catch unreachable;

    exec.@"suspend"();
    return 1;
}

pub fn run2(exec: Exec) i32 {
    _ = exec;
    _ = std.io.getStdIn().writer().write("hello 2\n") catch unreachable;

    return 2;
}

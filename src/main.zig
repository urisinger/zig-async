const std = @import("std");
const EventLoop = @import("EventLoop.zig");
pub fn main() !void {
    var gpa:  std.heap.DebugAllocator(.{}) = .{};

    const allocator = gpa.allocator();
    var event_loop = EventLoop.init(allocator);

    const exec = event_loop.exec();

    std.log.info("normal addres: 0x{x}", .{@intFromPtr(&main)});

    exec.asyncDetached(run, .{});

    std.Thread.sleep(100000000);
}

pub fn run() void{
    _ = std.io.getStdIn().writer().write("hi") catch unreachable;
}

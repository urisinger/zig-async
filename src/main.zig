const std = @import("std");
const log = std.log.scoped(.main);
const Runtime = @import("Runtime.zig");
const Future = Runtime.Future;
const Fibers = @import("Fibers.zig");
const EventLoop = @import("EventLoop.zig");

pub const std_options: std.Options = .{
    .logFn = logfn,
};

fn formatTimestamp(timestamp: u64, buf: []u8) []u8 {
    const ms_in_day = 24 * 60 * 60 * 1000;
    const ms_in_hour = 60 * 60 * 1000;
    const ms_in_minute = 60 * 1000;

    const ms_today = timestamp % ms_in_day;
    const hours = ms_today / ms_in_hour;
    const minutes = (ms_today % ms_in_hour) / ms_in_minute;
    const seconds = (ms_today % ms_in_minute) / 1000;
    const milliseconds = ms_today % 1000;

    return std.fmt.bufPrint(buf, "{:02}:{:02}:{:02}.{:03}", .{ hours, minutes, seconds, milliseconds }) catch "00:00:00.000";
}

fn logfn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const thread_id = std.Thread.getCurrentId();

    std.log.defaultLog(level, scope, "Thread id: {d} " ++ format, .{thread_id} ++ args);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;

    const allocator = gpa.allocator();

    var event_loop = EventLoop.init(gpa.allocator());
    var fibers = try Fibers.init(allocator, event_loop.io());

    const rt = fibers.runtime();

    rt.spawn(run, .{rt});
    rt.spawn(run, .{rt});
    rt.spawn(run, .{rt});
    rt.spawn(run, .{rt});

    fibers.deinit();

    log.info("{}", .{gpa.deinit()});
}

pub fn run(rt: Runtime) void {
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

    rt.spawn(run4, .{rt});

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

    std.log.info("h", .{});
    return read;
}

pub fn run4(rt: Runtime) void {
    _ = rt;
    log.info("future 4 running", .{});
}

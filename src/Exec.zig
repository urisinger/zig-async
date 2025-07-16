const std = @import("std");

const Exec = @This();

ctx: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    @"async": *const fn (
        ctx: ?*anyopaque,
        /// The pointer of this slice is an "eager" result value.
        /// The length is the size in bytes of the result type.
        /// This pointer's lifetime expires directly after the call to this function.
        result: []u8,
        result_alignment: std.mem.Alignment,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ?*AnyFuture,
    /// Executes `start` asynchronously in a manner such that it cleans itself
    /// up. This mode does not support results, await, or cancel.
    ///
    /// Thread-safe.
    asyncDetached: *const fn (
        /// Corresponds to `Exec.ctx`.
        ctx: ?*anyopaque,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) void,
    /// This function is only called when `async` returns a non-null value.
    ///
    /// Thread-safe.
    @"await": *const fn (
        /// Corresponds to `Io.userdata`.
        ctx: ?*anyopaque,
        /// The same value that was returned from `async`.
        any_future: *AnyFuture,
        /// Points to a buffer where the result is written.
        /// The length is equal to size in bytes of result type.
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void,

    select: *const fn (ctx: ?*anyopaque, futures: []const *AnyFuture) usize,

    // Suspends the future until Io wakes it up
    @"suspend": *const fn (ctx: ?*anyopaque) void,

    setIo: *const fn (ctx: ?*anyopaque, io: Io) void,
};

pub const Io = struct {
    ctx: ?*anyopaque,

    // This function gets called when an execution thread blocks.
    onPark: *const fn (ctx: ?*anyopaque, wake: *const fn (fut: *AnyFuture) void) void,
};

pub const AnyFuture = opaque {};

pub fn Future(Result: type) type {
    return struct {
        any_future: ?*AnyFuture,
        result: Result,

        pub fn @"await"(f: *@This(), exec: Exec) Result {
            const any_future = f.any_future orelse return f.result;
            exec.vtable.@"await"(exec.userdata, any_future, @ptrCast((&f.result)[0..1]), .of(Result));
            f.any_future = null;
            return f.result;
        }
    };
}

/// Calls `function` with `args` asynchronously. The resource cleans itself up
/// when the function returns. Does not support await, cancel, or a return value.
pub inline fn asyncDetached(exec: Exec, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque) void {
            const args_casted: *const Args = @alignCast(@ptrCast(context));
            @call(.auto, function, args_casted.*);
        }
    };
    exec.vtable.asyncDetached(exec.ctx, if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]), std.mem.Alignment.fromByteUnits(@alignOf(Args)), TypeErased.start);
}

/// Calls `function` with `args`, such that the return value of the function is
/// not guaranteed to be available until `await` is called.
pub inline fn @"async"(exec: Exec, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const args_casted: *const Args = @alignCast(@ptrCast(context));
            const result_casted: *Result = @ptrCast(@alignCast(result));
            result_casted.* = @call(.auto, function, args_casted.*);
        }
    };
    var future: Future(Result) = undefined;
    future.any_future = exec.vtable.@"async"(
        exec.ctx,
        @ptrCast((&future.result)[0..1]),
        .of(Result),
        if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]),
        .of(Args),
        TypeErased.start,
    );
    return future;
}

const std = @import("std");
const Io = @import("Io.zig");
const fs = std.fs;

const Runtime = @This();

const FileHandle = opaque {};

ctx: ?*anyopaque,
vtable: *const VTable,

io: Io,

pub const Cancelable = error{
    /// Caller has requested the async operation to stop.
    Canceled,
};

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
    /// runtimeutes `start` asynchronously in a manner such that it cleans itself
    /// up. This mode does not support results, await, or cancel.
    ///
    /// Thread-safe.
    asyncDetached: *const fn (
        /// Corresponds to `runtime.ctx`.
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

    // Suspends this future until Io wakes it up
    @"suspend": *const fn (ctx: ?*anyopaque) Cancelable!void,

    cancel: *const fn (
        /// Corresponds to `Runtime.ctx`.
        ctx: ?*anyopaque,
        /// The same value that was returned from `async`.
        any_future: *AnyFuture,
        /// Points to a buffer where the result is written.
        /// The length is equal to size in bytes of result type.
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void,

    wake: *const fn (ctx: ?*anyopaque, fut: *anyopaque) void,

    // Pass what you get from this to wake yourself
    getWaker: *const fn (ctx: ?*anyopaque) *anyopaque,

    // Get the local context for io
    getLocalContext: *const fn (ctx: ?*anyopaque) ?*anyopaque,
};

// Returns true if cancled
pub fn @"suspend"(runtime: Runtime) Cancelable!void {
    return runtime.vtable.@"suspend"(runtime.ctx);
}

pub fn wake(runtime: Runtime, fut: *anyopaque) void {
    runtime.vtable.wake(runtime.ctx, fut);
}

pub fn getWaker(runtime: Runtime) *anyopaque {
    return runtime.vtable.getWaker(runtime.ctx);
}

pub fn getLocalContext(runtime: Runtime) ?*anyopaque {
    return runtime.vtable.getLocalContext(runtime.ctx);
}

pub const AnyFuture = opaque {};

pub fn Future(Result: type) type {
    return struct {
        any_future: ?*AnyFuture,
        result: Result,

        /// Equivalent to `await` but sets a flag observable to application
        /// code that cancellation has been requested.
        ///
        /// Idempotent.
        pub fn cancel(f: *@This(), runtime: Runtime) Result {
            const any_future = f.any_future orelse return f.result;
            runtime.vtable.cancel(runtime.ctx, any_future, @ptrCast((&f.result)[0..1]), std.mem.Alignment.fromByteUnits(@alignOf(Result)));
            f.any_future = null;
            return f.result;
        }

        pub fn @"await"(f: *@This(), runtime: Runtime) Result {
            const any_future = f.any_future orelse return f.result;
            runtime.vtable.@"await"(runtime.ctx, any_future, if (@sizeOf(Result) == 0) &.{} else @ptrCast((&f.result)[0..1]), std.mem.Alignment.fromByteUnits(@alignOf(Result)));
            f.any_future = null;
            return f.result;
        }
    };
}

/// Calls `function` with `args` asynchronously. The resource cleans itself up
/// when the function returns. Does not support await, cancel, or a return value.
pub inline fn asyncDetached(runtime: Runtime, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque) void {
            const args_casted: *const Args = @alignCast(@ptrCast(context));
            @call(.auto, function, args_casted.*);
        }
    };
    runtime.vtable.asyncDetached(runtime.ctx, if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]), std.mem.Alignment.fromByteUnits(@alignOf(Args)), TypeErased.start);
}

/// Calls `function` with `args`, such that the return value of the function is
/// not guaranteed to be available until `await` is called.
pub noinline fn @"async"(runtime: Runtime, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
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

    const result_buf: []u8 = if (@sizeOf(Result) == 0) &.{} else @ptrCast((&future.result)[0..1]);
    const result_alignment = std.mem.Alignment.fromByteUnits(@alignOf(Result));
    const args_buf: []const u8 = if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]);
    const args_alignment = std.mem.Alignment.fromByteUnits(@alignOf(Args));
    const start = TypeErased.start;
    const ctx = runtime.ctx;

    std.log.info("vtable is: {x}, async is: {x}", .{ @intFromPtr(runtime.vtable), @intFromPtr(runtime.vtable.@"async") });
    future.any_future = runtime.vtable.@"async"(
        ctx,
        result_buf,
        result_alignment,
        args_buf,
        args_alignment,
        start,
    );
    return future;
}
/// Given a struct with each field a `*Future`, returns a union with the same
/// fields, each field type the future's result.
pub fn SelectUnion(S: type) type {
    const struct_fields = @typeInfo(S).@"struct".fields;
    var fields: [struct_fields.len]std.builtin.Type.UnionField = undefined;
    for (&fields, struct_fields) |*union_field, struct_field| {
        const F = @typeInfo(struct_field.type).pointer.child;
        const Result = @TypeOf(@as(F, undefined).result);
        union_field.* = .{
            .name = struct_field.name,
            .type = Result,
            .alignment = struct_field.alignment,
        };
    }
    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = std.meta.FieldEnum(S),
        .fields = &fields,
        .decls = &.{},
    } });
}

/// `s` is a struct with every field a `*Future(T)`, where `T` can be any type,
/// and can be different for each field.
pub fn select(runtime: Runtime, s: anytype) SelectUnion(@TypeOf(s)) {
    const U = SelectUnion(@TypeOf(s));
    const S = @TypeOf(s);
    const fields = @typeInfo(S).@"struct".fields;
    var futures: [fields.len]*AnyFuture = undefined;
    inline for (fields, &futures) |field, *any_future| {
        const future = @field(s, field.name);
        any_future.* = future.any_future orelse return @unionInit(U, field.name, future.result);
    }
    switch (runtime.vtable.select(runtime.ctx, &futures)) {
        inline 0...(fields.len - 1) => |selected_index| {
            const field_name = fields[selected_index].name;
            return @unionInit(U, field_name, @field(s, field_name).@"await"(runtime));
        },
        else => unreachable,
    }
}

pub fn open(runtime: Runtime, path: []const u8, flags: Io.File.OpenFlags) !Io.File {
    return runtime.io.vtable.openFile(runtime.io.ctx, runtime, path, flags);
}

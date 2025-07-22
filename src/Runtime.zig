const std = @import("std");
const Reactor = @import("Reactor.zig");
const fs = std.fs;

const Runtime = @This();

const FileHandle = opaque {};

ctx: ?*anyopaque,
vtable: *const VTable,

reactor: Reactor,

pub const AnyFuture = struct {
    start: *const fn (arg: *anyopaque) void,
    arg: *anyopaque,
};

pub const VTable = struct {
    /// runtimeutes `start` asynchronously in a manner such that it cleans itself
    /// up. This mode does not support results, await, or cancel.
    ///
    /// Thread-safe.
    spawn: *const fn (
        /// Corresponds to `runtime.ctx`.
        ctx: ?*anyopaque,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) void,
    /// Runs all the futures in parallel, and waits for them all to finish.
    ///
    /// Thread-safe.
    join: *const fn (ctx: ?*anyopaque, futures: []const AnyFuture) void,

    /// Runs all the futures in parallel, and waits for them all to finish.
    /// Its possible that two futures finish at the same time, in which case
    /// the implementation decides which one to return.
    ///
    /// Thread-safe.
    select: *const fn (ctx: ?*anyopaque, futures: []const AnyFuture) usize,

    // Suspends this future until Io wakes it up
    @"suspend": *const fn (ctx: ?*anyopaque) void,

    wake: *const fn (ctx: ?*anyopaque, fut: *anyopaque) void,

    // Pass what you get from this to wake yourself
    getWaker: *const fn (ctx: ?*anyopaque) *anyopaque,

    // Get the local context for io
    getThreadContext: *const fn (ctx: ?*anyopaque) ?*anyopaque,
};

pub fn @"suspend"(runtime: Runtime) void {
    return runtime.vtable.@"suspend"(runtime.ctx);
}

pub fn wake(runtime: Runtime, fut: *anyopaque) void {
    runtime.vtable.wake(runtime.ctx, fut);
}

pub fn getWaker(runtime: Runtime) *anyopaque {
    return runtime.vtable.getWaker(runtime.ctx);
}

pub fn getThreadContext(runtime: Runtime) ?*anyopaque {
    return runtime.vtable.getThreadContext(runtime.ctx);
}

pub fn Future(comptime Fn: anytype) type {
    const fn_info = @typeInfo(@TypeOf(Fn)).@"fn";
    return struct {
        const Self = @This();
        result: fn_info.return_type.?,
        // Maybe async functions get an implcicit frame arguemnt?
        args: std.meta.ArgsTuple(@TypeOf(Fn)),

        pub fn init(args: std.meta.ArgsTuple(@TypeOf(Fn))) Self {
            return .{
                .args = args,
                .result = undefined,
            };
        }

        pub fn any_future(self: *@This()) AnyFuture {
            const TypeErased = struct {
                fn start(arg: *anyopaque) void {
                    const self_casted: *Self = @alignCast(@ptrCast(arg));
                    self_casted.result = @call(.auto, Fn, self_casted.args);
                }
            };
            return .{
                .start = @ptrCast(&TypeErased.start),
                .arg = @ptrCast(self),
            };
        }
    };
}

/// Calls `function` with `args` asynchronously. The resource cleans itself up
/// when the function returns. Does not support await, cancel, or a return value.
pub inline fn spawn(runtime: Runtime, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque) void {
            const args_casted: *const Args = @alignCast(@ptrCast(context));
            @call(.auto, function, args_casted.*);
        }
    };
    runtime.vtable.spawn(runtime.ctx, if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]), std.mem.Alignment.fromByteUnits(@alignOf(Args)), TypeErased.start);
}

pub fn JoinResult(S: anytype) type {
    const struct_fields = @typeInfo(S).@"struct".fields;

    var fields: [struct_fields.len]std.builtin.Type.StructField = undefined;
    for (&fields, struct_fields) |*field, struct_field| {
        const F = @typeInfo(struct_field.type).pointer.child;
        const Result = @TypeOf(@as(F, undefined).result);
        field.* = .{
            .name = struct_field.name,
            .type = Result,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Result),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// `s` is a struct with every field a `*Future(T)`, where `T` can be any type,
/// and can be different for each field.
pub fn join(runtime: Runtime, s: anytype) JoinResult(@TypeOf(s)) {
    const fields = @typeInfo(@TypeOf(s)).@"struct".fields;
    var futures: [fields.len]AnyFuture = undefined;
    inline for (fields, &futures) |field, *any_future| {
        const future = @field(s, field.name);
        any_future.* = future.any_future();
    }
    runtime.vtable.join(runtime.ctx, &futures);

    var result: JoinResult(@TypeOf(s)) = undefined;
    inline for (fields) |field| {
        const future = @field(s, field.name);
        @field(result, field.name) = future.result;
    }
    return result;
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
    var futures: [fields.len]AnyFuture = undefined;
    inline for (fields, &futures) |field, *any_future| {
        const future = @field(s, field.name);
        any_future.* = future.any_future();
    }
    switch (runtime.vtable.select(runtime.ctx, &futures)) {
        inline 0...(fields.len - 1) => |selected_index| {
            const field_name = fields[selected_index].name;
            return @unionInit(U, field_name, @field(s, field_name).result);
        },
        else => unreachable,
    }
}

pub fn open(runtime: Runtime, path: []const u8, flags: Reactor.File.OpenFlags) !Reactor.File {
    return runtime.reactor.vtable.openFile(runtime.reactor.ctx, runtime, path, flags);
}

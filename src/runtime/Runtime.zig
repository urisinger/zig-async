const std = @import("std");
pub const File = @import("File.zig");

pub const net = @import("net.zig");
pub const Server = net.Server;
pub const Stream = net.Stream;

const Runtime = @This();

ctx: ?*anyopaque,
vtable: *const VTable,

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
        result_len: usize,
        result_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) *AnySpawnHandle,

    spawnDetached: *const fn (
        /// Corresponds to `runtime.ctx`.
        ctx: ?*anyopaque,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) void,

    @"await": *const fn (ctx: ?*anyopaque, task: *AnySpawnHandle, result: *anyopaque) void,

    cancel: *const fn (ctx: ?*anyopaque, task: *AnySpawnHandle) void,

    /// Runs all the futures in parallel, and waits for them all to finish.
    ///
    /// Thread-safe.
    join: *const fn (ctx: ?*anyopaque, futures: []AnyFuture) void,
    /// Runs all the futures in parallel, and waits for them all to finish.
    /// Its possible that two futures finish at the same time, in which case
    /// the implementation decides which one to return.
    ///
    /// Thread-safe.
    select: *const fn (ctx: ?*anyopaque, futures: []AnyFuture) usize,

    openFile: *const fn (ctx: ?*anyopaque, path: []const u8, flags: File.OpenFlags) File.OpenError!File,
    closeFile: *const fn (ctx: ?*anyopaque, file: File) void,

    getStdIn: *const fn (ctx: ?*anyopaque) File,

    pread: *const fn (ctx: ?*anyopaque, file: File, buffer: []u8, offset: std.posix.off_t) File.PReadError!usize,
    pwrite: *const fn (ctx: ?*anyopaque, file: File, buffer: []const u8, offset: std.posix.off_t) File.PWriteError!usize,

    listen: *const fn (ctx: ?*anyopaque, address: net.Address, options: Server.ListenOptions) Server.ListenError!Server,
    accept: *const fn (ctx: ?*anyopaque, server: Server) Server.AcceptError!Stream,

    writeStream: *const fn (ctx: ?*anyopaque, stream: Stream, buffer: []const u8) Stream.WriteError!usize,
    writevStream: *const fn (ctx: ?*anyopaque, stream: Stream, iovecs: []const Stream.iovec_const) Stream.WriteError!usize,

    readStream: *const fn (ctx: ?*anyopaque, stream: Stream, buffer: []u8) Stream.ReadError!usize,
    readvStream: *const fn (ctx: ?*anyopaque, stream: Stream, iovecs: []const Stream.iovec) Stream.ReadError!usize,

    closeStream: *const fn (ctx: ?*anyopaque, stream: Stream) void,
    closeServer: *const fn (ctx: ?*anyopaque, server: Server) void,

    sleep: *const fn (ctx: ?*anyopaque, ms: u64) Cancelable!void,
};

pub const AnyFuture = struct {
    start: *const fn (arg: *anyopaque) void,
    arg: *anyopaque,
    metadata: ?*anyopaque,
};

// just a typed wrapper over poller
pub const AnySpawnHandle = opaque {};

pub const Cancelable = error{
    Canceled,
};

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
                .metadata = null,
            };
        }
    };
}

pub fn SpawnHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        handle: *AnySpawnHandle,

        pub fn cancel(self: Self, runtime: Runtime) void {
            runtime.vtable.cancel(runtime.ctx, self.handle);
        }

        pub fn join(self: Self, runtime: Runtime) T {
            var result: T = undefined;
            runtime.vtable.@"await"(runtime.ctx, &self.handle, &result);
            return result;
        }
    };
}

/// Calls `function` with `args` asynchronously. The resource cleans itself up
/// when the function returns. Does not support await, cancel, or a return value.
pub inline fn spawn(runtime: Runtime, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) SpawnHandle(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    const Args = @TypeOf(args);
    const Ret = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const TypeErased = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const args_casted: *const Args = @alignCast(@ptrCast(context));
            const result_casted: *Ret = @alignCast(@ptrCast(result));
            result_casted.* = @call(.auto, function, args_casted.*);
        }
    };
    return .{
        .handle = runtime.vtable.spawn(
            runtime.ctx,
            if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]),
            std.mem.Alignment.fromByteUnits(@alignOf(Args)),
            @sizeOf(Ret),
            std.mem.Alignment.fromByteUnits(@alignOf(Ret)),
            TypeErased.start,
        ),
    };
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
pub inline fn join(runtime: Runtime, s: anytype) JoinResult(@TypeOf(s)) {
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

pub inline fn joinAny(runtime: Runtime, futures: []const AnyFuture) usize {
    return runtime.vtable.join(runtime.ctx, futures);
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
pub inline fn select(runtime: Runtime, s: anytype) SelectUnion(@TypeOf(s)) {
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

pub inline fn selectAny(runtime: Runtime, futures: []const AnyFuture) usize {
    return runtime.vtable.select(runtime.ctx, futures);
}

pub fn open(runtime: Runtime, path: []const u8, flags: File.OpenFlags) !File {
    return runtime.vtable.openFile(runtime.ctx, path, flags);
}

pub fn sleep(runtime: Runtime, ms: u64) Cancelable!void {
    try runtime.vtable.sleep(runtime.ctx, ms);
}

pub fn listen(rt: Runtime, address: net.Address, options: Server.ListenOptions) Server.ListenError!Server {
    return rt.vtable.listen(rt.ctx, address, options);
}

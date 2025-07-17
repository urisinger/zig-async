const std = @import("std");
const fs = std.fs;

const Runtime = @This();

const FileHandle = opaque {};

pub const Io = struct {
    pub const VTable = struct {
        createContext: *const fn (global_ctx: ?*anyopaque) ?*anyopaque,
        onPark: *const fn (global_ctx: ?*anyopaque, runtime: Runtime) void,

        //createFile: *const fn (global_ctx: ?*anyopaque, runtime: runtime, path: []const u8, flags: File.CreateFlags) File.OpenError!File,
        openFile: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, path: []const u8, flags: File.OpenFlags) File.OpenError!File,
        closeFile: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, File) void,
        pread: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, file: File, buffer: []u8, offset: std.posix.off_t) File.PReadError!usize,
        pwrite: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, file: File, buffer: []const u8, offset: std.posix.off_t) File.PWriteError!usize,
    };

    pub const File = struct {
        handle: Handle,
        runtime: Runtime,

        pub const Handle = std.posix.fd_t;

        pub const OpenFlags = fs.File.OpenFlags;
        pub const CreateFlags = fs.File.CreateFlags;

        pub const OpenError = fs.File.OpenError;

        pub fn close(file: File) void {
            return file.runtime.io.vtable.closeFile(file.runtime.io.ctx, file.runtime, file);
        }

        pub const ReadError = fs.File.ReadError;

        pub fn read(file: File, buffer: []u8) ReadError!usize {
            return @errorCast(file.pread(buffer, -1));
        }

        pub const PReadError = fs.File.PReadError;

        pub fn pread(file: File, buffer: []u8, offset: std.posix.off_t) PReadError!usize {
            return file.runtime.io.vtable.pread(file.runtime.io.ctx, file.runtime, file, buffer, offset);
        }

        pub const WriteError = fs.File.WriteError;

        pub fn write(file: File, buffer: []const u8) WriteError!usize {
            return @errorCast(file.pwrite(buffer, -1));
        }

        pub const PWriteError = fs.File.PWriteError;

        pub fn pwrite(file: File, buffer: []const u8, offset: std.posix.off_t) PWriteError!usize {
            return file.runtime.io.vtable.pwrite(file.runtime.io.ctx, file.runtime, file, buffer, offset);
        }

        pub fn writeAll(file: File, bytes: []const u8) WriteError!void {
            var index: usize = 0;
            while (index < bytes.len) {
                index += try file.write(bytes[index..]);
            }
        }

        pub fn readAll(file: File, buffer: []u8) ReadError!usize {
            var index: usize = 0;
            while (index != buffer.len) {
                const amt = try file.read(buffer[index..]);
                if (amt == 0) break;
                index += amt;
            }
            return index;
        }
    };
    ctx: ?*anyopaque,

    vtable: *const @This().VTable,
};

ctx: ?*anyopaque,
vtable: *const VTable,

io: Io,

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
    @"suspend": *const fn (ctx: ?*anyopaque) void,

    wake: *const fn (ctx: ?*anyopaque, fut: *anyopaque) void,

    // Pass what you get from this to wake yourself
    getWaker: *const fn (ctx: ?*anyopaque) *anyopaque,

    // Get the local context for io
    getLocalContext: *const fn (ctx: ?*anyopaque) ?*anyopaque,
};

pub fn @"suspend"(runtime: Runtime) void {
    runtime.vtable.@"suspend"(runtime.ctx);
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
pub inline fn @"async"(runtime: Runtime, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
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
    future.any_future = runtime.vtable.@"async"(
        runtime.ctx,
        if (@sizeOf(Result) == 0) &.{} else @ptrCast((&future.result)[0..1]),
        std.mem.Alignment.fromByteUnits(@alignOf(Result)),
        if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]),
        std.mem.Alignment.fromByteUnits(@alignOf(Args)),
        TypeErased.start,
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

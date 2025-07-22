const std = @import("std");
const Reactor = @import("Reactor.zig");
const fs = std.fs;

const Runtime = @This();

const FileHandle = opaque {};

ctx: ?*anyopaque,
vtable: *const VTable,

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

    openFile: *const fn (ctx: ?*anyopaque, path: []const u8, flags: File.OpenFlags) File.OpenError!File,
    closeFile: *const fn (ctx: ?*anyopaque, file: File) void,
    pread: *const fn (ctx: ?*anyopaque, file: File, buffer: []u8, offset: std.posix.off_t) File.PReadError!usize,
    pwrite: *const fn (ctx: ?*anyopaque, file: File, buffer: []const u8, offset: std.posix.off_t) File.PWriteError!usize,
};

pub const File = struct {
    handle: Handle,

    pub const Handle = std.posix.fd_t;

    pub const OpenFlags = fs.File.OpenFlags;
    pub const CreateFlags = fs.File.CreateFlags;

    pub const OpenError = fs.File.OpenError;

    pub fn close(file: File, runtime: Runtime) void {
        return runtime.vtable.closeFile(runtime.ctx, file);
    }

    pub const ReadError = fs.File.ReadError;

    pub fn read(file: File, runtime: Runtime, buffer: []u8) ReadError!usize {
        return @errorCast(runtime.vtable.pread(runtime.ctx, file, buffer, -1));
    }

    pub const PReadError = fs.File.PReadError;

    pub fn pread(file: File, runtime: Runtime, buffer: []u8, offset: std.posix.off_t) PReadError!usize {
        return runtime.vtable.pread(runtime.ctx, file, buffer, offset);
    }

    pub const WriteError = fs.File.WriteError;

    pub fn write(file: File, runtime: Runtime, buffer: []const u8) WriteError!usize {
        return @errorCast(runtime.vtable.pwrite(runtime.ctx, file, buffer, -1));
    }

    pub const PWriteError = fs.File.PWriteError;

    pub fn pwrite(file: File, runtime: Runtime, buffer: []const u8, offset: std.posix.off_t) PWriteError!usize {
        return runtime.vtable.pwrite(runtime.ctx, file, buffer, offset);
    }

    pub fn writeAll(file: File, runtime: Runtime, bytes: []const u8) WriteError!void {
        var index: usize = 0;
        while (index < bytes.len) {
            index += try runtime.vtable.write(runtime.ctx, file, bytes[index..]);
        }
    }

    pub fn readAll(file: File, runtime: Runtime, buffer: []u8) ReadError!usize {
        var index: usize = 0;
        while (index != buffer.len) {
            const amt = try file.read(runtime, buffer[index..]);
            if (amt == 0) break;
            index += amt;
        }
        return index;
    }
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

pub fn open(runtime: Runtime, path: []const u8, flags: File.OpenFlags) !File {
    return runtime.vtable.openFile(runtime.ctx, path, flags);
}

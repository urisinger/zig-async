const std = @import("std");
const Reactor = @import("Reactor.zig");
const fs = std.fs;

const Runtime = @This();

const FileHandle = opaque {};

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

    joinTask: *const fn (ctx: ?*anyopaque, task: *AnySpawnHandle, result: []u8) void,

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
    pread: *const fn (ctx: ?*anyopaque, file: File, buffer: []u8, offset: std.posix.off_t) *File.AnyReadHandle,
    awaitRead: *const fn (ctx: ?*anyopaque, handle: *File.AnyReadHandle) File.PReadError!usize,
    pwrite: *const fn (ctx: ?*anyopaque, file: File, buffer: []const u8, offset: std.posix.off_t) *File.AnyWriteHandle,
    awaitWrite: *const fn (ctx: ?*anyopaque, handle: *File.AnyWriteHandle) File.PWriteError!usize,

    createSocket: *const fn (ctx: ?*anyopaque, domain: Socket.Domain, protocol: Socket.Protocol) *Socket.AnyCreateHandle,
    awaitCreateSocket: *const fn (ctx: ?*anyopaque, handle: *Socket.AnyCreateHandle) Socket.CreateError!Socket,
    closeSocket: *const fn (ctx: ?*anyopaque, socket: Socket) void,

    bind: *const fn (ctx: ?*anyopaque, socket: Socket, address: *const Socket.Address, length: u32) Socket.BindError!void,
    listen: *const fn (ctx: ?*anyopaque, socket: Socket, backlog: u32) Socket.ListenError!void,

    connect: *const fn (ctx: ?*anyopaque, socket: Socket, address: *const Socket.Address) *Socket.AnyConnectHandle,
    awaitConnect: *const fn (ctx: ?*anyopaque, handle: *Socket.AnyConnectHandle) Socket.ConnectError!void,

    accept: *const fn (ctx: ?*anyopaque, socket: Socket) *Socket.AnyAcceptHandle,
    awaitAccept: *const fn (ctx: ?*anyopaque, handle: *Socket.AnyAcceptHandle) Socket.AcceptError!Socket,

    send: *const fn (ctx: ?*anyopaque, socket: Socket, buffer: []const u8, flags: Socket.SendFlags) *Socket.AnySendHandle,
    awaitSend: *const fn (ctx: ?*anyopaque, handle: *Socket.AnySendHandle) Socket.SendError!usize,
    recv: *const fn (ctx: ?*anyopaque, socket: Socket, buffer: []u8, flags: Socket.RecvFlags) *Socket.AnyRecvHandle,
    awaitRecv: *const fn (ctx: ?*anyopaque, handle: *Socket.AnyRecvHandle) Socket.RecvError!usize,

    sleep: *const fn (ctx: ?*anyopaque, ms: u64) void,
};

pub const Socket = struct {
    handle: Handle,

    pub const Handle = std.posix.socket_t;

    pub const AcceptError = std.posix.AcceptError;

    pub const Domain = enum {
        ipv4,
        ipv6,
        unix,
    };

    pub const Protocol = enum {
        tcp,
        udp,
        default,
    };

    pub const CreateError = std.posix.SocketError;
    pub const BindError = std.posix.BindError;
    pub const ConnectError = std.posix.ConnectError;
    pub const SendError = std.posix.SendError;
    pub const RecvError = std.posix.RecvFromError;
    pub const ListenError = std.posix.ListenError;

    pub const SendFlags = struct {
        dontwait: bool = false,
        more: bool = false,
        nosignal: bool = false,
    };

    pub const RecvFlags = struct {
        dontwait: bool = false,
        peek: bool = false,
        waitall: bool = false,
    };

    pub fn close(socket: Socket, runtime: Runtime) void {
        return runtime.vtable.closeSocket(runtime.ctx, socket);
    }

    pub fn bind(socket: Socket, runtime: Runtime, address: *const Socket.Address, length: u32) BindError!void {
        return runtime.vtable.bind(runtime.ctx, socket, address, length);
    }

    pub fn listen(socket: Socket, runtime: Runtime, backlog: u32) ListenError!void {
        return runtime.vtable.listen(runtime.ctx, socket, backlog);
    }

    pub fn accept(socket: Socket, runtime: Runtime) *AnyAcceptHandle {
        return runtime.vtable.accept(runtime.ctx, socket);
    }

    pub fn send(socket: Socket, runtime: Runtime, buffer: []const u8, flags: SendFlags) *AnySendHandle {
        return runtime.vtable.send(runtime.ctx, socket, buffer, flags);
    }

    pub fn recv(socket: Socket, runtime: Runtime, buffer: []u8, flags: RecvFlags) *AnyRecvHandle {
        return runtime.vtable.recv(runtime.ctx, socket, buffer, flags);
    }

    pub const AnyCreateHandle = opaque {
        pub fn @"await"(self: *AnyCreateHandle, runtime: Runtime) CreateError!Socket {
            return runtime.vtable.awaitCreateSocket(runtime.ctx, self);
        }
    };

    pub const AnyBindHandle = opaque {
        pub fn @"await"(self: *AnyBindHandle, runtime: Runtime) BindError!void {
            return runtime.vtable.awaitBind(runtime.ctx, self);
        }
    };

    pub const AnyAcceptHandle = opaque {
        pub fn @"await"(self: *AnyAcceptHandle, runtime: Runtime) AcceptError!Socket {
            return runtime.vtable.awaitAccept(runtime.ctx, self);
        }
    };

    pub const AnyConnectHandle = opaque {
        pub fn @"await"(self: *AnyConnectHandle, runtime: Runtime) ConnectError!void {
            return runtime.vtable.awaitConnect(runtime.ctx, self);
        }
    };

    pub const AnySendHandle = opaque {
        pub fn @"await"(self: *AnySendHandle, runtime: Runtime) SendError!usize {
            return runtime.vtable.awaitSend(runtime.ctx, self);
        }
    };

    pub const AnyRecvHandle = opaque {
        pub fn @"await"(self: *AnyRecvHandle, runtime: Runtime) RecvError!usize {
            return runtime.vtable.awaitRecv(runtime.ctx, self);
        }
    };

    pub const ReadError = std.net.Stream.ReadError;
    pub const AnyReadHandle = opaque {
        pub fn @"await"(self: *AnyReadHandle, runtime: Runtime) ReadError!usize {
            return runtime.vtable.awaitRead(runtime.ctx, self);
        }
    };
    pub const Address = std.posix.sockaddr;
};

pub const AnySpawnHandle = opaque {};

pub const File = struct {
    handle: Handle,

    pub const Handle = std.posix.fd_t;

    pub const AnyReadHandle = opaque {
        pub fn @"await"(self: *AnyReadHandle, runtime: Runtime) PReadError!usize {
            return runtime.vtable.awaitRead(runtime.ctx, self);
        }
    };

    pub const AnyWriteHandle = opaque {
        pub fn @"await"(self: *AnyWriteHandle, runtime: Runtime) PWriteError!usize {
            return runtime.vtable.awaitWrite(runtime.ctx, self);
        }
    };

    pub const OpenFlags = fs.File.OpenFlags;
    pub const CreateFlags = fs.File.CreateFlags;

    pub const OpenError = fs.File.OpenError;

    pub fn close(file: File, runtime: Runtime) void {
        return runtime.vtable.closeFile(runtime.ctx, file);
    }

    pub const ReadError = fs.File.ReadError;

    pub fn read(file: File, runtime: Runtime, buffer: []u8) *AnyReadHandle {
        return runtime.vtable.pread(runtime.ctx, file, buffer, -1);
    }

    pub const PReadError = fs.File.PReadError;

    pub fn pread(file: File, runtime: Runtime, buffer: []u8, offset: std.posix.off_t) PReadError!usize {
        return runtime.vtable.pread(runtime.ctx, file, buffer, offset);
    }

    pub const WriteError = fs.File.WriteError;

    pub fn write(file: File, runtime: Runtime, buffer: []const u8) *AnyWriteHandle {
        return runtime.vtable.pwrite(runtime.ctx, file, buffer, -1);
    }

    pub const PWriteError = fs.File.PWriteError;

    pub fn pwrite(file: File, runtime: Runtime, buffer: []const u8, offset: std.posix.off_t) *AnyWriteHandle {
        return runtime.vtable.pwrite(runtime.ctx, file, buffer, offset);
    }
};

pub const AnyFuture = struct {
    start: *const fn (arg: *anyopaque) void,
    arg: *anyopaque,
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

pub fn SpawnHandle(comptime Fn: anytype) type {
    const fn_info = @typeInfo(@TypeOf(Fn)).@"fn";
    const Ret = fn_info.return_type.?;

    return struct {
        const Self = @This();
        handle: *AnySpawnHandle,

        pub fn join(self: *const @This(), runtime: Runtime) Ret {
            var result: Ret = undefined;
            runtime.vtable.joinTask(runtime.ctx, self.handle, if (@sizeOf(Ret) == 0) &.{} else @ptrCast((&result)[0..1]));
            return result;
        }
    };
}

/// Calls `function` with `args` asynchronously. The resource cleans itself up
/// when the function returns. Does not support await, cancel, or a return value.
pub inline fn spawn(runtime: Runtime, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) SpawnHandle(function) {
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

pub fn sleep(runtime: Runtime, ms: u64) void {
    runtime.vtable.sleep(runtime.ctx, ms);
}

pub fn createSocket(runtime: Runtime, domain: Socket.Domain, protocol: Socket.Protocol) Socket.CreateError!Socket {
    return runtime.vtable.createSocket(runtime.ctx, domain, protocol).@"await"(runtime);
}

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
    ) AnySpawnHandle,

    cancel: *const fn (ctx: ?*anyopaque, task: AnySpawnHandle) void,

    /// Runs all the futures in parallel, and waits for them all to finish.
    ///
    /// Thread-safe.
    join: *const fn (ctx: ?*anyopaque, futures: []FutureOrPoller) void,
    /// Runs all the futures in parallel, and waits for them all to finish.
    /// Its possible that two futures finish at the same time, in which case
    /// the implementation decides which one to return.
    ///
    /// Thread-safe.
    select: *const fn (ctx: ?*anyopaque, futures: []FutureOrPoller) usize,

    openFile: *const fn (ctx: ?*anyopaque, path: []const u8, flags: File.OpenFlags) File.OpenError!File,
    closeFile: *const fn (ctx: ?*anyopaque, file: File) void,

    getStdIn: *const fn (ctx: ?*anyopaque) File,

    pread: *const fn (ctx: ?*anyopaque, file: File, buffer: []u8, offset: std.posix.off_t) Poller(File.PReadError!usize),
    pwrite: *const fn (ctx: ?*anyopaque, file: File, buffer: []const u8, offset: std.posix.off_t) Poller(File.PWriteError!usize),

    createSocket: *const fn (ctx: ?*anyopaque, domain: Socket.Domain, protocol: Socket.Protocol) Poller(Socket.CreateError!Socket),
    closeSocket: *const fn (ctx: ?*anyopaque, socket: Socket) void,
    setsockopt: *const fn (ctx: ?*anyopaque, socket: Socket, option: Socket.Option) Socket.SetOptError!void,

    bind: *const fn (ctx: ?*anyopaque, socket: Socket, address: *const Socket.Address, length: u32) Socket.BindError!void,
    listen: *const fn (ctx: ?*anyopaque, socket: Socket, backlog: u32) Socket.ListenError!void,

    connect: *const fn (ctx: ?*anyopaque, socket: Socket, address: *const Socket.Address) Poller(Socket.ConnectError!void),

    accept: *const fn (ctx: ?*anyopaque, socket: Socket) Poller(Socket.AcceptError!Socket),

    send: *const fn (ctx: ?*anyopaque, socket: Socket, buffer: []const u8, flags: Socket.SendFlags) Poller(Socket.SendError!usize),
    recv: *const fn (ctx: ?*anyopaque, socket: Socket, buffer: []u8, flags: Socket.RecvFlags) Poller(Socket.RecvError!usize),

    sleep: *const fn (ctx: ?*anyopaque, ms: u64) Cancelable!void,
};

pub const FutureOrPoller = union(enum) {
    future: AnyFuture,
    poller: AnyPoller,
};

pub const AnyPoller = struct {
    poll: *const fn (poller_ctx: ?*anyopaque) bool,
    poller_ctx: ?*anyopaque,

    pub fn any_poller(self: *@This()) AnyPoller {
        return self;
    }
};

pub fn Poller(comptime T: type) type {
    return struct {
        const Self = @This();
        result: T,
        has_result: bool = false,
        poller_ctx: ?*anyopaque,

        poll: *const fn (poller_ctx: ?*anyopaque) ?T,

        pub fn any_poller(self: *@This()) AnyPoller {
            const TypeErased = struct {
                fn poll(poller_ctx: ?*anyopaque) bool {
                    const self_casted: *Self = @alignCast(@ptrCast(poller_ctx));
                    if (self_casted.has_result) {
                        return true;
                    }
                    if (self_casted.poll(self_casted.poller_ctx)) |result| {
                        self_casted.result = result;
                        self_casted.has_result = true;
                        return true;
                    }
                    return false;
                }
            };
            return .{
                .poll = @ptrCast(&TypeErased.poll),
                .poller_ctx = @ptrCast(self),
            };
        }

        pub fn @"await"(self: @This(), runtime: Runtime) T {
            var self_mut = self;
            return runtime.join(.{&self_mut}).@"0";
        }
    };
}

pub const AnyFuture = struct {
    start: *const fn (arg: *anyopaque) void,
    arg: *anyopaque,
    metadata: ?*anyopaque,
};

// just a typed wrapper over poller
pub const AnySpawnHandle = struct {
    pooler: AnyPoller,
};

pub const Cancelable = error{
    Canceled,
};

pub const Socket = struct {
    handle: Handle,

    pub const Handle = std.posix.socket_t;

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

    pub const Option = union(enum) {
        /// Allow reuse of local addresses (SO_REUSEADDR)
        reuseaddr: bool,
        /// Allow reuse of local ports (SO_REUSEPORT)
        reuseport: bool,
        /// Enable keep-alive (SO_KEEPALIVE)
        keepalive: bool,
        /// Receive buffer size (SO_RCVBUF)
        rcvbuf: u32,
        /// Send buffer size (SO_SNDBUF)
        sndbuf: u32,
        /// Receive timeout in milliseconds (SO_RCVTIMEO)
        rcvtimeo: u32,
        /// Send timeout in milliseconds (SO_SNDTIMEO)
        sndtimeo: u32,
        /// Disable Nagle's algorithm (TCP_NODELAY)
        nodelay: bool,
        /// Enable broadcast (SO_BROADCAST)
        broadcast: bool,
    };

    pub const AcceptError = Cancelable || std.posix.AcceptError;
    pub const CreateError = Cancelable || std.posix.SocketError;
    pub const BindError = std.posix.BindError;
    pub const ConnectError = Cancelable || std.posix.ConnectError;
    pub const SendError = Cancelable || std.posix.SendError;
    pub const RecvError = Cancelable || std.posix.RecvFromError;
    pub const ListenError = std.posix.ListenError;
    pub const SetOptError = std.posix.SetSockOptError;

    pub const SendFlags = struct {
        more: bool = false,
        nosignal: bool = false,
    };

    pub const RecvFlags = struct {
        peek: bool = false,
        waitall: bool = false,
    };

    pub fn close(socket: Socket, runtime: Runtime) void {
        return runtime.vtable.closeSocket(runtime.ctx, socket);
    }

    pub fn setsockopt(socket: Socket, runtime: Runtime, option: Socket.Option) SetOptError!void {
        return runtime.vtable.setsockopt(runtime.ctx, socket, option);
    }

    pub fn bind(socket: Socket, runtime: Runtime, address: *const Socket.Address, length: u32) BindError!void {
        return runtime.vtable.bind(runtime.ctx, socket, address, length);
    }

    pub fn listen(socket: Socket, runtime: Runtime, backlog: u32) ListenError!void {
        return runtime.vtable.listen(runtime.ctx, socket, backlog);
    }

    pub fn accept(socket: Socket, runtime: Runtime) Poller(AcceptError!Socket) {
        return runtime.vtable.accept(runtime.ctx, socket);
    }

    pub fn send(socket: Socket, runtime: Runtime, buffer: []const u8, flags: SendFlags) Poller(SendError!usize) {
        return runtime.vtable.send(runtime.ctx, socket, buffer, flags);
    }

    pub fn recv(socket: Socket, runtime: Runtime, buffer: []u8, flags: RecvFlags) Poller(RecvError!usize) {
        return runtime.vtable.recv(runtime.ctx, socket, buffer, flags);
    }

    pub const Address = std.posix.sockaddr;
};

pub const File = struct {
    handle: Handle,

    pub const Handle = std.posix.fd_t;

    pub const OpenFlags = fs.File.OpenFlags;
    pub const CreateFlags = fs.File.CreateFlags;

    pub const OpenError = Cancelable || fs.File.OpenError;

    pub fn close(file: File, runtime: Runtime) void {
        return runtime.vtable.closeFile(runtime.ctx, file);
    }

    pub const ReadError = Cancelable || fs.File.ReadError;

    pub fn read(file: File, runtime: Runtime, buffer: []u8) Poller(ReadError!usize) {
        return runtime.vtable.pread(runtime.ctx, file, buffer, -1);
    }

    pub const PReadError = Cancelable || fs.File.PReadError;

    pub fn pread(file: File, runtime: Runtime, buffer: []u8, offset: std.posix.off_t) PReadError!usize {
        return runtime.vtable.pread(runtime.ctx, file, buffer, offset);
    }

    pub const WriteError = Cancelable || fs.File.WriteError;

    pub fn write(file: File, runtime: Runtime, buffer: []const u8) Poller(WriteError!usize) {
        return runtime.vtable.pwrite(runtime.ctx, file, buffer, -1);
    }

    pub const PWriteError = Cancelable || fs.File.PWriteError;

    pub fn pwrite(file: File, runtime: Runtime, buffer: []const u8, offset: std.posix.off_t) Poller(PWriteError!usize) {
        return runtime.vtable.pwrite(runtime.ctx, file, buffer, offset);
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
                .metadata = null,
            };
        }
    };
}

pub fn SpawnHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        handle: AnySpawnHandle,
        result: T,

        pub fn any_poller(self: Self) AnyPoller {
            return self.handle.pooler;
        }

        pub fn cancel(self: Self, runtime: Runtime) void {
            runtime.vtable.cancel(runtime.ctx, self.handle);
        }

        pub fn join(self: Self, runtime: Runtime) T {
            return runtime.join(.{&self}).@"0";
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
        .result = undefined,
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
    var futures: [fields.len]FutureOrPoller = undefined;
    inline for (fields, &futures) |field, *any_future| {
        const future = @field(s, field.name);
        if (@hasDecl(@typeInfo(@TypeOf(future)).pointer.child, "any_future")) {
            any_future.* = .{ .future = future.any_future() };
        } else {
            any_future.* = .{ .poller = future.any_poller() };
        }
    }
    runtime.vtable.join(runtime.ctx, &futures);

    var result: JoinResult(@TypeOf(s)) = undefined;
    inline for (fields) |field| {
        const future = @field(s, field.name);
        @field(result, field.name) = future.result;
    }
    return result;
}

pub inline fn joinAny(runtime: Runtime, futures: []const FutureOrPoller) usize {
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
    var futures: [fields.len]FutureOrPoller = undefined;
    inline for (fields, &futures) |field, *any_future| {
        const future = @field(s, field.name);
        if (@hasDecl(@typeInfo(@TypeOf(future)).pointer.child, "any_future")) {
            any_future.* = .{ .future = future.any_future() };
        } else {
            any_future.* = .{ .poller = future.any_poller() };
        }
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

pub fn createSocket(runtime: Runtime, domain: Socket.Domain, protocol: Socket.Protocol) Socket.CreateError!Socket {
    var pooler = runtime.vtable.createSocket(runtime.ctx, domain, protocol);
    return runtime.join(.{&pooler}).@"0";
}

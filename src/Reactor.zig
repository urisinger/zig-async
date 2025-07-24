const std = @import("std");
const Runtime = @import("Runtime.zig");
const File = @import("Runtime.zig").File;
const Socket = @import("Runtime.zig").Socket;
const Cancelable = @import("Runtime.zig").Cancelable;

const fs = std.fs;

pub const Executer = struct {
    pub const VTable = struct {
        getThreadContext: *const fn (ctx: ?*anyopaque) ?*anyopaque,
        getWaker: *const fn (ctx: ?*anyopaque) *anyopaque,
        wake: *const fn (ctx: ?*anyopaque, waker: *anyopaque) void,
        @"suspend": *const fn (ctx: ?*anyopaque) bool,
    };

    vtable: *const Executer.VTable,
    ctx: ?*anyopaque,

    pub fn getThreadContext(self: Executer) ?*anyopaque {
        return self.vtable.getThreadContext(self.ctx);
    }

    pub fn getWaker(self: Executer) *anyopaque {
        return self.vtable.getWaker(self.ctx);
    }

    pub fn wake(self: Executer, waker: *anyopaque) void {
        self.vtable.wake(self.ctx, waker);
    }

    pub fn @"suspend"(self: Executer) bool {
        return self.vtable.@"suspend"(self.ctx);
    }
};

pub const VTable = struct {
    // Create a thread context.
    createContext: *const fn (global_ctx: ?*anyopaque) ?*anyopaque,
    // Destroy a thread context.
    destroyContext: *const fn (global_ctx: ?*anyopaque, context: ?*anyopaque) void,
    // Called when a thread has no more work to do, should block until it wakes up a task or until it gets work to do.
    onPark: *const fn (global_ctx: ?*anyopaque, executer: Executer) void,

    // if cur_thread_ctx is null, the wakeThread is called from a thread that does not have a context.
    wakeThread: *const fn (global_ctx: ?*anyopaque, cur_thread_ctx: ?*anyopaque, other_thread_ctx: ?*anyopaque) void,

    //createFile: *const fn (global_ctx: ?*anyopaque, executer: Executer, path: []const u8, flags: File.CreateFlags) File.OpenError!File,
    openFile: *const fn (global_ctx: ?*anyopaque, executer: Executer, path: []const u8, flags: File.OpenFlags) File.OpenError!File,
    closeFile: *const fn (global_ctx: ?*anyopaque, executer: Executer, File) void,

    getStdIn: *const fn (global_ctx: ?*anyopaque, executer: Executer) File,

    pread: *const fn (global_ctx: ?*anyopaque, executer: Executer, file: File, buffer: []u8, offset: std.posix.off_t) *File.AnyReadHandle,
    awaitRead: *const fn (global_ctx: ?*anyopaque, executer: Executer, handle: *File.AnyReadHandle) File.PReadError!usize,

    pwrite: *const fn (global_ctx: ?*anyopaque, executer: Executer, file: File, buffer: []const u8, offset: std.posix.off_t) *File.AnyWriteHandle,
    awaitWrite: *const fn (global_ctx: ?*anyopaque, executer: Executer, handle: *File.AnyWriteHandle) File.PWriteError!usize,

    createSocket: *const fn (global_ctx: ?*anyopaque, executer: Executer, domain: Socket.Domain, protocol: Socket.Protocol) *Socket.AnyCreateHandle,
    awaitCreateSocket: *const fn (global_ctx: ?*anyopaque, executer: Executer, handle: *Socket.AnyCreateHandle) Socket.CreateError!Socket,
    closeSocket: *const fn (global_ctx: ?*anyopaque, executer: Executer, socket: Socket) void,

    bind: *const fn (global_ctx: ?*anyopaque, executer: Executer, socket: Socket, address: *const Socket.Address, length: u32) Socket.BindError!void,
    listen: *const fn (global_ctx: ?*anyopaque, executer: Executer, socket: Socket, backlog: u32) Socket.ListenError!void,

    connect: *const fn (global_ctx: ?*anyopaque, executer: Executer, socket: Socket, address: *const Socket.Address) *Socket.AnyConnectHandle,
    awaitConnect: *const fn (global_ctx: ?*anyopaque, executer: Executer, handle: *Socket.AnyConnectHandle) Socket.ConnectError!void,

    accept: *const fn (global_ctx: ?*anyopaque, executer: Executer, socket: Socket) *Socket.AnyAcceptHandle,
    awaitAccept: *const fn (global_ctx: ?*anyopaque, executer: Executer, handle: *Socket.AnyAcceptHandle) Socket.AcceptError!Socket,

    send: *const fn (global_ctx: ?*anyopaque, executer: Executer, socket: Socket, buffer: []const u8, flags: Socket.SendFlags) *Socket.AnySendHandle,
    awaitSend: *const fn (global_ctx: ?*anyopaque, executer: Executer, handle: *Socket.AnySendHandle) Socket.SendError!usize,
    recv: *const fn (global_ctx: ?*anyopaque, executer: Executer, socket: Socket, buffer: []u8, flags: Socket.RecvFlags) *Socket.AnyRecvHandle,
    awaitRecv: *const fn (global_ctx: ?*anyopaque, executer: Executer, handle: *Socket.AnyRecvHandle) Socket.RecvError!usize,

    sleep: *const fn (global_ctx: ?*anyopaque, executer: Executer, timestamp: u64) Cancelable!void,
};
ctx: ?*anyopaque,

vtable: *const @This().VTable,

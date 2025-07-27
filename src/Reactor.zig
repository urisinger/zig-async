const std = @import("std");
const Runtime = @import("runtime/Runtime.zig");
const File = Runtime.File;
const Cancelable = Runtime.Cancelable;

const fs = std.fs;

const net = Runtime.net;
const Server = net.Server;
const Stream = net.Stream;

pub const Executer = struct {
    pub const VTable = struct {
        getThreadContext: *const fn (ctx: ?*anyopaque) ?*anyopaque,
        getWaker: *const fn (ctx: ?*anyopaque) *anyopaque,
        wake: *const fn (ctx: ?*anyopaque, waker: *anyopaque) void,
        @"suspend": *const fn (ctx: ?*anyopaque) bool,

        isCanceled: *const fn (ctx: ?*anyopaque) bool,
    };

    vtable: *const Executer.VTable,
    ctx: ?*anyopaque,

    pub fn getThreadContext(self: Executer) ?*anyopaque {
        return self.vtable.getThreadContext(self.ctx);
    }

    pub fn getWaker(self: Executer) *anyopaque {
        return self.vtable.getWaker(self.ctx);
    }

    pub fn @"suspend"(self: Executer) bool {
        return self.vtable.@"suspend"(self.ctx);
    }

    pub fn wake(self: Executer, waker: *anyopaque) void {
        self.vtable.wake(self.ctx, waker);
    }

    pub fn isCanceled(self: Executer) bool {
        return self.vtable.isCanceled(self.ctx);
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

    pread: *const fn (global_ctx: ?*anyopaque, executer: Executer, file: File, buffer: []u8, offset: std.posix.off_t) File.PReadError!usize,

    pwrite: *const fn (global_ctx: ?*anyopaque, executer: Executer, file: File, buffer: []const u8, offset: std.posix.off_t) File.PWriteError!usize,

    listen: *const fn (global_ctx: ?*anyopaque, executer: Executer, address: net.Address, options: Server.ListenOptions) Server.ListenError!Server,
    accept: *const fn (global_ctx: ?*anyopaque, executer: Executer, server: Server) Server.AcceptError!Stream,

    writeStream: *const fn (global_ctx: ?*anyopaque, executer: Executer, stream: Stream, buffer: []const u8) Stream.WriteError!usize,
    writevStream: *const fn (global_ctx: ?*anyopaque, executer: Executer, stream: Stream, iovecs: []const Stream.iovec_const) Stream.WriteError!usize,

    readStream: *const fn (global_ctx: ?*anyopaque, executer: Executer, stream: Stream, buffer: []u8) Stream.ReadError!usize,
    readvStream: *const fn (global_ctx: ?*anyopaque, executer: Executer, stream: Stream, iovecs: []const Stream.iovec) Stream.ReadError!usize,

    closeStream: *const fn (global_ctx: ?*anyopaque, executer: Executer, stream: Stream) void,
    closeServer: *const fn (global_ctx: ?*anyopaque, executer: Executer, server: Server) void,

    sleep: *const fn (global_ctx: ?*anyopaque, executer: Executer, timestamp: u64) Cancelable!void,
};
ctx: ?*anyopaque,

vtable: *const @This().VTable,

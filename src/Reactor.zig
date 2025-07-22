const std = @import("std");
const Runtime = @import("Runtime.zig");

const fs = std.fs;

pub const VTable = struct {
    // Create a thread context.
    createContext: *const fn (global_ctx: ?*anyopaque) ?*anyopaque,
    // Destroy a thread context.
    destroyContext: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, context: ?*anyopaque) void,
    onPark: *const fn (global_ctx: ?*anyopaque, runtime: Runtime) bool,
    signalExit: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, signaled_thread: ?*anyopaque) void,

    // wake up another thread
    wakeThread: *const fn (global_ctx: ?*anyopaque, cur_thread_ctx: ?*anyopaque, other_thread_ctx: ?*anyopaque) void,

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
        return file.runtime.reactor.vtable.closeFile(file.runtime.reactor.ctx, file.runtime, file);
    }

    pub const ReadError = fs.File.ReadError;

    pub fn read(file: File, buffer: []u8) ReadError!usize {
        return @errorCast(file.pread(buffer, -1));
    }

    pub const PReadError = fs.File.PReadError;

    pub fn pread(file: File, buffer: []u8, offset: std.posix.off_t) PReadError!usize {
        return file.runtime.reactor.vtable.pread(file.runtime.reactor.ctx, file.runtime, file, buffer, offset);
    }

    pub const WriteError = fs.File.WriteError;

    pub fn write(file: File, buffer: []const u8) WriteError!usize {
        return @errorCast(file.pwrite(buffer, -1));
    }

    pub const PWriteError = fs.File.PWriteError;

    pub fn pwrite(file: File, buffer: []const u8, offset: std.posix.off_t) PWriteError!usize {
        return file.runtime.reactor.vtable.pwrite(file.runtime.reactor.ctx, file.runtime, file, buffer, offset);
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

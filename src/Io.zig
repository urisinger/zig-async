const std = @import("std");
const Runtime = @import("Runtime.zig");

const fs = std.fs;

const Cancelable = Runtime.Cancelable;

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

    pub const OpenError = Cancelable || fs.File.OpenError;

    pub fn close(file: File) void {
        return file.runtime.io.vtable.closeFile(file.runtime.io.ctx, file.runtime, file);
    }

    pub const ReadError = Cancelable || fs.File.ReadError;

    pub fn read(file: File, buffer: []u8) ReadError!usize {
        return @errorCast(file.pread(buffer, -1));
    }

    pub const PReadError = Cancelable || fs.File.PReadError;

    pub fn pread(file: File, buffer: []u8, offset: std.posix.off_t) PReadError!usize {
        return file.runtime.io.vtable.pread(file.runtime.io.ctx, file.runtime, file, buffer, offset);
    }

    pub const WriteError = Cancelable || fs.File.WriteError;

    pub fn write(file: File, buffer: []const u8) WriteError!usize {
        return @errorCast(file.pwrite(buffer, -1));
    }

    pub const PWriteError = Cancelable || fs.File.PWriteError;

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

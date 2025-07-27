const std = @import("std");
const posix = std.posix;

const fs = std.fs;

const Runtime = @import("Runtime.zig");
const Cancelable = Runtime.Cancelable;
const File = @This();

handle: Handle,

pub const Handle = std.posix.fd_t;

pub const OpenFlags = fs.File.OpenFlags;
pub const CreateFlags = fs.File.CreateFlags;

pub const OpenError = Cancelable || fs.File.OpenError;

pub fn close(file: File, runtime: Runtime) void {
    return runtime.vtable.closeFile(runtime.ctx, file);
}

pub const ReadError = Cancelable || fs.File.ReadError;

pub fn read(file: File, runtime: Runtime, buffer: []u8) ReadError!usize {
    return runtime.vtable.pread(runtime.ctx, file, buffer, -1);
}

pub const PReadError = Cancelable || fs.File.PReadError;

pub fn pread(file: File, runtime: Runtime, buffer: []u8, offset: std.posix.off_t) PReadError!usize {
    return runtime.vtable.pread(runtime.ctx, file, buffer, offset);
}

pub const WriteError = Cancelable || fs.File.WriteError;

pub fn write(file: File, runtime: Runtime, buffer: []const u8) WriteError!usize {
    return runtime.vtable.pwrite(runtime.ctx, file, buffer, -1);
}

pub const PWriteError = Cancelable || fs.File.PWriteError;

pub fn pwrite(file: File, runtime: Runtime, buffer: []const u8, offset: std.posix.off_t) PWriteError!usize {
    return runtime.vtable.pwrite(runtime.ctx, file, buffer, offset);
}

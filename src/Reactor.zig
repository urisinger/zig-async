const std = @import("std");
const Runtime = @import("Runtime.zig");
const File = @import("Runtime.zig").File;

const fs = std.fs;

pub const VTable = struct {
    // Create a thread context.
    createContext: *const fn (global_ctx: ?*anyopaque) ?*anyopaque,
    // Destroy a thread context.
    destroyContext: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, context: ?*anyopaque) void,
    onPark: *const fn (global_ctx: ?*anyopaque, runtime: Runtime) void,

    // wake up another thread
    wakeThread: *const fn (global_ctx: ?*anyopaque, cur_thread_ctx: ?*anyopaque, other_thread_ctx: ?*anyopaque) void,

    //createFile: *const fn (global_ctx: ?*anyopaque, runtime: runtime, path: []const u8, flags: File.CreateFlags) File.OpenError!File,
    openFile: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, path: []const u8, flags: File.OpenFlags) File.OpenError!File,
    closeFile: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, File) void,
    pread: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, file: File, buffer: []u8, offset: std.posix.off_t) File.PReadError!usize,
    pwrite: *const fn (global_ctx: ?*anyopaque, runtime: Runtime, file: File, buffer: []const u8, offset: std.posix.off_t) File.PWriteError!usize,
};
ctx: ?*anyopaque,

vtable: *const @This().VTable,

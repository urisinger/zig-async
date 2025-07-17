const std = @import("std");
const Exec = @import("Exec.zig");

const log = std.log.scoped(.EventLoop);

const IoUring = std.os.linux.IoUring;
const Allocator = std.mem.Allocator;

const EventLoop = @This();

const io_uring_entries = 64;

allocator: Allocator,

const ThreadContext = struct {
    event_loop: *EventLoop,
    io_uring: IoUring,

    pub fn init(event_loop: *EventLoop) ThreadContext {
        return .{ .io_uring = IoUring.init(io_uring_entries, 0) catch unreachable, .event_loop = event_loop };
    }
};

pub fn createContext(global_ctx: ?*anyopaque) ?*anyopaque {
    const event_loop: *EventLoop = @alignCast(@ptrCast(global_ctx));

    const thread_ctx = event_loop.allocator.create(ThreadContext) catch unreachable;
    thread_ctx.* = ThreadContext.init(event_loop);

    log.info("Created event loop context", .{});

    return @ptrCast(thread_ctx);
}

pub fn init(allocator: Allocator) EventLoop {
    return .{
        .allocator = allocator,
    };
}

const File = struct {
    handle: Handle,
    waker: *anyopaque,

    pub const Handle = std.posix.fd_t;
};

// File operation structures for async operations
const FileOperation = struct {
    waker: *anyopaque,
    completed: bool = false,
    result: union(enum) {
        success: usize, // bytes read/written
        err: std.posix.WriteError,
    } = .{ .success = 0 },
};

const ReadOperation = struct {
    base: FileOperation,
    fd: std.posix.fd_t,
    buffer: []u8,
    offset: u64,
};

const WriteOperation = struct {
    base: FileOperation,
    fd: std.posix.fd_t,
    buffer: []const u8,
    offset: u64,
};

// Open file asynchronously
pub fn openFile(exec: Exec, path: []const u8, flags: std.posix.O, mode: std.posix.mode_t) !File {
    // For file opening, we can do it synchronously since it's usually fast
    // In a real implementation, you might want to use io_uring's IORING_OP_OPENAT
    const fd = try std.posix.open(path, flags, mode);

    return File{
        .handle = fd,
        .waker = exec.getWaker(),
    };
}

// Async file read
pub fn readFile(exec: Exec, file: File, buffer: []u8, offset: u64) !usize {
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getLocalContext()));

    // Create read operation
    const read_op: ReadOperation = .{
        .base = FileOperation{
            .waker = file.waker,
        },
        .fd = file.handle,
        .buffer = buffer,
        .offset = offset,
    };

    // Submit read operation to io_uring
    const sqe = try thread_ctx.io_uring.get_sqe();
    sqe.prep_read(file.handle, buffer, offset);
    sqe.user_data = @intFromPtr(&read_op);

    exec.@"suspend"();

    switch (read_op.base.result) {
        .success => |bytes_read| return bytes_read,
        .err => |err| return err,
    }
}

// Async file write
pub fn writeFile(exec: Exec, file: File, buffer: []const u8, offset: u64) !usize {
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getLocalContext()));

    var write_op = WriteOperation{
        .base = FileOperation{
            .waker = file.waker,
        },
        .fd = file.handle,
        .buffer = buffer,
        .offset = offset,
    };

    // Submit write operation to io_uring
    const sqe = try thread_ctx.io_uring.get_sqe();
    sqe.prep_write(file.handle, buffer, offset);
    sqe.user_data = @intFromPtr(&write_op);

    // Suspend until the operation completes
    exec.@"suspend"();

    switch (write_op.base.result) {
        .success => |bytes_written| return bytes_written,
        .err => |err| return err,
    }
}

// Close file
pub fn closeFile(file: File) void {
    std.posix.close(file.handle);
}

pub fn io(el: *EventLoop) Exec.Io {
    return .{
        .ctx = el,
        .onPark = &onPark,
        .createContext = createContext,
    };
}

fn onPark(global_ctx: ?*anyopaque, exec: Exec) void {
    const event_loop: *EventLoop = @alignCast(@ptrCast(global_ctx));
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(exec.getLocalContext()));

    log.info("parked", .{});

    const io_uring = &thread_ctx.io_uring;

    // Check if there are any pending submissions
    const pending_submissions = io_uring.sq_ready();
    if (pending_submissions == 0) {
        event_loop.allocator.destroy(thread_ctx);
        return;
    }

    // Submit pending operations and wait for at least one completion
    _ = thread_ctx.io_uring.submit_and_wait(1) catch unreachable;

    // Wait for completion events
    var cqes: [io_uring_entries]std.os.linux.io_uring_cqe = undefined;
    const completed = io_uring.copy_cqes(&cqes, 1) catch {
        log.err("Failed to get completion events", .{});
        return;
    };

    // Process completed operations
    for (cqes[0..completed]) |cqe| {
        const user_data = cqe.user_data;
        if (user_data == 0) continue;

        // Cast back to our operation struct
        const base_op: *FileOperation = @ptrFromInt(user_data);

        // Set the result based on the completion event
        if (cqe.res >= 0) {
            base_op.result = .{ .success = @intCast(cqe.res) };
        } else {
            const errno = @as(std.posix.E, @enumFromInt(-cqe.res));
            base_op.result = .{ .err = std.posix.unexpectedErrno(errno) };
        }

        base_op.completed = true;

        // Wake up the suspended future
        exec.wake(base_op.waker);
    }
}

// Utility functions for common file operations

// Read entire file into allocated buffer
pub fn readFileAlloc(exec: Exec, allocator: Allocator, path: []const u8) ![]u8 {
    const file = try openFile(exec, path, .{}, 0);
    defer closeFile(file);

    // Get file size
    const stat = try std.posix.fstat(file.handle);
    const file_size = @as(usize, @intCast(stat.size));

    // Allocate buffer
    const buffer = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buffer);

    // Read the entire file
    const bytes_read = try readFile(exec, file, buffer, 0);

    if (bytes_read != file_size) {
        allocator.free(buffer);
        return error.IncompleteRead;
    }

    return buffer;
}

// Write entire buffer to file
pub fn writeFileAll(exec: Exec, path: []const u8, data: []const u8) !void {
    const file = try openFile(exec, path, .{ .WRONLY = true, .CREAT = true, .TRUNC = true }, 0o644);
    defer closeFile(file);

    var offset: u64 = 0;
    var remaining = data;

    while (remaining.len > 0) {
        const bytes_written = try writeFile(exec, file, remaining, offset);
        offset += bytes_written;
        remaining = remaining[bytes_written..];
    }
}

const std = @import("std");
const Runtime = @import("Runtime.zig");
const Io = @import("Io.zig");

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

    return @ptrCast(thread_ctx);
}

pub fn init(allocator: Allocator) EventLoop {
    return .{
        .allocator = allocator,
    };
}

// File operation structures for async operations
const Operation = struct {
    waker: *anyopaque,
    result: i32,
};

const vtable: Io.VTable = .{
    .createContext = createContext,
    .onPark = onPark,
    .openFile = openFile,
    .closeFile = closeFile,
    .pread = pread,
    .pwrite = pwrite,
    .wakeThread = wakeThread,
};

pub fn io(el: *EventLoop) Io {
    return .{
        .ctx = el,
        .vtable = &vtable,
    };
}

// Open file asynchronously
pub fn openFile(ctx: ?*anyopaque, rt: Runtime, path: []const u8, flags: Io.File.OpenFlags) Io.File.OpenError!Io.File {
    _ = ctx;
    var os_flags: std.posix.O = .{
        .ACCMODE = switch (flags.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
    };

    if (@hasField(std.posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) os_flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) os_flags.NOCTTY = !flags.allow_ctty;

    const fd = try std.posix.open(path, os_flags, 0);

    return .{
        .handle = fd,
        .runtime = rt,
    };
}

// Async file read
pub fn pread(ctx: ?*anyopaque, rt: Runtime, file: Io.File, buffer: []u8, offset: std.posix.off_t) Io.File.PReadError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(rt.getLocalContext()));

    // Create read operation
    const read_op: Operation = .{
        .waker = rt.getWaker(),
        .result = 0,
    };

    // Submit read operation to io_uring
    const sqe = thread_ctx.io_uring.get_sqe() catch {
        return error.SystemResources;
    };

    sqe.prep_read(file.handle, buffer, @bitCast(offset));
    sqe.user_data = @intFromPtr(&read_op);

    rt.@"suspend"() catch {
        sqe.prep_cancel(0, 0);
        return error.Canceled;
    };

    switch (errno(read_op.result)) {
        .SUCCESS => return @as(u32, @bitCast(read_op.result)),
        .INTR => unreachable,
        .CANCELED => return error.Canceled,

        .INVAL => unreachable,
        .FAULT => unreachable,
        .NOENT => return error.ProcessNotFound,
        .AGAIN => return error.WouldBlock,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

// Async file write
pub fn pwrite(ctx: ?*anyopaque, rt: Runtime, file: Io.File, buffer: []const u8, offset: std.posix.off_t) Io.File.PWriteError!usize {
    _ = ctx;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(rt.getLocalContext()));

    var write_op: Operation = .{
        .waker = rt.getWaker(),
        .result = 0,
    };

    // Submit write operation to io_uring
    const sqe = thread_ctx.io_uring.get_sqe() catch {
        return error.SystemResources;
    };
    sqe.prep_write(file.handle, buffer, @bitCast(offset));
    sqe.user_data = @intFromPtr(&write_op);

    // Suspend until the operation completes
    rt.@"suspend"() catch {
        sqe.prep_cancel(0, 0);
        return error.Canceled;
    };

    switch (errno(write_op.result)) {
        .SUCCESS => return @as(u32, @bitCast(write_op.result)),
        .INTR => unreachable,
        .INVAL => unreachable,
        .FAULT => unreachable,
        .AGAIN => unreachable,
        .BADF => return error.NotOpenForWriting, // can be a race condition.
        .DESTADDRREQ => unreachable, // `connect` was never called.
        .DQUOT => return error.DiskQuota,
        .FBIG => return error.FileTooBig,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .PERM => return error.AccessDenied,
        .PIPE => return error.BrokenPipe,
        .NXIO => return error.Unseekable,
        .SPIPE => return error.Unseekable,
        .OVERFLOW => return error.Unseekable,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

// Close file
pub fn closeFile(ctx: ?*anyopaque, rt: Runtime, file: Io.File) void {
    _ = ctx;
    _ = rt;
    std.posix.close(file.handle);
}

// Magic value to distinguish wake-up messages from regular I/O operations
// Using a large value that won't conflict with normal I/O lengths
const WAKE_TASK_MAGIC: u32 = 0xDEADBEEF;

fn wakeThread(global_ctx: ?*anyopaque, rt: Runtime, other_thread_ctx: ?*anyopaque, task: *anyopaque) void {
    _ = global_ctx;
    std.log.info("waking thread", .{});
    const other_thread: *ThreadContext = @alignCast(@ptrCast(other_thread_ctx));
    const cur_thread: *ThreadContext = @alignCast(@ptrCast(rt.getLocalContext()));

    const sqe = cur_thread.io_uring.get_sqe() catch {
        @panic("failed to get sqe");
    };

    std.log.info("other_thread: {}", .{@intFromPtr(other_thread)});

    if (other_thread == cur_thread) {
        std.log.info("waking thread on same thread", .{});
        rt.wake(task);
        return;
    }

    std.log.info("fd: {}", .{other_thread.io_uring.fd});

    sqe.prep_rw(.MSG_RING, other_thread.io_uring.fd, 0, WAKE_TASK_MAGIC, @intFromPtr(task));
}

fn onPark(global_ctx: ?*anyopaque, rt: Runtime) void {
    const event_loop: *EventLoop = @alignCast(@ptrCast(global_ctx));
    _ = event_loop;
    const thread_ctx: *ThreadContext = @alignCast(@ptrCast(rt.getLocalContext()));

    log.info("parked", .{});

    const io_uring = &thread_ctx.io_uring;

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

        // If the user data is 0, skip this entry
        std.log.info("0x{x}, e: 0x{x}", .{
            @as(u32, @bitCast(cqe.res)),
            cqe.user_data,
        });

        // Check if this is a wake-up message by looking at the len field in the result
        // For wake-up messages, the len field contains our magic value
        if (@as(u32, @bitCast(cqe.res)) == WAKE_TASK_MAGIC) {
            // This is a wake-up message, the user_data contains the task pointer
            const task: *anyopaque = @ptrFromInt(user_data);
            rt.wake(task);
            break;
        }

        // Regular I/O operation completion
        const base_op: *Operation = @ptrFromInt(user_data);

        // Set the result based on the completion event
        base_op.result = cqe.res;

        // Wake up the suspended future
        rt.wake(base_op.waker);
    }
}

fn errno(signed: i32) std.posix.E {
    return std.posix.errno(@as(isize, signed));
}

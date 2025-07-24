const std = @import("std");
const builtin = @import("builtin");

pub const Context = switch (builtin.cpu.arch) {
    .x86_64 => packed struct {
        rsp: u64 = 0,
        rbp: u64 = 0,
        rip: u64 = 0,

        pub fn init(entry_rip: usize, stack: usize) @This() {
            return .{
                .rsp = stack - 8,
                .rbp = 0,
                .rip = entry_rip,
            };
        }
    },
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
};

pub fn contextSwitch(old_ctx: *Context, new_ctx: *const Context) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
        // Save current context
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq $ret, 16(%%rax)

            // Restore new context
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx) // jump to RIP
            \\ ret:
            :
            : [old] "{rax}" (old_ctx),
              [new] "{rcx}" (new_ctx),
            : "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "fpsr", "fpcr", "mxcsr", "rflags", "dirflag", "memory"
        ),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    }
}

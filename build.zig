const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_mod.addImport("zig_io", lib_mod);

    // Build static library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig_io",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Export module for other projects
    _ = b.addModule("zig_io", .{
        .root_source_file = b.path("src/main.zig"),
    });

    // Echo example executable
    const echo_exe = b.addExecutable(.{
        .name = "echo",
        .root_source_file = b.path("examples/echo.zig"),
        .target = target,
        .optimize = optimize,
    });
    echo_exe.root_module.addImport("zig_io", lib_mod);
    b.installArtifact(echo_exe);

    // Echo run command
    const run_echo_cmd = b.addRunArtifact(echo_exe);
    if (b.args) |args| {
        run_echo_cmd.addArgs(args);
    }

    const run_echo_step = b.step("echo", "Run the echo server example");
    run_echo_step.dependOn(&run_echo_cmd.step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "scimcheck",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run scimcheck");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const fmt_paths: []const []const u8 = &.{ "src", "build.zig", "build.zig.zon" };
    const fmt_step = b.step("fmt", "Format the source");
    fmt_step.dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);

    const lint_step = b.step("lint", "Check formatting");
    lint_step.dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);

    const ci_step = b.step("ci", "Run lint, tests and build, as CI does");
    ci_step.dependOn(lint_step);
    ci_step.dependOn(test_step);
    ci_step.dependOn(b.getInstallStep());
}

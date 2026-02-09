const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const build_zon = @import("build.zig.zon");

fn getGitCommitHash(allocator: Allocator) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
    }) catch return null;
    if (result.term == .Exited and result.term.Exited == 0) {
        return std.mem.trim(u8, result.stdout, "\n\r ");
    }
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const toml = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    const git_commit = b.option([]const u8, "git_commit", "Current git commit")
        orelse getGitCommitHash(b.allocator)
        orelse @panic("Could not retrieve current git commit");
    assert(git_commit.len != 0);
    options.addOption([]const u8, "git_commit", git_commit);
    options.addOption([]const u8, "version", build_zon.version);

    const mod = b.addModule("slim_down", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const exe = b.addExecutable(.{
        .name = "slim-down",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "slim_down", .module = mod },
                .{ .name = "build_info", .module = options.createModule() },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "toml", .module = toml.module("toml") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const integration_options = b.addOptions();
    integration_options.addOptionPath("exe_path", exe.getEmittedBin());
    integration_tests.root_module.addOptions("build_options", integration_options);

    const run_integration = b.addRunArtifact(integration_tests);
    const integration_step = b.step("integration", "Run integration tests");
    integration_step.dependOn(&run_integration.step);
}

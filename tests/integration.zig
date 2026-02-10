const std = @import("std");
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const build_options = @import("build_options");

test "basic deletion" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "keep.txt", .data = "keep" });
    try tmp.dir.writeFile(.{ .sub_path = "delete.log", .data = "delete" });

    const exe_path = build_options.exe_path;

    const absolute_exe_path = try std.fs.cwd().realpathAlloc(allocator, exe_path);
    defer allocator.free(absolute_exe_path);

    var child = std.process.Child.init(&[_][]const u8{
        absolute_exe_path,
        "-r",
        "*.log",
        "--no-config",
    }, allocator);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    child.cwd = tmp_path;

    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    try expectEqual(std.process.Child.Term{ .Exited = 0 }, term);

    _ = try tmp.dir.statFile("keep.txt");

    try expectError(error.FileNotFound, tmp.dir.statFile("delete.log"));
}

test "ignore patterns" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "important.log", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "garbage.log", .data = "" });

    try runSlimDown(allocator, tmp.dir, &.{ "-r", "*.log", "-i", "important.log", "--no-config" });

    _ = try tmp.dir.statFile("important.log");
    try expectError(error.FileNotFound, tmp.dir.statFile("garbage.log"));
}

test "relative patterns are anchored to cwd" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "root.txt", .data = "" });
    try tmp.dir.makeDir("sub");
    try tmp.dir.writeFile(.{ .sub_path = "sub/nested.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "sub/root.txt", .data = "" });

    try runSlimDown(allocator, tmp.dir, &.{ "-r", "root.txt", "-r", "nested.txt", "--no-config" });

    try expectError(error.FileNotFound, tmp.dir.statFile("root.txt"));

    _ = try tmp.dir.statFile("sub/root.txt");
    _ = try tmp.dir.statFile("sub/nested.txt");
}

test "ignore takes precedence over remove" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "delete_me.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "keep_me.txt", .data = "" });
    try tmp.dir.makeDir("subdir");
    try tmp.dir.writeFile(.{ .sub_path = "subdir/delete_me.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "subdir/keep_me.txt", .data = "" });

    try runSlimDown(allocator, tmp.dir, &.{
        "-r", "**/*.txt",
        "-i", "**/*keep_me.txt",
        "--no-config",
    });

    try expectError(error.FileNotFound, tmp.dir.statFile("delete_me.txt"));
    try expectError(error.FileNotFound, tmp.dir.statFile("subdir/delete_me.txt"));

    _ = try tmp.dir.statFile("keep_me.txt");
    _ = try tmp.dir.statFile("subdir/keep_me.txt");
}

test "double star wildcard resolution" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // .
    // ├── deep
    // │   ├── a
    // │   │   └── target.log
    // │   └── target.log
    // ├── shallow
    // │   └── target.log
    // ├── target.log
    // └── other.log

    try tmp.dir.makePath("deep/a");
    try tmp.dir.makeDir("shallow");
    
    try tmp.dir.writeFile(.{ .sub_path = "deep/a/target.log", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "deep/target.log", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "shallow/target.log", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "target.log", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "other.log", .data = "" });

    try runSlimDown(allocator, tmp.dir, &.{ "-r", "**/target.log", "--no-config" });

    try expectError(error.FileNotFound, tmp.dir.statFile("deep/a/target.log"));
    try expectError(error.FileNotFound, tmp.dir.statFile("deep/target.log"));
    try expectError(error.FileNotFound, tmp.dir.statFile("shallow/target.log"));
    
    try expectError(error.FileNotFound, tmp.dir.statFile("target.log"));

    _ = try tmp.dir.statFile("other.log");
}

test "specific double star usage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("a/b/c");
    try tmp.dir.makePath("a/c");
    try tmp.dir.makePath("b/c");
    
    try tmp.dir.writeFile(.{ .sub_path = "a/b/c/file", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "a/c/file", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "b/c/file", .data = "" });

    try runSlimDown(allocator, tmp.dir, &.{ "-r", "a/**/c/file", "--no-config" });

    try expectError(error.FileNotFound, tmp.dir.statFile("a/b/c/file"));
    try expectError(error.FileNotFound, tmp.dir.statFile("a/c/file"));
    
    _ = try tmp.dir.statFile("b/c/file");
}

test "nested structure with config" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("custom_config");
    try tmp.dir.makeDir("custom_config/slim-down");
    const config_content =
        \\remove = ["node_modules"]
        \\ignore = ["node_modules/keep-me"]
    ;
    try tmp.dir.writeFile(.{ .sub_path = "custom_config/slim-down/config.toml", .data = config_content });

    try tmp.dir.makeDir("node_modules");
    try tmp.dir.writeFile(.{ .sub_path = "node_modules/trash.js", .data = "" });
    try tmp.dir.makeDir("node_modules/keep-me");
    try tmp.dir.writeFile(.{ .sub_path = "node_modules/keep-me/index.js", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "root.js", .data = "" });

    const absolute_config_home = try tmp.dir.realpathAlloc(allocator, "custom_config");
    defer allocator.free(absolute_config_home);

    try runSlimDownWithEnv(allocator, tmp.dir, &.{}, &.{
        .key = "XDG_CONFIG_HOME",
        .value = absolute_config_home,
    });

    try expectError(error.FileNotFound, tmp.dir.statFile("node_modules/trash.js"));
    try expectError(error.FileNotFound, tmp.dir.statFile("node_modules/keep-me/index.js"));

    _ = try tmp.dir.statFile("root.js");
}

fn runSlimDown(allocator: std.mem.Allocator, dir: std.fs.Dir, args: []const []const u8) !void {
    return runSlimDownWithEnv(allocator, dir, args, null);
}

const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

fn runSlimDownWithEnv(allocator: std.mem.Allocator, dir: std.fs.Dir, args: []const []const u8, env_var: ?*const EnvVar) !void {
    const exe_path = build_options.exe_path;
    const absolute_exe_path = try std.fs.cwd().realpathAlloc(allocator, exe_path);
    defer allocator.free(absolute_exe_path);

    var child_args = std.ArrayList([]const u8){};
    defer child_args.deinit(allocator);
    try child_args.append(allocator, absolute_exe_path);
    try child_args.appendSlice(allocator, args);

    var child = std.process.Child.init(child_args.items, allocator);

    const tmp_path = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    child.cwd = tmp_path;

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    if (env_var) |ev| {
        if (std.mem.eql(u8, ev.value, ".")) {
            try env_map.put(ev.key, tmp_path);
        } else {
            try env_map.put(ev.key, ev.value);
        }
    }
    child.env_map = &env_map;

    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    try expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
}

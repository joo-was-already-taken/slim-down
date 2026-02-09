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

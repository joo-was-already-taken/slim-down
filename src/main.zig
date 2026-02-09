const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const clap = @import("clap");
const toml = @import("toml");
const slim = @import("slim_down");

const RawConfig = struct {
    ignore: []const []const u8,
    remove: []const []const u8,

    pub const empty = RawConfig{ .ignore = &.{}, .remove = &.{} };

    pub fn toConfig(self: RawConfig, allocator: Allocator) !slim.Config {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const ignore = try allocator.alloc(slim.PathPattern, self.ignore.len);
        errdefer allocator.free(ignore);

        const remove = try allocator.alloc(slim.PathPattern, self.remove.len);
        errdefer allocator.free(remove);

        for (self.ignore, ignore) |s, *p| {
            const s_copy = try aa.dupe(u8, s);
            p.* = try .init(allocator, s_copy);
        }
        for (self.remove, remove) |s, *p| {
            const s_copy = try aa.dupe(u8, s);
            p.* = try .init(allocator, s_copy);
        }
        return .{ .ignore = ignore, .remove = remove, .arena = arena };
    }
};

const ConfigFromFileResult = struct {
    value: RawConfig,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ConfigFromFileResult) void {
        self.arena.deinit();
    }
};

fn parseConfigString(allocator: Allocator, content: []const u8) !ConfigFromFileResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const content_copy = try aa.dupe(u8, content);

    var parser = toml.Parser(RawConfig).init(aa);
    defer parser.deinit();

    const result = try parser.parseString(content_copy);
    return .{
        .value = result.value,
        .arena = arena,
    };
}

fn loadConfigFromFile(allocator: Allocator, path: []const u8) !ConfigFromFileResult {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const max_size = 1024 * 1024;
    const file_content = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(file_content);
    return parseConfigString(allocator, file_content);
}

fn resolveConfig(
    allocator: Allocator,
    file_config: ?RawConfig,
    args_ignore: []const []const u8,
    args_remove: []const []const u8,
) !slim.Config {
    var raw_config = file_config orelse RawConfig.empty;

    const ignore_combined = try std.mem.concat(allocator, []const u8, &.{ raw_config.ignore, args_ignore });
    defer allocator.free(ignore_combined);
    raw_config.ignore = ignore_combined;

    const remove_combined = try std.mem.concat(allocator, []const u8, &.{ raw_config.remove, args_remove });
    defer allocator.free(remove_combined);
    raw_config.remove = remove_combined;

    return try raw_config.toConfig(allocator);
}

fn getConfigPath(allocator: Allocator) ![]const u8 {
    const xdg_config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME");
    const config_home = xdg_config_home catch |err| blk: {
        if (err != error.EnvironmentVariableNotFound) return err;
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        break :blk try std.fs.path.join(allocator, &[_][]const u8{ home, ".config" });
    };
    defer allocator.free(config_home);
    const path_suffix = "slim-down/config.toml";
    return try std.fs.path.join(allocator, &[_][]const u8{ config_home, path_suffix });
}

fn getConfig(allocator: Allocator, args: anytype) !slim.Config {
    var result_arena: ?ConfigFromFileResult = null;
    defer if (result_arena) |*r| r.deinit();

    var file_config: ?RawConfig = null;

    if (args.@"no-config" == 0) {
        const path = if (args.config) |path|
            try allocator.dupe(u8, path)
        else
            try getConfigPath(allocator);
        defer allocator.free(path);

        result_arena = loadConfigFromFile(allocator, path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        if (result_arena) |r| {
            file_config = r.value;
        }
    }

    return resolveConfig(allocator, file_config, args.ignore, args.remove);
}

fn writeVersion(writer: *std.Io.Writer) !void {
    const build_info = @import("build_info");
    const commit_suffix = " (" ++ build_info.git_commit ++ ")";
    try writer.print("slim-down v{s}{s}\n", .{ build_info.version, commit_suffix });
}

fn writeHelp(writer: *std.Io.Writer, clap_params: anytype) !void {
    try writeVersion(writer);
    try writer.writeAll("Usage:\n    slim-down ");
    try clap.usage(writer, clap.Help, clap_params);
    try writer.writeAll("\n\n");
    try clap.help(writer, clap.Help, clap_params, .{});
    try writer.flush();
}

pub fn main() !u8 {
    const gpa = std.heap.page_allocator;

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-V, --version              Display version of the application.
        \\-c, --config <PATH>        Path to the configuration file.
        \\                           Defaults to ${XDG_CONFIG_HOME:-$HOME/.config}/slim-down/config.toml
        \\--no-config                Don't read config file, even if specified.
        \\-r, --remove <PATTERN>...  Path pattern specifying directories and files to remove.
        \\-i, --ignore <PATTERN>...  Path pattern specifying directories and files to preserve (has precedence over remove patterns).
        \\
    );
    const parsers = comptime .{
        .PATH = clap.parsers.string,
        .PATTERN = clap.parsers.string,
    };
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writeHelp(stdout, &params);
        return 0;
    }
    if (res.args.version != 0) {
        try writeVersion(stdout);
        return 0;
    }

    var config = try getConfig(gpa, &res.args);
    defer config.deinit(gpa);

    const cwd = try std.fs.cwd().openDir(".", .{ .iterate = true });
    var root_dir = try slim.walk(gpa, cwd, config.remove);
    defer root_dir.deinit(gpa);

    try slim.deleteTree(gpa, root_dir, config.ignore);

    return 0;
}

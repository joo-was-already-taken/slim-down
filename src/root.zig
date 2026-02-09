const std = @import("std");
const expectError = std.testing.expectError;
const dir_walk = @import("dir_walk.zig");
pub const Directory = dir_walk.Directory;
pub const File = dir_walk.File;
pub const walk = dir_walk.walk;
pub const PathPattern = @import("PathPattern.zig");
pub const Config = @import("Config.zig");

const Allocator = std.mem.Allocator;

const PatternMatcher = struct {
    pattern: *const PathPattern,
    matcher: PathPattern.Matcher,
};

pub fn deleteTree(allocator: Allocator, dir: Directory, ignore_patterns: []const PathPattern) !void {
    var matchers = std.ArrayList(PatternMatcher).empty;
    defer {
        for (matchers.items) |*m| m.matcher.deinit(allocator);
        matchers.deinit(allocator);
    }

    for (ignore_patterns) |*p| {
        try matchers.append(allocator, .{ .pattern = p, .matcher = .init() });
    }

    try deleteRecursive(allocator, std.fs.cwd(), dir, matchers.items);
}

fn deleteRecursive(allocator: Allocator, parent_dir: std.fs.Dir, dir: Directory, matchers: []const PatternMatcher) !void {
    var current_handle = if (std.mem.eql(u8, dir.name, "."))
        parent_dir
    else
        parent_dir.openDir(dir.name, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    defer if (!std.mem.eql(u8, dir.name, ".")) current_handle.close();

    for (dir.files) |file| {
        if (!try isIgnored(allocator, file.name, matchers)) {
            current_handle.deleteFile(file.name) catch {};
        }
    }

    for (dir.subdirs) |subdir| {
        var next_matchers = std.ArrayList(PatternMatcher).empty;
        defer next_matchers.deinit(allocator);

        var dir_ignored = false;

        for (matchers) |pm| {
            var next = try pm.matcher.clone(allocator);
            errdefer next.deinit(allocator);

            const res = try next.nextPart(allocator, pm.pattern, subdir.name);
            if (res == .matches) {
                dir_ignored = true;
                next.deinit(allocator);
                break;
            } else if (res == .proceed) {
                try next_matchers.append(allocator, .{ .pattern = pm.pattern, .matcher = next });
            } else {
                next.deinit(allocator);
            }
        }
        defer for (next_matchers.items) |*nm| nm.matcher.deinit(allocator);

        if (dir_ignored) continue;

        try deleteRecursive(allocator, current_handle, subdir, next_matchers.items);

        current_handle.deleteDir(subdir.name) catch |err| {
            if (err == error.DirNotEmpty) {
                try current_handle.deleteTree(subdir.name);
            } else {
                return err;
            }
        };
    }
}

fn isIgnored(allocator: Allocator, name: []const u8, matchers: []const PatternMatcher) !bool {
    for (matchers) |pm| {
        var temp = try pm.matcher.clone(allocator);
        defer temp.deinit(allocator);
        if ((try temp.nextPart(allocator, pm.pattern, name)) == .matches) {
            return true;
        }
    }
    return false;
}

test {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // File structure:
    // .
    // ├── to_delete.txt
    // ├── to_keep.txt
    // ├── wildcard_del_1.log
    // ├── wildcard_del_2.log
    // ├── folder_del/
    // │   └── file.txt
    // ├── folder_keep/
    // │   └── file.txt
    // ├── folder_mix/
    // │   ├── delete.txt
    // │   └── keep.txt
    // ├── wild_folder_1/
    // │   └── file
    // ├── wild_folder_2/
    // │   └── file
    // └── deep/
    //     └── nested/
    //         └── to_delete.txt

    try tmp.dir.writeFile(.{ .sub_path = "to_delete.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "to_keep.txt", .data = "" });
    try tmp.dir.makeDir("folder_del");
    try tmp.dir.writeFile(.{ .sub_path = "folder_del/file.txt", .data = "" });
    try tmp.dir.makeDir("folder_keep");
    try tmp.dir.writeFile(.{ .sub_path = "folder_keep/file.txt", .data = "" });
    try tmp.dir.makeDir("folder_mix");
    try tmp.dir.writeFile(.{ .sub_path = "folder_mix/delete.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "folder_mix/keep.txt", .data = "" });
    try tmp.dir.makePath("deep/nested");
    try tmp.dir.writeFile(.{ .sub_path = "deep/nested/to_delete.txt", .data = "" });

    try tmp.dir.writeFile(.{ .sub_path = "wildcard_del_1.log", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "wildcard_del_2.log", .data = "" });
    try tmp.dir.makeDir("wild_folder_1");
    try tmp.dir.writeFile(.{ .sub_path = "wild_folder_1/file", .data = "" });
    try tmp.dir.makeDir("wild_folder_2");
    try tmp.dir.writeFile(.{ .sub_path = "wild_folder_2/file", .data = "" });

    var rp1 = try PathPattern.init(allocator, "to_delete.txt");
    defer rp1.deinit(allocator);
    var rp2 = try PathPattern.init(allocator, "to_keep.txt");
    defer rp2.deinit(allocator);
    var rp3 = try PathPattern.init(allocator, "folder_del/");
    defer rp3.deinit(allocator);
    var rp4 = try PathPattern.init(allocator, "folder_keep/");
    defer rp4.deinit(allocator);
    var rp5 = try PathPattern.init(allocator, "folder_mix/");
    defer rp5.deinit(allocator);
    var rp6 = try PathPattern.init(allocator, "deep/");
    defer rp6.deinit(allocator);

    var rp7 = try PathPattern.init(allocator, "*.log");
    defer rp7.deinit(allocator);
    var rp8 = try PathPattern.init(allocator, "wild_folder_*");
    defer rp8.deinit(allocator);
    const remove_patterns = &[_]PathPattern{ rp1, rp2, rp3, rp4, rp5, rp6, rp7, rp8 };

    var ip1 = try PathPattern.init(allocator, "to_keep.txt");
    defer ip1.deinit(allocator);
    var ip2 = try PathPattern.init(allocator, "folder_keep/");
    defer ip2.deinit(allocator);
    var ip3 = try PathPattern.init(allocator, "folder_mix/keep.txt");
    defer ip3.deinit(allocator);

    const ignore_patterns = &[_]PathPattern{ ip1, ip2, ip3 };

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const walk_root = try std.fs.cwd().openDir(".", .{ .iterate = true });
    var root_dir = try walk(allocator, walk_root, remove_patterns);
    defer root_dir.deinit(allocator);

    try deleteTree(allocator, root_dir, ignore_patterns);

    try expectError(error.FileNotFound, tmp.dir.statFile("to_delete.txt"));

    _ = try tmp.dir.statFile("to_keep.txt");

    try expectError(error.FileNotFound, tmp.dir.statFile("folder_del/file.txt"));
    try expectError(error.FileNotFound, tmp.dir.statFile("folder_del"));

    _ = try tmp.dir.statFile("folder_keep/file.txt");

    try expectError(error.FileNotFound, tmp.dir.statFile("folder_mix"));
    try expectError(error.FileNotFound, tmp.dir.statFile("folder_mix/keep.txt"));

    try expectError(error.FileNotFound, tmp.dir.statFile("deep/nested/to_delete.txt"));
    try expectError(error.FileNotFound, tmp.dir.statFile("deep/nested"));
    try expectError(error.FileNotFound, tmp.dir.statFile("deep"));

    try expectError(error.FileNotFound, tmp.dir.statFile("wildcard_del_1.log"));
    try expectError(error.FileNotFound, tmp.dir.statFile("wildcard_del_2.log"));
    try expectError(error.FileNotFound, tmp.dir.statFile("wild_folder_1"));
    try expectError(error.FileNotFound, tmp.dir.statFile("wild_folder_2"));
}

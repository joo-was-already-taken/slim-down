const std = @import("std");
const Allocator = std.mem.Allocator;
const PathPattern = @import("PathPattern.zig");

pub const Directory = struct {
    name: []const u8,
    subdirs: []Directory,
    files: []File,
    size: u64,

    pub fn deinit(self: *Directory, allocator: Allocator) void {
        for (self.subdirs) |*dir| dir.deinit(allocator);
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.subdirs);
        allocator.free(self.files);
        allocator.free(self.name);
    }
};

pub const File = struct {
    name: []const u8,
    size: u64,

    pub fn deinit(self: *File, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

const Frame = struct {
    entered: ?struct {
        dir: std.fs.Dir,
        iter: std.fs.Dir.Iterator,
    },
    child_data: ?struct {
        name: []const u8,
        parent_idx: usize,
    },
    ref_count: usize,
    exhausted: bool,
    matchers: std.ArrayList(PatternMatcher),
    subdirs: std.ArrayList(Directory),
    files: std.ArrayList(File),

    const PatternMatcher = struct {
        pattern: *const PathPattern,
        matcher: PathPattern.Matcher,
    };

    fn deinit(self: *Frame, allocator: Allocator) void {
        if (self.entered) |*e| e.dir.close();
        if (self.child_data) |cd| allocator.free(cd.name);
        for (self.matchers.items) |*m| m.matcher.deinit(allocator);
        self.matchers.deinit(allocator);

        for (self.subdirs.items) |*d| d.deinit(allocator);
        self.subdirs.deinit(allocator);
        for (self.files.items) |*f| f.deinit(allocator);
        self.files.deinit(allocator);
    }

    fn parent(self: Frame, frames: []Frame) *Frame {
        return &frames[self.child_data.?.parent_idx];
    }

    fn next(self: *Frame, frames: []Frame) !?std.fs.Dir.Entry {
        if (self.entered == null) {
            const parent_dir = self.parent(frames).entered.?.dir;
            const dir = try parent_dir.openDir(self.child_data.?.name, .{ .iterate = true });
            self.entered = .{
                .dir = dir,
                .iter = dir.iterate(),
            };
        }
        if (self.exhausted) return null;
        const res = try self.entered.?.iter.next();
        if (res == null) self.exhausted = true;
        return res;
    }
};

pub fn walk(allocator: Allocator, root: std.fs.Dir, patterns: []const PathPattern) !Directory {
    var frames = std.ArrayList(Frame).empty;
    defer {
        for (frames.items) |*f| f.deinit(allocator);
        frames.deinit(allocator);
    }

    var matchers = std.ArrayList(Frame.PatternMatcher).empty;
    errdefer matchers.deinit(allocator);

    for (patterns) |*p| {
        try matchers.append(allocator, .{ .pattern = p, .matcher = PathPattern.Matcher.init() });
    }

    try frames.append(allocator, .{
        .entered = .{
            .dir = root,
            .iter = root.iterate(),
        },
        .child_data = null,
        .ref_count = 0,
        .exhausted = false,
        .matchers = matchers,
        .subdirs = .empty,
        .files = .empty,
    });

    while (frames.items.len > 0) {
        const top_idx = frames.items.len - 1;

        {
            const top = &frames.items[top_idx];
            if (top.entered != null and top.exhausted and top.ref_count == 0) {
                if (try finalizeFrame(allocator, &frames)) |root_dir| {
                    return root_dir;
                }
                continue;
            }
        }

        if (try frames.items[top_idx].next(frames.items)) |entry| {
            switch (entry.kind) {
                .directory => try processDirectoryEntry(allocator, &frames, top_idx, entry.name),
                .file => try processFileEntry(allocator, &frames.items[top_idx], entry.name),
                else => {},
            }
        }
    }
    unreachable;
}

fn finalizeFrame(allocator: Allocator, frames: *std.ArrayList(Frame)) !?Directory {
    const top_idx = frames.items.len - 1;
    const top = &frames.items[top_idx];

    var dir = Directory{
        .name = if (top.child_data) |cd| cd.name else try allocator.dupe(u8, "."),
        .subdirs = try top.subdirs.toOwnedSlice(allocator),
        .files = try top.files.toOwnedSlice(allocator),
        .size = 0,
    };

    if (top.child_data) |_| top.child_data = null;

    for (dir.subdirs) |d| dir.size += d.size;
    for (dir.files) |f| dir.size += f.size;

    top.deinit(allocator);
    _ = frames.pop();

    if (frames.items.len > 0) {
        const parent_frame = &frames.items[frames.items.len - 1];
        try parent_frame.subdirs.append(allocator, dir);
        parent_frame.ref_count -= 1;
        return null;
    } else {
        return dir;
    }
}

fn processDirectoryEntry(allocator: Allocator, frames: *std.ArrayList(Frame), top_idx: usize, entry_name: []const u8) !void {
    const top = &frames.items[top_idx];

    var child_matchers = std.ArrayList(Frame.PatternMatcher).empty;
    errdefer {
        for (child_matchers.items) |*m| m.matcher.deinit(allocator);
        child_matchers.deinit(allocator);
    }

    var matched = false;

    for (top.matchers.items) |pm| {
        var next_matcher = try pm.matcher.clone(allocator);
        errdefer next_matcher.deinit(allocator);

        const res = try next_matcher.nextPart(allocator, pm.pattern, entry_name);
        if (res == .matches) {
            matched = true;
            next_matcher.deinit(allocator);
            break;
        } else if (res == .proceed) {
            try child_matchers.append(allocator, .{ .pattern = pm.pattern, .matcher = next_matcher });
        } else {
            next_matcher.deinit(allocator);
        }
    }

    if (matched) {
        for (child_matchers.items) |*m| m.matcher.deinit(allocator);
        child_matchers.deinit(allocator);

        const name_dupe = try allocator.dupe(u8, entry_name);
        errdefer allocator.free(name_dupe);

        try top.subdirs.append(allocator, .{
            .name = name_dupe,
            .subdirs = &.{},
            .files = &.{},
            .size = 0,
        });
        return;
    }

    if (child_matchers.items.len > 0) {
        const name_dupe = try allocator.dupe(u8, entry_name);
        errdefer allocator.free(name_dupe);

        try frames.append(allocator, .{
            .entered = null,
            .child_data = .{
                .name = name_dupe,
                .parent_idx = top_idx,
            },
            .ref_count = 0,
            .exhausted = false,
            .matchers = child_matchers,
            .subdirs = std.ArrayList(Directory).empty,
            .files = std.ArrayList(File).empty,
        });
        frames.items[top_idx].ref_count += 1;
    } else {
        for (child_matchers.items) |*m| m.matcher.deinit(allocator);
        child_matchers.deinit(allocator);
    }
}

fn processFileEntry(allocator: Allocator, top: *Frame, entry_name: []const u8) !void {
    var matched = false;
    for (top.matchers.items) |pm| {
        var temp_matcher = try pm.matcher.clone(allocator);
        defer temp_matcher.deinit(allocator);

        const res = try temp_matcher.nextPart(allocator, pm.pattern, entry_name);
        if (res == .matches) {
            matched = true;
            break;
        }
    }

    if (matched) {
        const name = try allocator.dupe(u8, entry_name);
        errdefer allocator.free(name);

        const size = (try top.entered.?.dir.statFile(entry_name)).size;
        try top.files.append(allocator, .{
            .name = name,
            .size = size,
        });
    }
}

test {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "main" });
    try tmp.dir.writeFile(.{ .sub_path = "src/other.c", .data = "other" });
    try tmp.dir.makeDir("build");
    try tmp.dir.writeFile(.{ .sub_path = "build/output", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "# Readme" });

    var p1 = try PathPattern.init(allocator, "src/*.zig");
    defer p1.deinit(allocator);
    var p2 = try PathPattern.init(allocator, "README.md");
    defer p2.deinit(allocator);

    const patterns = &[_]PathPattern{ p1, p2 };

    const root_for_walk = try tmp.dir.openDir(".", .{ .iterate = true });

    var root_dir = try walk(allocator, root_for_walk, patterns);
    defer root_dir.deinit(allocator);

    try std.testing.expectEqualStrings(".", root_dir.name);

    var found_src = false;
    for (root_dir.subdirs) |d| {
        if (std.mem.eql(u8, d.name, "src")) {
            found_src = true;
            try std.testing.expectEqual(@as(usize, 1), d.files.len);
            try std.testing.expectEqualStrings("main.zig", d.files[0].name);
        }
    }
    try std.testing.expect(found_src);

    var found_readme = false;
    for (root_dir.files) |f| {
        if (std.mem.eql(u8, f.name, "README.md")) {
            found_readme = true;
        }
    }
    try std.testing.expect(found_readme);

    for (root_dir.subdirs) |d| {
        if (std.mem.eql(u8, d.name, "build")) {
            try std.testing.expect(false);
        }
    }
}

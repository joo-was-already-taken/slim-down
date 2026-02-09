//! Safety:
//!     This struct doesn't own memory of strings,
//!     allocator passed to init is only used for middle ArrayList.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const PathPattern = @This();

is_root: bool,
prefix: ?[]const u8,
middle: ?std.ArrayList(MiddlePart),
file: ?[]const u8,

const MiddlePart = union(enum) {
    dir: []const u8,
    wildcard,
};

pub const Error = error{
    Empty,
};

pub fn init(allocator: Allocator, pattern: []const u8) (Allocator.Error || Error)!PathPattern {
    try validate(pattern);
    return parse(allocator, pattern);
}

pub fn deinit(self: *PathPattern, allocator: Allocator) void {
    if (self.middle) |*middle| {
        middle.deinit(allocator);
    }
}

fn validate(pattern: []const u8) Error!void {
    // TODO
    _ = pattern;
}

fn parse(allocator: Allocator, pattern: []const u8) Allocator.Error!PathPattern {
    assert(pattern.len != 0);
    const is_root = pattern[0] == '/';
    const prefix_start: usize = if (is_root) 1 else 0;
    if (prefix_start == pattern.len) {
        return .{ .is_root = true, .prefix = null, .middle = null, .file = null };
    }
    const prefix = parsePrefix(pattern[prefix_start..]);
    const middle_start = (if (prefix) |p| p.len + 1 else 0) + prefix_start;

    var parts = std.ArrayList(MiddlePart).empty;
    var part_start: usize = middle_start;
    for (pattern[middle_start..], middle_start..) |ch, i| {
        if (ch == '/') {
            const part = pattern[part_start..i];
            if (std.mem.eql(u8, part, "**")) {
                try parts.append(allocator, .wildcard);
            } else {
                try parts.append(allocator, .{ .dir = part });
            }
            part_start = i + 1;
        }
    }

    return .{
        .is_root = is_root,
        .prefix = prefix,
        .middle = if (parts.items.len == 0) null else parts,
        .file = if (pattern[pattern.len - 1] == '/') null else pattern[part_start..],
    };
}

fn parsePrefix(pattern: []const u8) ?[]const u8 {
    assert(pattern.len != 0);
    var last_slash: ?usize = null;
    var escaped = false;

    for (pattern, 0..) |ch, i| {
        switch (ch) {
            '/' => last_slash = i,
            '*' => if (!escaped) break,
            else => {},
        }
        escaped = ch == '\\';
    } else {
        if (last_slash) |slash| {
            return pattern[0..slash];
        } else {
            return null;
        }
    }
    if (pattern[pattern.len - 1] == '/') {
        return pattern[0 .. pattern.len - 1];
    } else if (last_slash) |slash| {
        return pattern[0..slash];
    } else {
        return null;
    }
}

fn partAt(path: []const u8, part_idx: usize) ?[]const u8 {
    var part_start: usize = 0;
    var cur_part_idx: usize = 0;
    var idx: usize = 0;
    while (idx < path.len) {
        const res = Matcher.nextByte(path, idx);
        idx += res.offset;
        if (res.byte == '/') {
            if (cur_part_idx == part_idx) {
                return path[part_start .. idx - res.offset];
            }
            part_start = idx;
            cur_part_idx += 1;
        }
    }
    if (cur_part_idx == part_idx) {
        return path[part_start..];
    }
    return null;
}

pub fn format(
    self: *const PathPattern,
    writer: anytype,
) !void {
    if (self.is_root) try writer.writeByte('/');
    if (self.prefix) |prefix| try writer.print("{s}/", .{prefix});
    if (self.middle) |middle| {
        for (middle.items) |part| {
            switch (part) {
                .dir => |dir| try writer.print("{s}/", .{dir}),
                .wildcard => try writer.writeAll("**/"),
            }
        }
    }
    if (self.file) |file| try writer.writeAll(file);
    try writer.flush();
}

pub const Matcher = union(enum) {
    prefix: u32,
    middle: std.ArrayList(u32),
    file,

    pub fn init() Matcher {
        return .{ .prefix = 0 };
    }

    pub fn deinit(self: *Matcher, allocator: Allocator) void {
        switch (self.*) {
            .middle => |*middle| middle.deinit(allocator),
            else => {},
        }
    }

    pub fn clone(self: *const Matcher, allocator: Allocator) Allocator.Error!Matcher {
        return switch (self.*) {
            .middle => |m| .{ .middle = try m.clone(allocator) },
            .prefix, .file => self.*,
        };
    }

    fn initMiddle(allocator: Allocator, pattern: *const PathPattern) !Matcher {
        var idxs = std.ArrayList(u32).empty;
        try idxs.append(allocator, 0);

        if (pattern.middle) |middle| {
            var i: usize = 0;
            while (i < idxs.items.len) : (i += 1) {
                const idx = idxs.items[i];
                if (idx < middle.items.len and middle.items[idx] == .wildcard) {
                    try appendUnique(&idxs, allocator, idx + 1);
                }
            }
        }
        return .{ .middle = idxs };
    }

    fn appendUnique(list: *std.ArrayList(u32), allocator: Allocator, item: u32) !void {
        for (list.items) |i| {
            if (i == item) return;
        }
        try list.append(allocator, item);
    }

    pub const PartMatchResult = enum {
        differs,
        proceed,
        matches,
    };

    pub fn nextPart(self: *Matcher, allocator: Allocator, pattern: *const PathPattern, part: []const u8) Allocator.Error!PartMatchResult {
        if (self.* == .prefix) prefix: {
            const idx = self.prefix;
            const prefix = pattern.prefix orelse {
                self.* = try Matcher.initMiddle(allocator, pattern);
                break :prefix;
            };
            const expected_part = partAt(prefix, idx) orelse return .differs;
            const matches = try partMatches(expected_part, part);
            if (!matches) return .differs;
            if (partAt(prefix, idx + 1) == null) {
                self.* = try Matcher.initMiddle(allocator, pattern);
            } else {
                self.prefix += 1;
            }

            if (self.* == .middle) {
                if (pattern.middle == null and pattern.file == null) return .matches;
                return .proceed;
            }
            return .proceed;
        }

        if (self.* == .middle) middle: {
            const idxs = &self.middle;
            if (pattern.middle == null) {
                idxs.deinit(allocator);
                self.* = .file;
                break :middle;
            }
            const res = try nextMiddlePart(allocator, idxs, pattern, part);
            switch (res) {
                .differs, .proceed => return res,
                .matches => {
                    idxs.deinit(allocator);
                    self.* = .file;
                    return .matches;
                },
            }
        }

        if (self.* == .file) {
            const file = pattern.file orelse return .matches;
            return if (try partMatches(file, part)) .matches else .differs;
        }

        unreachable;
    }

    fn nextMiddlePart(allocator: Allocator, middle_idxs: *std.ArrayList(u32), pattern: *const PathPattern, part: []const u8) !PartMatchResult {
        var new_idxs = std.ArrayList(u32).empty;
        const middle = pattern.middle.?.items;
        var matched_file = false;

        for (middle_idxs.items) |p_idx| {
            if (p_idx == middle.len) {
                if (pattern.file) |file| {
                    if (try partMatches(file, part)) {
                        matched_file = true;
                    }
                }
                continue;
            }

            switch (middle[p_idx]) {
                .dir => |dir_pattern| {
                    if (try partMatches(dir_pattern, part)) {
                        try appendUnique(&new_idxs, allocator, p_idx + 1);
                    }
                },
                .wildcard => {
                    try appendUnique(&new_idxs, allocator, p_idx);

                    if (p_idx + 1 < middle.len) {
                        const next_part_pat = middle[p_idx + 1];
                        switch (next_part_pat) {
                            .dir => |d| {
                                if (try partMatches(d, part)) {
                                    try appendUnique(&new_idxs, allocator, p_idx + 2);
                                }
                            },
                            .wildcard => {
                                try appendUnique(&new_idxs, allocator, p_idx + 1);
                            },
                        }
                    } else {
                        if (pattern.file) |file| {
                            if (try partMatches(file, part)) {
                                matched_file = true;
                            }
                        } else {
                            matched_file = true;
                        }
                    }
                },
            }
        }

        var i: usize = 0;
        while (i < new_idxs.items.len) : (i += 1) {
            const idx = new_idxs.items[i];
            if (idx < middle.len and middle[idx] == .wildcard) {
                try appendUnique(&new_idxs, allocator, idx + 1);
            }
        }

        middle_idxs.deinit(allocator);
        middle_idxs.* = new_idxs;

        if (matched_file) return .matches;

        var completed_middle_path = false;
        for (middle_idxs.items) |idx| {
            if (idx == middle.len) {
                completed_middle_path = true;
                break;
            }
        }
        
        if (completed_middle_path and pattern.file == null) {
            return .matches;
        }

        if (middle_idxs.items.len > 0) return .proceed;
        return .differs;
    }

    fn partMatches(pattern: []const u8, part: []const u8) Allocator.Error!bool {
        var stack_fb = std.heap.stackFallback(32 * @sizeOf(u32), std.heap.page_allocator);
        const allocator = stack_fb.get();

        var pattern_idxs = std.ArrayList(u32).empty;
        defer pattern_idxs.deinit(allocator);
        pattern_idxs.append(allocator, 0) catch unreachable;

        for (part) |char| {
            var idxs_start: usize = 0;
            var idxs_end: usize = pattern_idxs.items.len;
            while (idxs_start < idxs_end) {
                const p_idx = pattern_idxs.items[idxs_start];
                if (p_idx == pattern.len) return true;

                const byte_info = nextByte(pattern, p_idx);

                if (byte_info.byte == '*' and !byte_info.escaped) {
                    if (p_idx + byte_info.offset >= pattern.len) {
                        return true;
                    }
                    const next_byte_info = nextByte(pattern, p_idx + byte_info.offset);
                    const next_byte = next_byte_info.byte;
                    assert(next_byte != '*' or next_byte_info.escaped);

                    if (next_byte == '/') {
                        return true;
                    } else if (next_byte == char) {
                        const new_p_idx = p_idx + byte_info.offset + next_byte_info.offset;
                        try pattern_idxs.append(allocator, new_p_idx);
                    }
                    idxs_start += 1;
                } else if (byte_info.byte == char) {
                    pattern_idxs.items[idxs_start] += byte_info.offset;
                    idxs_start += 1;
                } else {
                    _ = pattern_idxs.orderedRemove(idxs_start);
                    idxs_end -= 1;
                }
            }
            if (pattern_idxs.items.len == 0) return false;
        }

        for (pattern_idxs.items) |p_idx| {
            if (matchesEmpty(pattern, p_idx)) {
                return true;
            }
        }
        return false;
    }

    fn matchesEmpty(pattern: []const u8, start_idx: usize) bool {
        var idx = start_idx;
        while (idx < pattern.len) {
            if (pattern[idx] == '/') return true;
            const byte_info = nextByte(pattern, idx);
            if (byte_info.byte == '*' and !byte_info.escaped) {
                idx += byte_info.offset;
                continue;
            }
            return false;
        }
        return true;
    }

    fn nextByte(pattern: []const u8, idx: usize) struct {
        escaped: bool,
        byte: u8,
        offset: u32,
    } {
        assert(idx < pattern.len);
        const escaped = pattern[idx] == '\\';
        assert(!escaped or idx + 1 < pattern.len);
        const byte, const offset: u32 = if (escaped)
            .{ pattern[idx + 1], 2 }
        else
            .{ pattern[idx], 1 };
        return .{
            .escaped = escaped,
            .byte = byte,
            .offset = offset,
        };
    }
};

fn testParse(expected: anytype, pattern: []const u8) !void {
    const allocator = std.testing.allocator;
    var actual = try init(allocator, pattern);
    defer actual.deinit(allocator);

    try expectEqual(expected.is_root, actual.is_root);
    try expectEqualDeep(expected.prefix, actual.prefix);
    if (actual.middle) |m| {
        try expectEqualDeep(expected.middle, m.items);
    } else {
        try expectEqualDeep(expected.middle, null);
    }
    try expectEqualDeep(expected.file, actual.file);
}

test "parse" {
    try testParse(.{
        .is_root = false,
        .prefix = null,
        .middle = null,
        .file = "hello",
    }, "hello");
    try testParse(.{
        .is_root = true,
        .prefix = null,
        .middle = null,
        .file = "hello",
    }, "/hello");
    try testParse(.{
        .is_root = false,
        .prefix = "src",
        .middle = null,
        .file = "main.zig",
    }, "src/main.zig");
    try testParse(.{
        .is_root = true,
        .prefix = "usr",
        .middle = null,
        .file = "bin",
    }, "/usr/bin");
    try testParse(.{
        .is_root = false,
        .prefix = "src",
        .middle = null,
        .file = null,
    }, "src/");
    try testParse(.{
        .is_root = false,
        .prefix = null,
        .middle = null,
        .file = "*.zig",
    }, "*.zig");
    try testParse(.{
        .is_root = false,
        .prefix = "src",
        .middle = null,
        .file = "*.zig",
    }, "src/*.zig");
    try testParse(.{
        .is_root = false,
        .prefix = "src",
        .middle = &[_]MiddlePart{.wildcard},
        .file = "main.zig",
    }, "src/**/main.zig");
    try testParse(.{
        .is_root = false,
        .prefix = "src",
        .middle = &[_]MiddlePart{ .wildcard, .{ .dir = "test" } },
        .file = "*.zig",
    }, "src/**/test/*.zig");
    try testParse(.{
        .is_root = false,
        .prefix = "src",
        .middle = null,
        .file = "\\*.zig",
    }, "src/\\*.zig");
    try testParse(.{
        .is_root = true,
        .prefix = null,
        .middle = null,
        .file = null,
    }, "/");
}

test "partAt" {
    try expectEqualDeep("a", partAt("a/path/to/a/file", 0));
    try expectEqualDeep("a", partAt("a/path/to/a/file", 3));
    try expectEqualDeep("file", partAt("a/path/to/a/file", 4));
    try expectEqual(null, partAt("a/path/to/a/file", 5));
}

test "Matcher.partMatches - basic" {
    try expect(try Matcher.partMatches("basic", "basic"));
    try expect(try Matcher.partMatches("b*c", "basic"));
    try expect(try Matcher.partMatches("bas*", "basic"));
    try expect(try Matcher.partMatches("basic*", "basic"));
    try expect(try Matcher.partMatches("*", "anything"));
    try expect(try Matcher.partMatches("*thing", "something"));
    try expect(try Matcher.partMatches("anyth*g", "anythinging"));
}

test "Matcher.partMatches - escaped" {
    try expect(try Matcher.partMatches("\\basic", "basic"));
    try expect(try Matcher.partMatches("b\\*c", "b*c"));
    try expect(try Matcher.partMatches("esca\\\\ped", "esca\\ped"));
}

test "Matcher.partMatches - slash seperated" {
    try expect(try Matcher.partMatches("basic/not-matched", "basic"));
    try expect(try Matcher.partMatches("b*c/not-matched", "basic"));
    try expect(try Matcher.partMatches("b*/not-matched", "basic-and-rest"));
    try expect(try Matcher.partMatches("b\\*c/not-matched", "b*c"));
}

test "Matcher.partMatches - partial wildcard mismatch" {
    try expect(!try Matcher.partMatches("*.zig", "other.c"));
}

test "Matcher.nextMiddlePart" {
    const allocator = std.testing.allocator;

    {
        var middle_list = std.ArrayList(MiddlePart).empty;
        defer middle_list.deinit(allocator);
        try middle_list.append(allocator, .{ .dir = "a" });
        const dummy_pattern = PathPattern{
            .is_root = false,
            .prefix = null,
            .middle = middle_list,
            .file = null,
        };
        var idxs = std.ArrayList(u32).empty;
        defer idxs.deinit(allocator);
        try idxs.append(allocator, 0);

        const res = try Matcher.nextMiddlePart(allocator, &idxs, &dummy_pattern, "a");
        try expectEqual(.matches, res);
        try expectEqual(1, idxs.items.len);
        try expectEqual(1, idxs.items[0]);
    }

    {
        var middle_list = std.ArrayList(MiddlePart).empty;
        defer middle_list.deinit(allocator);
        try middle_list.append(allocator, .{ .dir = "a" });
        const dummy_pattern = PathPattern{
            .is_root = false,
            .prefix = null,
            .middle = middle_list,
            .file = null,
        };
        var idxs = std.ArrayList(u32).empty;
        defer idxs.deinit(allocator);
        try idxs.append(allocator, 0);

        const res = try Matcher.nextMiddlePart(allocator, &idxs, &dummy_pattern, "b");
        try expectEqual(.differs, res);
        try expectEqual(0, idxs.items.len);
    }

    {
        var middle_list = std.ArrayList(MiddlePart).empty;
        defer middle_list.deinit(allocator);
        try middle_list.append(allocator, .wildcard);
        const dummy_pattern = PathPattern{
            .is_root = false,
            .prefix = null,
            .middle = middle_list,
            .file = null,
        };
        var idxs = std.ArrayList(u32).empty;
        defer idxs.deinit(allocator);
        try idxs.append(allocator, 0);

        const res = try Matcher.nextMiddlePart(allocator, &idxs, &dummy_pattern, "anything");
        try expectEqual(.matches, res);
        try expectEqual(2, idxs.items.len);
        try expectEqual(0, idxs.items[0]);
        try expectEqual(1, idxs.items[1]);
    }

    {
        var middle_list = std.ArrayList(MiddlePart).empty;
        defer middle_list.deinit(allocator);
        try middle_list.append(allocator, .wildcard);
        try middle_list.append(allocator, .{ .dir = "b" });
        const dummy_pattern = PathPattern{
            .is_root = false,
            .prefix = null,
            .middle = middle_list,
            .file = null,
        };
        var idxs = std.ArrayList(u32).empty;
        defer idxs.deinit(allocator);
        try idxs.append(allocator, 0);

        const res = try Matcher.nextMiddlePart(allocator, &idxs, &dummy_pattern, "a");
        try expectEqual(.proceed, res);
    }
}

test "Matcher.nextPart" {
    const allocator = std.testing.allocator;

    {
        var pattern = try init(allocator, "src/main.zig");
        defer pattern.deinit(allocator);
        var matcher = Matcher.init();
        defer matcher.deinit(allocator);

        try expectEqual(.proceed, try matcher.nextPart(allocator, &pattern, "src"));
        try expectEqual(.matches, try matcher.nextPart(allocator, &pattern, "main.zig"));
    }

    {
        var pattern = try init(allocator, "a/b/c");
        defer pattern.deinit(allocator);
        var matcher = Matcher.init();
        defer matcher.deinit(allocator);

        try expectEqual(.proceed, try matcher.nextPart(allocator, &pattern, "a"));
        try expectEqual(.proceed, try matcher.nextPart(allocator, &pattern, "b"));
        try expectEqual(.matches, try matcher.nextPart(allocator, &pattern, "c"));
    }

    {
        var pattern = try init(allocator, "src/**/test.zig");
        defer pattern.deinit(allocator);
        {
            var matcher = Matcher.init();
            defer matcher.deinit(allocator);
            try expectEqual(.proceed, try matcher.nextPart(allocator, &pattern, "src"));
            try expectEqual(.proceed, try matcher.nextPart(allocator, &pattern, "a"));
            try expectEqual(.proceed, try matcher.nextPart(allocator, &pattern, "b"));
            try expectEqual(.proceed, try matcher.nextPart(allocator, &pattern, "c"));
            try expectEqual(.matches, try matcher.nextPart(allocator, &pattern, "test.zig"));
        }
        {
            var matcher = Matcher.init();
            defer matcher.deinit(allocator);
            try expectEqual(.proceed, try matcher.nextPart(allocator, &pattern, "src"));
            try expectEqual(.matches, try matcher.nextPart(allocator, &pattern, "test.zig"));
        }
    }

    {
        var pattern = try init(allocator, "src/main.zig");
        defer pattern.deinit(allocator);
        var matcher = Matcher.init();
        defer matcher.deinit(allocator);

        try expectEqual(.differs, try matcher.nextPart(allocator, &pattern, "lib"));
    }
}

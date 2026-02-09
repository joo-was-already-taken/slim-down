const std = @import("std");
const Allocator = std.mem.Allocator;
const PathPattern = @import("PathPattern.zig");
const Config = @This();

ignore: []PathPattern,
remove: []PathPattern,
arena: std.heap.ArenaAllocator,

pub fn deinit(self: *Config, allocator: Allocator) void {
    if (self.ignore.len != 0) {
        for (self.ignore) |*pattern| pattern.deinit(allocator);
        allocator.free(self.ignore);
    }
    if (self.remove.len != 0) {
        for (self.remove) |*pattern| pattern.deinit(allocator);
        allocator.free(self.remove);
    }
    self.arena.deinit();
}

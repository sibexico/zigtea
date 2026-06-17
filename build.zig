const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("zigtea", .{
        .root_source_file = b.path("zigtea_gc.zig"),
    });
}

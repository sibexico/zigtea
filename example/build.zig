const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigtea_mod = b.addModule("zigtea", .{
        .root_source_file = b.path("../zigtea_gc.zig"),
        .target = target,
    });

    const example = b.addExecutable(.{
        .name = "zigtea-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigtea", .module = zigtea_mod },
            },
        }),
    });

    b.installArtifact(example);

    const run_cmd = b.addRunArtifact(example);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the ZigTea example");
    run_step.dependOn(&run_cmd.step);
}

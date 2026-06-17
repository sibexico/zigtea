const std = @import("std");
const ZigTeaGC = @import("zigtea").ZigTeaGC;

pub fn main() !void {
    var gc = ZigTeaGC.init(std.heap.page_allocator);
    defer gc.deinit();

    // Register stack boundary.
    gc.registerCurrentStackBase();

    const allocator = gc.allocator();

    var list = try std.ArrayList(u32).initCapacity(allocator, 0);
    defer list.deinit(allocator);

    try list.append(allocator, 10);
    try list.append(allocator, 100);
    try list.append(allocator, 123);

    std.debug.print("items: {any}\n", .{list.items});

    // Optional manual trigger.
    gc.collect();
}

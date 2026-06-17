# ZigTea

Tiny conservative garbage collector allocator for Zig.

**!!!THIS IS AN EDUCATIONAL PROJECT! DON'T USE IN PRODUCTION!!!**


[**Explanation of how it works in the blogpost.**](https://sibexi.co/posts/zigtea-gc-allocator/)


## What It Does

- Uses 8 KiB spans.
- Groups allocations by fixed size classes.
- Tracks objects with two bitmaps per span:
  - `seen`: object is reachable.
  - `scanned`: object pointers was already traced.
- Processes active objects as `seen & scanned`.
- Sweeps by rebuilding per-span freelists.


Example build files:

- `example/build.zig`
- `example/build.zig.zon`

## Usage

Minimal integration is one allocator swap.

### Install From GitHub

From your app root:

```sh
zig fetch --save git+https://github.com/sibexico/zigtea
```

Then wire module import in your app `build.zig`:

```zig
const zigtea_dep = b.dependency("zigtea", .{
  .target = target,
  .optimize = optimize,
});

const zigtea_mod = zigtea_dep.module("zigtea");

const exe = b.addExecutable(.{
  .name = "my-app",
  .root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
      .{ .name = "zigtea", .module = zigtea_mod },
    },
  }),
});
```

In the code:

```zig
const ZigTeaGC = @import("zigtea").ZigTeaGC;
```

```zig
const std = @import("std");
const ZigTeaGC = @import("zigtea").ZigTeaGC;

pub fn main() !void {
    var gc = ZigTeaGC.init(std.heap.page_allocator);
    defer gc.deinit();

    gc.registerCurrentStackBase();
    const allocator = gc.allocator();

  var list = try std.ArrayList(u32).initCapacity(allocator, 0);
  defer list.deinit(allocator);

  try list.append(allocator, 10);
  try list.append(allocator, 50);

    gc.collect(); // Optional manual trigger
}
```

To run the example:

```sh
cd example
zig build run
```
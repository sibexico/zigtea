const std = @import("std");

pub const ZigTeaGC = struct {
    const Self = @This();

    const span_size = 8 * 1024;
    const class_sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024 };
    const min_class = class_sizes[0];
    const max_slots = span_size / min_class;
    const bit_words = max_slots / 64;
    const free_none: u16 = 0xFFFF;

    const Span = struct {
        memory: []u8,
        class_size: usize,
        slot_count: u16,

        // Allocation state.
        alloc_bits: [bit_words]u64,
        seen_bits: [bit_words]u64,
        scanned_bits: [bit_words]u64,

        // GC queue state.
        queued: bool,
        representative: u16,
        representative_is_unique: bool,

        // Free list is intrusive
        free_head: u16,

        fn init(memory: []u8, class_size: usize) Span {
            const slots: u16 = @intCast(memory.len / class_size);

            var span = Span{
                .memory = memory,
                .class_size = class_size,
                .slot_count = slots,
                .alloc_bits = [_]u64{0} ** bit_words,
                .seen_bits = [_]u64{0} ** bit_words,
                .scanned_bits = [_]u64{0} ** bit_words,
                .queued = false,
                .representative = 0,
                .representative_is_unique = true,
                .free_head = free_none,
            };

            span.rebuildFreeList();
            return span;
        }

        fn wordMask(slot: usize) struct { word: usize, mask: u64 } {
            return .{
                .word = slot / 64,
                .mask = @as(u64, 1) << @intCast(slot % 64),
            };
        }

        fn isBitSet(bits: *const [bit_words]u64, slot: usize) bool {
            const wm = wordMask(slot);
            return (bits[wm.word] & wm.mask) != 0;
        }

        fn setBit(bits: *[bit_words]u64, slot: usize) void {
            const wm = wordMask(slot);
            bits[wm.word] |= wm.mask;
        }

        fn clearBit(bits: *[bit_words]u64, slot: usize) void {
            const wm = wordMask(slot);
            bits[wm.word] &= ~wm.mask;
        }

        fn writeNext(self: *Span, slot: u16, next: u16) void {
            const offset = @as(usize, slot) * self.class_size;
            const p: *u16 = @ptrCast(@alignCast(self.memory.ptr + offset));
            p.* = next;
        }

        fn readNext(self: *Span, slot: u16) u16 {
            const offset = @as(usize, slot) * self.class_size;
            const p: *const u16 = @ptrCast(@alignCast(self.memory.ptr + offset));
            return p.*;
        }

        fn rebuildFreeList(self: *Span) void {
            self.free_head = free_none;

            var i: i32 = @intCast(self.slot_count);
            while (i > 0) {
                i -= 1;
                const slot: usize = @intCast(i);
                if (!isBitSet(&self.alloc_bits, slot)) {
                    const slot_u16: u16 = @intCast(slot);
                    self.writeNext(slot_u16, self.free_head);
                    self.free_head = slot_u16;
                }
            }
        }

        fn allocSlot(self: *Span) ?u16 {
            if (self.free_head == free_none) return null;

            const slot = self.free_head;
            self.free_head = self.readNext(slot);
            setBit(&self.alloc_bits, slot);
            return slot;
        }

        fn freeSlot(self: *Span, slot: usize) void {
            if (!isBitSet(&self.alloc_bits, slot)) return;

            clearBit(&self.alloc_bits, slot);
            const slot_u16: u16 = @intCast(slot);
            self.writeNext(slot_u16, self.free_head);
            self.free_head = slot_u16;
        }

        fn clearMarkBits(self: *Span) void {
            self.seen_bits = [_]u64{0} ** bit_words;
            self.scanned_bits = [_]u64{0} ** bit_words;
            self.queued = false;
            self.representative = 0;
            self.representative_is_unique = true;
        }

        fn objectSlice(self: *Span, slot: usize) []u8 {
            const start = slot * self.class_size;
            const end = start + self.class_size;
            return self.memory[start..end];
        }

        fn activeWord(self: *const Span, word_idx: usize) u64 {
            return self.seen_bits[word_idx] & ~self.scanned_bits[word_idx];
        }

        fn activeCount(self: *const Span) usize {
            var total: usize = 0;
            for (0..bit_words) |i| {
                total += @popCount(self.activeWord(i));
            }
            return total;
        }

        fn slotFromAddress(self: *const Span, addr: usize) ?usize {
            const base = @intFromPtr(self.memory.ptr);
            const limit = base + self.memory.len;
            if (addr < base or addr >= limit) return null;

            const offset = addr - base;
            const slot = offset / self.class_size;
            if (slot >= self.slot_count) return null;
            return slot;
        }

        fn liveBytes(self: *const Span) usize {
            var bytes: usize = 0;
            for (0..self.slot_count) |slot| {
                if (isBitSet(&self.alloc_bits, slot)) {
                    bytes += self.class_size;
                }
            }
            return bytes;
        }
    };

    backing: std.mem.Allocator,
    spans: std.ArrayList(Span),
    queue: std.ArrayList(usize),

    stack_base: ?usize,
    bytes_since_gc: usize,
    next_gc_at: usize,

    pub fn init(backing: std.mem.Allocator) Self {
        return .{
            .backing = backing,
            .spans = .empty,
            .queue = .empty,
            .stack_base = null,
            .bytes_since_gc = 0,
            .next_gc_at = 64 * 1024,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.spans.items) |span| {
            self.backing.free(span.memory);
        }
        self.spans.deinit(self.backing);
        self.queue.deinit(self.backing);
    }

    // Helper that captures an address close to the top of the current frame
    pub fn registerCurrentStackBase(self: *Self) void {
        var marker: usize = 0;
        self.stack_base = @intFromPtr(&marker);
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn pickClassSize(len: usize, alignment: usize) ?usize {
        const needed = @max(len, alignment);
        for (class_sizes) |size| {
            if (size >= needed) return size;
        }
        return null;
    }

    fn makeSpan(self: *Self, class_size: usize) ?usize {
        const mem = self.backing.alloc(u8, span_size) catch return null;
        const span = Span.init(mem, class_size);
        self.spans.append(self.backing, span) catch {
            self.backing.free(mem);
            return null;
        };
        return self.spans.items.len - 1;
    }

    fn findSpanForClass(self: *Self, class_size: usize) ?usize {
        for (self.spans.items, 0..) |span, i| {
            if (span.class_size == class_size and span.free_head != free_none) {
                return i;
            }
        }
        return self.makeSpan(class_size);
    }

    fn stackPointer() usize {
        return @frameAddress();
    }

    fn spanIndexForAddress(self: *Self, addr: usize) ?usize {
        for (self.spans.items, 0..) |span, i| {
            const base = @intFromPtr(span.memory.ptr);
            const limit = base + span.memory.len;
            if (addr >= base and addr < limit) return i;
        }
        return null;
    }

    fn markAddress(self: *Self, addr: usize) void {
        const span_index = self.spanIndexForAddress(addr) orelse return;
        var span = &self.spans.items[span_index];

        const slot = span.slotFromAddress(addr) orelse return;
        if (!Span.isBitSet(&span.alloc_bits, slot)) return;

        if (!Span.isBitSet(&span.seen_bits, slot)) {
            Span.setBit(&span.seen_bits, slot);
        }

        if (!span.queued) {
            span.queued = true;
            span.representative = @intCast(slot);
            span.representative_is_unique = true;
            self.queue.append(self.backing, span_index) catch return;
            return;
        }

        if (span.representative != slot) {
            span.representative_is_unique = false;
        }
    }

    fn scanWordsForPointers(self: *Self, bytes: []const u8) void {
        const word_size = @sizeOf(usize);
        const word_count = bytes.len / word_size;

        var i: usize = 0;
        while (i < word_count) : (i += 1) {
            const offset = i * word_size;
            const p: *const usize = @ptrCast(@alignCast(bytes.ptr + offset));
            self.markAddress(p.*);
        }
    }

    fn scanObject(self: *Self, span_index: usize, slot: usize) void {
        var span = &self.spans.items[span_index];
        if (Span.isBitSet(&span.scanned_bits, slot)) return;

        const object_bytes = span.objectSlice(slot);
        self.scanWordsForPointers(object_bytes);

        // `scanned` means we traced pointers for this object
        Span.setBit(&span.scanned_bits, slot);
    }

    fn markFromStack(self: *Self) void {
        const base = self.stack_base orelse return;
        const sp = stackPointer();

        const lo = @min(sp, base);
        const hi = @max(sp, base);
        const word_size = @sizeOf(usize);

        var addr = lo;
        while (addr + word_size <= hi) : (addr += word_size) {
            const p: *const usize = @ptrFromInt(addr);
            self.markAddress(p.*);
        }
    }

    fn runMark(self: *Self) void {
        for (self.spans.items) |*span| {
            span.clearMarkBits();
        }
        self.queue.clearRetainingCapacity();

        self.markFromStack();

        var cursor: usize = 0;
        while (cursor < self.queue.items.len) : (cursor += 1) {
            const span_index = self.queue.items[cursor];
            var span = &self.spans.items[span_index];

            const rep = @as(usize, span.representative);
            if (span.representative_is_unique and span.activeCount() == 1 and Span.isBitSet(&span.seen_bits, rep)) {
                self.scanObject(span_index, rep);
                continue;
            }

            for (0..span.slot_count) |slot| {
                if (Span.isBitSet(&span.seen_bits, slot) and !Span.isBitSet(&span.scanned_bits, slot)) {
                    self.scanObject(span_index, slot);
                }
            }
        }
    }

    fn runSweep(self: *Self) void {
        for (self.spans.items) |*span| {
            for (0..span.slot_count) |slot| {
                const is_live = Span.isBitSet(&span.seen_bits, slot);
                if (!is_live) {
                    Span.clearBit(&span.alloc_bits, slot);
                }
            }
            span.rebuildFreeList();
        }
    }

    fn recomputeThreshold(self: *Self) void {
        var live: usize = 0;
        for (self.spans.items) |*span| {
            live += span.liveBytes();
        }

        self.bytes_since_gc = live;
        self.next_gc_at = @max(64 * 1024, live * 2);
    }

    pub fn collect(self: *Self) void {
        if (self.stack_base == null) return;

        self.runMark();
        self.runSweep();
        self.recomputeThreshold();
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;

        var self: *Self = @ptrCast(@alignCast(ctx));

        const class_size = pickClassSize(len, alignment.toByteUnits()) orelse return null;
        const span_index = self.findSpanForClass(class_size) orelse return null;
        var span = &self.spans.items[span_index];

        const slot = span.allocSlot() orelse return null;
        const offset = @as(usize, slot) * span.class_size;
        const ptr = span.memory.ptr + offset;

        self.bytes_since_gc += class_size;
        if (self.bytes_since_gc >= self.next_gc_at) {
            self.collect();
        }

        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;

        var self: *Self = @ptrCast(@alignCast(ctx));
        if (buf.len == 0) return new_len == 0;

        const addr = @intFromPtr(buf.ptr);
        const span_index = self.spanIndexForAddress(addr) orelse return false;
        const span = &self.spans.items[span_index];

        return new_len <= span.class_size;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = alignment;

        var self: *Self = @ptrCast(@alignCast(ctx));
        if (buf.len == 0) return alloc(ctx, new_len, .@"1", ret_addr);

        const addr = @intFromPtr(buf.ptr);
        const span_index = self.spanIndexForAddress(addr) orelse return null;
        const span = &self.spans.items[span_index];

        if (new_len <= span.class_size) return buf.ptr;
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;

        var self: *Self = @ptrCast(@alignCast(ctx));
        if (buf.len == 0) return;

        const addr = @intFromPtr(buf.ptr);
        const span_index = self.spanIndexForAddress(addr) orelse return;
        var span = &self.spans.items[span_index];

        const slot = span.slotFromAddress(addr) orelse return;
        span.freeSlot(slot);
    }
};

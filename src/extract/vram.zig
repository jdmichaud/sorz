//! The state a screen's set-up leaves on the console, replayed to find what its maps draw: which
//! art block each video-memory tile came from, the work RAM's bytes (and the block each came
//! from), and the layout of the layers. The extractor reads the original's maps as the console
//! does, a cell naming a tile slot, and turns each slot back into a tile of a named block; the
//! content then has no slots at all (DESIGN.md R2).
const std = @import("std");

pub const slots = 2048;
pub const ram_size = 0x10000;

/// A tile of a decoded art block: the block's ROM address and the tile's index in it.
pub const Origin = struct { block: u32, tile: u16 };

/// Where the layers' cells are in video memory: the two planes' and the window's base addresses
/// and the planes' size in cells (the window is 64 cells wide).
pub const Layout = struct {
    plane_a: u16 = 0xC000,
    plane_b: u16 = 0xE000,
    window: ?u16 = 0xD000,
    width: u16 = 64,
    height: u16 = 32,
};

pub const Place = struct { layer: enum { plane_a, plane_b, window }, x: u16, y: u16 };

pub const Vram = struct {
    /// The tile slots' bytes (32 a tile: 4 bits a pixel, the left pixel in the high nibble).
    bytes: [slots][32]u8 = @splat(@splat(0)),
    /// Each slot's origin, when the slot holds a whole tile of a block.
    origin: [slots]?Origin = @splat(null),
    /// Slots written since the display was cleared; the others are zeros.
    written: std.StaticBitSet(slots) = .empty,
    /// Whether the set-up cleared the display: an unwritten slot is then known to be blank.
    cleared: bool = false,
    ram: [ram_size]u8 = @splat(0),
    /// The block each RAM byte came from, and the byte's offset in it (block 0: none).
    ram_block: [ram_size]u32 = @splat(0),
    ram_offset: [ram_size]u32 = @splat(0),
    layout: Layout = .{},

    /// The display cleared: every tile slot zero and known blank; the work RAM kept.
    pub fn clear(self: *Vram) void {
        self.bytes = @splat(@splat(0));
        self.origin = @splat(null);
        self.written = .empty;
        self.cleared = true;
    }

    /// The work RAM from `at`, `len` bytes, cleared.
    pub fn clearRam(self: *Vram, at: u32, len: u32) void {
        const a = at & 0xFFFF;
        const n = @min(len, ram_size - a);
        @memset(self.ram[a..][0..n], 0);
        @memset(self.ram_block[a..][0..n], 0);
    }

    /// Tiles of block `block` written at video-memory address `address`.
    pub fn writeTiles(self: *Vram, address: u32, block: u32, first: u16, bytes: []const u8) error{BadData}!void {
        if (address % 32 != 0) return error.BadData;
        const n = bytes.len / 32;
        for (0..n) |k| {
            const slot = address / 32 + k;
            if (slot >= slots) break;
            @memcpy(&self.bytes[slot], bytes[k * 32 ..][0..32]);
            self.origin[slot] = if (block != 0) .{ .block = block, .tile = @intCast(first + k) } else null;
            self.written.set(slot);
        }
    }

    /// A block's bytes unpacked into the work RAM at `at`.
    pub fn unpack(self: *Vram, at: u32, block: u32, bytes: []const u8) void {
        const a = at & 0xFFFF;
        const n = @min(bytes.len, ram_size - a);
        @memcpy(self.ram[a..][0..n], bytes[0..n]);
        for (0..n) |i| {
            self.ram_block[a + i] = block;
            self.ram_offset[a + i] = @intCast(i);
        }
    }

    /// `tiles` tiles of the work RAM from `from` copied to video memory from `address`: a slot
    /// keeps its block when its 32 bytes are one whole tile of one block.
    pub fn copy(self: *Vram, from: u32, address: u32, tiles: u32) error{BadData}!void {
        if (address % 32 != 0) return error.BadData;
        for (0..tiles) |k| {
            const slot = address / 32 + k;
            if (slot >= slots) break;
            const a: usize = (from & 0xFFFF) + 32 * k;
            if (a + 32 > ram_size) return error.BadData;
            @memcpy(&self.bytes[slot], self.ram[a..][0..32]);
            self.written.set(slot);
            const b = self.ram_block[a];
            const off = self.ram_offset[a];
            var whole = b != 0 and off % 32 == 0;
            for (1..32) |i| whole = whole and self.ram_block[a + i] == b and self.ram_offset[a + i] == off + i;
            self.origin[slot] = if (whole) .{ .block = b, .tile = @intCast(off / 32) } else null;
        }
    }

    pub fn ramWord(self: *const Vram, at: u32) u16 {
        const a = at & 0xFFFF;
        return @as(u16, self.ram[a]) << 8 | self.ram[(a + 1) & 0xFFFF];
    }

    pub fn ramLong(self: *const Vram, at: u32) u32 {
        return @as(u32, self.ramWord(at)) << 16 | self.ramWord(at + 2);
    }

    /// The layer and cell of video-memory address `address` in the layout.
    pub fn place(self: *const Vram, address: u16) ?Place {
        const l = self.layout;
        const plane_bytes: u32 = @as(u32, l.width) * l.height * 2;
        const row: u32 = @as(u32, l.width) * 2;
        if (address >= l.plane_a and address < @as(u32, l.plane_a) + plane_bytes) {
            const off = address - l.plane_a;
            return .{ .layer = .plane_a, .x = @intCast((off % row) / 2), .y = @intCast(off / row) };
        }
        if (address >= l.plane_b and address < @as(u32, l.plane_b) + plane_bytes) {
            const off = address - l.plane_b;
            return .{ .layer = .plane_b, .x = @intCast((off % row) / 2), .y = @intCast(off / row) };
        }
        if (l.window) |w| if (address >= w and address < @as(u32, w) + 64 * 32 * 2) {
            const off = address - w;
            return .{ .layer = .window, .x = @intCast((off % 128) / 2), .y = @intCast(off / 128) };
        };
        return null;
    }
};

/// The video-memory address of a write command long (its bits 29-16 and 1-0).
pub fn commandAddress(cmd: u32) u16 {
    return @intCast(((cmd >> 16) & 0x3FFF) | ((cmd & 3) << 14));
}

test "a copy keeps the blocks of whole tiles, and a straddling tile has none" {
    const v = try std.testing.allocator.create(Vram);
    defer std.testing.allocator.destroy(v);
    v.* = .{};
    var a: [64]u8 = undefined;
    @memset(&a, 0x11);
    var b: [48]u8 = undefined;
    @memset(&b, 0x22);
    v.unpack(0xFF0000, 0x100, &a);
    v.unpack(0xFF0040, 0x200, &b);
    try v.copy(0xFF0000, 0x400, 3);
    try std.testing.expectEqual(Origin{ .block = 0x100, .tile = 1 }, v.origin[0x21].?);
    try std.testing.expectEqual(Origin{ .block = 0x200, .tile = 0 }, v.origin[0x22].?);
    try v.copy(0xFF0010, 0x800, 1);
    try std.testing.expect(v.origin[0x40] == null and v.written.isSet(0x40));
    try std.testing.expectEqual(@as(u8, 0x11), v.bytes[0x40][0]);
}

test "an address's layer and cell" {
    const v: Vram = .{};
    try std.testing.expectEqual(Place{ .layer = .plane_a, .x = 2, .y = 3 }, v.place(0xC000 + 3 * 128 + 4).?);
    try std.testing.expectEqual(Place{ .layer = .window, .x = 0, .y = 1 }, v.place(0xD080).?);
    try std.testing.expectEqual(Place{ .layer = .plane_b, .x = 63, .y = 31 }, v.place(0xEFFE).?);
    try std.testing.expect(v.place(0x1000) == null);
    try std.testing.expectEqual(@as(u16, 0xC59C), commandAddress(0x459C0003));
}

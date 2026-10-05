//! The art a round streams in while it plays (gameplay port map; sor-remaster's
//! sim/nemesis_stream.zig): the loads (the lists at 0x8672) queue Nemesis blocks, whose head
//! block the logic starts in its tick's second half (0x84BA: its header and code table) and
//! whose tiles the display ticks decode, five at a time (0x8510), until the block ends. Each
//! display tick's decoding is work the 68000 does before the sound's driver looks at the Z80, so
//! the sound's timing reads it: the tiles decoded, the codes read (0x81DC), those written out in
//! full (the escape code, 0x8228) and the bytes read (0x8240's refills). This module decodes the
//! blocks as 0x8510 does, register by register, to count them; the art itself is the extractor's
//! (nemesis.zig).
const std = @import("std");
const sorz = @import("sorz");
const rom_mod = @import("rom.zig");

const Streamed = sorz.content.round.Streamed;
const u16be = rom_mod.u16be;

pub const Error = error{ OutOfMemory, BadData };

/// The tiles a display tick decodes (0x8510: moveq #5).
pub const tiles_a_display_tick = 5;

/// Block `at`'s display ticks of decoding: each one's tiles and reads.
pub fn batches(arena: std.mem.Allocator, rom: []const u8, at: u32) Error![]const Streamed {
    var d: Decoder = .{ .rom = rom, .a0 = at };
    const header = try d.word();
    d.xor = header & 0x8000 != 0;
    var tiles: u32 = header & 0x7FFF;
    try d.buildTable();
    d.bits = try d.word();
    d.bit_count = 16;
    var out: std.ArrayList(Streamed) = .empty;
    while (tiles != 0) {
        d.codes = 0;
        d.inline_codes = 0;
        d.bytes = 0;
        var n: u32 = 0;
        while (n < tiles_a_display_tick and tiles != 0) : (n += 1) {
            try d.tile();
            tiles -= 1;
        }
        try out.append(arena, .{
            .tiles = @intCast(n),
            .codes = std.math.cast(u16, d.codes) orelse return error.BadData,
            .long_codes = std.math.cast(u8, d.inline_codes) orelse return error.BadData,
            .bytes = std.math.cast(u16, d.bytes) orelse return error.BadData,
        });
    }
    return out.items;
}

/// The decoder's registers (0x81DC to 0x827E), its code table (0x8280), its counts.
const Decoder = struct {
    rom: []const u8,
    a0: u32,
    table: [0x200]u8 = @splat(0),
    run: u16 = 0, // d0
    nibble: u16 = 0, // d1
    bits: u16 = 0, // d5's low word
    bit_count: u16 = 0, // d6
    xor: bool = false,
    codes: u32 = 0,
    inline_codes: u32 = 0,
    bytes: u32 = 0,

    fn byte(d: *Decoder) Error!u8 {
        if (d.a0 >= d.rom.len) return error.BadData;
        const b = d.rom[d.a0];
        d.a0 += 1;
        return b;
    }

    fn word(d: *Decoder) Error!u16 {
        const hi = try d.byte();
        return @as(u16, hi) << 8 | try d.byte();
    }

    /// 0x8280: for each nibble value, codes of up to 8 bits and their repeat counts.
    fn buildTable(d: *Decoder) Error!void {
        var d0 = try d.byte();
        while (d0 != 0xFF) {
            var d7: u16 = d0;
            while (true) {
                d0 = try d.byte();
                if (d0 >= 0x80) break;
                d7 = (d7 & 0x0F) | (d0 & 0x70) | (@as(u16, d0 & 0x0F) << 8);
                const length: u4 = @intCast(d0 & 0x0F);
                const shift: u16 = 8 -% @as(u16, length);
                const code: u16 = try d.byte();
                if (shift == 0) {
                    d.put(code * 2, d7);
                } else {
                    if (shift > 8) return error.BadData;
                    var index: u16 = (code << @intCast(shift)) *% 2;
                    var count: u16 = (@as(u16, 1) << @intCast(shift)) - 1;
                    while (true) {
                        d.put(index, d7);
                        index +%= 2;
                        if (count == 0) break;
                        count -= 1;
                    }
                }
            }
        }
    }

    fn put(d: *Decoder, at: u16, v: u16) void {
        std.mem.writeInt(u16, d.table[at & 0x1FF ..][0..2], v, .big);
    }

    fn refill(d: *Decoder) Error!void {
        d.bits = (d.bits << 8) | try d.byte();
        d.bytes += 1;
    }

    /// One tile: eight rows of eight nibbles; the run in progress continues.
    fn tile(d: *Decoder) Error!void {
        var rows: u16 = 8;
        while (rows > 0) : (rows -= 1) {
            var left: u16 = 8;
            while (true) {
                var filled = false;
                while (true) {
                    if (d.run == 0) {
                        d.run = 0xFFFF;
                        break;
                    }
                    d.run -%= 1;
                    left -= 1;
                    if (left == 0) {
                        filled = true;
                        break;
                    }
                }
                if (filled) break;
                try d.nextCode();
                left -= 1;
                if (left == 0) break;
            }
        }
    }

    /// 0x81DC: the next code, its nibble and its repeats.
    fn nextCode(d: *Decoder) Error!void {
        d.codes += 1;
        const d7 = d.bit_count -% 8;
        const peek: u16 = d.bits >> @intCast(d7 & 0xF);
        if (@as(u8, @truncate(peek)) >= 0xFC) {
            d.inline_codes += 1;
            d.bit_count -%= 6;
            if (d.bit_count < 9) {
                d.bit_count += 8;
                try d.refill();
            }
            d.bit_count -%= 7;
            const v: u16 = d.bits >> @intCast(d.bit_count & 0xF);
            d.nibble = v & 0xF;
            d.run = (v & 0x70) >> 4;
            if (d.bit_count < 9) {
                d.bit_count += 8;
                try d.refill();
            }
            return;
        }
        const index: u16 = (peek & 0xFF) * 2;
        const length: u16 = @bitCast(@as(i16, @as(i8, @bitCast(d.table[index]))));
        d.bit_count -%= length;
        if (d.bit_count < 9) {
            d.bit_count += 8;
            try d.refill();
        }
        const entry: u16 = d.table[index + 1];
        d.nibble = entry & 0xF;
        d.run = (entry & 0xF0) >> 4;
    }
};

/// A load of a sequence (`schedule`): its blocks, and when it is queued.
pub const Load = struct {
    /// The ticks after the last load's end (or the sequence's start) that it is queued at.
    after: u32,
    blocks: []const []const Streamed,
    /// Queued before its tick looks at the queue's head (0x84BA, after the objects: an object's
    /// load, the camera's): its first block starts in that tick, not the next.
    before_head: bool = false,
};

/// The display ticks of a sequence of loads, from the end of the tick the sequence counts from:
/// index 0 is the display tick that ends it, 1 the next tick's middle, 2 its end... Each load's
/// first block starts at the tick after it is queued (0x84BA in the tick's second half, after the
/// level's events; an object's load, in its own tick) and is decoded from that tick's end; a block finished in a tick's middle lets the next start in the
/// same tick, at its end at the next. A load is over in the tick a next block would start in,
/// whose end sees the queue empty; the next load is queued `after` ticks later (the first,
/// `after` ticks after the sequence's tick; a load of no block takes its tick only).
pub fn schedule(arena: std.mem.Allocator, loads: []const Load) Error![]const Streamed {
    var out: std.ArrayList(Streamed) = .empty;
    // The tick each load is queued at.
    var tick: u32 = 0;
    for (loads) |l| {
        tick += l.after;
        if (l.blocks.len == 0) continue;
        var start = if (l.before_head) tick else tick + 1;
        for (l.blocks) |b| {
            // The block's display ticks: its start tick's end, then each tick's middle and end.
            const first = 2 * start;
            try put(arena, &out, first, b);
            const n: u32 = @intCast(b.len);
            const last = first + n - 1;
            // The next block starts in the tick of the last display tick if it was a middle
            // (odd), else in the next.
            start = if (last % 2 == 1) (last + 1) / 2 else last / 2 + 1;
        }
        // The queue is seen empty in the tick a next block would start in (a middle's tick, or
        // the tick after an end's).
        tick = start;
    }
    return out.items;
}

fn put(arena: std.mem.Allocator, out: *std.ArrayList(Streamed), from: u32, b: []const Streamed) Error!void {
    while (out.items.len < from + b.len) try out.append(arena, .{});
    for (b, 0..) |s, i| out.items[from + i] = s;
}

test "a block's display ticks: five tiles each, the run carried across" {
    // A block of 6 tiles, every nibble 0: one code of 1 bit (0) for value 0 repeating 8 times.
    // Header: 6 tiles; table: value 0, (count 8 = 7 + 1, length 1), code 0; end.
    var rom: [64]u8 = @splat(0);
    rom[0] = 0;
    rom[1] = 6;
    rom[2] = 0x00; // value 0
    rom[3] = 0x71; // repeats 7 (8 nibbles), length 1
    rom[4] = 0x00; // code 0
    rom[5] = 0xFF; // end of the table
    // The codes: all zero bits.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const b = try batches(arena.allocator(), &rom, 0);
    try std.testing.expectEqual(@as(usize, 2), b.len);
    try std.testing.expectEqual(@as(u8, 5), b[0].tiles);
    try std.testing.expectEqual(@as(u8, 1), b[1].tiles);
    // A row a code: 8 rows a tile.
    try std.testing.expectEqual(@as(u16, 40), b[0].codes);
    try std.testing.expectEqual(@as(u16, 8), b[1].codes);
}

test "loads in display ticks: the next block in a middle's tick, or the next tick" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const one: Streamed = .{ .tiles = 5 };
    // A block of two display ticks (its start's end, the next middle), then one of three.
    const s = try schedule(arena.allocator(), &.{.{ .after = 0, .blocks = &.{ &.{ one, one }, &.{ one, one, one } } }});
    // Queued at tick 0: the first block from tick 1's end (2) to tick 2's middle (3); the second
    // starts in tick 2, from its end (4) to tick 3's end (6).
    try std.testing.expectEqual(@as(usize, 7), s.len);
    for (s, 0..) |x, i| try std.testing.expectEqual(@as(u8, if (i >= 2) 5 else 0), x.tiles);
}

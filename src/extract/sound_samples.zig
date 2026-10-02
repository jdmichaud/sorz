//! The Z80 player's samples (sound port map 2.8): 17 samples, 0-8 in the Z80 program's image
//! (Kosinski-packed at 0x795A2, its first 0x1EC7 bytes copied to the Z80, the table at Z80
//! 0x019B), 9-16 in the ROM bank at 0x78000 (its table there). A sample is a 16-byte table of
//! steps then 4-bit codes, the first half of each byte first: a code c of 1-15 adds table[c] to the
//! DAC's value (from 0x80, wrapping at 8 bits), a code 0 repeats the last step table[0] times (256
//! when table[0] is 0). Samples 0-3 are the drums, 4 is empty, 5-16 the voices; 5-14 are five
//! recordings each at two rates.
const std = @import("std");
const content = @import("sorz").audio.content;
const kosinski = @import("kosinski.zig");
const Refusal = @import("sound_tracks.zig").Refusal;

pub const z80_program = 0x795A2;
pub const z80_copy = 0x1EC7;
pub const z80_table = 0x019B;
pub const bank = 0x78000;
pub const count = 17;
pub const first_voice = 5;

/// A sample's bytes as the player reads them, and where they are.
pub const Raw = struct {
    bytes: []const u8,
    delay: u8,
    banked: bool,
    address: u32,
};

/// The 17 samples' bytes.
pub fn raw(arena: std.mem.Allocator, rom: []const u8, refusal: *Refusal) ![count]Raw {
    const program = kosinski.decompress(arena, rom, z80_program) catch return refusal.refuse("the Z80 program does not unpack", z80_program);
    if (program.bytes.len < z80_copy) return refusal.refuse("the Z80 program is too short", z80_program);
    const z = program.bytes[0..z80_copy];
    var out: [count]Raw = undefined;
    for (&out, 0..) |*s, n| {
        const banked = n >= 9;
        const e = if (banked) rom[bank + 5 * (n - 9) ..][0..5] else z[z80_table + 5 * n ..][0..5];
        const at = @as(u32, e[0]) | @as(u32, e[1]) << 8;
        const len = @as(u32, e[2]) | @as(u32, e[3]) << 8;
        const address = if (banked) bank + at else at;
        const src = if (banked) rom else z;
        if (address + len > src.len) return refusal.refuse("a sample past its memory's end", address);
        s.* = .{ .bytes = src[address..][0..len], .delay = e[4], .banked = banked, .address = address };
    }
    return out;
}

/// The DAC values of a sample's bytes, and how the player paces each one.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8) !struct { values: []u8, pace: []content.Pace } {
    var values: std.ArrayList(u8) = .empty;
    var pace: std.ArrayList(content.Pace) = .empty;
    if (bytes.len >= 16) {
        const table = bytes[0..16];
        const run: usize = if (table[0] == 0) 256 else table[0];
        var v: u8 = 0x80;
        var last: u8 = 0;
        for (bytes[16..]) |b| {
            for ([2]u8{ b >> 4, b & 15 }, [2]bool{ true, false }) |code, first| {
                if (code != 0) {
                    last = table[code];
                    v +%= last;
                    try values.append(arena, v);
                    try pace.append(arena, if (first) .first else .second);
                } else for (0..run) |k| {
                    v +%= last;
                    try values.append(arena, v);
                    try pace.append(arena, if (first)
                        (if (k == 0) .first_repeat_start else .first_repeat)
                    else if (k == 0) .second_repeat_start else .second_repeat);
                }
            }
        }
    }
    return .{ .values = values.items, .pace = pace.items };
}

const testing = std.testing;

test "a sample's values and pace from its codes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bytes: [16 + 3]u8 = undefined;
    const table = [16]u8{ 2, 0, 1, 2, 6, 12, 24, 48, 96, 160, 208, 232, 244, 250, 254, 255 };
    @memcpy(bytes[0..16], &table);
    bytes[16] = 0x34; // +2, +6
    bytes[17] = 0x03; // repeat +6 twice, +2
    bytes[18] = 0xF1; // -1, +0
    const d = try decode(arena.allocator(), &bytes);
    try testing.expectEqualSlices(u8, &.{ 0x82, 0x88, 0x8E, 0x94, 0x96, 0x95, 0x95 }, d.values);
    try testing.expectEqualSlices(content.Pace, &.{ .first, .second, .first_repeat_start, .first_repeat, .second, .first, .second }, d.pace);
}

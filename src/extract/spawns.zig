//! What an enemy's spawn entry means to the enemy's code (the round's script's records,
//! scripts.zig): the three bytes its handler reads, +$40 its variant, +$41 its offsets and +$49
//! its strength, decoded by its type into its way in (the type's table of first states by the
//! variant's low nibble: 0xDDDA, 0xD6BC, 0xE94A, 0xF0F6), named traits, the place it keeps from
//! its target, and its strength.
const std = @import("std");
const sorz = @import("sorz");
const round = sorz.content.round;

pub const Error = error{BadData};

/// The offsets an enemy keeps beside its target, by the nibbles of its +$41 (0x945A).
const offsets_table = 0x9484;

pub const Decoded = struct {
    entrance: round.Entrance,
    traits: round.Traits,
    offset: round.Offset,
    strength: u8,
};

/// What the bytes +$40 (`variant`), +$41 (`offsets`) and +$49 (`strength`) of an enemy of type
/// `kind` mean.
pub fn decode(rom: []const u8, kind: u8, variant: u8, offsets: u8, strength: u8) Error!Decoded {
    if (strength > 2) return error.BadData;
    const v = variant & 0x7F;
    const way = v & 0xF;
    var t: round.Traits = .empty;
    if (variant & 0x80 != 0) t.insert(.waits_for_camera);
    const entrance: round.Entrance = switch (kind) {
        0x22 => blk: {
            if (v & 0x20 != 0) t.insert(.slow);
            break :blk switch (way) {
                0 => .close_in,
                1 => .edge,
                2, 5 => .wait,
                3 => .approach,
                4 => .shutter,
                6 => .square_up,
                else => return error.BadData,
            };
        },
        0x20 => switch (way) {
            0 => .close_in,
            1 => .jump_in,
            2 => .size_up,
            else => return error.BadData,
        },
        0x25 => blk: {
            if (v & 0x10 != 0) t.insert(.flips_away);
            if (v & 0x20 != 0) t.insert(.slow);
            if (v & 0x40 != 0) t.insert(.drops_in);
            if (v != 0) t.insert(.flips_at_close_range);
            break :blk switch (way) {
                0, 1 => .approach,
                2 => .close_in,
                3 => .enter,
                4 => .circle,
                else => return error.BadData,
            };
        },
        0x26 => blk: {
            if (v & 0x10 != 0) t.insert(.unflinching);
            if (v & 0x02 != 0) t.insert(.walks_off);
            break :blk switch (way) {
                0 => .follow,
                1 => .shutter,
                2, 3 => .close_in,
                else => return error.BadData,
            };
        },
        0x21 => blk: {
            if (v == 1) t.insert(.closes_in_after_lurking);
            break :blk .approach;
        },
        0x23 => blk: {
            if (v != 0) t.insert(.pipe_b);
            break :blk .approach;
        },
        0x24 => blk: {
            if (v != 0) t.insert(.slides);
            break :blk .approach;
        },
        // The others take up the fight one way.
        else => .approach,
    };
    return .{
        .entrance = entrance,
        .traits = t,
        .offset = .{
            .x = rom[offsets_table + @as(u32, offsets >> 4)],
            .depth = @as(i8, @bitCast(rom[offsets_table + @as(u32, offsets & 0xF)])),
        },
        .strength = strength,
    };
}

test "a variant's meaning by type" {
    var rom: [0x9500]u8 = @splat(0);
    for (0..16) |k| rom[offsets_table + k] = @intCast(k * 8);
    rom[offsets_table + 15] = 0xF0;
    const d = try decode(&rom, 0x22, 0xA0, 0x3F, 0);
    try std.testing.expectEqual(round.Entrance.close_in, d.entrance);
    try std.testing.expect(d.traits.contains(.waits_for_camera) and d.traits.contains(.slow));
    try std.testing.expectEqual(round.Offset{ .x = 24, .depth = -16 }, d.offset);
    try std.testing.expectEqual(round.Entrance.follow, (try decode(&rom, 0x26, 0x10, 0, 0)).entrance);
    try std.testing.expect((try decode(&rom, 0x26, 0x12, 0, 0)).traits.contains(.walks_off));
    try std.testing.expectError(error.BadData, decode(&rom, 0x22, 0x07, 0, 0));
}

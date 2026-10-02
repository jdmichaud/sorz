//! The enemies' and the bosses' colours (graphics port map 2.3; the wave loader 0xF46 and 0x576):
//! - the common enemies' colour variants (`ObjectPalettes` 0x1FACC): each type's first variant is
//!   at 0xA5A (Galsia 0, Signal 3, the acrobat 6, the brawler and the juggler 9), and a wave's
//!   palette byte adds the variant; variants 0 to 8 are a pair of lists, for palette 1 and for
//!   palette 2 (an enemy takes the palette its wave gives it), 9 to 11 one list for palette 1;
//! - the bosses' variants (the boss kinds at 0x1C3A8, each a table of lists at 0x1C3CC; round 8's
//!   Mr. X a list of his own), which the round's boss (0x1C378) and the waves load on palette 1.
const std = @import("std");
const sorz = @import("sorz");
const art = sorz.content.art;
const rom_mod = @import("rom.zig");
const builder_mod = @import("builder.zig");
const Builder = builder_mod.Builder;

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;

pub const enemy_lists = 0x1FACC;

/// The owner of each of the 12 entries of the enemies' table, by the types' first entries
/// (0xA5A).
const enemy_owners = [_][]const u8{ "galsia", "galsia", "galsia", "signal", "signal", "signal", "acrobat", "acrobat", "acrobat", "brawler", "brawler", "brawler" };

/// The bosses' lists of variants (0x1C3CC), by boss kind (0x1C3A8: $55, $56, $57, $58, $30).
const boss_variants = [_]struct { owner: []const u8, first: u32, count: u32, kind: u8 }{
    .{ .owner = "round2_boss", .first = 0, .count = 3, .kind = 0x55 },
    .{ .owner = "antonio", .first = 3, .count = 2, .kind = 0x56 },
    .{ .owner = "round4_boss", .first = 5, .count = 3, .kind = 0x57 },
    .{ .owner = "twins", .first = 8, .count = 2, .kind = 0x58 },
    .{ .owner = "round3_boss", .first = 10, .count = 3, .kind = 0x30 },
};
pub const boss_lists = 0x1C3CC;
/// Mr. X's list (round 8's entry of 0x1C378).
pub const mrx_list = 0x35172;

fn add(b: *Builder, name: []const u8, list: u32, why: []const u8) !void {
    var p = try builder_mod.paletteList(b.rom, list);
    p.provenance = try std.fmt.allocPrint(b.arena, "ROM 0x{X:0>5}: a palette list, {s}", .{ list, why });
    try b.palette(name, p);
    try b.origin(name, .{ .palette = list });
}

pub fn extract(b: *Builder) !void {
    const rom = b.rom;
    const arena = b.arena;
    for (enemy_owners, 0..) |owner, i| {
        const e: u32 = enemy_lists + @as(u32, u16be(rom, @intCast(enemy_lists + 2 * i)));
        const variant = i % 3 + 1;
        if (i < 9) {
            for (0..2) |k| {
                const list = e + @as(u32, u16be(rom, @intCast(e + 2 * k)));
                try add(b, try std.fmt.allocPrint(arena, "{s}/variant_{d}_palette_{d}", .{ owner, variant, k + 1 }), list, try std.fmt.allocPrint(arena, "{s}'s colour variant {d} on palette {d} (the enemies' table 0x1FACC, entry {d}, loaded by 0xF46)", .{ owner, variant, k + 1, i }));
            }
        } else {
            try add(b, try std.fmt.allocPrint(arena, "{s}/variant_{d}", .{ owner, variant }), e, try std.fmt.allocPrint(arena, "the brawler's and the juggler's colour variant {d} on palette 1 (the enemies' table 0x1FACC, entry {d}, loaded by 0xF46)", .{ variant, i }));
        }
    }
    for (boss_variants) |bv| {
        for (0..bv.count) |k| {
            const list = u32be(rom, boss_lists + 4 * (bv.first + @as(u32, @intCast(k))));
            try add(b, try std.fmt.allocPrint(arena, "{s}/variant_{d}", .{ bv.owner, k + 1 }), list, try std.fmt.allocPrint(arena, "the colour variant {d} of the boss of type ${X:0>2} on palette 1 (0x1C3CC, the boss kinds 0x1C3A8)", .{ k + 1, bv.kind }));
        }
    }
    try add(b, "mrx/colours", mrx_list, "Mr. X's colours on palette 1 (round 8's boss, 0x1C378)");
}

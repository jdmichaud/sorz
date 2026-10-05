//! Round 8's corridor (docs/content.md, `entities/NAME.json`): each a definition read from its
//! animation set and from the immediate values of the code that runs it, with the place of each
//! in its provenance.
//!
//! - The gold statue (type $15, its handler 0x760C, sor-remaster's obj/statue.zig): it stands on
//!   its pedestal at its height, with no shadow, from its second tick drawn behind what stands
//!   at its depth (0x763C), and goes when the camera leaves it behind (0x6A70).
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");
const items = @import("items.zig");

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const entryFrames = items.entryFrames;

/// `move.w #N,(D,a0)` at `at`: N, the displacement checked.
fn moveWord(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at + 4) != displacement) return error.BadData;
    return immediate(rom, at, &.{ 0x31, 0x7C }, 2);
}

/// A definition of the round's art set at `set` (`round8/PREFIX_NN`).
fn def(arena: std.mem.Allocator, rom: []const u8, prefix: []const u8, set: u32) Error!Def {
    return .{ .arena = arena, .rom = rom, .dir = "round8", .prefix = prefix, .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
}

/// The statue (type $15): its stand (entry 0, held still), its height; a record with a variant
/// takes entry 2 (0x7630; Mr. X's room's, not the corridor's).
fn statue(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x7622, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "statue", set);
    try d.animations.append(arena, .{ .name = "stand", .loop = true, .frames = try entryFrames(&d, "stand", 0, null, false) });
    try d.number("height", try moveWord(rom, 0x761C, 24), "ROM 0x0761C: move.w #N,(24,a0)");
    // From its second tick, behind what stands at its depth (0x763C: ori.b #$80,(1,a0)); no
    // shadow (0x6ABC: ori.b #$40).
    if (u32be(rom, 0x763C) != 0x0028_0080 or u16be(rom, 0x7640) != 1) return error.BadData;
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A70)");
    return .{
        .name = "statue",
        .provenance = try std.fmt.allocPrint(arena, "round 8's gold statues, type $15 (handler 0x760C): the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "statue",
        .numbers = d.numbers.items,
        .animations = d.animations.items,
    };
}

pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try statue(arena, rom));
}

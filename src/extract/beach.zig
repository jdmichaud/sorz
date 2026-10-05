//! Round 3's scenery, the beach's (docs/content.md, `entities/NAME.json`): each a definition read
//! from its animation set and from the immediate values of the code that runs it, with the place
//! of each in its provenance.
//!
//! - The lamp (type $4E, its handler 0x71DC, sor-remaster's obj/round3.zig): it stands at its
//!   height, drawn behind what stands at its depth; once the boss's bar shows, it is lit.
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

/// A definition of the round's art set at `set` (`round3/PREFIX_NN`).
fn def(arena: std.mem.Allocator, rom: []const u8, prefix: []const u8, set: u32) Error!Def {
    return .{ .arena = arena, .rom = rom, .dir = "round3", .prefix = prefix, .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
}

/// The lamp (type $4E): its two frames (entry 0, held still: unlit, lit), its height.
fn lamp(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x71F4, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "lamp", set);
    const frames = try entryFrames(&d, "lamp", 0, null, true);
    if (frames.len != 2) return error.BadData;
    try d.animations.append(arena, .{ .name = "lamp", .loop = true, .frames = frames });
    try d.number("height", try moveWord(rom, 0x71EE, 24), "ROM 0x071EE: move.w #N,(24,a0)");
    // Lit (0x71FE): the boss's section begun ($FFFA05 bit 6) and a boss's bar shown ($FFF50E).
    if (u32be(rom, 0x71FE) != 0x08380006 or u16be(rom, 0x7202) != 0xFA05 or u16be(rom, 0x7206) != 0x3038 or u16be(rom, 0x7208) != 0xF50E) return error.BadData;
    return .{
        .name = "lamp",
        .provenance = try std.fmt.allocPrint(arena, "round 3's lamps, type $4E (handler 0x71DC): the animation set at ROM 0x{X:0>5}; lit (its second frame) once the boss's bar shows (0x71FE){s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "lamp",
        .numbers = d.numbers.items,
        .animations = d.animations.items,
    };
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try lamp(arena, rom));
}

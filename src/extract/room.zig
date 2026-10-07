//! Mr. X's room's things (docs/content.md, `entities/NAME.json`), round 8's last room: its door
//! (type $46, its handler 0x7662) and the door's splinters (type $44, 0x7644). Each a definition
//! read from its animation set and from the immediate values of the code that runs it, with the
//! place of each in its provenance. Their sprites are round 8's (`round8/door_NN`,
//! `round8/splinters_NN`).
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");
const boss_r3 = @import("boss_r3.zig");
const items = @import("items.zig");

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const s16be = rom_mod.s16be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const moveq = entities.moveq;
const quick = entities.quick;

/// The things' first state's set-up (0x6ABC): no shadow, the set's animation of word 0, the next
/// state.
const thing_start = 0x6ABC;

/// A definition of the round's art set at `set` (`round8/PREFIX_NN`).
fn def(arena: std.mem.Allocator, rom: []const u8, prefix: []const u8, set: u32) Error!Def {
    return .{ .arena = arena, .rom = rom, .dir = "round8", .prefix = prefix, .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
}

/// `lea (N).l,a1` at `at`: N.
fn setAt(rom: []const u8, at: u32) Error!u32 {
    return @bitCast(try immediate(rom, at, &.{ 0x43, 0xF9 }, 4));
}

/// `jsr`/`jmp (d16,pc)` at `at`: whether it goes to `to`.
fn callsTo(rom: []const u8, at: u32, to: u32) bool {
    return u16be(rom, at) & 0xFFBF == 0x4EBA and @as(i32, @intCast(at + 2)) + s16be(rom, at + 2) == to;
}

/// The splinters' table (0x7698: lea at 0x7698): 6 bytes each, their speeds across and up (words
/// in 1/256 of a pixel), their frame, an index of their offset across (0x773A's bytes).
const splinter_table = 0x773E;
const splinter_offsets = 0x773A;

/// The door (type $46): standing where the players' walk in puts it, it breaks at its second
/// tick, its sound, its splinters flying (in the weapons' places, as many as are free), its cells
/// of the round's plane cleared, the room's opening asked for (`$FFFA0D`), and it goes
/// (behaviours/door.zig).
pub fn door(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set = try setAt(rom, 0x766E);
    if (!callsTo(rom, 0x7674, thing_start)) return error.BadData;
    var d = try def(arena, rom, "door", set);
    // Its frame's box is no box of the things' (it meets nothing): left out.
    try d.animations.append(arena, .{ .name = "shut", .loop = true, .frames = try items.entryFrames(&d, "shut", 0, null, true) });
    try d.sound("break", @bitCast(@as(i8, @intCast(try moveq(rom, 0x7678, 7)))));
    if (u16be(rom, 0x7688) != 0x0444) return error.BadData;
    try d.number("splinter_x", -@as(i32, u16be(rom, 0x768A)), "ROM 0x07688: subi.w #N,d4 (the splinters from the door's place across)");
    try d.number("splinter_depth", -(try quick(rom, 0x7690, 0x5145)), "ROM 0x07690: subq.w #N,d5 (in depth)");
    try d.number("splinter_rise", try quick(rom, 0x76A2, 0x5146), "ROM 0x076A2: subq.w #N,d6 (each splinter higher than the last, the first too)");
    if (u16be(rom, 0x7698) != 0x45FA or 0x769A + @as(i32, s16be(rom, 0x769A)) != splinter_table) return error.BadData;
    if (u16be(rom, 0x76D2) != 0x103B or 0x76D4 + @as(i32, rom[0x76D5]) != splinter_offsets) return error.BadData;
    const count: usize = @intCast(try moveq(rom, 0x7696, 3) + 1);
    const x = try arena.alloc(i32, count);
    const up = try arena.alloc(i32, count);
    const frame = try arena.alloc(i32, count);
    const offset = try arena.alloc(i32, count);
    for (0..count) |k| {
        const e = splinter_table + 6 * @as(u32, @intCast(k));
        x[k] = s16be(rom, e);
        up[k] = s16be(rom, e + 2);
        frame[k] = rom[e + 4];
        if (rom[e + 5] >= 4) return error.BadData;
        offset[k] = rom[splinter_offsets + @as(u32, rom[e + 5])];
    }
    try d.table("splinter_speed_x", x, "ROM 0x0773E: by the splinter, 6 bytes each: its speed across (a word, in 1/256 of a pixel)");
    try d.table("splinter_speed_up", up, "ROM 0x07740: up");
    try d.table("splinter_frame", frame, "ROM 0x07742: its frame");
    try d.table("splinter_offset", offset, "ROM 0x07743: the index of its offset across, among ROM 0x0773A's bytes");
    return .{
        .name = "door",
        .provenance = try std.fmt.allocPrint(arena, "the door of Mr. X's room, type $46 (handler 0x7662, its states at 0x766A): the animation set at ROM 0x{X:0>5}, its first animation (0x6ABC: no shadow); its splinters made at 0x769C, in the weapons' places (0x7EA8){s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "door",
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .animations = d.animations.items,
    };
}

/// A splinter of the door (type $44): it shows its frame and flies, falling, until it lands on
/// the floor; then it goes (behaviours/door_splinter.zig).
pub fn splinter(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set = try setAt(rom, 0x7650);
    if (!callsTo(rom, 0x7656, thing_start) or u32be(rom, 0x765A) != 0x1168000B or u16be(rom, 0x765E) != 0x000A) return error.BadData;
    var d = try def(arena, rom, "splinters", set);
    try d.animations.append(arena, .{ .name = "fly", .loop = true, .frames = try boss_r3.sideFrames(&d, 0, false) });
    if (u16be(rom, 0x6C48) != 0x06A8 or u16be(rom, 0x6C4E) != 36) return error.BadData;
    try d.number("gravity", @bitCast(u32be(rom, 0x6C4A)), "ROM 0x06C48: addi.l #N,(36,a0) (0x6C3A: its fall, until the floor)");
    return .{
        .name = "door_splinter",
        .provenance = try std.fmt.allocPrint(arena, "a splinter of the door of Mr. X's room, type $44 (handler 0x7644, its states at 0x764C: 0x7650, then the things' flight 0x6C3A): the animation set at ROM 0x{X:0>5}, its first animation (0x6ABC: no shadow), held at the frame its maker gives (0x765A){s}", .{ set, d.number_notes.items }),
        .family = .effect,
        .team = .neutral,
        .behaviour = "door_splinter",
        .numbers = d.numbers.items,
        .animations = d.animations.items,
    };
}

pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try door(arena, rom));
    try out.append(arena, try splinter(arena, rom));
}

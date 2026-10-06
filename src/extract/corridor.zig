//! Round 8's corridor (docs/content.md, `entities/NAME.json`): each a definition read from its
//! animation set and from the immediate values of the code that runs it, with the place of each
//! in its provenance.
//!
//! - The gold statue (type $15, its handler 0x760C, sor-remaster's obj/statue.zig): it stands on
//!   its pedestal at its height, with no shadow, from its second tick drawn behind what stands
//!   at its depth (0x763C), and goes when the camera leaves it behind (0x6A70).
//! - The covered trolley (type $45, 0x7534, sor-remaster's obj/trolley.zig): hidden until the
//!   camera nears it (0x7546), then solid at its height (0x75BE); one that rolls (0x7570) rolls
//!   at its speed at a player's depth, with its sound, striking as a thing thrown does (0x95CE's
//!   list, its power); a blow, a thing thrown or a grab knocks it away (0x7392, 0x73DC: the item
//!   it holds left, 0x7E54), it falls (0x75EE) and bounces (0x7110) and goes at its last
//!   landing.
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
const s16be = rom_mod.s16be;
const immediate = entities.immediate;
const moveq = entities.moveq;
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

/// The frames of entry `entry` of `d`'s set, with their bodies (but `bodiless`) and their
/// blows' boxes (a trolley never turns: its boxes are its frames' own).
fn struckFrames(d: *Def, name: []const u8, entry: u32, bodiless: bool) Error![]entity.Frame {
    const raw = try entities.readAnimation(d.arena, d.rom, d.set, entry);
    const out = try d.arena.alloc(entity.Frame, raw.frames.len);
    for (out, raw.frames) |*f, r| {
        if (r.mirrored) return error.BadData;
        f.* = .{
            .frame = try d.frameName(r.address),
            .ticks = @max(raw.timing, 1),
            .body = if (bodiless) null else try d.box(0, r.body, r.body, name, "body"),
            .attack = try d.box(1, r.attack, r.attack, name, "attack"),
        };
    }
    return out;
}

/// The trolley (type $45): its stand (entry 0) and its flight (entry 1, its animation 2: 0x740E's for type $45),
/// its height and solid box, how it comes out, rolls, strikes and is knocked away.
fn trolley(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x75CA, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "trolley", set);
    try d.animations.append(arena, .{ .name = "stand", .loop = true, .frames = try struckFrames(&d, "stand", 0, false) });
    // Knocked away, its animation 2 whichever way (0x740E: moveq #2,d0, kept for type $45).
    if (try moveq(rom, 0x740E, 0) != 2 or u16be(rom, 0x7410) != 0x0C28 or rom[0x7413] != 0x45) return error.BadData;
    // Flying, nothing strikes it (its state 2 looks at no hit, 0x75EE).
    try d.animations.append(arena, .{ .name = "fly", .loop = true, .frames = try struckFrames(&d, "fly", 1, true) });
    try d.number("height", try moveWord(rom, 0x75C4, 24), "ROM 0x075C4: move.w #N,(24,a0)");
    // Solid (0x75BE: ori.b #1,($3A,a0)), its box the solid boxes' entry at byte 32 (0x3BF4: no
    // type of the list but $41's, whose entry it falls to).
    if (u32be(rom, 0x75BE) != 0x0028_0001 or u16be(rom, 0x75C2) != 0x003A) return error.BadData;
    if (try moveq(rom, 0x3BF4, 4) != 32) return error.BadData;
    try items.solidBoxAt(&d, 32);
    // Its coming out (0x7546): one rolling from behind (its `rolls` at least ROM 0x07553's) once
    // right of the camera's place plus N, the others right of it less N.
    try d.number("from_behind", rom[0x7553], "ROM 0x07550: cmpi.b #N,($40,a0) (rolls from N on come from behind)");
    try d.number("behind", try immediate(rom, 0x7558, &.{ 0x06, 0x40 }, 2), "ROM 0x07558: addi.w #N,d0 (from the camera's place)");
    try d.number("ahead", try immediate(rom, 0x7564, &.{ 0x04, 0x40 }, 2), "ROM 0x07564: subi.w #N,d0 (from the camera's place)");
    // Rolling (0x7570): its blows' power (move.b #N,($34,a0)), its speeds across by its rolls
    // (the words after 0x075DC's rts), its sound.
    if (u16be(rom, 0x757E) != 0x117C or u16be(rom, 0x7582) != 0x0034) return error.BadData;
    try d.number("power", rom[0x7581], "ROM 0x0757E: move.b #N,($34,a0)");
    // On an enemy a thing below the weapons' places (a trolley) does 2 (0xA9F2: subq.w #N,($32,a0)).
    if (u16be(rom, 0xA9F2) & 0xF1FF != 0x5168 or u16be(rom, 0xA9F4) != 0x32) return error.BadData;
    try d.number("enemy_damage", (u16be(rom, 0xA9F2) >> 9) & 7, "ROM 0x0A9F2: subq.w #N,($32,a0) (on an enemy, from a thing below the weapons' places)");
    if (u16be(rom, 0x75DC) != 0x4E75) return error.BadData;
    inline for (1..5) |k| try d.number(std.fmt.comptimePrint("roll_{d}", .{k}), @as(i32, s16be(rom, 0x75DC + 2 * k)) << 16, std.fmt.comptimePrint("ROM 0x{X:0>5}: its speed across, whole pixels", .{0x75DC + 2 * k}));
    try d.sound("roll", @bitCast(@as(i8, @intCast(try moveq(rom, 0x7584, 7)))));
    // Knocked away (0x73DC): its speed up (type $45's moveq #N,d5), its speeds across by side
    // (the table at 0x7444), its sound; its fall (0x75EE: going up, coming down) and its
    // landings (0x7110: the obstacles' bounces).
    try d.number("up", (try moveq(rom, 0x73EC, 5)) << 16, "ROM 0x073EC: moveq #N,d5 (type $45's), whole pixels");
    try d.number("speed_left", @as(i32, s16be(rom, 0x7444)) << 16, "ROM 0x07444: the first word, whole pixels");
    try d.number("speed_right", @as(i32, s16be(rom, 0x7446)) << 16, "ROM 0x07446: the second word, whole pixels");
    try d.number("rising", try immediate(rom, 0x75EE, &.{ 0x20, 0x3C }, 4), "ROM 0x075EE: move.l #N,d0 (its speed down growing while it goes up)");
    try d.number("falling", try immediate(rom, 0x75FA, &.{ 0x20, 0x3C }, 4), "ROM 0x075FA: move.l #N,d0 (coming down)");
    if (u16be(rom, 0x7128) != 80) return error.BadData;
    try d.number("bounces", try immediate(rom, 0x7124, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x07124: cmpi.b #N,(80,a0) (its meetings with the floor)");
    try d.sound("knocked", @bitCast(@as(i8, @intCast(try moveq(rom, 0x73EE, 7)))));
    try d.sound("bounce", @bitCast(@as(i8, @intCast(try moveq(rom, 0x713A, 7)))));
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A70)");
    const drawn = try items.drawnOffset(rom);
    try d.number("screen_from", try immediate(rom, 0xAABA, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AABA: cmpi.w #N,(40,a0), less 0xAF6E's offset (a blow lands on the screen)");
    try d.number("screen_to", try immediate(rom, 0xAAC2, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AAC2: cmpi.w #N,(40,a0), less 0xAF6E's offset (excluded)");
    return .{
        .name = "trolley",
        .provenance = try std.fmt.allocPrint(arena, "round 8's covered trolley, type $45 (handler 0x7534): the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "trolley",
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try statue(arena, rom));
    try out.append(arena, try trolley(arena, rom));
}

//! Round 2's scenery (docs/content.md, `entities/NAME.json`): each a definition read from its
//! animation set and from the immediate values of the code that runs it, with the place of each
//! in its provenance.
//!
//! - The oil drum (type $19, its handler 0x6C84, sor-remaster's obj/knockable.zig): it stands
//!   solid until a player's blow or a thing thrown knocks it away; it leaves the item it holds
//!   (0x7E54), flies off to the side the one that struck it faces, bouncing, and goes.
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");
const items = @import("items.zig");

const u16be = rom_mod.u16be;
const s16be = rom_mod.s16be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const moveByte = entities.moveByte;
const moveq = entities.moveq;
const entryFrames = items.entryFrames;

/// `move.w #N,(D,a0)` at `at`: N, the displacement checked.
fn moveWord(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at + 4) != displacement) return error.BadData;
    return immediate(rom, at, &.{ 0x31, 0x7C }, 2);
}

/// A definition of the round's art set at `set` (`round2/PREFIX_NN`).
fn def(arena: std.mem.Allocator, rom: []const u8, prefix: []const u8, set: u32) Error!Def {
    return .{ .arena = arena, .rom = rom, .dir = "round2", .prefix = prefix, .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
}

/// The oil drum (type $19): its stand (entry 0, its body), its flight (entry 2, animation 4,
/// facing right; entry 1 is its mirror image, facing left: the tilted drum and a blank frame a
/// tick each; flying, it meets nothing), the breakable's solid box, its flight's numbers.
fn knockable(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x6CA2, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "obstacle", set);
    try d.animations.append(arena, .{ .name = "stand", .loop = true, .frames = try entryFrames(&d, "stand", 0, null, false) });
    try d.animations.append(arena, .{ .name = "fly", .loop = true, .frames = try entryFrames(&d, "fly", 2, null, true) });
    // Entry 1 is entry 2 mirrored (0x6CDC: the animation 2 to the left, 4 to the right).
    const left = try entities.readAnimation(arena, rom, set, 1);
    const right = try entities.readAnimation(arena, rom, set, 2);
    if (left.frames.len != right.frames.len or left.timing != right.timing) return error.BadData;
    for (left.frames, right.frames) |l, r| if (l.address != r.address or !l.mirrored) return error.BadData;
    // The solid box: type $19 takes the breakable's (0x3BCE: cmpi.b #$19,(0,a1), d4 still 0).
    if (u16be(rom, 0x3BC4) != 0x7800 or u16be(rom, 0x3BCE) != 0x0C29 or rom[0x3BD1] != 0x19) return error.BadData;
    try items.solidBox(&d);

    try d.number("height", try moveWord(rom, 0x6C96, 24), "ROM 0x06C96: move.w #N,(24,a0)");
    try d.number("flight", try moveByte(rom, 0x6CEC, 71), "ROM 0x06CEC: move.b #N,(71,a0)");
    // The speeds across by side (0x6CCE: move.w (0x6D0A,pc,d6.w),(28,a0)): to the left, then the
    // right, the same speed.
    const speed = s16be(rom, 0x6D0C);
    if (s16be(rom, 0x6D0A) != -speed or u16be(rom, 0x6CCE) != 0x317B) return error.BadData;
    try d.number("speed", @as(i32, speed) << 16, "ROM 0x06D0A: the second word, whole pixels (the first, to the left, its opposite)");
    try d.number("up", (try moveWord(rom, 0x6CE0, 36)) << 16, "ROM 0x06CE0: move.w #N,(36,a0), whole pixels");
    try d.number("rising", try immediate(rom, 0x6D16, &.{ 0x20, 0x3C }, 4), "ROM 0x06D16: move.l #N,d0 (its speed down negative)");
    try d.number("falling", try immediate(rom, 0x6D22, &.{ 0x20, 0x3C }, 4), "ROM 0x06D22: move.l #N,d0");
    try d.number("bounce", try immediate(rom, 0x6D36, &.{ 0x21, 0x7C }, 4), "ROM 0x06D36: move.l #N,(36,a0) (a cell with an attribute under it, 0xAD2A)");
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A70)");
    const drawn = try items.drawnOffset(rom);
    try d.number("screen_from", try immediate(rom, 0xAABA, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AABA: cmpi.w #N,(40,a0), less 0xAF6E's offset (a blow lands on the screen)");
    try d.number("screen_to", try immediate(rom, 0xAAC2, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AAC2: cmpi.w #N,(40,a0), less 0xAF6E's offset (excluded)");
    try d.sound("knocked", @bitCast(@as(i8, @intCast(try moveq(rom, 0x6CF8, 7)))));
    return .{
        .name = "knockable",
        .provenance = try std.fmt.allocPrint(arena, "round 2's oil drums, type $19 (handler 0x6C84): the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "knockable",
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try knockable(arena, rom));
}

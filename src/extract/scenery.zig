//! Round 2's scenery (docs/content.md, `entities/NAME.json`): each a definition read from its
//! animation set and from the immediate values of the code that runs it, with the place of each
//! in its provenance.
//!
//! - The oil drum (type $19, its handler 0x6C84, sor-remaster's obj/knockable.zig): it stands
//!   solid until a player's blow or a thing thrown knocks it away; it leaves the item it holds
//!   (0x7E54), flies off to the side the one that struck it faces, bouncing, and goes.
//! - The drip (type $14, 0x6D40, obj/drip.zig): it hangs, swells, falls to the floor, splashes,
//!   and hangs again.
//! - The flight (type $4D, 0x6E9E, obj/flight.zig): unseen, it waits for the camera to pass each
//!   of its marks, then sends its waves of fliers (type $12, 0x6E2A) across the screen; while a
//!   flight passes, the posters' corners (type $13, 0x6DDC) that stir with it flap.
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

/// The heights the posters' corners take by their list entry's byte $49 (0x6DEE: a word each).
pub const corner_heights = 0x6E06;
pub const corner_height_count = 4;

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

/// The drip (type $14): its five frames (entry 0, shown by its code: hanging, swelling, falling,
/// the splash, none), how long it hangs and each frame after, its fall.
fn drip(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x6D68, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "drip", set);
    const frames = try entryFrames(&d, "drip", 0, null, true);
    if (frames.len != 5) return error.BadData;
    try d.animations.append(arena, .{ .name = "drip", .loop = true, .frames = frames });
    try d.number("height", try moveWord(rom, 0x6D56, 24), "ROM 0x06D56: move.w #N,(24,a0)");
    try d.number("hang", try moveByte(rom, 0x6D62, 71), "ROM 0x06D62: move.b #N,(71,a0)");
    try d.number("frame_ticks", try moveByte(rom, 0x6D78, 71), "ROM 0x06D78: move.b #N,(71,a0)");
    try d.number("fall", (try moveWord(rom, 0x6D88, 36)) << 16, "ROM 0x06D88: move.w #N,(36,a0), whole pixels");
    try d.number("gravity", try immediate(rom, 0x6D94, &.{ 0x06, 0xA8 }, 4), "ROM 0x06D94: addi.l #N,(36,a0)");
    try d.number("probe", try moveq(rom, 0x6DA0, 3), "ROM 0x06DA0: moveq #N,d3 (below its place, 0xAD24: a cell with an attribute)");
    return .{
        .name = "drip",
        .provenance = try std.fmt.allocPrint(arena, "round 2's drips, type $14 (handler 0x6D40): the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "drip",
        .numbers = d.numbers.items,
        .animations = d.animations.items,
    };
}

/// The posters' corners (type $13): their flapping (entry 0); their heights are the round's
/// script's (`corner_heights`).
fn corner(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x6DFC, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "scenery", set);
    try d.animations.append(arena, .{ .name = "flap", .loop = true, .frames = try entryFrames(&d, "flap", 0, null, true) });
    return .{
        .name = "flight_scenery",
        .provenance = try std.fmt.allocPrint(arena, "round 2's posters' corners, type $13 (handler 0x6DDC): the animation set at ROM 0x{X:0>5}", .{set}),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "flight_scenery",
        .animations = d.animations.items,
    };
}

/// The flier (type $12): its two sizes (entries 0 and 1, 0x6E54), its speeds, where it goes.
fn flier(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x6E4C, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "flight", set);
    try d.animations.append(arena, .{ .name = "large", .loop = true, .frames = try entryFrames(&d, "large", 0, null, true) });
    try d.animations.append(arena, .{ .name = "small", .loop = true, .frames = try entryFrames(&d, "small", 1, null, true) });
    try d.number("down", (try moveWord(rom, 0x6E60, 36)) << 16, "ROM 0x06E60: move.w #N,(36,a0), whole pixels");
    try d.number("across", (try moveWord(rom, 0x6E66, 28)) << 16, "ROM 0x06E66: move.w #N,(28,a0), whole pixels");
    try d.number("depth", (try moveWord(rom, 0x6E6C, 32)) << 16, "ROM 0x06E6C: move.w #N,(32,a0), whole pixels");
    try d.number("lift", try immediate(rom, 0x6E88, &.{ 0x06, 0xA8 }, 4), "ROM 0x06E88: addi.l #N,(36,a0)");
    try d.number("drawn_offset", try items.drawnOffset(rom), "ROM 0x0AF6E: addi.w #N,d2 (its place across on the screen as the drawing keeps it)");
    try d.number("gone_drawn", try immediate(rom, 0x6E7E, &.{ 0x0C, 0x68 }, 2), "ROM 0x06E7E: cmpi.w #N,(40,a0) (unsigned)");
    try d.number("middle_from", try immediate(rom, 0x97E8, &.{ 0x0C, 0x68 }, 2), "ROM 0x097E8: cmpi.w #N,(40,a0) (during the special attack, 0x6E94)");
    try d.number("middle_to", try immediate(rom, 0x97F0, &.{ 0x0C, 0x68 }, 2), "ROM 0x097F0: cmpi.w #N,(40,a0) (excluded)");
    return .{
        .name = "flier",
        .provenance = try std.fmt.allocPrint(arena, "round 2's fliers, type $12 (handler 0x6E2A): the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "flier",
        .numbers = d.numbers.items,
        .animations = d.animations.items,
    };
}

/// The marks the camera passes (0x6F3E: words, $FFFF at the end) and a wave's fliers (0x6F1E: 8
/// bytes each, X from the camera's limit on the left plus the screen's width, Y, Z, a byte not
/// read, the size).
const marks = 0x6F3E;
const mark_count = 5;
const wave = 0x6F1E;

/// The flight (type $4D): unseen, no art of its own; its marks, its waves, their timing.
fn flight(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "round2", .prefix = "flight", .set = 0, .box_table = entities.object_boxes, .frame_addresses = &.{} };
    try d.number("screen_width", try immediate(rom, 0x6ED4, &.{ 0x06, 0x41 }, 2), "ROM 0x06ED4: addi.w #N,d1 (to the camera's limit on the left, $FFE01E)");
    if (try immediate(rom, 0x6F54, &.{ 0x06, 0x41 }, 2) != try immediate(rom, 0x6ED4, &.{ 0x06, 0x41 }, 2)) return error.BadData;
    try d.number("gap", try moveWord(rom, 0x6EEA, 98), "ROM 0x06EEA: move.w #N,(98,a0) (the ticks to the next wave)");
    try d.number("tail", try moveWord(rom, 0x6F62, 98), "ROM 0x06F62: move.w #N,(98,a0) (from the last wave to the flight's end)");
    var at: [mark_count]i32 = undefined;
    for (&at, 0..) |*m, k| {
        m.* = u16be(rom, marks + 2 * @as(u32, @intCast(k)));
        if (m.* & 0x8000 != 0) return error.BadData;
    }
    if (u16be(rom, marks + 2 * mark_count) != 0xFFFF) return error.BadData;
    try d.table("marks", &at, "ROM 0x06F3E: words, up to $FFFF");
    const fliers: usize = @intCast(try moveq(rom, 0x6EF4, 6) + 1);
    if (fliers != 4) return error.BadData;
    var x: [4]i32 = undefined;
    var y: [4]i32 = undefined;
    var z: [4]i32 = undefined;
    var small: [4]i32 = undefined;
    for (0..fliers) |k| {
        const e = wave + 8 * @as(u32, @intCast(k));
        x[k] = s16be(rom, e);
        y[k] = s16be(rom, e + 2);
        z[k] = s16be(rom, e + 4);
        small[k] = @intFromBool(rom[e + 7] != 0);
    }
    try d.table("flier_x", &x, "ROM 0x06F1E: each flier's first word (4 fliers, ROM 0x06EF4: moveq #N-1,d6)");
    try d.table("flier_depth", &y, "ROM 0x06F1E: each flier's second word");
    try d.table("flier_height", &z, "ROM 0x06F1E: each flier's third word");
    try d.table("flier_small", &small, "ROM 0x06F1E: each flier's eighth byte (not 0: the small one, 0x6E54)");
    return .{
        .name = "flight",
        .provenance = try std.fmt.allocPrint(arena, "round 2's flights, type $4D (handler 0x6E9E): three waves (its states 1 to 3, 0x6EA6){s}", .{d.number_notes.items}),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "flight",
        .numbers = d.numbers.items,
        .tables = d.tables.items,
    };
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try knockable(arena, rom));
    try out.append(arena, try drip(arena, rom));
    try out.append(arena, try corner(arena, rom));
    try out.append(arena, try flier(arena, rom));
    try out.append(arena, try flight(arena, rom));
}

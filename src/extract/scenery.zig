//! The rounds' scenery (docs/content.md, `entities/NAME.json`): each a definition read from its
//! animation set and from the immediate values of the code that runs it, with the place of each
//! in its provenance. Round 2's:
//!
//! - The oil drum (type $19, its handler 0x6C84, sor-remaster's obj/knockable.zig): it stands
//!   solid until a player's blow or a thing thrown knocks it away; it leaves the item it holds
//!   (0x7E54), flies off to the side the one that struck it faces, bouncing, and goes.
//! - The drip (type $14, 0x6D40, obj/drip.zig): it hangs, swells, falls to the floor, splashes,
//!   and hangs again.
//! - The flight (type $4D, 0x6E9E, obj/flight.zig): unseen, it waits for the camera to pass each
//!   of its marks, then sends its waves of fliers (type $12, 0x6E2A) across the screen; while a
//!   flight passes, the posters' corners (type $13, 0x6DDC) that stir with it flap.
//!
//! Round 5's:
//!
//! - The obstacle (type $1F, its handler 0x7CBC, sor-remaster's obj/obstacle.zig): it stands
//!   solid until a player's blow or a thing thrown knocks it away; it leaves the item it holds
//!   (0x7E54), flies off to the side the one that struck it faces, bouncing (0x7104), and goes.
//!
//! Round 6's:
//!
//! - The press (type $42, its handler 0x7A6C, sor-remaster's obj/press.zig): it hangs until a
//!   player comes near, shakes, drops striking what is under it, bounces on the floor, and rises
//!   back; its links (type $43, 0x7C70) are left behind as it drops, and go as it rises.
//!
//! Round 7's:
//!
//! - The lift's pieces (types $50 to $53, sor-remaster's obj/lift.zig), which the round's load
//!   places (0xF18): its far wall ($50, 0x7D4A), its rails ($51, 0x7D7A), which run down while the
//!   lift rides, its floor ($52, 0x7DF0), and the hidden piece that opens the first section ($53,
//!   0x7E20).
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");
const items = @import("items.zig");

const u16be = rom_mod.u16be;
const s16be = rom_mod.s16be;
const u32be = rom_mod.u32be;
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

/// A definition of round 2's art set at `set` (`round2/PREFIX_NN`).
fn def(arena: std.mem.Allocator, rom: []const u8, prefix: []const u8, set: u32) Error!Def {
    return defIn(arena, rom, "round2", prefix, set);
}

/// A definition of the art set at `set` (`DIR/PREFIX_NN`).
fn defIn(arena: std.mem.Allocator, rom: []const u8, dir: []const u8, prefix: []const u8, set: u32) Error!Def {
    return .{ .arena = arena, .rom = rom, .dir = dir, .prefix = prefix, .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
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

/// Round 5's obstacle (type $1F): its stand (entry 0, its body), its flight (entry 1, the
/// animation 2 whichever way it flies; flying, it meets nothing), its solid box, its flight's
/// numbers.
fn obstacle(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x7CDA, &.{ 0x43, 0xF9 }, 4));
    var d = try defIn(arena, rom, "round5", "obstacle", set);
    try d.animations.append(arena, .{ .name = "stand", .loop = true, .frames = try entryFrames(&d, "stand", 0, null, false) });
    // 0x7D12: moveq #2,d0 for SetAnim, to either side.
    if (try moveq(rom, 0x7D12, 0) != 2) return error.BadData;
    try d.animations.append(arena, .{ .name = "fly", .loop = true, .frames = try entryFrames(&d, "fly", 1, null, true) });
    // The solid box: type $1F's entry of 0x3C6A (0x3BEA: moveq #N,d4, then cmpi.b #$1F,(0,a1)).
    if (u16be(rom, 0x3BEC) != 0x0C29 or rom[0x3BEF] != 0x1F) return error.BadData;
    try items.solidBoxAt(&d, @intCast(try moveq(rom, 0x3BEA, 4)));

    try d.number("height", try moveWord(rom, 0x7CD4, 24), "ROM 0x07CD4: move.w #N,(24,a0)");
    // The speeds across by side (0x7D0C: move.w (0x7D46,pc,d6.w),(28,a0)): to the left, then the
    // right, the same speed.
    if (u16be(rom, 0x7D0C) != 0x317B or u16be(rom, 0x7D10) != 28) return error.BadData;
    try d.number("speed_left", @as(i32, s16be(rom, 0x7D46)) << 16, "ROM 0x07D46: the first word, whole pixels");
    try d.number("speed_right", @as(i32, s16be(rom, 0x7D48)) << 16, "ROM 0x07D48: the second word, whole pixels");
    // Standing it is solid and in front (0x7CE0: ori.b #1,(58,a0); 0x7CCE: ori.b #16,(1,a0));
    // knocked away, its flight's look runs (0x7D2E: bset.b #2,(1,a0)), whichever way it flies.
    if (u32be(rom, 0x7CE0) != 0x00280001 or u16be(rom, 0x7CE4) != 58 or u32be(rom, 0x7CCE) != 0x00280010 or u16be(rom, 0x7CD2) != 1 or u32be(rom, 0x7D2E) != 0x08E80002 or u16be(rom, 0x7D32) != 1) return error.BadData;
    try d.number("solid", 1, "ROM 0x07CE0: ori.b #1,(58,a0)");
    try d.number("in_front", 1, "ROM 0x07CCE: ori.b #16,(1,a0)");
    try d.number("turns", 0, "ROM 0x07D12: moveq #2,d0, its flight's animation whichever way it flies");
    try d.number("held", 0, "ROM 0x07D2E: bset.b #2,(1,a0), its flight's look running");
    try d.number("up", (try moveWord(rom, 0x7D1C, 36)) << 16, "ROM 0x07D1C: move.w #N,(36,a0), whole pixels");
    if (u16be(rom, 0x710A) != 36) return error.BadData;
    try d.number("falling", try immediate(rom, 0x7104, &.{ 0x06, 0xA8 }, 4), "ROM 0x07104: addi.l #N,(36,a0)");
    if (u16be(rom, 0x7128) != 80) return error.BadData;
    try d.number("bounces", try immediate(rom, 0x7124, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x07124: cmpi.b #N,(80,a0) (its meetings with the ground, 0xAD2A)");
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A70)");
    const drawn = try items.drawnOffset(rom);
    try d.number("screen_from", try immediate(rom, 0xAABA, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AABA: cmpi.w #N,(40,a0), less 0xAF6E's offset (a blow lands on the screen)");
    try d.number("screen_to", try immediate(rom, 0xAAC2, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AAC2: cmpi.w #N,(40,a0), less 0xAF6E's offset (excluded)");
    try d.sound("knocked", @bitCast(@as(i8, @intCast(try moveq(rom, 0x7D34, 7)))));
    try d.sound("bounce", @bitCast(@as(i8, @intCast(try moveq(rom, 0x713A, 7)))));
    return .{
        .name = "obstacle_1f",
        .provenance = try std.fmt.allocPrint(arena, "round 5's obstacles, type $1F (handler 0x7CBC): the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "obstacle",
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// A piece of round 7's lift: its first state at `start` sets its flags (`ori.b #N,(1,a0)`: bit
/// 4 in front, bit 0 hidden; bit 3, drawn off the screen too, is all sorz does), its place
/// (`move.w #N` into $10, $14, $18: across, depth, height; none for the opener) and its animation
/// set (`lea`, then 0x6ABC); its frame entry 0's, held.
const LiftPiece = struct {
    name: []const u8,
    prefix: []const u8,
    behaviour: []const u8,
    handler: u32,
    start: u32,
    placed: bool,
};

fn liftPiece(arena: std.mem.Allocator, rom: []const u8, p: LiftPiece, set_at: u32, flags_at: u32) Error!Def {
    const set: u32 = @bitCast(try immediate(rom, set_at, &.{ 0x43, 0xF9 }, 4));
    var d = try defIn(arena, rom, "round7", p.prefix, set);
    try d.animations.append(arena, .{ .name = "lift", .loop = true, .frames = try entryFrames(&d, "lift", 0, null, false) });
    if (u16be(rom, flags_at) != 0x0028 or u16be(rom, flags_at + 4) != 1) return error.BadData;
    const flags = u16be(rom, flags_at + 2);
    if (flags & ~@as(u16, 0x19) != 0) return error.BadData;
    if (p.placed) {
        try d.number("x", try moveWord(rom, p.start + 6, 16), "move.w #N,(16,a0) in its first state");
        try d.number("depth", try moveWord(rom, p.start + 12, 20), "move.w #N,(20,a0) in its first state");
        try d.number("height", try moveWord(rom, p.start + 18, 24), "move.w #N,(24,a0) in its first state");
    }
    return d;
}

/// The lift's far wall (type $50): in front of the planes' cells in front, at its place.
fn liftWall(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const p: LiftPiece = .{ .name = "lift_wall", .prefix = "lift_wall", .behaviour = "lift", .handler = 0x7D4A, .start = 0x7D56, .placed = true };
    var d = try liftPiece(arena, rom, p, 0x7D6E, 0x7D56);
    if (u16be(rom, 0x7D58) != 0x18) return error.BadData;
    try d.number("in_front", 1, "ROM 0x07D58: ori.b #$18,(1,a0), bit 4");
    try d.number("hidden", 0, "ROM 0x07D58: bit 0 clear");
    return liftDefinition(arena, p, &d);
}

/// The lift's floor (type $52): at its place.
fn liftFloor(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const p: LiftPiece = .{ .name = "lift_floor", .prefix = "lift_floor", .behaviour = "lift", .handler = 0x7DF0, .start = 0x7DFC, .placed = true };
    var d = try liftPiece(arena, rom, p, 0x7E14, 0x7DFC);
    if (u16be(rom, 0x7DFE) != 0x08) return error.BadData;
    try d.number("in_front", 0, "ROM 0x07DFE: ori.b #8,(1,a0), bit 4 clear");
    try d.number("hidden", 0, "ROM 0x07DFE: bit 0 clear");
    return liftDefinition(arena, p, &d);
}

/// The lift's opener (type $53): hidden; `move.b #N,(96,a0)` its ticks, then it opens the first
/// section ($FA0D, as a section's art does: 0x7E48) and goes. Its animation set is the floor's.
fn liftOpener(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const p: LiftPiece = .{ .name = "lift_opener", .prefix = "lift_floor", .behaviour = "lift", .handler = 0x7E20, .start = 0x7E2C, .placed = false };
    var d = try liftPiece(arena, rom, p, 0x7E38, 0x7E32);
    if (u16be(rom, 0x7E34) != 0x01 or u32be(rom, 0x7E48) != 0x11FC0001 or u16be(rom, 0x7E4C) != 0xFA0D or u16be(rom, 0x7E30) != 96) return error.BadData;
    try d.number("x", 0, "none set");
    try d.number("depth", 0, "none set");
    try d.number("height", 0, "none set");
    try d.number("in_front", 0, "ROM 0x07E34: ori.b #1,(1,a0), bit 4 clear");
    try d.number("hidden", 1, "ROM 0x07E34: bit 0");
    try d.number("opens_after", try immediate(rom, 0x7E2C, &.{ 0x11, 0x7C, 0x00 }, 1), "ROM 0x07E2C: move.b #N,(96,a0), counted down by 0x7E42");
    return liftDefinition(arena, p, &d);
}

/// The lift's rails (type $51): at their place; while the lift rides ($FA15), down by `move.l
/// #N,(36,a0)` a tick (0x7DB4, moved by 0x7DCA), from 0 again at `cmpi.w #N,(24,a0)` (0x7DCE);
/// stopped, back at their height (0x7DE4); the lift's sounds as they begin and stop (moveq #N,d7
/// at 0x7DBC and 0x7DEA, for 0x6ACA).
fn liftRails(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const p: LiftPiece = .{ .name = "lift_rails", .prefix = "lift_rails", .behaviour = "lift_rails", .handler = 0x7D7A, .start = 0x7D88, .placed = true };
    var d = try liftPiece(arena, rom, p, 0x7DA0, 0x7D88);
    if (u16be(rom, 0x7D8A) != 0x08) return error.BadData;
    if (u16be(rom, 0x7DAC) != 0xFA15 or u16be(rom, 0x7DC6) != 0xFA15 or u16be(rom, 0x7DBA) != 36) return error.BadData;
    try d.number("speed", try immediate(rom, 0x7DB4, &.{ 0x21, 0x7C }, 4), "ROM 0x07DB4: move.l #N,(36,a0)");
    if (u16be(rom, 0x7DD2) != 24 or try moveWord(rom, 0x7DE4, 24) != try moveWord(rom, 0x7D9A, 24)) return error.BadData;
    try d.number("wrap", try immediate(rom, 0x7DCE, &.{ 0x0C, 0x68 }, 2), "ROM 0x07DCE: cmpi.w #N,(24,a0)");
    try d.sound("start", @bitCast(@as(i8, @intCast(try moveq(rom, 0x7DBC, 7)))));
    try d.sound("stop", @bitCast(@as(i8, @intCast(try moveq(rom, 0x7DEA, 7)))));
    return liftDefinition(arena, p, &d);
}

fn liftDefinition(arena: std.mem.Allocator, p: LiftPiece, d: *Def) Error!entity.Definition {
    return .{
        .name = p.name,
        .provenance = try std.fmt.allocPrint(arena, "round 7's lift, type ${X:0>2} (handler 0x{X:0>5}, its first state at 0x{X:0>5}), placed by the round's load (0xF18): the animation set of round7/{s}{s}", .{ @as(u8, switch (p.handler) {
            0x7D4A => 0x50,
            0x7D7A => 0x51,
            0x7DF0 => 0x52,
            else => 0x53,
        }), p.handler, p.start, p.prefix, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = p.behaviour,
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

/// The heights the press passes as it drops, each leaving a link (0x7BC4: words; the last past
/// the floor, never passed).
const link_heights = 0x7BC4;

/// The presses' lamps' cells by place (0x7B28: write commands), in plane A of play (at $C000 in
/// video memory, 64 cells by 32: the rounds' layout).
const lamp_cells = 0x7B28;
const plane_a = 0xC000;
const plane_bytes = 64 * 32 * 2;

/// The press (type $42): its look (entry 0, its frame's attack box what the others meet as it
/// drops), the two boxes it strikes with at its own turn (0x7B48: $F4, then $EA, written as its
/// frame's attack box), its heights, speeds and waits, its bounce's sound, the shake's thud.
fn press(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x7A9A, &.{ 0x43, 0xF9 }, 4));
    var d = try defIn(arena, rom, "round6", "press", set);
    const raw = try entities.readAnimation(arena, rom, set, 0);
    if (raw.frames.len != 1 or raw.frames[0].mirrored or raw.frames[0].body != 0) return error.BadData;
    // The drop writes its look's attack box back after its own two (0x7B5C: move.b #N,(2,a0)).
    const own = try moveByte(rom, 0x7B5C, 2);
    if (raw.frames[0].attack != own) return error.BadData;
    const look = try d.arena.alloc(entity.Frame, 1);
    look[0] = .{ .frame = try d.frameName(raw.frames[0].address), .ticks = @max(raw.timing, 1), .attack = try d.box(1, @intCast(own), @intCast(own), "hang", "attack") };
    try d.animations.append(arena, .{ .name = "hang", .loop = true, .frames = look });
    const front = try moveByte(rom, 0x7B48, 2);
    const back = try moveByte(rom, 0x7B52, 2);
    _ = try d.box(1, @intCast(front), @intCast(front), "drop", "front");
    _ = try d.box(1, @intCast(back), @intCast(back), "drop", "back");

    try d.number("height", try moveWord(rom, 0x7A8E, 24), "ROM 0x07A8E: move.w #N,(24,a0)");
    try d.number("power", try moveByte(rom, 0x7A94, 52), "ROM 0x07A94: move.b #N,(52,a0)");
    if (u16be(rom, 0xA9EC) != 0xB2FC or u16be(rom, 0xA9EE) != 0xC900 or rom[0xA9F2] & 0xF1 != 0x51 or rom[0xA9F3] != 0x68) return error.BadData;
    try d.number("enemy_damage", @as(i32, rom[0xA9F2] >> 1) & 7, "ROM 0x0A9F2: subq.w #N,(50,a0) (a thing in the enemies' places hitting an enemy, 0x0A9EC: the press is one)");
    try d.number("near_behind", try immediate(rom, 0x7AA8, &.{ 0x04, 0x40 }, 2), "ROM 0x07AA8: subi.w #N,d0 (from its place across, excluded)");
    try d.number("near_span", try immediate(rom, 0x7AAE, &.{ 0x06, 0x41 }, 2), "ROM 0x07AAE: addi.w #N,d1 (included; unsigned, 0x7AB6)");
    try d.number("shake", try moveByte(rom, 0x7AD6, 87), "ROM 0x07AD6: move.b #N,(87,a0)");
    try d.number("drop_speed", (try moveWord(rom, 0x7B1A, 36)) << 16, "ROM 0x07B1A: move.w #N,(36,a0), whole pixels");
    try d.number("drop_gravity", try immediate(rom, 0x7B62, &.{ 0x06, 0xA8 }, 4), "ROM 0x07B62: addi.l #N,(36,a0)");
    const floor = try immediate(rom, 0x7BA2, &.{ 0x0C, 0x68 }, 2);
    if (u16be(rom, 0x7BA6) != 24 or try immediate(rom, 0x7C06, &.{ 0x0C, 0x68 }, 2) != floor or u16be(rom, 0x7C0A) != 24) return error.BadData;
    try d.number("floor", floor, "ROM 0x07BA2: cmpi.w #N,(24,a0) (and 0x7C06 as it bounces)");
    if (u16be(rom, 0x7BB0) != 36 or u16be(rom, 0x7C42) != 36) return error.BadData;
    try d.number("bounce_speed", try immediate(rom, 0x7BAA, &.{ 0x21, 0x7C }, 4), "ROM 0x07BAA: move.l #N,(36,a0)");
    try d.number("bounce_gravity", try immediate(rom, 0x7BFA, &.{ 0x06, 0xA8 }, 4), "ROM 0x07BFA: addi.l #N,(36,a0)");
    if (u16be(rom, 0x7C26) != 82) return error.BadData;
    try d.number("bounces", try immediate(rom, 0x7C22, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x07C22: cmpi.b #N,(82,a0)");
    const rest = try moveByte(rom, 0x7C2A, 80);
    if (try moveByte(rom, 0x7C5A, 80) != rest) return error.BadData;
    try d.number("rest", rest, "ROM 0x07C2A: move.b #N,(80,a0) (and 0x7C5A, risen)");
    try d.number("rise_speed", try immediate(rom, 0x7C3C, &.{ 0x21, 0x7C }, 4), "ROM 0x07C3C: move.l #N,(36,a0)");
    if (u16be(rom, 0x7B72) != 0x303B or u16be(rom, 0x7B74) != link_heights - 0x7B74) return error.BadData;
    var heights: [5]i32 = undefined;
    for (&heights, 0..) |*h, k| {
        h.* = u16be(rom, link_heights + 2 * @as(u32, @intCast(k)));
        if (k > 0 and h.* <= heights[k - 1]) return error.BadData;
    }
    if (heights[heights.len - 1] <= floor or heights[heights.len - 2] >= floor) return error.BadData;
    try d.table("link_heights", &heights, "ROM 0x07BC4: words (the last past the floor)");
    // Drawn this far left of the screen, it goes (0xAF46: the drawing's left edge, from its place
    // across less the camera's plus 0xAF6E's offset).
    try d.number("drawn_left", try immediate(rom, 0xAFA0, &.{ 0x30, 0x3C }, 2), "ROM 0x0AFA0: move.w #N,d0 (signed)");
    try d.number("drawn_offset", try items.drawnOffset(rom), "ROM 0x0AF6E: addi.w #N,d2");
    // Its lamp: the two cells of plane A it writes as it shakes, by its place (0x7B28: a write
    // command each, to plane A at $C000, 64 cells across, 0x7AEC: lea (58,pc,d0.w)), on one row.
    if (u16be(rom, 0x7AEC) != 0x43FB or rom[0x7AEF] != lamp_cells - 0x7AEE) return error.BadData;
    var lamp_x: [6]i32 = undefined;
    var lamp_y: ?i32 = null;
    for (&lamp_x, 0..) |*x, k| {
        const cmd = u32be(rom, lamp_cells + 4 * @as(u32, @intCast(k)));
        if (cmd & 0xC000_FFFC != 0x4000_0000) return error.BadData;
        const address: u32 = ((cmd >> 16) & 0x3FFF) | ((cmd & 3) << 14);
        if (address < plane_a or address >= plane_a + plane_bytes) return error.BadData;
        x.* = @intCast(((address - plane_a) % 128) / 2);
        const y: i32 = @intCast((address - plane_a) / 128);
        if (lamp_y != null and lamp_y.? != y) return error.BadData;
        lamp_y = y;
    }
    try d.table("lamp_x", &lamp_x, "ROM 0x07B28: a write command by its place, its cell's column of plane A's 64");
    try d.number("lamp_y", lamp_y.?, "ROM 0x07B28: the commands' row of plane A");
    try d.sound("bounce", @bitCast(@as(i8, @intCast(try moveq(rom, 0x7C14, 7)))));
    try d.sound("thud", @bitCast(@as(i8, @intCast(try moveq(rom, 0x4D58, 7)))));
    return .{
        .name = "press",
        .provenance = try std.fmt.allocPrint(arena, "round 6's presses, type $42 (handler 0x7A6C): the animation set at ROM 0x{X:0>5}; its boxes front and back: ROM 0x07B48 and 0x07B52, move.b #N,(2,a0){s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "press",
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// A link of the press's rod (type $43): its look (animation 2 of the press's set: its entry 1,
/// 0x7C90: jsr 0xB1DA), how much higher than the press it starts, how near the press rising
/// takes it away.
fn pressLink(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x7C88, &.{ 0x43, 0xF9 }, 4));
    if (set != @as(u32, @bitCast(try immediate(rom, 0x7A9A, &.{ 0x43, 0xF9 }, 4)))) return error.BadData;
    // 0x7C90: jsr 0xB1DA (moveq #2,d0: the animation 2).
    if (u16be(rom, 0x7C90) != 0x4EBA or 0x7C92 + @as(u32, @intCast(s16be(rom, 0x7C92))) != 0xB1DA or try moveq(rom, 0xB1DA, 0) != 2) return error.BadData;
    var d = try defIn(arena, rom, "round6", "press", set);
    try d.animations.append(arena, .{ .name = "link", .loop = true, .frames = try entryFrames(&d, "link", 1, null, true) });
    if (u16be(rom, 0x7C80) != 24) return error.BadData;
    try d.number("above", try immediate(rom, 0x7C7C, &.{ 0x04, 0x68 }, 2), "ROM 0x07C7C: subi.w #N,(24,a0)");
    try d.number("reach", try immediate(rom, 0x7CAE, &.{ 0x06, 0x40 }, 2), "ROM 0x07CAE: addi.w #N,d0 (below it, the press rising takes it away)");
    try d.number("drawn_left", try immediate(rom, 0xAFA0, &.{ 0x30, 0x3C }, 2), "ROM 0x0AFA0: move.w #N,d0 (signed)");
    try d.number("drawn_offset", try items.drawnOffset(rom), "ROM 0x0AF6E: addi.w #N,d2");
    return .{
        .name = "press_link",
        .provenance = try std.fmt.allocPrint(arena, "round 6's presses' links, type $43 (handler 0x7C70): the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "press_link",
        .numbers = d.numbers.items,
        .animations = d.animations.items,
    };
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try knockable(arena, rom));
    try out.append(arena, try obstacle(arena, rom));
    try out.append(arena, try drip(arena, rom));
    try out.append(arena, try corner(arena, rom));
    try out.append(arena, try flier(arena, rom));
    try out.append(arena, try flight(arena, rom));
    try out.append(arena, try press(arena, rom));
    try out.append(arena, try pressLink(arena, rom));
    try out.append(arena, try liftWall(arena, rom));
    try out.append(arena, try liftRails(arena, rom));
    try out.append(arena, try liftFloor(arena, rom));
    try out.append(arena, try liftOpener(arena, rom));
}

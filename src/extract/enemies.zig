//! The common enemies of the streets and round 1's boss (docs/content.md, `entities/NAME.json`):
//! each a definition read from its type's tables (its animation set at 0x27032, its strength rows
//! at 0x26FCE, its points at 0x27010) and from the immediate values of the code that runs it, with
//! the place of each in its provenance. The common states' numbers come from the enemies' shared
//! code (0x92AC to 0xA59C, 0xDBCC), the same in every enemy's definition; each kind's own from
//! its handler (sor-remaster's obj/galsia.zig, galsia_armed.zig, signal.zig, acrobat.zig,
//! brawler.zig, boss_antonio.zig).
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");
const weapons = @import("weapons.zig");

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const moveByte = entities.moveByte;
const moveq = entities.moveq;
const frameCompared = entities.frameCompared;
const quick = entities.quick;
const readAnimation = entities.readAnimation;
const soundName = entities.soundName;

/// A long per enemy type from $20: its animation set (0x938C).
const enemy_sets = 0x27032;
/// Per enemy type from $20, 6 bytes by strength (the palette variant): its health's low byte at
/// strength N, then its power at strength N three bytes on (0x93CE).
const enemy_numbers = 0x26FCE;
/// Per enemy type from $20, 3 bytes by strength: the index of the points it gives (0x93B4).
const score_indices = 0x27010;
/// The amounts added to a score, 4 bytes each from index 1, in decimal digits (0x10DDE).
const score_amounts = 0x10DDE;
/// The sine and the cosine of each slope of 64ths (0x982C).
const slopes = 0x2705E;
/// The walk off's pacing (0xDD26): a stretch's ticks, and its speed (8.8) with its frames' ticks.
const pace_lengths = 0x1033A;
const pace_speeds = 0xDD68;

/// The points of the score's amount at `index`, read from its digits as the score shows them.
pub fn points(rom: []const u8, index: u8) Error!i32 {
    if (index == 0) return error.BadData;
    const at = score_amounts + 4 * (@as(u32, index) - 1);
    var v: i32 = 0;
    for (rom[at + 1 .. at + 4]) |b| {
        if (b >> 4 > 9 or b & 0xF > 9) return error.BadData;
        v = v * 100 + (b >> 4) * 10 + (b & 0xF);
    }
    return v;
}

/// The frames of an enemy's entry `entry` (facing right) with the next one's (facing left), each
/// shown for the animation's timing byte, as the objects' animations run (0xB0B6); a still
/// picture (one frame, a timing of 0) shows a tick at a time.
fn enemyFrames(d: *Def, name: []const u8, entry: u32) Error![]entity.Frame {
    const right = try readAnimation(d.arena, d.rom, d.set, entry);
    const left = try readAnimation(d.arena, d.rom, d.set, entry + 1);
    if (right.frames.len != left.frames.len or right.timing != left.timing) return error.BadData;
    if (right.timing == 0 and right.frames.len != 1) return error.BadData;
    const out = try d.arena.alloc(entity.Frame, right.frames.len);
    for (out, right.frames, left.frames) |*f, r, l| {
        if (r.address != l.address or r.mirrored == l.mirrored) return error.BadData;
        // The boxes go by the facing, the art's mirroring aside: a frame drawn mirrored facing
        // right (art that faces left) mirrors its boxes facing right, so its boxes are given the
        // other way round (round 2's boss, Antonio's bounce).
        const flipped = r.mirrored;
        f.* = .{
            .frame = try d.frameName(r.address),
            .ticks = @max(right.timing, 1),
            .flip = flipped,
            .body = if (flipped) try d.box(0, l.body, r.body, name, "body") else try d.box(0, r.body, l.body, name, "body"),
            .attack = if (flipped) try d.box(1, l.attack, r.attack, name, "attack") else try d.box(1, r.attack, l.attack, name, "attack"),
        };
    }
    return out;
}

/// An animation of the set by its entry (the code's animation number / 2).
pub const Anim = struct { name: []const u8, entry: u32 };

/// The animations the common states play (0x937A, 0x9B36, 0x991A, 0xA43E, 0xA04A): the walk,
/// the knock-down (its flight, lying, getting up; frame 5 upside down in a back drop), the reel,
/// the stand, and held in front or thrown over a shoulder.
const common_animations = [_]Anim{
    .{ .name = "walk", .entry = 0 },
    .{ .name = "down", .entry = 2 },
    .{ .name = "reel", .entry = 4 },
    .{ .name = "stand", .entry = 6 },
    .{ .name = "thrown", .entry = 8 },
};

/// A common enemy of type `kind` begun: its animation set and art (`dir`), its common animations
/// and `own` ones, the numbers, tables and sounds of the common states.
fn begin(arena: std.mem.Allocator, rom: []const u8, kind: u8, dir: []const u8, own: []const Anim) Error!Def {
    const k: u32 = kind - 0x20;
    const set = u32be(rom, enemy_sets + 4 * k);
    var d: Def = .{ .arena = arena, .rom = rom, .dir = dir, .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    for (common_animations) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, an.entry) });
    // Slammed down in a back drop, it shows the poses of its knock-down's frames (0xA2EC).
    try d.animations.append(arena, .{ .name = "slammed", .loop = true, .frames = d.animations.items[d.animationIndex("down").?].frames });
    for (own) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, an.entry) });
    try commonNumbers(&d, kind);
    try d.sound("hurt", @bitCast(@as(i8, @intCast(try moveq(rom, 0x9BC6, 7)))));
    try d.sound("thud", @bitCast(@as(i8, @intCast(try moveq(rom, 0x9AB6, 7)))));
    // The knockout cry (0x997E): one for an even place across, another for an odd one; the
    // brawler's own.
    if (kind == try immediate(rom, 0x9988, &.{ 0x0C, 0x28, 0x00 }, 1)) {
        const own_cry: u8 = @bitCast(@as(i8, @intCast(try moveq(rom, 0x9986, 7))));
        try d.sound("cry", own_cry);
        try d.sound("cry_odd", own_cry);
    } else {
        try d.sound("cry", @bitCast(@as(i8, @intCast(try moveq(rom, 0x9990, 7)))));
        try d.sound("cry_odd", @bitCast(@as(i8, @intCast(try moveq(rom, 0x999A, 7)))));
    }
    return d;
}

/// The definition of `d`, of type `kind`: its health, power and points at strength 0 (the
/// strengths 1 and 2 come with the rounds that place them: PLAN item 15).
fn finish(d: *Def, name: []const u8, kind: u8, behaviour: []const u8, what: []const u8) Error!entity.Definition {
    const k: u32 = kind - 0x20;
    return .{
        .name = name,
        .provenance = try std.fmt.allocPrint(d.arena, "enemy type ${X:0>2}, {s}: the animation set at ROM 0x{X:0>5} (0x27032), the boxes (0x1A68E, 0x1AB8E); health ROM 0x{X:0>5} (0x93CE, strength 0); gravity ROM 0x0973E: addi.l #N,(36,a0){s}", .{ kind, what, d.set, enemy_numbers + 6 * k, d.number_notes.items }),
        .family = .enemy,
        .team = .enemy,
        .behaviour = behaviour,
        .health = d.rom[enemy_numbers + 6 * k],
        .gravity = try immediate(d.rom, 0x973E, &.{ 0x06, 0xA8 }, 4),
        .shadow = true,
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .choices = d.choices.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
        .moves = d.moves.items,
    };
}

/// The numbers and tables of the common states (behaviours/enemy.zig's `Common`), and the
/// type's points and power at strength 0.
fn commonNumbers(d: *Def, kind: u8) Error!void {
    const rom = d.rom;
    const k: u32 = kind - 0x20;
    try d.number("appears_from", try immediate(rom, 0x97E8, &.{ 0x0C, 0x68 }, 2) - 0x80, "ROM 0x097E8: cmpi.w #N+$80,(40,a0)");
    try d.number("appears_to", try immediate(rom, 0x97F0, &.{ 0x0C, 0x68 }, 2) - 0x80 - 1, "ROM 0x097F0: cmpi.w #N+$81,(40,a0)");
    // Round 8's (0xA5A6: cmpi.w #7,($FF02)), its camera going left: one that does not wait for
    // the camera comes out once its place is past the camera's plus N (0xA5DC).
    if (u16be(rom, 0xA5A6) != 0x0C78 or u16be(rom, 0xA5A8) != 7 or u16be(rom, 0xA5AA) != 0xFF02) return error.BadData;
    try d.number("appears_behind", try immediate(rom, 0xA5E8, &.{ 0x06, 0x40 }, 2), "ROM 0x0A5E8: addi.w #N,d0 (round 8's camera going left: past the camera's place plus N)");
    try d.number("points", try points(rom, rom[score_indices + 3 * k]), "ROM 0x27010 (the score's index by type and strength, 0x93B4), the amount at ROM 0x10DDE (0x9E26)");
    try d.number("power", rom[enemy_numbers + 6 * k + 3], "ROM 0x26FCE (by type and strength, three bytes after the health, 0x93CE)");
    try d.number("reel", try moveByte(rom, 0x9B90, 80), "ROM 0x09B90: move.b #N,(80,a0)");
    try d.number("reel_nudge", try moveq(rom, 0x9BF2, 0), "ROM 0x09BF2: moveq #N,d0");
    try d.number("knocked_x", try immediate(rom, 0x992E, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x0992E: move.w #N,(28,a0)");
    try d.number("knocked_out_x", try immediate(rom, 0x9940, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x09940: move.w #N,(28,a0)");
    try d.number("knocked_up", try immediate(rom, 0x9934, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x09934: move.w #N,(36,a0)");
    try d.number("knocked_slowing", try immediate(rom, 0x99D2, &.{ 0x20, 0x3C }, 4), "ROM 0x099D2: move.l #N,d0");
    try d.number("bounce_most", (try immediate(rom, 0x9A72, &.{ 0x0C, 0x68 }, 2)) << 16, "ROM 0x09A72: cmpi.w #N,(36,a0)");
    try d.number("bounce_slowing", try immediate(rom, 0x9A92, &.{ 0x20, 0x3C }, 4), "ROM 0x09A92: move.l #N,d0");
    try d.number("fall_most", try immediate(rom, 0x974E, &.{ 0x0C, 0xA8 }, 4), "ROM 0x0974E: cmpi.l #N,(36,a0)");
    try d.number("hole_deep", try immediate(rom, 0x976E, &.{ 0x0C, 0x46 }, 2), "ROM 0x0976E: cmpi.w #N,d6 (a hole's floor this far down or more: drawn in front, 0x9774)");
    // Its knock-down's animation (0x97A6: its number, bit 1 cleared, `cmpi.w #4`) lands only
    // from less than `cmpi.w #N,d0` below the floor's top (0x97B4: its height less the floor's).
    if (u16be(rom, 0x97AE) != 0x0C41 or u16be(rom, 0x97B0) != 4 or u16be(rom, 0x97B4) != 0x9046) return error.BadData;
    try d.number("land_within", try immediate(rom, 0x97B6, &.{ 0x0C, 0x40 }, 2), "ROM 0x097B6: cmpi.w #N,d0 (its knock-down's height below the floor's top, 0x979C; from it, it flies on)");
    try d.number("fall_out", try immediate(rom, 0x977A, &.{ 0x0C, 0x68 }, 2), "ROM 0x0977A: cmpi.w #N,(24,a0) (fallen this far, out of the fight, 0x9782)");
    if (u16be(rom, 0x979C) != 0x3028 or u16be(rom, 0x97A4) != 0x6EDC) return error.BadData;
    try d.number("fall_out_below", try immediate(rom, 0x97A0, &.{ 0x0C, 0x40 }, 2), "ROM 0x097A0: cmpi.w #N,d0 (at or below the floor's top, its height past this: out of the fight, 0x9782)");
    try d.number("floor_ahead_x", try moveq(rom, 0x9E90, 1), "ROM 0x09E90: moveq #N,d1 (the walk's look ahead for a floor, 0x9E68; none there: it walks off, 0x9EBE)");
    try d.number("floor_ahead_depth", try moveq(rom, 0x9E92, 2), "ROM 0x09E92: moveq #N,d2");
    try d.number("fly_ahead", try moveq(rom, 0x9F56, 1), "ROM 0x09F56: moveq #N,d1 (flying off a blow, it moves across while the cell this far ahead has a height)");
    try d.number("across_ahead", try moveq(rom, 0x9F72, 1), "ROM 0x09F72: moveq #N,d1 (its walk across looks this far ahead, 0x9F6A)");
    try d.number("across_lowest", try immediate(rom, 0x9F84, &.{ 0x0C, 0x46 }, 2), "ROM 0x09F84: cmpi.w #N,d6 (a cell lower there sends it back)");
    try d.number("depth_ahead", try moveq(rom, 0x9FE6, 2), "ROM 0x09FE6: moveq #N,d2 (its walk in depth looks this far ahead, 0x9FE6)");
    try d.number("depth_lowest", try immediate(rom, 0x9FFA, &.{ 0x0C, 0x46 }, 2), "ROM 0x09FFA: cmpi.w #N,d6 (a cell lower there sends it back)");
    try d.number("lying", (try immediate(rom, 0x9A26, &.{ 0x31, 0x7C }, 2)) & 0xFF, "ROM 0x09A26: move.w #N*$101,(12,a0)");
    if (rom[0x9A4E] & 0xF1 != 0x50 or rom[0x9A4F] != 0) return error.BadData;
    try d.number("lying_least", @as(i32, rom[0x9A4E] >> 1) & 7, "ROM 0x09A4E: addq.b #N,d0 (the draw's low two bits, doubled)");
    try d.number("gets_up_frame", try frameCompared(rom, 0x9A5A), "ROM 0x09A5A: cmpi.b #N,(10,a0)");
    try d.number("blinks", (try immediate(rom, 0x9D36, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x09D36: move.w #N*$100+T,(70,a0)");
    try d.number("first_blink", (try immediate(rom, 0x9D36, &.{ 0x31, 0x7C }, 2)) & 0xFF, "ROM 0x09D36: move.w #B*$100+N,(70,a0)");
    try d.number("blink", try moveByte(rom, 0x9D84, 71), "ROM 0x09D84: move.b #N,(71,a0)");
    try d.number("stand", try moveByte(rom, 0xA460, 80), "ROM 0x0A460: move.b #N,(80,a0)");
    try d.number("struck_held", try moveByte(rom, 0xA180, 80), "ROM 0x0A180: move.b #N,(80,a0)");
    if (rom[0xA9F2] & 0xF1 != 0x51 or rom[0xA9F3] != 0x68) return error.BadData;
    try d.number("thrown_damage", @as(i32, rom[0xA9F2] >> 1) & 7, "ROM 0x0A9F2: subq.w #N,(50,a0) (a thrown body's hit)");
    try d.number("flipped_x", try immediate(rom, 0xA218, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x0A218: move.w #N,(28,a0)");
    try d.number("flipped_up", try immediate(rom, 0xA21E, &.{ 0x21, 0x7C }, 4), "ROM 0x0A21E: move.l #N,(36,a0)");
    if (u16be(rom, 0xA1E4) != 10) return error.BadData;
    try d.number("flipped_frame", try immediate(rom, 0xA1E0, &.{ 0x0C, 0x29 }, 2), "ROM 0x0A1E0: cmpi.b #N,(10,a1) (the holder's frame it is flipped over at)");
    // Lifted in a reel (0x9C50): up a little at once (0x9C58: subq.w #N,(24,a0)), at a speed up
    // by the game's tick (0x9C7E, 0x9C8C at an even tick: 0x9C84), in its knock-down's pose, or
    // the pose of one thrown for the kinds of the set 0x9C68 compares; down again, it reels still
    // a while (0x9CBA). Knocked off it (0x9CE2), it flies across (0x9AD6) a while, then falls.
    if (u16be(rom, 0x9C58) & 0xF1FF != 0x5168 or u16be(rom, 0x9C5A) != 0x18) return error.BadData;
    try d.number("lift_start", @as(i32, (u16be(rom, 0x9C58) >> 9) & 7), "ROM 0x09C58: subq.w #N,(24,a0)");
    if (u16be(rom, 0x9C82) != 0x24 or u16be(rom, 0x9C90) != 0x24 or u16be(rom, 0x9C84) != 0x0838 or u16be(rom, 0x9C88) != 0xFB09) return error.BadData;
    try d.number("lift_up", try immediate(rom, 0x9C7E, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x09C7E: move.w #N,(36,a0) (at an odd tick)");
    try d.number("lift_up_even", try immediate(rom, 0x9C8C, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x09C8C: move.w #N,(36,a0) (at an even tick, 0x09C84)");
    if (u16be(rom, 0x9C6E) != 4) return error.BadData;
    try d.number("lift_thrown", @intFromBool(d.set == @as(u32, @bitCast(try immediate(rom, 0x9C68, &.{ 0x0C, 0xA8 }, 4)))), "ROM 0x09C68: cmpi.l #N,(4,a0) (its animation set: lifted in the pose of one thrown, 1)");
    try d.number("lifted_reel", try moveByte(rom, 0x9CBA, 80), "ROM 0x09CBA: move.b #N,(80,a0)");
    if (u16be(rom, 0x9CE6) != 0x24) return error.BadData;
    try d.number("knocked_off_up", try immediate(rom, 0x9CE2, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x09CE2: move.w #N,(36,a0)");
    if (u16be(rom, 0x9AFE) != 0x1C) return error.BadData;
    try d.number("knocked_off_x", try immediate(rom, 0x9AFA, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x09AFA: move.w #N,(28,a0)");
    try d.number("knocked_off_ticks", try moveByte(rom, 0x9B00, 80), "ROM 0x09B00: move.b #N,(80,a0)");
    try d.number("knocked_off_slowing", try immediate(rom, 0x9B1E, &.{ 0x30, 0x3C }, 2) << 16, "ROM 0x09B1E: move.w #N,d0");
    try d.number("thrown_x", try immediate(rom, 0xA26C, &.{ 0x20, 0x3C }, 4), "ROM 0x0A26C: move.l #N,d0");
    try d.number("thrown_up", try immediate(rom, 0xA272, &.{ 0x22, 0x3C }, 4), "ROM 0x0A272: move.l #N,d1");
    try d.number("thrown_slide", try moveByte(rom, 0xA2C4, 80), "ROM 0x0A2C4: move.b #N,(80,a0)");
    if (rom[0xA2C0] & 0xF1 != 0x51 or rom[0xA2C1] != 0x68) return error.BadData;
    try d.number("thrown_hurt", @as(i32, rom[0xA2C0] >> 1) & 7, "ROM 0x0A2C0: subq.w #N,(50,a0) (thrown off a hold)");
    if (rom[0xA338] & 0xF1 != 0x51 or rom[0xA339] != 0x68) return error.BadData;
    try d.number("slam_hurt", @as(i32, rom[0xA338] >> 1) & 7, "ROM 0x0A338: subq.w #N,(50,a0) (slammed off a hold)");
    try d.number("slam_ticks", try moveByte(rom, 0xA300, 80), "ROM 0x0A300: move.b #N,(80,a0)");
    try d.number("knocked_back_x", (try immediate(rom, 0x9534, &.{ 0x33, 0x7C }, 2)) << 16, "ROM 0x09534: move.w #N,(28,a1) (a player's new life, 0x9494)");
    try d.number("knocked_back_up", (try immediate(rom, 0x953A, &.{ 0x33, 0x7C }, 2)) << 16, "ROM 0x0953A: move.w #N,(36,a1)");
    try d.number("slammed_x", try immediate(rom, 0xA358, &.{ 0x21, 0x7C }, 4), "ROM 0x0A358: move.l #N,(28,a0)");
    try d.number("slammed_up", try immediate(rom, 0xA360, &.{ 0x21, 0x7C }, 4), "ROM 0x0A360: move.l #N,(36,a0)");
    try d.number("grab_height", try immediate(rom, 0xAAF6, &.{ 0x0C, 0x42 }, 2), "ROM 0x0AAF6: cmpi.w #N,d2");
    // Its heading toward a point (0x982C) takes the sine and cosine of a slope from the table
    // at 0x2705E: the world computes the same table (world/fixed.zig), checked here (the level's
    // part of it, the round screen's `levels`: play.zig).
    for (sorz.world.fixed.slopes[1..], 1..) |sl, j| {
        const at = slopes + 4 * @as(u32, @intCast(j));
        if (u16be(rom, at) != sl.sine or u16be(rom, at + 2) != sl.cosine) return error.BadData;
    }
    // Held still by the special attack (0xA496): a pose by its place across's low two bits.
    try d.number("special_spin_frame", try moveByte(rom, 0xA4FC, 10), "ROM 0x0A4FC: move.b #N,(10,a0)");
    try d.number("special_spin_turn", try moveByte(rom, 0xA502, 81), "ROM 0x0A502: move.b #N,(81,a0)");
    try d.number("special_down_frame", try moveByte(rom, 0xA530, 10), "ROM 0x0A530: move.b #N,(10,a0)");
    try d.number("special_shake_pace", (try immediate(rom, 0xA54C, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0A54C: move.w #N*$101,(12,a0)");
    try d.number("special_shake_turn", try moveByte(rom, 0xA552, 81), "ROM 0x0A552: move.b #N,(81,a0)");
    // The walk off (0xDBCC): away in depth, then pacing across near its target.
    try d.number("walk_off_pace", (try immediate(rom, 0xDBEC, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0DBEC: move.w #N*$100+1,(12,a0)");
    try d.number("walk_off_depth", try immediate(rom, 0xDC1A, &.{ 0x20, 0x3C }, 4), "ROM 0x0DC1A: move.l #N,d0");
    try d.number("walk_off_faster", try immediate(rom, 0xDC28, &.{ 0x20, 0x3C }, 4), "ROM 0x0DC28: move.l #N,d0");
    try d.number("walk_off_fastest", try immediate(rom, 0xDC36, &.{ 0x20, 0x3C }, 4), "ROM 0x0DC36: move.l #N,d0");
    try d.number("walk_off_faster_after", try immediate(rom, 0xDC20, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x0DC20: cmpi.b #N,(110,a0)");
    try d.number("walk_off_fastest_after", try immediate(rom, 0xDC2E, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x0DC2E: cmpi.b #N,(110,a0)");
    try d.number("walk_off_up_from", try immediate(rom, 0xDC66, &.{ 0x0C, 0x69 }, 2), "ROM 0x0DC66: cmpi.w #N,(20,a1)");
    try d.number("walk_off_down_to", try immediate(rom, 0xDCCA, &.{ 0x0C, 0x68 }, 2), "ROM 0x0DCCA: cmpi.w #N,(20,a0)");
    try d.number("walk_off_up_to", try immediate(rom, 0xDCD6, &.{ 0x0C, 0x68 }, 2), "ROM 0x0DCD6: cmpi.w #N,(20,a0)");
    try d.number("walk_off_again", try immediate(rom, 0xDC7C, &.{ 0x0C, 0x40 }, 2), "ROM 0x0DC7C: cmpi.w #N,d0");
    try d.number("walk_off_near", try moveq(rom, 0xDD12, 0), "ROM 0x0DD12: moveq #N,d0");
    {
        if (u32be(rom, 0xDD2E + 2) != pace_lengths) return error.BadData;
        var lengths: [4]i32 = undefined;
        var speeds: [4]i32 = undefined;
        var paces: [4]i32 = undefined;
        for (0..4) |j| {
            const jj: u32 = @intCast(j);
            lengths[j] = rom[pace_lengths + jj];
            speeds[j] = @as(i32, u16be(rom, pace_speeds + 4 * jj)) << 8;
            paces[j] = u16be(rom, pace_speeds + 4 * jj + 2) >> 8;
        }
        try d.table("pacing", &lengths, "ROM 0x1033A: a stretch's ticks by a draw's low two bits (0xDD26)");
        try d.table("pacing_speed", &speeds, "ROM 0x0DD68: its speed (8.8)");
        try d.table("pacing_pace", &paces, "ROM 0x0DD6A: its frames' ticks");
    }
    // By its strength (its record's, 0 to 2): its health (its word's low byte), its blows'
    // damage (0x93CE) and its points (0x93B4).
    {
        var health: [3]i32 = undefined;
        var power: [3]i32 = undefined;
        var pts: [3]i32 = undefined;
        for (0..3) |s| {
            const ss: u32 = @intCast(s);
            health[s] = rom[enemy_numbers + 6 * k + ss];
            power[s] = rom[enemy_numbers + 6 * k + 3 + ss];
            pts[s] = try points(rom, rom[score_indices + 3 * k + ss]);
        }
        try d.table("strength_health", &health, "ROM 0x26FCE: by type, 6 bytes, the health at strength N (0x93CE)");
        try d.table("strength_power", &power, "ROM 0x26FCE: three bytes on, the power at strength N (0x93CE)");
        try d.table("strength_points", &pts, "ROM 0x27010: by type, 3 bytes, the score's index at strength N (0x93B4), the amount at ROM 0x10DDE");
    }
    // Where the enemies walk (0x9F96, 0xA00E), the screen's middle (0x97CE) and where the
    // players' blows land on them (0xAAA0).
    try d.number("walk_x_most", (try immediate(rom, 0x9FBC, &.{ 0x24, 0x3C }, 4)) >> 16, "ROM 0x09FBC: move.l #N,d2");
    try d.number("walk_depth_least", (try immediate(rom, 0xA018, &.{ 0x0C, 0x81 }, 4)) >> 16, "ROM 0x0A018: cmpi.l #N,d1");
    try d.number("walk_depth_most", (try immediate(rom, 0xA028, &.{ 0x0C, 0x81 }, 4)) >> 16, "ROM 0x0A028: cmpi.l #N,d1");
    try d.number("middle_from", try immediate(rom, 0x97D0, &.{ 0x0C, 0x68 }, 2) - 0x80, "ROM 0x097D0: cmpi.w #N+$80,(40,a0)");
    try d.number("middle_to", try immediate(rom, 0x97D8, &.{ 0x0C, 0x68 }, 2) - 0x80, "ROM 0x097D8: cmpi.w #N+$80,(40,a0)");
    try d.number("struck_from", try immediate(rom, 0xAABA, &.{ 0x0C, 0x68 }, 2) - 0x80, "ROM 0x0AABA: cmpi.w #N+$80,(40,a0)");
    try d.number("struck_to", try immediate(rom, 0xAAC2, &.{ 0x0C, 0x68 }, 2) - 0x80, "ROM 0x0AAC2: cmpi.w #N+$80,(40,a0)");
}

/// The damage of the blows of the enemy `d` (its number `power`).
fn powerOf(d: *const Def) u16 {
    for (d.numbers.items) |n| if (std.mem.eql(u8, n.name, "power")) return @intCast(n.value);
    unreachable;
}

/// The frames of `name` with an attack box are its blows (the enemies' blows: their frame's
/// attack box meets a player's body, 0xAA22).
fn blows(d: *Def, name: []const u8) void {
    for (@constCast(d.animations.items[d.animationIndex(name).?].frames)) |*f| f.blow = f.attack != null;
}

/// A state of a type's handler, named as the semantic traces name it, by the state word the
/// code writes (its high byte).
fn stateName(names: []const []const u8, word: u16) Error![]const u8 {
    const st = word >> 8;
    if (st >= names.len) return error.BadData;
    return names[st];
}

// --- Galsia ------------------------------------------------------------------------------------

/// Galsia's states by the original's number (type $22's table at 0xDD80), as the traces name them.
const galsia_states = [_][]const u8{ "appear", "choose", "reel", "knocked_down", "stand", "held", "knocked_out", "walk_off", "square_up", "close_in", "punch", "circle", "hesitate", "walk_off", "approach", "edge", "flank", "taunt", "wait", "shutter_entry" };

/// The Galsias of round 1 (type $22, its handler 0xDD78, sor-remaster's obj/galsia.zig): their
/// approaches by the way they are placed, their punch. The looks of the armed Galsias (types $20
/// and $23, whose animation set is theirs): one that finds no place for its weapon (0xD64C) or
/// loses it becomes a plain Galsia, its type alone changed, and shows on the look it had until its
/// next state sets its own.
pub fn galsia(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set = u32be(rom, enemy_sets + 4 * (0x22 - 0x20));
    if (u32be(rom, enemy_sets) != set or u32be(rom, enemy_sets + 4 * (0x23 - 0x20)) != set) return error.BadData;
    var d = try begin(arena, rom, 0x22, "galsia", &.{
        .{ .name = "punch", .entry = 10 },
        .{ .name = "walk_knife", .entry = try animEntry(rom, 0xD77E) },
        .{ .name = "jump_in", .entry = try animEntry(rom, 0xD6E2) },
        .{ .name = "stab", .entry = try animEntry(rom, 0xD89C) },
        .{ .name = "throw", .entry = try animEntry(rom, 0xD8FA) },
        .{ .name = "walk_pipe", .entry = try animEntry(rom, 0xE3BA) },
        .{ .name = "walk_pipe_b", .entry = try animEntry(rom, 0xE3C2) },
        .{ .name = "swing", .entry = try animEntry(rom, 0xE486) },
        .{ .name = "swing_b", .entry = try animEntry(rom, 0xE48E) },
    });
    try punk(&d);
    // Waiting, flanking and taunting, at the screen's edge (0xDE78, 0xDEC6, 0xDF0A, 0xDF52).
    try d.number("wait_frame", try moveByte(rom, 0xDE8C, 10), "ROM 0x0DE8C: move.b #N,(10,a0)");
    try d.number("wait_ticks", try moveByte(rom, 0xDE92, 80), "ROM 0x0DE92: move.b #N,(80,a0)");
    try d.number("wait_near", try immediate(rom, 0xDEB2, &.{ 0x0C, 0x40 }, 2), "ROM 0x0DEB2: cmpi.w #N,d0");
    try d.number("flank_beside", try immediate(rom, 0xDEE4, &.{ 0x31, 0x7C }, 2), "ROM 0x0DEE4: move.w #N,(102,a0)");
    try d.number("flank_speed", try immediate(rom, 0xDEEA, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0DEEA: move.w #N,(100,a0) (8.8)");
    try d.number("taunt_pace", (try immediate(rom, 0xDF1E, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0DF1E: move.w #N*$101,(12,a0)");
    try d.number("taunts", try moveByte(rom, 0xDF24, 80), "ROM 0x0DF24: move.b #N,(80,a0)");
    try d.number("taunt_ends", try frameCompared(rom, 0xDF32), "ROM 0x0DF32: cmpi.b #N,(10,a0)");
    try d.number("edge_speed", try immediate(rom, 0xDF6E, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0DF6E: move.w #N,(100,a0) (8.8)");
    try d.number("edge_ticks", try moveByte(rom, 0xDF74, 80), "ROM 0x0DF74: move.b #N,(80,a0)");
    try d.number("edge_right", try immediate(rom, 0xDF82, &.{ 0x30, 0x3C }, 2), "ROM 0x0DF82: move.w #N,d0");
    try d.number("edge_left", try moveq(rom, 0xDF94, 0), "ROM 0x0DF94: moveq #N,d0");
    try d.number("edge_depth", try immediate(rom, 0xDF9E, &.{ 0x31, 0x7C }, 2), "ROM 0x0DF9E: move.w #N,(98,a0)");
    try d.number("edge_near", try immediate(rom, 0xDFCA, &.{ 0x0C, 0x40 }, 2), "ROM 0x0DFCA: cmpi.w #N,d0");
    // Approaching, squaring up (0xE01E, 0xE07C).
    try d.number("approach_ticks", try moveByte(rom, 0xE02C, 80), "ROM 0x0E02C: move.b #N,(80,a0)");
    try d.number("approach_speed", try immediate(rom, 0xE032, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0E032: move.w #N,(100,a0) (8.8)");
    try d.number("square_ticks", try moveByte(rom, 0xE096, 80), "ROM 0x0E096: move.b #N,(80,a0)");
    try d.number("square_level", try immediate(rom, 0xE0C4, &.{ 0x06, 0x40 }, 2), "ROM 0x0E0C4: addi.w #N,d0");
    // Hesitating and circling (0xE2DC, 0xE20A): their tables.
    {
        var hesitate: [4]i32 = undefined;
        for (&hesitate, 0..) |*h, j| h.* = rom[0xE322 + j];
        try d.table("hesitate", &hesitate, "ROM 0x0E322: the ticks by the tick's low two bits (0xE2DC)");
        var xs: [16]i32 = undefined;
        var ds: [16]i32 = undefined;
        for (&xs, &ds, 0..) |*x, *y, j| {
            x.* = entities.s8(rom, 0x1031A + 2 * @as(u32, @intCast(j)));
            y.* = entities.s8(rom, 0x1031A + 2 * @as(u32, @intCast(j)) + 1);
        }
        try d.table("circle_x", &xs, "ROM 0x1031A: the point around its place, by a draw's low four bits (0xE20A)");
        try d.table("circle_depth", &ds, "ROM 0x1031B");
        var speeds: [4]i32 = undefined;
        var paces: [4]i32 = undefined;
        for (&speeds, &paces, 0..) |*sp, *pc, j| {
            const at: u32 = 0x10342 + 4 * @as(u32, @intCast(j));
            sp.* = @as(i32, u16be(rom, at)) << 8;
            pc.* = rom[at + 2];
        }
        try d.table("circle_speed", &speeds, "ROM 0x10342: its speed (8.8) by its place across's low two bits");
        try d.table("circle_pace", &paces, "ROM 0x10344: its frames' ticks");
        var after: [8][]const u8 = undefined;
        for (&after, 0..) |*a, j| a.* = try stateName(&galsia_states, u16be(rom, 0x10352 + 2 * @as(u32, @intCast(j))));
        try d.choice("after_circle", &after, "ROM 0x10352: the state after a circle, by the tick's low three bits");
    }
    try shutterNumbers(&d);
    return finish(&d, "galsia", 0x22, "galsia", "Galsia (handler 0xDD78)");
}

/// The numbers of the way in through a rolling shutter (0xDDE6), which the Galsia and the
/// brawler share.
fn shutterNumbers(d: *Def) Error!void {
    const rom = d.rom;
    try d.number("shutter_beside", try immediate(rom, 0xDE1E, &.{ 0x06, 0x68 }, 2), "ROM 0x0DE1E: addi.w #N,(16,a0)");
    try d.number("shutter_above", try immediate(rom, 0xDE24, &.{ 0x04, 0x68 }, 2), "ROM 0x0DE24: subi.w #N,(24,a0)");
    try d.number("shutter_drop", try immediate(rom, 0xDE40, &.{ 0x31, 0x7C }, 2), "ROM 0x0DE40: move.w #N,(36,a0) (whole pixels)");
    try d.number("shutter_depth", try immediate(rom, 0xDE52, &.{ 0x31, 0x7C }, 2), "ROM 0x0DE52: move.w #N,(20,a0)");
}

/// The palette line of an object's art, from `move.w #N,d1` at `at` (the art's place in video
/// memory, its line in bits 13 and 14, as the animation's start takes it: 0xB1D6).
fn lineOfArt(rom: []const u8, at: u32) Error!u2 {
    if (u16be(rom, at) != 0x323C) return error.BadData;
    return @intCast((u16be(rom, at + 2) >> 13) & 3);
}

/// The palette line of an object's art word written to another (`move.w #N,(14,a1)`).
fn lineOfArtGiven(rom: []const u8, at: u32) Error!u2 {
    if (u16be(rom, at) != 0x337C or u16be(rom, at + 4) != 14) return error.BadData;
    return @intCast((u16be(rom, at + 2) >> 13) & 3);
}

// --- The rolling shutter ---------------------------------------------------------------------------

/// Round 1's rolling shutter (type $54, its handler 0x101C8, sor-remaster's obj/shutter.zig): its
/// slats (the animation set at 0x26F7A), how they stack and roll, how near its player opens it.
pub fn shutter(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x10246, &.{ 0x43, 0xF9 }, 4));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "round1", .prefix = "shutter", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    const slat = try readAnimation(arena, rom, set, 0);
    const frames = try arena.alloc(entity.Frame, slat.frames.len);
    for (frames, slat.frames) |*f, r| f.* = .{ .frame = try d.frameName(r.address), .ticks = @max(slat.timing, 1), .flip = r.mirrored };
    try d.animations.append(arena, .{ .name = "slat", .loop = true, .frames = frames });
    try d.number("slats", try moveq(rom, 0x101F2, 7) + 1, "ROM 0x101F2: moveq #N-1,d7 (dbf)");
    try d.number("above", try immediate(rom, 0x101F8, &.{ 0x04, 0x42 }, 2), "ROM 0x101F8: subi.w #N,d2");
    try d.number("spacing", try immediate(rom, 0x10216, &.{ 0x04, 0x42 }, 2), "ROM 0x10216: subi.w #N,d2");
    try d.number("roll", try moveq(rom, 0x101FC, 4), "ROM 0x101FC: moveq #N,d4");
    try d.number("less", try immediate(rom, 0x10230, &.{ 0x04, 0x04, 0x00 }, 1), "ROM 0x10230: subi.b #N,d4");
    try d.number("top", try immediate(rom, 0x10238, &.{ 0x13, 0x7C, 0x00 }, 1), "ROM 0x10238: move.b #N,(80,a1)");
    try d.number("roll_speed", (try immediate(rom, 0x102B0, &.{ 0x31, 0x7C }, 2)) << 16, "ROM 0x102B0: move.w #N,(36,a0)");
    try d.number("near", try immediate(rom, 0x10260, &.{ 0x04, 0x40 }, 2), "ROM 0x10260: subi.w #N,d0");
    try d.number("beside", try immediate(rom, 0xDE1E, &.{ 0x06, 0x68 }, 2), "ROM 0x0DE1E: addi.w #N,(16,a0) (its enemy's move)");
    try d.sound("roll", @bitCast(@as(i8, @intCast(try moveq(rom, 0x102B6, 7)))));
    return .{
        .name = "shutter",
        .provenance = try std.fmt.allocPrint(arena, "the rolling shutter, type $54 (handler 0x101C8): the animation set at ROM 0x{X:0>5}; its palette line its art's (move.w #N,d1 at ROM 0x1024C){s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "shutter",
        .palette = try lineOfArt(rom, 0x1024C),
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .animations = d.animations.items,
    };
}

/// The punch and the close in Galsia and the stalker share (0xE124, 0xE190): the punch's frames
/// with a box are blows; from its last punch's frame on (0xE1FA), a blow that lands knocks down.
/// The reach the Galsia punches from is its first jab's box (0xE102); the last punch's box is
/// tested once (0xE1D8).
fn punk(d: *Def) Error!void {
    const rom = d.rom;
    blows(d, "punch");
    const punch = d.animations.items[d.animationIndex("punch").?].frames;
    const reach_box = try moveq(rom, 0xE102, 1);
    const last_box = try moveq(rom, 0xE1D8, 1);
    const reach_frame = for (punch, 0..) |f, j| {
        if (f.attack) |b| if (d.box_keys.items[b][1] == reach_box) break j;
    } else return error.BadData;
    const last_frame = for (punch, 0..) |f, j| {
        if (f.attack) |b| if (d.box_keys.items[b][1] == last_box) break j;
    } else return error.BadData;
    const knocks_from = try frameCompared(rom, 0xE1FA);
    if (knocks_from != last_frame) return error.BadData;
    const index = d.animationIndex("punch").?;
    const power = powerOf(d);
    try d.moves.append(d.arena, .{ .name = "punch", .provenance = "the punch (0xE190), its damage the type's power (0x93CE)", .animation = index, .damage = power });
    try d.moves.append(d.arena, .{ .name = "punch_last", .provenance = "the punch's last blow, from its last punch's frame on (0xE1FA): it knocks down", .animation = index, .damage = power, .reaction = .knock_down });
    try d.number("reach_frame", @intCast(reach_frame), "the punch's frame with box 18 (ROM 0x0E102: moveq #18,d1)");
    try d.number("last_punch_frame", @intCast(last_frame), "the punch's frame with box 62 (ROM 0x0E1D8: moveq #62,d1)");
    try d.number("last_punch_test", try frameCompared(rom, 0xE1CA), "ROM 0x0E1CA: cmpi.b #N,(10,a0)");
    try d.number("punch_ends", try frameCompared(rom, 0xE1EA), "ROM 0x0E1EA: cmpi.b #N,(10,a0)");
    try d.number("close_in_speed", try immediate(rom, 0xE14A, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0E14A: move.w #N,(100,a0) (8.8)");
    try d.number("close_in_slow", try immediate(rom, 0xE158, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0E158: move.w #N,(100,a0) (8.8, one placed slow)");
    try d.number("close_in_ticks", try moveByte(rom, 0xE144, 80), "ROM 0x0E144: move.b #N,(80,a0)");
    try d.number("close_in_beside", try moveq(rom, 0xE16A, 1), "ROM 0x0E16A: moveq #N,d1");
    try d.number("close_in_pace", (try immediate(rom, 0xE138, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0E138: move.w #N*$100+1,(12,a0)");
    try d.number("too_close", try immediate(rom, 0xE0FC, &.{ 0x0C, 0x40 }, 2), "ROM 0x0E0FC: cmpi.w #N,d0");
    try d.number("edge_punch_pace", (try immediate(rom, 0xE1B4, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0E1B4: move.w #N*$101,(12,a0)");
}

// --- The stalker -------------------------------------------------------------------------------

/// The stalker Galsias (type $21, its handler 0xD99A): they head for their place beside their
/// target, lurk there, sneak up on a target that turns its back and grab it from behind; they
/// share the Galsia's close in and punch.
pub fn stalker(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try begin(arena, rom, 0x21, "galsia", &.{ .{ .name = "punch", .entry = 10 }, .{ .name = "grab", .entry = 12 } });
    try punk(&d);
    try d.number("approach_speed", try immediate(rom, 0xD9D6, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0D9D6: move.w #N,(100,a0) (8.8)");
    try d.number("approach_ticks", try moveByte(rom, 0xD9E2, 80), "ROM 0x0D9E2: move.b #N,(80,a0)");
    try d.number("lurk_ticks", try moveByte(rom, 0xDA1E, 80), "ROM 0x0DA1E: move.b #N,(80,a0)");
    try d.number("sneak_pace", try moveByte(rom, 0xDAA6, 12), "ROM 0x0DAA6: move.b #N,(12,a0)");
    try d.number("sneak_speed", try immediate(rom, 0xDAAC, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0DAAC: move.w #N,(100,a0) (8.8)");
    // The box it sneaks up with, which grabs (0xDAB8: its frame's attack box set to it).
    const grab_box: u8 = @intCast(try moveByte(rom, 0xDAB8, 2));
    _ = try d.box(1, grab_box, grab_box, "sneak", "grab");
    try d.number_notes.print(arena, "; the sneak's box: ROM 0x0DAB8: move.b #N,(2,a0)", .{});
    return finish(&d, "galsia_stalker", 0x21, "stalker", "the stalker Galsia (handler 0xD99A)");
}

// --- Signal ------------------------------------------------------------------------------------

/// Signal (type $24, its handler 0xE4D2, sor-remaster's obj/signal.zig): it runs slantwise to its
/// place, sizes its target up, closes in or slides in with a kick; walking into its target it
/// holds it and throws it.
pub fn signal(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try begin(arena, rom, 0x24, "signal", &.{ .{ .name = "hold", .entry = 10 }, .{ .name = "slide", .entry = 12 } });
    blows(&d, "slide");
    const power = powerOf(&d);
    try d.moves.append(arena, .{ .name = "slide", .provenance = "the slide kick (0xE80A): a blow that lands knocks down (reaction 1)", .animation = d.animationIndex("slide").?, .damage = power, .reaction = .knock_down });
    try d.number("approach_speed", try immediate(rom, 0xE516, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0E516: move.w #N,(100,a0) (8.8)");
    try d.number("approach_ticks", try moveByte(rom, 0xE51C, 80), "ROM 0x0E51C: move.b #N,(80,a0)");
    try d.number("diagonal_x", try immediate(rom, 0xE55A, &.{ 0x24, 0x3C }, 4), "ROM 0x0E55A: move.l #N,d2");
    try d.number("diagonal_depth", try immediate(rom, 0xE56C, &.{ 0x24, 0x3C }, 4), "ROM 0x0E56C: move.l #N,d2");
    try d.number("size_up_ticks", try moveByte(rom, 0xE602, 80), "ROM 0x0E602: move.b #N,(80,a0)");
    try d.number("far", try immediate(rom, 0xE63C, &.{ 0x0C, 0x80 }, 4), "ROM 0x0E63C: cmpi.l #N,d0 (0x98E8's estimate)");
    try d.number("slide_level", try quick(rom, 0xE652, 0x5140), "ROM 0x0E652: subq.w #N,d0");
    try d.number("close_in_pace", (try immediate(rom, 0xE692, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0E692: move.w #N*$101,(12,a0)");
    try d.number("close_in_ticks", try moveByte(rom, 0xE698, 80), "ROM 0x0E698: move.b #N,(80,a0)");
    try d.number("close_in_speed", try immediate(rom, 0xE69E, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0E69E: move.w #N,(100,a0) (8.8)");
    try d.number("slide_ticks", try moveByte(rom, 0xE826, 80), "ROM 0x0E826: move.b #N,(80,a0)");
    try d.number("slide_speed", try immediate(rom, 0xE85C, &.{ 0x20, 0x3C }, 4), "ROM 0x0E85C: move.l #N,d0");
    try d.number("slide_slowing", -(try immediate(rom, 0xE876, &.{ 0x20, 0x3C }, 4)), "ROM 0x0E876: move.l #-N,d0");
    try d.number("slide_end_ticks", try moveByte(rom, 0xE896, 80), "ROM 0x0E896: move.b #N,(80,a0)");
    try d.number("slide_end_frame", try moveByte(rom, 0xE89C, 10), "ROM 0x0E89C: move.b #N,(10,a0)");
    try d.number("hold_middle", try immediate(rom, 0xE71E, &.{ 0x06, 0x40 }, 2), "ROM 0x0E71E: addi.w #N,d0");
    // In one round the hold faces right wherever it is: `cmpi.w #N,($FF02)` at 0xE712, `beq`
    // past the test of its place.
    if (u16be(rom, 0xE712) != 0x0C78 or u16be(rom, 0xE716) != 0xFF02 or rom[0xE718] != 0x67) return error.BadData;
    try d.number("hold_right_round", @as(i32, u16be(rom, 0xE714)) + 1, "ROM 0x0E714: cmpi.w #N,($FF02), the round from 0");
    try d.number("hold_place", -(try moveq(rom, 0xE744, 0)), "ROM 0x0E744: moveq #-N,d0");
    try d.number("hold_ends", try frameCompared(rom, 0xE7A0), "ROM 0x0E7A0: cmpi.b #N,(10,a0)");
    if (try frameTicksCompared(rom, 0xE77C) != 1) return error.BadData;
    try d.number_notes.print(arena, "; the throw at its first frame's last tick: ROM 0x0E77C: cmpi.b #1,(13,a0)", .{});
    try d.sound("slide", @bitCast(@as(i8, @intCast(try moveq(rom, 0xE850, 7)))));
    return finish(&d, "signal", 0x24, "signal", "Signal (handler 0xE4D2)");
}

/// `cmpi.b #N,(13,a0)`: a frame's ticks left compared.
fn frameTicksCompared(rom: []const u8, at: u32) Error!i32 {
    if (u16be(rom, at) != 0x0C28 or rom[at + 2] != 0 or u16be(rom, at + 4) != 13) return error.BadData;
    return rom[at + 3];
}

// --- The pipe Galsia ---------------------------------------------------------------------------

/// The pipe Galsia (type $23, its handler 0xE326, sor-remaster's obj/galsia_armed.zig): it takes
/// up its pipe (0xD64C), heads for its place, stands, closes in and swings; its walk and its swing
/// hold the pipe (the hands at 0x60A0), its second pipe's for variants other than 0.
pub fn galsiaPipe(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try begin(arena, rom, 0x23, "galsia", &.{
        .{ .name = "walk_pipe", .entry = try animEntry(rom, 0xE3BA) },
        .{ .name = "walk_pipe_b", .entry = try animEntry(rom, 0xE3C2) },
        .{ .name = "swing", .entry = try animEntry(rom, 0xE486) },
        .{ .name = "swing_b", .entry = try animEntry(rom, 0xE48E) },
    });
    try weapons.enemyHands(&d, "walk_pipe", @intCast(try moveq(rom, 0xE3BA, 0)));
    try weapons.enemyHands(&d, "walk_pipe_b", @intCast(try moveq(rom, 0xE3C2, 0)));
    try weapons.enemyHands(&d, "swing", @intCast(try moveq(rom, 0xE486, 0)));
    try weapons.enemyHands(&d, "swing_b", @intCast(try moveq(rom, 0xE48E, 0)));
    // The swing: its frames with a box are blows, its damage the type's power (0xE47E).
    blows(&d, "swing");
    blows(&d, "swing_b");
    const power = powerOf(&d);
    try d.moves.append(arena, .{ .name = "swing", .provenance = "the swing (0xE47E), its damage the type's power (0x93CE)", .animation = d.animationIndex("swing").?, .damage = power });
    try d.moves.append(arena, .{ .name = "swing_b", .provenance = "the swing with the second pipe (0xE47E)", .animation = d.animationIndex("swing_b").?, .damage = power });
    try d.number("approach_speed", try immediate(rom, 0xE3A8, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0E3A8: move.w #N,(100,a0) (8.8)");
    try d.number("wait_ticks", try moveByte(rom, 0xE420, 80), "ROM 0x0E420: move.b #N,(80,a0)");
    try d.number("wait_level", try immediate(rom, 0xE44A, &.{ 0x06, 0x40 }, 2), "ROM 0x0E44A: addi.w #N,d0");
    try d.number("close_in_pace", (try immediate(rom, 0xE356, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0E356: move.w #N*$101,(12,a0)");
    try d.number("close_in_ticks", try moveByte(rom, 0xE35C, 80), "ROM 0x0E35C: move.b #N,(80,a0)");
    try d.number("close_in_speed", try immediate(rom, 0xE362, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0E362: move.w #N,(100,a0) (8.8)");
    try d.number("close_in_beside", try moveq(rom, 0xE378, 1), "ROM 0x0E378: moveq #N,d1");
    try d.number("swing_pace", (try immediate(rom, 0xE49A, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0E49A: move.w #N*$101,(12,a0)");
    try d.number("swing_sound_frame", try frameCompared(rom, 0xE4AE), "ROM 0x0E4AE: cmpi.b #N,(10,a0)");
    try d.number("swing_ends", try frameCompared(rom, 0xE4C2), "ROM 0x0E4C2: cmpi.b #N,(10,a0)");
    try d.sound("swing", @bitCast(@as(i8, @intCast(try moveq(rom, 0xE4BC, 7)))));
    return finish(&d, "galsia_pipe", 0x23, "galsia_pipe", "the pipe Galsia (handler 0xE326)");
}

// --- The acrobat --------------------------------------------------------------------------------

/// The acrobat (type $25, its handler 0xE8F0, sor-remaster's obj/acrobat.zig): it circles its
/// place, lines up, dashes, closes in and punches, somersaults, jump kicks and flips.
pub fn acrobat(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try acrobatOf(arena, rom, 0x25);
    return finish(&d, "acrobat", 0x25, "acrobat", "the acrobat (handler 0xE8F0)");
}

/// The acrobats who fight as a trio (type $2A, handler 0xF7D0, sor-remaster's
/// obj/acrobat_trio.zig): the acrobat's art, attacks and numbers, and the trio's own: its others
/// brought beside the leader (0xF7D8), their places out from the screen's middle (0xF93C), the
/// walk there, the pose and the charge (0xFB40), the brace (0xF9B6), the leap across (0xF9F0).
pub fn acrobatTrio(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try acrobatOf(arena, rom, 0x2A);
    try d.number("role_1_beside", try moveq(rom, 0xF83E, 0), "ROM 0x0F83E: moveq #N,d0 (role 1's place ahead of the leader)");
    try d.number("role_0_beside", try moveq(rom, 0xF84C, 0), "ROM 0x0F84C: moveq #N,d0 (role 0's)");
    if (u32be(rom, 0xF93C) != 0x3038E002 or u32be(rom, 0xF996) != 0x3038E002 or u32be(rom, 0xFA0C) != 0x3038E002) return error.BadData;
    const middle = try immediate(rom, 0xF940, &.{ 0x06, 0x40 }, 2);
    if (try immediate(rom, 0xF99A, &.{ 0x06, 0x40 }, 2) != middle or try immediate(rom, 0xFA10, &.{ 0x06, 0x40 }, 2) != middle) return error.BadData;
    try d.number("middle", middle, "ROM 0x0F940: addi.w #N,d0 (to the camera's place across, $FFE002)");
    try d.number("leader_out", try moveq(rom, 0xF95C, 1), "ROM 0x0F95C: moveq #N,d1");
    try d.number("role_1_out", try immediate(rom, 0xF974, &.{ 0x32, 0x3C }, 2), "ROM 0x0F974: move.w #N,d1");
    try d.number("role_0_out", try immediate(rom, 0xF97E, &.{ 0x32, 0x3C }, 2), "ROM 0x0F97E: move.w #N,d1");
    try d.number("place_pace", (try immediate(rom, 0xF898, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0F898: move.w #N*$100+1,(12,a0)");
    try d.number("place_speed", try immediate(rom, 0xF89E, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0F89E: move.w #N,(100,a0) (8.8)");
    const near = try immediate(rom, 0xFAFE, &.{ 0x0C, 0x40 }, 2);
    if (try immediate(rom, 0xFA80, &.{ 0x0C, 0x40 }, 2) != near) return error.BadData;
    try d.number("near", near, "ROM 0x0FAFE: cmpi.w #N,d0 (holding: it leaps at its target; landing, ROM 0x0FA80: it closes in)");
    if (try moveq(rom, 0xFB56, 0) != 4) return error.BadData;
    try d.number("pose_frame", try moveByte(rom, 0xFB5C, 10), "ROM 0x0FB5C: move.b #N,(10,a0) (of its knock-down's frames, animation 4: ROM 0x0FB56)");
    try d.number("pose_ticks", try moveByte(rom, 0xFB62, 80), "ROM 0x0FB62: move.b #N,(80,a0)");
    try d.number("charge_speed", try immediate(rom, 0xFB7A, &.{ 0x21, 0x7C }, 4), "ROM 0x0FB7A: move.l #N,(28,a0)");
    try d.number("charge_pace", (try immediate(rom, 0xFB8E, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0FB8E: move.w #N*$100+1,(12,a0)");
    try d.number("role_0_near", try immediate(rom, 0xFBE4, &.{ 0x0C, 0x41 }, 2), "ROM 0x0FBE4: cmpi.w #N,d1");
    try d.number("role_1_near", try immediate(rom, 0xFBF2, &.{ 0x0C, 0x41 }, 2), "ROM 0x0FBF2: cmpi.w #N,d1");
    try d.number("leader_near", try immediate(rom, 0xFC06, &.{ 0x0C, 0x41 }, 2), "ROM 0x0FC06: cmpi.w #N,d1");
    try d.number("brace_ticks", try moveByte(rom, 0xF9D0, 80), "ROM 0x0F9D0: move.b #N,(80,a0)");
    if (try moveq(rom, 0xF9FE, 0) != 28) return error.BadData;
    try d.number("leap_up", try immediate(rom, 0xFA04, &.{ 0x21, 0x7C }, 4), "ROM 0x0FA04: move.l #N,(36,a0) (the flip's animation, 28: ROM 0x0F9FE)");
    try d.number("leap_holds", try frameCompared(rom, 0xFA52), "ROM 0x0FA52: cmpi.b #N,(10,a0)");
    var speeds: [4]i32 = undefined;
    for (&speeds, 0..) |*v, k| v.* = @as(i8, @bitCast(rom[0xFA8E + k]));
    try d.table("leap_speeds", &speeds, "ROM 0x0FA8E: bytes, by the low byte of the distance to the middle, in quarters of 64 (0xFA1C)");
    var offsets: [16]i32 = undefined;
    for (&offsets, 0..) |*v, k| v.* = @as(i8, @bitCast(rom[0x9484 + k]));
    try d.table("offsets", &offsets, "ROM 0x09484: the offsets from the target by a nibble (0x945A): its others' offsets' byte one on for role 1 (0xF7D8)");
    return finish(&d, "acrobat_trio", 0x2A, "acrobat_trio", "the acrobats of a trio (handler 0xF7D0)");
}

/// An acrobat's definition of type `kind` (the acrobat's, the trio's): the acrobat's art, attacks
/// and numbers.
fn acrobatOf(arena: std.mem.Allocator, rom: []const u8, kind: u8) Error!Def {
    var d = try begin(arena, rom, kind, "acrobat", &.{
        .{ .name = "punch", .entry = try animEntryWord(rom, 0xEB7C) },
        .{ .name = "jump_kick", .entry = try animEntryWord(rom, 0xEDEC) },
        .{ .name = "flip", .entry = try animEntry(rom, 0xEE9E) },
        .{ .name = "turn", .entry = try animEntry(rom, 0xEADA) },
    });
    if (try animEntryWord(rom, 0xEBDC) != try animEntryWord(rom, 0xEB7C)) return error.BadData;
    blows(&d, "punch");
    blows(&d, "jump_kick");
    const power = powerOf(&d);
    try d.moves.append(arena, .{ .name = "punch", .provenance = "the punch (0xEB6E), its damage the type's power (0x93CE)", .animation = d.animationIndex("punch").?, .damage = power });
    try d.moves.append(arena, .{ .name = "somersault", .provenance = "the somersault (0xEBAC), the punch's frames held", .animation = d.animationIndex("punch").?, .damage = power });
    try d.moves.append(arena, .{ .name = "jump_kick", .provenance = "the jump kick (0xEDD8): a blow that lands knocks down (reaction 1)", .animation = d.animationIndex("jump_kick").?, .damage = power, .reaction = .knock_down });
    // The box its close in reaches with (0xEF0A: 0xAD04 with box 6, or 7 facing left).
    const reach: u8 = @intCast(try moveq(rom, 0xEF64, 1));
    try namedBox(&d, reach, reach + 1, "close_in", "reach");
    try d.number_notes.print(arena, "; the close in's reach: ROM 0x0EF64: moveq #N,d1", .{});
    try d.number("approach_speed", try immediate(rom, 0xEB4A, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0EB4A: move.w #N,(100,a0) (8.8)");
    try d.number("circle_pause", try moveByte(rom, 0xEC90, 80), "ROM 0x0EC90: move.b #N,(80,a0)");
    try d.number("circle_turns", try moveByte(rom, 0xECA6, 81), "ROM 0x0ECA6: move.b #N,(81,a0)");
    try d.number("circle_stops", try moveByte(rom, 0xECAC, 82), "ROM 0x0ECAC: move.b #N,(82,a0)");
    try d.number("circle_near", try immediate(rom, 0xECD0, &.{ 0x0C, 0x40 }, 2), "ROM 0x0ECD0: cmpi.w #N,d0");
    try d.number("level_speed", try immediate(rom, 0xED5E, &.{ 0x20, 0x3C }, 4), "ROM 0x0ED5E: move.l #N,d0");
    try d.number("level_dash_bits", try immediate(rom, 0xEDA8, &.{ 0x02, 0x00, 0x00 }, 1), "ROM 0x0EDA8: andi.b #N,d0 (a draw)");
    try d.number("level_near", try immediate(rom, 0xEDBA, &.{ 0x0C, 0x41 }, 2), "ROM 0x0EDBA: cmpi.w #N,d1");
    try d.number("close_in_pace", (try immediate(rom, 0xEF1E, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0EF1E: move.w #N*$100+1,(12,a0)");
    try d.number("close_in_ticks", try moveByte(rom, 0xEF2A, 80), "ROM 0x0EF2A: move.b #N,(80,a0)");
    try d.number("close_in_speed", try immediate(rom, 0xEF40, &.{ 0x3C, 0x3C }, 2) << 8, "ROM 0x0EF40: move.w #N,d6 (8.8)");
    try d.number("close_in_fast", try immediate(rom, 0xEF4C, &.{ 0x3C, 0x3C }, 2) << 8, "ROM 0x0EF4C: move.w #N,d6 (8.8)");
    try d.number("close_in_slow", try immediate(rom, 0xEF58, &.{ 0x3C, 0x3C }, 2) << 8, "ROM 0x0EF58: move.w #N,d6 (8.8)");
    try d.number("close_in_beside", try moveq(rom, 0xEF3E, 3), "ROM 0x0EF3E: moveq #N,d3");
    try d.number("close_in_level", try immediate(rom, 0xEF86, &.{ 0x0C, 0x40 }, 2), "ROM 0x0EF86: cmpi.w #N,d0");
    try d.number("close_in_near", try immediate(rom, 0xEF98, &.{ 0x0C, 0x40 }, 2), "ROM 0x0EF98: cmpi.w #N,d0");
    try d.number("punch_ends", try frameCompared(rom, 0xEB96), "ROM 0x0EB96: cmpi.b #N,(10,a0)");
    try d.number("somersault_x", try immediate(rom, 0xEBC6, &.{ 0x21, 0x7C }, 4), "ROM 0x0EBC6: move.l #N,(28,a0)");
    try d.number("somersault_up", try immediate(rom, 0xEBCE, &.{ 0x21, 0x7C }, 4), "ROM 0x0EBCE: move.l #N,(36,a0)");
    try d.number("somersault_near", try immediate(rom, 0xEC00, &.{ 0x0C, 0x40 }, 2), "ROM 0x0EC00: cmpi.w #N,d0");
    try d.number("somersault_ends", try frameCompared(rom, 0xEC42), "ROM 0x0EC42: cmpi.b #N,(10,a0)");
    try d.number("dash_pace", (try immediate(rom, 0xEFCA, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0EFCA: move.w #N*$100+1,(12,a0)");
    try d.number("dash_speed", try immediate(rom, 0xEFE6, &.{ 0x3C, 0x3C }, 2) << 8, "ROM 0x0EFE6: move.w #N,d6 (8.8)");
    try d.number("dash_near", try immediate(rom, 0xF002, &.{ 0x0C, 0x40 }, 2), "ROM 0x0F002: cmpi.w #N,d0");
    try d.number("dash_back_ticks", try moveByte(rom, 0xF012, 80), "ROM 0x0F012: move.b #N,(80,a0)");
    try d.number("dash_back_depth", try immediate(rom, 0xF018, &.{ 0x21, 0x7C }, 4), "ROM 0x0F018: move.l #N,(32,a0)");
    try d.number("jump_kick_up", try immediate(rom, 0xEDF4, &.{ 0x21, 0x7C }, 4), "ROM 0x0EDF4: move.l #N,(36,a0)");
    try d.number("jump_kick_x", try immediate(rom, 0xEDFC, &.{ 0x20, 0x3C }, 4), "ROM 0x0EDFC: move.l #N,d0");
    try d.number("jump_kick_holds", try frameCompared(rom, 0xEE2A), "ROM 0x0EE2A: cmpi.b #N,(10,a0)");
    try d.number("flip_up", try immediate(rom, 0xEEA4, &.{ 0x21, 0x7C }, 4), "ROM 0x0EEA4: move.l #N,(36,a0)");
    try d.number("flip_x", try immediate(rom, 0xEEAC, &.{ 0x20, 0x3C }, 4), "ROM 0x0EEAC: move.l #N,d0");
    try d.number("back_flip_up", try immediate(rom, 0xEEBA, &.{ 0x21, 0x7C }, 4), "ROM 0x0EEBA: move.l #N,(36,a0)");
    try d.number("back_flip_x", try immediate(rom, 0xEEC2, &.{ 0x20, 0x3C }, 4), "ROM 0x0EEC2: move.l #N,d0");
    try d.number("flip_holds", try frameCompared(rom, 0xEEDE), "ROM 0x0EEDE: cmpi.b #N,(10,a0)");
    // The flip away from a knock-down (0xEA8A): its speeds (whole pixels), its frames' pace, the
    // frame it turns to its target at; down again, the frame it crouches in and its ticks.
    try d.number("flip_away_x", try moveWord(rom, 0xEA98, 28), "ROM 0x0EA98: move.w #N,(28,a0) (whole pixels, away from the one who struck it)");
    try d.number("flip_away_up", try moveWord(rom, 0xEA9E, 36), "ROM 0x0EA9E: move.w #N,(36,a0) (whole pixels)");
    try d.number("flip_away_pace", (try moveWord(rom, 0xEAB6, 12)) >> 8, "ROM 0x0EAB6: move.w #N*$101,(12,a0)");
    try d.number("flip_away_turns", try frameCompared(rom, 0xEACC), "ROM 0x0EACC: cmpi.b #N,(10,a0)");
    if (try animEntry(rom, 0xEAF0) != 2) return error.BadData;
    try d.number("flip_away_crouch", try moveByte(rom, 0xEAF6, 10), "ROM 0x0EAF6: move.b #N,(10,a0) (its knock-down's frame, held)");
    try d.number("flip_away_ticks", try moveByte(rom, 0xEB02, 80), "ROM 0x0EB02: move.b #N,(80,a0)");
    // Coming in (0xE952): its leap from below the wall, its drop from above.
    if (try animEntry(rom, 0xE972) != try animEntry(rom, 0xEE9E)) return error.BadData;
    if (u16be(rom, 0xE97C) != 24) return error.BadData;
    try d.number("enter_below", try immediate(rom, 0xE978, &.{ 0x06, 0x68 }, 2), "ROM 0x0E978: addi.w #N,(24,a0)");
    try d.number("enter_up", try moveWord(rom, 0xE96C, 36), "ROM 0x0E96C: move.w #N,(36,a0) (whole pixels)");
    if (u16be(rom, 0xEA20) != 36) return error.BadData;
    try d.number("enter_gravity", try immediate(rom, 0xEA1A, &.{ 0x06, 0xA8 }, 4), "ROM 0x0EA1A: addi.l #N,(36,a0)");
    if (try immediate(rom, 0xE9C8, &.{ 0x06, 0x40 }, 2) != try immediate(rom, 0xE9BC, &.{ 0x06, 0x40 }, 2)) return error.BadData;
    try d.number("enter_near", try immediate(rom, 0xE9BC, &.{ 0x06, 0x40 }, 2), "ROM 0x0E9BC: addi.w #N,d0 (to the camera's place; 0x0E9C8 as much again unless its record's bit 5)");
    if (try frameCompared(rom, 0xEA0C) != try moveByte(rom, 0xE9DA, 10)) return error.BadData;
    try d.number("enter_frame", try moveByte(rom, 0xE9DA, 10), "ROM 0x0E9DA: move.b #N,(10,a0)");
    if (u16be(rom, 0xEA32) != 20) return error.BadData;
    try d.number("enter_deeper", try quick(rom, 0xEA30, 0x5068), "ROM 0x0EA30: addq.w #N,(20,a0)");
    try d.number("drop_height", try moveWord(rom, 0xE986, 24), "ROM 0x0E986: move.w #N,(24,a0)");
    try d.number("drop_spread", try immediate(rom, 0xE996, &.{ 0x02, 0x40 }, 2), "ROM 0x0E996: andi.w #N,d0 (a draw)");
    try d.number("drop_x", try immediate(rom, 0xE99A, &.{ 0x06, 0x40 }, 2), "ROM 0x0E99A: addi.w #N,d0");
    try d.number("drop_depth", try moveWord(rom, 0xE9A2, 20), "ROM 0x0E9A2: move.w #N,(20,a0)");
    if (try moveq(rom, 0xEA44, 7) != try moveq(rom, 0xEEF6, 7)) return error.BadData;
    try d.sound("leap", @bitCast(@as(i8, @intCast(try moveq(rom, 0xEDE0, 7)))));
    try d.sound("land", @bitCast(@as(i8, @intCast(try moveq(rom, 0xEEF6, 7)))));
    try d.sound("flip_away", @bitCast(@as(i8, @intCast(try moveq(rom, 0xEA92, 7)))));
    return d;
}

/// The box of the pair (`right`, `left`) of the objects' table named `animation`_`role`, which a
/// behaviour tests by name, also when frames use it under another.
fn namedBox(d: *Def, right: u8, left: u8, animation: []const u8, role: []const u8) Error!void {
    const name = try std.fmt.allocPrint(d.arena, "{s}_{s}", .{ animation, role });
    const i = (try d.box(1, right, left, animation, role)) orelse return error.BadData;
    if (std.mem.eql(u8, d.boxes.items[i].name, name)) return;
    var b = d.boxes.items[i];
    b.name = name;
    try d.boxes.append(d.arena, b);
    // A key no frame's pair takes.
    try d.box_keys.append(d.arena, .{ 0xFF, right, left });
}

/// The animation set's entry of the animation number the `move.w #N,d0` at `at` names.
fn animEntryWord(rom: []const u8, at: u32) Error!u32 {
    const anim = try immediate(rom, at, &.{ 0x30, 0x3C }, 2);
    if (anim < 0 or @mod(anim, 4) != 0) return error.BadData;
    return @intCast(@divExact(anim, 2));
}

/// The animation set's entry of the animation number the `moveq #N,d0` at `at` names (facing
/// right).
fn animEntry(rom: []const u8, at: u32) Error!u32 {
    const anim = try moveq(rom, at, 0);
    if (anim < 0 or @mod(anim, 4) != 0) return error.BadData;
    return @intCast(@divExact(anim, 2));
}

// --- The knife Galsia --------------------------------------------------------------------------

/// The knife Galsia (type $20, its handler 0xD606, sor-remaster's obj/galsia_armed.zig): it takes
/// up a knife (0xD64C), closes in to its place beside its target (0xD76A) or rushes past it
/// (0xD6C0), sizes it up (0xD7BE), then near stabs (0xD856), far throws its knife (0xD8EC) and
/// takes up another; its walk, its rush, its stab and its throw hold the knife (the hands at
/// 0x60A0).
pub fn galsiaKnife(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try begin(arena, rom, 0x20, "galsia", &.{
        .{ .name = "walk_knife", .entry = try animEntry(rom, 0xD77E) },
        .{ .name = "jump_in", .entry = try animEntry(rom, 0xD6E2) },
        .{ .name = "stab", .entry = try animEntry(rom, 0xD89C) },
        .{ .name = "throw", .entry = try animEntry(rom, 0xD8FA) },
    });
    try weapons.enemyHands(&d, "walk_knife", @intCast(try moveq(rom, 0xD77E, 0)));
    try weapons.enemyHands(&d, "jump_in", @intCast(try moveq(rom, 0xD6E2, 0)));
    try weapons.enemyHands(&d, "stab", @intCast(try moveq(rom, 0xD89C, 0)));
    try weapons.enemyHands(&d, "throw", @intCast(try moveq(rom, 0xD8FA, 0)));
    // The stab: its frames with a box are blows, its damage the type's power; its reach.
    blows(&d, "stab");
    blows(&d, "jump_in");
    const power = powerOf(&d);
    const stab_sound = try entities.soundName(@bitCast(@as(i8, @intCast(try moveq(rom, 0xD872, 7)))));
    try d.moves.append(arena, .{ .name = "stab", .provenance = "the stab (0xD856), its damage the type's power (0x93CE); its sound when it lands (ROM 0x0D872: moveq #N,d7)", .animation = d.animationIndex("stab").?, .damage = power, .hit_sound = stab_sound });
    try d.moves.append(arena, .{ .name = "jump_in", .provenance = "the rush (0xD6FC: a blow that lands knocks down, reaction 1, 0xD704), its damage the type's power", .animation = d.animationIndex("jump_in").?, .damage = power, .reaction = .knock_down });
    const reach_right: u8 = @intCast(try immediate(rom, 0xD880, &.{ 0x32, 0x3C }, 2));
    const reach_left: u8 = @intCast(try immediate(rom, 0xD88C, &.{ 0x32, 0x3C }, 2));
    try namedBox(&d, reach_right, reach_left, "stab", "reach");
    try d.number_notes.print(arena, "; the stab's reach: ROM 0x0D880, 0x0D88C: move.w #N,d1", .{});
    try d.number("jump_in_speed", try immediate(rom, 0xD6E8, &.{ 0x3C, 0x3C }, 2) << 8, "ROM 0x0D6E8: move.w #N,d6 (8.8)");
    try d.number("jump_in_pace", (try immediate(rom, 0xD738, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0D738: move.w #N*$101,(12,a0)");
    try d.number("jump_in_slowing", try immediate(rom, 0xD73E, &.{ 0x20, 0x3C }, 4), "ROM 0x0D73E: move.l #N,d0");
    try d.number("close_in_speed", try immediate(rom, 0xD78A, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0D78A: move.w #N,(100,a0) (8.8)");
    try d.number("close_in_first", try moveByte(rom, 0xD784, 13), "ROM 0x0D784: move.b #N,(13,a0)");
    try d.number("size_up_ticks", try moveByte(rom, 0xD7C6, 80), "ROM 0x0D7C6: move.b #N,(80,a0)");
    if (u16be(rom, 0xD7FE) != 0x5040 or u16be(rom, 0xD800) != 0x5141) return error.BadData;
    try d.number("size_up_level", 8, "ROM 0x0D7FE: addq.w #8,d0, 0x0D800: subq.w #8,d1");
    try d.number("stab_near", try immediate(rom, 0xD81E, &.{ 0x0C, 0x40 }, 2), "ROM 0x0D81E: cmpi.w #N,d0");
    try d.number("stab_speed", try immediate(rom, 0xD864, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0D864: move.w #N,(100,a0) (8.8)");
    try d.number("stab_beside", try moveq(rom, 0xD8D6, 1), "ROM 0x0D8D6: moveq #N,d1");
    try d.number("stab_pace", (try immediate(rom, 0xD8A2, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0D8A2: move.w #N*$101,(12,a0)");
    try d.number("stab_again", try frameCompared(rom, 0xD8A8), "ROM 0x0D8A8: cmpi.b #N,(10,a0)");
    try d.number("throw_frame", try frameCompared(rom, 0xD90E), "ROM 0x0D90E: cmpi.b #N,(10,a0)");
    try d.number("throw_ends", try frameCompared(rom, 0xD938), "ROM 0x0D938: cmpi.b #N,(10,a0)");
    try d.sound("throw", @bitCast(@as(i8, @intCast(try moveq(rom, 0xD932, 7)))));
    return finish(&d, "galsia_knife", 0x20, "galsia_knife", "the knife Galsia (handler 0xD606)");
}

// --- The brawler --------------------------------------------------------------------------------

/// The brawler (type $26, its handler 0xF038, its states at 0x10362): it follows its target
/// (0xF0FC), closes in and punches (0xF1B0, a blow that knocks down: reaction 1, 0xF1F0), comes in
/// through a rolling shutter (Galsia's, 0xDDE6); struck, it reels (0xF062), or shrugs the blow
/// off when placed to (0xF078).
pub fn brawler(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try begin(arena, rom, 0x26, "brawler", &.{.{ .name = "punch", .entry = try animEntry(rom, 0xF240) }});
    blows(&d, "punch");
    const power = powerOf(&d);
    try d.moves.append(arena, .{ .name = "punch", .provenance = "the punch (0xF23A): a blow that lands knocks down (reaction 1, 0xF1F0), its damage the type's power", .animation = d.animationIndex("punch").?, .damage = power, .reaction = .knock_down });
    try namedBox(&d, @intCast(try moveq(rom, 0xF218, 1)), @intCast(try moveq(rom, 0xF222, 1)), "punch", "reach");
    try d.number_notes.print(arena, "; the punch's reach: ROM 0x0F218, 0x0F222: moveq #N,d1", .{});
    try d.number("follow_speed", try immediate(rom, 0xF11E, &.{ 0x31, 0x7C }, 2) << 8, "ROM 0x0F11E: move.w #N,(100,a0) (8.8)");
    try d.number("follow_first", try moveByte(rom, 0xF118, 13), "ROM 0x0F118: move.b #N,(13,a0)");
    try d.number("follow_turns", try moveByte(rom, 0xF124, 80), "ROM 0x0F124: move.b #N,(80,a0)");
    try d.number("follow_stops", try moveByte(rom, 0xF12A, 81), "ROM 0x0F12A: move.b #N,(81,a0)");
    try d.number("follow_ticks", try moveByte(rom, 0xF130, 82), "ROM 0x0F130: move.b #N,(82,a0)");
    try d.number("close_in_pace", (try immediate(rom, 0xF1D4, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0F1D4: move.w #N*$101,(12,a0)");
    try d.number("close_in_punches", try moveByte(rom, 0xF1DA, 80), "ROM 0x0F1DA: move.b #N,(80,a0)");
    try d.number("close_in_ticks", try moveByte(rom, 0xF1E0, 81), "ROM 0x0F1E0: move.b #N,(81,a0)");
    try d.number("close_in_beside", try moveq(rom, 0xF22A, 1), "ROM 0x0F22A: moveq #N,d1");
    try d.number("punch_ends", try frameCompared(rom, 0xF246), "ROM 0x0F246: cmpi.b #N,(10,a0)");
    if (try animEntry(rom, 0xF096) != 2) return error.BadData;
    try d.number("shrug_frame", try moveByte(rom, 0xF09C, 10), "ROM 0x0F09C: move.b #N,(10,a0) (of its animation 4: its fall's)");
    try d.number("shrug_ticks", try moveByte(rom, 0xF0A8, 80), "ROM 0x0F0A8: move.b #N,(80,a0)");
    try d.number("shrug_near", try immediate(rom, 0xF0CA, &.{ 0x0C, 0x40 }, 2), "ROM 0x0F0CA: cmpi.w #N,d0");
    const drawn = try immediate(rom, 0xAF6E, &.{ 0x06, 0x42 }, 2);
    try d.number("sides_from", try immediate(rom, 0x97E8, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x097E8: cmpi.w #N,(40,a0), less 0xAF6E's offset (0xF142)");
    try d.number("sides_to", try immediate(rom, 0x97F0, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x097F0: cmpi.w #N,(40,a0), less 0xAF6E's offset (excluded)");
    try d.sound("shrug", @bitCast(@as(i8, @intCast(try moveq(rom, 0xF090, 7)))));
    // A player it knocks down falls with a sound of its own (the player's knock-down, 0x3496,
    // asks for it when its striker is of the brawler's type).
    if (try immediate(rom, 0x349C, &.{ 0x0C, 0x29, 0x00 }, 1) != 0x26) return error.BadData;
    try d.sound("fells", @bitCast(@as(i8, @intCast(try moveq(rom, 0x34A4, 7)))));
    try shutterNumbers(&d);
    return finish(&d, "brawler", 0x26, "brawler", "the brawler (handler 0xF038)");
}

// --- Antonio, round 1's boss, and his boomerang -------------------------------------------------

/// The bosses' animation sets by type from $55 (0x158B4).
const boss_sets = 0x158B4;
/// The bosses' power and health by type from $55 (0x17EDC).
const boss_power = 0x17F26;
const boss_health = 0x17F2A;
/// The bosses' points' index by type from $55 (0x16542).
const boss_points = 0x16564;
/// Where the boomerang shows in Antonio's hand: by his animation word / 2 the offset of its
/// frames' records, 0 when it is hidden (0x173F6); the records, 4 bytes (0x1741C): across from
/// him, in depth, up from his feet, the boomerang's own animation word.
const boomerang_hands = 0x17494;
const boomerang_records = 0x173A0;

/// The entry of the animation word `word` (facing right; the next entry faces left).
fn wordEntry(word: i32) Error!u32 {
    if (word < 0 or @mod(word, 4) != 0) return error.BadData;
    return @intCast(@divExact(word, 2));
}

/// `move.w #N,(8,a0)`: an animation word written.
fn animWord(rom: []const u8, at: u32) Error!i32 {
    if (u16be(rom, at) != 0x317C or u16be(rom, at + 4) != 8) return error.BadData;
    return u16be(rom, at + 2);
}

/// `cmpi.w #N,(D,a0)` or `cmpi.w #N,dK`: the immediate word compared (the instruction checked).
fn comparedWord(rom: []const u8, at: u32) Error!i32 {
    const op = u16be(rom, at);
    if (op & 0xFFF8 != 0x0C40 and op != 0x0C68 and op != 0x0C69) return error.BadData;
    return @as(i16, @bitCast(@as(u16, @intCast(u16be(rom, at + 2)))));
}

/// `move.l #N,(D,a0)`: the long written.
fn movedLong(rom: []const u8, at: u32) Error!i32 {
    return immediate(rom, at, &.{ 0x21, 0x7C }, 4);
}

/// `move.w #N,(D,a0)`: the word written (sign extended).
fn movedWord(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at) != 0x317C or u16be(rom, at + 4) != displacement) return error.BadData;
    return @as(i16, @bitCast(@as(u16, @intCast(u16be(rom, at + 2)))));
}

/// `moveq #N,dK` then `swap dK`: N whole pixels.
fn swappedPixels(rom: []const u8, at: u32, register: u3) Error!i32 {
    const v = try moveq(rom, at, register);
    if (u16be(rom, at + 2) != 0x4840 | @as(u16, register)) return error.BadData;
    return v << 16;
}

/// The byte of a boss's table at `table` for type `kind` (from $55).
fn bossByte(rom: []const u8, table: u32, kind: u8) u8 {
    return rom[table + @as(u32, kind - 0x55)];
}

/// Antonio (type $56, his handler 0x16CE4, his states at 0x16CF4, sor-remaster's
/// obj/boss_antonio.zig): he walks in from the screen's side, backs away from a target that
/// comes near, taunts, strolls in depth, aligns with his target and throws his boomerang, waits
/// for it and catches it; near, he charges and swings his boomerang in hand (state 2, a blow
/// that knocks down). Struck, he is knocked back or down; held, kneed, thrown; the special
/// attack holds him still and costs him health at its end.
/// The numbers of the bosses' common body (boss.zig), for boss type `kind`: its power and
/// health by the level, the blows it takes (knocked back and down, the shake, lying, beaten, its
/// points), held and thrown (its places from its holder by its type), the special attack and a
/// player's new life, its keeping above its target in depth (0x179AC), its sounds taken.
fn bossBody(d: *Def, kind: u8) Error!void {
    const rom = d.rom;
    const arena = d.arena;
    _ = arena;
    const power = bossByte(rom, boss_power, kind);
    try d.number("power", power, "ROM 0x17F27 (by type from $55, 0x17EDC)");
    try d.number("hardest_health", try quick(rom, 0x17EFC, 0x5042), "ROM 0x17EFC: addq.w #N,d2 (the hardest level's)");
    try d.number("outside_power", try quick(rom, 0x17F1A, 0x5001), "ROM 0x17F1A: addq.b #N,d1 (out of the boss's section, 0x17F08)");
    // Out of the boss's section, in the round of 0x17F10's compare (round 8's boss rush), his
    // health is more.
    if (u16be(rom, 0x17F10) != 0x0C78 or u16be(rom, 0x17F14) != 0xFF02) return error.BadData;
    try d.number("outside_health_round", 1 + try immediate(rom, 0x17F10, &.{ 0x0C, 0x78 }, 2), "ROM 0x17F10: cmpi.w #N,($FF02) (the round's number, N + 1)");
    try d.number("outside_health", try quick(rom, 0x17F18, 0x5042), "ROM 0x17F18: addq.w #N,d2");
    try d.number("struck_from", try comparedWord(rom, 0xAABA) - 0x80, "ROM 0x0AABA: cmpi.w #N+$80,(40,a0) (drawn across: the meeting check's, 0xAA22)");
    try d.number("struck_to", try comparedWord(rom, 0xAAC2) - 0x80, "ROM 0x0AAC2: cmpi.w #N+$80,(40,a0)");
    try d.number("grab_height", try comparedWord(rom, 0xAAF6), "ROM 0x0AAF6: cmpi.w #N,d2 (a grab's reach in height, 0xAA22)");
    // Keeping a little above the target in depth (0x179AC).
    try d.number("keep_far", try comparedWord(rom, 0x179B8), "ROM 0x179B8: cmpi.w #N,d1");
    try d.number("keep_near", try comparedWord(rom, 0x179BE), "ROM 0x179BE: cmpi.w #N,d1");
    try d.number("keep_step_2", try comparedWord(rom, 0x179C6), "ROM 0x179C6: cmpi.w #N,d1");
    try d.number("keep_step_1", try comparedWord(rom, 0x179D4), "ROM 0x179D4: cmpi.w #N,d1");
    try d.number("keep_at", try comparedWord(rom, 0x179DA), "ROM 0x179DA: cmpi.w #N,d1");
    try d.number("steer_fast", (try moveq(rom, 0x179B0, 0)) << 16, "ROM 0x179B0: moveq #N,d0 (whole pixels)");
    try d.number("steer", (try moveq(rom, 0x179C4, 0)) << 16, "ROM 0x179C4: moveq #N,d0");
    try d.number("steer_slow", (try moveq(rom, 0x179D2, 0)) << 16, "ROM 0x179D2: moveq #N,d0");
    try d.number("knock_back_ticks", try moveq(rom, 0x17C7C, 0), "ROM 0x17C7C: moveq #N,d0");
    try d.number("knock_down_ticks", try moveq(rom, 0x17C9C, 0), "ROM 0x17C9C: moveq #N,d0");
    try d.number("knocked_x", try movedLong(rom, 0x17C9E), "ROM 0x17C9E: move.l #N,(28,a0)");
    try d.number("knocked_up", try movedLong(rom, 0x17CA6), "ROM 0x17CA6: move.l #N,(36,a0)");
    try d.number("knocked_bounces", try moveByte(rom, 0x17CAE, 0x63), "ROM 0x17CAE: move.b #N,(99,a0)");
    try d.number("knocked_gravity", try immediate(rom, 0x163E8, &.{ 0x06, 0xA8 }, 4), "ROM 0x163E8: addi.l #N,(36,a0)");
    try d.number("bounce_up", try movedLong(rom, 0x16406), "ROM 0x16406: move.l #N,(36,a0)");
    try d.number("shake", try quick(rom, 0x16436, 0x5168), "ROM 0x16436: subq.w #N,(16,a0)");
    try d.number("down_ticks", try moveByte(rom, 0x1648A, 0x62), "ROM 0x1648A: move.b #N,(98,a0)");
    try d.number("dead_ticks", try moveByte(rom, 0x16498, 0x62), "ROM 0x16498: move.b #N,(98,a0)");
    try d.number("points_at", try immediate(rom, 0x1651E, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x1651E: cmpi.b #N,(98,a0)");
    try d.number("points", try points(rom, bossByte(rom, boss_points, kind)), "ROM 0x16565 (the score's index by type from $55, 0x16542), the amount at ROM 0x10DDE");
    try d.number("hold_front", entities.s8(rom, 0x17D76 + @as(u32, kind - 0x55)), "ROM 0x17D77 (by type from $55, 0x17D6C)");
    try d.number("hold_behind", entities.s8(rom, 0x17DB0 + @as(u32, kind - 0x55)), "ROM 0x17DB1 (by type from $55, 0x17D96)");
    try d.number("knee_damage", try moveByte(rom, 0x17D32, 0x6C), "ROM 0x17D32: move.b #N,(108,a0)");
    try d.number("missile_damage", try moveByte(rom, 0x17BF4, 0x6C), "ROM 0x17BF4: move.b #N,(108,a0) (a body thrown at him)");
    if (rom[0xA9F2] & 0xF1 != 0x51 or rom[0xA9F3] != 0x68) return error.BadData;
    try d.number("thrown_damage", @as(i32, rom[0xA9F2] >> 1) & 7, "ROM 0x0A9F2: subq.w #N,(50,a0) (what a thrown body does to the enemies it meets)");
    try d.number("last_knee_damage", try moveByte(rom, 0x17D2A, 0x6C), "ROM 0x17D2A: move.b #N,(108,a0)");
    try d.number("toss_place", entities.s8(rom, 0x17DF4 + @as(u32, kind - 0x55)), "ROM 0x17DF5 (by type from $55, 0x17DC8)");
    try d.number("toss_ticks", try moveByte(rom, 0x17DDC, 0x62), "ROM 0x17DDC: move.b #N,(98,a0)");
    try d.number("vault_place", entities.s8(rom, 0x17E90 + @as(u32, kind - 0x55)), "ROM 0x17E91 (by type from $55, 0x17E64)");
    try d.number("vault_ticks", try moveByte(rom, 0x17E76, 0x62), "ROM 0x17E76: move.b #N,(98,a0)");
    try d.number("fling_place", entities.s8(rom, 0x17ED6 + @as(u32, kind - 0x55)), "ROM 0x17ED7 (by type from $55, 0x17EA8)");
    try d.number("fling_ticks", try moveByte(rom, 0x17EBC, 0x62), "ROM 0x17EBC: move.b #N,(98,a0)");
    try d.number("thrown_bounces", try moveByte(rom, 0x17DE2, 0x63), "ROM 0x17DE2: move.b #N,(99,a0); 0x17E7C, 0x17EC2");
    if (try moveByte(rom, 0x17E7C, 0x63) != try moveByte(rom, 0x17DE2, 0x63) or try moveByte(rom, 0x17EC2, 0x63) != try moveByte(rom, 0x17DE2, 0x63)) return error.BadData;
    try thrownNumbers(d, kind);
    try d.number("special_grounded", try moveByte(rom, 0x16B4E, 0x76), "ROM 0x16B4E: move.b #N,(118,a0)");
    try d.number("special_ticks", try movedWord(rom, 0x16B60, 0x54), "ROM 0x16B60: move.w #N,(84,a0)");
    try d.number("special_ticks_second", try movedWord(rom, 0x16B6C, 0x54), "ROM 0x16B6C: move.w #N,(84,a0) (the second player's)");
    try d.number("special_damage", try immediate(rom, 0x16A66, &.{ 0x04, 0x68 }, 2), "ROM 0x16A66: subi.w #N,(50,a0)");
    // The pepper (a thrown thing of type $0C, 0x17BE0; on his ground, 0x17BAC): state 9
    // (0x16B88) a while, his look 0 and the flinch by turns (bit 1 of his ticks, 0x16BAC).
    if (u32be(rom, 0x17BE0) != 0x0C11000C or u32be(rom, 0x16BAC) != 0x08280001 or u16be(rom, 0x16BB0) != 98 or try moveq(rom, 0x16BAA, 0) != 0) return error.BadData;
    try d.number("pepper_ticks", try moveByte(rom, 0x17BC2, 98), "ROM 0x17BC2: move.b #N,(98,a0) (peppered: state 9, 0x16B88)");
    try d.number("blast_x", try movedLong(rom, 0x16A84), "ROM 0x16A84: move.l #N,(28,a0)");
    try d.number("blast_up", try movedLong(rom, 0x16A8C), "ROM 0x16A8C: move.l #N,(36,a0); 0x16A7A");
    if (try movedLong(rom, 0x16A7A) != try movedLong(rom, 0x16A8C)) return error.BadData;
    try d.number("dying_x", try movedLong(rom, 0x16A72), "ROM 0x16A72: move.l #N,(28,a0)");
    try d.number("blast_ticks", try moveByte(rom, 0x16AA4, 0x62), "ROM 0x16AA4: move.b #N,(98,a0)");
    try d.number("blast_bounces", try moveByte(rom, 0x16A9E, 0x63), "ROM 0x16A9E: move.b #N,(99,a0)");
    try d.sound("hurt", @bitCast(@as(i8, @intCast(try moveq(rom, 0x17C4A, 7)))));
    // The beaten cry (0x166D4), but the type of 0x166D6's compare's own (0x166DC).
    if (u16be(rom, 0x166D6) != 0x0C10 or rom[0x166D8] != 0 or u16be(rom, 0x166DA) != 0x6602) return error.BadData;
    const own_cry = kind == rom[0x166D9];
    try d.sound("cry", @bitCast(@as(i8, @intCast(try moveq(rom, if (own_cry) 0x166DC else 0x166D4, 7)))));
    try d.sound("thud", @bitCast(@as(i8, @intCast(try moveq(rom, 0x16412, 7)))));
    if (try moveq(rom, 0x17C08, 7) != try moveq(rom, 0x17C4A, 7) or try moveq(rom, 0x166B6, 7) != try moveq(rom, 0x16412, 7)) return error.BadData;
    try d.number("depth_most", (try immediate(rom, 0x17ACE, &.{ 0x0C, 0x80 }, 4)) >> 16, "ROM 0x17ACE: cmpi.l #N,d0 (whole pixels: the depth a boss moves to at most, 0x17AB8)");
}

pub fn antonio(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const kind: u8 = 0x56;
    const set = u32be(rom, boss_sets + 4 * @as(u32, kind - 0x55));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "antonio", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    const anims = [_]struct { name: []const u8, word: i32 }{
        .{ .name = "stand", .word = try moveq(rom, 0x15888, 0) },
        .{ .name = "swing", .word = try moveq(rom, 0x16F26, 0) },
        .{ .name = "knocked", .word = try animWord(rom, 0x17CC2) },
        .{ .name = "held", .word = try animWord(rom, 0x17D66) },
        .{ .name = "held_behind", .word = try animWord(rom, 0x17D90) },
        .{ .name = "flight", .word = try animWord(rom, 0x17CC2) + try immediate(rom, 0x163F8, &.{ 0x06, 0x68 }, 2) },
        .{ .name = "bounce", .word = try animWord(rom, 0x17CC2) + try immediate(rom, 0x163F8, &.{ 0x06, 0x68 }, 2) + try quick(rom, 0x1640E, 0x5068) },
        .{ .name = "down", .word = try immediate(rom, 0x16490, &.{ 0x30, 0x3C }, 2) },
        .{ .name = "lifted", .word = try animWord(rom, 0x1662A) },
        .{ .name = "flinch", .word = try moveq(rom, 0x16BB4, 0) },
        .{ .name = "idle", .word = try moveq(rom, 0x17058, 0) },
        .{ .name = "walk", .word = try moveq(rom, 0x1703A, 0) },
        .{ .name = "taunt", .word = try moveq(rom, 0x16FEE, 0) },
        .{ .name = "throw", .word = try moveq(rom, 0x1711A, 0) },
        .{ .name = "wait", .word = try moveq(rom, 0x1712C, 0) },
    };
    for (anims) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, try wordEntry(an.word)) });
    // The swing's frames with an attack box are blows; a blow that lands knocks down (the
    // player's reaction 1, 0x171E4), its damage his power.
    blows(&d, "swing");
    // The boomerang in his hand, frame by frame.
    for (anims) |an| try boomerangHands(&d, an.name, an.word);

    const power = bossByte(rom, boss_power, kind);
    try bossBody(&d, kind);
    try d.moves.append(arena, .{ .name = "swing", .provenance = "the swing (state 2, 0x171CC): a blow that lands knocks the player down (0x171E4: its reaction 1), its damage his power (0x17EDC)", .animation = d.animationIndex("swing").?, .damage = power, .reaction = .knock_down });
    // The screen, from where he was drawn: off it he walks in (0x16DEC).
    try d.number("on_screen_from", try comparedWord(rom, 0x16DF0) - 0x80, "ROM 0x16DF0: cmpi.w #N+$80,d1 (drawn across)");
    try d.number("on_screen_to", try comparedWord(rom, 0x16DF6) - 0x80, "ROM 0x16DF6: cmpi.w #N+$80,d1");
    try d.number("screen_middle", try comparedWord(rom, 0x16E04) - 0x80, "ROM 0x16E04: cmpi.w #N+$80,d1");
    try d.number("walk_in_speed", try movedLong(rom, 0x16DFC), "ROM 0x16DFC: move.l #N,(28,a0); in depth 0x16E0E");
    if (try movedLong(rom, 0x16E0E) != try movedLong(rom, 0x16DFC)) return error.BadData;
    try d.number("walk_in_low", try comparedWord(rom, 0x16E16), "ROM 0x16E16: cmpi.w #N,(20,a1)");
    try d.number("walk_in_ticks", try moveByte(rom, 0x16E22, 0x5C), "ROM 0x16E22: move.b #N,(92,a0)");
    try d.number("walk_in_ticks_second", try moveByte(rom, 0x16E30, 0x5C), "ROM 0x16E30: move.b #N,(92,a0) (the second of twins)");
    try d.number("near", try comparedWord(rom, 0x16E60), "ROM 0x16E60: cmpi.w #N,d2");
    try d.number("charge_from", try comparedWord(rom, 0x16E7A), "ROM 0x16E7A: cmpi.w #N,d2");
    if (try comparedWord(rom, 0x16E74) != try comparedWord(rom, 0x16E60)) return error.BadData;
    try d.number("charge_level", try comparedWord(rom, 0x16E80), "ROM 0x16E80: cmpi.w #N,(82,a0)");
    try d.number("charge_speed", try movedLong(rom, 0x16E8E), "ROM 0x16E8E: move.l #N,(28,a0)");
    try d.number("charge_stop_far", try comparedWord(rom, 0x16F6E), "ROM 0x16F6E: cmpi.w #N,(80,a0)");
    try d.number("charge_stop_near", try comparedWord(rom, 0x16F76), "ROM 0x16F76: cmpi.w #N,(80,a0)");
    try d.number("charge_stop_level", try comparedWord(rom, 0x16F7E), "ROM 0x16F7E: cmpi.w #N,(82,a0)");
    try d.number("swing_reach_coming", try comparedWord(rom, 0x16EF0), "ROM 0x16EF0: cmpi.w #N,d2 (a target coming at him)");
    try d.number("swing_reach_going", try comparedWord(rom, 0x16EC0), "ROM 0x16EC0: cmpi.w #N,d2 (going away)");
    try d.number("swing_reach_still", try comparedWord(rom, 0x16EE8), "ROM 0x16EE8: cmpi.w #N,d2 (still, on his right)");
    try d.number("swing_reach_still_left", try comparedWord(rom, 0x16EE0), "ROM 0x16EE0: cmpi.w #N,d2 (still, on his left)");
    try d.number("swing_level_above", try comparedWord(rom, 0x16F00), "ROM 0x16F00: cmpi.w #N,d0");
    try d.number("swing_level", try comparedWord(rom, 0x16F08), "ROM 0x16F08: cmpi.w #N,d0");
    try d.number("swing_frame", try moveByte(rom, 0x16F32, 10), "ROM 0x16F32: move.b #N,(10,a0)");
    try d.number("swing_from_start", try immediate(rom, 0x16F2C, &.{ 0x0C, 0x07, 0x00 }, 1), "ROM 0x16F2C: cmpi.b #N,d7 (the walk's frame from which the swing starts at its first)");
    try d.number("swing_ends", try frameCompared(rom, 0x171EA), "ROM 0x171EA: cmpi.b #N,(10,a0)");
    try d.number("back_away_ticks", try moveByte(rom, 0x16FA4, 0x78), "ROM 0x16FA4: move.b #N,(120,a0)");
    try d.number("back_away_speed", try movedLong(rom, 0x16FCC), "ROM 0x16FCC: move.l #N,(28,a0); the other way 0x16FC2");
    if (try movedLong(rom, 0x16FC2) != -(try movedLong(rom, 0x16FCC))) return error.BadData;
    try d.number("taunt_from", try comparedWord(rom, 0x16FE4), "ROM 0x16FE4: cmpi.w #N,(80,a0)");
    try d.number("stroll_ticks", try moveByte(rom, 0x16FF0, 0x78), "ROM 0x16FF0: move.b #N,(120,a0)");
    try d.number("stroll_toward_from", try comparedWord(rom, 0x17020), "ROM 0x17020: cmpi.w #N,(80,a0)");
    try d.number("stroll_speed", try swappedPixels(rom, 0x1701C, 1), "ROM 0x1701C: moveq #N,d1; swap d1");
    try d.number("stand_near", try comparedWord(rom, 0x17050), "ROM 0x17050: cmpi.w #N,(80,a0)");
    try d.number("stand_far_level", try comparedWord(rom, 0x1706E), "ROM 0x1706E: cmpi.w #N,(82,a0)");
    if (u16be(rom, 0x17076) != 0x323C) return error.BadData;
    try d.number("stand_far_speed", (try swappedPixels(rom, 0x1706A, 1)) | u16be(rom, 0x17078), "ROM 0x1706A: moveq #N,d1; swap d1; 0x17076: move.w #F,d1");
    try d.number("align_speed", try swappedPixels(rom, 0x170CC, 1), "ROM 0x170CC: moveq #N,d1; swap d1");
    try d.number("align_level", try comparedWord(rom, 0x170FA), "ROM 0x170FA: cmpi.w #N,(82,a0)");
    try d.number("throw_ticks", try moveByte(rom, 0x17110, 0x78), "ROM 0x17110: move.b #N,(120,a0)");
    try d.number("charge_back_from", try comparedWord(rom, 0x17154), "ROM 0x17154: cmpi.w #N,(80,a0)");
    try d.number("charge_back_level", try comparedWord(rom, 0x1715C), "ROM 0x1715C: cmpi.w #N,(82,a0)");
    try d.number("catch_hand", try immediate(rom, 0x171AC, &.{ 0x06, 0x41 }, 2), "ROM 0x171AC: addi.w #N,d1");
    try d.number("catch_within", try comparedWord(rom, 0x171BE), "ROM 0x171BE: cmpi.w #N,d1");
    try d.number("catch_steer", try immediate(rom, 0x17188, &.{ 0x21, 0x7C }, 4), "ROM 0x17188: move.l #N,(32,a0); the other way 0x17192");
    if (try immediate(rom, 0x17192, &.{ 0x21, 0x7C }, 4) != -(try immediate(rom, 0x17188, &.{ 0x21, 0x7C }, 4))) return error.BadData;
    try d.number("sway_speed", try swappedPixels(rom, 0x17A6E, 1), "ROM 0x17A6E: moveq #N,d1; swap d1");
    try d.number("zigzag_turn", try comparedWord(rom, 0x17A7A), "ROM 0x17A7A: cmpi.w #N,d7");
    try d.number("zigzag_back", try comparedWord(rom, 0x17A80), "ROM 0x17A80: cmpi.w #N,d7");
    // Keeping a little above his target in depth (0x179AC) and going to its depth (0x1797E).
    try d.number("level_far", try comparedWord(rom, 0x17984), "ROM 0x17984: cmpi.w #N,d1");
    try d.number("level_mid", try comparedWord(rom, 0x1798C), "ROM 0x1798C: cmpi.w #N,d1");
    try d.number("level_near", try comparedWord(rom, 0x17994), "ROM 0x17994: cmpi.w #N,d1");
    for ([_][2]u32{ .{ 0x17982, 0x179B0 }, .{ 0x1798A, 0x179C4 }, .{ 0x17992, 0x179D2 } }) |p| {
        if (try moveq(rom, p[0], 0) != try moveq(rom, p[1], 0)) return error.BadData;
    }
    // The screen's edges, far out (0x17088).
    try d.number("edge_from", (try immediate(rom, 0x1708C, &.{ 0x32, 0x3C }, 2)) - 0x80, "ROM 0x1708C: move.w #N+$80,d1");
    try d.number("edge_to", (try immediate(rom, 0x17094, &.{ 0x32, 0x3C }, 2)) - 0x80, "ROM 0x17094: move.w #N+$80,d1");
    try d.number("push_from", try comparedWord(rom, 0x170A2) - 0x80, "ROM 0x170A2: cmpi.w #N+$80,d0");
    try d.number("push_to", try comparedWord(rom, 0x170A8) - 0x80, "ROM 0x170A8: cmpi.w #N+$80,d0");
    // Blows taken (0x17C36), and the knock back and down (state 3, 0x163D0).
    // Held (0x17CF2): his place in front of his holder or before him, the knees' damage.
    // Thrown by a player (states 6, 7, 8): their places, ticks and bounces.
    // The special attack (0x16AEC, state 10 0x16A60) and a player's new life (0x16A1A).
    try d.sound("swing", @bitCast(@as(i8, @intCast(try moveq(rom, 0x16F1A, 7)))));
    return .{
        .name = "antonio",
        .provenance = try std.fmt.allocPrint(arena, "boss type $56, Antonio (handler 0x16CE4): the animation set at ROM 0x{X:0>5} (0x158B4), the boxes (0x1A68E, 0x1AB8E); health ROM 0x17F2B (0x17EDC); his palette line his art's (move.w #N,d1 at ROM 0x16D36){s}", .{ set, d.number_notes.items }),
        .family = .boss,
        .team = .enemy,
        .behaviour = "antonio",
        .palette = try lineOfArt(rom, 0x16D36),
        .health = bossByte(rom, boss_health, kind),
        .shadow = true,
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
        .moves = d.moves.items,
    };
}

/// The numbers of the throws he takes (states 6, 7 and 8: 0x1659A, 0x16702, 0x168CC): the
/// ticks left at which each step comes, the speeds, the damage of the landings.
fn thrownNumbers(d: *Def, kind: u8) Error!void {
    const rom = d.rom;
    // Tossed over the shoulder (state 6).
    try d.number("toss_lift_at", try immediate(rom, 0x16620, &.{ 0x0C, 0x07, 0x00 }, 1), "ROM 0x16620: cmpi.b #N,d7");
    try d.number("toss_up", (try movedWord(rom, 0x16630, 0x24)) << 16, "ROM 0x16630: move.w #N,(36,a0)");
    try d.number("toss_lift", try immediate(rom, 0x16636, &.{ 0x04, 0x68 }, 2), "ROM 0x16636: subi.w #N,(24,a0)");
    try d.number("toss_x", (try immediate(rom, 0x1663C, &.{ 0x30, 0x3C }, 2)) << 16, "ROM 0x1663C: move.w #N,d0");
    try d.number("toss_ahead", try immediate(rom, 0x16640, &.{ 0x32, 0x3C }, 2), "ROM 0x16640: move.w #N,d1");
    try d.number("thrown_gravity", (try quick(rom, 0x1666A, 0x5068)) << 16, "ROM 0x1666A: addq.w #N,(36,a0)");
    try d.number("toss_bounce", (try movedWord(rom, 0x1667E, 0x24)) << 16, "ROM 0x1667E: move.w #N,(36,a0)");
    try d.number("toss_bounce_2", (try movedWord(rom, 0x16698, 0x24)) << 16, "ROM 0x16698: move.w #N,(36,a0)");
    try d.number("toss_damage", try quick(rom, 0x166A4, 0x5168), "ROM 0x166A4: subq.w #N,(50,a0)");
    // Vaulted over (state 7): his places as he is carried over, by steps of 8 from the table
    // 0x168A4 (two bytes by type from $55).
    try d.number("vault_turn_at", try immediate(rom, 0x16712, &.{ 0x0C, 0x07, 0x00 }, 1), "ROM 0x16712: cmpi.b #N,d7");
    try d.number("vault_over_at", try immediate(rom, 0x16748, &.{ 0x0C, 0x07, 0x00 }, 1), "ROM 0x16748: cmpi.b #N,d7");
    try d.number("vault_down_at", try immediate(rom, 0x1674E, &.{ 0x0C, 0x07, 0x00 }, 1), "ROM 0x1674E: cmpi.b #N,d7");
    try d.number("vault_damage", try quick(rom, 0x16756, 0x5168), "ROM 0x16756: subq.w #N,(50,a0)");
    try d.number("vault_fly_at", try immediate(rom, 0x167F8, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x167F8: cmpi.b #N,(98,a0)");
    try d.number("vault_fly", try movedLong(rom, 0x16818), "ROM 0x16818: move.l #N,(28,a0); in height 0x16820");
    if (try movedLong(rom, 0x16820) != try movedLong(rom, 0x16818)) return error.BadData;
    try d.number("vault_slide", try movedLong(rom, 0x16874), "ROM 0x16874: move.l #N,(28,a0); in height 0x1687C");
    if (try movedLong(rom, 0x1687C) != try movedLong(rom, 0x16874)) return error.BadData;
    var places: [10]i32 = undefined;
    for (0..5) |k| {
        const at: u32 = 0x168A4 + 8 * @as(u32, @intCast(k)) + 2 * @as(u32, kind - 0x55);
        places[2 * k] = entities.s8(rom, at);
        places[2 * k + 1] = entities.s8(rom, at + 1);
    }
    try d.table("carried", &places, "ROM 0x168A4 (by step of 8, two bytes by type from $55: back from the thrower, then down)");
    // Flung (state 8).
    try d.number("fling_lift_at", try immediate(rom, 0x1694A, &.{ 0x0C, 0x07, 0x00 }, 1), "ROM 0x1694A: cmpi.b #N,d7");
    try d.number("fling_at", try immediate(rom, 0x16952, &.{ 0x0C, 0x07, 0x00 }, 1), "ROM 0x16952: cmpi.b #N,d7");
    try d.number("fling_up", (try movedWord(rom, 0x169CC, 0x24)) << 16, "ROM 0x169CC: move.w #N,(36,a0)");
    try d.number("fling_x", (try moveq(rom, 0x169D2, 3)) << 16, "ROM 0x169D2: moveq #N,d3");
    try d.number("fling_turn_at", try immediate(rom, 0x1695C, &.{ 0x0C, 0x07, 0x00 }, 1), "ROM 0x1695C: cmpi.b #N,d7");
    try d.number("fling_bounce", (try movedWord(rom, 0x16988, 0x24)) << 16, "ROM 0x16988: move.w #N,(36,a0)");
    try d.number("fling_bounce_2", (try movedWord(rom, 0x169A2, 0x24)) << 16, "ROM 0x169A2: move.w #N,(36,a0)");
    try d.number("fling_damage", try quick(rom, 0x169AE, 0x5168), "ROM 0x169AE: subq.w #N,(50,a0)");
}

/// The frames of his animation `name` (its word `word`, facing right) show the boomerang in his
/// hand where the records say, in its pose by the record's animation word; the frames facing
/// left have the mirror records (but the throw's sixth, never reached in hand: the original's
/// table names the right-facing record there).
fn boomerangHands(d: *Def, name: []const u8, word: i32) Error!void {
    const rom = d.rom;
    const right = rom[boomerang_hands + @as(u32, @intCast(word)) / 2];
    const left = rom[boomerang_hands + @as(u32, @intCast(word)) / 2 + 1];
    const frames: []entity.Frame = @constCast(d.animations.items[d.animationIndex(name).?].frames);
    if ((right == 0) != (left == 0)) return error.BadData;
    if (right == 0) return;
    var launched = false;
    for (frames, 0..) |*f, k| {
        const r = boomerang_records + 4 * @as(u32, rom[boomerang_hands + @as(u32, right) + k]);
        const l = boomerang_records + 4 * @as(u32, rom[boomerang_hands + @as(u32, left) + k]);
        if (rom[r + 1] != 0) return error.BadData;
        const pose: []const u8 = switch (rom[r + 3]) {
            0x38 => "held",
            0x3C => "held_high",
            0x40 => "spin",
            else => return error.BadData,
        };
        if (!launched and (entities.s8(rom, l) != -entities.s8(rom, r) or rom[l + 2] != rom[r + 2] or rom[l + 3] != rom[r + 3] + 2)) return error.BadData;
        if (rom[r + 3] == 0x40) launched = true;
        f.hand = .{ .x = entities.s8(rom, r), .height = -@as(i16, rom[r + 2]), .pose = pose };
    }
}

// --- Round 2's boss, his claws and his trail -------------------------------------------------------

/// Round 2's boss (type $55, his handler 0x15E70, his states at 0x15E84; sor-remaster's
/// obj/boss_55.zig): he walks in from the screen's side, keeps his distance from his target,
/// closes in on one whose back is turned, slashes with his claws near and level (state 2, a blow
/// that knocks down), and dodges a flying kick in depth, then dashes across, both out of the
/// blows' reach. The rest is the bosses' common body (`bossBody`).
pub fn bossR2(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const kind: u8 = 0x55;
    const set = u32be(rom, boss_sets + 4 * @as(u32, kind - 0x55));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "round2_boss", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    // His slash is his walk's word plus 4 (0x15F64: addq.w #4,(8,a0)), its start 0x1628E.
    if (u16be(rom, 0x15F64) != 0x5868 or u16be(rom, 0x15F66) != 8) return error.BadData;
    const anims = [_]struct { name: []const u8, word: i32 }{
        .{ .name = "stand", .word = try moveq(rom, 0x15888, 0) },
        .{ .name = "swing", .word = try moveq(rom, 0x1628E, 0) },
        .{ .name = "knocked", .word = try animWord(rom, 0x17CC2) },
        .{ .name = "held", .word = try animWord(rom, 0x17D66) },
        .{ .name = "held_behind", .word = try animWord(rom, 0x17D90) },
        .{ .name = "flight", .word = try animWord(rom, 0x17CC2) + try immediate(rom, 0x163F8, &.{ 0x06, 0x68 }, 2) },
        .{ .name = "bounce", .word = try animWord(rom, 0x17CC2) + try immediate(rom, 0x163F8, &.{ 0x06, 0x68 }, 2) + try quick(rom, 0x1640E, 0x5068) },
        .{ .name = "down", .word = try immediate(rom, 0x16490, &.{ 0x30, 0x3C }, 2) },
        .{ .name = "lifted", .word = try animWord(rom, 0x1662A) },
        .{ .name = "flinch", .word = try moveq(rom, 0x16BB4, 0) },
    };
    for (anims) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, try wordEntry(an.word)) });
    // The slash's frames with an attack box are blows (from its first: the claws only show
    // some); a blow that lands knocks down (0x16140: the player's $7D), its damage his power.
    blows(&d, "swing");
    const power = bossByte(rom, boss_power, kind);
    try d.moves.append(arena, .{ .name = "swing", .provenance = "the slash (state 2, 0x16118): a blow that lands knocks the player down (0x16140: move.b #1,(125,a1)), its damage his power (0x17EDC)", .animation = d.animationIndex("swing").?, .damage = power, .reaction = .knock_down });
    try bossBody(&d, kind);
    // Off the screen (from where he was drawn) he walks in (0x15FBC).
    try d.number("on_screen_from", try comparedWord(rom, 0x15FC0) - 0x80, "ROM 0x15FC0: cmpi.w #N+$80,d1 (drawn across)");
    try d.number("on_screen_to", try comparedWord(rom, 0x15FC6) - 0x80, "ROM 0x15FC6: cmpi.w #N+$80,d1");
    try d.number("screen_middle", try comparedWord(rom, 0x15FD4) - 0x80, "ROM 0x15FD4: cmpi.w #N+$80,d1");
    try d.number("walk_in_speed", try movedLong(rom, 0x15FCC), "ROM 0x15FCC: move.l #N,(28,a0); in depth 0x15FDE: moveq #4,d1; swap d1");
    if (try swappedPixels(rom, 0x15FDE, 1) != try movedLong(rom, 0x15FCC)) return error.BadData;
    if (try immediate(rom, 0x15FEA, &.{ 0x06, 0x41 }, 2) & 0xFFFF != 0x8000) return error.BadData;
    try d.number("second_more", 0x8000, "ROM 0x15FEA: addi.w #N,d1 (the second of twins' speeds, the low word without its carry: 0x1602E, 0x160C4, 0x160F4)");
    try d.number("walk_in_low", try comparedWord(rom, 0x15FEE), "ROM 0x15FEE: cmpi.w #N,(20,a1) (his target's depth from which he walks in upward)");
    try d.number("walk_in_ticks", try moveByte(rom, 0x15FFC, 0x5C), "ROM 0x15FFC: move.b #N,(92,a0)");
    try d.number("walk_in_ticks_second", try moveByte(rom, 0x1600A, 0x5C), "ROM 0x1600A: move.b #N,(92,a0) (the second of twins)");
    // His count and his close-in timer (0x15EF8, 0x15EFC).
    try d.number("count_most", try immediate(rom, 0x15F7E, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x15F7E: cmpi.b #N,(120,a0) (his count wraps)");
    try d.number("close_after", try immediate(rom, 0x15F98, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x15F98: cmpi.b #N,(123,a0) (his timer to close in)");
    try d.number("close_level", try comparedWord(rom, 0x15FAC), "ROM 0x15FAC: cmpi.w #N,(20,a1) (his target this far down: he closes in)");
    try d.number("close_stop_level", try comparedWord(rom, 0x160D4), "ROM 0x160D4: cmpi.w #N,(20,a1) (his target above this: he stops closing in)");
    try d.number("near_least", try comparedWord(rom, 0x1601A), "ROM 0x1601A: cmpi.w #N,(80,a0); 0x160DC");
    if (try comparedWord(rom, 0x160DC) != try comparedWord(rom, 0x1601A)) return error.BadData;
    try d.number("advance_speed", try swappedPixels(rom, 0x16022, 0), "ROM 0x16022: moveq #N,d0; swap d0 (on a back turned; closing in 0x160E8)");
    if (try swappedPixels(rom, 0x160E8, 0) != try swappedPixels(rom, 0x16022, 0)) return error.BadData;
    try d.number("advance_stop", try comparedWord(rom, 0x1604C), "ROM 0x1604C: cmpi.w #N,(80,a0)");
    try d.number("advance_stop_level", try comparedWord(rom, 0x16054), "ROM 0x16054: cmpi.w #N,(82,a0)");
    try d.number("keep_from", try moveq(rom, 0x1606A, 3), "ROM 0x1606A: moveq #N,d3 (the band he keeps his distance in)");
    try d.number("keep_to", try immediate(rom, 0x1606C, &.{ 0x38, 0x3C }, 2), "ROM 0x1606C: move.w #N,d4");
    try d.number("keep_from_second", try immediate(rom, 0x16078, &.{ 0x36, 0x3C }, 2), "ROM 0x16078: move.w #N,d3 (the second of twins')");
    try d.number("keep_to_second", try immediate(rom, 0x1607C, &.{ 0x38, 0x3C }, 2), "ROM 0x1607C: move.w #N,d4");
    try d.number("keep_speed", try swappedPixels(rom, 0x16084, 0), "ROM 0x16084: moveq #N,d0; swap d0");
    try d.number("keep_depth_speed", try immediate(rom, 0x160B2, &.{ 0x20, 0x3C }, 4), "ROM 0x160B2: move.l #N,d0 (a target walking across, not in depth)");
    // The slash (0x15F08).
    try d.number("slash_reach_going", try comparedWord(rom, 0x15F1E), "ROM 0x15F1E: cmpi.w #N,d2 (a target going away)");
    try d.number("slash_reach_still", try comparedWord(rom, 0x15F26), "ROM 0x15F26: cmpi.w #N,d2");
    try d.number("slash_reach_coming", try comparedWord(rom, 0x15F2E), "ROM 0x15F2E: cmpi.w #N,d2 (a target coming at him)");
    try d.number("slash_least", try comparedWord(rom, 0x15F34), "ROM 0x15F34: cmpi.w #N,d2");
    try d.number("slash_level_above", try comparedWord(rom, 0x15F44), "ROM 0x15F44: cmpi.w #N,d0");
    try d.number("slash_level", try comparedWord(rom, 0x15F4C), "ROM 0x15F4C: cmpi.w #N,d0");
    try d.number("slash_ends", try frameCompared(rom, 0x1617C), "ROM 0x1617C: cmpi.b #N,(10,a0)");
    try d.number("slash_step", try quick(rom, 0x16196, 0x5068), "ROM 0x16196: addq.w #N,(16,a0) (at its end, the way he faces; 0x1618E)");
    if (try quick(rom, 0x1618E, 0x5168) != try quick(rom, 0x16196, 0x5068)) return error.BadData;
    // The dodge of a flying kick (0x16234), in depth then across (0x1619E, 0x161C6).
    try d.number("dodge_level", try comparedWord(rom, 0x1623C), "ROM 0x1623C: cmpi.w #N,(82,a0)");
    try d.number("dodge_near", try comparedWord(rom, 0x16244), "ROM 0x16244: cmpi.w #N,(80,a0)");
    try d.number("dodge_speed", try swappedPixels(rom, 0x1624C, 0), "ROM 0x1624C: moveq #N,d0; swap d0");
    try d.number("dodge_far", try comparedWord(rom, 0x161B2), "ROM 0x161B2: cmpi.w #N,(82,a0) (this far in depth he dashes)");
    try d.number("dash_stop_far", try comparedWord(rom, 0x161CC), "ROM 0x161CC: cmpi.w #N,(80,a0)");
    try d.number("dash_stop_near", try comparedWord(rom, 0x161D4), "ROM 0x161D4: cmpi.w #N,(80,a0)");
    try d.number("dash_level_above", try comparedWord(rom, 0x161E2), "ROM 0x161E2: cmpi.w #N,(82,a0)");
    try d.number("dash_level", try comparedWord(rom, 0x161EC), "ROM 0x161EC: cmpi.w #N,(82,a0)");
    try d.number("dash_speed", try swappedPixels(rom, 0x161F4, 0), "ROM 0x161F4: moveq #N,d0; swap d0");
    try d.number("dash_beside", try immediate(rom, 0x161F8, &.{ 0x32, 0x3C }, 2), "ROM 0x161F8: move.w #N,d1 (across from his target)");
    // His target (0x16294): two players, one near and one far.
    try d.number("target_near", try comparedWord(rom, 0x1633E), "ROM 0x1633E: cmpi.w #N,d1");
    try d.number("target_far", try comparedWord(rom, 0x16344), "ROM 0x16344: cmpi.w #N,d2; 0x16358");
    if (try comparedWord(rom, 0x16358) != try comparedWord(rom, 0x16344)) return error.BadData;
    try d.number("target_level", try comparedWord(rom, 0x1634A), "ROM 0x1634A: cmpi.w #N,d3; 0x1635E");
    if (try comparedWord(rom, 0x1635E) != try comparedWord(rom, 0x1634A)) return error.BadData;
    try d.number("target_close", try moveByte(rom, 0x16350, 0x7B), "ROM 0x16350: move.b #N,(123,a0) (he closes in at once); 0x16364");
    if (try moveByte(rom, 0x16364, 0x7B) != try moveByte(rom, 0x16350, 0x7B)) return error.BadData;
    // A flying kick: the players' states $16, $17, $42, $43 (0x162A4), sorz's jump kicks.
    for ([_][2]u32{ .{ 0x162A4, 0x16 }, .{ 0x162AA, 0x17 }, .{ 0x162B0, 0x42 }, .{ 0x162B6, 0x43 } }) |c| {
        if (u16be(rom, c[0]) != 0x0C00 or u16be(rom, c[0] + 2) != c[1]) return error.BadData;
    }
    return .{
        .name = "boss_r2",
        .provenance = try std.fmt.allocPrint(arena, "boss type $55, round 2's (handler 0x15E70): the animation set at ROM 0x{X:0>5} (0x158B4), the boxes (0x1A68E, 0x1AB8E); health ROM 0x17F2A (0x17EDC); his palette line his art's (move.w #N,d1 at ROM 0x15ED0){s}", .{ set, d.number_notes.items }),
        .family = .boss,
        .team = .enemy,
        .behaviour = "boss_r2",
        .palette = try lineOfArt(rom, 0x15ED0),
        .health = bossByte(rom, boss_health, kind),
        .shadow = true,
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
        .moves = d.moves.items,
    };
}

/// Round 2's boss's claws (type $98, handler 0x16C60): a look that follows him through his slash
/// (state 2), shown at its frames that strike (3 and 4 of the first strike, $C and $D of the
/// second), a swish at each; no blow of its own (his slash's frames strike).
pub fn bossR2Claws(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set = u32be(rom, boss_sets);
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "round2_boss", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    const first = try moveq(rom, 0x16C84, 0);
    if (try moveq(rom, 0x16C4C, 0) != first) return error.BadData;
    for ([_]struct { name: []const u8, word: i32 }{
        .{ .name = "claws", .word = first },
        .{ .name = "claws_2", .word = try moveq(rom, 0x16C94, 0) },
    }) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, try wordEntry(an.word)) });
    try d.number("first_from", try immediate(rom, 0x16C78, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x16C78: cmpi.b #N,d1 (his frame)");
    try d.number("first_to", try immediate(rom, 0x16C7E, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x16C7E: cmpi.b #N,d1 (excluded)");
    try d.number("second_from", try immediate(rom, 0x16C88, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x16C88: cmpi.b #N,d1");
    try d.number("second_to", try immediate(rom, 0x16C8E, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x16C8E: cmpi.b #N,d1 (excluded)");
    try d.number("below", try quick(rom, 0x16CB6, 0x5040), "ROM 0x16CB6: addq.w #N,d0 (in depth from him)");
    try d.number("swish_tick", try immediate(rom, 0x16CD4, &.{ 0x0C, 0x29, 0x00 }, 1), "ROM 0x16CD4: cmpi.b #N,(13,a1) (the tick of his frame it swishes at)");
    try d.sound("swish", @bitCast(@as(i8, @intCast(try moveq(rom, 0x16CDC, 7)))));
    return .{
        .name = "boss_r2_claws",
        .provenance = try std.fmt.allocPrint(arena, "round 2's boss's claws (type $98, handler 0x16C60, made at 0x16C2E): his animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .projectile,
        .team = .enemy,
        .behaviour = "boss_r2_claws",
        .palette = try lineOfArtGiven(rom, 0x16C46),
        // Every object of the original's play below its shadows' places has a shadow (0xB132).
        .shadow = true,
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// Round 2's boss's trail (type $99, handler 0x16C24, made at 0x16BC6): his look as he dodges and
/// dashes, his animation and frame where he is, for a few ticks (fewer for twins, or with two
/// players).
pub fn bossR2Trail(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set = u32be(rom, boss_sets);
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "round2_boss", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    for ([_]struct { name: []const u8, word: i32 }{
        .{ .name = "stand", .word = try moveq(rom, 0x15888, 0) },
        .{ .name = "swing", .word = try moveq(rom, 0x1628E, 0) },
    }) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, try wordEntry(an.word)) });
    try d.number("ticks_twins", try moveq(rom, 0x16C0A, 1), "ROM 0x16C0A: moveq #N,d1 (a twin's trail)");
    try d.number("ticks_two", try moveq(rom, 0x16C12, 1), "ROM 0x16C12: moveq #N,d1 (two players in play)");
    try d.number("ticks", try moveq(rom, 0x16C1C, 1), "ROM 0x16C1C: moveq #N,d1");
    return .{
        .name = "boss_r2_trail",
        .provenance = try std.fmt.allocPrint(arena, "round 2's boss's trail (type $99): his animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .effect,
        .team = .neutral,
        .behaviour = "boss_r2_trail",
        .palette = try lineOfArtGiven(rom, 0x16BDE),
        .shadow = true,
        .numbers = d.numbers.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// His boomerang (type $96, its handler 0x17262): in his hand (0x173D8) it shows where his frame
/// says, hidden in his frames without it; at the frame of his throw that holds it out ahead it
/// flies off (0x172B2), slowing to a stop, then back (0x17320) faster and faster until he
/// catches it or it leaves the screen; struck in flight it drops away (0x1727A). It knocks down
/// a player it meets.
pub fn boomerang(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set = u32be(rom, boss_sets + 4 * (0x56 - 0x55));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "antonio", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    const held = try moveq(rom, 0x17230, 0);
    const high: i32 = rom[boomerang_records + 4 * 10 + 3];
    const spin = try comparedWord(rom, 0x17450);
    for ([_]struct { name: []const u8, word: i32 }{
        .{ .name = "held", .word = held },
        .{ .name = "held_high", .word = high },
        .{ .name = "spin", .word = spin },
    }) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, try wordEntry(an.word)) });
    try d.number("flight_speed", try movedLong(rom, 0x17458), "ROM 0x17458: move.l #N,(28,a0); the other way 0x17462");
    if (try movedLong(rom, 0x17462) != -(try movedLong(rom, 0x17458))) return error.BadData;
    try d.number("flight_depth", try movedLong(rom, 0x1746A), "ROM 0x1746A: move.l #N,(32,a0)");
    try d.number("flight_ticks", try moveByte(rom, 0x17476, 0x6B), "ROM 0x17476: move.b #N,(107,a0)");
    try d.number("slowing", try immediate(rom, 0x172D4, &.{ 0x22, 0x3C }, 4), "ROM 0x172D4: move.l #N,d1; 0x17344");
    if (try immediate(rom, 0x17344, &.{ 0x22, 0x3C }, 4) != try immediate(rom, 0x172D4, &.{ 0x22, 0x3C }, 4)) return error.BadData;
    try d.number("depth_slowing", try immediate(rom, 0x172E8, &.{ 0x06, 0xA8 }, 4), "ROM 0x172E8: addi.l #N,(32,a0)");
    try d.number("depth_back", try immediate(rom, 0x1737A, &.{ 0x06, 0xA8 }, 4), "ROM 0x1737A: addi.l #N,(32,a0); 0x17370");
    if (try immediate(rom, 0x17370, &.{ 0x04, 0xA8 }, 4) != try immediate(rom, 0x1737A, &.{ 0x06, 0xA8 }, 4)) return error.BadData;
    try d.number("depth_within", try comparedWord(rom, 0x17364), "ROM 0x17364: cmpi.w #N,d1");
    try d.number("depth_most", (try immediate(rom, 0x17ACE, &.{ 0x0C, 0x80 }, 4)) >> 16, "ROM 0x17ACE: cmpi.l #N,d0 (its move's, as his)");
    try d.number("gone_from", try comparedWord(rom, 0x1738C) - 0x80, "ROM 0x1738C: cmpi.w #N+$80,d1 (drawn across)");
    try d.number("gone_to", try comparedWord(rom, 0x17394) - 0x80, "ROM 0x17394: cmpi.w #N+$80,d1");
    try d.number("struck_from", try comparedWord(rom, 0xAABA) - 0x80, "ROM 0x0AABA: cmpi.w #N+$80,(40,a0) (drawn across: the meeting check's, 0xAA22)");
    try d.number("struck_to", try comparedWord(rom, 0xAAC2) - 0x80, "ROM 0x0AAC2: cmpi.w #N+$80,(40,a0)");
    try d.number("dropped_ticks", try moveByte(rom, 0x17286, 0x7B), "ROM 0x17286: move.b #N,(123,a0)");
    try d.number("dropped_up", (try movedWord(rom, 0x1728C, 0x24)) << 16, "ROM 0x1728C: move.w #N,(36,a0)");
    try d.number("dropped_depth", (try movedWord(rom, 0x17292, 0x20)) << 16, "ROM 0x17292: move.w #N,(32,a0)");
    if (u16be(rom, 0x1729C) & 0xF1FF != 0xE080) return error.BadData;
    try d.number("dropped_back", (u16be(rom, 0x1729C) >> 9) & 7, "ROM 0x1729C: asr.l #N,d0 (its speed across back, so much shifted)");
    try d.sound("whirr", @bitCast(@as(i8, @intCast(try moveq(rom, 0x1747E, 7)))));
    try d.sound("dropped", @bitCast(@as(i8, @intCast(try moveq(rom, 0x172AA, 7)))));
    if (try moveq(rom, 0x17314, 7) != try moveq(rom, 0x1747E, 7)) return error.BadData;
    return .{
        .name = "boomerang",
        .provenance = try std.fmt.allocPrint(arena, "Antonio's boomerang (type $96, handler 0x17262): his animation set at ROM 0x{X:0>5}, the boxes (0x1A68E, 0x1AB8E){s}", .{ set, d.number_notes.items }),
        .family = .projectile,
        .team = .enemy,
        .behaviour = "boomerang",
        .shadow = true,
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

// --- Round 4's boss and his shoulder ---------------------------------------------------------------

/// Round 4's boss (type $57, his handler 0x174E0, his states at 0x174F4; sor-remaster's
/// obj/boss_57.zig): he walks at his target keeping a band from it in depth, turns when it gets
/// behind him, and within reach across charges (state 2): three looks of a wind-up, then a rush
/// with his shoulder out (type $97) that speeds up until he has passed his target, and a slide.
/// His own frames strike nothing (his blow's power is cleared each tick, 0x174E8): his shoulder
/// strikes. The rest is the bosses' common body (`bossBody`).
pub fn bossR4(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const kind: u8 = 0x57;
    const set = u32be(rom, boss_sets + 4 * @as(u32, kind - 0x55));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "round4_boss", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    // His looks, facing right (the facing bit of the word aside, 0x17A24, 0x176C8).
    const anims = [_]struct { name: []const u8, word: i32 }{
        .{ .name = "stand", .word = try moveq(rom, 0x15888, 0) },
        .{ .name = "turn", .word = try moveq(rom, 0x1766C, 0) },
        .{ .name = "wind_up", .word = try moveq(rom, 0x1764E, 0) },
        .{ .name = "wind_up_2", .word = try moveq(rom, 0x176BC, 0) },
        .{ .name = "wind_up_3", .word = try moveq(rom, 0x176DC, 0) },
        .{ .name = "rush", .word = try moveq(rom, 0x17740, 0) },
        .{ .name = "knocked", .word = try animWord(rom, 0x17CC2) },
        .{ .name = "held", .word = try animWord(rom, 0x17D66) },
        .{ .name = "held_behind", .word = try animWord(rom, 0x17D90) },
        .{ .name = "flight", .word = try animWord(rom, 0x17CC2) + try immediate(rom, 0x163F8, &.{ 0x06, 0x68 }, 2) },
        .{ .name = "bounce", .word = try animWord(rom, 0x17CC2) + try immediate(rom, 0x163F8, &.{ 0x06, 0x68 }, 2) + try quick(rom, 0x1640E, 0x5068) },
        .{ .name = "down", .word = try immediate(rom, 0x16490, &.{ 0x30, 0x3C }, 2) },
        .{ .name = "lifted", .word = try animWord(rom, 0x1662A) },
        .{ .name = "flinch", .word = try moveq(rom, 0x16BB4, 0) },
    };
    for (anims) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, try wordEntry(an.word)) });
    // His blow's power cleared each tick (0x174E8: clr.b (52,a0)): his own frames strike nothing.
    if (u32be(rom, 0x174E8) != 0x42280034) return error.BadData;
    try bossBody(&d, kind);
    // The walk (state 1, 0x175BA): his speed, the second of twins' ((93,a0) = 2).
    if (u32be(rom, 0x175EA) != 0x0C280002 or u16be(rom, 0x175EE) != 0x5D) return error.BadData;
    try d.number("walk_speed", try movedLong(rom, 0x175E2), "ROM 0x175E2: move.l #N,(28,a0) (facing left, its whole pixels' bits reversed: not.w at 0x17608)");
    try d.number("walk_speed_second", try movedLong(rom, 0x175F2), "ROM 0x175F2: move.l #N,(28,a0) (the second of twins)");
    if (u32be(rom, 0x17608) != 0x4668001C) return error.BadData;
    try d.number("depth_near", try comparedWord(rom, 0x17614), "ROM 0x17614: cmpi.w #N,(82,a0) (nearer in depth, he steps away)");
    try d.number("depth_far", try comparedWord(rom, 0x1761C), "ROM 0x1761C: cmpi.w #N,(82,a0) (this far or farther, he steps nearer)");
    try d.number("depth_speed", try moveLong(rom, 0x17628, 0), "ROM 0x17628: move.l #N,d0; the other way 0x17630");
    if (try moveLong(rom, 0x17630, 0) != -(try moveLong(rom, 0x17628, 0))) return error.BadData;
    try d.number("charge_reach", try comparedWord(rom, 0x17642), "ROM 0x17642: cmpi.w #N,(80,a0) (nearer across, he charges)");
    try d.number("turn_ticks", try moveByte(rom, 0x17666, 104), "ROM 0x17666: move.b #N,(104,a0)");
    // The charge (state 2, 0x17682): the wind-up's looks and their ticks, the rush, its speed-up,
    // the slide.
    try d.number("wind_up_ticks", try moveByte(rom, 0x17650, 104), "ROM 0x17650: move.b #N,(104,a0)");
    try d.number("wind_up_2_ticks", try moveByte(rom, 0x176BE, 104), "ROM 0x176BE: move.b #N,(104,a0)");
    try d.number("wind_up_3_ticks", try moveByte(rom, 0x176DE, 104), "ROM 0x176DE: move.b #N,(104,a0)");
    try d.number("rush_speed", try swappedPixels(rom, 0x176F8, 1), "ROM 0x176F8: moveq #N,d1; swap d1 (across, the way he faces)");
    try d.number("rush_depth_most", try immediate(rom, 0x17728, &.{ 0x0C, 0x81 }, 4), "ROM 0x17728: cmpi.l #N,d1 (in depth: the distance's share, (dd << 8) / (dx / 2) << 8, at most this)");
    if (try swappedPixels(rom, 0x17730, 1) != try immediate(rom, 0x17728, &.{ 0x0C, 0x81 }, 4)) return error.BadData;
    try d.number("speed_up", try immediate(rom, 0x17780, &.{ 0x06, 0x80 }, 4), "ROM 0x17780: addi.l #N,d0 (each tick of the rush, across; in depth 0x177AC)");
    if (try immediate(rom, 0x177AC, &.{ 0x06, 0x80 }, 4) != try immediate(rom, 0x17780, &.{ 0x06, 0x80 }, 4)) return error.BadData;
    try d.number("speed_most", try swappedPixels(rom, 0x17786, 1), "ROM 0x17786: moveq #N,d1; swap d1; 0x177B2");
    if (try swappedPixels(rom, 0x177B2, 1) != try swappedPixels(rom, 0x17786, 1)) return error.BadData;
    try d.number("speed_up_depth_from", try comparedWord(rom, 0x1779C), "ROM 0x1779C: cmpi.w #N,(82,a0) (this far from his target in depth, his speed in depth grows)");
    try d.number("passed_by", try comparedWord(rom, 0x177CC), "ROM 0x177CC: cmpi.w #N,(80,a0) (past his target this far across, he slides)");
    try d.number("slide_ticks", try moveByte(rom, 0x177DA, 121), "ROM 0x177DA: move.b #N,(121,a0)");
    // The screen (from where he was drawn): he walks and winds up within it (0x17744), slides
    // while within it (0x177E2).
    try d.number("on_screen_from", try comparedWord(rom, 0x17748) - 0x80, "ROM 0x17748: cmpi.w #N+$80,d1 (drawn across)");
    try d.number("on_screen_to", try immediate(rom, 0x17754, &.{ 0x04, 0x41 }, 2) - 0x80, "ROM 0x17754: subi.w #N+$80,d1");
    if (try comparedWord(rom, 0x177EE) != try comparedWord(rom, 0x17748) or try immediate(rom, 0x177F4, &.{ 0x04, 0x40 }, 2) != try immediate(rom, 0x17754, &.{ 0x04, 0x41 }, 2)) return error.BadData;
    try d.sound("rush", @bitCast(@as(i8, @intCast(try moveq(rom, 0x176F0, 7)))));
    return .{
        .name = "boss_r4",
        .provenance = try std.fmt.allocPrint(arena, "boss type $57, round 4's (handler 0x174E0): the animation set at ROM 0x{X:0>5} (0x158B4), the boxes (0x1A68E, 0x1AB8E); health ROM 0x{X:0>5} (0x17EDC); his palette line his art's (move.w #N,d1 at ROM 0x17530){s}", .{ set, boss_health + @as(u32, kind - 0x55), d.number_notes.items }),
        .family = .boss,
        .team = .enemy,
        .behaviour = "boss_r4",
        .palette = try lineOfArt(rom, 0x17530),
        .health = bossByte(rom, boss_health, kind),
        .shadow = true,
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
        .moves = d.moves.items,
    };
}

/// Round 5's bosses, the twins (type $58, handler 0x158C4, sor-remaster's obj/boss_58.zig): they
/// wait for their art to be copied from the players' (0x158EE); then one (the first of twins)
/// stands, walks, leaps back from a near target and pounces on one a little off its depth, a
/// flying kick; the other (the second, holding) walks slower, catches a player its reach meets,
/// then tosses it from the front or slams it from behind, somersaults at a target facing it,
/// leaps back from one it may not set on. A twin left alone turns from one to the other. Their
/// boxes are the players' (0xAB24: `HitBoxes58`), their art the players'.
pub fn bossR5(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const kind: u8 = 0x58;
    const set = u32be(rom, boss_sets + 4 * @as(u32, kind - 0x55));
    // His boxes: the players' table (0xAB2A: cmpi.b #$58,(0,a0), then lea HitBoxes58).
    if (u16be(rom, 0xAB2A) != 0x0C28 or rom[0xAB2D] != kind) return error.BadData;
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "twins", .set = set, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    const anims = [_]struct { name: []const u8, word: i32 }{
        .{ .name = "stand", .word = try moveq(rom, 0x15888, 0) },
        .{ .name = "walk", .word = try moveq(rom, 0x15AA6, 0) },
        .{ .name = "knocked", .word = try animWord(rom, 0x17CC2) },
        .{ .name = "held", .word = try animWord(rom, 0x17D66) },
        .{ .name = "held_behind", .word = try animWord(rom, 0x17D90) },
        .{ .name = "flight", .word = try animWord(rom, 0x17CC2) + try immediate(rom, 0x163F8, &.{ 0x06, 0x68 }, 2) },
        .{ .name = "bounce", .word = try animWord(rom, 0x17CC2) + try immediate(rom, 0x163F8, &.{ 0x06, 0x68 }, 2) + try quick(rom, 0x1640E, 0x5068) },
        .{ .name = "down", .word = try immediate(rom, 0x16490, &.{ 0x30, 0x3C }, 2) },
        .{ .name = "lifted", .word = try animWord(rom, 0x1662A) },
        .{ .name = "flinch", .word = try moveq(rom, 0x16BB4, 0) },
        .{ .name = "jump", .word = try moveq(rom, 0x15DB4, 0) },
        .{ .name = "crouch", .word = try moveq(rom, 0x15A50, 0) },
        .{ .name = "kick", .word = try moveq(rom, 0x15DD0, 0) },
        .{ .name = "catch_front", .word = try moveq(rom, 0x15BA6, 0) },
        .{ .name = "catch_behind", .word = try moveq(rom, 0x15B9A, 0) },
        .{ .name = "toss", .word = try moveq(rom, 0x15E58, 0) },
        .{ .name = "slam", .word = try moveq(rom, 0x15E50, 0) },
        .{ .name = "leap", .word = try moveq(rom, 0x15A76, 0) },
        .{ .name = "somersault", .word = try moveq(rom, 0x15CDA, 0) },
    };
    if (try moveq(rom, 0x15C5A, 0) != try moveq(rom, 0x15AA6, 0) or try moveq(rom, 0x15DFE, 0) != try moveq(rom, 0x15A50, 0) or try moveq(rom, 0x15C12, 0) != try moveq(rom, 0x15A76, 0)) return error.BadData;
    for (anims) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, try wordEntry(an.word)) });
    // His power is his blows' only in state 2 (0x15D12: (74,a0) to (52,a0); cleared at each
    // tick, 0x158C4): the frames there with a box that strikes (the kick's, the walk's on the
    // pounce's first tick, the stand's at its end). A blow that lands knocks down (0x15D44).
    if (u32be(rom, 0x158C4) != 0x42280034 or u32be(rom, 0x15D12) != 0x1168004A or u16be(rom, 0x15D16) != 52) return error.BadData;
    if (u32be(rom, 0x15D44) != 0x137C0001 or u16be(rom, 0x15D48) != 125) return error.BadData;
    blows(&d, "stand");
    blows(&d, "walk");
    // The kick's frames all strike: his power stands through state 2 whatever his frame, and
    // his box is the frame drawn last (a kick frame's after the kick's look starts over).
    for (@constCast(d.animations.items[d.animationIndex("kick").?].frames)) |*f| f.blow = true;
    const power = bossByte(rom, boss_power, kind);
    try d.moves.append(arena, .{ .name = "pounce", .provenance = "the pounce (state 2, 0x15D0C): a blow that lands knocks the player down (0x15D44: move.b #1,(125,a1)), its damage his power (0x15D12)", .animation = d.animationIndex("kick").?, .damage = power, .reaction = .knock_down });
    try bossBody(&d, kind);
    // His art copied from the players' (0x17FC2, a step each tick after the objects', asked at
    // 0x1590E): its steps (cmpi.w #N,d0 by steps of addi.w #N,($FB54)), then the tick that ends
    // it; he comes out at the next.
    if (u16be(rom, 0x17FCE) != 0x0C40 or u16be(rom, 0x17FE6) != 0x0678 or u16be(rom, 0x17FEA) != 0xFB54 or u32be(rom, 0x1590E) != 0x11FC0001 or u16be(rom, 0x15912) != 0xFA5A) return error.BadData;
    const copy_steps = @divExact(u16be(rom, 0x17FD0), u16be(rom, 0x17FE8));
    try d.number("copy_ticks", copy_steps + 1, "ROM 0x17FD0 over ROM 0x17FE8: the copy's steps (0x17FC2), a tick each from the one asking, then the tick that ends it");
    // His target (0x15946) and his measures; state 1 (0x159C2): the pounce's band in depth, its
    // reach across; the leap back's; standing; walking (0x1792C, 0x17924: whole pixels toward his
    // target; 0x17954: in depth toward or away by the band; 0x1797E: toward it, by the depth).
    try d.number("pounce_far", try comparedWord(rom, 0x15A1C), "ROM 0x15A1C: cmpi.w #N,(82,a0) (in depth, nearer than this)");
    try d.number("pounce_near", try comparedWord(rom, 0x15A24), "ROM 0x15A24: cmpi.w #N,(82,a0) (and not nearer than this)");
    try d.number("pounce_reach", try comparedWord(rom, 0x15A2C), "ROM 0x15A2C: cmpi.w #N,(80,a0) (across, nearer than this)");
    try d.number("pounce_from_walk", try moveByte(rom, 0x15A44, 120), "ROM 0x15A44: move.b #N,(120,a0) (his count, from a walk)");
    try d.number("leap_near", try comparedWord(rom, 0x15A64), "ROM 0x15A64: cmpi.w #N,(80,a0) (across, nearer: he leaps back)");
    try d.number("stand_ticks", try immediate(rom, 0x15A88, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x15A88: cmpi.b #N,(120,a0)");
    try d.number("walk_speed", (try moveq(rom, 0x1792C, 0)) << 16, "ROM 0x1792C: moveq #N,d0; swap d0");
    try d.number("hold_walk_speed", (try moveq(rom, 0x17924, 0)) << 16, "ROM 0x17924: moveq #N,d0; swap d0");
    try d.number("somersault_x", (try moveq(rom, 0x17928, 0)) << 16, "ROM 0x17928: moveq #N,d0; swap d0");
    try d.number("leap_x", (try moveq(rom, 0x17942, 0)) << 16, "ROM 0x17942: moveq #N,d0; swap d0 (away)");
    try d.number("hover_speed", try moveLong(rom, 0x17954, 0), "ROM 0x17954: move.l #N,d0");
    try d.number("hover_band", try comparedWord(rom, 0x1795A), "ROM 0x1795A: cmpi.w #N,(82,a0) (farther in depth: toward, else away)");
    try d.number("level_far", try comparedWord(rom, 0x17984), "ROM 0x17984: cmpi.w #N,d1 (from it, moveq #N,d0 at 0x17982)");
    try d.number("level_mid", try comparedWord(rom, 0x1798C), "ROM 0x1798C: cmpi.w #N,d1 (0x1798A)");
    try d.number("level_near", try comparedWord(rom, 0x17994), "ROM 0x17994: cmpi.w #N,d1 (0x17992)");
    try d.number("level_far_speed", (try moveq(rom, 0x17982, 0)) << 16, "ROM 0x17982: moveq #N,d0; swap d0");
    try d.number("level_mid_speed", (try moveq(rom, 0x1798A, 0)) << 16, "ROM 0x1798A: moveq #N,d0");
    try d.number("level_near_speed", (try moveq(rom, 0x17992, 0)) << 16, "ROM 0x17992: moveq #N,d0");
    // The leap back (move 2, 0x15ABA; the holding twin's move 3), its fall (0x15AF4).
    try d.number("leap_at", try immediate(rom, 0x15AC2, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x15AC2: cmpi.b #N,d1 (his count: the leap starts)");
    try d.number("leap_depth", try movedLong(rom, 0x15ACA), "ROM 0x15ACA: move.l #N,(32,a0) (toward his target's depth)");
    try d.number("leap_up", try movedLong(rom, 0x15ADC), "ROM 0x15ADC: move.l #N,(36,a0)");
    try d.number("fall_gravity", try immediate(rom, 0x15AFE, &.{ 0x06, 0xA8 }, 4), "ROM 0x15AFE: addi.l #N,(36,a0); 0x15DE0");
    if (try immediate(rom, 0x15DE0, &.{ 0x06, 0xA8 }, 4) != try immediate(rom, 0x15AFE, &.{ 0x06, 0xA8 }, 4)) return error.BadData;
    // The holding twin (0x15B2A): the catch's places, the airborne catch's count; the leap off a
    // target he may not set on (0x15BE8: near, on the screen); the somersault (0x15C72).
    try d.number("catch_front", try immediate(rom, 0x15BA8, &.{ 0x34, 0x3C }, 2), "ROM 0x15BA8: move.w #N,d2 (across from him, in front)");
    try d.number("catch_behind", try immediate(rom, 0x15B9C, &.{ 0x34, 0x3C }, 2), "ROM 0x15B9C: move.w #N,d2 (from behind)");
    try d.number("catch_airborne", try moveByte(rom, 0x15B5A, 120), "ROM 0x15B5A: move.b #N,(120,a0) (his count, caught in the air)");
    try d.number("leap_off_near", try comparedWord(rom, 0x15BF0), "ROM 0x15BF0: cmpi.w #N,(80,a0)");
    try d.number("leap_off_from", try immediate(rom, 0x15BFC, &.{ 0x0C, 0x40 }, 2) - 0x80, "ROM 0x15BFC: cmpi.w #N+$80,d0 (drawn across, past it)");
    try d.number("leap_off_to", try immediate(rom, 0x15C02, &.{ 0x0C, 0x40 }, 2) - 0x80, "ROM 0x15C02: cmpi.w #N+$80,d0 (before it)");
    try d.number("somersault_near", try comparedWord(rom, 0x15C72), "ROM 0x15C72: cmpi.w #N,(80,a0)");
    try d.number("somersault_far", try comparedWord(rom, 0x15C84), "ROM 0x15C84: cmpi.w #N,(80,a0)");
    try d.number("somersault_up", try movedLong(rom, 0x15CC2), "ROM 0x15CC2: move.l #N,(36,a0)");
    try d.number("hop_ticks", try immediate(rom, 0x15CE0, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x15CE0: cmpi.b #N,(13,a0) (a frame's first tick)");
    try d.number("hop_up_frame", try frameCompared(rom, 0x15CE8), "ROM 0x15CE8: cmpi.b #N,(10,a0)");
    try d.number("hop_down_frame", try frameCompared(rom, 0x15CF8), "ROM 0x15CF8: cmpi.b #N,(10,a0)");
    try d.number("hop", try immediate(rom, 0x15CF0, &.{ 0x04, 0x68 }, 2), "ROM 0x15CF0: subi.w #N,(24,a0); addi.w at 0x15D00");
    if (try immediate(rom, 0x15D00, &.{ 0x06, 0x68 }, 2) != try immediate(rom, 0x15CF0, &.{ 0x04, 0x68 }, 2)) return error.BadData;
    // The pounce (state 2, 0x15D0C): its count's steps (0x15D52...), its jump.
    try d.number("pounce_stand_at", try immediate(rom, 0x15D52, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x15D52: cmpi.b #N,d1");
    try d.number("pounce_end_at", try immediate(rom, 0x15D5C, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x15D5C: cmpi.b #N,d1");
    try d.number("pounce_at", try immediate(rom, 0x15D7C, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x15D7C: cmpi.b #N,d1 (the jump)");
    try d.number("shout_at", try immediate(rom, 0x15DBC, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x15DBC: cmpi.b #N,d1");
    try d.number("kick_at", try immediate(rom, 0x15DCA, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x15DCA: cmpi.b #N,d1");
    if (u16be(rom, 0x15D96) != 0xE880) return error.BadData;
    try d.number("pounce_up", try moveWord(rom, 0x15D9C, 36), "ROM 0x15D9C: move.w #N,(36,a0) (whole pixels, the fraction kept; in depth a sixteenth of the gap, 0x15D96: asr.l #4)");
    try d.number("pounce_x", try movedLong(rom, 0x15DA2), "ROM 0x15DA2: move.l #N,(28,a0)");
    // The hold (0x15E06): its count's throw, the toss's and the slam's ends.
    try d.number("throw_at", try immediate(rom, 0x15E40, &.{ 0x0C, 0x06, 0x00 }, 1), "ROM 0x15E40: cmpi.b #N,d6");
    try d.number("toss_end", try immediate(rom, 0x15E16, &.{ 0x0C, 0x06, 0x00 }, 1), "ROM 0x15E16: cmpi.b #N,d6");
    try d.number("slam_end", try immediate(rom, 0x15E24, &.{ 0x0C, 0x06, 0x00 }, 1), "ROM 0x15E24: cmpi.b #N,d6");
    if (try moveq(rom, 0x15CD2, 7) != try moveq(rom, 0x15AE8, 7) or try moveq(rom, 0x15D86, 7) != try moveq(rom, 0x15AE8, 7) or try moveq(rom, 0x15DF2, 7) != try moveq(rom, 0x15B0A, 7) or try moveq(rom, 0x15E66, 7) != try moveq(rom, 0x15DC2, 7)) return error.BadData;
    try d.sound("jump", @bitCast(@as(i8, @intCast(try moveq(rom, 0x15AE8, 7)))));
    try d.sound("land", @bitCast(@as(i8, @intCast(try moveq(rom, 0x15B0A, 7)))));
    try d.sound("shout", @bitCast(@as(i8, @intCast(try moveq(rom, 0x15DC2, 7)))));
    return .{
        .name = "boss_r5",
        .provenance = try std.fmt.allocPrint(arena, "boss type $58, round 5's twins (handler 0x158C4): the animation set at ROM 0x{X:0>5} (0x158B4), the players' boxes (0x1ABA8, 0x1AB8E); health ROM 0x{X:0>5} (0x17EDC); his palette line his art's (move.w #N,d1 at ROM 0x1593C){s}", .{ set, boss_health + @as(u32, kind - 0x55), d.number_notes.items }),
        .family = .boss,
        .team = .enemy,
        .behaviour = "boss_r5",
        .palette = try lineOfArt(rom, 0x1593C),
        .health = bossByte(rom, boss_health, kind),
        .shadow = true,
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
        .moves = d.moves.items,
    };
}

/// Round 4's boss's shoulder (type $97, handler 0x17858, made at 0x1781E): his rush's blow, at
/// his shoulder (0x178D0): its first look until the last tick of its frame 2, then its second;
/// gone once he leaves his charge (in its second look). A blow that lands knocks down, its damage
/// his power.
pub fn bossR4Shoulder(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const kind: u8 = 0x57;
    const set = u32be(rom, boss_sets + 4 * @as(u32, kind - 0x55));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "round4_boss", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    for ([_]struct { name: []const u8, word: i32 }{
        .{ .name = "lead", .word = try moveq(rom, 0x17842, 0) },
        .{ .name = "shoulder", .word = try moveq(rom, 0x1788E, 0) },
    }) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, try wordEntry(an.word)) });
    blows(&d, "lead");
    blows(&d, "shoulder");
    // A blow that lands knocks the player down (0x17874: move.b #1,(125,a1)), its damage his
    // power ((74,a0) to its (52,a1), 0x17832).
    if (u32be(rom, 0x17874) != 0x137C0001 or u16be(rom, 0x17878) != 125 or u32be(rom, 0x17832) != 0x1368004A or u16be(rom, 0x17836) != 52) return error.BadData;
    try d.moves.append(arena, .{ .name = "shoulder", .provenance = "the rush's shoulder (0x17858): a blow that lands knocks the player down (0x17874: move.b #1,(125,a1)), its damage his power (0x17832)", .animation = d.animationIndex("lead").?, .damage = bossByte(rom, boss_power, kind), .reaction = .knock_down });
    // Its second look at the last tick of its first's frame 2 (0x1787E: (13,a0) its frame's
    // ticks left, (10,a0) its frame).
    if (u16be(rom, 0x1787E) != 0x0C28 or rom[0x17880] != 0 or u16be(rom, 0x17882) != 13) return error.BadData;
    try d.number("turn_left", rom[0x17881], "ROM 0x1787E: cmpi.b #N,(13,a0) (its frame's ticks left)");
    try d.number("turn_frame", try frameCompared(rom, 0x17886), "ROM 0x17886: cmpi.b #N,(10,a0)");
    // At his shoulder (0x178D0): ahead of him the way he faces, deeper, above his feet (a pixel
    // less at his frames 0 and `low_frame`).
    try d.number("ahead", try immediate(rom, 0x178EE, &.{ 0x06, 0x40 }, 2), "ROM 0x178EE: addi.w #N,d0 (facing left 0x178E2: subi.w)");
    if (try immediate(rom, 0x178E2, &.{ 0x04, 0x40 }, 2) != try immediate(rom, 0x178EE, &.{ 0x06, 0x40 }, 2)) return error.BadData;
    try d.number("deeper", try quick(rom, 0x178FA, 0x5040), "ROM 0x178FA: addq.w #N,d0");
    try d.number("above", try immediate(rom, 0x17910, &.{ 0x04, 0x40 }, 2), "ROM 0x17910: subi.w #N,d0");
    try d.number("above_low", try immediate(rom, 0x17916, &.{ 0x04, 0x40 }, 2), "ROM 0x17916: subi.w #N,d0 (at his frame 0 and the next number's)");
    try d.number("low_frame", try immediate(rom, 0x1790A, &.{ 0x0C, 0x01, 0x00 }, 1), "ROM 0x1790A: cmpi.b #N,d1 (his frame)");
    return .{
        .name = "boss_r4_shoulder",
        .provenance = try std.fmt.allocPrint(arena, "round 4's boss's shoulder (type $97, handler 0x17858, made at 0x1781E): his animation set at ROM 0x{X:0>5}, the boxes (0x1A68E, 0x1AB8E){s}", .{ set, d.number_notes.items }),
        .family = .projectile,
        .team = .enemy,
        .behaviour = "boss_r4_shoulder",
        .palette = try lineOfArtGiven(rom, 0x1783C),
        // Every object of the original's play below its shadows' places has a shadow (0xB132).
        .shadow = true,
        .numbers = d.numbers.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
        .moves = d.moves.items,
    };
}

/// The definitions this module writes, appended to `out`.
// --- The juggler, round 2's, and its knives ---------------------------------------------------

/// `move.w #N,(D,a0)` at `at` (the displacement checked): N.
fn moveWord(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at + 4) != displacement) return error.BadData;
    return immediate(rom, at, &.{ 0x31, 0x7C }, 2);
}

/// `move.l #N,dR` at `at`: N.
fn moveLong(rom: []const u8, at: u32, register: u3) Error!i32 {
    return immediate(rom, at, &.{ 0x20 | (@as(u8, register) << 1), 0x3C }, 4);
}

/// The juggler's states by the original's number (type $27's table at 0x1037C), as the traces
/// name them (its state 3 a way into its knock-down, $11).
const juggler_states = [_][]const u8{ "appear", "choose", "reel", "knocked_down", "stand", "held", "knocked_out", "walk_off", "close_in", "lunge", "sidestep", "raise", "approach", "keep_away", "throw_knives", "leap", "crouch", "knocked_down", "circle" };

/// The juggler (type $27, its handler 0xF27E, sor-remaster's obj/juggler.zig): it heads for its
/// place a way off its target, juggling two knives (its walk paced), closes in at a depth by its
/// target's, steps in and backs off (`lunge`), sidesteps to its target's depth, and raises its
/// knives to throw them (its animation $14); or it keeps away, crossing the screen, then throws
/// knives it takes out; or it leaps about its target (its animation $20), crouching between
/// leaps; or it circles its place. Its own blows are its knives' (`juggler_knife`).
pub fn juggler(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try begin(arena, rom, 0x27, "juggler", &.{
        .{ .name = "throw", .entry = try animEntryWord(rom, 0xF770) },
        .{ .name = "leap", .entry = try animEntry(rom, 0xF2EE) },
    });
    if (try animEntry(rom, 0xF418) != try animEntryWord(rom, 0xF770)) return error.BadData;
    try d.number("approach_speed", (try moveWord(rom, 0xF5A4, 100)) << 8, "ROM 0x0F5A4: move.w #N,(100,a0) (8.8)");
    try d.number("approach_beside", try immediate(rom, 0xF5AA, &.{ 0x30, 0x3C }, 2), "ROM 0x0F5AA: move.w #N,d0 (on its own side of its target)");
    try d.number("approach_ticks", try moveByte(rom, 0xF5C0, 80), "ROM 0x0F5C0: move.b #N,(80,a0)");
    try d.number("approach_first", try moveByte(rom, 0xF588, 13), "ROM 0x0F588: move.b #N,(13,a0) (its walk's first frame's ticks)");
    if (u16be(rom, 0xF604) != 20) return error.BadData;
    try d.number("close_level", try immediate(rom, 0xF600, &.{ 0x0C, 0x69 }, 2), "ROM 0x0F600: cmpi.w #N,(20,a1) (its target's depth)");
    try d.number("close_near", try moveq(rom, 0xF5FA, 0), "ROM 0x0F5FA: moveq #N,d0 (its depth, its target nearer than close_level)");
    try d.number("close_far", try moveq(rom, 0xF608, 0), "ROM 0x0F608: moveq #N,d0 (its depth, else)");
    try d.number("close_step", try moveq(rom, 0xF624, 1), "ROM 0x0F624: moveq #N,d1 (toward its target, once there)");
    try d.number("lunge_far", try immediate(rom, 0xF66A, &.{ 0x0C, 0x40 }, 2), "ROM 0x0F66A: cmpi.w #N,d0 (farther across from its target: it sidesteps)");
    try d.number("lunge_near", try immediate(rom, 0xF670, &.{ 0x0C, 0x40 }, 2), "ROM 0x0F670: cmpi.w #N,d0 (farther: it takes up the fight again)");
    try d.number("lunge_speed", (try moveWord(rom, 0xF676, 100)) << 8, "ROM 0x0F676: move.w #N,(100,a0) (8.8)");
    try d.number("lunge_step", try moveq(rom, 0xF67C, 1), "ROM 0x0F67C: moveq #N,d1 (away from its target)");
    try d.number("sidestep_x", try moveLong(rom, 0xF6C8, 1), "ROM 0x0F6C8: move.l #N,d1 (away from its target)");
    try d.number("sidestep_depth", try moveLong(rom, 0xF6DE, 1), "ROM 0x0F6DE: move.l #N,d1 (toward its target's depth)");
    try d.number("sidestep_level", try immediate(rom, 0xF70A, &.{ 0x0C, 0x40 }, 2), "ROM 0x0F70A: cmpi.w #N,d0 (its target's depth within it)");
    try d.number("raise_pace", (try moveWord(rom, 0xF736, 12)) >> 8, "ROM 0x0F736: move.w #N*$101,(12,a0)");
    try d.number("raise_throws", try moveByte(rom, 0xF73C, 81), "ROM 0x0F73C: move.b #N,(81,a0)");
    try d.number("raise_ticks", try moveByte(rom, 0xF742, 80), "ROM 0x0F742: move.b #N,(80,a0) (its throw's wait for a knife in hand)");
    try d.number("raise_wait", try moveByte(rom, 0xF748, 84), "ROM 0x0F748: move.b #N,(84,a0) (its wait for a knife caught)");
    try d.number("throw_frame", try frameCompared(rom, 0xF78C), "ROM 0x0F78C: cmpi.b #N,(10,a0)");
    // Keeping away (0xF4A6), throwing knives (0xF410), their test of the target's nearness
    // (0xF482).
    try d.number("keep_away_legs", try moveByte(rom, 0xF4BA, 80), "ROM 0x0F4BA: move.b #N,(80,a0)");
    try d.number("keep_away_left", try immediate(rom, 0xF4D6, &.{ 0x32, 0x3C }, 2), "ROM 0x0F4D6: move.w #N,d1 (from the camera, facing left)");
    try d.number("keep_away_right", try moveq(rom, 0xF4E2, 1), "ROM 0x0F4E2: moveq #N,d1 (from the camera, facing right)");
    try d.number("throw_near", try immediate(rom, 0xF492, &.{ 0x0C, 0x40 }, 2), "ROM 0x0F492: cmpi.w #N,d0 (its target nearer across: it walks off)");
    try d.number("throw_pace", (try moveWord(rom, 0xF41E, 12)) >> 8, "ROM 0x0F41E: move.w #N*$101,(12,a0)");
    try d.number("throw_count", try moveByte(rom, 0xF42A, 80), "ROM 0x0F42A: move.b #N,(80,a0) (counted down before its test: one knife fewer)");
    try d.number("throw_rearm", try frameCompared(rom, 0xF43E), "ROM 0x0F43E: cmpi.b #N,(10,a0)");
    // Leaping (0xF2E6) and crouching (0xF3B6).
    try d.number("leap_land_ticks", try moveByte(rom, 0xF364, 80), "ROM 0x0F364: move.b #N,(80,a0) (the landing's tick counted)");
    try d.number("leap_land_frame", try moveByte(rom, 0xF36A, 10), "ROM 0x0F36A: move.b #N,(10,a0)");
    try d.number("crouch_least", try immediate(rom, 0xF3C6, &.{ 0x06, 0x00 }, 2), "ROM 0x0F3C6: addi.b #N,d0 (a draw's low three bits added)");
    if (try moveByte(rom, 0xF3F6, 81) != try moveByte(rom, 0xF3DC, 81)) return error.BadData;
    try d.number("crouch_flip", try moveByte(rom, 0xF3DC, 81), "ROM 0x0F3DC: move.b #N,(81,a0) (the ticks between two turns, its ticks odd)");
    {
        var xs: [16]i32 = undefined;
        var ds: [16]i32 = undefined;
        for (&xs, &ds, 0..) |*x, *y, j| {
            x.* = entities.s8(rom, 0x1031A + 2 * @as(u32, @intCast(j)));
            y.* = entities.s8(rom, 0x1031A + 2 * @as(u32, @intCast(j)) + 1);
        }
        try d.table("point_x", &xs, "ROM 0x1031A: a leap's or a circle's point around its place, by a draw's low four bits (0xF304, 0xE254)");
        try d.table("point_depth", &ds, "ROM 0x1031B");
        var speeds: [4]i32 = undefined;
        var ups: [4]i32 = undefined;
        var after_leap: [4][]const u8 = undefined;
        for (&speeds, &ups, &after_leap, 0..) |*sp, *up, *af, j| {
            const jj: u32 = @intCast(j);
            sp.* = @as(i32, u16be(rom, 0xF3AA + 2 * jj)) << 8;
            up.* = entities.s8(rom, 0xF3B2 + jj);
            af.* = try stateName(&juggler_states, u16be(rom, 0xF3A2 + 2 * jj));
        }
        try d.table("leap_speed", &speeds, "ROM 0x0F3AA: a leap's speed (8.8) by its depth's low two bits");
        try d.table("leap_up", &ups, "ROM 0x0F3B2: a leap's speed up (whole pixels; its fraction kept) by the tick's low two bits");
        try d.choice("after_leap", &after_leap, "ROM 0x0F3A2: the state after a leap, by its place across's low two bits");
        var depths: [8]i32 = undefined;
        for (&depths, 0..) |*y, j| y.* = rom[0xF53C + j];
        try d.table("keep_away_depth", &depths, "ROM 0x0F53C: a leg's depth by a draw's low three bits");
        var circle_speeds: [4]i32 = undefined;
        var paces: [4]i32 = undefined;
        for (&circle_speeds, &paces, 0..) |*sp, *pc, j| {
            const at: u32 = 0x102FA + 4 * @as(u32, @intCast(j));
            sp.* = @as(i32, u16be(rom, at)) << 8;
            pc.* = rom[at + 2];
        }
        try d.table("circle_speed", &circle_speeds, "ROM 0x102FA: its circle's speed (8.8) by its place across's low two bits (0xE248)");
        try d.table("circle_pace", &paces, "ROM 0x102FC: its frames' ticks");
        var after: [8][]const u8 = undefined;
        for (&after, 0..) |*a, j| a.* = try stateName(&juggler_states, u16be(rom, 0x1030A + 2 * @as(u32, @intCast(j))));
        try d.choice("after_circle", &after, "ROM 0x1030A: the state after a circle, by the tick's low three bits (0xE2C6)");
    }
    return finish(&d, "juggler", 0x27, "juggler", "the juggler (handler 0xF27E)");
}

/// The juggler's knives (type $28, its handler 0xFC14, states by the offsets at 0x103A2, its
/// set the juggler's): a maker that makes two of them (0xFC1C), and each knife juggled in an arc
/// from its juggler's hand (0xFCB6), tossed high (0xFE46), falling away (0xFED6), or in the hand
/// and thrown (0xFEE4); its blow the type's power, knocking a player down.
pub fn jugglerKnife(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const kind: u8 = 0x28;
    const k: u32 = kind - 0x20;
    const set = u32be(rom, enemy_sets + 4 * k);
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "juggler", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    try d.animations.append(arena, .{ .name = "knife", .loop = true, .frames = try enemyFrames(&d, "knife", try wordEntry(try moveWord(rom, 0xFC82, 8))) });
    try d.animations.append(arena, .{ .name = "knife_b", .loop = true, .frames = try enemyFrames(&d, "knife_b", try wordEntry(try moveWord(rom, 0xFC94, 8))) });
    try d.number("power", rom[enemy_numbers + 6 * k + 3], "ROM 0x26FCE (by type and strength, three bytes after the health, 0x938C)");
    try d.number("maker_knives", try moveByte(rom, 0xFC2A, 80), "ROM 0x0FC2A: move.b #N,(80,a0)");
    try d.number("maker_first", try moveByte(rom, 0xFC30, 81), "ROM 0x0FC30: move.b #N,(81,a0)");
    try d.number("maker_gap", try moveByte(rom, 0xFC5E, 81), "ROM 0x0FC5E: move.b #N,(81,a0)");
    try d.number("pace", (try moveWord(rom, 0xFC7C, 12)) >> 8, "ROM 0x0FC7C: move.w #N*$101,(12,a0)");
    // Drawn in front in one round (0xFC9A: cmpi.w #N,($FF02), then bset #4,(1,a0)).
    if (u16be(rom, 0xFC9E) != 0xFF02 or u32be(rom, 0xFCA2) != 0x08E80004 or u16be(rom, 0xFCA6) != 1) return error.BadData;
    try d.number("front_round", (try immediate(rom, 0xFC9A, &.{ 0x0C, 0x78 }, 2)) + 1, "ROM 0x0FC9A: cmpi.w #N,($FF02) (the round's number less one)");
    try d.number("juggle_height", try moveWord(rom, 0xFCC4, 24), "ROM 0x0FCC4: move.w #N,(24,a0)");
    if (u16be(rom, 0xFCD0) != 36 or u16be(rom, 0xFCD8) != 28) return error.BadData;
    try d.number("juggle_up", try immediate(rom, 0xFCCA, &.{ 0x21, 0x7C }, 4), "ROM 0x0FCCA: move.l #N,(36,a0)");
    try d.number("juggle_across", try immediate(rom, 0xFCD2, &.{ 0x21, 0x7C }, 4), "ROM 0x0FCD2: move.l #N,(28,a0)");
    try d.number("juggle_offset", try moveWord(rom, 0xFCDA, 84), "ROM 0x0FCDA: move.w #N,(84,a0) (from its juggler's place across)");
    try d.number("juggle_offset_left", try moveWord(rom, 0xFCEC, 84), "ROM 0x0FCEC: move.w #N,(84,a0) (its juggler facing left)");
    if (u16be(rom, 0xFD3A) != 20) return error.BadData;
    try d.number("juggle_depth", try quick(rom, 0xFD38, 0x5068), "ROM 0x0FD38: addq.w #N,(20,a0) (from its juggler's depth)");
    if (u16be(rom, 0xFD86) != 28) return error.BadData;
    try d.number("juggle_back", try immediate(rom, 0xFD80, &.{ 0x21, 0x7C }, 4), "ROM 0x0FD80: move.l #N,(28,a0) (back to the hand)");
    try d.number("hand", try moveq(rom, 0xFD8C, 1), "ROM 0x0FD8C: moveq #N,d1 (the hand, across from its juggler)");
    try d.number("hand_left", try moveq(rom, 0xFD96, 1), "ROM 0x0FD96: moveq #N,d1 (its juggler facing left)");
    if (try moveq(rom, 0xFDD6, 0) != -(try moveq(rom, 0xFDCC, 0))) return error.BadData;
    try d.number("caught_x", try moveq(rom, 0xFDCC, 0), "ROM 0x0FDCC: moveq #N,d0 (caught, across from its juggler; its opposite facing left)");
    if (u16be(rom, 0xFE26) != 36) return error.BadData;
    try d.number("copy_up", try immediate(rom, 0xFE20, &.{ 0x23, 0x7C }, 4), "ROM 0x0FE20: move.l #N,(36,a1) (a knife struck in its arc: a copy falls away)");
    try d.number("copy_across", try moveq(rom, 0xFE28, 0), "ROM 0x0FE28: moveq #N,d0 (whole pixels, behind its juggler)");
    if (u16be(rom, 0xFE54) != 36) return error.BadData;
    try d.number("toss_up", try immediate(rom, 0xFE4E, &.{ 0x21, 0x7C }, 4), "ROM 0x0FE4E: move.l #N,(36,a0)");
    if (u16be(rom, 0xFE72) != 24) return error.BadData;
    try d.number("toss_top", try immediate(rom, 0xFE6E, &.{ 0x0C, 0x68 }, 2), "ROM 0x0FE6E: cmpi.w #N,(24,a0)");
    if (try moveq(rom, 0xFE8E, 0) != -(try moveq(rom, 0xFE7C, 0))) return error.BadData;
    try d.number("toss_x", try moveq(rom, 0xFE7C, 0), "ROM 0x0FE7C: moveq #N,d0 (across from its juggler at its top; its opposite facing left)");
    try d.number("toss_hang", try moveByte(rom, 0xFE9A, 80), "ROM 0x0FE9A: move.b #N,(80,a0)");
    try d.number("toss_catch", try immediate(rom, 0xFEAE, &.{ 0x06, 0x40 }, 2), "ROM 0x0FEAE: addi.w #N,d0 (from its juggler's height)");
    if (u16be(rom, 0xFF0A) != 20) return error.BadData;
    try d.number("hand_depth", -(try quick(rom, 0xFF08, 0x5168)), "ROM 0x0FF08: subq.w #N,(20,a0) (in the hand, from its juggler's depth)");
    try d.number("hand_height", try immediate(rom, 0xFF10, &.{ 0x06, 0x40 }, 2), "ROM 0x0FF10: addi.w #N,d0 (in the hand, from its juggler's height)");
    if (try moveq(rom, 0xFF2E, 0) != -(try moveq(rom, 0xFF1E, 0))) return error.BadData;
    try d.number("hand_x", try moveq(rom, 0xFF1E, 0), "ROM 0x0FF1E: moveq #N,d0 (in the hand, across from its juggler; its opposite facing left)");
    if (u16be(rom, 0xFF4A) != 10) return error.BadData;
    try d.number("launch_frame", try immediate(rom, 0xFF46, &.{ 0x0C, 0x29 }, 2), "ROM 0x0FF46: cmpi.b #N,(10,a1) (its juggler's frame)");
    if (u16be(rom, 0xFF60) != 24) return error.BadData;
    try d.number("launch_drop", try immediate(rom, 0xFF5C, &.{ 0x06, 0x68 }, 2), "ROM 0x0FF5C: addi.w #N,(24,a0)");
    try d.number("launch_speed", try moveLong(rom, 0xFF62, 0), "ROM 0x0FF62: move.l #N,d0");
    try d.number("launch_ahead", try immediate(rom, 0xFF68, &.{ 0x34, 0x3C }, 2), "ROM 0x0FF68: move.w #N,d2");
    if (u16be(rom, 0x10058) != 36) return error.BadData;
    try d.number("turn_up", try immediate(rom, 0x10052, &.{ 0x21, 0x7C }, 4), "ROM 0x10052: move.l #N,(36,a0) (a blow turns it back)");
    try d.number("deflect_speed", (try immediate(rom, 0x10032, &.{ 0x3C, 0x3C }, 2)) << 8, "ROM 0x10032: move.w #N,d6 (8.8; a swung weapon sends it toward the screen's edge)");
    try d.number("deflect_width", try immediate(rom, 0x10026, &.{ 0x06, 0x40 }, 2), "ROM 0x10026: addi.w #N,d0 (the screen's right edge from its left)");
    var depths: [4]i32 = undefined;
    for (&depths, 0..) |*v, j| v.* = rom_mod.s16be(rom, 0x1009C + 2 * @as(u32, @intCast(j)));
    try d.table("deflect_depth", &depths, "ROM 0x1009C: the depth it is sent to, by a draw's low two bits (0x1000A)");
    try d.number("redirect_power", try moveByte(rom, 0x10066, 52), "ROM 0x10066: move.b #N,(52,a0) (sent at the other player)");
    try d.number("redirect_speed", (try immediate(rom, 0x1008A, &.{ 0x3C, 0x3C }, 2)) << 8, "ROM 0x1008A: move.w #N,d6 (8.8)");
    const drawn = try immediate(rom, 0xAF6E, &.{ 0x06, 0x42 }, 2);
    try d.number("flight_from", try immediate(rom, 0x97E8, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x097E8: cmpi.w #N,(40,a0), less 0xAF6E's offset (0xFFC4)");
    try d.number("flight_to", try immediate(rom, 0x97F0, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x097F0: cmpi.w #N,(40,a0), less 0xAF6E's offset (excluded)");
    try d.number("fall_most", try immediate(rom, 0x974E, &.{ 0x0C, 0xA8 }, 4), "ROM 0x0974E: cmpi.l #N,(36,a0)");
    try d.number("grab_height", try comparedWord(rom, 0xAAF6), "ROM 0x0AAF6: cmpi.w #N,d2 (a reach that meets it within this height, 0xAA22)");
    try d.number("struck_from", try comparedWord(rom, 0xAABA) - 0x80, "ROM 0x0AABA: cmpi.w #N+$80,(40,a0) (drawn across: the meeting check's, 0xAA22)");
    try d.number("struck_to", try comparedWord(rom, 0xAAC2) - 0x80, "ROM 0x0AAC2: cmpi.w #N+$80,(40,a0)");
    return .{
        .name = "juggler_knife",
        .provenance = try std.fmt.allocPrint(arena, "the juggler's knives, type $28 (handler 0xFC14): the juggler's animation set at ROM 0x{X:0>5} (0x27032), its knives' animations $18 and $1C (0xFC82, 0xFC94), the boxes (0x1A68E, 0x1AB8E); gravity ROM 0x0973E: addi.l #N,(36,a0){s}", .{ set, d.number_notes.items }),
        .family = .projectile,
        .team = .enemy,
        .behaviour = "juggler_knife",
        // Every object of the original's play below its shadows' places has a shadow (0xB132).
        .shadow = true,
        .gravity = try immediate(rom, 0x973E, &.{ 0x06, 0xA8 }, 4),
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try juggler(arena, rom));
    try out.append(arena, try jugglerKnife(arena, rom));
    try out.append(arena, try brawler(arena, rom));
    try out.append(arena, try galsiaKnife(arena, rom));
    try out.append(arena, try galsia(arena, rom));
    try out.append(arena, try stalker(arena, rom));
    try out.append(arena, try signal(arena, rom));
    try out.append(arena, try galsiaPipe(arena, rom));
    try out.append(arena, try acrobat(arena, rom));
    try out.append(arena, try acrobatTrio(arena, rom));
    try out.append(arena, try shutter(arena, rom));
    try out.append(arena, try antonio(arena, rom));
    try out.append(arena, try boomerang(arena, rom));
    try out.append(arena, try bossR2(arena, rom));
    try out.append(arena, try bossR2Claws(arena, rom));
    try out.append(arena, try bossR2Trail(arena, rom));
    try out.append(arena, try bossR4(arena, rom));
    try out.append(arena, try bossR4Shoulder(arena, rom));
    try out.append(arena, try bossR5(arena, rom));
}

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

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const moveByte = entities.moveByte;
const moveq = entities.moveq;
const frameCompared = entities.frameCompared;
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
/// shown for the animation's timing byte, as the objects' animations run (0xB0B6).
fn enemyFrames(d: *Def, name: []const u8, entry: u32) Error![]entity.Frame {
    const right = try readAnimation(d.arena, d.rom, d.set, entry);
    const left = try readAnimation(d.arena, d.rom, d.set, entry + 1);
    if (right.frames.len != left.frames.len or right.timing == 0) return error.BadData;
    const out = try d.arena.alloc(entity.Frame, right.frames.len);
    for (out, right.frames, left.frames) |*f, r, l| {
        if (r.address != l.address or r.mirrored == l.mirrored) return error.BadData;
        f.* = .{
            .frame = try d.frameName(r.address),
            .ticks = right.timing,
            .flip = r.mirrored,
            .body = try d.box(0, r.body, l.body, name, "body"),
            .attack = try d.box(1, r.attack, l.attack, name, "attack"),
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
    try d.number("thrown_x", try immediate(rom, 0xA26C, &.{ 0x20, 0x3C }, 4), "ROM 0x0A26C: move.l #N,d0");
    try d.number("thrown_up", try immediate(rom, 0xA272, &.{ 0x22, 0x3C }, 4), "ROM 0x0A272: move.l #N,d1");
    try d.number("thrown_slide", try moveByte(rom, 0xA2C4, 80), "ROM 0x0A2C4: move.b #N,(80,a0)");
    if (rom[0xA2C0] & 0xF1 != 0x51 or rom[0xA2C1] != 0x68) return error.BadData;
    try d.number("thrown_hurt", @as(i32, rom[0xA2C0] >> 1) & 7, "ROM 0x0A2C0: subq.w #N,(50,a0) (thrown off a hold)");
    if (rom[0xA338] & 0xF1 != 0x51 or rom[0xA339] != 0x68) return error.BadData;
    try d.number("slam_hurt", @as(i32, rom[0xA338] >> 1) & 7, "ROM 0x0A338: subq.w #N,(50,a0) (slammed off a hold)");
    try d.number("slam_ticks", try moveByte(rom, 0xA300, 80), "ROM 0x0A300: move.b #N,(80,a0)");
    try d.number("slammed_x", try immediate(rom, 0xA358, &.{ 0x21, 0x7C }, 4), "ROM 0x0A358: move.l #N,(28,a0)");
    try d.number("slammed_up", try immediate(rom, 0xA360, &.{ 0x21, 0x7C }, 4), "ROM 0x0A360: move.l #N,(36,a0)");
    try d.number("grab_height", try immediate(rom, 0xAAF6, &.{ 0x0C, 0x42 }, 2), "ROM 0x0AAF6: cmpi.w #N,d2");
    // Its heading toward a point (0x982C) takes the sine and cosine of a slope from the table
    // at 0x2705E: the world computes the same table (world/fixed.zig), checked here.
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
/// approaches by the way they are placed, their punch.
pub fn galsia(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try begin(arena, rom, 0x22, "galsia", &.{.{ .name = "punch", .entry = 10 }});
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
    return finish(&d, "galsia", 0x22, "galsia", "Galsia (handler 0xDD78)");
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
    try d.number("hold_place", -(try moveq(rom, 0xE744, 0)), "ROM 0x0E744: moveq #-N,d0");
    try d.number("hold_ends", try frameCompared(rom, 0xE7A0), "ROM 0x0E7A0: cmpi.b #N,(10,a0)");
    if (try frameTicksCompared(rom, 0xE77C) != 1) return error.BadData;
    try d.number_notes.print(arena, "; the throw at its first frame's last tick: ROM 0x0E77C: cmpi.b #1,(13,a0)", .{});
    try d.sound("slide", @bitCast(@as(i8, @intCast(try moveq(rom, 0xE850, 7)))));
    return finish(&d, "signal", 0x24, "signal", "Signal (handler 0xE4D2)");
}

/// `addq` or `subq` at `at`, whose opcode less its count is `base`: the count (0 is 8).
fn quick(rom: []const u8, at: u32, base: u16) Error!i32 {
    const op = u16be(rom, at);
    if (op & 0xF1FF != base) return error.BadData;
    const n: i32 = (op >> 9) & 7;
    return if (n == 0) 8 else n;
}

/// `cmpi.b #N,(13,a0)`: a frame's ticks left compared.
fn frameTicksCompared(rom: []const u8, at: u32) Error!i32 {
    if (u16be(rom, at) != 0x0C28 or rom[at + 2] != 0 or u16be(rom, at + 4) != 13) return error.BadData;
    return rom[at + 3];
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try galsia(arena, rom));
    try out.append(arena, try stalker(arena, rom));
    try out.append(arena, try signal(arena, rom));
}

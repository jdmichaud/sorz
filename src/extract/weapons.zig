//! The weapons (docs/content.md, `entities/NAME.json`): each a definition read from its animation
//! set (its poses: lying, level, slanted, spinning, upright, blinking out) and from the immediate
//! values of the code that runs it (sor-remaster's obj/weapon.zig, handlers 0x5C1E, 0x61F6,
//! 0x6226), with the place of each in its provenance; and the hands of their holders: where an
//! enemy's frame puts the weapon it holds (the table at 0x60A0, sor-remaster's 0x5E68).
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");

const u16be = rom_mod.u16be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const moveByte = entities.moveByte;
const readAnimation = entities.readAnimation;
const moveq = entities.moveq;

/// A weapon's poses, by the original's animation number / 4 (its sets' entries in pairs, right
/// and left); the knife has no upright pose.
const poses = [_][]const u8{ "lying", "level", "slanted", "spinning", "upright", "blinking" };

/// The pose of the original's animation number `anim` (bit 1, the mirror image, cleared).
fn poseName(anim: u8) Error![]const u8 {
    if (anim & 3 != 0 or anim / 4 >= poses.len) return error.BadData;
    return poses[anim / 4];
}

/// The frames of the weapon's entry `entry` (facing right) with the next one's (facing left),
/// each shown for the animation's timing byte (a static pose's, 0, as one tick that stays).
fn weaponFrames(d: *Def, name: []const u8, entry: u32) Error![]entity.Frame {
    const right = try readAnimation(d.arena, d.rom, d.set, entry);
    // Blinking out it shows one way only (its entry has no mirror image after it).
    if (std.mem.eql(u8, name, "blinking")) {
        const out = try d.arena.alloc(entity.Frame, right.frames.len);
        for (out, right.frames) |*f, r| {
            if (r.mirrored or r.body != 0 or r.attack != 0) return error.BadData;
            f.* = .{ .frame = try d.frameName(r.address), .ticks = @max(right.timing, 1) };
        }
        return out;
    }
    const left = try readAnimation(d.arena, d.rom, d.set, entry + 1);
    if (right.frames.len != left.frames.len) return error.BadData;
    const out = try d.arena.alloc(entity.Frame, right.frames.len);
    for (out, right.frames, left.frames) |*f, r, l| {
        if (r.address != l.address or r.mirrored == l.mirrored) return error.BadData;
        f.* = .{
            .frame = try d.frameName(r.address),
            .ticks = @max(right.timing, 1),
            .flip = r.mirrored,
            .body = try d.box(0, r.body, l.body, name, "body"),
            .attack = try d.box(1, r.attack, l.attack, name, "attack"),
        };
    }
    return out;
}

const Weapon = struct {
    name: []const u8,
    behaviour: []const u8,
    set: u32,
    prefix: []const u8,
    /// `move.b #N,(52,a0)`: its power, in its start (0x5C46, 0x620A, 0x623A).
    power_at: u32,
    what: []const u8,
    /// Its type (8 to 12).
    kind: u8,
    /// Its own numbers besides the weapons' (the knife's flight).
    own: ?*const fn (d: *Def) Error!void = null,
};

/// The weapon `w`: its poses, its power, how it lasts and falls.
fn weapon(arena: std.mem.Allocator, rom: []const u8, w: Weapon) Error!entity.Definition {
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "weapons", .prefix = w.prefix, .set = w.set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, w.set) };
    for (poses, 0..) |pose, k| {
        const entry: u32 = 2 * @as(u32, @intCast(k));
        // A pose a weapon has not (the knife upright): its entry is empty.
        if (rom_mod.s16be(rom, w.set + 2 * entry) == 0) continue;
        try d.animations.append(arena, .{ .name = pose, .loop = true, .frames = try weaponFrames(&d, pose, entry) });
    }
    try d.number("power", try moveByte(rom, w.power_at, 52), try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: move.b #N,(52,a0)", .{w.power_at}));
    try d.number("uses", try immediate(rom, 0x5C66, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x05C66: cmpi.b #N,(80,a0) (its pick-ups)");
    try d.number("blink", try moveByte(rom, 0x5C90, 86), "ROM 0x05C90: move.b #N,(86,a0)");
    try d.number("drop", (try immediate(rom, 0x5E4A, &.{ 0x31, 0x7C }, 2)) << 16, "ROM 0x05E4A: move.w #N,(36,a0)");
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A66: out of a hand)");
    // In a player's hand: held long (the holder's stand and walk the long weapon's, 0x2E5A by
    // type from 8: those that add 4 to the animation), swung (B swings it, 0x309C).
    const table: u32 = 0x2E5A;
    const step = rom_mod.s16be(rom, table + 2 * (@as(u32, w.kind) - 8));
    if (rom_mod.u16be(rom, 0x2E66) != 0x5868) return error.BadData;
    try d.number("long", @intFromBool(table + @as(u32, @intCast(step)) == 0x2E66), "ROM 0x02E5A (by type from 8: those that add 4 to the holder's stand and walk, 0x02E66)");
    const swung = w.kind == try immediate(rom, 0x309C, &.{ 0x0C, 0x01, 0x00 }, 1) or w.kind == try immediate(rom, 0x30A2, &.{ 0x0C, 0x01, 0x00 }, 1);
    try d.number("swung", @intFromBool(swung), "ROM 0x0309C, 0x030A2: cmpi.b #N,d1 (the types B swings)");
    const thrown = w.kind == try immediate(rom, 0x2204, &.{ 0x0C, 0x29, 0x00 }, 1) or w.kind == try immediate(rom, 0x220C, &.{ 0x0C, 0x29, 0x00 }, 1);
    try d.number("thrown", @intFromBool(thrown), "ROM 0x02204, 0x0220C: cmpi.b #N,(0,a1) (the types the plain blow throws)");
    if (w.own) |own| try own(&d);
    return .{
        .name = w.name,
        .provenance = try std.fmt.allocPrint(arena, "{s}: the animation set at ROM 0x{X:0>5} (its poses by entry pair), the boxes (0x1A68E, 0x1AB8E); gravity ROM 0x05CE8: addi.l #N,(36,a0){s}", .{ w.what, w.set, d.number_notes.items }),
        .family = .weapon,
        .team = .neutral,
        .behaviour = w.behaviour,
        .gravity = try immediate(rom, 0x5CE8, &.{ 0x06, 0xA8 }, 4),
        .numbers = d.numbers.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// The knife's flight, thrown (0x5D84: its speed across, how far ahead of its holder and below
/// its hand it starts; 0x5D34: it flies while on the screen, wider than the screen's sides by
/// the drawing's offset, 0x97E6), and its bounce off a wall (0x5D4E: a quarter of its speed back;
/// 0x5DEA: its gravity; down, it is worn out).
fn knifeFlight(d: *Def) Error!void {
    const rom = d.rom;
    try d.number("throw_speed", (try moveq(rom, 0x5D8C, 0)) << 16, "ROM 0x05D8C: moveq #N,d0, its speed's whole pixels");
    try d.number("throw_ahead", try moveq(rom, 0x5D8E, 1), "ROM 0x05D8E: moveq #N,d1");
    try d.number("throw_below", try immediate(rom, 0x5DBA, &.{ 0x06, 0x68 }, 2), "ROM 0x05DBA: addi.w #N,(24,a0)");
    const drawn = try immediate(rom, 0xAF6E, &.{ 0x06, 0x42 }, 2);
    try d.number("flight_from", try immediate(rom, 0x97E8, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x097E8: cmpi.w #N,(40,a0), less 0xAF6E's offset");
    try d.number("flight_to", try immediate(rom, 0x97F0, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x097F0: cmpi.w #N,(40,a0), less 0xAF6E's offset (excluded)");
    // asr.l #N,d0: 1110 NNN0 1000 0000.
    const asr = u16be(rom, 0x5D5A);
    if (asr & 0xF1FF != 0xE080) return error.BadData;
    try d.number("bounce_shift", (asr >> 9) & 7, "ROM 0x05D5A: asr.l #N,d0 (its speed back, divided by 2^N)");
    try d.number("bounce_gravity", try immediate(rom, 0x5DEA, &.{ 0x06, 0xA8 }, 4), "ROM 0x05DEA: addi.l #N,(36,a0)");
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try weapon(arena, rom, .{ .name = "knife", .behaviour = "knife", .set = 0x6FA06, .prefix = "knife", .power_at = 0x5C54, .what = "the knife, type $08 (handler 0x5C1E)", .kind = 8, .own = knifeFlight }));
    try out.append(arena, try weapon(arena, rom, .{ .name = "pipe", .behaviour = "weapon", .set = 0x6FA9A, .prefix = "pipe", .power_at = 0x6214, .what = "the pipe, type $0A (handler 0x61F6)", .kind = 0x0A }));
    try out.append(arena, try weapon(arena, rom, .{ .name = "pipe_b", .behaviour = "weapon", .set = 0x6FB5A, .prefix = "pipe_2", .power_at = 0x6244, .what = "the second pipe, type $0B (handler 0x6226)", .kind = 0x0B }));
}

// --- The hands --------------------------------------------------------------------------------------

/// Where a player holding a weapon puts it, by the player's armed animation (a word offset per
/// animation pair from $28, 0x5FD6..), by character (a byte offset), 3 bytes a frame: across
/// ahead of the player, height downward, the weapon's animation (bit 0: its blow is under way;
/// bit 1: turned the other way from the player's; bit 7: the player drawn behind the others at
/// its depth, 4.4 of the spec, not kept).
const player_hands = 0x5FC8;

/// The hands of the frames of `d`'s player animation `name`, the `index`th of the armed ones
/// ($28 + 4 index facing right), for character `character`.
pub fn playerHands(d: *Def, name: []const u8, index: u8, character: u8) Error!void {
    const frames = @constCast(d.animations.items[d.animationIndex(name) orelse return error.BadData].frames);
    const sub: u32 = @intCast(@as(i32, player_hands) + rom_mod.s16be(d.rom, player_hands + 2 * @as(u32, index)));
    const list = sub + d.rom[sub + character];
    for (frames, 0..) |*f, j| {
        const e = list + 3 * @as(u32, @intCast(j));
        const shown = d.rom[e + 2];
        f.hand = .{
            .x = entities.s8(d.rom, e),
            .height = entities.s8(d.rom, e + 1),
            .pose = try poseName(shown & 0x7C),
            .turned = shown & 2 != 0,
            .strikes = shown & 1 != 0,
        };
    }
    try d.number_notes.print(d.arena, "; {s}'s hands: ROM 0x{X:0>5} (0x5FC8)", .{ name, list });
}

/// Where an enemy holding a weapon puts it, by the enemy's animation from $1C (a word offset by
/// animation pair to a list of 3 bytes a frame: across ahead of the enemy, height downward, the
/// weapon's animation, whose bit 0 puts it a pixel in front of the enemy in depth, else behind).
const enemy_hands = 0x60A0;

/// The hands of the frames of `d`'s animation `name`, which is the original's animation number
/// `anim` facing right: each frame's weapon place and pose.
pub fn enemyHands(d: *Def, name: []const u8, anim: u8) Error!void {
    if (anim < 0x1C or anim & 3 != 0) return error.BadData;
    const index = d.animationIndex(name) orelse return error.BadData;
    const frames = @constCast(d.animations.items[index].frames);
    const d0: u32 = anim - 0x1C;
    const list: u32 = @intCast(@as(i32, enemy_hands) + rom_mod.s16be(d.rom, enemy_hands + d0 / 2));
    for (frames, 0..) |*f, j| {
        const e = list + 3 * @as(u32, @intCast(j));
        const shown = d.rom[e + 2];
        f.hand = .{
            .x = entities.s8(d.rom, e),
            .height = entities.s8(d.rom, e + 1),
            .pose = try poseName(shown & 0xFE),
            .front = shown & 1 != 0,
        };
    }
    try d.number_notes.print(d.arena, "; {s}'s hands: ROM 0x{X:0>5} (0x60A0, animation {d})", .{ name, list, anim });
}

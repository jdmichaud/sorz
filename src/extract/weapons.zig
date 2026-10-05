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

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try weapon(arena, rom, .{ .name = "pipe", .behaviour = "weapon", .set = 0x6FA9A, .prefix = "pipe", .power_at = 0x6214, .what = "the pipe, type $0A (handler 0x61F6)" }));
    try out.append(arena, try weapon(arena, rom, .{ .name = "pipe_b", .behaviour = "weapon", .set = 0x6FB5A, .prefix = "pipe_2", .power_at = 0x6244, .what = "the second pipe, type $0B (handler 0x6226)" }));
}

// --- The hands --------------------------------------------------------------------------------------

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

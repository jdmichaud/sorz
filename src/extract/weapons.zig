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
const u32be = rom_mod.u32be;
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
    // Blinking out it shows one way only (its entry has no mirror image after it), and is
    // neither taken nor strikes: its frames' boxes (the bat's lying one has some) are left out.
    if (std.mem.endsWith(u8, name, "blinking")) {
        const out = try d.arena.alloc(entity.Frame, right.frames.len);
        for (out, right.frames) |*f, r| {
            if (r.mirrored) return error.BadData;
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
    /// The poses its set holds (the bottle's set holds its splash and shards where the others
    /// hold their level pose).
    poses: []const []const u8 = &poses,
};

/// The weapon `w`: its poses, its power, how it lasts and falls.
fn weapon(arena: std.mem.Allocator, rom: []const u8, w: Weapon) Error!entity.Definition {
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "weapons", .prefix = w.prefix, .set = w.set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, w.set) };
    for (poses, 0..) |pose, k| {
        const entry: u32 = 2 * @as(u32, @intCast(k));
        // A pose a weapon has not (the knife upright): its entry is empty.
        if (rom_mod.s16be(rom, w.set + 2 * entry) == 0) continue;
        for (w.poses) |p| {
            if (std.mem.eql(u8, p, pose)) break;
        } else continue;
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
    // B stabs at a thing ahead with the types B tests for none of its own blows (0x30C4): the
    // swung ones swing, the bottle and the bat strike plainly.
    var own_blow = swung;
    for ([_]u32{ 0x30AA, 0x30B0 }) |at| own_blow = own_blow or w.kind == try immediate(rom, at, &.{ 0x0C, 0x01, 0x00 }, 1);
    try d.number("stabs", @intFromBool(!own_blow), "ROM 0x030C4: the types B tests for none of its blows (0x0309C, 0x030A2, 0x030AA, 0x030B0: cmpi.b #N,d1) stab at a thing ahead");
    // In a player's hand, the type 0x5F5A tests shows its lying pose whatever the hand's, its
    // holder's way.
    try d.number("hand_lying", @intFromBool(w.kind == try immediate(rom, 0x5F5A, &.{ 0x0C, 0x28, 0x00 }, 1)), "ROM 0x05F5A: cmpi.b #N,(0,a0) (in a player's hand, its pose the lying one, turned no way)");
    if (w.own) |own| try own(&d);
    return .{
        .name = w.name,
        .provenance = try std.fmt.allocPrint(arena, "{s}: the animation set at ROM 0x{X:0>5} (its poses by entry pair), the boxes (0x1A68E, 0x1AB8E); gravity ROM 0x05CE8: addi.l #N,(36,a0){s}", .{ w.what, w.set, d.number_notes.items }),
        .family = .weapon,
        .team = .neutral,
        .behaviour = w.behaviour,
        .gravity = try immediate(rom, 0x5CE8, &.{ 0x06, 0xA8 }, 4),
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// The bat's splintering (0x614E): held, at its first blow struck, its poses become the
/// splintered bat's (the set at 0x6FCAE, `broken_` and the pose), with a sound and three splinters
/// at its place (0x7EEA's pool), flying up and back from the side it faces (0x61B2: their speeds
/// up, 0x61B8: across, words; the other way unless it faces left, 0x619C).
fn batSplinters(d: *Def) Error!void {
    const rom = d.rom;
    const broken: u32 = @bitCast(try immediate(rom, 0x6160, &.{ 0x21, 0x7C }, 4));
    const own_set = d.set;
    const own_prefix = d.prefix;
    const own_frames = d.frame_addresses;
    d.set = broken;
    d.prefix = "bat_broken";
    d.frame_addresses = try sprites.frameAddresses(d.arena, rom, broken);
    for (poses, 0..) |pose, k| {
        const entry: u32 = 2 * @as(u32, @intCast(k));
        if (rom_mod.s16be(rom, broken + 2 * entry) == 0) continue;
        const name = try std.fmt.allocPrint(d.arena, "broken_{s}", .{pose});
        try d.animations.append(d.arena, .{ .name = name, .loop = true, .frames = try weaponFrames(d, name, entry) });
    }
    d.set = own_set;
    d.prefix = own_prefix;
    d.frame_addresses = own_frames;
    try d.number_notes.print(d.arena, "; broken_*: the splintered bat's set at ROM 0x{X:0>5} (0x6160: move.l #N,(4,a0))", .{broken});
    try d.sound("splinter", @bitCast(@as(i8, @intCast(try moveq(rom, 0x6168, 7)))));
    try d.number("splinters", try moveq(rom, 0x616E, 6) + 1, "ROM 0x0616E: moveq #N,d6 (dbf: N + 1 splinters)");
    var up: [3]i32 = undefined;
    var across: [3]i32 = undefined;
    for (0..3) |k| {
        up[k] = rom_mod.s16be(rom, 0x61B2 + 2 * @as(u32, @intCast(k)));
        across[k] = rom_mod.s16be(rom, 0x61B8 + 2 * @as(u32, @intCast(k)));
    }
    try d.table("splinter_up", &up, "ROM 0x061B2 (words, whole pixels a tick)");
    try d.table("splinter_across", &across, "ROM 0x061B8 (words, whole pixels a tick; facing right, the other way)");
}

/// The bat's splinter (type $1E, 0x61BE): no shadow, the animation at entry 2 of the set at
/// 0x6FD42 (0x61D4, animation 4); it falls (0x61E0: its gravity) and goes out of the screen as
/// the drawing deletes an object (0xAF46: past 0x500 across or below 0x200 down, its drawn place
/// less the drawing's offsets, 0xAF6E and 0xAF72; above 0x10).
fn splinter(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x61D4, &.{ 0x22, 0x7C }, 4));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "weapons", .prefix = "splinters", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    const raw = try readAnimation(arena, rom, set, 2);
    const frames = try arena.alloc(entity.Frame, raw.frames.len);
    for (frames, raw.frames) |*f, r| f.* = .{ .frame = try d.frameName(r.address), .ticks = @max(raw.timing, 1), .flip = r.mirrored };
    try d.animations.append(arena, .{ .name = "falling", .loop = true, .frames = frames });
    const dx = try immediate(rom, 0xAF6E, &.{ 0x06, 0x42 }, 2);
    const dy = try immediate(rom, 0xAF72, &.{ 0x06, 0x43 }, 2);
    try d.number("gone_right", try immediate(rom, 0xAFA4, &.{ 0x0C, 0x42 }, 2) - dx, "ROM 0x0AFA4: cmpi.w #N,d2, less 0xAF6E's offset");
    try d.number("gone_below", try immediate(rom, 0xAFB2, &.{ 0x0C, 0x43 }, 2) - dy, "ROM 0x0AFB2: cmpi.w #N,d3, less 0xAF72's offset");
    try d.number("gone_above", try immediate(rom, 0xAFBA, &.{ 0x0C, 0x43 }, 2) - dy, "ROM 0x0AFBA: cmpi.w #N,d3, less 0xAF72's offset");
    try d.number("gone_left", try immediate(rom, 0xAFA0, &.{ 0x30, 0x3C }, 2) - dx, "ROM 0x0AFA0: move.w #N,d0, less 0xAF6E's offset");
    return .{
        .name = "bat_splinter",
        .provenance = try std.fmt.allocPrint(arena, "the bat's splinter, type $1E (handler 0x61BE): the animation set at ROM 0x{X:0>5} (entry 2); gravity ROM 0x061E0: addi.l #N,(36,a0){s}", .{ set, d.number_notes.items }),
        .family = .effect,
        .team = .neutral,
        .behaviour = "bat_splinter",
        .gravity = try immediate(rom, 0x61E0, &.{ 0x06, 0xA8 }, 4),
        .numbers = d.numbers.items,
        .animations = d.animations.items,
    };
}

/// The bottle's breaking (0x6256): thrown (0x62DA: its speed across and up, how far ahead of its
/// hand and below it starts), it falls (0x6312: its gravity) until a hit it gave or took or the
/// floor breaks it; then it hides (0x6328), its splash (its set's entry 2) shows a while in the
/// weapons' places, and its shards (entry 3, five frames, each with a blow) come two ticks apart
/// at their places around it (0x63C4) in the last free place below the effects' (0x7E92), each
/// going at its last frame (0x63E4).
fn bottleBreaking(d: *Def) Error!void {
    const rom = d.rom;
    try d.animations.append(d.arena, .{ .name = "splash", .loop = true, .frames = try entryOf(d, "splash", 2) });
    try d.animations.append(d.arena, .{ .name = "shard", .loop = true, .frames = try entryOf(d, "shard", 3) });
    try d.number("throw_speed", (try moveq(rom, 0x62E4, 0)) << 16, "ROM 0x062E4: moveq #N,d0, its speed's whole pixels");
    try d.number("throw_ahead", try moveq(rom, 0x62E6, 1), "ROM 0x062E6: moveq #N,d1");
    if (u16be(rom, 0x62FC) != 24) return error.BadData;
    try d.number("throw_below", try immediate(rom, 0x62F8, &.{ 0x06, 0x68 }, 2), "ROM 0x062F8: addi.w #N,(24,a0)");
    if (u16be(rom, 0x6306) != 36) return error.BadData;
    try d.number("throw_up", (try immediate(rom, 0x6302, &.{ 0x31, 0x7C }, 2)) << 16, "ROM 0x06302: move.w #N,(36,a0), whole pixels");
    try d.number("fall_gravity", try immediate(rom, 0x6318, &.{ 0x06, 0xA8 }, 4), "ROM 0x06318: addi.l #N,(36,a0)");
    try d.number("first_shard", try moveByte(rom, 0x6334, 86), "ROM 0x06334: move.b #N,(86,a0) (the ticks to the first shard)");
    if (u16be(rom, 0x635E) != 0x1D7C or rom[0x6360] != 0 or u16be(rom, 0x6362) != 86) return error.BadData;
    try d.number("splash_ticks", rom[0x6361], "ROM 0x0635E: move.b #N,(86,a6)");
    try d.number("shard_gap", try moveByte(rom, 0x6378, 86), "ROM 0x06378: move.b #N,(86,a0)");
    if (u16be(rom, 0x63B8) != 88) return error.BadData;
    const shards = try immediate(rom, 0x63B4, &.{ 0x0C, 0x68 }, 2) + 1;
    if (shards != 8) return error.BadData;
    try d.number("shards", shards, "ROM 0x063B4: cmpi.w #N-1,(88,a0)");
    try d.number("shard_last_frame", try entities.frameCompared(rom, 0x63E4), "ROM 0x063E4: cmpi.b #N,(10,a0)");
    // Thrown, it keeps its mark of being thrown ($51), which the knife's throw clears (0x5DCE):
    // its holder's throwing frame throws it again at each tick (0x221C), with the throw's sound.
    if (u32be(rom, 0x5DCE) != 0x42280051) return error.BadData;
    var clears = false;
    var at: u32 = 0x62DA;
    while (at < 0x6312) : (at += 2) clears = clears or u32be(rom, at) == 0x42280051;
    try d.number("rethrown", @intFromBool(!clears), "ROM 0x062DA to 0x06312: its throw, without the knife's clr.b (81,a0) (0x05DCE)");
    var x: [8]i32 = undefined;
    var h: [8]i32 = undefined;
    for (0..8) |k| {
        x[k] = rom_mod.s16be(rom, 0x63C4 + 4 * @as(u32, @intCast(k)));
        h[k] = rom_mod.s16be(rom, 0x63C6 + 4 * @as(u32, @intCast(k)));
    }
    try d.table("shard_x", &x, "ROM 0x063C4: each shard's first word, across from the bottle");
    try d.table("shard_height", &h, "ROM 0x063C4: each shard's second word, in height from the bottle");
}

/// The frames of entry `entry` of `d`'s set, facing right only (the bottle's splash and shards),
/// with their blows (the right-facing boxes: they never face left).
fn entryOf(d: *Def, name: []const u8, entry: u32) Error![]entity.Frame {
    const raw = try readAnimation(d.arena, d.rom, d.set, entry);
    const out = try d.arena.alloc(entity.Frame, raw.frames.len);
    for (out, raw.frames) |*f, r| {
        if (r.mirrored) return error.BadData;
        f.* = .{
            .frame = try d.frameName(r.address),
            .ticks = @max(raw.timing, 1),
            .body = try d.box(0, r.body, r.body, name, "body"),
            .attack = try d.box(1, r.attack, r.attack, name, "attack"),
        };
    }
    return out;
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
    try out.append(arena, try weapon(arena, rom, .{ .name = "bat", .behaviour = "bat", .set = 0x6FC1A, .prefix = "bat", .power_at = 0x613C, .what = "the baseball bat, type $09 (handler 0x6114)", .kind = 0x09, .own = batSplinters }));
    try out.append(arena, try weapon(arena, rom, .{ .name = "bottle", .behaviour = "bottle", .set = @bitCast(try immediate(rom, 0x6280, &.{ 0x22, 0x7C }, 4)), .prefix = "splinters", .power_at = 0x627A, .what = "the bottle, type $0C (handler 0x6256; its set, ROM 0x06280: movea.l #N,a1)", .kind = 0x0C, .own = bottleBreaking, .poses = &.{ "lying", "blinking" } }));
    try out.append(arena, try splinter(arena, rom));
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

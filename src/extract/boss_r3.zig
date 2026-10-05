//! Round 3's boss (docs/content.md, `entities/boss_r3.json`, `boss_r3_part.json`,
//! `boss_r3_helper.json`): type $30, his handler 0x143D0, with his part (type $31, 0x15794) and,
//! for two players, the helper that watches a pair of them (type $39, 0x14318); sor-remaster's
//! obj/boss_30.zig. His code is his own (0x1292E to 0x15846), not the other bosses' common body:
//! each definition's numbers are read from the immediate values of that code, the place of each
//! in its provenance.
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");
const enemies = @import("enemies.zig");

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const s16be = rom_mod.s16be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const moveByte = entities.moveByte;
const moveq = entities.moveq;
const quick = entities.quick;
const readAnimation = entities.readAnimation;

/// His animation set (0x144EE: move.l #N,(4,a1), his part's; 0x1453C his own).
const set = 0x34B94;
/// His health and power by the options' level, two bytes each (0x1455C).
const strengths = 0x145AE;
/// His part's places from him, across and in height (words) by an index (0x1569C).
const part_offsets = 0x35054;
/// By the holder's character ($50 of a player), the offsets of the one it throws by its frame,
/// across then in height (0x15220): a word offset to each list from the table.
const throw_offsets = 0x35060;
/// The state a grab sends him to, by the holder's request (its $7D); negative: none (0x154E0).
const grab_states = 0x155B2;
/// The hug's stages: their ticks (bytes), then the one hugged's moves across and in height
/// (words, 0x14E5E).
const hug_ticks = 0x14E8E;
const hug_x = 0x14E92;
const hug_height = 0x14E9A;

/// `move.l #N,(D,a0)`: the long written, its displacement checked.
fn movedLong(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at + 6) != displacement) return error.BadData;
    return immediate(rom, at, &.{ 0x21, 0x7C }, 4);
}

/// `move.w #N,(D,a0)`: the word written (sign extended), its displacement checked.
fn movedWord(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at) != 0x317C or u16be(rom, at + 4) != displacement) return error.BadData;
    return s16be(rom, at + 2);
}

/// `cmpi.w #N,dK` or `cmpi.w #N,(D,a0)`: the word compared.
fn comparedWord(rom: []const u8, at: u32) Error!i32 {
    const op = u16be(rom, at);
    if (op & 0xFFF8 != 0x0C40 and op != 0x0C68) return error.BadData;
    return s16be(rom, at + 2);
}

/// `move.l #N,d0`: the long moved.
fn longMoved(rom: []const u8, at: u32) Error!i32 {
    return immediate(rom, at, &.{ 0x20, 0x3C }, 4);
}

/// `subq.w #N,(50,a0)`: the health taken.
fn healthTaken(rom: []const u8, at: u32) Error!i32 {
    if (u16be(rom, at + 2) != 50) return error.BadData;
    return quick(rom, at, 0x5168);
}

/// The frames of animation `word` (facing right: its entry's bit 1 clear) with the next entry's
/// (facing left), each shown for the animation's timing (a timing of 0: still, its frames set
/// by his code), their boxes.
fn frames(d: *Def, name: []const u8, word: i32) Error![]entity.Frame {
    if (word < 0 or @mod(word, 2) != 0) return error.BadData;
    const entry: u32 = @intCast(@divExact(word, 2) & ~@as(i32, 1));
    const right = try readAnimation(d.arena, d.rom, d.set, entry);
    const left = try readAnimation(d.arena, d.rom, d.set, entry + 1);
    if (right.frames.len != left.frames.len or right.timing != left.timing) return error.BadData;
    const out = try d.arena.alloc(entity.Frame, right.frames.len);
    for (out, right.frames, left.frames) |*f, r, l| {
        if (r.address != l.address or r.mirrored == l.mirrored) return error.BadData;
        const flipped = r.mirrored;
        // A box of a negative width facing left (box 48: 0 over -32, the hug's last frame's
        // body, the slam's blow), which the original's test meets only with a box spanning it
        // whole, as none does: none, either way (his hug and his slam look at no blow; the
        // slam's on his target is undone, a second player's aside).
        f.* = .{
            .frame = try d.frameName(r.address),
            .ticks = @max(right.timing, 1),
            .flip = flipped,
            .body = if (inverted(d, r.body, l.body)) null else if (flipped) try d.box(0, l.body, r.body, name, "body") else try d.box(0, r.body, l.body, name, "body"),
            .attack = if (inverted(d, r.attack, l.attack)) null else if (flipped) try d.box(1, l.attack, r.attack, name, "attack") else try d.box(1, r.attack, l.attack, name, "attack"),
        };
    }
    return out;
}

/// Whether either of a frame's boxes (its two sides') spans a negative width across.
fn inverted(d: *const Def, right: u8, left: u8) bool {
    for ([_]u8{ right, left }) |b| {
        if (b == 0) continue;
        const x = entities.tableBox(d.rom, d.box_table, b).x;
        if (x.to < x.from) return true;
    }
    return false;
}

/// The frames of entry `entry` alone, for the side `left` (a part whose two sides show frames of
/// their own), without boxes.
fn sideFrames(d: *Def, entry: u32, left: bool) Error![]entity.Frame {
    const a = try readAnimation(d.arena, d.rom, d.set, entry);
    const out = try d.arena.alloc(entity.Frame, a.frames.len);
    for (out, a.frames) |*f, r| {
        if (r.attack != 0 or r.body != 0) return error.BadData;
        // Facing left, a frame shows mirrored when its flag and the side differ.
        f.* = .{ .frame = try d.frameName(r.address), .ticks = @max(a.timing, 1), .flip = r.mirrored != left };
    }
    return out;
}

fn def(arena: std.mem.Allocator, rom: []const u8) Error!Def {
    if (u32be(rom, 0x1453E) != set or u32be(rom, 0x144F0) != set) return error.BadData;
    return .{ .arena = arena, .rom = rom, .dir = "round3_boss", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
}

/// Round 3's boss: he walks to his target's depth, sizes it up, backs off or charges, hugs a
/// player he catches, takes blows and holds, is knocked away, thrown, slammed; his knockout ends
/// the round (behaviours/boss_r3.zig).
pub fn boss(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try def(arena, rom);
    if (try moveq(rom, 0x14ECA, 0) + 2 != try moveq(rom, 0x14EBC, 0)) return error.BadData;
    if (try moveq(rom, 0x14F90, 0) + 2 != try moveq(rom, 0x14F96, 0)) return error.BadData;
    const anims = [_]struct { name: []const u8, word: i32 }{
        .{ .name = "walk", .word = try moveq(rom, 0x15740, 0) },
        .{ .name = "charge", .word = try moveq(rom, 0x14BE8, 0) },
        .{ .name = "slam", .word = try moveq(rom, 0x14CB6, 0) },
        .{ .name = "hug", .word = try moveq(rom, 0x14D46, 0) },
        .{ .name = "struck", .word = try moveq(rom, 0x1477C, 0) },
        .{ .name = "knocked", .word = try moveq(rom, 0x14B2A, 0) },
        .{ .name = "thrown_over", .word = try moveq(rom, 0x14ECA, 0) },
        .{ .name = "get_up", .word = try moveq(rom, 0x14A8C, 0) },
        .{ .name = "thrown", .word = try moveq(rom, 0x14F90, 0) },
    };
    for (anims) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try frames(&d, an.name, an.word) });

    var strength: [8]i32 = undefined;
    for (&strength, 0..) |*v, k| v.* = rom[strengths + k];
    if (u16be(rom, 0x14562) != 0x117B or u16be(rom, 0x14568) != 0x117B) return error.BadData;
    try d.table("strength", &strength, "ROM 0x145AE: by the level, his health then his power (0x1455C)");
    try d.number("variant_power", try quick(rom, 0x1457A, 0x5028), "ROM 0x1457A: addq.b #N,(52,a0) (a variant's, its entry's low nibble)");
    try d.number("variant_health", try quick(rom, 0x1458A, 0x5068), "ROM 0x1458A: addq.w #N,(50,a0) (a variant of palette variant 2)");
    var offsets: [6]i32 = undefined;
    for (&offsets, 0..) |*v, k| v.* = s16be(rom, part_offsets + 2 * @as(u32, @intCast(k)));
    try d.table("part_offsets", &offsets, "ROM 0x35054: his part's places, across then in height, by an index (0x1569C)");
    var grabs: [12]i32 = undefined;
    for (&grabs, 0..) |*v, k| v.* = @as(i8, @bitCast(rom[grab_states + k]));
    try d.table("grab_states", &grabs, "ROM 0x155B2: the state a grab sends him to by the holder's request (negative: none, 0x154E0)");
    for ([_][]const u8{ "axel", "adam", "blaze" }, 0..) |who, c| {
        const across: u32 = @intCast(@as(i32, throw_offsets) + s16be(rom, throw_offsets + 2 * @as(u32, @intCast(c))));
        const up: u32 = @intCast(@as(i32, throw_offsets) + s16be(rom, throw_offsets + 2 * @as(u32, @intCast(c)) + 6));
        var xs: [12]i32 = undefined;
        var hs: [12]i32 = undefined;
        for (&xs, &hs, 0..) |*x, *h, k| {
            x.* = s16be(rom, across + 2 * @as(u32, @intCast(k)));
            h.* = s16be(rom, up + 2 * @as(u32, @intCast(k)));
        }
        try d.table(try std.fmt.allocPrint(arena, "throw_x_{s}", .{who}), &xs, "ROM 0x35060: by the holder's character, its rows (thrown over, slammed, thrown) of 4 by its frame (0x15220)");
        try d.table(try std.fmt.allocPrint(arena, "throw_height_{s}", .{who}), &hs, "ROM 0x35066: the same, in height");
    }
    var ht: [4]i32 = undefined;
    var hx: [4]i32 = undefined;
    var hh: [4]i32 = undefined;
    for (&ht, &hx, &hh, 0..) |*t, *x, *h, k| {
        t.* = rom[hug_ticks + k];
        x.* = s16be(rom, hug_x + 2 * @as(u32, @intCast(k)));
        h.* = s16be(rom, hug_height + 2 * @as(u32, @intCast(k)));
    }
    try d.table("hug_ticks", &ht, "ROM 0x14E8E: the hug's stages' ticks (0x14E5E)");
    try d.table("hug_x", &hx, "ROM 0x14E92: the one hugged moved across by stage, against his side");
    try d.table("hug_height", &hh, "ROM 0x14E9A: and in height");

    // Walking (0x1577C), approaching (state 1, 0x145DE) and sizing up (state 2, 0x14648).
    const walk_x = try movedLong(rom, 0x15788, 28);
    if (try movedLong(rom, 0x15780, 32) != walk_x) return error.BadData;
    try d.number("walk_speed", walk_x, "ROM 0x15788: move.l #N,(28,a0); in depth 0x15780");
    const approach = try longMoved(rom, 0x14616);
    if (try longMoved(rom, 0x14668) != approach) return error.BadData;
    try d.number("approach_level", approach >> 16, "ROM 0x14616: move.l #N,d0 (its high word: in depth; 0x14668)");
    try d.number("approach_near", approach & 0xFFFF, "ROM 0x14616: its low word, across");
    try d.number("variant_level", (try longMoved(rom, 0x146B6)) >> 16, "ROM 0x146B6: move.l #N,d0 (a variant's, in depth)");
    try d.number("size_up_ticks", try movedWord(rom, 0x1463A, 84), "ROM 0x1463A: move.w #N,(84,a0)");
    try d.number("back_off_far", try comparedWord(rom, 0x14686), "ROM 0x14686: cmpi.w #N,d0 (beyond, he charges)");
    try d.number("back_off_near", try comparedWord(rom, 0x1468C), "ROM 0x1468C: cmpi.w #N,d0 (within, he charges)");
    // Backing off (state 3, 0x146E2), struck (4 and 5, 0x1476C).
    try d.number("back_off_ticks", try movedWord(rom, 0x14718, 84), "ROM 0x14718: move.w #N,(84,a0)");
    try d.number("struck_ticks", try movedWord(rom, 0x1476C, 84), "ROM 0x1476C: move.w #N,(84,a0); held 0x14A0C");
    if (try movedWord(rom, 0x14A0C, 84) != try movedWord(rom, 0x1476C, 84)) return error.BadData;
    try d.number("shake", try movedWord(rom, 0x14772, 94), "ROM 0x14772: move.w #N,(94,a0) (a shake's step across)");
    try d.number("weapon_hits", try moveByte(rom, 0x147C2, 88), "ROM 0x147C2: move.b #N,(88,a0) (struck by the pepper, state 15)");
    try d.number("weapon_ticks", try movedWord(rom, 0x147C8, 84), "ROM 0x147C8: move.w #N,(84,a0)");
    // Knocked away (state 6, 0x14B00; 0x15604), falling and lying (0x1292E, 0x1296A).
    try d.number("knock_away_x", try movedLong(rom, 0x15614, 28), "ROM 0x15614: move.l #N,(28,a0)");
    try d.number("knock_away_up", try movedLong(rom, 0x1560C, 36), "ROM 0x1560C: move.l #N,(36,a0)");
    try d.number("knock_away_slowing", try movedLong(rom, 0x15604, 94), "ROM 0x15604: move.l #N,(94,a0)");
    try d.number("knocked_gravity", try movedLong(rom, 0x14B30, 98), "ROM 0x14B30: move.l #N,(98,a0)");
    try d.number("falling_gravity", try movedLong(rom, 0x12956, 98), "ROM 0x12956: move.l #N,(98,a0) (from the top)");
    try d.number("bounce_above", try immediate(rom, 0x129AA, &.{ 0x0C, 0xA8 }, 4), "ROM 0x129AA: cmpi.l #N,(36,a0) (falling faster, he bounces)");
    if (u16be(rom, 0x129BC) != 0xE680) return error.BadData;
    try d.number("bounce_shift", 3, "ROM 0x129BC: asr.l #3,d0 (the bounce an eighth of the fall)");
    try d.number("lie_ticks", try movedWord(rom, 0x129D0, 84), "ROM 0x129D0: move.w #N,(84,a0) (landed; thrown, state 14, waits for it)");
    if (try comparedWord(rom, 0x15098) != try movedWord(rom, 0x129D0, 84)) return error.BadData;
    try d.number("knocked_lie_ticks", try movedWord(rom, 0x14B74, 84), "ROM 0x14B74: move.w #N,(84,a0)");
    try d.number("get_up_ticks", try movedWord(rom, 0x14A92, 84), "ROM 0x14A92: move.w #N,(84,a0)");
    // The charge (state 7, 0x14BCE).
    try d.number("charge_speed", try movedLong(rom, 0x14BF6, 28), "ROM 0x14BF6: move.l #N,(28,a0) (turned toward his target, 0x1566E)");
    try d.number("charge_near", try moveq(rom, 0x14C34, 0), "ROM 0x14C34: moveq #N,d0 (across)");
    try d.number("charge_right", try comparedWord(rom, 0x14C54) - 0x80, "ROM 0x14C54: cmpi.w #N+$80,(40,a0) (drawn across)");
    try d.number("charge_left", try comparedWord(rom, 0x14C5E) - 0x80, "ROM 0x14C5E: cmpi.w #N+$80,(40,a0)");
    try d.number("slam_wait", try movedWord(rom, 0x14C8E, 84), "ROM 0x14C8E: move.w #N,(84,a0)");
    try d.number("slam_ticks", try movedWord(rom, 0x14CAC, 84), "ROM 0x14CAC: move.w #N,(84,a0)");
    // Held by a player (state 11, 0x1484E).
    try d.number("held_ahead", try moveq(rom, 0x14878, 0), "ROM 0x14878: moveq #N,d0 (in front of his holder)");
    try d.number("held_ticks", try movedWord(rom, 0x148A8, 84), "ROM 0x148A8: move.w #N,(84,a0)");
    // Thrown over (state 13, 0x14EA2), thrown (state 14, 0x14F46), slammed (state 9, 0x1512E).
    try d.number("thrown_over_ticks", try movedWord(rom, 0x14EEE, 84), "ROM 0x14EEE: move.w #N,(84,a0)");
    try d.number("thrown_up", try movedLong(rom, 0x14FC4, 36), "ROM 0x14FC4: move.l #N,(36,a0)");
    try d.number("thrown_gravity", try movedLong(rom, 0x14FCC, 98), "ROM 0x14FCC: move.l #N,(98,a0); 0x1501E");
    if (try movedLong(rom, 0x1501E, 98) != try movedLong(rom, 0x14FCC, 98)) return error.BadData;
    try d.number("thrown_x", try movedLong(rom, 0x14FD4, 28), "ROM 0x14FD4: move.l #N,(28,a0); 0x14FFE");
    if (try movedLong(rom, 0x14FFE, 28) != try movedLong(rom, 0x14FD4, 28)) return error.BadData;
    try d.number("thrown_slowing", try movedLong(rom, 0x14FDC, 94), "ROM 0x14FDC: move.l #N,(94,a0)");
    try d.number("thrown_over", try moveq(rom, 0x14FFC, 0), "ROM 0x14FFC: moveq #N,d0 (on, at the top)");
    try d.number("thrown_down", try movedLong(rom, 0x15016, 36), "ROM 0x15016: move.l #N,(36,a0)");
    try d.number("thrown_bounce", try movedLong(rom, 0x1507A, 36), "ROM 0x1507A: move.l #N,(36,a0)");
    try d.number("thrown_damage", try healthTaken(rom, 0x150A6), "ROM 0x150A6: subq.w #N,(50,a0)");
    try d.number("thrown_slide", try movedWord(rom, 0x15100, 84), "ROM 0x15100: move.w #N,(84,a0)");
    try d.number("slammed_ticks", try movedWord(rom, 0x151AE, 84), "ROM 0x151AE: move.w #N,(84,a0)");
    try d.number("slammed_up", try movedLong(rom, 0x151D6, 36), "ROM 0x151D6: move.l #N,(36,a0)");
    try d.number("slammed_gravity", try movedLong(rom, 0x151DE, 98), "ROM 0x151DE: move.l #N,(98,a0)");
    try d.number("slammed_x", try movedLong(rom, 0x151E6, 28), "ROM 0x151E6: move.l #N,(28,a0)");
    try d.number("slammed_slowing", try movedLong(rom, 0x151EE, 94), "ROM 0x151EE: move.l #N,(94,a0)");
    try d.number("slammed_damage", try healthTaken(rom, 0x1521A), "ROM 0x1521A: subq.w #N,(50,a0)");
    // The special attack (0x143D0), the knockout (state 12, 0x15266).
    try d.number("special_damage", try immediate(rom, 0x14416, &.{ 0x04, 0x68 }, 2), "ROM 0x14416: subi.w #N,(50,a0)");
    try d.number("knocked_out_rise", try movedWord(rom, 0x152E4, 84), "ROM 0x152E4: move.w #N,(84,a0) (up again, then sitting: 0x15346)");
    if (try movedWord(rom, 0x15346, 84) != try movedWord(rom, 0x152E4, 84)) return error.BadData;
    try d.number("knocked_out_drop", try movedWord(rom, 0x15368, 84), "ROM 0x15368: move.w #N,(84,a0) (shaking on the ground)");
    try d.number("knocked_out_shake", try movedWord(rom, 0x1536E, 88), "ROM 0x1536E: move.w #N,(88,a0) (in height)");
    try d.number("blink_ticks", try movedWord(rom, 0x153E4, 84), "ROM 0x153E4: move.w #N,(84,a0); a variant's 0x152CA");
    if (try movedWord(rom, 0x152CA, 84) != try movedWord(rom, 0x153E4, 84)) return error.BadData;
    try d.number("blink_from", try comparedWord(rom, 0x15402), "ROM 0x15402: cmpi.w #N,(84,a0)");
    try d.number("blink_hidden", try comparedWord(rom, 0x15416), "ROM 0x15416: cmpi.w #N,(84,a0) (below, hidden)");
    try d.number("points", try enemies.points(rom, @intCast(try moveq(rom, 0x154D8, 7))), "ROM 0x154D8: moveq #N,d7 (the score's amount at ROM 0x10DDE)");
    // His sounds: struck (0x155C2, 0x14A02), the thud of a landing (0x129A0), his cry knocked
    // out (0x14B16, 0x150AC).
    try d.sound("hurt", @bitCast(@as(i8, @intCast(try immediate(rom, 0x155C2, &.{ 0x3E, 0x3C }, 2)))));
    try d.sound("thud", @bitCast(@as(i8, @intCast(try immediate(rom, 0x129A0, &.{ 0x3E, 0x3C }, 2)))));
    try d.sound("cry", @bitCast(@as(i8, @intCast(try immediate(rom, 0x14B16, &.{ 0x3E, 0x3C }, 2)))));
    if (try immediate(rom, 0x14A02, &.{ 0x3E, 0x3C }, 2) != try immediate(rom, 0x155C2, &.{ 0x3E, 0x3C }, 2)) return error.BadData;
    if (u16be(rom, 0x15778) != 0x4EFA or u16be(rom, 0x1573C) != 0x323C) return error.BadData;
    return .{
        .name = "boss_r3",
        .provenance = try std.fmt.allocPrint(arena, "boss type $30, round 3's (handler 0x143D0, his states at 0x14460): the animation set at ROM 0x{X:0>5}, the boxes (0x1A68E, 0x1AB8E); his health and power by the level (0x1455C); his palette line his art's (move.w #N,d1 at ROM 0x1573C){s}", .{ set, d.number_notes.items }),
        .family = .boss,
        .team = .enemy,
        .behaviour = "boss_r3",
        .palette = @intCast((u16be(rom, 0x1573E) >> 13) & 3),
        .health = rom[strengths + 2],
        .shadow = true,
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// His part (type $31, 0x15794): what his frames leave out of him, placed by him at an offset
/// (0x1569C): standing, it shows its own frames by side (0x15746); in his charge, its frames for
/// the charge's way (0x157C4), then the slam's (0x157EC); in his hug, its own (0x1581C).
pub fn part(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try def(arena, rom);
    const stand = try moveq(rom, 0x1575A, 0);
    if (stand != 2) return error.BadData;
    try d.animations.append(arena, .{ .name = "stand", .loop = true, .frames = try sideFrames(&d, 0, false) });
    try d.animations.append(arena, .{ .name = "stand_left", .loop = true, .frames = try sideFrames(&d, 1, true) });
    if (try moveq(rom, 0x157D6, 0) + 2 != try moveq(rom, 0x157CE, 0)) return error.BadData;
    if (try moveq(rom, 0x15808, 0) + 2 != try moveq(rom, 0x15804, 0)) return error.BadData;
    for ([_]struct { name: []const u8, word: i32 }{
        .{ .name = "charge", .word = try moveq(rom, 0x157D6, 0) },
        .{ .name = "charge_end", .word = try moveq(rom, 0x15808, 0) },
        .{ .name = "hug", .word = try movedWord(rom, 0x1582E, 8) },
    }) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try frames(&d, an.name, an.word) });
    return .{
        .name = "boss_r3_part",
        .provenance = try std.fmt.allocPrint(arena, "round 3's boss's part (type $31, handler 0x15794, made at 0x144DE): his animation set at ROM 0x{X:0>5}; its palette line his art's{s}", .{ set, d.number_notes.items }),
        .family = .projectile,
        .team = .neutral,
        .behaviour = "boss_r3_part",
        .palette = @intCast((u16be(rom, 0x1573E) >> 13) & 3),
        .numbers = d.numbers.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// The helper of a two-player round 3 (type $39, 0x14318), made by the boss whose entry has a bar
/// of its own: hidden, it watches the two bosses, knocks out the section's enemies when both are
/// beaten, clears each done with his knockout, and ends the round with the second.
pub fn helper(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    _ = rom;
    return .{
        .name = "boss_r3_helper",
        .provenance = "round 3's boss's helper (type $39, handler 0x14318, made at 0x1451C)",
        .family = .effect,
        .team = .neutral,
        .behaviour = "boss_r3_helper",
        .shadow_place = true,
        .animations = try arena.alloc(entity.Animation, 0),
    };
}

pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try boss(arena, rom));
    try out.append(arena, try part(arena, rom));
    try out.append(arena, try helper(arena, rom));
}

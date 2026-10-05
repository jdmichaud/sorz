//! Round 8's boss, Mr. X (docs/content.md, `entities/mr_x.json`, `mr_x_shot.json`,
//! `mr_x_cartridge.json`): standing, type $35 (his handler 0x1306A), with his gun's shots (type
//! $36, 0x140DC) and their cartridges (type $37, 0x14266). His animation set (0x3468A) is of round
//! 3's boss's kind, and his code shares round 3's boss's helpers (0x1292E to 0x12B4C:
//! extract/boss_r3.zig). Each definition's numbers are read from the immediate values of his
//! code, the place of each in its provenance.
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");
const enemies = @import("enemies.zig");
const boss_r3 = @import("boss_r3.zig");

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const moveq = entities.moveq;
const moveByte = entities.moveByte;
const frameCompared = entities.frameCompared;
const quick = entities.quick;
const movedLong = boss_r3.movedLong;
const movedWord = boss_r3.movedWord;
const comparedWord = boss_r3.comparedWord;
const longMoved = boss_r3.longMoved;
const healthTaken = boss_r3.healthTaken;
const frames = boss_r3.frames;
const framesShown = boss_r3.framesShown;
const sideFrames = boss_r3.sideFrames;

/// His animation set (move.l #N,(4,a0): his at 0x13E88, his shot's at 0x140FA, his cartridge's
/// at 0x14278).
const set = 0x3468A;
/// His health and power by the options' level, two bytes each (0x13EBC).
const strengths = 0x13ED0;
/// The state a player's grab sends him to, by the player's request (its $7D); negative: none
/// (0x13F40).
const grab_states = 0x13F5E;
/// The burst's table (0x14128, 0x14296): by an index, 8 bytes: the shot's speeds across and in
/// depth (words, in 1/256 of a pixel), its frame (the low byte of a word), and its offsets across
/// and in depth (bytes).
const bursts = 0x350FC;

fn def(arena: std.mem.Allocator, rom: []const u8) Error!Def {
    for ([_]u32{ 0x13E88, 0x140FA, 0x14278 }) |at| {
        if (u16be(rom, at) != 0x217C or u32be(rom, at + 2) != set or u16be(rom, at + 6) != 4) return error.BadData;
    }
    return .{ .arena = arena, .rom = rom, .dir = "mrx", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
}

/// `move.w #N,d0` (an animation's word) at `at`.
fn wordMoved(rom: []const u8, at: u32) Error!i32 {
    return immediate(rom, at, &.{ 0x30, 0x3C }, 2);
}

/// `move.w #N,d7` at `at`, a sound's request (0x1069E).
fn soundAt(rom: []const u8, at: u32) Error!u8 {
    return @bitCast(@as(i8, @intCast(try immediate(rom, at, &.{ 0x3E, 0x3C }, 2))));
}

/// `cmpi.l #N,(D,a0)` at `at`: the long compared, its displacement checked.
fn comparedLong(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at + 6) != displacement) return error.BadData;
    return immediate(rom, at, &.{ 0x0C, 0xA8 }, 4);
}

/// `andi.w #N,d0` (or `andi.b`: `byte`) at `at`: the mask.
fn masked(rom: []const u8, at: u32, byte: bool) Error!i32 {
    if (u16be(rom, at) != @as(u16, if (byte) 0x0200 else 0x0240)) return error.BadData;
    return u16be(rom, at + 2);
}

/// The palette line of the name base `move.w #N,d1` at `at` (his art's).
fn paletteOf(rom: []const u8, at: u32) Error!u2 {
    return @intCast((try immediate(rom, at, &.{ 0x32, 0x3C }, 2) >> 13) & 3);
}

/// Mr. X standing (type $35): he sizes his target up, walks at it, closes in, dashes at it with
/// his gun, fires bursts of shots from the top of the floor, backs off; struck, knocked away,
/// grabbed, held from behind, thrown and slammed by the players; his health gone, his long fall
/// ends the round (behaviours/mr_x.zig).
pub fn boss(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try def(arena, rom);
    // His animations, each a pair (facing right, then left): standing and walking (0x14090), his
    // gun raised (0x13C1E) and aimed (0x13C6E), his dash (0x13D9A), held from behind (0x13242),
    // thrown (0x132F2), knocked away (0x13798; up again: its third frame, 0x13E90); struck
    // (0x1372E): its first frame alone (its second is no pair's).
    const raise = try wordMoved(rom, 0x13C1E);
    if (try wordMoved(rom, 0x13C2A) != raise + 2) return error.BadData;
    const aim = try movedWord(rom, 0x13C6E, 8);
    if (try movedWord(rom, 0x13C82, 8) != aim + 2) return error.BadData;
    const struck = try wordMoved(rom, 0x1372E);
    if (try wordMoved(rom, 0x1373A) != struck + 2) return error.BadData;
    const held = try moveq(rom, 0x13242, 0);
    if (try moveq(rom, 0x13232, 0) != held + 2) return error.BadData;
    const thrown = try moveq(rom, 0x132F2, 0);
    if (try moveq(rom, 0x132F8, 0) != thrown + 2) return error.BadData;
    const knocked = try wordMoved(rom, 0x13798);
    if (try wordMoved(rom, 0x137A2) != knocked + 2 or try moveq(rom, 0x13E90, 0) != knocked) return error.BadData;
    for ([_]struct { name: []const u8, word: i32 }{
        .{ .name = "walk", .word = try moveq(rom, 0x14090, 0) },
        .{ .name = "raise", .word = raise },
        .{ .name = "aim", .word = aim },
        .{ .name = "dash", .word = try movedWord(rom, 0x13D9A, 8) },
        .{ .name = "held_behind", .word = held },
        .{ .name = "thrown", .word = thrown },
        .{ .name = "knocked", .word = knocked },
    }) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try frames(&d, an.name, an.word) });
    try d.animations.append(arena, .{ .name = "struck", .loop = true, .frames = try framesShown(&d, "struck", struck, 1) });

    // His health and power by the level (0x13EBC: the health's low byte, $33, then his power).
    if (u16be(rom, 0x13EBC) != 0x3038 or u16be(rom, 0x13EC2) != 0x117B or u16be(rom, 0x13EC8) != 0x117B) return error.BadData;
    var strength: [8]i32 = undefined;
    for (&strength, 0..) |*v, k| v.* = rom[strengths + k];
    try d.table("strength", &strength, "ROM 0x13ED0: by the level, his health then his power (0x13EBC)");
    var grabs: [12]i32 = undefined;
    for (&grabs, 0..) |*v, k| v.* = @as(i8, @bitCast(rom[grab_states + k]));
    try d.table("grab_states", &grabs, "ROM 0x13F5E: the state a player's grab sends him to by its request (negative: none, 0x13F40)");
    for ([_]u32{ 0x13258, 0x1331A, 0x13480, 0x134D6 }) |at| {
        if (u16be(rom, at) & 0xFFBF != 0x4EBA or @as(i32, @intCast(at + 2)) + rom_mod.s16be(rom, at + 2) != 0x15220) return error.BadData;
    }
    try boss_r3.throwTables(&d);

    // Walking (0x14072); getting up (state 0, 0x13E6C) and sizing up (state 1, 0x130D6; 3,
    // 0x130EE).
    const walk = try movedLong(rom, 0x14078, 28);
    if (try movedLong(rom, 0x14080, 32) != walk) return error.BadData;
    try d.number("walk_speed", walk, "ROM 0x14078: move.l #N,(28,a0); in depth 0x14080");
    try d.number("get_up_ticks", try movedWord(rom, 0x13E78, 84), "ROM 0x13E78: move.w #N,(84,a0)");
    if (u16be(rom, 0x13E98) != 10) return error.BadData;
    try d.number("get_up_frame", try quick(rom, 0x13E96, 0x5028), "ROM 0x13E96: addq.b #N,(10,a0) (of his knocked animation)");
    const wait = try movedWord(rom, 0x130DA, 84);
    for ([_]u32{ 0x13204, 0x13B46, 0x13EAE }) |at| if (try movedWord(rom, at, 84) != wait) return error.BadData;
    try d.number("size_up_ticks", wait, "ROM 0x130DA: move.w #N,(84,a0); 0x13204, 0x13B46, 0x13EAE");
    const reach = try longMoved(rom, 0x13104);
    if (try longMoved(rom, 0x131D4) != reach) return error.BadData;
    try d.number("reach_level", reach >> 16, "ROM 0x13104: move.l #N,d0 (its high word, in depth; 0x131D4)");
    try d.number("reach_near", reach & 0xFFFF, "ROM 0x13104: its low word, across");
    try d.number("close_within", try comparedWord(rom, 0x1310E), "ROM 0x1310E: cmpi.w #N,d0 (nearer across, he closes in)");
    // Approaching (state 4, 0x1314C): across at his target, in depth away from its part of the
    // screen.
    const depth_speed = try movedLong(rom, 0x13168, 32);
    if (try movedLong(rom, 0x131F8, 32) != depth_speed) return error.BadData;
    try d.number("approach_depth", depth_speed, "ROM 0x13168: move.l #N,(32,a0); 0x131F8");
    const least = try comparedLong(rom, 0x1318E, 20);
    if (try movedLong(rom, 0x13198, 20) != least) return error.BadData;
    try d.number("depth_least", least, "ROM 0x1318E: cmpi.l #N,(20,a0)");
    const most = try comparedLong(rom, 0x131A2, 20);
    if (try movedLong(rom, 0x131AC, 20) != most) return error.BadData;
    try d.number("depth_most", most, "ROM 0x131A2: cmpi.l #N,(20,a0)");
    // The screen's part his target is in (0x13FFC): left of the middle, above a line.
    if (u16be(rom, 0x14008) != 0x0442 or u16be(rom, 0x1400C) != 0x0443 or u16be(rom, 0x14010) != 0x0C42 or u16be(rom, 0x14016) != 0x0C43) return error.BadData;
    try d.number("screen_middle", @as(i32, u16be(rom, 0x1400A)) - 0x80 + u16be(rom, 0x14012), "ROM 0x14008: subi.w #N,d2, then cmpi.w #M,d2 (drawn across: N+M less $80)");
    try d.number("screen_top", @as(i32, u16be(rom, 0x1400E)) - 0x80 + u16be(rom, 0x14018), "ROM 0x1400C: subi.w #N,d3, then cmpi.w #M,d3 (drawn down: N+M less $80)");
    // His target before he has one (the standing one comes with none, 0x12CE0): the original
    // reads the object at address 0, the ROM's first words.
    if (u16be(rom, 0x13104 + 6) != 0x4EBA or u16be(rom, 0x12A7E) != 0x3268 or u16be(rom, 0x12A80) != 92) return error.BadData;
    try d.number("unseen_x", @bitCast(u32be(rom, 16)), "ROM 0x00010: a long, its place across (the object at address 0, read through his target's word, 0x12A7E)");
    try d.number("unseen_depth", @bitCast(u32be(rom, 20)), "ROM 0x00014: in depth");
    try d.number("unseen_left", (u16be(rom, 8) >> 1) & 1, "ROM 0x00008: its animation's word, bit 1 (facing left)");
    try d.number("unseen_line", @as(i32, rom_mod.s16be(rom, 44)) - 0x80, "ROM 0x0002C: the line it was drawn on (less $80)");
    const left = try comparedWord(rom, 0x131C2);
    const right = try comparedWord(rom, 0x131CC);
    for ([_]u32{ 0x13B22, 0x13886 }) |at| if (try comparedWord(rom, at) != left) return error.BadData;
    for ([_]u32{ 0x13B2A, 0x1388E }) |at| if (try comparedWord(rom, at) != right) return error.BadData;
    try d.number("edge_left", left - 0x80, "ROM 0x131C2: cmpi.w #N+$80,(40,a0) (drawn across; 0x13B22, 0x13886)");
    try d.number("edge_right", right - 0x80, "ROM 0x131CC: cmpi.w #N+$80,(40,a0) (0x13B2A, 0x1388E)");
    // Backing off (state 5, 0x13AFA), closing in (state 6, 0x13B54).
    try d.number("back_off_ticks", try movedWord(rom, 0x13B16, 84), "ROM 0x13B16: move.w #N,(84,a0)");
    const close = try longMoved(rom, 0x13B6C);
    if (close >> 16 != reach >> 16) return error.BadData;
    try d.number("close_near", close & 0xFFFF, "ROM 0x13B6C: move.l #N,d0 (its low word, across; its high word the reach's)");
    // A burst (state 7, 0x13BD0): up to the floor's top, his gun raised, aimed, fired.
    const top = try comparedLong(rom, 0x13BFC, 20);
    if (try movedLong(rom, 0x13C10, 20) != top or try comparedLong(rom, 0x13B96, 20) != top or try movedLong(rom, 0x13BA0, 20) != top) return error.BadData;
    try d.number("burst_depth", top, "ROM 0x13BFC: cmpi.l #N,(20,a0) (closing in, not above it: 0x13B96)");
    try d.number("burst_up", try movedLong(rom, 0x13BE4, 32), "ROM 0x13BE4: move.l #N,(32,a0)");
    try d.number("raise_ticks", try movedWord(rom, 0x13C3A, 84), "ROM 0x13C3A: move.w #N,(84,a0)");
    try d.number("raise_still", try comparedWord(rom, 0x13C54), "ROM 0x13C54: cmpi.w #N,(84,a0) (from it down, still)");
    try d.number("burst_frames", try movedWord(rom, 0x13C9A, 84), "ROM 0x13C9A: move.w #N,(84,a0)");
    const period = try movedWord(rom, 0x13CA0, 86);
    if (try movedWord(rom, 0x13CB4, 86) != period) return error.BadData;
    try d.number("burst_period", period, "ROM 0x13CA0: move.w #N,(86,a0); 0x13CB4");
    try d.number("burst_flash", try frameCompared(rom, 0x13CC4), "ROM 0x13CC4: cmpi.b #N,(10,a0) (from that frame, his art by the frame's parity)");
    // The dash (state 2, 0x13D86).
    try d.number("dash_speed", -(try movedLong(rom, 0x13DB8, 28)), "ROM 0x13DB8: move.l #-N,(28,a0) (to the left; negated to the right)");
    try d.number("dash_slowing", try movedLong(rom, 0x13DC0, 94), "ROM 0x13DC0: move.l #N,(94,a0)");
    try d.number("dash_ticks", try movedWord(rom, 0x13DD8, 84), "ROM 0x13DD8: move.w #N,(84,a0)");
    try d.number("dash_still", try movedWord(rom, 0x13DEC, 84), "ROM 0x13DEC: move.w #N,(84,a0)");
    try d.number("dash_fire", try masked(rom, 0x13E2C, true), "ROM 0x13E2C: andi.b #N,d0 (a draw: at none, he fires)");
    // Struck (state 8, 0x1371C; by a knee, 0x136A8), knocked away (9, 0x13778, 0x13FB4),
    // falling and lying (0x1292E, 0x1296A, 0x129DE).
    const struck_ticks = try movedWord(rom, 0x1374A, 84);
    if (try movedWord(rom, 0x136CE, 84) != struck_ticks) return error.BadData;
    try d.number("struck_ticks", struck_ticks, "ROM 0x1374A: move.w #N,(84,a0); 0x136CE");
    const shake = try movedWord(rom, 0x13756, 94);
    if (try movedWord(rom, 0x136DA, 94) != shake) return error.BadData;
    try d.number("shake", shake, "ROM 0x13756: move.w #N,(94,a0) (a shake's step across; 0x136DA)");
    try d.number("knock_away_slowing", try movedLong(rom, 0x13FB4, 94), "ROM 0x13FB4: move.l #N,(94,a0)");
    try d.number("knock_away_up", try movedLong(rom, 0x13FBC, 36), "ROM 0x13FBC: move.l #N,(36,a0)");
    try d.number("knock_away_x", try movedLong(rom, 0x13FC4, 28), "ROM 0x13FC4: move.l #N,(28,a0)");
    try d.number("knocked_gravity", try movedLong(rom, 0x137AA, 98), "ROM 0x137AA: move.l #N,(98,a0)");
    try d.number("falling_gravity", try movedLong(rom, 0x12956, 98), "ROM 0x12956: move.l #N,(98,a0) (from the top)");
    try d.number("bounce_above", try comparedLong(rom, 0x129AA, 36), "ROM 0x129AA: cmpi.l #N,(36,a0) (falling faster, he bounces)");
    if (u16be(rom, 0x129BC) != 0xE680) return error.BadData;
    try d.number("bounce_shift", 3, "ROM 0x129BC: asr.l #3,d0 (the bounce an eighth of the fall)");
    const lie = try movedWord(rom, 0x129D0, 84);
    if (try comparedWord(rom, 0x133F0) != lie) return error.BadData;
    try d.number("lie_ticks", lie, "ROM 0x129D0: move.w #N,(84,a0) (landed; thrown, state $C, waits for it)");
    try d.number("knocked_lie_ticks", try movedWord(rom, 0x137D8, 84), "ROM 0x137D8: move.w #N,(84,a0)");
    // Knocked away and thrown, he joins the objects that hit the others (0x95CE: at 0x13788 and
    // 0x1330A), whose blow on an enemy costs it the enemies' own (0xA9F2).
    if (rom[0xA9F2] & 0xF1 != 0x51 or rom[0xA9F3] != 0x68) return error.BadData;
    try d.number("missile_damage", @as(i32, rom[0xA9F2] >> 1) & 7, "ROM 0x0A9F2: subq.w #N,(50,a0) (what a body that hits does to the enemies it meets)");
    // Grabbed (state $A, 0x1353A), held from behind ($B, 0x13218).
    try d.number("grabbed_ticks", try movedWord(rom, 0x1355A, 84), "ROM 0x1355A: move.w #N,(84,a0)");
    try d.number("grabbed_ahead", try moveq(rom, 0x1356A, 0), "ROM 0x1356A: moveq #N,d0 (in front of his holder)");
    try d.number("grabbed_wait", try movedWord(rom, 0x13666, 84), "ROM 0x13666: move.w #N,(84,a0) (the last knee: then knocked away)");
    try d.number("grabbed_hold", try movedWord(rom, 0x1369E, 84), "ROM 0x1369E: move.w #N,(84,a0) (a throw back: held on)");
    try d.number("held_ticks", try movedWord(rom, 0x13264, 84), "ROM 0x13264: move.w #N,(84,a0)");
    // Thrown (state $C, 0x132B2), slammed ($D, 0x1344A).
    try d.number("thrown_up", try movedLong(rom, 0x13326, 36), "ROM 0x13326: move.l #N,(36,a0)");
    const tg = try movedLong(rom, 0x1332E, 98);
    if (try movedLong(rom, 0x13380, 98) != tg) return error.BadData;
    try d.number("thrown_gravity", tg, "ROM 0x1332E: move.l #N,(98,a0); 0x13380");
    const tx = try movedLong(rom, 0x13336, 28);
    if (try movedLong(rom, 0x13360, 28) != tx) return error.BadData;
    try d.number("thrown_x", tx, "ROM 0x13336: move.l #N,(28,a0); 0x13360");
    try d.number("thrown_slowing", try movedLong(rom, 0x1333E, 94), "ROM 0x1333E: move.l #N,(94,a0)");
    try d.number("thrown_over", try moveq(rom, 0x1335E, 0), "ROM 0x1335E: moveq #N,d0 (on, at the top)");
    try d.number("thrown_down", try movedLong(rom, 0x13378, 36), "ROM 0x13378: move.l #N,(36,a0)");
    const floor = try comparedWord(rom, 0x133AA);
    if (try movedWord(rom, 0x133C0, 24) != floor or try comparedWord(rom, 0x138E8) != floor) return error.BadData;
    if (u32be(rom, 0x13916) != @as(u32, @intCast(floor)) << 16 or try wordMoved(rom, 0x12976) != floor) return error.BadData;
    try d.number("floor", floor, "ROM 0x133AA: cmpi.w #N,(24,a0) (thrown, and his last fall, 0x138E8, land there; round 8's in the falls' helper, 0x12976)");
    try d.number("thrown_bounce", try movedLong(rom, 0x133D2, 36), "ROM 0x133D2: move.l #N,(36,a0)");
    try d.number("thrown_damage", try healthTaken(rom, 0x133FE), "ROM 0x133FE: subq.w #N,(50,a0)");
    try d.number("thrown_slide", try movedWord(rom, 0x1340E, 84), "ROM 0x1340E: move.w #N,(84,a0)");
    if (u16be(rom, 0x13498) != 0x0C29 or rom[0x1349A] != 0 or u16be(rom, 0x1349C) != 10) return error.BadData;
    try d.number("slammed_frame", rom[0x1349B], "ROM 0x13498: cmpi.b #N,(10,a1) (the holder's frame that slams him)");
    try d.number("slammed_ticks", try movedWord(rom, 0x134C4, 84), "ROM 0x134C4: move.w #N,(84,a0)");
    try d.number("slammed_up", try movedLong(rom, 0x134E0, 36), "ROM 0x134E0: move.l #N,(36,a0)");
    try d.number("slammed_gravity", try movedLong(rom, 0x134E8, 98), "ROM 0x134E8: move.l #N,(98,a0)");
    try d.number("slammed_x", try movedLong(rom, 0x134F0, 28), "ROM 0x134F0: move.l #N,(28,a0)");
    try d.number("slammed_slowing", try movedLong(rom, 0x134F8, 94), "ROM 0x134F8: move.l #N,(94,a0)");
    try d.number("slammed_damage", try healthTaken(rom, 0x13524), "ROM 0x13524: subq.w #N,(50,a0)");
    // His last fall (state $E, 0x13808) and the cartridges he spills in it (0x13A7A).
    try d.number("defeated_gravity", try movedLong(rom, 0x1384E, 98), "ROM 0x1384E: move.l #N,(98,a0)");
    try d.number("defeated_x", try movedLong(rom, 0x13856, 28), "ROM 0x13856: move.l #N,(28,a0) (away from his target)");
    try d.number("defeated_up", try movedLong(rom, 0x1385E, 36), "ROM 0x1385E: move.l #N,(36,a0)");
    try d.number("defeated_falling", try movedLong(rom, 0x138C4, 98), "ROM 0x138C4: move.l #N,(98,a0)");
    const fastest = try comparedLong(rom, 0x138F8, 36);
    if (try movedLong(rom, 0x13902, 36) != fastest) return error.BadData;
    try d.number("defeated_most", fastest, "ROM 0x138F8: cmpi.l #N,(36,a0)");
    try d.number("defeated_bounce", try movedLong(rom, 0x13926, 36), "ROM 0x13926: move.l #N,(36,a0)");
    try d.number("defeated_bounce_gravity", try movedLong(rom, 0x1392E, 98), "ROM 0x1392E: move.l #N,(98,a0)");
    try d.number("defeated_rest", try comparedLong(rom, 0x13972, 36), "ROM 0x13972: cmpi.l #N,(36,a0) (slower, he rests)");
    const lying = try movedWord(rom, 0x13988, 84);
    if (try movedWord(rom, 0x139A8, 84) != lying) return error.BadData;
    try d.number("defeated_lie", lying, "ROM 0x13988: move.w #N,(84,a0); 0x139A8");
    try d.number("defeated_frame", try moveByte(rom, 0x1399C, 10), "ROM 0x1399C: move.b #N,(10,a0)");
    try d.number("defeated_sway", try movedWord(rom, 0x139B6, 88), "ROM 0x139B6: move.w #N,(88,a0) (in height)");
    try d.number("defeated_rise", try movedWord(rom, 0x139CC, 84), "ROM 0x139CC: move.w #N,(84,a0)");
    const down = try movedWord(rom, 0x13A00, 84);
    if (try movedWord(rom, 0x13A38, 84) != down) return error.BadData;
    try d.number("defeated_down", down, "ROM 0x13A00: move.w #N,(84,a0); 0x13A38");
    try d.number("points", try enemies.points(rom, @intCast(try moveq(rom, 0x13A56, 7))), "ROM 0x13A56: moveq #N,d7 (the score's amount at ROM 0x10DDE)");
    if (try masked(rom, 0x13A82, false) != 3 or try comparedWord(rom, 0x13A86) != 3) return error.BadData;
    try d.number("spill_every", 4, "ROM 0x13A82: andi.w #3,d0, cmpi.w #3,d0 (a cartridge every 4 ticks)");
    if (try masked(rom, 0x13AC0, true) != 7) return error.BadData;
    try d.number("spill_height", try masked(rom, 0x13ACE, false), "ROM 0x13ACE: andi.w #N,d0 (a draw: up to that much higher)");
    try d.number("spill_spread", try masked(rom, 0x13ADC, false), "ROM 0x13ADC: andi.w #N,d0 (a draw: across, behind him)");
    if (u16be(rom, 0x13AE0) != 0x0440) return error.BadData;
    try d.number("spill_ahead", u16be(rom, 0x13AE2), "ROM 0x13AE0: subi.w #N,d0 (less that much: ahead of him)");
    // His end (0x13A60): the round's end due, the screen fading.
    try d.number("end_fade", try immediate(rom, 0x13A66, &.{ 0x31, 0xFC }, 2), "ROM 0x13A66: move.w #N,($FB0C).w");
    // His sounds: struck (0x13F0E; 0x135E8, 0x136A8, 0x1382E, 0x13F6E), the thud of a landing
    // (0x129A0; 0x134BA, 0x1391C, 0x13962), his groan at the last (0x139D8).
    const hurt = try soundAt(rom, 0x13F0E);
    for ([_]u32{ 0x135E8, 0x136A8, 0x1382E, 0x13F6E }) |at| if (try soundAt(rom, at) != hurt) return error.BadData;
    try d.sound("hurt", hurt);
    const thud = try soundAt(rom, 0x129A0);
    for ([_]u32{ 0x134BA, 0x1391C, 0x13962 }) |at| if (try soundAt(rom, at) != thud) return error.BadData;
    try d.sound("thud", thud);
    try d.sound("groan", try soundAt(rom, 0x139D8));
    return .{
        .name = "mr_x",
        .provenance = try std.fmt.allocPrint(arena, "boss type $35, round 8's (handler 0x1306A, his states at 0x130B8): the animation set at ROM 0x{X:0>5}, the boxes (0x1A68E, 0x1AB8E); his health and power by the level (0x13EBC); his palette line his art's (move.w #N,d1 at ROM 0x1408C){s}", .{ set, d.number_notes.items }),
        .family = .boss,
        .team = .enemy,
        .behaviour = "mr_x",
        .palette = try paletteOf(rom, 0x1408C),
        .health = rom[strengths + 2],
        .shadow = true,
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// The burst's table (0x350FC) by its eight indices: speeds across and in depth (words, in 1/256
/// of a pixel), and for the shot its frames and offsets.
fn burstTables(d: *Def, rom: []const u8, shot_too: bool) Error!void {
    var x: [8]i32 = undefined;
    var depth: [8]i32 = undefined;
    var frame: [8]i32 = undefined;
    var off_x: [8]i32 = undefined;
    var off_depth: [8]i32 = undefined;
    for (0..8) |k| {
        const e = bursts + 8 * @as(u32, @intCast(k));
        x[k] = u16be(rom, e);
        depth[k] = u16be(rom, e + 2);
        if (rom[e + 4] != 0) return error.BadData;
        frame[k] = rom[e + 5];
        off_x[k] = entities.s8(rom, e + 6);
        off_depth[k] = entities.s8(rom, e + 7);
    }
    try d.table("burst_x", &x, "ROM 0x350FC: by the burst's index, 8 bytes each: the speed across (a word, in 1/256 of a pixel; 0x1412E)");
    try d.table("burst_depth", &depth, "ROM 0x350FE: in depth");
    if (!shot_too) return;
    try d.table("burst_frame", &frame, "ROM 0x35101: its frame (0x14146)");
    try d.table("burst_offset_x", &off_x, "ROM 0x35102: its offset across (a byte, 0x14158)");
    try d.table("burst_offset_depth", &off_depth, "ROM 0x35103: in depth (0x1414E)");
}

/// What a shot knocked out of the air and a cartridge share (0x14214): out of the screen's middle
/// they go; near the screen's top their depth stops; on the floor they bounce at half their
/// speed, and go once slow.
fn bounceNumbers(d: *Def, rom: []const u8) Error!void {
    if (u16be(rom, 0x1421C) != 0x0C68 or u16be(rom, 0x14220) != 44) return error.BadData;
    try d.number("bounce_top", @as(i32, u16be(rom, 0x1421E)) - 0x80, "ROM 0x1421C: cmpi.w #N+$80,(44,a0) (drawn down)");
    const floor = try comparedWord(rom, 0x1422E);
    if (u16be(rom, 0x14236) != 0x217C or u32be(rom, 0x14238) != @as(u32, @intCast(floor)) << 16) return error.BadData;
    try d.number("bounce_floor", floor, "ROM 0x1422E: cmpi.w #N,(24,a0); 0x14236");
    try d.number("bounce_least", try immediate(rom, 0x14242, &.{ 0x0C, 0x80 }, 4), "ROM 0x14242: cmpi.l #N,d0 (landing slower, it goes)");
    if (u16be(rom, 0x1424A) != 0xE280) return error.BadData;
    try d.number("bounce_shift", 1, "ROM 0x1424A: asr.l #1,d0 (a bounce half the fall)");
}

/// A shot of his burst (type $36): from his gun it flies until it leaves the screen's middle or
/// his depths; it knocks down the player it meets; a player's blow knocks it out of the air
/// (behaviours/mr_x_shot.zig).
pub fn shot(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try def(arena, rom);
    const fly = try wordMoved(rom, 0x14106);
    if (try wordMoved(rom, 0x14110) != fly + 2) return error.BadData;
    try d.animations.append(arena, .{ .name = "fly", .loop = true, .frames = try frames(&d, "fly", fly) });
    try burstTables(&d, rom, true);
    if (u16be(rom, 0x14132) != 0xE189 or u16be(rom, 0x1413E) != 0xE189) return error.BadData;
    try d.number("speed_shift", 8, "ROM 0x14132: lsl.l #8,d1 (the table's speeds; 0x1413E)");
    if (u16be(rom, 0x1416E) != 0x0468 or u16be(rom, 0x14172) != 24) return error.BadData;
    try d.number("up", u16be(rom, 0x14170), "ROM 0x1416E: subi.w #N,(24,a0) (his gun's height)");
    try d.number("depth_most", try comparedLong(rom, 0x14184, 20), "ROM 0x14184: cmpi.l #N,(20,a0) (deeper, it goes)");
    try d.number("power", try moveByte(rom, 0x141A8, 52), "ROM 0x141A8: move.b #N,(52,a0) (its blow on a player)");
    if (u16be(rom, 0x141C2) != 0xE680 or u16be(rom, 0x141CC) != 0xE680) return error.BadData;
    try d.number("knocked_shift", 3, "ROM 0x141C2: asr.l #3,d0 (struck: its speeds an eighth, back across; 0x141CC)");
    try d.number("knocked_up", try movedLong(rom, 0x141D2, 36), "ROM 0x141D2: move.l #N,(36,a0)");
    try d.number("knocked_gravity", try movedLong(rom, 0x141DA, 98), "ROM 0x141DA: move.l #N,(98,a0)");
    try d.number("knocked_frame", try moveByte(rom, 0x141E2, 10), "ROM 0x141E2: move.b #N,(10,a0)");
    try bounceNumbers(&d, rom);
    try d.sound("fire", try soundAt(rom, 0x140EA));
    return .{
        .name = "mr_x_shot",
        .provenance = try std.fmt.allocPrint(arena, "Mr. X's shot (type $36, handler 0x140DC, made at 0x13D20): his animation set at ROM 0x{X:0>5}; its palette line his art's (move.w #N,d1 at ROM 0x14102); no shadow (0x14118: ori.b #$40,(1,a0)){s}", .{ set, d.number_notes.items }),
        .family = .projectile,
        .team = .enemy,
        .behaviour = "mr_x_shot",
        .palette = try paletteOf(rom, 0x14102),
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// A cartridge (type $37): out of his gun at each shot, or spilled in his last fall, it flies
/// away and bounces off the floor (behaviours/mr_x_cartridge.zig).
pub fn cartridge(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d = try def(arena, rom);
    const spin = try wordMoved(rom, 0x14284);
    try d.animations.append(arena, .{ .name = "spin", .loop = true, .frames = try sideFrames(&d, @intCast(@divExact(spin, 2)), false) });
    try burstTables(&d, rom, false);
    if (u16be(rom, 0x142A0) != 0xEB89 or u16be(rom, 0x142AC) != 0xE989) return error.BadData;
    try d.number("shift_x", 5, "ROM 0x142A0: lsl.l #5,d1 (the burst's speed across, of the index the other way: 0x13D6E)");
    try d.number("shift_depth", 4, "ROM 0x142AC: lsl.l #4,d1");
    if (u16be(rom, 0x142CA) != 0x0468 or u16be(rom, 0x142CE) != 24) return error.BadData;
    try d.number("up", u16be(rom, 0x142CC), "ROM 0x142CA: subi.w #N,(24,a0) (his gun's height)");
    try d.number("gun_up", try movedLong(rom, 0x142D0, 36), "ROM 0x142D0: move.l #N,(36,a0)");
    try d.number("gun_gravity", try movedLong(rom, 0x142D8, 98), "ROM 0x142D8: move.l #N,(98,a0)");
    if (u16be(rom, 0x142E6) != 0xE280 or u16be(rom, 0x142F0) != 0xE280) return error.BadData;
    try d.number("fall_up", try movedLong(rom, 0x142F6, 36), "ROM 0x142F6: move.l #N,(36,a0) (spilled in his fall, at half the speeds: 0x142E6)");
    try d.number("fall_gravity", try movedLong(rom, 0x142FE, 98), "ROM 0x142FE: move.l #N,(98,a0)");
    try bounceNumbers(&d, rom);
    return .{
        .name = "mr_x_cartridge",
        .provenance = try std.fmt.allocPrint(arena, "Mr. X's cartridge (type $37, handler 0x14266, made at 0x13D56 and 0x13A9C): his animation set at ROM 0x{X:0>5}; its palette line his art's (move.w #N,d1 at ROM 0x14280); animated, no shadow (0x14272: ori.b #$44,(1,a0)){s}", .{ set, d.number_notes.items }),
        .family = .effect,
        .team = .neutral,
        .behaviour = "mr_x_cartridge",
        .palette = try paletteOf(rom, 0x14280),
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try boss(arena, rom));
    try out.append(arena, try shot(arena, rom));
    try out.append(arena, try cartridge(arena, rom));
}

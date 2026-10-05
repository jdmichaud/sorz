//! Round 4's obstacles (docs/content.md, `entities/NAME.json`): each a definition read from its
//! animation set and from the immediate values of the code that runs it, with the place of each
//! in its provenance.
//!
//! The cone (type $1B, its handler 0x7370), the post (type $1C, 0x7448) and the barrier (type $1D,
//! 0x746A; sor-remaster's obj/obstacle.zig): they stand (the barrier solid) until a player's blow
//! or a thing thrown knocks them away (0x7392, 0x74A6): the item each holds is left (0x7E54), they
//! fly to the side they are sent to (0x6AD0), the barrier its top too (a piece of its own in the
//! pieces' places, 0x7EEA), fall and bounce (0x7104), and go at their second landing or when the
//! camera leaves them behind (0x6A70).
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
const moveq = entities.moveq;
const entryFrames = items.entryFrames;

const Obstacle = struct {
    name: []const u8,
    what: []const u8,
    prefix: []const u8,
    /// Its start: its set (`lea.l #N,a1`), and its height (`move.w #N,(24,a0)`).
    set_at: u32,
    height_at: u32,
    /// Its knocking away: its sound (`moveq #N,d7`), its speed up (`moveq #N,d5`, or `move.w
    /// #N,(36,a0)`), its speeds across by side (the table of two words).
    sound_at: u32,
    up_at: u32,
    up_word: bool,
    speeds: u32,
    /// The barrier: solid, with its top.
    barrier: bool = false,
};

/// `move.w #N,(D,a0)` at `at`: N, the displacement checked.
fn moveWord(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at + 4) != displacement) return error.BadData;
    return immediate(rom, at, &.{ 0x31, 0x7C }, 2);
}

fn obstacle(arena: std.mem.Allocator, rom: []const u8, o: Obstacle) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, o.set_at, &.{ 0x43, 0xF9 }, 4));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "round4", .prefix = o.prefix, .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    // Its animations by number (the set's entries: 0, 2 and 4): standing; knocked away, its pose
    // and a blank frame (its blinking once it has landed): the cone's and the post's to the
    // right (entry 2; entry 1 is it mirrored, to the left), the barrier's either way (entry 1),
    // and the barrier's top (entry 2).
    try d.animations.append(arena, .{ .name = "stand", .loop = true, .frames = try entryFrames(&d, "stand", 0, null, false) });
    if (o.barrier) {
        try d.animations.append(arena, .{ .name = "fly", .loop = true, .frames = try entryFrames(&d, "fly", 1, null, true) });
        try d.animations.append(arena, .{ .name = "part", .loop = true, .frames = try entryFrames(&d, "part", 2, null, true) });
    } else {
        const left = try entities.readAnimation(arena, rom, set, 1);
        const right = try entities.readAnimation(arena, rom, set, 2);
        if (left.frames.len != right.frames.len or left.timing != right.timing or !left.frames[0].mirrored) return error.BadData;
        for (left.frames, right.frames) |l, r| if (l.address != r.address or r.mirrored) return error.BadData;
        const fly = try entryFrames(&d, "fly", 2, null, true);
        try d.animations.append(arena, .{ .name = "fly", .loop = true, .frames = fly });
        // None of its own: its pose's.
        try d.animations.append(arena, .{ .name = "part", .loop = true, .frames = fly });
    }
    try d.number("height", try moveWord(rom, o.height_at, 24), try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: move.w #N,(24,a0)", .{o.height_at}));
    if (o.barrier) {
        // The barrier is solid (0x7498: ori.b #1,($3A,a0)), its box the solid boxes' entry of
        // type $1D (0x3BE0: moveq #16,d4 for cmpi.b #$1D).
        if (u32be(rom, 0x7498) != 0x0028_0001 or u16be(rom, 0x749C) != 0x003A) return error.BadData;
        if (try moveq(rom, 0x3BE0, 4) != 16 or rom[0x3BE5] != 0x1D) return error.BadData;
        try items.solidBoxAt(&d, 16);
    }
    try d.number("solid", @intFromBool(o.barrier), "ROM 0x07498: ori.b #1,($3A,a0) (the barrier's alone)");
    const up = if (o.up_word) try signedWord(rom, o.up_at, &.{ 0x31, 0x7C }) else try moveq(rom, o.up_at, 5);
    try d.number("up", up << 16, try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: its speed up's whole pixels", .{o.up_at}));
    try d.number("speed_left", @as(i32, s16be(rom, o.speeds)) << 16, try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: the first word, whole pixels", .{o.speeds}));
    try d.number("speed_right", @as(i32, s16be(rom, o.speeds + 2)) << 16, try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: the second word, whole pixels", .{o.speeds + 2}));
    try d.number("falling", try immediate(rom, 0x7104, &.{ 0x06, 0xA8 }, 4), "ROM 0x07104: addi.l #N,(36,a0)");
    if (o.barrier) {
        if (u16be(rom, 0x750C) != 24 or u16be(rom, 0x7512) != 36) return error.BadData;
        try d.number("part_above", try signedWord(rom, 0x7508, &.{ 0x06, 0x6E }), "ROM 0x07508: addi.w #N,(24,a6)");
        try d.number("part_up", (try signedWord(rom, 0x750E, &.{ 0x3D, 0x7C })) << 16, "ROM 0x0750E: move.w #N,(36,a6), whole pixels");
        try d.number("part_left", @as(i32, s16be(rom, 0x7530)) << 16, "ROM 0x07530: the first word, whole pixels");
        try d.number("part_right", @as(i32, s16be(rom, 0x7532)) << 16, "ROM 0x07532: the second word, whole pixels");
    }
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A70)");
    const drawn = try items.drawnOffset(rom);
    try d.number("screen_from", try immediate(rom, 0xAABA, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AABA: cmpi.w #N,(40,a0), less 0xAF6E's offset (a blow lands on the screen)");
    try d.number("screen_to", try immediate(rom, 0xAAC2, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AAC2: cmpi.w #N,(40,a0), less 0xAF6E's offset (excluded)");
    try d.sound("knocked", @bitCast(@as(i8, @intCast(try moveq(rom, o.sound_at, 7)))));
    try d.sound("bounce", @bitCast(@as(i8, @intCast(try moveq(rom, 0x713A, 7)))));
    return .{
        .name = o.name,
        .provenance = try std.fmt.allocPrint(arena, "{s}: the animation set at ROM 0x{X:0>5}{s}", .{ o.what, set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "obstacle_r4",
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

fn u32be(rom: []const u8, at: u32) u32 {
    return rom_mod.u32be(rom, at);
}

/// The word immediate of the instruction at `at` (its opcode checked), signed.
fn signedWord(rom: []const u8, at: u32, opcode: []const u8) Error!i32 {
    _ = try immediate(rom, at, opcode, 2);
    return s16be(rom, at + @as(u32, @intCast(opcode.len)));
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try obstacle(arena, rom, .{ .name = "obstacle_1b", .what = "round 4's cones, type $1B (handler 0x7370)", .prefix = "obstacle_1", .set_at = 0x7388, .height_at = 0x7382, .sound_at = 0x73E2, .up_at = 0x73E0, .up_word = false, .speeds = 0x7444 }));
    try out.append(arena, try obstacle(arena, rom, .{ .name = "obstacle_1c", .what = "round 4's posts, type $1C (handler 0x7448)", .prefix = "obstacle_2", .set_at = 0x7460, .height_at = 0x745A, .sound_at = 0x73FC, .up_at = 0x73E0, .up_word = false, .speeds = 0x7444 }));
    try out.append(arena, try obstacle(arena, rom, .{ .name = "obstacle_1d", .what = "round 4's barriers, type $1D (handler 0x746A)", .prefix = "obstacle_3", .set_at = 0x747C, .height_at = 0x749E, .sound_at = 0x74C4, .up_at = 0x74D4, .up_word = true, .speeds = 0x752C, .barrier = true }));
}

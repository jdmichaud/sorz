//! The street's breakables and the items a player picks up (docs/content.md,
//! `entities/NAME.json`): each a definition read from its animation set and from the immediate
//! values of the code that runs it, with the place of each in its provenance.
//!
//! - The breakable (type $11, its handler 0x6AF4, sor-remaster's obj/breakable.zig): it stands
//!   solid until a player's blow or a thing thrown breaks it; it leaves the item it holds
//!   (0x7E54), blinks and goes, and its pieces fly off (the table at 0x6BD8).
//! - The items (handlers 0x68E2 to 0x69A6, sor-remaster's obj/item.zig): the food gives health
//!   (0x4E6C), the life a life, the special item a special attack, the money and the gold bar
//!   points (the table at 0x10DDA); each falls to the ground and waits there.
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
const moveq = entities.moveq;
const readAnimation = entities.readAnimation;

/// The drawing puts an object at its place across less the camera's, plus this (0xAF6E: addi.w
/// #N,d2); the meetings test the result (`(40,a0)`) against the screen's sides.
pub fn drawnOffset(rom: []const u8) Error!i32 {
    return immediate(rom, 0xAF6E, &.{ 0x06, 0x42 }, 2);
}

/// The frames of entry `entry` of `d`'s set, as one animation facing right, each shown the
/// entry's timing (a still entry's, 0, as one tick that stays); `first` frames only when given;
/// their bodies unless `bodiless`.
pub fn entryFrames(d: *Def, name: []const u8, entry: u32, first: ?usize, bodiless: bool) Error![]entity.Frame {
    const raw = try readAnimation(d.arena, d.rom, d.set, entry);
    const n = first orelse raw.frames.len;
    if (n > raw.frames.len) return error.BadData;
    const out = try d.arena.alloc(entity.Frame, n);
    for (out, raw.frames[0..n]) |*f, r| {
        if (r.mirrored) return error.BadData;
        f.* = .{
            .frame = try d.frameName(r.address),
            .ticks = @max(raw.timing, 1),
            .body = if (bodiless) null else try d.box(0, r.body, r.body, name, "body"),
        };
    }
    return out;
}

// --- The breakable ---------------------------------------------------------------------------------

/// The box that stops the fighters' walks (0x3C00), from 0x3C6A's first entry, which the types
/// $11 and $19 take (0x3BC4: d4 = 0 for them): across and in depth, both sides excluded; in
/// height, the body's of `d`'s first frame.
pub fn solidBox(d: *Def) Error!void {
    return solidBoxAt(d, 0);
}

/// The box that stops the fighters' walks (0x3C00) of the entry at byte `entry` of 0x3C6A's
/// table (a type's `moveq #N,d4`, 0x3BC4), as `solidBox`.
pub fn solidBoxAt(d: *Def, entry: u32) Error!void {
    const rom = d.rom;
    const solid = 0x3C6A + entry;
    const from_x = rom_mod.s16be(rom, solid);
    const span_x = rom_mod.s16be(rom, solid + 2);
    const from_d = rom_mod.s16be(rom, solid + 4);
    const span_d = rom_mod.s16be(rom, solid + 6);
    const body = d.boxes.items[d.animations.items[0].frames[0].body orelse return error.BadData];
    try d.boxes.append(d.arena, .{
        .name = "solid",
        .x = .{ .from = from_x + 1, .to = from_x + span_x - 1 },
        .depth = .{ .from = from_d + 1, .to = from_d + span_d - 1 },
        .height = body.height,
    });
    try d.number_notes.print(d.arena, "; solid: ROM 0x{X:0>5} (0x3C00: across and in depth, both sides excluded)", .{solid});
}

/// The pieces' table (0x6BD8): ten entries of their speed across and up (longs), their frame
/// (an animation number, by pairs) and an index into their offsets across (0x6BD4).
const pieces = 0x6BD8;
const piece_offsets = 0x6BD4;

/// The breakable (type $11): its stand and its blink (the set's first entry, the second frame a
/// blank one; broken, it meets nothing), its pieces' frames (entries 1 to 3), its body, the solid box that stops the
/// fighters (0x3C6A's first, for types $11 and $19: across from its place less 28 to plus 28,
/// in depth from less 10 to plus 4, both sides excluded), how it breaks and goes, the pieces'
/// flight.
fn breakable(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x6B0A, &.{ 0x43, 0xF9 }, 4));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "round1", .prefix = "breakable", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    try d.animations.append(arena, .{ .name = "stand", .loop = true, .frames = try entryFrames(&d, "stand", 0, 1, false) });
    try d.animations.append(arena, .{ .name = "blink", .loop = true, .frames = try entryFrames(&d, "blink", 0, null, true) });
    // The pieces' frames: the table's animation numbers 2, 4, 6 (entries 1 to 3).
    for (1..4) |k| {
        const name = try std.fmt.allocPrint(arena, "piece_{d}", .{k});
        try d.animations.append(arena, .{ .name = name, .loop = true, .frames = try entryFrames(&d, name, @intCast(k), null, false) });
    }
    // The solid box: 0x3C6A's first entry (type $11 takes it, 0x3BC6).
    if (u16be(rom, 0x3BC4) != 0x7800 or rom[0x3BC9] != 0x11) return error.BadData;
    try solidBox(&d);

    try d.number("height", try immediate(rom, 0x6B2C, &.{ 0x31, 0x7C }, 2), "ROM 0x06B2C: move.w #N,(24,a0)");
    try d.number("breaking", try moveByte(rom, 0x6B60, 71), "ROM 0x06B60: move.b #N,(71,a0)");
    try d.number("going", try moveByte(rom, 0x6C58, 71), "ROM 0x06C58: move.b #N,(71,a0)");
    try d.number("pieces", try moveq(rom, 0x6B84, 3) + 1, "ROM 0x06B84: moveq #N-1,d3 (dbf)");
    try d.number("piece_x", -(try immediate(rom, 0x6B76, &.{ 0x04, 0x44 }, 2)), "ROM 0x06B76: subi.w #-N,d4");
    if (u16be(rom, 0x6B7E) != 0x5845) return error.BadData;
    try d.number("piece_depth", 4, "ROM 0x06B7E: addq.w #4,d5");
    if (u16be(rom, 0x6B90) != 0x5146) return error.BadData;
    try d.number("piece_above", 8, "ROM 0x06B90: subq.w #8,d6 (before each piece)");
    try d.number("piece_gravity", try immediate(rom, 0x6C48, &.{ 0x06, 0xA8 }, 4), "ROM 0x06C48: addi.l #N,(36,a0)");
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A70)");
    const drawn = try drawnOffset(rom);
    try d.number("screen_from", try immediate(rom, 0xAABA, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AABA: cmpi.w #N,(40,a0), less 0xAF6E's offset (a blow lands on the screen)");
    try d.number("screen_to", try immediate(rom, 0xAAC2, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AAC2: cmpi.w #N,(40,a0), less 0xAF6E's offset (excluded)");

    const n = 10;
    var vx: [n]i32 = undefined;
    var vh: [n]i32 = undefined;
    var shown: [n]i32 = undefined;
    var off: [n]i32 = undefined;
    for (0..n) |k| {
        const e = pieces + 10 * @as(u32, @intCast(k));
        vx[k] = @bitCast(rom_mod.u32be(rom, e));
        vh[k] = @bitCast(rom_mod.u32be(rom, e + 4));
        const anim = rom[e + 8];
        if (anim == 0 or anim & 1 != 0 or anim / 2 > 3) return error.BadData;
        shown[k] = anim / 2;
        if (rom[e + 9] > 3) return error.BadData;
        off[k] = entities.s8(rom, piece_offsets + @as(u32, rom[e + 9]));
    }
    try d.table("piece_speed_x", try arena.dupe(i32, &vx), "ROM 0x06BD8: each piece's first long");
    try d.table("piece_speed_up", try arena.dupe(i32, &vh), "ROM 0x06BD8: each piece's second long");
    try d.table("piece_frame", try arena.dupe(i32, &shown), "ROM 0x06BD8: each piece's animation number / 2 (`piece_N`)");
    try d.table("piece_offset", try arena.dupe(i32, &off), "ROM 0x06BD8: each piece's index into ROM 0x06BD4's offsets across");
    try d.sound("shatter", @bitCast(@as(i8, @intCast(try moveq(rom, 0x6B56, 7)))));
    return .{
        .name = "breakable",
        .provenance = try std.fmt.allocPrint(arena, "the street's breakables, type $11 (handler 0x6AF4): the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "breakable",
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

// --- The items ---------------------------------------------------------------------------------

/// What an item gives (0x69F8's effects, by the item's kind).
const Gives = union(enum) {
    /// Health (`moveq #N,d7` at `at`, added by 0x4E6C).
    health: u32,
    /// A life or a special attack (0x10DCA adds the table's first amount, 0x10DDA).
    life,
    special,
    /// Points: the amount of the table at 0x10DDA (`moveq #N,d7` at `at`, 0x10DA6).
    points: u32,
};

const Item = struct {
    name: []const u8,
    /// Its art's prefix (`items/apple_00`).
    prefix: []const u8,
    /// Its first state (`lea.l SET,a1` there) and its type.
    start: u32,
    type: u8,
    gives: Gives,
    /// `moveq #N,d7` before its sound (0x5976).
    sound_at: u32,
};

const items = [_]Item{
    .{ .name = "apple", .prefix = "apple", .start = 0x693E, .type = 0x4B, .gives = .{ .health = 0x6A08 }, .sound_at = 0x6A0E },
    .{ .name = "beef", .prefix = "beef", .start = 0x699E, .type = 0x47, .gives = .{ .health = 0x6A04 }, .sound_at = 0x6A0E },
    .{ .name = "life", .prefix = "life", .start = 0x6960, .type = 0x4C, .gives = .life, .sound_at = 0x6A14 },
    .{ .name = "special_item", .prefix = "special", .start = 0x6980, .type = 0x4F, .gives = .special, .sound_at = 0x6A60 },
    .{ .name = "money", .prefix = "money", .start = 0x68FA, .type = 0x3F, .gives = .{ .points = 0x6A46 }, .sound_at = 0x6A60 },
    .{ .name = "gold", .prefix = "gold", .start = 0x691C, .type = 0x40, .gives = .{ .points = 0x6A4A }, .sound_at = 0x6A60 },
};

/// The amount `k` of the table at 0x10DDA, as 0x10DA6 adds it: its last three bytes, decimal
/// digits by pairs.
fn amount(rom: []const u8, k: u32) Error!u32 {
    var v: u32 = 0;
    for (1..4) |j| {
        const b = rom[0x10DDA + 4 * k + @as(u32, @intCast(j))];
        if (b >> 4 > 9 or b & 0xF > 9) return error.BadData;
        v = v * 100 + (b >> 4) * 10 + (b & 0xF);
    }
    return v;
}

/// The item `it`: its pose, how it falls, what it gives, its sound.
fn item(arena: std.mem.Allocator, rom: []const u8, it: Item) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, it.start, &.{ 0x43, 0xF9 }, 4));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "items", .prefix = it.prefix, .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    try d.animations.append(arena, .{ .name = "lying", .loop = true, .frames = try entryFrames(&d, "lying", 0, null, false) });
    try d.number("fall", (try immediate(rom, 0x69BC, &.{ 0x31, 0x7C }, 2)) << 16, "ROM 0x069BC: move.w #N,(36,a0) (whole pixels)");
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A70)");
    try d.number("health_most", try moveq(rom, 0x4E6C, 6), "ROM 0x04E6C: moveq #N,d6");
    var health: i32 = 0;
    var lives: i32 = 0;
    var specials: i32 = 0;
    var points: i32 = 0;
    switch (it.gives) {
        .health => |at| {
            health = try moveq(rom, at, 7);
            try d.number_notes.print(arena, "; health: ROM 0x{X:0>5}: moveq #N,d7", .{at});
        },
        .life => {
            lives = @intCast(try amount(rom, 0));
            try d.number_notes.print(arena, "; lives: the first amount of ROM 0x10DDA (0x10DCA)", .{});
        },
        .special => {
            specials = @intCast(try amount(rom, 0));
            try d.number_notes.print(arena, "; specials: the first amount of ROM 0x10DDA (0x10DCA)", .{});
        },
        .points => |at| {
            const k = try moveq(rom, at, 7);
            points = @intCast(try amount(rom, @intCast(k)));
            try d.number_notes.print(arena, "; points: amount N of ROM 0x10DDA, ROM 0x{X:0>5}: moveq #N,d7 (0x10DA6)", .{at});
        },
    }
    try d.numbers.appendSlice(arena, &.{
        .{ .name = "health", .value = health },
        .{ .name = "lives", .value = lives },
        .{ .name = "specials", .value = specials },
        .{ .name = "points", .value = points },
    });
    try d.sound("picked", @bitCast(@as(i8, @intCast(try moveq(rom, it.sound_at, 7)))));
    return .{
        .name = it.name,
        .provenance = try std.fmt.allocPrint(arena, "the {s}, type ${X:0>2}: the animation set at ROM 0x{X:0>5} (its first state, 0x{X:0>5}){s}", .{ it.name, it.type, set, it.start, d.number_notes.items }),
        .family = .item,
        .team = .neutral,
        .behaviour = "item",
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try breakable(arena, rom));
    for (items) |it| try out.append(arena, try item(arena, rom, it));
}

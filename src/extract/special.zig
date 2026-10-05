//! The special attack's things (docs/content.md, `entities/NAME.json`), each a definition read
//! from its animation set and from the immediate values of the code that runs it, with the place of
//! each in its provenance:
//! - `special_knockdown`, the special attack's own (type $29, 0x100B6): the camera's run back and
//!   ahead (0x18CC4, 0x18DC2), the car's coming (0x18CDE), and the knock-downs: player 1's by the
//!   blast's line in depth, player 2's one at a time;
//! - `police_car`, the car and its parts (type 5, 0x597C): the car, its officer, the bazooka and
//!   its flash and smoke (player 1's), the gun and its fire (player 2's);
//! - `special_blast`, player 1's (type $E, 0x654E): the rocket, and the ring of explosions it
//!   sets off;
//! - `special_fire`, player 2's (type $D, 0x63F6): the bullets' falls and impacts.
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const s16be = rom_mod.s16be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const moveq = entities.moveq;
const frameCompared = entities.frameCompared;
const readAnimation = entities.readAnimation;

/// `move.w #N,(D,aK)`: the word written (sign extended), the instruction checked.
fn movedWord(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    const op = u16be(rom, at);
    if (op != 0x317C and op != 0x3D7C) return error.BadData;
    if (u16be(rom, at + 4) != displacement) return error.BadData;
    return s16be(rom, at + 2);
}

/// `cmpi.w #N,(D,aK)` or `cmpi.w #N,dK`: the word compared.
fn comparedWord(rom: []const u8, at: u32) Error!i32 {
    const op = u16be(rom, at);
    if (op & 0xFFF8 != 0x0C40 and op != 0x0C68 and op != 0x0C69) return error.BadData;
    return s16be(rom, at + 2);
}

/// The frames of the set's animation `word` (its entry is half of it): each shown for the
/// animation's timing byte (a still picture's, 0, a tick at a time); their names in the set's
/// directory.
fn frames(d: *Def, word: u32) Error![]entity.Frame {
    const raw = try readAnimation(d.arena, d.rom, d.set, word / 2);
    if (raw.timing == 0 and raw.frames.len != 1) return error.BadData;
    const out = try d.arena.alloc(entity.Frame, raw.frames.len);
    for (out, raw.frames) |*f, r| f.* = .{ .frame = try d.frameName(r.address), .ticks = @max(raw.timing, 1), .flip = r.mirrored };
    return out;
}

fn animation(d: *Def, name: []const u8, word: u32) Error!void {
    try d.animations.append(d.arena, .{ .name = name, .loop = true, .frames = try frames(d, word) });
}

fn finish(d: *Def, name: []const u8, behaviour: []const u8, what: []const u8, hidden: bool) Error!entity.Definition {
    return .{
        .name = name,
        .provenance = try std.fmt.allocPrint(d.arena, "{s}{s}", .{ what, d.number_notes.items }),
        .family = .effect,
        .team = .neutral,
        .behaviour = behaviour,
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .animations = if (hidden) &.{} else d.animations.items,
    };
}

/// The calls of the art's decoder a block of `tiles` tiles takes (0x8554: five tiles a call).
fn calls(tiles: u32) u32 {
    return (tiles + 4) / 5;
}

/// The tiles of the art list `list`'s first block (0x8672: a word offset per list to its count
/// less one, then a long source and a word address per block; the block's header word & $7FFF).
fn listTiles(rom: []const u8, list: u32) Error!u32 {
    const at: u32 = @intCast(@as(i32, 0x8672) + s16be(rom, 0x8672 + 2 * list));
    if (u16be(rom, at) != 0) return error.BadData;
    const source = u32be(rom, at + 2);
    return u16be(rom, source) & 0x7FFF;
}

/// The ticks from the tick the car queues its art (the queue idle) to the tick it sees it all
/// loaded (2.2 of the reading): the decoder runs twice a tick, in the middle of the objects' run
/// and at its end; a job of c calls from the end of tick s ends at the end of tick s + (c−1)/2 if
/// c is odd, in the middle of tick s + c/2 if even; the next job starts at the end of the tick
/// the last ended in the middle of, else at the end of the next; the car (after the middle) sees
/// the queue empty in the tick of a middle finish, in the next after an end finish.
fn artTicks(first: u32, second: u32) u32 {
    var start: u32 = 0;
    var seen: u32 = 0;
    for ([_]u32{ first, second }) |tiles| {
        const c = calls(tiles);
        if (c % 2 == 1) {
            const end = start + (c - 1) / 2;
            start = end + 1;
            seen = end + 1;
        } else {
            const end = start + c / 2;
            start = end;
            seen = end;
        }
    }
    return seen;
}

/// The special attack's own: the camera's run, the car's coming, the knock-downs.
pub fn specialKnockdown(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "police", .set = 0x70A78, .box_table = entities.object_boxes, .frame_addresses = &.{} };
    const back = try immediate(rom, 0x18CC4, &.{ 0x23, 0x7C }, 4);
    if (try immediate(rom, 0x18DC2, &.{ 0x23, 0x7C }, 4) != -back) return error.BadData;
    try d.number("run", -back, "ROM 0x18CC4: move.l #N,(10,a1) (the camera's speed back; 0x18DC2 the same ahead)");
    try d.number("run_most", -(try immediate(rom, 0x192E4, &.{ 0x06, 0x80 }, 4)), "ROM 0x192E4: addi.l #N,d0 (to the camera's place at the call)");
    try d.number("comes", (try immediate(rom, 0x18CDE, &.{ 0x04, 0x40 }, 2)) << 16, "ROM 0x18CDE: subi.w #N,d0 (from the camera's place at the call: the car comes)");
    try d.number("arrives", -(try immediate(rom, 0x18CDE, &.{ 0x04, 0x40 }, 2) + try immediate(rom, 0x18D26, &.{ 0x04, 0x40 }, 2)), "ROM 0x18CDE, 0x18D26: subi.w #N,d0 (the car's place across from the camera's at the call)");
    try d.number("second_first", rom[0x10173], "ROM 0x10170: move.b #N,$FA42 (player 2's: the ticks to its first knock-down after the first bullet lands)");
    if (u16be(rom, 0x10170) != 0x11FC) return error.BadData;
    if (u16be(rom, 0x10186) != 0x11FC) return error.BadData;
    try d.number("second_every", rom[0x10189], "ROM 0x10186: move.b #N,$FA42 (player 2's: reloaded after each knock-down, which comes when the count goes below 0)");
    try d.number("rest_frame", try immediate(rom, 0x10144, &.{ 0x0C, 0x29, 0x00 }, 1), "ROM 0x10144: cmpi.b #N,(10,a1) (the last pass spares one in its knock-down's flight but at this frame)");
    return finish(&d, "special_knockdown", "special_knockdown", "the special attack's own (type $29, 0x100B6; the camera's run 0x18CC4, 0x18DC2, its limit 0x192E4), never drawn", true);
}

/// The police car and its parts.
pub fn policeCar(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set = 0x70A78;
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "police", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    // The parts' animations, by their state and animation pairs (0x5A02 player 1's, 0x5A0A
    // player 2's; the car's, $00).
    if (rom[0x5A05] != 4 or rom[0x5A07] != 8 or rom[0x5A0F] != 0x0C or rom[0x5A09] != 0x10 or rom[0x5A0B] != 0x14 or rom[0x5A11] != 0x18) return error.BadData;
    try animation(&d, "car", 0);
    try animation(&d, "officer", rom[0x5A05]);
    try animation(&d, "bazooka", rom[0x5A07]);
    try animation(&d, "gun", rom[0x5A0F]);
    try animation(&d, "flash", rom[0x5A09]);
    try animation(&d, "smoke", rom[0x5A0B]);
    try animation(&d, "gunfire", rom[0x5A11]);
    try d.number("depth", try movedWord(rom, 0x18D06, 0x14), "ROM 0x18D06: move.w #N,(20,a6)");
    try d.number("height", try movedWord(rom, 0x18D0C, 0x18), "ROM 0x18D0C: move.w #N,(24,a6)");
    // Its art: lists 0 and 9 (player 1's) or 10 (player 2's), queued as it comes (0x59D4).
    const car_tiles = try listTiles(rom, 0);
    const first = artTicks(car_tiles, try listTiles(rom, 9));
    if (first != artTicks(car_tiles, try listTiles(rom, 10))) return error.BadData;
    try d.number("art", @intCast(first), "the ticks its art takes to load (lists 0 and 9, or 10, at 0x8672: their blocks' tiles, five a decoder's call, two calls a tick, 0x8554)");
    try d.number("drive", (try movedWord(rom, 0x5A32, 0x1C)) << 16, "ROM 0x05A32: move.w #N,(28,a0)");
    try d.number("slowing", try immediate(rom, 0x5A96, &.{ 0x06, 0xA8 }, 4), "ROM 0x05A96: addi.l #N,(28,a0)");
    try d.number("brakes_ahead", try immediate(rom, 0x5AA6, &.{ 0x06, 0x40 }, 2), "ROM 0x05AA6: addi.w #N,d0 (the camera's place across and this; past it, it brakes)");
    try d.number("parked", try movedWord(rom, 0x5ABA, 0x52), "ROM 0x05ABA: move.w #N,(82,a0)");
    if (u16be(rom, 0x5A5E) & 0xF1FF != 0x506E) return error.BadData;
    try d.number("officer_depth", @as(i32, (u16be(rom, 0x5A5E) >> 9) & 7), "ROM 0x05A5E: addq.w #N,(20,a6)");
    try d.number("bazooka_up", try immediate(rom, 0x5AEC, &.{ 0x04, 0x6E }, 2), "ROM 0x05AEC: subi.w #N,(24,a6)");
    try d.number("bazooka_top", try immediate(rom, 0x5AF8, &.{ 0x04, 0x6E }, 2), "ROM 0x05AF8: subi.w #N,(96,a6) (up from the car's feet)");
    if (u16be(rom, 0x5B04) & 0xF1FF != 0x516E) return error.BadData;
    try d.number("bazooka_depth", @as(i32, (u16be(rom, 0x5B04) >> 9) & 7), "ROM 0x05B04: subq.w #N,(20,a6)");
    try d.number("rise", (try movedWord(rom, 0x5B0E, 0x24)) << 16, "ROM 0x05B0E: move.w #N,(36,a6)");
    try d.number("aim", try movedWord(rom, 0x5B34, 0x52), "ROM 0x05B34: move.w #N,(82,a0)");
    try d.number("smoke_after", try movedWord(rom, 0x5B72, 0x52), "ROM 0x05B72: move.w #N,(82,a6)");
    try d.number("gunfire", try movedWord(rom, 0x5B78, 0x54), "ROM 0x05B78: move.w #N,(84,a6)");
    try d.number("aim_ends", try frameCompared(rom, 0x5B94), "ROM 0x05B94: cmpi.b #N,(10,a0) (from it the bazooka stops)");
    try d.number("puff_ends", try frameCompared(rom, 0x5BD8), "ROM 0x05BD8: cmpi.b #N,(10,a0) (from it the flash and the smoke go, 0x05BEC)");
    if (try frameCompared(rom, 0x5BEC) != try frameCompared(rom, 0x5BD8)) return error.BadData;
    // Drawn this far behind the camera's place across, it goes (the drawing's, 0xAF86: its
    // place on the screen less 128).
    try d.number("gone_behind", (try immediate(rom, 0xAF86, &.{ 0x30, 0x3C }, 2)) - 0x80, "ROM 0x0AF86: move.w #N+$80,d0 (the drawing's left edge for its type, 0x0AF8A)");
    try d.sound("siren", @bitCast(@as(i8, @intCast(try moveq(rom, 0x5A18, 7)))));
    try d.sound("brakes", @bitCast(@as(i8, @intCast(try moveq(rom, 0x5AB0, 7)))));
    try d.sound("bazooka", @bitCast(@as(i8, @intCast(try moveq(rom, 0x5B8C, 7)))));
    try d.sound("gun", @bitCast(@as(i8, @intCast(try moveq(rom, 0x5B84, 7)))));
    return finish(&d, "police_car", "police_car", try std.fmt.allocPrint(arena, "the special attack's police car and its parts (type 5, 0x597C): the animation set at ROM 0x{X:0>5}", .{set}), false);
}

/// Player 1's blast: the rocket and the ring of explosions.
pub fn specialBlast(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @intCast(try immediate(rom, 0x6580, &.{ 0x22, 0x7C }, 4));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "special", .prefix = "blast", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    try animation(&d, "rocket", 0);
    const sizes = [_]u32{ 4, 6, 8, 0x0A, 0x0C };
    for (sizes, 1..) |w, k| try animation(&d, try std.fmt.allocPrint(arena, "blast_{d}", .{k}), w);
    // Its sizes, two ticks each (0x6720, the animations' words; the last ends it).
    var order: [12]i32 = undefined;
    for (&order, 0..) |*o, k| {
        const b = rom[0x6720 + k];
        o.* = if (b == 0xFF) 0 else for (sizes, 1..) |w, s| {
            if (w == b) break @as(i32, @intCast(s));
        } else return error.BadData;
    }
    if (order[11] != 0) return error.BadData;
    try d.table("sizes", &order, "ROM 0x06720 (the animations' words, 2 ticks each, 0x066C4; $FF ends it: here 0)");
    var across: [16]i32 = undefined;
    var depth: [16]i32 = undefined;
    across[0] = 0;
    depth[0] = 0;
    for (1..16) |n| {
        across[n] = entities.s8(rom, 0x66B4 + @as(u32, @intCast(n)));
        depth[n] = entities.s8(rom, 0x66A5 + @as(u32, @intCast(n)));
    }
    try d.table("ring_across", &across, "ROM 0x066B4 (by generation from 1: from its parent's place, the left arm's the other way)");
    try d.table("ring_depth", &depth, "ROM 0x066A5 (by generation from 1)");
    try d.number("hidden", try movedWord(rom, 0x6578, 0x50), "ROM 0x06578: move.w #N,(80,a0) (the rocket's ticks unseen)");
    try d.number("ahead", try immediate(rom, 0x65A2, &.{ 0x06, 0x68 }, 2), "ROM 0x065A2: addi.w #N,(16,a0) (from the camera's place)");
    try d.number("depth", try movedWord(rom, 0x65A8, 0x14), "ROM 0x065A8: move.w #N,(20,a0)");
    try d.number("height", try movedWord(rom, 0x65AE, 0x18), "ROM 0x065AE: move.w #N,(24,a0)");
    try d.number("fall", (try movedWord(rom, 0x65CE, 0x24)) << 16, "ROM 0x065CE: move.w #N,(36,a0)");
    try d.number("drift", (try movedWord(rom, 0x65D4, 0x1C)) << 16, "ROM 0x065D4: move.w #N,(28,a0)");
    try d.number("fuse", try movedWord(rom, 0x65EE, 0x50), "ROM 0x065EE: move.w #N,(80,a0) (landed, the ticks to its explosion)");
    try d.number("ring_fuse", try movedWord(rom, 0x658C, 0x50), "ROM 0x0658C: move.w #N,(80,a0) (an explosion's, to its own)");
    try d.number("size_ticks", (try movedWord(rom, 0x6630, 0x52)) >> 8, "ROM 0x06630: move.w #N*$100+1,(82,a0)");
    try d.number("generations", try comparedWord(rom, 0x663A), "ROM 0x0663A: cmpi.w #N,(86,a0) (the last generation)");
    try d.number("line_above", try immediate(rom, 0x66EA, &.{ 0x04, 0x78 }, 2), "ROM 0x066EA: subi.w #N,$FB40 (the line, from the depth of an explosion at its largest)");
    try d.number("rest_generation", try comparedWord(rom, 0x66F0), "ROM 0x066F0: cmpi.w #N,(86,a0) (at its largest: the rest are knocked down)");
    try d.number("last_wait", try movedWord(rom, 0x6714, 0x50), "ROM 0x06714: move.w #N,(80,a0) (the last generation's, unseen, to the special attack's end)");
    try d.sound("launch", @bitCast(@as(i8, @intCast(try moveq(rom, 0x65B8, 7)))));
    try d.sound("explosion", @bitCast(@as(i8, @intCast(try moveq(rom, 0x6626, 7)))));
    return finish(&d, "special_blast", "special_blast", try std.fmt.allocPrint(arena, "player 1's special attack's rocket and blast (type $E, 0x654E): the animation set at ROM 0x{X:0>5}", .{set}), false);
}

/// Player 2's fire: the bullets.
pub fn specialFire(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @intCast(try immediate(rom, 0x643C, &.{ 0x22, 0x7C }, 4));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "special", .prefix = "fire", .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    try animation(&d, "falling", 0);
    try animation(&d, "impact", 4);
    var across: [16]i32 = undefined;
    var depth: [16]i32 = undefined;
    for (0..16) |k| {
        across[k] = s16be(rom, 0x64B2 + 4 * @as(u32, @intCast(k)));
        depth[k] = s16be(rom, 0x64B4 + 4 * @as(u32, @intCast(k)));
    }
    try d.table("across", &across, "ROM 0x064B2 (by bullet & 15: from the camera's place, less `behind`)");
    try d.table("depth", &depth, "ROM 0x064B4");
    try d.number("hidden", try movedWord(rom, 0x6436, 0x50), "ROM 0x06436: move.w #N,(80,a0)");
    try d.number("every", try movedWord(rom, 0x644E, 0x50), "ROM 0x0644E: move.w #N,(80,a0)");
    try d.number("bullets", try comparedWord(rom, 0x649C), "ROM 0x0649C: cmpi.w #N,(82,a0)");
    try d.number("last_wait", try movedWord(rom, 0x64AA, 0x50), "ROM 0x064AA: move.w #N,(80,a0)");
    try d.number("behind", try immediate(rom, 0x648A, &.{ 0x04, 0x41 }, 2), "ROM 0x0648A: subi.w #N,d1");
    try d.number("drift", (try movedWord(rom, 0x6476, 0x1C)) << 16, "ROM 0x06476: move.w #N,(28,a6)");
    try d.number("fall", (try movedWord(rom, 0x647C, 0x24)) << 16, "ROM 0x0647C: move.w #N,(36,a6)");
    try d.number("gravity", try immediate(rom, 0x64F2, &.{ 0x06, 0xA8 }, 4), "ROM 0x064F2: addi.l #N,(36,a0)");
    try d.number("impact_ends", try frameCompared(rom, 0x6532), "ROM 0x06532: cmpi.b #N,(10,a0)");
    if (u16be(rom, 0x6516) != 0x11FC) return error.BadData;
    try d.number("shake", rom[0x6519], "ROM 0x06516: move.b #N,$FA45 (the first impact shakes the screen so many ticks)");
    try d.sound("fire", @bitCast(@as(i8, @intCast(try moveq(rom, 0x642C, 7)))));
    return finish(&d, "special_fire", "special_fire", try std.fmt.allocPrint(arena, "player 2's special attack's fire (type $D, 0x63F6): the animation set at ROM 0x{X:0>5}", .{set}), false);
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try specialKnockdown(arena, rom));
    try out.append(arena, try policeCar(arena, rom));
    try out.append(arena, try specialBlast(arena, rom));
    try out.append(arena, try specialFire(arena, rom));
}

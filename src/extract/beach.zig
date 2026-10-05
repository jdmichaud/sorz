//! Round 3's scenery, the beach's (docs/content.md, `entities/NAME.json`): each a definition read
//! from its animation set and from the immediate values of the code that runs it, with the place
//! of each in its provenance.
//!
//! - The lamp (type $4E, its handler 0x71DC, sor-remaster's obj/round3.zig): it stands at its
//!   height, drawn behind what stands at its depth; once the boss's bar shows, it is lit.
//! - The crate (type $18, 0x70C4): a stack of tyres that stands solid until a player's blow or
//!   a thing thrown breaks it into four pieces (crates themselves), which fall, bounce once and
//!   go; it leaves the item it holds (0x7E54).
//! - The rain (type $17, 0x6F7C): hidden until the camera nears it, then five showers of seven
//!   raindrops (rain themselves) falling on the screen, the sky flashing (its colours, 0x708A);
//!   the special attack ends it.
//! - The drifter (type $16, 0x7214): a piece of flotsam on the sea's edge that stays, drifts
//!   away, drifts and stops in turn, or rides the waves, as its record says (round.zig's
//!   `drift`).
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const entities = @import("entities.zig");
const items = @import("items.zig");
const rounds = @import("rounds.zig");

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const s16be = rom_mod.s16be;
const Def = entities.Def;
const Error = entities.Error;
const immediate = entities.immediate;
const entryFrames = items.entryFrames;

/// `move.w #N,(D,a0)` at `at`: N, the displacement checked.
fn moveWord(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at + 4) != displacement) return error.BadData;
    return immediate(rom, at, &.{ 0x31, 0x7C }, 2);
}

/// A definition of the round's art set at `set` (`round3/PREFIX_NN`).
fn def(arena: std.mem.Allocator, rom: []const u8, prefix: []const u8, set: u32) Error!Def {
    return .{ .arena = arena, .rom = rom, .dir = "round3", .prefix = prefix, .set = set, .box_table = entities.object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
}

/// The lamp (type $4E): its two frames (entry 0, held still: unlit, lit), its height.
fn lamp(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x71F4, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "lamp", set);
    const frames = try entryFrames(&d, "lamp", 0, null, true);
    if (frames.len != 2) return error.BadData;
    try d.animations.append(arena, .{ .name = "lamp", .loop = true, .frames = frames });
    try d.number("height", try moveWord(rom, 0x71EE, 24), "ROM 0x071EE: move.w #N,(24,a0)");
    // Lit (0x71FE): the boss's section begun ($FFFA05 bit 6) and a boss's bar shown ($FFF50E).
    if (u32be(rom, 0x71FE) != 0x08380006 or u16be(rom, 0x7202) != 0xFA05 or u16be(rom, 0x7206) != 0x3038 or u16be(rom, 0x7208) != 0xF50E) return error.BadData;
    return .{
        .name = "lamp",
        .provenance = try std.fmt.allocPrint(arena, "round 3's lamps, type $4E (handler 0x71DC): the animation set at ROM 0x{X:0>5}; lit (its second frame) once the boss's bar shows (0x71FE){s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "lamp",
        .numbers = d.numbers.items,
        .animations = d.animations.items,
    };
}

/// `moveq #N,dR` at `at`, the register `reg` checked: N.
fn moveqOf(rom: []const u8, at: u32, reg: u3) Error!i32 {
    const w = u16be(rom, at);
    if (w & 0xF100 != 0x7000 or (w >> 9) & 7 != reg) return error.BadData;
    return @as(i8, @bitCast(@as(u8, @truncate(w))));
}

/// The crate (type $18): its stand (entry 0, its body), a piece's frames (entry 1: the piece,
/// none; still until it bounces, then blinking), the solid box of its type (0x3BD6), its pieces'
/// numbers and speeds, its sound.
fn crate(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x70DC, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "obstacle", set);
    try d.animations.append(arena, .{ .name = "stand", .loop = true, .frames = try entryFrames(&d, "stand", 0, null, false) });
    try d.animations.append(arena, .{ .name = "piece", .loop = true, .frames = try entryFrames(&d, "piece", 1, null, true) });
    // The solid box: type $18 takes the table's entry at byte 8 (0x3BD6: moveq #8,d4, then
    // cmpi.b #$18,(0,a1)).
    if (u16be(rom, 0x3BD6) != 0x7808 or u16be(rom, 0x3BD8) != 0x0C29 or rom[0x3BDB] != 0x18) return error.BadData;
    try items.solidBoxAt(&d, 8);
    try d.number("height", try moveWord(rom, 0x70FA, 24), "ROM 0x070FA: move.w #N,(24,a0)");
    try d.number("pieces", try moveqOf(rom, 0x716A, 2) + 1, "ROM 0x0716A: moveq #N,d2, a dbra's (N + 1 pieces)");
    const first = try moveqOf(rom, 0x716C, 5);
    if (first != 6 or u16be(rom, 0x71AA) != 0x5545) return error.BadData;
    try d.number("above", -s16be(rom, 0x7174), "ROM 0x07172: addi.w #N,d4 to its height (the first piece's, above it)");
    if (u16be(rom, 0x7172) != 0x0644 or u16be(rom, 0x71AC) != 0x0644) return error.BadData;
    try d.number("step", s16be(rom, 0x71AE), "ROM 0x071AC: addi.w #N,d4 (each next piece's, lower)");
    if (u16be(rom, 0x7104) != 0x06A8 or u16be(rom, 0x710A) != 36) return error.BadData;
    try d.number("gravity", @bitCast(u32be(rom, 0x7106)), "ROM 0x07104: addi.l #N,(36,a0)");
    if (u16be(rom, 0x7124) != 0x0C28 or u16be(rom, 0x7128) != 80) return error.BadData;
    try d.number("bounces", rom[0x7127], "ROM 0x07124: cmpi.b #N,(80,a0) (its landings: at this one, it goes)");
    // The pieces' speeds (whole pixels, a word each): up by piece (0x71D4, from the word at
    // byte 6 down by 2), across by piece and side (0x71C4, the left's then the right's).
    var up: [4]i32 = undefined;
    var left: [4]i32 = undefined;
    var right: [4]i32 = undefined;
    for (0..4) |k| {
        const off: u32 = @intCast(6 - 2 * k);
        up[k] = s16be(rom, 0x71D4 + off);
        left[k] = s16be(rom, 0x71C4 + 2 * off);
        right[k] = s16be(rom, 0x71C4 + 2 * off + 2);
    }
    try d.table("piece_up", &up, "ROM 0x071D4: words, the first piece's at byte 6, the next 2 less (0x7198: move.w (0x71D4,pc,d3.w),(36,a6))");
    try d.table("piece_left", &left, "ROM 0x071C4: words at twice the piece's byte, to the left (0x71A4: move.w (0x71C4,pc,d3.w),(28,a6))");
    try d.table("piece_right", &right, "ROM 0x071C4: the next word, to the right");
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A70)");
    const drawn = try items.drawnOffset(rom);
    try d.number("screen_from", try immediate(rom, 0xAABA, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AABA: cmpi.w #N,(40,a0), less 0xAF6E's offset (a blow lands on the screen)");
    try d.number("screen_to", try immediate(rom, 0xAAC2, &.{ 0x0C, 0x68 }, 2) - drawn, "ROM 0x0AAC2: cmpi.w #N,(40,a0), less 0xAF6E's offset (excluded)");
    const broken = try moveqOf(rom, 0x7160, 7);
    if (try moveqOf(rom, 0x713A, 7) != broken) return error.BadData;
    try d.sound("broken", @bitCast(@as(i8, @intCast(broken))));
    return .{
        .name = "crate",
        .provenance = try std.fmt.allocPrint(arena, "round 3's crates, type $18 (handler 0x70C4): the animation set at ROM 0x{X:0>5}; broken (0x715A), its pieces in the pieces' places (0x7EEA), each falling (0x7104){s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "crate",
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
    };
}

/// `move.l #N,(D,a0)` at `at`: N, the displacement checked.
fn moveLong(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at) != 0x217C or u16be(rom, at + 6) != displacement) return error.BadData;
    return @bitCast(u32be(rom, at + 2));
}

/// `cmpi.w #N,(D,a0)` at `at`: N, the displacement checked.
fn cmpWord(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at) != 0x0C68 or u16be(rom, at + 4) != displacement) return error.BadData;
    return u16be(rom, at + 2);
}

/// `move.b #N,(D,a0)` at `at`: N, the displacement checked.
fn moveByteAt(rom: []const u8, at: u32, displacement: u16) Error!i32 {
    if (u16be(rom, at) != 0x117C or u16be(rom, at + 4) != displacement) return error.BadData;
    return rom[at + 3];
}

/// The drifter (type $16): its frames (entry 0, two, its animation's pace; still while it
/// stays), its height, its ways of drifting (0x7226's states by its record's byte $40).
fn drifter(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x7246, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "drifter", set);
    try d.animations.append(arena, .{ .name = "drift", .loop = true, .frames = try entryFrames(&d, "drift", 0, null, true) });
    try d.number("height", try moveWord(rom, 0x7238, 24), "ROM 0x07238: move.w #N,(24,a0)");
    // Its speeds across (raw, 1/65536 pixel): the words of 0x727A (drifting away) and of 0x72D2
    // (drifting and stopping), sign-extended (ext.l), by a draw's low 3 bits.
    var away: [8]i32 = undefined;
    var stops: [8]i32 = undefined;
    for (&away, &stops, 0..) |*a, *s, k| {
        a.* = s16be(rom, 0x727A + 2 * @as(u32, @intCast(k)));
        s.* = s16be(rom, 0x72D2 + 2 * @as(u32, @intCast(k)));
    }
    if (u16be(rom, 0x7260) != 0x0240 or u16be(rom, 0x7262) != 7 or u16be(rom, 0x7298) != 0x0240 or u16be(rom, 0x72A0) != 0x0240 or u16be(rom, 0x72A2) != 7) return error.BadData;
    try d.table("away", &away, "ROM 0x0727A: words, sign-extended (0x7252: by a draw's andi.w #7)");
    try d.table("stops", &stops, "ROM 0x072D2: words, sign-extended (0x728A: by the draw's andi.w #7)");
    try d.number("drift_most", u16be(rom, 0x729A), "ROM 0x07298: andi.w #N,d0 (its drift's ticks, a draw's)");
    try d.number("stop", try moveByteAt(rom, 0x72BE, 80), "ROM 0x072BE: move.b #N,(80,a0) (its stop's ticks)");
    // The waves' rider (0x72F4): at the waves' step (cmpi.w #N,($FFFB1A)), it rises at its speed,
    // slowed each tick, to its depth's top; it waits, then comes back to its depth's bottom.
    if (u16be(rom, 0x72F4) != 0x0C78 or u16be(rom, 0x72F8) != 0xFB1A) return error.BadData;
    try d.number("wave_step", u16be(rom, 0x72F6), "ROM 0x072F4: cmpi.w #N,($FFFB1A) (the round's animation's step it rises at)");
    try d.number("rise", try moveLong(rom, 0x7302, 32), "ROM 0x07302: move.l #N,(32,a0)");
    try d.number("rise_slows", try immediate(rom, 0x7312, &.{ 0x06, 0xA8 }, 4), "ROM 0x07312: addi.l #N,(32,a0)");
    try d.number("top", try cmpWord(rom, 0x731E, 20), "ROM 0x0731E: cmpi.w #N,(20,a0) (its depth's, below it it waits)");
    try d.number("wait", try moveByteAt(rom, 0x732C, 80), "ROM 0x0732C: move.b #N,(80,a0)");
    try d.number("back", try moveLong(rom, 0x7346, 32), "ROM 0x07346: move.l #N,(32,a0)");
    try d.number("bottom", try cmpWord(rom, 0x735A, 20), "ROM 0x0735A: cmpi.w #N,(20,a0) (from it it waits for the waves again)");
    try d.number("left_behind", try immediate(rom, 0x6A7C, &.{ 0x04, 0x40 }, 2), "ROM 0x06A7C: subi.w #N,d0 (from the camera's place across, 0x6A70)");
    return .{
        .name = "drifter",
        .provenance = try std.fmt.allocPrint(arena, "round 3's drifting scenery, type $16 (handler 0x7214): the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "drifter",
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .animations = d.animations.items,
    };
}

/// The rain (type $17): its frames (entry 0: none, the drops; animated), when it comes, its
/// showers, its raindrops (their places on the screen, 0x702C; their fall), its sky's flash and
/// the colours of each of its steps, and the sky's colours after it.
fn rain(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set: u32 = @bitCast(try immediate(rom, 0x6FBE, &.{ 0x43, 0xF9 }, 4));
    var d = try def(arena, rom, "rain", set);
    try d.animations.append(arena, .{ .name = "rain", .loop = true, .frames = try entryFrames(&d, "rain", 0, null, true) });
    // Hidden until the camera's limit behind, plus N, reaches its place across (0x6F94).
    if (u16be(rom, 0x6FA0) != 0x3038 or u16be(rom, 0x6FA2) != 0xE01E) return error.BadData;
    try d.number("appears_within", try immediate(rom, 0x6FA4, &.{ 0x06, 0x40 }, 2), "ROM 0x06FA4: addi.w #N,d0 (to the camera's limit behind, $FFE01E)");
    try d.number("showers", try moveByteAt(rom, 0x6FE4, 82), "ROM 0x06FE4: move.b #N,(82,a0)");
    try d.number("shower_ticks", try moveWord(rom, 0x7020, 80), "ROM 0x07020: move.w #N,(80,a0) (from one shower to the next)");
    try d.number("drops", try moveqOf(rom, 0x6FF2, 6) + 1, "ROM 0x06FF2: moveq #N,d6, a dbra's (N + 1 drops)");
    try d.number("drop_across", (try moveWord(rom, 0x6FCA, 28)) << 16, "ROM 0x06FCA: move.w #N,(28,a0), whole pixels");
    try d.number("drop_down", (try moveWord(rom, 0x6FD0, 36)) << 16, "ROM 0x06FD0: move.w #N,(36,a0), whole pixels");
    try d.number("drop_end", try cmpWord(rom, 0x707C, 24), "ROM 0x0707C: cmpi.w #N,(24,a0) (from this height down, it goes)");
    // The sky's flash (0x708A): a step every N + 1 ticks ($FFFA5F counts down below zero), of M.
    if (u16be(rom, 0x7090) != 0x11FC or u16be(rom, 0x7094) != 0xFA5F or u16be(rom, 0x709A) != 0x0C38 or u16be(rom, 0x709E) != 0xFA5E) return error.BadData;
    try d.number("flash_ticks", rom[0x7093], "ROM 0x07090: move.b #N,($FFFA5F) (a step every N + 1 ticks)");
    try d.number("flash_steps", rom[0x709D], "ROM 0x0709A: cmpi.b #N,($FFFA5E)");
    if (rom[0x709D] != rounds.rain_flashes) return error.BadData;
    // The raindrops' places on the screen (0x702C: 7 x 3 words, across, depth, height).
    const drops: u32 = 0x702C;
    if (u16be(rom, 0x6FF4) != 0x43FA or 0x6FF6 + u16be(rom, 0x6FF6) != drops) return error.BadData;
    var x: [7]i32 = undefined;
    var depth: [7]i32 = undefined;
    var height: [7]i32 = undefined;
    for (0..7) |k| {
        const at = drops + 6 * @as(u32, @intCast(k));
        x[k] = s16be(rom, at);
        depth[k] = s16be(rom, at + 2);
        height[k] = s16be(rom, at + 4);
    }
    try d.table("drop_x", &x, "ROM 0x0702C: each drop's first word (its place across on the screen)");
    try d.table("drop_depth", &depth, "ROM 0x0702C: each drop's second word");
    try d.table("drop_height", &height, "ROM 0x0702C: each drop's third word");
    // The sky's colours: each flash step's (the list at 0x70BA + 2 a step, 0x70AE), and after the
    // rain (0x706E: lea to the list at 0x70C0).
    if (u32be(rom, 0x70AE) != 0x4DFB000A or u16be(rom, 0x706E) != 0x4DFA) return error.BadData;
    const after = 0x7070 + @as(u32, u16be(rom, 0x7070));
    if (after < rounds.rain_flash or (after - rounds.rain_flash) % 2 != 0 or (after - rounds.rain_flash) / 2 >= rounds.rain_flashes) return error.BadData;
    var colours: std.ArrayList(entity.Colours) = .empty;
    for (0..rounds.rain_flashes) |s| try colours.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "flash_{d}", .{s + 1}),
        .palette = try std.fmt.allocPrint(arena, "round3/flash_{d}", .{s + 1}),
    });
    try colours.append(arena, .{ .name = "after", .palette = try std.fmt.allocPrint(arena, "round3/flash_{d}", .{(after - rounds.rain_flash) / 2 + 1}) });
    return .{
        .name = "rain",
        .provenance = try std.fmt.allocPrint(arena, "round 3's rain, type $17 (handler 0x6F7C): the animation set at ROM 0x{X:0>5}; its showers (0x6FEE), its raindrops in the pieces' places (0x7EEA) else the last free below (0x7E92), the sky's flash (0x708A), its colours after it (0x706E){s}", .{ set, d.number_notes.items }),
        .family = .scenery,
        .team = .neutral,
        .behaviour = "rain",
        .numbers = d.numbers.items,
        .tables = d.tables.items,
        .animations = d.animations.items,
        .colours = colours.items,
    };
}

/// The definitions this module writes, appended to `out`.
pub fn all(arena: std.mem.Allocator, rom: []const u8, out: *std.ArrayList(entity.Definition)) Error!void {
    try out.append(arena, try lamp(arena, rom));
    try out.append(arena, try crate(arena, rom));
    try out.append(arena, try drifter(arena, rom));
    try out.append(arena, try rain(arena, rom));
}

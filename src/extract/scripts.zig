//! The rounds' scripts (docs/content.md, `rounds/NAME.json`): what the original's level events
//! (0x436, gameplay port map; sor-remaster's sim/level/events.zig) do in a round, read from the
//! ROM's tables and written as the round's sections, waves and boss.
//!
//! The ROM's places:
//! - the spawn lists, a Nemesis stream per round (word offsets at 0x1B036), unpacked at the
//!   round's start (0xE5C) and read in order: per section, three groups placed ahead (0xCC0: a
//!   count less one, then 6 bytes an entry: the type, three bytes the enemy's code reads, the X's
//!   low byte, the Y), the timed wave (0x784: a delay word before each 6-byte entry: the type,
//!   the three bytes, the Y, the side; a delay of $0099 ends it), and the entries waiting for a
//!   free slot (0x810: a size word, then 6-byte entries as the wave's, $99 ending them). The X of
//!   a group's entry is the page of the placing step (0x1C1BC), a page more after each group;
//!   the Y's low two bits are the lowest difficulty the entry comes at; type bit 7 marks an entry
//!   only for two players;
//! - the sections (0x1C1C4: per round, word offsets to its entries; the first holds the lists'
//!   start and the placing step, then the four art kinds the section loads, as each later
//!   entry does);
//! - the walls (0x195D8, the camera's right limit by section), the camera's place and first
//!   limits (the round header, the limits' sets at 0x1998A), the timer (0x195F6, 0x10C88), the
//!   music (0x11B44), the boss's arrival (0x59C).
//!
//! The times between the events are the original's loads of art: a section opens, and a waiting
//! entry comes in, once its kinds' art is in video memory (0xD70, 0xB76). The loads are streamed
//! at five tiles a display tick (0x8510) one block after the other (0x84BA), which this module
//! counts from the blocks' sizes (the load lists at 0x8672) to give the script its ticks; and the
//! decoding's display ticks themselves, the work the sound's timing reads (stream.zig: each
//! section's, the boss's, each waiting entry's `streamed`).
const std = @import("std");
const sorz = @import("sorz");
const round = sorz.content.round;
const nemesis = @import("nemesis.zig");
const kosinski = @import("kosinski.zig");
const rom_mod = @import("rom.zig");
const sound_names = @import("sound_names.zig");
const spawns = @import("spawns.zig");
const palettes = @import("palettes.zig");
const rounds = @import("rounds.zig");
const stream = @import("stream.zig");
const scenery = @import("scenery.zig");
const entities = @import("entities.zig");

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const s16be = rom_mod.s16be;

pub const Error = error{ OutOfMemory, BadData } || nemesis.Error || kosinski.Error;

/// Word offsets per round to its spawn lists (Nemesis).
const spawn_lists = 0x1B036;
/// Word offsets per round to its sections' entries; the placing steps (two words each).
const sections_table = 0x1C1C4;
const placing_steps = 0x1C1BC;
/// The camera's walls by section (0x19570 reads them), the limits' sets (0x19922).
const camera_stops = 0x195D8;
const camera_limits = 0x1998A;
/// The round's music by round (0x11B12).
const round_music = 0x11B44;
/// The load lists (0x8454): word offsets to each list: a count less one, then 6 bytes a load,
/// the block's address and its video address.
const load_lists = 0x8672;
/// The boss of each round (0x576): 6 bytes a round, the palette list's address and the art load.
const round_bosses = 0x1C378;
/// The art kind of each common enemy type ($20 to $2A), the first art load (0x9CA).
const art_of_type = 0xA4E;
/// The first enemies' colours of each common enemy type (0xA66: by the type less $20).
const palette_of_type = 0xA5A;
const first_art_load = 0xB;
/// The items a breakable holds, by its entry's index from 1 (0x7E54).
const breakable_items = 0x7E85;
/// Per round, a word offset to its pair of word offsets to the floor cells' attributes and
/// heights (0x19BD8).
const floor_tables = 0x19C04;
/// The offsets an enemy keeps from its target, by a nibble (0x9484).
const target_offsets = 0x9484;
/// The tiles one display tick streams (0x8510).
const tiles_a_display_tick = 5;

/// The list's end and the wave's last delay.
const end_mark = 0x99;
const wave_end: u16 = 0x0099;

/// The rounds' loads (mode $28, 0x106EA, the picture dark) as the original's last, in display
/// ticks: measured, sor-remaster's (its load_times.zig, from the captures of the original: round
/// 1's at VBlank 1139, round 2's at 17526); the others' are the flow's until they are measured.
const measured_loads = [_]u16{ 53, 49 };

/// The rounds whose scripts the extractor writes (PLAN items 13 and 15: rounds 1 to 7; the others
/// to come).
pub const extracted = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

/// The kinds' names of the original's object types: the traces' (sor-remaster's docs/traces.md),
/// but the pepper's (type $0C, the traces' bottle).
fn kindName(t: u8) ?[]const u8 {
    return switch (t) {
        0x08 => "knife",
        0x09 => "bat",
        0x0A => "pipe",
        0x0B => "pipe_b",
        0x0C => "pepper",
        0x11 => "breakable",
        0x13 => "flight_scenery",
        0x14 => "drip",
        0x15 => "statue",
        0x16 => "drifter",
        0x17 => "rain",
        0x18 => "crate",
        0x19 => "knockable",
        0x1B => "obstacle_1b",
        0x1C => "obstacle_1c",
        0x1D => "obstacle_1d",
        0x1F => "obstacle_1f",
        0x20 => "galsia_knife",
        0x21 => "galsia_stalker",
        0x22 => "galsia",
        0x23 => "galsia_pipe",
        0x24 => "signal",
        0x25 => "acrobat",
        0x26 => "brawler",
        0x27 => "juggler",
        0x28 => "juggler_knife",
        0x2A => "acrobat_trio",
        0x30 => "boss_r3",
        0x3F => "money",
        0x40 => "gold",
        0x41 => "shatter",
        0x42 => "press",
        0x45 => "trolley",
        0x47 => "beef",
        0x4B => "apple",
        0x4C => "life",
        0x4D => "flight",
        0x4E => "lamp",
        0x4F => "special_item",
        0x50 => "lift_wall",
        0x51 => "lift_rails",
        0x52 => "lift_floor",
        0x53 => "lift_opener",
        0x55 => "boss_r2",
        0x56 => "antonio",
        0x57 => "boss_r4",
        0x58 => "boss_r5",
        else => null,
    };
}

fn commonEnemy(t: u8) bool {
    return t >= 0x20 and t <= 0x2A;
}

fn boss(t: u8) bool {
    return t >= 0x55 and t <= 0x58;
}

fn soundName(request: u8) Error![]const u8 {
    for (sound_names.entries) |e| if (e.request == request) return e.name;
    return error.BadData;
}

/// The immediate operand of the instruction at `at`, after its opcode bytes `opcode` (checked:
/// a ROM that differs there is refused).
fn immediate(rom: []const u8, at: u32, opcode: []const u8, width: u8) Error!u32 {
    if (at + opcode.len + width > rom.len) return error.BadData;
    if (!std.mem.eql(u8, rom[at..][0..opcode.len], opcode)) return error.BadData;
    const v = at + @as(u32, @intCast(opcode.len));
    return switch (width) {
        1 => rom[v],
        2 => u16be(rom, v),
        else => error.BadData,
    };
}

/// Plane `p`'s bands in round `r`'s layout record (0x199C6: per band its rows less one, its
/// ratio's times and per, its first row, then its chunks to a negative word and the next band's
/// offset; a negative word ends the list).
fn bandsOf(arena: std.mem.Allocator, rom: []const u8, r: u32, p: u32) Error![]const round.Band {
    var a: u32 = rounds.layout_table + @as(u32, u16be(rom, rounds.layout_table + 4 * r + 2 * p)) + 6;
    // The vertical layout (round 7's: its planes' limits' set the one of 0x19A16's `cmpi.w`) has
    // one band, its chunks laid out by 0x19A70 after its header.
    if (u16be(rom, 0x19A16) != 0x0C69 or u16be(rom, 0x19A1A) != 66 or u16be(rom, 0x19A1C) != 0x6752) return error.BadData;
    const vertical = u16be(rom, rounds.header(rom, r) + 32 + 12 * p + 4) == u16be(rom, 0x19A18);
    var out: std.ArrayList(round.Band) = .empty;
    while (true) {
        const rows_less = s16be(rom, a);
        if (rows_less < 0) break;
        const times = u16be(rom, a + 2);
        const per = u16be(rom, a + 4);
        if (rows_less > @as(i16, if (vertical) 95 else 63) or times == 0 or per == 0 or times > 255 or per > 255) return error.BadData;
        try out.append(arena, .{ .rows = @intCast(rows_less + 1), .times = @intCast(times), .per = @intCast(per) });
        if (vertical) break;
        a += 8;
        while (s16be(rom, a) >= 0) a += 2;
        a += 4;
        if (out.items.len > 8) return error.BadData;
    }
    return out.items;
}

/// A plane's bands in its mode 1 (plane A's 0x18C70, plane B's 0x19368): each band's place across
/// is the plane's (its layer's X set to the plane's: 0x18D04, 0x1937E), its layout record's ratio
/// unread.
fn atPlaneX(arena: std.mem.Allocator, bands: []const round.Band) Error![]const round.Band {
    const out = try arena.alloc(round.Band, bands.len);
    for (out, bands) |*o, b| o.* = .{ .rows = b.rows, .times = 1, .per = 1 };
    return out;
}

/// A plane's bands in its mode (the round header's mode word): in mode 0 (plane A's 0x18C4A,
/// plane B's 0x1934A) each band's place across is the camera's X times its layout record's
/// ratio (0x190EA: muls.w, then divs.w), in mode 1 the plane's (`atPlaneX`); in mode 2 plane A's
/// is its mode 1 (the camera's table at 0x18C34 runs 0x18C70 for both), plane B's the water's
/// (`waterOf`), the plane's too; in mode 3 (the lift's: plane A's 0x18C92, plane B's 0x1938E)
/// the plane's, which stays across. The other modes are the special attack's.
fn bandsInMode(arena: std.mem.Allocator, rom: []const u8, r: u32, p: u32, mode: u16) Error![]const round.Band {
    const bands = try bandsOf(arena, rom, r, p);
    return switch (mode) {
        0 => if (p == 1) try drifting(arena, rom, r, bands) else bands,
        1 => atPlaneX(arena, bands),
        2 => {
            if (p == 0 and u16be(rom, 0x18C36) != u16be(rom, 0x18C38)) return error.BadData;
            return atPlaneX(arena, bands);
        },
        3 => atPlaneX(arena, bands),
        else => error.BadData,
    };
}

/// The way round `r`'s enemies walk off in depth, when the round has its own (0xDBCC: tested on
/// the round's number before the kind's and the target's way): round 6's down (0xDC3C), round
/// 7's down before a place across and up from it (0xDC44, 0xDC4C), round 4's up (0xDC56).
fn walkOffOf(rom: []const u8, r: u32) Error!?round.WalkOff {
    if (u16be(rom, 0xDC3E + 2) != 0xFF02 or u16be(rom, 0xDC46 + 2) != 0xFF02 or u16be(rom, 0xDC58 + 2) != 0xFF02) return error.BadData;
    if (r == try immediate(rom, 0xDC3C, &.{ 0x0C, 0x78 }, 2)) return .{ .up = false };
    if (r == try immediate(rom, 0xDC44, &.{ 0x0C, 0x78 }, 2)) {
        if (u16be(rom, 0xDC50) != 0x0010) return error.BadData;
        return .{ .up = true, .down_before = @intCast(try immediate(rom, 0xDC4C, &.{ 0x0C, 0x68 }, 2)) };
    }
    if (r == try immediate(rom, 0xDC56, &.{ 0x0C, 0x78 }, 2)) return .{ .up = true };
    return null;
}

/// Plane B's water in its mode 2 (the camera's table at 0x1933A, entry 2: 0x1938A jumps to 0x191E0),
/// set up by round `r`'s start (the table at 0x19C4C): its ripple's speed, its start and its turn
/// (0x19C92, 0x19C9A, 0x19CA2: move.l #N,($FC18), ($FC1C), ($FB32) with $FB34), the ticks the
/// start runs it (0x19CAA: moveq #N,d7, dbf); each tick (0x191E0) the copy of its places but the
/// last (0x191FC: move.w #N,d7), the lines at the plane's place (0x19234: moveq #N,d7, dbf), the
/// lines less half a place (0x19248, asr.w #1 at 0x1924E), the lines less a whole one (0x1925A).
fn waterOf(rom: []const u8, r: u32) Error!round.Water {
    if (u16be(rom, 0x1933A + 4) != 0x50 or u16be(rom, 0x1938A) != 0x4EFA) return error.BadData;
    const scroll: u32 = @intCast(@as(i32, 0x1938C) + s16be(rom, 0x1938C));
    if (scroll != 0x191E0) return error.BadData;
    const setup: u32 = 0x19C4C + @as(u32, u16be(rom, 0x19C4C + 2 * r));
    if (setup != 0x19C92) return error.BadData;
    const long = struct {
        fn f(rm: []const u8, at: u32, dest: u16) Error!i32 {
            if (u16be(rm, at) != 0x21FC or u16be(rm, at + 6) != dest) return error.BadData;
            return @bitCast(u32be(rm, at + 2));
        }
    }.f;
    const speed = try long(rom, 0x19C92, 0xFC18);
    const start = try long(rom, 0x19C9A, 0xFC1C);
    const turns: u32 = @bitCast(try long(rom, 0x19CA2, 0xFB32));
    if (turns >> 16 != turns & 0xFFFF or turns >> 16 == 0 or turns >> 16 > 255) return error.BadData;
    const from = try immediate(rom, 0x19234, &.{0x7E}, 1) + 1;
    const half = try immediate(rom, 0x19248, &.{0x7E}, 1) + 1;
    const whole = try immediate(rom, 0x1925A, &.{0x7E}, 1) + 1;
    if (u16be(rom, 0x1924E) != 0xE242 or u16be(rom, 0x19232) != 0xE241) return error.BadData;
    if (try immediate(rom, 0x19CAA, &.{0x7E}, 1) + 1 != half + whole) return error.BadData;
    if (try immediate(rom, 0x191FC, &.{ 0x3E, 0x3C }, 2) + 2 != half + whole) return error.BadData;
    return .{ .from = @intCast(from), .half = @intCast(half), .whole = @intCast(whole), .start = start, .speed = speed, .turn = @intCast(turns >> 16) };
}

/// Plane B's bands in its mode 0 (0x190EA), which drift in the round of 0x190FE's `cmpi.w`
/// (0x19138): each its drift of the table at 0x19196 (`d7`, the bands left, picks it: the last
/// entry for the first band).
fn drifting(arena: std.mem.Allocator, rom: []const u8, r: u32, bands: []const round.Band) Error![]const round.Band {
    if (u16be(rom, 0x19102) != 0xFF02 or u16be(rom, 0x19104) != 0x6606 or u16be(rom, 0x19106) != 0xB2FC or u16be(rom, 0x19108) != 0xE100) return error.BadData;
    if (try immediate(rom, 0x190FE, &.{ 0x0C, 0x78 }, 2) != r) return bands;
    if (u16be(rom, 0x19146) != 0x343B or bands.len > 4) return error.BadData;
    const out = try arena.dupe(round.Band, bands);
    for (out, 0..) |*b, k| {
        const left: u32 = @intCast(bands.len - 1 - k);
        b.drift = @intCast(s16be(rom, 0x19196 + 2 * left));
    }
    return out;
}

/// How the frames of play copy the planes' scroll (0x196A4, by plane A's mode: its table at
/// 0x196B2): by cells (0x196CA: two copies of $20 words, but by lines in the round of its
/// `cmpi.w`), by lines (0x19758: two copies of $100 words), or not at all (0x197D8: the planes
/// scroll whole).
fn scrollOf(rom: []const u8, r: u32, mode_a: u16) Error!round.Scroll {
    const table: u32 = 0x196B2;
    if (mode_a >= 12 or u16be(rom, 0x196AA) != 0x303B or u16be(rom, 0x196B0) != 0x0002) return error.BadData;
    const cells: u32 = 0x196CA;
    const lines: u32 = 0x19758;
    // The copies' lengths ($93LL $94HH), as transfers.zig counts them.
    if (u32be(rom, 0x196E8) != 0x93209400 or u32be(rom, lines + 20) != 0x93009401) return error.BadData;
    return switch (table + u16be(rom, table + 2 * mode_a)) {
        cells => {
            if (u16be(rom, cells) != 0x0C78 or u16be(rom, cells + 4) != 0xFF02 or u16be(rom, cells + 6) != 0x6700 or cells + 8 + u16be(rom, cells + 8) != lines) return error.BadData;
            return if (u16be(rom, cells + 2) == r) .lines else .cells;
        },
        lines => .lines,
        0x197D8 => .whole,
        else => error.BadData,
    };
}

/// The pixels of a long immediate's whole part (its high word), after `opcode` at `at`; its low
/// word, the fraction, is none.
fn longPixels(rom: []const u8, at: u32, opcode: []const u8) Error!u32 {
    const whole = try immediate(rom, at, opcode, 2);
    if (u16be(rom, at + @as(u32, @intCast(opcode.len)) + 2) != 0) return error.BadData;
    return whole;
}

/// A packed decimal byte as a number.
fn decimal(b: u32) Error!u8 {
    if (b > 0x99 or b & 0xF > 9) return error.BadData;
    return @intCast((b >> 4) * 10 + (b & 0xF));
}

// --- The loads ---------------------------------------------------------------------------------

/// The tiles of each block of load list `n`.
fn loadBlocks(rom: []const u8, n: u16, out: *[8]u16) Error![]const u16 {
    const off: i16 = @bitCast(u16be(rom, load_lists + 2 * @as(u32, n)));
    const at: u32 = @intCast(@as(i32, load_lists) + off);
    const count = s16be(rom, at);
    if (count < 0) return out[0..0];
    if (count >= out.len) return error.BadData;
    for (0..@as(usize, @intCast(count)) + 1) |i| {
        const block = u32be(rom, at + 2 + 6 * @as(u32, @intCast(i)));
        if (block + 2 > rom.len) return error.BadData;
        out[i] = u16be(rom, block) & 0x7FFF;
    }
    return out[0 .. @as(usize, @intCast(count)) + 1];
}

/// The streaming of a load queued at a tick's end: its first block starts at the next tick, and
/// each display tick decodes five tiles (the tick's two: its middle, then its end). A block
/// finished in a tick's middle lets the next start in the same tick; at its end, at the next.
/// Returns the tick, counted from the one that queued it, at whose end the queue is seen empty.
pub fn streamTicks(blocks: []const u16) u32 {
    var start: u32 = 1;
    var done: u32 = 0;
    for (blocks) |tiles| {
        const n = std.math.divCeil(u32, tiles, tiles_a_display_tick) catch unreachable;
        // The display ticks: the first is the start tick's end, then each tick's middle and end.
        if (n % 2 == 0) {
            const at = start + n / 2; // a middle
            done = at;
            start = at;
        } else {
            const at = start + (n - 1) / 2; // an end
            done = at + 1;
            start = at + 1;
        }
    }
    return done;
}

/// The ticks from the first of a section's art loads (0xD70: art slots 2, 1 and 0, then the
/// boss's slot) to the tick its wait for the wall begins. Each slot takes a tick to be looked at
/// (one without a kind, only that), then its load's stream; the boss's slot one more.
pub fn artTicks(rom: []const u8, kinds: [4]u8) Error!u32 {
    var t: u32 = 0;
    for ([_]u8{ 2, 1, 0 }) |slot| {
        const kind = kinds[slot];
        if (kind == 0) {
            t += 1;
            continue;
        }
        var buf: [8]u16 = undefined;
        const blocks = try loadBlocks(rom, @as(u16, kind - 1) * 3 + (2 - slot) + first_art_load, &buf);
        t += if (blocks.len == 0) 1 else streamTicks(blocks) + 1;
    }
    if (kinds[3] != 0) {
        var buf: [8]u16 = undefined;
        const blocks = try loadBlocks(rom, kinds[3], &buf);
        t += if (blocks.len == 0) 1 else streamTicks(blocks) + 1;
    }
    return t;
}

/// The blocks of load list `n`, each its display ticks of decoding.
fn loadStream(arena: std.mem.Allocator, rom: []const u8, n: u16) Error![]const []const round.Streamed {
    const off: i16 = @bitCast(u16be(rom, load_lists + 2 * @as(u32, n)));
    const at: u32 = @intCast(@as(i32, load_lists) + off);
    const count = s16be(rom, at);
    if (count < 0) return &.{};
    const out = try arena.alloc([]const round.Streamed, @intCast(count + 1));
    for (out, 0..) |*b, i| b.* = try stream.batches(arena, rom, u32be(rom, at + 2 + 6 * @as(u32, @intCast(i))));
    return out;
}

/// A section's art loads (0xD70) as `artTicks` counts them: art slots 2, 1 and 0, then the
/// boss's slot, the first looked at `first` ticks after the stream's tick, each next one a tick
/// after the one before is done.
fn artLoads(arena: std.mem.Allocator, rom: []const u8, kinds: [4]u8, first: u32, out: *std.ArrayList(stream.Load)) Error!void {
    var after = first;
    for ([_]u8{ 2, 1, 0 }) |slot| {
        const kind = kinds[slot];
        const blocks = if (kind == 0) &.{} else try loadStream(arena, rom, @as(u16, kind - 1) * 3 + (2 - slot) + first_art_load);
        try out.append(arena, .{ .after = after, .blocks = blocks });
        after = 1;
    }
    if (kinds[3] != 0) try out.append(arena, .{ .after = after, .blocks = try loadStream(arena, rom, kinds[3]) });
}

/// The special attack's art (0x599E): as its police car comes (its first update, the queue
/// empty), load list 0 (the car's, moveq #0 at 0x59D2) and list 9, or 10 when player 2 called it
/// ($FFFA1C: moveq #9 at 0x59D8, moveq #10 at 0x59E0), queued together by the car, streamed from
/// its tick's end.
fn specialArt(arena: std.mem.Allocator, rom: []const u8) Error!round.Special {
    if (u16be(rom, 0x59D2) != 0x7000 or u16be(rom, 0x59D8) != 0x7009 or u16be(rom, 0x59E0) != 0x700A or u32be(rom, 0x59DA) != 0x4A38FA1C) return error.BadData;
    const car = try loadStream(arena, rom, 0);
    var both: [2][]const round.Streamed = undefined;
    for (&both, [_]u16{ 9, 10 }) |*o, n| {
        const blocks = try std.mem.concat(arena, []const round.Streamed, &.{ car, try loadStream(arena, rom, n) });
        o.* = try stream.schedule(arena, &.{.{ .after = 0, .blocks = blocks, .before_head = true }});
    }
    return .{ .provenance = "the police car's art (0x599E): load lists 0 and 9, or 10 when player 2 called the special attack, queued at the car's first update (its queue empty), streamed from that tick's end (0x84BA after the objects, 0x8510)", .streamed = both };
}

/// A section's art again after the special attack (0x18E3C, as the camera comes back): the boss's
/// load ($FFFA63, art slot 3's kind), else art slot 1's kind's own load ((kind - 1) * 3 + $C:
/// muls.w #3 and addi.w #$C at 0x18E8C), else none; queued by the camera, streamed from its
/// tick's end. (TODO(PLAN item 15): an arrival that takes art slot 1 before the special attack,
/// 0x9CA.)
fn againStream(arena: std.mem.Allocator, rom: []const u8, kinds: [4]u8) Error![]const round.Streamed {
    if (u32be(rom, 0x18E8C) != 0xC1FC0003 or u16be(rom, 0x18E90) != 0x0640 or u16be(rom, 0x18E92) != first_art_load + 1) return error.BadData;
    const load: u16 = if (kinds[3] != 0) kinds[3] else if (kinds[1] != 0) @as(u16, kinds[1] - 1) * 3 + first_art_load + 1 else return &.{};
    return stream.schedule(arena, &.{.{ .after = 0, .blocks = try loadStream(arena, rom, load), .before_head = true }});
}

/// Whether round `r`'s (from 0) boss's art is not loaded again after the special attack: the
/// boss's section's branch (0x18E96) compares the round with the twins' (cmpi.w at 0x18EB0), whose
/// art is copied from the players' again (0x18EC2), not loaded.
fn copiesBossArt(rom: []const u8, r: u32) Error!bool {
    if (u16be(rom, 0x18EB0) != 0x0C40 or u16be(rom, 0x18EB4) != 0x670C) return error.BadData;
    return u16be(rom, 0x18EB2) == r;
}

/// The bosses' art and colours by kind (0x1C3A8, six bytes each: the type, its art's load, its
/// colours' lists).
const boss_palettes = 0x1C3A8;
const boss_palettes_count = 6;
/// Which types the reserve takes as common enemies (0x9350: $20 to $2A, but those this table
/// marks; the others' art and colours are a boss's).
const uncommon_types = 0x936E;

/// A reserve's entry of a type that is not a common enemy's (0x9350): its art and colours a
/// boss's, by its palette byte (0xA02, 0xB24): the low nibble its kind's entry of the bosses'
/// table (whose type must be its own), whose art's load it takes; the high nibble the list of
/// that entry's colours lists, loaded over the first line; the byte itself the colours' number.
fn reserveBoss(arena: std.mem.Allocator, rom: []const u8, t: u8, palette: u8) Error!?round.ReserveBoss {
    if (t >= 0x20 and t < 0x2B and rom[uncommon_types + @as(u32, t - 0x20)] == 0) return null;
    if (u32be(rom, 0x9354) != 0x04000020 or u16be(rom, 0x935A) != 0x0C00 or rom[0x935D] != 0x0B or u16be(rom, 0x9360) != 0x103B) return error.BadData;
    if (palette & 0xF >= boss_palettes_count) return error.BadData;
    const e = boss_palettes + 6 * @as(u32, palette & 0xF);
    if (rom[e] != t) return error.BadData;
    const list = u32be(rom, u32be(rom, e + 2) + 4 * @as(u32, palette >> 4));
    return .{
        .art = rom[e + 1],
        .colours = palette,
        .palette = try palettes.bossColoursName(arena, rom, list) orelse return error.BadData,
    };
}

/// A waiting entry's kind's art streamed from its call: a tick, then its load (0xB76).
fn arrivalStream(arena: std.mem.Allocator, rom: []const u8, t: u8) Error![]const round.Streamed {
    if (!commonEnemy(t)) return &.{};
    const kind = rom[art_of_type + @as(u32, t - 0x20)];
    if (kind & 0x80 != 0 or kind == 0) return &.{};
    const blocks = try loadStream(arena, rom, @as(u16, kind - 1) * 3 + first_art_load);
    return stream.schedule(arena, &.{.{ .after = 1, .blocks = blocks }});
}

/// The ticks from a waiting entry's call (its turn chosen) to its coming in: a tick, then its
/// kind's art load (0xB76).
fn arrivalTicks(rom: []const u8, t: u8) Error!u16 {
    if (!commonEnemy(t)) return 1;
    const kind = rom[art_of_type + @as(u32, t - 0x20)];
    if (kind & 0x80 != 0 or kind == 0) return 1;
    var buf: [8]u16 = undefined;
    const blocks = try loadBlocks(rom, @as(u16, kind - 1) * 3 + first_art_load, &buf);
    return @intCast(1 + streamTicks(blocks));
}

// --- The entries -------------------------------------------------------------------------------

/// What the enemy's code reads of an entry's three bytes (the variant, the offsets' nibbles, the
/// palette row), in the game's terms (spawns.zig); a boss's: its twin, its bar.
fn enemyRecord(rom: []const u8, s: *round.Spawn, t: u8, variant: u8, offsets: u8, palette: u8) Error!void {
    // A boss's: bit 7 of its variant byte is the enemies' wait for the camera (0xA59C), which
    // the bosses clear (0x17F2E) and never read (round 8's records set it); the rest makes it
    // the second of twins.
    if (boss(t)) {
        if (variant & 0x7F != 0) s.traits.insert(.twin);
        s.bar = offsets;
        return;
    }
    // Round 3's boss (type $30, 0x144D2): a variant by its byte (bit 0: no helper of its own,
    // and the low nibble a variant: 0x1527A, 0x152C0, as one; bit 7 as a boss's), its bar; by
    // its palette byte's high nibble, its row: at his knockout's end (0x15444), his beating the
    // round's end (0) or he goes as an enemy (1: round 5's reserves, $14; 2: round 8's, $24,
    // the helper of a pair going with him, and a variant's health more, 0x1455C), its strength.
    // The palette byte's low nibble is a reserve's boss's colours (reserveBoss).
    if (t == 0x30) {
        const v = variant & 0x7F;
        const row = palette >> 4;
        if (v > 1 or row > 2) return error.BadData;
        if (v != 0) s.traits.insert(.twin);
        if (row != 0) s.traits.insert(.goes_as_enemy);
        s.strength = row;
        s.bar = offsets;
        return;
    }
    if (!commonEnemy(t)) return;
    // Its art, by its type (0xA4E): the art slots hold it by that number.
    s.art = rom[art_of_type + @as(u32, t - 0x20)];
    const d = try spawns.decode(rom, t, variant, offsets, palette);
    s.entrance = d.entrance;
    s.traits = d.traits;
    s.offset = d.offset;
    // The trio's others count on from its offsets' nibbles (0xF7D8).
    if (t == 0x2A) s.offset_nibbles = offsets;
    s.strength = d.strength;
    s.colours = try coloursOf(rom, t, palette);
}

/// The enemies' colours of an entry (0xA66): its type's first (the table at 0xA5A) plus its
/// palette byte; bit 7 set, its own (and that bit cleared). A number of the enemies' colours
/// (palettes.zig: 0 to 8 a pair, 9 to 11 their own).
fn coloursOf(rom: []const u8, t: u8, palette: u8) Error!u8 {
    const p = rom[palette_of_type + @as(u32, t - 0x20)] +% palette;
    if (p & 0x80 != 0) {
        const own = p & 0x7F;
        if (own < 9 or own > 11) return error.BadData;
        return own;
    }
    if (p > 8) return error.BadData;
    return p;
}

/// A section's colours (0xF46, its entry's bytes 4 and 5): the first's the low nibble of byte
/// 4, the other's its high nibble plus 8 (none when 0), the second's byte 5. (A boss's colours
/// in byte 4, bit 7: TODO(PLAN item 15), not in round 1.)
fn sectionColours(rom: []const u8, at: u32) Error!round.Colours {
    const b4 = rom[at + 4];
    if (b4 & 0x80 != 0) return error.BadData;
    return .{ .first = b4 & 0xF, .second = rom[at + 5], .other = if (b4 >> 4 != 0) (b4 >> 4) + 8 else null };
}

/// An entry's record: its kind, its depth (the Y, whose low two bits are its lowest level), and
/// what its kind's code reads of its three bytes.
fn entry(rom: []const u8, type_byte: u8, bytes: [3]u8, y: u8) Error!round.Spawn {
    const t = type_byte & 0x7F;
    var s: round.Spawn = .{
        .kind = kindName(t) orelse return error.BadData,
        .depth = y,
        .level = @intCast(y & 3),
        .two_players = type_byte & 0x80 != 0,
    };
    switch (t) {
        0x11, 0x18, 0x19, 0x1B, 0x1C, 0x1D, 0x1F, 0x41, 0x45 => {
            // A breakable, a crate, an oil drum, round 4's and 5's obstacles, round 6's crates
            // that shatter, round 8's trolleys: the item it holds (its byte $41, which 0x7E54
            // reads), an index from 1 (0 for none). A trolley rolls by its byte $40 (0x7546: 0
            // to 4).
            if (((t >= 0x1B and t <= 0x1D) or t == 0x41) and (bytes[0] != 0 or bytes[2] != 0)) return error.BadData;
            if (t == 0x45) {
                if (bytes[0] > 4 or bytes[2] != 0) return error.BadData;
                s.rolls = bytes[0];
            }
            if (bytes[1] != 0) {
                if (bytes[1] > 11) return error.BadData;
                s.holds = kindName(rom[breakable_items + @as(u32, bytes[1])]) orelse return error.BadData;
            }
            return s;
        },
        0x13 => {
            // A poster's corner: its height by its byte $49 (0x6DEE), and whether it stirs with
            // a flight by its byte $40 (0x6E0E).
            if (bytes[2] >= scenery.corner_height_count or bytes[1] != 0) return error.BadData;
            s.height = s16be(rom, scenery.corner_heights + 2 * @as(u32, bytes[2]));
            if (bytes[0] != 0) s.traits.insert(.stirs);
            return s;
        },
        0x16 => {
            // A drifter: its way of drifting by its byte $40, a state (0x7238).
            if (bytes[0] > 3 or bytes[1] != 0 or bytes[2] != 0) return error.BadData;
            s.drift = @fromBackingInt(@intCast(bytes[0]));
            return s;
        },
        0x42 => {
            // A press: its place among the round's by its byte $40, which chooses its cells of
            // the plane (0x7B28).
            if (bytes[1] != 0 or bytes[2] != 0) return error.BadData;
            s.place = bytes[0];
            return s;
        },
        // A drip, the rain, a flight, a lamp, the lift's pieces, the corridor's statues (a
        // variant is Mr. X's room's): their code reads none of the bytes.
        0x14, 0x15, 0x17, 0x4D, 0x4E, 0x50...0x53 => {
            if (!std.mem.allEqual(u8, &bytes, 0)) return error.BadData;
            return s;
        },
        else => {},
    }
    try enemyRecord(rom, &s, t, bytes[0], bytes[1], bytes[2]);
    return s;
}

/// A reader of the unpacked lists.
const Lists = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(self: *Lists) Error!u8 {
        if (self.at >= self.bytes.len) return error.BadData;
        defer self.at += 1;
        return self.bytes[self.at];
    }

    fn word(self: *Lists) Error!u16 {
        const hi = try self.byte();
        return @as(u16, hi) << 8 | try self.byte();
    }

    fn peek(self: *const Lists) Error!u8 {
        if (self.at >= self.bytes.len) return error.BadData;
        return self.bytes[self.at];
    }
};

/// A group placed ahead (0xCC0), its entries' X on the page of `page`.
fn group(arena: std.mem.Allocator, rom: []const u8, l: *Lists, page: u16, out: *std.ArrayList(round.Spawn)) Error!void {
    const count = try l.word();
    if (count & 0x8000 != 0) return;
    for (0..@as(usize, count) + 1) |_| {
        const t = try l.byte();
        const b = [3]u8{ try l.byte(), try l.byte(), try l.byte() };
        const x_low = try l.byte();
        const y = try l.byte();
        var s = try entry(rom, t, b, y);
        s.x = (page & 0xFF00) | x_low;
        try out.append(arena, s);
    }
}

/// The target of the `jsr (d16,pc)` at `at`, checked.
fn jsrTarget(rom: []const u8, at: u32) Error!u32 {
    if (u16be(rom, at) != 0x4EBA) return error.BadData;
    return @intCast(@as(i32, @intCast(at + 2)) + s16be(rom, at + 2));
}

/// The round's own routine (0x112F2, its table at 0x11300, a play tick before the objects): none
/// (`rts`), round 3's sound (0x11310) or round 5's horn (0x1132E, `endless`).
fn ownSound(arena: std.mem.Allocator, rom: []const u8, r: u32) Error!?round.OwnSound {
    const table: u32 = 0x11300;
    const at: u32 = table + u16be(rom, table + 2 * r);
    if (u16be(rom, at) == 0x4E75) return null;
    if (u16be(rom, at) == 0x5378) return try endless(arena, rom, r, at);
    return try counted(arena, rom, r, at);
}

/// Round 3's kind of own sound: while its times last ($FFFA55), its ticks ($FFFB50) count down; at
/// zero they come again from $FFFB51, a time is spent and the sound is asked for. Its set-up
/// (0x19D08: its times, its first ticks and the next ones) runs at the round's load (the round's
/// entry of 0x19C4C) and at a section's opening (0x195AE: for the round of its `cmpi.w`).
fn counted(arena: std.mem.Allocator, rom: []const u8, r: u32, at: u32) Error!round.OwnSound {
    const pattern = [_]u8{ 0x4A, 0x38, 0xFA, 0x55, 0x67, 0x16, 0x53, 0x38, 0xFB, 0x50, 0x66, 0x10, 0x11, 0xF8, 0xFB, 0x51, 0xFB, 0x50, 0x53, 0x38, 0xFA, 0x55, 0x7E };
    if (at + pattern.len + 1 > rom.len or !std.mem.eql(u8, rom[at..][0..pattern.len], &pattern)) return error.BadData;
    const request = rom[at + pattern.len];
    const setup: u32 = 0x19D08;
    if (u16be(rom, setup) != 0x11FC or rom[setup + 2] != 0 or u16be(rom, setup + 4) != 0xFA55 or u16be(rom, setup + 6) != 0x31FC or u16be(rom, setup + 10) != 0xFB50) return error.BadData;
    const loads: u32 = 0x19C4C;
    if (try jsrTarget(rom, loads + u16be(rom, loads + 2 * r)) != setup) return error.BadData;
    if (u16be(rom, 0x195AE) != 0x0C78 or u16be(rom, 0x195B0) != r or u16be(rom, 0x195B2) != 0xFF02 or try jsrTarget(rom, 0x195B6) != setup) return error.BadData;
    return .{
        .provenance = try std.fmt.allocPrint(arena, "the round's own routine (0x112F2, ROM 0x{X:0>5}): its sound ROM 0x{X:0>5}, set up by 0x19D08 at the round's load and at each section's opening (0x195AE): its times ROM 0x19D0B, its first ticks ROM 0x19D10, then every ROM 0x19D11's", .{ at, at + pattern.len + 1 }),
        .sound = try soundName(request),
        .times = rom[setup + 3],
        .first = rom[setup + 8],
        .every = rom[setup + 9],
    };
}

/// Round 5's kind of own sound: its ticks (the word $FFFB50) count down; at zero they come again
/// from the routine's `move.w` and the sound is asked for, endlessly. Its first ticks are set at
/// the round's load only (the round's entry of 0x19C4C, its `move.w #N,($FFFB50)`).
fn endless(arena: std.mem.Allocator, rom: []const u8, r: u32, at: u32) Error!round.OwnSound {
    // subq.w #1,($FB50); bne.s +12; move.w #N,($FB50); moveq #S,d7; jmp (d16,pc)
    if (at + 18 > rom.len or u16be(rom, at + 2) != 0xFB50 or u16be(rom, at + 4) != 0x660C or u16be(rom, at + 6) != 0x31FC or u16be(rom, at + 10) != 0xFB50 or rom[at + 12] != 0x7E or u16be(rom, at + 14) != 0x4EFA) return error.BadData;
    const every = u16be(rom, at + 8);
    const loads: u32 = 0x19C4C;
    const load = loads + u16be(rom, loads + 2 * r);
    // The set-up's `move.w #N,($FB50)` (0x19C62: three `move.b` first).
    const first_at = load + 18;
    if (first_at + 6 > rom.len or u16be(rom, first_at) != 0x31FC or u16be(rom, first_at + 4) != 0xFB50) return error.BadData;
    const first = u16be(rom, first_at + 2);
    if (first == 0 or every == 0) return error.BadData;
    return .{
        .provenance = try std.fmt.allocPrint(arena, "the round's own routine (0x112F2, ROM 0x{X:0>5}): its sound ROM 0x{X:0>5}, endlessly, every ROM 0x{X:0>5}'s ticks; its first ticks ROM 0x{X:0>5}, set at the round's load only (0x19C4C)", .{ at, at + 13, at + 8, first_at + 2 }),
        .sound = try soundName(rom[at + 13]),
        .times = null,
        .per_section = false,
        .first = first,
        .every = every,
    };
}

/// The waves (0x112C0 at the round's load, for the round of its `cmpi.w`; 0x11346 at each tick of
/// play): their ticks between two steps and before the first (`move.w #$0505,($FFFA0A)`), their
/// steps (0x11346: `cmpi.w #N,($FFFB1A)`), each step's frame (0x11398) and colours (0x1139E), the
/// maps and the palettes of the round's art set (rounds.zig names them).
fn animation(arena: std.mem.Allocator, rom: []const u8, r: u32) Error!?round.Animation {
    const init: u32 = 0x112C0;
    if (u16be(rom, init) != 0x0C78 or u16be(rom, init + 4) != 0xFF02 or u16be(rom, init + 6) != 0x6706) return error.BadData;
    if (u16be(rom, init + 2) != r) return null;
    if (u16be(rom, init + 20) != 0x31FC or u16be(rom, init + 24) != 0xFA0A) return error.BadData;
    // The ticks before the first step ($FFFA0B) are the steps' period ($FFFA0A).
    const every = rom[init + 22];
    if (rom[init + 23] != every or every == 0) return error.BadData;
    const tick: u32 = 0x11346;
    if (u16be(rom, tick + 30) != 0x0C78 or u16be(rom, tick + 34) != 0xFB1A) return error.BadData;
    const count = u16be(rom, tick + 32);
    if (count == 0 or count > 8) return error.BadData;
    const steps = try arena.alloc(round.AnimationStep, count);
    for (steps, 0..) |*st, s| {
        const frame = rom[rounds.wave_steps + s];
        if (frame >= 4) return error.BadData;
        st.* = .{
            .map = try std.fmt.allocPrint(arena, "waves_{d}", .{frame + 1}),
            .colours = try std.fmt.allocPrint(arena, "waves_{d}", .{s + 1}),
        };
    }
    return .{
        .provenance = try std.fmt.allocPrint(arena, "the waves (0x112C0 at the round's load, 0x11346 at each tick of play): a step every ROM 0x{X:0>5}'s ticks, the first after as many; {d} steps (ROM 0x{X:0>5}), each its frame (ROM 0x{X:0>5}) and its colours (ROM 0x{X:0>5}, 8 bytes a step)", .{ init + 22, count, tick + 32, rounds.wave_steps, rounds.wave_palettes }),
        .every = every,
        .steps = steps,
    };
}

/// The first of the enemies' art slots a waiting enemy's art may take (0x966: its search from
/// slot 0, but from slot 1 in round 1: `tst.w ($FFFF02)`, then `moveq #1,d1`).
fn artFrom(rom: []const u8, r: u32) Error!u8 {
    if (u16be(rom, 0x998) != 0x7C02 or u16be(rom, 0x99A) != 0x7200 or u32be(rom, 0x99C) != 0x4A78FF02 or u16be(rom, 0x9A0) != 0x6604 or u16be(rom, 0x9A2) != 0x7C01 or u16be(rom, 0x9A4) != 0x7201) return error.BadData;
    if (u16be(rom, 0x9EC) != 0xFA63) return error.BadData;
    return if (r == 0) 1 else 0;
}

/// The pieces the round's start places itself after the first section's groups (0xEF0: for the
/// round of its `cmpi.w`, two objects, each in the enemies' places (0xE46), of the type and the
/// place across of its `move.b` and `move.w`, its depth 0): round 3's two lamps.
fn ownPlaced(arena: std.mem.Allocator, rom: []const u8, r: u32, out: *std.ArrayList(round.Spawn)) Error!void {
    if (u16be(rom, 0xEF0) != 0x0C78 or u16be(rom, 0xEF4) != 0xFF02 or u16be(rom, 0xEF6) & 0xFF00 != 0x6600) return error.BadData;
    // Round 7's lift (0xF18, for the round of its `cmpi.w`): moveq #N,d7 pieces and one more,
    // types from moveq #N,d0 down, each in the next of the enemies' places from the first
    // (`lea ($B900).w,a1`, then 128 bytes on); their own code sets their places.
    if (u16be(rom, 0xF18) != 0x0C78 or u16be(rom, 0xF1C) != 0xFF02 or u16be(rom, 0xF24) != 0x43F8 or u16be(rom, 0xF26) != 0xB900 or u16be(rom, 0xF2C) != 0x5300) return error.BadData;
    if (u16be(rom, 0xF1A) == r) {
        const count = try moveqAt(rom, 0xF20, 7) + 1;
        const first = try moveqAt(rom, 0xF22, 0);
        for (0..count) |k| try out.append(arena, try entry(rom, @intCast(first - k), .{ 0, 0, 0 }, 0));
    }
    if (u16be(rom, 0xEF2) != r) return;
    for ([_]u32{ 0xEF8, 0xF08 }) |at| {
        if (u16be(rom, at) != 0x4EBA or u16be(rom, at + 4) != 0x137C or u16be(rom, at + 8) != 0 or u16be(rom, at + 10) != 0x337C or u16be(rom, at + 14) != 16) return error.BadData;
        var s = try entry(rom, @intCast(u16be(rom, at + 6)), .{ 0, 0, 0 }, 0);
        s.x = u16be(rom, at + 12);
        try out.append(arena, s);
    }
}

/// `moveq #N,dR` at `at`: N, not below 0.
fn moveqAt(rom: []const u8, at: u32, register: u3) Error!u8 {
    const v = try entities.moveq(rom, at, register);
    if (v < 0) return error.BadData;
    return @intCast(v);
}

/// The timed wave (0x784): an entry after each delay, up to the delay $0099.
fn wave(arena: std.mem.Allocator, rom: []const u8, l: *Lists) Error![]const round.Spawn {
    var out: std.ArrayList(round.Spawn) = .empty;
    while (true) {
        const delay = try l.word();
        if (delay == wave_end) break;
        const t = try l.byte();
        const b = [3]u8{ try l.byte(), try l.byte(), try l.byte() };
        const y = try l.byte();
        const side = try l.byte();
        var s = try entry(rom, t, b, y);
        s.after = delay & 0x7FFF;
        s.side = if (side == 0) .right else .left;
        try out.append(arena, s);
    }
    return out.items;
}

/// The entries waiting for a free slot (0x810): a size word, then the entries up to $99.
fn reserve(arena: std.mem.Allocator, rom: []const u8, l: *Lists) Error![]const round.Spawn {
    const size = try l.word();
    const next = l.at + size;
    var out: std.ArrayList(round.Spawn) = .empty;
    while (try l.peek() != end_mark) {
        const t = try l.byte();
        const b = [3]u8{ try l.byte(), try l.byte(), try l.byte() };
        const y = try l.byte();
        const side = try l.byte();
        var s = try entry(rom, t, b, y);
        s.side = if (side == 0) .right else .left;
        if (try reserveBoss(arena, rom, t & 0x7F, b[2])) |rb| {
            // A boss's kind: its art's load streamed from its call as a common enemy's.
            var buf: [8]u16 = undefined;
            s.reserve_boss = rb;
            s.arrives_after = @intCast(1 + streamTicks(try loadBlocks(rom, rb.art, &buf)));
            s.streamed = try stream.schedule(arena, &.{.{ .after = 1, .blocks = try loadStream(arena, rom, rb.art) }});
        } else {
            s.arrives_after = try arrivalTicks(rom, t & 0x7F);
            s.streamed = try arrivalStream(arena, rom, t & 0x7F);
        }
        try out.append(arena, s);
    }
    l.at = next;
    return out.items;
}

// --- The round ---------------------------------------------------------------------------------

/// The first 6 bytes of a section's entry's art: the four art kinds.
fn artKinds(rom: []const u8, at: u32) [4]u8 {
    return rom[at..][0..4].*;
}

/// Round `n`'s script (1 to 8; the rounds of `extracted`).
pub fn extract(arena: std.mem.Allocator, rom: []const u8, n: u8) Error!round.Round {
    if (n == 0 or n > rounds.count) return error.BadData;
    const r: u32 = n - 1;
    const lists_at = spawn_lists + @as(u32, u16be(rom, spawn_lists + 2 * r));
    const lists = (try nemesis.decompress(arena, rom, lists_at)).bytes;

    const part: u32 = @intCast(@as(i32, sections_table) + s16be(rom, sections_table + 2 * r));
    const entryAt = struct {
        fn f(rm: []const u8, p: u32, k: u32) u32 {
            return @intCast(@as(i32, @intCast(p)) + s16be(rm, p + 2 * k));
        }
    }.f;
    const first = entryAt(rom, part, 0);
    // The first entry: the lists' start (in the RAM they are unpacked to, $FF6800), the placing
    // step, then the art.
    const list_start = u32be(rom, first);
    if (list_start < 0xFF6800 or list_start - 0xFF6800 >= lists.len) return error.BadData;
    const step = u16be(rom, first + 4);
    const page_step: u16 = u16be(rom, placing_steps + @as(u32, step)) & 0xFF;
    var page: u16 = u16be(rom, placing_steps + @as(u32, step) + 2);

    // The round header's plane A: its width, height, limits' set, X, Y, mode (0x19922).
    const h = rounds.header(rom, r) + 32;
    // Plane A takes the next set of limits in the round of 0x19936's `cmpi.w` (round 7's).
    if (u16be(rom, 0x19936) != 0x0C78 or u16be(rom, 0x1993A) != 0xFF02 or u16be(rom, 0x19944) != 0x5040) return error.BadData;
    const limits_set: u32 = u16be(rom, h + 4) * 8 + @as(u32, if (u16be(rom, 0x19938) == r) 8 else 0);
    const limits = camera_limits + limits_set;
    // The wall reached (0x6A6: cmpi.w #N,d0 on the limits' gap), the enemies left behind brought
    // to its edge (subi.w #N,d1 from the camera's X; moveq #N,d2, their depth), the edges a wave
    // comes in at (0xC60: addi.w #N,d0 to the camera's X; subq.w #8,d0).
    const wall_within = try immediate(rom, 0x6AE, &.{ 0x0C, 0x40 }, 2);
    const behind_x = try immediate(rom, 0x6CC, &.{ 0x04, 0x41 }, 2);
    const behind_depth = try immediate(rom, 0x706, &.{0x74}, 1);
    const right_edge = try immediate(rom, 0xCAE, &.{ 0x06, 0x40 }, 2);
    _ = try immediate(rom, 0xCB8, &.{0x51}, 1);
    // How the camera follows the players (0x18F5C): a player's place on the screen as its object
    // keeps it, the sprites' origin 128 more, past $110 or from $130 (subi.l #N,d0 and d1) moves
    // it by as much, at most move.l #N,d1's pixels a tick. The players kept on the screen (0x43AA:
    // moveq #N,d2 from the camera's X, then move.w #N,d3 more) and on the depths (moveq #N,d1 up
    // to moveq #N,d1, round 7's move.w #N,d1 on the cmpi.w's round). A heavy fall's shake
    // (0x4D40: move.b #N,($FA45), its ticks; 0x19282: moveq #N,d0, its pixels).
    const origin = 128;
    const band_from = try longPixels(rom, 0x18F7E, &.{ 0x04, 0x80 });
    const band_to = try longPixels(rom, 0x18F86, &.{ 0x04, 0x81 });
    const follow_most = try longPixels(rom, 0x18FD6, &.{ 0x22, 0x3C });
    if (try longPixels(rom, 0x18FCC, &.{ 0x22, 0x3C }) != 0x10000 - follow_most) return error.BadData;
    const kept_left = try immediate(rom, 0x43F4, &.{0x74}, 1);
    const kept_width = try immediate(rom, 0x43F6, &.{ 0x36, 0x3C }, 2);
    const depth_from = try immediate(rom, 0x440A, &.{0x72}, 1);
    const depth_to_common = try immediate(rom, 0x4414, &.{0x72}, 1);
    const own_round = try immediate(rom, 0x4416, &.{ 0x0C, 0x78 }, 2);
    if (u16be(rom, 0x441A) != 0xFF02) return error.BadData;
    const depth_to_own = try immediate(rom, 0x441E, &.{ 0x32, 0x3C }, 2);
    const shake_ticks = try immediate(rom, 0x4D52, &.{ 0x11, 0xFC }, 2);
    if (u16be(rom, 0x4D56) != 0xFA45) return error.BadData;
    const shake_by = try immediate(rom, 0x19292, &.{0x70}, 1);
    // The planes' modes (the round header's mode words): plane B in its mode 1 (0x19368) at the
    // camera's X in round 1, a quarter of it in the others (tst.w ($FF02) at 0x19372, then asr.w
    // #2); in its mode 0 (0x1934A) at plane A's X, its bands at their ratios of it.
    const mode_a = u16be(rom, h + 10);
    const mode_b = u16be(rom, h + 22);
    if (u32be(rom, 0x19372) != 0x4A78FF02 or u16be(rom, 0x19376) != 0x6702 or u16be(rom, 0x19378) & 0xF1FF != 0xE040) return error.BadData;
    const plane_b_shift: u3 = @intCast((u16be(rom, 0x19378) >> 9) & 7);
    // In its mode 0 plane B takes plane A's place down (0x19360), but in the round of 0x19358's
    // `cmpi.w`, where it keeps its own.
    if (u16be(rom, 0x1935C) != 0xFF02 or u16be(rom, 0x1935E) != 0x6706) return error.BadData;
    const own_plane_b = try immediate(rom, 0x19358, &.{ 0x0C, 0x78 }, 2);
    const plane_b: [2]u8 = switch (mode_b) {
        0 => .{ 1, 1 },
        1 => .{ 1, if (r == 0) 1 else @as(u8, 1) << plane_b_shift },
        // The water's: half the camera's (asr.w #1 at 0x19232).
        2 => .{ 1, 2 },
        // The lift's: its own place across, the camera's (which stays).
        3 => .{ 1, 1 },
        else => return error.BadData,
    };
    // The round whose camera goes left (0x19570: cmpi.w #N,($FF02)): its walls are its limits on
    // the left, from byte N of the walls' table (addi.w #N,d0), its first the limits' set's left
    // one; its limit on the right follows it (0x195C0).
    const leftward_round = try immediate(rom, 0x19586, &.{ 0x0C, 0x78 }, 2);
    if (u16be(rom, 0x1958A) != 0xFF02 or u16be(rom, 0x195C4) != 0xFF02 or u16be(rom, 0x195C0) != 0x0C78 or u16be(rom, 0x195C2) != leftward_round) return error.BadData;
    const leftward_walls = try immediate(rom, 0x1958E, &.{ 0x06, 0x40 }, 2);
    const leftward = r == leftward_round;
    // Going left, a thing it leaves behind goes once right of its place plus N (0x6A70: in the
    // round of its compare, addi.w #N,d0).
    if (u16be(rom, 0x6A74) != 0x0C78 or u16be(rom, 0x6A76) != leftward_round or u16be(rom, 0x6A78) != 0xFF02) return error.BadData;
    const behind_right = try immediate(rom, 0x6A88, &.{ 0x06, 0x40 }, 2);
    const camera: round.Camera = .{
        .provenance = try std.fmt.allocPrint(arena, "the round header's plane A (ROM 0x{X:0>5}): its X and Y; its limits' set {d} (0x1998A): the first section's wall, the limit behind, the limits down (round 8's camera goes left: ROM 0x19586, its first wall on the left, its limit behind on the right, 0x195C0); the planes in their modes (the header's mode words): in mode 0 (0x18C4A, 0x1934A) their bands at the camera's X times their ratios, plane B at plane A's X and Y; in mode 1 plane A at the camera's X, plane B at it in round 1, a quarter of it in the others (ROM 0x19378: asr.w #2); the wall reached within ROM 0x006B0's pixels (0x6A6); the left behind brought to the camera's X less ROM 0x006CE, at depth ROM 0x00707; the edges: the camera's X less 8 (ROM 0x00CB8: subq.w #8,d0) and plus ROM 0x00CB0 (0xC60); it follows a player whose place on the screen (its object's, the sprites' origin 128 more) is before ROM 0x18F80's or from ROM 0x18F88's (subi.l), by at most ROM 0x18FD8's pixels a tick (0x18F5C); the players kept from ROM 0x043F5's pixels across, for ROM 0x043F8's more, and on the depths from ROM 0x0440B's to ROM 0x04415's (round 7, ROM 0x04419's from 0, to ROM 0x04420's) (0x43AA); a heavy fall's shake ROM 0x04D55's ticks (0x4D40), ROM 0x19293's pixels (0x19282); the planes' bands, their rows and ratios, from the layout records (0x199C6, the table at ROM 0x5F788), the strips the camera brings in (0x18B3C); how the frames copy the planes' scroll by plane A's mode (0x196A4)", .{ h, limits_set / 8 }),
        .x = u16be(rom, h + 6),
        .y = u16be(rom, h + 8),
        .x_min = u16be(rom, limits + 4),
        .x_max = if (leftward) u16be(rom, limits + 6) else null,
        .leftward = leftward,
        .behind_right = if (leftward) @intCast(behind_right) else 0,
        .y_min = u16be(rom, limits),
        .y_max = u16be(rom, limits + 2),
        .plane_b = plane_b,
        .plane_b_down = mode_b == 0 and r != own_plane_b,
        .wobble = try wobbleOf(rom, r),
        .scroll = try scrollOf(rom, r, mode_a),
        .wall_within = @intCast(wall_within),
        .edges = .{ -8, @intCast(right_edge) },
        .left_behind = .{ -@as(i32, @intCast(behind_x)), @intCast(behind_depth) },
        .follow = .{ @intCast(@as(i32, @intCast(band_from)) - origin), @intCast(@as(i32, @intCast(band_to)) - origin) },
        .follow_most = @intCast(follow_most),
        .kept_x = .{ @intCast(kept_left), @intCast(kept_left + kept_width) },
        .kept_depth = .{ @intCast(depth_from), @intCast(if (r == own_round) depth_to_own else depth_to_common) },
        .shake = .{ @intCast(shake_ticks), @intCast(shake_by) },
        .bands = .{ try bandsInMode(arena, rom, r, 0, mode_a), try bandsInMode(arena, rom, r, 1, mode_b) },
        .water = if (mode_b == 2) try waterOf(rom, r) else null,
    };
    const first_wall: i32 = u16be(rom, limits + 6);

    // The timer (0x195F6) by the round (the `cmpi.w`s on $FF02): before the round of 0x195FA's,
    // moveq #$40 for the first sections, #$50 from the section of 0x1961C's compare; from it,
    // 0x19602's, and the same from the section of 0x19610's compare, but in the round of
    // 0x19604's, 0x1960C's for all. Its pace (0x10C88).
    if (u16be(rom, 0x195FE) != 0xFF02 or u16be(rom, 0x19608) != 0xFF02 or u16be(rom, 0x19614) != 0xFF04 or u16be(rom, 0x19620) != 0xFF04) return error.BadData;
    const late_rounds = try immediate(rom, 0x195FA, &.{ 0x0C, 0x78 }, 2);
    const own_timer_round = try immediate(rom, 0x19604, &.{ 0x0C, 0x78 }, 2);
    const Timer = struct { first: u32, later: u32, from: u32 };
    const timer_at: Timer = if (r < late_rounds)
        .{ .first = 0x195F8, .later = 0x19624, .from = 0x1961C }
    else if (r == own_timer_round)
        .{ .first = 0x1960C, .later = 0x1960C, .from = 0x1961C }
    else
        .{ .first = 0x19602, .later = 0x19618, .from = 0x19610 };
    const timer_first = try decimal(try immediate(rom, timer_at.first, &.{0x70}, 1));
    const later_from = try immediate(rom, timer_at.from, &.{ 0x0C, 0x78 }, 2);
    const timer_later = try decimal(try immediate(rom, timer_at.later, &.{0x70}, 1));
    const pace = try immediate(rom, 0x10C9A, &.{ 0x31, 0xFC }, 2);

    // A life starts facing left in the round of 0x1EC0's compare (its animation 2), with no
    // special attack in the round of 0x1EFE's (its count cleared; else 1 more than the hidden
    // option's, 0 here).
    const left_start = try immediate(rom, 0x1EC0, &.{ 0x0C, 0x78 }, 2);
    const no_specials = try immediate(rom, 0x1EFE, &.{ 0x0C, 0x78 }, 2);
    if (u16be(rom, 0x1EC4) != 0xFF02 or u16be(rom, 0x1F02) != 0xFF02 or u16be(rom, 0x1EC8) != 0x7002) return error.BadData;
    // A life starts at the camera's X, at depth $40 (player 2, $20 less) and height 0 (0x1E0E).
    const second_less = try immediate(rom, 0x1EA2, &.{ 0x04, 0x68 }, 2);
    const height = try immediate(rom, 0x1E64, &.{ 0x31, 0x7C }, 2);
    // By the round ($FF02, 0x1E50): round 8 farther across, round 7 farther across, round 6
    // deeper.
    if (u16be(rom, 0x1E50) != 0x0C78 or u16be(rom, 0x1E52) != 7 or u16be(rom, 0x1E6A) != 0x0C78 or u16be(rom, 0x1E6C) != 6 or u16be(rom, 0x1E7A) != 0x0C78 or u16be(rom, 0x1E7C) != 5) return error.BadData;
    if (u16be(rom, 0x1E5C) != 16 or u16be(rom, 0x1E76) != 16 or u16be(rom, 0x1E86) != 20) return error.BadData;
    const start_x: i32 = switch (r) {
        7 => @intCast(try immediate(rom, 0x1E58, &.{ 0x06, 0x68 }, 2)),
        6 => @intCast(try immediate(rom, 0x1E72, &.{ 0x06, 0x68 }, 2)),
        else => 0,
    };
    const depth = try immediate(rom, 0x1E5E, &.{ 0x31, 0x7C }, 2) + if (r == 5) try immediate(rom, 0x1E82, &.{ 0x06, 0x68 }, 2) else 0;

    var l: Lists = .{ .bytes = lists, .at = list_start - 0xFF6800 };
    // A section's opening (0x5F4) brings the boss's from the section of a `cmpi.w` on $FF04 by
    // the round: before the round of 0x62E's, 0x67A's (sections 0 to 3, then the boss's); from
    // it, 0x63E's (sections 0 to 5).
    if (u16be(rom, 0x632) != 0xFF02 or u16be(rom, 0x642) != 0xFF04 or u16be(rom, 0x67E) != 0xFF04) return error.BadData;
    const late_sections = try immediate(rom, 0x62E, &.{ 0x0C, 0x78 }, 2);
    const boss_from = try immediate(rom, if (r < late_sections) 0x67A else 0x63E, &.{ 0x0C, 0x78 }, 2);
    // The round of 0x646's `cmpi.w` (round 7's) ends there without a boss: its players walk out
    // (0x656, `exitOf`).
    var exit = try exitOf(arena, rom, r);
    const section_count: u32 = @intCast(if (exit != null) boss_from else boss_from + 1);
    const lift = try liftOf(arena, rom, r, mode_a, mode_b, u16be(rom, h + 6), u16be(rom, h + 12 + 8), section_count);
    // The walk out's opening loads the enemies' colours of the next entry, as a section's does.
    if (exit) |*ex| ex.colours = try sectionColours(rom, entryAt(rom, part, if (lift != null) section_count + 1 else section_count));
    const sections = try arena.alloc(round.Section, section_count);
    for (sections, 0..) |*s, k| {
        const lists_from = l.at;
        var placed: std.ArrayList(round.Spawn) = .empty;
        for (0..3) |_| {
            try group(arena, rom, &l, page, &placed);
            page +%= page_step * 0x100;
        }
        if (k == 0) try ownPlaced(arena, rom, r, &placed);
        // A later section's entry is the next of the section's number as its opening counts it
        // (0x618: ($FF04) + 1): one less than the section's own, but in the lift's round, whose
        // first ride counts too (0x18F3A), its first's opening not (0xDFC).
        const art_at = if (k == 0) first + 6 else entryAt(rom, part, @intCast(if (lift != null) k + 1 else k));
        const kinds = artKinds(rom, art_at);
        const art = try artTicks(rom, kinds);
        // The first section's loads count from the round's start (its first queued with the
        // round's load, started at the first tick of play); a later one's from its clear, its
        // first look the tick after.
        var loads: std.ArrayList(stream.Load) = .empty;
        try artLoads(arena, rom, kinds, if (k == 0) 0 else 1, &loads);
        // The lift's camera keeps its first limit (its mode never moves it). A leftward camera's
        // walls: its first the limits' set's left one, the others from their own place in the
        // walls' table (0x19586).
        const wall: i32 = if (leftward)
            (if (k == 0) u16be(rom, limits + 4) else u16be(rom, camera_stops + leftward_walls + 2 * @as(u32, @intCast(k))))
        else if (k == 0 or lift != null) first_wall else u16be(rom, camera_stops + 2 * @as(u32, @intCast(k)));
        s.* = .{
            .provenance = try std.fmt.allocPrint(arena, "section {d}: its wall {s} 0x{X:0>5}; its entry at ROM 0x{X:0>5} (0x1C1C4), its art kinds {any} loaded in {d} ticks (0xD70, the load lists at 0x8672 streamed by 0x8510){s}; its lists from byte {d} of the spawn lists (Nemesis at ROM 0x{X:0>5}){s}", .{
                k,
                if (k == 0) "the limit at" else "from the walls at",
                if (k == 0) limits + 6 else camera_stops,
                art_at,
                kinds,
                art,
                if (k == 0) ", from the round's start, the tick before its first tick of play, then a tick for its turn" else ", from its clear, then 2 ticks for its turn and the camera's",
                lists_from,
                lists_at,
                if (k == 0) "; then the pieces the round's start places itself (0xEF0)" else "",
            }),
            .wall = wall,
            .timer = if (k < later_from) timer_first else timer_later,
            .opens_after = @intCast(if (k == 0) art + 1 else art + 2),
            .streamed = try stream.schedule(arena, loads.items),
            .again = try againStream(arena, rom, kinds),
            .colours = try sectionColours(rom, art_at),
            .art = kinds,
            .placed = placed.items,
            .wave = try wave(arena, rom, &l),
            .reserve = try reserve(arena, rom, &l),
        };
    }

    // Round 8's boss's section (Mr. X's room: its own state, 0x4CA) is not written yet: its
    // script ends with its last section. TODO(PLAN item 15): Mr. X's room.
    const boss_section: ?round.Boss = if (exit != null or leftward) null else try bossSection(arena, rom, r, entryAt(rom, part, section_count), &l);

    // The ground: the floor's height (0xAD2A probes the floor map) at every place the script
    // places an enemy, the same in all.
    const floor_at = u32be(rom, rounds.header(rom, r) + 24);
    const floor = (try kosinski.decompress(arena, rom, floor_at)).bytes;
    const row_width: u32 = u16be(rom, h);
    const tables: u32 = floor_tables + @as(u32, u16be(rom, floor_tables + 2 * r));
    const heights: u32 = tables + @as(u32, u16be(rom, tables + 2));
    // In the round of 0xC8E's `cmpi.w` (round 7's lift) the script puts its enemies at the height
    // of 0xC96's `move.w #N,d6` without a probe, its placed pieces where their own code says.
    if (u16be(rom, 0xC8E) != 0x0C78 or u16be(rom, 0xC92) != 0xFF02 or u16be(rom, 0xC9A) != 0x6006) return error.BadData;
    const fixed_ground: ?u16 = if (u16be(rom, 0xC90) == r) @intCast(try immediate(rom, 0xC96, &.{ 0x3C, 0x3C }, 2)) else null;
    var ground: ?u16 = fixed_ground;
    if (fixed_ground == null) for (sections) |s| for (s.placed) |rec| {
        const at = @as(u32, @intCast(rec.depth >> 3)) * row_width + @as(u32, @intCast(rec.x >> 4));
        if (at >= floor.len) return error.BadData;
        const cell = if (rec.x & 0xF < 8) floor[at] >> 4 else floor[at] & 0xF;
        const at_height = u16be(rom, heights + 2 * @as(u32, cell));
        if (ground != null and ground.? != at_height) return error.BadData;
        ground = at_height;
    };
    // The floor is one kind of cell everywhere (round 1's): its height is the ground's at every
    // place. Else it is written cell by cell (round 4's holes, round 6's machines and conveyors):
    // each kind's height (0: a wall) and whether it has a floor (its attribute, the byte table the
    // tables' first word gives: 0 none; 1 a floor; 2 and 3 a conveyor carrying a pixel a tick to
    // the right, to the left: 0x92D8, 0x3E4A), the others refused until their rounds come.
    const kind = floor[0] >> 4;
    const uniform = for (floor) |byte| {
        if (byte >> 4 != kind or byte & 0xF != kind) break false;
    } else true;
    if (uniform and ground != null and ground.? != u16be(rom, heights + 2 * @as(u32, kind))) return error.BadData;
    const by_cells: ?round.Floor = if (uniform) null else blk: {
        const attributes: u32 = tables + @as(u32, u16be(rom, tables));
        var most: u8 = 0;
        for (floor) |byte| most = @max(most, byte >> 4, byte & 0xF);
        const cell_kinds = try arena.alloc(round.FloorKind, @as(usize, most) + 1);
        for (cell_kinds, 0..) |*k, i| {
            const attribute = rom[attributes + i];
            if (attribute > 3) return error.BadData;
            const carry: i8 = switch (attribute) {
                2 => 1,
                3 => -1,
                else => 0,
            };
            k.* = .{ .height = u16be(rom, heights + 2 * @as(u32, @intCast(i))), .floor = attribute != 0, .carry = carry };
        }
        if (floor.len % row_width != 0) return error.BadData;
        const rows = try arena.alloc([]const u8, floor.len / row_width);
        for (rows, 0..) |*row, y| {
            const text = try arena.alloc(u8, 2 * row_width);
            for (floor[y * row_width ..][0..row_width], 0..) |byte, i| {
                text[2 * i] = std.fmt.digitToChar(byte >> 4, .lower);
                text[2 * i + 1] = std.fmt.digitToChar(byte & 0xF, .lower);
            }
            row.* = text;
        }
        break :blk .{
            .provenance = try std.fmt.allocPrint(arena, "the floor map (Kosinski at ROM 0x{X:0>5}): a nibble per 8 pixels across (the high one first), a row per 8 of depth, as wide as plane A's map (0xAD30: lsr.w #4 and the nibble by bit 3; lsr.w #3; muls.w ($E02E)); each kind's height (ROM 0x{X:0>5}, words) and attribute (ROM 0x{X:0>5}, bytes: 1 a floor, 0 none; 0xAD2A answers it at or below the height)", .{ floor_at, heights, attributes }),
            .cell = .{ 8, 8 },
            .kinds = cell_kinds,
            .rows = rows,
        };
    };

    return .{
        .number = n,
        .provenance = try std.fmt.allocPrint(arena, "round {d}'s level events (0x436): the spawn lists (Nemesis at ROM 0x{X:0>5}), the sections (0x1C1C4), the walls (0x195D8), the music (0x11B44); its ground the height of the floor map's one kind of cell, everywhere (Kosinski at ROM 0x{X:0>5}, the cells' heights at ROM 0x{X:0>5}, 0x19C04; 0xAD2A probes it); its load's time measured (sor-remaster's load_times.zig)", .{ n, lists_at, floor_at, heights }),
        .art = try std.fmt.allocPrint(arena, "round{d}", .{n}),
        .music = try soundName(rom[round_music + r]),
        .ground = ground orelse return error.BadData,
        .floor = by_cells,
        .walk_off = try walkOffOf(rom, r),
        .load = if (n <= measured_loads.len) measured_loads[n - 1] else null,
        .camera = camera,
        .players = .{
            .provenance = "a life starts at the camera's X, at the depth and height of ROM 0x01E60 and 0x01E66 (move.w #N,($14,a0), ($18,a0)); player 2's depth less ROM 0x01EA6 (subi.w #N,($14,a0)) (0x1E0E); by the round (0x1E50): round 8 farther across by ROM 0x01E5A, round 7 by ROM 0x01E74 (addi.w #N,($10,a0)), round 6 deeper by ROM 0x01E84 (addi.w #N,($14,a0))",
            .x = start_x,
            .depth = .{ @intCast(depth), @as(i32, @intCast(depth)) - @as(i32, @intCast(second_less)) },
            .height = @intCast(height),
            .left = r == left_start,
            .specials = if (r == no_specials) 0 else 1,
        },
        .timer = .{
            .provenance = try std.fmt.allocPrint(arena, "a second every ROM 0x10C9C's ticks (0x10C88); {d} seconds at a section's start (ROM 0x{X:0>5}), {d} from section {d} (ROM 0x{X:0>5}, 0x{X:0>5}), by the round (0x195F6: ROM 0x195FC, 0x19606)", .{ timer_first, timer_at.first + 1, timer_later, later_from, timer_at.later + 1, timer_at.from + 2 }),
            .pace = @intCast(pace),
        },
        .sections = sections,
        .special = try specialArt(arena, rom),
        .boss = boss_section,
        .own_sound = try ownSound(arena, rom, r),
        .animation = try animation(arena, rom, r),
        .art_from = try artFrom(rom, r),
        .boss_art_full = @intCast(try immediate(rom, 0x9E8, &.{ 0x0C, 0x38, 0x00 }, 1)),
        .in_front = try inFront(arena, rom, r),
        .lift = lift,
        .exit = exit,
        .depth_walls = try depthWalls(rom, r),
        .knocked_back_left = try knockedBackLeft(rom, r),
        .enemy_walk = try enemyWalkOf(arena, rom, r),
    };
}

/// Round `r`'s lift, when its plane A's mode is the lift's (3: the camera's table at 0x18C34
/// runs 0x18C92, which steps the lift, 0x18ECA, and starts it, 0x18F32), plane B's too (0x1933A's
/// entry 3, 0x1938E): plane B's place down at the start its header's (`plane_b_y`), each
/// section's height the next word of 0x18F20 (by the section's number, counted from 1 as the
/// lift starts: `addq.w #1,($FF04)`), its first the start's; its speed up (0x193B0: `move.l
/// #N,(22,a1)`, negated, whole pixels); its jolts the words of 0x18F2C from the second, up to the
/// step of 0x18EE0's `cmpi.w` (the first, 0, unused); their period (0x18F44: `move.w #N,($FA12)`,
/// the ticks to the first and the period, the same); the wave's wait (0x750: `move.w #N,($FB16)`)
/// in the round whose sections go to it from their art (0xE0A's `cmpi.w`), then the next jolt
/// (`$FA27`, 0x18EE8).
fn liftOf(arena: std.mem.Allocator, rom: []const u8, r: u32, mode_a: u16, mode_b: u16, camera_x: u16, plane_b_y: u16, sections: u32) Error!?round.Lift {
    if (mode_a != 3 and mode_b != 3) return null;
    if (mode_a != 3 or mode_b != 3) return error.BadData;
    const at = struct {
        fn f(base: u32, offset: u16) u32 {
            return base + offset;
        }
    }.f;
    if (at(0x18C34, u16be(rom, 0x18C34 + 6)) != 0x18C92 or u16be(rom, 0x18C92) != 0x4EBA or u16be(rom, 0x18C96) != 0x4EBA) return error.BadData;
    if (at(0x18C94, u16be(rom, 0x18C94)) != 0x18ECA or at(0x18C98, u16be(rom, 0x18C98)) != 0x18F32) return error.BadData;
    if (at(0x1933A, u16be(rom, 0x1933A + 6)) != 0x1938E) return error.BadData;
    // The round whose sections wait for the lift: 0xE0A's, which sets the state $10 (0x748).
    if (u16be(rom, 0xE0A) != 0x0C78 or u16be(rom, 0xE0E) != 0xFF02 or u16be(rom, 0xE1A) != 0x31FC or u16be(rom, 0xE1C) != 0x10) return error.BadData;
    if (u16be(rom, 0xE0C) != r) return error.BadData;
    const heights_at = 0x18F20;
    if (u16be(rom, 0x18F18) != 0x31FB or u16be(rom, 0x18F1C) != 0xE126) return error.BadData;
    if (u16be(rom, heights_at) != plane_b_y) return error.BadData;
    const heights = try arena.alloc(i32, sections);
    for (heights, 0..) |*x, k| x.* = u16be(rom, heights_at + 2 * @as(u32, @intCast(k + 1)));
    if (u16be(rom, 0x193B0) != 0x237C or u16be(rom, 0x193B6) != 22 or u16be(rom, 0x193B4) != 0) return error.BadData;
    const speed = -s16be(rom, 0x193B2);
    const steps = try immediate(rom, 0x18EE0, &.{ 0x0C, 0x78 }, 2);
    if (u16be(rom, 0x18EE4) != 0xFB36 or u16be(rom, 0x18F2C) != 0 or steps < 2 or steps > 8) return error.BadData;
    const jolts = try arena.alloc(i8, steps - 1);
    for (jolts, 0..) |*j, k| j.* = @intCast(s16be(rom, 0x18F2C + 2 * @as(u32, @intCast(k + 1))));
    if (u16be(rom, 0x18F44) != 0x31FC or u16be(rom, 0x18F48) != 0xFA12) return error.BadData;
    const period = u16be(rom, 0x18F46);
    if (period >> 8 != period & 0xFF or period & 0xFF == 0) return error.BadData;
    if (u16be(rom, 0x750) != 0x31FC or u16be(rom, 0x754) != 0xFB16) return error.BadData;
    // The special attack's call (0x3FCC) in the round of 0x3FF0's `cmpi.w`: refused while the lift
    // is called ($FA0D), jolts ($FA14) or rides ($FA15).
    if (u16be(rom, 0x3FF0) != 0x0C78 or u16be(rom, 0x3FF4) != 0xFF02) return error.BadData;
    for ([_]u32{ 0x3FF8, 0x4000, 0x4008 }, [_]u16{ 0xFA0D, 0xFA14, 0xFA15 }) |a, flag| {
        if (u16be(rom, a) != 0x4A38 or u16be(rom, a + 2) != flag or u16be(rom, a + 4) != 0x6600) return error.BadData;
    }
    // The special attack on the lift (0x192A4: the round of 0x192D8's `cmpi.w`, 0x192F4): plane B
    // a mode on, its lowest `move.l #N<<16,(34,a1)` at 0x192F8 (the camera's that less plane B's
    // place, 0x19304), plane A in mode 7 (0x18D62: plane B's moves; level again from 0x18DA6's
    // `cmpi.w`); plane B's modes 4 to 7 (0x193E4 down to the lowest, 0x1940E back, 0x1942E ahead
    // to the camera's place, 0x19484 up), each by 16 pixels a tick; the police car (0x18D2A, the
    // same round) at 0x18D3E's `moveq` across, as much lower (0x18D32).
    if (u16be(rom, 0x192D8) != 0x0C78 or u16be(rom, 0x192DA) != r or u16be(rom, 0x192DC) != 0xFF02) return error.BadData;
    if (u16be(rom, 0x192F8) != 0x237C or u16be(rom, 0x192FC) != 0 or u16be(rom, 0x192FE) != 34) return error.BadData;
    const drop = u16be(rom, 0x192FA);
    if (u16be(rom, 0x19304) != 0x303C or u16be(rom, 0x19306) != drop or u16be(rom, 0x19400) != 0x0C69 or u16be(rom, 0x19402) != drop) return error.BadData;
    if (u16be(rom, 0x18D2A) != 0x0C78 or u16be(rom, 0x18D2C) != r or u16be(rom, 0x18D32) != 0x323C or u16be(rom, 0x18D34) != drop) return error.BadData;
    if (u16be(rom, 0x19454) != 0x0C69 or u16be(rom, 0x19456) != camera_x) return error.BadData;
    if (u16be(rom, 0x18DA6) != 0x0C69 or u16be(rom, 0x18DAA) != 14 or u16be(rom, 0x18DBA) != 0x31FC or u16be(rom, 0x18DBC) != 3) return error.BadData;
    for ([_]u32{ 0x193E4, 0x1940E, 0x1942E, 0x19484 }, [_]u32{ 0x00100000, 0xFFF00000, 0x00100000, 0xFFF00000 }) |a, v| {
        if (u16be(rom, a) != 0x237C or u32be(rom, a + 2) != v) return error.BadData;
    }
    return .{
        .provenance = try std.fmt.allocPrint(arena, "the lift's camera (plane A's mode 3, 0x18C92; plane B's, 0x1938E): plane B from its header's place down, up to each section's height (ROM 0x{X:0>5}, a word a section from the second), by ROM 0x193B2's pixels a tick (negated); the jolts of the lift's start and stop (0x18ECA: ROM 0x18F2E, a word each, to the step of ROM 0x18EE2), a step every ROM 0x18F46's ticks (0x18F32); the wave's wait (0x748: ROM 0x00752's ticks), then the next jolt; no special attack while it is called, jolts or rides in the round of ROM 0x03FF2 (0x3FCC); the special attack's run by plane B (0x192F4): down to ROM 0x192FA's, back, ahead, up, the camera level again within ROM 0x18DA8's (0x18D62), the police car at ROM 0x18D3E's moveq (0x18CD4)", .{heights_at}),
        .from = plane_b_y,
        .heights = heights,
        .speed = speed,
        .jolts = jolts,
        .period = @intCast(period & 0xFF),
        .wait = @intCast(u16be(rom, 0x752)),
        .holds_special = u16be(rom, 0x3FF2) == r,
        .special_drop = drop,
        .special_settle = u16be(rom, 0x18DA8),
        .special_car_x = try entities.moveq(rom, 0x18D3E, 0),
    };
}

/// How round `r`'s enemies walk on its own floor (the round of 0x9E96's `cmpi.w`, round 7's; the
/// same at 0x9FA2 and 0xA020): across past `cmpi.l #N,d1` at 0x9FB0 (0x9F96), in depth short of
/// 0xA038's (0xA00E); their walk (0x9ED4) looks `moveq #N,d1` at 0x9ED4 across for a cell deeper
/// than 0x9EE8's `cmpi.w #N,d6`, and back by 0x9EFA's and 0x9EFC's `moveq`s for the level's top.
fn enemyWalkOf(arena: std.mem.Allocator, rom: []const u8, r: u32) Error!?round.EnemyWalk {
    for ([_]u32{ 0x9E96, 0x9FA2, 0xA020 }) |at| {
        if (u16be(rom, at) != 0x0C78 or u16be(rom, at + 4) != 0xFF02 or u16be(rom, at + 2) != u16be(rom, 0x9E98)) return error.BadData;
    }
    if (u16be(rom, 0x9E98) != r) return null;
    if (u16be(rom, 0x9EE4) != 0x4EBA or u16be(rom, 0x9F00) != 0x4EBA) return error.BadData;
    const x_least = try longPixels(rom, 0x9FB0, &.{ 0x0C, 0x81 });
    const depth_most = try longPixels(rom, 0xA038, &.{ 0x0C, 0x81 });
    const back_x = try entities.moveq(rom, 0x9EFA, 1);
    const back_depth = try entities.moveq(rom, 0x9EFC, 2);
    if (back_x > 0 or back_depth > 0) return error.BadData;
    // Knocked away (0x9F22, the same round): as low as `cmpi.w #N,(24,a0)` at 0x9F2A, the cell
    // under it deeper than 0x9F36's, else the one 0x9F3C's `moveq` ahead; higher, the one 0x9F56's.
    if (u16be(rom, 0x9F22) != 0x0C78 or u16be(rom, 0x9F24) != r or u16be(rom, 0x9F2E) != 24 or u16be(rom, 0x9F36) != 0x0C46 or u16be(rom, 0x9F38) != u16be(rom, 0x9EEA) or u16be(rom, 0x9F4E) != 0x0C46 or u16be(rom, 0x9F50) != u16be(rom, 0x9EEA)) return error.BadData;
    return .{
        .provenance = try std.fmt.allocPrint(arena, "the enemies' walk in round {d} (0x9E96, 0x9FA2, 0xA020): past ROM 0x09FB2's place across, short of ROM 0x0A03A's depth; looking ROM 0x09ED5's pixels across for a cell deeper than ROM 0x09EEA's, back ROM 0x09EFB's and ROM 0x09EFD's for the level's top", .{r + 1}),
        .x_least = @intCast(x_least),
        .depth_most = @intCast(depth_most),
        .ahead = try entities.moveq(rom, 0x9ED4, 1),
        .deep = @intCast(try immediate(rom, 0x9EE8, &.{ 0x0C, 0x46 }, 2)),
        .back = .{ -back_x, -back_depth },
        .flight_low = @intCast(try immediate(rom, 0x9F2A, &.{ 0x0C, 0x68 }, 2)),
        .flight_ahead = try entities.moveq(rom, 0x9F3C, 1),
    };
}

/// Whether a new life knocks round `r`'s enemies back to the left (0x9522): from the round of
/// 0x9552's `cmpi.w` on (bcs past), their animation's the other and their speed across negated.
fn knockedBackLeft(rom: []const u8, r: u32) Error!bool {
    if (u16be(rom, 0x9552) != 0x0C78 or u16be(rom, 0x9556) != 0xFF02 or rom[0x9558] != 0x65 or u16be(rom, 0x9560) != 0x4469 or u16be(rom, 0x9562) != 28) return error.BadData;
    return r >= u16be(rom, 0x9554);
}

/// Whether round `r`'s walls stop the players' moves in depth (0x3B4E): not in the round of its
/// `cmpi.w` (round 7's).
fn depthWalls(rom: []const u8, r: u32) Error!bool {
    if (u16be(rom, 0x3B54) != 0x0C78 or u16be(rom, 0x3B58) != 0xFF02 or u16be(rom, 0x3B5A) != 0x672C) return error.BadData;
    return u16be(rom, 0x3B56) != r;
}

/// How round `r` ends without a boss (0x646: the round of its `cmpi.w`, round 7's): its last
/// section's opening (0x656) stops the timer ($FA79) and has the players walk out ($FA73, 0x502C):
/// each left while at or past `cmpi.w #N,d0` at 0x5062, then down before 0x5074's depth or up
/// from 0x507C's; there `move.b #N,($FA74)` at 0x508A turns of a player there, walking left; then
/// the round ends (0x5098: $FA71 and the fade, as a boss's beating).
fn exitOf(arena: std.mem.Allocator, rom: []const u8, r: u32) Error!?round.Exit {
    if (u16be(rom, 0x646) != 0x0C78 or u16be(rom, 0x64A) != 0xFF02 or u16be(rom, 0x64C) != 0x6708) return error.BadData;
    if (u16be(rom, 0x648) != r) return null;
    if (u32be(rom, 0x656) != 0x11FC0001 or u16be(rom, 0x65A) != 0xFA79 or u32be(rom, 0x65C) != 0x11FC0001 or u16be(rom, 0x660) != 0xFA73) return error.BadData;
    if (u16be(rom, 0x508E) != 0xFA74 or u32be(rom, 0x5098) != 0x11FC0001 or u16be(rom, 0x509C) != 0xFA71) return error.BadData;
    return .{
        .provenance = try std.fmt.allocPrint(arena, "the players' walk out (0x502C, set at 0x656 with the timer stopped): left while at or past ROM 0x05064's place across, then into the depths of ROM 0x05076 to ROM 0x0507E's (excluded), then left ROM 0x0508A's turns of a player there; then the round ends (0x5098); the colours of the round's next entry (0x608)", .{}),
        .x = @intCast(try immediate(rom, 0x5062, &.{ 0x0C, 0x40 }, 2)),
        .depth = .{ @intCast(try immediate(rom, 0x5074, &.{ 0x0C, 0x40 }, 2)), @intCast(try immediate(rom, 0x507C, &.{ 0x0C, 0x40 }, 2)) },
        .ticks = @intCast(try immediate(rom, 0x508A, &.{ 0x11, 0xFC, 0x00 }, 1)),
    };
}

/// Round `r`'s boss's section, its entry at `at`, its wave and reserve the next of the lists `l`.
fn bossSection(arena: std.mem.Allocator, rom: []const u8, r: u32, at: u32, l: *Lists) Error!round.Boss {
    // The boss's section (0x59C): the camera stops, the music fades ($E0), the boss's art loads
    // (the art load of 0x1C378), then $20 ticks, the boss's music ($87); then the art of the
    // section's slots and the boss's again, and the wave.
    const fade = try immediate(rom, 0x5A4, &.{ 0x11, 0xFC, 0x00 }, 1);
    const wait = try immediate(rom, 0x5CE, &.{ 0x31, 0xFC }, 2);
    const music = try immediate(rom, 0x5E0, &.{ 0x11, 0xFC, 0x00 }, 1);
    const boss_load = rom[round_bosses + 6 * r + 4];
    var buf: [8]u16 = undefined;
    const boss_blocks = try loadBlocks(rom, boss_load, &buf);
    const music_after = 1 + streamTicks(boss_blocks) + wait - 1;
    const boss_art = artKinds(rom, at);
    var kinds = boss_art;
    kinds[3] = boss_load;
    const wave_after = 1 + try artTicks(rom, kinds);
    // From the last section's clear: the boss's art a tick later, then the wait, then the art
    // loads, their first look the tick after the music's.
    var boss_loads: std.ArrayList(stream.Load) = .empty;
    try boss_loads.append(arena, .{ .after = 1, .blocks = try loadStream(arena, rom, boss_load) });
    try artLoads(arena, rom, kinds, @intCast(wait), &boss_loads);
    return .{
        .provenance = try std.fmt.allocPrint(arena, "the boss's section (0x59C): the fade's request at ROM 0x{X:0>5}, the boss's art (load {d}, 0x1C378) streamed, then the wait of ROM 0x{X:0>5}, the music's request at ROM 0x{X:0>5}; then the section's art and the boss's (0xD70) before its wave", .{ 0x5A7, boss_load, 0x5D0, 0x5E3 }),
        .fade = try soundName(@intCast(fade)),
        .music = try soundName(@intCast(music)),
        .music_after = @intCast(music_after),
        .wave_after = @intCast(wave_after),
        .streamed = try stream.schedule(arena, boss_loads.items),
        .again = if (try copiesBossArt(rom, r)) &.{} else try againStream(arena, rom, kinds),
        .section_colours = try sectionColours(rom, at),
        .colours = try palettes.bossColoursName(arena, rom, u32be(rom, round_bosses + 6 * r)) orelse return error.BadData,
        // The section's art kinds, the boss's in the last slot (0x59C: its art load).
        .art = kinds,
        .wave = try wave(arena, rom, l),
        .reserve = try reserve(arena, rom, l),
    };
}

/// The camera's rocking (0x1916E, after plane B's bands: its speed grows by its acceleration,
/// which turns to its opposite at the end of its ticks, then every period; plane A's place down
/// moves by the speed), set by the round's load entry of 0x19C4C: `move.l #N,($E1AA)` (its
/// acceleration), `move.w #N,($E1A8)` (its first ticks, then its period), `move.l #0,($E1AE)`
/// (its speed); the special attack's call sets it again (0x4086, for the round of its
/// `cmpi.w`). None in a round whose entry does not.
fn wobbleOf(rom: []const u8, r: u32) Error!?round.Wobble {
    const loads: u32 = 0x19C4C;
    const load = loads + u16be(rom, loads + 2 * r);
    // The entry's moves, after its three `move.b #1,(N).w` and the own sound's `move.w`.
    const at = load + 24;
    if (u16be(rom, load) != 0x11FC or u16be(rom, at) != 0x21FC or u16be(rom, at + 6) != 0xE1AA) return null;
    if (u16be(rom, at + 8) != 0x31FC or u16be(rom, at + 12) != 0xE1A8 or u16be(rom, at + 14) != 0x21FC or u32be(rom, at + 16) != 0 or u16be(rom, at + 20) != 0xE1AE) return error.BadData;
    // The special attack's call sets it again in the same round, as the load does.
    if (u16be(rom, 0x4086) != 0x0C78 or u16be(rom, 0x4088) != r or u32be(rom, 0x408E + 2) != u32be(rom, at + 2) or u16be(rom, 0x4096 + 2) != u16be(rom, at + 10)) return error.BadData;
    const ticks = u16be(rom, at + 10);
    return .{ .ticks = @intCast(ticks >> 8), .period = @intCast(ticks & 0xFF), .accel = @bitCast(u32be(rom, at + 2)) };
}

/// What the round draws in front of its planes' cells in front of the sprites (an object's
/// flags' bit 4): the entities its script places (0xC80 for a wave's or a reserve's, 0xD10 for a
/// group's: `bset #4,(1,a1)` in the round of their `cmpi.w`), the players at each life's start
/// (0x1EDC: byte 7 of the round's entry at 0x1F2C or'ed into their flags), the things (0x6AA6:
/// the round's byte of 0x6AB4).
fn inFront(arena: std.mem.Allocator, rom: []const u8, r: u32) Error!round.InFront {
    const placing = [_]u32{ 0xC80, 0xD10 };
    var script = false;
    for (placing) |at| {
        if (u16be(rom, at) != 0x0C78 or u16be(rom, at + 4) != 0xFF02 or u16be(rom, at + 6) != 0x6606 or u32be(rom, at + 8) != 0x08E80004 or u16be(rom, at + 12) != 0x0001) return error.BadData;
        const in_round = u16be(rom, at + 2) == r;
        if (at != placing[0] and in_round != script) return error.BadData;
        script = in_round;
    }
    if (u16be(rom, 0x1EDC) != 0x8128 or u16be(rom, 0x1EDE) != 0x0001) return error.BadData;
    const lives_at: u32 = 0x1F2C + 10 * r;
    const things_at: u32 = 0x6AB4 + r;
    if (u16be(rom, 0x6AA6) != 0x3038 or u16be(rom, 0x6AA8) != 0xFF02 or u16be(rom, 0x6AAA) != 0x103B) return error.BadData;
    return .{
        .provenance = try std.fmt.allocPrint(arena, "the objects' flags' bit 4: the script's (0xC80, 0xD10: cmpi.w #N,($FF02)), the players' (0x1EDC: ROM 0x{X:0>5}), the things' (0x6AA6: ROM 0x{X:0>5})", .{ lives_at + 7, things_at }),
        .script = script,
        .players = rom[lives_at + 7] & 0x10 != 0,
        .things = rom[things_at] & 0x10 != 0,
    };
}

/// The scripts of the rounds of `extracted`.
pub fn all(arena: std.mem.Allocator, rom: []const u8) Error![]const round.Round {
    const out = try arena.alloc(round.Round, extracted.len);
    for (out, extracted) |*o, n| o.* = try extract(arena, rom, n);
    return out;
}

test "a stream's ticks: five tiles a display tick, the next block when one ends" {
    // 257 tiles: 52 display ticks, the last a middle: seen empty 26 ticks after its queueing's.
    try std.testing.expectEqual(@as(u32, 27), streamTicks(&.{257}));
    // 295 tiles: 59, the last an end: seen at the next tick.
    try std.testing.expectEqual(@as(u32, 31), streamTicks(&.{295}));
    // Two blocks of 10 tiles: the first ends at its tick's middle, the second at the next's.
    try std.testing.expectEqual(@as(u32, 3), streamTicks(&.{ 10, 10 }));
    try std.testing.expectEqual(@as(u32, 0), streamTicks(&.{}));
}

test "a section's lists: the groups placed by page, the timed wave, the waiting entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A synthetic image of the tables the entries read: the offsets by nibble, the items held,
    // the art kinds by type (Galsia's 1), and load list 11 (a block of 10 tiles).
    const rom = try arena.alloc(u8, 0x10000);
    @memset(rom, 0);
    for (0..16) |k| rom[target_offsets + k] = @intCast(16 * k);
    rom[target_offsets + 15] = 0xF0; // -16
    rom[breakable_items + 2] = 0x4B;
    rom[art_of_type + 2] = 1;
    std.mem.writeInt(u16, rom[load_lists + 2 * 11 ..][0..2], 0x100, .big);
    std.mem.writeInt(u16, rom[load_lists + 0x100 ..][0..2], 0, .big);
    std.mem.writeInt(u32, rom[load_lists + 0x102 ..][0..4], 0x9000, .big);
    std.mem.writeInt(u16, rom[0x9000..][0..2], 10, .big);
    // Its code table: value 0, eight of them a code of 1 bit (0); the codes all 0.
    @memcpy(rom[0x9002..][0..4], &[_]u8{ 0x00, 0x71, 0x00, 0xFF });
    const lists = [_]u8{
        0x00, 0x01, // a group of two
        0x22, 0x80, 0x1F, 0x00, 0x50, 0x41, // Galsia, waits for the camera, X $x50, Y $41 (level 1)
        0x11, 0x00, 0x02, 0x00, 0x60, 0x20, // a breakable holding item 2
        0xFF, 0xFF, // no group
        0x00, 0x00, // a group of one
        0xA2, 0x00, 0x00, 0x00, 0x10, 0x30, // a two-player Galsia
        0x00, 0x10, 0x22, 0x03, 0x00, 0x00, 0x58, 0x00, // after 16, from the right
        0x00, 0x99, // the wave's end
        0x00, 0x08, 0x22, 0x00, 0x00, 0x00, 0x48, 0x01, 0x99, 0x00, // one waiting, from the left
    };
    var l: Lists = .{ .bytes = &lists };
    var placed: std.ArrayList(round.Spawn) = .empty;
    var page: u16 = 0x300;
    for (0..3) |_| {
        try group(arena, rom, &l, page, &placed);
        page += 0x100;
    }
    const p = placed.items;
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqual(@as(i32, 0x350), p[0].x);
    try std.testing.expectEqual(@as(i32, 0x41), p[0].depth);
    try std.testing.expectEqual(@as(u2, 1), p[0].level);
    try std.testing.expect(p[0].traits.contains(.waits_for_camera));
    try std.testing.expectEqual(round.Offset{ .x = 16, .depth = -16 }, p[0].offset.?);
    try std.testing.expectEqualStrings("apple", p[1].holds.?);
    try std.testing.expectEqual(@as(i32, 0x510), p[2].x);
    try std.testing.expect(p[2].two_players);
    const w = try wave(arena, rom, &l);
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqual(@as(u16, 16), w[0].after);
    try std.testing.expectEqual(round.Side.right, w[0].side);
    try std.testing.expectEqual(round.Entrance.approach, w[0].entrance.?);
    const r = try reserve(arena, rom, &l);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqual(round.Side.left, r[0].side);
    // Its art: a tick, then 10 tiles, two display ticks, the last a tick's middle.
    try std.testing.expectEqual(@as(u16, 3), r[0].arrives_after);
    try std.testing.expectEqual(lists.len, l.at);
}

test "packed decimal" {
    try std.testing.expectEqual(@as(u8, 40), try decimal(0x40));
    try std.testing.expectError(error.BadData, decimal(0x4A));
}

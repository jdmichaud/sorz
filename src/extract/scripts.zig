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

/// The rounds whose scripts the extractor writes (PLAN items 13 and 15: rounds 1 to 3; the others,
/// whose last sections differ, to come).
pub const extracted = [_]u8{ 1, 2, 3 };

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
        0x16 => "drifter",
        0x17 => "rain",
        0x18 => "crate",
        0x19 => "knockable",
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
        0x47 => "beef",
        0x4B => "apple",
        0x4C => "life",
        0x4D => "flight",
        0x4E => "lamp",
        0x4F => "special_item",
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
    var out: std.ArrayList(round.Band) = .empty;
    while (true) {
        const rows_less = s16be(rom, a);
        if (rows_less < 0) break;
        const times = u16be(rom, a + 2);
        const per = u16be(rom, a + 4);
        if (rows_less > 63 or times == 0 or per == 0 or times > 255 or per > 255) return error.BadData;
        try out.append(arena, .{ .rows = @intCast(rows_less + 1), .times = @intCast(times), .per = @intCast(per) });
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
/// ratio (0x190EA: muls.w, then divs.w), in mode 1 the plane's (`atPlaneX`). The other modes (the
/// water's, the lift's) are refused until their rounds come (PLAN item 15).
fn bandsInMode(arena: std.mem.Allocator, rom: []const u8, r: u32, p: u32, mode: u16) Error![]const round.Band {
    const bands = try bandsOf(arena, rom, r, p);
    return switch (mode) {
        0 => bands,
        1 => atPlaneX(arena, bands),
        else => error.BadData,
    };
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
/// tick's end. (TODO(PLAN item 15): round 5's twins' case, 0x18E96; an arrival that takes art
/// slot 1 before the special attack, 0x9CA.)
fn againStream(arena: std.mem.Allocator, rom: []const u8, kinds: [4]u8) Error![]const round.Streamed {
    if (u32be(rom, 0x18E8C) != 0xC1FC0003 or u16be(rom, 0x18E90) != 0x0640 or u16be(rom, 0x18E92) != first_art_load + 1) return error.BadData;
    const load: u16 = if (kinds[3] != 0) kinds[3] else if (kinds[1] != 0) @as(u16, kinds[1] - 1) * 3 + first_art_load + 1 else return &.{};
    return stream.schedule(arena, &.{.{ .after = 0, .blocks = try loadStream(arena, rom, load), .before_head = true }});
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
    if (boss(t)) {
        if (variant != 0) s.traits.insert(.twin);
        s.bar = offsets;
        return;
    }
    if (!commonEnemy(t)) return;
    const d = try spawns.decode(rom, t, variant, offsets, palette);
    s.entrance = d.entrance;
    s.traits = d.traits;
    s.offset = d.offset;
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
        0x11, 0x18, 0x19 => {
            // A breakable, a crate, an oil drum: the item it holds (its byte $41, which 0x7E54
            // reads), an index from 1 (0 for none).
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
        // A drip, the rain, a flight, a lamp: their code reads none of the bytes.
        0x14, 0x17, 0x4D, 0x4E => {
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
/// (`rts`), or round 3's sound (0x11310): while its times last ($FFFA55), its ticks ($FFFB50)
/// count down; at zero they come again from $FFFB51, a time is spent and the sound is asked for.
/// Its set-up (0x19D08: its times, its first ticks and the next ones) runs at the round's load (the
/// round's entry of 0x19C4C) and at a section's opening (0x195AE: for the round of its
/// `cmpi.w`). A routine of another kind (round 5's horn) is refused until its round comes.
fn ownSound(arena: std.mem.Allocator, rom: []const u8, r: u32) Error!?round.OwnSound {
    const table: u32 = 0x11300;
    const at: u32 = table + u16be(rom, table + 2 * r);
    if (u16be(rom, at) == 0x4E75) return null;
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

/// The pieces the round's start places itself after the first section's groups (0xEF0: for the
/// round of its `cmpi.w`, two objects, each in the enemies' places (0xE46), of the type and the
/// place across of its `move.b` and `move.w`, its depth 0): round 3's two lamps.
fn ownPlaced(arena: std.mem.Allocator, rom: []const u8, r: u32, out: *std.ArrayList(round.Spawn)) Error!void {
    if (u16be(rom, 0xEF0) != 0x0C78 or u16be(rom, 0xEF4) != 0xFF02 or u16be(rom, 0xEF6) & 0xFF00 != 0x6600) return error.BadData;
    if (u16be(rom, 0xEF2) != r) return;
    for ([_]u32{ 0xEF8, 0xF08 }) |at| {
        if (u16be(rom, at) != 0x4EBA or u16be(rom, at + 4) != 0x137C or u16be(rom, at + 8) != 0 or u16be(rom, at + 10) != 0x337C or u16be(rom, at + 14) != 16) return error.BadData;
        var s = try entry(rom, @intCast(u16be(rom, at + 6)), .{ 0, 0, 0 }, 0);
        s.x = u16be(rom, at + 12);
        try out.append(arena, s);
    }
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
        s.arrives_after = try arrivalTicks(rom, t & 0x7F);
        s.streamed = try arrivalStream(arena, rom, t & 0x7F);
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
    const limits_set: u32 = u16be(rom, h + 4) * 8;
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
    const plane_b: [2]u8 = switch (mode_b) {
        // Round 5's plane B keeps its own place down and wobbles (0x1934A, 0x1916C): with round 5.
        0 => if (r == 4) return error.BadData else .{ 1, 1 },
        1 => .{ 1, if (r == 0) 1 else @as(u8, 1) << plane_b_shift },
        else => return error.BadData,
    };
    const camera: round.Camera = .{
        .provenance = try std.fmt.allocPrint(arena, "the round header's plane A (ROM 0x{X:0>5}): its X and Y; its limits' set {d} (0x1998A): the first section's wall, the limit behind, the limits down; the planes in their modes (the header's mode words): in mode 0 (0x18C4A, 0x1934A) their bands at the camera's X times their ratios, plane B at plane A's X and Y; in mode 1 plane A at the camera's X, plane B at it in round 1, a quarter of it in the others (ROM 0x19378: asr.w #2); the wall reached within ROM 0x006B0's pixels (0x6A6); the left behind brought to the camera's X less ROM 0x006CE, at depth ROM 0x00707; the edges: the camera's X less 8 (ROM 0x00CB8: subq.w #8,d0) and plus ROM 0x00CB0 (0xC60); it follows a player whose place on the screen (its object's, the sprites' origin 128 more) is before ROM 0x18F80's or from ROM 0x18F88's (subi.l), by at most ROM 0x18FD8's pixels a tick (0x18F5C); the players kept from ROM 0x043F5's pixels across, for ROM 0x043F8's more, and on the depths from ROM 0x0440B's to ROM 0x04415's (round 7, ROM 0x04419's from 0, to ROM 0x04420's) (0x43AA); a heavy fall's shake ROM 0x04D55's ticks (0x4D40), ROM 0x19293's pixels (0x19282); the planes' bands, their rows and ratios, from the layout records (0x199C6, the table at ROM 0x5F788), the strips the camera brings in (0x18B3C); how the frames copy the planes' scroll by plane A's mode (0x196A4)", .{ h, limits_set / 8 }),
        .x = u16be(rom, h + 6),
        .y = u16be(rom, h + 8),
        .x_min = u16be(rom, limits + 4),
        .y_min = u16be(rom, limits),
        .y_max = u16be(rom, limits + 2),
        .plane_b = plane_b,
        .plane_b_down = mode_b == 0,
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
    };
    const first_wall: i32 = u16be(rom, limits + 6);

    // The timer (0x195F6): moveq #$40 for the first sections, #$50 from the section of the
    // compare; its pace (0x10C88).
    const timer_first = try decimal(try immediate(rom, 0x195F8, &.{0x70}, 1));
    const later_from = try immediate(rom, 0x1961C, &.{ 0x0C, 0x78 }, 2);
    const timer_later = try decimal(try immediate(rom, 0x19624, &.{0x70}, 1));
    const pace = try immediate(rom, 0x10C9A, &.{ 0x31, 0xFC }, 2);

    // A life starts at the camera's X, at depth $40 (player 2, $20 less) and height 0 (0x1E0E).
    const depth = try immediate(rom, 0x1E5E, &.{ 0x31, 0x7C }, 2);
    const second_less = try immediate(rom, 0x1EA2, &.{ 0x04, 0x68 }, 2);
    const height = try immediate(rom, 0x1E64, &.{ 0x31, 0x7C }, 2);

    var l: Lists = .{ .bytes = lists, .at = list_start - 0xFF6800 };
    // Rounds 1 to 4 (0x5F4): sections 0 to 3, then the boss's.
    const section_count = 4;
    const sections = try arena.alloc(round.Section, section_count);
    for (sections, 0..) |*s, k| {
        const lists_from = l.at;
        var placed: std.ArrayList(round.Spawn) = .empty;
        for (0..3) |_| {
            try group(arena, rom, &l, page, &placed);
            page +%= page_step * 0x100;
        }
        if (k == 0) try ownPlaced(arena, rom, r, &placed);
        const art_at = if (k == 0) first + 6 else entryAt(rom, part, @intCast(k));
        const kinds = artKinds(rom, art_at);
        const art = try artTicks(rom, kinds);
        // The first section's loads count from the round's start (its first queued with the
        // round's load, started at the first tick of play); a later one's from its clear, its
        // first look the tick after.
        var loads: std.ArrayList(stream.Load) = .empty;
        try artLoads(arena, rom, kinds, if (k == 0) 0 else 1, &loads);
        const wall: i32 = if (k == 0) first_wall else u16be(rom, camera_stops + 2 * @as(u32, @intCast(k)));
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
            .placed = placed.items,
            .wave = try wave(arena, rom, &l),
            .reserve = try reserve(arena, rom, &l),
        };
    }

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
    const boss_art = artKinds(rom, entryAt(rom, part, section_count));
    var kinds = boss_art;
    kinds[3] = boss_load;
    const wave_after = 1 + try artTicks(rom, kinds);
    // From the last section's clear: the boss's art a tick later, then the wait, then the art
    // loads, their first look the tick after the music's.
    var boss_loads: std.ArrayList(stream.Load) = .empty;
    try boss_loads.append(arena, .{ .after = 1, .blocks = try loadStream(arena, rom, boss_load) });
    try artLoads(arena, rom, kinds, @intCast(wait), &boss_loads);
    const boss_section: round.Boss = .{
        .provenance = try std.fmt.allocPrint(arena, "the boss's section (0x59C): the fade's request at ROM 0x{X:0>5}, the boss's art (load {d}, 0x1C378) streamed, then the wait of ROM 0x{X:0>5}, the music's request at ROM 0x{X:0>5}; then the section's art and the boss's (0xD70) before its wave", .{ 0x5A7, boss_load, 0x5D0, 0x5E3 }),
        .fade = try soundName(@intCast(fade)),
        .music = try soundName(@intCast(music)),
        .music_after = @intCast(music_after),
        .wave_after = @intCast(wave_after),
        .streamed = try stream.schedule(arena, boss_loads.items),
        .again = try againStream(arena, rom, kinds),
        .section_colours = try sectionColours(rom, entryAt(rom, part, section_count)),
        .colours = try palettes.bossColoursName(arena, rom, u32be(rom, round_bosses + 6 * r)) orelse return error.BadData,
        .wave = try wave(arena, rom, &l),
        .reserve = try reserve(arena, rom, &l),
    };

    // The ground: the floor's height (0xAD2A probes the floor map) at every place the script
    // places an enemy, the same in all.
    const floor_at = u32be(rom, rounds.header(rom, r) + 24);
    const floor = (try kosinski.decompress(arena, rom, floor_at)).bytes;
    const row_width: u32 = u16be(rom, h);
    const tables: u32 = floor_tables + @as(u32, u16be(rom, floor_tables + 2 * r));
    const heights: u32 = tables + @as(u32, u16be(rom, tables + 2));
    var ground: ?u16 = null;
    for (sections) |s| for (s.placed) |rec| {
        const at = @as(u32, @intCast(rec.depth >> 3)) * row_width + @as(u32, @intCast(rec.x >> 4));
        if (at >= floor.len) return error.BadData;
        const cell = if (rec.x & 0xF < 8) floor[at] >> 4 else floor[at] & 0xF;
        const at_height = u16be(rom, heights + 2 * @as(u32, cell));
        if (ground != null and ground.? != at_height) return error.BadData;
        ground = at_height;
    };
    // The floor is one kind of cell everywhere (round 1's), so its height is the ground's at
    // every place: a round whose floor's cells differ needs them cell by cell (its walls, its
    // pits, PLAN item 15), and is refused until then.
    const kind = floor[0] >> 4;
    for (floor) |byte| if (byte >> 4 != kind or byte & 0xF != kind) return error.BadData;
    if (ground != null and ground.? != u16be(rom, heights + 2 * @as(u32, kind))) return error.BadData;

    return .{
        .number = n,
        .provenance = try std.fmt.allocPrint(arena, "round {d}'s level events (0x436): the spawn lists (Nemesis at ROM 0x{X:0>5}), the sections (0x1C1C4), the walls (0x195D8), the music (0x11B44); its ground the height of the floor map's one kind of cell, everywhere (Kosinski at ROM 0x{X:0>5}, the cells' heights at ROM 0x{X:0>5}, 0x19C04; 0xAD2A probes it); its load's time measured (sor-remaster's load_times.zig)", .{ n, lists_at, floor_at, heights }),
        .art = try std.fmt.allocPrint(arena, "round{d}", .{n}),
        .music = try soundName(rom[round_music + r]),
        .ground = ground orelse return error.BadData,
        .load = if (n <= measured_loads.len) measured_loads[n - 1] else null,
        .camera = camera,
        .players = .{
            .provenance = "a life starts at the camera's X, at the depth and height of ROM 0x01E60 and 0x01E66 (move.w #N,($14,a0), ($18,a0)); player 2's depth less ROM 0x01EA6 (subi.w #N,($14,a0)) (0x1E0E)",
            .x = 0,
            .depth = .{ @intCast(depth), @as(i32, @intCast(depth)) - @as(i32, @intCast(second_less)) },
            .height = @intCast(height),
        },
        .timer = .{
            .provenance = try std.fmt.allocPrint(arena, "a second every ROM 0x10C9C's ticks (0x10C88); {d} seconds at a section's start (ROM 0x195F9), {d} from section {d} (ROM 0x19625, 0x1961E)", .{ timer_first, timer_later, later_from }),
            .pace = @intCast(pace),
        },
        .sections = sections,
        .special = try specialArt(arena, rom),
        .boss = boss_section,
        .own_sound = try ownSound(arena, rom, r),
        .animation = try animation(arena, rom, r),
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

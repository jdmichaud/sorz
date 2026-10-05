//! Play's screen (docs/content.md: the `play` set and `screens/round.json`): the video memory a
//! round's set-up leaves (the round's art, play's pattern loads, and the tiles the game makes
//! itself: the banner's letters, the round's number, the bars' tiles and their fills), and from
//! it the round's fixed texts as frames (the banner, the pause, the time over), the status bar's
//! parts as maps, and the screen's record: where each part goes, how the banner moves.
//!
//! The ROM's places: the play set-up 0x110AC, 0x10E42 (the big letters masked to one colour, the
//! round's number), 0x11156 and 0x11072 (the bars' tiles, built from rows), 0x11564; the fixed
//! sprite lists 0x1079A, 0x109F6 and 0x10A6E (8 bytes an entry: y, size, link, name, x, the
//! positions plus 128); the banner's steps (0x11A50); the status bar's cells (0x4CD0, 0x4D60,
//! 0x4E14, 0x4E6C, 0x10C88, 0x115CC).
const std = @import("std");
const sorz = @import("sorz");
const art = sorz.content.art;
const records = sorz.content.screens;
const rom_mod = @import("rom.zig");
const blocks = @import("blocks.zig");
const vram_mod = @import("vram.zig");
const screens = @import("screens.zig");
const rounds = @import("rounds.zig");
const fonts = @import("fonts.zig");
const builder_mod = @import("builder.zig");
const Builder = builder_mod.Builder;
const Vram = vram_mod.Vram;

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;

pub const Error = screens.Error || error{BadData};

// The tiles the game makes, each set of them a block of its own: its key (the routine that makes
// it) and its sheet.
const letters_block: blocks.Block = .{ .name = "play/letters", .pack = .made, .source = 0x10E42, .what = "the banner's and the texts' big letters, the game's big font masked to one colour (0x10E42): the letters of the list at 0x10F5C, four tiles each by the table at 0x6EE52" };
const number_block: blocks.Block = .{ .name = "play/round_number", .pack = .made, .source = 0x10E62, .what = "the round's number on the banner: its two tiles of the status bar's art, kept to colours 1, 12 and 13 (0x10E42)" };
const bars_block: blocks.Block = .{ .name = "play/bar_tiles", .pack = .made, .source = 0x11156, .what = "the bars' tiles the game builds from rows (0x11156, 0x11090): three rows of colour 2, five of a colour, then colour 2" };
const fills_block: blocks.Block = .{ .name = "play/fills", .pack = .made, .source = 0x11072, .what = "the bars' partial cells (0x11072): a player's, a row of colour 2, five rows of its fill by the eighths of the cell (0x4F2C), two of colour 2; an enemy's, three rows of colour 2 and five of its fill (0x11930)" };

/// The pattern loads of play's set-up, in order (0x110AC, 0x11564): round 1's props (round +
/// 12), the font, the status bar, the marks, the effects, the food, the shutter, the weapons.
const pattern_loads = [_]u8{ 12, 3, 4, 33, 52, 54, 56, 5 };

/// The letters 0x10F30 copies (an index of 0x6EE52 each), and the table of their four tiles.
const letter_list = 0x10F5C;
const letter_tiles = 0x6EE52;
/// The tile of the status bar's health bars the set-up copies to $DB20 (0x11564).
const bar_tile = 0x1158C;
/// The fill rows of a player's partial cell (8, by the eighths) and of an enemy's.
const health_fills = 0x4F2C;
const enemy_fills = 0x11930;
/// A border row of the bars' tiles: colour 2.
const border: u32 = 0x22222222;

/// A bar's tile (0x11090, 0x11072): `top` border rows, five rows of `fill`, then border rows.
fn barTile(fill: u32, top: usize) [32]u8 {
    var t: [32]u8 = undefined;
    for (0..8) |r| std.mem.writeInt(u32, t[r * 4 ..][0..4], if (r < top or r >= top + 5) border else fill, .big);
    return t;
}

/// The tiles the game makes, as the extractor makes them.
fn madeTiles(b: *Builder) !void {
    const rom = b.rom;
    const arena = b.arena;
    // The big font masked to colour 1 (0x10EE6: each byte and $11), the letters' tiles in the
    // list's order: 11 letters, then 3 more (0x10ECC).
    const big = try b.lib.byName("fonts/big");
    var letters: std.ArrayList(u8) = .empty;
    for (0..14) |i| {
        const letter: u32 = rom[letter_list + i];
        for (0..4) |k| {
            const t: usize = rom[letter_tiles + letter * 4 + k];
            if (32 * (t + 1) > big.bytes.len) return error.BadData;
            for (big.bytes[32 * t ..][0..32]) |byte| try letters.append(arena, byte & 0x11);
        }
    }
    try b.lib.made(letters_block, letters.items);
    // The round's number: two tiles of the status bar's art from its tile 3 (round 1), kept to
    // colours 1, 12 and 13 (0x10F6A).
    const bar = try b.lib.byName("play/status_bar");
    const number = try arena.alloc(u8, 64);
    for (number, bar.bytes[96..][0..64]) |*o, byte| o.* = keep(byte >> 4) << 4 | keep(byte & 0xF);
    try b.lib.made(number_block, number);
    // The bars' tiles (0x11156): full and empty enemy cells, a colour-15 and a colour-1 cell.
    var bars: std.ArrayList(u8) = .empty;
    for ([_]u32{ 0x33333333, 0xEEEEEEEE, 0xFFFFFFFF, 0x11111111 }) |fill| try bars.appendSlice(arena, &barTile(fill, 3));
    try b.lib.made(bars_block, bars.items);
    // The partial cells: the players' (one border row first), then the enemies' (three).
    var fills: std.ArrayList(u8) = .empty;
    for (0..8) |k| try fills.appendSlice(arena, &barTile(u32be(rom, health_fills + 4 * @as(u32, @intCast(k))), 1));
    for (0..8) |k| try fills.appendSlice(arena, &barTile(u32be(rom, enemy_fills + 4 * @as(u32, @intCast(k))), 3));
    try b.lib.made(fills_block, fills.items);
}

fn keep(n: u8) u8 {
    return if (n == 1 or n == 0xC or n == 0xD) n else 0;
}

/// Play's video memory once round 1 is set up.
pub fn vram(b: *Builder) !*Vram {
    const rom = b.rom;
    const v = try b.arena.create(Vram);
    v.* = .{};
    v.clear();
    const h = rounds.header(rom, 0);
    for (0..2) |k| {
        const cmd = u32be(rom, @intCast(h + 8 * k));
        const src = u32be(rom, @intCast(h + 8 * k + 4));
        const d = try b.lib.decode(.{ .name = if (k == 0) "round1/art_1" else "round1/art_2", .pack = .kosinski, .source = src, .what = "" });
        try v.writeTiles(vram_mod.commandAddress(cmd), src, 0, d.bytes[0 .. d.bytes.len & ~@as(usize, 31)]);
    }
    for (pattern_loads) |i| {
        const e: u32 = screens.pattern_loads + (@as(u32, i) - 1) * 8;
        const d = try b.lib.get(u32be(rom, e + 4));
        try v.writeTiles(vram_mod.commandAddress(u32be(rom, e)), d.block.source, 0, d.bytes);
    }
    try madeTiles(b);
    const at = struct {
        fn tiles(vv: *Vram, lib: *blocks.Library, address: u32, source: u32, first: u16, n: usize) !void {
            const d = try lib.get(source);
            try vv.writeTiles(address, source, first, d.bytes[32 * @as(usize, first) ..][0 .. 32 * n]);
        }
    };
    try at.tiles(v, &b.lib, 0xDFC0, number_block.source, 0, 2);
    try at.tiles(v, &b.lib, 0xD240, letters_block.source, 0, 44);
    try at.tiles(v, &b.lib, 0xFE80, letters_block.source, 44, 12);
    try at.tiles(v, &b.lib, 0xDF40, bars_block.source, 0, 1);
    try at.tiles(v, &b.lib, 0xDF60, bars_block.source, 1, 1);
    try at.tiles(v, &b.lib, 0xD7C0, bars_block.source, 2, 1);
    try at.tiles(v, &b.lib, 0xFE40, bars_block.source, 3, 1);
    const end = try b.lib.byName("play/bar_end");
    try v.writeTiles(0xDB20, end.block.source, 0, end.bytes);
    // The partial cells as they stand empty: the players' at $DB40 and $DB60, the enemies' at
    // $DF80 and $DFA0.
    try at.tiles(v, &b.lib, 0xDB40, fills_block.source, 0, 1);
    try at.tiles(v, &b.lib, 0xDB60, fills_block.source, 0, 1);
    try at.tiles(v, &b.lib, 0xDF80, fills_block.source, 8, 1);
    try at.tiles(v, &b.lib, 0xDFA0, fills_block.source, 8, 1);
    return v;
}

// --- The fixed texts -----------------------------------------------------------------------------

/// The fixed sprite lists (0x10B2E inserts them): the banner's (its left part, the round's number,
/// its right part), the pause's, the time over's.
const banner_list = 0x1079A;
const banner_left = 5;
const pause_list = 0x109F6;
const pause_entries = 5;
const time_over_list = 0x10A6E;
const time_over_entries = 8;

/// The frame of `count` entries of the list at `list`, its origin at the screen's top-left: the
/// entries' places on the screen (less 128), their tiles from play's video memory, the first on
/// top. All its entries share a palette and a priority.
fn textFrame(b: *Builder, v: *const Vram, name: []const u8, list: u32, count: usize, why: []const u8) !void {
    const rom = b.rom;
    var x0: i32 = std.math.maxInt(i32);
    var y0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var y1: i32 = std.math.minInt(i32);
    for (0..count) |i| {
        const e = list + 8 * @as(u32, @intCast(i));
        const size = rom[e + 2];
        const x: i32 = @as(i32, @as(i16, @bitCast(u16be(rom, e + 6)))) - 128;
        const y: i32 = @as(i32, @as(i16, @bitCast(u16be(rom, e)))) - 128;
        x0 = @min(x0, x);
        y0 = @min(y0, y);
        x1 = @max(x1, x + 8 * (@as(i32, (size >> 2) & 3) + 1));
        y1 = @max(y1, y + 8 * (@as(i32, size & 3) + 1));
    }
    const width: usize = @intCast(x1 - x0);
    const height: usize = @intCast(y1 - y0);
    const px = try b.arena.alloc(u8, width * height);
    @memset(px, 0);
    const first_name = u16be(rom, list + 4);
    var k = count;
    while (k > 0) {
        k -= 1;
        const e = list + 8 * @as(u32, @intCast(k));
        const size = rom[e + 2];
        const nm = u16be(rom, e + 4);
        if (nm & 0xE000 != first_name & 0xE000) return error.BadData;
        const w: usize = ((size >> 2) & 3) + 1;
        const h: usize = (size & 3) + 1;
        const x: i32 = @as(i32, @as(i16, @bitCast(u16be(rom, e + 6)))) - 128;
        const y: i32 = @as(i32, @as(i16, @bitCast(u16be(rom, e)))) - 128;
        for (0..h * 8) |sy| for (0..w * 8) |sx| {
            const ux = if (nm & 0x800 != 0) w * 8 - 1 - sx else sx;
            const uy = if (nm & 0x1000 != 0) h * 8 - 1 - sy else sy;
            const slot = (nm + (ux / 8) * h + uy / 8) & 0x7FF;
            if (!v.written.isSet(slot)) return error.BadData;
            const byte = v.bytes[slot][(uy % 8) * 4 + (ux % 8) / 2];
            const c = if (ux % 2 == 0) byte >> 4 else byte & 0xF;
            if (c == 0) continue;
            const ox: usize = @intCast(x - x0 + @as(i32, @intCast(sx)));
            const oy: usize = @intCast(y - y0 + @as(i32, @intCast(sy)));
            px[oy * width + ox] = c;
        };
    }
    const own = Builder.split(name).own;
    try b.frame(name, .{
        .name = "",
        .provenance = try std.fmt.allocPrint(b.arena, "ROM 0x{X:0>5}: {d} entries of a fixed sprite list, {s}, drawn from play's video memory (the play set-up 0x110AC and the tiles it makes)", .{ list, count, why }),
        .file = try std.fmt.allocPrint(b.arena, "{s}.png", .{own}),
        .width = @intCast(width),
        .height = @intCast(height),
        .origin_x = @intCast(-x0),
        .origin_y = @intCast(-y0),
        .pixels = px,
        .palette = @intCast((first_name >> 13) & 3),
        .priority = first_name & 0x8000 != 0,
        .view = (try playColours(rom))[(first_name >> 13) & 3],
    });
}

/// The colours of play's palettes once round 1 is set up (its colours, then play's), for the
/// pictures' files.
fn playColours(rom: []const u8) ![art.palette_count][art.palette_size]art.Colour {
    var c: [art.palette_count][art.palette_size]art.Colour = @splat(@splat(art.Colour.black));
    const lists = [_]u32{ u32be(rom, rounds.header(rom, 0) + 28), 0x6F2F0, 0x115AC };
    for (lists) |l| (try builder_mod.paletteList(rom, l)).apply(&c);
    return c;
}

// --- The status bar --------------------------------------------------------------------------------

/// The rows of tiles the status bar's code writes (0x4D1E: a count less one, a base tile, a byte
/// per tile): the players' names (0x4CD0).
const name_rows = [2]u32{ 0x4D30, 0x4D38 };
/// The players' health bars' cells (0x4E6C: ten full, the partial one, ten empty), and the
/// enemies' (0x11876).
const health_cells = [2]u32{ 0x4ED8, 0x4F02 };
const enemy_cells = [2]u32{ 0x118DC, 0x11906 };
/// The game's font in video memory (pattern-load entry 3 at tile $7C0): a text's byte is its
/// tile.
const font_base = 0x7C0;

/// The text of a row of the game's font (its glyphs, fonts.zig).
fn rowText(arena: std.mem.Allocator, rom: []const u8, row: u32) ![]const u8 {
    const n = u16be(rom, row) + 1;
    const base = u16be(rom, row + 2);
    if (base != font_base) return error.BadData;
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |k| {
        const tile = rom[row + 4 + k];
        const g = for (fonts.main_glyphs) |g| {
            if (g.tile == tile) break g;
        } else return error.BadData;
        try out.appendSlice(arena, g.text);
    }
    return out.items;
}

fn romWords(arena: std.mem.Allocator, rom: []const u8, at: u32, n: usize) ![]u16 {
    const out = try arena.alloc(u16, n);
    for (out, 0..) |*w, k| w.* = u16be(rom, at + 2 * @as(u32, @intCast(k)));
    return out;
}

/// The cell of the status bar's image (window rows 1 on, 40 cells a row) of the byte offset
/// `at` of the original's image (its 8 bytes of header first).
fn cellAt(at: u16) records.Cell {
    const k = (at - 8) / 2;
    return .{ .x = @intCast(k % 40), .y = @intCast(1 + k / 40) };
}

/// The immediate operand after the opcode bytes `opcode` of the instruction at `at` (checked).
fn immediate(rom: []const u8, at: u32, opcode: []const u8, width: u8) !u32 {
    if (!std.mem.eql(u8, rom[at..][0..opcode.len], opcode)) return error.BadData;
    const v = at + @as(u32, @intCast(opcode.len));
    return switch (width) {
        1 => rom[v],
        2 => u16be(rom, v),
        else => error.BadData,
    };
}

/// A packed decimal byte as a number.
fn decimal(b: u32) !u8 {
    if (b > 0x99 or b & 0xF > 9) return error.BadData;
    return @intCast((b >> 4) * 10 + (b & 0xF));
}

/// Play's screen: its frames and maps into the builder, and its record.
pub fn extract(b: *Builder) !records.Round {
    const rom = b.rom;
    const arena = b.arena;
    const v = try vram(b);
    try textFrame(b, v, "play/banner_left", banner_list, banner_left, "the round's banner, its left part (0x10780)");
    try textFrame(b, v, "play/banner_number", banner_list + 8 * banner_left, 1, "the round's banner, the round's number (0x10780)");
    try textFrame(b, v, "play/banner_right", banner_list + 8 * (banner_left + 1), banner_left, "the round's banner, its right part (0x10780)");
    try textFrame(b, v, "play/pause", pause_list, pause_entries, "the pause's text (0x10948)");
    try textFrame(b, v, "play/time_over", time_over_list, time_over_entries, "the time over's text (0x10976)");

    const screen: screens.Screen = .{ .name = "play", .what = "", .steps = &.{} };
    var run: screens.Run = .{ .b = b, .v = v, .screen = &screen };
    var digits: [20]u16 = undefined;
    for (0..10) |d| {
        digits[d] = 0x6C0 + 2 * @as(u16, @intCast(d));
        digits[10 + d] = 0x6C1 + 2 * @as(u16, @intCast(d));
    }
    try run.mapAt("play/time_digits", &digits, 10, 2, null, "the big digits of the timer and the lives (0x10CCC, 0x4E14): digit d's tiles $6C0 + 2d over $6C1 + 2d, a column a digit", .code);
    for (health_cells, 0..) |at, k| {
        const name = try std.fmt.allocPrint(arena, "play/health_{d}", .{k + 1});
        const why = try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: player {d}'s health bar's cells (0x4E6C): ten full, the partial one (its fill the game builds), ten empty", .{ at, k + 1 });
        try run.mapAt(name, try romWords(arena, rom, at, 21), 21, 1, null, why, .{ .rom_words = at });
    }
    for (enemy_cells, 0..) |at, k| {
        const name = try std.fmt.allocPrint(arena, "play/enemy_bar_{d}", .{k + 1});
        const why = try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: the enemies' bar {d}'s cells (0x11876): ten full, the partial one (its fill the game builds), ten empty", .{ at, k + 1 });
        try run.mapAt(name, try romWords(arena, rom, at, 21), 21, 1, null, why, .{ .rom_words = at });
    }
    try run.mapAt("play/police_icon", &.{ 0x6DC, 0x6DD, 0x6DE, 0x6DF }, 2, 2, null, "the special attack's mark beside a player's name (0x4CD0: $06DC06DD over $06DE06DF)", .code);
    try run.finish();

    // The banner's steps (0x11A50): the fade of the first colours (moveq #N,d6: the colours less
    // one), the slide in (addq.w #4; until the last entry's place is below cmpi.w #N), the wait
    // (move.w #N), the slide out (addi.w #-N; until cmpi.w #N), the wait after.
    const fade = 1 + try immediate(rom, 0x11A68, &.{0x7C}, 1);
    if (u16be(rom, 0x11A7C) != 0x5869) return error.BadData;
    const in = 4;
    const stop = try immediate(rom, 0x11AA0, &.{ 0x0C, 0x69 }, 2);
    const wait = try immediate(rom, 0x11AAC, &.{ 0x31, 0xFC }, 2);
    const out: u32 = 0x10000 - try immediate(rom, 0x11ACA, &.{ 0x06, 0x69 }, 2);
    const gone = try immediate(rom, 0x11AF0, &.{ 0x0C, 0x69 }, 2);
    const after = try immediate(rom, 0x11AFC, &.{ 0x31, 0xFC }, 2);
    const last: u32 = u16be(rom, banner_list + 8 * 10 + 6);
    var in_ticks: u32 = 0;
    var x = last;
    while (x >= stop) : (in_ticks += 1) x -= in;
    var out_ticks: u32 = 0;
    while (x < gone) : (out_ticks += 1) x += out;

    // The status bar's cells, as the code's offsets in its image place them; player 2's 26 cells
    // on, its lives and special attacks swapped.
    var players: [2]records.BarPlayer = undefined;
    for (&players, 0..) |*p, k| {
        const second: u16 = @intCast(52 * k);
        const name_at: u16 = 0x0A + second;
        const name_end: u16 = name_at + 8;
        p.* = .{
            .name = try rowText(arena, rom, name_rows[k]),
            .name_at = cellAt(name_at),
            .score = cellAt(name_end),
            .health = cellAt(0x5A + second),
            .lives = cellAt(0x20 + second),
            .lives_mark = cellAt(name_end + (if (k == 0) @as(u16, 92) else 92)),
            .icon = cellAt(if (k == 0) name_at + 26 else name_at - 10),
            .specials = cellAt(if (k == 0) 0x20 + 10 else 0x20 + second - 26),
            .specials_mark = cellAt(name_end + (if (k == 0) @as(u16, 102) else 66)),
        };
    }
    return .{
        .banner = .{
            .provenance = try std.fmt.allocPrint(arena, "the round's banner (0x10780, its steps 0x11A50): the status bar's first {d} colours fade in (ROM 0x11A69); its parts slide in by {d} pixels a tick (ROM 0x11A7C) until its last entry's place (ROM 0x{X:0>5}) is below ${X} (ROM 0x11AA2), {d} ticks; it stays ROM 0x11AAE's ticks (the round's music at their start); it slides out by ROM 0x11ACC's until ${X} (ROM 0x11AF2), {d} ticks; then ROM 0x11AFE's ticks", .{ fade, in, banner_list + 86, stop, in_ticks, gone, out_ticks }),
            .left = "play/banner_left",
            .number = "play/banner_number",
            .right = "play/banner_right",
            .fade = @intCast(fade),
            .in = in,
            .in_ticks = @intCast(in_ticks),
            .wait = @intCast(wait),
            .out = @intCast(out),
            .out_ticks = @intCast(out_ticks),
            .after = @intCast(after),
        },
        .pause = .{ .provenance = "the pause's text, a fixed sprite list (0x10948, ROM 0x109F6)", .frame = "play/pause" },
        .time_over = .{
            .provenance = "the time over (0x10976): its text, a fixed sprite list (ROM 0x10A6E), drawn at its first tick, then ROM 0x10CC2's ticks (move.b #N,($FA4A) at the timer's end, 0x10C88); then each player in play's health less ROM 0x109E3's (moveq #-N,d7; 0x4E6C) and the timer at ROM 0x1099C's seconds (move.w #N,($FB00))",
            .frame = "play/time_over",
            .ticks = @intCast(1 + try immediate(rom, 0x10CC0, &.{ 0x11, 0xFC }, 2)),
            .health = @intCast(0x100 - try immediate(rom, 0x109E2, &.{0x7E}, 1)),
            .seconds = try decimal(try immediate(rom, 0x1099A, &.{ 0x31, 0xFC }, 2)),
        },
        .status_bar = .{
            .provenance = "the status bar's image (0x110AC: window rows 1 to 3, 40 cells a row): the players' names (0x4CD0, the rows at 0x4D30 and 0x4D38) and their special attack's mark, their scores (0x4D60), their lives and special attacks (0x4E14) and the marks before them (0x4CD0), their health bars (0x4E6C), player 2's 26 cells on but its lives and special attacks swapped; the timer (0x10C88)",
            .players = players,
            .time = cellAt(0x2E),
        },
    };
}

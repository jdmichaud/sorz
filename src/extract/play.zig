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
const number_block: blocks.Block = .{ .name = "play/round_number", .pack = .made, .source = 0x10E62, .what = "the rounds' numbers on the banner: each round's two tiles of the status bar's art (from its tile 3, two a round), kept to colours 1, 12 and 13 (0x10E42)" };

/// The rounds (their numbers on the banner).
const round_count = 8;
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
    // The rounds' numbers: two tiles of the status bar's art a round from its tile 3 (0x10E42:
    // $FF8060 plus the round from 0 times 64), kept to colours 1, 12 and 13 (0x10F6A).
    const bar = try b.lib.byName("play/status_bar");
    if (bar.bytes.len < 96 + 64 * round_count) return error.BadData;
    const number = try arena.alloc(u8, 64 * round_count);
    for (number, bar.bytes[96..][0 .. 64 * round_count]) |*o, byte| o.* = keep(byte >> 4) << 4 | keep(byte & 0xF);
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
const game_over_list = 0x10BB8;
const game_over_entries = 8;

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

/// Player 2's invitation to join (0x11682): three rows of the font (lea at ROM 0x1168A), each
/// ending at its byte $FF, written from the image's offset of ROM 0x1169C's (lea $FF60xx), a cell
/// left between them; a counter set to ROM 0x1163C's (move.b #N,($FA21)) times its blinks.
const join_rows = 0x1168A;
const join_place = 0x1169A;
const join_blink = 0x11638;
/// Where the game keeps the status bar's image in its memory ($FF6000, header first): a place in
/// it is an offset of the image.
const image_ram = 0x6000;

/// The text of `count` rows of the font from `at` (0x11708: each a count less one, the font's
/// base tile, a byte per tile, a byte $FF ending it early), a cell between them: their words one
/// space apart.
fn rowsText(arena: std.mem.Allocator, rom: []const u8, at: u32, count: usize) ![]const u8 {
    var row = at;
    var out: std.ArrayList(u8) = .empty;
    for (0..count) |r| {
        if (r > 0) try out.append(arena, ' ');
        const n = u16be(rom, row) + 1;
        if (u16be(rom, row + 2) != font_base) return error.BadData;
        for (0..n) |k| {
            const tile = rom[row + 4 + k];
            if (tile == 0xFF) break;
            const g = for (fonts.main_glyphs) |g| {
                if (g.tile == tile) break g;
            } else return error.BadData;
            try out.appendSlice(arena, g.text);
        }
        row += 4 + n;
    }
    return out.items;
}

/// The target of `lea (d16,pc),a3` at `at`.
fn leaPc(rom: []const u8, at: u32) !u32 {
    if (u16be(rom, at) != 0x47FA) return error.BadData;
    const d: i16 = @bitCast(u16be(rom, at + 2));
    return @intCast(@as(i64, at + 2) + d);
}

/// The status bar's cell of `lea $FF60xx,aN` at `at` (`opcode` its first word): an offset of the
/// bar's image in the game's memory.
fn leaCell(rom: []const u8, at: u32, opcode: u16) !records.Cell {
    if (u16be(rom, at) != opcode or u16be(rom, at + 2) != 0xFF or u16be(rom, at + 4) -% image_ram >= 0x100) return error.BadData;
    return cellAt(u16be(rom, at + 4) - image_ram);
}

/// The join's text, its rows one space apart.
fn joinText(arena: std.mem.Allocator, rom: []const u8) ![]const u8 {
    return rowsText(arena, rom, try leaPc(rom, join_rows), 3);
}

// --- The round's clear ---------------------------------------------------------------------------

/// The round's end (0x181EA, its steps 0x1833C): "round N clear" (0x183F0: the 13 letters at
/// 0x18468 of the big font's table at 0x6EE4E, two cells by two each, palette 1 with priority, a
/// word rectangle for plane A at $C38E; the round's number, a big digit, over the seventh
/// letter's right half), the bonuses' lines (0x18564, 28 bytes each: a write command, 23 letters
/// of the font from $7C0, $FF), their palettes (0x18532 and 0x1852C: move.w #N,d7), the waits
/// (0x18476: move.b #N,($FB4E)), the bonuses (0x18296).
const clear_letters = 0x18468;
const big_font = 0x6EE4E;
const clear_lines = [3]u32{ 0x18564, 0x18580, 0x1859C };

/// The plane A cell of video memory address `address` (a 64 cells wide plane at $C000).
fn planeCell(address: u32) !records.Cell {
    if (address < 0xC000 or address >= 0xE000) return error.BadData;
    const k = (address - 0xC000) / 2;
    return .{ .x = @intCast(k % 64), .y = @intCast(k / 64) };
}

fn roundClear(b: *Builder, play_v: *const Vram) !records.Clear {
    const rom = b.rom;
    const arena = b.arena;
    // The round's end's video memory: play's, the big letters (pattern-load entry $20) over it.
    const v = try arena.create(Vram);
    v.* = play_v.*;
    const e: u32 = screens.pattern_loads + (0x20 - 1) * 8;
    const d = try b.lib.get(u32be(rom, e + 4));
    try v.writeTiles(vram_mod.commandAddress(u32be(rom, e)), d.block.source, 0, d.bytes);
    // The header: 13 letters, 26 cells by 2; a letter 0 is four empty cells.
    var words: [52]u16 = @splat(0);
    for (0..13) |i| {
        const letter: u32 = rom[clear_letters + i];
        if (letter == 0) continue;
        const f = big_font + letter * 4;
        words[2 * i] = 0x2100 | @as(u16, rom[f]);
        words[2 * i + 1] = 0x2100 | @as(u16, rom[f + 2]);
        words[26 + 2 * i] = 0x2100 | @as(u16, rom[f + 1]);
        words[26 + 2 * i + 1] = 0x2100 | @as(u16, rom[f + 3]);
    }
    // The header's place (move.l #N,(a4)+ at 0x18400: a write to $C38E).
    if (u16be(rom, 0x18400) != 0x28FC) return error.BadData;
    const header_at = try planeCell(vram_mod.commandAddress(u32be(rom, 0x18402)));
    const screen: screens.Screen = .{ .name = "round_end", .what = "", .steps = &.{} };
    var run: screens.Run = .{ .b = b, .v = v, .screen = &screen };
    try run.mapAt("round_end/header", &words, 26, 2, null, "ROUND n CLEAR (0x183F0): the letters at ROM 0x18468, each two cells by two from the big font's table at ROM 0x6EE4E; the round's number goes over the seventh letter's right half", .code);
    try run.finish();
    var lines: [3]records.ClearLine = undefined;
    for (&lines, clear_lines) |*l, at| {
        var text: std.ArrayList(u8) = .empty;
        var k: u32 = at + 4;
        while (rom[k] != 0xFF) : (k += 1) {
            const g = for (fonts.main_glyphs) |g| {
                if (g.tile == rom[k]) break g;
            } else return error.BadData;
            try text.appendSlice(arena, g.text);
        }
        l.* = .{ .text = text.items, .at = try planeCell(vram_mod.commandAddress(u32be(rom, at))) };
    }
    if (u16be(rom, 0x18532) != 0x3E3C or u16be(rom, 0x1852C) != 0x3E3C) return error.BadData;
    return .{
        .provenance = "the round's end (0x181EA, its steps 0x1833C): the header (0x183F0: ROM 0x18468's letters, the round's number over the seventh's right half), the bonuses' lines (ROM 0x18564, 0x18580, 0x1859C: a write command and 23 letters; a bonus's six digits from the 14th, 0x1850C), their palettes (ROM 0x18534, 0x1852E: move.w #N,d7), the waits (ROM 0x18478: move.b #N,($FB4E)); the bonuses (0x18296): the clear's 10000 and 10000 a special attack left, the time's 100 a second left, the level's 10000 a LEVEL, counted 100 points a tick (0x187D0)",
        .header = "round_end/header",
        .header_at = header_at,
        .number = .{ .x = 13, .y = 0 },
        .lines = lines,
        .digits = 13,
        .normal = @intCast(u16be(rom, 0x18534) >> 13),
        .counted = @intCast(u16be(rom, 0x1852E) >> 13),
        .wait = @intCast(try immediate(rom, 0x18476, &.{ 0x11, 0xFC }, 2)),
        .clear_bonus = 10000,
        .time_bonus = 100,
        .level_bonus = 10000,
        .count = 100,
        .colours = "round_end/colours",
    };
}

/// The continue's question (0x5432): player 1's and player 2's places, from the instructions that
/// write them (0x54B0, 0x5590: the question and its answers; 0x5456, 0x5526: the game over's
/// text; 0x5620, 0x563E: the cells cleared, 0x103FE clearing a row's 18), and the answers' places
/// (the longs at 0x5324); the texts' rows (0x54E8: with NEW GAME; 0x550A: with GAME OVER).
fn continueQuestion(arena: std.mem.Allocator, rom: []const u8) !records.Continue {
    const lea_a2 = 0x45F9;
    const lea_a1 = 0x43F9;
    var cleared: u8 = 0;
    var at: u32 = 0x103FE;
    while (u16be(rom, at) == 0x22C1) : (at += 2) cleared += 2;
    if (u16be(rom, at) != 0x4E75) return error.BadData;
    // The count's digit: the font's digits from tile $7DB (addi.w #$7DB,d0), at the question's
    // place plus $12 (move.w d0,($12,a2)).
    if (u16be(rom, 0x54C6) != 0x0640 or u16be(rom, 0x54C8) != font_base + 27 or u32be(rom, 0x54CA) != 0x35400012) return error.BadData;
    const with_new_game = try leaPc(rom, 0x54AC);
    const with_game_over = try leaPc(rom, 0x559A);
    const new_game = try rowsText(arena, rom, with_new_game, 3);
    const game_over = try rowsText(arena, rom, with_game_over, 3);
    const question = "CONTINUE";
    if (!std.mem.startsWith(u8, new_game, question ++ " ") or !std.mem.startsWith(u8, game_over, question ++ " ")) return error.BadData;
    var places: [2]records.ContinuePlaces = undefined;
    for (&places, 0..) |*p, k| {
        const answers: u32 = 0x5324 + 8 * @as(u32, @intCast(k));
        const yes = u32be(rom, answers);
        const no = u32be(rom, answers + 4);
        if (yes >> 8 != 0xFF60 or no >> 8 != 0xFF60) return error.BadData;
        p.* = .{
            .cleared = .{ try leaCell(rom, if (k == 0) 0x5626 else 0x5644, lea_a1), try leaCell(rom, if (k == 0) 0x5632 else 0x5650, lea_a1) },
            .question = try leaCell(rom, if (k == 0) 0x54C0 else 0x559E, lea_a2),
            .answer = try leaCell(rom, if (k == 0) 0x54D4 else 0x55B2, lea_a2),
            .yes = cellAt(@intCast(yes & 0xFF)),
            .no = cellAt(@intCast(no & 0xFF)),
            .out = try leaCell(rom, if (k == 0) 0x5498 else 0x5570, lea_a2),
        };
    }
    // The game over's text in the bar: the rows at 0x11754 (lea at 0x5482).
    if (u16be(rom, 0x5482) != 0x47F9 or u32be(rom, 0x5484) != 0x11754) return error.BadData;
    const out_text = try rowsText(arena, rom, 0x11754, 2);
    if (!std.mem.eql(u8, out_text, game_over[question.len + 1 ..])) return error.BadData;
    // The cursor: tile $7E7 (move.w #$7E7,d0 at 0x52E2), a glyph of the font.
    if (u16be(rom, 0x52E2) != 0x303C) return error.BadData;
    const cursor_tile = u16be(rom, 0x52E4) - font_base;
    const cursor = for (fonts.main_glyphs) |g| {
        if (g.tile == cursor_tile) break g.text;
    } else return error.BadData;
    return .{
        .provenance = "the waiting player's status bar (0x5432): the question and its answers' rows (ROM 0x054E8 with NEW GAME, 0x0550A with GAME OVER; lea at 0x054AC, 0x0559A), the continues left a digit (0x054C6: addi.w #$7DB,d0; move.w d0,($12,a2)), the places (lea $FF60xx at 0x054C0, 0x054D4, 0x0559E, 0x055B2; the answers' at 0x05324), the cursor's tile (0x052E2), the game over's rows (0x11754, at 0x05498 and 0x05570), the cells cleared (0x05620, 0x0563E, 0x103FE); the game over's text over the picture, a fixed sprite list (0x10B70, ROM 0x10BB8)",
        .question = question,
        .count = 9,
        .new_game = new_game[question.len + 1 ..],
        .game_over = game_over[question.len + 1 ..],
        .cursor = cursor,
        .cleared = cleared,
        .players = places,
        .frame = "play/game_over",
    };
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

/// The status bar's image the game writes at every frame of play (0x110AC: its header, move.l
/// #$50800003, then move.w #N,($FF6004) its cells less one and move.w #N,($FF6006) its rows
/// less one): its rows and cells.
fn barImage(rom: []const u8) ![2]u8 {
    const at = 0x11136;
    if (u16be(rom, at) != 0x23FC or u16be(rom, at + 6) != 0xFF or u16be(rom, at + 8) != image_ram) return error.BadData;
    if (u16be(rom, at + 10) != 0x33FC or u16be(rom, at + 18) != 0x33FC) return error.BadData;
    if (u16be(rom, at + 16) != image_ram + 4 or u16be(rom, at + 24) != image_ram + 6) return error.BadData;
    const cells = u16be(rom, at + 12) + 1;
    const rows = u16be(rom, at + 20) + 1;
    if (cells > 40 or rows > 4) return error.BadData;
    return .{ @intCast(rows), @intCast(cells) };
}

/// The most a score holds: what 0x10DA6 writes over a score its sum overflows (move.l
/// #$00999900,(-1,a6) at 0x10DC0), its packed decimal digits.
fn scoreMost(rom: []const u8) !u32 {
    const at = 0x10DC0;
    if (u16be(rom, at) != 0x2D7C or u16be(rom, at + 6) != 0xFFFF) return error.BadData;
    var v: u32 = 0;
    for (rom[at + 2 ..][0..4]) |b| {
        if (b >> 4 > 9 or b & 0xF > 9) return error.BadData;
        v = v * 100 + (b >> 4) * 10 + (b & 0xF);
    }
    return v;
}

/// Play's screen: its frames and maps into the builder, and its record.
pub fn extract(b: *Builder) !records.Round {
    const rom = b.rom;
    const arena = b.arena;
    const v = try vram(b);
    try textFrame(b, v, "play/banner_left", banner_list, banner_left, "the round's banner, its left part (0x10780)");
    // Each round's number, its tiles at $DFC0 as its set-up leaves them (round 1's last, as the
    // rest of play's video memory is).
    const numbers = try arena.alloc([]const u8, round_count);
    const number_tiles = try b.lib.get(number_block.source);
    var n: usize = round_count;
    while (n > 0) : (n -= 1) {
        try v.writeTiles(0xDFC0, number_block.source, @intCast(2 * (n - 1)), number_tiles.bytes[64 * (n - 1) ..][0..64]);
        numbers[n - 1] = try std.fmt.allocPrint(arena, "play/banner_number_{d}", .{n});
        const why = try std.fmt.allocPrint(arena, "the round's banner, round {d}'s number (0x10780; its tiles 0x10E42)", .{n});
        try textFrame(b, v, numbers[n - 1], banner_list + 8 * banner_left, 1, why);
    }
    try textFrame(b, v, "play/banner_right", banner_list + 8 * (banner_left + 1), banner_left, "the round's banner, its right part (0x10780)");
    try textFrame(b, v, "play/pause", pause_list, pause_entries, "the pause's text (0x10948)");
    try textFrame(b, v, "play/time_over", time_over_list, time_over_entries, "the time over's text (0x10976)");
    try textFrame(b, v, "play/game_over", game_over_list, game_over_entries, "the game over's text (0x10B70)");

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
    const clear = try roundClear(b, v);

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
    const image = try barImage(rom);
    return .{
        .banner = .{
            .provenance = try std.fmt.allocPrint(arena, "the round's banner (0x10780, its steps 0x11A50): the status bar's first {d} colours fade in (ROM 0x11A69); its parts slide in by {d} pixels a tick (ROM 0x11A7C) until its last entry's place (ROM 0x{X:0>5}) is below ${X} (ROM 0x11AA2), {d} ticks; it stays ROM 0x11AAE's ticks (the round's music at their start); it slides out by ROM 0x11ACC's until ${X} (ROM 0x11AF2), {d} ticks; then ROM 0x11AFE's ticks", .{ fade, in, banner_list + 86, stop, in_ticks, gone, out_ticks }),
            .left = "play/banner_left",
            .numbers = numbers,
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
            .provenance = "the status bar's image (0x110AC: window rows 1 to 3, 40 cells a row): the players' names (0x4CD0, the rows at 0x4D30 and 0x4D38) and their special attack's mark, their scores (0x4D60), their lives and special attacks (0x4E14) and the marks before them (0x4CD0), their health bars (0x4E6C), player 2's 26 cells on but its lives and special attacks swapped; the timer (0x10C88); player 2's invitation to join (0x11682: its rows at ROM 0x1168A's, its place ROM 0x1169C's, its blinks ROM 0x1163C's); its image written at every frame of play, its rows and cells (ROM 0x11142's and 0x1114A's, 0x110AC); the most a score holds, where a score's overflow holds it (0x10DA6: move.l #N,(-1,a6) at ROM 0x10DC0, packed decimal)",
            .players = players,
            .time = cellAt(0x2E),
            .join = .{
                .text = try joinText(arena, rom),
                .at = at: {
                    if (u16be(rom, join_place) != 0x45F9 or u16be(rom, join_place + 2) != 0xFF or u16be(rom, join_place + 4) -% image_ram >= 0x100)
                        return error.BadData;
                    break :at cellAt(u16be(rom, join_place + 4) - image_ram);
                },
                .blink = @intCast(try immediate(rom, join_blink, &.{ 0x11, 0xFC }, 2)),
            },
            .score_most = try scoreMost(rom),
            .image_rows = image[0],
            .image_cells = image[1],
        },
        .continue_question = try continueQuestion(arena, rom),
        .clear = clear,
    };
}

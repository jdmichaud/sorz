//! The rounds' backgrounds (graphics port map 2.6, 3.4): each round's two art blocks, its two
//! planes' maps in cells (the map the loader builds from the layout's bands of chunks of 16 x 16
//! blocks, each block 2 x 2 cells), its palette, and round 3's waves. The camera, the bands'
//! parallax and the floor are the round's behaviour, extracted with the rounds' scripts.
const std = @import("std");
const sorz = @import("sorz");
const art = sorz.content.art;
const rom_mod = @import("rom.zig");
const blocks = @import("blocks.zig");
const enigma = @import("enigma.zig");
const kosinski = @import("kosinski.zig");
const vram_mod = @import("vram.zig");
const screens = @import("screens.zig");
const builder_mod = @import("builder.zig");
const Builder = builder_mod.Builder;

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const s16be = rom_mod.s16be;

pub const count = 8;
/// `RoundHeaderTable`: 8 word offsets, then the headers (two art blocks, the planes' block
/// tables, the floor, the palette list, the planes' sizes and cameras).
pub const header_table = 0x5F5B8;
/// `RoundLayoutTable`: per round, a word offset for plane A's layout record, then plane B's.
pub const layout_table = 0x5F788;
/// Round 3's waves: an Enigma map of 4 frames of 6 rows of 32 cells (0x112C0), the frame of each
/// of its 5 steps, and a palette list of 4 words per step.
pub const wave_maps = 0x65976;
pub const wave_steps = 0x11398;
pub const wave_palettes = 0x1139E;
pub const palette_cycles = 0x1C400;

pub fn header(rom: []const u8, n: u32) u32 {
    return header_table + @as(u32, u16be(rom, header_table + 2 * n));
}

const map_bytes = 0x2000;

/// The block numbers of a plane's map (as 0x199C6 builds it at $FF0000 or $FF2000), with its
/// width and rows in blocks.
const BlockMap = struct { bytes: []u8, stride: u32, width: u32, rows: u32 };

fn buildMap(arena: std.mem.Allocator, rom: []const u8, n: u32, p: u32, width: u32, vertical: bool) !BlockMap {
    var a: u32 = layout_table + @as(u32, u16be(rom, layout_table + 4 * n + 2 * p));
    const chunks = (try kosinski.decompress(arena, rom, u32be(rom, a))).bytes;
    // Bytes per map row: $150, round 8 $140, round 7's vertical layout 80.
    const stride: u32 = if (vertical) 80 else if (n == 7) 0x140 else 0x150;
    const map = try arena.alloc(u8, map_bytes);
    @memset(map, 0);
    a += 6;
    var row_base: u32 = 0;
    var rows: u32 = 0;
    while (true) {
        const d7 = s16be(rom, a);
        if (d7 < 0) break;
        const band_rows: u32 = @intCast(d7 + 1);
        const start = u16be(rom, a + 6);
        a += 8;
        if (vertical) {
            // 0x19A70: 6 rows of 5 chunks, 80 blocks a row.
            for (0..6) |cy| for (0..5) |cx| {
                const c = u16be(rom, a);
                a += 2;
                for (0..16) |row| try copyChunkRow(map, (cy * 16 + row) * 80 + cx * 16, chunks, c, row);
            };
            rows = 96;
            break;
        }
        var col: u32 = 0;
        while (true) {
            const c = s16be(rom, a);
            a += 2;
            if (c < 0) break;
            for (0..band_rows) |row| try copyChunkRow(map, row_base + @as(u32, @intCast(row)) * stride + col, chunks, @intCast(c), row);
            col += 16;
        }
        const next = u16be(rom, a);
        a += 2;
        row_base += next;
        rows = @max(rows, start + band_rows);
    }
    return .{ .bytes = map, .stride = stride, .width = @min(width, stride), .rows = @min(rows, map_bytes / stride) };
}

fn copyChunkRow(map: []u8, o: usize, chunks: []const u8, c: u16, row: usize) !void {
    if (o + 16 > map.len) return error.BadData;
    const from = @as(usize, c) * 256 + row * 16;
    if (from + 16 > chunks.len) return error.BadData;
    @memcpy(map[o..][0..16], chunks[from..][0..16]);
}

fn roundName(arena: std.mem.Allocator, n: u32, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, "round{d}/" ++ fmt, .{n + 1} ++ args);
}

/// Extracts round `n` (0 to 7) into the builder.
pub fn extract(b: *Builder, n: u32) !void {
    const arena = b.arena;
    const rom = b.rom;
    const h = header(rom, n);
    const set = try std.fmt.allocPrint(arena, "round{d}", .{n + 1});
    try b.describe(set, try std.fmt.allocPrint(arena, "round {d}'s background: its art, its planes' maps and its colours (the round header at ROM 0x{X:0>5}, loaded by 0x19848)", .{ n + 1, h }));
    try b.use(set, "play");

    // The video memory of play: the round's two art blocks at their addresses.
    const v = try arena.create(vram_mod.Vram);
    v.* = .{};
    v.clear();
    for (0..2) |k| {
        const cmd = u32be(rom, @intCast(h + 8 * k));
        const src = u32be(rom, @intCast(h + 8 * k + 4));
        const blk: blocks.Block = .{
            .name = try roundName(arena, n, "art_{d}", .{k + 1}),
            .pack = .kosinski,
            .source = src,
            .what = try std.fmt.allocPrint(arena, "round {d}'s art, block {d} (the round header +{d})", .{ n + 1, k + 1, 8 * k }),
        };
        const d = try b.lib.decode(blk);
        try v.writeTiles(vram_mod.commandAddress(cmd), src, 0, d.bytes[0 .. d.bytes.len & ~@as(usize, 31)]);
    }
    var run: screens.Run = .{ .b = b, .v = v, .screen = &.{ .name = set, .what = "", .steps = &.{} } };
    const list = u32be(rom, h + 28);
    try run.step(.{ .palette = .{ .list = list, .name = try roundName(arena, n, "colours", .{}), .why = "the round's colours (the round header +28)" } });

    for (0..2) |p| {
        const ph: u32 = @intCast(h + 32 + 12 * p);
        const width = u16be(rom, ph);
        const limits = u16be(rom, ph + 4);
        const blocks_source = u32be(rom, @intCast(h + 16 + 4 * p));
        const table = (try enigma.decompress(arena, rom, blocks_source, 0)).words;
        const m = try buildMap(arena, rom, n, @intCast(p), width, limits == 2);
        // Each block of the map as its 2 x 2 cells (the block table holds 256 blocks of the
        // top-left, top-right, bottom-left and bottom-right cells; past its words, zeros).
        const cols = m.width * 2;
        const rows = m.rows * 2;
        const words = try arena.alloc(u16, cols * rows);
        for (0..m.rows) |r| for (0..m.width) |c| {
            const blk: usize = m.bytes[r * m.stride + c];
            for (0..4) |q| {
                const w: u16 = if (blk * 4 + q < table.len) table[blk * 4 + q] else 0;
                words[(r * 2 + q / 2) * cols + c * 2 + q % 2] = w;
            }
        };
        const name = try roundName(arena, n, "plane_{c}", .{@as(u8, if (p == 0) 'a' else 'b')});
        const why = try std.fmt.allocPrint(arena, "plane {c}'s whole map: the layout record at ROM 0x{X:0>5} (its bands of Kosinski chunks, built by 0x199C6), each block from the Enigma block table at ROM 0x{X:0>5}", .{
            @as(u8, if (p == 0) 'A' else 'B'), layout_table + @as(u32, u16be(rom, layout_table + 4 * n + 2 * @as(u32, @intCast(p)))), blocks_source,
        });
        try run.mapAt(name, words, @intCast(cols), @intCast(rows), null, why, .{ .round_plane = .{ .round = @intCast(n), .plane = @intCast(p) } });
    }

    // The palette cycles (`PaletteCycleTable` 0x1C400, set up by 0x1119E and run every tick by
    // 0x11210): per round, word offsets to cycles until a negative word; a cycle is its period
    // in ticks, its count of steps and of colours a step, then one palette list of every step's
    // colours.
    const t = palette_cycles + @as(u32, u16be(rom, palette_cycles + 2 * n));
    var i: u32 = 0;
    while (s16be(rom, t + 2 * i) >= 0) : (i += 1) {
        const c = t + @as(u32, u16be(rom, t + 2 * i));
        const period = u16be(rom, c);
        const steps = u16be(rom, c + 2);
        const per_step = u16be(rom, c + 4);
        const out = try arena.alloc([art.palette_count][art.palette_size]?art.Colour, steps);
        var at = c + 6;
        for (out, 0..) |*s, k| {
            s.* = @splat(@splat(null));
            for (0..per_step) |_| {
                const w = u16be(rom, at);
                at += 2;
                const place: usize = (w & 0x10) | ((w >> 12) & 0xF) | ((w & 0x100) >> 3);
                s[place / 16][place % 16] = builder_mod.colourOf(w);
                // The list's last word ends it.
                if (w & 1 != 0 and !(k + 1 == steps)) return error.BadData;
            }
        }
        if (u16be(rom, at - 2) & 1 == 0) return error.BadData;
        const name = try roundName(arena, n, "cycle_{d}", .{i + 1});
        const note: []const u8 = if (n == 7) "; round 8 waits at some steps for the camera to pass a place (0x112B8)" else "";
        try b.cycle(name, .{
            .name = "",
            .provenance = try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: a palette cycle of round {d} (0x1C400): {d} steps of {d} colours, a step every {d} ticks{s}", .{ c, n + 1, steps, per_step, period, note }),
            .period = period,
            .steps = out,
        });
        try b.origin(name, .{ .cycle = c });
    }

    if (n == 2) {
        // Round 3's waves (0x112C0, 0x11346): four frames of 6 x 32 cells the VBlank writes on
        // plane B's rows 23 to 28, at columns 0 and 32, and a palette list a step.
        const w = (try enigma.decompress(arena, rom, wave_maps, 0)).words;
        if (w.len < 4 * 6 * 32) return error.BadData;
        for (0..4) |f| {
            const why = try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: an Enigma map, round 3's waves, frame {d} of 4 (written by 0x11346 on plane B's rows 23 to 28)", .{ wave_maps, f + 1 });
            try run.map(try roundName(arena, n, "waves_{d}", .{f + 1}), w[f * 192 ..][0..192], 32, 6, 0xE000 + 23 * 128, 128, why, .{ .waves = @intCast(f) });
        }
        for (0..5) |s| {
            const at: u32 = @intCast(wave_palettes + 8 * s);
            var pal = try builder_mod.paletteList(rom, at);
            pal.provenance = try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: a palette list, round 3's waves at step {d} of 5 (0x11346), which shows frame {d}", .{ at, s + 1, rom[wave_steps + s] + 1 });
            const pname = try roundName(arena, n, "waves_{d}", .{s + 1});
            try b.palette(pname, pal);
            try b.origin(pname, .{ .palette = at });
        }
    }
    try run.finish();
}

//! The picture's transfers and the sound (DESIGN.md A4, P4): in the original, as each frame
//! starts the game copies the parts of the picture that its last tick made (the sprites' list,
//! the colours when it touched them, a screen's own table of scroll or tiles) and reads the pads,
//! each time with the sound's processor stopped, so that the samples it plays (the drums, the
//! voices) come that much later. A deliberate model of that time, measured by sor-remaster on the
//! original: a transfer of n words stops the sound's processor for 64 + 456n / 205 of its cycles
//! (228n / 205 for the colours), the pads' reading for 235.
//!
//! A tick says what its frame transfers (`Frame`); the game gives the sound the time at the next
//! frame's start, when the original transfers it (game.zig). A load's frames transfer nothing:
//! the original's loads hold the frame's work and the sound's driver.
//!
//! The frame's other work comes before the sound's driver too, and puts its looks at the sample
//! player later in the frame (`work`, in the sound processor's cycles: sor-remaster's fit of the
//! original's timing, audio/clock.zig): the frame's start, its drawing (play's way or a screen's),
//! each transfer's set-up, the status bar's rows of play, the planes' strips as the camera moves,
//! the health bars' partial cells, the screens' first line's scroll; and in play, the art the
//! round streams in, which every frame decodes a little of (`streamWork`), the middle of a
//! logic tick's too.
const std = @import("std");
const Streamed = @import("../content/round.zig").Streamed;

/// What a tick's picture transfers as the next frame starts.
pub const Frame = struct {
    /// The colours, when the tick touched them (set, faded, stepped).
    colours: bool = false,
    /// A table of scroll a line, both planes' (the intro, the title).
    line_scroll: bool = false,
    /// The scroll by cells, both planes' (the Sega logo's frames: play's way, with nothing to
    /// scroll).
    cell_scroll: bool = false,
    /// Tiles the game copies, a transfer each (Axel's picture revealed, the title's set-up, the
    /// select's portraits' frames, a player's new frame in play).
    tiles: Tiles = .{},
    /// Drawn play's way (the scroll by cells, the status bar), not a screen's: play, the Sega
    /// logo's and the high scores' frames.
    play: bool = false,
    /// The first line's scroll written, a cell each plane (the game menu's, the options', the
    /// character select's frames).
    first_line: bool = false,
    /// The status bar's rows written, `status_cells` cells each.
    status_rows: u8 = 0,
    status_cells: u8 = 0,
    /// The planes' columns written as the camera moves, and their blocks in all; its rows (32
    /// blocks each).
    strips: u8 = 0,
    strip_blocks: u16 = 0,
    strip_rows: u8 = 0,
    /// The health bars' partial cells built.
    bar_parts: u8 = 0,
};

/// Transfers of tiles, each its length in words (16 a tile).
pub const Tiles = struct {
    pub const max = 6;
    words: [max]u16 = @splat(0),
    len: u8 = 0,

    pub fn one(words: u16) Tiles {
        var t: Tiles = .{};
        t.add(words);
        return t;
    }

    /// A transfer of `words` (none when 0, or when there are `max` already).
    pub fn add(self: *Tiles, words: u16) void {
        if (words == 0 or self.len == max) return;
        self.words[self.len] = words;
        self.len += 1;
    }
};

pub const words_per_tile = 16;

/// The sprites' list: 320 words, every frame.
const sprite_list_words = 320;
const colour_words = 64;
const line_scroll_words = 512;
/// Two transfers of 32 words.
const cell_scroll_words = 32;

/// The cycles a transfer of `words` stops the sound's processor; `colours` at half the cost a
/// word.
fn transfer(words: u32, colours: bool) u32 {
    const per_word: u32 = if (colours) 228 else 456;
    return 64 + words * per_word / 205;
}

/// The cycles the pads' reading stops it, at each frame but a load's.
pub const pads = 235;

/// The frame's work before the sound's driver, each part's cost in the sound processor's cycles
/// (sor-remaster's fit over the original's captures).
pub const costs = struct {
    /// A frame's start after a logic tick that ended, and one in the middle of a logic tick (no
    /// picture then).
    pub const frame = 218;
    pub const split = 25;
    /// A frame the logic takes in its middle (an interrupt a load left waiting): the driver alone.
    pub const lag = 6;
    /// The picture's drawing: play's way, a screen's.
    pub const play = 99;
    pub const screen = 120;
    /// A transfer's set-up.
    pub const transfer = 34;
    /// A row of cells written, and each cell (some fitted costs are negative: their unit always
    /// comes with others).
    pub const row = 779;
    pub const row_cell = -3;
    /// A column or a row of a plane's strip, each half block of a column (two cells), each block
    /// of a row (its top and bottom halves, four cells).
    pub const strip = 21;
    pub const strip_half = 25;
    pub const strip_row_block = 46;
    /// The blocks of a row.
    pub const row_blocks = 32;
    /// A health bar's partial cell built.
    pub const bar_part = 195;
    /// A cell written alone.
    pub const cell = -8;
    /// The art streamed in: each tile decoded, each code read (and each written out in full),
    /// each byte read.
    pub const stream_tile = 1593;
    pub const stream_code = 78;
    pub const stream_long_code = 14;
    pub const stream_byte = 9;
    /// The writes of cells go at the processor's pace until the picture's blanking ends, this
    /// far into the frame, then each takes at least `slot` (the video chip's free slots).
    pub const blanking_end = 8180;
    pub const slot = 25;
};

/// The frame's work and holds so far, its writes of cells slowed after the blanking.
const Busy = struct {
    work: i32 = 0,
    held: u32 = 0,

    fn spend(b: *Busy, cycles: i32) void {
        b.work += cycles;
    }

    fn transfer_(b: *Busy, words: u32, colours: bool) void {
        b.work += costs.transfer;
        b.held += transfer(words, colours);
    }

    /// Work of `cost` cycles writing `cells` cells (words).
    fn writes(b: *Busy, cost: i32, cells: u32) void {
        const t = b.work + @as(i32, @intCast(b.held));
        if (cells == 0 or t + cost <= costs.blanking_end) {
            b.work += cost;
            return;
        }
        const n: i32 = @intCast(cells);
        const per = @max(1, @divTrunc(cost, n));
        const fast: i32 = if (t >= costs.blanking_end) 0 else @min(n, @divTrunc(costs.blanking_end - t, per));
        b.work += cost + (n - fast) * (@max(per, costs.slot) - per);
    }
};

/// The work before the sound's driver of the frame that follows a tick whose picture is `f`
/// (null: a tick that ended no frame, the middle of a logic tick or a load's).
pub fn work(f: ?Frame) i32 {
    const x = f orelse return costs.split;
    var b: Busy = .{};
    b.spend(costs.frame);
    if (x.colours) b.transfer_(colour_words, true);
    b.transfer_(sprite_list_words, false);
    b.spend(if (x.play) costs.play else costs.screen);
    if (x.first_line) for (0..2) |_| b.writes(costs.cell, 1);
    if (x.line_scroll) b.transfer_(line_scroll_words, false);
    if (x.cell_scroll) {
        b.transfer_(cell_scroll_words, false);
        b.transfer_(cell_scroll_words, false);
    }
    // A column of n blocks is 2n half blocks of two cells each.
    if (x.strips != 0) {
        b.spend(costs.strip * @as(i32, x.strips));
        for (0..2 * @as(u32, x.strip_blocks)) |_| b.writes(costs.strip_half, 2);
    }
    for (0..x.strip_rows) |_| {
        b.spend(costs.strip);
        for (0..costs.row_blocks) |_| b.writes(costs.strip_row_block, 4);
    }
    for (x.tiles.words[0..x.tiles.len]) |w| b.transfer_(w, false);
    for (0..x.status_rows) |_| b.writes(costs.row + costs.row_cell * @as(i32, x.status_cells), x.status_cells);
    for (0..x.bar_parts) |_| b.writes(costs.bar_part, 16);
    return b.work;
}

/// The work of a frame's decoding of the art streamed in, after its picture's work.
pub fn streamWork(s: Streamed) i32 {
    return @as(i32, s.tiles) * costs.stream_tile + @as(i32, s.codes) * costs.stream_code +
        @as(i32, s.long_codes) * costs.stream_long_code + @as(i32, s.bytes) * costs.stream_byte;
}

/// The cycles the transfers of `f` stop the sound's processor.
pub fn hold(f: Frame) u32 {
    var h = transfer(sprite_list_words, false);
    if (f.colours) h += transfer(colour_words, true);
    if (f.line_scroll) h += transfer(line_scroll_words, false);
    if (f.cell_scroll) h += 2 * transfer(cell_scroll_words, false);
    for (f.tiles.words[0..f.tiles.len]) |w| h += transfer(w, false);
    return h;
}

test "a frame's work before the sound's driver" {
    // A logic tick split in two: its middle.
    try std.testing.expectEqual(@as(i32, 25), work(null));
    // Play: the frame, the sprites' list, the drawing, the status bar's three rows of 40.
    try std.testing.expectEqual(@as(i32, 2328), work(.{ .play = true, .status_rows = 3, .status_cells = 40 }));
    try std.testing.expectEqual(@as(i32, 2362), work(.{ .play = true, .colours = true, .status_rows = 3, .status_cells = 40 }));
    // The Sega logo: play's way, its scroll by cells.
    try std.testing.expectEqual(@as(i32, 453), work(.{ .play = true, .colours = true, .cell_scroll = true }));
}

test "a frame's decoding of the art streamed in" {
    // Round 1's first: five tiles, 181 codes (3 written out in full), 111 bytes.
    try std.testing.expectEqual(@as(i32, 5 * 1593 + 181 * 78 + 3 * 14 + 111 * 9), streamWork(.{ .tiles = 5, .codes = 181, .long_codes = 3, .bytes = 111 }));
    try std.testing.expectEqual(@as(i32, 0), streamWork(.{}));
}

test "the transfers' cycles, as sor-remaster measured them" {
    try std.testing.expectEqual(@as(u32, 775), hold(.{}));
    try std.testing.expectEqual(@as(u32, 775 + 135 + 1202), hold(.{ .colours = true, .line_scroll = true }));
    try std.testing.expectEqual(@as(u32, 775 + 270), hold(.{ .cell_scroll = true }));
    try std.testing.expectEqual(@as(u32, 775 + 6327), hold(.{ .tiles = .one(2816) }));
    // Each transfer its own: a frame's two parts, 34 tiles then 32.
    var parts: Tiles = .{};
    parts.add(34 * words_per_tile);
    parts.add(32 * words_per_tile);
    try std.testing.expectEqual(@as(u32, 775 + 1274 + 1202), hold(.{ .tiles = parts }));
}

//! Text in the game's font and the colours of its game menu (the content's `fonts/main` and
//! `menu/one_pad`: palette 0 bright, palette 1 dim), composed alone or over a picture: what the
//! port draws that the cartridge does not, in the cartridge's look. The browser page's screens are
//! drawn with it (DESIGN.md 5.3: the loading screen, the page's menu, network play's messages), and
//! so are the scenes the game puts over its picture (S3: the settings, the other player's absence,
//! a notice about the settings record).
//!
//! The panel is a board of the screen's cells, its own composer, and the arrow of the menu (the
//! font's `->`) as a sprite; it composes into its own RGBA picture, never into the game's view, so
//! the game's picture and its state are the same with a panel over it or not.
const std = @import("std");
const platform = @import("platform.zig");
const render = @import("render/root.zig");
const art = @import("content/art.zig");

pub const width = render.width;
pub const height = render.height;
pub const columns = width / 8;
pub const rows = height / 8;

pub const Tone = enum(u2) { bright = 0, dim = 1 };

/// `%`, which the game's font does not have: a tile in the style of the font's digits (1 the
/// letter, C its shade, 2 the cell's ground), slanted as they are.
const percent_tile: art.Tile = tile: {
    const rows_ = [8]*const [8]u8{
        "22211C1C",
        "2211C1C2",
        "22221C22",
        "2221C222",
        "221C2222",
        "21C211C2",
        "1C211C22",
        "22222222",
    };
    var t: art.Tile = undefined;
    for (rows_, 0..) |row, y| for (row, 0..) |ch, x| {
        t[y * 8 + x] = switch (ch) {
            '1' => 1,
            '2' => 2,
            'C' => 12,
            else => unreachable,
        };
    };
    break :tile t;
};

/// A cell of the font's ground alone (the menu's black): a panel's box, a strip under a message.
const ground_tile: art.Tile = @splat(2);

/// The longest line of a message; a longer one is cut at its spaces.
pub const message_columns = 36;

pub const Panel = struct {
    gpa: std.mem.Allocator,
    font: *const art.Font,
    sheet: *const art.TileSheet,
    arrow: art.Frame,
    board: render.Board,
    composer: *render.Composer,
    sprites: [1]render.Sprite = undefined,
    screen: render.Screen = .{},
    /// The menu's colours, which a fade goes from or towards.
    colours: render.palettes.Colours = render.palettes.black,
    /// The last picture, RGBA.
    rgba: []u8,

    pub const Error = error{OutOfMemory};

    /// In place: the screen's layer points at the board. `font` (its glyphs tiles of `sheet`,
    /// `->` among them) and `colours` outlive the panel.
    pub fn init(self: *Panel, gpa: std.mem.Allocator, font: *const art.Font, sheet: *const art.TileSheet, colours: *const art.Palette) error{ OutOfMemory, NoArrow }!void {
        const g = font.glyphAt("->") orelse return error.NoArrow;
        self.* = .{
            .gpa = gpa,
            .font = font,
            .sheet = sheet,
            .arrow = .{ .name = "arrow", .file = "", .width = 8, .height = 8, .origin_x = 0, .origin_y = 0, .pixels = &sheet.tiles[g.tile] },
            .board = try render.Board.init(gpa, columns, rows),
            .composer = undefined,
            .rgba = &.{},
        };
        errdefer self.board.deinit();
        self.composer = try render.Composer.create(gpa);
        errdefer self.composer.destroy();
        self.rgba = try gpa.alloc(u8, width * height * 4);
        self.screen = .{ .plane_a = .{ .board = &self.board } };
        colours.apply(&self.colours);
        self.screen.colours = self.colours;
    }

    pub fn deinit(self: *Panel) void {
        self.gpa.free(self.rgba);
        self.composer.destroy();
        self.board.deinit();
        self.* = undefined;
    }

    /// The colours `steps` steps into a fade of the panel (render.Fade, a step a tick), from black
    /// to the menu's colours or from them to black; null: the menu's colours.
    pub fn faded(self: *Panel, to: ?render.Fade.To, steps: u8) void {
        const t = to orelse {
            self.screen.colours = self.colours;
            return;
        };
        var ps: render.Palettes = .{ .shown = if (t == .black) self.colours else render.palettes.black, .target = self.colours };
        var f: render.Fade = .{ .to = t };
        for (0..steps) |_| _ = f.step(&ps);
        self.screen.colours = ps.shown;
    }

    /// A new picture: no text, no arrow.
    pub fn begin(self: *Panel) void {
        self.board.clear();
        self.screen.sprites = &.{};
    }

    /// `s` in the font from column `col` of `row`, bright or dim. A lower-case letter is drawn as
    /// its capital, a separator of a file's name (`/`, `_`) as the dash, `%` as the panel's own
    /// tile, and a character the font does not have as a blank; a blank keeps what is under it.
    pub fn text(self: *Panel, col: usize, row: usize, s: []const u8, tone: Tone) Error!void {
        const look: render.Look = .{ .palette = @backingInt(tone) };
        for (s, 0..) |ch, i| {
            if (col + i >= columns or row >= rows) break;
            const x: i32 = @intCast(col + i);
            const c = switch (ch) {
                '/', '\\', '_' => '-',
                else => std.ascii.toUpper(ch),
            };
            if (c == '%') {
                self.board.put(x, @intCast(row), &percent_tile, look) catch return error.OutOfMemory;
                continue;
            }
            if (c == ' ') continue;
            const g = self.font.glyphAt(&.{c}) orelse continue;
            self.board.put(x, @intCast(row), &self.sheet.tiles[g.tile], look) catch return error.OutOfMemory;
        }
    }

    /// A box of the ground's cells (black), `cols` by `rows_` from (`col`, `row`), under the text.
    pub fn box(self: *Panel, col: usize, row: usize, cols: usize, rows_: usize) Error!void {
        for (row..@min(rows, row + rows_)) |y| for (col..@min(columns, col + cols)) |x| {
            self.board.put(@intCast(x), @intCast(y), &ground_tile, .{}) catch return error.OutOfMemory;
        };
    }

    /// The menu's arrow at the cell (`col`, `row`).
    pub fn arrowAt(self: *Panel, col: i32, row: i32) void {
        self.sprites[0] = render.Sprite.of(&self.arrow, col * 8, row * 8);
        self.screen.sprites = &self.sprites;
    }

    /// The lines of `text_` (split at '\n', each cut at its spaces to fit), centred from
    /// `first_row`, each on a strip of the ground a cell wider on each side when `strips`;
    /// returns the row after them.
    pub fn message(self: *Panel, text_: []const u8, first_row: usize, strips: bool) Error!usize {
        var row = first_row;
        var it = std.mem.splitScalar(u8, text_, '\n');
        var first = true;
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (!first) row += 1;
            first = false;
            var rest = std.mem.trim(u8, line, " ");
            while (rest.len != 0 and row < rows - 1) : (row += 1) {
                var n: usize = @min(rest.len, message_columns);
                if (n < rest.len) {
                    if (std.mem.lastIndexOfScalar(u8, rest[0 .. n + 1], ' ')) |space| {
                        if (space != 0) n = space;
                    }
                }
                const part = std.mem.trimEnd(u8, rest[0..n], " ");
                const col = (columns - part.len) / 2;
                if (strips) try self.box(col -| 1, row, part.len + 2, 1);
                try self.text(col, row, part, .bright);
                rest = std.mem.trimStart(u8, rest[n..], " ");
            }
        }
        return row;
    }

    /// Composes the picture; over `under`, where the panel is empty (its backdrop), the picture
    /// under it, at a quarter of its light when `dim`.
    pub fn finish(self: *Panel, under: ?platform.RgbaFrame, dim: bool) Error![]const u8 {
        _ = try self.composer.compose(&self.screen);
        const f = self.composer.frame();
        @memcpy(self.rgba, f.pixels[0 .. width * height * 4]);
        const u = under orelse return self.rgba;
        for (0..height) |y| for (0..width) |x| {
            if (self.composer.indices[y * width + x] != 0) continue;
            const from = u.pixels[y * u.stride + x * 4 ..][0..4];
            const to = self.rgba[(y * width + x) * 4 ..][0..4];
            if (dim) {
                to.* = .{ from[0] / 4, from[1] / 4, from[2] / 4, 255 };
            } else to.* = from.*;
        };
        return self.rgba;
    }
};

// --- tests -----------------------------------------------------------------------------------------

const testing = std.testing;

/// A font whose tiles are its glyphs' codes in colour 1 on a ground of colour 2 (the blank, A,
/// the dash, the arrow), and the menu's colours (palette 0 white, palette 1 dim).
pub const Fixture = struct {
    pub const tiles = blk: {
        var t: [4]art.Tile = undefined;
        for (&t, 0..) |*x, k| {
            @memset(x, 2);
            if (k != 0) @memset(x[0..8], 1);
        }
        break :blk t;
    };
    pub const sheet: art.TileSheet = .{ .name = "main", .file = "main.png", .tiles = &tiles };
    pub const glyphs = [_]art.Glyph{ .{ .text = " ", .tile = 0 }, .{ .text = "A", .tile = 1 }, .{ .text = "-", .tile = 2 }, .{ .text = "->", .tile = 3 } };
    pub const font: art.Font = .{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs };
    pub const colours = blk: {
        var c: art.Palette = .{ .name = "one_pad" };
        c.colours[0][1] = .{ .r = 7, .g = 7, .b = 7 };
        c.colours[0][2] = art.Colour.black;
        c.colours[1][1] = .{ .r = 1, .g = 1, .b = 1 };
        c.colours[1][2] = art.Colour.black;
        break :blk c;
    };
};

fn pixelAt(rgba: []const u8, x: usize, y: usize) [3]u8 {
    return rgba[(y * width + x) * 4 ..][0..3].*;
}

test "a panel: text bright and dim, a box, a message on strips over a picture, dimmed or not" {
    var p: Panel = undefined;
    try p.init(testing.allocator, &Fixture.font, &Fixture.sheet, &Fixture.colours);
    defer p.deinit();
    p.begin();
    try p.text(2, 1, "a-", .bright);
    try p.text(2, 2, "A", .dim);
    p.arrowAt(0, 1);
    var rgba = try p.finish(null, false);
    try testing.expectEqual([3]u8{ 255, 255, 255 }, pixelAt(rgba, 16, 8));
    try testing.expectEqual([3]u8{ 49, 49, 49 }, pixelAt(rgba, 16, 16));
    try testing.expectEqual([3]u8{ 255, 255, 255 }, pixelAt(rgba, 0, 8));

    const under = try testing.allocator.alloc(u8, width * height * 4);
    defer testing.allocator.free(under);
    @memset(under, 0x80);
    const frame: platform.RgbaFrame = .{ .width = width, .height = height, .stride = width * 4, .pixels = under };
    p.begin();
    try testing.expectEqual(@as(usize, 12), try p.message("aa", 11, true));
    rgba = try p.finish(frame, false);
    try testing.expectEqual([3]u8{ 255, 255, 255 }, pixelAt(rgba, 19 * 8, 11 * 8));
    try testing.expectEqual([3]u8{ 0, 0, 0 }, pixelAt(rgba, 18 * 8, 11 * 8));
    try testing.expectEqual([3]u8{ 0x80, 0x80, 0x80 }, pixelAt(rgba, 17 * 8, 11 * 8));
    rgba = try p.finish(frame, true);
    try testing.expectEqual([3]u8{ 0x20, 0x20, 0x20 }, pixelAt(rgba, 17 * 8, 11 * 8));
    p.begin();
    try p.box(1, 1, 3, 2);
    rgba = try p.finish(frame, true);
    try testing.expectEqual([3]u8{ 0, 0, 0 }, pixelAt(rgba, 3 * 8, 2 * 8 + 7));
    try testing.expectEqual([3]u8{ 0x20, 0x20, 0x20 }, pixelAt(rgba, 4 * 8, 2 * 8));
}

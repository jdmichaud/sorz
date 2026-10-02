//! A board: the cells a layer of the picture shows (DESIGN.md 10.5, R1-R2). A screen or a round
//! draws the content's maps on it by name, at their place or at a cell, and writes texts with a
//! font. A board is the size the screen needs (a round's whole map, a screen's 64 x 64 cells)
//! and repeats past its edges.
//!
//! A cell names a tile of the board's own list, which refers to the tiles of the sheets drawn on
//! it. The board also keeps its cells drawn, ready for the composition: when a cell is written,
//! its tile's 8 rows are drawn into the board's pixels with the cell's flips, palette and
//! priority, so that a layer's line is a copy of a run of them.
const std = @import("std");
const art = @import("../content/art.zig");

pub const Cell = art.Cell;
pub const Tile = art.Tile;

// A pixel of a layer, as boards keep them and the composition mixes them: 0 where transparent,
// else its colour index (the palette times 16 plus the colour, 1 to 15) with its priority in bit 7.

pub const priority_bit: u8 = 128;

pub fn attributes(palette: u2, priority: bool) u8 {
    return @as(u8, @intFromBool(priority)) * priority_bit + @as(u8, palette) * art.palette_size;
}

// Eight pixels in a word, the first in its low byte, to work on them at once (in plain integers,
// which a debug build runs about as fast as vectors).
pub const lanes: u64 = std.math.maxInt(u64) / 255;
pub const high_bits: u64 = lanes * priority_bit;
const colour_bits: u64 = lanes * (art.palette_size - 1);

pub inline fn load(bytes: *const [8]u8) u64 {
    return std.mem.readInt(u64, bytes, .little);
}

pub inline fn store(bytes: *[8]u8, w: u64) void {
    std.mem.writeInt(u64, bytes, w, .little);
}

/// Bit 7 of each byte whose colour (its low 4 bits) is not 0.
pub inline fn opaqueBits(w: u64) u64 {
    return ((w & colour_bits) +% lanes * 127) & high_bits;
}

/// Each byte to all ones where `m` (bits 7 only) has its bit 7, else to 0.
pub inline fn spread(m: u64) u64 {
    return (m -% (m >> 7)) | m;
}

/// The bytes of `x` where `mask`'s are all ones, else those of `y`.
pub inline fn choose(mask: u64, x: u64, y: u64) u64 {
    return (x & mask) | (y & ~mask);
}

pub const Board = struct {
    gpa: std.mem.Allocator,
    /// The size in cells.
    width: u16,
    height: u16,
    /// `width` * `height` cells, row by row; `Cell.tile` numbers `tiles`.
    cells: []Cell,
    /// The cells drawn: `width` * 8 pixels a row, `height` * 8 rows (layer pixels, above).
    pixels: []u8,
    /// The tiles the cells draw, each the tile of a sheet drawn on the board.
    tiles: std.ArrayList(*const Tile) = .empty,
    /// The runs of tiles registered: a map's tiles, a sheet's, each with its first number.
    runs: std.ArrayList(Run) = .empty,
    /// Counts the changes, so the composition knows when to draw the layer again.
    revision: u32 = 0,

    const Run = struct { first: [*]const Tile, len: usize, base: u16 };

    pub const Error = error{ OutOfMemory, TooManyTiles, NoGlyph };

    pub fn init(gpa: std.mem.Allocator, width: u16, height: u16) error{OutOfMemory}!Board {
        std.debug.assert(width > 0 and height > 0);
        const cells = try gpa.alloc(Cell, @as(usize, width) * height);
        errdefer gpa.free(cells);
        @memset(cells, Cell.empty);
        const pixels = try gpa.alloc(u8, @as(usize, width) * height * 64);
        @memset(pixels, 0);
        return .{ .gpa = gpa, .width = width, .height = height, .cells = cells, .pixels = pixels };
    }

    pub fn deinit(self: *Board) void {
        self.gpa.free(self.cells);
        self.gpa.free(self.pixels);
        self.tiles.deinit(self.gpa);
        self.runs.deinit(self.gpa);
        self.* = undefined;
    }

    /// Every cell empty, and the tiles forgotten.
    pub fn clear(self: *Board) void {
        @memset(self.cells, Cell.empty);
        @memset(self.pixels, 0);
        self.tiles.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.revision +%= 1;
    }

    /// The cell at (x, y), repeating past the board's edges.
    pub fn cell(self: *const Board, x: i32, y: i32) Cell {
        return self.cells[self.index(x, y)];
    }

    /// The pixel width of the board's rows.
    pub fn pixelWidth(self: *const Board) usize {
        return @as(usize, self.width) * art.tile_side;
    }

    /// The board's pixel row `py` (0 to `height` * 8 - 1).
    pub fn row(self: *const Board, py: usize) []const u8 {
        const w = self.pixelWidth();
        return self.pixels[py * w ..][0..w];
    }

    fn index(self: *const Board, x: i32, y: i32) usize {
        const cx: usize = @intCast(@mod(x, @as(i32, self.width)));
        const cy: usize = @intCast(@mod(y, @as(i32, self.height)));
        return cy * self.width + cx;
    }

    /// Writes cell `i` and draws it.
    fn set(self: *Board, i: usize, c: Cell) void {
        self.cells[i] = c;
        const w = self.pixelWidth();
        const at = (i / self.width) * 8 * w + (i % self.width) * 8;
        if (c.isEmpty()) {
            for (0..8) |ty| store(self.pixels[at + ty * w ..][0..8], 0);
            return;
        }
        const t = self.tiles.items[c.tile];
        const attr = lanes * attributes(c.palette, c.priority);
        for (0..8) |ty| {
            var px = load(t[(if (c.flip_y) 7 - ty else ty) * 8 ..][0..8]);
            if (c.flip_x) px = @byteSwap(px);
            store(self.pixels[at + ty * w ..][0..8], (px | attr) & spread(opaqueBits(px)));
        }
    }

    /// The number the board gives the first of `tiles`, registering them on first use.
    fn base(self: *Board, tiles: []const Tile) Error!u16 {
        for (self.runs.items) |r| {
            if (r.first == tiles.ptr and r.len == tiles.len) return r.base;
        }
        const first = self.tiles.items.len;
        if (first + tiles.len >= Cell.no_tile) return error.TooManyTiles;
        try self.runs.ensureUnusedCapacity(self.gpa, 1);
        try self.tiles.ensureUnusedCapacity(self.gpa, tiles.len);
        for (tiles) |*t| self.tiles.appendAssumeCapacity(t);
        self.runs.appendAssumeCapacity(.{ .first = tiles.ptr, .len = tiles.len, .base = @intCast(first) });
        return @intCast(first);
    }

    /// Draws `map` with its top-left cell at (x, y): each of its cells replaces the board's, an
    /// empty one too, repeating past the board's edges.
    pub fn drawMap(self: *Board, map: *const art.TileMap, x: i32, y: i32) Error!void {
        const b = try self.base(map.tiles);
        for (0..map.height) |my| for (0..map.width) |mx| {
            var c = map.cell(mx, my);
            if (!c.isEmpty()) c.tile += b;
            self.set(self.index(x + @as(i32, @intCast(mx)), y + @as(i32, @intCast(my))), c);
        };
        self.revision +%= 1;
    }

    /// Draws `map` at the cell of its place (`TileMap.place`), or at (0, 0) when it has none.
    pub fn drawMapAtPlace(self: *Board, map: *const art.TileMap) Error!void {
        const p = map.place orelse return self.drawMap(map, 0, 0);
        return self.drawMap(map, p.x, p.y);
    }

    /// Puts one tile at (x, y) (a tile the game makes, such as a bar's part). Its pixels are drawn
    /// as they are when it is put; `tile` must stay alive while the board shows it.
    pub fn put(self: *Board, x: i32, y: i32, tile: *const Tile, look: Look) Error!void {
        const b = try self.base(@as(*const [1]Tile, tile));
        self.set(self.index(x, y), look.cell(b));
        self.revision +%= 1;
    }

    /// Writes `text` with `font` (its glyphs tiles of `sheet`) from (x, y) to the right, a glyph a
    /// cell; a text the font has no glyph for is refused, and nothing of it is written.
    pub fn write(self: *Board, sheet: *const art.TileSheet, font: *const art.Font, x: i32, y: i32, text: []const u8, look: Look) Error!void {
        var rest = text;
        while (rest.len != 0) {
            const g = font.glyphAt(rest) orelse return error.NoGlyph;
            rest = rest[g.len..];
        }
        const b = try self.base(sheet.tiles);
        rest = text;
        var cx = x;
        while (rest.len != 0) : (cx += 1) {
            const g = font.glyphAt(rest).?;
            rest = rest[g.len..];
            self.set(self.index(cx, y), look.cell(b + g.tile));
        }
        self.revision +%= 1;
    }

    /// Empties the cells of a rectangle.
    pub fn erase(self: *Board, x: i32, y: i32, width: u16, height: u16) void {
        for (0..height) |dy| for (0..width) |dx| {
            self.set(self.index(x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy))), Cell.empty);
        };
        self.revision +%= 1;
    }
};

/// How a cell draws its tile: the palette, the flips and the priority.
pub const Look = struct {
    palette: u2 = 0,
    flip_x: bool = false,
    flip_y: bool = false,
    priority: bool = false,

    fn cell(l: Look, tile: u16) Cell {
        return .{ .tile = tile, .palette = l.palette, .flip_x = l.flip_x, .flip_y = l.flip_y, .priority = l.priority };
    }
};

// Tests ----------------------------------------------------------------------------------------

const testing = std.testing;

fn solid(v: u8) Tile {
    return @splat(v);
}

/// Every pixel of the board against its cells and their tiles.
fn expectDrawn(b: *const Board) !void {
    for (0..@as(usize, b.height) * 8) |py| for (0..b.pixelWidth()) |px| {
        const c = b.cell(@intCast(px / 8), @intCast(py / 8));
        var want: u8 = 0;
        if (!c.isEmpty()) {
            const tx = if (c.flip_x) 7 - px % 8 else px % 8;
            const ty = if (c.flip_y) 7 - py % 8 else py % 8;
            const v = b.tiles.items[c.tile][ty * 8 + tx];
            if (v != 0) want = attributes(c.palette, c.priority) + v;
        }
        try testing.expectEqual(want, b.row(py)[px]);
    };
}

test "maps drawn on a board keep their cells' looks, and share the board's tiles" {
    var tiles = [_]Tile{ solid(1), solid(2) };
    tiles[1][3] = 0;
    tiles[1][9] = 7;
    const cells = [_]Cell{ .{ .tile = 1, .palette = 3, .flip_x = true }, .empty, .{ .tile = 0, .priority = true }, .{ .tile = 1, .flip_y = true } };
    const map: art.TileMap = .{ .name = "m", .file = "m.tmj", .width = 2, .height = 2, .sheets = &.{}, .tiles = &tiles, .cells = &cells, .place = .{ .layer = .plane_a, .x = 3, .y = 1 } };
    var b = try Board.init(testing.allocator, 4, 4);
    defer b.deinit();
    try b.drawMapAtPlace(&map);
    try expectDrawn(&b);
    // The map's right column wraps to the board's first.
    const c = b.cell(3, 1);
    try testing.expectEqual(@as(u2, 3), c.palette);
    try testing.expect(c.flip_x and b.tiles.items[c.tile] == &tiles[1]);
    try testing.expect(b.cell(0, 1).isEmpty());
    try testing.expect(b.cell(3, 2).priority and b.tiles.items[b.cell(3, 2).tile] == &tiles[0]);
    // Drawn again elsewhere, the map's tiles are not registered twice.
    try b.drawMap(&map, 0, 0);
    try expectDrawn(&b);
    try testing.expectEqual(@as(usize, 2), b.tiles.items.len);
    try testing.expect(b.cell(-1, -1).isEmpty() and b.cell(3, 3).isEmpty());
    const r = b.revision;
    b.clear();
    try testing.expect(b.revision != r and b.cell(3, 1).isEmpty() and b.tiles.items.len == 0);
    try testing.expect(std.mem.allEqual(u8, b.pixels, 0));
}

test "texts are written a glyph a cell, the longest glyph first, or refused whole" {
    const tiles = [_]Tile{ solid(0), solid(1), solid(2), solid(3) };
    const sheet: art.TileSheet = .{ .name = "main", .file = "main.png", .tiles = &tiles };
    const glyphs = [_]art.Glyph{ .{ .text = " ", .tile = 0 }, .{ .text = "A", .tile = 1 }, .{ .text = "-", .tile = 2 }, .{ .text = "->", .tile = 3 } };
    const font: art.Font = .{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs };
    var b = try Board.init(testing.allocator, 8, 2);
    defer b.deinit();
    try b.write(&sheet, &font, 1, 1, "->A -", .{ .palette = 1, .priority = true });
    try expectDrawn(&b);
    const want = [_]*const Tile{ &tiles[3], &tiles[1], &tiles[0], &tiles[2] };
    for (want, 1..) |t, x| {
        const c = b.cell(@intCast(x), 1);
        try testing.expect(b.tiles.items[c.tile] == t and c.palette == 1);
    }
    try testing.expectError(error.NoGlyph, b.write(&sheet, &font, 0, 0, "AB", .{}));
    try testing.expect(b.cell(0, 0).isEmpty());
}

test "a tile put on its own, and a rectangle erased" {
    var t = solid(9);
    t[0] = 4;
    var b = try Board.init(testing.allocator, 2, 2);
    defer b.deinit();
    try b.put(1, 0, &t, .{ .flip_y = true, .palette = 2 });
    try expectDrawn(&b);
    try testing.expect(b.tiles.items[b.cell(1, 0).tile] == &t and b.cell(1, 0).flip_y);
    try testing.expectEqual(@as(u8, 32 + 4), b.row(7)[8]);
    b.erase(0, 0, 2, 1);
    try testing.expect(b.cell(1, 0).isEmpty());
    try expectDrawn(&b);
}

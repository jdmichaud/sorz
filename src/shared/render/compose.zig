//! The composition of a picture (DESIGN.md 10.5, R1, R3, R4): its layers and sprites into
//! 320 x 224 colour indices (a palette times 16 plus a colour), then into RGBA for the platform.
//!
//! The work is done by cell and by run, not pixel by pixel:
//! - a board keeps its cells drawn (each cell's tile drawn once, when the cell is written), and a
//!   layer's line is a copy of a run of the board's pixels;
//! - a sprite is placed once and drawn over its visible lines, 8 pixels at a time;
//! - the layers are mixed 8 pixels at a time, in plain 64-bit integers.
//! What did not change is not drawn again: a layer whose board, revision and scroll are the
//! same keeps its pixels, the sprites theirs, and an unchanged picture is not composed at all.
//! The tests check the composition against the rules applied pixel by pixel (`reference`).
const std = @import("std");
const platform = @import("../platform.zig");
const art = @import("../content/art.zig");
const palettes = @import("palettes.zig");
const screen = @import("screen.zig");
const board_mod = @import("board.zig");

const Board = board_mod.Board;
const Cell = board_mod.Cell;
const Screen = screen.Screen;
const Layer = screen.Layer;
const Sprite = screen.Sprite;
const Lines = screen.Lines;

const lanes = board_mod.lanes;
const high_bits = board_mod.high_bits;
const load = board_mod.load;
const store = board_mod.store;
const opaqueBits = board_mod.opaqueBits;
const spread = board_mod.spread;
const choose = board_mod.choose;

pub const width = screen.width;
pub const height = screen.height;

// A layer's line: its pixels (a board's, `board.zig`), with 8 bytes of room on either side where
// the sprites' edges spill.
const margin = 8;
const row_len = margin + width + margin;
const Row = [row_len]u8;

const index_bits: u64 = lanes * (palettes.count * palettes.size - 1);

/// `out.len` pixels of the board's pixel row `py`, from its pixel `px` on, repeating past its
/// right edge.
fn copyRun(b: *const Board, py: usize, px: usize, out: []u8) void {
    const src = b.row(py);
    var x = px;
    var at: usize = 0;
    while (at < out.len) {
        const n = @min(out.len - at, src.len - x);
        @memcpy(out[at..][0..n], src[x..][0..n]);
        at += n;
        x = 0;
    }
}

/// A scrolling layer's pixels on `line`.
fn layerLine(l: *const Layer, line: usize, out: *Row) void {
    const b = l.board orelse {
        @memset(out, 0);
        return;
    };
    const bw: i32 = @intCast(b.pixelWidth());
    const bh: i32 = @as(i32, b.height) * screen.cell;
    const x = l.x +% (if (l.line_x) |lx| lx[line] else 0);
    const px: usize = @intCast(@mod(x, bw));
    const y = l.y +% @as(i32, @intCast(line));
    if (l.column_y) |cy| {
        // Each 16-pixel column at its own height.
        for (cy, 0..) |dy, c| {
            const py: usize = @intCast(@mod(y +% dy, bh));
            const cpx = (px + c * screen.column_width) % @as(usize, @intCast(bw));
            copyRun(b, py, cpx, out[margin + c * screen.column_width ..][0..screen.column_width]);
        }
    } else {
        copyRun(b, @intCast(@mod(y, bh)), px, out[margin..][0..width]);
    }
}

/// The window's pixels on `line`: its board's row `line`, not scrolled.
fn windowLine(b: *const Board, line: usize, out: *Row) void {
    copyRun(b, line % (@as(usize, b.height) * screen.cell), 0, out[margin..][0..width]);
}

/// Draws a sprite over the lines of `rows` it covers.
fn drawSprite(s: *const Sprite, lines: Lines, rows: *[height]Row) void {
    const f = s.frame;
    const top: i32 = s.y - f.origin_y;
    const first: i32 = @max(top, lines.top);
    const end: i32 = @min(top + f.height, lines.bottom);
    if (first >= end) return;
    const fw: i32 = f.width;
    // The frame's columns on the screen: column c at x0 + c, or mirrored at x0 - c.
    const x0: i32 = if (s.flip_x) s.x - 1 + f.origin_x else s.x - f.origin_x;
    const c_start: usize = @intCast(if (s.flip_x) @max(0, x0 - width + 1) else @max(0, -x0));
    const c_end: usize = @intCast(@max(0, if (s.flip_x) @min(fw, x0 + 1) else @min(fw, width - x0)));
    if (c_start >= c_end) return;
    // The whole groups of 8 columns, and the rest.
    const whole = (c_end - c_start) / 8;
    const rest = (c_end - c_start) % 8;
    const attr = lanes * board_mod.attributes(s.palette, s.priority);
    // Where the first group's 8 pixels go in a row: the first's place, or mirrored the last's.
    const at0: usize = @intCast(margin + if (s.flip_x) x0 - @as(i32, @intCast(c_start)) - 7 else x0 + @as(i32, @intCast(c_start)));
    var line: i32 = first;
    while (line < end) : (line += 1) {
        const r: usize = @intCast(line - top);
        const ry = if (s.flip_y) f.height - 1 - r else r;
        var src = f.pixels[ry * f.width + c_start ..][0 .. c_end - c_start];
        const out = &rows[@intCast(line)];
        var at = at0;
        for (0..whole + @intFromBool(rest != 0)) |k| {
            var w: u64 = undefined;
            if (k < whole) {
                w = load(src[0..8]);
                src = src[8..];
            } else {
                var part: [8]u8 = @splat(0);
                @memcpy(part[0..rest], src);
                w = load(&part);
            }
            if (w != 0) {
                if (s.flip_x) w = @byteSwap(w);
                const dst = out[at..][0..8];
                store(dst, choose(spread(opaqueBits(w)), w | attr, load(dst)));
            }
            if (s.flip_x) at -%= 8 else at += 8;
        }
    }
}

/// The layers' pixels on a line into colour indices: plane B, then the front (plane A or the
/// window), then the sprites; a pixel with priority over the pixels without it; the backdrop
/// where all are transparent.
fn mixLine(back: *const Row, front: *const Row, sprites: *const Row, backdrop: u8, out: *[width]u8) void {
    const fill = lanes * backdrop;
    var x: usize = 0;
    while (x < width) : (x += 8) {
        var c = load(back[margin + x ..][0..8]);
        inline for (.{ front, sprites }) |layer| {
            const l = load(layer[margin + x ..][0..8]);
            // In front of what is there, unless that has priority and it has not.
            if (l != 0) c = choose(spread(opaqueBits(l) & ~(c & ~l & high_bits)), l, c);
        }
        store(out[x..][0..8], choose(spread(opaqueBits(c)), c, fill) & index_bits);
    }
}

/// What a scrolling layer was composed from.
const LayerKey = struct {
    board: ?*const Board = null,
    revision: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    line_x: ?[height]i32 = null,
    column_y: ?[screen.columns]i32 = null,

    fn of(l: *const Layer) LayerKey {
        return .{
            .board = l.board,
            .revision = if (l.board) |b| b.revision else 0,
            .x = l.x,
            .y = l.y,
            .line_x = if (l.line_x) |v| v.* else null,
            .column_y = if (l.column_y) |v| v.* else null,
        };
    }
};

const FrontKey = struct {
    plane_a: LayerKey = .{},
    window: ?*const Board = null,
    window_revision: u32 = 0,
    lines: Lines = .{},

    fn of(p: *const Screen) FrontKey {
        return .{
            .plane_a = .of(&p.plane_a),
            .window = p.window.board,
            .window_revision = if (p.window.board) |b| b.revision else 0,
            .lines = p.window.lines,
        };
    }
};

pub const Composer = struct {
    gpa: std.mem.Allocator,
    /// The picture: a colour index (palette * 16 + colour) per pixel, row by row.
    indices: [height * width]u8 = undefined,
    /// The picture in RGBA, a pixel a word (its bytes R, G, B, A).
    rgba: [height * width]u32 = undefined,
    back: [height]Row = undefined,
    front: [height]Row = undefined,
    sprites: [height]Row = undefined,
    /// What the last picture was composed from; null before the first.
    back_key: ?LayerKey = null,
    front_key: ?FrontKey = null,
    sprite_key: std.ArrayList(Sprite) = .empty,
    sprite_lines: ?Lines = null,
    backdrop: ?u8 = null,
    colours: ?palettes.Colours = null,

    pub fn create(gpa: std.mem.Allocator) error{OutOfMemory}!*Composer {
        const self = try gpa.create(Composer);
        self.* = .{ .gpa = gpa };
        return self;
    }

    pub fn destroy(self: *Composer) void {
        self.sprite_key.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Composes `p` into `indices` and `rgba`, drawing again only what changed: a board is known
    /// by its address and revision, a frame by its address. Returns false when nothing was drawn
    /// again (`p` shows what the last screen composed showed), true otherwise.
    pub fn compose(self: *Composer, p: *const Screen) error{OutOfMemory}!bool {
        var mixed = false;
        const back_key: LayerKey = .of(&p.plane_b);
        if (self.back_key == null or !std.meta.eql(self.back_key.?, back_key)) {
            for (&self.back, 0..) |*r, line| layerLine(&p.plane_b, line, r);
            self.back_key = back_key;
            mixed = true;
        }
        const front_key: FrontKey = .of(p);
        if (self.front_key == null or !std.meta.eql(self.front_key.?, front_key)) {
            for (&self.front, 0..) |*r, line| {
                if (p.window.board != null and p.window.lines.has(line)) {
                    windowLine(p.window.board.?, line, r);
                } else layerLine(&p.plane_a, line, r);
            }
            self.front_key = front_key;
            mixed = true;
        }
        if (self.sprite_lines == null or !std.meta.eql(self.sprite_lines.?, p.sprite_lines) or !sameSprites(self.sprite_key.items, p.sprites)) {
            try self.sprite_key.resize(self.gpa, p.sprites.len);
            @memcpy(self.sprite_key.items, p.sprites);
            self.sprite_lines = p.sprite_lines;
            @memset(std.mem.sliceAsBytes(&self.sprites), 0);
            const lines: Lines = .{ .top = @min(p.sprite_lines.top, height), .bottom = @min(p.sprite_lines.bottom, height) };
            for (p.sprites) |*s| drawSprite(s, lines, &self.sprites);
            mixed = true;
        }
        const backdrop = p.backdrop.index();
        if (self.backdrop != backdrop) {
            self.backdrop = backdrop;
            mixed = true;
        }
        if (mixed) {
            for (0..height) |line| mixLine(&self.back[line], &self.front[line], &self.sprites[line], backdrop, self.indices[line * width ..][0..width]);
        }
        if (mixed or self.colours == null or !std.meta.eql(self.colours.?, p.colours)) {
            self.colours = p.colours;
            var table: [256]u32 = @splat(0);
            for (p.colours, 0..) |line, i| for (line, 0..) |c, k| {
                table[i * palettes.size + k] = std.mem.readInt(u32, &palettes.rgba(c), .native);
            };
            // Eight pixels a step.
            var k: usize = 0;
            while (k < self.indices.len) : (k += 8) {
                const w = load(self.indices[k..][0..8]);
                const out = self.rgba[k..][0..8];
                inline for (0..8) |j| out[j] = table[@as(u8, @truncate(w >> (8 * j)))];
            }
            return true;
        }
        return false;
    }

    /// The last picture composed, for the platform to present.
    pub fn frame(self: *const Composer) platform.RgbaFrame {
        return .{ .width = width, .height = height, .stride = width * 4, .pixels = std.mem.sliceAsBytes(&self.rgba) };
    }
};

fn sameSprites(a: []const Sprite, b: []const Sprite) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

// The rules pixel by pixel ----------------------------------------------------------------------

/// A layer's pixel: its colour index, 0 where transparent, and its priority.
const Px = struct { index: u8 = 0, priority: bool = false };

fn boardPixel(b: *const Board, px: i32, py: i32) Px {
    const c = b.cell(@divFloor(px, 8), @divFloor(py, 8));
    if (c.isEmpty()) return .{};
    const tx: usize = @intCast(@mod(px, 8));
    const ty: usize = @intCast(@mod(py, 8));
    const v = b.tiles.items[c.tile][(if (c.flip_y) 7 - ty else ty) * 8 + (if (c.flip_x) 7 - tx else tx)];
    if (v == 0) return .{};
    return .{ .index = @as(u8, c.palette) * palettes.size + v, .priority = c.priority };
}

fn layerPixel(l: *const Layer, x: usize, line: usize) Px {
    const b = l.board orelse return .{};
    const dx = if (l.line_x) |lx| lx[line] else 0;
    const dy = if (l.column_y) |cy| cy[x / screen.column_width] else 0;
    return boardPixel(b, l.x + dx + @as(i32, @intCast(x)), l.y + dy + @as(i32, @intCast(line)));
}

fn spritePixel(p: *const Screen, x: usize, line: usize) Px {
    if (!p.sprite_lines.has(line)) return .{};
    var i = p.sprites.len;
    // The last sprite given with a pixel there is in front.
    while (i > 0) {
        i -= 1;
        const s = &p.sprites[i];
        const f = s.frame;
        const r = @as(i32, @intCast(line)) - (s.y - f.origin_y);
        if (r < 0 or r >= f.height) continue;
        // The frame's column at x: x = s.x + c - origin, or mirrored x = s.x - 1 - (c - origin).
        const c = if (s.flip_x) s.x - 1 - @as(i32, @intCast(x)) + f.origin_x else @as(i32, @intCast(x)) - s.x + f.origin_x;
        if (c < 0 or c >= f.width) continue;
        const ry: usize = @intCast(if (s.flip_y) f.height - 1 - r else r);
        const v = f.pixels[ry * f.width + @as(usize, @intCast(c))];
        if (v == 0) continue;
        return .{ .index = @as(u8, s.palette) * palettes.size + v, .priority = s.priority };
    }
    return .{};
}

/// The picture's colour index at (x, line), by the rules.
pub fn reference(p: *const Screen, x: usize, line: usize) u8 {
    const b = layerPixel(&p.plane_b, x, line);
    const a = if (p.window.board != null and p.window.lines.has(line))
        boardPixel(p.window.board.?, @intCast(x), @intCast(line))
    else
        layerPixel(&p.plane_a, x, line);
    const s = spritePixel(p, x, line);
    var c = p.backdrop.index();
    // Back to front: B, A and the sprites without priority, then those with it.
    for ([_]bool{ false, true }) |high| for ([_]Px{ b, a, s }) |l| {
        if (l.index != 0 and l.priority == high) c = l.index;
    };
    return c;
}

// Tests -----------------------------------------------------------------------------------------

const testing = std.testing;

/// Synthetic art: tile k is all colour k, except tile 15, whose top-left pixel is 5 and the rest
/// colour 6, and tile 0, transparent but for its top-left pixel (colour 9).
const TestArt = struct {
    tiles: [16]art.Tile,

    fn init() TestArt {
        var t: TestArt = undefined;
        for (&t.tiles, 0..) |*tile, k| @memset(tile, @intCast(k));
        t.tiles[15][0] = 5;
        @memset(t.tiles[15][1..], 6);
        t.tiles[0][0] = 9;
        return t;
    }

    fn map(self: *const TestArt, w: u16, h: u16, cells: []const Cell) art.TileMap {
        return .{ .name = "m", .file = "m.tmj", .width = w, .height = h, .sheets = &.{}, .tiles = &self.tiles, .cells = cells };
    }
};

/// Every pixel of the composition `c` against the rules applied to `p`.
fn expectRules(c: *const Composer, p: *const Screen) !void {
    for (0..height) |line| for (0..width) |x| {
        const want = reference(p, x, line);
        if (c.indices[line * width + x] != want) {
            std.debug.print("pixel ({d}, {d}): {d}, the rules give {d}\n", .{ x, line, c.indices[line * width + x], want });
            return error.TestExpectedEqual;
        }
    };
}

fn composeOnce(p: *const Screen) !*Composer {
    const c = try Composer.create(testing.allocator);
    errdefer c.destroy();
    _ = try c.compose(p);
    try expectRules(c, p);
    return c;
}

fn pixel(c: *const Composer, x: usize, line: usize) u8 {
    return c.indices[line * width + x];
}

test "priority: A over B, a high cell over a low one, sprites between the low and the high" {
    const ta = TestArt.init();
    var bb = try Board.init(testing.allocator, 64, 32);
    defer bb.deinit();
    var ba = try Board.init(testing.allocator, 64, 32);
    defer ba.deinit();
    const cells_b = [_]Cell{ .{ .tile = 1, .palette = 1 }, .{ .tile = 1, .palette = 1, .priority = true }, .{ .tile = 1, .palette = 1 }, .{ .tile = 1, .palette = 1, .priority = true } };
    const cells_a = [_]Cell{ .{ .tile = 2, .palette = 2 }, .{ .tile = 2, .palette = 2 }, .{ .tile = 2, .palette = 2, .priority = true }, .empty };
    const mb = ta.map(4, 1, &cells_b);
    const ma = ta.map(4, 1, &cells_a);
    try bb.drawMap(&mb, 0, 0);
    try ba.drawMap(&ma, 0, 0);
    const frame_pixels: [16 * 8]u8 = @splat(3);
    const f: art.Frame = .{ .name = "f", .file = "f.png", .width = 16, .height = 8, .origin_x = 0, .origin_y = 0, .pixels = &frame_pixels };
    var p: Screen = .{ .plane_b = .{ .board = &bb }, .plane_a = .{ .board = &ba }, .backdrop = .{ .palette = 3, .colour = 4 } };
    const c = try composeOnce(&p);
    defer c.destroy();
    try testing.expectEqual(@as(u8, 34), pixel(c, 0, 0)); // A over B, both low
    try testing.expectEqual(@as(u8, 17), pixel(c, 8, 0)); // B high over A low
    try testing.expectEqual(@as(u8, 34), pixel(c, 16, 0)); // A high over B low
    try testing.expectEqual(@as(u8, 17), pixel(c, 24, 0)); // B high, A empty
    try testing.expectEqual(@as(u8, 52), pixel(c, 32, 0)); // nothing: the backdrop
    // A low sprite over the low cells, under the high ones; a high sprite over all.
    const low = [_]Sprite{ .{ .frame = &f, .x = 0, .y = 0, .palette = 3 }, .{ .frame = &f, .x = 16, .y = 0, .palette = 3 } };
    p.sprites = &low;
    _ = try c.compose(&p);
    try testing.expectEqual(@as(u8, 51), pixel(c, 0, 0));
    try testing.expectEqual(@as(u8, 17), pixel(c, 8, 0));
    try testing.expectEqual(@as(u8, 34), pixel(c, 16, 0));
    try testing.expectEqual(@as(u8, 17), pixel(c, 24, 0));
    const high = [_]Sprite{.{ .frame = &f, .x = 8, .y = 0, .palette = 3, .priority = true }};
    p.sprites = &high;
    _ = try c.compose(&p);
    try testing.expectEqual(@as(u8, 51), pixel(c, 8, 0));
    try testing.expectEqual(@as(u8, 51), pixel(c, 16, 0));
}

test "sprites: a later one covers an earlier one whatever their priorities" {
    const ta = TestArt.init();
    var ba = try Board.init(testing.allocator, 64, 32);
    defer ba.deinit();
    const cells_a = [_]Cell{.{ .tile = 2, .palette = 2, .priority = true }};
    const ma = ta.map(1, 1, &cells_a);
    try ba.drawMap(&ma, 0, 0);
    const px: [8 * 8]u8 = @splat(3);
    const f: art.Frame = .{ .name = "f", .file = "f.png", .width = 8, .height = 8, .origin_x = 0, .origin_y = 0, .pixels = &px };
    // A high sprite first, a low one over it: the low one is in front, and the high cell over it.
    const list = [_]Sprite{ .{ .frame = &f, .x = 0, .y = 0, .palette = 1, .priority = true }, .{ .frame = &f, .x = 4, .y = 0, .palette = 3 } };
    const p: Screen = .{ .plane_a = .{ .board = &ba }, .sprites = &list };
    const c = try composeOnce(&p);
    defer c.destroy();
    try testing.expectEqual(@as(u8, 19), pixel(c, 2, 0));
    try testing.expectEqual(@as(u8, 34), pixel(c, 4, 0));
    try testing.expectEqual(@as(u8, 51), pixel(c, 9, 0));
}

test "flips: cells and sprites, a sprite mirrored about its origin" {
    const ta = TestArt.init();
    var ba = try Board.init(testing.allocator, 64, 32);
    defer ba.deinit();
    const cells = [_]Cell{ .{ .tile = 15 }, .{ .tile = 15, .flip_x = true }, .{ .tile = 15, .flip_y = true }, .{ .tile = 15, .flip_x = true, .flip_y = true } };
    const m = ta.map(4, 1, &cells);
    try ba.drawMap(&m, 0, 0);
    // A frame 5 wide and 3 high, its origin at (1, 2): a different colour per column and row.
    var px: [15]u8 = undefined;
    for (&px, 0..) |*v, i| v.* = @intCast(1 + i % 5 + 5 * (i / 5) % 15);
    const f: art.Frame = .{ .name = "f", .file = "f.png", .width = 5, .height = 3, .origin_x = 1, .origin_y = 2, .pixels = &px };
    const list = [_]Sprite{
        .{ .frame = &f, .x = 100, .y = 50 },
        .{ .frame = &f, .x = 200, .y = 50, .flip_x = true },
        .{ .frame = &f, .x = 100, .y = 100, .flip_y = true },
    };
    const p: Screen = .{ .plane_a = .{ .board = &ba }, .sprites = &list };
    const c = try composeOnce(&p);
    defer c.destroy();
    try testing.expectEqual(@as(u8, 5), pixel(c, 0, 0));
    try testing.expectEqual(@as(u8, 5), pixel(c, 15, 0));
    try testing.expectEqual(@as(u8, 5), pixel(c, 16, 7));
    try testing.expectEqual(@as(u8, 5), pixel(c, 31, 7));
    try testing.expectEqual(@as(u8, 6), pixel(c, 8, 0));
    // Column c of the frame at 100 + c - 1; mirrored at 200 - 1 - (c - 1).
    try testing.expectEqual(px[0], pixel(c, 99, 48));
    try testing.expectEqual(px[4], pixel(c, 103, 48));
    try testing.expectEqual(px[0], pixel(c, 200, 48));
    try testing.expectEqual(px[4], pixel(c, 196, 48));
    try testing.expectEqual(px[10], pixel(c, 99, 50));
    // Flipped down: the bottom row on top.
    try testing.expectEqual(px[10], pixel(c, 99, 98));
    try testing.expectEqual(px[0], pixel(c, 99, 100));
}

test "transparency: colour 0 of a cell or a sprite shows what is behind it" {
    const ta = TestArt.init();
    var bb = try Board.init(testing.allocator, 64, 32);
    defer bb.deinit();
    var ba = try Board.init(testing.allocator, 64, 32);
    defer ba.deinit();
    const cb = [_]Cell{.{ .tile = 7, .palette = 1 }};
    const ca = [_]Cell{.{ .tile = 0, .palette = 2, .priority = true }};
    const mb = ta.map(1, 1, &cb);
    const ma = ta.map(1, 1, &ca);
    try bb.drawMap(&mb, 0, 0);
    try ba.drawMap(&ma, 0, 0);
    var px: [8 * 8]u8 = @splat(0);
    px[9] = 4;
    const f: art.Frame = .{ .name = "f", .file = "f.png", .width = 8, .height = 8, .origin_x = 0, .origin_y = 0, .pixels = &px };
    const list = [_]Sprite{.{ .frame = &f, .x = 0, .y = 0, .palette = 3, .priority = true }};
    const p: Screen = .{ .plane_b = .{ .board = &bb }, .plane_a = .{ .board = &ba }, .sprites = &list };
    const c = try composeOnce(&p);
    defer c.destroy();
    try testing.expectEqual(@as(u8, 32 + 9), pixel(c, 0, 0)); // A's one opaque pixel
    try testing.expectEqual(@as(u8, 16 + 7), pixel(c, 1, 0)); // A's colour 0, high: B shows
    try testing.expectEqual(@as(u8, 48 + 4), pixel(c, 1, 1)); // the sprite's opaque pixel
    try testing.expectEqual(@as(u8, 16 + 7), pixel(c, 2, 1)); // its colour 0
}

test "scroll: the board's pixel at the corner, wrapping past its edges both ways" {
    const ta = TestArt.init();
    var b = try Board.init(testing.allocator, 4, 2);
    defer b.deinit();
    const cells = [_]Cell{ .{ .tile = 1 }, .{ .tile = 2 }, .{ .tile = 3 }, .{ .tile = 4 }, .{ .tile = 5 }, .{ .tile = 6 }, .{ .tile = 7 }, .{ .tile = 15 } };
    const m = ta.map(4, 2, &cells);
    try b.drawMap(&m, 0, 0);
    var p: Screen = .{ .plane_a = .{ .board = &b, .x = 3, .y = 5 } };
    const c = try composeOnce(&p);
    defer c.destroy();
    try testing.expectEqual(@as(u8, 1), pixel(c, 4, 2)); // pixel (7, 7): cell (0, 0)
    try testing.expectEqual(@as(u8, 2), pixel(c, 5, 2)); // pixel (8, 7): cell (1, 0)
    try testing.expectEqual(@as(u8, 5), pixel(c, 4, 3)); // pixel (7, 8): cell (0, 1)
    try testing.expectEqual(@as(u8, 1), pixel(c, 4, 18)); // pixel (7, 23): wrapped to (7, 7)
    try testing.expectEqual(@as(u8, 2), pixel(c, 37, 2)); // pixel (40, 7): wrapped to (8, 7)
    p.plane_a.x = -1;
    p.plane_a.y = -17;
    _ = try c.compose(&p);
    try testing.expectEqual(@as(u8, 6), pixel(c, 31, 0)); // pixel (30, -17): (30, 15) in cell (3, 1)
    try testing.expectEqual(@as(u8, 4), pixel(c, 32, 1)); // pixel (31, -16): (31, 0) in cell (3, 0)
    try testing.expectEqual(@as(u8, 1), pixel(c, 1, 1)); // pixel (0, -16): (0, 0)
    try testing.expectEqual(@as(u8, 5), pixel(c, 25, 25)); // pixel (24, 8): tile 15's top left
    try expectRules(c, &p);
}

/// A board of `w` x `h` cells whose cell (x, y) is tile 1 + (x + 3y) % 14 on palette (x + y) % 4.
fn patterned(ta: *const TestArt, w: u16, h: u16) !Board {
    var b = try Board.init(testing.allocator, w, h);
    errdefer b.deinit();
    const cells = try testing.allocator.alloc(Cell, @as(usize, w) * h);
    defer testing.allocator.free(cells);
    for (cells, 0..) |*c, i| {
        const x = i % w;
        const y = i / w;
        c.* = .{ .tile = @intCast(1 + (x + 3 * y) % 14), .palette = @intCast((x + y) % 4) };
    }
    const m = ta.map(w, h, cells);
    try b.drawMap(&m, 0, 0);
    return b;
}

test "line scroll: each line's own offset; column scroll: each 16-pixel column's" {
    const ta = TestArt.init();
    var b = try patterned(&ta, 64, 32);
    defer b.deinit();
    var line_x: [height]i32 = @splat(0);
    line_x[1] = 3;
    line_x[2] = -500;
    var p: Screen = .{ .plane_b = .{ .board = &b, .x = 500, .y = 3, .line_x = &line_x } };
    const c = try composeOnce(&p);
    defer c.destroy();
    // Line 1 shows the board's row 4 from its pixel 503; line 2 its row 5 from pixel 0.
    try testing.expectEqual(reference(&.{ .plane_b = .{ .board = &b, .x = 503, .y = 3 } }, 0, 1), pixel(c, 0, 1));
    try testing.expectEqual(@as(u8, 1), pixel(c, 0, 2)); // cell (0, 0): tile 1, palette 0
    var column_y: [screen.columns]i32 = @splat(0);
    column_y[1] = 8;
    p = .{ .plane_b = .{ .board = &b, .column_y = &column_y } };
    _ = try c.compose(&p);
    try expectRules(c, &p);
    // Column 1 (x 16 to 31) shows the board a cell lower: cell (2, 1), tile 6 on palette 3.
    try testing.expectEqual(@as(u8, 3 * 16 + 6), pixel(c, 16, 0));
    try testing.expectEqual(@as(u8, 16 + 2), pixel(c, 15, 0)); // cell (1, 0), column 0: tile 2 on palette 1
    // Both at once, scrolled every way.
    for (&line_x, 0..) |*v, line| v.* = @as(i32, @intCast(line % 7)) * 3 - 9;
    for (&column_y, 0..) |*v, k| v.* = @as(i32, @intCast(k)) * 5 - 40;
    p = .{ .plane_b = .{ .board = &b, .x = -7, .y = 1000, .line_x = &line_x, .column_y = &column_y } };
    _ = try c.compose(&p);
    try expectRules(c, &p);
}

test "the window takes plane A's place on its lines only, and does not scroll" {
    const ta = TestArt.init();
    var ba = try patterned(&ta, 64, 32);
    defer ba.deinit();
    var bb = try patterned(&ta, 64, 32);
    defer bb.deinit();
    var bw = try Board.init(testing.allocator, 40, 28);
    defer bw.deinit();
    // The window's first row: cell 0 a tile, cell 1 empty (plane B shows, not plane A).
    const cells = [_]Cell{ .{ .tile = 7, .palette = 3 }, .empty };
    const m = ta.map(2, 1, &cells);
    try bw.drawMap(&m, 0, 0);
    var p: Screen = .{
        .plane_b = .{ .board = &bb, .x = 1, .y = 2 },
        .plane_a = .{ .board = &ba, .x = 300, .y = 40 },
        .window = .{ .board = &bw, .lines = .{ .top = 0, .bottom = 4 } },
    };
    const c = try composeOnce(&p);
    defer c.destroy();
    try testing.expectEqual(@as(u8, 48 + 7), pixel(c, 0, 3));
    try testing.expectEqual(reference(&.{ .plane_b = p.plane_b }, 9, 3), pixel(c, 9, 3));
    // Line 4 is plane A's again.
    try testing.expectEqual(reference(&.{ .plane_b = p.plane_b, .plane_a = p.plane_a }, 0, 4), pixel(c, 0, 4));
    // The window on lines 100 to 131: its rows 12 to 16.
    p.window.lines = .{ .top = 100, .bottom = 132 };
    _ = try c.compose(&p);
    try expectRules(c, &p);
}

test "sprites show only on their lines" {
    const ta = TestArt.init();
    var bb = try patterned(&ta, 64, 32);
    defer bb.deinit();
    const px: [16 * 40]u8 = @splat(2);
    const f: art.Frame = .{ .name = "f", .file = "f.png", .width = 16, .height = 40, .origin_x = 8, .origin_y = 39, .pixels = &px };
    const list = [_]Sprite{
        .{ .frame = &f, .x = 50, .y = 50, .palette = 1, .priority = true },
        .{ .frame = &f, .x = -3, .y = 223, .palette = 1, .flip_x = true },
        .{ .frame = &f, .x = 318, .y = 2, .palette = 2, .flip_y = true },
    };
    const p: Screen = .{ .plane_b = .{ .board = &bb }, .sprites = &list, .sprite_lines = .{ .top = 32, .bottom = height } };
    const c = try composeOnce(&p);
    defer c.destroy();
    try testing.expectEqual(@as(u8, 18), pixel(c, 45, 32));
    try testing.expect(pixel(c, 45, 31) != 18);
}

test "an unchanged picture is not composed again; a changed board, scroll or colour is" {
    const ta = TestArt.init();
    var bb = try patterned(&ta, 64, 32);
    defer bb.deinit();
    var p: Screen = .{ .plane_b = .{ .board = &bb } };
    p.colours[0][1] = .{ .r = 7, .g = 0, .b = 0 };
    const c = try composeOnce(&p);
    defer c.destroy();
    try testing.expect(!try c.compose(&p));
    const cells = [_]Cell{.{ .tile = 9, .palette = 2 }};
    const m = ta.map(1, 1, &cells);
    try bb.drawMap(&m, 0, 0);
    try testing.expect(try c.compose(&p));
    try expectRules(c, &p);
    p.plane_b.y = 1;
    try testing.expect(try c.compose(&p));
    try expectRules(c, &p);
    p.colours[0][1] = .{ .r = 0, .g = 7, .b = 0 };
    try testing.expect(try c.compose(&p));
    try testing.expect(!try c.compose(&p));
}

test "the frame is RGBA at the colours' levels" {
    const ta = TestArt.init();
    var bb = try patterned(&ta, 64, 32);
    defer bb.deinit();
    var p: Screen = .{ .plane_b = .{ .board = &bb }, .backdrop = .{ .palette = 2, .colour = 0 } };
    for (&p.colours, 0..) |*line, i| for (line, 0..) |*col, k| {
        col.* = .{ .r = @intCast(i), .g = @intCast(k % 8), .b = @intCast(k / 2) };
    };
    const c = try composeOnce(&p);
    defer c.destroy();
    const f = c.frame();
    try f.validate();
    for (0..height) |line| for (0..width) |x| {
        const i = pixel(c, x, line);
        const want = palettes.rgba(p.colours[i / 16][i % 16]);
        try testing.expectEqualSlices(u8, &want, f.row(@intCast(line))[x * 4 ..][0..4]);
    };
}

// Random pictures over random boards and frames: sizes, scrolls, flips, priorities, palettes, the
// window on any lines, sprites across the screen's edges; the composition against the rules.
test "the composition equals the rules applied pixel by pixel" {
    var prng = std.Random.DefaultPrng.init(5 * 7 * 11 * 13 * 17 * 19);
    const r = prng.random();
    var tiles: [12]art.Tile = undefined;
    var images: [4][40 * 40]u8 = undefined;
    var frames: [4]art.Frame = undefined;
    const sizes = [_][2]u16{ .{ 64, 32 }, .{ 32, 64 }, .{ 13, 5 }, .{ 40, 28 }, .{ 672, 30 }, .{ 1, 1 } };
    const sprites = try testing.allocator.alloc(Sprite, 100);
    defer testing.allocator.free(sprites);
    var line_x: [height]i32 = undefined;
    var column_y: [screen.columns]i32 = undefined;
    const c = try Composer.create(testing.allocator);
    defer c.destroy();
    for (0..30) |_| {
        for (&tiles) |*t| for (t) |*v| {
            v.* = randomColour(r);
        };
        for (&frames, &images) |*f, *img| {
            for (img) |*v| v.* = randomColour(r);
            const w = r.intRangeAtMost(u16, 1, 40);
            const h = r.intRangeAtMost(u16, 1, 40);
            f.* = .{ .name = "f", .file = "f.png", .width = w, .height = h, .origin_x = r.intRangeAtMost(i16, -20, 60), .origin_y = r.intRangeAtMost(i16, -20, 60), .pixels = img[0 .. @as(usize, w) * h] };
        }
        var boards: [3]Board = undefined;
        for (&boards, 0..) |*b, k| {
            errdefer for (boards[0..k]) |*done| done.deinit();
            const size = sizes[r.uintLessThan(usize, sizes.len)];
            b.* = try Board.init(testing.allocator, size[0], size[1]);
            errdefer b.deinit();
            const cells = try testing.allocator.alloc(Cell, @as(usize, size[0]) * size[1]);
            defer testing.allocator.free(cells);
            for (cells) |*cl| {
                cl.* = if (r.uintLessThan(u8, 8) == 0) .empty else .{ .tile = r.uintLessThan(u16, tiles.len), .palette = r.int(u2), .flip_x = r.boolean(), .flip_y = r.boolean(), .priority = r.boolean() };
            }
            const m: art.TileMap = .{ .name = "m", .file = "m.tmj", .width = size[0], .height = size[1], .sheets = &.{}, .tiles = &tiles, .cells = cells };
            try b.drawMap(&m, 0, 0);
        }
        defer for (&boards) |*b| b.deinit();
        for (&line_x) |*v| v.* = r.intRangeAtMost(i32, -1000, 1000);
        for (&column_y) |*v| v.* = r.intRangeAtMost(i32, -1000, 1000);
        for (sprites) |*s| s.* = .{
            .frame = &frames[r.uintLessThan(usize, frames.len)],
            .x = r.intRangeAtMost(i32, -80, 400),
            .y = r.intRangeAtMost(i32, -80, 300),
            .flip_x = r.boolean(),
            .flip_y = r.boolean(),
            .palette = r.int(u2),
            .priority = r.boolean(),
        };
        const lines = [2]u16{ r.uintAtMost(u16, 240), r.uintAtMost(u16, 240) };
        const sprite_lines = [2]u16{ r.uintAtMost(u16, 240), r.uintAtMost(u16, 240) };
        const p: Screen = .{
            .plane_b = randomLayer(r, &boards[0], &line_x, &column_y),
            .plane_a = randomLayer(r, &boards[1], &line_x, &column_y),
            .window = .{ .board = if (r.boolean()) &boards[2] else null, .lines = .{ .top = @min(lines[0], lines[1]), .bottom = @max(lines[0], lines[1]) } },
            .sprites = sprites[0..r.uintAtMost(usize, sprites.len)],
            .sprite_lines = .{ .top = @min(sprite_lines[0], sprite_lines[1]), .bottom = @max(sprite_lines[0], sprite_lines[1]) },
            .backdrop = .{ .palette = r.int(u2), .colour = r.int(u4) },
        };
        _ = try c.compose(&p);
        try expectRules(c, &p);
    }
}

fn randomColour(r: std.Random) u8 {
    return if (r.uintLessThan(u8, 3) == 0) 0 else r.uintLessThan(u8, 16);
}

fn randomLayer(r: std.Random, b: *const Board, line_x: *const [height]i32, column_y: *const [screen.columns]i32) Layer {
    return .{
        .board = if (r.uintLessThan(u8, 6) == 0) null else b,
        .x = r.intRangeAtMost(i32, -5000, 5000),
        .y = r.intRangeAtMost(i32, -5000, 5000),
        .line_x = if (r.boolean()) line_x else null,
        .column_y = if (r.boolean()) column_y else null,
    };
}

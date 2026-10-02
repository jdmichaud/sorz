//! The scenes' picture (DESIGN.md 10.5): the renderer's description of a frame (`render.Screen`),
//! the boards its layers show, the sprites, the frames and tiles the game makes, and the composer
//! that turns them into the frame the platform presents. It is the presentation, not the game's
//! state: a scene draws its state here (scene.zig), and the boards keep what was drawn, so that a
//! tick draws only what changed. A new scene starts a new picture (`begin`).
const std = @import("std");
const platform = @import("platform.zig");
const render = @import("render/root.zig");
const art = @import("content/art.zig");
const Text = @import("library.zig").Text;

pub const width = render.width;
pub const height = render.height;

/// The layers whose boards a scene draws on.
pub const Plane = enum { a, b, window };

/// A board's size in cells.
pub const Size = struct { width: u16, height: u16 };

/// The boards a scene's picture needs: a layer without a size has no board (it is transparent).
pub const Layout = struct {
    a: ?Size = null,
    b: ?Size = null,
    window: ?Size = null,
};

pub const View = struct {
    gpa: std.mem.Allocator,
    composer: *render.Composer,
    screen: render.Screen = .{},
    /// Each its own allocation, so that the screen's layers keep pointing at them.
    boards: std.EnumArray(Plane, ?*render.Board) = .initFill(null),
    sprites: std.ArrayList(render.Sprite) = .empty,
    /// Frames the game makes (a font's glyph shown as a sprite), kept for as long as the picture.
    made_frames: std.ArrayList(*art.Frame) = .empty,
    /// Tiles the game makes (a picture drawn a part at a time), kept for as long as the picture.
    made_tiles: std.ArrayList(*art.Tile) = .empty,
    /// The scene whose drawing the boards hold (its number, `scene.Stack.serial`); null: none, the
    /// next scene draws whole.
    shows: ?u32 = null,

    pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!View {
        return .{ .gpa = gpa, .composer = try render.Composer.create(gpa) };
    }

    pub fn deinit(self: *View) void {
        self.forget();
        var it = self.boards.iterator();
        while (it.next()) |e| if (e.value.*) |b| self.destroyBoard(b);
        self.sprites.deinit(self.gpa);
        self.made_frames.deinit(self.gpa);
        self.made_tiles.deinit(self.gpa);
        self.composer.destroy();
        self.* = undefined;
    }

    fn forget(self: *View) void {
        for (self.made_frames.items) |f| self.gpa.destroy(f);
        self.made_frames.clearRetainingCapacity();
        for (self.made_tiles.items) |t| self.gpa.destroy(t);
        self.made_tiles.clearRetainingCapacity();
    }

    /// Starts the picture of scene `serial`: the boards of `layout`, empty, at no scroll; no
    /// sprite; every colour black. A board of the same size is cleared rather than made again.
    pub fn begin(self: *View, serial: u32, layout: Layout) error{OutOfMemory}!void {
        self.forget();
        self.sprites.clearRetainingCapacity();
        inline for (.{ .a, .b, .window }) |p| {
            const want: ?Size = @field(layout, @tagName(p));
            const slot = self.boards.getPtr(p);
            if (slot.*) |b| {
                if (want != null and b.width == want.?.width and b.height == want.?.height) {
                    b.clear();
                } else {
                    self.destroyBoard(b);
                    slot.* = null;
                }
            }
            if (want) |size| if (slot.* == null) {
                const b = try self.gpa.create(render.Board);
                errdefer self.gpa.destroy(b);
                b.* = try render.Board.init(self.gpa, size.width, size.height);
                slot.* = b;
            };
        }
        self.screen = .{
            .plane_a = .{ .board = self.boardOrNull(.a) },
            .plane_b = .{ .board = self.boardOrNull(.b) },
            .window = .{ .board = self.boardOrNull(.window) },
        };
        self.shows = serial;
    }

    fn boardOrNull(self: *View, p: Plane) ?*const render.Board {
        return self.boards.get(p);
    }

    fn destroyBoard(self: *View, b: *render.Board) void {
        b.deinit();
        self.gpa.destroy(b);
    }

    /// The board of `p`, which the scene's layout has.
    pub fn board(self: *View, p: Plane) *render.Board {
        return self.boards.get(p).?;
    }

    /// Writes `text` with the font of `t` at cell (x, y) of `p`'s board.
    pub fn write(self: *View, p: Plane, t: Text, x: i32, y: i32, text: []const u8, look: render.Look) render.Board.Error!void {
        try self.board(p).write(t.sheet, t.font, x, y, text, look);
    }

    /// A frame of one tile of a font, its glyph for `glyph` (an arrow shown as a sprite), with
    /// its origin at its top-left corner; it lives as long as the picture.
    pub fn glyphFrame(self: *View, t: Text, glyph: []const u8) error{ OutOfMemory, NoGlyph }!*const art.Frame {
        const g = t.font.glyphAt(glyph) orelse return error.NoGlyph;
        if (g.len != glyph.len) return error.NoGlyph;
        const f = try self.gpa.create(art.Frame);
        errdefer self.gpa.destroy(f);
        f.* = .{ .name = "glyph", .file = "", .width = art.tile_side, .height = art.tile_side, .origin_x = 0, .origin_y = 0, .pixels = &t.sheet.tiles[g.tile] };
        try self.made_frames.append(self.gpa, f);
        return f;
    }

    /// A tile the game makes, blank, which lives as long as the picture.
    pub fn makeTile(self: *View) error{OutOfMemory}!*art.Tile {
        const t = try self.gpa.create(art.Tile);
        errdefer self.gpa.destroy(t);
        t.* = @splat(0);
        try self.made_tiles.append(self.gpa, t);
        return t;
    }

    /// Composes the picture: the sprites given since the last `clearSprites`, the colours, the
    /// layers. Returns the frame to present.
    pub fn compose(self: *View) error{OutOfMemory}!platform.RgbaFrame {
        self.screen.sprites = self.sprites.items;
        _ = try self.composer.compose(&self.screen);
        return self.composer.frame();
    }

    /// The last frame composed.
    pub fn frame(self: *const View) platform.RgbaFrame {
        return self.composer.frame();
    }
};

const testing = std.testing;

test "a picture begins with its boards empty and black, and composes its texts" {
    var v = try View.init(testing.allocator);
    defer v.deinit();
    try v.begin(1, .{ .a = .{ .width = 64, .height = 32 } });
    try testing.expect(v.screen.plane_b.board == null and v.screen.plane_a.board != null);
    const tiles = [_]art.Tile{ @splat(0), @splat(3) };
    const sheet: art.TileSheet = .{ .name = "main", .file = "main.png", .tiles = &tiles };
    const glyphs = [_]art.Glyph{ .{ .text = " ", .tile = 0 }, .{ .text = "A", .tile = 1 } };
    const font: art.Font = .{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs };
    const t: Text = .{ .font = &font, .sheet = &sheet };
    try v.write(.a, t, 2, 1, "A A", .{ .palette = 1 });
    v.screen.colours[1][3] = .{ .r = 7, .g = 0, .b = 0 };
    const f = try v.compose();
    // Cell (2, 1): red; cell (3, 1): the backdrop, black.
    const px = f.pixels[(8 * f.width + 16) * 4 ..][0..4];
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, px);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, f.pixels[(8 * f.width + 24) * 4 ..][0..4]);
    // A glyph as a sprite, and a made tile; the next picture forgets them and keeps its board.
    const arrow = try v.glyphFrame(t, "A");
    try v.sprites.append(testing.allocator, render.Sprite.of(arrow, 100, 100));
    _ = try v.makeTile();
    const kept = v.board(.a);
    try v.begin(2, .{ .a = .{ .width = 64, .height = 32 } });
    try testing.expect(v.board(.a) == kept and v.board(.a).cell(2, 1).isEmpty());
    try testing.expectEqual(@as(usize, 0), v.sprites.items.len + v.made_frames.items.len + v.made_tiles.items.len);
    try testing.expectEqual(@as(?u32, 2), v.shows);
    try testing.expectError(error.NoGlyph, v.glyphFrame(t, "B"));
}

//! The game's art as typed data, by name (docs/content.md): palettes, tile sheets, tile maps,
//! sprite frames and fonts, grouped in art sets. A set is a directory of the content tree, a
//! screen, a round, a character or the art a group of them shares; an asset's name is its set's
//! name, a slash and its own ("title/logo", "round1/plane_a", "axel/012").
//!
//! The model knows nothing of where the original kept its data: each asset carries a provenance,
//! a text the extractor writes for the reader and that no code interprets.
const std = @import("std");

/// A colour of the console's 512: 3 bits of red, green and blue.
pub const Colour = struct {
    r: u3,
    g: u3,
    b: u3,

    pub const black: Colour = .{ .r = 0, .g = 0, .b = 0 };

    pub fn eql(a: Colour, b: Colour) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    /// The 8-bit channels a picture file shows the colour with (each level times 255 / 7).
    pub fn rgb(c: Colour) [3]u8 {
        return .{ level(c.r), level(c.g), level(c.b) };
    }

    /// The nearest colour to 8-bit channels (the inverse of `rgb` on its values).
    pub fn fromRgb(v: [3]u8) Colour {
        return .{ .r = nearest(v[0]), .g = nearest(v[1]), .b = nearest(v[2]) };
    }

    fn level(x: u3) u8 {
        return @intCast((@as(u16, x) * 255 + 3) / 7);
    }

    fn nearest(x: u8) u3 {
        return @intCast((@as(u16, x) * 7 + 127) / 255);
    }
};

/// The renderer's four palettes of 16 colours (DESIGN.md 10.5); colour 0 of each is transparent
/// where a layer or a sprite is drawn.
pub const palette_count = 4;
pub const palette_size = 16;

/// The colours an asset gives the renderer's palettes: for each of the four, 16 colours or null
/// where the colour is left as it is. A screen applies several in turn.
pub const Palette = struct {
    name: []const u8,
    provenance: []const u8 = "",
    colours: [palette_count][palette_size]?Colour = @splat(@splat(null)),

    /// Whether the asset gives palette `p` any colour.
    pub fn touches(self: *const Palette, p: usize) bool {
        for (self.colours[p]) |c| if (c != null) return true;
        return false;
    }

    /// Applies the asset to `dst`: each colour it gives replaces the one there.
    pub fn apply(self: *const Palette, dst: *[palette_count][palette_size]Colour) void {
        for (self.colours, 0..) |line, p| for (line, 0..) |c, i| {
            if (c) |colour| dst[p][i] = colour;
        };
    }
};

/// An 8x8 tile: 64 colour indices 0-15, row by row; index 0 is transparent.
pub const Tile = [64]u8;

pub const tile_side = 8;

/// A sheet of tiles, in order.
pub const TileSheet = struct {
    name: []const u8,
    provenance: []const u8 = "",
    /// The picture file, relative to the set's directory.
    file: []const u8,
    tiles: []const Tile,
    /// The colours the picture file shows the tiles with, for a reader; the game draws them
    /// with the palettes a screen loads.
    view: [palette_size]Colour = grey,
};

/// A grey ramp, the view of art no palette is known for.
pub const grey: [palette_size]Colour = blk: {
    var g: [palette_size]Colour = undefined;
    for (&g, 0..) |*c, i| {
        const v: u3 = @intCast(i / 2);
        c.* = .{ .r = v, .g = v, .b = v };
    }
    break :blk g;
};

/// A cell of a tile map: a tile of the map's sheets, the palette it is drawn with, its flips and
/// its priority (a high-priority cell is drawn over the low-priority sprites).
pub const Cell = packed struct(u32) {
    /// The tile, numbered across the map's sheets in order; `no_tile` for an empty cell.
    tile: u16 = no_tile,
    palette: u2 = 0,
    flip_x: bool = false,
    flip_y: bool = false,
    priority: bool = false,
    _: u11 = 0,

    pub const no_tile: u16 = std.math.maxInt(u16);
    pub const empty: Cell = .{};

    pub fn isEmpty(c: Cell) bool {
        return c.tile == no_tile;
    }
};

/// The layers a screen draws tile maps on (DESIGN.md 10.5): the two scrolling layers, A in front
/// of B, and the fixed window that holds the status bar.
pub const Layer = enum { plane_a, plane_b, window };

/// Where the original draws a map: a layer, and the cell of the layer its top-left cell goes to.
pub const Place = struct { layer: Layer, x: u16, y: u16 };

/// A rectangle of cells over tile sheets.
pub const TileMap = struct {
    name: []const u8,
    provenance: []const u8 = "",
    /// The map file, relative to the set's directory.
    file: []const u8,
    width: u16,
    height: u16,
    /// The full names of the sheets the cells draw from, in order.
    sheets: []const []const u8,
    /// The sheets' tiles one after the other, which `Cell.tile` numbers (filled by the loader).
    tiles: []const Tile = &.{},
    /// `width` * `height` cells, row by row.
    cells: []const Cell,
    place: ?Place = null,

    pub fn cell(self: *const TileMap, x: usize, y: usize) Cell {
        return self.cells[y * self.width + x];
    }
};

/// One hardware sprite of a frame as the original drew it: its top-left corner relative to the
/// frame's origin, and its size in cells (1 to 4). The renderer draws the frame's picture; the
/// pieces say how the original split it (the sprite limits, not reproduced: decision D4).
pub const Piece = struct { x: i16, y: i16, width: u8, height: u8 };

/// A sprite frame: one picture, drawn with one palette and one priority, placed by its origin
/// (the point of the entity's position) and mirrored about it (column c to -1 - c).
pub const Frame = struct {
    name: []const u8,
    provenance: []const u8 = "",
    file: []const u8,
    width: u16,
    height: u16,
    /// The entity's position in the picture, in pixels from its top-left corner.
    origin_x: i16,
    origin_y: i16,
    /// `width` * `height` colour indices 0-15, row by row; 0 is transparent.
    pixels: []const u8,
    /// The frame's own palette and priority (an entity may add its own to the palette).
    palette: u2 = 0,
    priority: bool = false,
    pieces: []const Piece = &.{},
    view: [palette_size]Colour = grey,
};

/// A glyph of a font: its text and the tile of the font's sheet that draws it.
pub const Glyph = struct { text: []const u8, tile: u16 };

pub const Font = struct {
    name: []const u8,
    provenance: []const u8 = "",
    /// The full name of the sheet the glyphs are tiles of.
    sheet: []const u8,
    glyphs: []const Glyph,

    /// The tile of the longest glyph `text` starts with, and its length; null when none does.
    pub fn glyphAt(self: *const Font, text: []const u8) ?struct { tile: u16, len: usize } {
        var best: ?Glyph = null;
        for (self.glyphs) |g| {
            if (std.mem.startsWith(u8, text, g.text) and (best == null or g.text.len > best.?.text.len)) best = g;
        }
        const g = best orelse return null;
        return .{ .tile = g.tile, .len = g.text.len };
    }
};

/// A directory of the tree: a screen's, a round's, a character's or a shared group's art, and
/// the other sets a screen draws with (`uses`).
pub const ArtSet = struct {
    name: []const u8,
    provenance: []const u8 = "",
    uses: []const []const u8 = &.{},
    palettes: []const Palette = &.{},
    sheets: []const TileSheet = &.{},
    maps: []const TileMap = &.{},
    frames: []const Frame = &.{},
    fonts: []const Font = &.{},
};

/// The game's art: its sets, and the assets by full name.
pub const Art = struct {
    sets: []const ArtSet,

    fn find(comptime T: type, comptime field: []const u8, sets: []const ArtSet, name: []const u8) ?*const T {
        const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return null;
        for (sets) |*s| {
            if (!std.mem.eql(u8, s.name, name[0..slash])) continue;
            for (@field(s, field)) |*a| {
                if (std.mem.eql(u8, a.name, name[slash + 1 ..])) return a;
            }
        }
        return null;
    }

    pub fn set(self: *const Art, name: []const u8) ?*const ArtSet {
        for (self.sets) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }
    pub fn palette(self: *const Art, name: []const u8) ?*const Palette {
        return find(Palette, "palettes", self.sets, name);
    }
    pub fn sheet(self: *const Art, name: []const u8) ?*const TileSheet {
        return find(TileSheet, "sheets", self.sets, name);
    }
    pub fn map(self: *const Art, name: []const u8) ?*const TileMap {
        return find(TileMap, "maps", self.sets, name);
    }
    pub fn frame(self: *const Art, name: []const u8) ?*const Frame {
        return find(Frame, "frames", self.sets, name);
    }
    pub fn font(self: *const Art, name: []const u8) ?*const Font {
        return find(Font, "fonts", self.sets, name);
    }
};

/// An asset's or a set's own name: 1 to 64 of `a-z`, `0-9` and `_`; a set's name may have
/// several such components separated by `/`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

pub fn validSetName(name: []const u8) bool {
    if (name.len == 0 or name.len > 96) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| if (!validName(part)) return false;
    return true;
}

test "colours convert to 8-bit channels and back" {
    for (0..8) |v| {
        const c: Colour = .{ .r = @intCast(v), .g = 0, .b = @intCast(7 - v) };
        try std.testing.expect(Colour.fromRgb(c.rgb()).eql(c));
    }
    try std.testing.expectEqual([3]u8{ 0, 0, 255 }, (Colour{ .r = 0, .g = 0, .b = 7 }).rgb());
}

test "a palette applies only the colours it gives" {
    var p: Palette = .{ .name = "x" };
    p.colours[2][1] = .{ .r = 7, .g = 0, .b = 0 };
    var dst: [palette_count][palette_size]Colour = @splat(@splat(Colour.black));
    dst[2][2] = .{ .r = 1, .g = 1, .b = 1 };
    p.apply(&dst);
    try std.testing.expect(dst[2][1].eql(.{ .r = 7, .g = 0, .b = 0 }));
    try std.testing.expect(dst[2][2].eql(.{ .r = 1, .g = 1, .b = 1 }));
    try std.testing.expect(p.touches(2) and !p.touches(0));
}

test "assets are found by their full name" {
    const sheets = [_]TileSheet{.{ .name = "logo", .file = "logo.png", .tiles = &.{} }};
    const glyphs = [_]Glyph{ .{ .text = "-", .tile = 38 }, .{ .text = "->", .tile = 39 } };
    const fonts = [_]Font{.{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs }};
    const sets = [_]ArtSet{ .{ .name = "title", .sheets = &sheets }, .{ .name = "fonts", .fonts = &fonts } };
    const art: Art = .{ .sets = &sets };
    try std.testing.expect(art.sheet("title/logo") != null);
    try std.testing.expect(art.sheet("title/city") == null);
    try std.testing.expect(art.sheet("logo") == null);
    try std.testing.expect(art.map("title/logo") == null);
    const f = art.font("fonts/main").?;
    try std.testing.expectEqual(@as(u16, 39), f.glyphAt("->A").?.tile);
    try std.testing.expectEqual(@as(u16, 38), f.glyphAt("-A").?.tile);
    try std.testing.expect(f.glyphAt("A") == null);
}

test "names" {
    try std.testing.expect(validName("plane_a") and validName("012"));
    try std.testing.expect(!validName("Plane") and !validName("a-b") and !validName("") and !validName("a/b"));
    try std.testing.expect(validSetName("rounds/round1") and !validSetName("a//b") and !validSetName("/a"));
}

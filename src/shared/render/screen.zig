//! A frame's description (DESIGN.md 10.5, R1): what the screen shows, in the game's terms. Two
//! scrolling layers of tiles (plane B at the back, plane A in front), each a board seen from a
//! scroll position, with an optional scroll per line and per column; the window, a fixed layer
//! that takes plane A's place on a range of lines (the status bar); sprites, each a frame of the
//! content at a position; the four palettes' colours and the backdrop's.
//!
//! The rules are the console's, so that the pictures can equal the original's (R3):
//! - pixels of colour 0 are transparent, wherever they are;
//! - back to front: plane B, plane A (or the window), the sprites, each first for its pixels
//!   without priority, then again for those with it: a cell or a sprite with priority is in front
//!   of everything without it;
//! - among the sprites, one given later covers one given earlier, whatever their priorities; the
//!   pixel in front then takes its priority against the layers.
const std = @import("std");
const art = @import("../content/art.zig");
const palettes = @import("palettes.zig");
const picture = @import("../picture.zig");
const Board = @import("board.zig").Board;

/// The screen's size in pixels: the picture the game presents (picture.zig).
pub const width = 320;
pub const height = 224;

comptime {
    std.debug.assert(width == picture.width and height == picture.height);
}
/// A cell's side in pixels.
pub const cell = art.tile_side;
/// The columns a per-column scroll moves: 16 pixels wide each.
pub const column_width = 16;
pub const columns = width / column_width;

/// A scrolling layer: its board seen through the screen, repeated past the board's edges.
pub const Layer = struct {
    /// The cells it shows; none: the layer is transparent.
    board: ?*const Board = null,
    /// The board's pixel at the screen's top-left corner.
    x: i32 = 0,
    y: i32 = 0,
    /// Per line of the screen, added to `x` (bands that scroll at their own speed, waves).
    line_x: ?*const [height]i32 = null,
    /// Per 16-pixel column of the screen, added to `y`.
    column_y: ?*const [columns]i32 = null,
};

/// Lines of the screen, from `top` to before `bottom`.
pub const Lines = struct {
    top: u16 = 0,
    bottom: u16 = 0,

    pub const all: Lines = .{ .top = 0, .bottom = height };

    pub fn has(self: Lines, line: usize) bool {
        return line >= self.top and line < self.bottom;
    }
};

/// The fixed layer: its board does not scroll (its cell (x, y) is on the screen's cell (x, y)),
/// and it shows on its lines in place of plane A.
pub const Window = struct {
    board: ?*const Board = null,
    lines: Lines = .{},
};

/// A sprite: a frame of the content with its origin at (x, y) on the screen, mirrored about the
/// origin (column c of the frame to -1 - c), drawn with a palette and a priority. A frame the game
/// makes (a tile shown as a sprite) keeps its pixels while it is shown: a new picture is a new
/// frame.
pub const Sprite = struct {
    frame: *const art.Frame,
    x: i32,
    y: i32,
    flip_x: bool = false,
    flip_y: bool = false,
    palette: u2 = 0,
    priority: bool = false,

    /// The frame drawn with its own palette and priority.
    pub fn of(frame: *const art.Frame, x: i32, y: i32) Sprite {
        return .{ .frame = frame, .x = x, .y = y, .palette = frame.palette, .priority = frame.priority };
    }
};

/// A colour of the palettes: palette `palette`'s colour `colour`.
pub const ColourIndex = struct {
    palette: u2 = 0,
    colour: u4 = 0,

    pub fn index(c: ColourIndex) u8 {
        return @as(u8, c.palette) * palettes.size + c.colour;
    }
};

/// What the screen shows at a frame.
pub const Screen = struct {
    plane_b: Layer = .{},
    plane_a: Layer = .{},
    window: Window = .{},
    /// Back to front: each is drawn over those before it.
    sprites: []const Sprite = &.{},
    /// The lines the sprites show on: in play, none shows over the status bar.
    sprite_lines: Lines = Lines.all,
    /// The four palettes' colours, as shown.
    colours: palettes.Colours = palettes.black,
    /// The colour where every layer and sprite is transparent.
    backdrop: ColourIndex = .{},
};

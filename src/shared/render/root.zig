//! The renderer (DESIGN.md 10.5): a frame's description in the game's terms (`Screen`: two
//! scrolling layers, the window, sprites, the palettes' colours), the boards the layers show,
//! the palettes with their fades and cycles, and the composition into the RGBA frame the
//! platform presents.
pub const screen = @import("screen.zig");
pub const board = @import("board.zig");
pub const palettes = @import("palettes.zig");
pub const compose = @import("compose.zig");

pub const Screen = screen.Screen;
pub const Layer = screen.Layer;
pub const Window = screen.Window;
pub const Sprite = screen.Sprite;
pub const Lines = screen.Lines;
pub const Board = board.Board;
pub const Look = board.Look;
pub const Palettes = palettes.Palettes;
pub const Fade = palettes.Fade;
pub const CycleRun = palettes.CycleRun;
pub const Composer = compose.Composer;
pub const width = screen.width;
pub const height = screen.height;

test {
    @import("std").testing.refAllDecls(@This());
}

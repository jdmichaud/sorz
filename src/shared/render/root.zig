//! The renderer (DESIGN.md 10.5): the boards the layers show, and the palettes with their fades
//! and cycles.
pub const board = @import("board.zig");
pub const palettes = @import("palettes.zig");

pub const Board = board.Board;
pub const Look = board.Look;
pub const Palettes = palettes.Palettes;
pub const Fade = palettes.Fade;
pub const CycleRun = palettes.CycleRun;

test {
    @import("std").testing.refAllDecls(@This());
}

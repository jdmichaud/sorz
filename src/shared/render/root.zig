//! The renderer (DESIGN.md 10.5): the palettes with their fades and cycles.
pub const palettes = @import("palettes.zig");

pub const Palettes = palettes.Palettes;
pub const Fade = palettes.Fade;
pub const CycleRun = palettes.CycleRun;

test {
    @import("std").testing.refAllDecls(@This());
}

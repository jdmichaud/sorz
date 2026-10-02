//! The game's sound (DESIGN.md 10.6): the chip models that turn register writes into PCM.
pub const chips = @import("chips/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

//! The game's sound (DESIGN.md 10.6): the sound content (songs, effects, samples and the names
//! the game asks for), its files, and the chip models that turn register writes into PCM.
pub const chips = @import("chips/root.zig");
pub const content = @import("content.zig");
pub const notation = @import("notation.zig");
pub const files = @import("files.zig");
pub const wav = @import("wav.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

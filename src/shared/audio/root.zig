//! The game's sound (DESIGN.md 10.6): the sound content (songs, effects, samples and the names
//! the game asks for) and its files, the sequencer that plays it with the original driver's
//! semantics, and the output stage and chip models that turn its writes into PCM.
pub const chips = @import("chips/root.zig");
pub const content = @import("content.zig");
pub const notation = @import("notation.zig");
pub const files = @import("files.zig");
pub const wav = @import("wav.zig");
pub const clock = @import("clock.zig");
pub const sequencer = @import("sequencer.zig");
pub const Sequencer = sequencer.Sequencer;
pub const output = @import("output.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

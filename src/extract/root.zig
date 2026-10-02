//! The extractor: the one place that reads the user's ROM, by address, as a parser of its
//! formats (DESIGN.md P1, C1). It checks the ROM's digest and writes the content tree that the
//! game loads (docs/content.md), a module per kind of content.
pub const rom = @import("rom.zig");
pub const kosinski = @import("kosinski.zig");
pub const nemesis = @import("nemesis.zig");
pub const enigma = @import("enigma.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

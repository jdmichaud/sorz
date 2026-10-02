//! Network play (DESIGN.md 9): the in-memory transport. None of it is part of the simulation.
pub const memory = @import("memory.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

//! Network play (DESIGN.md 9): the in-memory transport, the session protocol and the netplay
//! driver that the game takes its pads from. None of it is part of the simulation.
pub const memory = @import("memory.zig");
pub const protocol = @import("protocol.zig");
pub const identity = @import("identity.zig");
pub const session = @import("session.zig");
pub const Session = session.Session;
pub const netplay = @import("netplay.zig");
pub const Netplay = netplay.Netplay;

test {
    @import("std").testing.refAllDecls(@This());
}

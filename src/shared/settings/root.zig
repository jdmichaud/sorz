//! The port's settings (DESIGN.md 7): the record (`record.zig`) and the screen that changes it in
//! the game (`screen.zig`), an overlay over the game's scenes (DESIGN.md 10.4 S3, game.zig).
pub const record = @import("record.zig");
pub const screen = @import("screen.zig");
pub const net_screens = @import("net_screens.zig");
pub const Settings = record.Settings;

test {
    @import("std").testing.refAllDecls(@This());
}

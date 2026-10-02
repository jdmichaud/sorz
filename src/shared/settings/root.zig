//! The port's settings (DESIGN.md 7): the record (`record.zig`). The screen that changes it is a
//! scene of the game (DESIGN.md 10.4, PLAN item 19).
pub const record = @import("record.zig");
pub const Settings = record.Settings;

test {
    @import("std").testing.refAllDecls(@This());
}

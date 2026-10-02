//! The parts of the browser build that run without a browser: the key table, the gamepads'
//! mapping, the storage, the backend over a table of page functions, and the settings as the page
//! applies them. The unit tests build them for the native target; `main.zig` builds them into the
//! WebAssembly module.
pub const keys = @import("keys.zig");
pub const gamepad = @import("gamepad.zig");
pub const host = @import("host.zig");
pub const backend = @import("backend.zig");
pub const storage = @import("storage.zig");
pub const settings = @import("settings.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

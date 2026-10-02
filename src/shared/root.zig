//! The shared module: the platform boundary, the in-memory providers and the game. It links
//! nothing and needs no libc, so the same code builds for the native hosts and for the browser
//! (wasm32-freestanding).
pub const platform = @import("platform.zig");
pub const memory = @import("memory.zig");
pub const version = @import("version.zig");
pub const formats = @import("formats/root.zig");
pub const content = @import("content/root.zig");
pub const game = @import("game.zig");
pub const Game = game.Game;
pub const net = @import("net/root.zig");
pub const input = @import("input.zig");
pub const settings = @import("settings/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

//! The shared module: the platform boundary, the in-memory providers and the game. It links
//! nothing and needs no libc, so the same code builds for the native hosts and for the browser
//! (wasm32-freestanding).
pub const platform = @import("platform.zig");
pub const memory = @import("memory.zig");
pub const version = @import("version.zig");
pub const formats = @import("formats/root.zig");
pub const content = @import("content/root.zig");
pub const render = @import("render/root.zig");
pub const game = @import("game.zig");
pub const Game = game.Game;
pub const canonical = @import("canonical.zig");
pub const scene = @import("scene.zig");
pub const flow = @import("flow.zig");
pub const library = @import("library.zig");
pub const view = @import("view.zig");
pub const setup = @import("setup.zig");
pub const screens = struct {
    pub const colours = @import("screens/colours.zig");
    pub const sega_logo = @import("screens/sega_logo.zig");
    pub const half_colours = @import("screens/half_colours.zig");
    pub const title = @import("screens/title.zig");
};
pub const picture = @import("picture.zig");
pub const sound_out = @import("sound_out.zig");
pub const net = @import("net/root.zig");
pub const input = @import("input.zig");
pub const settings = @import("settings/root.zig");
pub const audio = @import("audio/root.zig");
pub const world = @import("world/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

//! A load (DESIGN.md 10.2, T4): where the original stopped its picture to set up the next screen,
//! the screen stays dark for the wait it measured, over the new scene, which waits too. The
//! original's loads also hold its sound's driver (the music holds its notes) and read no pad, and
//! the game does the same.
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const render = @import("../render/root.zig");
const view = @import("../view.zig");

pub const Load = struct {
    /// The display ticks left.
    left: u16 = 0,
    /// Whether the sound's driver waits too.
    sound_held: bool = true,

    pub const Assets = struct {
        pub const names = .{};
    };
    pub const layout: view.Layout = .{};

    pub fn tick(self: *Load, turn: *scene.Turn, _: *const Assets) ?flow.Exit {
        if (self.sound_held) turn.sound_driver = false;
        turn.read_pads = false;
        self.left -|= 1;
        return null;
    }

    /// The dark screen: no layer, every colour black.
    pub fn draw(_: *const Load, _: ?*const Load, v: *view.View, _: *const Assets) !void {
        v.screen.colours = render.palettes.black;
        v.screen.backdrop = .{};
    }
};

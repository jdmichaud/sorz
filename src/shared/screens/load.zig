//! A load (DESIGN.md 10.2, T4): where the original stopped its picture to set up the next screen,
//! the screen stays dark for the wait it measured, then the next scene begins. The original's
//! loads also hold its sound's driver (the music holds its notes), and the game does the same.
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const View = @import("../view.zig").View;

pub const Load = struct {
    /// The scene it is for.
    next: flow.Kind = .sega_logo,
    /// The display ticks left.
    left: u16 = 0,
    /// Whether the sound's driver waits too.
    sound_held: bool = true,

    pub const Assets = struct {
        pub const names = .{};
    };
    pub const layout: @import("../view.zig").Layout = .{};

    pub fn tick(self: *Load, turn: *scene.Turn, _: *const Assets) ?flow.Exit {
        if (self.sound_held) turn.sound_driver = false;
        if (self.left > 1) {
            self.left -= 1;
            return null;
        }
        return .done;
    }

    /// The dark screen: no layer, every colour black.
    pub fn draw(_: *const Load, _: ?*const Load, v: *View, _: *const Assets) !void {
        v.screen.colours = @import("../render/root.zig").palettes.black;
        v.screen.backdrop = .{};
    }
};

//! A load (DESIGN.md 10.2, T4): where the original stopped its picture to set up the next screen,
//! the screen stays dark for the wait it measured, over the new scene, which waits too. The
//! original's loads also hold its sound's driver (the music holds its notes) and read no pad, and
//! the game does the same; a load that leaves the interrupts on (the round's clear's) runs the
//! driver alone at each of its ticks.
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const render = @import("../render/root.zig");
const view = @import("../view.zig");

pub const Load = struct {
    /// The display ticks left.
    left: u16 = 0,
    /// Whether the sound's driver waits too.
    sound_held: bool = true,
    /// The sound's driver runs at its first tick all the same (flow.zig).
    driver_once: bool = false,
    /// The load loads the sound's driver again: it starts again after it (flow.zig).
    driver_reloaded: bool = false,

    pub const Assets = struct {
        pub const names = .{};
    };
    pub const layout: view.Layout = .{};

    pub fn tick(self: *Load, turn: *scene.Turn, _: *const Assets) ?flow.Exit {
        turn.sound_driver = !self.sound_held;
        turn.lag = if (self.sound_held) .none else .load;
        if (self.driver_once) {
            self.driver_once = false;
            turn.sound_driver = true;
            turn.lag = .middle;
        }
        // The driver loaded again: its first update after the load stops every sound.
        if (self.driver_reloaded and self.left == 1) turn.sound_restart = true;
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

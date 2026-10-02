//! The Sega logo: the first screen at power-on, and again after the high scores or a demo
//! stopped by START. The logo's outline and its trademark show white; then its letters' colours
//! sweep (palette steps `segalogo/sweep`), it holds, and it fades to black; START during the sweep
//! skips to the fade. Its set-up starts the sound's driver again from its first state, as the
//! original's start-up loads it: what still sounds stops at the first tick after the load.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const art = @import("../content/art.zig");
const Setup = @import("../setup.zig").Setup;
const Colours = @import("colours.zig").Colours;

/// The sweep's steps last 4 ticks each, but the first 3 (its ticks are counted from 1, and a step
/// moves on every fourth: quirk L2).
const sweep_period = 4;
/// The hold after the sweep, before the fade.
const hold_ticks = 64;

pub const SegaLogo = struct {
    /// Ticks since the set-up (the set-up is tick 0).
    ticks: u16 = 0,
    phase: Phase = .setup,
    colours: Colours = .{},
    /// The ticks left of the hold.
    hold: u8 = 0,

    pub const Phase = enum(u8) { setup, sweep, hold, fade };

    pub const Assets = struct {
        logo: *const art.TileMap,
        trademark: *const art.TileMap,
        colours: *const art.Palette,
        trademark_colour: *const art.Palette,
        sweep: *const art.PaletteSteps,
        pub const names = .{
            .logo = "segalogo/logo",
            .trademark = "segalogo/trademark",
            .colours = "segalogo/colours",
            .trademark_colour = "segalogo/trademark",
            .sweep = "segalogo/sweep",
        };
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn start(_: *const Setup) SegaLogo {
        return .{};
    }

    pub fn tick(self: *SegaLogo, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.colours.latch();
        defer self.ticks +|= 1;
        switch (self.phase) {
            .setup => {
                // The logo white and the sweep's colours black, the pads released, the sound's
                // driver loaded again.
                self.colours.show(a.colours);
                self.colours.show(a.trademark_colour);
                turn.release_pads = true;
                turn.sound_restart = true;
                self.phase = .sweep;
            },
            .sweep => {
                const step = self.ticks / sweep_period;
                self.colours.showStep(a.sweep, step);
                if (step == a.sweep.steps.len - 1) {
                    // The last step ends the sweep; START is not read at its tick (quirk L1).
                    self.phase = .hold;
                    self.hold = hold_ticks;
                } else if (turn.pressed.pad1.start or turn.pressed.pad2.start) {
                    self.phase = .fade;
                    self.colours.startFade(.black);
                }
            },
            .hold => {
                self.hold -= 1;
                if (self.hold == 0) {
                    self.phase = .fade;
                    self.colours.startFade(.black);
                }
            },
            .fade => if (self.colours.stepFade()) return .done,
        }
        return null;
    }

    pub fn draw(self: *const SegaLogo, prev: ?*const SegaLogo, v: *view.View, a: *const Assets) !void {
        if (prev == null) {
            try v.board(.a).drawMapAtPlace(a.logo);
            try v.board(.a).drawMapAtPlace(a.trademark);
        }
        v.screen.colours = self.colours.shown;
    }
};

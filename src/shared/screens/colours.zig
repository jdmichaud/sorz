//! A screen's colours: the four palettes it sets, the target a fade in goes towards, the fade
//! running, and what the picture shows of them. The original's picture takes its colours as a
//! frame starts, so the colours a tick sets show from the next tick that runs (scene.zig): a
//! scene latches the colours at the start of each of its ticks (`latch`), and draws `shown`.
const render = @import("../render/root.zig");
const art = @import("../content/art.zig");

pub const Colours = struct {
    palettes: render.Palettes = .{},
    fade: ?render.Fade = null,
    /// What the picture shows at this tick: the colours at the end of the tick before.
    shown: render.palettes.Colours = render.palettes.black,

    /// At the start of a tick: the picture takes the colours the tick before left.
    pub fn latch(self: *Colours) void {
        self.shown = self.palettes.shown;
    }

    /// Shows a palette asset's colours (from the next tick on).
    pub fn show(self: *Colours, p: *const art.Palette) void {
        self.palettes.show(p);
    }

    /// Makes a palette asset's colours the target of a fade in.
    pub fn aim(self: *Colours, p: *const art.Palette) void {
        self.palettes.aim(p);
    }

    /// Shows palette step `i` of `steps`.
    pub fn showStep(self: *Colours, steps: *const art.PaletteSteps, i: usize) void {
        for (steps.steps[i], 0..) |line, p| for (line, 0..) |c, k| {
            if (c) |colour| self.palettes.shown[p][k] = colour;
        };
    }

    /// Starts a fade of every colour, to black or to the target, a step a tick from the next.
    pub fn startFade(self: *Colours, to: render.Fade.To) void {
        self.fade = .{ .to = to };
    }

    /// One step of the fade running; true when that was its last (or none runs).
    pub fn stepFade(self: *Colours) bool {
        const f = &(self.fade orelse return true);
        if (f.step(&self.palettes)) return false;
        self.fade = null;
        return true;
    }
};

const std = @import("std");

test "a tick's colours show at the next tick; a fade ends after its 64th step" {
    var c: Colours = .{};
    var p: art.Palette = .{ .name = "white" };
    p.colours[0][1] = .{ .r = 7, .g = 7, .b = 7 };
    c.latch();
    c.show(&p);
    try std.testing.expect(c.shown[0][1].eql(art.Colour.black));
    c.latch();
    try std.testing.expect(c.shown[0][1].eql(.{ .r = 7, .g = 7, .b = 7 }));
    c.startFade(.black);
    var steps: usize = 1;
    while (!c.stepFade()) steps += 1;
    try std.testing.expectEqual(@as(usize, 64), steps);
    try std.testing.expect(c.fade == null and c.palettes.shown[0][1].eql(art.Colour.black));
}

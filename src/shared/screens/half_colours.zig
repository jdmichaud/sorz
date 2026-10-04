//! The intro's and the title's colours, in half-levels: a channel holds 0 to 15, a colour's level
//! l is 2l, and the picture shows the half-level halved (an odd one shows as the level below).
//! Their fades step half a level at a time, all three channels at once, as the original's palette
//! words do (it counts their lowest bit, which the console does not show): they are not the
//! 64-step fades of the other screens (colours.zig). The picture shows the colours of the tick
//! before (`latch`), as everywhere.
const std = @import("std");
const render = @import("../render/root.zig");
const art = @import("../content/art.zig");

pub const lines = art.palette_count;
pub const size = art.palette_size;

/// A colour in half-levels: red, green, blue.
pub const Half = [3]u4;

pub const HalfColours = struct {
    now: [lines][size]Half = @splat(@splat(.{ 0, 0, 0 })),
    target: [lines][size]Half = @splat(@splat(.{ 0, 0, 0 })),
    /// What the picture shows at this tick: the colours the tick before left.
    shown: render.palettes.Colours = render.palettes.black,

    pub fn latch(self: *HalfColours) void {
        self.shown = self.levels();
    }

    /// The colours as levels.
    pub fn levels(self: *const HalfColours) render.palettes.Colours {
        var out: render.palettes.Colours = undefined;
        for (self.now, 0..) |line, p| for (line, 0..) |h, k| {
            out[p][k] = .{ .r = @intCast(h[0] >> 1), .g = @intCast(h[1] >> 1), .b = @intCast(h[2] >> 1) };
        };
        return out;
    }

    fn half(c: art.Colour) Half {
        return .{ @as(u4, c.r) * 2, @as(u4, c.g) * 2, @as(u4, c.b) * 2 };
    }

    /// Shows a palette asset's colours (those it gives).
    pub fn show(self: *HalfColours, p: *const art.Palette) void {
        for (p.colours, 0..) |line, i| for (line, 0..) |c, k| {
            if (c) |colour| self.now[i][k] = half(colour);
        };
    }

    /// Makes a palette asset's colours the target (those it gives).
    pub fn aim(self: *HalfColours, p: *const art.Palette) void {
        for (p.colours, 0..) |line, i| for (line, 0..) |c, k| {
            if (c) |colour| self.target[i][k] = half(colour);
        };
    }

    /// Shows step `i` of palette steps (the colours it gives).
    pub fn showStep(self: *HalfColours, steps: *const art.PaletteSteps, i: usize) void {
        for (steps.steps[i], 0..) |line, p| for (line, 0..) |c, k| {
            if (c) |colour| self.now[p][k] = half(colour);
        };
    }

    /// Every colour black, shown and target.
    pub fn clear(self: *HalfColours) void {
        self.now = @splat(@splat(.{ 0, 0, 0 }));
        self.target = self.now;
    }

    /// The colours `first` to `last` of palette `line`.
    pub const Range = struct { line: u2, first: u4 = 0, last: u4 = size - 1 };

    pub const Step = enum {
        /// Up towards the target: h = min(h + 1, t).
        rise,
        /// Down to black: h = max(h - 1, 0).
        sink,
        /// Up to white: h = min(h + 1, 14), and not below the target.
        whiten,
        /// Down to the target: h = max(h - 1, t).
        unwhiten,
    };

    /// One step of a fade over `r`.
    pub fn step(self: *HalfColours, r: Range, s: Step) void {
        var k: usize = r.first;
        while (k <= r.last) : (k += 1) {
            const c = &self.now[r.line][k];
            const t = self.target[r.line][k];
            for (c, t) |*h, goal| h.* = switch (s) {
                .rise => @min(h.* +| 1, goal),
                .sink => h.* -| 1,
                .whiten => @max(@min(h.* +| 1, 14), goal),
                .unwhiten => @max(h.* -| 1, goal),
            };
        }
    }

    /// One step of the fade of everything on START: two half-levels down, every colour.
    pub fn fadeAll(self: *HalfColours) void {
        for (&self.now) |*line| for (line) |*c| {
            for (c) |*h| h.* = h.* -| 2;
        };
    }
};

const testing = std.testing;

test "half-levels: a level is two, the picture shows half; each fade's rule" {
    var c: HalfColours = .{};
    var p: art.Palette = .{ .name = "p" };
    p.colours[1][3] = .{ .r = 3, .g = 0, .b = 7 };
    c.aim(&p);
    for (0..3) |_| c.step(.{ .line = 1 }, .rise);
    try testing.expectEqual(Half{ 3, 0, 3 }, c.now[1][3]);
    c.latch();
    try testing.expect(c.shown[1][3].eql(.{ .r = 1, .g = 0, .b = 1 }));
    for (0..20) |_| c.step(.{ .line = 1 }, .rise);
    try testing.expectEqual(Half{ 6, 0, 14 }, c.now[1][3]);
    for (0..20) |_| c.step(.{ .line = 1, .first = 3, .last = 3 }, .whiten);
    try testing.expectEqual(Half{ 14, 14, 14 }, c.now[1][3]);
    c.step(.{ .line = 1 }, .unwhiten);
    try testing.expectEqual(Half{ 13, 13, 14 }, c.now[1][3]);
    c.fadeAll();
    try testing.expectEqual(Half{ 11, 11, 12 }, c.now[1][3]);
    for (0..10) |_| c.step(.{ .line = 1 }, .sink);
    try testing.expectEqual(Half{ 1, 1, 2 }, c.now[1][3]);
}

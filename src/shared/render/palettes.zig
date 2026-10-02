//! The renderer's colours (DESIGN.md 10.5): four palettes of 16 colours, set from the content's
//! palettes, faded to black and back and cycled as the original does them, and the 8-bit levels
//! a colour shows with.
//!
//! A screen keeps two sets of colours: those shown, and the target a fade from black goes
//! towards. The original sets either: a screen's set-up shows its colours at once, or sets the
//! target and fades in.
const std = @import("std");
const art = @import("../content/art.zig");

const Colour = art.Colour;

pub const count = art.palette_count;
pub const size = art.palette_size;
/// Every colour of the four palettes: palette p's colour i is `colours[p][i]`.
pub const Colours = [count][size]Colour;

pub const black: Colours = @splat(@splat(Colour.black));

/// The 8-bit level of each of a colour's 8 levels, as the original's pictures show them: measured
/// on its screenshots (sor-remaster's rendering, the graphics port map's evidence), so that a
/// picture composed here equals the reference's.
pub const levels = [8]u8{ 0, 49, 87, 119, 146, 174, 206, 255 };

/// A colour as RGBA bytes.
pub fn rgba(c: Colour) [4]u8 {
    return .{ levels[c.r], levels[c.g], levels[c.b], 255 };
}

pub const Palettes = struct {
    /// The colours shown.
    shown: Colours = black,
    /// The colours a fade from black goes towards.
    target: Colours = black,

    /// Shows a palette asset's colours at once (those it gives; the others stay).
    pub fn show(self: *Palettes, p: *const art.Palette) void {
        p.apply(&self.shown);
    }

    /// Makes a palette asset's colours the target of the fades, without showing them.
    pub fn aim(self: *Palettes, p: *const art.Palette) void {
        p.apply(&self.target);
    }
};

/// A colour's channel.
pub const Channel = enum { red, green, blue };

/// A fade of the shown colours, step by step as the original fades: each step moves one channel
/// of every colour by one level, in the order red, a step with no change, blue, green, and again.
/// A fade has 64 steps, which leave every channel at its end (7 levels at most to go). A fade to
/// black lowers every colour; a fade in raises each channel that is below the target's, and
/// leaves those above it.
pub const Fade = struct {
    to: To,
    /// The steps left; the next step's channel follows from it.
    left: u8 = steps,
    /// The colours the fade moves: the first `colours` of palette 0 then 1, 2 and 3 (the round's
    /// title card fades in only the first 17).
    colours: u8 = count * size,

    pub const steps = 64;
    pub const To = enum { black, target };

    pub fn done(self: Fade) bool {
        return self.left == 0;
    }

    /// The channel the next step moves: none every fourth step.
    pub fn channel(self: Fade) ?Channel {
        // The original counts its steps down and picks the channel by the count's last two bits.
        return switch (self.left % 4) {
            0 => .red,
            1 => .green,
            2 => .blue,
            else => null,
        };
    }

    /// One step (one display tick). Returns whether the fade goes on.
    pub fn step(self: *Fade, p: *Palettes) bool {
        if (self.left == 0) return false;
        if (self.channel()) |c| {
            for (0..self.colours) |k| {
                const shown = &p.shown[k / size][k % size];
                const now = level(shown.*, c);
                switch (self.to) {
                    .black => if (now > 0) setLevel(shown, c, now - 1),
                    .target => if (now < level(p.target[k / size][k % size], c)) setLevel(shown, c, now + 1),
                }
            }
        }
        self.left -= 1;
        return self.left != 0;
    }
};

fn level(c: Colour, ch: Channel) u3 {
    return switch (ch) {
        .red => c.r,
        .green => c.g,
        .blue => c.b,
    };
}

fn setLevel(c: *Colour, ch: Channel, v: u3) void {
    switch (ch) {
        .red => c.r = v,
        .green => c.g = v,
        .blue => c.b = v,
    }
}

/// A palette cycle running (a round's neon signs, its water): every `period` ticks of its
/// cycle, the next step's colours are shown, the last step followed by the first. It starts on
/// its first step without showing it: the colours shown are the screen's own until the cycle
/// first moves on.
pub const CycleRun = struct {
    cycle: *const art.Cycle,
    /// Ticks until the next step.
    countdown: u16,
    /// The step shown (or, before the first change, the step the screen's colours stand for).
    step: u16 = 0,

    pub fn start(cycle: *const art.Cycle) CycleRun {
        return .{ .cycle = cycle, .countdown = cycle.period };
    }

    /// One tick of the cycle (a logic tick in play).
    pub fn tick(self: *CycleRun, p: *Palettes) void {
        self.countdown -= 1;
        if (self.countdown != 0) return;
        self.countdown = self.cycle.period;
        self.step += 1;
        if (self.step == self.cycle.steps.len) self.step = 0;
        const colours = &self.cycle.steps[self.step];
        for (colours, 0..) |line, i| for (line, 0..) |c, k| {
            if (c) |colour| p.shown[i][k] = colour;
        };
    }
};

// Tests ----------------------------------------------------------------------------------------

const testing = std.testing;

fn grey(v: u3) Colour {
    return .{ .r = v, .g = v, .b = v };
}

test "a palette asset is shown, or aimed at, in the colours it gives" {
    var asset: art.Palette = .{ .name = "x" };
    asset.colours[1][3] = grey(5);
    var p: Palettes = .{};
    p.shown[1][4] = grey(2);
    p.show(&asset);
    try testing.expect(p.shown[1][3].eql(grey(5)) and p.shown[1][4].eql(grey(2)));
    try testing.expect(p.target[1][3].eql(Colour.black));
    p.aim(&asset);
    try testing.expect(p.target[1][3].eql(grey(5)));
}

test "a fade's steps move red, then nothing, then blue, then green" {
    var f: Fade = .{ .to = .black };
    var order: [8]?Channel = undefined;
    for (&order) |*c| {
        c.* = f.channel();
        f.left -= 1;
    }
    try testing.expectEqualSlices(?Channel, &.{ .red, null, .blue, .green, .red, null, .blue, .green }, &order);
}

test "a fade to black lowers one channel a step and stops at 0" {
    var p: Palettes = .{};
    p.shown[0][1] = .{ .r = 1, .g = 7, .b = 2 };
    p.shown[3][15] = grey(7);
    var f: Fade = .{ .to = .black };
    try testing.expect(f.step(&p)); // red
    try testing.expect(p.shown[0][1].eql(.{ .r = 0, .g = 7, .b = 2 }));
    try testing.expect(p.shown[3][15].eql(.{ .r = 6, .g = 7, .b = 7 }));
    _ = f.step(&p); // nothing
    try testing.expect(p.shown[0][1].eql(.{ .r = 0, .g = 7, .b = 2 }));
    _ = f.step(&p); // blue
    _ = f.step(&p); // green
    try testing.expect(p.shown[0][1].eql(.{ .r = 0, .g = 6, .b = 1 }));
    _ = f.step(&p); // red again: already 0
    try testing.expect(p.shown[0][1].eql(.{ .r = 0, .g = 6, .b = 1 }));
    var steps: usize = 5;
    while (f.step(&p)) steps += 1;
    try testing.expectEqual(@as(usize, Fade.steps), steps + 1);
    try testing.expect(f.done() and !f.step(&p));
    for (p.shown) |line| for (line) |c| try testing.expect(c.eql(Colour.black));
}

test "a fade in raises each channel towards the target, one level a step, and no further" {
    var p: Palettes = .{};
    p.target[2][5] = .{ .r = 7, .g = 2, .b = 0 };
    // A colour above its target is left as it is.
    p.shown[2][6] = grey(3);
    var f: Fade = .{ .to = .target };
    _ = f.step(&p);
    try testing.expect(p.shown[2][5].eql(.{ .r = 1, .g = 0, .b = 0 }));
    for (0..7) |_| _ = f.step(&p);
    // Two of each channel's steps: red 2, green 2.
    try testing.expect(p.shown[2][5].eql(.{ .r = 2, .g = 2, .b = 0 }));
    while (f.step(&p)) {}
    try testing.expect(p.shown[2][5].eql(p.target[2][5]));
    try testing.expect(p.shown[2][6].eql(grey(3)));
}

test "a fade of the first colours leaves the others" {
    var p: Palettes = .{};
    p.target = @splat(@splat(grey(7)));
    var f: Fade = .{ .to = .target, .colours = 17 };
    while (f.step(&p)) {}
    try testing.expect(p.shown[0][15].eql(grey(7)) and p.shown[1][0].eql(grey(7)));
    try testing.expect(p.shown[1][1].eql(Colour.black) and p.shown[3][15].eql(Colour.black));
}

test "a cycle shows its next step every period, its first only after its last" {
    var s0: [count][size]?Colour = @splat(@splat(null));
    var s1 = s0;
    var s2 = s0;
    s0[2][10] = grey(1);
    s1[2][10] = grey(2);
    s2[2][10] = grey(3);
    s2[2][11] = grey(4);
    const steps = [_][count][size]?Colour{ s0, s1, s2 };
    const cycle: art.Cycle = .{ .name = "neon", .period = 3, .steps = &steps };
    var p: Palettes = .{};
    p.shown[2][10] = grey(7);
    var run = CycleRun.start(&cycle);
    var seen: [10]u3 = undefined;
    for (&seen) |*v| {
        run.tick(&p);
        v.* = p.shown[2][10].r;
    }
    try testing.expectEqualSlices(u3, &.{ 7, 7, 2, 2, 2, 3, 3, 3, 1, 1 }, &seen);
    try testing.expect(p.shown[2][11].eql(grey(4)));
    try testing.expect(p.target[2][10].eql(Colour.black));
}

test "colours show at the measured levels" {
    try testing.expectEqual([4]u8{ 0, 119, 255, 255 }, rgba(.{ .r = 0, .g = 3, .b = 7 }));
}

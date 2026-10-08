//! The output stage of the original Mega Drive (model 1): the mix of the YM2612 and the PSG, and
//! the console's low-pass filter, at the YM2612's rate (master / 1008, 53,267 Hz).
//!
//! The levels are BlastEm's, the outside reference used for the mix: its YM2612 channel gives
//! 0x20 x 79 / 120 = 21.07 per step of the 9-bit DAC, and ymfm's scaling here 128 x 64 / (6 x 65)
//! = 21.01, so the YM2612's samples are mixed as `Ym2612.generate` gives them; a PSG channel at
//! attenuation 0 gives 32767 / 14 = 2340 while its output is high (`psg.levels`), mixed at the
//! same gain into both sides. The filter is BlastEm's model of the model 1's output: one pole at
//! 3,390 Hz (its `lowpass_cutoff`), y += (x - y) x alpha with alpha = dt / (dt + RC) in 16.16
//! fixed point, dt = 1008 / 53,693,175 s and RC = 1 / (2 pi 3390) s.
//!
//! `process` with `enabled` false leaves the samples unfiltered: the switch of the model 1 stage.
const std = @import("std");
const Frame = @import("chip.zig").Frame;

/// floor(65536 x dt / (dt + RC)) for the values above (0.28565 x 65536 = 18720.3).
pub const lowpass_alpha: i64 = 18720;

pub const Model1 = struct {
    enabled: bool = true,
    last: Frame = .{},

    /// One sample of the mix: the YM2612's sample (scaled by the chip) and the PSG's mean level
    /// over the same sample time, through the filter when the stage is on.
    pub inline fn process(m: *Model1, fm: Frame, psg: i32) Frame {
        const x: Frame = .{ .left = fm.left + psg, .right = fm.right + psg };
        if (!m.enabled) return x;
        m.last = .{ .left = lowpass(m.last.left, x.left), .right = lowpass(m.last.right, x.right) };
        return m.last;
    }
};

/// BlastEm's one-pole filter in 16.16: (x alpha + y (1 - alpha)) >> 16. Any 32-bit values give
/// products and a sum within 49 bits: the operations cannot overflow.
inline fn lowpass(last: i32, x: i32) i32 {
    const v = (@as(i64, x) *% lowpass_alpha +% @as(i64, last) *% (0x10000 - lowpass_alpha)) >> 16;
    return @intCast(v);
}

const testing = std.testing;

test "the filter's constant is BlastEm's 3390 Hz pole at the YM2612's rate" {
    const dt = 1008.0 / 53693175.0;
    const rc = 1.0 / (2.0 * std.math.pi * 3390.0);
    const alpha = comptime @as(i64, @intFromFloat(@floor(65536.0 * dt / (dt + rc))));
    try testing.expectEqual(alpha, lowpass_alpha);
}

test "the filter: a step settles, a Nyquist tone is cut, off passes through" {
    var m: Model1 = .{};
    var y: Frame = .{};
    for (0..200) |_| y = m.process(.{ .left = 10000, .right = -10000 }, 0);
    try testing.expect(y.left >= 9990 and y.left <= 10000);
    try testing.expect(y.right <= -9990 and y.right >= -10001);
    // Alternating +-10000 (26.6 kHz): the gain of one pole there is about 0.17.
    m = .{};
    var peak: i32 = 0;
    for (0..400) |i| {
        const v: i32 = if (i % 2 == 0) 10000 else -10000;
        y = m.process(.{ .left = v, .right = v }, 0);
        if (i > 200) peak = @max(peak, @as(i32, @intCast(@abs(y.left))));
    }
    try testing.expect(peak > 1000 and peak < 2500);
    m = .{ .enabled = false };
    try testing.expectEqual(Frame{ .left = 1234 + 50, .right = -99 + 50 }, m.process(.{ .left = 1234, .right = -99 }, 50));
}

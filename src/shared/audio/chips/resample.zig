//! Resampling from the chips' mix (one sample every 1008 master cycles, 53,267 Hz) to the host's
//! rate, by linear interpolation in integer arithmetic. Time is counted exactly: output frame k is
//! at master cycle k x master / rate, kept as an integer numerator over `rate`, so the output never
//! drifts from the chips' time.
const std = @import("std");
const chip = @import("chip.zig");
const Frame = chip.Frame;

/// Master cycles per input sample (the YM2612's rate).
pub const input_cycles: u64 = 1008;

pub const Resampler = struct {
    /// Output frames per second.
    rate: u32,
    /// The input samples seen so far; `b` is sample `count - 1`, `a` the one before.
    count: u64 = 0,
    a: Frame = .{},
    b: Frame = .{},
    /// The next output frame's position, in master cycles x `rate`, as an input index `s` and a
    /// remainder `frac` < input_cycles x rate: the frame lies between inputs s and s + 1.
    s: u64 = 0,
    frac: u64 = 0,

    pub fn init(rate: u32) Resampler {
        return .{ .rate = rate };
    }

    fn span(r: *const Resampler) u64 {
        return input_cycles * r.rate;
    }

    /// Takes the next input sample; writes the output frames it completes into `out` (stereo
    /// interleaved) and returns their number. With an output rate below the input's it is 0 or
    /// 1, so `out` needs room for one frame; above, for rate / 53,267 rounded up.
    pub inline fn push(r: *Resampler, x: Frame, out: []i16) usize {
        r.a = r.b;
        r.b = x;
        r.count += 1;
        var n: usize = 0;
        const width = r.span();
        // Frame at s + frac: needs inputs s and s + 1, that is count >= s + 2.
        while (r.count >= r.s + 2) {
            if (r.count != r.s + 2) unreachable;
            out[2 * n] = interpolate(r.a.left, r.b.left, r.frac, width);
            out[2 * n + 1] = interpolate(r.a.right, r.b.right, r.frac, width);
            n += 1;
            r.frac += chip.master_clock;
            while (r.frac >= width) {
                r.frac -= width;
                r.s += 1;
            }
        }
        return n;
    }

    /// Changes the output rate from the next frame on; the next frame keeps its place between its
    /// two inputs. The clock balancing of network play stretches the sound this way by up to
    /// 0.5 % (DESIGN.md 9).
    pub fn setRate(r: *Resampler, rate: u32) void {
        if (rate == r.rate) return;
        // frac < input_cycles x old rate, so the scaled one stays below the new span.
        r.frac = r.frac * rate / r.rate;
        r.rate = rate;
    }

    /// The number of input samples still needed before the next output frame.
    pub fn inputsBeforeNextFrame(r: *const Resampler) u64 {
        return r.s + 2 - r.count;
    }
};

/// `frac` is below `span`, 1008 times a rate of at most 53,267, below 2^26: with any 32-bit
/// values, the operations cannot overflow.
inline fn interpolate(a: i32, b: i32, frac: u64, span: u64) i16 {
    const d: i64 = @as(i64, b) -% a;
    const v = @as(i64, a) +% @divFloor(d *% @as(i64, @intCast(frac)), @as(i64, @intCast(span)));
    return @intCast(@max(@min(v, std.math.maxInt(i16)), std.math.minInt(i16)));
}

const testing = std.testing;

test "48 kHz: 48000 frames for 53693175 / 1008 input samples, a ramp interpolated" {
    var r = Resampler.init(48000);
    var out: [2]i16 = undefined;
    var frames: u64 = 0;
    // One second of input: 53267 samples (and 33 cycles more).
    const inputs = chip.master_clock / input_cycles;
    var last: i16 = -1;
    for (0..inputs) |i| {
        const v: i32 = @intCast(i % 20000);
        const n = r.push(.{ .left = v, .right = -v }, &out);
        if (n == 1) {
            frames += 1;
            // A ramp stays a ramp: each frame is between the two inputs around it.
            if (i % 20000 > 2 and i % 20000 < 19998) {
                try testing.expect(out[0] > last);
                // Floor division: the negative side can be one lower.
                try testing.expect(out[1] == -out[0] or out[1] == -out[0] - 1);
            }
            last = out[0];
        }
    }
    // Frame k needs input floor(k x 53693175 / (1008 x 48000)) + 1: frames 0-47999 fit.
    try testing.expectEqual(@as(u64, 48000), frames);
}

test "the output clamps to 16 bits" {
    var r = Resampler.init(48000);
    var out: [2]i16 = undefined;
    _ = r.push(.{ .left = 100000, .right = -100000 }, &out);
    try testing.expectEqual(@as(usize, 1), r.push(.{ .left = 100000, .right = -100000 }, &out));
    try testing.expectEqual(@as(i16, 32767), out[0]);
    try testing.expectEqual(@as(i16, -32768), out[1]);
}

test "a rate stretched by 0.5 % gives 0.5 % more frames for the same input" {
    var r = Resampler.init(48000);
    var out: [2]i16 = undefined;
    const inputs = chip.master_clock / input_cycles;
    var frames: u64 = 0;
    for (0..inputs) |i| {
        // Half a second at 48 kHz, then half at 48,240 Hz.
        if (i == inputs / 2) r.setRate(48240);
        frames += r.push(.{ .left = 0, .right = 0 }, &out);
    }
    try testing.expect(frames >= 48000 + 119 and frames <= 48000 + 121);
    r.setRate(48000);
    try testing.expect(r.frac < input_cycles * r.rate);
}

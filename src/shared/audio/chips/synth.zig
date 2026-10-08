//! The synthesiser: the YM2612, the PSG and the DAC player on the Mega Drive's master clock, the
//! model 1 output stage, and the resampling to the host's rate.
//!
//! Time is counted in master clock cycles (53,693,175 Hz). The chips produce their samples as time
//! passes: the YM2612's sample s when time passes s x 1008, the PSG's step k when it passes k x 240,
//! each DAC write at its own cycle. A write takes effect at the current time: before every sample
//! that starts at or after it. The PSG's steps are averaged over each YM2612 sample's time (a
//! boxcar), mixed with it by the model 1 stage, and resampled to the output rate; so the host's
//! frames follow the chips' time exactly, whatever the rate of the game's updates. The PSG's steps
//! are made when a YM2612 sample or a PSG write needs them, and its runs of steps that keep its
//! level at once (`psgTo`).
//!
//! The sequencer's writes of one VBlank are given from the VBlank's time, each at its own time
//! (`advanceTo` up to it, then the write; see `../output.zig`), and the chips run for the rest of
//! the VBlank (896,040 cycles on NTSC in all): about 801 frames at 48 kHz.
const std = @import("std");
const chip = @import("chip.zig");
const Frame = chip.Frame;
const Ym2612 = @import("ym2612.zig").Ym2612;
const Psg = @import("psg.zig").Psg;
const dac = @import("dac.zig");
const Dac = dac.Dac;
const Model1 = @import("model1.zig").Model1;
const Resampler = @import("resample.zig").Resampler;

/// Master cycles per VBlank on NTSC: 262 lines of 3420 cycles.
pub const cycles_per_vblank: u64 = 262 * 3420;

pub const Options = struct {
    /// Output frames per second; at most the YM2612's rate (53,267).
    rate: u32 = 48000,
    /// The original Mega Drive's sound: the YM2612's DAC distortion and the console's filter.
    /// Off: a YM3438 without the distortion, and no filter.
    model1: bool = true,
};

/// The synthesiser with the port's chips.
pub const Default = Synth(Ym2612, Psg);

pub fn init(options: Options) Default {
    return Default.init(Ym2612.init(if (options.model1) .ym2612 else .ym3438), Psg.init(), options);
}

/// A synthesiser over any YM2612 core `Fm` and PSG core `P` implementing the chip interface
/// (`chip.zig`).
pub fn Synth(comptime Fm: type, comptime P: type) type {
    chip.check(Fm);
    chip.check(P);
    return struct {
        const Self = @This();

        fm: Fm,
        psg: P,
        dac: Dac = .{},
        stage: Model1 = .{},
        resampler: Resampler,

        /// The chips' time: every event before it has happened.
        now: u64 = 0,
        /// Samples generated so far; the next is due at count x cycles_per_sample. The PSG's
        /// count includes the steps of `psg_pending`.
        fm_count: u64 = 0,
        psg_count: u64 = 0,
        /// The YM2612's latest sample, mixed once its time has passed.
        fm_sample: Frame = .{},
        /// The PSG's current level, and its integral (level x cycles) over the time of the YM2612's
        /// latest sample, up to `psg_mark`.
        psg_level: i32 = 0,
        psg_sum: i64 = 0,
        psg_mark: u64 = 0,
        /// Steps counted but not yet made, all at the current level (see `psgTo`), and the number
        /// of steps after them that keep it.
        psg_pending: u32 = 0,
        psg_steady: u32 = 0,

        pub fn init(fm: Fm, psg: P, options: Options) Self {
            std.debug.assert(options.rate > 0 and options.rate <= chip.master_clock / Fm.cycles_per_sample);
            return .{
                .fm = fm,
                .psg = psg,
                .stage = .{ .enabled = options.model1 },
                .resampler = Resampler.init(options.rate),
            };
        }

        /// A write to the YM2612's port 0-3 at the current time.
        pub fn writeFm(s: *Self, port: u2, value: u8) void {
            s.fm.write(port, value);
        }

        /// A byte written to the PSG at the current time: after its steps before that time. The
        /// next step is made, as its level can differ from the latest step's.
        pub fn writePsg(s: *Self, value: u8) void {
            s.psgTo(s.now);
            s.psgFlush();
            s.psg.write(0, value);
            s.psg_steady = 0;
        }

        /// Starts a PCM sample through the DAC at the current time (the Z80's request); see
        /// `dac.zig`.
        pub fn startSample(s: *Self, values: []const u8, steps: []const u16, pan_both: bool) void {
            s.dac.start(s.now, values, steps, pan_both);
        }

        pub fn stopSample(s: *Self) void {
            s.dac.stop();
        }

        /// The Z80 stopped for `z80_cycles` from the current time: the 68000 held its bus (its own
        /// chip writes and the VBlank's transfers). The sample playing is delayed that much, as
        /// in the original, where these holds make long samples play up to 20% slower than their
        /// counted cycles. One total per VBlank, given at the VBlank, is enough: on the original's
        /// logged holds it keeps the DAC writes within a few milliseconds of the original's.
        pub fn holdZ80(s: *Self, z80_cycles: u64) void {
            s.dac.hold(s.now, z80_cycles * dac.master_per_z80);
        }

        pub fn samplePlaying(s: *const Self) bool {
            return s.dac.playing();
        }

        /// The most frames that `advance(cycles)` can give.
        pub fn maxFrames(s: *const Self, cycles: u64) usize {
            return @intCast(cycles * s.resampler.rate / chip.master_clock + 2);
        }

        /// Runs the chips for `cycles` master cycles and writes the finished frames into `out`
        /// (stereo interleaved, room for `maxFrames(cycles)` frames); returns their number.
        pub fn advance(s: *Self, cycles: u64, out: []i16) usize {
            std.debug.assert(out.len >= 2 * s.maxFrames(cycles));
            return s.advanceTo(s.now + cycles, out);
        }

        /// Runs the chips up to master cycle `t` (not before the current time); see `advance`.
        pub fn advanceTo(s: *Self, t: u64, out: []i16) usize {
            var n: usize = 0;
            while (true) {
                const next_fm = s.fm_count * Fm.cycles_per_sample;
                // The DAC's writes before the next sample (and before `t`) go first. They write
                // the YM2612 only: the PSG's steps can come before or after them.
                if (t > 0) {
                    if (s.dac.nextWrite(@min(next_fm, t - 1))) |w| {
                        s.now = @max(s.now, w.cycle);
                        s.fm.write(w.port, w.value);
                        continue;
                    }
                }
                if (next_fm >= t) break;
                // The samples that start before `t` and before the DAC's next write take no write:
                // the YM2612 makes them at once. A core that renders its channels apart from the
                // DAC's value (`dac_values`) takes the sample's values among them, each before the
                // first sample that starts at or after it: they write only the DAC's data. The
                // PSG's are made sample by sample with the mix.
                const next_dac = if (dac_values) s.dac.nextSetup() else s.dac.nextCycle();
                const end = if (next_dac) |w| @min(t, w) else t;
                const most: usize = @intCast(@min((end + Fm.cycles_per_sample - 1) / Fm.cycles_per_sample - s.fm_count, block_samples));
                var block: [block_samples]Frame = undefined;
                const count = if (dac_values) s.fm.renderChannels(block[0..most]) else most;
                if (!dac_values) s.fm.generate(block[0..count]);
                var dac_due = if (dac_values) s.dac.nextCycle() orelse std.math.maxInt(u64) else 0;
                for (block[0..count]) |f| {
                    const at = s.fm_count * Fm.cycles_per_sample;
                    var sample = f;
                    if (dac_values) {
                        if (at >= dac_due) {
                            while (s.dac.nextWrite(at)) |w| s.fm.write(w.port, w.value);
                            dac_due = s.dac.nextCycle() orelse std.math.maxInt(u64);
                        }
                        sample = s.fm.withDac(f);
                    }
                    if (s.fm_count > 0) {
                        n += s.mix(s.psgMean(at), out[2 * n ..]);
                    } else s.psgTo(at);
                    s.fm_sample = sample;
                    s.fm_count += 1;
                }
                s.now = (s.fm_count - 1) * Fm.cycles_per_sample;
            }
            s.now = @max(s.now, t);
            return n;
        }

        /// The most YM2612 samples made at once (the YM2612 renders up to 128 at a time).
        const block_samples = 128;

        /// Whether the YM2612 core renders its channels apart from the DAC's value
        /// (`renderChannels`, `withDac`: see `Ym2612`), so that the DAC's values do not end its
        /// blocks.
        const dac_values = @hasDecl(Fm, "renderChannels") and @hasDecl(Fm, "withDac");

        /// The PSG's mean level over the time of the YM2612's latest sample, which ends at `at`:
        /// `psgTo(at)`, then the sum divided by the sample's cycles. When every step before `at`
        /// keeps the level, `psgTo` would only add to the sum, and the steps are left to the next
        /// one, which counts them from the same total (`psg_count + psg_steady`) whatever the
        /// split; when moreover nothing was added since the last mean, at the sample's start, the
        /// mean is the level.
        inline fn psgMean(s: *Self, at: u64) i32 {
            if ((s.psg_count + s.psg_steady) * P.cycles_per_sample >= at) {
                if (s.psg_sum == 0 and s.psg_mark + Fm.cycles_per_sample == at) {
                    s.psg_mark = at;
                    return s.psg_level;
                }
                s.psg_sum += @as(i64, s.psg_level) * @as(i64, @intCast(at - s.psg_mark));
                s.psg_mark = at;
            } else s.psgTo(at);
            const sum = s.psg_sum;
            s.psg_sum = 0;
            return @intCast(@divFloor(sum, Fm.cycles_per_sample));
        }

        /// Runs the PSG's steps before master cycle `t` (step k is at k x cycles_per_sample) and
        /// adds its level x cycles to `psg_sum` up to `t`. The PSG changes its level only at some
        /// steps (`Psg.steady`): the steps in between are only counted, and made at once
        /// (`psgFlush`) before the next step that can change the level, or a write. Their level
        /// is the current one, so the sum is that of the steps one by one.
        fn psgTo(s: *Self, t: u64) void {
            const before_t = (t + P.cycles_per_sample - 1) / P.cycles_per_sample;
            while (s.psg_count < before_t) {
                const due = before_t - s.psg_count;
                if (s.psg_steady >= due) {
                    s.psg_steady -= @intCast(due);
                    s.psg_pending += @intCast(due);
                    s.psg_count += due;
                    break;
                }
                s.psg_pending += s.psg_steady;
                s.psg_count += s.psg_steady;
                s.psg_steady = 0;
                s.psgFlush();
                // A step that can change the level.
                const at = s.psg_count * P.cycles_per_sample;
                s.psg_sum += @as(i64, s.psg_level) * @as(i64, @intCast(at - s.psg_mark));
                s.psg_mark = at;
                var f: [1]Frame = undefined;
                s.psg.generate(&f);
                s.psg_level = f[0].left;
                s.psg_count += 1;
                s.psg_steady = psgSteady(&s.psg);
            }
            if (t > s.psg_mark) {
                s.psg_sum += @as(i64, s.psg_level) * @as(i64, @intCast(t - s.psg_mark));
                s.psg_mark = t;
            }
        }

        /// Makes the counted steps.
        fn psgFlush(s: *Self) void {
            if (!has_runs or s.psg_pending == 0) return;
            s.psg.skip(s.psg_pending);
            s.psg_pending = 0;
        }

        /// Whether the PSG core tells its steady runs (`steady`, `skip`: see `Psg`); without
        /// them, each step is made.
        const has_runs = @hasDecl(P, "steady") and @hasDecl(P, "skip");

        /// The steps after the latest that keep its level. At most about a VBlank's (4,096
        /// steps), so that the steps made at once stay few: a silent noise channel's register
        /// shifts up to every other step.
        fn psgSteady(p: *const P) u32 {
            if (!has_runs) return 0;
            return @min(p.steady(), 4096);
        }

        /// Renders exactly `out.len / 2` frames, running the chips as far as they need.
        pub fn render(s: *Self, out: []i16) void {
            var n: usize = 0;
            const want = out.len / 2;
            while (n < want) {
                // The frame comes with the mix of the YM2612 sample after `inputs` more mixes; a mix
                // happens when the next sample's time passes. Running up to exactly there keeps
                // each call to one frame at most, as the output rate is below the input's.
                const inputs = s.resampler.inputsBeforeNextFrame();
                const t = (s.fm_count + inputs - 1) * Fm.cycles_per_sample + 1;
                n += s.advanceTo(t, out[2 * n ..]);
            }
        }

        /// Mixes the YM2612's latest sample with the PSG's mean over its time, and resamples.
        inline fn mix(s: *Self, psg: i32, out: []i16) usize {
            const y = s.stage.process(s.fm_sample, psg);
            return s.resampler.push(y, out);
        }
    };
}

// ----- tests: synthetic register streams, no game data

const testing = std.testing;

test "a VBlank gives 800 to 802 frames at 48 kHz, 48000 a second" {
    var s = init(.{});
    var buf: [2 * 900]i16 = undefined;
    var total: usize = 0;
    var vblanks: usize = 0;
    // 60 VBlanks: 60 x 896040 cycles = 1.00129 s.
    while (vblanks < 60) : (vblanks += 1) {
        const n = s.advance(cycles_per_vblank, &buf);
        // 801.03 frames a VBlank, give or take the YM2612 sample whose time straddles its end.
        try testing.expect((n >= 800 and n <= 802) or (vblanks == 0 and n >= 797));
        total += n;
    }
    const expected = 60 * cycles_per_vblank * 48000 / chip.master_clock;
    try testing.expect(total + 2 >= expected and total <= expected);
}

test "render gives exactly the frames asked, and the same PCM as advance" {
    var a = init(.{});
    var b = init(.{});
    const frames = 5000;
    var pa: [2 * frames]i16 = undefined;
    // A tone on the PSG and on the YM2612's DAC, from both paths.
    for ([_]*Default{ &a, &b }) |s| {
        s.writePsg(0x80 | 0x0e);
        s.writePsg(0x03);
        s.writePsg(0x92);
        s.writeFm(0, 0x2b);
        s.writeFm(1, 0x80);
        s.writeFm(0, 0x2a);
        s.writeFm(1, 0xe0);
    }
    a.render(&pa);
    var pb: [2 * frames + 2 * 900]i16 = undefined;
    var n: usize = 0;
    while (n < frames) n += b.advance(1000, pb[2 * n ..]);
    try testing.expectEqualSlices(i16, &pa, pb[0 .. 2 * frames]);
    // The output moves: the PSG's square wave is there.
    var lo: i16 = std.math.maxInt(i16);
    var hi: i16 = std.math.minInt(i16);
    for (pa[1000..]) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    try testing.expect(hi - lo > 1000);
}

test "a DAC sample is heard at its step times" {
    var s = init(.{ .model1 = false });
    // Two values, 1000 Z80 cycles apart: +64, then -64 on the 8-bit scale.
    s.startSample(&.{ 0xc0, 0x40 }, &.{1000}, false);
    var buf: [2 * 4000]i16 = undefined;
    var n = s.advance(40000 * 15, &buf);
    // Before the first value: the DAC at 0 (a silent start).
    try testing.expectEqual(@as(i16, 0), buf[0]);
    // After the second value has settled, the DAC's -128 scaled by 128 / 6.
    try testing.expectEqual(@as(i16, @divTrunc(-128 * 128, 6)), buf[2 * (n - 1)]);
    // Somewhere in between: +128 scaled.
    var seen = false;
    for (0..n) |i| seen = seen or buf[2 * i] == @divTrunc(128 * 128, 6);
    try testing.expect(seen);
    try testing.expect(!s.samplePlaying());
    n = s.advance(1000, &buf);
    try testing.expect(n <= 2);
}

test "a hold of the Z80 delays the sample's next values" {
    var a = init(.{ .model1 = false });
    var b = init(.{ .model1 = false });
    var buf: [2 * 4000]i16 = undefined;
    for ([_]*Default{ &a, &b }) |s| s.startSample(&.{ 0xc0, 0x40 }, &.{1000}, false);
    _ = a.advance(1500 * 15, &buf);
    _ = b.advance(1500 * 15, &buf);
    // The first value is due 1051 Z80 cycles after the request, the second 1000 after it.
    b.holdZ80(700);
    _ = a.advance(1000 * 15, &buf);
    _ = b.advance(1000 * 15, &buf);
    try testing.expect(a.dac.index == 2 and !a.samplePlaying());
    try testing.expect(b.dac.index == 1 and b.samplePlaying());
    _ = b.advance(700 * 15, &buf);
    try testing.expect(!b.samplePlaying());
}

test "the same writes give the same PCM" {
    var pcm: [2][2 * 3000]i16 = undefined;
    for (&pcm) |*p| {
        var s = init(.{});
        s.writeFm(0, 0x22);
        s.writeFm(1, 0x0b); // LFO on
        s.writeFm(0, 0xb4);
        s.writeFm(1, 0xc7);
        s.writeFm(0, 0xb0);
        s.writeFm(1, 0x3c);
        s.writeFm(0, 0x40);
        s.writeFm(1, 0x10);
        s.writeFm(0, 0x4c);
        s.writeFm(1, 0x00);
        s.writeFm(0, 0x50);
        s.writeFm(1, 0x1f);
        s.writeFm(0, 0x5c);
        s.writeFm(1, 0x1f);
        s.writeFm(0, 0xa4);
        s.writeFm(1, 0x22);
        s.writeFm(0, 0xa0);
        s.writeFm(1, 0x69);
        s.writeFm(0, 0x28);
        s.writeFm(1, 0xf0);
        s.writePsg(0xe7);
        s.writePsg(0xf0);
        s.render(p);
    }
    try testing.expectEqualSlices(i16, &pcm[0], &pcm[1]);
}

/// The PSG with its levels multiplied by the YM2612's sample time, so that the synthesiser's mean
/// over a sample is the exact sum of its level x cycles; with or without its steady runs.
fn ScaledPsg(comptime runs: bool) type {
    const Base = struct {
        pub const cycles_per_sample = Psg.cycles_per_sample;
        psg: Psg = .{},
        pub fn reset(p: *@This()) void {
            p.psg.reset();
        }
        pub fn write(p: *@This(), port: u2, value: u8) void {
            p.psg.write(port, value);
        }
        pub fn generate(p: *@This(), out: []Frame) void {
            for (out) |*f| {
                const v = p.psg.step() * @as(i32, Ym2612.cycles_per_sample);
                f.* = .{ .left = v, .right = v };
            }
        }
    };
    if (!runs) return Base;
    return struct {
        pub const cycles_per_sample = Psg.cycles_per_sample;
        base: Base = .{},
        pub fn reset(p: *@This()) void {
            p.base.reset();
        }
        pub fn write(p: *@This(), port: u2, value: u8) void {
            p.base.write(port, value);
        }
        pub fn generate(p: *@This(), out: []Frame) void {
            p.base.generate(out);
        }
        pub fn steady(p: *const @This()) u32 {
            return p.base.psg.steady();
        }
        pub fn skip(p: *@This(), n: u32) void {
            p.base.psg.skip(n);
        }
    };
}

test "the PSG's steady runs give the sums of its steps one by one, over every sample" {
    const Steps = Synth(Ym2612, ScaledPsg(false));
    const Runs = Synth(Ym2612, ScaledPsg(true));
    var a = Steps.init(Ym2612.init(.ym2612), .{}, .{ .model1 = false });
    var b = Runs.init(Ym2612.init(.ym2612), .{}, .{ .model1 = false });
    var prng = std.Random.DefaultPrng.init(0x2a6d365a);
    const r = prng.random();
    var buf: [2 * 900]i16 = undefined;
    var t: u64 = 0;
    var runs: u64 = 0;
    for (0..2000) |_| {
        // Writes at any cycle, some within a step of each other, some far apart.
        t += switch (r.uintLessThan(u8, 4)) {
            0 => r.uintLessThan(u64, 300),
            1 => r.uintLessThan(u64, 5000),
            else => r.uintLessThan(u64, 200_000),
        };
        // To the write's time, one YM2612 sample at a time: each sample's PSG mean is compared.
        while (a.now < t) {
            const to = @min(t, a.fm_count * Ym2612.cycles_per_sample + 1);
            _ = a.advanceTo(to, &buf);
            _ = b.advanceTo(to, &buf);
            try testing.expectEqual(a.resampler.count, b.resampler.count);
            try testing.expectEqual(a.resampler.b, b.resampler.b);
        }
        // A latch byte (attenuations 0 and 15 often, small periods often) or a data byte.
        const ch: u8 = r.uintLessThan(u8, 4) << 5;
        const v: u8 = switch (r.uintLessThan(u8, 8)) {
            0, 1 => 0x90 | ch | (if (r.boolean()) 15 else r.uintLessThan(u8, 16)),
            2, 3 => 0x80 | ch | r.uintLessThan(u8, 4),
            4 => 0x80 | ch | r.uintLessThan(u8, 16),
            5 => r.uintLessThan(u8, 4),
            else => r.uintLessThan(u8, 0x80),
        };
        // The steps counted (the samples leave theirs to the next `psgTo`) and not yet made.
        b.psgTo(b.now);
        runs += b.psg_pending;
        a.writePsg(v);
        b.writePsg(v);
    }
    try testing.expect(runs > 0);
}

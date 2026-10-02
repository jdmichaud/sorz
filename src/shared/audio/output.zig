//! The output stage: each update's writes (sequencer.zig) given to the chips on the master clock,
//! and the update's PCM (stereo, interleaved) at the host's rate.
//!
//! - The sample requests act at the update's start: the DAC player starts the sample (its values
//!   at the Z80 player's pace, `clock.step`) or stops it; the update's bus hold delays the playing
//!   sample by as much.
//! - The register writes follow, `write_cycles` apart from the update's start, as the original's
//!   68000 spaces them (3,834 master cycles on average in a VBlank, measured by sor-remaster on the
//!   original): a key off and the next key on written in one instant would never restart the note,
//!   as the YM2612 takes them at its next sample. A YM2612 register (its address then its data)
//!   or a PSG byte with the data byte after it is one write. An update with more writes than fit
//!   has them closer.
//! - Then the chips run to the update's end: 896,040 master cycles, about 801 frames at 48 kHz.
const std = @import("std");
const chips = @import("chips/root.zig");
const content = @import("content.zig");
const sequencer = @import("sequencer.zig");
const clock = @import("clock.zig");
const registers = @import("chips/registers.zig");

/// Master cycles from one of an update's writes to the next.
pub const write_cycles: u64 = 3834;

pub const Output = struct {
    synth: chips.synth.Default,
    sounds: *const content.Content,
    /// Each sample's Z80 cycles between its values, by number.
    steps: [32][]const u16 = @splat(&.{}),
    /// Room for one update's frames at the most stretched rate.
    buffer: []i16,
    rate: u32,

    /// The most that `stretch` lengthens the sound: 0.5 %, in parts per million.
    pub const max_stretch_ppm: u32 = 5000;

    /// `c` outlives the output; `rate` is the host's frames per second; `model1` the original
    /// console's DAC distortion and filter.
    pub fn init(gpa: std.mem.Allocator, c: *const content.Content, rate: u32, model1: bool) !Output {
        var o: Output = .{
            .synth = chips.synth.init(.{ .rate = rate, .model1 = model1 }),
            .sounds = c,
            .buffer = &.{},
            .rate = rate,
        };
        errdefer o.deinit(gpa);
        for (c.samples) |*s| {
            if (s.number >= o.steps.len or s.values.len < 2) continue;
            const st = try gpa.alloc(u16, s.values.len - 1);
            for (st, 1..) |*v, i| v.* = clock.step(s, i);
            o.steps[s.number] = st;
        }
        o.synth.resampler.rate = stretchedRate(rate, max_stretch_ppm);
        o.buffer = try gpa.alloc(i16, 2 * o.synth.maxFrames(chips.synth.cycles_per_vblank));
        o.synth.resampler.rate = rate;
        return o;
    }

    pub fn deinit(o: *Output, gpa: std.mem.Allocator) void {
        for (&o.steps) |*s| {
            if (s.len != 0) gpa.free(s.*);
            s.* = &.{};
        }
        if (o.buffer.len != 0) gpa.free(o.buffer);
        o.buffer = &.{};
    }

    fn stretchedRate(rate: u32, ppm: u32) u32 {
        const r = rate + @as(u32, @intCast(@as(u64, rate) * @min(ppm, max_stretch_ppm) / 1_000_000));
        return @min(r, chips.chip.master_clock / 1008);
    }

    /// Network play's clock balancing (DESIGN.md 9): `ppm` millionths more frames an update, up
    /// to 0.5 %.
    pub fn stretch(o: *Output, ppm: u32) void {
        o.synth.resampler.setRate(stretchedRate(o.rate, ppm));
    }

    /// One update's PCM from its writes; valid until the next call.
    pub fn tick(o: *Output, t: *const sequencer.Tick) []const i16 {
        const writes = t.items();
        for (writes) |w| if (w.port == .sample) o.sample(w.value);
        o.synth.holdZ80(t.hold);
        const start = o.synth.now;
        const update_cycles = chips.synth.cycles_per_vblank;
        var count: u64 = 0;
        for (writes) |w| count += @intFromBool(startsWrite(w));
        const spacing = @min(write_cycles, update_cycles / (count + 1));
        var n: usize = 0;
        var k: u64 = 0;
        for (writes) |w| {
            if (startsWrite(w)) {
                n += o.synth.advanceTo(start + k * spacing, o.buffer[2 * n ..]);
                k += 1;
            }
            switch (w.port) {
                .part1_address, .part1_data, .part2_address, .part2_data => o.synth.writeFm(@intCast(@backingInt(w.port)), w.value),
                .psg => o.synth.writePsg(w.value),
                .sample => {},
            }
        }
        n += o.synth.advanceTo(start + update_cycles, o.buffer[2 * n ..]);
        return o.buffer[0 .. 2 * n];
    }

    /// Whether `w` starts one of the original's writes: a YM2612 address (its data follows in the
    /// same instant) or a PSG byte with its latch bit (a data byte after it follows in the same
    /// instant).
    fn startsWrite(w: sequencer.Write) bool {
        return switch (w.port) {
            .part1_address, .part2_address => true,
            .psg => registers.latches(w.value),
            else => false,
        };
    }

    fn sample(o: *Output, value: u8) void {
        switch (value) {
            sequencer.none_code => {},
            sequencer.stop_code => o.synth.stopSample(),
            else => {
                const s = o.sounds.sample(value) orelse return o.synth.stopSample();
                o.synth.startSample(s.values, o.steps[value], s.voice);
            },
        }
    }
};

test "an update gives its frames, and a note makes sound" {
    const gpa = std.testing.allocator;
    const c: content.Content = .{ .driver = .{} };
    var o = try Output.init(gpa, &c, 48000, true);
    defer o.deinit(gpa);
    var t: sequencer.Tick = .{};
    try std.testing.expect(o.tick(&t).len >= 2 * 800);
    // FM1: algorithm 7, op4 at full level with a fast attack, the others silent; a note on.
    const Recorder = struct {
        tick: *sequencer.Tick,
        pub fn takeBus(_: @This()) void {}
        pub fn port(r: @This(), p: registers.Port, v: u8) void {
            r.tick.writes[r.tick.len] = .{ .port = p, .value = v };
            r.tick.len += 1;
        }
    };
    const r: Recorder = .{ .tick = &t };
    var i: content.Instrument = .{ .number = 0, .algorithm = 7, .feedback = 0, .operators = @splat(.{ .level = 127 }) };
    i.operators[3] = .{ .multiple = 1, .attack = 31 };
    registers.instrument(r, .fm1, &i, registers.output_reset);
    registers.pitch(r, .fm1, 4 << 11 | 617);
    registers.keyOn(r, .fm1);
    _ = o.tick(&t);
    t.len = 0;
    var peak: i32 = 0;
    for (o.tick(&t)) |v| peak = @max(peak, @as(i32, @intCast(@abs(v))));
    try std.testing.expect(peak > 100);
}

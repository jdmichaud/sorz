//! The PSG of the Mega Drive: Sega's variant of the SN76489 inside the VDP, written from the chip's
//! documentation (SMS Power's "SN76489 notes"):
//!
//! - three square-wave tone channels with 10-bit period registers and one noise channel, each with
//!   a 4-bit attenuation in steps of 2 dB (15 is off);
//! - the chip divides its clock (the Z80's, master / 15) by 16: each step, every channel's counter
//!   counts down; at 0 it is reloaded with the channel's period and the channel's output flips; a
//!   tone whose period is 0 or 1 outputs a constant +1 (the way games play samples on the PSG);
//! - the noise counter is reloaded with $10, $20 or $40 (rate 0-2) or with tone 2's period (rate
//!   3); each time its output rises, the 16-bit shift register shifts right: its bit 0 is the
//!   noise output, and the bit fed in at bit 15 is bit 0 (periodic noise) or bit 0 XOR bit 3
//!   (white noise, Sega's taps). A write to the noise register resets the register to $8000.
//! - a byte with bit 7 set latches a channel (bits 5-6) and a register (bit 4: attenuation, else
//!   period or noise) and writes its low 4 bits into the register's low 4 bits; a byte with bit 7
//!   clear writes the latched register: the period's high 6 bits, or the attenuation's or noise
//!   register's 4 bits.
//!
//! The output is unipolar, as the chip's: a channel adds its level while its output is high. The
//! level of attenuation 0 is 32767 / 14 = 2340 per channel, the PSG's scale in BlastEm, whose FM
//! and PSG levels relative to each other the mix keeps (`model1.zig`); the other levels fall by
//! 2 dB a step.
const std = @import("std");
const chip = @import("chip.zig");
const Frame = chip.Frame;

/// The level of each attenuation, 2 dB apart: round(2340 * 10^(-a / 10)), 0 for 15.
pub const levels: [16]u16 = .{ 2340, 1859, 1476, 1173, 932, 740, 588, 467, 371, 295, 234, 186, 148, 117, 93, 0 };

pub const Psg = struct {
    /// One step every 16 cycles of the chip, the chip at master / 15.
    pub const cycles_per_sample: u32 = 15 * 16;

    /// The white noise's taps: bits 0 and 3.
    pub const white_taps: u16 = 0x0009;

    /// Periods of tones 0-2, then the noise's reload value.
    period: [4]u16 = @splat(0),
    counter: [4]u16 = @splat(0),
    attenuation: [4]u4 = @splat(15),
    output: [4]u1 = @splat(0),
    /// The noise register's low 3 bits: bit 2 white noise, bits 0-1 the rate.
    noise: u3 = 0,
    lfsr: u16 = 0x8000,
    noise_out: u1 = 0,
    /// The latched register: bits 1-2 the channel, bit 0 set for the attenuation.
    latch: u3 = 0,
    taps: u16 = white_taps,

    pub fn init() Psg {
        return .{};
    }

    pub fn reset(p: *Psg) void {
        p.* = .{ .taps = p.taps };
    }

    /// A byte written to the PSG's port ($C00011); `port` is ignored.
    pub fn write(p: *Psg, port: u2, value: u8) void {
        _ = port;
        if (value & 0x80 != 0) {
            p.latch = @intCast((value >> 4) & 7);
            p.writeLatched(value & 0x0f, false);
        } else {
            p.writeLatched(value & 0x3f, true);
        }
    }

    fn writeLatched(p: *Psg, data: u8, is_data_byte: bool) void {
        const channel = p.latch >> 1;
        if (p.latch & 1 != 0) {
            p.attenuation[channel] = @intCast(data & 0x0f);
        } else if (channel == 3) {
            p.noise = @intCast(data & 7);
            p.lfsr = 0x8000;
            p.period[3] = p.noisePeriod();
        } else {
            if (is_data_byte) {
                p.period[channel] = (p.period[channel] & 0x00f) | (@as(u16, data) << 4);
            } else {
                p.period[channel] = (p.period[channel] & 0x3f0) | data;
            }
            if (channel == 2 and p.noise & 3 == 3) p.period[3] = p.period[2];
        }
    }

    fn noisePeriod(p: *const Psg) u16 {
        return switch (p.noise & 3) {
            0 => 0x10,
            1 => 0x20,
            2 => 0x40,
            else => p.period[2],
        };
    }

    /// One step: the counters, then the output level (0 to 4 x 2340).
    pub fn step(p: *Psg) i32 {
        for (0..4) |i| {
            if (p.counter[i] != 0) p.counter[i] -= 1;
            if (p.counter[i] == 0) {
                p.counter[i] = p.period[i];
                p.output[i] ^= 1;
                if (i < 3 and p.period[i] <= 1) p.output[i] = 1;
                if (i == 3 and p.output[3] == 1) p.shiftNoise();
            }
        }
        var sum: i32 = 0;
        for (0..3) |i| {
            if (p.output[i] != 0) sum += levels[p.attenuation[i]];
        }
        if (p.noise_out != 0) sum += levels[p.attenuation[3]];
        return sum;
    }

    /// The next `out.len` steps, the same on both sides.
    pub fn generate(p: *Psg, out: []Frame) void {
        for (out) |*f| {
            const v = p.step();
            f.* = .{ .left = v, .right = v };
        }
    }

    /// Called after a step, with no write since: the number of next steps that give the level of
    /// that step, in which no channel that is heard (attenuation below 15) changes its output. A
    /// channel's output changes only when its counter reaches 0, which takes `counter` steps (one
    /// when it is 0); a tone whose period is 0 or 1 and that has reached its constant +1 never
    /// changes.
    pub fn steady(p: *const Psg) u32 {
        var n: u32 = std.math.maxInt(u32);
        for (0..3) |i| {
            if (p.attenuation[i] == 15) continue;
            if (p.period[i] <= 1 and p.counter[i] == p.period[i] and p.output[i] == 1) continue;
            if (p.counter[i] == 0) return 0;
            n = @min(n, p.counter[i] - 1);
        }
        if (p.attenuation[3] != 15) n = @min(n, p.noiseSteady());
        return n;
    }

    /// The steps before the noise's output (`noise_out`) can change. It changes only when the
    /// channel's output rises, every other time its counter reaches 0, and then takes the
    /// register's bit 0 before the shift: the next 16 rises give bits 0 to 15 of the register as it
    /// is now, and only the 17th a bit fed back.
    fn noiseSteady(p: *const Psg) u32 {
        const interval: u32 = @max(p.period[3], 1);
        // The step of the next rise: the counter's next 0, or the one after when it falls there.
        var rise: u32 = if (p.counter[3] == 0) 1 else p.counter[3];
        if (p.output[3] == 1) rise += interval;
        // The rises that give the output it has: the register's low bits equal to it.
        const same: u32 = @ctz(p.lfsr ^ (if (p.noise_out == 1) @as(u16, 0xffff) else 0));
        return rise + same * 2 * interval - 1;
    }

    /// `n` steps at once, `n` at most `steady()`: each channel's counter, and the outputs and the
    /// noise register of the channels not heard, end as `n` calls of `step` leave them.
    pub fn skip(p: *Psg, n: u32) void {
        if (n == 0) return;
        for (0..4) |i| {
            const flips = p.runCounter(i, n);
            if (flips == 0) continue;
            if (i < 3) {
                p.output[i] = if (p.period[i] <= 1) 1 else p.output[i] ^ @as(u1, @truncate(flips));
            } else {
                // The register shifts when the output rises: every other flip, from the first if
                // the output is low.
                const rises = if (p.output[3] == 0) (flips + 1) / 2 else flips / 2;
                for (0..rises) |_| p.shiftNoise();
                p.output[3] ^= @truncate(flips);
            }
        }
    }

    /// Runs channel `i`'s counter for `n` steps; returns the number of times it reached 0 (and was
    /// reloaded with the period: every `max(period, 1)` steps after the first time).
    fn runCounter(p: *Psg, i: usize, n: u32) u32 {
        const c = p.counter[i];
        const first: u32 = if (c == 0) 1 else c;
        if (n < first) {
            p.counter[i] = @intCast(c - n);
            return 0;
        }
        const period = p.period[i];
        const rest = n - first;
        if (period == 0) {
            p.counter[i] = 0;
            return 1 + rest;
        }
        p.counter[i] = @intCast(period - rest % period);
        return 1 + rest / period;
    }

    fn shiftNoise(p: *Psg) void {
        p.noise_out = @intCast(p.lfsr & 1);
        const feedback: u16 = if (p.noise & 4 != 0) @popCount(p.lfsr & p.taps) & 1 else p.lfsr & 1;
        p.lfsr = (p.lfsr >> 1) | (feedback << 15);
    }
};

comptime {
    chip.check(Psg);
}

// ----- tests: synthetic register streams, no game data

const testing = std.testing;

/// The steps between the rising edges of `channel`'s output.
fn risingPeriod(p: *Psg, channel: usize) usize {
    var prev = p.output[channel];
    var first: ?usize = null;
    var i: usize = 0;
    while (i < 100000) : (i += 1) {
        _ = p.step();
        if (prev == 0 and p.output[channel] == 1) {
            if (first) |f| return i - f;
            first = i;
        }
        prev = p.output[channel];
    }
    return 0;
}

test "a tone's period: twice its register, in steps" {
    var p = Psg.init();
    p.write(0, 0x80 | 0x0d); // tone 0, low bits $D
    p.write(0, 0x0f); // high bits: period $FD
    try testing.expectEqual(@as(u16, 0xfd), p.period[0]);
    try testing.expectEqual(@as(usize, 2 * 0xfd), risingPeriod(&p, 0));
    p.write(0, 0xa0 | 0x03); // tone 1: period 3
    try testing.expectEqual(@as(usize, 6), risingPeriod(&p, 1));
}

test "a tone of period 0 or 1 is a constant +1" {
    var p = Psg.init();
    p.write(0, 0x90);
    p.write(0, 0x81); // period 1
    for (0..10) |_| try testing.expectEqual(@as(i32, 2340), p.step());
    p.write(0, 0x80); // period 0
    for (0..10) |_| try testing.expectEqual(@as(i32, 2340), p.step());
}

test "the levels: 2 dB steps, 15 off, the sum of the channels" {
    for (1..15) |a| {
        // Each step is 10^(-0.1): between 0.79 and 0.80 of the previous.
        const r = @as(u32, levels[a]) * 1000 / levels[a - 1];
        try testing.expect(r >= 790 and r <= 800);
    }
    var p = Psg.init();
    try testing.expectEqual(@as(i32, 0), p.step());
    p.write(0, 0x90); // tone 0 at attenuation 0
    p.write(0, 0xb2); // tone 1 at attenuation 2
    p.write(0, 0x80 | 0x05);
    p.write(0, 0x00);
    p.write(0, 0xa0 | 0x05);
    p.write(0, 0x00);
    var seen_both = false;
    for (0..40) |_| {
        const v = p.step();
        try testing.expect(v == 0 or v == 2340 or v == 1476 or v == 2340 + 1476);
        if (v == 2340 + 1476) seen_both = true;
    }
    try testing.expect(seen_both);
}

test "white noise: Sega's 16-bit register, taps 0 and 3, period 57337 shifts" {
    var p = Psg.init();
    p.write(0, 0xe4); // white noise, rate 0 (shift every $20 steps)
    const start = p.lfsr;
    var shifts: usize = 0;
    var prev = p.output[3];
    while (true) {
        _ = p.step();
        if (prev == 0 and p.output[3] == 1) {
            shifts += 1;
            if (p.lfsr == start) break;
        }
        prev = p.output[3];
    }
    try testing.expectEqual(@as(usize, 57337), shifts);
    // Periodic noise: the register rotates, a period of 16 shifts; one output bit in 16 is set.
    p.write(0, 0xe0);
    var ones: usize = 0;
    var n: usize = 0;
    prev = p.output[3];
    while (n < 160) {
        _ = p.step();
        if (prev == 0 and p.output[3] == 1) {
            n += 1;
            ones += p.noise_out;
        }
        prev = p.output[3];
    }
    try testing.expectEqual(@as(usize, 10), ones);
}

test "noise rate 3 follows tone 2's period, and a noise write resets the register" {
    var p = Psg.init();
    p.write(0, 0xc0 | 0x07); // tone 2 period 7
    p.write(0, 0x00);
    p.write(0, 0xe7); // white noise at tone 2's rate
    try testing.expectEqual(@as(u16, 7), p.period[3]);
    p.write(0, 0xc0 | 0x09); // tone 2's period changes: so does the noise's
    try testing.expectEqual(@as(u16, 9), p.period[3]);
    for (0..1000) |_| _ = p.step();
    try testing.expect(p.lfsr != 0x8000);
    p.write(0, 0xe7);
    try testing.expectEqual(@as(u16, 0x8000), p.lfsr);
    // A data byte after an attenuation latch sets the attenuation.
    p.write(0, 0xff);
    p.write(0, 0x03);
    try testing.expectEqual(@as(u4, 3), p.attenuation[3]);
}

/// A random register write: periods 0 to 3 and others, every attenuation (15 often), the noise at
/// each rate, data bytes alone.
fn randomWrite(p: *Psg, r: std.Random) void {
    const ch: u8 = r.uintLessThan(u8, 4);
    switch (r.uintLessThan(u8, 10)) {
        0...2 => p.write(0, 0x90 | (ch << 5) | (if (r.boolean()) 15 else r.uintLessThan(u8, 16))),
        3 => p.write(0, 0xe0 | r.uintLessThan(u8, 8)),
        4 => p.write(0, r.uintLessThan(u8, 0x80)),
        else => {
            const period: u16 = if (r.boolean()) r.uintLessThan(u16, 4) else r.uintLessThan(u16, 1024);
            p.write(0, 0x80 | ((ch % 3) << 5) | @as(u8, @intCast(period & 15)));
            p.write(0, @intCast(period >> 4));
        },
    }
}

test "a steady run: its steps keep the level, and skip leaves the state of the steps" {
    var prng = std.Random.DefaultPrng.init(0x2a6d365a);
    const r = prng.random();
    var p = Psg.init();
    var runs: usize = 0;
    for (0..20000) |_| {
        for (0..r.uintLessThan(u8, 3)) |_| randomWrite(&p, r);
        // `steady` is asked after a step.
        const level = p.step();
        const n = p.steady();
        const k: u32 = @min(n, r.uintLessThan(u32, 5000));
        var stepped = p;
        for (0..k) |_| try testing.expectEqual(level, stepped.step());
        p.skip(k);
        try testing.expectEqual(stepped, p);
        if (k > 1) runs += 1;
    }
    // The runs were not all empty.
    try testing.expect(runs > 5000);
}

test "a silent channel's steps are skipped: the tones' periods 0 and 1, the noise's register" {
    var p = Psg.init();
    // Power-on: every period 0, the noise's too, every channel silent.
    _ = p.step();
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), p.steady());
    var stepped = p;
    for (0..1001) |_| _ = stepped.step();
    p.skip(1001);
    try testing.expectEqual(stepped, p);
    // A tone heard at period 1 is a constant: it does not end the run; the noise heard does.
    p.write(0, 0x90);
    p.write(0, 0x81);
    _ = p.step();
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), p.steady());
    p.write(0, 0xe4);
    p.write(0, 0xf0);
    const level = p.step();
    // The noise's output is 0 and its channel's low: it rises in $10 steps, then every $20; the
    // register reset to $8000 gives 15 more zeros, and its 1 at the 16th rise.
    try testing.expectEqual(@as(u1, 0), p.noise_out);
    try testing.expectEqual(@as(u1, 0), p.output[3]);
    try testing.expectEqual(@as(u32, 0x10 + 15 * 0x20 - 1), p.steady());
    for (0..0x10 + 15 * 0x20 - 1) |_| try testing.expectEqual(level, p.step());
    try testing.expectEqual(level + levels[0], p.step());
}

test "white noise at its fastest, heard: its steady runs give the steps' levels" {
    var p = Psg.init();
    // Noise at tone 2's rate, tone 2 at period 0: the channel flips at every step.
    p.write(0, 0xc0);
    p.write(0, 0x00);
    p.write(0, 0xe7);
    p.write(0, 0xf3);
    var stepped = p;
    var made: usize = 0;
    var steps: usize = 0;
    while (steps < 100000) {
        const level = p.step();
        try testing.expectEqual(level, stepped.step());
        made += 1;
        steps += 1;
        const n = p.steady();
        for (0..n) |_| try testing.expectEqual(level, stepped.step());
        p.skip(n);
        steps += n;
        try testing.expectEqual(stepped, p);
    }
    // A step in about four is made: the output changes at half the rises, every other step.
    try testing.expect(made < steps / 3);
}

//! The DAC path: a PCM sample played through the YM2612's DAC, as the Z80's player does it (sound
//! port map 3.8). The sequencer decides when a sample starts and stops (`start`, `stop`); this
//! player only turns the sample's values into the YM2612 writes the Z80 makes, at the Z80's times:
//! $2B (DAC on), optionally $B6 (channel 6 on both sides, for the long samples), then each value
//! into $2A, the steps between two values given in Z80 cycles, as the extractor decodes them.
//!
//! The delays before the first value are measured on the original (the demo capture from
//! power-on, 552 requests): the Z80 turns the DAC on 139-176 Z80 cycles after the 68000's request
//! (by where its wait loop is), and writes the first value 908 cycles after that for the samples
//! in its RAM. The Z80 stops while the 68000 holds its bus, which makes samples play up to 20%
//! slower than their counted cycles: `hold` delays the play by such a stop. The Z80 also sees a
//! new request only after the current byte of codes, so the original can write one or two more
//! values of the previous sample before the new one; the port starts the new one at once.
const std = @import("std");

/// The Z80 runs at master / 15.
pub const master_per_z80: u32 = 15;
/// Z80 cycles from the request to the DAC-on write (the most common value measured).
pub const enable_delay: u32 = 143;
/// Z80 cycles from the DAC-on write to the first value.
pub const first_value_delay: u32 = 908;

/// A write the player makes: `port` and `value` as for `Ym2612.write`, at `cycle` (master clock).
pub const Write = struct { cycle: u64, port: u2, value: u8 };

pub const Dac = struct {
    values: []const u8 = &.{},
    steps: []const u16 = &.{},
    /// The next value to write.
    index: u32 = 0,
    /// The master cycle of the next event.
    next: u64 = 0,
    stage: Stage = .idle,
    pan_both: bool = false,
    /// The second write of a pair ($2A, then the value), when the first was returned.
    pending: ?Write = null,

    const Stage = enum { idle, enable, pan, value };

    /// The sample's values and steps are the content's: a machine's sound in its form names the
    /// sample instead (sound_form.zig).
    pub const canonical_skip = [_][]const u8{ "values", "steps" };

    /// Starts `values` at master cycle `now` (the time of the request), replacing a sample that
    /// plays. `steps[i]` is the number of Z80 cycles from value i to value i + 1. With
    /// `pan_both`, channel 6 is put on both sides first, as the Z80 does for samples 5-16.
    pub fn start(d: *Dac, now: u64, values: []const u8, steps: []const u16, pan_both: bool) void {
        d.* = .{
            .values = values,
            .steps = steps,
            .next = now + enable_delay * master_per_z80,
            .stage = .enable,
            .pan_both = pan_both,
        };
    }

    /// Stops the sample: no more values are written (the DAC keeps the last one).
    pub fn stop(d: *Dac) void {
        d.stage = .idle;
        d.pending = null;
    }

    /// The Z80 stopped from master cycle `from` for `cycles` master cycles, while the 68000 held
    /// its bus: the play's next events come that much later. Call it in time order, before
    /// taking the writes due after `from`.
    pub fn hold(d: *Dac, from: u64, cycles: u64) void {
        if (d.stage != .idle and d.next >= from) d.next += cycles;
    }

    /// Whether a sample is playing (the Z80's flag $1FF6 for the long samples).
    pub fn playing(d: *const Dac) bool {
        return d.stage != .idle;
    }

    /// The master cycle of the next write, or null when the player has none to make. A pending
    /// write is due at once.
    pub fn nextCycle(d: *const Dac) ?u64 {
        if (d.pending) |p| return p.cycle;
        if (d.stage == .idle) return null;
        return d.next;
    }

    /// The master cycle of the next write that is not one of the sample's values (the DAC's
    /// switching on, the pan), or null when none is to come: the values write only the DAC's
    /// data.
    pub fn nextSetup(d: *const Dac) ?u64 {
        if (d.pending) |p| return p.cycle;
        return switch (d.stage) {
            .enable, .pan => d.next,
            .idle, .value => null,
        };
    }

    /// The next write due at or before master cycle `until`, or null. Each call returns one port
    /// write; an address write is always followed by its data write at the same cycle.
    pub fn nextWrite(d: *Dac, until: u64) ?Write {
        if (d.pending) |p| {
            d.pending = null;
            return p;
        }
        if (d.stage == .idle or d.next > until) return null;
        const at = d.next;
        switch (d.stage) {
            .idle => unreachable,
            .enable => {
                d.pending = .{ .cycle = at, .port = 1, .value = 0x80 };
                if (d.pan_both) {
                    d.stage = .pan;
                } else {
                    d.stage = .value;
                    d.next = at + first_value_delay * master_per_z80;
                }
                return .{ .cycle = at, .port = 0, .value = 0x2b };
            },
            .pan => {
                d.pending = .{ .cycle = at, .port = 3, .value = 0xc0 };
                d.stage = .value;
                d.next = at + first_value_delay * master_per_z80;
                return .{ .cycle = at, .port = 2, .value = 0xb6 };
            },
            .value => {
                if (d.index >= d.values.len) {
                    d.stage = .idle;
                    return null;
                }
                d.pending = .{ .cycle = at, .port = 1, .value = d.values[d.index] };
                if (d.index < d.steps.len) {
                    d.next = at + @as(u64, d.steps[d.index]) * master_per_z80;
                } else if (d.index + 1 < d.values.len) {
                    // Steps missing: the player stops rather than guessing a rate.
                    d.stage = .idle;
                }
                d.index += 1;
                if (d.index >= d.values.len) d.stage = .idle;
                return .{ .cycle = at, .port = 0, .value = 0x2a };
            },
        }
    }
};

// ----- tests: synthetic samples, no game data

const testing = std.testing;

test "a sample's writes: DAC on, then each value at its step" {
    var d: Dac = .{};
    d.start(1000, &.{ 0x80, 0x90, 0x70 }, &.{ 200, 250 }, false);
    try testing.expect(d.playing());
    try testing.expectEqual(@as(?Write, null), d.nextWrite(1000));
    const t0 = 1000 + enable_delay * 15;
    try testing.expectEqual(Write{ .cycle = t0, .port = 0, .value = 0x2b }, d.nextWrite(t0).?);
    try testing.expectEqual(Write{ .cycle = t0, .port = 1, .value = 0x80 }, d.nextWrite(t0).?);
    const t1 = t0 + first_value_delay * 15;
    try testing.expectEqual(@as(?Write, null), d.nextWrite(t1 - 1));
    try testing.expectEqual(Write{ .cycle = t1, .port = 0, .value = 0x2a }, d.nextWrite(t1).?);
    try testing.expectEqual(Write{ .cycle = t1, .port = 1, .value = 0x80 }, d.nextWrite(t1).?);
    const t2 = t1 + 200 * 15;
    try testing.expectEqual(Write{ .cycle = t2, .port = 1, .value = 0x90 }, blk: {
        _ = d.nextWrite(t2).?;
        break :blk d.nextWrite(t2).?;
    });
    const t3 = t2 + 250 * 15;
    _ = d.nextWrite(t3).?;
    try testing.expectEqual(Write{ .cycle = t3, .port = 1, .value = 0x70 }, d.nextWrite(t3).?);
    try testing.expect(!d.playing());
    try testing.expectEqual(@as(?Write, null), d.nextWrite(t3 + 100000));
}

test "a hold delays the next value, not one due before it" {
    var d: Dac = .{};
    d.start(0, &.{ 1, 2 }, &.{100}, false);
    const t1 = (enable_delay + first_value_delay) * 15;
    d.hold(10, 500);
    // The DAC-on writes, then nothing until the first value, 500 cycles late.
    try testing.expectEqual(@as(u64, enable_delay * 15 + 500), d.nextWrite(t1 + 499).?.cycle);
    _ = d.nextWrite(t1 + 499).?;
    try testing.expectEqual(@as(?Write, null), d.nextWrite(t1 + 499));
    _ = d.nextWrite(t1 + 500).?;
    _ = d.nextWrite(t1 + 500).?;
    d.hold(t1 + 100 * 15 + 500 + 1, 1000); // after the next value's time: no effect on it
    try testing.expectEqual(@as(u64, t1 + 500 + 100 * 15), d.nextWrite(1 << 40).?.cycle);
}

test "the long samples put channel 6 on both sides; stop ends the writes" {
    var d: Dac = .{};
    d.start(0, &.{ 1, 2, 3 }, &.{ 100, 100 }, true);
    const t0 = enable_delay * 15;
    _ = d.nextWrite(t0).?;
    _ = d.nextWrite(t0).?;
    try testing.expectEqual(Write{ .cycle = t0, .port = 2, .value = 0xb6 }, d.nextWrite(t0).?);
    try testing.expectEqual(Write{ .cycle = t0, .port = 3, .value = 0xc0 }, d.nextWrite(t0).?);
    d.stop();
    try testing.expect(!d.playing());
    try testing.expectEqual(@as(?Write, null), d.nextWrite(1 << 40));
}

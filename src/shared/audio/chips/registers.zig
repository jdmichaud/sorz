//! The YM2612's and the PSG's registers as the sequencer writes them: each operation of the
//! sequencer (a key on, a pitch, an instrument, a level) becomes its writes in the order the
//! original driver makes them, through a sink that records them. The register numbers live here,
//! with the chips; the sequencer speaks of channels, operators and values.
//!
//! The sink is any value with `takeBus()` (the 68000 takes the Z80's bus before a group of YM2612
//! writes: the sequencer's clock counts it) and `port(Port, u8)`.
const content = @import("../content.zig");
const OperatorName = content.OperatorName;

/// A channel: its value is the chip's code for it (the YM2612's key-on code, the PSG's latch
/// bits), which the original's tracks keep and one quirk counts with (see the sequencer).
pub const Channel = enum(u8) {
    fm1 = 0,
    fm2 = 1,
    fm3 = 2,
    fm4 = 4,
    fm5 = 5,
    fm6 = 6,
    tone0 = 0x80,
    tone1 = 0xA0,
    tone2 = 0xC0,
    _,

    pub fn isPsg(c: Channel) bool {
        return @backingInt(c) & 0x80 != 0;
    }
};

/// Where a write goes: the YM2612's address and data ports of its two parts, the PSG, and the
/// sample player's request.
pub const Port = enum(u3) { part1_address, part1_data, part2_address, part2_data, psg, sample };

/// The register slot of each operator ($x0, $x4, $x8, $xC hold op1, op3, op2, op4).
pub fn slot(op: OperatorName) u8 {
    return switch (op) {
        .op1 => 0,
        .op3 => 1,
        .op2 => 2,
        .op4 => 3,
    };
}

/// The operators in register order.
pub const register_order = [4]OperatorName{ .op1, .op3, .op2, .op4 };

fn part1(out: anytype, reg: u8, value: u8) void {
    out.port(.part1_address, reg);
    out.port(.part1_data, value);
}

fn part2(out: anytype, reg: u8, value: u8) void {
    out.port(.part2_address, reg);
    out.port(.part2_data, value);
}

/// Register `reg` of channel `c`: through its part, with the channel's number added.
fn channel(out: anytype, c: Channel, reg: u8, value: u8) void {
    const code = @backingInt(c);
    if (code & 4 != 0) part2(out, reg +% (code & ~@as(u8, 4)), value) else part1(out, reg +% code, value);
}

pub fn keyOn(out: anytype, c: Channel) void {
    out.takeBus();
    part1(out, 0x28, @backingInt(c) | 0xF0);
}

pub fn keyOff(out: anytype, c: Channel) void {
    out.takeBus();
    part1(out, 0x28, @backingInt(c));
}

/// The key off of all six channels (FM3 and FM6 first), in one group.
pub fn keysOff(out: anytype) void {
    out.takeBus();
    for ([_]u8{ 2, 1, 0 }) |c| {
        part1(out, 0x28, c);
        part1(out, 0x28, c + 4);
    }
}

/// The channel's pitch: block and F-number in one word.
pub fn pitch(out: anytype, c: Channel, word: u16) void {
    out.takeBus();
    channel(out, c, 0xA4, @truncate(word >> 8));
    channel(out, c, 0xA0, @truncate(word));
}

/// FM3 in its special mode: each operator's pitch, in the order `operators`.
pub fn fm3Pitches(out: anytype, words: [4]u16, operators: [4]OperatorName) void {
    out.takeBus();
    for (words, operators) |w, op| {
        const high: u8 = switch (op) {
            .op1 => 0xAD,
            .op2 => 0xAE,
            .op3 => 0xAC,
            .op4 => 0xA6,
        };
        part1(out, high, @truncate(w >> 8));
        part1(out, high - 4, @truncate(w));
    }
}

/// Key off, then every operator silent: attenuation 127, the fastest release.
pub fn silence(out: anytype, c: Channel) void {
    out.takeBus();
    part1(out, 0x28, @backingInt(c));
    for (0..4) |s| channel(out, c, 0x40 + 4 * @as(u8, @intCast(s)), 0x7F);
    for (0..4) |s| channel(out, c, 0x80 + 4 * @as(u8, @intCast(s)), 0x0F);
}

/// The six channels keyed off, then every operator of both parts silent.
pub fn silenceAll(out: anytype) void {
    out.takeBus();
    for ([_]u8{ 2, 1, 0 }) |c| {
        part1(out, 0x28, c);
        part1(out, 0x28, c + 4);
    }
    for ([_][2]u8{ .{ 0x40, 0x7F }, .{ 0x80, 0x0F } }) |group| {
        for (0..3) |c| for (0..4) |s| {
            const reg = group[0] + 4 * @as(u8, @intCast(s)) + @as(u8, @intCast(c));
            part1(out, reg, group[1]);
            part2(out, reg, group[1]);
        };
    }
}

/// Every channel on both speakers, without the LFO's modulation.
pub fn resetOutputs(out: anytype) void {
    out.takeBus();
    for ([_]u8{ 0xB4, 0xB5, 0xB6 }) |reg| {
        part1(out, reg, 0xC0);
        part2(out, reg, 0xC0);
    }
}

pub fn dacOn(out: anytype) void {
    out.takeBus();
    part1(out, 0x2B, 0x80);
}

pub fn fm3Special(out: anytype, on: bool) void {
    out.takeBus();
    part1(out, 0x27, if (on) 0x40 else 0);
}

/// The LFO on at `rate`.
pub fn lfo(out: anytype, rate: u8) void {
    out.takeBus();
    part1(out, 0x22, rate | 8);
}

/// The value of an instrument's register: group 0-5 ($30 to $80) for operator `op`.
pub fn instrumentByte(i: *const content.Instrument, group: usize, op: OperatorName) u8 {
    const o = i.operators[@backingInt(op)];
    return o.ignored[group] | switch (group) {
        0 => @as(u8, o.detune) << 4 | o.multiple,
        1 => o.level,
        2 => @as(u8, o.key_scale) << 6 | o.attack,
        3 => @as(u8, @intFromBool(o.am)) << 7 | o.decay,
        4 => o.sustain_rate,
        5 => @as(u8, o.sustain_level) << 4 | o.release,
        else => unreachable,
    };
}

/// The bits of a parameter group's register that the chip does not use.
pub fn ignoredBits(p: content.Parameter) u8 {
    return switch (p) {
        .detune_multiple, .level => 0x80,
        .key_scale_attack => 0x20,
        .am_decay => 0x60,
        .sustain_rate => 0xE0,
        .sustain_level_release => 0,
    };
}

/// The algorithm and feedback byte of an instrument.
pub fn algorithmByte(i: *const content.Instrument) u8 {
    return i.ignored | @as(u8, i.feedback) << 3 | i.algorithm;
}

/// An instrument's operators, its algorithm and the channel's output (`output`: speakers and the
/// LFO's sensitivities), in one group.
pub fn instrument(out: anytype, c: Channel, i: *const content.Instrument, output_byte: u8) void {
    out.takeBus();
    for (0..6) |group| for (register_order, 0..) |op, s| {
        channel(out, c, 0x30 + 0x10 * @as(u8, @intCast(group)) + 4 * @as(u8, @intCast(s)), instrumentByte(i, group, op));
    };
    channel(out, c, 0xB0, algorithmByte(i));
    channel(out, c, 0xB4, output_byte);
}

/// An operator's attenuation.
pub fn level(out: anytype, c: Channel, op: OperatorName, value: u8) void {
    out.takeBus();
    channel(out, c, 0x40 + 4 * slot(op), value);
}

/// One parameter group of an operator.
pub fn parameter(out: anytype, c: Channel, op: OperatorName, p: content.Parameter, value: u8) void {
    out.takeBus();
    const base: u8 = switch (p) {
        .detune_multiple => 0x30,
        .level => 0x40,
        .key_scale_attack => 0x50,
        .am_decay => 0x60,
        .sustain_rate => 0x70,
        .sustain_level_release => 0x80,
    };
    channel(out, c, base + 4 * slot(op), value);
}

/// Timer B, written through the channel's part.
pub fn timerB(out: anytype, c: Channel, value: u8) void {
    out.takeBus();
    if (@backingInt(c) & 4 != 0) part2(out, 0x26, value) else part1(out, 0x26, value);
}

/// The channel's output: its speakers (bits 7-6) and its sensitivities to the LFO.
pub fn output(out: anytype, c: Channel, value: u8) void {
    out.takeBus();
    channel(out, c, 0xB4, value);
}

/// The speakers' bits of the output byte.
pub fn speakers(s: content.Speakers) u8 {
    return switch (s) {
        .both => 0xC0,
        .left => 0x80,
        .right => 0x40,
        .none => 0,
    };
}

/// The output byte of a channel that starts: both speakers, no LFO.
pub const output_reset: u8 = 0xC0;

/// An output byte with its speakers replaced (its other bits kept).
pub fn withSpeakers(output_byte: u8, s: content.Speakers) u8 {
    return speakers(s) | (output_byte & 0x3F);
}

/// An output byte with its sensitivities to the LFO replaced (its speakers kept): values past
/// their fields spill into the next ones, as the driver writes them.
pub fn withLfo(output_byte: u8, fms: u8, ams: u8) u8 {
    return fms | @as(u8, @truncate(@as(u16, ams) << 4)) | (output_byte & 0xC0);
}

// --- the PSG (no bus to take: it is not on the Z80's bus) ----------------------------------

/// A tone channel's divider: the latch byte with its low 4 bits, then its high bits.
pub fn tone(out: anytype, c: Channel, divider: u16) void {
    out.port(.psg, @backingInt(c) | @as(u8, @truncate(divider & 15)));
    out.port(.psg, @truncate(divider >> 4));
}

/// A channel's attenuation as the driver writes it: its value or'ed into the channel's latch,
/// then the attenuation bit added (values above 15 spill into the next channel's bits).
pub fn attenuation(out: anytype, c: Channel, value: u8) void {
    out.port(.psg, (value | @backingInt(c)) +% 0x10);
}

pub fn noiseAttenuation(out: anytype, value: u8) void {
    out.port(.psg, value | 0xF0);
}

/// The channel silent (and the noise channel too when the track plays it).
pub fn quiet(out: anytype, c: Channel, noise: bool) void {
    out.port(.psg, 0x1F +% @backingInt(c));
    if (noise) out.port(.psg, 0xFF);
}

/// The four PSG channels silent.
pub fn quietAll(out: anytype) void {
    for ([_]u8{ 0x9F, 0xBF, 0xDF, 0xFF }) |v| out.port(.psg, v);
}

/// The noise channel set to white noise at tone 2's rate, tone 2 silent and at period 0.
pub fn noiseMode(out: anytype) void {
    for ([_]u8{ 0xDF, 0xE7, 0xC0, 0x00 }) |v| out.port(.psg, v);
}

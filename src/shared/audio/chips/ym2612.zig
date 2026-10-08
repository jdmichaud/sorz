//! The YM2612 (OPN2): a Zig port of ymfm's `ym2612` by Aaron Giles (ymfm commit 81aec25: the
//! `ym2612` class of ymfm_opn.h/.cpp, the OPNA registers of ymfm_opn.cpp, and the FM engine,
//! channel and operator of ymfm_fm.h/.ipp). It follows ymfm sample for sample: the same tables,
//! the same integer arithmetic, the same order of operations and the same caching of the operator
//! data, so its output equals ymfm's (checked on logged write streams of the original; see
//! sor-remaster's item 15). Only the parts the Mega Drive's YM2612 uses are ported: no SSG, ADPCM,
//! rhythm or OPM noise; the timers and the status register are not modelled (the port never reads
//! the chip, and nothing uses CSM mode).
//!
//! `Variant.ym2612` is the original 1991 Mega Drive's chip, with the distortion of its 9-bit
//! multiplexed DAC (the "ladder effect", `dacDiscontinuity`); `Variant.ym3438` is the later CMOS
//! chip without it.
//!
//! ymfm's licence:
//!
//! BSD 3-Clause License
//!
//! Copyright (c) 2021, Aaron Giles
//! All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//! 1. Redistributions of source code must retain the above copyright notice, this
//!    list of conditions and the following disclaimer.
//!
//! 2. Redistributions in binary form must reproduce the above copyright notice,
//!    this list of conditions and the following disclaimer in the documentation
//!    and/or other materials provided with the distribution.
//!
//! 3. Neither the name of the copyright holder nor the names of its
//!    contributors may be used to endorse or promote products derived from
//!    this software without specific prior written permission.
//!
//! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
const std = @import("std");
const chip = @import("chip.zig");
const Frame = chip.Frame;

/// The chip with or without the DAC distortion of the original Mega Drive's YM2612.
pub const Variant = enum { ym2612, ym3438 };

const channels = 6;
const operators = 24;
const all_channels: u32 = (1 << channels) - 1;
const registers = 0x200;
const reg_mode = 0x27;
/// An envelope attenuation above this is silent: the operator's output is 0.
const eg_quiet: u32 = 0x380;
const waveform_length = 0x400;

const EnvelopeState = enum(u3) { attack = 1, decay = 2, sustain = 3, release = 4 };

const keyon_normal = 0;
const keyon_csm = 2;

/// The operator data computed once from the registers and kept until a register changes
/// (ymfm's `opdata_cache`, with the register fields that ymfm reads at each sample: every write
/// prepares the operators again before the next sample, so the registers never change under it).
const OpCache = struct {
    /// `phase_step` value meaning "recompute every sample" (PM from the LFO is active).
    const phase_step_dynamic: u32 = 1;
    /// A PM value the LFO never gives (it gives -7 to 7).
    const pm_none: i32 = std.math.maxInt(i32);

    phase_step: u32 = 0,
    total_level: u32 = 0,
    block_freq: u32 = 0,
    detune: i32 = 0,
    multiple: u32 = 0,
    eg_sustain: u32 = 0,
    /// Indexed by `EnvelopeState` (entries 1-4 are used).
    eg_rate: [6]u8 = @splat(0),
    /// The channel's PM sensitivity, for the phase step with the LFO.
    pm_sensitivity: u32 = 0,
    /// With the LFO's PM: the PM value of `pm_step`, the phase step last computed (`pm_none`
    /// before the first). The value changes every 28 to 440 samples, by the LFO's rate.
    pm_value: i32 = pm_none,
    pm_step: u32 = 0,
    ssg_eg_enable: bool = false,
    ssg_eg_mode: u32 = 0,
    lfo_am_enable: bool = false,
};

/// A channel's register fields, kept as `OpCache` is.
const ChCache = struct {
    /// The algorithm's routing (`algorithm_ops`).
    algorithm: u16 = 0,
    feedback: u32 = 0,
    output0: bool = false,
    output1: bool = false,
    /// The shift of the LFO's AM value by the channel's AM sensitivity.
    am_shift: u5 = 0,
};

const Operator = struct {
    choffs: u32,
    opoffs: u32,
    /// 10.10 fixed point.
    phase: u32 = 0,
    /// 4.6 fixed point attenuation.
    env_attenuation: u16 = 0x3ff,
    env_state: EnvelopeState = .release,
    ssg_inverted: u8 = 0,
    key_state: u8 = 0,
    keyon_live: u8 = 0,
    cache: OpCache = .{},

    fn reset(op: *Operator) void {
        op.phase = 0;
        op.env_attenuation = 0x3ff;
        op.env_state = .release;
        op.ssg_inverted = 0;
        op.key_state = 0;
        op.keyon_live = 0;
    }

    /// The phase's integer part (10 bits of a period, and more above).
    inline fn phaseInt(op: *const Operator) u32 {
        return op.phase >> 10;
    }
};

const Channel = struct {
    choffs: u32,
    feedback: [2]i16 = .{ 0, 0 },
    feedback_in: i16 = 0,
    /// The operators O1, O2, O3, O4, as indices into `Ym2612.ops`.
    ops: [4]u8,
    cache: ChCache = .{},
    /// The operators (bit n for On+1) that are not silent (`Ym2612.opSilent`): set at each
    /// preparation, where a key on can wake one, and cleared when one's clock makes it silent.
    live: u4 = 0,
};

/// Operator number to register offset (ymfm's `operator_offset` for OPNA).
fn operatorOffset(opnum: u32) u32 {
    return (opnum % 12) + ((opnum % 12) / 3) + 0x100 * (opnum / 12);
}

/// Channel number to register offset.
fn channelOffset(chnum: u32) u32 {
    return (chnum % 3) + 0x100 * (chnum / 3);
}

/// The operators of each channel, in the order O1, O2, O3, O4 (ymfm's fixed OPNA map).
const operator_map = [channels][4]u8{
    .{ 0, 6, 3, 9 },
    .{ 1, 7, 4, 10 },
    .{ 2, 8, 5, 11 },
    .{ 12, 18, 15, 21 },
    .{ 13, 19, 16, 22 },
    .{ 14, 20, 17, 23 },
};

inline fn bitfield(value: u32, start: u5, length: u5) u32 {
    return (value >> start) & ((@as(u32, 1) << length) - 1);
}

/// |sin| of a 10-bit phase as a 4.8 logarithmic attenuation; the values are the OPN's, from the
/// die (ymfm's `abs_sin_attenuation`).
const sin_table = [256]u16{
    0x859, 0x6c3, 0x607, 0x58b, 0x52e, 0x4e4, 0x4a6, 0x471, 0x443, 0x41a, 0x3f5, 0x3d3, 0x3b5, 0x398, 0x37e, 0x365,
    0x34e, 0x339, 0x324, 0x311, 0x2ff, 0x2ed, 0x2dc, 0x2cd, 0x2bd, 0x2af, 0x2a0, 0x293, 0x286, 0x279, 0x26d, 0x261,
    0x256, 0x24b, 0x240, 0x236, 0x22c, 0x222, 0x218, 0x20f, 0x206, 0x1fd, 0x1f5, 0x1ec, 0x1e4, 0x1dc, 0x1d4, 0x1cd,
    0x1c5, 0x1be, 0x1b7, 0x1b0, 0x1a9, 0x1a2, 0x19b, 0x195, 0x18f, 0x188, 0x182, 0x17c, 0x177, 0x171, 0x16b, 0x166,
    0x160, 0x15b, 0x155, 0x150, 0x14b, 0x146, 0x141, 0x13c, 0x137, 0x133, 0x12e, 0x129, 0x125, 0x121, 0x11c, 0x118,
    0x114, 0x10f, 0x10b, 0x107, 0x103, 0x0ff, 0x0fb, 0x0f8, 0x0f4, 0x0f0, 0x0ec, 0x0e9, 0x0e5, 0x0e2, 0x0de, 0x0db,
    0x0d7, 0x0d4, 0x0d1, 0x0cd, 0x0ca, 0x0c7, 0x0c4, 0x0c1, 0x0be, 0x0bb, 0x0b8, 0x0b5, 0x0b2, 0x0af, 0x0ac, 0x0a9,
    0x0a7, 0x0a4, 0x0a1, 0x09f, 0x09c, 0x099, 0x097, 0x094, 0x092, 0x08f, 0x08d, 0x08a, 0x088, 0x086, 0x083, 0x081,
    0x07f, 0x07d, 0x07a, 0x078, 0x076, 0x074, 0x072, 0x070, 0x06e, 0x06c, 0x06a, 0x068, 0x066, 0x064, 0x062, 0x060,
    0x05e, 0x05c, 0x05b, 0x059, 0x057, 0x055, 0x053, 0x052, 0x050, 0x04e, 0x04d, 0x04b, 0x04a, 0x048, 0x046, 0x045,
    0x043, 0x042, 0x040, 0x03f, 0x03e, 0x03c, 0x03b, 0x039, 0x038, 0x037, 0x035, 0x034, 0x033, 0x031, 0x030, 0x02f,
    0x02e, 0x02d, 0x02b, 0x02a, 0x029, 0x028, 0x027, 0x026, 0x025, 0x024, 0x023, 0x022, 0x021, 0x020, 0x01f, 0x01e,
    0x01d, 0x01c, 0x01b, 0x01a, 0x019, 0x018, 0x017, 0x017, 0x016, 0x015, 0x014, 0x014, 0x013, 0x012, 0x011, 0x011,
    0x010, 0x00f, 0x00f, 0x00e, 0x00d, 0x00d, 0x00c, 0x00c, 0x00b, 0x00a, 0x00a, 0x009, 0x009, 0x008, 0x008, 0x007,
    0x007, 0x007, 0x006, 0x006, 0x005, 0x005, 0x005, 0x004, 0x004, 0x004, 0x003, 0x003, 0x003, 0x002, 0x002, 0x002,
    0x002, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000,
};

fn absSinAttenuation(index: u32) u32 {
    const i = if (bitfield(index, 8, 1) != 0) ~index else index;
    return sin_table[i & 0xff];
}

/// The operator waveform: |sin| attenuation, and the sign in bit 15.
const waveform: [waveform_length]u16 = blk: {
    @setEvalBranchQuota(10000);
    var w: [waveform_length]u16 = undefined;
    for (&w, 0..) |*v, i| v.* = @intCast(absSinAttenuation(i) | (bitfield(i, 9, 1) << 15));
    break :blk w;
};

/// 2^-x mantissas (10 bits, with the implied 0x400), from the die, pre-shifted by 2 and in
/// reverse order (ymfm's `attenuation_to_volume`).
const power_table: [256]u16 = blk: {
    const m = [256]u16{
        0x3fa, 0x3f5, 0x3ef, 0x3ea, 0x3e4, 0x3df, 0x3da, 0x3d4, 0x3cf, 0x3c9, 0x3c4, 0x3bf, 0x3b9, 0x3b4, 0x3ae, 0x3a9,
        0x3a4, 0x39f, 0x399, 0x394, 0x38f, 0x38a, 0x384, 0x37f, 0x37a, 0x375, 0x370, 0x36a, 0x365, 0x360, 0x35b, 0x356,
        0x351, 0x34c, 0x347, 0x342, 0x33d, 0x338, 0x333, 0x32e, 0x329, 0x324, 0x31f, 0x31a, 0x315, 0x310, 0x30b, 0x306,
        0x302, 0x2fd, 0x2f8, 0x2f3, 0x2ee, 0x2e9, 0x2e5, 0x2e0, 0x2db, 0x2d6, 0x2d2, 0x2cd, 0x2c8, 0x2c4, 0x2bf, 0x2ba,
        0x2b5, 0x2b1, 0x2ac, 0x2a8, 0x2a3, 0x29e, 0x29a, 0x295, 0x291, 0x28c, 0x288, 0x283, 0x27f, 0x27a, 0x276, 0x271,
        0x26d, 0x268, 0x264, 0x25f, 0x25b, 0x257, 0x252, 0x24e, 0x249, 0x245, 0x241, 0x23c, 0x238, 0x234, 0x230, 0x22b,
        0x227, 0x223, 0x21e, 0x21a, 0x216, 0x212, 0x20e, 0x209, 0x205, 0x201, 0x1fd, 0x1f9, 0x1f5, 0x1f0, 0x1ec, 0x1e8,
        0x1e4, 0x1e0, 0x1dc, 0x1d8, 0x1d4, 0x1d0, 0x1cc, 0x1c8, 0x1c4, 0x1c0, 0x1bc, 0x1b8, 0x1b4, 0x1b0, 0x1ac, 0x1a8,
        0x1a4, 0x1a0, 0x19c, 0x199, 0x195, 0x191, 0x18d, 0x189, 0x185, 0x181, 0x17e, 0x17a, 0x176, 0x172, 0x16f, 0x16b,
        0x167, 0x163, 0x160, 0x15c, 0x158, 0x154, 0x151, 0x14d, 0x149, 0x146, 0x142, 0x13e, 0x13b, 0x137, 0x134, 0x130,
        0x12c, 0x129, 0x125, 0x122, 0x11e, 0x11b, 0x117, 0x114, 0x110, 0x10c, 0x109, 0x106, 0x102, 0x0ff, 0x0fb, 0x0f8,
        0x0f4, 0x0f1, 0x0ed, 0x0ea, 0x0e7, 0x0e3, 0x0e0, 0x0dc, 0x0d9, 0x0d6, 0x0d2, 0x0cf, 0x0cc, 0x0c8, 0x0c5, 0x0c2,
        0x0be, 0x0bb, 0x0b8, 0x0b5, 0x0b1, 0x0ae, 0x0ab, 0x0a8, 0x0a4, 0x0a1, 0x09e, 0x09b, 0x098, 0x094, 0x091, 0x08e,
        0x08b, 0x088, 0x085, 0x082, 0x07e, 0x07b, 0x078, 0x075, 0x072, 0x06f, 0x06c, 0x069, 0x066, 0x063, 0x060, 0x05d,
        0x05a, 0x057, 0x054, 0x051, 0x04e, 0x04b, 0x048, 0x045, 0x042, 0x03f, 0x03c, 0x039, 0x036, 0x033, 0x030, 0x02d,
        0x02a, 0x028, 0x025, 0x022, 0x01f, 0x01c, 0x019, 0x016, 0x014, 0x011, 0x00e, 0x00b, 0x008, 0x006, 0x003, 0x000,
    };
    var t: [256]u16 = undefined;
    for (&t, m) |*v, x| v.* = (x | 0x400) << 2;
    break :blk t;
};

/// A 5.8 logarithmic attenuation to a 13-bit linear volume.
fn attenuationToVolume(input: u32) u32 {
    return @as(u32, power_table[input & 0xff]) >> @intCast(input >> 8);
}

/// The sums of a waveform's attenuation (at most `sin_table[0]`) and an envelope's (4.6 fixed
/// point, at most $3FF, shifted left by 2).
const volume_span = sin_table[0] + (0x3ff << 2) + 1;

/// The volume of each such sum (`attenuationToVolume`), then the same negated.
const signed_volume: [2 * volume_span]i16 = blk: {
    @setEvalBranchQuota(100000);
    var t: [2 * volume_span]i16 = undefined;
    for (0..volume_span) |i| {
        t[i] = @intCast(attenuationToVolume(i));
        t[volume_span + i] = -t[i];
    }
    break :blk t;
};

/// The waveform as indices into `signed_volume`: its attenuation, past `volume_span` when it is
/// negative.
const signed_waveform: [waveform_length]u16 = blk: {
    @setEvalBranchQuota(10000);
    var w: [waveform_length]u16 = undefined;
    for (&w, waveform) |*v, x| v.* = (x & 0x7fff) + if (x & 0x8000 != 0) volume_span else 0;
    break :blk w;
};

/// The operator's 14-bit signed output at a phase (its integer part, with the modulation) and an
/// envelope attenuation shifted left by 2, as `Ym2612.opComputeVolume` gives it for an operator
/// without SSG-EG's inversion: there, an envelope above `eg_quiet` gives 0 by the lookup itself.
inline fn waveVolume(phase: u32, eg4: u32) i32 {
    const index: u10 = @truncate(phase);
    // At most `2 * volume_span - 1`: no overflow.
    return signed_volume[signed_waveform[index] +% eg4];
}

/// Per 6-bit rate, eight 4-bit envelope increments (ymfm's `attenuation_increment`).
const increment_table = [64]u32{
    0x00000000, 0x00000000, 0x10101010, 0x10101010,
    0x10101010, 0x10101010, 0x11101110, 0x11101110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x10101010, 0x10111010, 0x11101110, 0x11111110,
    0x11111111, 0x21112111, 0x21212121, 0x22212221,
    0x22222222, 0x42224222, 0x42424242, 0x44424442,
    0x44444444, 0x84448444, 0x84848484, 0x88848884,
    0x88888888, 0x88888888, 0x88888888, 0x88888888,
};

fn attenuationIncrement(rate: u32, index: u32) u32 {
    return bitfield(increment_table[rate], @intCast(4 * index), 4);
}

/// Phase displacement by key code and detune (ymfm's `detune_adjustment`).
const detune_table = [32][4]u8{
    .{ 0, 0, 1, 2 },   .{ 0, 0, 1, 2 },   .{ 0, 0, 1, 2 },   .{ 0, 0, 1, 2 },
    .{ 0, 1, 2, 2 },   .{ 0, 1, 2, 3 },   .{ 0, 1, 2, 3 },   .{ 0, 1, 2, 3 },
    .{ 0, 1, 2, 4 },   .{ 0, 1, 3, 4 },   .{ 0, 1, 3, 4 },   .{ 0, 1, 3, 5 },
    .{ 0, 2, 4, 5 },   .{ 0, 2, 4, 6 },   .{ 0, 2, 4, 6 },   .{ 0, 2, 5, 7 },
    .{ 0, 2, 5, 8 },   .{ 0, 3, 6, 8 },   .{ 0, 3, 6, 9 },   .{ 0, 3, 7, 10 },
    .{ 0, 4, 8, 11 },  .{ 0, 4, 8, 12 },  .{ 0, 4, 9, 13 },  .{ 0, 5, 10, 14 },
    .{ 0, 5, 11, 16 }, .{ 0, 6, 12, 17 }, .{ 0, 6, 13, 19 }, .{ 0, 7, 14, 20 },
    .{ 0, 8, 16, 22 }, .{ 0, 8, 16, 22 }, .{ 0, 8, 16, 22 }, .{ 0, 8, 16, 22 },
};

fn detuneAdjustment(detune: u32, keycode: u32) i32 {
    const result: i32 = detune_table[keycode][detune & 3];
    return if (bitfield(detune, 2, 1) != 0) -result else result;
}

/// Two shifts per PM depth and LFO step: a cheap multiplication of the F-number's top 7 bits
/// (ymfm's `opn_lfo_pm_phase_adjustment`, written to match Nuked-OPN2).
const lfo_pm_shifts = [8][8]u8{
    .{ 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77 },
    .{ 0x77, 0x77, 0x77, 0x77, 0x72, 0x72, 0x72, 0x72 },
    .{ 0x77, 0x77, 0x77, 0x72, 0x72, 0x72, 0x17, 0x17 },
    .{ 0x77, 0x77, 0x72, 0x72, 0x17, 0x17, 0x12, 0x12 },
    .{ 0x77, 0x77, 0x72, 0x17, 0x17, 0x17, 0x12, 0x07 },
    .{ 0x77, 0x77, 0x17, 0x12, 0x07, 0x07, 0x02, 0x01 },
    .{ 0x77, 0x77, 0x17, 0x12, 0x07, 0x07, 0x02, 0x01 },
    .{ 0x77, 0x77, 0x17, 0x12, 0x07, 0x07, 0x02, 0x01 },
};

fn lfoPmPhaseAdjustment(fnum_bits: u32, pm_sensitivity: u32, lfo_raw_pm: i32) i32 {
    const abs_pm: u32 = @abs(lfo_raw_pm);
    const shifts = lfo_pm_shifts[pm_sensitivity][bitfield(abs_pm, 0, 3)];
    var adjust: i32 = @bitCast((fnum_bits >> @intCast(shifts & 0xf)) + (fnum_bits >> @intCast(shifts >> 4)));
    if (pm_sensitivity > 5) adjust <<= @intCast(pm_sensitivity - 5);
    adjust >>= 2;
    return if (lfo_raw_pm < 0) -adjust else adjust;
}

/// Inputs and outputs of the eight algorithms (ymfm's `s_algorithm_ops`): bit 0 the input of O2,
/// bits 1-3 of O3, bits 4-6 of O4 (indices into `opout`), bits 7-9 whether O1, O2, O3 are summed
/// into the output with O4.
const algorithm_ops = blk: {
    const A = struct {
        fn f(op2in: u16, op3in: u16, op4in: u16, op1out: u16, op2out: u16, op3out: u16) u16 {
            return op2in | (op3in << 1) | (op4in << 4) | (op1out << 7) | (op2out << 8) | (op3out << 9);
        }
    };
    break :blk [8]u16{
        A.f(1, 2, 3, 0, 0, 0), // 0: O1 -> O2 -> O3 -> O4 -> out (O4)
        A.f(0, 5, 3, 0, 0, 0), // 1: (O1 + O2) -> O3 -> O4 -> out (O4)
        A.f(0, 2, 6, 0, 0, 0), // 2: (O1 + (O2 -> O3)) -> O4 -> out (O4)
        A.f(1, 0, 7, 0, 0, 0), // 3: ((O1 -> O2) + O3) -> O4 -> out (O4)
        A.f(1, 0, 3, 0, 1, 0), // 4: ((O1 -> O2) + (O3 -> O4)) -> out (O2+O4)
        A.f(1, 1, 1, 0, 1, 1), // 5: ((O1 -> O2) + (O1 -> O3) + (O1 -> O4)) -> out (O2+O3+O4)
        A.f(1, 0, 0, 0, 1, 1), // 6: ((O1 -> O2) + O3 + O4) -> out (O2+O3+O4)
        A.f(0, 0, 0, 1, 1, 1), // 7: (O1 + O2 + O3 + O4) -> out (O1+O2+O3+O4)
    };
};

/// The LFO's divider per rate (ymfm's `lfo_max_count`).
const lfo_max_count = [8]u8{ 109, 78, 72, 68, 63, 45, 9, 6 };

pub const Ym2612 = struct {
    /// One sample every 144 clocks of the chip (6 prescale x 24 operators), the chip at master / 7.
    pub const cycles_per_sample: u32 = 7 * 144;

    variant: Variant = .ym2612,

    // The chip's interface (ymfm's ym2612).
    address: u16 = 0,
    dac_data: u16 = 0,
    dac_enable: u8 = 0,

    // The OPNA registers (ymfm's opn_registers_base<true>).
    regs: [registers]u8 = @splat(0),
    lfo_counter: u32 = 0,
    lfo_am: u8 = 0,
    /// The LFO's register fields, kept from one preparation to the next as the operators' are.
    lfo_enable: bool = false,
    lfo_rate: u32 = 0,

    // The FM engine (ymfm's fm_engine_base).
    env_counter: u32 = 0,
    total_clocks: u8 = 0,
    active_channels: u32 = all_channels,
    /// A register was written since the last preparation: the next sample prepares the channels
    /// (ymfm marks every channel modified at every write).
    written: bool = true,
    /// The channels whose registers changed since their data was cached (`channelsWritten`): a
    /// preparation caches theirs again, and only theirs, as the others' would come out the same.
    modified_channels: u32 = all_channels,
    prepare_count: u32 = 0,
    chans: [channels]Channel = blk: {
        var c: [channels]Channel = undefined;
        for (&c, 0..) |*ch, i| ch.* = .{ .choffs = channelOffset(i), .ops = operator_map[i] };
        break :blk c;
    },
    ops: [operators]Operator = blk: {
        var o: [operators]Operator = undefined;
        for (&o, 0..) |*op, i| op.* = .{ .choffs = 0, .opoffs = operatorOffset(i) };
        // Each operator's channel (ymfm's assign_operators).
        for (operator_map, 0..) |list, c| {
            for (list) |i| o[i].choffs = channelOffset(c);
        }
        break :blk o;
    },

    /// A chip in its power-on state.
    pub fn init(variant: Variant) Ym2612 {
        var y: Ym2612 = .{ .variant = variant };
        y.reset();
        return y;
    }

    /// ymfm's reset: the registers cleared (both outputs on for each channel), the mode register
    /// written with 0, the channels' and the operators' state cleared. The envelope and LFO
    /// counters, the address and the DAC keep their values, as in ymfm.
    pub fn reset(y: *Ym2612) void {
        y.regs = @splat(0);
        for ([_]usize{ 0xb4, 0xb5, 0xb6, 0x1b4, 0x1b5, 0x1b6 }) |r| y.regs[r] = 0xc0;
        y.engineWrite(reg_mode, 0);
        y.modified_channels = all_channels;
        for (&y.chans) |*ch| {
            ch.feedback = .{ 0, 0 };
            ch.feedback_in = 0;
        }
        for (&y.ops) |*op| op.reset();
    }

    /// A write to port 0 (address, part 1), 1 (data, part 1), 2 (address, part 2) or 3 (data,
    /// part 2).
    pub fn write(y: *Ym2612, port: u2, value: u8) void {
        switch (port) {
            0 => y.address = value,
            1 => {
                // A data write to part 1 after a part 2 address is ignored.
                if (y.address & 0x100 != 0) return;
                switch (y.address) {
                    // DAC data, the 8 most significant bits.
                    0x2a => y.dac_data = (y.dac_data & ~@as(u16, 0x1fe)) | (@as(u16, value ^ 0x80) << 1),
                    // DAC enable.
                    0x2b => y.dac_enable = value >> 7,
                    // Test register: the DAC's low bit.
                    0x2c => y.dac_data = (y.dac_data & ~@as(u16, 1)) | ((value >> 3) & 1),
                    else => y.engineWrite(y.address, value),
                }
            },
            2 => y.address = 0x100 | @as(u16, value),
            3 => {
                if (y.address & 0x100 == 0) return;
                y.engineWrite(y.address, value);
            },
        }
    }

    /// The next `out.len` samples: 16-bit-scaled stereo, as ymfm's `generate`.
    pub fn generate(y: *Ym2612, out: []Frame) void {
        var done: usize = 0;
        while (done < out.len) {
            const n = y.renderChannels(out[done..]);
            for (out[done..][0..n]) |*f| f.* = y.withDac(f.*);
            done += n;
        }
    }

    /// A sample of `renderChannels` with the DAC's value as it is now, scaled as ymfm scales it:
    /// the DAC's data written between `renderChannels` and this call is heard from this sample.
    pub inline fn withDac(y: *const Ym2612, channels_out: Frame) Frame {
        return y.scale(y.withDacRaw(channels_out));
    }

    /// `withDac` before the final scaling: the DAC replaces channel 6 when it is on.
    inline fn withDacRaw(y: *const Ym2612, channels_out: Frame) Frame {
        if (y.dac_enable == 0) return channels_out;
        const ch6 = &y.chans[5].cache;
        const dacval = y.dacValue();
        const dac: Frame = switch (y.variant) {
            .ym2612 => .{
                .left = if (ch6.output0) dacDiscontinuity(dacval) else dac_zero,
                .right = if (ch6.output1) dacDiscontinuity(dacval) else dac_zero,
            },
            .ym3438 => .{ .left = if (ch6.output0) dacval else 0, .right = if (ch6.output1) dacval else 0 },
        };
        return .{ .left = channels_out.left + dac.left, .right = channels_out.right + dac.right };
    }

    /// A sample before the final scaling, scaled as ymfm scales it (`scaled`).
    inline fn scale(y: *const Ym2612, raw: Frame) Frame {
        const table = &scale_tables[@backingInt(y.variant)];
        return .{ .left = table[@intCast(raw.left + raw_max)], .right = table[@intCast(raw.right + raw_max)] };
    }

    /// The most a sample before the scaling reaches either way: six channels of 9 bits (-257 to
    /// 256 after the clipping, or the DAC's -256 to 255), each moved by the YM2612's distortion.
    const raw_max = 6 * 260;

    /// A sum of the channels' outputs scaled as ymfm scales it.
    fn scaled(variant: Variant, raw: i32) i32 {
        return switch (variant) {
            // The discontinuity adds about 1/64 to the range: ymfm scales by 64/65 too.
            .ym2612 => @divTrunc(raw * 128 * 64, 6 * 65),
            .ym3438 => @divTrunc(raw * 128, 6),
        };
    }

    /// `scaled` of each sum, for each variant: no division per sample.
    const scale_tables: [2][2 * raw_max + 1]i32 = blk: {
        @setEvalBranchQuota(100000);
        var t: [2][2 * raw_max + 1]i32 = undefined;
        for (0..2) |v| {
            for (&t[v], 0..) |*x, i| x.* = scaled(@fromBackingInt(@as(u1, @intCast(v))), @as(i32, @intCast(i)) - raw_max);
        }
        break :blk t;
    };

    /// One sample before the final scaling (see `renderChannels`).
    pub fn sampleRaw(y: *Ym2612) Frame {
        var out: [1]Frame = undefined;
        _ = y.renderChannels(&out);
        return y.withDacRaw(out[0]);
    }

    /// The most samples rendered at once.
    const block_samples = 128;

    /// What the channels share over a block of samples, made once for all of them: per sample,
    /// the envelope counter and the LFO's PM and AM values.
    const Clocks = struct {
        len: usize = 0,
        env_counter: [block_samples]u32 = undefined,
        lfo_pm: [block_samples]i32 = undefined,
        lfo_am: [block_samples]u8 = undefined,
    };

    /// Renders the channels of the next samples into `out`, before the DAC's value and the final
    /// scaling (`withDac`): the sum of the FM channels' 9-bit outputs, channel 6's only when the
    /// DAC is off. The YM2612 variant applies the DAC's distortion to each channel, as its
    /// multiplexed output does (Nuked-OPN2's sum of its 24 output cycles, divided by its gain of
    /// 3, gives the same sums). Returns the number of samples, at least one: a block of up to
    /// `block_samples`, which ends before a preparation. Until `withDac` takes the last of them,
    /// the only writes allowed are the DAC's data (register $2A): it changes nothing else.
    ///
    /// ymfm clocks every channel, then outputs every channel, sample after sample. The channels
    /// share only their clocks (`Clocks`) and the preparation, and no write comes within a block:
    /// each channel runs through the whole block in turn, with the same results.
    pub fn renderChannels(y: *Ym2612, out: []Frame) usize {
        var clocks: Clocks = .{};
        y.clockShared(&clocks, @min(out.len, block_samples));
        const raw = out[0..clocks.len];
        var base: Frame = .{};
        // A channel that is not active gives 0, which the DAC moves to `dac_zero`.
        if (y.variant == .ym2612) {
            const fm: u32 = if (y.dac_enable != 0) all_channels >> 1 else all_channels;
            const quiet: i32 = @popCount(fm & ~y.active_channels);
            base.left += quiet * dac_zero;
            base.right += quiet * dac_zero;
        }
        @memset(raw, base);
        for (0..channels) |c| y.renderChannel(c, &clocks, raw);
        return raw.len;
    }

    /// Advances the clocks the channels share by up to `max` samples, into `clocks`: the first
    /// sample prepares the channels after a write, and every 4096 samples to catch ending notes
    /// (ymfm's `clock`); the block ends before the next preparation.
    fn clockShared(y: *Ym2612, clocks: *Clocks, max: usize) void {
        var due = y.written;
        if (!due) {
            due = y.prepare_count >= 4096;
            y.prepare_count += 1;
        }
        if (due) y.prepare();
        var n: usize = 0;
        while (true) {
            // The envelope runs once every 3 samples: the counter's low 2 bits count 0, 1, 2.
            y.env_counter +%= 1;
            if (bitfield(y.env_counter, 0, 2) == 3) y.env_counter +%= 1;
            clocks.env_counter[n] = y.env_counter;
            clocks.lfo_pm[n] = y.clockLfo();
            clocks.lfo_am[n] = y.lfo_am;
            n += 1;
            if (n == max or y.prepare_count >= 4096) break;
            y.prepare_count += 1;
        }
        clocks.len = n;
        y.total_clocks +%= @truncate(n);
    }

    /// Prepares the channels: their data cached again from the registers where they changed, the
    /// key ons and offs taken, the channels that can be heard found (`active_channels`).
    fn prepare(y: *Ym2612) void {
        y.lfo_enable = y.lfoEnable() != 0;
        y.lfo_rate = y.lfoRate();
        y.active_channels = 0;
        for (0..channels) |c| {
            if (y.chPrepare(c)) y.active_channels |= @as(u32, 1) << @intCast(c);
        }
        y.written = false;
        y.modified_channels = 0;
        y.prepare_count = 0;
    }

    /// Runs channel `c` through the block: clocks it, and adds its output to `raw`'s samples when
    /// it is active and not replaced by the DAC (`render` counts the others').
    fn renderChannel(y: *Ym2612, c: usize, clocks: *const Clocks, raw: []Frame) void {
        const dac = c == 5 and y.dac_enable != 0;
        if (bitfield(y.active_channels, @intCast(c), 1) != 0 and !dac) {
            y.runAudible(&y.chans[c], clocks, raw);
        } else y.runChannel(&y.chans[c], clocks, raw, false);
    }

    /// An active channel through the block: `runChannel`, which follows ymfm step by step, when
    /// one of its operators that are not silent has SSG-EG; else `runPlain`, its algorithm known.
    fn runAudible(y: *Ym2612, ch: *Channel, clocks: *const Clocks, raw: []Frame) void {
        var am = false;
        for (ch.ops, 0..) |i, n| {
            if (ch.live & (@as(u4, 1) << @intCast(n)) == 0) continue;
            const cache = &y.ops[i].cache;
            if (cache.ssg_eg_enable) return y.runChannel(ch, clocks, raw, true);
            am = am or cache.lfo_am_enable;
        }
        inline for (algorithm_ops) |algorithm| {
            if (ch.cache.algorithm == algorithm) {
                return if (am) y.runPlain(ch, clocks, raw, algorithm, true) else y.runPlain(ch, clocks, raw, algorithm, false);
            }
        }
        unreachable;
    }

    /// `runChannel` with output, for a channel whose operators that are not silent have no SSG-EG
    /// (their inversion is cleared at their first clock, and nothing else sets it), its algorithm
    /// `algorithm` (its `algorithm_ops`) and, with `am`, operators with the LFO's AM. It does the
    /// same work in fewer steps: each operator's envelope attenuation is worked out when the
    /// envelope moves or the AM offset changes, the routing is the algorithm's alone, and the
    /// volume is one lookup (`waveVolume`).
    fn runPlain(y: *Ym2612, ch: *Channel, clocks: *const Clocks, raw: []Frame, comptime algorithm: u16, comptime am: bool) void {
        const rshift = 5;
        const clipmax: i32 = 256;
        const clipmin = -clipmax - 1;
        const op = [4]*Operator{ &y.ops[ch.ops[0]], &y.ops[ch.ops[1]], &y.ops[ch.ops[2]], &y.ops[ch.ops[3]] };
        const distort = y.variant == .ym2612;
        const output0 = ch.cache.output0;
        const output1 = ch.cache.output1;
        const feedback = ch.cache.feedback;
        const am_shift = ch.cache.am_shift;
        var live = ch.live;
        // Per operator: the phase and its step (0 when silent: it is not clocked), the steps that
        // follow the LFO's PM, the envelope attenuation with the total level, and with the AM
        // offset when it applies, shifted left by 2.
        var phase: [4]u32 = @splat(0);
        var step: [4]u32 = @splat(0);
        var dynamic: u4 = 0;
        var base: [4]u32 = @splat(0);
        var am_mask: [4]u32 = @splat(0);
        var eg4: [4]u32 = @splat(0);
        // The envelope counters at which an operator's envelope can move (`envelopeMask`).
        var env_mask: [4]u32 = @splat(0);
        inline for (0..4) |n| {
            const bit = @as(u4, 1) << n;
            const cache = &op[n].cache;
            phase[n] = op[n].phase;
            if (live & bit != 0) {
                op[n].ssg_inverted = 0;
                step[n] = cache.phase_step;
                if (cache.phase_step == OpCache.phase_step_dynamic) dynamic |= bit;
                env_mask[n] = envelopeMask(op[n]);
            }
            base[n] = op[n].env_attenuation + cache.total_level;
            am_mask[n] = if (cache.lfo_am_enable) ~@as(u32, 0) else 0;
            eg4[n] = envelope4(base[n]);
        }
        // The AM offset, which changes with the LFO's steps.
        var am_offset: u32 = 0;
        if (am) {
            am_offset = (@as(u32, clocks.lfo_am[0]) << 1) >> am_shift;
            inline for (0..4) |n| eg4[n] = envelope4(base[n] + (am_offset & am_mask[n]));
        }
        var fb0: i32 = ch.feedback[0];
        var fb1: i32 = ch.feedback[1];
        var fb_in: i16 = ch.feedback_in;
        var pm: i32 = OpCache.pm_none;
        for (raw, 0..) |*f, i| {
            fb0 = fb1;
            fb1 = fb_in;
            // The clock: the phases, their steps again when the LFO's PM value changes; then the
            // envelopes when they run, those that can move.
            if (dynamic != 0 and clocks.lfo_pm[i] != pm) {
                pm = clocks.lfo_pm[i];
                inline for (0..4) |n| {
                    if (dynamic & (@as(u4, 1) << n) != 0) {
                        const cache = &op[n].cache;
                        if (cache.pm_value != pm) {
                            cache.pm_value = pm;
                            cache.pm_step = computePhaseStep(cache, pm);
                        }
                        step[n] = cache.pm_step;
                    }
                }
            }
            inline for (0..4) |n| phase[n] +%= step[n];
            const env_counter = clocks.env_counter[i];
            if (env_counter & 3 == 0 and live != 0) {
                const counter = env_counter >> 2;
                inline for (0..4) |n| {
                    const bit = @as(u4, 1) << n;
                    if (live & bit != 0 and counter & env_mask[n] == 0) {
                        opClockEnvelope(op[n], counter);
                        env_mask[n] = envelopeMask(op[n]);
                        base[n] = op[n].env_attenuation + op[n].cache.total_level;
                        eg4[n] = envelope4(base[n] + (am_offset & am_mask[n]));
                        if (opSilent(op[n])) {
                            live &= ~bit;
                            step[n] = 0;
                            dynamic &= ~bit;
                        }
                    }
                }
            }
            if (am) {
                const offset = (@as(u32, clocks.lfo_am[i]) << 1) >> am_shift;
                if (offset != am_offset) {
                    am_offset = offset;
                    inline for (0..4) |n| eg4[n] = envelope4(base[n] + (am_offset & am_mask[n]));
                }
            }

            // The output: O1 with its feedback, then the algorithm's routing.
            var mod1: i32 = 0;
            if (feedback != 0) mod1 = (fb0 + fb1) >> @intCast(10 - feedback);
            fb_in = @truncate(waveVolume((phase[0] >> 10) +% @as(u32, @bitCast(mod1)), eg4[0]));
            // With both outputs off, only the feedback is computed.
            if (!output0 and !output1) {
                if (distort) {
                    f.left += dac_zero;
                    f.right += dac_zero;
                }
                continue;
            }
            const o1: i16 = fb_in;
            const o2: i16 = @truncate(waveVolume((phase[1] >> 10) +% modulation(bitfield(algorithm, 0, 1), o1, 0, 0), eg4[1]));
            const o3: i16 = @truncate(waveVolume((phase[2] >> 10) +% modulation(bitfield(algorithm, 1, 3), o1, o2, 0), eg4[2]));
            var result = waveVolume((phase[3] >> 10) +% modulation(bitfield(algorithm, 4, 3), o1, o2, o3), eg4[3]) >> rshift;
            if (comptime bitfield(algorithm, 7, 1) != 0) result = @max(@min(result + (@as(i32, o1) >> rshift), clipmax), clipmin);
            if (comptime bitfield(algorithm, 8, 1) != 0) result = @max(@min(result + (@as(i32, o2) >> rshift), clipmax), clipmin);
            if (comptime bitfield(algorithm, 9, 1) != 0) result = @max(@min(result + (@as(i32, o3) >> rshift), clipmax), clipmin);

            const left = if (output0) result else 0;
            const right = if (output1) result else 0;
            if (distort) {
                f.left += dacDiscontinuity(left);
                f.right += dacDiscontinuity(right);
            } else {
                f.left += left;
                f.right += right;
            }
        }
        inline for (0..4) |n| {
            if (ch.live & (@as(u4, 1) << n) != 0) op[n].phase = phase[n];
        }
        ch.live = live;
        ch.feedback = .{ @intCast(fb0), @intCast(fb1) };
        ch.feedback_in = fb_in;
    }

    /// The bits of the envelope counter (`opClockEnvelope`'s, divided by 4) that are 0 when the
    /// operator's envelope can move: those of its state's rate, or none when its state changes at
    /// the next clock (it reached 0 in the attack, or its sustain level in the decay). In between,
    /// a clock of its envelope changes nothing.
    fn envelopeMask(op: *const Operator) u32 {
        const att = op.env_attenuation;
        if (op.env_state == .attack and att == 0) return 0;
        if (op.env_state == .decay and att >= op.cache.eg_sustain) return 0;
        const rate_shift: u5 = @intCast(op.cache.eg_rate[@backingInt(op.env_state)] >> 2);
        return @as(u32, 0x7ff) >> rate_shift;
    }

    /// An envelope attenuation with the total level and the AM offset, at most $3FF, shifted left
    /// by 2 for `waveVolume`.
    inline fn envelope4(attenuation: u32) u32 {
        return @as(u32, @min(attenuation, 0x3ff)) << 2;
    }

    /// The modulation of an operator by the input `index` of `algorithm_ops` (0: none; 1, 2, 3:
    /// O1, O2, O3; 5, 6, 7: O1 + O2, O1 + O3, O2 + O3), halved, as an addition to its phase.
    inline fn modulation(comptime index: u32, o1: i16, o2: i16, o3: i16) u32 {
        const in: i16 = switch (index) {
            0 => 0,
            1 => o1,
            2 => o2,
            3 => o3,
            5 => o1 +% o2,
            6 => o1 +% o3,
            7 => o2 +% o3,
            else => unreachable,
        };
        return @bitCast(@as(i32, in >> 1));
    }

    /// The channel's clock and, with `output`, its output by its algorithm, 9 bits after the shift
    /// of 5, added to the sides it is panned to (ymfm's `clock` and `output_4op` with rshift 5,
    /// clipmax 256), for each sample of the block.
    fn runChannel(y: *Ym2612, ch: *Channel, clocks: *const Clocks, raw: []Frame, comptime output: bool) void {
        const op = [4]*Operator{ &y.ops[ch.ops[0]], &y.ops[ch.ops[1]], &y.ops[ch.ops[2]], &y.ops[ch.ops[3]] };
        if (!output and ch.live == 0) {
            // Nothing to clock, nothing to output: the feedback's history only moves.
            ch.feedback[0] = if (raw.len == 1) ch.feedback[1] else ch.feedback_in;
            ch.feedback[1] = ch.feedback_in;
            return;
        }
        const rshift = 5;
        const clipmax: i32 = 256;
        const clipmin = -clipmax - 1;
        const cache = ch.cache;
        const distort = y.variant == .ym2612;
        for (raw, 0..) |*f, i| {
            ch.feedback[0] = ch.feedback[1];
            ch.feedback[1] = ch.feedback_in;
            // The operators that are not silent, in their order.
            if (ch.live != 0) {
                const env_counter = clocks.env_counter[i];
                const lfo_raw_pm = clocks.lfo_pm[i];
                inline for (0..4) |n| {
                    const bit = @as(u4, 1) << n;
                    if (ch.live & bit != 0) {
                        opClock(op[n], env_counter, lfo_raw_pm);
                        if (opSilent(op[n])) ch.live &= ~bit;
                    }
                }
            }
            if (!output) continue;

            const am_offset = (@as(u32, clocks.lfo_am[i]) << 1) >> cache.am_shift;

            // O1's feedback.
            var opmod: i32 = 0;
            if (cache.feedback != 0) opmod = (@as(i32, ch.feedback[0]) + ch.feedback[1]) >> @intCast(10 - cache.feedback);
            ch.feedback_in = @truncate(opComputeVolume(op[0], op[0].phaseInt() +% @as(u32, @bitCast(opmod)), am_offset));

            // With both outputs off, only the feedback is computed.
            if (!cache.output0 and !cache.output1) {
                if (distort) {
                    f.left += dac_zero;
                    f.right += dac_zero;
                }
                continue;
            }

            const algorithm = cache.algorithm;
            var opout: [8]i16 = @splat(0);
            opout[1] = ch.feedback_in;

            opmod = opout[bitfield(algorithm, 0, 1)] >> 1;
            opout[2] = @truncate(opComputeVolume(op[1], op[1].phaseInt() +% @as(u32, @bitCast(opmod)), am_offset));
            opout[5] = opout[1] +% opout[2];

            opmod = opout[bitfield(algorithm, 1, 3)] >> 1;
            opout[3] = @truncate(opComputeVolume(op[2], op[2].phaseInt() +% @as(u32, @bitCast(opmod)), am_offset));
            opout[6] = opout[1] +% opout[3];
            opout[7] = opout[2] +% opout[3];

            opmod = opout[bitfield(algorithm, 4, 3)] >> 1;
            var result = opComputeVolume(op[3], op[3].phaseInt() +% @as(u32, @bitCast(opmod)), am_offset);
            result >>= rshift;

            if (bitfield(algorithm, 7, 1) != 0) result = std.math.clamp(result + (@as(i32, opout[1]) >> rshift), clipmin, clipmax);
            if (bitfield(algorithm, 8, 1) != 0) result = std.math.clamp(result + (@as(i32, opout[2]) >> rshift), clipmin, clipmax);
            if (bitfield(algorithm, 9, 1) != 0) result = std.math.clamp(result + (@as(i32, opout[3]) >> rshift), clipmin, clipmax);

            const left = if (cache.output0) result else 0;
            const right = if (cache.output1) result else 0;
            if (distort) {
                f.left += dacDiscontinuity(left);
                f.right += dacDiscontinuity(right);
            } else {
                f.left += left;
                f.right += right;
            }
        }
    }

    /// The DAC's 9-bit signed value.
    fn dacValue(y: *const Ym2612) i32 {
        const v: i16 = @bitCast(y.dac_data << 7);
        return v >> 7;
    }

    /// The YM2612's DAC distortion: each channel's output moves away from 0 by 4 (positive) or 3
    /// (negative) steps, a silent channel included.
    inline fn dacDiscontinuity(value: i32) i32 {
        return if (value < 0) value - 3 else value + 4;
    }

    /// A silent channel through the DAC.
    const dac_zero = dacDiscontinuity(0);

    // ----- registers (ymfm's opn_registers_base<true>)

    fn byte(y: *const Ym2612, offset: u32, start: u5, count: u5, extra: u32) u32 {
        return bitfield(y.regs[offset + extra], start, count);
    }

    fn word(y: *const Ym2612, o1: u32, s1: u5, c1: u5, o2: u32, s2: u5, c2: u5, extra: u32) u32 {
        return (y.byte(o1, s1, c1, extra) << c2) | y.byte(o2, s2, c2, extra);
    }

    fn lfoEnable(y: *const Ym2612) u32 {
        return y.byte(0x22, 3, 1, 0);
    }
    fn lfoRate(y: *const Ym2612) u32 {
        return y.byte(0x22, 0, 3, 0);
    }
    fn multiFreq(y: *const Ym2612) bool {
        return y.byte(0x27, 6, 2, 0) != 0;
    }
    fn multiBlockFreq(y: *const Ym2612, num: u32) u32 {
        return y.word(0xac, 0, 6, 0xa8, 0, 8, num);
    }
    fn chBlockFreq(y: *const Ym2612, choffs: u32) u32 {
        return y.word(0xa4, 0, 6, 0xa0, 0, 8, choffs);
    }
    fn chFeedback(y: *const Ym2612, choffs: u32) u32 {
        return y.byte(0xb0, 3, 3, choffs);
    }
    fn chAlgorithm(y: *const Ym2612, choffs: u32) u32 {
        return y.byte(0xb0, 0, 3, choffs);
    }
    fn chOutput0(y: *const Ym2612, choffs: u32) bool {
        return y.byte(0xb4, 7, 1, choffs) != 0;
    }
    fn chOutput1(y: *const Ym2612, choffs: u32) bool {
        return y.byte(0xb4, 6, 1, choffs) != 0;
    }
    fn chLfoAmSens(y: *const Ym2612, choffs: u32) u32 {
        return y.byte(0xb4, 4, 2, choffs);
    }
    fn chLfoPmSens(y: *const Ym2612, choffs: u32) u32 {
        return y.byte(0xb4, 0, 3, choffs);
    }
    fn opDetune(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x30, 4, 3, opoffs);
    }
    fn opMultiple(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x30, 0, 4, opoffs);
    }
    fn opTotalLevel(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x40, 0, 7, opoffs);
    }
    fn opKsr(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x50, 6, 2, opoffs);
    }
    fn opAttackRate(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x50, 0, 5, opoffs);
    }
    fn opDecayRate(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x60, 0, 5, opoffs);
    }
    fn opLfoAmEnable(y: *const Ym2612, opoffs: u32) bool {
        return y.byte(0x60, 7, 1, opoffs) != 0;
    }
    fn opSustainRate(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x70, 0, 5, opoffs);
    }
    fn opSustainLevel(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x80, 4, 4, opoffs);
    }
    fn opReleaseRate(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x80, 0, 4, opoffs);
    }
    fn opSsgEgEnable(y: *const Ym2612, opoffs: u32) bool {
        return y.byte(0x90, 3, 1, opoffs) != 0;
    }
    fn opSsgEgMode(y: *const Ym2612, opoffs: u32) u32 {
        return y.byte(0x90, 0, 3, opoffs);
    }

    const KeyOn = struct { channel: u32, opmask: u32 };

    /// Stores a register write; the frequency registers go through their latches. Returns the
    /// key-on event of a write to $28.
    fn regsWrite(y: *Ym2612, index: u32, data: u8) ?KeyOn {
        // $A0-$AF: the upper halves only latch (one latch for $A4-$A6, one for $AC-$AE, shared by
        // the two parts); a write to a lower half applies the latch. Registers $B8-$BF hold the
        // latches.
        if (index & 0xf0 == 0xa0) {
            if (bitfield(index, 0, 2) == 3) return null;
            const latch = 0xb8 | bitfield(index, 3, 1);
            if (bitfield(index, 2, 1) != 0) {
                y.regs[latch] = data & 0x3f;
            } else {
                y.regs[index] = data;
                y.regs[index | 4] = y.regs[latch];
            }
            return null;
        } else if (index & 0xf8 == 0xb8) {
            return null;
        }
        y.regs[index] = data;
        if (index == 0x28) {
            var channel = bitfield(data, 0, 2);
            if (channel == 3) return null;
            channel += bitfield(data, 2, 1) * 3;
            return .{ .channel = channel, .opmask = bitfield(data, 4, 4) };
        }
        return null;
    }

    /// The channels whose cached data (`cacheChannelData`, `cacheOperatorData`) can change by a
    /// write to `regnum`: the channel of an operator's or a channel's register; every channel for
    /// the LFO; channel 3 for the mode register and its operators' own frequencies. The key ons
    /// are taken at each preparation, and the frequency latches and the other registers are not
    /// cached. A mask wider than needed only costs time.
    fn channelsWritten(regnum: u32) u32 {
        const index = regnum & 0xff;
        const part = regnum >> 8;
        // Bits 0-1 of an operator's or a channel's register are the channel in its part (3: none).
        const own: u32 = if (index & 3 == 3) 0 else @as(u32, 1) << @intCast((index & 3) + 3 * part);
        return switch (index) {
            0x22 => all_channels,
            0x27, 0xa8...0xaf => 1 << 2,
            0x30...0x9f, 0xa0...0xa3, 0xb0...0xb7 => own,
            else => 0,
        };
    }

    /// Clocks the LFO; returns the raw PM value (ymfm's `clock_noise_and_lfo`).
    fn clockLfo(y: *Ym2612) i32 {
        if (!y.lfo_enable) {
            y.lfo_counter = 0;
            // A stopped LFO sits at position 0, whose AM value is $3F.
            y.lfo_am = 0x3f;
            return 0;
        }
        const subcount: u32 = y.lfo_counter & 0xff;
        y.lfo_counter +%= 1;
        if (subcount >= lfo_max_count[y.lfo_rate]) y.lfo_counter +%= 0x101 - subcount;
        y.lfo_am = @intCast(bitfield(y.lfo_counter, 8, 6));
        if (bitfield(y.lfo_counter, 8 + 6, 1) == 0) y.lfo_am ^= 0x3f;
        return lfoRawPm(y.lfo_counter);
    }

    /// The LFO's raw PM value at a position of its counter: -7 to 7.
    fn lfoRawPm(lfo_counter: u32) i32 {
        var pm: i32 = @intCast(bitfield(lfo_counter, 10, 3));
        if (bitfield(lfo_counter, 10 + 3, 1) != 0) pm ^= 7;
        return if (bitfield(lfo_counter, 10 + 4, 1) != 0) -pm else pm;
    }

    fn cacheChannelData(y: *const Ym2612, choffs: u32, cache: *ChCache) void {
        cache.algorithm = algorithm_ops[y.chAlgorithm(choffs)];
        cache.feedback = y.chFeedback(choffs);
        cache.output0 = y.chOutput0(choffs);
        cache.output1 = y.chOutput1(choffs);
        cache.am_shift = @intCast((@as(u32, 1) << @intCast(y.chLfoAmSens(choffs) ^ 3)) - 1);
    }

    fn cacheOperatorData(y: *const Ym2612, choffs: u32, opoffs: u32, cache: *OpCache) void {
        var block_freq = y.chBlockFreq(choffs);
        // Channel 3's special mode: operators 1-3 have their own frequencies.
        if (y.multiFreq() and choffs == 2) {
            if (opoffs == 2) {
                block_freq = y.multiBlockFreq(1);
            } else if (opoffs == 10) {
                block_freq = y.multiBlockFreq(2);
            } else if (opoffs == 6) {
                block_freq = y.multiBlockFreq(0);
            }
        }
        cache.block_freq = block_freq;

        // The 5-bit key code: the block and the F-number's top bit, and a bit made of the next
        // three (YM2608 manual: F11 & (F10 | F9 | F8) | !F11 & F10 & F9 & F8).
        var keycode = bitfield(block_freq, 10, 4) << 1;
        keycode |= bitfield(0xfe80, @intCast(bitfield(block_freq, 7, 4)), 1);

        cache.detune = detuneAdjustment(y.opDetune(opoffs), keycode);
        cache.multiple = y.opMultiple(opoffs) * 2;
        if (cache.multiple == 0) cache.multiple = 1;

        cache.pm_sensitivity = y.chLfoPmSens(choffs);
        cache.pm_value = OpCache.pm_none;
        if (y.lfoEnable() == 0 or cache.pm_sensitivity == 0) {
            cache.phase_step = computePhaseStep(cache, 0);
        } else {
            cache.phase_step = OpCache.phase_step_dynamic;
        }
        cache.ssg_eg_enable = y.opSsgEgEnable(opoffs);
        cache.ssg_eg_mode = y.opSsgEgMode(opoffs);
        cache.lfo_am_enable = y.opLfoAmEnable(opoffs);

        cache.total_level = y.opTotalLevel(opoffs) << 3;

        // A sustain level of 15 means 31.
        cache.eg_sustain = y.opSustainLevel(opoffs);
        cache.eg_sustain |= (cache.eg_sustain + 1) & 0x10;
        cache.eg_sustain <<= 5;

        const ksrval = keycode >> @intCast(y.opKsr(opoffs) ^ 3);
        cache.eg_rate[@backingInt(EnvelopeState.attack)] = effectiveRate(y.opAttackRate(opoffs) * 2, ksrval);
        cache.eg_rate[@backingInt(EnvelopeState.decay)] = effectiveRate(y.opDecayRate(opoffs) * 2, ksrval);
        cache.eg_rate[@backingInt(EnvelopeState.sustain)] = effectiveRate(y.opSustainRate(opoffs) * 2, ksrval);
        cache.eg_rate[@backingInt(EnvelopeState.release)] = effectiveRate(y.opReleaseRate(opoffs) * 4 + 2, ksrval);
    }

    fn effectiveRate(rawrate: u32, ksr: u32) u8 {
        return if (rawrate == 0) 0 else @intCast(@min(rawrate + ksr, 63));
    }

    fn computePhaseStep(cache: *const OpCache, lfo_raw_pm: i32) u32 {
        var fnum = bitfield(cache.block_freq, 0, 11) << 1;
        const pm_sensitivity = cache.pm_sensitivity;
        if (pm_sensitivity != 0) {
            fnum +%= @bitCast(lfoPmPhaseAdjustment(bitfield(cache.block_freq, 4, 7), pm_sensitivity, lfo_raw_pm));
            fnum &= 0xfff;
        }
        const block: u5 = @intCast(bitfield(cache.block_freq, 11, 3));
        var phase_step = (fnum << block) >> 2;
        phase_step +%= @bitCast(cache.detune);
        // Detune can overflow: 17 bits are kept.
        phase_step &= 0x1ffff;
        return (phase_step * cache.multiple) >> 1;
    }

    // ----- operators (ymfm's fm_operator)

    /// `modified`: the operator's registers changed since its data was cached.
    fn opPrepare(y: *Ym2612, op: *Operator, modified: bool) bool {
        if (modified) y.cacheOperatorData(op.choffs, op.opoffs, &op.cache);
        opClockKeystate(op, @intFromBool(op.keyon_live != 0));
        op.keyon_live &= ~@as(u8, 1 << keyon_csm);
        return op.env_state != .release or op.env_attenuation < eg_quiet;
    }

    inline fn opClock(op: *Operator, env_counter: u32, lfo_raw_pm: i32) void {
        if (op.cache.ssg_eg_enable) {
            opClockSsgEgState(op);
        } else {
            op.ssg_inverted = 0;
        }
        if (bitfield(env_counter, 0, 2) == 0) opClockEnvelope(op, env_counter >> 2);
        var phase_step = op.cache.phase_step;
        if (phase_step == OpCache.phase_step_dynamic) {
            // A function of the cached data and the PM value: computed again when the value
            // changes (and after each preparation, which sets `pm_value` to none).
            if (op.cache.pm_value != lfo_raw_pm) {
                op.cache.pm_value = lfo_raw_pm;
                op.cache.pm_step = computePhaseStep(&op.cache, lfo_raw_pm);
            }
            phase_step = op.cache.pm_step;
        }
        op.phase +%= phase_step;
    }

    /// The operator's 14-bit signed output for a phase and an AM offset.
    inline fn opComputeVolume(op: *const Operator, phase: u32, am_offset: u32) i32 {
        if (op.env_attenuation > eg_quiet) return 0;
        const sin_attenuation: u32 = waveform[phase & (waveform_length - 1)];
        const env_attenuation = opEnvelopeAttenuation(op, am_offset) << 2;
        const result: i32 = @intCast(attenuationToVolume((sin_attenuation & 0x7fff) + env_attenuation));
        return if (bitfield(sin_attenuation, 15, 1) != 0) -result else result;
    }

    fn opKeyOnOff(op: *Operator, on: u32, kind: u3) void {
        op.keyon_live = (op.keyon_live & ~(@as(u8, 1) << kind)) | (@as(u8, @intCast(on & 1)) << kind);
    }

    fn opStartAttack(op: *Operator, is_restart: bool) void {
        if (op.env_state == .attack) return;
        op.env_state = .attack;
        if (!is_restart) {
            op.ssg_inverted = @intCast(@intFromBool(op.cache.ssg_eg_enable) & bitfield(op.cache.ssg_eg_mode, 2, 1));
            op.phase = 0;
        }
        if (op.cache.eg_rate[@backingInt(EnvelopeState.attack)] >= 62) op.env_attenuation = 0;
    }

    fn opStartRelease(op: *Operator) void {
        if (@backingInt(op.env_state) >= @backingInt(EnvelopeState.release)) return;
        op.env_state = .release;
        if (op.ssg_inverted != 0) {
            op.env_attenuation = @intCast((0x200 -% @as(u32, op.env_attenuation)) & 0x3ff);
            op.ssg_inverted = 0;
        }
    }

    fn opClockKeystate(op: *Operator, keystate: u8) void {
        if (keystate ^ op.key_state != 0) {
            op.key_state = keystate;
            if (keystate != 0) {
                opStartAttack(op, false);
            } else {
                opStartRelease(op);
            }
        }
    }

    fn opClockSsgEgState(op: *Operator) void {
        if (bitfield(op.env_attenuation, 9, 1) == 0) return;
        const mode = op.cache.ssg_eg_mode;
        if (bitfield(mode, 0, 1) != 0) {
            // Hold modes (1, 3, 5, 7).
            op.ssg_inverted = @intCast(bitfield(mode, 2, 1) ^ bitfield(mode, 1, 1));
            if (op.env_state != .attack) op.env_attenuation = if (op.ssg_inverted != 0) 0x200 else 0x3ff;
        } else {
            // Continuous modes (0, 2, 4, 6).
            op.ssg_inverted ^= @intCast(bitfield(mode, 1, 1));
            if (op.env_state == .decay or op.env_state == .sustain) opStartAttack(op, true);
            if (bitfield(mode, 1, 1) == 0) op.phase = 0;
        }
        if (op.env_state == .release) op.env_attenuation = 0x3ff;
    }

    fn opClockEnvelope(op: *Operator, env_counter_in: u32) void {
        if (op.env_state == .attack and op.env_attenuation == 0) op.env_state = .decay;
        // Right after the attack, so that a sustain level of 0 skips the decay.
        if (op.env_state == .decay and op.env_attenuation >= op.cache.eg_sustain) op.env_state = .sustain;

        const rate: u32 = op.cache.eg_rate[@backingInt(op.env_state)];
        const rate_shift: u5 = @intCast(rate >> 2);
        const env_counter = env_counter_in << rate_shift;
        if (bitfield(env_counter, 0, 11) != 0) return;

        const relevant_bits = bitfield(env_counter, if (rate_shift <= 11) 11 else rate_shift, 3);
        const increment = attenuationIncrement(rate, relevant_bits);

        if (op.env_state == .attack) {
            // Attack rates 62 and 63 do not increment after the key on (handled there).
            if (rate < 62) {
                const att: u32 = op.env_attenuation;
                op.env_attenuation = @truncate(att +% ((~att *% increment) >> 4));
            }
        } else {
            if (!op.cache.ssg_eg_enable) {
                op.env_attenuation +%= @intCast(increment);
            } else if (op.env_attenuation < 0x200) {
                op.env_attenuation +%= @intCast(4 * increment);
            }
            if (op.env_attenuation >= 0x400) op.env_attenuation = 0x3ff;
        }
    }

    inline fn opEnvelopeAttenuation(op: *const Operator, am_offset: u32) u32 {
        var result: u32 = op.env_attenuation;
        if (op.ssg_inverted != 0) result = (0x200 -% result) & 0x3ff;
        if (op.cache.lfo_am_enable) result += am_offset;
        result += op.cache.total_level;
        return @min(result, 0x3ff);
    }

    // ----- channels (ymfm's fm_channel)

    fn chPrepare(y: *Ym2612, c: usize) bool {
        const ch = &y.chans[c];
        const modified = bitfield(y.modified_channels, @intCast(c), 1) != 0;
        if (modified) y.cacheChannelData(ch.choffs, &ch.cache);
        var active: u32 = 0;
        ch.live = 0;
        for (ch.ops, 0..) |i, n| {
            if (y.opPrepare(&y.ops[i], modified)) active |= @as(u32, 1) << @intCast(n);
            if (!opSilent(&y.ops[i])) ch.live |= @as(u4, 1) << @intCast(n);
        }
        return active != 0;
    }

    /// Whether the operator is released and at the most attenuation, where its clock changes
    /// nothing that is ever heard, so that it is not clocked: its envelope stays there (the
    /// release adds to it and clamps it to $3FF; SSG-EG sets it to $3FF in the release); its
    /// output is 0 (above `eg_quiet`); it leaves the release only by a key on, which sets its
    /// phase to 0 and its SSG-EG inversion afresh (`opStartAttack`), the only state its clock
    /// changes. Its phase is then stale, as nothing reads it.
    inline fn opSilent(op: *const Operator) bool {
        return op.env_state == .release and op.env_attenuation == 0x3ff;
    }

    // ----- the engine (ymfm's fm_engine_base)

    fn engineWrite(y: *Ym2612, regnum: u32, data: u8) void {
        // Every write prepares the channels again at the next sample.
        y.written = true;
        y.modified_channels |= channelsWritten(regnum);
        if (regnum == reg_mode) {
            // The mode register: ymfm then updates its timers, which this port leaves out.
            _ = y.regsWrite(reg_mode, data);
            return;
        }
        if (y.regsWrite(regnum, data)) |k| {
            for (y.chans[k.channel].ops, 0..) |i, n| opKeyOnOff(&y.ops[i], bitfield(k.opmask, @intCast(n), 1), keyon_normal);
        }
    }
};

// ----- tests: synthetic register streams, no game data

const testing = std.testing;

fn writeReg(y: *Ym2612, part: u1, reg: u8, value: u8) void {
    y.write(@as(u2, part) * 2, reg);
    y.write(@as(u2, part) * 2 + 1, value);
}

/// A sine tone on channel 1: algorithm 7, only O4 audible, the others at TL $7F.
fn sineVoice(y: *Ym2612, block: u8, fnum: u16, ar: u8, d1r: u8, d1l: u8, rr: u8) void {
    writeReg(y, 0, 0xb0, 0x07);
    for ([_]u8{ 0x30, 0x34, 0x38, 0x3c }) |r| writeReg(y, 0, r, 0x01); // DT 0, MUL 1
    for ([_]u8{ 0x40, 0x44, 0x48 }) |r| writeReg(y, 0, r, 0x7f);
    writeReg(y, 0, 0x4c, 0x00);
    for ([_]u8{ 0x50, 0x54, 0x58, 0x5c }) |r| writeReg(y, 0, r, ar);
    for ([_]u8{ 0x60, 0x64, 0x68, 0x6c }) |r| writeReg(y, 0, r, d1r);
    for ([_]u8{ 0x70, 0x74, 0x78, 0x7c }) |r| writeReg(y, 0, r, 0);
    for ([_]u8{ 0x80, 0x84, 0x88, 0x8c }) |r| writeReg(y, 0, r, (d1l << 4) | rr);
    writeReg(y, 0, 0xa4, (block << 3) | @as(u8, @intCast(fnum >> 8)));
    writeReg(y, 0, 0xa0, @intCast(fnum & 0xff));
}

/// Counts the rising zero crossings of channel 1 over `n` samples (raw, left).
fn risingCrossings(y: *Ym2612, n: usize) usize {
    var count: usize = 0;
    var prev: i32 = y.sampleRaw().left;
    for (0..n) |_| {
        const v = y.sampleRaw().left;
        if (prev < 0 and v >= 0) count += 1;
        prev = v;
    }
    return count;
}

test "a single tone has the frequency of its F-number and block" {
    var y = Ym2612.init(.ym3438);
    // f = fnum * 2^block * rate / 2^21 at MUL 1: fnum 1000, block 4 gives 406.4 Hz at 53,267 Hz.
    sineVoice(&y, 4, 1000, 31, 0, 0, 15);
    writeReg(&y, 0, 0x28, 0xf0);
    const rate = chip.master_clock / Ym2612.cycles_per_sample;
    const n = rate * 2; // two seconds
    const crossings = risingCrossings(&y, n);
    // 1000 * 16 / 2^21 cycles per sample: 812.7 cycles in two seconds.
    const expected = 1000 * 16 * n / (1 << 21);
    try testing.expect(crossings + 1 >= expected and crossings <= expected + 1);
}

test "the phase step: F-number, block, multiple and detune" {
    var y = Ym2612.init(.ym3438);
    sineVoice(&y, 4, 1000, 31, 0, 0, 15);
    writeReg(&y, 0, 0x3c, 0x03); // O4: MUL 3
    _ = y.sampleRaw();
    // (fnum << 1 << block) >> 2, times MUL: 8000 * 3.
    try testing.expectEqual(@as(u32, 8000 * 3), y.ops[9].cache.phase_step);
    writeReg(&y, 0, 0x3c, 0x00); // MUL 0 means 1/2
    _ = y.sampleRaw();
    try testing.expectEqual(@as(u32, 4000), y.ops[9].cache.phase_step);
    // DT 3 at key code 17 (block 4, F11 = 0, F10-F8 = 111): +8; DT 7: -8.
    writeReg(&y, 0, 0x3c, 0x31);
    _ = y.sampleRaw();
    try testing.expectEqual(@as(u32, 8000 + 8), y.ops[9].cache.phase_step);
    writeReg(&y, 0, 0x3c, 0x71);
    _ = y.sampleRaw();
    try testing.expectEqual(@as(u32, 8000 - 8), y.ops[9].cache.phase_step);
}

test "the envelope: instant attack, decay to the sustain level, release" {
    var y = Ym2612.init(.ym3438);
    // AR 31 (instant), D1R 20, D1L 4 (attenuation 4 * 32), RR 8.
    sineVoice(&y, 4, 1000, 31, 20, 4, 8);
    writeReg(&y, 0, 0x28, 0xf0);
    _ = y.sampleRaw();
    const op = &y.ops[9];
    try testing.expectEqual(EnvelopeState.attack, op.env_state);
    try testing.expectEqual(@as(u16, 0), op.env_attenuation);
    // The decay rises monotonically to the sustain level and stays there.
    var last: u16 = 0;
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        _ = y.sampleRaw();
        try testing.expect(op.env_attenuation >= last);
        last = op.env_attenuation;
    }
    try testing.expectEqual(EnvelopeState.sustain, op.env_state);
    try testing.expect(op.env_attenuation >= 4 * 32 and op.env_attenuation < 4 * 32 + 8);
    // The release goes to silence and the channel becomes inactive.
    writeReg(&y, 0, 0x28, 0x00);
    i = 0;
    while (i < 200000 and op.env_attenuation < 0x3ff) : (i += 1) _ = y.sampleRaw();
    try testing.expectEqual(EnvelopeState.release, op.env_state);
    try testing.expectEqual(@as(u16, 0x3ff), op.env_attenuation);
    for (0..5000) |_| _ = y.sampleRaw();
    try testing.expectEqual(@as(u32, 0), y.active_channels & 1);
}

test "the attack's exponential shape: fast at first, slower near full level" {
    var y = Ym2612.init(.ym3438);
    sineVoice(&y, 4, 1000, 16, 0, 0, 15);
    writeReg(&y, 0, 0x28, 0xf0);
    const op = &y.ops[9];
    var trace: [4]u16 = undefined;
    var i: usize = 0;
    var k: usize = 0;
    while (k < trace.len) : (i += 1) {
        _ = y.sampleRaw();
        if (i % 600 == 599) {
            trace[k] = op.env_attenuation;
            k += 1;
        }
    }
    // Each interval takes a fraction of what is left: the steps shrink.
    try testing.expect(trace[0] < 0x3ff);
    try testing.expect(0x3ff - trace[0] > trace[0] - trace[1]);
    try testing.expect(trace[0] - trace[1] > trace[1] - trace[2]);
}

test "the DAC replaces channel 6, with the YM2612's distortion" {
    var y = Ym2612.init(.ym2612);
    writeReg(&y, 0, 0x2b, 0x80);
    writeReg(&y, 0, 0x2a, 0xc0); // +64 in 8 bits: +128 in 9 bits
    const raw = y.sampleRaw();
    // Five silent FM channels at +4 each, the DAC at 128 + 4.
    try testing.expectEqual(@as(i32, 5 * 4 + 132), raw.left);
    writeReg(&y, 0, 0x2a, 0x40); // -64: -128
    try testing.expectEqual(@as(i32, 5 * 4 - 128 - 3), y.sampleRaw().right);
    var clean = Ym2612.init(.ym3438);
    writeReg(&clean, 0, 0x2b, 0x80);
    writeReg(&clean, 0, 0x2a, 0x40);
    try testing.expectEqual(@as(i32, -128), clean.sampleRaw().left);
    // Pan: channel 6 on the left only.
    writeReg(&y, 1, 0xb6, 0x80);
    const panned = y.sampleRaw();
    try testing.expectEqual(@as(i32, 5 * 4 - 131), panned.left);
    try testing.expectEqual(@as(i32, 5 * 4 + 4), panned.right);
}

test "silence at power-on, and a data write needs its part's address" {
    var y = Ym2612.init(.ym2612);
    const raw = y.sampleRaw();
    try testing.expectEqual(@as(i32, 6 * 4), raw.left);
    try testing.expectEqual(@as(i32, 6 * 4), raw.right);
    y.write(2, 0xb0); // part 2's address, then part 1's data port: ignored
    y.write(1, 0x07);
    try testing.expectEqual(@as(u8, 0), y.regs[0xb0]);
    try testing.expectEqual(@as(u8, 0), y.regs[0x1b0]);
    y.write(3, 0x07);
    try testing.expectEqual(@as(u8, 0x07), y.regs[0x1b0]);
}

test "the frequency latch: the upper half applies with the lower" {
    var y = Ym2612.init(.ym2612);
    writeReg(&y, 0, 0xa4, 0x22);
    try testing.expectEqual(@as(u8, 0), y.regs[0xa4]);
    writeReg(&y, 0, 0xa0, 0x55);
    try testing.expectEqual(@as(u8, 0x22), y.regs[0xa4]);
    try testing.expectEqual(@as(u32, 0x2255), y.chBlockFreq(0));
}

test "a silent operator's clock changes only what its key on sets afresh" {
    var prng = std.Random.DefaultPrng.init(0x2a6d365a);
    const r = prng.random();
    for (0..2000) |_| {
        var op: Operator = .{ .choffs = 0, .opoffs = 0 };
        op.phase = r.int(u32);
        op.ssg_inverted = r.uintLessThan(u8, 2);
        op.cache.ssg_eg_enable = r.boolean();
        op.cache.ssg_eg_mode = r.uintLessThan(u32, 8);
        op.cache.phase_step = r.uintLessThan(u32, 0x20000);
        for (&op.cache.eg_rate) |*rate| rate.* = r.uintLessThan(u8, 64);
        try testing.expect(Ym2612.opSilent(&op));
        var clocked = op;
        var env_counter = r.int(u32);
        for (0..r.uintLessThan(usize, 3000)) |_| {
            env_counter +%= 1;
            if (bitfield(env_counter, 0, 2) == 3) env_counter +%= 1;
            Ym2612.opClock(&clocked, env_counter, 0);
            try testing.expect(Ym2612.opSilent(&clocked));
        }
        // Its output is 0 whatever its phase.
        try testing.expectEqual(@as(i32, 0), Ym2612.opComputeVolume(&clocked, clocked.phase, 0));
        Ym2612.opClockKeystate(&clocked, 1);
        Ym2612.opClockKeystate(&op, 1);
        try testing.expectEqual(op, clocked);
    }
}

test "the phase step with the LFO's PM: the step of the sample's PM value" {
    var y = Ym2612.init(.ym3438);
    sineVoice(&y, 4, 1000, 31, 0, 0, 15);
    writeReg(&y, 0, 0xb4, 0xc7); // PM sensitivity 7
    writeReg(&y, 0, 0x28, 0xf0);
    const op = &y.ops[9];
    var changes: usize = 0;
    for (0..8) |rate| {
        writeReg(&y, 0, 0x22, 0x08 | @as(u8, @intCast(rate)));
        var last_pm: i32 = Ym2612.lfoRawPm(y.lfo_counter);
        for (0..5000) |_| {
            const before = op.phase;
            _ = y.sampleRaw();
            const pm = Ym2612.lfoRawPm(y.lfo_counter);
            try testing.expectEqual(OpCache.phase_step_dynamic, op.cache.phase_step);
            try testing.expectEqual(Ym2612.computePhaseStep(&op.cache, pm), op.phase -% before);
            if (pm != last_pm) changes += 1;
            last_pm = pm;
        }
    }
    // The PM value changed often (454 times over the eight rates).
    try testing.expect(changes > 400);
}

/// A random register write: key ons and offs of any operators, the operators' and the channels'
/// registers (fast releases and SSG-EG often), the LFO.
fn randomWrite(y: *Ym2612, r: std.Random) void {
    const part: u1 = r.int(u1);
    switch (r.uintLessThan(u8, 10)) {
        0, 1 => writeReg(y, 0, 0x28, (r.int(u8) & 0xf0) | r.uintLessThan(u8, 3) | (@as(u8, r.int(u1)) << 2)),
        2 => writeReg(y, 0, 0x22, r.int(u8) & 0x0f),
        3 => writeReg(y, part, 0x80 + r.uintLessThan(u8, 16), r.int(u8) | 0x0c),
        4 => writeReg(y, part, 0x90 + r.uintLessThan(u8, 16), r.int(u8) & 0x0f),
        5 => writeReg(y, part, 0xa0 + r.uintLessThan(u8, 3) * 4 + r.uintLessThan(u8, 3), r.int(u8)),
        6 => writeReg(y, part, 0xb0 + r.uintLessThan(u8, 2) * 4 + r.uintLessThan(u8, 3), r.int(u8)),
        else => writeReg(y, part, 0x30 + r.uintLessThan(u8, 0x60), r.int(u8)),
    }
}

test "the operators clocked are those not silent" {
    var prng = std.Random.DefaultPrng.init(0x2a6d365a);
    const r = prng.random();
    var y = Ym2612.init(.ym2612);
    var woken: usize = 0;
    var slept: usize = 0;
    for (0..3000) |_| {
        for (0..r.uintLessThan(u8, 4)) |_| randomWrite(&y, r);
        for (0..r.uintLessThan(u16, 300)) |_| {
            var before: [channels]u4 = undefined;
            for (y.chans, 0..) |ch, c| before[c] = ch.live;
            _ = y.sampleRaw();
            for (y.chans, 0..) |ch, c| {
                for (ch.ops, 0..) |i, n| {
                    const live = ch.live & (@as(u4, 1) << @intCast(n)) != 0;
                    try testing.expectEqual(!Ym2612.opSilent(&y.ops[i]), live);
                }
                woken += @popCount(ch.live & ~before[c]);
                slept += @popCount(before[c] & ~ch.live);
            }
        }
    }
    // Operators woke and fell silent often (about 750 times each).
    try testing.expect(woken > 500 and slept > 500);
}

comptime {
    chip.check(Ym2612);
}

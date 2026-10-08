//! The interface every sound chip of the synthesiser implements, so that a core can be replaced by
//! another one (another YM2612 core, for instance) without touching the rest.
//!
//! A chip is a value type with:
//!
//! - `pub const cycles_per_sample: u32`: the Mega Drive master clock cycles (53,693,175 Hz, NTSC)
//!   per sample at the chip's native rate;
//! - `pub fn reset(self: *T) void`: the power-on state;
//! - `pub fn write(self: *T, port: u2, value: u8) void`: one write to one of the chip's ports,
//!   applied before the next sample it generates;
//! - `pub fn generate(self: *T, out: []Frame) void`: the next `out.len` samples at its native rate.
//!
//! A PSG core may also tell its runs of samples that keep its level, which the synthesiser then
//! does not generate one by one: `pub fn steady(self: *const T) u32`, asked after a sample with no
//! write since, the number of next samples equal to it, and `pub fn skip(self: *T, n: u32) void`,
//! which takes `n` of them at once (see `Psg`).
//!
//! A YM2612 core may also render its channels apart from the DAC's value, so that the DAC's
//! values, written every few samples while a PCM sample plays, do not cut its work into small
//! blocks: `pub fn renderChannels(self: *T, out: []Frame) usize`, the next samples of its channels
//! (at least one, at most `out.len`), after which only the DAC's data may be written until
//! `pub fn withDac(self: *const T, channels: Frame) Frame` gives each of them with the DAC's value
//! at its time (see `Ym2612`).
//!
//! The synthesiser takes its chips as comptime parameters (`Synth(Fm, Psg)`): a game is a value,
//! and a chip held behind a pointer to its own owner would break when the game is copied.
//! Everything is integer arithmetic, so the samples are the same on every platform.

/// One stereo sample at a chip's native rate. The scale is the chip's own; the mixer
/// (`model1.zig`) gives each chip its level.
pub const Frame = struct {
    left: i32 = 0,
    right: i32 = 0,
};

/// The master clock of an NTSC Mega Drive, in Hz: the 68000 runs at master / 7, the Z80 and the
/// PSG's clock at master / 15, the YM2612's at master / 7.
pub const master_clock: u32 = 53_693_175;

/// Refuses, at compile time, a type that does not implement the chip interface.
pub fn check(comptime T: type) void {
    const cycles: u32 = T.cycles_per_sample;
    if (cycles == 0) @compileError(@typeName(T) ++ ": cycles_per_sample is 0");
    const Reset = fn (*T) void;
    const Write = fn (*T, u2, u8) void;
    const Generate = fn (*T, []Frame) void;
    if (@TypeOf(T.reset) != Reset) @compileError(@typeName(T) ++ ".reset must be " ++ @typeName(Reset));
    if (@TypeOf(T.write) != Write) @compileError(@typeName(T) ++ ".write must be " ++ @typeName(Write));
    if (@TypeOf(T.generate) != Generate) @compileError(@typeName(T) ++ ".generate must be " ++ @typeName(Generate));
}

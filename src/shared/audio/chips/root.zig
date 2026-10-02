//! The sound chips of the Mega Drive and the output of the original model 1, which turn the sound
//! sequencer's writes into PCM (PLAN item 09, decision D1), carried over from sor-remaster:
//!
//! - `chip.zig`: the interface a chip core implements (write a port, generate samples at its
//!   native rate), so that a core can be replaced;
//! - `ym2612.zig`: the YM2612, a Zig port of ymfm (BSD-3-Clause, its notice in the file);
//! - `psg.zig`: the PSG, Sega's SN76489 variant;
//! - `dac.zig`: PCM samples played through the YM2612's DAC as the Z80 plays them;
//! - `model1.zig`: the model 1's mix and low-pass filter, which can be switched off;
//! - `resample.zig`: the resampling to the host's rate;
//! - `synth.zig`: all of it on the master clock's time.
//!
//! Integer arithmetic throughout: the PCM is the same on every platform.
pub const chip = @import("chip.zig");
pub const ym2612 = @import("ym2612.zig");
pub const registers = @import("registers.zig");
pub const psg = @import("psg.zig");
pub const dac = @import("dac.zig");
pub const model1 = @import("model1.zig");
pub const resample = @import("resample.zig");
pub const synth = @import("synth.zig");

pub const Frame = chip.Frame;
pub const Ym2612 = ym2612.Ym2612;
pub const Psg = psg.Psg;
pub const Dac = dac.Dac;
pub const Synth = synth.Synth;

test {
    @import("std").testing.refAllDecls(@This());
}

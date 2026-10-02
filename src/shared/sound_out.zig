//! The game's sound on its way to the platform (DESIGN.md 3.4): each display tick's stereo frames
//! at the device's rate. A tick lasts the console's frame, so a tick's frames are counted exactly
//! from the device's rate and the tick rate, and the device's queue can pace the game (game.zig):
//! the sound keeps the device's time and never drifts. Network play's balancing stretches the
//! frames of a tick by up to 0.5 % (DESIGN.md 9), which slows the peer that is ahead.
//!
//! The frames are silence for now. TODO(PLAN item 09): the sequencer and the chip models
//! (src/shared/audio) make each tick's frames here, from the sounds the game asks for.
const std = @import("std");

/// The display tick's rate, in ticks a second: the console's frame (NTSC), its master clock
/// (53,693,175 Hz) over the clock's periods in a frame (896,040). 59.92 ticks a second.
pub const tick_rate_numerator: u64 = 53_693_175;
pub const tick_rate_denominator: u64 = 896_040;

/// A tick's time in picoseconds (rounded down): 16.69 ms.
pub const tick_ps: u64 = tick_rate_denominator * 1_000_000_000_000 / tick_rate_numerator;

/// The format the game asks of the platform.
pub const channels = 2;
pub const rate: u32 = 48000;

/// The largest stretch of a tick's frames, in millionths (0.5 %).
pub const max_stretch_ppm: u32 = 5000;

pub const SoundOut = struct {
    /// The device's rate, in frames a second.
    rate: u32,
    /// The fraction of a frame that the ticks so far left over, in 1 / `unit` of a frame.
    rest: u64 = 0,
    /// Room for the frames of a tick at the largest stretch.
    frames: []i16,

    const unit: u64 = tick_rate_numerator * 1_000_000;

    pub fn init(allocator: std.mem.Allocator, device_rate: u32) error{OutOfMemory}!SoundOut {
        var self: SoundOut = .{ .rate = device_rate, .frames = &.{} };
        self.frames = try allocator.alloc(i16, channels * self.maxFrames());
        return self;
    }

    pub fn deinit(self: *SoundOut, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        self.* = undefined;
    }

    /// The most frames that a tick has, at the largest stretch.
    pub fn maxFrames(self: *const SoundOut) u32 {
        return @intCast(@as(u64, self.rate) * (1_000_000 + max_stretch_ppm) * tick_rate_denominator / unit + 1);
    }

    /// The next tick's frames, interleaved stereo, `stretch_ppm` millionths longer than the tick's
    /// time at the device's rate (network play's balancing; 0 otherwise). They stay valid until
    /// the next call.
    pub fn tick(self: *SoundOut, stretch_ppm: u32) []const i16 {
        const ppm: u64 = @min(stretch_ppm, max_stretch_ppm);
        self.rest += @as(u64, self.rate) * (1_000_000 + ppm) * tick_rate_denominator;
        const n: usize = @intCast(self.rest / unit);
        self.rest %= unit;
        const out = self.frames[0 .. channels * n];
        @memset(out, 0);
        return out;
    }
};

test "a tick's frames add up to the device's rate, exactly, and the stretch lengthens them" {
    var out = try SoundOut.init(std.testing.allocator, 48000);
    defer out.deinit(std.testing.allocator);
    // 53,693,175 ticks last 896,040 seconds: 896,040 x 48,000 frames.
    var frames: u64 = 0;
    for (0..53_693) |_| frames += out.tick(0).len / channels;
    try std.testing.expectEqual(@as(u64, 53_693 * 48000 * 896_040 / 53_693_175), frames);
    try std.testing.expect(out.maxFrames() >= 805);
    var stretched: u64 = 0;
    for (0..1000) |_| {
        const f = out.tick(max_stretch_ppm);
        try std.testing.expect(f.len / channels <= out.maxFrames());
        stretched += f.len / channels;
    }
    try std.testing.expect(stretched >= 805_000 and stretched <= 805_100);
    try std.testing.expectEqual(@as(u64, 16_688_154_500), tick_ps);
}

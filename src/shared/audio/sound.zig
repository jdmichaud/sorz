//! The game's sound (DESIGN.md A1): the sounds by name, one update per display tick, the PCM.
//!
//! ```
//! var sound = try Sound.init(gpa, &content, 48000);
//! const punch = sound.find("enemy hit").?;
//! sound.play(punch);
//! const frames = sound.tick(); // stereo, interleaved, about 801 frames at 48 kHz
//! ```
const std = @import("std");
const content = @import("content.zig");
const Sequencer = @import("sequencer.zig").Sequencer;
const Output = @import("output.zig").Output;

/// A sound of the content, by its index in `Content.sounds`.
pub const Id = u16;

pub const Sound = struct {
    sounds: *const content.Content,
    sequencer: Sequencer,
    output: Output,

    /// `c` outlives the sound; `rate` is the host's frames per second.
    pub fn init(gpa: std.mem.Allocator, c: *const content.Content, rate: u32) !Sound {
        return .{
            .sounds = c,
            .sequencer = .init(c),
            .output = try .init(gpa, c, rate, true),
        };
    }

    pub fn deinit(s: *Sound, gpa: std.mem.Allocator) void {
        s.output.deinit(gpa);
    }

    /// The sound named `name` ("menu move", "round 1 music"...).
    pub fn find(s: *const Sound, name: []const u8) ?Id {
        return s.sounds.find(name);
    }

    /// Asks for a sound at the next tick (three wait at most; a sound already waiting is not
    /// asked again; a fourth is dropped).
    pub fn play(s: *Sound, id: Id) void {
        s.sequencer.request(id);
    }

    /// Asks for a sound in the first place, replacing what waits there (some of the original's
    /// requests are made so: the pause jingle, the round's song).
    pub fn playFirst(s: *Sound, id: Id) void {
        s.sequencer.requestFirst(id);
    }

    /// One display tick: the sequencer's update, then its PCM (stereo, interleaved), valid until
    /// the next tick.
    pub fn tick(s: *Sound) []const i16 {
        return s.output.tick(s.sequencer.update());
    }
};

test "a sound by name: a tone, then silence when it ends" {
    const gpa = std.testing.allocator;
    const resting = [_]content.Event{ .{ .rest = 1 }, .end };
    const tone = [_]content.Event{ .{ .instrument = 0 }, .{ .volume = 0 }, .{ .note = .{ .duration = 30, .octave = 4, .key = 9 } }, .end };
    var driver: content.Driver = .{};
    for (&driver.fm_keys, 0..) |*k, i| k.* = 0x284 + 0x2A * @as(u16, @intCast(i));
    driver.carriers[7] = .{ true, true, true, true };
    const instrument: content.Instrument = .{ .number = 0, .algorithm = 7, .feedback = 0, .operators = @splat(.{ .multiple = 1, .attack = 31, .release = 15 }) };
    const c: content.Content = .{
        .driver = driver,
        .songs = &.{.{ .name = "tune", .instruments = &.{instrument}, .fm = .{ .{ .events = &tone }, .{ .events = &resting }, .{ .events = &resting }, .{ .events = &resting }, .{ .events = &resting } }, .drums = .{ .events = &.{ .{ .rest = 256 }, .{ .jump = 0 } } }, .psg = &.{} }},
        .sounds = &.{.{ .name = "tune", .priority = 128, .plays = .{ .song = 0 } }},
    };
    var sound = try Sound.init(gpa, &c, 48000);
    defer sound.deinit(gpa);
    try std.testing.expectEqual(@as(?Id, null), sound.find("nothing"));
    sound.play(sound.find("tune").?);
    var loud: u32 = 0;
    for (0..60) |t| {
        const frames = sound.tick();
        try std.testing.expect(frames.len >= 2 * 800 and frames.len <= 2 * 802);
        var peak: u32 = 0;
        for (frames) |v| peak = @max(peak, @abs(v));
        if (peak > 1000) loud += 1;
        // Silent after the note and its release.
        if (t > 40) try std.testing.expect(peak < 1000);
    }
    try std.testing.expect(loud >= 28);
}

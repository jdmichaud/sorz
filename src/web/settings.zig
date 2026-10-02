//! The game's settings in the browser (DESIGN.md 5.3, 7). The record `settings.json`, kept by the
//! page with the game's other records, is the page's only settings; the player changes it on the
//! game's settings screen (a scene to come, PLAN item 19). The page applies its sound and window as
//! a browser does them, from what the module tells it (`View`): the volume as the gain of the
//! page's output (the game then queues its sound at full volume, `Game.host_volume`, so that this
//! gain is the only one), the window's scale as the picture's whole multiple in the page, and full
//! screen as the page's.
const std = @import("std");
const sorz = @import("sorz");
const record = sorz.settings.record;
const Settings = record.Settings;

/// What the page applies of the settings.
pub const View = struct {
    /// The gain of the page's output: the square of the volume's fraction, the native game's
    /// curve (game.zig's `atVolume`), or 0 with the sound off.
    gain: f64,
    /// The picture's whole multiple in the page (the largest that fits the browser's window, when
    /// it is smaller).
    scale: u8,
    /// The page's full screen, which a browser gives only at a click or a key.
    fullscreen: bool,

    pub fn of(s: *const Settings) View {
        const v: f64 = @floatFromInt(s.sound.volume);
        const max: f64 = @floatFromInt(record.max_volume);
        return .{
            .gain = if (s.sound.mute) 0 else (v / max) * (v / max),
            .scale = s.window.scale,
            .fullscreen = s.window.fullscreen,
        };
    }
};

test "the view: the native game's volume curve, the scale and full screen" {
    var s: Settings = .{};
    try std.testing.expectEqual(View{ .gain = 1, .scale = 3, .fullscreen = false }, View.of(&s));
    s.sound.volume = 30;
    s.window = .{ .scale = 1, .fullscreen = true };
    const v = View.of(&s);
    try std.testing.expectApproxEqAbs(@as(f64, 0.09), v.gain, 1e-12);
    try std.testing.expectEqual(@as(u8, 1), v.scale);
    try std.testing.expect(v.fullscreen);
    s.sound.mute = true;
    try std.testing.expectEqual(@as(f64, 0), View.of(&s).gain);
}

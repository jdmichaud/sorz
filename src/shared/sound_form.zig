//! A machine's sound as it plays, in a form that another machine loads (canonical.zig): network
//! play's join carries it beside the game's form (DESIGN.md 9), so that the guest's sound goes on
//! from the host's, its music and the effects under way at the same place, from the session's
//! first tick. The sound is each machine's own, outside the game's state (DESIGN.md 6): this form
//! is the join's alone, never hashed or checked with the game's.
//!
//! It holds the sequencer, its tracks' events named by their place in the content; the chips,
//! the sample playing named by its number; the resampler as the host had it, which the guest
//! takes to its own rate (`Resampler.setRate` keeps the next frame's place between its inputs);
//! the sounds asked for the next update; and the frame's transfers due (game.zig `Due`). The two
//! machines have the same content (the handshake compares it), so the names are the same on both.
const std = @import("std");
const canonical = @import("canonical.zig");
const audio = @import("audio/root.zig");
const sound_out = @import("sound_out.zig");
const Due = @import("game.zig").Due;

const content = audio.content;
const Sequencer = audio.Sequencer;
const Synth = audio.chips.synth.Default;

/// A track's events, by their place in the content.
pub const Events = union(enum) {
    none,
    /// A song's track: 0 to 4 its FM tracks, 5 its drums, 6 and on its PSG tracks.
    song: struct { song: u16, track: u8 },
    effect: u16,
};

pub const Form = struct {
    sequencer: Sequencer,
    events: [audio.sequencer.track_count]Events,
    synth: Synth,
    /// The sample the chips play, by its number.
    sample: ?u8,
    /// The sounds asked for the next update, in order.
    asked: [max_asked]?audio.sound.Id,
    due: Due,
};

const max_asked = @typeInfo(@FieldType(sound_out.SoundOut, "asked")).array.len;

/// The most bytes of a form.
pub const max_size = canonical.maxSize(Form);

/// The form of `so`'s sound, the frame's transfers `due`, into `out` (`max_size` bytes); null
/// without the content's sound, or when a track's events or the sample are not the content's.
pub fn write(so: *const sound_out.SoundOut, due: Due, out: []u8) ?[]u8 {
    const s = if (so.sound) |*x| x else return null;
    const c = s.sounds;
    var form: Form = .{
        .sequencer = s.sequencer,
        .events = undefined,
        .synth = s.output.synth,
        .sample = null,
        .asked = @splat(null),
        .due = due,
    };
    for (&form.events, s.sequencer.tracks) |*e, t| e.* = eventsOf(c, t.events) orelse return null;
    const d = &s.output.synth.dac;
    if (d.values.len != 0) form.sample = sampleOf(c, d.values) orelse return null;
    for (so.asked[0..so.asked_len], 0..) |id, i| form.asked[i] = id;
    return canonical.write(Form, &form, out);
}

pub const LoadError = canonical.ReadError || error{NoSound};

/// `so`'s sound from now on is the one `bytes` is the form of, and the frame's transfers `due`
/// its; at this machine's rate and stretch. A form that does not read leaves the sound as it was.
pub fn load(so: *sound_out.SoundOut, due: *Due, bytes: []const u8) LoadError!void {
    const s = if (so.sound) |*x| x else return error.NoSound;
    const c = s.sounds;
    // What the form leaves out stays this machine's: the content, the timings made from it.
    var form: Form = .{
        .sequencer = s.sequencer,
        .events = undefined,
        .synth = s.output.synth,
        .sample = null,
        .asked = @splat(null),
        .due = .{},
    };
    try canonical.read(Form, bytes, &form);
    var tracks: [audio.sequencer.track_count][]const content.Event = undefined;
    for (&tracks, form.events) |*t, e| t.* = eventsAt(c, e) orelse return error.Malformed;
    const sample: ?*const content.Sample = if (form.sample) |n| c.sample(n) orelse return error.Malformed else null;
    var asked_len: u8 = 0;
    for (form.asked) |a| if (a) |id| {
        if (id >= c.sounds.len) return error.Malformed;
        asked_len += 1;
    };

    const rate = s.output.synth.resampler.rate;
    s.sequencer = form.sequencer;
    for (&s.sequencer.tracks, tracks) |*t, events| t.events = events;
    s.sequencer.tick.len = 0;
    s.sequencer.fault = null;
    s.output.synth = form.synth;
    const d = &s.output.synth.dac;
    if (sample) |x| {
        d.values = x.values;
        d.steps = s.output.steps[x.number];
    } else {
        d.values = &.{};
        d.steps = &.{};
    }
    s.output.synth.resampler.setRate(rate);
    so.asked_len = 0;
    for (form.asked) |a| if (a) |id| {
        so.asked[so.asked_len] = id;
        so.asked_len += 1;
    };
    due.* = form.due;
}

/// Where `events` are in the content; null when they are not the content's.
fn eventsOf(c: *const content.Content, events: []const content.Event) ?Events {
    if (events.len == 0) return .none;
    for (c.songs, 0..) |*song, n| {
        for (song.fm, 0..) |t, k| if (same(t.events, events)) return .{ .song = .{ .song = @intCast(n), .track = @intCast(k) } };
        if (same(song.drums.events, events)) return .{ .song = .{ .song = @intCast(n), .track = 5 } };
        for (song.psg, 0..) |t, k| if (same(t.events, events)) return .{ .song = .{ .song = @intCast(n), .track = @intCast(6 + k) } };
    }
    for (c.effects, 0..) |*effect, n| if (same(effect.events, events)) return .{ .effect = @intCast(n) };
    return null;
}

/// The events at `e` in the content; null when the content has no such place.
fn eventsAt(c: *const content.Content, e: Events) ?[]const content.Event {
    return switch (e) {
        .none => &.{},
        .song => |x| blk: {
            if (x.song >= c.songs.len) break :blk null;
            const song = &c.songs[x.song];
            break :blk switch (x.track) {
                0...4 => song.fm[x.track].events,
                5 => song.drums.events,
                else => if (x.track - 6 < song.psg.len) song.psg[x.track - 6].events else null,
            };
        },
        .effect => |n| if (n < c.effects.len) c.effects[n].events else null,
    };
}

fn same(a: []const content.Event, b: []const content.Event) bool {
    return a.ptr == b.ptr and a.len == b.len;
}

/// The number of the sample whose values are `values`; null when they are no sample's.
fn sampleOf(c: *const content.Content, values: []const u8) ?u8 {
    for (c.samples) |*x| if (x.values.ptr == values.ptr and x.values.len == values.len) return x.number;
    return null;
}

const testing = std.testing;

test "a sound loaded from another's form plays on as it does: the same frames" {
    const gpa = testing.allocator;
    const tone = [_]content.Event{ .{ .instrument = 0 }, .{ .volume = 0 }, .{ .note = .{ .duration = 40, .octave = 4, .key = 9 } }, .{ .jump = 0 } };
    const resting = [_]content.Event{ .{ .rest = 1 }, .end };
    var driver: content.Driver = .{};
    for (&driver.fm_keys, 0..) |*k, i| k.* = 644 + 42 * @as(u16, @intCast(i));
    driver.carriers[7] = .{ true, true, true, true };
    const instrument: content.Instrument = .{ .number = 0, .algorithm = 7, .feedback = 0, .operators = @splat(.{ .multiple = 1, .attack = 31, .release = 15 }) };
    const blip = [_]content.Event{ .{ .instrument = 0 }, .{ .note = .{ .duration = 20, .octave = 5, .key = 2 } }, .end };
    const c: content.Content = .{
        .driver = driver,
        .songs = &.{.{ .name = "tune", .instruments = &.{instrument}, .fm = .{ .{ .events = &tone }, .{ .events = &resting }, .{ .events = &resting }, .{ .events = &resting }, .{ .events = &resting } }, .drums = .{ .events = &.{ .{ .rest = 256 }, .{ .jump = 0 } } }, .psg = &.{} }},
        .effects = &.{.{ .name = "blip", .channel = .fm4, .volume_offset = 0, .instruments = &.{instrument}, .events = &blip }},
        .sounds = &.{ .{ .name = "tune", .priority = 128, .plays = .{ .song = 0 } }, .{ .name = "blip", .priority = 10, .plays = .{ .effect = 0 } } },
    };
    var host = try sound_out.SoundOut.init(gpa, 48000, &c);
    defer host.deinit(gpa);
    host.ask(0);
    for (0..30) |_| _ = host.play(0, &.{}, &.{}, true, false, false, 0, 0);
    // An effect under way, a sound asked for the next update.
    _ = host.play(0, &.{}, &.{1}, true, false, false, 0, 0);
    for (0..5) |_| _ = host.play(0, &.{}, &.{}, true, false, false, 0, 0);
    host.ask(1);
    var buf: [max_size]u8 = undefined;
    const form = write(&host, .{ .held = 7, .work = 3 }, &buf).?;
    try testing.expectEqual(Events{ .song = .{ .song = 0, .track = 0 } }, eventsOf(&c, host.sound.?.sequencer.tracks[0].events).?);

    var guest = try sound_out.SoundOut.init(gpa, 48000, &c);
    defer guest.deinit(gpa);
    _ = guest.play(0, &.{}, &.{}, true, false, false, 0, 0);
    var due: Due = .{};
    try load(&guest, &due, form);
    try testing.expectEqual(Due{ .held = 7, .work = 3 }, due);
    var peak: u32 = 0;
    for (0..60) |_| {
        const a = try gpa.dupe(i16, host.play(0, &.{}, &.{}, true, false, false, 0, 0));
        defer gpa.free(a);
        try testing.expectEqualSlices(i16, a, guest.play(0, &.{}, &.{}, true, false, false, 0, 0));
        for (a) |v| peak = @max(peak, @abs(v));
    }
    // The tune plays on: the frames are not silence.
    try testing.expect(peak > 1000);
    // A form that does not read leaves the sound as it was.
    try testing.expectError(error.Malformed, load(&guest, &due, form[0 .. form.len - 1]));
}

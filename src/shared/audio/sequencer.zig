//! The sequencer (DESIGN.md A2): it plays the songs and the effects of the sound content with the
//! original driver's semantics, once per display tick (`update`), and its output is the chips'
//! writes of that tick (`Tick`): the YM2612's and the PSG's registers, and the requests to the
//! sample player, which the output stage turns into PCM.
//!
//! - A song plays on FM1 to FM5, the drum track (FM6's sample player) and up to three PSG tracks.
//!   An effect plays on FM3 or FM4: it takes the song's channel, which keeps its time silently, and
//!   gives it back when it ends (the song's instrument loaded again, the next note heard).
//! - Requests wait in three slots until the next update. Of those read at once, the last whose
//!   priority is at least the playing effect's wins; a song's priority is never kept, so songs
//!   never hold off effects, and an effect holds off lower ones only while it plays.
//! - Durations are in updates; there is no tempo. A note is cut by its gate; ties continue a note.
//! - The fade lowers the FM tracks fifteen times, every fifth update, then stops everything;
//!   while it runs, the slots are not read. The pause (the pause jingle's command) silences the
//!   song every update until the jingle comes again; effects go on.
//!
//! The original's quirks that the sound depends on are kept as named rules, each where it acts:
//! the PassQuirk (`Pass`: an effect that gives its channel back mid-update makes the effects after
//! it act as the song), `clearedTrackChannel` (a cleared track names FM1), the stray loop end of
//! round 6's music (`loopCounter`), the envelope read on past its end by rests (`envelopeStep`),
//! the drum hold (`clock.zig`), the drum track's end that ends the update (`step`), and the stop
//! that stops again at the next update (`Current.stop`).
const std = @import("std");
const content = @import("content.zig");
const Event = content.Event;
const chips = @import("chips/registers.zig");
const Channel = chips.Channel;
const clock_mod = @import("clock.zig");
const Clock = clock_mod.Clock;

/// A write of the tick: where, and the value (for a request to the sample player: the sample's
/// number, or `stop_code`, or `none_code`).
pub const Write = struct {
    port: chips.Port,
    value: u8,
};

pub const stop_code: u8 = 255;
pub const none_code: u8 = 254;

/// A song's priority, and any from it up, is never kept: songs never hold off effects.
const song_priority = 128;

/// One update's output: the writes in order, and the cycles the bus was held (the sample player
/// is delayed by as much).
pub const Tick = struct {
    writes: [capacity]Write = undefined,
    len: usize = 0,
    /// Writes that did not fit (no update makes that many).
    lost: usize = 0,
    hold: u32 = 0,

    pub const capacity = 4096;

    pub fn items(t: *const Tick) []const Write {
        return t.writes[0..t.len];
    }
};

/// The track flags, in the order of the original's (the stray loop end counts with them as a
/// byte: `loopCounter`).
pub const Flags = packed struct(u8) {
    /// Music tracks: an effect holds the channel (nothing is written). The drum track: a voice
    /// played at its last hit.
    held: bool = false,
    rest: bool = false,
    /// FM: FM3's special mode. PSG: noise.
    special: bool = false,
    vibrato: bool = false,
    /// PSG: the envelope held or ended, the channel silent.
    silent: bool = false,
    tie: bool = false,
    /// An effect track ended: its channel goes back to the song at the next update.
    ended: bool = false,
    playing: bool = false,
};

pub const Kind = enum { fm, drums, psg };

/// What a step did: went on, or left its caller too (the original's routines that pop their
/// caller's return).
const Flow = enum { next, unwind };

/// A track's state.
pub const Track = struct {
    flags: Flags = .{},
    channel: Channel = clearedTrackChannel,
    /// Set when a song or an effect starts the track; only the stray loop end reads it.
    started: u8 = 0,
    volume_offset: u8 = 0,
    events: []const Event = &.{},
    /// The next event's index.
    pos: u16 = 0,
    /// FM: the carriers' attenuation; PSG: the attenuation.
    volume: u8 = 0,
    /// FM: the volume level; PSG: the instrument's number (kept, never used).
    level: u8 = 0,
    /// FM: the instrument's number; PSG: the envelope's.
    instrument: u8 = 0,
    /// The loop counts, the top at depth 1 (`loopCounter`).
    loops: [6]u8 = @splat(0),
    depth: i8 = 0,
    gate: u8 = 0,
    duration: u8 = 0,
    /// FM: block and F-number in one word; PSG: the divider.
    pitch: u16 = 0,
    /// The drum track: the request of its next hit, and the one kept during a rest.
    sample: clock_mod.Request = .none,
    saved_sample: clock_mod.Request = .none,
    envelope_pos: u8 = 0,
    /// FM: the channel's output byte (speakers, LFO sensitivities).
    output: u8 = 0,
    vib_delay: u8 = 0,
    vib_period: u8 = 0,
    vib_step: u16 = 0,
    vib_count: u8 = 0,
    vib_delay_left: u8 = 0,
    vib_period_left: u8 = 0,
    vib_step_now: u16 = 0,
    vib_count_left: u8 = 0,
    vib_offset: u16 = 0,
    /// The algorithm and feedback byte of the instrument loaded last.
    algorithm: u8 = 0,
    detune: u16 = 0,
    detune_applied: u16 = 0,
    /// The register tweak to write again after each volume change.
    tweak: ?content.Tweak = null,

    /// The events are the content's: a machine's sound in its form names their track instead
    /// (sound_form.zig).
    pub const canonical_skip = [_][]const u8{"events"};

    fn kind(t: *const Track, index: usize) Kind {
        if (index == drum_track) return .drums;
        return if (t.channel.isPsg()) .psg else .fm;
    }
};

/// A cleared track names FM1: the original's cleared record holds channel code 0. An effect that
/// starts on FM3 while no song has set the song's FM3 track up silences FM1 (`startEffect`).
pub const clearedTrackChannel: Channel = .fm1;

/// The tracks, in the original's order (the stray loop end reads the next one's state).
pub const track_count = 11;
const song_fm = 0; // five FM tracks
pub const drum_track = 5;
const song_psg = 6; // three PSG tracks
const effect_fm3 = 9;
const effect_fm4 = 10;

/// Which part of an update runs: it decides the instrument list (the song's or the last effect's)
/// and FM3's offsets, whether a tweak is written again after a volume change, and whether a track
/// that ends gives its channel back. The PassQuirk: an effect that gives its channel back during
/// the effects' part sets it back to `song`, so the effects stepped after it in that update act as
/// the song's tracks; and the part left set by the previous update is what the requests and the
/// fade see.
pub const Pass = enum { song, effects, extra };

/// The request being handled: none, a sound, or a stop (the cleared state, which the next update
/// reads as a stop: a stop, a song's start and the fade's end stop everything twice).
pub const Current = union(enum) {
    none,
    stop,
    sound: u16,
};

pub const Pause = enum { running, paused, resuming };

/// Something the sequencer met that it cannot play as the original does: the update's remaining
/// work is not done. Not expected with the extracted content.
pub const Fault = struct { what: []const u8, detail: u32 = 0 };

pub const Sequencer = struct {
    sounds: *const content.Content,
    timings: [32]clock_mod.Timing = @splat(.{}),
    tracks: [track_count]Track = @splat(.{}),
    /// The request slots, by sound index.
    slots: [3]?u16 = @splat(null),
    current: Current = .stop,
    /// The playing effect's priority (0: none).
    priority: u8 = 0,
    fade: u8 = 0,
    fade_delay: u8 = 0,
    pause: Pause = .running,
    pass: Pass = .song,
    /// The song whose instruments the song's tracks use, and the effect whose instruments the
    /// effects use (the last started: an effect playing on FM3 while one starts on FM4 uses the
    /// new one's list).
    song: ?u16 = null,
    effect: ?u16 = null,
    fm3_song: [4]u8 = @splat(0),
    fm3_effects: [4]u8 = @splat(0),
    clock: Clock = .{},
    tick: Tick = .{},
    /// Held cycles of the current update.
    held: u32 = 0,
    fault: ?Fault = null,

    /// Out of a machine's sound in its form (sound_form.zig): the content, the samples' timings
    /// made from it, an update's writes and what it met (each update's own).
    pub const canonical_skip = [_][]const u8{ "sounds", "timings", "tick", "fault" };

    pub fn init(c: *const content.Content) Sequencer {
        var s: Sequencer = .{ .sounds = c };
        for (c.samples) |*sample| {
            if (sample.number < s.timings.len) s.timings[sample.number] = clock_mod.timing(sample);
        }
        return s;
    }

    // --- the game's side ------------------------------------------------------------------------

    /// Asks for sound `index` of `Content.sounds` at the next update: into the first free slot,
    /// unless a slot holds it already; dropped when the three are taken.
    pub fn request(s: *Sequencer, index: u16) void {
        for (s.slots) |slot| if (slot == index) return;
        for (&s.slots) |*slot| if (slot.* == null) {
            slot.* = index;
            return;
        };
    }

    /// Puts sound `index` into the first slot, replacing what it held (some of the original's
    /// requests are written there directly).
    pub fn requestFirst(s: *Sequencer, index: u16) void {
        s.slots[0] = index;
    }

    /// One update: the requests, the fade, the song's tracks, the effects'. Returns its writes.
    pub fn update(s: *Sequencer) *const Tick {
        return s.updateAfter(0);
    }

    /// `update`, after `work_before` cycles of the frame's work (its looks at the sample player
    /// come after it: screens/transfers.zig).
    pub fn updateAfter(s: *Sequencer, work_before: i32) *const Tick {
        s.tick.len = 0;
        s.tick.lost = 0;
        s.held = 0;
        s.clock.newUpdate();
        s.clock.work = work_before;
        s.clock.spend(.update);
        s.step();
        s.clock.held += s.held;
        s.tick.hold = s.held;
        return &s.tick;
    }

    fn step(s: *Sequencer) void {
        switch (s.pause) {
            .resuming => {
                s.pause = .running;
                return;
            },
            .paused => {
                chips.keysOff(s);
                chips.quietAll(s);
            },
            .running => {},
        }
        if (s.fade == 0) s.requests();
        s.fadeStep();
        if (s.fault != null) return;
        if (s.pause == .running) {
            s.pass = .song;
            for (song_fm..song_fm + 5) |i| if (s.tracks[i].flags.playing) {
                s.fmStep(i);
                if (s.fault != null) return;
            };
            // The drum track's end leaves the whole update.
            if (s.tracks[drum_track].flags.playing and s.drumStep() == .unwind) return;
            if (s.fault != null) return;
            for (song_psg..song_psg + 3) |i| if (s.tracks[i].flags.playing) {
                s.psgStep(i);
                if (s.fault != null) return;
            };
        }
        s.pass = .effects;
        for ([_]usize{ effect_fm3, effect_fm4 }) |i| if (s.tracks[i].flags.playing) {
            s.fmStep(i);
            if (s.fault != null) return;
        };
        s.pass = .extra;
    }

    fn fail(s: *Sequencer, what: []const u8) void {
        if (s.fault == null) s.fault = .{ .what = what };
    }

    // --- the chips' sink (chips/registers.zig) ------------------------------------------------

    pub fn takeBus(s: *Sequencer) void {
        s.held += s.clock.busHold();
    }

    pub fn port(s: *Sequencer, p: chips.Port, value: u8) void {
        if (s.tick.len == Tick.capacity) {
            s.tick.lost += 1;
        } else {
            s.tick.writes[s.tick.len] = .{ .port = p, .value = value };
            s.tick.len += 1;
        }
        switch (p) {
            .psg, .sample => {},
            else => {
                s.clock.spend(.port_write);
                s.held += clock_mod.hold_per_port_write;
            },
        }
    }

    /// A request to the sample player.
    fn sampleRequest(s: *Sequencer, r: clock_mod.Request) void {
        s.port(.sample, switch (r) {
            .play => |n| n,
            .stop => stop_code,
            .none => none_code,
        });
        s.clock.request(r, switch (r) {
            .play => |n| s.timings[n],
            else => .{},
        });
    }

    // --- requests (sound port map 3.1) -------------------------------------------------------

    fn requests(s: *Sequencer) void {
        for (&s.slots) |*slot| {
            if (slot.*) |index| {
                const p = s.sounds.sounds[index].priority;
                if (p >= s.priority) {
                    s.priority = p;
                    s.current = .{ .sound = index };
                }
            }
            slot.* = null;
        }
        if (s.priority >= song_priority) s.priority = 0;
        if (s.current != .none) s.clock.spend(.request);
        switch (s.current) {
            .none => {},
            .stop => {
                s.stopAll();
                s.current = .none;
            },
            .sound => |index| switch (s.sounds.sounds[index].plays) {
                .song => |n| s.startSong(n),
                .effect => |n| s.startEffect(n),
                .sample => |n| {
                    s.takeBus();
                    s.sampleRequest(.{ .play = n });
                    s.priority = 0;
                    s.current = .none;
                },
                .fade_out => s.fadeStart(),
                .stop => s.stopAll(),
                .stop_effects => s.stopEffects(),
            },
        }
    }

    fn startSong(s: *Sequencer, n: u16) void {
        s.clock.spend(.song_start);
        s.stopAll();
        const song = &s.sounds.songs[n];
        s.song = n;
        const channels = [6]Channel{ .fm1, .fm2, .fm3, .fm4, .fm5, .fm6 };
        for (0..6) |k| {
            const t = &s.tracks[song_fm + k];
            const from = if (k == 5) song.drums else song.fm[k];
            t.output = chips.output_reset;
            t.duration = 1;
            t.depth = 0;
            t.flags = .{ .playing = true };
            t.channel = channels[k];
            t.started = 1;
            t.volume_offset = from.volume_offset;
            t.events = from.events;
            t.pos = 0;
        }
        const tones = [3]Channel{ .tone2, .tone1, .tone0 };
        for (song.psg, 0..) |from, k| {
            const t = &s.tracks[song_psg + k];
            t.duration = 1;
            t.depth = 0;
            t.flags = .{ .playing = true };
            t.channel = tones[k];
            t.started = 1;
            t.volume_offset = from.volume_offset;
            t.events = from.events;
            t.pos = 0;
            t.instrument = from.envelope;
        }
        s.current = .none;
    }

    fn startEffect(s: *Sequencer, n: u16) void {
        s.clock.spend(.effect_start);
        chips.fm3Special(s, false);
        const effect = &s.sounds.effects[n];
        s.effect = n;
        const music: usize = switch (effect.channel) {
            .fm3 => song_fm + 2,
            .fm4 => song_fm + 3,
        };
        s.tracks[music].flags.held = true;
        const t = &s.tracks[if (effect.channel == .fm3) effect_fm3 else effect_fm4];
        t.* = .{
            .events = effect.events,
            .flags = .{ .playing = true },
            .channel = if (effect.channel == .fm3) .fm3 else .fm4,
            .started = 1,
            .volume_offset = effect.volume_offset,
            .output = chips.output_reset,
            .duration = 1,
        };
        // The song's track's channel: FM1 when no song set it up.
        chips.silence(s, s.tracks[music].channel);
        s.current = .none;
    }

    /// Everything stops: the DAC on, FM3 normal, every channel on both speakers, the state
    /// cleared (`Current.stop`), every channel silent.
    fn stopAll(s: *Sequencer) void {
        chips.dacOn(s);
        chips.fm3Special(s, false);
        chips.resetOutputs(s);
        s.tracks = @splat(.{});
        s.slots = @splat(null);
        s.current = .stop;
        s.priority = 0;
        s.fade = 0;
        s.fade_delay = 0;
        s.pause = .running;
        s.pass = .song;
        s.song = null;
        s.effect = null;
        s.fm3_song = @splat(0);
        s.fm3_effects = @splat(0);
        chips.silenceAll(s);
        chips.quietAll(s);
    }

    fn stopEffects(s: *Sequencer) void {
        chips.fm3Special(s, false);
        for ([_]usize{ effect_fm3, effect_fm4 }) |i| {
            const t = &s.tracks[i];
            if (!t.flags.playing) continue;
            t.flags = .{};
            s.keyOff(t);
            // The song's track of the effect's channel: its instrument again, its output.
            const music = &s.tracks[s.musicTrackOf(t.channel) orelse return s.fail("an effect on a channel no song track has")];
            music.flags.held = false;
            music.flags.rest = true;
            s.loadInstrument(music, music.instrument, .song);
            s.writeOutput(music);
        }
        s.priority = 0;
        s.current = .none;
    }

    fn musicTrackOf(_: *Sequencer, c: Channel) ?usize {
        return switch (c) {
            .fm3 => song_fm + 2,
            .fm4 => song_fm + 3,
            .fm5 => song_fm + 4,
            else => null,
        };
    }

    // --- the fade and the pause (sound port map 3.10) ----------------------------------------

    fn fadeStart(s: *Sequencer) void {
        s.fade = 16;
        s.fade_delay = 4;
        // The drums and the PSG stop at once.
        for ([_]usize{ drum_track, song_psg, song_psg + 1, song_psg + 2 }) |i| s.tracks[i].flags = .{};
        chips.quietAll(s);
    }

    fn fadeStep(s: *Sequencer) void {
        if (s.fade == 0) return;
        if (s.fade_delay != 0) {
            s.fade_delay -= 1;
            return;
        }
        s.fade -= 1;
        if (s.fade == 0) return s.stopAll();
        s.fade_delay = 4;
        for (song_fm..song_fm + 5) |i| {
            const t = &s.tracks[i];
            t.volume +%= 1;
            s.writeVolume(t);
        }
    }

    fn pauseToggle(s: *Sequencer) void {
        s.pause = if (s.pause != .running) .resuming else .paused;
    }

    // --- events -------------------------------------------------------------------------------

    /// The commands from the track's position up to its next note, rest or end; returns that
    /// event's index (the position is not stored: the caller does).
    fn commands(s: *Sequencer, index: usize) ?u16 {
        const t = &s.tracks[index];
        const kind = t.kind(index);
        var pos = t.pos;
        // A jump back with no note, rest nor end on the way (an edited track) would run its
        // commands for good: past this many at once (each event 256 times, a loop's count), the
        // track fails.
        var left = t.events.len * 256 + 256;
        while (true) : (left -= 1) {
            if (left == 0) {
                s.fail("a track's commands loop with no note");
                return null;
            }
            if (pos >= t.events.len) {
                s.fail("a track ran past its last event");
                return null;
            }
            const e = t.events[pos];
            switch (e) {
                .note, .rest, .end => return pos,
                else => {},
            }
            s.clock.spend(.command);
            pos = s.command(index, kind, e, pos) orelse return null;
            if (s.fault != null) return null;
        }
    }

    /// One command; returns the next position.
    fn command(s: *Sequencer, index: usize, kind: Kind, e: Event, pos: u16) ?u16 {
        const t = &s.tracks[index];
        switch (e) {
            .note, .rest, .end => unreachable,
            .drum => |n| if (kind == .drums) {
                t.sample = .{ .play = n };
            },
            .instrument => |n| switch (kind) {
                .drums => t.sample = drumSample(n),
                .psg => t.level = n,
                .fm => {
                    t.instrument = n;
                    if (!t.flags.held) {
                        t.tweak = null;
                        if (t.channel == .fm3 and !t.flags.special) chips.fm3Special(s, false);
                        s.loadInstrument(t, n, s.pass);
                    }
                },
            },
            .volume => |n| switch (kind) {
                .drums => {},
                .psg => t.volume = ((0 -% n) & 15) +% t.volume_offset,
                .fm => if (s.fade == 0) s.setLevel(t, n),
            },
            .volume_add => |n| switch (kind) {
                .drums => {},
                .psg => t.volume +%= 0 -% n,
                .fm => if (s.fade == 0) s.setLevel(t, n +% t.level),
            },
            .detune => |d| {
                t.detune = @bitCast(d.value);
                t.detune_applied = if (d.add) t.detune_applied +% t.detune else t.detune;
            },
            .gate => |n| t.gate = n,
            .vibrato => |v| switch (v) {
                .set => |p| {
                    t.flags.vibrato = true;
                    t.vib_delay = p.delay;
                    t.vib_period = p.period;
                    t.vib_step = @bitCast(p.step);
                    t.vib_count = p.count;
                    t.vib_delay_left = p.delay;
                    t.vib_period_left = p.period;
                    t.vib_step_now = @bitCast(p.step);
                    t.vib_count_left = p.count >> 1;
                    t.vib_offset = 0;
                },
                .off => t.flags.vibrato = false,
                .on => t.flags.vibrato = true,
                .delay => |d| {
                    t.vib_delay = d;
                    t.vib_delay_left = d;
                },
                .period => |p| {
                    t.vib_period = p;
                    t.vib_period_left = p;
                },
                .step => |st| {
                    t.vib_step = @bitCast(st);
                    t.vib_step_now = @bitCast(st);
                },
                .count => |c| {
                    t.vib_count = c;
                    t.vib_count_left = c >> 1;
                },
            },
            .loop_start => |count| {
                t.depth += 1;
                (s.loopCounter(index) orelse return null).* = count;
            },
            .loop_end => |l| {
                const top = s.loopCounter(index) orelse return null;
                top.* -%= 1;
                if (top.* != 0) return l.to;
                t.depth -= 1;
            },
            .loop_break => |to| {
                if ((s.loopCounter(index) orelse return null).* == 1) {
                    t.depth -= 1;
                    t.flags.tie = false;
                    return to;
                }
            },
            .fm3 => |offsets| {
                const target = if (s.pass != .song) &s.fm3_effects else &s.fm3_song;
                target.* = offsets;
                if (!std.mem.allEqual(u8, &offsets, 0) and !t.flags.held) {
                    t.flags.special = true;
                    chips.fm3Special(s, true);
                }
            },
            .noise => {
                t.flags.special = true;
                t.channel = .tone2;
                chips.noiseMode(s);
            },
            .pan => |speakers| if (kind != .psg) {
                t.output = chips.withSpeakers(t.output, speakers);
                s.writeOutput(t);
            },
            .pause => s.pauseToggle(),
            .envelope => |n| t.instrument = n,
            .tweak => |tw| {
                t.tweak = tw;
                s.writeTweak(t, tw);
            },
            .lfo => |l| {
                chips.lfo(s, l.rate);
                t.output = chips.withLfo(t.output, l.fms, l.ams);
                s.writeOutput(t);
            },
            .tie => t.flags.tie = true,
            .jump => |to| {
                if (kind != .psg) {
                    t.flags.vibrato = false;
                    t.flags.tie = false;
                }
                t.output = chips.output_reset;
                return to;
            },
        }
        return pos + 1;
    }

    /// The loop count at the top of a track's stack. A loop end with no loop start before it (in
    /// round 6's music) finds the stack empty and counts in the next track's state instead: the
    /// original keeps the stack inside the track's record, and past its end lies the next track's
    /// record (its flags, its channel, its started byte, its volume offset).
    fn loopCounter(s: *Sequencer, index: usize) ?*u8 {
        const t = &s.tracks[index];
        if (t.depth >= 1 and t.depth <= t.loops.len) return &t.loops[@intCast(t.depth - 1)];
        if (t.depth > t.loops.len) {
            s.fail("loops nested deeper than a track holds");
            return null;
        }
        if (index + 1 >= track_count) {
            s.fail("a stray loop end of the last track");
            return null;
        }
        const next = &s.tracks[index + 1];
        return switch (-t.depth) {
            0 => @ptrCast(&next.flags),
            1 => @ptrCast(&next.channel),
            2 => &next.started,
            3 => &next.volume_offset,
            else => {
                s.fail("a stray loop end counting past the next track's first bytes");
                return null;
            },
        };
    }

    // --- FM tracks (sound port map 3.3, 3.5) --------------------------------------------------

    fn fmStep(s: *Sequencer, index: usize) void {
        const t = &s.tracks[index];
        s.clock.spend(.fm_step);
        if (t.flags.ended) return s.effectEnded(index);
        t.duration -%= 1;
        if (t.duration == 0) {
            s.clock.spend(.fm_event);
            if (!s.nextIsTie(t) and !t.flags.tie) t.flags.rest = false;
            t.flags.tie = false;
            if (s.fmNext(index) == .unwind) return;
            s.keyOn(t);
            return;
        }
        if (t.flags.rest) {
            t.flags.tie = false;
            s.keyOff(t);
            return;
        }
        if (!s.nextIsTie(t) and t.duration == t.gate) return s.keyOff(t);
        if (s.vibratoStep(t)) s.fmPitch(t, t.pitch +% t.vib_offset);
    }

    fn nextIsTie(_: *Sequencer, t: *const Track) bool {
        return t.pos < t.events.len and t.events[t.pos] == .tie;
    }

    fn fmNext(s: *Sequencer, index: usize) Flow {
        const t = &s.tracks[index];
        const at = s.commands(index) orelse return .unwind;
        s.keyOff(t);
        switch (t.events[at]) {
            .end => {
                t.duration = 0;
                return s.trackEnd(index);
            },
            .rest => |n| {
                t.duration = @truncate(n);
                t.flags.rest = true;
                s.moveOn(t, at + 1);
                return .next;
            },
            .note => |n| {
                t.duration = n.duration;
                const word = s.sounds.driver.fm_keys[n.key] | @as(u16, n.octave) << 11;
                if (t.flags.tie and t.pitch == word) {
                    t.pos = at + 1;
                    return .next;
                }
                t.pitch = word;
                t.pos = at + 1;
                resetVibrato(t);
                var p = t.pitch;
                if (t.flags.vibrato and t.flags.tie) p +%= t.vib_offset;
                s.fmPitch(t, p);
                return .next;
            },
            else => unreachable,
        }
    }

    /// The pitch with the detune, unless an effect holds the channel; FM3 in its special mode
    /// writes its four operators' (the song's offsets or the effects', by the pass).
    fn fmPitch(s: *Sequencer, t: *Track, p: u16) void {
        const word = p +% t.detune_applied;
        if (t.flags.held) return;
        if (t.flags.special) {
            if (t.channel != .fm3) return;
            const offsets = if (s.pass != .song) s.fm3_effects else s.fm3_song;
            var words: [4]u16 = undefined;
            for (&words, offsets) |*w, o| w.* = word +% o;
            return chips.fm3Pitches(s, words, s.sounds.driver.fm3_operators);
        }
        chips.pitch(s, t.channel, word);
    }

    fn keyOn(s: *Sequencer, t: *const Track) void {
        if (t.flags.rest or t.flags.tie or t.flags.held) return;
        chips.keyOn(s, t.channel);
    }

    fn keyOff(s: *Sequencer, t: *const Track) void {
        if (t.flags.tie or t.flags.held) return;
        chips.keyOff(s, t.channel);
    }

    /// Instrument `n` of the list `pass` names (the song's, the last effect's), loaded unless an
    /// effect holds the channel or the track stopped; then its volume.
    fn loadInstrument(s: *Sequencer, t: *Track, n: u8, pass: Pass) void {
        if (t.flags.held or !t.flags.playing) return;
        const i = s.instrumentOf(n, pass) orelse {
            s.fail("an instrument its list does not hold");
            s.fault.?.detail = n | @as(u32, @backingInt(pass)) << 8 | @as(u32, @intFromBool(s.song != null)) << 12;
            return;
        };
        chips.instrument(s, t.channel, i, t.output);
        t.algorithm = chips.algorithmByte(i);
        s.writeVolume(t);
    }

    fn instrumentOf(s: *Sequencer, n: u8, pass: Pass) ?*const content.Instrument {
        switch (pass) {
            .song => {
                // Numbers from 129 load the first; 128 reads far past the list.
                const k: u8 = if (n > 128) 0 else n;
                const list = if (s.song) |song| s.sounds.songs[song].instruments else s.sounds.driver.songless_instruments;
                for (list) |*i| if (i.number == k) return i;
                return null;
            },
            .effects => return s.sounds.effects[s.effect orelse return null].instrument(if (n > 128) 0 else n),
            .extra => return null,
        }
    }

    /// The carriers' attenuation (the volume and the offset), then the tweak again when the song's
    /// part runs (`Pass`).
    fn writeVolume(s: *Sequencer, t: *Track) void {
        const carriers = s.sounds.driver.carriers[t.algorithm & 7];
        const tl = t.volume +% t.volume_offset;
        for (chips.register_order) |op| if (carriers[@backingInt(op)] and !t.flags.held) {
            chips.level(s, t.channel, op, tl);
        };
        if (s.pass != .song) return;
        if (t.tweak) |tw| s.writeTweak(t, tw);
    }

    /// A tweak written, a carrier's attenuation with the track's offset added.
    fn writeTweak(s: *Sequencer, t: *const Track, tw: content.Tweak) void {
        if (t.flags.held) return;
        switch (tw) {
            .timer_b => |v| chips.timerB(s, t.channel, v),
            .operator => |o| {
                var v = o.value;
                if (o.parameter == .level and s.sounds.driver.carriers[t.algorithm & 7][@backingInt(o.operator)]) v +%= t.volume_offset;
                chips.parameter(s, t.channel, o.operator, o.parameter, v);
            },
        }
    }

    fn writeOutput(s: *Sequencer, t: *const Track) void {
        if (t.flags.held) return;
        chips.output(s, t.channel, t.output);
    }

    fn setLevel(s: *Sequencer, t: *Track, n: u8) void {
        t.level = n;
        t.volume = s.sounds.driver.volume_levels[n];
        s.writeVolume(t);
    }

    /// The end of a track: its channel silenced (all the PSG's for a PSG track; nothing for the
    /// drums), then an effect is marked ended (its channel goes back at the next update) and a
    /// song's track stops; the drum track's end leaves the update (`step`).
    fn trackEnd(s: *Sequencer, index: usize) Flow {
        const t = &s.tracks[index];
        switch (t.kind(index)) {
            .drums => {
                t.flags.playing = false;
                return .unwind;
            },
            .psg => chips.quietAll(s),
            .fm => chips.silence(s, t.channel),
        }
        if (s.pass != .song) t.flags.ended = true else t.flags.playing = false;
        return .unwind;
    }

    /// The update after an effect's end: the priority cleared, the channel given back to the
    /// song's track (its instrument loaded again, a rest until its next note), FM3's mode set back.
    /// The PassQuirk starts here.
    fn effectEnded(s: *Sequencer, index: usize) void {
        const t = &s.tracks[index];
        t.flags.ended = false;
        t.flags.playing = false;
        s.priority = 0;
        s.pass = .song;
        const music = &s.tracks[s.musicTrackOf(t.channel) orelse return s.fail("an effect on a channel no song track has")];
        music.flags.held = false;
        music.flags.rest = true;
        s.loadInstrument(music, music.instrument, .song);
        if (music.channel == .fm3) chips.fm3Special(s, music.flags.special);
    }

    // --- the vibrato --------------------------------------------------------------------------

    fn resetVibrato(t: *Track) void {
        if (!t.flags.vibrato) return;
        t.vib_delay_left = t.vib_delay;
        t.vib_period_left = t.vib_period;
        t.vib_step_now = t.vib_step;
        t.vib_count_left = t.vib_count >> 1;
        t.vib_offset = 0;
    }

    /// The position after a rest or a drum hit stored; the vibrato restarts unless tied.
    fn moveOn(_: *Sequencer, t: *Track, pos: u16) void {
        t.pos = pos;
        if (!t.flags.tie) resetVibrato(t);
    }

    /// After its delay, once per period, the offset moves by the step, in a triangle. Returns
    /// whether it moved.
    fn vibratoStep(s: *Sequencer, t: *Track) bool {
        if (!t.flags.vibrato) return false;
        if (t.vib_delay_left != 0) {
            t.vib_delay_left -= 1;
            return false;
        }
        t.vib_period_left -%= 1;
        if (t.vib_period_left != 0) return false;
        t.vib_period_left = t.vib_period;
        if (t.vib_count_left != 0) {
            t.vib_count_left -= 1;
        } else {
            t.vib_count_left = t.vib_count;
            t.vib_step_now = 0 -% t.vib_step_now;
        }
        t.vib_offset +%= t.vib_step_now;
        s.clock.spend(.vibrato);
        return true;
    }

    // --- the drum track (sound port map 3.7) --------------------------------------------------

    fn drumStep(s: *Sequencer) Flow {
        const t = &s.tracks[drum_track];
        s.clock.spend(.drum_step);
        t.duration -%= 1;
        if (t.duration != 0) {
            if (t.duration == t.gate) return s.drumRest(t, t.pos);
            return .next;
        }
        s.clock.spend(.drum_event);
        s.takeBus();
        if (s.clock.voicePlaying()) t.flags.held = true;
        if (t.flags.rest) {
            t.sample = t.saved_sample;
            t.flags.rest = false;
        }
        const at = s.commands(drum_track) orelse return .unwind;
        switch (t.events[at]) {
            .rest => |n| {
                t.duration = @truncate(n);
                return s.drumRest(t, at + 1);
            },
            .end => {
                t.duration = 0;
                return s.trackEnd(drum_track);
            },
            .note => |n| {
                t.duration = n.duration;
                return s.drumHit(t, at + 1);
            },
            else => unreachable,
        }
    }

    /// A hit: the request to the player, unless a voice plays (the drum hold).
    fn drumHit(s: *Sequencer, t: *Track, pos: u16) Flow {
        s.takeBus();
        if (!s.clock.voicePlaying()) {
            s.sampleRequest(t.sample);
            t.flags.held = false;
        }
        s.moveOn(t, pos);
        return .next;
    }

    /// A rest or the gate: the sample kept for the next hit, and the empty sample asked for (it
    /// stops the playing one).
    fn drumRest(s: *Sequencer, t: *Track, pos: u16) Flow {
        t.saved_sample = t.sample;
        t.sample = .{ .play = empty_sample };
        t.flags.rest = true;
        return s.drumHit(t, pos);
    }

    // --- PSG tracks (sound port map 3.6) ------------------------------------------------------

    fn psgStep(s: *Sequencer, index: usize) void {
        const t = &s.tracks[index];
        s.clock.spend(.psg_step);
        t.duration -%= 1;
        if (t.duration == 0) {
            s.clock.spend(.psg_event);
            t.flags.tie = false;
            if (s.psgNext(index) == .unwind) return;
            s.envelopeStep(t);
            return;
        }
        if (t.flags.rest) return;
        if (!s.nextIsTie(t) and t.duration == t.gate) return s.psgQuiet(t);
        if (!t.flags.silent) s.envelopeStep(t);
        if (s.vibratoStep(t)) s.psgPitch(t, t.pitch +% asr4(t.vib_offset));
    }

    fn psgNext(s: *Sequencer, index: usize) Flow {
        const t = &s.tracks[index];
        t.flags.rest = false;
        t.flags.silent = false;
        const at = s.commands(index) orelse return .unwind;
        switch (t.events[at]) {
            .end => {
                t.duration = 0;
                return s.trackEnd(index);
            },
            .rest => |n| {
                t.duration = @truncate(n);
                t.flags.rest = true;
                s.psgQuiet(t);
                s.moveOn(t, at + 1);
                return .next;
            },
            .note => |n| {
                t.duration = n.duration;
                const divider = s.sounds.driver.psg_steps[n.step];
                t.envelope_pos = 0;
                if (t.flags.tie and t.pitch == divider) {
                    t.pos = at + 1;
                    return .next;
                }
                t.pitch = divider;
                s.moveOn(t, at + 1);
                if (t.flags.special or t.flags.rest) return .next;
                if (t.flags.vibrato and t.flags.tie) {
                    s.psgPitch(t, t.pitch +% asr4(t.vib_offset));
                } else s.psgPitch(t, t.pitch);
                return .next;
            },
            else => unreachable,
        }
    }

    fn psgPitch(s: *Sequencer, t: *const Track, p: u16) void {
        chips.tone(s, t.channel, p +% asr4(t.detune_applied));
    }

    fn psgQuiet(s: *Sequencer, t: *Track) void {
        t.flags.silent = true;
        chips.quiet(s, t.channel, t.flags.special);
    }

    /// The envelope's next read added to the volume (sums from 15 to 142 become 15), or the
    /// volume alone without an envelope; a hold stops the reads until the next note, a silence
    /// quiets the channel, an again starts over. A rest moves the position on without a note's
    /// restart, so rests read on past the envelope's end into what follows it (`Envelope.reads`).
    fn envelopeStep(s: *Sequencer, t: *Track) void {
        var v = t.volume;
        if (t.instrument != 0) {
            if (t.instrument > 5) return s.fail("an envelope past the table");
            const env = &s.sounds.driver.envelopes[t.instrument - 1];
            var p: u16 = t.envelope_pos;
            while (true) {
                if (p >= env.reads.len) return s.fail("an envelope read past its window");
                const r = env.reads[p];
                p += 1;
                t.envelope_pos = @truncate(p);
                switch (r.kind) {
                    .step => {
                        v = r.value;
                        break;
                    },
                    .silence => return s.psgQuiet(t),
                    .hold => {
                        t.flags.silent = true;
                        return;
                    },
                    .again => p -= p % 256,
                }
            }
            v +%= t.volume;
            if (@as(i8, @bitCast(v -% 15)) >= 0) v = 15;
        }
        if (t.flags.silent) return;
        if (t.flags.special) return chips.noiseAttenuation(s, v);
        chips.attenuation(s, t.channel, v);
    }
};

/// The empty sample, which stops the playing one.
const empty_sample = 4;

/// The drum track's instrument n: sample n - 1 for 1 to 17 (counted without the top bit), a stop
/// for the others.
fn drumSample(n: u8) clock_mod.Request {
    const k = n & 127;
    return if (k >= 1 and k <= 17) .{ .play = k - 1 } else .stop;
}

fn asr4(w: u16) u16 {
    return @bitCast(@as(i16, @bitCast(w)) >> 4);
}

// ----- tests: made-up tables and items, never the game's

const testing = std.testing;

fn testDriver() content.Driver {
    var d: content.Driver = .{};
    for (&d.fm_keys, 0..) |*k, i| k.* = 512 + 16 * @as(u16, @intCast(i));
    for (&d.psg_steps, 0..) |*s, i| s.* = 768 - @as(u16, @intCast(i));
    for (&d.volume_levels, 0..) |*v, i| v.* = 64 -% 2 *% @as(u8, @truncate(i));
    for (&d.carriers, 0..) |*c, alg| c.* = switch (alg) {
        0...3 => .{ false, false, false, true },
        4 => .{ false, true, false, true },
        5, 6 => .{ false, true, true, true },
        else => .{ true, true, true, true },
    };
    // Envelope 1: 0, 1, 2, then hold.
    for (&d.envelopes[0].reads, 0..) |*r, i| r.* = if (i < 3) .{ .kind = .step, .value = @intCast(i) } else .{ .kind = .hold };
    d.envelopes[0].length = 4;
    return d;
}

/// Algorithm 1 (op4 the carrier), each operator's level its number times 16.
const test_instrument: content.Instrument = .{
    .number = 0,
    .algorithm = 1,
    .feedback = 2,
    .operators = .{ .{ .level = 16, .attack = 31 }, .{ .level = 32, .attack = 31 }, .{ .level = 48, .attack = 31 }, .{ .level = 64, .attack = 31 } },
};

const resting = [_]Event{ .{ .rest = 256 }, .{ .jump = 0 } };

fn testSong(fm1: []const Event, fm3: []const Event, drums: []const Event, psg: []const content.Track) content.Song {
    return .{
        .name = "song",
        .instruments = &.{test_instrument},
        .fm = .{ .{ .events = fm1 }, .{ .events = &resting }, .{ .events = fm3 }, .{ .events = &resting }, .{ .events = &resting } },
        .drums = .{ .events = drums },
        .psg = psg,
    };
}

/// The writes of chip operations (chips/registers.zig), to look for in a tick's.
const Expected = struct {
    writes: [512]Write = undefined,
    len: usize = 0,

    pub fn takeBus(_: *Expected) void {}

    pub fn port(e: *Expected, p: chips.Port, value: u8) void {
        e.writes[e.len] = .{ .port = p, .value = value };
        e.len += 1;
    }

    fn items(e: *const Expected) []const Write {
        return e.writes[0..e.len];
    }
};

/// Where `needle` is in `writes`, or null.
fn find(writes: []const Write, needle: []const Write) ?usize {
    var i: usize = 0;
    outer: while (i + needle.len <= writes.len) : (i += 1) {
        for (needle, writes[i..][0..needle.len]) |a, b| if (a.port != b.port or a.value != b.value) continue :outer;
        return i;
    }
    return null;
}

test "a song's first update: everything stops, then the instrument, the volume, the note" {
    const fm1 = [_]Event{ .{ .instrument = 0 }, .{ .note = .{ .duration = 2, .octave = 2, .key = 5 } }, .end };
    const songs = [_]content.Song{testSong(&fm1, &resting, &resting, &.{})};
    const sounds = [_]content.Sound{.{ .name = "song", .priority = 128, .plays = .{ .song = 0 } }};
    const c: content.Content = .{ .driver = testDriver(), .songs = &songs, .sounds = &sounds };
    var s: Sequencer = .init(&c);
    s.request(0);
    const w = s.update().items();
    // The stop: DAC on, FM3 normal, both speakers everywhere.
    var e: Expected = .{};
    chips.dacOn(&e);
    chips.fm3Special(&e, false);
    chips.resetOutputs(&e);
    try testing.expectEqual(@as(?usize, 0), find(w, e.items()));
    // FM1's instrument, its carrier's level (volume 0, no offset), the key off, the pitch (key 5
    // in octave 2), the key on.
    e = .{};
    chips.instrument(&e, .fm1, &test_instrument, chips.output_reset);
    chips.level(&e, .fm1, .op4, 0);
    chips.keyOff(&e, .fm1);
    chips.pitch(&e, .fm1, c.driver.fm_keys[5] | 2 << 11);
    chips.keyOn(&e, .fm1);
    try testing.expect(find(w, e.items()) != null);
    try testing.expectEqual(@as(?Fault, null), s.fault);
    // The note lasts two updates; the end keys off and silences FM1.
    _ = s.update();
    e = .{};
    chips.keyOff(&e, .fm1);
    chips.silence(&e, .fm1);
    try testing.expect(find(s.update().items(), e.items()) != null);
    try testing.expect(!s.tracks[0].flags.playing);
}

test "a track whose commands loop with no note fails, at once, rather than run for good" {
    // An edited track: its instrument, then a jump back to it, no note on the way.
    const fm1 = [_]Event{ .{ .instrument = 0 }, .{ .jump = 0 } };
    const songs = [_]content.Song{testSong(&fm1, &resting, &resting, &.{})};
    const sounds = [_]content.Sound{.{ .name = "song", .priority = 128, .plays = .{ .song = 0 } }};
    const c: content.Content = .{ .driver = testDriver(), .songs = &songs, .sounds = &sounds };
    var s: Sequencer = .init(&c);
    s.request(0);
    _ = s.update();
    try testing.expectEqualStrings("a track's commands loop with no note", s.fault.?.what);
}

test "an effect holds FM3, then gives it back with the song's instrument" {
    const fm3 = [_]Event{ .{ .instrument = 0 }, .{ .note = .{ .duration = 100, .octave = 3, .key = 0 } }, .end };
    const songs = [_]content.Song{testSong(&resting, &fm3, &resting, &.{})};
    const effect_events = [_]Event{ .{ .instrument = 0 }, .{ .note = .{ .duration = 1, .octave = 4, .key = 0 } }, .end };
    const effects = [_]content.Effect{.{ .name = "effect", .channel = .fm3, .volume_offset = 8, .instruments = &.{test_instrument}, .events = &effect_events }};
    const sounds = [_]content.Sound{
        .{ .name = "song", .priority = 128, .plays = .{ .song = 0 } },
        .{ .name = "effect", .priority = 64, .plays = .{ .effect = 0 } },
    };
    const c: content.Content = .{ .driver = testDriver(), .songs = &songs, .effects = &effects, .sounds = &sounds };
    var s: Sequencer = .init(&c);
    s.request(0);
    _ = s.update();
    s.request(1);
    const start = s.update().items();
    // FM3 normal, the song's FM3 silenced (key off, every level 127).
    var e: Expected = .{};
    chips.fm3Special(&e, false);
    chips.silence(&e, .fm3);
    try testing.expectEqual(@as(?usize, 0), find(start, e.items()));
    try testing.expect(s.tracks[2].flags.held);
    try testing.expectEqual(@as(u8, 64), s.priority);
    // The effect's note ends it at the next update; the update after gives FM3 back: the song's
    // instrument and its level, then FM3's mode.
    _ = s.update();
    try testing.expect(s.tracks[effect_fm3].flags.ended);
    const back = s.update().items();
    try testing.expect(!s.tracks[2].flags.held and s.tracks[2].flags.rest);
    try testing.expectEqual(@as(u8, 0), s.priority);
    e = .{};
    chips.instrument(&e, .fm3, &test_instrument, chips.output_reset);
    chips.level(&e, .fm3, .op4, 0);
    chips.fm3Special(&e, false);
    try testing.expect(find(back, e.items()) != null);
}

test "the drums wait while a voice plays" {
    // A hit of sample 1 every other update.
    const drums = [_]Event{ .{ .drum = 1 }, .{ .note = .{ .duration = 2 } }, .{ .jump = 1 } };
    const songs = [_]content.Song{testSong(&resting, &resting, &drums, &.{})};
    const long: [2000]content.Pace = @splat(.first);
    const values: [2000]u8 = @splat(128);
    const samples = [_]content.Sample{
        .{ .number = 1, .values = values[0..10], .pace = long[0..10], .delay = 1 },
        .{ .number = 7, .values = &values, .pace = &long, .delay = 30, .voice = true },
    };
    const sounds = [_]content.Sound{
        .{ .name = "song", .priority = 128, .plays = .{ .song = 0 } },
        .{ .name = "voice", .priority = 112, .plays = .{ .sample = 7 } },
    };
    const c: content.Content = .{ .driver = testDriver(), .songs = &songs, .samples = &samples, .sounds = &sounds };
    var s: Sequencer = .init(&c);
    s.request(0);
    var hits: u32 = 0;
    var voice_at: ?u32 = null;
    var held: u32 = 0;
    for (0..200) |u| {
        if (u == 20) s.request(1);
        for (s.update().items()) |w| if (w.port == .sample) {
            if (w.value == 7) voice_at = @intCast(u);
            if (w.value == 1) hits += 1;
        };
        if (voice_at != null and s.clock.voicePlaying()) held += 1;
    }
    try testing.expectEqual(@as(?u32, 20), voice_at);
    // 2,000 values some 610 cycles apart: about 20 updates without hits, then the hits again.
    try testing.expect(held > 15 and held < 30);
    try testing.expect(hits > 80 and hits < 100);
}

test "the fade: fifteen steps every fifth update, then everything stops" {
    const songs = [_]content.Song{testSong(&resting, &resting, &resting, &.{})};
    const sounds = [_]content.Sound{
        .{ .name = "song", .priority = 128, .plays = .{ .song = 0 } },
        .{ .name = "fade", .priority = 0, .plays = .fade_out },
    };
    const c: content.Content = .{ .driver = testDriver(), .songs = &songs, .sounds = &sounds };
    var s: Sequencer = .init(&c);
    s.request(0);
    _ = s.update();
    s.request(1);
    _ = s.update();
    var updates: u32 = 0;
    while (s.fade != 0) : (updates += 1) {
        s.request(0); // not read while the fade runs
        _ = s.update();
        try testing.expect(updates < 200);
    }
    try testing.expectEqual(@as(u32, 79), updates);
    try testing.expectEqual(Current.stop, s.current);
}

test "a PSG note: its divider, then its envelope until it holds" {
    const psg_events = [_]Event{ .{ .note = .{ .duration = 8, .step = 15 } }, .end };
    const psg = [_]content.Track{.{ .envelope = 1, .events = &psg_events }};
    const songs = [_]content.Song{testSong(&resting, &resting, &resting, &psg)};
    const sounds = [_]content.Sound{.{ .name = "song", .priority = 128, .plays = .{ .song = 0 } }};
    const c: content.Content = .{ .driver = testDriver(), .songs = &songs, .sounds = &sounds };
    var s: Sequencer = .init(&c);
    s.request(0);
    const first = s.update().items();
    // Tone 2: the divider of step 15, then the envelope's first value (attenuation 0).
    var e: Expected = .{};
    chips.tone(&e, .tone2, 768 - 15);
    chips.attenuation(&e, .tone2, 0);
    try testing.expectEqual(first.len - e.len, find(first, e.items()));
    // Then one value an update, 1 and 2, then the hold: no more writes for the PSG.
    for ([_]?u8{ 1, 2, null }) |value| {
        const w = s.update().items();
        const wrote = w.len != 0 and w[w.len - 1].port == .psg;
        try testing.expectEqual(value != null, wrote);
        if (value) |v| {
            e = .{};
            chips.attenuation(&e, .tone2, v);
            try testing.expectEqual(e.writes[0], w[w.len - 1]);
        }
    }
}

test "requests: the last slot at the playing priority or above wins" {
    const effect_events = [_]Event{ .{ .rest = 100 }, .end };
    const effects = [_]content.Effect{
        .{ .name = "high", .channel = .fm3, .volume_offset = 0, .instruments = &.{}, .events = &effect_events },
        .{ .name = "low", .channel = .fm3, .volume_offset = 0, .instruments = &.{}, .events = &effect_events },
    };
    const sounds = [_]content.Sound{
        .{ .name = "high", .priority = 64, .plays = .{ .effect = 0 } },
        .{ .name = "low", .priority = 48, .plays = .{ .effect = 1 } },
    };
    const c: content.Content = .{ .driver = testDriver(), .effects = &effects, .sounds = &sounds };
    var s: Sequencer = .init(&c);
    _ = s.update();
    s.request(1);
    s.request(0);
    s.request(0); // already waiting: not asked again
    try testing.expectEqual(@as(?u16, null), s.slots[2]);
    _ = s.update();
    try testing.expectEqual(@as(u8, 64), s.priority);
    try testing.expectEqual(@as(?u16, 0), s.effect);
    // A lower priority waits in vain while the effect plays.
    s.request(1);
    _ = s.update();
    try testing.expectEqual(@as(?u16, 0), s.effect);
}

test "a loop end with no loop start counts in the next track's flags" {
    // PSG track 1: a note, then the stray loop end back to it; PSG track 2: a long note.
    const stray = [_]Event{ .{ .note = .{ .duration = 1, .step = 30 } }, .{ .loop_end = .{ .to = 0, .matched = false } } };
    const long = [_]Event{ .{ .note = .{ .duration = 100, .step = 40 } }, .end };
    const psg = [_]content.Track{ .{ .events = &stray }, .{ .events = &long } };
    const songs = [_]content.Song{testSong(&resting, &resting, &resting, &psg)};
    const sounds = [_]content.Sound{.{ .name = "song", .priority = 128, .plays = .{ .song = 0 } }};
    const c: content.Content = .{ .driver = testDriver(), .songs = &songs, .sounds = &sounds };
    var s: Sequencer = .init(&c);
    s.request(0);
    _ = s.update();
    try testing.expectEqual(Flags{ .playing = true }, s.tracks[song_psg + 1].flags);
    // At the next update the stray loop end takes one from track 2's flags: it stops playing,
    // and its other flags are all set.
    _ = s.update();
    const all_but_playing: Flags = .{ .held = true, .rest = true, .special = true, .vibrato = true, .silent = true, .tie = true, .ended = true };
    try testing.expectEqual(all_but_playing, s.tracks[song_psg + 1].flags);
}

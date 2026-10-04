//! The sound content (docs/content-sound.md): the songs and effects as sequences of events, their
//! instruments, the voice samples and drums, the driver's tables, and the names the game asks for.
//! The extractor makes it from the ROM (src/extract/sound.zig); `notation.zig` and `files.zig`
//! read and write its files. Nothing here is an address: every value is a number of the music
//! (a pitch, a duration, a level) or of the chips' parameters, and every reference is an index.
const std = @import("std");

pub const Content = struct {
    driver: Driver,
    songs: []const Song = &.{},
    effects: []const Effect = &.{},
    samples: []const Sample = &.{},
    /// The names the game asks for, each with what it plays and its priority.
    sounds: []const Sound = &.{},

    /// The sound named `name`, by its index in `sounds`.
    pub fn find(self: *const Content, name: []const u8) ?u16 {
        for (self.sounds, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return @intCast(i);
        return null;
    }

    /// Sample `number`, if the content has it.
    pub fn sample(self: *const Content, number: u8) ?*const Sample {
        for (self.samples) |*s| if (s.number == number) return s;
        return null;
    }
};

/// A name the game asks for (DESIGN.md A1).
pub const Sound = struct {
    name: []const u8,
    /// An effect asked for while another plays takes the effect channel only with a priority at
    /// least the playing one's; a song's (128 and above) never holds it (sound port map 3.1).
    priority: u8,
    plays: Plays,
    /// The original's number for this request, for comparing a trace with sor-remaster's, which
    /// names sounds by it; the game never reads it (it asks for sounds by name).
    request: ?u8 = null,
    provenance: []const u8 = "",
};

pub const Plays = union(enum) {
    /// A song, by its index in `Content.songs`.
    song: u16,
    /// An effect, by its index in `Content.effects`.
    effect: u16,
    /// A sample by its number (the voices are 5 to 16).
    sample: u8,
    /// The music fades out over 79 updates, then everything stops.
    fade_out,
    /// Everything stops, and stops again at the next update (the driver's state is cleared,
    /// which it reads as a stop).
    stop,
    /// The effects stop and give their channels back to the music.
    stop_effects,
};

/// An FM instrument: the operators' parameters and the channel's algorithm and feedback. The
/// operators are named as the YM2612's documentation names them (op1 to op4).
pub const Instrument = struct {
    /// The instrument's number in its song's or effect's list (the events name it so).
    number: u8,
    algorithm: u3,
    feedback: u3,
    operators: [4]Operator,
    /// Bits of the algorithm's register that the chip ignores, as found (`Operator.ignored`).
    ignored: u8 = 0,
    /// Not one of the item's own: an instrument another effect reaches by its number, through
    /// the sequencer's quirks (the effects' shared list, `Pass`); some are bytes that are no
    /// instrument.
    borrowed: bool = false,
};

pub const Operator = struct {
    detune: u3 = 0,
    multiple: u4 = 0,
    /// The operator's attenuation (total level): 0 loudest, 127 silent.
    level: u7 = 0,
    key_scale: u2 = 0,
    attack: u5 = 0,
    am: bool = false,
    decay: u5 = 0,
    sustain_rate: u5 = 0,
    sustain_level: u4 = 0,
    release: u4 = 0,
    /// Bits of each parameter group's register that the chip ignores (by `Parameter`), written
    /// as found: zero in every instrument the songs and effects ask for in their own lists, set in
    /// some that an effect reaches through another's list (bytes that are not an instrument).
    ignored: [6]u8 = @splat(0),
};

/// The operators in the order the chip's registers list them: op1, op3, op2, op4.
pub const OperatorName = enum(u2) { op1, op2, op3, op4 };

/// A parameter group that a tweak sets (one register of the chip each).
pub const Parameter = enum { detune_multiple, level, key_scale_attack, am_decay, sustain_rate, sustain_level_release };

pub const Song = struct {
    name: []const u8,
    provenance: []const u8 = "",
    /// The song's instruments, numbered from 0: every one its list holds, used or not (an
    /// effect that gives its channel back can load one of them by number, see the sequencer).
    instruments: []const Instrument,
    /// The tracks on FM1 to FM5.
    fm: [5]Track,
    /// The drum track: the sixth FM track, which asks the sample player for drum hits.
    drums: Track,
    /// The PSG tracks, on tone 2, tone 1 and tone 0 in that order (some songs have fewer).
    psg: []const Track,
};

pub const EffectChannel = enum { fm3, fm4 };

pub const Effect = struct {
    name: []const u8,
    provenance: []const u8 = "",
    channel: EffectChannel,
    /// Added to the effect's carriers' attenuation.
    volume_offset: u8,
    /// The instruments the effect uses, by their number (effects share their lists with their
    /// neighbours, so the numbers need not start at 0).
    instruments: []const Instrument,
    events: []const Event,

    pub fn instrument(self: *const Effect, number: u8) ?*const Instrument {
        for (self.instruments) |*i| if (i.number == number) return i;
        return null;
    }
};

pub const Track = struct {
    /// Added to the carriers' attenuation (FM) or to the attenuation (PSG).
    volume_offset: u8 = 0,
    /// PSG: the envelope the track starts with (0 for none).
    envelope: u8 = 0,
    events: []const Event,
};

/// One element of a track, in the order the track plays them. The meaning of some depends on
/// the track's kind (FM, drums, PSG): the comments say how. Targets are indexes in the track.
pub const Event = union(enum) {
    /// A note of `duration` updates. FM: `key` (0-11 the scale from C, 12-15 the four values the
    /// driver's table gives past B) in `octave`; PSG: `step`, the index of the divider in the PSG
    /// table; drums: a hit, with whatever pitch it was written with.
    note: Note,
    /// A rest of 1 to 256 updates.
    rest: u16,
    /// The end of the track.
    end,
    /// FM: instrument n. PSG: kept, no effect.
    instrument: u8,
    /// Drums: the sample of the next hits.
    drum: u8,
    /// FM: the volume level (the volume table's index, higher louder). PSG: attenuation (16 - v)
    /// mod 16 plus the track's offset. Drums: no effect.
    volume: u8,
    /// FM: the volume level moved by n (signed). PSG: the attenuation lowered by n. Drums: no
    /// effect.
    volume_add: u8,
    /// The pitch moved by `value` (FM: F-number units; PSG: a sixteenth of a divider step); with
    /// `add`, added to the current detune.
    detune: struct { value: i16, add: bool },
    /// The note is released when this many updates remain (0: never).
    gate: u8,
    vibrato: Vibrato,
    /// Repeat from here: the count of the matching `loop_end`.
    loop_start: u8,
    /// The end of a repeat: back to `to` until the count runs out. With `matched` false, there is
    /// no loop start before it: it counts in whatever the loop stack's top is, see the sequencer.
    loop_end: struct { to: u16, matched: bool = true },
    /// On the last pass of the enclosing repeat, leave it: go to `to`, past its end.
    loop_break: u16,
    /// FM: FM3's special mode, with the four operators' pitch offsets (zero offsets leave the
    /// mode as it is).
    fm3: [4]u8,
    /// PSG: the track plays the noise channel (tone 2 sets its rate).
    noise,
    /// FM: the speakers. PSG: no effect.
    pan: Speakers,
    /// FM: the pause toggles (the pause jingle carries it).
    pause,
    /// PSG: envelope n (0 for none).
    envelope: u8,
    /// FM: one parameter group of an operator set, and kept: written again after each volume
    /// change while the instrument stays.
    tweak: Tweak,
    /// FM: the chip's low-frequency oscillator, and the channel's sensitivities to it.
    lfo: struct { rate: u8, fms: u8, ams: u8 },
    /// The next note continues this one: no key off, no key on, no restart of an equal pitch.
    tie,
    /// Go on at `to`.
    jump: u16,
};

pub const Note = struct {
    duration: u8,
    octave: u3 = 0,
    key: u4 = 0,
    step: u8 = 0,
};

pub const Vibrato = union(enum) {
    /// On, with all its parameters: after `delay` updates, every `period` updates the pitch moves
    /// by `step`, `count` / 2 times one way, then `count` + 1 times the other way, and so on.
    set: struct { delay: u8, period: u8, step: i16, count: u8 },
    off,
    on,
    delay: u8,
    period: u8,
    step: i16,
    count: u8,
};

pub const Tweak = union(enum) {
    operator: struct { operator: OperatorName, parameter: Parameter, value: u8 },
    /// The chip's timer B (no effect on the sound). On FM4 to FM6 it writes the second part's
    /// copy of the register, which the chip ignores.
    timer_b: u8,
};

/// The driver's tables (docs/content-sound.md).
pub const Driver = struct {
    /// FM pitches: the F-numbers of the keys C to B, then the four values found past B.
    fm_keys: [16]u16 = @splat(0),
    /// PSG pitches: the dividers by step (octave x 12 + key); steps 0-23 repeat octave 2's,
    /// 84-119 octave 6's, and step 120 is 0.
    psg_steps: [121]u16 = @splat(0),
    /// FM volume levels: the carriers' attenuation by level, the level read as a signed byte:
    /// 0-19 are the table, the others what the driver finds around it.
    volume_levels: [256]u8 = @splat(0),
    /// The carriers of each algorithm (op1 to op4).
    carriers: [8][4]bool = @splat(@splat(false)),
    /// FM3's special mode: the operators the four offsets of `Event.fm3` apply to.
    fm3_operators: [4]OperatorName = .{ .op4, .op3, .op2, .op1 },
    /// The PSG envelopes 1 to 5.
    envelopes: [5]Envelope = @splat(.{}),
    /// The instruments an effect loads from the song's list when no song plays (see the
    /// sequencer's `Pass`): the driver then reads the cartridge's first bytes, which are no
    /// instrument. By the numbers the effects use.
    songless_instruments: []const Instrument = &.{},
    provenance: []const u8 = "",
};

pub const Speakers = enum { both, left, right, none };

/// A PSG envelope: from a note's start, one read per update. `reads` is what each position
/// gives: the envelope's own steps up to its end, then what the driver reads on past that end
/// (the next envelopes, then its own code) when a rest moves the position on.
pub const Envelope = struct {
    reads: [256]Read = @splat(.{ .kind = .hold }),
    /// The envelope's own length, its end included.
    length: u16 = 1,
};

pub const Read = struct {
    kind: Kind,
    /// For `step`: the attenuation added to the track's.
    value: u8 = 0,

    pub const Kind = enum {
        step,
        /// The value stays: no more reads until the next note.
        hold,
        /// The channel goes silent.
        silence,
        /// Back to the envelope's start.
        again,
    };
};

/// A sample the Z80's player plays through the DAC: a drum hit or a voice.
pub const Sample = struct {
    number: u8,
    name: []const u8 = "",
    /// The DAC's values, one per write (unsigned, 128 the middle).
    values: []const u8 = &.{},
    /// How the player paces each value (see `Pace`), one per value.
    pace: []const Pace = &.{},
    /// The player's delay between two values, in its loop's units.
    delay: u8 = 0,
    /// Read through the player's window on the cartridge (slower).
    banked: bool = false,
    /// A voice: the drums wait while it plays, and it plays on both speakers.
    voice: bool = false,
    provenance: []const u8 = "",
};

/// What gives a value in the player's stream: a code in the first or the second half of a
/// byte, or a repeat of the last step by a zero code (the first of its run, or a later one).
pub const Pace = enum(u3) { first, second, first_repeat_start, first_repeat, second_repeat_start, second_repeat };

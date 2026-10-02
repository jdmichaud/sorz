//! The voice clock: when the sample player finishes a voice, as the sequencer sees it. It decides
//! the drum hold (DESIGN.md A4, P4): the drum track sends no hit while a voice plays, and whether a
//! voice still plays at a drum hit depends on the 68000's and the Z80's timing in the original.
//! This is the deliberate model of that timing, sor-remaster's (its audio/z80.zig, measured on
//! captures of the original), and of the bus holds that slow the samples down (the PCM's timing).
//!
//! - Time is counted in the Z80's cycles. Each update gives the player an update's cycles less
//!   the cycles the 68000 held the Z80's bus in it.
//! - Within an update, a look at the player (a drum hit's check, a request) falls after the
//!   driver's work so far: each of its steps costs the cycles of `Work` (a least-squares fit over
//!   the original's captures; some costs are negative where their step always comes with others).
//! - The driver holds the Z80's bus for each group of YM2612 writes (15 cycles to take it, 66 per
//!   port written); while a sample plays, taking the bus waits for the Z80's DAC write too
//!   (`waitHold`), and the Z80 runs on for most of that wait.
//! - A play lasts its start (the Z80's look at the request and its set-up), its counted cycles
//!   between DAC writes, and its end (`Timing`).
//!
//! sor-remaster's model agrees with the original's flag at 557 of the 559 reads of complete long
//! plays in its references; the two others are within a few hundred cycles of the play's end, and
//! there a drum hit can differ from the original's (the five drum-hit cases of sor-remaster's item
//! 15). The game's own holds of the bus (the display's transfers) are not modelled in sorz.
const std = @import("std");
const content = @import("content.zig");

/// Z80 cycles per update (NTSC): 262 lines of 3420 master cycles, the Z80 at master / 15.
pub const cycles_per_update: i32 = 262 * 3420 / 15;

/// The steps of the driver's work, by what they do.
pub const Work = enum {
    update,
    request,
    song_start,
    effect_start,
    fm_step,
    fm_event,
    drum_step,
    drum_event,
    psg_step,
    psg_event,
    command,
    bus,
    port_write,
    vibrato,
    /// The Z80's own run while the 68000 waits for the bus.
    wait,
};

/// Each step's cost in Z80 cycles (sor-remaster's fit).
const cost = std.enums.EnumArray(Work, i32).init(.{
    .update = 250,
    .request = -65,
    .song_start = 2651,
    .effect_start = 442,
    .fm_step = 238,
    .fm_event = 233,
    .drum_step = -367,
    .drum_event = -45,
    .psg_step = 177,
    .psg_event = 286,
    .command = 140,
    .bus = 54,
    .port_write = 3,
    .vibrato = 144,
    .wait = 1,
});

/// The Z80 cycles a YM2612 port write and the taking of the bus stop the Z80.
pub const hold_per_port_write: u32 = 66;
pub const hold_per_bus: u32 = 15;

/// The play's start: from the Z80's look at a request to its first DAC write (through the bank
/// window for the samples on the cartridge), and its look: 12 cycles after the request while it
/// waits, after the playing sample's current byte and 29 cycles more while it plays.
const start_in_ram: u32 = 1154;
const start_banked: u32 = 1286;
const look_waiting: u32 = 12;
const look_playing: u32 = 29;

/// A sample's timing (from the Z80 program): its counted cycles between DAC writes, the cycles
/// from its last write to its end, and the mean wait for the player's next look at a request.
pub const Timing = struct {
    length: u32 = 0,
    tail: u32 = 0,
    delay: u8 = 0,
    banked: bool = false,
    look_wait: u32 = 0,
    voice: bool = false,
};

/// The Z80 cycles between two DAC writes, by the kinds of the two values (port map 3.8), without
/// the delay (13 cycles a unit) and the bank's reads (6 cycles a new code).
fn between(a: content.Pace, b: content.Pace) u16 {
    const Kind = enum { high, low, high_repeat, low_repeat };
    const kind = struct {
        fn of(p: content.Pace) Kind {
            return switch (p) {
                .first => .high,
                .second => .low,
                .first_repeat_start, .first_repeat => .high_repeat,
                .second_repeat_start, .second_repeat => .low_repeat,
            };
        }
    }.of;
    return switch (kind(a)) {
        .high => if (kind(b) == .low) 194 else 218,
        .low => if (kind(b) == .high) 238 else 262,
        .high_repeat => switch (kind(b)) {
            .high_repeat => 219,
            .low => 218,
            else => 242,
        },
        .low_repeat => switch (kind(b)) {
            .low_repeat => 219,
            .high => 266,
            else => 294,
        },
    };
}

fn startsCode(p: content.Pace) bool {
    return switch (p) {
        .first, .second, .first_repeat_start, .second_repeat_start => true,
        .first_repeat, .second_repeat => false,
    };
}

fn endsByte(p: content.Pace, next: ?content.Pace) bool {
    return switch (p) {
        .second => true,
        .second_repeat_start, .second_repeat => next == null or next.? != .second_repeat,
        else => false,
    };
}

/// The Z80 cycles from value `i` - 1 to value `i` of `s`.
pub fn step(s: *const content.Sample, i: usize) u16 {
    const bank: u16 = if (s.banked and startsCode(s.pace[i])) 6 else 0;
    return between(s.pace[i - 1], s.pace[i]) + 13 * @as(u16, s.delay) + bank;
}

pub fn timing(s: *const content.Sample) Timing {
    var t: Timing = .{ .delay = s.delay, .banked = s.banked, .voice = s.voice };
    if (s.pace.len == 0) return t;
    var gap: u64 = 0;
    var sum: u64 = 0;
    var squares: u64 = 0;
    for (s.pace, 0..) |p, i| {
        if (i > 0) {
            const c = step(s, i);
            t.length += c;
            gap += c;
        }
        if (endsByte(p, if (i + 1 < s.pace.len) s.pace[i + 1] else null)) {
            sum += gap;
            squares += gap * gap;
            gap = 0;
        }
    }
    const last = s.pace[s.pace.len - 1];
    const repeat_end: u32 = if (last == .second_repeat or last == .second_repeat_start) 28 else 0;
    t.tail = 13 * @as(u32, s.delay) + 101 + repeat_end;
    if (sum != 0) t.look_wait = @intCast(squares / (2 * sum));
    return t;
}

/// What the sequencer asks the sample player.
pub const Request = union(enum) {
    /// Sample n starts (the current one stops).
    play: u8,
    /// The current sample stops; the player then waits, its voice flag as it was.
    stop,
    /// A request that asks nothing (a drum track's hit before it chose a sample).
    none,
};

pub const Clock = struct {
    /// The voice playing (the drums wait while it is set), by number, else null. A stop request
    /// leaves it set (the original's player does not clear its flag then).
    voice: ?u8 = null,
    /// Whether a sample plays, and the Z80 cycles left of it from the update's start.
    playing: bool = false,
    left: i32 = 0,
    delay: u8 = 0,
    look_wait: u32 = 0,
    /// The cycles the bus was held in the current update, and the driver's work so far.
    held: u32 = 0,
    work: i32 = 0,

    /// An update begins: the play went on for the last update less its bus holds.
    pub fn newUpdate(c: *Clock) void {
        const free = @max(0, cycles_per_update - @as(i32, @intCast(@min(c.held, 1 << 30))));
        c.held = 0;
        c.work = 0;
        if (!c.playing) return;
        c.left -= free;
        c.settle();
    }

    pub fn spend(c: *Clock, w: Work) void {
        c.work +|= cost.get(w);
    }

    /// The play ends once its cycles are spent by the work so far.
    fn settle(c: *Clock) void {
        if (!c.playing or c.left > c.work) return;
        c.playing = false;
        c.left = 0;
        c.voice = null;
    }

    /// Whether a voice plays now (the drums' check).
    pub fn voicePlaying(c: *Clock) bool {
        c.settle();
        return c.voice != null;
    }

    /// The Z80 cycles the taking of the bus stops the Z80: while a sample plays it also waits for
    /// the Z80's DAC write, the rest of a window of 13 x delay + 42 cycles in a period of 13 x
    /// delay + 250, on average about the window's square over the period.
    pub fn busHold(c: *Clock) u32 {
        c.spend(.bus);
        c.settle();
        if (!c.playing) return hold_per_bus;
        const b: u64 = 13 * @as(u64, c.delay) + 42;
        const p: u64 = 13 * @as(u64, c.delay) + 250;
        const wait: u32 = @intCast(20 + 824 * b * b / (1000 * p));
        c.work +|= @intCast(wait * 89 / 100);
        return hold_per_bus + wait;
    }

    /// A request to the player, `t` the timing of the sample it starts.
    pub fn request(c: *Clock, r: Request, t: Timing) void {
        c.settle();
        switch (r) {
            .none => {},
            .stop => {
                c.playing = false;
                c.left = 0;
            },
            .play => |n| {
                const look = if (c.playing) c.look_wait + look_playing else look_waiting;
                const start = look + if (t.banked) start_banked else start_in_ram;
                c.voice = if (t.voice) n else null;
                c.playing = t.length != 0;
                c.delay = t.delay;
                c.look_wait = t.look_wait;
                c.left = if (c.playing) @as(i32, @intCast(@min(t.length + t.tail + start, 1 << 30))) +| c.work else 0;
            },
        }
    }
};

const testing = std.testing;

test "a synthetic sample's steps, end and look wait" {
    // h l | h L L (the zero code repeats twice): steps h-l, l-h, h-L, L-L.
    const s: content.Sample = .{
        .number = 5,
        .values = &.{ 1, 2, 3, 4, 5 },
        .pace = &.{ .first, .second, .first, .second_repeat_start, .second_repeat },
        .delay = 1,
    };
    const t = timing(&s);
    try testing.expectEqual(@as(u32, 194 + 238 + 218 + 219 + 4 * 13), t.length);
    // The last code is a run of repeats: 28 more cycles at the end.
    try testing.expectEqual(@as(u32, 13 + 101 + 28), t.tail);
    // Byte gaps of 207 and 251 + 231 + 232: (207^2 + 714^2) / (2 x 921).
    try testing.expectEqual(@as(u32, 300), t.look_wait);
    var banked = s;
    banked.banked = true;
    try testing.expectEqual(@as(u16, 194 + 13 + 6), step(&banked, 1));
    try testing.expectEqual(@as(u16, 219 + 13), step(&banked, 4));
}

test "a voice holds the drums until its cycles are spent, bus holds included" {
    const tail = 13 * 10 + 101;
    const t: Timing = .{ .length = 3 * @as(u32, cycles_per_update) - 3000 - look_waiting - start_in_ram - tail, .tail = tail, .delay = 10, .voice = true };
    var c: Clock = .{};
    c.request(.{ .play = 7 }, t);
    try testing.expect(c.voicePlaying());
    c.newUpdate();
    c.newUpdate();
    try testing.expect(c.voicePlaying());
    c.newUpdate();
    try testing.expect(!c.voicePlaying());
    // With the bus held 1,500 cycles each update, one more update.
    c.request(.{ .play = 7 }, t);
    for (0..3) |_| {
        c.held += 1500;
        c.newUpdate();
    }
    try testing.expect(c.voicePlaying());
    c.newUpdate();
    try testing.expect(!c.voicePlaying());
    // A stop leaves the voice flag set; a drum hit clears it.
    c.request(.{ .play = 15 }, .{ .length = 1_000_000, .delay = 21, .banked = true, .voice = true });
    c.request(.stop, .{});
    for (0..40) |_| c.newUpdate();
    try testing.expect(c.voicePlaying());
    c.request(.{ .play = 1 }, .{ .length = 1_000_000, .delay = 1 });
    try testing.expect(!c.voicePlaying());
}

test "taking the bus waits for the player's DAC write while it plays" {
    var c: Clock = .{};
    try testing.expectEqual(hold_per_bus, c.busHold());
    c.request(.{ .play = 13 }, .{ .length = 1_000_000, .delay = 37, .banked = true, .look_wait = 400, .voice = true });
    c.work = 0;
    // 20 + 0.824 x 523 x 523 / 731.
    try testing.expectEqual(hold_per_bus + 20 + 308, c.busHold());
    try testing.expectEqual(cost.get(.bus) + (20 + 308) * 89 / 100, c.work);
}

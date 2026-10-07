//! The round's script as the world runs it (DESIGN.md W6; its content, content/round.zig): the
//! sections, their walls, their placed enemies and props, their waves and reserves, the GO arrow,
//! the boss's arrival, the round won; and the round's timer.
//!
//! A section starts when the one before it is cleared (the first, with the round): its placed
//! come at once, hidden until their place is on the screen (their behaviours' rule). It opens
//! `opens_after` ticks later: the camera's wall moves to the section's, the GO arrow shows, the
//! timer starts again. When the camera has reached the wall, the enemies left behind it come back
//! to its edge, and the wave comes in, a record after the other, at the screen's edges. Once the
//! wave is in, each of the section's enemies that goes calls the next of the reserve, which comes
//! in its `arrives_after` ticks later, one at a time; if no enemy is left when the wave is in,
//! two are called at once. The section is cleared when its last enemy goes and nothing more is
//! to come. After the last section, the boss's: the camera stops, the music fades, the boss's
//! music comes, then its wave; the boss's behaviour says when it is beaten (`won`).
//!
//! The section's enemies are the entities of the enemies' and bosses' families in the world (the
//! script brings them all); one that leaves the world has gone.
//!
//! On a lift (round 7's, the round's `Lift`) the camera stays: a section's opening starts the
//! lift (the first's, a hidden piece of it: `callLift`), and its wave waits for the lift's stop
//! (`wait` ticks, then its next jolt).
//!
//! A round without a boss ends with its `Exit`: once its last section is cleared, the timer stops
//! and the players walk out by themselves (`exitWalk`).
//!
//! Round 8 ends in Mr. X's room (its `Room`, world/room.zig): after the corridor's last section
//! the room begins as a section does (its placed, its art); once its art is loaded its own script
//! starts (the players walk in; the door's breaking opens it). Its fight's first wave comes at Mr.
//! X's first laugh, with the fight's music; at its clear and his second laugh, the second; at the
//! second's clear the music fades and the fight's last art loads, then Mr. X stands up to the
//! last music, and once the art after it is in the last wave comes, then the reserve. Mr. X's
//! beating ends the round.
//!
//! The original's level events do not run during the special attack, nor does its timer: the
//! script and the timer wait while it lasts.
const std = @import("std");
const content_round = @import("../content/round.zig");
const content_screens = @import("../content/screens.zig");
const fixed = @import("fixed.zig");
const entity = @import("entity.zig");
const tick_mod = @import("tick.zig");
const behaviours = @import("behaviours.zig");

const Fixed = fixed.Fixed;
const Tick = tick_mod.Tick;
const world_mod = @import("world.zig");
const World = world_mod.World;
const Round = content_round.Round;
const Spawn = content_round.Spawn;
const StreamOf = content_round.StreamOf;
const Streamed = content_round.Streamed;

/// What the script follows besides the world: the round's script and the options of the game.
pub const Plan = struct {
    round: *const Round,
    /// The options' LEVEL (0, the easiest, to 3): a record comes from its `level` on; what else
    /// it changes in play (`levels`, read at it: `Tick.heading`, `Tick.enemyPowerMore`).
    level: u2 = 1,
    levels: content_screens.Levels = .{},
    /// The lives a continue gives (the options' lives).
    lives: u8 = 3,
    /// The scores that give a player a life more, by the lives its score gave it already (play's
    /// record's; none: no life more).
    extra_lives: []const u32 = &.{},
    /// The players' buttons, by the options' CONTROL: which gives the special attack, the
    /// attack and the jump.
    buttons: content_screens.Layout = .{},
    /// The high-score table's last entry, which the score of a player out of lives must beat for
    /// its name to be entered (lives.zig); null: no table, no name entry.
    last_score: ?Ranked = null,
    /// The round's art still streams in (`ArtQueue.loading`) as the logic tick's first half runs,
    /// and as its second half runs.
    art_loading: [2]bool = .{ false, false },
    /// The palette lines of the enemies' colours (`Held`): the first's, the second's, the
    /// other's; and which enemies' colours (by number, a bit each) are a kind's own.
    colour_lines: [3]u2 = .{ 1, 2, 1 },
    own_colours: u16 = 0,

    /// Whether enemies' colours `n` are a kind's own (they show on the other).
    pub fn ownColours(self: *const Plan, n: u8) bool {
        return n < 16 and self.own_colours & (@as(u16, 1) << @intCast(n)) != 0;
    }
};

/// The enemies' colours the round's palettes hold (DESIGN.md W6; play's `enemy_colours`, by
/// number): the first (the enemies' first palette line), the second (their second line) and the
/// other (the first line's other colours: some kinds' own); null: none an enemy's kind has (a
/// boss's colours over the first). And since the reserve began, the enemies that show on each:
/// an arriving enemy takes the colours that hold its own, or ones no enemy shows on.
pub const Held = struct {
    pub const first = 0;
    pub const second = 1;
    pub const other = 2;
    colours: [3]?u8 = .{ null, null, null },
    counts: [3]u8 = .{ 0, 0, 0 },

    /// Which of them an enemy of `colours` shows on: its own the other; the first when the first
    /// holds them; else the second.
    pub fn of(self: *const Held, colours: u8, own: bool) u2 {
        if (own) return other;
        if (self.colours[first] == colours) return first;
        return second;
    }

    /// Which of them an arriving enemy of `colours` takes (0xA66): its own, the other when it holds
    /// them or none shows on it; else the first or the second that holds them, else the first or
    /// the second none shows on; null when none can be had.
    pub fn take(self: *const Held, colours: u8, own: bool) ?u2 {
        if (own) {
            if (self.colours[other] == colours or self.counts[other] == 0) return other;
            return null;
        }
        if (self.colours[first] == colours) return first;
        if (self.colours[second] == colours) return second;
        if (self.counts[first] == 0) return first;
        if (self.counts[second] == 0) return second;
        return null;
    }
};

/// An enemy of `colours` appears: the palette line it shows on, by the colours held then.
pub fn lineOf(t: *const Tick, colours: u8) u2 {
    const p = t.plan orelse return 0;
    return p.colour_lines[t.world.script.held.of(colours, p.ownColours(colours))];
}

/// The art the round streams in, as the original's load queue is decoded: a display tick's share
/// at a time (`content_round.Streamed`, from the end of the logic tick that queued it). The
/// round's picture holds it (its shares are its frames' work); the world sees whether it still
/// loads through its plan.
pub const ArtQueue = struct {
    /// The list under way, and its display ticks done.
    of: ?StreamOf = null,
    at: u16 = 0,

    /// Art queued at this logic tick (`Output.streamed`), decoded from its last display tick on.
    pub fn start(q: *ArtQueue, of: StreamOf) void {
        q.* = .{ .of = of };
    }

    /// The display tick's share, the queue on to the next.
    pub fn next(q: *ArtQueue, r: *const Round) Streamed {
        const of = q.of orelse return .{};
        const list = of.of(r);
        if (q.at >= list.len) {
            q.of = null;
            return .{};
        }
        defer q.at += 1;
        return list[q.at];
    }

    /// Whether it still loads as a logic tick's first half runs (before the frame in its middle
    /// decodes its share), and as its second half runs: asked at the logic tick, its first
    /// display tick's share done.
    pub fn loading(q: *const ArtQueue, r: *const Round) [2]bool {
        const of = q.of orelse return .{ false, false };
        const n = of.of(r).len;
        return .{ q.at <= n, q.at < n };
    }
};

/// An entry of the high-score table as a score is ranked against it: its score, its level and
/// its round.
pub const Ranked = struct {
    score: u32,
    level: u8,
    round: u8,

    /// Whether `score` beats the entry: a higher score, or the same one whose last four digits
    /// beat the entry's level, or equal it and beat its round. (The original compares the score's
    /// last four digits there, as it codes them, with the level's and the round's numbers: the
    /// same as comparing their values while those are under 10, as they are.)
    pub fn beatenBy(self: Ranked, score: u32) bool {
        if (score != self.score) return score > self.score;
        const last = score % 10_000;
        if (last != self.level) return last > self.level;
        return last > self.round;
    }
};

pub const Stage = enum {
    /// The section has started: its opening is due in `ticks`.
    opening,
    /// It is open: its wave waits for the camera to reach the wall.
    wall,
    /// It is open on a lift: its wave waits `ticks`, then for the lift's next jolt.
    lift,
    /// Its wave comes in: the next record in `ticks`.
    wave,
    /// Its wave is in; `ticks` until the reserve's calls are heard.
    wave_end,
    /// Each of its enemies that goes calls the next of its reserve.
    reserve,
    /// The last section is cleared: the boss's section opens in `ticks` (the camera stops, the
    /// music fades), its music `ticks` later.
    boss_opening,
    boss_music,
    /// The boss's art: its wave in `ticks`.
    boss_wave,
    /// The last section of a round without a boss is cleared: the players walk out.
    exit,
    /// Round 8's room has begun: its own script starts in `ticks` (its art loaded).
    room_load,
    /// The room's fight's step: the fight begun, its next wave waits for Mr. X's laugh.
    room,
    /// The room's fight after a wave: its clear, then its last art.
    room_end,
    /// The boss's fight is over (`fightOver`): the reserve is called no more, and the round
    /// waits for the boss's behaviour to end it.
    fight_over,
    /// A beaten boss has ended the round (or the players walked out).
    won,
    /// Its records come from elsewhere: an agent's situation brings them as the other program's
    /// trace has them; the timer and the lives still follow the round.
    stand_in,
};

/// The script's place in the round, part of the world.
pub const State = struct {
    /// The section opened last, from 0 (the semantic traces' `section`).
    section: u8 = 0,
    /// The part whose records the stage reads: a section's index, or the sections' count for
    /// the boss's.
    part: u8 = 0,
    stage: Stage = .opening,
    ticks: u16 = 0,
    /// The next record of the wave or the reserve.
    next: u8 = 0,
    /// The reserve's calls not yet answered, and the ticks until the one under way comes in (0:
    /// none).
    calls: u8 = 0,
    arriving: u16 = 0,
    /// The script's enemies in the world at the end of its last tick.
    enemies: u8 = 0,
    /// Two players were in play when a section started: the two players' records come (and
    /// keep coming).
    two_players: bool = false,
    /// The enemies' colours the palettes hold.
    held: Held = .{},
    /// The colours the arriving enemy takes.
    taking: ?u2 = null,
    /// The enemies' art the art slots hold by number (`Section.art`: the three enemies' slots,
    /// the boss's, and one more), and how many enemies show each, as the original tallies them
    /// (and its colours' counts, `Held`): the enemies in the world as the reserve begins, one more
    /// as each arrives, one less as each is knocked out while it runs; cleared from the second
    /// when the last boss of its kind a reserve brought goes (`bossCountedOff`).
    art: [5]u8 = @splat(0),
    art_counts: [5]u8 = @splat(0),
    /// The reserve runs: from its wave's end to the section's clear.
    waiting: bool = false,
    /// The reserve's records brought or left out (a bit each), the one arriving and the art
    /// slot its art takes (null: none of the enemies').
    taken: u32 = 0,
    chosen: u8 = 0,
    chosen_art: ?u3 = null,
    /// The arriving one's art is in its slot already: none is streamed (a reserve's boss's).
    chosen_loaded: bool = false,
    /// The round's own sound (`Round.own_sound`): its times left, the ticks to the next.
    own_sound: struct { left: ?u8 = 0, ticks: u16 = 0 } = .{},
    /// The round's animation (`Round.animation`): the step it shows, the ticks to the next.
    animation: struct { step: u8 = 0, ticks: u8 = 0 } = .{},
    /// The players' walk out (`Round.exit`): under way (still once the round is won), each
    /// player past the exit's place across, each at its depths; the turns of a player there left.
    exit: struct { on: bool = false, past: [2]bool = .{ false, false }, there: [2]bool = .{ false, false }, ticks: u16 = 0 } = .{},
};

/// The round's timer, part of the world.
pub const Timer = struct {
    /// The seconds it counts.
    seconds: u8 = 0,
    /// The seconds the status bar shows: those of its last count or start (the time over's
    /// seconds are not shown until it counts or starts again).
    shown: u8 = 0,
    /// The ticks left of the second under way.
    ticks: u8 = 0,
    /// It ran out at this tick: the round's time is up.
    up: bool = false,
    /// A boss's last blow stopped it.
    stopped: bool = false,
};

/// How round `r`'s camera follows the players.
pub fn cameraRules(r: *const Round) world_mod.Camera.Rules {
    const c = &r.camera;
    return .{
        .band = .{ @intCast(c.follow[0]), @intCast(c.follow[1]) },
        .most = @intCast(c.follow_most),
        .cleared = c.follow_cleared,
        .kept_x = .{ @intCast(c.kept_x[0]), @intCast(c.kept_x[1]) },
        .kept_depth = .{ @intCast(c.kept_depth[0]), @intCast(c.kept_depth[1]) },
        .shake_ticks = @intCast(c.shake[0]),
        .shake_by = @intCast(c.shake[1]),
        .wobble = if (c.wobble) |wb| .{ .ticks = wb.ticks, .period = wb.period, .accel = .of(wb.accel) } else null,
        .leftward = c.leftward,
    };
}

/// The world at the round's start: the camera at its place and limits, the first section
/// started (its placed come with `placeFirst`), the timer at the first section's.
pub fn start(w: anytype, plan: *const Plan) void {
    const r = plan.round;
    const c = &w.camera;
    c.x = .pixels(r.camera.x);
    c.y = .pixels(r.camera.y);
    c.x_min = .pixels(r.camera.x_min);
    c.x_max = .pixels(r.camera.x_max orelse r.sections[0].wall);
    c.y_min = .pixels(r.camera.y_min);
    c.y_max = .pixels(r.camera.y_max);
    c.follows = cameraRules(r);
    // The round's start ripples its water by as many ticks as its lines show.
    if (r.camera.water) |wt| c.ripple = @as(u32, wt.half) + wt.whole;
    if (c.follows.?.wobble) |wb| c.wobble = .fresh(wb);
    c.lift = if (r.lift) |lf| .{ .y = lf.from, .to = lf.from } else .{};
    w.script = .{};
    ownSoundAgain(w, r);
    if (r.animation) |an| w.script.animation.ticks = an.every;
    w.timer = .{ .seconds = r.sections[0].timer, .shown = r.sections[0].timer, .ticks = r.timer.pace };
}

/// The round's own sound counts again (the round's start, a section's opening).
fn ownSoundAgain(w: anytype, r: *const Round) void {
    if (r.own_sound) |o| w.script.own_sound = .{ .left = o.times, .ticks = o.first };
}

/// At a section's opening, the round's own sound counts again when it does so.
fn ownSoundAtSection(w: anytype, r: *const Round) void {
    if (r.own_sound) |o| if (o.per_section) ownSoundAgain(w, r);
}

/// The round's own sound, asked for before the entities' turns (in the tick's first half): while
/// it has times left, its ticks count down; at zero it plays, and the next is due `every` ticks
/// later.
pub fn ownSound(t: *Tick) void {
    const p = t.plan orelse return;
    const o = p.round.own_sound orelse return;
    const s = &t.world.script.own_sound;
    if (s.left) |n| if (n == 0) return;
    s.ticks -|= 1;
    if (s.ticks != 0) return;
    s.ticks = o.every;
    if (s.left) |*n| n.* -= 1;
    t.out.sounds.append(.{ .name = o.sound, .first = true });
}

/// The first section starts, its placed at their places: at the round's start.
pub fn placeFirst(t: *Tick, plan: *const Plan) void {
    beginSection(t, plan, 0);
}

/// The script of a world taken up in round 8's room: begun as the corridor's last section's
/// clear begins it.
pub fn takeUpRoom(t: *Tick, plan: *const Plan) void {
    t.world.script.section = @intCast(plan.round.sections.len - 1);
    beginRoom(t, plan);
}

/// The timer: a second less every `pace` ticks while every player in play plays (none dying or
/// waiting to continue); at zero the time is up. It holds during the special attack, and stops
/// at a boss's last blow.
pub fn timer(t: *Tick) void {
    const p = t.plan orelse return;
    const tm = &t.world.timer;
    tm.up = false;
    if (t.world.special or tm.stopped) return;
    tm.ticks -|= 1;
    if (tm.ticks != 0) return;
    tm.ticks = p.round.timer.pace;
    if (!t.playersPlay() or tm.seconds == 0) return;
    tm.seconds -= 1;
    tm.shown = tm.seconds;
    if (tm.seconds == 0) tm.up = true;
}

/// The timer starts again at the open section's seconds (a section's opening, a life's start);
/// stopped (round 8's offer, a boss's last blow), it stays stopped.
pub fn restartTimer(w: anytype, plan: *const Plan) void {
    const r = plan.round;
    const k = @min(w.script.section, r.sections.len - 1);
    const seconds = if (w.script.section >= r.sections.len and r.room != null) r.room.?.timer else r.sections[k].timer;
    w.timer = .{ .seconds = seconds, .shown = seconds, .ticks = r.timer.pace, .stopped = w.timer.stopped };
}

/// The round's animation, after the entities' turns: every `every` ticks, its next step (the
/// round's picture shows it).
pub fn animate(t: *Tick) void {
    const p = t.plan orelse return;
    const an = p.round.animation orelse return;
    const s = &t.world.script.animation;
    s.ticks -|= 1;
    if (s.ticks != 0) return;
    s.ticks = an.every;
    s.step = if (s.step + 1 < an.steps.len) s.step + 1 else 0;
}

/// The GO arrow's kind.
pub const go_arrow = "go_arrow";

/// A section due to open opens, before the camera moves, so that the camera goes on to the new
/// wall in the same tick: the wall, the GO arrow, the timer.
pub fn opening(t: *Tick) void {
    const p = t.plan orelse return;
    const s = &t.world.script;
    if (t.world.special) return;
    if (t.world.room.opening) return openRoom(t, p);
    if (s.stage != .opening) return;
    s.ticks -|= 1;
    if (s.ticks != 0) return;
    s.section = s.part;
    // On a lift: the lift starts (the first section's, by its own piece), the wave waits for it.
    if (p.round.lift) |lf| {
        s.stage = .lift;
        s.ticks = lf.wait;
        if (s.part != 0) callLift(t.world);
        return;
    }
    s.stage = .wall;
    // The first section's wall and timer are the round's own.
    if (s.part == 0) return;
    const wall: Fixed = .pixels(p.round.sections[s.part].wall);
    if (p.round.camera.leftward) t.world.camera.x_min = wall else t.world.camera.x_max = wall;
    ownSoundAtSection(t.world, p.round);
    restartTimer(t.world, p);
    // The GO arrow, in a free place of the effects'.
    if (t.kinds.find(go_arrow)) |kind| {
        const places = World.effect_places;
        _ = t.world.spawnWithin(t.kinds, kind, places.from, places.to, .zero, .right) catch return;
    }
}

/// Round 8's room opens as its door breaks (world/room.zig): its wall (the camera's limit on the
/// left), its timer, the GO arrow; the script stays at the room's step.
fn openRoom(t: *Tick, p: *const Plan) void {
    const rm = p.round.room orelse return;
    const s = &t.world.script;
    t.world.room.opening = false;
    s.section = s.part;
    t.world.camera.x_min = .pixels(rm.wall);
    ownSoundAtSection(t.world, p.round);
    restartTimer(t.world, p);
    if (t.kinds.find(go_arrow)) |kind| {
        const places = World.effect_places;
        _ = t.world.spawnWithin(t.kinds, kind, places.from, places.to, .zero, .right) catch return;
    }
}

/// The script's tick, after the others have moved: the enemies that went, the camera at the
/// wall, the wave, the reserve, the clear, the boss.
pub fn run(t: *Tick) void {
    const p = t.plan orelse return;
    const s = &t.world.script;
    if (t.world.special) {
        // A reserve's enemy called before it, its colours loaded, has its art streamed in
        // meanwhile (the original's event machine waits, its art loads): it comes at the special
        // attack's end at the soonest.
        if (s.stage == .reserve and s.arriving > 1 and s.arriving < arrivalTicks(s, &reserveOf(p.round, s.part)[s.chosen])) s.arriving -= 1;
        return;
    }
    const now = countEnemies(t);
    const went = s.enemies -| now;
    s.enemies = now;
    const r = p.round;
    switch (s.stage) {
        .opening, .exit, .fight_over, .won, .stand_in => {},
        .lift => {
            // Its wait's last tick forgets the jolts before (the lift's start's); then the next
            // one (its stop's) brings the wave.
            const l = &t.world.camera.lift;
            if (s.ticks != 0) {
                s.ticks -= 1;
                if (s.ticks == 0) l.jolted = false;
            }
            if (s.ticks != 0 or !l.jolted) return;
            s.stage = .wave;
            s.next = 0;
            nextWave(t, p);
        },
        .wall => {
            const c = &t.world.camera;
            if (c.x_max.sub(c.x_min).whole() >= r.camera.wall_within) return;
            bringBack(t, r);
            s.stage = .wave;
            s.next = 0;
            nextWave(t, p);
        },
        .wave => {
            s.ticks -|= 1;
            if (s.ticks != 0) return;
            bring(t, p, &waveOf(t, r, s.part)[s.next]);
            s.next += 1;
            nextWave(t, p);
        },
        .wave_end => {
            s.ticks -|= 1;
            if (s.ticks != 0) return;
            // The room's fight goes on to its next step until its last art.
            if (s.part >= r.sections.len and r.room != null and t.world.room.has(.begun) and !t.world.room.has(.last_art)) {
                t.world.room.wave +|= 1;
                s.stage = .room_end;
                return roomEnd(t, p);
            }
            s.stage = .reserve;
            s.waiting = true;
            s.taken = 0;
            for (reserveOf(r, s.part), 0..) |*rec, k| {
                if (!comes(p, s, rec)) s.taken |= @as(u32, 1) << @intCast(k);
            }
            tally(t, p);
            // None left: two are called at once.
            s.calls = if (s.enemies == 0) 2 else 0;
            s.arriving = 0;
            clearIfDone(t, p);
        },
        .reserve => {
            s.calls +|= went;
            const list = reserveOf(r, s.part);
            if (s.arriving != 0) {
                const rec = &list[s.chosen];
                // The arriving enemy's colours, at its arrival's first tick.
                if (s.arriving == arrivalTicks(s, rec)) {
                    t.out.colours = true;
                    if (rec.reserve_boss) |b| {
                        t.out.colour_loads.append(.{ .reserve_boss = b.colours });
                    } else if (rec.colours) |c| if (s.taking) |into| t.out.colour_loads.append(.{ .enemies = .{ .colours = c, .into = into } });
                }
                s.arriving -= 1;
                if (s.arriving != 0) return;
                if (coloursOf(rec)) |c| if (s.taking) |into| {
                    s.held.colours[into] = c;
                    s.held.counts[into] +%= 1;
                };
                if (s.chosen_art) |slot| if (artOf(rec)) |a| {
                    s.art[slot] = a;
                    s.art_counts[slot] +%= 1;
                };
                bring(t, p, rec);
                s.taken |= @as(u32, 1) << @intCast(s.chosen);
                s.calls -|= 1;
                s.enemies = countEnemies(t);
            } else if (s.calls != 0) if (chooseWaiting(t, p, list)) |k| {
                s.chosen = k;
                s.arriving = arrivalTicks(s, &list[k]);
                // Its kind's art is loaded as it is called (unless its slot holds it).
                if (list[k].streamed.len != 0 and !s.chosen_loaded) t.out.streamed = .{ .part = s.part, .record = k };
                return;
            };
            clearIfDone(t, p);
        },
        .room_load => {
            s.ticks -|= 1;
            if (s.ticks != 0) return;
            s.stage = .room;
            roomFight(t, p);
        },
        .room => roomFight(t, p),
        .room_end => roomEnd(t, p),
        .boss_opening => {
            s.ticks -|= 1;
            if (s.ticks != 0) return;
            const b = r.boss.?;
            const c = &t.world.camera;
            c.x_min = c.x;
            c.x_max = c.x;
            t.sound(b.fade, null);
            // The boss's colours.
            bossColours(t);
            s.stage = .boss_music;
            s.ticks = @max(b.music_after -| 1, 1);
        },
        .boss_music => {
            s.ticks -|= 1;
            if (s.ticks != 0) return;
            const b = r.boss.?;
            t.sound(b.music, null);
            s.stage = .boss_wave;
            s.ticks = @max(b.wave_after, 1);
        },
        .boss_wave => {
            s.ticks -|= 1;
            if (s.ticks != 0) return;
            // The boss's fight: its colours again.
            bossColours(t);
            s.stage = .wave;
            s.next = 0;
            nextWave(t, p);
        },
    }
}

/// A section calls the lift: the camera starts it at its next turn.
pub fn callLift(w: anytype) void {
    w.camera.lift.called = true;
}

/// Whether the players walk out (`Round.exit`), the round won or not: nothing keeps them on the
/// screen.
pub fn exiting(w: anytype) bool {
    return w.script.exit.on;
}

/// The command player `k` (its fighter `h`) takes in the players' walk out, instead of its own:
/// none outside it, and none in the air (its own then). It lets go of what it holds. Left while
/// it is at or past the exit's place across; once before it, up or down into the exit's depths;
/// there, left, and each such turn counts down the round's end (`won` at none left, its own
/// command at that turn; the last player there counts again from the exit's ticks).
pub fn exitWalk(t: *Tick, k: u1, h: entity.Handle) ?world_mod.Command {
    const p = t.plan orelse return null;
    const ex = p.round.exit orelse return null;
    const s = &t.world.script;
    if (s.stage != .exit) return null;
    const e = t.world.get(h) orelse return null;
    if (e.holding != null) t.letGo(h);
    if (!e.velocity.height.eql(.zero)) return null;
    const own = t.world.players[k].command;
    const way: world_mod.Actions = way: {
        if (!s.exit.there[k]) {
            if (!s.exit.past[k]) {
                if (e.position.x.whole() >= ex.x) break :way .{ .left = true };
                s.exit.past[k] = true;
            }
            const d = e.position.depth.whole();
            if (d < ex.depth[0]) break :way .{ .down = true };
            if (d >= ex.depth[1]) break :way .{ .up = true };
            s.exit.there[k] = true;
            s.exit.ticks = ex.ticks;
        }
        s.exit.ticks -|= 1;
        if (s.exit.ticks == 0) {
            won(t.world);
            return null;
        }
        break :way .{ .left = true };
    };
    var held = way;
    held.start = own.held.start;
    var pressed = way;
    pressed.start = own.pressed.start;
    return .{ .held = held, .pressed = pressed, .last = pressed };
}

/// Whether the boss's section has begun (the boss's fight is on): the script reads the boss's
/// part.
pub fn bossFight(w: anytype, plan: *const Plan) bool {
    return w.script.part >= plan.round.sections.len;
}

/// The boss's fight is over (his beating knocks the enemies out): the original's events wait for
/// the section's clear, so no more of the reserve come.
pub fn fightOver(w: anytype) void {
    if (w.script.stage != .won) w.script.stage = .fight_over;
}

/// The boss was beaten: the round is won (the boss's behaviour says when).
pub fn won(w: anytype) void {
    w.script.stage = .won;
}

/// The wave's next record that comes (by its level and players), and its delay; after the last,
/// the wave's end: read at the next tick, the reserve set up at the one after.
fn nextWave(t: *Tick, p: *const Plan) void {
    const s = &t.world.script;
    const list = waveOf(t, p.round, s.part);
    while (s.next < list.len and !comes(p, s, &list[s.next])) s.next += 1;
    if (s.next < list.len) {
        s.ticks = @max(list[s.next].after, 1);
        return;
    }
    s.stage = .wave_end;
    s.ticks = 2;
}

/// The first of the reserve's records still to come whose art and colours can be had (0x936):
/// it takes their slots (`chosen_art`, `taking`).
fn chooseWaiting(t: *Tick, p: *const Plan, list: []const Spawn) ?u8 {
    const s = &t.world.script;
    for (list, 0..) |*rec, k| {
        if (s.taken & (@as(u32, 1) << @intCast(k)) != 0) continue;
        const art = artSlot(t.world, p, rec) orelse continue;
        const colours = coloursSlot(t.world, p, rec) orelse continue;
        s.chosen_art = art.slot;
        s.chosen_loaded = art.loaded;
        s.taking = colours.slot;
        // A reserve's boss's colours hold the first line too from now (0xB4C).
        if (rec.reserve_boss) |b| s.held.colours[Held.first] = b.colours;
        return @intCast(k);
    }
    return null;
}

/// The ticks from a reserve's record's call to its coming in: its art's load's (none when its
/// slot holds it already), at least one.
fn arrivalTicks(s: *const State, rec: *const Spawn) u16 {
    if (s.chosen_loaded) return 1;
    return @max(rec.arrives_after, 1);
}

/// A record's art and colours by number: an enemy's, or a reserve's boss's.
fn artOf(rec: *const Spawn) ?u8 {
    if (rec.reserve_boss) |b| return b.art;
    return rec.art;
}

fn coloursOf(rec: *const Spawn) ?u8 {
    if (rec.reserve_boss) |b| return b.colours;
    return rec.colours;
}

/// The boss's art slot.
const boss_slot = 3;

const Slot = struct { slot: ?u3, loaded: bool = false };
const ColoursSlot = struct { slot: ?u2 };

/// Whether a waiting record's art can be had (0x966), and the art slot it takes: its art's own,
/// else one no enemy shows (round 1's from its second); in the boss's fight (or a section that
/// holds a boss's art) only the first, and none with a boss's art that leaves no slot. A record
/// without the enemies' art takes none.
fn artSlot(w: anytype, p: *const Plan, rec: *const Spawn) ?Slot {
    const s = &w.script;
    // A reserve's boss's (0xA02): the boss's slot, holding its art already, or once no enemy
    // shows the second's, the third's or the boss's.
    if (rec.reserve_boss) |b| {
        if (s.art[boss_slot] == b.art) return .{ .slot = boss_slot, .loaded = true };
        if (s.art_counts[boss_slot] != 0 or s.art_counts[1] != 0 or s.art_counts[2] != 0) return null;
        return .{ .slot = boss_slot };
    }
    const a = rec.art orelse return .{ .slot = null };
    if (bossFight(w, p) or s.art[3] != 0) {
        if (s.art[3] == p.round.boss_art_full) return null;
        if (s.art[0] == a or s.art_counts[0] == 0) return .{ .slot = 0 };
        return null;
    }
    const from = p.round.art_from;
    for (from..3) |i| if (s.art[i] == a) return .{ .slot = @intCast(i) };
    for (from..3) |i| if (s.art_counts[i] == 0) return .{ .slot = @intCast(i) };
    return null;
}

/// Whether a waiting record's colours can be had (0xA66), and those it takes (`Held.take`); in
/// the boss's fight (or a section that holds a boss's art) only the second's, never a kind's own.
fn coloursSlot(w: anytype, p: *const Plan, rec: *const Spawn) ?ColoursSlot {
    const s = &w.script;
    // A reserve's boss's (0xB24): the other's, holding them already, or once no enemy shows on
    // the first or the other (its colours go over the first line).
    if (rec.reserve_boss) |b| {
        if (s.held.colours[Held.other] == b.colours) return .{ .slot = Held.other };
        if (s.held.counts[Held.first] != 0 or s.held.counts[Held.other] != 0) return null;
        return .{ .slot = Held.other };
    }
    const c = rec.colours orelse return .{ .slot = null };
    const own = p.ownColours(c);
    if (bossFight(w, p) or s.art[3] != 0) {
        if (own) return null;
        if (s.held.colours[Held.second] == c or s.held.counts[Held.second] == 0) return .{ .slot = Held.second };
        return null;
    }
    return .{ .slot = s.held.take(c, own) orelse return null };
}

/// An enemy knocked out while the reserve runs is counted off its art's slot and its colours':
/// its art's among the slots a waiting record may take (none: the last of them), its
/// colours' where they are held.
pub fn countOff(t: *Tick, e: *const entity.Entity) void {
    const p = t.plan orelse return;
    const s = &t.world.script;
    if (!s.waiting) return;
    if (e.spawn.art) |a| {
        const from = p.round.art_from;
        var slot: usize = 2;
        for (from..3) |i| if (s.art[i] == a) {
            slot = i;
            break;
        };
        s.art_counts[slot] -%= 1;
    }
    const c = e.spawn.colours orelse return;
    const h = &s.held;
    if (p.ownColours(c)) {
        if (h.colours[Held.other] == c) h.counts[Held.other] -%= 1;
    } else if (h.colours[Held.first] == c) {
        h.counts[Held.first] -%= 1;
    } else if (h.colours[Held.second] == c) {
        h.counts[Held.second] -%= 1;
    }
}

/// A boss that goes as an enemy (its beating not the round's end: a reserve's, or a variant of
/// the boss's fight) is counted off as the original counts it, the reserve running or not:
/// off the boss's art slot's count, which at 0 clears the art of the second, the third, the
/// boss's slot and the one more (the boss's art loaded over theirs); off the other colours'
/// count. (The enemies' count and the reserve's call: as any enemy's going.)
pub fn bossCountedOff(t: *Tick) void {
    const s = &t.world.script;
    s.art_counts[boss_slot] -%= 1;
    if (s.art_counts[boss_slot] == 0) @memset(s.art[1..], 0);
    s.held.counts[Held.other] -%= 1;
}

/// The section is cleared when nothing more is to come and its last enemy has gone: the next
/// section starts, or the boss's. The boss's section ends with the boss.
fn clearIfDone(t: *Tick, p: *const Plan) void {
    const s = &t.world.script;
    const r = p.round;
    const all = (@as(u64, 1) << @intCast(reserveOf(r, s.part).len)) - 1;
    if (s.taken != all or s.arriving != 0 or s.enemies != 0) return;
    // Round 8's room ends with Mr. X's beating.
    if (s.part >= r.sections.len and r.room != null) return;
    if (s.part >= r.sections.len) {
        // The boss's section with nothing left and no boss: the content does not have him yet
        // (his kind skipped as the wave brought him). The round is won rather than left without
        // an end. TODO(PLAN item 15 and on): each round's boss.
        std.log.warn("the round's boss is not in the content yet: the round is won without him", .{});
        return won(t.world);
    }
    const k = s.part + 1;
    if (k < r.sections.len) return beginSection(t, p, k);
    if (r.room != null) return beginRoom(t, p);
    if (r.exit) |ex| {
        // The players walk out; the timer stops; the next entry's colours are loaded.
        holdColours(t, ex.colours);
        s.stage = .exit;
        s.exit = .{ .on = true };
        t.world.timer.stopped = true;
        return;
    }
    if (r.boss == null) return;
    // The boss's section opens as a section does: its colours; its art loads.
    holdColours(t, r.boss.?.section_colours);
    @memcpy(s.art[0..4], &r.boss.?.art);
    s.waiting = false;
    t.out.streamed = .{ .part = k };
    s.part = k;
    s.stage = .boss_opening;
    s.ticks = 1;
}

/// Section `k` starts: its placed come, and its opening is due.
fn beginSection(t: *Tick, p: *const Plan, k: u8) void {
    const s = &t.world.script;
    const sec = &p.round.sections[k];
    // A section's art's colours are set as it begins, and its art loads.
    holdColours(t, sec.colours);
    @memcpy(s.art[0..4], &sec.art);
    s.waiting = false;
    t.out.streamed = .{ .part = k };
    s.part = k;
    s.stage = .opening;
    s.ticks = @max(sec.opens_after, 1);
    s.next = 0;
    s.calls = 0;
    s.arriving = 0;
    s.two_players = s.two_players or t.playersInPlay() == 2;
    for (sec.placed) |*rec| {
        if (comes(p, s, rec)) place(t, rec, rec.x);
    }
    s.enemies = countEnemies(t);
}

/// Round 8's room begins as a section does (its colours, its art, its placed); its own script
/// starts once its art is loaded.
fn beginRoom(t: *Tick, p: *const Plan) void {
    const rm = &p.round.room.?;
    const s = &t.world.script;
    const k: u8 = @intCast(p.round.sections.len);
    holdColours(t, rm.colours);
    @memcpy(s.art[0..4], &rm.art);
    s.waiting = false;
    t.out.streamed = .{ .part = k };
    s.part = k;
    s.stage = .room_load;
    s.ticks = @max(rm.starts_after, 1);
    s.next = 0;
    s.calls = 0;
    s.arriving = 0;
    s.two_players = s.two_players or t.playersInPlay() == 2;
    for (rm.placed) |*rec| {
        if (comes(p, s, rec)) place(t, rec, rec.x);
    }
    s.enemies = countEnemies(t);
}

/// The room's fight's step (0x4CA): at its first, Mr. X's colours, a player out of the game
/// leaves, the players walk in, the art slots the room's; then, once Mr. X has laughed, the
/// fight's music and its first wave; after it, once he has laughed again, its next wave.
fn roomFight(t: *Tick, p: *const Plan) void {
    const rm = &p.round.room.?;
    const s = &t.world.script;
    const r = &t.world.room;
    if (!r.set(.begun)) {
        bossColours(t);
        for (&t.world.players, 0..) |*pl, k| {
            const h = pl.entity orelse continue;
            const e = t.world.get(h) orelse continue;
            if (e.mind == .player) continue;
            r.gone[k] = true;
            pl.entity = null;
            pl.out = true;
            t.world.remove(h);
        }
        r.walking = true;
        s.art[0] = room_slot_art;
        s.art[boss_slot] = 0;
        s.art_counts[0] = 1;
    }
    if (r.has(.music)) {
        if (!r.has(.second_laugh)) return;
    } else {
        if (!r.has(.first_laugh)) return;
        t.sound(rm.music, null);
        _ = r.set(.music);
    }
    s.stage = .wave;
    s.next = 0;
    nextWave(t, p);
}

/// The art the room's first slot holds from the fight's start (0x4CA: $F, none of the enemies'),
/// and from Mr. X's standing up (0x4B4: 1).
const room_slot_art = 0xF;
const room_stand_art = 1;

/// The room's fight after a wave (0x464): once no enemy is left, the fight's next step (the next
/// wave waits for Mr. X's laugh); the second time, the music fades and the last art loads; once
/// it is in, Mr. X stands up to the last music and the art after it loads; once that is in, the
/// fight's step again (its last wave).
fn roomEnd(t: *Tick, p: *const Plan) void {
    const rm = &p.round.room.?;
    const s = &t.world.script;
    const r = &t.world.room;
    if (!r.has(.last_art)) {
        if (roomEnemies(t) != 0) return;
        if (!r.set(.cleared)) {
            s.stage = .room;
            return;
        }
        t.sound(rm.fade, null);
        s.art_counts[0] = 0;
        s.art[boss_slot] = room_slot_art;
        t.out.streamed = .{ .part = s.part, .room_art = .last };
        _ = r.set(.last_art);
        // Its load counts from the next tick.
        s.ticks = @max(rm.last_art_after, 1);
        return;
    }
    s.ticks -|= 1;
    if (s.ticks != 0) return;
    if (r.set(.last_loaded)) {
        s.stage = .room;
        return;
    }
    _ = r.set(.stands);
    t.sound(rm.last_music, null);
    s.art[0] = room_stand_art;
    t.out.streamed = .{ .part = s.part, .room_art = .stand };
    s.ticks = @max(rm.stand_art_after, 1);
}

/// The room's enemies left: those of the enemies' family (Mr. X is none of them).
fn roomEnemies(t: *Tick) u8 {
    var n: u8 = 0;
    for (&t.world.entities) |*e| {
        const kind = e.kind orelse continue;
        if (t.kinds.get(kind).family() == .enemy) n +|= 1;
    }
    return n;
}

/// A section's colours loaded (0xF46): the other's first when it gives one (else the other keeps
/// its own), then the first's, then the second's.
fn holdColours(t: *Tick, c: content_round.Colours) void {
    const h = &t.world.script.held;
    t.out.colours = true;
    if (c.other) |n| {
        h.colours[Held.other] = n;
        t.out.colour_loads.append(.{ .enemies = .{ .colours = n, .into = Held.other } });
    }
    h.colours[Held.first] = c.first;
    if (c.first) |n| t.out.colour_loads.append(.{ .enemies = .{ .colours = n, .into = Held.first } });
    h.colours[Held.second] = c.second;
    if (c.second) |n| t.out.colour_loads.append(.{ .enemies = .{ .colours = n, .into = Held.second } });
}

/// The boss's colours loaded (0x576), over the first's, which no kind's then match.
fn bossColours(t: *Tick) void {
    t.out.colours = true;
    t.out.colour_loads.append(.boss);
    t.world.script.held.colours[Held.first] = null;
}

/// As the reserve begins (0x810), the enemies in the world are added to the tallies: each to
/// its art's slot (art none holds: uncounted) and to the colours it shows on, by the line it
/// took (those not yet out are not counted; one out but hidden is, an acrobat's leap in).
fn tally(t: *Tick, p: *const Plan) void {
    const s = &t.world.script;
    for (&t.world.entities) |*e| {
        if (!e.alive()) continue;
        if (e.flags.hidden) if (behaviours.stateName(&e.mind)) |name| if (std.mem.eql(u8, name, "appear")) continue;
        const c = e.spawn.colours orelse continue;
        if (e.spawn.art) |a| if (a & 0x80 == 0) {
            if (std.mem.indexOfScalar(u8, &s.art, a)) |i| s.art_counts[i] +%= 1;
        };
        const part: u2 = if (p.ownColours(c)) Held.other else if (e.palette == p.colour_lines[Held.first]) Held.first else if (e.palette == p.colour_lines[Held.second]) Held.second else continue;
        s.held.counts[part] +%= 1;
    }
}

/// Whether a record comes in this game: its level, and its players.
fn comes(p: *const Plan, s: *const State, rec: *const Spawn) bool {
    if (rec.level > p.level) return false;
    if (rec.two_players and !s.two_players) return false;
    return true;
}

fn waveOf(t: *const Tick, r: *const Round, part: u8) []const Spawn {
    if (part < r.sections.len) return r.sections[part].wave;
    if (r.room) |*rm| return rm.waves[@min(t.world.room.wave, rm.waves.len - 1)];
    return r.boss.?.wave;
}

fn reserveOf(r: *const Round, part: u8) []const Spawn {
    if (part < r.sections.len) return r.sections[part].reserve;
    if (r.room) |*rm| return rm.reserve;
    return r.boss.?.reserve;
}

/// A wave's or a reserve's record comes in at the screen's edge on its side.
fn bring(t: *Tick, p: *const Plan, rec: *const Spawn) void {
    const edges = p.round.camera.edges;
    const at = t.world.camera.x.whole() + if (rec.side == .left) edges[0] else edges[1];
    place(t, rec, at);
}

/// The entity of a record at `x` and its depth, on the ground; placed as its record says
/// (`placing`). A kind the content does not define yet is skipped, with a warning.
fn place(t: *Tick, rec: *const Spawn, x: i32) void {
    const kind = t.kinds.find(rec.kind) orelse {
        std.log.warn("the round's script brings a {s}, which the content does not define yet: skipped", .{rec.kind});
        return;
    };
    const position: fixed.Vec3 = .{ .x = .pixels(x), .depth = .pixels(rec.depth), .height = t.world.ground };
    // In the enemies' places, as the original's script takes its objects' (0xE46).
    const places = World.enemy_places;
    const how = placing(rec);
    const made = switch (t.kinds.get(kind).family()) {
        .enemy, .boss => t.world.spawnEnemy(t.kinds, kind, position, how),
        else => t.world.spawnWithin(t.kinds, kind, places.from, places.to, position, .right),
    };
    const h = made catch {
        std.log.warn("the world is full: the round's script's {s} is skipped", .{rec.kind});
        return;
    };
    t.world.get(h).?.spawn = how;
    // The round may draw what its script brings in front of its layers' cells.
    if (t.plan) |p| t.world.get(h).?.flags.in_front = p.round.in_front.script;
    // A breakable holds the item its record names.
    if (rec.holds) |name| {
        if (t.kinds.find(name)) |item| t.give(h, item) else std.log.warn("the round's script's {s} holds a {s}, which the content does not define yet: it holds none", .{ rec.kind, name });
    }
    // An enemy comes hidden, its health not yet given: its behaviour brings it out when its
    // place is on the screen.
    switch (t.kinds.get(kind).family()) {
        .enemy, .boss => {
            const e = t.world.get(h).?;
            e.flags.hidden = true;
            e.health = 0;
        },
        else => {},
    }
}

/// How a record places its entity, in the world's terms: an enemy's way in, its traits (a piece
/// of scenery's too), its place beside its target, its strength; a piece of scenery's height.
pub fn placing(rec: *const Spawn) entity.Spawn {
    var sp: entity.Spawn = .{ .strength = @intCast(@min(rec.strength, 3)) };
    if (rec.entrance) |way| sp.entrance = switch (way) {
        inline else => |w| @field(entity.Entrance, @tagName(w)),
    };
    inline for (comptime std.meta.fieldNames(content_round.Trait)) |name| {
        @field(sp.traits, name) = rec.traits.contains(@field(content_round.Trait, name));
    }
    if (rec.offset) |o| {
        sp.offset_x = o.x;
        sp.offset_depth = o.depth;
    }
    sp.offset_nibbles = rec.offset_nibbles;
    sp.bar = rec.bar;
    sp.colours = rec.colours;
    if (rec.height) |h| sp.height = @intCast(h);
    if (rec.drift) |d| sp.drift = switch (d) {
        inline else => |x| @field(entity.Drift, @tagName(x)),
    };
    sp.art = rec.art;
    sp.place = rec.place;
    sp.rolls = rec.rolls;
    return sp;
}

/// The section's enemies in the world: those of the enemies' and the bosses' families.
fn countEnemies(t: *Tick) u8 {
    var n: u8 = 0;
    for (&t.world.entities) |*e| {
        const kind = e.kind orelse continue;
        switch (t.kinds.get(kind).family()) {
            .enemy, .boss => n +|= 1,
            else => {},
        }
    }
    return n;
}

/// When the camera reaches the wall, the enemies left behind it come back to its left edge, at
/// the depth the round gives, and their behaviours are told. Only their whole pixels move: the
/// fractions stay, as the original writes its places' whole words.
fn bringBack(t: *Tick, r: *const Round) void {
    // Going left, those at or right of the camera's place plus `left_behind_right` come there.
    const leftward = r.camera.leftward;
    const back = t.world.camera.x.whole() + if (leftward) r.camera.left_behind_right else r.camera.left_behind[0];
    for (&t.world.entities, 0..) |*e, i| {
        const kind = e.kind orelse continue;
        if (t.kinds.get(kind).family() != .enemy) continue;
        if (if (leftward) e.position.x.whole() < back else e.position.x.whole() > back) continue;
        e.position.x = .parts(@intCast(back), e.position.x.frac());
        e.position.depth = .parts(@intCast(r.camera.left_behind[1]), e.position.depth.frac());
        t.leftBehind(t.world.handleAt(i).?);
    }
}

test "the enemies' colours: an enemy shows on those that hold its own; one arriving takes them, or ones none shows on" {
    var h: Held = .{ .colours = .{ 0, 3, 9 } };
    try std.testing.expectEqual(@as(u2, Held.first), h.of(0, false));
    try std.testing.expectEqual(@as(u2, Held.second), h.of(3, false));
    // Colours none holds: the second line.
    try std.testing.expectEqual(@as(u2, Held.second), h.of(5, false));
    try std.testing.expectEqual(@as(u2, Held.other), h.of(10, true));
    try std.testing.expectEqual(@as(?u2, Held.second), h.take(3, false));
    h.counts = .{ 2, 1, 1 };
    try std.testing.expectEqual(@as(?u2, null), h.take(5, false));
    h.counts[Held.second] = 0;
    try std.testing.expectEqual(@as(?u2, Held.second), h.take(5, false));
    try std.testing.expectEqual(@as(?u2, Held.other), h.take(9, true));
    try std.testing.expectEqual(@as(?u2, null), h.take(10, true));
}

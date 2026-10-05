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
//! The original's level events do not run during the special attack, nor does its timer: the
//! script and the timer wait while it lasts.
const std = @import("std");
const content_round = @import("../content/round.zig");
const content_screens = @import("../content/screens.zig");
const fixed = @import("fixed.zig");
const entity = @import("entity.zig");
const tick_mod = @import("tick.zig");

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
    /// The options' LEVEL (0, the easiest, to 3): a record comes from its `level` on.
    level: u2 = 1,
    /// The lives a continue gives (the options' lives).
    lives: u8 = 3,
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
    /// A beaten boss has ended the round.
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
        .kept_x = .{ @intCast(c.kept_x[0]), @intCast(c.kept_x[1]) },
        .kept_depth = .{ @intCast(c.kept_depth[0]), @intCast(c.kept_depth[1]) },
        .shake_ticks = @intCast(c.shake[0]),
        .shake_by = @intCast(c.shake[1]),
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
    c.x_max = .pixels(r.sections[0].wall);
    c.y_min = .pixels(r.camera.y_min);
    c.y_max = .pixels(r.camera.y_max);
    c.follows = cameraRules(r);
    w.script = .{};
    w.timer = .{ .seconds = r.sections[0].timer, .shown = r.sections[0].timer, .ticks = r.timer.pace };
}

/// The first section starts, its placed at their places: at the round's start.
pub fn placeFirst(t: *Tick, plan: *const Plan) void {
    beginSection(t, plan, 0);
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

/// The timer starts again at the open section's seconds (a section's opening, a life's start).
pub fn restartTimer(w: anytype, plan: *const Plan) void {
    const r = plan.round;
    const k = @min(w.script.section, r.sections.len - 1);
    w.timer = .{ .seconds = r.sections[k].timer, .shown = r.sections[k].timer, .ticks = r.timer.pace };
}

/// The GO arrow's kind.
pub const go_arrow = "go_arrow";

/// A section due to open opens, before the camera moves, so that the camera goes on to the new
/// wall in the same tick: the wall, the GO arrow, the timer.
pub fn opening(t: *Tick) void {
    const p = t.plan orelse return;
    const s = &t.world.script;
    if (t.world.special or s.stage != .opening) return;
    s.ticks -|= 1;
    if (s.ticks != 0) return;
    s.section = s.part;
    s.stage = .wall;
    // The first section's wall and timer are the round's own.
    if (s.part == 0) return;
    t.world.camera.x_max = .pixels(p.round.sections[s.part].wall);
    restartTimer(t.world, p);
    if (t.kinds.find(go_arrow)) |kind| {
        _ = t.world.spawn(t.kinds, kind, .zero, .right) catch return;
    }
}

/// The script's tick, after the others have moved: the enemies that went, the camera at the
/// wall, the wave, the reserve, the clear, the boss.
pub fn run(t: *Tick) void {
    const p = t.plan orelse return;
    if (t.world.special) return;
    const s = &t.world.script;
    const now = countEnemies(t);
    const went = s.enemies -| now;
    s.enemies = now;
    const r = p.round;
    switch (s.stage) {
        .opening, .won, .stand_in => {},
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
            bring(t, p, &waveOf(r, s.part)[s.next]);
            s.next += 1;
            nextWave(t, p);
        },
        .wave_end => {
            s.ticks -|= 1;
            if (s.ticks != 0) return;
            s.stage = .reserve;
            s.next = 0;
            nextReserve(p, s);
            countColours(t, p);
            // None left: two are called at once.
            s.calls = if (s.enemies == 0) 2 else 0;
            s.arriving = 0;
            clearIfDone(t, p);
        },
        .reserve => {
            s.calls +|= went;
            const list = reserveOf(r, s.part);
            if (s.arriving != 0) {
                // The arriving enemy's colours, at its arrival's first tick.
                if (s.arriving == @max(list[s.next].arrives_after, 1)) {
                    t.out.colours = true;
                    if (list[s.next].colours) |c| if (s.taking) |into| t.out.colour_loads.append(.{ .enemies = .{ .colours = c, .into = into } });
                }
                s.arriving -= 1;
                if (s.arriving != 0) return;
                if (list[s.next].colours) |c| if (s.taking) |into| {
                    s.held.colours[into] = c;
                    s.held.counts[into] +|= 1;
                };
                bring(t, p, &list[s.next]);
                s.next += 1;
                s.calls -|= 1;
                nextReserve(p, s);
                s.enemies = countEnemies(t);
            } else if (s.calls != 0 and s.next < list.len) {
                s.arriving = @max(list[s.next].arrives_after, 1);
                // The colours it takes. TODO(PLAN item 15): none to be had, the original brings
                // the first waiting record whose colours (and art) can be had; round 1's always
                // can.
                s.taking = if (list[s.next].colours) |c| s.held.take(c, p.ownColours(c)) else null;
                // Its kind's art is loaded as it is called.
                if (list[s.next].streamed.len != 0) t.out.streamed = .{ .part = s.part, .record = s.next };
                return;
            }
            clearIfDone(t, p);
        },
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

/// Whether the boss's section has begun (the boss's fight is on): the script reads the boss's
/// part.
pub fn bossFight(w: anytype, plan: *const Plan) bool {
    return w.script.part >= plan.round.sections.len;
}

/// The boss was beaten: the round is won (the boss's behaviour says when).
pub fn won(w: anytype) void {
    w.script.stage = .won;
}

/// The wave's next record that comes (by its level and players), and its delay; after the last,
/// the wave's end: read at the next tick, the reserve set up at the one after.
fn nextWave(t: *Tick, p: *const Plan) void {
    const s = &t.world.script;
    const list = waveOf(p.round, s.part);
    while (s.next < list.len and !comes(p, s, &list[s.next])) s.next += 1;
    if (s.next < list.len) {
        s.ticks = @max(list[s.next].after, 1);
        return;
    }
    s.stage = .wave_end;
    s.ticks = 2;
}

/// The reserve's next record that comes.
fn nextReserve(p: *const Plan, s: *State) void {
    const list = reserveOf(p.round, s.part);
    while (s.next < list.len and !comes(p, s, &list[s.next])) s.next += 1;
}

/// The section is cleared when nothing more is to come and its last enemy has gone: the next
/// section starts, or the boss's. The boss's section ends with the boss.
fn clearIfDone(t: *Tick, p: *const Plan) void {
    const s = &t.world.script;
    const r = p.round;
    if (s.next < reserveOf(r, s.part).len or s.arriving != 0 or s.enemies != 0) return;
    if (s.part >= r.sections.len) return;
    const k = s.part + 1;
    if (k < r.sections.len) return beginSection(t, p, k);
    if (r.boss == null) return;
    // The boss's section opens as a section does: its colours; its art loads.
    holdColours(t, r.boss.?.section_colours);
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

/// As the reserve begins (0x810), the enemies that show on each of the colours held: by the line
/// each took (those not yet out are not counted).
fn countColours(t: *Tick, p: *const Plan) void {
    const h = &t.world.script.held;
    h.counts = .{ 0, 0, 0 };
    for (&t.world.entities) |*e| {
        if (!e.alive() or e.flags.hidden) continue;
        const c = e.spawn.colours orelse continue;
        const part: u2 = if (p.ownColours(c)) Held.other else if (e.palette == p.colour_lines[Held.first]) Held.first else if (e.palette == p.colour_lines[Held.second]) Held.second else continue;
        h.counts[part] +|= 1;
    }
}

/// Whether a record comes in this game: its level, and its players.
fn comes(p: *const Plan, s: *const State, rec: *const Spawn) bool {
    if (rec.level > p.level) return false;
    if (rec.two_players and !s.two_players) return false;
    return true;
}

fn waveOf(r: *const Round, part: u8) []const Spawn {
    return if (part < r.sections.len) r.sections[part].wave else r.boss.?.wave;
}

fn reserveOf(r: *const Round, part: u8) []const Spawn {
    return if (part < r.sections.len) r.sections[part].reserve else r.boss.?.reserve;
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
    sp.bar = rec.bar;
    sp.colours = rec.colours;
    if (rec.height) |h| sp.height = @intCast(h);
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
/// the depth the round gives, and their behaviours are told.
fn bringBack(t: *Tick, r: *const Round) void {
    const back = t.world.camera.x.whole() + r.camera.left_behind[0];
    for (&t.world.entities, 0..) |*e, i| {
        const kind = e.kind orelse continue;
        if (t.kinds.get(kind).family() != .enemy) continue;
        if (e.position.x.whole() > back) continue;
        e.position.x = .pixels(back);
        e.position.depth = .pixels(r.camera.left_behind[1]);
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

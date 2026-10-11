//! The CPU's play (PLAN items 30, 31 and 34): a player's pad from what the round's world shows
//! and what the CPU remembers (`Memory`, its world's player's), the same on every machine. It
//! chooses once a logic tick (the world's clock), from the world as its last logic tick left it:
//! the pad is the same at both display ticks of one, as a player's read is.
//!
//! - In the fight it plays as a person, with a mind of its own. A few times a second it looks
//!   at the screen (so it reacts late) and goes for the best of what it shows, a little at
//!   random: a foe near (one on a player 1 in trouble first, one player 1 fights or goes for
//!   after the others, so that with foes on both sides each takes one), what lies about (food
//!   when hurt, before the foes when badly hurt; money, gold, a life, a special attack, unless
//!   player 1 is nearer), a thing to break (a blow knocks the bridge's barriers and the deck's
//!   blocks away), or else a place of its own on the floor, mostly ahead of player 1 (the way the
//!   round goes) and out of its line, where it stays a while before choosing another. Food it
//!   needs, it goes for past the foes not in its way.
//! - Held from behind by a foe, it jumps out and, in the moment after, throws the holder over;
//!   thrown by one, it lands on its feet now and then (up and C): at a person's reaction, and
//!   now and then missed.
//! - It strikes a foe in front of it within its jab's reach (its first blow's box on the foe's
//!   body) at once, whatever it goes for, at a person's pace: a burst of blows (the combo's four)
//!   and a breath, unless the foe is not reeling. It goes to strike from near its jab's end, out
//!   of a punk's reach; now and then it walks into its foe to grab it, knees it and throws it (not
//!   a boss too heavy for it), comes in with a jump kick, and strikes a foe behind it with the
//!   back attack. Its blows that do not hurt a foe make it back off a while.
//! - A boss it comes at out of its line, where bosses charge, slash and throw; facing it while
//!   player 1 is near the boss, it keeps out of its line, facing it, and lets player 1 draw it;
//!   its back turned, it comes round to it. It steps out of the way of what comes at it in its
//!   line (a thrown knife, a boomerang, a shot, a boss's rush, a boss lining up on it), at a
//!   person's reaction, and out from under a press about to come down (round 6's).
//! - It calls the police (a life brings one) when a boss is near, among three foes, among two
//!   when hurt, near its end with a foe about, or for player 1 near its end without one.
//! - It never blocks player 1's way: walked at, it steps out of its line, and it never walks into
//!   it, which would grab it. With two CPUs (0 PLAYERS - 2 CPU), each takes the other for its
//!   player 1, and CPU 1 leads: it goes on through the round as a CPU alone does, and keeps off
//!   CPU 2 only as far as not walking into it, while CPU 2 gives way to it as to a person.
//! - Nor does it walk into player 1's blows' way while player 1 fights (both CPUs): it goes
//!   round it, and fights a foe there from the other side; there already, it stays.
//! - It walks round the holes and the walls of the round's floor (round 4's bridge, round 6's
//!   machines), never into one. A walk that does not take it on (a solid thing, player 1 in the
//!   way, a jitter) makes it look again, give up a thing it went for, and take a detour along the
//!   shortest way round (`wayRound`); in a solid thing, it walks out across.
//! - Mr. X's offer: no.
//! - Out of lives: its name, CPU, when its score entered the high-score table; yes to the
//!   continue's question (asked only while it has continues).
//! - Never START, which would open the settings or the pause.
//!
//! Its random draws are its own (`Memory.draw`): the game's stay the original's. The agent
//! host's bot plays item 30's rule (`fight`), sor-remaster's runner's bot.
const std = @import("std");
const input = @import("../input.zig");
const content_screens = @import("../content/screens.zig");
const world_mod = @import("world.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const content_round = @import("../content/round.zig");
const behaviours = @import("behaviours.zig");
const systems = @import("systems.zig");
const player_waiting = @import("behaviours/player_waiting.zig");

const World = world_mod.World;
const Actions = world_mod.Actions;
const Entity = entity.Entity;
const Handle = entity.Handle;
const Kinds = kinds_mod.Kinds;
const Layout = content_screens.Layout;
const Floor = content_round.Floor;

/// The name the CPU enters in the high-score table.
pub const name = "CPU";

/// The screen's width, which the camera shows of the world from its place.
const screen_width = 320;

/// What the CPU keeps from one logic tick to the next.
pub const Memory = struct {
    /// The world's clock at its last choice, and the actions it chose then.
    at: ?u32 = null,
    chose: Actions = .{},
    /// Its random generator's state (xorshift); 0 before its first draw.
    seed: u32 = 0,
    /// The ticks to its next look at the fight, and what it goes for until then.
    look: u8 = 0,
    goal: Goal = .{ .roam = .{} },
    /// A new goal's wait: the ticks it walks on as it walked before turning to it.
    wait: u8 = 0,
    /// At its place (roaming): the ticks it stays there before it chooses another.
    linger: u8 = 0,
    /// Drawn for its foe at each look: how near in depth is near enough to strike, how far short
    /// of its jab's reach on the foe it stands, or that it walks into the foe to grab it, and a
    /// jump kick to come in.
    slack: u8 = 3,
    short: u8 = 4,
    grab: bool = false,
    kick: bool = false,
    /// The special attack it calls at its next tick free to act.
    special: bool = false,
    /// It saw what comes at it (`threat`), and steps out of its way.
    dodge: bool = false,
    /// Its presses at a foe whose health stays as it was (`noteFutile`): the foe, its health then,
    /// and the presses so far; then the ticks it backs off from it.
    pressed_at: ?Handle = null,
    pressed_health: i16 = 0,
    futile: u8 = 0,
    back_off: u8 = 0,
    /// The blows' pace: those left in its burst, the ticks to the next, its breath after.
    blows: u8 = 0,
    beat: u8 = 0,
    breath: u8 = 0,
    /// The foe it holds, and the knees it gives it before it throws it.
    foe_held: ?Handle = null,
    knees: u8 = 0,
    /// A foe's hold from behind or throw it is in (`breakOut`), the ticks before it reacts, and
    /// whether it tries this time.
    caught: Caught = .none,
    react: u8 = 0,
    tries: bool = false,
    /// Its side of player 1's line: above it (farther away) or below.
    above: bool = false,
    /// A walk that does not take it from where it stood (or one it kept off player 1): the
    /// ticks so far, where it stood, and the walk it wanted at its last tick; then the ticks
    /// left of its detour round what stopped it.
    stuck: u8 = 0,
    stood: Spot = .{},
    wanted: Actions = .{},
    detour: u8 = 0,
    /// The things it gave up (an item or a thing to break it got stuck going for), the last few,
    /// and the slot of the next.
    given_up: [4]?Handle = @splat(null),
    given_at: [4]u32 = @splat(0),
    give_up_at: u2 = 0,

    /// A draw of its own, from 0 to `n` - 1.
    fn draw(m: *Memory, n: u8) u8 {
        var x = if (m.seed == 0) 0x2545F491 else m.seed;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        m.seed = x;
        return @intCast(x % n);
    }

    /// Whether a draw falls within `n` chances in a hundred.
    fn chance(m: *Memory, n: u8) bool {
        return m.draw(100) < n;
    }
};

/// A foe's hold or throw the CPU is in: held from behind (and jumping out), the moment after a
/// jump out (`counter_window`), thrown (knocked down, landing on its feet still open), or none.
pub const Caught = enum { none, held_behind, counter, thrown };

/// A place in the world: across, and in depth.
pub const Spot = struct { x: i32 = 0, depth: i32 = 0 };

/// What the CPU goes for: a place of its own, a foe, an item to take, a thing to break.
pub const Goal = union(enum) { roam: Spot, foe: Handle, take: Handle, smash: Handle };

/// The rule's numbers, in logic ticks (30 a second) and pixels. Its looks, and a new goal's wait
/// (its reaction); its blows' bursts (the combo's four blows, mostly), the ticks from one blow
/// to the next (eight to fifteen a second) and its breath after a burst; the knees it gives a
/// foe it holds before throwing it.
const look_ticks = .{ 5, 10 };
const wait_ticks = .{ 3, 6 };
const burst = .{ 4, 6 };
const beat_ticks = .{ 2, 4 };
const breath_ticks = .{ 4, 10 };
const knees = .{ 0, 2 };
/// A foe's hold from behind or throw (`breakOut`): the ticks before the CPU reacts (in the moment
/// after a jump out, which lasts some 8 ticks, the second numbers), and the chances in a hundred
/// that it jumps out of the hold, throws the holder in the moment after, and lands a throw on
/// its feet (up and C at once, harder).
const react_ticks = .{ 3, 8 };
const counter_react_ticks = .{ 1, 3 };
const escape_chance = 90;
const counter_chance = 80;
const recover_chance = 60;
/// Its foe: how far short of its jab's reach on it it stands (`reachOn`: the jab meets a punk's
/// body from 63 to 77 pixels across, by the character, out of the punk's punch, 56), how near in
/// depth (blows reach 16), the least it keeps across; the depth within which it strikes a foe in
/// front of it at once, within its reach, from wherever it stands, and its jab's reach when its
/// definition has no first blow's box; a thing to break's place and reach; the chances in a
/// hundred, at a look, that it goes to grab its foe (a boss, whom a throw hurts most), and that
/// it comes in with a jump kick, from within the kick's distances, and the reach it kicks from in
/// the air.
const short_px = .{ 2, 6 };
const slack_px = .{ 2, 6 };
const too_close = 14;
const jab_level = 10;
const jab_ahead = 48;
const smash_from = 24;
const smash_reach = 30;
const grab_chance = 20;
const boss_grab_chance = 50;
const kick_chance = 20;
const kick_from = .{ 58, 80 };
const kick_reach = 36;
/// A boss: farther across than its reach and this, it comes in this far out of the boss's line.
/// Facing it while player 1 is near the boss (within `boss_busy`), it keeps out of its line.
const boss_room = 8;
const boss_aside = 32;
const boss_busy = 160;
/// What comes at it (`threat`): as fast as this across (in a tick, 16.16), from as far as this
/// across, within this in depth of its line; the chances in a hundred at a tick that it sees it
/// (a person's reaction).
const fast_raw = 2 << 16;
const threat_px = .{ 112, 14 };
const dodge_chance = 40;
/// Presses at a foe that do not hurt it (it shrugs them off, or they miss): after this many, it
/// backs off these ticks.
const futile_presses = 12;
const back_off_ticks = .{ 30, 60 };
/// Foes this far off the screen's edges it goes for (they wait there, round 7's).
const off_screen = 48;
/// A foe right behind it, within this across and in depth: the back attack, these chances in a
/// hundred at a tick.
const behind_px = .{ 28, 8 };
const back_chance = 6;
/// The police (the special attack), called with one left and none under way, when a life is at
/// stake (`policeDue`): the foes within `crowd_px` of a player, its health's shares in a hundred
/// that count as hurt and as near its end; the chances in a hundred at a look that it calls them
/// then (a moment's hesitation).
const crowd_px = 80;
const hurt = 60;
const near_end = 25;
const police_chance = 40;
/// Its places: across from player 1 (mostly ahead, the way the round goes: right, or left as the
/// camera goes in round 8), out of its line in depth, within the screen's margins; the ticks it
/// stays at one; near enough to it. Without player 1, ahead of itself.
const ahead_px = .{ -40, 120 };
const aside_px = .{ 24, 44 };
const margin_left = 48;
const margin_right = 64;
const linger_ticks = .{ 20, 80 };
const there_px = .{ 8, 4 };
const alone_ahead_px = .{ 40, 120 };
/// A walk that has not taken it farther than this from where it stood (either way: a walk that
/// jitters) for this many ticks is stuck: it looks again, and takes a detour of these ticks
/// along the way round to its goal (`wayRound`).
const stuck_px = 3;
const stuck_ticks = 8;
const detour_ticks = .{ 20, 40 };
/// A thing it gave up going for is tried again after this many ticks (a person tries again: a
/// barrier it could not come at from one place, from another).
const give_up_ticks = 450;
/// The depths the players are kept on (the camera's rules), which its places keep to: a step out
/// of a line in depth is turned the other way within this of their edge.
const edge_room = 8;
/// Food is wanted under this share of its health in a hundred, and needed under the second: then
/// it goes for it before the foes, striking only one in its way.
const peckish = 75;
const starving = 40;
/// Player 1's room (a walk's reach grabs what it meets: the reach 16 pixels ahead, a body up to
/// 13 ahead, each 8 either side in depth): in its line within this in depth, and the nearest in
/// depth it walks to it from beside it; within a body's reach across, a walk's, and the room to
/// leave its line before walking at it; and how near player 1 walking at it makes it step aside.
const line = 18;
const beside = 22;
/// The holes of the round's floor: how far ahead across and in depth a step looks for one, the
/// floor's cells' steps, and how far in depth it looks for the floor ahead to go round one.
const hole_ahead = .{ 12, 8 };
const wall_ahead = 8;
/// A press about to come down: the margins round its blows' boxes within which it walks out from
/// under it, and into which it does not walk.
const press_out = 4;
const press_in = 8;
const cell_px = 8;
const round_px = 64;
const body_room = 14;
const reach_room = 32;
const pass_room = 48;
const coming_room = 72;
/// Player 1's blows' way (`Fire`): beyond its jab's reach on a body, this much more across; in
/// depth, as far as its blows reach (16) and a little more.
const fire_room = 16;
const fire_line = 20;

/// What the CPU plays with besides the world: the kinds, the round's floor by cells (its holes),
/// the name entry's letters (content), the buttons of the options' CONTROL, and whether it leads
/// (CPU 1 of two).
pub const Given = struct {
    kinds: *const Kinds,
    floor: ?*const Floor = null,
    letters: []const []const u8 = &.{},
    layout: Layout = .{},
    leads: bool = false,
};

/// Player `k`'s pad as the CPU plays it, its memory `m`, from the world as its last logic tick
/// left it.
pub fn pad(w: *const World, g: Given, m: *Memory, k: u1) input.Pad {
    const layout = g.layout;
    const press = w.tick % 2 == 0;
    const r = &w.room;
    // Held in the offer's choice: its answer, no, and nothing once given.
    if (r.choosing[k]) return if (r.answered[k]) .{} else padOf(if (r.on_no[k]) .{ .attack = press } else .{ .down = press }, layout);
    const e = w.getConst(w.players[k].entity orelse return .{}) orelse return .{};
    return switch (e.mind) {
        .player => padOf(choose(w, g, m, k, e), layout),
        .player_waiting => |*mind| switch (mind.state) {
            .name_entry => entry(mind, g.letters, layout, press),
            .continue_choose => padOf(if (mind.cursor == .no) .{ .up = press } else .{ .attack = press }, layout),
            else => .{},
        },
        else => .{},
    };
}

/// The CPU's name entry in `m` (player_waiting.zig's rules), with a press if `press`: left or
/// right to its name's letter at the cursor's place, the nearer way round, then the letter taken;
/// a letter that `letters` lacks is taken as it is.
pub fn entry(m: *const player_waiting.Mind, letters: []const []const u8, layout: Layout, press: bool) input.Pad {
    const want = if (m.place < name.len) for (letters, 0..) |l, i| {
        if (l.len == 1 and l[0] == name[m.place]) break i;
    } else m.letter else m.letter;
    if (m.letter == want) return padOf(.{ .special = press }, layout);
    const n = letters.len;
    const ahead = (want + n - m.letter) % n;
    return padOf(if (ahead <= n / 2) .{ .right = press } else .{ .left = press }, layout);
}

/// The pad whose buttons give `a` by `layout`.
fn padOf(a: Actions, layout: Layout) input.Pad {
    var p: input.Pad = .{ .up = a.up, .down = a.down, .left = a.left, .right = a.right, .start = a.start };
    for ([_]struct { content_screens.Button, bool }{ .{ layout.special, a.special }, .{ layout.attack, a.attack }, .{ layout.jump, a.jump } }) |b| if (b[1]) switch (b[0]) {
        .a => p.a = true,
        .b => p.b = true,
        .c => p.c = true,
    };
    return p;
}

/// The actions of the CPU's fighter `p`, player `k`, at this logic tick: chosen at its first
/// display tick, the same at its second.
fn choose(w: *const World, g: Given, m: *Memory, k: u1, p: *const Entity) Actions {
    if (m.at) |at| if (at == w.tick) return m.chose;
    m.at = w.tick;
    m.chose = play(w, g, m, k, p);
    return m.chose;
}

/// A draw from the range `r` (its least and its most) of the rule's numbers.
fn between(m: *Memory, comptime r: anytype) i32 {
    return r[0] + @as(i32, m.draw(r[1] - r[0] + 1));
}

/// Player 1's fighter for player `k` (the other player's), while it fights.
fn partnerOf(w: *const World, k: u1) ?*const Entity {
    const q = w.getConst(w.players[1 - k].entity orelse return null) orelse return null;
    return if (q.mind == .player) q else null;
}

fn play(w: *const World, g: Given, m: *Memory, k: u1, p: *const Entity) Actions {
    const kinds = g.kinds;
    const leads = g.leads;
    const partner = partnerOf(w, k);
    const fire = fireOf(w, kinds, partner);
    const stuck = noteStuck(w, m, p);
    m.wanted = .{};
    if (p.holding) |h| return withFoeHeld(w, kinds, m, k, p, h);
    if (breakOut(w, m, p)) |a| return a;
    m.foe_held = null;
    if (m.look == 0) {
        lookAround(w, kinds, g.floor, m, k, p, partner, leads);
        m.look = @intCast(between(m, look_ticks));
    } else m.look -= 1;
    if (stuck) m.detour = @intCast(between(m, detour_ticks));
    if (m.special and ready(p)) {
        m.special = false;
        return .{ .special = true };
    }
    // Under a press about to come down: out from under it, the nearest way.
    if (ready(p)) if (pressOver(w, kinds, spotHere(p), press_out)) |out| return safe(w, g, out, p);
    // Something coming at it in its line: once it sees it, it steps out of the way.
    const jab = jabAhead(kinds, p);
    if (threat(w, kinds, p, jab)) |t| {
        if (!m.dodge) m.dodge = m.chance(dodge_chance);
        if (m.dodge and ready(p)) {
            const dd = t.position.depth.whole() - p.position.depth.whole();
            const up = if (dd != 0) dd > 0 else m.above;
            return safe(w, g, .{ .up = up, .down = !up }, p);
        }
    } else m.dodge = false;
    // Backing off from a foe its blows do not hurt: away across, out of its line.
    if (m.back_off > 0) {
        m.back_off -= 1;
        if (m.pressed_at) |h| if (w.getConst(h)) |f| {
            const dx = f.position.x.whole() - p.position.x.whole();
            const dd = f.position.depth.whole() - p.position.depth.whole();
            return safe(w, g, .{ .left = dx >= 0, .right = dx < 0, .up = dd > 0 and @abs(dd) < line, .down = dd <= 0 and @abs(dd) < line }, p);
        };
        m.back_off = 0;
    }
    // A foe in front of it, in reach: it strikes, whatever it goes for (but food it needs, past a
    // foe not in its way); at once while the foe is not reeling from its blows (it would strike
    // first).
    if (foeInFront(w, kinds, p, jab)) |f| if (!needsFood(w, kinds, m, p, f)) {
        if (!behaviours.inState(&f.mind, "reel")) m.breath = 0;
        const a: Actions = .{ .attack = strike(m) };
        if (a.attack) noteFutile(w, m, f);
        return a;
    };
    // Inside a solid thing (a new life dropped in it): out across, the nearer way (a walk across
    // alone stands it against the thing's side; any other is undone).
    if (ready(p)) if (solidSide(w, kinds, p)) |out| return out;
    if (m.detour > 0) {
        m.detour -= 1;
        if (goalPlace(w, m.goal)) |to| {
            const a = wayRound(w, g, p, to);
            if (walks(a)) return safe(w, g, clearOf(m, keepOff(w, m, a, p, partner, leads), p, fire), p);
        }
        m.detour = 0;
    }
    // A new goal: it walks on as it walked a moment (not its blows).
    if (m.wait > 0) {
        m.wait -= 1;
        m.wanted = walkOf(m.chose);
        return safe(w, g, clearOf(m, keepOff(w, m, walkOf(m.chose), p, partner, leads), p, fire), p);
    }
    // A foe right behind it, while it fights another: now and then, the back attack.
    if (m.goal == .foe and ready(p)) if (foeBehind(w, kinds, p)) {
        if (m.chance(back_chance)) return .{ .attack = true, .jump = true };
    };
    const a: Actions = switch (m.goal) {
        .foe => |h| if (foeAt(w, kinds, h)) |f| fightFoe(w, m, p, f, partner, fire, reachOn(kinds, jab, p, f), kinds.get(f.kind.?).family() == .boss) else .{},
        .smash => |h| if (standing(w, h)) |f| strikeAt(w, m, p, f, smash_from, smash_reach) else .{},
        .take => |h| if (w.getConst(h)) |f| take(kinds, m, p, f) else .{},
        .roam => |s| roam(m, p, s),
    };
    if (a.attack and m.goal == .foe) if (foeAt(w, kinds, m.goal.foe)) |f| noteFutile(w, m, f);
    m.wanted = walkOf(a);
    return if (ready(p)) safe(w, g, clearOf(m, keepOff(w, m, a, p, partner, leads), p, fire), p) else a;
}

/// A press at foe `f`: counted while its health stays as it was; after `futile_presses`, it backs
/// off from it a while.
fn noteFutile(w: *const World, m: *Memory, f: *const Entity) void {
    const i = @divExact(@intFromPtr(f) - @intFromPtr(&w.entities[0]), @sizeOf(Entity));
    const h = w.handleAt(i) orelse return;
    if (m.pressed_at == null or !m.pressed_at.?.eql(h) or f.health != m.pressed_health) {
        m.pressed_at = h;
        m.pressed_health = f.health;
        m.futile = 0;
        return;
    }
    m.futile += 1;
    if (m.futile < futile_presses) return;
    m.futile = 0;
    m.back_off = @intCast(between(m, back_off_ticks));
}

/// A look at the fight: what it goes for until its next, and its numbers for it.
fn lookAround(w: *const World, kinds: *const Kinds, floor: ?*const Floor, m: *Memory, k: u1, p: *const Entity, partner: ?*const Entity, leads: bool) void {
    if (m.seed == 0) m.seed = 0x9E3779B9 ^ w.tick;
    if (m.stuck >= stuck_ticks) switch (m.goal) {
        .take, .smash => |h| {
            m.given_up[m.give_up_at] = h;
            m.given_at[m.give_up_at] = w.tick;
            m.give_up_at +%= 1;
        },
        else => {},
    };
    const was = m.goal;
    m.goal = goalOf(w, kinds, floor, m, p, partner, leads);
    const new = std.meta.activeTag(was) != std.meta.activeTag(m.goal) or switch (was) {
        .roam => false,
        inline else => |h, tag| !h.eql(@field(m.goal, @tagName(tag))),
    };
    if (new) {
        m.wait = @intCast(between(m, wait_ticks));
        m.kick = m.chance(kick_chance);
    }
    m.slack = @intCast(between(m, slack_px));
    const boss = if (m.goal == .foe) if (w.getConst(m.goal.foe)) |f| kinds.get(f.kind.?).family() == .boss else false else false;
    m.grab = m.chance(if (boss) boss_grab_chance else grab_chance);
    m.short = @intCast(between(m, short_px));
    m.special = policeDue(w, kinds, k, p, partner) and m.chance(police_chance);
}

/// What it goes for: the best of what the screen shows, a little at random. A foe near comes
/// first (one on a player 1 in trouble before all, one player 1 fights after the others, one
/// player 1 nearer to it goes for after the others: the CPU takes the other side); then
/// what lies about (food when hurt, before the foes when badly hurt, unless player 1 is more hurt
/// and nearer; money, gold, a life, a special attack, unless player 1 is nearer); then a thing to
/// break (the same); else a place
/// of its own, kept until it has stayed there its while (the leader's ahead of itself). A goal
/// it got stuck on is let go, and a thing it got stuck going for, given up.
fn goalOf(w: *const World, kinds: *const Kinds, floor: ?*const Floor, m: *Memory, p: *const Entity, partner: ?*const Entity, leads: bool) Goal {
    const left = w.camera.x.whole();
    const share = healthShare(kinds, p);
    var best: Goal = .{ .roam = roamSpot(w, floor, m, p, if (leads) null else partner) };
    var best_score: i32 = 30 + @as(i32, m.draw(16));
    for (&w.entities, 0..) |*e, i| {
        if (!e.alive() or e.flags.hidden) continue;
        const x = e.position.x.whole();
        const edge: i32 = if (isFoe(kinds, e)) off_screen else 0;
        if (x < left - edge or x >= left + screen_width + edge) continue;
        const h = w.handleAt(i) orelse continue;
        if (givenUp(m, h, w.tick)) continue;
        const far: i32 = @intCast(apart(p, e));
        const kind = kinds.get(e.kind.?);
        var goal: Goal = undefined;
        var score: i32 = undefined;
        if (isFoe(kinds, e)) {
            goal = .{ .foe = h };
            score = 120 - @divTrunc(far, 3);
            if (partner) |q| {
                if (apart(q, e) < 56) {
                    score += if (inTrouble(q)) 40 else -40;
                } else if (headsFor(q, e) and apart(q, e) < far) score -= 40;
            }
        } else if (kind.family() == .item and e.mind == .item and e.mind.item.state == .lying and e.holder == null) {
            goal = .{ .take = h };
            if (isFood(kind)) {
                if (share >= peckish) continue;
                if (partner) |q| if (q.health < p.health and apart(q, e) < apart(p, e)) continue;
                // Needed, it comes before the fight, foes about it or not (`needsFood`).
                score = if (share < starving) 200 - @divTrunc(far, 4) else 80 - @divTrunc(far, 4) - @as(i32, if (foesNear(w, kinds, e, 48) > 0) 40 else 0);
            } else {
                if (partner) |q| if (apart(q, e) < apart(p, e)) continue;
                score = 75 - @divTrunc(far, 4);
                if (foesNear(w, kinds, e, 48) > 0) score -= 40;
            }
        } else if (breakable(e)) {
            if (partner) |q| if (apart(q, e) < apart(p, e)) continue;
            goal = .{ .smash = h };
            score = 50 - @divTrunc(far, 4);
        } else continue;
        if (std.meta.eql(goal, m.goal)) score += if (m.stuck >= stuck_ticks) -60 else 20;
        score += m.draw(16);
        if (score > best_score) {
            best_score = score;
            best = goal;
        }
    }
    return best;
}

/// Whether it gave `h` up, not long ago (`give_up_ticks`).
fn givenUp(m: *const Memory, h: Handle, now: u32) bool {
    for (m.given_up, m.given_at) |g, at| if (g) |x| if (x.eql(h) and now -% at < give_up_ticks) return true;
    return false;
}

/// The way out of player 1's line in depth, `up` or down, for `p`: the other when the edge of the
/// depths the players are kept on is within `edge_room` that way (where it would stay, its way
/// on shut; out of a thing's line coming at it, or player 1's blows', it keeps to its own way).
fn upOrDown(w: *const World, p: *const Entity, up: bool) bool {
    const rules = w.camera.follows orelse return up;
    const d = p.position.depth.whole();
    if (up and d - edge_room <= rules.kept_depth[0]) return false;
    if (!up and d + edge_room >= rules.kept_depth[1]) return true;
    return up;
}

/// Its place, roaming: the one it goes to while it has not stayed there its while, nor got stuck,
/// and it is still on the screen and out of player 1's line; else a new one: across from player 1
/// (mostly ahead, the way the round goes), out of its line on the CPU's side of it (now and then
/// the other), within the screen's margins; without player 1, ahead of itself.
fn roamSpot(w: *const World, floor: ?*const Floor, m: *Memory, p: *const Entity, partner: ?*const Entity) Spot {
    const left = w.camera.x.whole();
    if (m.goal == .roam) {
        const s = m.goal.roam;
        const done = m.linger == 0 and there(p, s);
        const off = s.x < left + margin_left or s.x > left + screen_width - margin_right;
        const in_line = if (partner) |q| @abs(q.position.depth.whole() - s.depth) <= line else false;
        if (!done and !off and !in_line and m.stuck < stuck_ticks and !(s.x == 0 and s.depth == 0)) return s;
    }
    if (m.stuck >= stuck_ticks) m.above = !m.above else if (m.chance(25)) m.above = !m.above;
    m.stuck = 0;
    m.linger = @intCast(between(m, linger_ticks));
    const way: i32 = if (w.camera.follows) |rules| (if (rules.leftward) -1 else 1) else 1;
    var s: Spot = undefined;
    if (partner) |q| {
        const aside = between(m, aside_px);
        s = .{ .x = q.position.x.whole() + way * between(m, ahead_px), .depth = q.position.depth.whole() + if (m.above) -aside else aside };
    } else s = .{ .x = p.position.x.whole() + way * between(m, alone_ahead_px), .depth = p.position.depth.whole() + between(m, .{ -20, 20 }) };
    s.x = std.math.clamp(s.x, left + margin_left, left + screen_width - margin_right);
    if (w.camera.follows) |rules| s.depth = std.math.clamp(s.depth, rules.kept_depth[0], rules.kept_depth[1]);
    return onFloor(floor, s);
}

fn spotHere(p: *const Entity) Spot {
    return .{ .x = p.position.x.whole(), .depth = p.position.depth.whole() };
}

fn there(p: *const Entity, s: Spot) bool {
    return @abs(s.x - p.position.x.whole()) <= there_px[0] and @abs(s.depth - p.position.depth.whole()) <= there_px[1];
}

/// To its place, and its while there.
fn roam(m: *Memory, p: *const Entity, s: Spot) Actions {
    var a: Actions = .{};
    go(&a, s.x - p.position.x.whole(), s.depth - p.position.depth.whole(), there_px[0], there_px[1]);
    if (@as(u8, @bitCast(a)) == 0 and m.linger > 0) m.linger -= 1;
    return a;
}

/// Whether `p` stands free to act: ready, idle or walking, armed or not.
fn ready(p: *const Entity) bool {
    return switch (p.mind.player.state) {
        .ready, .idle, .walk, .armed_stand, .armed_walk => true,
        else => false,
    };
}

/// A walk it wanted that did not take it from where it stood: counted, until it moves on, but
/// not while it is beset (it stays then by no fault of the way). Returns whether it is stuck now
/// (it looks again at once).
fn noteStuck(w: *const World, m: *Memory, p: *const Entity) bool {
    const here = spotHere(p);
    if (walks(m.wanted) and !beset(w, p) and @abs(here.x - m.stood.x) <= stuck_px and @abs(here.depth - m.stood.depth) <= stuck_px) {
        m.stuck +|= 1;
    } else {
        m.stuck = 0;
        m.stood = here;
    }
    if (m.stuck != stuck_ticks) return false;
    m.look = 0;
    return true;
}

/// Whether `p` is struck, held by a foe, thrown or down: where it stays is none of its walk's
/// doing. Held by player 1 (their team move, met by walking into each other), it is not: stuck,
/// it goes round once let go.
fn beset(w: *const World, p: *const Entity) bool {
    return switch (p.mind.player.state) {
        .held, .held_behind, .escape => if (p.holder) |h| w.playerOf(h) == null else false,
        .hurt, .knocked_down, .down, .getting_up, .recover, .thrown, .tossed, .shaken, .slam_pause, .lift, .air_slam, .air_fall, .slammed, .thrown_fall, .dying, .lying_dead => true,
        else => false,
    };
}

/// Where its goal is: its place, or its entity's.
fn goalPlace(w: *const World, goal: Goal) ?Spot {
    return switch (goal) {
        .roam => |s| s,
        inline else => |h| if (w.getConst(h)) |e| spotHere(e) else null,
    };
}

/// A solid thing's place on the ground: across and in depth, from and to.
const Rect = struct { left: i32, right: i32, far: i32, near: i32 };

/// The walk out across of a solid thing `p` stands in, to its nearer side; null out of all.
fn solidSide(w: *const World, kinds: *const Kinds, p: *const Entity) ?Actions {
    const here = spotHere(p);
    for (&w.entities) |*o| {
        if (!o.alive() or !o.flags.solid or o == p) continue;
        const def = kinds.get(o.kind.?).definition;
        const b = def.boxes[def.box("solid") orelse continue];
        const ox = o.position.x.whole();
        const od = o.position.depth.whole();
        if (here.x < ox + b.x.from or here.x > ox + b.x.to or here.depth < od + b.depth.from or here.depth > od + b.depth.to) continue;
        const left = here.x - (ox + b.x.from) <= ox + b.x.to - here.x;
        return .{ .left = left, .right = !left };
    }
    return null;
}

/// The cells of the ways round: the screen's across, and in depth to the ground's nearest.
const grid_w = screen_width / cell_px;
const grid_d = 240 / cell_px;

/// The walk round what stopped `p`, toward `to`: its first step (across or in depth: a step
/// across a corner would meet the thing) along the shortest way on a grid of the floor's cells
/// across the screen, the holes, the walls and the solid things left out (a step in depth, the
/// walls a cell ahead too, where a walk looks for them), and the places the camera keeps the
/// players out of, to the cell nearest `to` it reaches.
fn wayRound(w: *const World, g: Given, p: *const Entity, to: Spot) Actions {
    const x0 = @divFloor(w.camera.x.whole(), cell_px) * cell_px;
    var solids: [16]Rect = undefined;
    var n: usize = 0;
    for (&w.entities) |*o| {
        if (!o.alive() or !o.flags.solid or n == solids.len) continue;
        const def = g.kinds.get(o.kind.?).definition;
        const b = def.boxes[def.box("solid") orelse continue];
        const ox = o.position.x.whole();
        const od = o.position.depth.whole();
        // Grown by half a cell: a cell any part of which it covers is shut.
        const half = cell_px / 2;
        solids[n] = .{ .left = ox + b.x.from - half, .right = ox + b.x.to + half, .far = od + b.depth.from - half, .near = od + b.depth.to + half };
        n += 1;
    }
    const none = std.math.maxInt(u16);
    var came: [grid_w * grid_d]u16 = @splat(none);
    var queue: [grid_w * grid_d]u16 = undefined;
    const here = spotHere(p);
    const start = cellOf(x0, here);
    const goal = cellOf(x0, to);
    came[start] = start;
    queue[0] = start;
    var head: usize = 0;
    var tail: usize = 1;
    var best = start;
    while (head < tail) : (head += 1) {
        const c = queue[head];
        if (cellsApart(c, goal) < cellsApart(best, goal)) best = c;
        if (c == goal) break;
        const cx: i32 = c % grid_w;
        const cd: i32 = c / grid_w;
        for ([_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |step| {
            const nx = cx + step[0];
            const nd = cd + step[1];
            if (nx < 0 or nx >= grid_w or nd < 0 or nd >= grid_d) continue;
            const next: u16 = @intCast(nd * grid_w + nx);
            if (came[next] != none) continue;
            const x = x0 + nx * cell_px + cell_px / 2;
            const d = nd * cell_px + cell_px / 2;
            if (w.camera.follows) |rules| {
                const left = w.camera.x.whole();
                if (x < left + rules.kept_x[0] or x > left + rules.kept_x[1] or d < rules.kept_depth[0] or d > rules.kept_depth[1]) continue;
            }
            if (!open(g.floor, solids[0..n], x, d)) continue;
            if (step[1] != 0 and !open(g.floor, &.{}, x + cell_px, d)) continue;
            came[next] = c;
            queue[tail] = next;
            tail += 1;
        }
    }
    if (best == start) return .{};
    var c = best;
    while (came[c] != start) c = came[c];
    var a: Actions = .{};
    go(&a, @as(i32, c % grid_w) - @as(i32, start % grid_w), @as(i32, c / grid_w) - @as(i32, start / grid_w), 0, 0);
    return a;
}

/// The cell of the ways round of a place, on the screen whose left is `x0`.
fn cellOf(x0: i32, s: Spot) u16 {
    const cx = std.math.clamp(@divFloor(s.x - x0, cell_px), 0, grid_w - 1);
    const cd = std.math.clamp(@divFloor(s.depth, cell_px), 0, grid_d - 1);
    return @intCast(cd * grid_w + cx);
}

fn cellsApart(a: u16, b: u16) u32 {
    return @abs(@as(i32, a % grid_w) - @as(i32, b % grid_w)) + @abs(@as(i32, a / grid_w) - @as(i32, b / grid_w));
}

/// Whether a place is open to a walk: on the floor (no hole, no wall), out of the solid things.
fn open(floor: ?*const Floor, solids: []const Rect, x: i32, d: i32) bool {
    if (floor) |f| if (shut(f, x, d)) return false;
    for (solids) |r| if (x >= r.left and x <= r.right and d >= r.far and d <= r.near) return false;
    return true;
}

/// Holding `h`: player 1 (walked into after all), let go, away from it; a foe, its knees at its
/// pace, then the throw (away from it, and the blow).
fn withFoeHeld(w: *const World, kinds: *const Kinds, m: *Memory, k: u1, p: *const Entity, h: Handle) Actions {
    const away: Actions = if (p.facing == .left) .{ .right = true } else .{ .left = true };
    if (w.players[1 - k].entity) |q| if (q.eql(h)) return away;
    if (m.foe_held == null or !m.foe_held.?.eql(h)) {
        m.foe_held = h;
        m.knees = @intCast(between(m, knees));
    }
    if (!strike(m)) return .{};
    if (m.knees > 0 or heavy(w, kinds, h)) {
        m.knees -|= 1;
        return .{ .attack = true };
    }
    var throw = away;
    throw.attack = true;
    return throw;
}

/// Held from behind by a foe: after its reaction, C jumps out, and in the moment after it, B
/// throws the holder over. Thrown by a foe: up and C, after its reaction, land it on its feet.
/// Each now and then missed (a person's); each a press, released at the tick after. Null when
/// neither.
fn breakOut(w: *const World, m: *Memory, p: *const Entity) ?Actions {
    const s = &p.mind.player;
    const by_foe = if (p.holder) |h| w.playerOf(h) == null else false;
    const now: Caught = switch (s.state) {
        .escape => if (by_foe) .held_behind else .none,
        .held_behind => if (!by_foe) .none else if (s.counter_window != 0) .counter else .held_behind,
        .knocked_down => if (s.may_recover) .thrown else .none,
        else => .none,
    };
    if (now != m.caught) {
        m.caught = now;
        m.react = @intCast(if (now == .counter) between(m, counter_react_ticks) else between(m, react_ticks));
        m.tries = m.chance(switch (now) {
            .held_behind => escape_chance,
            .counter => counter_chance,
            .thrown => recover_chance,
            .none => 0,
        });
    }
    if (now == .none) return null;
    if (m.react > 0) {
        m.react -= 1;
        return .{};
    }
    if (!m.tries or s.state == .escape) return .{};
    const press = w.tick % 2 == 0;
    return switch (now) {
        .held_behind => .{ .jump = press },
        .counter => .{ .attack = press },
        .thrown => .{ .up = true, .jump = press },
        .none => unreachable,
    };
}

/// Whether it goes for food it needs (under `starving`), foe `f` not in its way there: not
/// between it and the food across.
fn needsFood(w: *const World, kinds: *const Kinds, m: *const Memory, p: *const Entity, f: *const Entity) bool {
    const h = switch (m.goal) {
        .take => |h| h,
        else => return false,
    };
    const food = w.getConst(h) orelse return false;
    if (!isFood(kinds.get(food.kind.?)) or healthShare(kinds, p) >= starving) return false;
    const to_food = food.position.x.whole() - p.position.x.whole();
    const to_foe = f.position.x.whole() - p.position.x.whole();
    return (to_food < 0) != (to_foe < 0) or @abs(to_foe) > @abs(to_food);
}

/// Whether `h` is too heavy to be thrown (round 4's boss, who crushes the thrower): knees only.
fn heavy(w: *const World, kinds: *const Kinds, h: Handle) bool {
    const e = w.getConst(h) orelse return false;
    return kinds.get(e.kind.?).definition.number("crush_toss_at") != null;
}

/// Whether the CPU calls the police (a life brings one): with one left and none under way, a
/// boss about it (the police hurt a boss as nothing else does), among three foes, or among two
/// and hurt, or near its end with a foe about; or player 1 near its end among two foes with none
/// of its own left.
fn policeDue(w: *const World, kinds: *const Kinds, k: u1, p: *const Entity, partner: ?*const Entity) bool {
    if (w.players[k].specials == 0 or w.special) return false;
    for (&w.entities) |*f| {
        if (isFoe(kinds, f) and kinds.get(f.kind.?).family() == .boss and apart(p, f) <= crowd_px) return true;
    }
    const share = healthShare(kinds, p);
    const near = foesNear(w, kinds, p, crowd_px);
    if (near >= 3 or (near >= 2 and share < hurt) or (near >= 1 and share < near_end)) return true;
    const q = partner orelse return false;
    return w.players[1 - k].specials == 0 and healthShare(kinds, q) < near_end and foesNear(w, kinds, q, crowd_px) >= 2;
}

/// The share of its full health `e` has left, in a hundred.
fn healthShare(kinds: *const Kinds, e: *const Entity) i32 {
    const full: i32 = kinds.get(e.kind.?).definition.health;
    return if (full == 0) 100 else @divTrunc(@as(i32, e.health) * 100, full);
}

/// Whether player 1 `q` goes for `e`, as a person sees it: it faces it, not in trouble.
fn headsFor(q: *const Entity, e: *const Entity) bool {
    if (inTrouble(q)) return false;
    const dx = e.position.x.whole() - q.position.x.whole();
    return dx != 0 and (dx < 0) == (q.facing == .left);
}

/// Player 1 held, hurt or down: a foe on it is helped against first.
fn inTrouble(q: *const Entity) bool {
    return switch (q.mind.player.state) {
        .held, .held_behind, .hurt, .knocked_down, .down, .thrown => true,
        else => false,
    };
}

/// Its foe `h` while it is one.
fn foeAt(w: *const World, kinds: *const Kinds, h: Handle) ?*const Entity {
    const e = w.getConst(h) orelse return null;
    return if (isFoe(kinds, e)) e else null;
}

/// The thing to break `h` while it stands.
fn standing(w: *const World, h: Handle) ?*const Entity {
    const e = w.getConst(h) orelse return null;
    return if (breakable(e)) e else null;
}

/// A thing of the street a blow breaks or knocks away, standing.
fn breakable(e: *const Entity) bool {
    return switch (e.mind) {
        .breakable => |b| b.state == .stand,
        .knockable => |b| b.state == .stand,
        .crate => |b| b.state == .stand,
        .obstacle => |b| b.state == .stand,
        .shatter => |b| b.state == .stand,
        else => false,
    };
}

/// Food: an item whose definition gives health (the apple, the beef, a mod's own).
fn isFood(kind: *const kinds_mod.Kind) bool {
    return kind.behaviour == .item and kinds_mod.numbersOf(behaviours.module(.item), kind).health > 0;
}

/// The foes within `px` (across plus in depth) of `e`.
fn foesNear(w: *const World, kinds: *const Kinds, e: *const Entity, px: u32) u8 {
    var n: u8 = 0;
    for (&w.entities) |*f| {
        if (isFoe(kinds, f) and apart(e, f) <= px) n +|= 1;
    }
    return n;
}

/// Whether a foe stands right behind `p`, in its line.
fn foeBehind(w: *const World, kinds: *const Kinds, p: *const Entity) bool {
    for (&w.entities) |*f| {
        if (!isFoe(kinds, f)) continue;
        const dx = f.position.x.whole() - p.position.x.whole();
        const behind = if (p.facing == .left) dx > 0 else dx < 0;
        if (behind and @abs(dx) <= behind_px[0] and @abs(f.position.depth.whole() - p.position.depth.whole()) <= behind_px[1]) return true;
    }
    return false;
}

/// Its foe: at the reach it drew (or into it, to grab it), on its own side of it (the other when
/// player 1 is there, or its blows' way holds the place, unless the other is taken too), level
/// with it; faced, and struck at its pace, but not while it is down;
/// from farther, in its line, now and then a jump kick in. A boss, from farther than its reach,
/// it comes at out of its line, where the boss charges, slashes and throws; facing it while
/// player 1 is near it, it keeps out of its line, facing it, and lets player 1 draw it; its back
/// turned, it comes round to it. `range`: its jab's reach on it.
fn fightFoe(w: *const World, m: *Memory, p: *const Entity, f: *const Entity, partner: ?*const Entity, fire: ?Fire, range: i32, boss: bool) Actions {
    const px = p.position.x.whole();
    const fx = f.position.x.whole();
    const dx = fx - px;
    const dd = f.position.depth.whole() - p.position.depth.whole();
    // Its jump: on at it through the crouch and in the air, and the kick once near.
    switch (p.mind.player.state) {
        .jump_crouch, .jump, .armed_jump_crouch, .armed_jump => {
            const air = p.mind.player.state == .jump or p.mind.player.state == .armed_jump;
            return .{ .left = dx < 0, .right = dx > 0, .attack = air and @abs(dx) < kick_reach };
        },
        else => {},
    }
    if (m.kick and ready(p) and @abs(dd) <= m.slack and @abs(dx) >= kick_from[0] and @abs(dx) <= kick_from[1] and (dx < 0) == (p.facing == .left)) {
        m.kick = false;
        return .{ .left = dx < 0, .right = dx > 0, .jump = true };
    }
    var side: i32 = if (dx > 0) -1 else 1;
    if (sideTaken(f, partner, fire, side, range) and !sideTaken(f, partner, fire, -side, range)) side = -side;
    if (behaviours.inState(&f.mind, "knocked_down")) {
        // Down: it waits at its range, out of the way of its getting up.
        var a: Actions = .{};
        go(&a, fx + side * range - px, dd, 6, m.slack);
        return a;
    }
    if (boss and !behaviours.inState(&f.mind, "held")) {
        var a: Actions = .{};
        const aside: i32 = if (dd > 0) -boss_aside else boss_aside;
        const facing_it = (f.facing == .left) == (fx > px);
        const busy = if (partner) |q| apart(q, f) <= boss_busy else false;
        if (facing_it and busy and @abs(dx) > range) {
            // Out of its line in depth alone, facing it: a walk away across would turn its back,
            // which a boss sets on.
            go(&a, 0, dd + aside, 0, m.slack);
            if (!walks(a) and (p.facing == .left) != (dx < 0)) {
                a.left = dx < 0;
                a.right = dx > 0;
            }
            return a;
        }
        const back: i32 = if (f.facing == .left) 1 else -1;
        const behind = (px - fx) * back > 0;
        if (@abs(dx) > range + boss_room or (!facing_it and !behind)) {
            go(&a, fx + (if (facing_it) side else back) * range - px, dd + aside, 6, m.slack);
            return a;
        }
    }
    return strikeAt(w, m, p, f, if (m.grab) 0 else @intCast(@max(range - m.short, too_close)), range - 1);
}

/// Whether its place on `side` of foe `f`, `range` across from it, is player 1's: player 1 stands
/// there by the foe, in its line, or its blows' way holds the place.
fn sideTaken(f: *const Entity, partner: ?*const Entity, fire: ?Fire, side: i32, range: i32) bool {
    const fx = f.position.x.whole();
    const fd = f.position.depth.whole();
    if (fire) |z| if (z.holds(.{ .x = fx + side * range, .depth = fd })) return true;
    const q = partner orelse return false;
    const qx = q.position.x.whole();
    return (qx - fx) * side > 0 and @abs(qx - fx) <= range + reach_room and @abs(q.position.depth.whole() - fd) <= line;
}

/// `f` struck: within `within` across and level with it, faced and struck at its pace; else to
/// `from` pixels across from it on the CPU's side (into it, at 0), level with it. Too close, it
/// steps back, the other way at the edge of the view the players are kept in.
fn strikeAt(w: *const World, m: *Memory, p: *const Entity, f: *const Entity, from: u8, within: i32) Actions {
    const px = p.position.x.whole();
    const dx = f.position.x.whole() - px;
    const dd = f.position.depth.whole() - p.position.depth.whole();
    const side: i32 = if (dx > 0) -1 else 1;
    var a: Actions = .{};
    if (from == 0) {
        go(&a, dx, dd, 0, m.slack);
        return a;
    }
    if (@abs(dx) < too_close) {
        a.left = dx >= 0;
        a.right = dx < 0;
        if (atEdge(w, p, a.left)) {
            a.left = !a.left;
            a.right = !a.right;
        }
        return a;
    }
    if (@abs(dx) <= within and @abs(dd) <= jab_level) {
        if ((dx < 0) != (p.facing == .left)) return .{ .left = dx < 0, .right = dx >= 0 };
        return .{ .attack = strike(m) };
    }
    go(&a, f.position.x.whole() + side * @as(i32, from) - px, dd, 6, m.slack);
    return a;
}

/// What comes at `p` in its line, from ahead or behind: fast, an enemy's thing in flight (a
/// knife, a boomerang, a shot, a boss's rush) or a boss; or a boss facing it beyond `jab` (its
/// jab's reach ahead) and its own body, lining up its charge or its slash.
fn threat(w: *const World, kinds: *const Kinds, p: *const Entity, jab: i32) ?*const Entity {
    for (&w.entities) |*e| {
        if (!e.alive() or e.flags.hidden or e.team != .enemy) continue;
        const family = kinds.get(e.kind.?).family();
        if (family != .projectile and family != .boss) continue;
        const dx = e.position.x.whole() - p.position.x.whole();
        if (@abs(dx) > threat_px[0] or @abs(e.position.depth.whole() - p.position.depth.whole()) > threat_px[1]) continue;
        const vx = e.velocity.x.raw;
        if ((dx > 0 and vx <= -fast_raw) or (dx < 0 and vx >= fast_raw)) return e;
        const facing_it = (e.facing == .left) == (dx > 0);
        if (family == .boss and isFoe(kinds, e) and facing_it and @abs(dx) > reachOn(kinds, jab, p, e) + boss_room) return e;
    }
    return null;
}

/// A foe standing in front of `p` within its jab's reach (`jab` ahead of it), level with it, and
/// not down.
fn foeInFront(w: *const World, kinds: *const Kinds, p: *const Entity, jab: i32) ?*const Entity {
    for (&w.entities) |*f| {
        if (!isFoe(kinds, f) or behaviours.inState(&f.mind, "knocked_down")) continue;
        const dx = f.position.x.whole() - p.position.x.whole();
        const ahead = if (p.facing == .left) -dx else dx;
        if (ahead >= too_close and ahead < reachOn(kinds, jab, p, f) and @abs(f.position.depth.whole() - p.position.depth.whole()) <= jab_level) return f;
    }
    return null;
}

/// How far ahead of `p` its jab reaches: its first blow's box's far end, by its definition.
fn jabAhead(kinds: *const Kinds, p: *const Entity) i32 {
    const d = kinds.get(p.kind.?).definition;
    return d.boxes[d.box("attack1_blow") orelse return jab_ahead].x.to;
}

/// How far across from `f` `p`'s jab, `jab` ahead of it, meets its body as it stands.
fn reachOn(kinds: *const Kinds, jab: i32, p: *const Entity, f: *const Entity) i32 {
    const body = kinds.get(f.kind.?).definition.boxes[f.boxes.body orelse return jab].across(f.boxes.mirrored);
    return jab + if (f.position.x.whole() > p.position.x.whole()) -body.from else body.to;
}

/// An item: to it, and picked up.
fn take(kinds: *const Kinds, m: *Memory, p: *const Entity, f: *const Entity) Actions {
    var a: Actions = .{};
    go(&a, f.position.x.whole() - p.position.x.whole(), f.position.depth.whole() - p.position.depth.whole(), 12, 8);
    if (@as(u8, @bitCast(a)) != 0 and !bodiesMeet(kinds, p, f)) return a;
    return .{ .attack = strike(m) };
}

/// Whether the bodies of `p` and `f` meet: a pick-up takes it (an item at the floor's back edge,
/// short of which it stands, too).
fn bodiesMeet(kinds: *const Kinds, p: *const Entity, f: *const Entity) bool {
    const pb = p.boxes.body orelse return false;
    const fb = f.boxes.body orelse return false;
    return systems.meet(p, &kinds.get(p.kind.?).definition.boxes[pb], f, &kinds.get(f.kind.?).definition.boxes[fb]);
}

/// The walk of `a`, its actions left out.
fn walkOf(a: Actions) Actions {
    return .{ .up = a.up, .down = a.down, .left = a.left, .right = a.right };
}

/// Whether `a` walks.
fn walks(a: Actions) bool {
    return a.up or a.down or a.left or a.right;
}

/// The actions `a`, their walk kept off player 1 `q`, whose body a walk's reach would grab. In
/// its line: very close, it does not walk (the leader walks away); within a walk's reach facing
/// it, it turns away; else it steps out of the line rather than walk at it, as it does when
/// player 1 walks at it (not the leader). Beside it, out of its line, it keeps out. Its blows
/// stay.
fn keepOff(w: *const World, m: *const Memory, a: Actions, p: *const Entity, q: ?*const Entity, leads: bool) Actions {
    const other = q orelse return a;
    const dx = other.position.x.whole() - p.position.x.whole();
    const dd = other.position.depth.whole() - p.position.depth.whole();
    const ax = @abs(dx);
    var out = a;
    if (@abs(dd) > line) {
        if (ax <= reach_room and @abs(dd) <= beside and ((dd > 0 and a.down) or (dd < 0 and a.up))) {
            out.up = false;
            out.down = false;
        }
        return out;
    }
    const at_it = (dx > 0 and a.right) or (dx < 0 and a.left);
    const coming = !leads and other.mind.player.state == .walk and (other.facing == .left) == (dx > 0) and ax <= coming_room;
    if (ax > pass_room and !coming) return a;
    if (!at_it and !coming and !(ax <= reach_room and (a.up or a.down))) return a;
    out.up = false;
    out.down = false;
    out.left = false;
    out.right = false;
    if (ax <= body_room and !leads) return out;
    if (ax <= body_room or (ax <= reach_room and (p.facing == .left) == (dx < 0))) {
        out.left = if (dx == 0) p.facing == .left else dx > 0;
        out.right = !out.left;
        // At the edge of the view the players are kept in, that way is shut: out in depth.
        if (!atEdge(w, p, out.left)) return out;
        out.left = false;
        out.right = false;
    }
    const up = upOrDown(w, p, if (dd != 0) dd > 0 else m.above);
    out.up = up;
    out.down = !up;
    if (!at_it) {
        out.left = a.left;
        out.right = a.right;
    }
    return out;
}

/// Player 1's blows' way, while it fights: ahead of it (by its facing) to its jab's reach on a
/// body and `fire_room` more, within `fire_line` of its line in depth.
const Fire = struct {
    x: i32,
    depth: i32,
    way: i32,
    reach: i32,

    fn holds(z: Fire, s: Spot) bool {
        const ahead = (s.x - z.x) * z.way;
        return ahead > 0 and ahead <= z.reach and @abs(s.depth - z.depth) <= fire_line;
    }
};

/// Player 1's blows' way (`Fire`) while it strikes, or a foe stands in it or a walk's room
/// beyond (it is about to strike); none else.
fn fireOf(w: *const World, kinds: *const Kinds, partner: ?*const Entity) ?Fire {
    const q = partner orelse return null;
    const z: Fire = .{
        .x = q.position.x.whole(),
        .depth = q.position.depth.whole(),
        .way = if (q.facing == .left) -1 else 1,
        .reach = jabAhead(kinds, q) + body_room + fire_room,
    };
    switch (q.mind.player.state) {
        .attack1, .attack2, .attack3, .attack4, .armed_attack, .armed_stab, .armed_swing => return z,
        else => {},
    }
    for (&w.entities) |*f| {
        if (!isFoe(kinds, f) or behaviours.inState(&f.mind, "knocked_down")) continue;
        const ahead = (f.position.x.whole() - z.x) * z.way;
        if (ahead > 0 and ahead <= z.reach + pass_room and @abs(f.position.depth.whole() - z.depth) <= line) return z;
    }
    return null;
}

/// The walk of `a` kept out of player 1's blows' way (`fire`): a step that would take it in is
/// left out, and for one across it goes round in depth, the nearer way. Already in it (player 1
/// came behind it), it stays: leaving the foe it fights would leave it open.
fn clearOf(m: *const Memory, a: Actions, p: *const Entity, fire: ?Fire) Actions {
    const z = fire orelse return a;
    const here = spotHere(p);
    if (z.holds(here)) return a;
    const dd = here.depth - z.depth;
    const up = if (dd != 0) dd < 0 else m.above;
    var out = a;
    const sx: i32 = if (a.right) hole_ahead[0] else if (a.left) -hole_ahead[0] else 0;
    const sd: i32 = if (a.down) hole_ahead[1] else if (a.up) -hole_ahead[1] else 0;
    if (sd != 0 and z.holds(.{ .x = here.x, .depth = here.depth + sd })) {
        out.up = false;
        out.down = false;
    }
    if (sx != 0 and z.holds(.{ .x = here.x + sx, .depth = here.depth })) {
        out.left = false;
        out.right = false;
        if (!out.up and !out.down) {
            out.up = up;
            out.down = !up;
        }
    }
    return out;
}

/// The walk of `a` kept off the holes of the round's floor and from under the presses about to
/// come down.
fn safe(w: *const World, g: Given, a: Actions, p: *const Entity) Actions {
    return offPresses(w, g.kinds, offHoles(w, g.floor, a, p), p);
}

/// The walk of `a` kept from under the presses about to come down (`pressOver`): a step across or
/// in depth that would take it under one is left out (from under one, it goes on).
fn offPresses(w: *const World, kinds: *const Kinds, a: Actions, p: *const Entity) Actions {
    const here = spotHere(p);
    if (pressOver(w, kinds, here, press_in) != null) return a;
    var out = a;
    const sx: i32 = if (a.right) hole_ahead[0] else if (a.left) -hole_ahead[0] else 0;
    const sd: i32 = if (a.down) hole_ahead[1] else if (a.up) -hole_ahead[1] else 0;
    if (sx != 0 and pressOver(w, kinds, .{ .x = here.x + sx, .depth = here.depth }, press_in) != null) {
        out.left = false;
        out.right = false;
    }
    if (sd != 0 and pressOver(w, kinds, .{ .x = here.x, .depth = here.depth + sd }, press_in) != null) {
        out.up = false;
        out.down = false;
    }
    return out;
}

/// Round 6's press about to come down (shaking, dropping or bouncing) whose blows' boxes, grown by
/// `margin`, hold the place `s`: the walk out from under it, to the box's nearest side (in depth
/// counted half as far again, a walk's pace there being slower).
fn pressOver(w: *const World, kinds: *const Kinds, s: Spot, margin: i32) ?Actions {
    for (&w.entities) |*e| {
        if (!e.alive() or e.mind != .press) continue;
        switch (e.mind.press.state) {
            .shake, .drop, .bounce => {},
            else => continue,
        }
        const def = kinds.get(e.kind.?).definition;
        const ex = e.position.x.whole();
        const ed = e.position.depth.whole();
        for ([_][]const u8{ "drop_front", "drop_back" }) |box| {
            const b = def.boxes[def.box(box) orelse continue];
            const left = s.x - (ex + b.x.from - margin);
            const right = ex + b.x.to + margin - s.x;
            const up = s.depth - (ed + b.depth.from - margin);
            const down = ed + b.depth.to + margin - s.depth;
            if (left < 0 or right < 0 or up < 0 or down < 0) continue;
            const across = @min(left, right);
            const depth = @divTrunc(@min(up, down) * 3, 2);
            if (across <= depth) return .{ .left = left <= right, .right = left > right };
            return .{ .up = up <= down, .down = up > down };
        }
    }
    return null;
}

/// The walk of `a` kept off the holes and the walls of the round's floor `floor` (`shut`): a step
/// in depth that would end over one, or before a wall where a walk looks for one (a cell ahead
/// across, `wall_ahead`), is left out, and so is a step across, for which it goes round in depth
/// the nearer way the floor goes on ahead, on the depths the players are kept on.
fn offHoles(w: *const World, floor: ?*const Floor, a: Actions, p: *const Entity) Actions {
    const f = floor orelse return a;
    const x = p.position.x.whole();
    const d = p.position.depth.whole();
    var out = a;
    const sx: i32 = if (a.right) hole_ahead[0] else if (a.left) -hole_ahead[0] else 0;
    var sd: i32 = if (a.down) hole_ahead[1] else if (a.up) -hole_ahead[1] else 0;
    const look: i32 = if (a.left) -wall_ahead else wall_ahead;
    if (sd != 0 and (shut(f, x, d + sd) or shut(f, x + look, d + sd))) {
        out.up = false;
        out.down = false;
        sd = 0;
    }
    if (sx == 0 or !(shut(f, x + sx, d) or shut(f, x + sx, d + sd))) return out;
    out.left = false;
    out.right = false;
    if (sd != 0) return out;
    var off: i32 = cell_px;
    while (off <= round_px) : (off += cell_px) {
        for ([_]i32{ -off, off }) |o| if (kept(w, d + o) and !shut(f, x + sx, d + o) and !shut(f, x, d + o) and !shut(f, x + look, d + o)) {
            out.up = o < 0;
            out.down = o > 0;
            return out;
        };
    }
    return out;
}

/// Whether `p` stands within `edge_room` of the edge of the view the players are kept in (the
/// camera's rules), on its left or on its right.
fn atEdge(w: *const World, p: *const Entity, left: bool) bool {
    const rules = w.camera.follows orelse return false;
    const x = p.position.x.whole() - w.camera.x.whole();
    return if (left) x - edge_room <= rules.kept_x[0] else x + edge_room >= rules.kept_x[1];
}

/// Whether the depth `d` is on the depths the players are kept on (the camera's rules).
fn kept(w: *const World, d: i32) bool {
    const rules = w.camera.follows orelse return true;
    return d >= rules.kept_depth[0] and d <= rules.kept_depth[1];
}

/// Whether the floor's cell at `x`, `d` is shut to a walk: a hole, or a wall (no height).
fn shut(f: *const Floor, x: i32, d: i32) bool {
    const cell = f.at(x, d);
    return !cell.floor or cell.height == 0;
}

/// `s` moved in depth onto the round's floor (out of a hole or a wall), the nearer way; as it was
/// where none is near.
fn onFloor(floor: ?*const Floor, s: Spot) Spot {
    const f = floor orelse return s;
    if (!shut(f, s.x, s.depth)) return s;
    var off: i32 = cell_px;
    while (off <= round_px) : (off += cell_px) {
        for ([_]i32{ -off, off }) |o| if (!shut(f, s.x, s.depth + o) and !shut(f, s.x + wall_ahead, s.depth + o)) return .{ .x = s.x, .depth = s.depth + o };
    }
    return s;
}

/// The walk to a place `dx` across and `dd` in depth away, near enough within `slack_x` and
/// `slack_d`.
fn go(a: *Actions, dx: i32, dd: i32, slack_x: i32, slack_d: i32) void {
    a.left = dx < -slack_x;
    a.right = dx > slack_x;
    a.up = dd < -slack_d;
    a.down = dd > slack_d;
}

/// Whether it strikes at this tick, at a person's pace: bursts of blows a few ticks apart, a
/// breath after each.
fn strike(m: *Memory) bool {
    if (m.breath > 0) {
        m.breath -= 1;
        return false;
    }
    if (m.beat > 0) {
        m.beat -= 1;
        return false;
    }
    if (m.blows == 0) m.blows = @intCast(between(m, burst));
    m.blows -= 1;
    m.beat = @intCast(between(m, beat_ticks) - 1);
    if (m.blows == 0) m.breath = @intCast(between(m, breath_ticks));
    return true;
}

/// How far apart two entities are: across, plus in depth.
fn apart(a: *const Entity, b: *const Entity) u32 {
    return @abs(a.position.x.whole() - b.position.x.whole()) + @abs(a.position.depth.whole() - b.position.depth.whole());
}

/// Whether the way right is shut, at its depth, by a solid thing ahead.
fn blockedAhead(w: *const World, p: *const Entity) bool {
    if (p.facing == .left) return false;
    const px = p.position.x.whole();
    const pd = p.position.depth.whole();
    for (&w.entities) |*e| {
        if (!e.alive() or !e.flags.solid or e.flags.hidden) continue;
        const dx = e.position.x.whole() - px;
        if (dx >= 0 and dx <= blocked and @abs(e.position.depth.whole() - pd) <= blocked_depth) return true;
    }
    return false;
}

/// Item 30's rule (sor-remaster's runner's bot), which the agent host's bot plays: the depth
/// within which it is level with its foe, the reach it jabs from across (its jab's), the least
/// across it keeps; the health under which food comes first; how far ahead across and in depth
/// a solid thing stops its walk.
const level = 3;
const reach = 34;
const close = 14;
const hungry = 40;
const blocked = 48;
const blocked_depth = 12;

/// Player `k`'s pad at tick `now` by the fight's rule (the cartridge's buttons: B attacks), while
/// it is a fighter; null otherwise.
pub fn fight(w: *const World, kinds: *const Kinds, k: u1, now: u64) ?input.Pad {
    const p = w.getConst(w.players[k].entity orelse return null) orelse return null;
    if (p.mind != .player) return null;
    const px = p.position.x.whole();
    const pd = p.position.depth.whole();
    const left = p.facing == .left;
    const jab = now % 2 == 0;
    switch (p.mind.player.state) {
        .grab, .grab_behind, .grab_blow => return .{ .b = jab },
        else => {},
    }
    var out: input.Pad = .{};
    if (p.health < hungry) if (nearest(w, kinds, px, pd, .food)) |e| {
        const dx = e.position.x.whole() - px;
        const dd = e.position.depth.whole() - pd;
        if (@abs(dd) > 2) {
            out.up = dd < 0;
            out.down = dd > 0;
        }
        if (@abs(dx) > 6) {
            out.left = dx < 0;
            out.right = dx > 0;
        }
        if (@as(u8, @bitCast(out)) == 0) out.b = jab;
        return out;
    };
    // No foe: right, but a solid thing ahead at its depth stops the walk, and is jabbed.
    const foe = nearest(w, kinds, px, pd, .foe) orelse return if (blockedAhead(w, p)) .{ .b = jab } else .{ .right = true };
    const dx = foe.position.x.whole() - px;
    const dd = foe.position.depth.whole() - pd;
    if (@abs(dd) > level) {
        out.up = dd < 0;
        out.down = dd > 0;
    }
    if (@abs(dx) > reach) {
        out.left = dx < 0;
        out.right = dx > 0;
    } else if (@abs(dx) < close) {
        out.right = dx < 0;
        out.left = dx >= 0;
    } else if ((dx < 0) != left) {
        out.left = dx < 0;
        out.right = dx >= 0;
    } else if (@as(u8, @bitCast(out)) == 0) out.b = jab;
    return out;
}

/// The nearest entity (across plus in depth) the rule looks for: a foe (`isFoe`), or food
/// (`isFood`).
fn nearest(w: *const World, kinds: *const Kinds, px: i32, pd: i32, what: enum { foe, food }) ?*const Entity {
    var best: ?*const Entity = null;
    var best_d: u32 = std.math.maxInt(u32);
    for (&w.entities) |*e| {
        if (!e.alive() or e.flags.hidden) continue;
        switch (what) {
            .foe => if (!isFoe(kinds, e)) continue,
            .food => if (!isFood(kinds.get(e.kind.?))) continue,
        }
        const d = @abs(e.position.x.whole() - px) + @abs(e.position.depth.whole() - pd);
        if (d < best_d) {
            best_d = d;
            best = e;
        }
    }
    return best;
}

/// A foe: an enemy or a boss out of hiding with health left, neither appearing (nor waiting to
/// come in: round 5's acrobats behind the wall, until the camera nears them) nor knocked out.
fn isFoe(kinds: *const Kinds, e: *const Entity) bool {
    if (!e.alive() or e.flags.hidden) return false;
    const f = kinds.get(e.kind.?).family();
    if (f != .enemy and f != .boss) return false;
    if (e.health < 0) return false;
    return !behaviours.inState(&e.mind, "appear") and !behaviours.inState(&e.mind, "enter") and !behaviours.inState(&e.mind, "knocked_out");
}

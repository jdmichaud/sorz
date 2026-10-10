//! The CPU's play (PLAN items 30 and 31): a player's pad from what the round's world shows and
//! what the CPU remembers (`Memory`, its world's player's), the same on every machine. It
//! chooses once a logic tick (the world's clock), from the world as its last logic tick left it:
//! the pad is the same at both display ticks of one, as a player's read is.
//!
//! - In the fight it plays as a person, with a mind of its own. A few times a second it looks
//!   at the screen (so it reacts late) and goes for the best of what it shows, a little at
//!   random: a foe near (one on a player 1 in trouble first, one player 1 fights after the
//!   others), what lies about (food when hurt, money, gold, a life, a special attack), a thing to
//!   break, or else a place of its own, mostly ahead of player 1 and out of its line, where it
//!   stays a while before choosing another. It strikes at a person's pace, a few blows and a
//!   breath, from the side player 1 is not on; now and then it walks into its foe to grab it,
//!   knees it and throws it, comes in with a jump kick, and strikes a foe behind it with the
//!   back attack. It calls the police when a life is at stake: swarmed, hurt among foes, near its
//!   end, or player 1 near its end without one of its own. It never blocks player 1's way:
//!   walked at, it steps out of its line, and it never walks into it, which would grab it.
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
const behaviours = @import("behaviours.zig");
const player_waiting = @import("behaviours/player_waiting.zig");

const World = world_mod.World;
const Actions = world_mod.Actions;
const Entity = entity.Entity;
const Handle = entity.Handle;
const Kinds = kinds_mod.Kinds;
const Layout = content_screens.Layout;

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
    /// Drawn for its foe at each look: how near in depth is near enough to strike, the reach it
    /// strikes from across (0: it walks into the foe, to grab it), and a jump kick to come in.
    slack: u8 = 3,
    reach: u8 = 24,
    kick: bool = false,
    /// The special attack it calls at its next tick free to act.
    special: bool = false,
    /// The blows' pace: those left in its burst, the ticks to the next, its breath after.
    blows: u8 = 0,
    beat: u8 = 0,
    breath: u8 = 0,
    /// The foe it holds, and the knees it gives it before it throws it.
    held: ?Handle = null,
    knees: u8 = 0,
    /// Its side of player 1's line: above it (farther away) or below.
    above: bool = false,
    /// A walk that does not move it: the ticks so far, and where it stood.
    stuck: u8 = 0,
    stood: Spot = .{},

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

/// A place in the world: across, and in depth.
pub const Spot = struct { x: i32 = 0, depth: i32 = 0 };

/// What the CPU goes for: a place of its own, a foe, an item to take, a thing to break.
pub const Goal = union(enum) { roam: Spot, foe: Handle, take: Handle, smash: Handle };

/// The rule's numbers, in logic ticks (30 a second) and pixels. Its looks, and a new goal's wait
/// (its reaction); its blows' bursts, the ticks from one blow to the next (six to ten a second)
/// and its breath after a burst; the knees it gives a foe it holds before throwing it.
const look_ticks = .{ 5, 10 };
const wait_ticks = .{ 3, 6 };
const burst = .{ 3, 5 };
const beat_ticks = .{ 3, 5 };
const breath_ticks = .{ 8, 20 };
const knees = .{ 0, 2 };
/// Its foe: the reach it strikes from (its jab's is 34), how near in depth (blows reach 16), the
/// least it keeps across; the chances in a hundred, at a look, that it goes to grab its foe, and
/// that it comes in with a jump kick, from within the kick's distances.
const reach_px = .{ 20, 28 };
const slack_px = .{ 2, 6 };
const too_close = 14;
const smash_reach = 24;
const grab_chance = 20;
const kick_chance = 20;
const kick_from = .{ 40, 72 };
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
/// Its places: across from player 1 (mostly ahead, as the round goes right), out of its line in
/// depth, within the screen's margins; the ticks it stays at one; near enough to it. Without
/// player 1, ahead of itself.
const ahead_px = .{ -40, 120 };
const aside_px = .{ 24, 44 };
const margin_left = 48;
const margin_right = 64;
const linger_ticks = .{ 20, 80 };
const there_px = .{ 8, 4 };
const alone_ahead_px = .{ 40, 120 };
/// A walk that has not moved it for this many ticks is stuck: it goes elsewhere.
const stuck_ticks = 8;
/// Food is wanted under this share of its health in a hundred, and needed under the second.
const peckish = 75;
const starving = 40;
/// Player 1's room (a walk's reach grabs what it meets: the reach 16 pixels ahead, a body up to
/// 13 ahead, each 8 either side in depth): in its line within this in depth; within a body's
/// reach across, a walk's, and the room to leave its line before walking at it; and how near
/// player 1 walking at it makes it step aside.
const line = 18;
const body_room = 14;
const reach_room = 32;
const pass_room = 48;
const coming_room = 72;

/// Player `k`'s pad as the CPU plays it, its memory `m`, from the world as its last logic tick
/// left it: `letters` are the name entry's (content), `layout` the buttons of the options'
/// CONTROL.
pub fn pad(w: *const World, kinds: *const Kinds, m: *Memory, letters: []const []const u8, layout: Layout, k: u1) input.Pad {
    const press = w.tick % 2 == 0;
    const r = &w.room;
    // Held in the offer's choice: its answer, no, and nothing once given.
    if (r.choosing[k]) return if (r.answered[k]) .{} else padOf(if (r.on_no[k]) .{ .attack = press } else .{ .down = press }, layout);
    const e = w.getConst(w.players[k].entity orelse return .{}) orelse return .{};
    return switch (e.mind) {
        .player => padOf(choose(w, kinds, m, k, e), layout),
        .player_waiting => |*mind| switch (mind.state) {
            .name_entry => entry(mind, letters, layout, press),
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
fn choose(w: *const World, kinds: *const Kinds, m: *Memory, k: u1, p: *const Entity) Actions {
    if (m.at) |at| if (at == w.tick) return m.chose;
    m.at = w.tick;
    m.chose = play(w, kinds, m, k, p);
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

fn play(w: *const World, kinds: *const Kinds, m: *Memory, k: u1, p: *const Entity) Actions {
    const partner = partnerOf(w, k);
    noteStuck(m, p);
    if (p.holding) |h| return hold(w, m, k, p, h);
    m.held = null;
    if (m.look == 0) {
        lookAround(w, kinds, m, k, p, partner);
        m.look = @intCast(between(m, look_ticks));
    } else m.look -= 1;
    if (m.special and ready(p)) {
        m.special = false;
        return .{ .special = true };
    }
    // A new goal: it walks on as it walked a moment (not its blows).
    if (m.wait > 0) {
        m.wait -= 1;
        return keepOff(m, walkOf(m.chose), p, partner);
    }
    // A foe right behind it, while it fights another: now and then, the back attack.
    if (m.goal == .foe and ready(p)) if (foeBehind(w, kinds, p)) {
        if (m.chance(back_chance)) return .{ .attack = true, .jump = true };
    };
    const a: Actions = switch (m.goal) {
        .foe => |h| if (foeAt(w, kinds, h)) |f| fightFoe(m, p, f, partner) else .{},
        .smash => |h| if (standing(w, h)) |f| strikeAt(m, p, f, smash_reach) else .{},
        .take => |h| if (w.getConst(h)) |f| take(m, p, f) else .{},
        .roam => |s| roam(m, p, s),
    };
    return if (ready(p)) keepOff(m, a, p, partner) else a;
}

/// A look at the fight: what it goes for until its next, and its numbers for it.
fn lookAround(w: *const World, kinds: *const Kinds, m: *Memory, k: u1, p: *const Entity, partner: ?*const Entity) void {
    if (m.seed == 0) m.seed = 0x9E3779B9 ^ w.tick;
    const was = m.goal;
    m.goal = goalOf(w, kinds, m, p, partner);
    const new = std.meta.activeTag(was) != std.meta.activeTag(m.goal) or switch (was) {
        .roam => false,
        inline else => |h, tag| !h.eql(@field(m.goal, @tagName(tag))),
    };
    if (new) {
        m.wait = @intCast(between(m, wait_ticks));
        m.kick = m.chance(kick_chance);
    }
    m.slack = @intCast(between(m, slack_px));
    m.reach = if (m.chance(grab_chance)) 0 else @intCast(between(m, reach_px));
    m.special = policeDue(w, kinds, k, p, partner) and m.chance(police_chance);
}

/// What it goes for: the best of what the screen shows, a little at random. A foe near comes
/// first (one on a player 1 in trouble before all, one player 1 fights after the others); then
/// what lies about (food when hurt, unless player 1 is more hurt and nearer; money, gold, a life,
/// a special attack); then a thing to break; else a place of its own, kept until it has stayed
/// there its while.
fn goalOf(w: *const World, kinds: *const Kinds, m: *Memory, p: *const Entity, partner: ?*const Entity) Goal {
    const left = w.camera.x.whole();
    const share = healthShare(kinds, p);
    var best: Goal = .{ .roam = roamSpot(w, m, p, partner) };
    var best_score: i32 = 30 + @as(i32, m.draw(16));
    for (&w.entities, 0..) |*e, i| {
        if (!e.alive() or e.flags.hidden) continue;
        const x = e.position.x.whole();
        if (x < left or x >= left + screen_width) continue;
        const h = w.handleAt(i) orelse continue;
        const far: i32 = @intCast(apart(p, e));
        const kind = kinds.get(e.kind.?);
        var goal: Goal = undefined;
        var score: i32 = undefined;
        if (isFoe(kinds, e)) {
            goal = .{ .foe = h };
            score = 120 - @divTrunc(far, 3);
            if (partner) |q| if (apart(q, e) < 56) {
                score += if (inTrouble(q)) 40 else -40;
            };
        } else if (kind.family() == .item and e.mind == .item and e.mind.item.state == .lying and e.holder == null) {
            goal = .{ .take = h };
            if (isFood(kind)) {
                if (share >= peckish) continue;
                if (partner) |q| if (q.health < p.health and apart(q, e) < apart(p, e)) continue;
                score = (if (share < starving) @as(i32, 140) else 80) - @divTrunc(far, 4);
            } else score = 75 - @divTrunc(far, 4);
            if (foesNear(w, kinds, e, 48) > 0) score -= 40;
        } else if (breakable(e)) {
            goal = .{ .smash = h };
            score = 50 - @divTrunc(far, 4);
        } else continue;
        if (std.meta.eql(goal, m.goal)) score += 20;
        score += m.draw(16);
        if (score > best_score) {
            best_score = score;
            best = goal;
        }
    }
    return best;
}

/// Its place, roaming: the one it goes to while it has not stayed there its while, nor got stuck,
/// and it is still on the screen and out of player 1's line; else a new one: across from player 1
/// (mostly ahead), out of its line on the CPU's side of it (now and then the other), within the
/// screen's margins; without player 1, ahead of itself.
fn roamSpot(w: *const World, m: *Memory, p: *const Entity, partner: ?*const Entity) Spot {
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
    var s: Spot = undefined;
    if (partner) |q| {
        const aside = between(m, aside_px);
        s = .{ .x = q.position.x.whole() + between(m, ahead_px), .depth = q.position.depth.whole() + if (m.above) -aside else aside };
    } else s = .{ .x = p.position.x.whole() + between(m, alone_ahead_px), .depth = p.position.depth.whole() + between(m, .{ -20, 20 }) };
    s.x = std.math.clamp(s.x, left + margin_left, left + screen_width - margin_right);
    return s;
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

/// Whether `p` stands free to act: ready, idle or walking.
fn ready(p: *const Entity) bool {
    return switch (p.mind.player.state) {
        .ready, .idle, .walk => true,
        else => false,
    };
}

/// A walk that did not move it: counted, until it moves.
fn noteStuck(m: *Memory, p: *const Entity) void {
    const here = spotHere(p);
    const walked = m.chose.up or m.chose.down or m.chose.left or m.chose.right;
    m.stuck = if (walked and std.meta.eql(here, m.stood)) m.stuck +| 1 else 0;
    m.stood = here;
    if (m.stuck == stuck_ticks) m.look = 0;
}

/// Holding `h`: player 1 (walked into after all), let go, away from it; a foe, its knees at its
/// pace, then the throw (away from it, and the blow).
fn hold(w: *const World, m: *Memory, k: u1, p: *const Entity, h: Handle) Actions {
    const away: Actions = if (p.facing == .left) .{ .right = true } else .{ .left = true };
    if (w.players[1 - k].entity) |q| if (q.eql(h)) return away;
    if (m.held == null or !m.held.?.eql(h)) {
        m.held = h;
        m.knees = @intCast(between(m, knees));
    }
    if (!strike(m)) return .{};
    if (m.knees > 0) {
        m.knees -= 1;
        return .{ .attack = true };
    }
    var throw = away;
    throw.attack = true;
    return throw;
}

/// Whether the CPU calls the police: with one left and none under way, swarmed (four foes about
/// it), or among three and hurt, or near its end among two; or player 1 near its end among two
/// foes with none of its own left.
fn policeDue(w: *const World, kinds: *const Kinds, k: u1, p: *const Entity, partner: ?*const Entity) bool {
    if (w.players[k].specials == 0 or w.special) return false;
    const share = healthShare(kinds, p);
    const near = foesNear(w, kinds, p, crowd_px);
    if (near >= 4 or (near >= 3 and share < hurt) or (near >= 2 and share < near_end)) return true;
    const q = partner orelse return false;
    return w.players[1 - k].specials == 0 and healthShare(kinds, q) < near_end and foesNear(w, kinds, q, crowd_px) >= 2;
}

/// The share of its full health `e` has left, in a hundred.
fn healthShare(kinds: *const Kinds, e: *const Entity) i32 {
    const full: i32 = kinds.get(e.kind.?).definition.health;
    return if (full == 0) 100 else @divTrunc(@as(i32, e.health) * 100, full);
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
/// player 1 is there), level with it; faced, and struck at its pace, but not while it is down;
/// from farther, in its line, now and then a jump kick in.
fn fightFoe(m: *Memory, p: *const Entity, f: *const Entity, partner: ?*const Entity) Actions {
    const px = p.position.x.whole();
    const fx = f.position.x.whole();
    const dx = fx - px;
    const dd = f.position.depth.whole() - p.position.depth.whole();
    // Its jump: on at it through the crouch and in the air, and the kick once near.
    switch (p.mind.player.state) {
        .jump_crouch, .jump => return .{ .left = dx < 0, .right = dx > 0, .attack = p.mind.player.state == .jump and @abs(dx) < reach_px[1] + 8 },
        else => {},
    }
    if (m.kick and ready(p) and @abs(dd) <= m.slack and @abs(dx) >= kick_from[0] and @abs(dx) <= kick_from[1] and (dx < 0) == (p.facing == .left)) {
        m.kick = false;
        return .{ .left = dx < 0, .right = dx > 0, .jump = true };
    }
    var side: i32 = if (dx > 0) -1 else 1;
    if (partner) |q| {
        const qx = q.position.x.whole();
        if ((qx - fx) * side > 0 and @abs(qx - fx) <= @as(i32, m.reach) + reach_room and @abs(q.position.depth.whole() - f.position.depth.whole()) <= line) side = -side;
    }
    const now = behaviours.stateName(&f.mind) orelse "";
    if (std.mem.eql(u8, now, "knocked_down")) {
        // Down: it waits at its reach, out of the way of its getting up.
        var a: Actions = .{};
        go(&a, fx + side * @as(i32, reach_px[1]) - px, dd, 6, m.slack);
        return a;
    }
    return strikeAt(m, p, f, @intCast(m.reach));
}

/// `f` struck: to `from` pixels across from it on the CPU's side (into it, at 0), level with
/// it; faced, and struck at its pace.
fn strikeAt(m: *Memory, p: *const Entity, f: *const Entity, from: u8) Actions {
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
    } else go(&a, f.position.x.whole() + side * @as(i32, from) - px, dd, 6, m.slack);
    if (@as(u8, @bitCast(a)) != 0) return a;
    if ((dx < 0) != (p.facing == .left)) return .{ .left = dx < 0, .right = dx >= 0 };
    return .{ .attack = strike(m) };
}

/// An item: to it, and picked up.
fn take(m: *Memory, p: *const Entity, f: *const Entity) Actions {
    var a: Actions = .{};
    go(&a, f.position.x.whole() - p.position.x.whole(), f.position.depth.whole() - p.position.depth.whole(), 12, 8);
    if (@as(u8, @bitCast(a)) != 0) return a;
    return .{ .attack = strike(m) };
}

/// The walk of `a`, its actions left out.
fn walkOf(a: Actions) Actions {
    return .{ .up = a.up, .down = a.down, .left = a.left, .right = a.right };
}

/// The actions `a`, their walk kept off player 1 `q`, whose body a walk's reach would grab. In
/// its line: very close, it does not walk; within a walk's reach facing it, it turns away;
/// else it steps out of the line rather than walk at it, as it does when player 1 walks at it.
/// Beside it, out of its line, it keeps out. Its blows stay.
fn keepOff(m: *const Memory, a: Actions, p: *const Entity, q: ?*const Entity) Actions {
    const other = q orelse return a;
    const dx = other.position.x.whole() - p.position.x.whole();
    const dd = other.position.depth.whole() - p.position.depth.whole();
    const ax = @abs(dx);
    var out = a;
    if (@abs(dd) > line) {
        if (ax <= reach_room and ((dd > 0 and a.down) or (dd < 0 and a.up))) {
            out.up = false;
            out.down = false;
        }
        return out;
    }
    const at_it = (dx > 0 and a.right) or (dx < 0 and a.left);
    const coming = other.mind.player.state == .walk and (other.facing == .left) == (dx > 0) and ax <= coming_room;
    if (ax > pass_room and !coming) return a;
    if (!at_it and !coming and !(ax <= reach_room and (a.up or a.down))) return a;
    out.up = false;
    out.down = false;
    out.left = false;
    out.right = false;
    if (ax <= body_room) return out;
    if (ax <= reach_room and (p.facing == .left) == (dx < 0)) {
        out.left = dx > 0;
        out.right = dx < 0;
        return out;
    }
    const up = if (dd != 0) dd > 0 else m.above;
    out.up = up;
    out.down = !up;
    if (!at_it) {
        out.left = a.left;
        out.right = a.right;
    }
    return out;
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
    const state = behaviours.stateName(&p.mind) orelse "";
    if (std.mem.startsWith(u8, state, "grab")) return .{ .b = jab };
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

/// A foe: an enemy or a boss out of hiding with health left, neither appearing nor knocked out.
fn isFoe(kinds: *const Kinds, e: *const Entity) bool {
    if (!e.alive() or e.flags.hidden) return false;
    const f = kinds.get(e.kind.?).family();
    if (f != .enemy and f != .boss) return false;
    if (e.health < 0) return false;
    const now = behaviours.stateName(&e.mind) orelse "";
    return !std.mem.eql(u8, now, "appear") and !std.mem.eql(u8, now, "knocked_out");
}

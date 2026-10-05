//! A player's lives (PLAN item 13), as the original counts them: a life is lost as the player
//! dies; when it has lain dead its time, its next life drops in where the camera is, or, its
//! lives out, it waits to continue (`player_waiting`, behaviours/player_waiting.zig), its name
//! entered first when its score enters the high-score table: YES spends a continue and gives it
//! the lives of a new game, its score cleared, and a new life.
//!
//! A new life (the original's start of a life, after a death): the player's entity is
//! its fighter again, its record cleared (it blinks from its first tick); it drops in at the
//! round's place for a life from the camera, its health full and one special attack; the timer
//! starts again; the enemies on the screen are knocked back.
const std = @import("std");
const tick_mod = @import("tick.zig");
const entity = @import("entity.zig");
const script = @import("script.zig");
const player = @import("behaviours/player.zig");

const Tick = tick_mod.Tick;
const Handle = entity.Handle;
const World = @import("world.zig").World;

/// The kind a player out of lives becomes.
pub const waiting_kind = "player_waiting";

/// Whether player `k` is in play, as the original counts its players in play (whom its enemies go
/// after): while it plays as a fighter; out of lives, at the tick its last life ended (its wait
/// has not begun) and at the tick its name is entered, not otherwise (nor after a NO).
pub fn inPlay(w: *const World, k: u1) bool {
    const e = w.getConst(w.players[k].entity orelse return false) orelse return false;
    return switch (e.mind) {
        .player => true,
        .player_waiting => |m| m.state == .begin and !m.answered_no,
        else => false,
    };
}

/// A life is lost: the player of `h` dies.
pub fn lose(t: *Tick, h: Handle) void {
    const k = t.world.playerOf(h) orelse return;
    const p = &t.world.players[k];
    if (p.lives != 0) p.lives -= 1;
}

/// The player of `h` has lain dead its time: its next life, or, its lives out, the wait to
/// continue. `h`'s behaviour changes: its hook returns at once.
pub fn lifeOver(t: *Tick, h: Handle) void {
    const k = t.world.playerOf(h) orelse return;
    if (t.world.players[k].lives != 0) return newLife(t, k);
    const kind = t.kinds.find(waiting_kind) orelse {
        std.log.warn("the content defines no {s}: player {d} is out of the game", .{ waiting_kind, @as(u8, k) + 1 });
        t.world.players[k].out = true;
        t.world.players[k].entity = null;
        t.world.remove(h);
        return;
    };
    // Its score is ranked against the high-score table: when it beats the last entry, the player
    // enters its name before the continue's question.
    var enters = false;
    if (t.plan) |plan| if (plan.last_score) |last| {
        enters = last.beatenBy(t.world.players[k].score);
        t.out.rankings.append(.{ .player = k });
    };
    t.world.morph(t.kinds, h, kind);
    switch (t.world.get(h).?.mind) {
        .player_waiting => |*m| m.entering = enters,
        else => {},
    }
    // The original clears its record: at the level's corner, which the camera's keeping the
    // players in view then moves (it stays hidden there), its mark of a shadow gone (it takes a
    // shadow again, drawn at its first tick: world/shadows.zig, draw_list.zig).
    const e = t.world.get(h).?;
    e.position = .zero;
    e.flags.has_shadow = false;
    // Its side faced cleared too: right.
    e.facing = .right;
    e.flags.hidden = true;
    e.flags.stays = true;
}

/// Player `k` answered YES to the continue: a continue spent, the lives of a new game, its score
/// cleared, and a new life.
pub fn continueGame(t: *Tick, k: u1) void {
    const p = &t.world.players[k];
    p.continues -|= 1;
    p.score = 0;
    p.extra_lives = 0;
    if (t.plan) |plan| p.lives = plan.lives;
    newLife(t, k);
}

/// Player `k` joins the game under way (the original's second player pressing START while
/// player 1 plays): its fighter, of `kind`, in its own place in the world (else the first free),
/// with `lives` (the one it plays counted), drawn with its definition's colour map `colours`
/// (none: its own colours), its first life dropping in as a new life does (the timer starts
/// again, the enemies on the screen are knocked back). False when the world has no room for it.
pub fn join(t: *Tick, k: u1, kind: entity.KindId, lives: u8, colours: ?u8) bool {
    const w = t.world;
    const h = w.spawnIn(t.kinds, kind, k, .zero, .right) catch w.spawn(t.kinds, kind, .zero, .right) catch return false;
    const p = &w.players[k];
    p.entity = h;
    p.character = kind;
    p.colours = colours;
    p.lives = lives;
    p.out = false;
    newLife(t, k);
    return true;
}

/// Player `k`'s next life drops in.
pub fn newLife(t: *Tick, k: u1) void {
    const w = t.world;
    const p = &w.players[k];
    const h = p.entity orelse return;
    const kind = p.character orelse return;
    w.morph(t.kinds, h, kind);
    const e = w.get(h).?;
    e.facing = .right;
    p.specials = 1;
    if (t.plan) |plan| {
        const r = plan.round;
        if (r.players.left) e.facing = .left;
        p.specials = r.players.specials;
        e.position = .{
            .x = w.camera.x.add(.pixels(r.players.x)),
            .depth = .pixels(r.players.depth[k]),
            .height = .pixels(r.players.height),
        };
        script.restartTimer(w, plan);
    }
    t.knockBack();
    if (t.actor(player, h)) |a| player.startLife(a);
    // It starts where it was put: it moves from the next tick.
    e.flags.still = true;
}

/// At the end of player `k`'s turn, as the original's: its score at the plan's next
/// `extra_lives` score gives it a life more, with its sound; one a turn (a score past two gives
/// the second at the next). True when it gave one.
pub fn extraLife(t: *Tick, k: u1) bool {
    const scores = (t.plan orelse return false).extra_lives;
    const p = &t.world.players[k];
    if (p.extra_lives >= scores.len or p.score < scores[p.extra_lives]) return false;
    p.extra_lives += 1;
    p.lives +|= 1;
    t.sound(extra_life_sound, p.entity);
    return true;
}

/// The sound of a life more.
pub const extra_life_sound = "extra life";

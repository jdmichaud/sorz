//! A player's lives (PLAN item 13), as the original counts them: a life is lost as the player
//! dies; when it has lain dead its time, its next life drops in where the camera is, or, its
//! lives out, it waits to continue (`player_waiting`, behaviours/player_waiting.zig): YES spends
//! a continue and gives it the lives of a new game, its score cleared, and a new life.
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

/// The kind a player out of lives becomes.
pub const waiting_kind = "player_waiting";

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
    t.world.morph(t.kinds, h, kind);
    // The original clears its record: at the level's corner, which the camera's keeping the
    // players in view then moves (it stays hidden there).
    // TODO(PLAN item 23, exact): the original draws its shadow object one display tick more, at
    // the floor's top, as its owner becomes the waiting player (two display ticks differ from
    // sor-remaster's pictures there); not reproduced.
    const e = t.world.get(h).?;
    e.position = .zero;
    e.flags.hidden = true;
    e.flags.stays = true;
}

/// Player `k` answered YES to the continue: a continue spent, the lives of a new game, its score
/// cleared, and a new life.
pub fn continueGame(t: *Tick, k: u1) void {
    const p = &t.world.players[k];
    p.continues -|= 1;
    p.score = 0;
    if (t.plan) |plan| p.lives = plan.lives;
    newLife(t, k);
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

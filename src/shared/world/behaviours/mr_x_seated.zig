//! Mr. X seated in his chair, at round 8's room's end, as the room's offer has him talk
//! (world/room.zig: the line it asks for, his line said). His first tick makes his lower part
//! (mr_x_seated_lower.zig) and his pipe (mr_x_pipe.zig) beside him, and seats him higher. Then:
//! - he waits for the offer's first line, gestures a while and says it (talking);
//! - he waits for his next line: the duel's (his pipe kicked away a while later, gesturing on to
//!   the duel's lines), the reward's (talking, then a stamp of his lower part, then his line
//!   said: the trapdoors), the refusal's (talking, then his pipe a weapon and a laugh);
//! - after the duel he says the duel's line and waits for the next: the reward's, or the
//!   traitor's, which ends as the refusal does;
//! - after his first laugh (the fight's first wave due), at the first wave's clear he laughs
//!   again (the second wave due), and at the room's last wave he stands up: his standing self
//!   (mr_x.zig) takes his place, and his lower part goes.
//! His talk, his gestures and his laughs are poses held a while; each ends in the state it was
//! for. The other program's traces number his states (`trace_states`). His numbers and poses are
//! his definition's (`entities/mr_x_seated.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");
const room = @import("../room.zig");
const lower_mod = @import("mr_x_seated_lower.zig");
const pipe_mod = @import("mr_x_pipe.zig");

const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum {
    start,
    waits_offer,
    offer_said,
    waits_line,
    refused,
    waits_clear,
    waits_last,
    duel,
    duel_said,
    waits_answer,
    stamp,
    stamping,
    gesture,
    gesturing,
    talk,
    talking,
    gesture_waits,
    gesturing_waits,
    laugh,
    laughing,
    laughed,
    kick,
    kicked,
    waits_traitor,
};

/// The other program's traces number his states, in the original's order.
pub const trace_states = blk: {
    const names = std.enums.values(State);
    var out: [names.len]struct { name: []const u8, state: State } = undefined;
    for (names, 0..) |s, k| out[k] = .{ .name = std.fmt.comptimePrint("s{d}", .{k}), .state = s };
    break :blk out;
};

pub const Mind = struct {
    state: State = .start,
    /// The state his pose ends in.
    then: State = .start,
    ticks: u16 = 0,
    /// The ticks to his stamp or his kick.
    due: u16 = 0,
    /// His lower part and his pipe.
    lower: ?Handle = null,
    pipe: ?Handle = null,
    /// The room's progress his next laugh marks (the original counts by twos: the first laugh,
    /// the second).
    laughs: u3 = 0,
};

pub const Animation = enum { talk, gesture, laugh };

pub const Numbers = struct {
    lower_x: i16,
    pipe_x: i16,
    pipe_depth: i16,
    raised: i16,
    talk_ticks: u16,
    gesture_ticks: u16,
    stamp_due: u16,
    kick_due: u16,
    kick_ticks: u16,
    stamp_ticks: u16,
    laugh_ticks: u16,
    laugh_more: u16,
};

pub const lower_kind = "mr_x_seated_lower";
pub const pipe_kind = "mr_x_pipe";
pub const standing_kind = "mr_x";

pub fn think(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const r = &a.tick.world.room;
    e.flags.still = true;
    switch (m.state) {
        .start => start(a),
        .waits_offer => if (heard(r)) {
            m.then = .offer_said;
            m.ticks = n.gesture_ticks;
            m.state = .gesture;
        },
        .offer_said => {
            r.talk_said = true;
            talk(a, .waits_line);
        },
        .waits_line => if (heard(r)) switch (r.talk) {
            1 => talk(a, .duel),
            2 => {
                m.due = n.stamp_due;
                talk(a, .stamp);
            },
            3 => {
                m.due = n.stamp_due;
                talk(a, .refused);
            },
            else => {},
        },
        .refused => {
            m.laughs = 0;
            if (pipeOf(a)) |p| p.mind.state = .weapon;
            laugh(a, .waits_clear);
        },
        .waits_clear => if (r.has(.cleared)) laugh(a, .waits_last),
        .waits_last => if (r.has(.stands)) standUp(a),
        .duel => {
            m.due = n.kick_due;
            m.state = .kick;
        },
        .duel_said => talk(a, .waits_answer),
        .waits_answer => if (heard(r)) {
            r.talk_asked = false;
            r.talk_said = false;
            if (r.talk == 2) {
                m.due = n.stamp_due;
                talk(a, .stamp);
            } else talk(a, .waits_traitor);
        },
        .stamp => {
            m.due -%= 1;
            if (m.due != 0) return;
            if (lowerOf(a)) |l| l.mind.stamp = true;
            m.ticks = n.stamp_ticks;
            m.state = .stamping;
        },
        .stamping => {
            m.ticks -%= 1;
            if (m.ticks == 0) r.talk_said = true;
        },
        .gesture => {
            a.animate(.gesture);
            a.pause(false);
            m.state = .gesturing;
        },
        .gesturing => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            a.animate(.talk);
            a.pause(true);
            m.state = m.then;
        },
        .talk => {
            a.animate(.talk);
            a.pause(false);
            m.state = .talking;
        },
        .talking => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            a.setFrame(0);
            a.pause(true);
            m.state = m.then;
        },
        .gesture_waits => {
            a.animate(.gesture);
            a.pause(false);
            m.state = .gesturing_waits;
        },
        .gesturing_waits => if (heard(r)) {
            a.setFrame(0);
            a.pause(true);
            m.state = m.then;
        },
        .laugh => {
            // His laugh's frames have no time of their own: he steps them himself.
            a.animate(.laugh);
            a.pause(true);
            m.ticks = n.laugh_ticks;
            m.state = .laughing;
        },
        .laughing => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            a.setFrame(a.frame() + 1);
            m.ticks = n.laugh_more;
            m.state = .laughed;
        },
        .laughed => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            a.animate(.talk);
            a.pause(true);
            r.progress |= @as(u8, 1) << m.laughs;
            m.laughs +%= 2;
            m.state = m.then;
        },
        .kick => {
            m.due -%= 1;
            if (m.due != 0) return;
            if (lowerOf(a)) |l| l.mind.state = .stomp;
            if (pipeOf(a)) |p| p.mind.kicked = true;
            m.ticks = n.kick_ticks;
            m.state = .kicked;
        },
        .kicked => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            r.talk_asked = false;
            m.then = .duel_said;
            m.state = .gesture_waits;
        },
        .waits_traitor => if (heard(r)) talk(a, .refused),
    }
}

/// Whether the offer asked for a new line: the ask is taken.
fn heard(r: *room.State) bool {
    defer r.talk_asked = false;
    return r.talk_asked;
}

/// He talks a while, then goes on to `then`.
fn talk(a: Actor, then: State) void {
    a.mind.ticks = a.numbers().talk_ticks;
    a.mind.then = then;
    a.mind.state = .talk;
}

/// He laughs, then goes on to `then`.
fn laugh(a: Actor, then: State) void {
    a.mind.then = then;
    a.mind.state = .laugh;
}

/// His first tick: talking still, no shadow; his lower part and his pipe beside him in the
/// enemies' first free places; seated higher.
fn start(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    a.animate(.talk);
    a.pause(true);
    const places = world_mod.World.enemy_places;
    const w = a.tick.world;
    if (a.tick.kinds.find(lower_kind)) |k| {
        var at = e.position;
        at.x = at.x.add(.pixels(n.lower_x));
        m.lower = w.spawnWithin(a.tick.kinds, k, places.from, places.to, at, .right) catch null;
    }
    if (a.tick.kinds.find(pipe_kind)) |k| {
        var at = e.position;
        at.x = at.x.add(.pixels(n.pipe_x));
        at.depth = at.depth.add(.pixels(n.pipe_depth));
        m.pipe = w.spawnWithin(a.tick.kinds, k, places.from, places.to, at, .right) catch null;
    }
    e.position.height = e.position.height.sub(.pixels(n.raised));
    m.state = .waits_offer;
}

/// He stands up: his standing self at his place (lower, on the ground), in the enemies' first
/// free place; his lower part and he go.
fn standUp(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    const w = a.tick.world;
    if (a.tick.kinds.find(standing_kind)) |k| {
        var at = e.position;
        at.height = at.height.add(.pixels(n.raised));
        const places = world_mod.World.enemy_places;
        _ = w.spawnWithin(a.tick.kinds, k, places.from, places.to, at, .left) catch {};
    }
    if (a.mind.lower) |l| if (w.get(l) != null) w.remove(l);
    a.remove();
}

/// Taken up from a situation past his first tick (the situation's place is his first): his lower
/// part and his pipe are the world's, his laughs the room's progress's, and he sits higher.
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    const m = a.mind;
    if (m.state == .start) return;
    const w = a.tick.world;
    for (&w.entities, 0..) |*e, i| {
        if (!e.alive()) continue;
        switch (e.mind) {
            .mr_x_seated_lower => m.lower = w.handleAt(i),
            .mr_x_pipe => m.pipe = w.handleAt(i),
            else => {},
        }
    }
    const r = &w.room;
    m.laughs = if (r.has(.second_laugh)) 4 else if (r.has(.first_laugh)) 2 else 0;
    a.entity.position.height = a.entity.position.height.sub(.pixels(a.numbers().raised));
}

fn lowerOf(a: Actor) ?tick.Actor(lower_mod) {
    return a.tick.actor(lower_mod, a.mind.lower orelse return null);
}

fn pipeOf(a: Actor) ?tick.Actor(pipe_mod) {
    return a.tick.actor(pipe_mod, a.mind.pipe orelse return null);
}

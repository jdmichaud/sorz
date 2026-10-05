//! A link of round 6's press's rod (press.zig), left behind as the press drops: it starts
//! `above` higher than the press was, without a shadow, and stays until the press has risen
//! back, or until the press rising comes within `reach` below it. Its press gone, it goes. Drawn
//! far enough left of the screen, it goes.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const entity = @import("../entity.zig");
const press = @import("press.zig");

const Actor = tick.Actor(@This());

/// Its kind's name, which the press finds.
pub const kind_name = "press_link";

pub const State = enum { start, hang };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .hang },
};

pub const Mind = struct {
    state: State = .start,
    /// Its press.
    press: ?entity.Handle = null,
};

pub const Animation = enum { link };

pub const Numbers = struct {
    /// How much higher than the press it starts; how near below it the press rising takes it.
    above: i16,
    reach: i16,
    /// It goes when its place across less the camera's plus `drawn_offset` is below
    /// `drawn_left`.
    drawn_left: i16,
    drawn_offset: i16,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    const n = a.numbers();
    e.flags.still = true;
    if (a.mind.state == .start) {
        e.position.height = .parts(@intCast(e.position.height.whole() - n.above), e.position.height.frac());
        a.animate(.link);
        a.mind.state = .hang;
    }
    const p = a.tick.actor(press, a.mind.press orelse return a.remove()) orelse return a.remove();
    if (press.risen(p)) return a.remove();
    if (press.rising(p) and e.position.height.whole() + n.reach >= p.entity.position.height.whole()) return a.remove();
    if (e.position.x.whole() - a.tick.world.camera.x.whole() + n.drawn_offset < n.drawn_left) a.remove();
}

/// Taken up from a situation in its state: its look; its press, the one where it is across.
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    if (a.mind.state != .hang) return;
    a.animate(.link);
    for (&a.tick.world.entities, 0..) |*o, i| {
        if (!o.alive() or o.mind != .press or !o.position.x.eql(a.entity.position.x)) continue;
        a.mind.press = a.tick.world.handleAt(i);
        return;
    }
}

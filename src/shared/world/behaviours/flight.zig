//! A flight across the screen (round 2's). Unseen, it waits for the camera's limit on the left,
//! plus the screen's width, to reach the next of its marks across the level; there a flight
//! passes (`World.flight`): it sends its first wave of fliers (flier.zig) from that place on,
//! past the screen's right edge, then two more `gap` ticks apart from where the camera's limit
//! is then, each flier in the first of the items' free places (none free: the wave's rest is not
//! sent). `tail` ticks after its last wave the flight is over, and it waits for its next mark;
//! past its last it goes. Each flight the round's script places goes through the marks from the
//! first, so that one placed after the camera passed some sends a flight after the other; the
//! world's flag is the last one's to start or end one.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const world_mod = @import("../world.zig");

const Actor = tick.Actor(@This());

pub const State = enum { start, wait, second, third, last, tail };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .wait },
    .{ .name = "s2", .state = .second },
    .{ .name = "s3", .state = .third },
    .{ .name = "s4", .state = .last },
    .{ .name = "s5", .state = .tail },
};

pub const Mind = struct {
    state: State = .start,
    /// The next of its marks.
    mark: u8 = 0,
    /// The ticks to its next wave, or to the flight's end.
    timer: u16 = 0,
};

pub const Numbers = struct {
    /// Added to the camera's limit on the left: the place a mark is passed at, and the waves'.
    screen_width: i16,
    /// The ticks between two waves, and from the last to the flight's end.
    gap: u16,
    tail: u16,
};

pub const Tables = struct {
    /// The places across the level a flight starts at, in turn.
    marks: [5]i32,
    /// A wave's fliers: each one's place, across from where the wave starts, in depth and in
    /// height; whether it is a small one.
    flier_x: [4]i16,
    flier_depth: [4]i16,
    flier_height: [4]i16,
    flier_small: [4]u1,
};

/// The kind of its fliers.
pub const flier_kind = "flier";

pub fn think(a: Actor) void {
    const e = a.entity;
    e.flags.still = true;
    const m = a.mind;
    switch (m.state) {
        .start => {
            e.flags.hidden = true;
            e.flags.stays = true;
            m.state = .wait;
        },
        .wait => {
            const t = a.tables();
            if (m.mark >= t.marks.len) return a.remove();
            const from = start(a);
            if (from < t.marks[m.mark]) return;
            m.mark += 1;
            a.tick.world.flight = true;
            send(a, from);
        },
        .second, .third => {
            m.timer -%= 1;
            if (m.timer == 0) send(a, start(a));
        },
        .last => {
            m.timer = a.numbers().tail;
            m.state = .tail;
        },
        .tail => {
            m.timer -%= 1;
            if (m.timer != 0) return;
            m.state = .wait;
            a.tick.world.flight = false;
        },
    }
}

/// Where a wave starts across: the camera's limit on the left plus the screen's width.
fn start(a: Actor) i32 {
    return a.tick.world.camera.x_min.whole() + a.numbers().screen_width;
}

/// The next state, the ticks to the next wave, and a wave's fliers from `from` across.
fn send(a: Actor, from: i32) void {
    const m = a.mind;
    m.state = switch (m.state) {
        .wait => .second,
        .second => .third,
        else => .last,
    };
    m.timer = a.numbers().gap;
    const t = a.tables();
    const kind = a.tick.kinds.find(flier_kind) orelse return;
    const places = world_mod.World.item_places;
    for (0..t.flier_x.len) |k| {
        const h = a.tick.world.spawnWithin(a.tick.kinds, kind, places.from, places.to, .{
            .x = .pixels(from + t.flier_x[k]),
            .depth = .pixels(t.flier_depth[k]),
            .height = .pixels(t.flier_height[k]),
        }, .right) catch return;
        a.tick.world.get(h).?.mind.flier.small = t.flier_small[k] != 0;
    }
}

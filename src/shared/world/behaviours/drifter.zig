//! A drifter (round 3's flotsam on the sea's edge). It lies at its height, drawn behind what
//! lies at its depth, and moves as its record says (`Spawn.drift`):
//! - `still`: it stays, its first frame held;
//! - `drifts`: it drifts away to the left at a speed of its `away` table (a draw's), animated;
//! - `stops`: it drifts left a draw's ticks (up to `drift_most`) at a speed of its `stops` table,
//!   animated, then stops `stop` ticks, and drifts again;
//! - `waves`: when the round's animation comes to its step `wave_step`, it rises at `rise`,
//!   slowed by `rise_slows` each tick, until its depth is above `top`; it waits `wait` ticks, then
//!   comes back at `back` until its depth is `bottom` or more, and waits for the waves again.
//! Left behind the camera, it goes.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { start, still, drifts, stops, waves, stopped, rising, waiting, back };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .still },
    .{ .name = "s2", .state = .drifts },
    .{ .name = "s3", .state = .stops },
    .{ .name = "s4", .state = .waves },
    .{ .name = "s5", .state = .stopped },
    .{ .name = "s6", .state = .rising },
    .{ .name = "s7", .state = .waiting },
    .{ .name = "s8", .state = .back },
};

pub const Mind = struct {
    state: State = .start,
    /// Its drift's speed is drawn (at its first tick drifting, again after each stop).
    drawn: bool = false,
    /// The ticks left of its drift, its stop or its wait.
    count: u8 = 0,
};

pub const Animation = enum { drift };

pub const Numbers = struct {
    height: i16,
    drift_most: u8,
    stop: u8,
    wave_step: u8,
    rise: Fixed,
    rise_slows: Fixed,
    top: i16,
    wait: u8,
    back: Fixed,
    bottom: i16,
    left_behind: i16,
};

pub const Tables = struct {
    /// Its speeds across, by a draw's low three bits: drifting away, drifting and stopping.
    away: [8]i32,
    stops: [8]i32,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    const m = a.mind;
    const n = a.numbers();
    e.flags.still = true;
    e.flags.behind = true;
    switch (m.state) {
        .start => {
            e.position.height = .parts(n.height, e.position.height.frac());
            a.animate(.drift);
            a.pause(true);
            m.state = switch (e.spawn.drift) {
                .still => .still,
                .drifts => .drifts,
                .stops => .stops,
                .waves => .waves,
            };
        },
        .still => {},
        .drifts => {
            if (!m.drawn) {
                m.drawn = true;
                e.velocity.x = .{ .raw = a.tables().away[a.draw(.drift) & 7] };
                a.pause(false);
            }
            e.position = e.position.add(e.velocity);
        },
        .stops => {
            if (!m.drawn) {
                m.drawn = true;
                const r = a.draw(.drift);
                m.count = @intCast(r & n.drift_most);
                e.velocity.x = .{ .raw = a.tables().stops[r & 7] };
                a.pause(false);
            }
            m.count -%= 1;
            if (m.count != 0) {
                e.position = e.position.add(e.velocity);
            } else {
                m.count = n.stop;
                m.state = .stopped;
                a.pause(true);
            }
        },
        .stopped => {
            m.count -%= 1;
            if (m.count == 0) {
                m.state = .stops;
                m.drawn = false;
            }
        },
        .waves => if (a.tick.world.script.animation.step == n.wave_step) {
            m.state = .rising;
            e.velocity.depth = n.rise;
            a.pause(false);
        },
        .rising => {
            e.velocity.depth = e.velocity.depth.add(n.rise_slows);
            e.position = e.position.add(e.velocity);
            if (e.position.depth.whole() < n.top) {
                m.state = .waiting;
                m.count = n.wait;
                a.pause(true);
            }
        },
        .waiting => {
            m.count -%= 1;
            if (m.count == 0) {
                m.state = .back;
                e.velocity.depth = n.back;
                a.pause(false);
            }
        },
        .back => {
            e.position = e.position.add(e.velocity);
            if (e.position.depth.whole() >= n.bottom) {
                m.state = .waves;
                a.pause(true);
            }
        },
    }
    const from_camera = e.position.x.whole() - a.tick.world.camera.x.whole();
    if (from_camera <= -n.left_behind) return a.remove();
}

/// Taken up from a situation in its state: its frames, moving or held.
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    a.animate(.drift);
    a.pause(switch (a.mind.state) {
        .drifts, .rising, .back => false,
        else => true,
    });
}

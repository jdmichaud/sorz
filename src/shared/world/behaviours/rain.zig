//! The rain (round 3's, on the beach). Hidden until the camera's limit behind, plus
//! `appears_within`, reaches its place across, it then shows fixed on the screen, animated, and
//! starts its `showers`: each makes `drops` raindrops (rain of their own) at their places on the
//! screen (`drop_x`, `drop_depth`, `drop_height`), in the items' places, else the last free one
//! below them, while one is free; `shower_ticks` ticks later, the next. All the while the sky
//! flashes: every `flash_ticks` + 1 ticks, the next of its `flash_steps` colours. After its last
//! shower it goes, the sky in its colours `after`. A raindrop falls at `drop_across` and
//! `drop_down` a tick until its height is `drop_end`, and goes. The special attack ends the rain
//! and its raindrops at once (the sky in its colours `after`).
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { start, shower, between, falling };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .shower },
    .{ .name = "s2", .state = .between },
    .{ .name = "s3", .state = .falling },
};

pub const Mind = struct {
    state: State = .start,
    /// A raindrop, which a shower made.
    drop: bool = false,
    showers: u8 = 0,
    /// The ticks to the next shower.
    ticks: u16 = 0,
};

/// None, then the drops.
pub const Animation = enum { rain };
pub const Colours = enum { flash_1, flash_2, flash_3, flash_4, flash_5, after };

pub const Numbers = struct {
    appears_within: i16,
    showers: u8,
    shower_ticks: u16,
    drops: u8,
    drop_across: Fixed,
    drop_down: Fixed,
    drop_end: i16,
    flash_ticks: i8,
    flash_steps: u8,
};

pub const Tables = struct {
    drop_x: [7]i32,
    drop_depth: [7]i32,
    drop_height: [7]i32,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    const m = a.mind;
    const n = a.numbers();
    const w = a.tick.world;
    e.flags.still = true;
    if (w.special) {
        a.showColours(.after);
        return a.remove();
    }
    switch (m.state) {
        .start => {
            e.flags.hidden = true;
            if (!m.drop and w.camera.x_min.whole() + n.appears_within < e.position.x.whole()) return;
            e.flags.hidden = false;
            e.flags.on_screen = true;
            e.flags.stays = true;
            a.animate(.rain);
            a.pause(false);
            if (m.drop) {
                e.velocity = .{ .x = n.drop_across, .height = n.drop_down };
                m.state = .falling;
            } else {
                w.sky = .{};
                m.showers = n.showers;
                m.state = .shower;
            }
        },
        .shower => {
            flash(a);
            const t = a.tables();
            for (0..@min(n.drops, t.drop_x.len)) |k| {
                const place: fixed.Vec3 = .{ .x = .pixels(@intCast(t.drop_x[k])), .depth = .pixels(@intCast(t.drop_depth[k])), .height = .pixels(@intCast(t.drop_height[k])) };
                const h = w.spawnItem(a.tick.kinds, e.kind.?, place) catch break;
                w.get(h).?.mind.rain.drop = true;
            }
            m.ticks = n.shower_ticks;
            m.state = .between;
        },
        .between => {
            flash(a);
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            m.showers -%= 1;
            if (m.showers == 0) {
                a.showColours(.after);
                return a.remove();
            }
            m.state = .shower;
        },
        .falling => {
            if (e.position.height.whole() >= n.drop_end) return a.remove();
            e.position = e.position.add(e.velocity);
        },
    }
}

/// The sky's flash: its ticks count down; below zero, the next step's colours.
fn flash(a: Actor) void {
    const n = a.numbers();
    const sky = &a.tick.world.sky;
    sky.ticks -%= 1;
    if (sky.ticks >= 0) return;
    sky.ticks = n.flash_ticks;
    sky.step += 1;
    if (sky.step >= n.flash_steps) sky.step = 0;
    a.showColours(@fromBackingInt(@intCast(sky.step)));
}

/// Taken up from a situation in its state: shown, animated.
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    if (a.mind.state == .start) return;
    a.entity.flags.on_screen = true;
    a.entity.flags.stays = true;
    a.animate(.rain);
    a.pause(false);
}

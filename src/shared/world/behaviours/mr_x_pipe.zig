//! Mr. X's pipe beside his chair (mr_x_seated.zig makes it): it lies, the second pipe's first
//! frame, until he kicks it away (it flies, bounces on the floor, and once slow lies there as
//! the second pipe, a weapon) or refuses the players (it is that weapon at once). Its numbers
//! and frame are its definition's (`entities/mr_x_pipe.json`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const world_mod = @import("../world.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { start, lies, flies, weapon };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .lies },
    .{ .name = "s2", .state = .flies },
    .{ .name = "s3", .state = .weapon },
};

pub const Mind = struct {
    state: State = .start,
    /// He kicked it.
    kicked: bool = false,
};

pub const Animation = enum { lie };

pub const Numbers = struct {
    kick_x: Fixed,
    kick_depth: Fixed,
    kick_up: Fixed,
    gravity: Fixed,
    bounce_above: Fixed,
};

/// The weapon it becomes.
pub const weapon_kind = "pipe_b";

pub fn think(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    e.flags.still = true;
    switch (m.state) {
        .start => {
            a.animate(.lie);
            a.pause(true);
            m.state = .lies;
        },
        .lies => if (m.kicked) {
            e.velocity = .{ .x = n.kick_x, .depth = n.kick_depth, .height = n.kick_up };
            m.state = .flies;
            e.position = e.position.add(e.velocity);
        },
        .flies => {
            const floor = a.tick.floorUnder(e.position);
            if (floor == null or e.position.height.lessThan(floor.?)) {
                e.velocity.height = e.velocity.height.add(n.gravity);
                e.position = e.position.add(e.velocity);
                return;
            }
            e.position.height = .pixels(floor.?.whole());
            if (n.bounce_above.lessThan(e.velocity.height)) {
                e.velocity.height = e.velocity.height.shr(1).neg();
                e.position = e.position.add(e.velocity);
                return;
            }
            becomeWeapon(a);
        },
        .weapon => becomeWeapon(a),
    }
}

/// It lies as the second pipe, a weapon in the weapons' first free place, and goes.
fn becomeWeapon(a: Actor) void {
    const w = a.tick.world;
    if (a.tick.kinds.find(weapon_kind)) |k| {
        const places = world_mod.World.weapon_places;
        _ = w.spawnWithin(a.tick.kinds, k, places.from, places.to, a.entity.position, .right) catch {};
    }
    a.remove();
}

//! A splinter of the bat (bat.zig lets them off): from its next tick it falls, its definition's
//! gravity added to its speed before it moves, and goes when it falls through the ground (the
//! original's: on a cell of the round's floor with an attribute under it) or when its drawn place
//! leaves the screen (`gone_*`: past its sides, below or above, as the original's drawing deletes
//! it). Its numbers and its animation are its definition's (`entities/bat_splinter.json`).
//! TODO(PLAN item 15): the floor's cells, for the round's ground.
const tick = @import("../tick.zig");

const Actor = tick.Actor(@This());

pub const State = enum { start, falling };

pub const Mind = struct {
    state: State = .start,
};

pub const Animation = enum { falling };

pub const Numbers = struct {
    gone_right: i16,
    gone_below: i16,
    gone_above: i16,
    gone_left: i16,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    e.flags.still = true;
    switch (a.mind.state) {
        .start => {
            a.animate(.falling);
            a.mind.state = .falling;
        },
        .falling => {
            e.velocity.height = e.velocity.height.add(.of(a.kind.definition.gravity));
            e.position = e.position.add(e.velocity);
            if (!e.position.height.lessThan(a.tick.world.ground)) return a.remove();
        },
    }
    // The drawing's place on the screen (its height up, half its depth down).
    const n = a.numbers();
    const c = a.tick.world.camera;
    const sx = e.position.x.whole() - c.x.whole();
    const sy = (e.position.depth.whole() >> 1) + e.position.height.whole() - c.y.whole();
    if (sx >= n.gone_right or sx < n.gone_left or sy >= n.gone_below or sy < n.gone_above) a.remove();
}

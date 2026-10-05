//! Player 2's special attack's shot (special_knockdown.zig brings it when the camera is back):
//! its fire, unseen, waits a while (`waiting`), then lets a bullet fall every other tick over
//! the screen, from places it takes in turn, until its count; then the special attack ends a
//! while after (`ending`). A bullet falls, faster and faster, drifting across (`falling`); landed,
//! it bursts (`impact`) and goes: the first shakes the screen, every one lets the enemies be
//! knocked down. The fire keeps its place on the screen as the camera moves; bullets take the
//! special attack's places (police_car.zig), the first free, and none falls when none is. Its
//! numbers, animations and sounds are its definition's (`entities/special_fire.json`).
//! Not measured: the recorded play has no second player's special attack.
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const police_car = @import("police_car.zig");
const special_knockdown = @import("special_knockdown.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { start, waiting, ending, falling, impact };

pub const Mind = struct {
    state: State = .start,
    /// A bullet (else the fire itself).
    bullet: bool = false,
    timer: u16 = 0,
    /// The bullets let fall.
    count: u8 = 0,
};

pub const Animation = enum { falling, impact };
pub const Sound = enum { fire };

pub const Tables = struct {
    /// The bullets' places, in turn: across from the camera's place (less `behind`), in depth.
    across: [16]i16,
    depth: [16]i16,
};

pub const Numbers = struct {
    /// The fire: unseen `hidden` ticks, then a bullet every `every` ticks, `bullets` in all; the
    /// special attack ends `last_wait` ticks after the last.
    hidden: u16,
    every: u16,
    bullets: u8,
    last_wait: u16,
    behind: i16,
    /// A bullet's speeds across and down at first, its gravity; its impact's last frame; the
    /// first impact shakes the screen `shake` ticks.
    drift: Fixed,
    fall: Fixed,
    gravity: Fixed,
    impact_ends: u8,
    shake: u8,
};

pub fn think(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    e.flags.still = true;
    const c = &a.tick.world.camera;
    e.position.x = e.position.x.add(c.x.sub(c.prev_x));
    switch (m.state) {
        .start => if (m.bullet) {
            m.state = .falling;
            a.animate(.falling);
        } else {
            e.flags.hidden = true;
            a.sound(.fire);
            m.timer = n.hidden;
            m.state = .waiting;
            a.animate(.falling);
        },
        .waiting => {
            m.timer -= 1;
            if (m.timer != 0) return;
            m.timer = n.every;
            const t = a.tables();
            const k = m.count & 15;
            const at: fixed.Vec3 = .{ .x = .pixels(c.x.whole() + t.across[k] - n.behind), .depth = .pixels(t.depth[k]), .height = .zero };
            const h = a.tick.world.spawnWithin(a.tick.kinds, e.kind.?, police_car.places.from, police_car.places.to, at, .right) catch return;
            if (a.tick.actor(@This(), h)) |b| {
                b.mind.* = .{ .bullet = true };
                b.entity.velocity = .{ .x = .parts(@intCast(n.drift.whole()), 0), .height = .parts(@intCast(n.fall.whole()), 0) };
            }
            m.count += 1;
            if (m.count < n.bullets) return;
            m.state = .ending;
            m.timer = n.last_wait;
        },
        .ending => {
            m.timer -= 1;
            if (m.timer != 0) return;
            a.tick.world.special = false;
            a.remove();
        },
        .falling => {
            e.velocity.height = e.velocity.height.add(n.gravity);
            e.position = e.position.add(e.velocity);
            if (e.position.height.lessThan(a.tick.world.ground)) return;
            if (special_knockdown.of(a.tick)) |k| {
                if (!k.mind.shook) {
                    k.mind.shook = true;
                    c.shake = n.shake;
                }
                k.mind.rest = true;
            }
            m.state = .impact;
            a.animate(.impact);
        },
        .impact => if (a.frame() == n.impact_ends) a.remove(),
    }
}

//! Player 1's special attack's shot (special_knockdown.zig brings it when the camera is back):
//! - the rocket: unseen a while ahead of the screen's left, high up; then it falls, drifting
//!   across, and lands (`hidden`, `falling`);
//! - landed, a moment later it explodes (`lit`), and sets off a ring of explosions: two arms out
//!   from it, each explosion a moment after its parent, along the ground, then curving up the
//!   screen and back toward each other, fifteen generations long;
//! - each explosion grows and shrinks (`blasting`); at its largest it draws the special attack's
//!   line in depth a little above itself, along which the enemies are knocked down; the eleventh
//!   generation's knocks the rest down; the last generation's end the special attack a while after
//!   (`last`).
//! The shot keeps its place on the screen as the camera moves. Explosions take the special
//! attack's places (police_car.zig), the first free; one that finds none tries again a tick
//! later. Its numbers, animations and sounds are its definition's (`entities/special_blast.json`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const police_car = @import("police_car.zig");
const special_knockdown = @import("special_knockdown.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { start, hidden, falling, lit, blasting, last };

pub const Mind = struct {
    state: State = .start,
    /// Its generation (0 the rocket), its arm (−1 left, 1 right; 0 the rocket's two).
    generation: u8 = 0,
    arm: i2 = 0,
    timer: u16 = 0,
    /// Its size's place in the sizes, and the ticks to the next.
    size: u8 = 0,
    size_ticks: u8 = 0,
};

pub const Animation = enum { rocket, blast_1, blast_2, blast_3, blast_4, blast_5 };
pub const Sound = enum { launch, explosion };

pub const Tables = struct {
    /// The sizes it shows, a size every `size_ticks` (0 ends them).
    sizes: [12]u8,
    /// A generation's step from its parent, across (the left arm's the other way) and in depth.
    ring_across: [16]i8,
    ring_depth: [16]i8,
};

pub const Numbers = struct {
    /// The rocket: unseen `hidden` ticks, `ahead` of the camera's place, at `depth` and `height`;
    /// it falls at `fall`, drifting at `drift`; landed, it explodes after `fuse` ticks.
    hidden: u16,
    ahead: i16,
    depth: i16,
    height: i16,
    fall: Fixed,
    drift: Fixed,
    fuse: u16,
    /// An explosion explodes `ring_fuse` ticks after it is set off; its sizes show `size_ticks`
    /// each; `generations` the last.
    ring_fuse: u16,
    size_ticks: u8,
    generations: u8,
    /// At its largest: the line `line_above` above it; the `rest_generation`'s knock the rest
    /// down; the last generation's wait `last_wait` ticks unseen, then the special attack ends.
    line_above: i16,
    rest_generation: u8,
    last_wait: u16,
};

pub fn think(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    e.flags.still = true;
    // It keeps its place on the screen.
    const c = a.tick.world.camera;
    e.position.x = e.position.x.add(c.x.sub(c.prev_x));
    switch (m.state) {
        .start => if (m.arm == 0) {
            e.flags.hidden = true;
            e.position.x = e.position.x.add(.pixels(n.ahead));
            e.position.depth = .parts(n.depth, e.position.depth.frac());
            e.position.height = .parts(n.height, e.position.height.frac());
            m.state = .hidden;
            m.timer = n.hidden;
            a.animate(.rocket);
            a.sound(.launch);
        } else {
            m.timer = n.ring_fuse;
            m.state = .lit;
            a.animate(.blast_1);
        },
        .hidden => {
            m.timer -= 1;
            if (m.timer != 0) return;
            e.flags.hidden = false;
            m.state = .falling;
            e.velocity.height = .parts(@intCast(n.fall.whole()), e.velocity.height.frac());
            e.velocity.x = .parts(@intCast(n.drift.whole()), e.velocity.x.frac());
        },
        .falling => {
            e.position = e.position.add(e.velocity);
            const ground = a.tick.world.ground;
            if (e.position.height.lessThan(ground)) return;
            e.position.height = .parts(@intCast(ground.whole()), e.position.height.frac());
            m.state = .lit;
            m.timer = n.fuse;
            a.animate(.blast_1);
        },
        .lit => lit(a),
        .blasting => blasting(a),
        .last => {
            m.timer -= 1;
            if (m.timer != 0) return;
            a.tick.world.special = false;
            a.remove();
        },
    }
}

/// Lit: it explodes (the rocket with its sound) and sets off its next generation (the rocket two
/// arms); a generation finding no place tries again at the next tick.
fn lit(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.timer -= 1;
    if (m.timer != 0) return;
    // The first explosion sounds, once.
    if (special_knockdown.of(a.tick)) |k| if (!k.mind.exploded) {
        k.mind.exploded = true;
        a.sound(.explosion);
    };
    m.state = .blasting;
    m.size_ticks = 1;
    m.size = 0;
    if (m.generation >= n.generations) return;
    if (m.arm != 0) return setOff(a, m.arm);
    setOff(a, 1);
    setOff(a, -1);
}

/// Its next generation on arm `arm`, a step from it.
fn setOff(a: Actor, arm: i2) void {
    const m = a.mind;
    const t = a.tables();
    const next = m.generation + 1;
    const at = a.entity.position;
    const place: fixed.Vec3 = .{
        .x = .pixels(at.x.whole() + @as(i32, t.ring_across[next]) * @as(i32, arm)),
        .depth = .pixels(at.depth.whole() + t.ring_depth[next]),
        .height = .pixels(at.height.whole()),
    };
    const h = a.tick.world.spawnWithin(a.tick.kinds, a.entity.kind.?, police_car.places.from, police_car.places.to, place, .right) catch {
        // No place: it lights again at the next tick.
        m.state = .lit;
        m.timer = 1;
        return;
    };
    if (a.tick.actor(@This(), h)) |child| child.mind.* = .{ .generation = next, .arm = arm };
}

/// It grows and shrinks, a size every few ticks; at its largest it draws the line (the eleventh
/// generation's, the rest's knock-down); its sizes done, it goes (the last generation's waits,
/// unseen, and ends the special attack).
fn blasting(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const t = a.tables();
    m.size_ticks -= 1;
    if (m.size_ticks != 0) return;
    m.size_ticks = n.size_ticks;
    const size = t.sizes[m.size];
    if (size == 0) {
        if (m.generation < n.generations) return a.remove();
        a.entity.flags.hidden = true;
        m.timer = n.last_wait;
        m.state = .last;
        return;
    }
    const frame = a.frame();
    a.animate(@fromBackingInt(@intCast(size)));
    a.setFrame(frame);
    if (size == 5) if (special_knockdown.of(a.tick)) |k| {
        k.mind.line = @intCast(a.entity.position.depth.whole() - n.line_above);
        if (m.generation == n.rest_generation) k.mind.rest = true;
    };
    m.size += 1;
}

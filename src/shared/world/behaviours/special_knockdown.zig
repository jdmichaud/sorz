//! The special attack's own, never drawn: made at the call (`Tick.callSpecial`), it sends the
//! camera running back across the round; once the camera has run back far enough the police car
//! comes (police_car.zig, whose bazooka's smoke, or gunfire, sends the camera running ahead);
//! as it runs ahead, the colours are copied at every tick the round's art is loaded, and within
//! `again_within` of its place at the call the enemies' art the car took the place of streams in
//! again (the section's `again`); back where it was, the shot comes: player 1's rocket
//! (special_blast.zig), player 2's fire (special_fire.zig). Then it knocks the enemies down (each a fall without the knock-down's
//! damage: their health went at the call):
//! - player 1's: as the blast's line (the depth of its latest explosion at its largest, less a
//!   little) comes up the screen, every enemy below it, but one already falling or lying (in its
//!   knock-down's pose); when the blast's last explosions have grown, the rest (but those falling
//!   short of the frame its pose stays on), and it goes;
//! - player 2's: from the first bullet's impact a while on, one enemy at a time, in their places'
//!   order, whatever its state or depth (even after the special attack's end), and it goes when
//!   none is left.
//! Its numbers are its definition's (`entities/special_knockdown.json`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");
const police_car = @import("police_car.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { running };

pub const Mind = struct {
    state: State = .running,
    /// The one who called it, and whether that is the second player.
    by: ?Handle = null,
    second: bool = false,
    /// The camera's place at the call; the car came; its art gave way to the enemies' again;
    /// the shot came.
    from: Fixed = .zero,
    car: bool = false,
    again: bool = false,
    shot: bool = false,
    /// The blast's line in depth (none yet); the rest are to be knocked down; the first bullet's
    /// impact shook the screen.
    line: ?i16 = null,
    rest: bool = false,
    shook: bool = false,
    /// The blast's first explosion was heard.
    exploded: bool = false,
    /// Player 2's: the count to its next knock-down, and the next place it looks from.
    count: i8 = 0,
    next: u8 = 0,
    counting: bool = false,
};

pub const Numbers = struct {
    /// The camera's run: its speed (back, then ahead), how far back it runs at most; the car
    /// comes when it has run back `comes`, at `arrives` across from its place at the call.
    run: Fixed,
    run_most: Fixed,
    comes: Fixed,
    arrives: i16,
    /// Player 2's: the ticks to its first knock-down after the first impact, then `second_every`
    /// and one more between each.
    second_first: i8,
    second_every: i8,
    /// The last pass spares one in its knock-down's pose but at this frame.
    rest_frame: u8,
    /// The camera running ahead this close to its place at the call, the enemies' art comes
    /// again.
    again_within: i16,
};

/// The kinds it brings.
pub const car_kind = "police_car";
pub const blast_kind = "special_blast";
pub const fire_kind = "special_fire";

/// Called: the camera runs back from where it is, as far as its run goes but not past the
/// round's start.
pub fn specialCalled(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const w = a.tick.world;
    const c = &w.camera;
    m.by = w.special_by;
    m.second = if (w.special_by) |by| if (w.players[1].entity) |p| p.eql(by) else false else false;
    m.from = c.x;
    c.run = .{ .from = c.x, .speed = n.run, .limit = c.x.sub(n.run_most).max(.zero) };
    // A rocking camera is put back level, its rocking from its start.
    if (c.follows) |rules| if (rules.wobble) |wb| {
        c.y = .zero;
        c.wobble = .fresh(wb);
    };
    a.entity.flags.hidden = true;
    // The colours shown are kept, the police car's to lie over them.
    a.tick.out.colour_loads.append(.keep);
}

pub fn think(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const w = a.tick.world;
    const c = &w.camera;
    a.entity.flags.hidden = true;
    a.entity.flags.still = true;
    // The camera has run back far enough: the car comes, at the left, unseen until its art is in.
    if (!m.car) if (c.run) |r| if (r.state == .back and c.x.whole() <= m.from.whole() - n.comes.whole()) {
        m.car = true;
        if (spawn(a, car_kind, .{ .x = .pixels(m.from.whole() + n.arrives), .depth = .zero, .height = .zero })) |h| {
            if (a.tick.actor(police_car, h)) |car| {
                const cn = car.numbers();
                car.entity.position.depth = .pixels(cn.depth);
                car.entity.position.height = .pixels(cn.height);
                police_car.arrive(car, m.second);
            }
        }
    };
    // Running ahead, the car there, the round's art loaded: the colours copied; close enough,
    // the enemies' art again.
    if (m.car and !m.again) if (c.run) |r| if (r.state == .ahead) {
        const loading = if (a.tick.plan) |p| p.art_loading[0] else false;
        if (!loading) {
            a.tick.out.colours = true;
            if (c.x.whole() >= m.from.whole() - n.again_within) {
                m.again = true;
                a.tick.out.colour_loads.append(.back);
                a.tick.out.streamed = .{ .part = w.script.part, .again = true };
            }
        }
    };
    // Back where it was: the shot.
    if (m.car and !m.shot and c.run == null) {
        m.shot = true;
        _ = spawn(a, if (m.second) fire_kind else blast_kind, .{ .x = c.x, .depth = .zero, .height = .zero });
    }
    if (m.second) return knockSecond(a);
    const line = m.line orelse return;
    const first = world_mod.World.enemy_places;
    for (first.from..first.to) |i| {
        const h = w.handleAt(i) orelse continue;
        if (w.get(h).?.flags.hidden) continue;
        _ = a.tick.specialKnockDown(h, m.by, if (m.rest) .{ .rest = n.rest_frame } else .{ .line = line });
    }
    if (m.rest) a.remove();
}

/// Player 2's: a count from the first impact; then an enemy at a time, the next in the places'
/// order not hidden, whatever it is doing; none left, it goes.
fn knockSecond(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const w = a.tick.world;
    if (!m.counting) {
        m.counting = true;
        m.next = @intCast(world_mod.World.enemy_places.from);
        m.count = n.second_first;
    }
    if (!m.rest) return;
    m.count -= 1;
    if (m.count >= 0) return;
    m.count = n.second_every;
    var i: usize = m.next;
    while (i < world_mod.World.enemy_places.to) : (i += 1) {
        const h = w.handleAt(i) orelse continue;
        if (w.get(h).?.flags.hidden) continue;
        if (!a.tick.specialKnockDown(h, m.by, .any)) continue;
        m.next = @intCast(i + 1);
        return;
    }
    a.remove();
}

/// A thing of the special attack in the first free of its places, from the lowest; it acts
/// from this tick.
fn spawn(a: Actor, name: []const u8, at: fixed.Vec3) ?Handle {
    const kind = a.tick.kinds.find(name) orelse return null;
    return a.tick.world.spawnWithin(a.tick.kinds, kind, police_car.places.from, police_car.places.to, at, .right) catch null;
}

/// Its places: the weapons' and on, the first free (the original's own range of them).
pub const places: struct { from: usize, to: usize } = .{ .from = 34, .to = 58 };

/// The special attack's own, found: player 1's blast sets its line, both the rest's knock-down.
pub fn of(t: *tick.Tick) ?Actor {
    for (places.from..places.to) |i| {
        const h = t.world.handleAt(i) orelse continue;
        if (t.actor(@This(), h)) |o| return o;
    }
    return null;
}

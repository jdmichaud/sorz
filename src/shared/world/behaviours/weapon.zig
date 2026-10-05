//! A weapon a player or an enemy fights with, the pipes (the knife, which can also be thrown, is
//! knife.zig's, on the same body). It lies on the ground (`lying`) until it is taken: then it is
//! in its holder's hand (`held`), where the holder's frame says (`Frame.hand`: from the holder's
//! place, in front of it in depth or behind, the weapon's pose), and unseen in the holder's frames
//! without a hand. Dropped, it falls (`falling`) and lies again; worn out by its pick-ups, it
//! blinks out (`blinking_out`) and goes. Its numbers and its poses (its animations) are its
//! definition's (`entities/pipe.json`, `pipe_b.json`).
//!
//! It is taken up by `Tick.arm` (an armed Galsia's own) or a pick-up; its holder drops it with
//! `Tick.dropWeapon`. It places itself in its holder's hand when its holder has moved (`follow`,
//! the movement system), as the original's weapons follow at their turn after their holder's.
//! In a player's hand it is at the player's depth, and in a frame without a hand it stays where
//! it was last seen; its blow is its own: at each tick of a frame whose hand strikes it joins the
//! things whose blows land (a thing thrown, its power its damage), and leaves them a tick at a
//! time after.
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { start, lying, falling, held, blinking_out };

pub const Mind = struct {
    state: State = .start,
    body: Body = .{},
};

pub const Numbers = struct {
    /// The damage its blow does.
    power: u8,
    /// The pick-ups it lasts; then it blinks out, for `blink` ticks.
    uses: u8,
    blink: u8,
    /// Dropped, its speed down at first (its definition's gravity adds to it each tick).
    drop: Fixed,
    /// Out of a hand, it goes this far behind the camera's place across.
    left_behind: i16,
};

/// A weapon's memory (a knife's too).
pub const Body = struct {
    /// The times it was taken up.
    taken: u8 = 0,
    /// Its holder dropped it.
    dropped: bool = false,
    /// The ticks left of its blinking out.
    blink: u8 = 0,
    /// In a player's hand: the ticks its blow has struck, which it leaves a tick at a time.
    strikes: u8 = 0,
};

pub fn think(a: Actor) void {
    const C = Of(@This());
    if (C.act(a)) _ = C.leftBehind(a);
}

pub fn follow(a: Actor) void {
    Of(@This()).follow(a);
}

pub fn dropped(a: Actor) void {
    Of(@This()).dropped(a);
}

pub fn putDown(a: Actor) void {
    Of(@This()).putDown(a);
}

pub fn pickedUp(a: Actor, by: Handle) bool {
    return Of(@This()).pickedUp(a, by);
}

pub fn takeable(a: Actor) bool {
    return Of(@This()).takeable(a);
}

pub fn takeUp(a: Actor, elapsed: u32) void {
    Of(@This()).takeUp(a, elapsed);
}

pub fn takeUpTaken(a: Actor, times: u8) void {
    a.mind.body.taken = times;
}

/// The states every weapon shares, for module `M` (a `Mind` with `state` and `body`, its
/// `Numbers` at least the weapon's).
pub fn Of(comptime M: type) type {
    return struct {
        const A = tick.Actor(M);

        /// A tick of the states it shares: false when its state is the module's own.
        pub fn act(a: A) bool {
            a.entity.flags.still = true;
            const s = a.mind.state;
            if (s == .start) {
                pose(a, "lying");
                a.mind.state = .lying;
            } else if (s == .lying) {
                lying(a);
            } else if (s == .falling) {
                falling(a);
            } else if (s == .held) {
                held(a);
            } else if (s == .blinking_out) {
                a.mind.body.blink -%= 1;
                if (a.mind.body.blink == 0) a.remove();
            } else return false;
            return true;
        }

        /// Out of a hand (none holds it) and left behind the camera, it goes: whether it went.
        pub fn leftBehind(a: A) bool {
            if (a.entity.holder != null or !a.entity.alive()) return false;
            const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
            if (from_camera > -a.numbers().left_behind) return false;
            a.remove();
            return true;
        }

        /// Lying: worn out, it blinks out; taken, it is held (counted).
        fn lying(a: A) void {
            const n = a.numbers();
            const b = &a.mind.body;
            if (b.taken >= n.uses) {
                pose(a, "blinking");
                b.blink = n.blink;
                a.mind.state = .blinking_out;
                return;
            }
            if (a.entity.holder == null) return;
            b.taken += 1;
            a.mind.state = .held;
        }

        /// Held: dropped, it shows and falls.
        fn held(a: A) void {
            const b = &a.mind.body;
            if (!b.dropped) return;
            b.dropped = false;
            b.strikes = 0;
            a.entity.missile = null;
            a.entity.flags.hidden = false;
            a.entity.velocity.height = a.numbers().drop;
            a.mind.state = .falling;
        }

        /// It falls, faster each tick: once at or under the ground, it lies there (the fraction
        /// of its height kept), still.
        fn falling(a: A) void {
            const e = a.entity;
            e.velocity.height = e.velocity.height.add(.of(a.kind.definition.gravity));
            const ground = a.tick.world.ground.whole();
            if (e.position.height.whole() < ground) {
                e.position = e.position.add(e.velocity);
                return;
            }
            e.position.height = .parts(@intCast(ground), e.position.height.frac());
            e.velocity = .zero;
            pose(a, "lying");
            a.mind.state = .lying;
        }

        /// Its holder dropped it.
        pub fn dropped(a: A) void {
            a.mind.body.dropped = true;
            a.entity.holder = null;
        }

        /// Its holder took another: it lies where it is, on its holder's ground, as it showed;
        /// it may be taken again.
        pub fn putDown(a: A) void {
            const e = a.entity;
            if (e.holder) |h| if (a.other(h)) |holder| {
                e.position.height = holder.position.height;
            };
            e.holder = null;
            e.missile = null;
            a.mind.body.strikes = 0;
            a.mind.state = .lying;
        }

        /// Picked up: in its taker's hand (counted at its next tick).
        pub fn pickedUp(a: A, by: Handle) bool {
            a.entity.holder = by;
            return true;
        }

        /// Whether it may be taken: out of a hand, not worn out.
        pub fn takeable(a: A) bool {
            const s = a.mind.state;
            if (s != .lying and s != .falling and s != .start) return false;
            return a.mind.body.taken < a.numbers().uses;
        }

        /// Held, at its holder's hand: from its holder's place (whole pixels, its own fractions
        /// kept), in front of it in depth or behind, facing its way, in the frame's pose; in a
        /// frame without a hand, unseen at its holder's place.
        pub fn follow(a: A) void {
            if (a.mind.state != .held) return;
            const hh = a.entity.holder orelse return;
            const holder = a.other(hh) orelse return;
            const e = a.entity;
            const by_player = a.tick.kindOf(holder).family() == .player;
            const f = a.tick.frameOf(holder);
            const hand = if (f) |x| x.hand else null;
            const at = holder.position;
            const h = hand orelse {
                e.flags.hidden = true;
                if (by_player) return strike(a, hh, false);
                e.position = .{
                    .x = .parts(@intCast(at.x.whole()), e.position.x.frac()),
                    .depth = .parts(@intCast(at.depth.whole()), e.position.depth.frac()),
                    .height = .parts(@intCast(at.height.whole()), e.position.height.frac()),
                };
                return;
            };
            e.flags.hidden = false;
            const depth: i32 = if (by_player) 0 else if (h.front) 1 else -1;
            e.position = .{
                .x = .parts(@intCast(at.x.whole() + h.x * holder.facing.sign()), e.position.x.frac()),
                .depth = .parts(@intCast(at.depth.whole() + depth), e.position.depth.frac()),
                .height = .parts(@intCast(at.height.whole() + h.height), e.position.height.frac()),
            };
            e.facing = if (h.turned) holder.facing.turned() else holder.facing;
            pose(a, h.pose);
            if (by_player) strike(a, hh, h.strikes);
        }

        /// In a player's hand: a tick its blow strikes, it joins the things whose blows land
        /// (once more; the original's list of them holds five); another, it leaves them once.
        fn strike(a: A, holder: Handle, strikes: bool) void {
            const b = &a.mind.body;
            if (strikes) {
                b.strikes = @min(b.strikes + 1, 5);
            } else if (b.strikes != 0) b.strikes -= 1;
            a.entity.missile = if (b.strikes != 0) .{ .by = holder, .damage = a.numbers().power } else null;
        }

        /// Taken up from a situation: its pose by its state (held, its holder's hand places it
        /// at its next move).
        pub fn takeUp(a: A, elapsed: u32) void {
            _ = elapsed;
            const s = a.mind.state;
            if (s == .lying or s == .falling) pose(a, "lying");
            if (s == .blinking_out) pose(a, "blinking");
        }

        /// It shows its animation `name` (a pose), unless it shows it already.
        pub fn pose(a: A, name: []const u8) void {
            const index = a.kind.definition.animation(name) orelse return;
            if (a.entity.animation.index == index) return;
            a.tick.startAnimation(a.handle, a.entity, index);
        }
    };
}

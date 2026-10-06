//! The bosses' common body, the original's common boss code: their coming in (their ground,
//! twins, the status bar, their strength by the level), their measures and moves, the blows they
//! take (knocked back, down, beaten, the points), the holds and throws, the special attack and a
//! player's new life, and their taking up from a situation. Each boss's behaviour (antonio.zig,
//! boss_r2.zig) has its own target, walk and blow, and the rest of its tick from this body.
//!
//! A boss's behaviour `M` gives the body: its `State` (with `appear`, `walk`, `swing` its blow,
//! `knocked_back`, `held`, `down`, `tossed`, `vaulted`, `flung`, `peppered`, `special_still`), its
//! `Mind` with the body's fields (as Antonio's), its `Numbers` with the body's, its `Animation`
//! (with `stand`, its animation 0, and `knocked`, `held`, `held_behind`, `flight`, `bounce`,
//! `down`, `lifted`, `flinch`), its `Sound` (`hurt`, `cry`, `thud`), and `walkAfresh(a)`, its walk
//! from its start.
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const behaviours = @import("../behaviours.zig");
const script = @import("../script.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Entity = entity.Entity;

/// What a hold's holder does to him, by the holder's state.
pub const Hold = packed struct(u8) {
    /// A grab took him (he is held from the next tick); placed in front of the holder, or with
    /// his back to it; thrown.
    grabbed: bool = false,
    front: bool = false,
    behind: bool = false,
    thrown: bool = false,
    _: u4 = 0,

    fn placed(h: Hold) bool {
        return h.front or h.behind or h.thrown;
    }
};

/// What his holder's state does to him.
pub const Reaction = enum { release, front, behind, knee, last_knee, toss, vault, fling, nothing };

/// The body of the boss whose behaviour is `M`.
pub fn Of(comptime M: type) type {
    return struct {
        const A = tick.Actor(M);
        const State = M.State;
        const Animation = M.Animation;

        /// The original's null object, as a boss reads it: its place 0 across and in depth.
        const nobody: Entity = .{};

        /// The rest of the tick is not his.
        pub fn end(a: A) void {
            a.mind.ended = true;
        }

        /// Whether the boss's section has begun (without a round's script, as in the tests: yes).
        pub fn inFight(a: A) bool {
            const p = a.tick.plan orelse return true;
            return script.bossFight(a.tick.world, p);
        }

        /// The status bar shows his health (from his boss's section only): one placed as the first of
        /// twins (or alone) in its first bar, unless the bar shows twins already; one placed as the
        /// second in its second, the bar showing twins. The bar keeps him until the next round's load.
        pub fn onBar(a: A) void {
            const w = a.tick.world;
            const bar = a.entity.spawn.bar orelse return;
            if (!a.entity.spawn.traits.twin) {
                if (w.boss_bar == null or w.boss_bar.? != bar + 1) w.boss_bar = bar;
                w.bosses[0] = a.handle;
            } else {
                w.boss_bar = bar;
                w.bosses[1] = a.handle;
            }
        }

        /// His power and health by the level: the easiest halves his power, the harder ones double it,
        /// the hardest adds to his health; out of his boss's section, his power is more, and in
        /// the round `outside_health_round` (round 8's boss rush) his health too.
        pub fn strength(a: A) struct { power: u8, health: i16 } {
            const n = a.numbers();
            var power: u8 = n.power;
            var health: i16 = a.kind.definition.health;
            const level: u2 = if (a.tick.plan) |p| p.level else 1;
            switch (level) {
                0 => power >>= 1,
                1 => {},
                2 => power *%= 2,
                3 => {
                    health += n.hardest_health;
                    power *%= 2;
                },
            }
            if (!inFight(a)) {
                power +%= n.outside_power;
                if (a.tick.plan) |p| if (p.round.number == n.outside_health_round) {
                    health += n.outside_health;
                };
            }
            return .{ .power = power, .health = health };
        }

        /// The second of twins finds the first among the enemies: each knows the other.
        pub fn pairUp(a: A) void {
            const m = a.mind;
            if (!a.entity.spawn.traits.twin) return;
            for (2..34) |i| {
                const o = &a.tick.world.entities[i];
                if (!o.alive() or i == a.handle.index or o.kind == null or o.kind.? != a.entity.kind.?) continue;
                m.twin = 2;
                m.twin_at = @intCast(i);
                const h = a.tick.world.handleAt(i).?;
                if (a.tick.actor(M, h)) |other| {
                    other.mind.twin = 1;
                    other.mind.twin_at = @intCast(a.handle.index);
                }
                return;
            }
        }

        /// His twin, while it is one.
        pub fn twinOf(a: A) ?A {
            const at = a.mind.twin_at orelse return null;
            const h = a.tick.world.handleAt(at) orelse return null;
            return a.tick.actor(M, h);
        }

        /// He measures himself against `o`: on which side across, how far, above or below and how far
        /// in depth; facing it when `face` (dead level across: right).
        pub fn measure(a: A, o: *const Entity, face: bool) void {
            const m = a.mind;
            const dx = o.position.x.whole() - a.entity.position.x.whole();
            m.left_of = dx < 0;
            m.dx = @intCast(@min(@abs(dx), std.math.maxInt(u16)));
            if (face) a.entity.facing = if (dx < 0) .left else .right;
            const dd = o.position.depth.whole() - a.entity.position.depth.whole();
            m.above = dd < 0;
            m.dd = @intCast(@min(@abs(dd), std.math.maxInt(u16)));
        }

        /// He faces his target (the side he measured it on), and shows animation `which` from its start.
        pub fn faceAndShow(a: A, which: Animation) void {
            a.entity.facing = if (a.mind.left_of) .left else .right;
            a.animate(which);
        }

        /// He moves by his speeds: in depth no further than the ground's depths, down no further than his
        /// ground.
        pub fn move(a: A) void {
            const n = a.numbers();
            const e = a.entity;
            e.position.x = e.position.x.add(e.velocity.x);
            var d = e.position.depth.add(e.velocity.depth);
            if (d.raw < 0) d = .zero;
            if (!d.lessThan(.pixels(n.depth_most))) d = .pixels(n.depth_most);
            e.position.depth = d;
            const h = e.position.height.add(e.velocity.height);
            e.position.height = if (@as(u32, @bitCast(h.raw)) > @as(u32, @bitCast(a.mind.ground.raw))) a.mind.ground else h;
        }

        pub fn stop(a: A) void {
            a.entity.velocity = .zero;
        }

        /// Whether he stands on his ground (whole pixels).
        pub fn grounded(a: A) bool {
            return a.entity.position.height.whole() == a.mind.ground.whole();
        }

        /// His speed in depth keeping a little above his target.
        pub fn keepAbove(a: A) Fixed {
            const n = a.numbers();
            const m = a.mind;
            if (m.above) return n.steer_fast.neg();
            const d = m.dd;
            if (d >= n.keep_far) return n.steer_fast;
            if (d < n.keep_near) return n.steer_fast.neg();
            if (d >= n.keep_step_2) return n.steer;
            if (d >= n.keep_step_1) return n.steer_slow;
            if (d >= n.keep_at) return .zero;
            return n.steer_slow.neg();
        }

        /// He walks again, facing his target, standing.
        pub fn walkAgain(a: A) void {
            a.mind.state = .walk;
            a.endMove();
            faceAndShow(a, .stand);
        }

        /// A blow meets him: walking, swinging, held or peppered, on the screen, a player's blow
        /// costs him its damage at his next tick (knocking him down when it does); a thing thrown or
        /// swung (but by a hand), a weapon's power or a body's, and it knocks down; the pepper's, on
        /// his ground, pepper him (`peppered`), else it does nothing. His own blow does not land at
        /// this tick.
        pub fn struck(a: A, blow: tick.Blow) bool {
            const n = a.numbers();
            const m = a.mind;
            switch (m.state) {
                .walk, .swing, .held, .peppered => {},
                else => return false,
            }
            if (m.ended) return false;
            const sx = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
            if (sx < n.struck_from or sx >= n.struck_to) return false;
            if (blow.missile and blow.reaction == .sneeze) return peppered(a, blow);
            a.endMove();
            if (blow.missile) {
                const thing = a.other(blow.attacker);
                const weapon = if (thing) |x| a.tick.kindOf(x).family() == .weapon else false;
                m.damage = if (weapon) @intCast(@min(blow.damage, 255)) else n.missile_damage;
                m.attacker = if (thing) |x| if (x.missile) |mi| mi.by else blow.attacker else blow.attacker;
                m.knocks_down = true;
                a.sound(.hurt);
                return true;
            }
            m.damage = @intCast(@min(blow.damage, 255));
            m.attacker = blow.attacker;
            m.knocks_down = blow.reaction == .knock_down;
            return true;
        }

        /// The pepper meets him: on his ground (not held), from its thrower, he stops where he is a
        /// while, his tick over, showing his stand from its start; off his ground it does nothing.
        fn peppered(a: A, blow: tick.Blow) bool {
            const m = a.mind;
            if (m.state == .held or a.entity.position.height.raw != m.ground.raw) return true;
            a.endMove();
            const thing = a.other(blow.attacker);
            m.attacker = if (thing) |x| if (x.missile) |mi| mi.by else blow.attacker else blow.attacker;
            m.state = .peppered;
            m.count = a.numbers().pepper_ticks;
            a.animate(.stand);
            end(a);
            return true;
        }

        /// Peppered: unmoving, his stand and his flinch by turns, two ticks each, until his ticks
        /// run out; then he walks again.
        pub fn pepperedTick(a: A) void {
            const m = a.mind;
            m.count -%= 1;
            if (m.count == 0) {
                M.walkAfresh(a);
                a.pause(false);
                return walkAgain(a);
            }
            a.animate(if (m.count & 2 != 0) .stand else .flinch);
            a.pause(true);
        }

        /// The damage of a blow met at the last tick: he stops; his last health, a blow that knocks
        /// down, or one in the air knocks him down (out of a hold); else he is knocked back (held, he
        /// stays so, facing his holder). Returns whether he took one.
        pub fn takeDamage(a: A) bool {
            const n = a.numbers();
            const m = a.mind;
            if (m.damage == 0) return false;
            const d = m.damage;
            m.damage = 0;
            stop(a);
            a.takeDamage(m.attacker, d);
            var from = m.attacker;
            if (a.entity.health <= 0) {
                beatenCry(a);
                breakHold(a);
                knockDown(a, from, n.knock_down_ticks);
                return true;
            }
            a.sound(.hurt);
            const knocks = m.knocks_down;
            m.knocks_down = false;
            if (knocks or !grounded(a)) {
                breakHold(a);
                knockDown(a, from, n.knock_down_ticks);
                return true;
            }
            if (m.hold.grabbed) from = m.holder;
            knocked(a, from, n.knock_back_ticks);
            return true;
        }

        /// Knocked down: flying back from `from`, up, to bounce.
        pub fn knockDown(a: A, from: ?Handle, ticks: u8) void {
            const n = a.numbers();
            a.entity.velocity.x = n.knocked_x;
            a.entity.velocity.height = n.knocked_up;
            a.mind.bounces = n.knocked_bounces;
            knocked(a, from, ticks);
        }

        /// Knocked back (or down) `ticks` ticks, facing `from` (his speed across away from it); held from
        /// behind, facing away.
        pub fn knocked(a: A, from: ?Handle, ticks: u8) void {
            const m = a.mind;
            const e = a.entity;
            m.count = ticks;
            m.state = .knocked_back;
            M.walkAfresh(a);
            a.endMove();
            e.facing = .right;
            if (from) |h| if (a.other(h)) |o| if (o.position.x.whole() < e.position.x.whole()) {
                e.facing = .left;
                e.velocity.x = e.velocity.x.neg();
            };
            if (m.hold.behind) e.facing = e.facing.turned();
            move(a);
            a.animate(.knocked);
        }

        /// Out of a hold: his holder lets him go.
        pub fn breakHold(a: A) void {
            const m = a.mind;
            if (@as(u8, @bitCast(m.hold)) == 0) return;
            m.hold = .{};
            if (a.entity.holder != null) a.letGo();
        }

        /// The cry of his last health; in his section with no twin left, the round's timer stops.
        pub fn beatenCry(a: A) void {
            const m = a.mind;
            const alone = m.twin == 0 or if (twinOf(a)) |o| o.entity.health <= 0 else true;
            if (alone and inFight(a)) a.tick.world.timer.stopped = true;
            a.sound(.cry);
        }

        /// Knocked back: he shakes where he stands, or flies, bounces and lands; out of time, held still
        /// he stays so, else he walks, or (down from a fall) lies.
        pub fn knockedBackTick(a: A) void {
            const n = a.numbers();
            const m = a.mind;
            const e = a.entity;
            // Knocked back by no one who struck him (a player's new life): the original measures
            // him against its null object, whose place reads 0 across and in depth.
            if (m.attacker) |h| {
                if (a.other(h)) |o| measure(a, o, false);
            } else measure(a, &nobody, false);
            if (m.bounces != 0) {
                if (!e.position.height.eql(m.ground)) {
                    e.velocity.height = e.velocity.height.add(n.knocked_gravity);
                    if (e.velocity.height.raw == 0 and m.bounces == 2) a.animate(.flight);
                } else {
                    m.bounces -= 1;
                    if (m.bounces == 0) {
                        e.velocity.x = .zero;
                        e.velocity.height = .zero;
                    } else {
                        e.velocity.height = n.bounce_up;
                        a.animate(.bounce);
                    }
                    a.sound(.thud);
                }
            } else if (a.plays(.knocked)) {
                const by: i32 = if (m.count & 1 != 0) -n.shake else n.shake;
                e.position.x = e.position.x.add(.pixels(by));
            }
            m.count -%= 1;
            if (m.count != 0) return move(a);
            if (@as(u8, @bitCast(m.hold)) != 0) {
                m.state = .held;
                return a.animate(if (m.hold.front) .held else .held_behind);
            }
            if (a.plays(.knocked)) return walkAgain(a);
            lie(a);
        }

        /// Down: alive, a moment; beaten, much longer, blinking at first, and his points go to the
        /// player who struck him last; the round is won (with no twin) when it is over.
        pub fn lie(a: A) void {
            const n = a.numbers();
            const m = a.mind;
            m.hold = .{};
            m.state = .down;
            if (a.entity.health > 0) {
                m.count = n.down_ticks;
                return faceAndShow(a, .down);
            }
            m.count = n.dead_ticks;
            // Beaten in his section, alone (or the last of twins): the fight is over, the other
            // enemies knocked down with him.
            if (!inFight(a)) return;
            if (m.twin == 0) return a.tick.bossBeaten();
            const other = twinOf(a) orelse return;
            if (other.entity.health > 0 or m.twin_beaten) return;
            other.mind.twin_beaten = true;
            a.tick.bossBeaten();
            a.tick.roundWon();
        }

        pub fn down(a: A) void {
            const n = a.numbers();
            const m = a.mind;
            if (a.entity.health > 0) {
                // Getting up: a boss that notes it (round 4's twins change targets then).
                if (@hasField(M.Mind, "rose")) m.rose = true;
                m.count -%= 1;
                if (m.count == 0) walkAgain(a);
                return;
            }
            a.entity.flags.hidden = true;
            m.count -%= 1;
            if (m.count == 0) {
                if (m.twin == 0) a.tick.roundWon();
                return leave(a);
            }
            if (m.count == n.points_at) {
                scorePoints(a);
                // Brought by a section's reserve, outside the boss's section: he leaves then,
                // counted off the reserve's boss's art and colours.
                if (!inFight(a)) {
                    script.bossCountedOff(a.tick);
                    leave(a);
                }
                return;
            }
            if (m.count > n.points_at and m.count & 2 != 0) a.entity.flags.hidden = false;
        }

        /// He goes: his twin is alone from now.
        fn leave(a: A) void {
            if (twinOf(a)) |o| {
                o.mind.twin = 0;
                o.mind.twin_at = null;
            }
            a.remove();
        }

        /// His points to the player who struck him last: player 1, else player 2.
        pub fn scorePoints(a: A) void {
            const w = a.tick.world;
            const by_first = if (a.mind.attacker) |h| if (w.players[0].entity) |p| p.eql(h) else false else false;
            const p = &w.players[if (by_first) 0 else 1];
            p.score = @min(p.score +| a.numbers().points, w.score_most);
        }

        /// Walking, swinging or held, a player's reach meets him within his height: the grab takes him
        /// (not one another holds).
        pub fn grabbable(a: A, by: Handle) bool {
            const m = a.mind;
            switch (m.state) {
                .walk, .swing, .held => {},
                else => return false,
            }
            if (m.ended) return false;
            if (m.hold.grabbed) if (m.holder) |h| if (!h.eql(by)) return false;
            const holder = a.other(by) orelse return false;
            return @abs(holder.position.height.whole() - a.entity.position.height.whole()) <= a.numbers().grab_height;
        }

        /// A grab took him: from his next tick, his holder's state says what it does to him.
        pub fn heldBy(a: A, holder: Handle) void {
            a.endMove();
            const m = a.mind;
            if (m.hold.grabbed) return;
            m.hold.grabbed = true;
            m.holder = holder;
        }

        /// His holder let him go.
        pub fn letGoBy(a: A, holder: Handle) void {
            _ = holder;
            a.mind.let_go = true;
        }

        pub fn reactionOf(a: A, holder: *const Entity) Reaction {
            const name = behaviours.stateName(&holder.mind) orelse return .release;
            _ = a;
            const table = [_]struct { []const u8, Reaction }{
                .{ "grab", .front },
                .{ "grab_behind", .behind },
                .{ "knee", .knee },
                .{ "knee_last", .last_knee },
                .{ "grab_blow", .toss },
                .{ "vault", .vault },
                .{ "vault_land", .vault },
                .{ "throw", .nothing },
                .{ "throw_back", .nothing },
            };
            for (table) |r| if (std.mem.eql(u8, r[0], name)) return r[1];
            return .release;
        }

        /// Grabbed, what his holder does to him now: holds him in front or from behind (placed once);
        /// knees him (the damage at his next tick); throws him; or lets him go (placed, he walks).
        /// Returns whether his tick ended there.
        pub fn holdTaken(a: A) bool {
            const n = a.numbers();
            const m = a.mind;
            if (!m.hold.grabbed) return false;
            const hh = m.holder orelse return release(a);
            const holder = a.other(hh) orelse return release(a);
            switch (reactionOf(a, holder)) {
                .release => return release(a),
                .nothing => return false,
                .knee => {
                    m.damage = n.knee_damage;
                    m.attacker = hh;
                    return false;
                },
                .last_knee => {
                    m.knocks_down = true;
                    m.damage = n.last_knee_damage;
                    m.attacker = hh;
                    return false;
                },
                .front => {
                    if (m.hold.front) return false;
                    m.hold = .{ .grabbed = true, .front = true };
                    placeFacing(a, holder, n.hold_front);
                    return heldNow(a, .held);
                },
                .behind => {
                    if (m.hold.behind) return false;
                    m.hold = .{ .grabbed = true, .behind = true };
                    placeBacking(a, holder, n.hold_behind);
                    return heldNow(a, .held_behind);
                },
                .toss => {
                    if (m.hold.thrown) return false;
                    m.hold = .{ .grabbed = true, .thrown = true };
                    placeBacking(a, holder, n.toss_place);
                    return thrown(a, .tossed, .held, n.toss_ticks);
                },
                .vault => {
                    if (m.hold.thrown) return false;
                    m.hold = .{ .grabbed = true, .thrown = true };
                    placeBacking(a, holder, n.vault_place);
                    return thrown(a, .vaulted, .held_behind, n.vault_ticks);
                },
                .fling => {
                    m.hold = .{ .grabbed = true, .thrown = true };
                    placeFacing(a, holder, n.fling_place);
                    return thrown(a, .flung, .held, n.fling_ticks);
                },
            }
        }

        /// Let go: placed in the hold, he walks again at once.
        pub fn release(a: A) bool {
            const m = a.mind;
            const placed = m.hold.placed();
            m.hold = .{};
            if (!placed) return false;
            walkAgain(a);
            return true;
        }

        /// Held: he stands in his hold's pose, still.
        pub fn heldNow(a: A, which: Animation) bool {
            const m = a.mind;
            M.walkAfresh(a);
            m.state = .held;
            stop(a);
            a.animate(which);
            return true;
        }

        /// Thrown: a thing thrown by his holder, in the throw's state, for `ticks` ticks.
        pub fn thrown(a: A, state: State, which: Animation, ticks: u8) bool {
            const n = a.numbers();
            const m = a.mind;
            m.state = state;
            m.count = ticks;
            m.bounces = n.thrown_bounces;
            a.animate(which);
            stop(a);
            if (m.holder) |h| a.entity.missile = .{ .by = h, .damage = n.thrown_damage };
            return true;
        }

        /// Placed `ahead` in front of his holder, facing it; on its depth, on his ground.
        pub fn placeFacing(a: A, holder: *const Entity, ahead: i16) void {
            const e = a.entity;
            e.facing = .right;
            if (holder.facing == .right) {
                e.facing = .left;
                e.position.x = holder.position.x.add(.pixels(ahead));
            } else e.position.x = holder.position.x.sub(.pixels(ahead));
            e.position.depth = holder.position.depth;
            e.position.height = a.mind.ground;
        }

        /// Placed `back` behind where his holder faces (ahead of it, negative), his back to it.
        pub fn placeBacking(a: A, holder: *const Entity, back: i16) void {
            const e = a.entity;
            e.facing = .right;
            if (holder.facing == .left) {
                e.facing = .left;
                e.position.x = holder.position.x.add(.pixels(back));
            } else e.position.x = holder.position.x.sub(.pixels(back));
            e.position.depth = holder.position.depth;
            e.position.height = a.mind.ground;
        }

        /// Held: let go by his holder he walks; his hold ended otherwise, he walks.
        pub fn held(a: A) void {
            const m = a.mind;
            if (m.let_go) {
                m.let_go = false;
                m.hold = .{};
                return walkAgain(a);
            }
            if (m.state != .held) return;
            if (!m.hold.grabbed) walkAgain(a);
        }

        /// The thrower's side: whether it faces left.
        pub fn throwerLeft(a: A) bool {
            const h = a.mind.holder orelse return false;
            const t = a.other(h) orelse return false;
            return t.facing == .left;
        }

        /// A landing's shake of the screen, with its thud, unless the screen shakes already.
        pub fn landingShake(a: A) void {
            const c = &a.tick.world.camera;
            if (a.tick.world.special or c.shake != 0) return;
            a.tick.shake();
            a.sound(.thud);
        }

        /// His fall after a throw: in the air, faster down; landing, his bounces: the first `first`
        /// back up (a shake of the screen when `shake_first`, else a thud); the second halves his speed
        /// across, `second` up, with the throw's `damage` (the shake then, or a thud); the last stops
        /// him.
        pub fn thrownFall(a: A, first: Fixed, second: Fixed, damage: u8, shake_first: bool) void {
            const n = a.numbers();
            const m = a.mind;
            const e = a.entity;
            if (!grounded(a)) {
                e.velocity.height = e.velocity.height.add(n.thrown_gravity);
                return;
            }
            m.bounces -= 1;
            if (m.bounces == 0) {
                e.velocity.x = .zero;
                e.velocity.height = .zero;
                return a.sound(.thud);
            }
            if (m.bounces == 1) {
                if (!shake_first) landingShake(a);
                e.velocity.x = .{ .raw = e.velocity.x.raw >> 1 };
                e.velocity.height = .parts(@intCast(second.whole()), e.velocity.height.frac());
                a.takeDamage(m.holder, damage);
                if (e.health <= 0) return beatenCry(a);
                if (shake_first) a.sound(.thud);
                return;
            }
            e.velocity.height = .parts(@intCast(first.whole()), e.velocity.height.frac());
            a.animate(.bounce);
            if (shake_first) landingShake(a) else a.sound(.thud);
        }

        /// The throw's ticks run out: he is no longer a thing thrown, and lies.
        pub fn thrownCount(a: A) void {
            const m = a.mind;
            m.count -%= 1;
            if (m.count != 0) return move(a);
            a.entity.missile = null;
            lie(a);
        }

        /// Tossed over the shoulder: lifted, flying over, then he falls and bounces.
        pub fn tossed(a: A) void {
            const n = a.numbers();
            const m = a.mind;
            const e = a.entity;
            if (m.bounces != 0) {
                const left = m.count;
                if (left == n.toss_lift_at) {
                    a.animate(.lifted);
                    e.velocity.height = .parts(@intCast(n.toss_up.whole()), e.velocity.height.frac());
                    e.position.height = e.position.height.sub(.pixels(n.toss_lift));
                    var x = n.toss_x.whole();
                    var ahead: i32 = n.toss_ahead;
                    if (throwerLeft(a)) {
                        x = -x;
                        ahead = -ahead;
                        e.facing = .left;
                    }
                    e.velocity.x = .parts(@intCast(x), e.velocity.x.frac());
                    e.position.x = e.position.x.add(.pixels(ahead));
                } else if (left < n.toss_lift_at) {
                    thrownFall(a, n.toss_bounce, n.toss_bounce_2, n.toss_damage, true);
                }
            }
            thrownCount(a);
        }

        /// Carried over the thrower's head step by step (`carried`), slammed down (the vault's damage),
        /// then flying off and sliding.
        pub fn vaulted(a: A) void {
            const n = a.numbers();
            const m = a.mind;
            const e = a.entity;
            if (m.bounces != 0) {
                const left = m.count;
                var step: ?usize = null;
                if (left == n.vault_turn_at) {
                    step = 0;
                    a.animate(.flight);
                } else if (left == n.vault_over_at) {
                    step = 1;
                } else if (left == n.vault_down_at) {
                    a.takeDamage(m.holder, n.vault_damage);
                    if (e.health <= 0) beatenCry(a);
                    landingShake(a);
                    a.animate(.lifted);
                    step = 2;
                }
                if (step) |k| {
                    var back: i32 = a.tables().carried[2 * k];
                    const below: i32 = a.tables().carried[2 * k + 1];
                    m.bounces -= 1;
                    if (throwerLeft(a)) {
                        back = -back;
                        e.facing = .left;
                    }
                    e.position.x = e.position.x.sub(.pixels(back));
                    e.position.height = e.position.height.add(.pixels(below));
                }
            }
            const left = m.count;
            if (left == n.vault_fly_at) {
                e.velocity.x = n.vault_fly;
                e.velocity.height = n.vault_fly;
                a.sound(.thud);
                if (e.facing == .left) e.velocity.x = e.velocity.x.neg();
            } else if (left < n.vault_fly_at) {
                if (!grounded(a)) {
                    e.velocity.height = e.velocity.height.add(n.thrown_gravity);
                } else if (e.velocity.x.raw != 0) {
                    if (a.plays(.bounce)) {
                        e.velocity = .zero;
                    } else {
                        e.facing = if (m.left_of) .right else .left;
                        a.animate(.bounce);
                        e.velocity.x = n.vault_slide;
                        e.velocity.height = n.vault_slide;
                        a.sound(.thud);
                        if (e.facing == .left) e.velocity.x = e.velocity.x.neg();
                    }
                }
            }
            thrownCount(a);
        }

        /// Flung behind the thrower: swung to its back, flying off, falling and bouncing.
        pub fn flung(a: A) void {
            const n = a.numbers();
            const m = a.mind;
            const e = a.entity;
            if (m.bounces != 0) {
                const left = m.count;
                if (left == n.fling_lift_at or left == n.fling_at) {
                    const k: usize = if (left == n.fling_lift_at) 3 else 4;
                    var x: i32 = 0;
                    if (left == n.fling_lift_at) {
                        a.animate(.lifted);
                    } else {
                        e.velocity.height = .parts(@intCast(n.fling_up.whole()), e.velocity.height.frac());
                        x = n.fling_x.whole();
                    }
                    var back: i32 = a.tables().carried[2 * k];
                    const below: i32 = a.tables().carried[2 * k + 1];
                    if (!throwerLeft(a)) {
                        back = -back;
                        x = -x;
                        e.facing = .left;
                    }
                    e.position.x = e.position.x.add(.pixels(back));
                    e.position.height = e.position.height.add(.pixels(below));
                    e.velocity.x = .parts(@intCast(x), e.velocity.x.frac());
                } else if (left < n.fling_at) {
                    if (left == n.fling_turn_at) a.animate(.flight);
                    thrownFall(a, n.fling_bounce, n.fling_bounce_2, n.fling_damage, false);
                }
            }
            thrownCount(a);
        }

        /// Taken up, a blow of `by` met him at the situation's tick: its damage at his next tick,
        /// knocking him down when it does (a thing thrown, or a blow that knocks down).
        pub fn takeUpMet(a: A, by: Handle, damage: i16) void {
            const m = a.mind;
            switch (m.state) {
                .walk, .swing, .held => {},
                else => return,
            }
            m.damage = @intCast(std.math.clamp(damage, 0, 255));
            m.attacker = by;
            const s = a.other(by) orelse return;
            if (s.missile != null) {
                m.knocks_down = true;
                m.attacker = s.missile.?.by;
                return;
            }
            const blow = s.move orelse return;
            m.knocks_down = a.tick.kindOf(s).definition.moves[blow].reaction == .knock_down;
        }

        /// Taken up held: in front of his holder when he faces it, else from behind.
        pub fn takeUpHeld(a: A, elapsed: u32) void {
            _ = elapsed;
            const m = a.mind;
            const hh = a.entity.holder orelse return;
            const holder = a.other(hh) orelse return;
            m.hold = .{ .grabbed = true };
            m.holder = hh;
            if (holder.facing != a.entity.facing) m.hold.front = true else m.hold.behind = true;
        }

        /// A player called the special attack.
        pub fn specialCalled(a: A) void {
            a.mind.special_new = true;
        }

        /// At a special attack's first tick he takes it once: held still a while (longer for the second
        /// player's), then knocked down with its damage. Returns whether his tick ended there.
        pub fn special(a: A) bool {
            const n = a.numbers();
            const m = a.mind;
            const w = a.tick.world;
            if (!w.special) {
                m.special_taken = false;
                m.special_new = false;
                return false;
            }
            if (m.special_new) {
                m.special_new = false;
                m.special_taken = false;
            }
            if (m.state == .appear or m.special_taken) return false;
            m.special_taken = true;
            if (m.state == .special_still or a.entity.health <= 0) return false;
            const second = if (w.special_by) |by| if (w.players[1].entity) |p| p.eql(by) else false else false;
            m.attacker = w.players[if (second) 1 else 0].entity;
            m.grounded_in = n.special_grounded;
            m.state = .special_still;
            a.endMove();
            a.pause(true);
            m.special_left = if (second) n.special_ticks_second else n.special_ticks;
            m.hold = .{};
            M.walkAfresh(a);
            return true;
        }

        /// Held still by the special attack; put back on the ground a moment in; at its end its damage,
        /// and he is knocked down (dying, faster).
        pub fn specialStill(a: A) void {
            const n = a.numbers();
            const m = a.mind;
            if (m.special_left != 0) {
                m.special_left -= 1;
                if (m.grounded_in == 0) return;
                m.grounded_in -= 1;
                if (m.grounded_in != 0) return;
                a.entity.position.height = m.ground;
                a.animate(.stand);
                return;
            }
            a.takeDamage(m.attacker, n.special_damage);
            if (a.entity.health > 0) {
                a.entity.velocity.x = n.blast_x;
            } else {
                beatenCry(a);
                a.entity.velocity.x = n.dying_x;
            }
            a.entity.velocity.height = n.blast_up;
            knockedFlat(a);
        }

        /// A player's new life drops in: at his tick it knocks him down.
        pub fn knockedBack(a: A) void {
            a.mind.blast = true;
        }

        /// A player's new life knocks him down when he walks, swings or is held still: facing left, his
        /// health spared. Returns whether his tick ended there.
        pub fn blast(a: A) bool {
            const n = a.numbers();
            const m = a.mind;
            if (!m.blast) return false;
            m.blast = false;
            switch (m.state) {
                .walk, .swing, .special_still => {},
                else => return false,
            }
            // Facing left, knocked to the right (his speed turned as he faces left); but in a
            // round whose new lives knock back to the left (round 8's: the original leaves his
            // facing bit clear there), facing right, knocked to the left.
            const left = if (a.tick.plan) |p| p.round.knocked_back_left else false;
            a.entity.facing = if (left) .right else .left;
            a.entity.velocity.x = n.blast_x;
            a.entity.velocity.height = n.blast_up;
            knockedFlat(a);
            return true;
        }

        /// Knocked down where he is (the special attack's, a new life's): flying back the way he faces
        /// is not, up, to bounce.
        pub fn knockedFlat(a: A) void {
            const n = a.numbers();
            const m = a.mind;
            const e = a.entity;
            e.velocity.depth = .zero;
            m.bounces = n.blast_bounces;
            m.count = n.blast_ticks;
            m.state = .knocked_back;
            M.walkAfresh(a);
            a.endMove();
            if (e.facing == .left) e.velocity.x = e.velocity.x.neg();
            if (m.left_of) e.facing = .left;
            a.animate(.knocked);
            move(a);
        }
    };
}

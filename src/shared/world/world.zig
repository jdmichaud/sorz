//! The world of a round (DESIGN.md 10.3): its entities in a fixed pool, the two players, the
//! camera and the round's script. It is a value, its fields named and typed, with no pointer: its
//! canonical form (canonical.zig) is what the tests, the replays and network play compare.
//!
//! The content the world reads (its kinds, kinds.zig), the random generator (the game's one, which
//! the screens before play draw from too) and the tick's output (output.zig) are given to each
//! tick: systems.zig runs a logic tick over them.
const std = @import("std");
const canonical = @import("../canonical.zig");
const input = @import("../input.zig");
const fixed = @import("fixed.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const behaviours = @import("behaviours.zig");
const script = @import("script.zig");

const Fixed = fixed.Fixed;
const Vec3 = fixed.Vec3;
const Entity = entity.Entity;
const Handle = entity.Handle;
const KindId = entity.KindId;
const Kinds = kinds_mod.Kinds;
pub const Spawn = entity.Spawn;
pub const Entrance = entity.Entrance;
pub const Traits = entity.Traits;

pub const capacity = entity.capacity;

/// What a player asks for at a logic tick: the buttons held, and those newly pressed.
pub const Command = struct {
    held: input.Pad = .{},
    pressed: input.Pad = .{},
    /// The presses of the last read alone (those a player waiting to continue reads, as the
    /// original's reads its pad there).
    last: input.Pad = .{},
};

pub const Player = struct {
    /// The entity the player plays, if any: its fighter, or, out of lives, its wait to continue.
    entity: ?Handle = null,
    /// The kind of its fighter (its character's).
    character: ?KindId = null,
    lives: u8 = 0,
    specials: u8 = 0,
    /// The continues left; out of the game (it answered no, or had none left).
    continues: u8 = 0,
    out: bool = false,
    /// Points, as the original counts them: they hold at the world's `score_most`.
    score: u32 = 0,
    /// The command of this tick.
    command: Command = .{},
    /// The pad as read at the last display tick, which the next read's presses are new against.
    last: input.Pad = .{},
};

/// The view of the round: its top-left corner, and how far it may go.
pub const Camera = struct {
    x: Fixed = .zero,
    y: Fixed = .zero,
    /// Across, to the wall it stops at until the section is cleared; and down.
    x_min: Fixed = .zero,
    x_max: Fixed = .of(std.math.maxInt(i32)),
    y_min: Fixed = .zero,
    y_max: Fixed = .of(std.math.maxInt(i32)),
    /// It follows the players across (in play), by the round's camera's rules, from where the
    /// last tick drew them, and never goes back: its limit on the left follows it.
    follows: ?Rules = null,
    drawn: [2]?Fixed = .{ null, null },
    /// The special attack's run, while it lasts: the camera neither follows nor holds the players.
    run: ?Run = null,
    /// Its place across at the last tick (what moved with it moves by the difference).
    prev_x: Fixed = .zero,
    /// A shake under way (`Tick.shake`): its ticks left.
    shake: u8 = 0,

    /// How it follows the players (the round's camera's, script.zig `cameraRules`): a player
    /// drawn left of `band[0]` or from `band[1]` on, across the screen, moves it by as much, at
    /// most `most` pixels a tick; the players are kept within `kept_x` across from its left edge
    /// (but in a hold) and on the depths `kept_depth`; a heavy fall shakes it `shake_ticks`
    /// ticks, `shake_by` pixels down and up in turn.
    pub const Rules = struct {
        band: [2]i16,
        most: i16,
        kept_x: [2]i16,
        kept_depth: [2]i16,
        shake_ticks: u8,
        shake_by: i16,
    };

    /// The special attack's run (behaviours/special_knockdown.zig): called, the camera follows for the
    /// tick of the call; then it runs back across at `speed` to `limit`; then (its effect over) it
    /// runs ahead at that speed until it is back where it was at the call.
    pub const Run = struct {
        from: Fixed,
        state: enum { called, back, ahead } = .called,
        speed: Fixed = .zero,
        limit: Fixed = .zero,
    };
};

/// The round's script's place in the round, and the round's timer (script.zig).
pub const Script = script.State;
pub const Timer = script.Timer;

pub const World = struct {
    /// The game's clock, as the original's tick counter, which some of the enemies' choices
    /// read: it counts every tick of the game's logic that ends, a logic tick in play (the
    /// world's), a display tick while the world waits (the round's start, the pause, the time
    /// over, the end: the round scene counts them), never a load's. The round's load clears it:
    /// a round's world starts it at 0.
    tick: u32 = 0,
    entities: [capacity]Entity = @splat(.{}),
    players: [2]Player = @splat(.{}),
    camera: Camera = .{},
    script: Script = .{},
    timer: Timer = .{},
    /// The ground's height, until the round's floor gives it place by place (PLAN item 13).
    ground: Fixed = .zero,
    /// The most a player's score holds (play's record's, which the round sets; none before).
    score_most: u32 = std.math.maxInt(u32),
    /// A special attack is under way (play's phase `special`): the players stand still, the
    /// enemies it caught wait for its blast; the player who called the last one.
    special: bool = false,
    special_by: ?Handle = null,
    /// The status bar's bosses, from the first tick of the round's boss: its entry in the bar's
    /// names and bars (the round's script's `bar`), and the bosses whose health its bars show
    /// (the second of twins in the second).
    boss_bar: ?u8 = null,
    bosses: [2]?Handle = .{ null, null },

    pub const Full = error{Full};

    /// The entity `h` names, or null when it has gone.
    pub fn get(self: *World, h: Handle) ?*Entity {
        if (h.index >= capacity) return null;
        const e = &self.entities[h.index];
        if (!e.alive() or e.generation != h.generation) return null;
        return e;
    }

    pub fn getConst(self: *const World, h: Handle) ?*const Entity {
        return @constCast(self).get(h);
    }

    /// The handle of the entity at place `index`, or null when the place is free.
    pub fn handleAt(self: *const World, index: usize) ?Handle {
        const e = &self.entities[index];
        if (!e.alive()) return null;
        return .{ .index = @intCast(index), .generation = e.generation };
    }

    /// A new entity of `kind` at `position`, facing `facing`, in the first free place: its
    /// team, health and palette from its definition, its behaviour at its first state, its
    /// definition's first animation started.
    pub fn spawn(self: *World, kinds: *const Kinds, kind: KindId, position: Vec3, facing: entity.Facing) Full!Handle {
        const index = for (&self.entities, 0..) |*e, i| {
            if (!e.alive()) break i;
        } else return error.Full;
        return self.spawnIn(kinds, kind, index, position, facing);
    }

    /// `spawn` in the place `index` (the order the world updates its entities in follows the
    /// places), which must be free.
    pub fn spawnIn(self: *World, kinds: *const Kinds, kind: KindId, index: usize, position: Vec3, facing: entity.Facing) Full!Handle {
        if (index >= capacity or self.entities[index].alive()) return error.Full;
        const k = kinds.get(kind);
        const e = &self.entities[index];
        e.* = .{
            .generation = e.generation,
            .kind = kind,
            .team = k.definition.team,
            .position = position,
            .facing = facing,
            .health = k.definition.health,
            .palette = k.definition.palette,
            .mind = behaviours.initial(k.behaviour),
        };
        if (k.definition.animations.len != 0) kinds.startAnimation(e, 0);
        return .{ .index = @intCast(index), .generation = e.generation };
    }

    /// The entity `h` becomes a new entity of `kind` in its place, as the original's objects
    /// change their type, their record cleared: its handle still finds it, at its place, facing
    /// its way; the rest as `spawn` gives it.
    pub fn morph(self: *World, kinds: *const Kinds, h: Handle, kind: KindId) void {
        const e = self.get(h) orelse return;
        const position = e.position;
        const facing = e.facing;
        const k = kinds.get(kind);
        e.* = .{
            .generation = e.generation,
            .kind = kind,
            .team = k.definition.team,
            .position = position,
            .facing = facing,
            .health = k.definition.health,
            .palette = k.definition.palette,
            .mind = behaviours.initial(k.behaviour),
        };
        if (k.definition.animations.len != 0) kinds.startAnimation(e, 0);
    }

    /// The entity `h` becomes one of `kind` in its place, its record kept, as the original's
    /// objects whose type alone changes (an armed Galsia that lost its weapon fights on as a plain
    /// one): its handle still finds it; its behaviour at its first state, its team and palette its
    /// new definition's (an enemy whose record gave it colours keeps its line), the animation of
    /// the same name played on (else its first); its place, speeds, health, holds and the rest
    /// kept.
    pub fn retype(self: *World, kinds: *const Kinds, h: Handle, kind: KindId) void {
        const e = self.get(h) orelse return;
        const old = if (e.animation.index) |i| kinds.get(e.kind.?).definition.animations[i].name else null;
        const k = kinds.get(kind);
        e.kind = kind;
        e.team = k.definition.team;
        if (e.spawn.colours == null) e.palette = k.definition.palette;
        e.mind = behaviours.initial(k.behaviour);
        e.boxes = .{};
        const same = if (old) |n| k.definition.animation(n) else null;
        if (same) |i| {
            e.animation.index = i;
            if (e.animation.frame >= k.definition.animations[i].frames.len) e.animation.frame = 0;
        } else if (k.definition.animations.len != 0) kinds.startAnimation(e, 0);
    }

    /// The places the enemies take (the original's enemies' objects, its 3rd to its 34th): a
    /// shutter and its slats too.
    pub const enemy_places: struct { from: usize, to: usize } = .{ .from = 2, .to = 34 };

    /// The places the weapons take, which the order of updates puts after the enemies' (the
    /// original's weapons' objects, its 35th to its 42nd).
    pub const weapon_places: struct { from: usize, to: usize } = .{ .from = 34, .to = 42 };

    /// The places the items a breakable leaves and its pieces take, after the weapons' (the
    /// original's objects 43 to 50).
    pub const item_places: struct { from: usize, to: usize } = .{ .from = 42, .to = 50 };

    /// An item a breakable leaves: in the first free place of the items', else in the last free
    /// one below them, down to the enemies' first (as the original's).
    pub fn spawnItem(self: *World, kinds: *const Kinds, kind: KindId, position: Vec3) Full!Handle {
        return self.spawnWithin(kinds, kind, item_places.from, item_places.to, position, .right) catch {
            var i = item_places.to;
            while (i > enemy_places.from) {
                i -= 1;
                if (!self.entities[i].alive()) return self.spawnIn(kinds, kind, i, position, .right);
            }
            return error.Full;
        };
    }

    /// `spawn` in the first free place from `from` to `to` (excluded).
    pub fn spawnWithin(self: *World, kinds: *const Kinds, kind: KindId, from: usize, to: usize, position: Vec3, facing: entity.Facing) Full!Handle {
        for (from..@min(to, capacity)) |i| {
            if (!self.entities[i].alive()) return self.spawnIn(kinds, kind, i, position, facing);
        }
        return error.Full;
    }

    /// An enemy the round's script places: a new entity of `kind` at `position`, facing right, in
    /// its first state, in the first of the enemies' free places, placed as `how` says (its way
    /// in, its traits, its place beside its target, its strength).
    pub fn spawnEnemy(self: *World, kinds: *const Kinds, kind: KindId, position: Vec3, how: Spawn) Full!Handle {
        const h = try self.spawnWithin(kinds, kind, enemy_places.from, enemy_places.to, position, .right);
        self.get(h).?.spawn = how;
        return h;
    }

    /// The entity goes: its place is freed, its handles find nothing, and a grab it was in ends.
    pub fn remove(self: *World, h: Handle) void {
        const e = self.get(h) orelse return;
        e.* = .{ .generation = e.generation +% 1 };
        for (&self.entities) |*other| {
            if (other.holder) |x| if (x.eql(h)) {
                other.holder = null;
            };
            if (other.holding) |x| if (x.eql(h)) {
                other.holding = null;
            };
        }
    }

    /// The entities in the order the world updates them: the players', player 1's first, then
    /// the others in their places' order. Returns their places.
    pub fn updateOrder(self: *const World, buf: *[capacity]u8) []const u8 {
        var n: usize = 0;
        var player_place: [2]?usize = .{ null, null };
        for (self.players, 0..) |p, k| {
            const h = p.entity orelse continue;
            if (self.getConst(h) == null) continue;
            if (k == 1 and player_place[0] == h.index) continue;
            player_place[k] = h.index;
            buf[n] = h.index;
            n += 1;
        }
        for (&self.entities, 0..) |*e, i| {
            if (!e.alive()) continue;
            if (player_place[0] == i or player_place[1] == i) continue;
            buf[n] = @intCast(i);
            n += 1;
        }
        return buf[0..n];
    }

    /// The player who plays the entity `h`, if any.
    pub fn playerOf(self: *const World, h: Handle) ?u1 {
        for (self.players, 0..) |p, k| {
            if (p.entity) |x| if (x.eql(h)) return @intCast(k);
        }
        return null;
    }

    /// The hash of the world's canonical form.
    pub fn hash(self: *const World) u64 {
        return canonical.hash(World, self);
    }
};

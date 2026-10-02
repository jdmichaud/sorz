//! The semantic traces (DESIGN.md V2): the world's events at each logic tick as JSON lines, in
//! the vocabulary and the format sor-remaster's observer writes (its docs/traces.md), so that one
//! comparison (`trace-compare`) reads both programs' traces.
//!
//! The world gives its events of a tick in its output (the draws, the blows, the pick-ups, the
//! sounds); the rest is what changed since the last tick: the entities that appeared and went,
//! their states, sides, health and places, the pads, the players' lives and scores, the camera.
//! The scene's layer tells the scene and play's phase (`startScene`, `setPhase`).
//!
//! A line is `{"v":V,"t":T,"ev":"KIND",...}`: `v` the display tick from power-on, `t` the scene's
//! tick (the logic tick in play), then the event's fields; fields whose name starts with `_` are
//! the writer's own (the entity's place in the pool, the draws' names), which a comparison
//! ignores. The events of a tick come in the vocabulary's order of kinds, and within a kind by
//! entity id. Positions and speeds are in 1/65536 pixel, as the world keeps them.
const std = @import("std");
const content_entity = @import("../content/entity.zig");
const input = @import("../input.zig");
const fixed = @import("fixed.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const world_mod = @import("world.zig");
const output = @import("output.zig");
const behaviours = @import("behaviours.zig");

const Vec3 = fixed.Vec3;
const Handle = entity.Handle;
const World = world_mod.World;
const Kinds = kinds_mod.Kinds;
const Output = output.Output;
const Family = content_entity.Family;
const capacity = entity.capacity;

pub const format = "sor-trace";
pub const version = 1;

/// The ids the trace gives the players' entities; the others count from `first_id`.
const first_id = 3;

/// The families whose position is written every tick it changes.
fn sampled(f: Family) bool {
    return switch (f) {
        .player, .enemy, .boss, .projectile, .weapon, .item => true,
        else => false,
    };
}

/// The families whose states are written.
fn stated(f: Family) bool {
    return sampled(f) or f == .scenery;
}

/// The families with health and a side faced.
fn fighter(f: Family) bool {
    return f == .player or f == .enemy or f == .boss;
}

/// An entity as an observation saw it.
const Seen = struct {
    live: bool = false,
    generation: u16 = 0,
    id: u32 = 0,
    kind: entity.KindId = 0,
    family: Family = .effect,
    /// Its state's name (its behaviour's), if it has one.
    state: ?[]const u8 = null,
    left: bool = false,
    position: Vec3 = .zero,
    velocity: Vec3 = .zero,
    health: i16 = 0,

    fn moved(a: Seen, b: Seen) bool {
        return !a.position.eql(b.position) or !a.velocity.eql(b.velocity);
    }
};

pub const Writer = struct {
    w: *std.Io.Writer,
    seen: [capacity]Seen = @splat(.{}),
    next_id: u32 = first_id,
    first: bool = true,
    /// The last observation's display tick and scene tick, and the events written.
    v: u64 = 0,
    t: u64 = 0,
    events: u64 = 0,
    /// A scene told since the last observation, which the next writes first.
    scene: ?Scene = null,
    phase: ?[]const u8 = null,
    phase_told: bool = false,
    pads: [2]input.Pad = .{ .{}, .{} },
    lives: [2][2]u8 = .{ .{ 0, 0 }, .{ 0, 0 } },
    scores: [2]u32 = .{ 0, 0 },
    camera: [2]i32 = .{ 0, 0 },
    camera_stop: [3]i32 = .{ 0, 0, 0 },
    section: u8 = 0,

    pub const Scene = struct {
        name: []const u8,
        /// A round's scenes: the round (1 to 8), and whether it is the attract demo.
        round: ?u8 = null,
        demo: bool = false,
    };

    pub fn init(w: *std.Io.Writer) Writer {
        return .{ .w = w };
    }

    /// The trace's first line: `start` is `power-on`, or `reference` for a run started from a
    /// recorded state.
    pub fn begin(self: *Writer, start: []const u8) std.Io.Writer.Error!void {
        try self.w.print("{{\"ev\":\"begin\",\"format\":\"{s}\",\"version\":{d},\"program\":\"sorz\",\"fixed\":{d},\"start\":\"{s}\"}}\n", .{ format, version, fixed.Fixed.frac_bits, start });
    }

    /// The trace's last line: where the run stopped, and the events written.
    pub fn end(self: *Writer) std.Io.Writer.Error!void {
        var l = try self.line("end");
        try l.int("events", self.events);
        try l.close();
    }

    /// A scene begins: written with the next observation, whose scene tick is then 0.
    pub fn startScene(self: *Writer, scene: Scene) void {
        self.scene = scene;
    }

    /// Play's phase (`intro`, `play`, `paused`...): written with the next observation when it
    /// changed.
    pub fn setPhase(self: *Writer, phase: []const u8) void {
        if (self.phase) |p| if (std.mem.eql(u8, p, phase)) return;
        self.phase = phase;
        self.phase_told = true;
    }

    /// One observation at the end of a logic tick, at display tick `v`: the tick's events.
    pub fn observe(self: *Writer, v: u64, world: *const World, kinds: *const Kinds, out: *const Output) std.Io.Writer.Error!void {
        self.v = v;
        if (self.scene) |s| {
            self.t = 0;
            var l = try self.line("scene");
            try l.str("scene", s.name);
            if (s.round) |r| {
                try l.int("round", r);
                try l.boolean("demo", s.demo);
            }
            try l.close();
            self.scene = null;
        } else if (!self.first) self.t += 1;

        if (self.phase_told) {
            self.phase_told = false;
            var l = try self.line("phase");
            try l.str("phase", self.phase.?);
            try l.close();
        }

        for (world.players, 0..) |p, k| {
            if (!self.first and p.last == self.pads[k]) continue;
            self.pads[k] = p.last;
            var l = try self.line("pad");
            try l.int("pad", k + 1);
            var buf: [8]u8 = undefined;
            try l.str("held", letters(p.last, &buf));
            try l.close();
        }

        try self.draws(out);
        try self.entities(world, kinds, out);

        for (world.players, 0..) |p, k| {
            const now = [2]u8{ p.lives, p.specials };
            if (self.first or !std.mem.eql(u8, &now, &self.lives[k])) {
                self.lives[k] = now;
                var l = try self.line("lives");
                try l.int("player", k + 1);
                try l.int("lives", p.lives);
                try l.int("specials", p.specials);
                try l.close();
            }
        }
        for (world.players, 0..) |p, k| {
            if (!self.first and p.score == self.scores[k]) continue;
            self.scores[k] = p.score;
            var l = try self.line("score");
            try l.int("player", k + 1);
            try l.int("score", p.score);
            try l.close();
        }

        const c = world.camera;
        const cam = [2]i32{ c.x.raw, c.y.raw };
        if (self.first or !std.mem.eql(i32, &cam, &self.camera)) {
            self.camera = cam;
            var l = try self.line("camera");
            try l.int("x", cam[0]);
            try l.int("y", cam[1]);
            try l.close();
        }
        const stop = [3]i32{ c.x_max.raw, c.y_min.raw, c.y_max.raw };
        if (self.first or !std.mem.eql(i32, &stop, &self.camera_stop)) {
            self.camera_stop = stop;
            var l = try self.line("camera_stop");
            try l.int("x", stop[0]);
            try l.int("y_min", stop[1]);
            try l.int("y_max", stop[2]);
            try l.close();
        }
        if (self.first or world.script.section != self.section) {
            self.section = world.script.section;
            var l = try self.line("section");
            try l.int("section", self.section);
            try l.close();
        }

        for (out.sounds.slice()) |s| {
            var l = try self.line("sound");
            try l.str("sound", s.name);
            try l.close();
        }
        self.first = false;
    }

    /// The generator's draws of the tick: their count, the first values, and their names.
    fn draws(self: *Writer, out: *const Output) !void {
        const d = &out.draws;
        if (d.count == 0 and !d.reseeded) return;
        var l = try self.line("rng");
        try l.int("draws", d.count);
        const kept = @min(d.count, d.values.len);
        try l.key("values");
        try l.w.writeByte('[');
        for (d.values[0..kept], 0..) |v, i| {
            if (i != 0) try l.w.writeByte(',');
            try l.w.print("{d}", .{v});
        }
        try l.w.writeByte(']');
        if (d.reseeded) try l.boolean("reseed", true);
        try l.key("_draws");
        try l.w.writeByte('[');
        for (d.purposes[0..kept], 0..) |p, i| {
            if (i != 0) try l.w.writeByte(',');
            try writeString(l.w, p);
        }
        try l.w.writeByte(']');
        try l.close();
    }

    /// The entities: those that went, those that appeared, those whose kind changed, then the
    /// going-on ones' states, the blows they took, their health, the pick-ups and their places.
    fn entities(self: *Writer, world: *const World, kinds: *const Kinds, out: *const Output) !void {
        var now: [capacity]Seen = @splat(.{});
        for (&world.entities, 0..) |*e, i| {
            const kind = e.kind orelse continue;
            const k = kinds.get(kind);
            now[i] = .{
                .live = true,
                .generation = e.generation,
                .kind = kind,
                .family = k.family(),
                .state = behaviours.stateName(&e.mind),
                .left = e.facingLeft(),
                .position = e.position,
                .velocity = e.velocity,
                .health = e.health,
            };
        }
        var removed: [capacity]bool = @splat(false);
        var spawned: [capacity]bool = @splat(false);
        var morphed: [capacity]bool = @splat(false);
        for (&self.seen, &now, 0..) |was, *is, i| {
            const same = was.live and is.live and was.generation == is.generation;
            removed[i] = was.live and !same;
            spawned[i] = is.live and !same;
            if (same) {
                is.id = was.id;
                morphed[i] = is.kind != was.kind;
            }
        }
        // New ids: the players' entities have theirs; the others in the order of their kind's
        // name, then their place, so that the order does not depend on the pool.
        var order: [capacity]u8 = undefined;
        var n: usize = 0;
        for (0..capacity) |i| if (spawned[i]) {
            const h: Handle = .{ .index = @intCast(i), .generation = now[i].generation };
            if (world.playerOf(h)) |p| {
                now[i].id = @as(u32, p) + 1;
            } else {
                order[n] = @intCast(i);
                n += 1;
            }
        };
        const Ctx = struct { now: *const [capacity]Seen, kinds: *const Kinds };
        std.mem.sort(u8, order[0..n], Ctx{ .now = &now, .kinds = kinds }, struct {
            fn less(c: Ctx, a: u8, b: u8) bool {
                const ea = c.now[a];
                const eb = c.now[b];
                switch (std.mem.order(u8, c.kinds.get(ea.kind).name(), c.kinds.get(eb.kind).name())) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
                if (!ea.position.x.eql(eb.position.x)) return ea.position.x.lessThan(eb.position.x);
                if (!ea.position.depth.eql(eb.position.depth)) return ea.position.depth.lessThan(eb.position.depth);
                if (!ea.position.height.eql(eb.position.height)) return ea.position.height.lessThan(eb.position.height);
                return a < b;
            }
        }.less);
        for (order[0..n]) |i| {
            now[i].id = self.next_id;
            self.next_id += 1;
        }

        var ids: [capacity]u8 = undefined;
        for (byId(&ids, &removed, &self.seen)) |i| {
            var l = try self.line("remove");
            try l.int("e", self.seen[i].id);
            try l.str("kind", kinds.get(self.seen[i].kind).name());
            try l.close();
        }
        for (byId(&ids, &spawned, &now)) |i| {
            const e = now[i];
            var l = try self.line("spawn");
            try l.int("e", e.id);
            try l.str("kind", kinds.get(e.kind).name());
            if (world.playerOf(.{ .index = @intCast(i), .generation = e.generation })) |p| try l.int("player", @as(u32, p) + 1);
            try l.int("x", e.position.x.raw);
            try l.int("d", e.position.depth.raw);
            try l.int("h", e.position.height.raw);
            if (sampled(e.family)) {
                try l.int("vx", e.velocity.x.raw);
                try l.int("vd", e.velocity.depth.raw);
                try l.int("vh", e.velocity.height.raw);
            }
            if (stated(e.family) and e.state != null) try stateFields(&l, e);
            if (fighter(e.family)) try l.int("health", e.health);
            try l.int("_slot", i);
            try l.close();
        }
        for (byId(&ids, &morphed, &now)) |i| {
            var l = try self.line("morph");
            try l.int("e", now[i].id);
            try l.str("kind", kinds.get(now[i].kind).name());
            try l.str("from", kinds.get(self.seen[i].kind).name());
            try l.close();
        }
        var going: [capacity]bool = undefined;
        for (&going, now, spawned) |*g, e, s| g.* = e.live and !s;
        const on = byId(&ids, &going, &now);
        for (on) |i| {
            const e = now[i];
            const was = self.seen[i];
            if (!stated(e.family) or e.state == null) continue;
            const same_state = was.state != null and std.mem.eql(u8, was.state.?, e.state.?);
            if (same_state and (!fighter(e.family) or e.left == was.left) and !morphed[i]) continue;
            var l = try self.line("state");
            try l.int("e", e.id);
            try stateFields(&l, e);
            try l.close();
        }
        try self.hits(&now, out);
        for (on) |i| {
            const e = now[i];
            if (!fighter(e.family) or e.health == self.seen[i].health) continue;
            var l = try self.line("health");
            try l.int("e", e.id);
            try l.int("health", e.health);
            try l.int("delta", @as(i32, e.health) - self.seen[i].health);
            try l.close();
        }
        for (out.pickups.slice()) |p| {
            var l = try self.line("pickup");
            try self.idField(&l, "e", p.item, &now);
            try l.str("kind", kinds.get(p.kind).name());
            try self.idField(&l, "by", p.by, &now);
            try l.close();
        }
        for (on) |i| {
            const e = now[i];
            if (!sampled(e.family) or !e.moved(self.seen[i])) continue;
            var l = try self.line("pos");
            try l.int("e", e.id);
            try l.int("x", e.position.x.raw);
            try l.int("d", e.position.depth.raw);
            try l.int("h", e.position.height.raw);
            try l.int("vx", e.velocity.x.raw);
            try l.int("vd", e.velocity.depth.raw);
            try l.int("vh", e.velocity.height.raw);
            try l.close();
        }
        self.seen = now;
    }

    /// The blows that cost health, one line a fighter struck (the blows on it summed, the last
    /// striker named), by the struck one's id; `reaction` is the state it is in.
    fn hits(self: *Writer, now: *const [capacity]Seen, out: *const Output) !void {
        var damage: [capacity]i32 = @splat(0);
        var by: [capacity]?Handle = @splat(null);
        var struck: [capacity]bool = @splat(false);
        for (out.hits.slice()) |h| {
            if (h.damage <= 0) continue;
            const e = now[h.target.index];
            if (!e.live or e.generation != h.target.generation or !fighter(e.family)) continue;
            damage[h.target.index] += h.damage;
            by[h.target.index] = h.attacker;
            struck[h.target.index] = true;
        }
        var ids: [capacity]u8 = undefined;
        for (byId(&ids, &struck, now)) |i| {
            const e = now[i];
            var l = try self.line("hit");
            try l.int("e", e.id);
            if (by[i]) |a| try self.idField(&l, "by", a, now) else try l.nul("by");
            try l.int("damage", damage[i]);
            try l.int("health", e.health);
            try l.str("reaction", e.state orelse "");
            try l.close();
        }
    }

    /// The id of the entity `h` names, from this observation or the last; null when neither saw
    /// it.
    fn idField(self: *Writer, l: *Line, name: []const u8, h: Handle, now: *const [capacity]Seen) !void {
        const n = now[h.index];
        const was = self.seen[h.index];
        if (n.live and n.generation == h.generation) return l.int(name, n.id);
        if (was.live and was.generation == h.generation) return l.int(name, was.id);
        try l.nul(name);
    }

    fn line(self: *Writer, ev: []const u8) std.Io.Writer.Error!Line {
        self.events += 1;
        try self.w.print("{{\"v\":{d},\"t\":{d},\"ev\":\"{s}\"", .{ self.v, self.t, ev });
        return .{ .w = self.w };
    }
};

/// The places marked in `marks`, by their entity's id.
fn byId(out: *[capacity]u8, marks: *const [capacity]bool, seen: *const [capacity]Seen) []const u8 {
    var n: usize = 0;
    for (marks, 0..) |m, i| if (m) {
        out[n] = @intCast(i);
        n += 1;
    };
    std.mem.sort(u8, out[0..n], seen, struct {
        fn less(s: *const [capacity]Seen, a: u8, b: u8) bool {
            return s[a].id < s[b].id;
        }
    }.less);
    return out[0..n];
}

fn stateFields(l: *Line, e: Seen) !void {
    try l.str("state", e.state.?);
    if (fighter(e.family)) try l.str("facing", if (e.left) "left" else "right");
}

/// A pad's held buttons as letters, in the order U D L R A B C S.
fn letters(pad: input.Pad, buf: *[8]u8) []const u8 {
    const order = [_]struct { button: input.Button, letter: u8 }{
        .{ .button = .up, .letter = 'U' },   .{ .button = .down, .letter = 'D' },
        .{ .button = .left, .letter = 'L' }, .{ .button = .right, .letter = 'R' },
        .{ .button = .a, .letter = 'A' },    .{ .button = .b, .letter = 'B' },
        .{ .button = .c, .letter = 'C' },    .{ .button = .start, .letter = 'S' },
    };
    var n: usize = 0;
    for (order) |b| if (pad.held(b.button)) {
        buf[n] = b.letter;
        n += 1;
    };
    return buf[0..n];
}

fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// One event's line, its fields written in order.
const Line = struct {
    w: *std.Io.Writer,

    fn key(self: *Line, name: []const u8) !void {
        try self.w.print(",\"{s}\":", .{name});
    }

    fn int(self: *Line, name: []const u8, v: anytype) !void {
        try self.key(name);
        try self.w.print("{d}", .{v});
    }

    fn str(self: *Line, name: []const u8, v: []const u8) !void {
        try self.key(name);
        try writeString(self.w, v);
    }

    fn boolean(self: *Line, name: []const u8, v: bool) !void {
        try self.key(name);
        try self.w.writeAll(if (v) "true" else "false");
    }

    fn nul(self: *Line, name: []const u8) !void {
        try self.key(name);
        try self.w.writeAll("null");
    }

    fn close(self: *Line) !void {
        try self.w.writeAll("}\n");
    }
};

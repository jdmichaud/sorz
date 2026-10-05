//! Scenarios (sor-remaster's docs/scenarios.md, the same files): a start that reaches a
//! situation, then a script of timed pad events in the game's terms, which the agent host runs
//! (`--scenario FILE`) and traces (`--trace-events`, `--probe`). The runner decides each logic
//! tick's pads from the script and from what the world shows; it reads the world and never
//! writes it, so that a scenario's run is a run of the game with those pads.
//!
//! The start: until the round's scene plays round 1 from its content (PLAN items 08 and 13),
//! `start CHARACTER` takes up round 1 where another program's trace was when its play began
//! (`--situation TRACE`, sor-remaster's trace of the same scenario: DESIGN.md decision D14, a
//! converted starting state): the camera, the ground, the player dropping in, the enemies that
//! wait for their turn, with the trace's ids. The script then runs from the next tick, as in
//! sor-remaster, whose script's tick 0 is the tick after play's phase began.
const std = @import("std");
const sorz = @import("sorz");
const world = sorz.world;
const input = sorz.input;
const content = sorz.content;

/// A button by its use in play (the default controls: B attacks, C jumps, A is the special
/// attack), by its bit in `input.Pad`.
pub const Button = enum(u3) {
    up = 0,
    down = 1,
    left = 2,
    right = 3,
    special = 4,
    attack = 5,
    jump = 6,
    start = 7,
};

comptime {
    for (std.enums.values(Button)) |b| {
        const pad_name = switch (b) {
            .special => "a",
            .attack => "b",
            .jump => "c",
            else => @tagName(b),
        };
        std.debug.assert(@bitOffsetOf(input.Pad, pad_name) == @backingInt(b));
    }
}

pub const Start = union(enum) {
    /// One player (or two) of these characters, from the start of play in round 1.
    players: struct { first: []const u8, second: ?[]const u8 },
    /// A recorded play's pads (a line per display tick from power-on: pad 1's and pad 2's
    /// buttons in hexadecimal, sor-remaster's `--pads` format), for its first `vblanks` display
    /// ticks; the file is named from the scenario's directory.
    pads: struct { path: []const u8, vblanks: u64 },
};

/// The pads of a recorded play's file (`start pads`); null for a malformed line.
pub fn parsePads(gpa: std.mem.Allocator, text: []const u8) !?[]input.Pads {
    var out: std.ArrayList(input.Pads) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const p1 = std.fmt.parseInt(u16, it.next() orelse return null, 16) catch return null;
        const p2 = std.fmt.parseInt(u16, it.next() orelse return null, 16) catch return null;
        if (it.next() != null) return null;
        try out.append(gpa, .{ .pad1 = @bitCast(@as(u8, @truncate(p1))), .pad2 = @bitCast(@as(u8, @truncate(p2))) });
    }
    return try out.toOwnedSlice(gpa);
}

/// Who a condition is about: an entity of the trace by its id, or any entity of a kind.
pub const Who = union(enum) {
    id: u32,
    kind: []const u8,
};

pub const max_states = 8;

pub const Condition = union(enum) {
    scene: []const u8,
    phase: []const u8,
    /// An entity in one of the states (or, negated, in none of them).
    state: struct { who: Who, states: [max_states][]const u8, count: u8, negate: bool },
    /// An entity of the kind, out of hiding and not knocked out, within `across` pixels of the
    /// pad's player across, and `depth` in depth (any when null).
    near: struct { kind: []const u8, across: i32, depth: ?i32, pad: u1 },
    /// The camera's left edge at or past `x` pixels.
    camera: i32,
};

pub const Command = struct {
    line: u32,
    op: union(enum) {
        /// The buttons held `ticks` ticks, then released for one: the script goes on after both.
        press: struct { pad: u1, buttons: u8, ticks: u32 },
        /// The buttons held from now (for `ticks` when given): the script goes on at once.
        hold: struct { pad: u1, buttons: u8, ticks: ?u32 },
        release: struct { pad: u1, buttons: u8 },
        wait: u32,
        until: struct { cond: Condition, within: u32 },
    },
};

pub const Diagnostic = struct {
    line: u32 = 0,
    message: []const u8 = "",
};

pub const Script = struct {
    start: Start,
    commands: []Command,

    pub fn deinit(self: *Script, gpa: std.mem.Allocator) void {
        gpa.free(self.commands);
    }
};

/// The longest wait of an `until` without `within`, in ticks.
pub const default_within = 3000;

/// The script of `text`, whose names point into `text` (it must outlive the script).
pub fn parse(gpa: std.mem.Allocator, text: []const u8, diag: *Diagnostic) !Script {
    var commands: std.ArrayList(Command) = .empty;
    errdefer commands.deinit(gpa);
    var start: ?Start = null;
    var pad: u1 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 0;
    while (lines.next()) |raw| {
        n += 1;
        const code = if (std.mem.indexOfScalar(u8, raw, '#')) |k| raw[0..k] else raw;
        var words: [8][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, code, " \t\r");
        while (it.next()) |word| {
            if (count == words.len) return refuse(diag, n, "too many words");
            words[count] = word;
            count += 1;
        }
        if (count == 0) continue;
        const w = words[0..count];
        if (std.mem.eql(u8, w[0], "start")) {
            if (start != null or commands.items.len != 0) return refuse(diag, n, "the start comes first, once");
            if (w.len == 4 and std.mem.eql(u8, w[1], "pads")) {
                start = .{ .pads = .{ .path = w[2], .vblanks = number(w[3]) orelse return refuse(diag, n, "`start pads FILE VBLANKS`") } };
                continue;
            }
            if (w.len < 2 or w.len > 3) return refuse(diag, n, "a start is `start CHARACTER [CHARACTER]` or `start pads FILE VBLANKS`");
            start = .{ .players = .{ .first = w[1], .second = if (w.len == 3) w[2] else null } };
            continue;
        }
        if (start == null) return refuse(diag, n, "the script begins with its start");
        if (std.mem.eql(u8, w[0], "pad")) {
            if (count != 2) return refuse(diag, n, "`pad 1` or `pad 2`");
            pad = if (std.mem.eql(u8, w[1], "1")) 0 else if (std.mem.eql(u8, w[1], "2")) 1 else return refuse(diag, n, "`pad 1` or `pad 2`");
            continue;
        }
        if (std.mem.eql(u8, w[0], "wait")) {
            if (count != 2) return refuse(diag, n, "`wait TICKS`");
            const t = number(w[1]) orelse return refuse(diag, n, "a wait is a number of ticks");
            try commands.append(gpa, .{ .line = n, .op = .{ .wait = t } });
            continue;
        }
        if (std.mem.eql(u8, w[0], "until")) {
            var rest = w[1..];
            var within: u32 = default_within;
            if (rest.len >= 2 and std.mem.eql(u8, rest[rest.len - 2], "within")) {
                within = number(rest[rest.len - 1]) orelse return refuse(diag, n, "`within TICKS`");
                rest = rest[0 .. rest.len - 2];
            }
            const cond = parseCondition(rest, pad) orelse return refuse(diag, n, "a condition is `scene NAME`, `phase NAME`, `state WHO STATE[|STATE...]` (`!` before: none of them), `near KIND PIXELS [DEPTH]` or `camera PIXELS`");
            try commands.append(gpa, .{ .line = n, .op = .{ .until = .{ .cond = cond, .within = within } } });
            continue;
        }
        const first = w[0];
        const kind: enum { press, hold, release } = if (first[0] == '+') .hold else if (first[0] == '-') .release else .press;
        const list = if (kind == .press) first else first[1..];
        const buttons = parseButtons(list) orelse return refuse(diag, n, "an unknown command or button (up, down, left, right, attack, jump, special, start; joined by +)");
        if (count > 2 or (kind == .release and count != 1)) return refuse(diag, n, "`BUTTONS [TICKS]`, `+BUTTONS [TICKS]` or `-BUTTONS`");
        const ticks: ?u32 = if (count == 2) number(w[1]) orelse return refuse(diag, n, "a number of ticks") else null;
        if (ticks != null and ticks.? == 0) return refuse(diag, n, "at least one tick");
        try commands.append(gpa, .{ .line = n, .op = switch (kind) {
            .press => .{ .press = .{ .pad = pad, .buttons = buttons, .ticks = ticks orelse 1 } },
            .hold => .{ .hold = .{ .pad = pad, .buttons = buttons, .ticks = ticks } },
            .release => .{ .release = .{ .pad = pad, .buttons = buttons } },
        } });
    }
    return .{ .start = start orelse return refuse(diag, n, "no start"), .commands = try commands.toOwnedSlice(gpa) };
}

fn refuse(diag: *Diagnostic, line: u32, message: []const u8) error{BadScenario} {
    diag.* = .{ .line = line, .message = message };
    return error.BadScenario;
}

fn number(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn parseButtons(text: []const u8) ?u8 {
    if (text.len == 0) return null;
    var bits: u8 = 0;
    var it = std.mem.splitScalar(u8, text, '+');
    while (it.next()) |name| {
        const b = std.meta.stringToEnum(Button, name) orelse return null;
        bits |= @as(u8, 1) << @backingInt(b);
    }
    return bits;
}

fn parseCondition(w: []const []const u8, pad: u1) ?Condition {
    if (w.len == 0) return null;
    if (std.mem.eql(u8, w[0], "scene") and w.len == 2) return .{ .scene = w[1] };
    if (std.mem.eql(u8, w[0], "phase") and w.len == 2) return .{ .phase = w[1] };
    if (std.mem.eql(u8, w[0], "camera") and w.len == 2) return .{ .camera = @intCast(number(w[1]) orelse return null) };
    if (std.mem.eql(u8, w[0], "near") and (w.len == 3 or w.len == 4)) {
        const across = number(w[2]) orelse return null;
        const depth: ?i32 = if (w.len == 4) @intCast(number(w[3]) orelse return null) else null;
        return .{ .near = .{ .kind = w[1], .across = @intCast(across), .depth = depth, .pad = pad } };
    }
    if (std.mem.eql(u8, w[0], "state") and w.len == 3) {
        const who: Who = if (number(w[1])) |id| .{ .id = id } else .{ .kind = w[1] };
        var list = w[2];
        const negate = list[0] == '!';
        if (negate) list = list[1..];
        var states: [max_states][]const u8 = undefined;
        var count: u8 = 0;
        var it = std.mem.splitScalar(u8, list, '|');
        while (it.next()) |name| {
            if (name.len == 0 or count == max_states) return null;
            states[count] = name;
            count += 1;
        }
        return .{ .state = .{ .who = who, .states = states, .count = count, .negate = negate } };
    }
    return null;
}

/// The script's body: the commands run at each tick's start, and the buttons they hold.
pub const Body = struct {
    commands: []const Command,
    /// The ticks since the body began, at the tick under way.
    now: u64 = 0,
    pc: usize = 0,
    resume_at: u64 = 0,
    waiting: ?struct { cond: Condition, deadline: u64, line: u32 } = null,
    /// By pad and button, the tick at which a hold ends (`forever` until released), or null.
    holds: [2][8]?u64 = @splat(@splat(null)),
    /// The line of the condition that did not come in time.
    timed_out: ?u32 = null,

    const forever = std.math.maxInt(u64);

    /// At the start of tick `now` (from 0, one more at each call): the commands due, then the
    /// pads to hold over the tick; null when the script is done (or a condition timed out).
    /// `holds_fn(ctx, cond)` tells whether a condition holds at the last tick's end.
    pub fn tick(self: *Body, ctx: anytype, comptime holds_fn: fn (@TypeOf(ctx), Condition) bool) ?input.Pads {
        for (&self.holds) |*pad| for (pad) |*h| {
            if (h.* != null and h.*.? <= self.now) h.* = null;
        };
        while (true) {
            if (self.waiting) |w| {
                if (!holds_fn(ctx, w.cond)) {
                    if (self.now >= w.deadline) {
                        self.timed_out = w.line;
                        return null;
                    }
                    break;
                }
                self.waiting = null;
            }
            if (self.now < self.resume_at) break;
            if (self.pc == self.commands.len) {
                if (self.timedHolds()) break;
                return null;
            }
            const c = self.commands[self.pc];
            self.pc += 1;
            switch (c.op) {
                .press => |p| {
                    self.set(p.pad, p.buttons, self.now + p.ticks);
                    self.resume_at = self.now + p.ticks + 1;
                },
                .hold => |h| self.set(h.pad, h.buttons, if (h.ticks) |t| self.now + t else forever),
                .release => |r| self.set(r.pad, r.buttons, null),
                .wait => |t| self.resume_at = self.now + t,
                .until => |u| self.waiting = .{ .cond = u.cond, .deadline = self.now + u.within, .line = c.line },
            }
        }
        const held = self.pads();
        self.now += 1;
        return held;
    }

    fn set(self: *Body, pad: u1, buttons: u8, until: ?u64) void {
        for (0..8) |b| if (buttons >> @intCast(b) & 1 != 0) {
            self.holds[pad][b] = until;
        };
    }

    fn timedHolds(self: *const Body) bool {
        for (self.holds) |pad| for (pad) |h| if (h != null and h.? != forever) return true;
        return false;
    }

    pub fn pads(self: *const Body) input.Pads {
        var bits: [2]u8 = .{ 0, 0 };
        for (self.holds, 0..) |pad, k| for (pad, 0..) |h, b| {
            if (h != null) bits[k] |= @as(u8, 1) << @intCast(b);
        };
        return .{ .pad1 = @bitCast(bits[0]), .pad2 = @bitCast(bits[1]) };
    }
};

// The situation ----------------------------------------------------------------------------------

/// Where a round's play began in another program's trace: its scene's ticks, the camera, and
/// each entity then (as the trace knows it: its kind, id, place, speed, state, side, health).
pub const Situation = struct {
    /// The display tick and the scene's tick of play's start.
    v: u64,
    t: u64,
    round: u8 = 1,
    camera: [2]i32 = .{ 0, 0 },
    camera_stop: [3]i32 = .{ 0, 0, 0 },
    lives: [2][2]u8 = .{ .{ 0, 0 }, .{ 0, 0 } },
    next_id: u32 = 3,
    entities: []const Seen,

    pub const Seen = struct {
        id: u32,
        kind: []const u8,
        player: ?u8 = null,
        position: [3]i32 = .{ 0, 0, 0 },
        velocity: [3]i32 = .{ 0, 0, 0 },
        state: ?[]const u8 = null,
        left: bool = false,
        health: ?i32 = null,
    };
};

/// The situation of a sor-trace at its round scene's first `phase play`: the events before it
/// (from power-on) replayed for what they say of the entities and the camera.
pub fn situationOf(arena: std.mem.Allocator, trace_text: []const u8) !Situation {
    var seen: std.AutoArrayHashMapUnmanaged(u32, Situation.Seen) = .empty;
    var s: Situation = .{ .v = 0, .t = 0, .entities = &.{} };
    var in_round = false;
    var lines = std.mem.splitScalar(u8, trace_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return error.BadTrace;
        if (v != .object) return error.BadTrace;
        const o = v.object;
        const ev = str(o, "ev") orelse return error.BadTrace;
        if (std.mem.eql(u8, ev, "begin")) continue;
        if (std.mem.eql(u8, ev, "end")) break;
        if (std.mem.eql(u8, ev, "scene")) {
            in_round = std.mem.eql(u8, str(o, "scene") orelse "", "round");
            if (in_round) s.round = @intCast(int(o, "round") orelse 1);
        } else if (std.mem.eql(u8, ev, "spawn")) {
            const e: u32 = @intCast(int(o, "e") orelse return error.BadTrace);
            try seen.put(arena, e, .{
                .id = e,
                .kind = try arena.dupe(u8, str(o, "kind") orelse return error.BadTrace),
                .player = if (int(o, "player")) |p| @intCast(p) else null,
                .position = .{ @intCast(int(o, "x") orelse 0), @intCast(int(o, "d") orelse 0), @intCast(int(o, "h") orelse 0) },
                .velocity = .{ @intCast(int(o, "vx") orelse 0), @intCast(int(o, "vd") orelse 0), @intCast(int(o, "vh") orelse 0) },
                .state = if (str(o, "state")) |x| try arena.dupe(u8, x) else null,
                .left = if (str(o, "facing")) |f| std.mem.eql(u8, f, "left") else false,
                .health = if (int(o, "health")) |h| @intCast(h) else null,
            });
            s.next_id = @max(s.next_id, e + 1);
        } else if (std.mem.eql(u8, ev, "remove")) {
            _ = seen.orderedRemove(@intCast(int(o, "e") orelse return error.BadTrace));
        } else if (std.mem.eql(u8, ev, "morph")) {
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            x.kind = try arena.dupe(u8, str(o, "kind") orelse return error.BadTrace);
        } else if (std.mem.eql(u8, ev, "state")) {
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            x.state = try arena.dupe(u8, str(o, "state") orelse return error.BadTrace);
            if (str(o, "facing")) |f| x.left = std.mem.eql(u8, f, "left");
        } else if (std.mem.eql(u8, ev, "pos")) {
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            x.position = .{ @intCast(int(o, "x") orelse 0), @intCast(int(o, "d") orelse 0), @intCast(int(o, "h") orelse 0) };
            x.velocity = .{ @intCast(int(o, "vx") orelse 0), @intCast(int(o, "vd") orelse 0), @intCast(int(o, "vh") orelse 0) };
        } else if (std.mem.eql(u8, ev, "health")) {
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            x.health = @intCast(int(o, "health") orelse 0);
        } else if (std.mem.eql(u8, ev, "camera")) {
            s.camera = .{ @intCast(int(o, "x") orelse 0), @intCast(int(o, "y") orelse 0) };
        } else if (std.mem.eql(u8, ev, "camera_stop")) {
            s.camera_stop = .{ @intCast(int(o, "x") orelse 0), @intCast(int(o, "y_min") orelse 0), @intCast(int(o, "y_max") orelse 0) };
        } else if (std.mem.eql(u8, ev, "lives")) {
            const p: usize = @intCast((int(o, "player") orelse 1) - 1);
            if (p < 2) s.lives[p] = .{ @intCast(int(o, "lives") orelse 0), @intCast(int(o, "specials") orelse 0) };
        } else if (std.mem.eql(u8, ev, "phase")) {
            if (in_round and std.mem.eql(u8, str(o, "phase") orelse "", "play")) {
                s.v = @intCast(int(o, "v") orelse 0);
                s.t = @intCast(int(o, "t") orelse 0);
                s.entities = try arena.dupe(Situation.Seen, seen.values());
                return s;
            }
        }
    }
    return error.NoPlay;
}

fn str(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(o: std.json.ObjectMap, name: []const u8) ?i64 {
    const v = o.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

// The run ----------------------------------------------------------------------------------------

/// The ground's height in round 1 (the trace's h of a fighter standing), until the round's floor
/// comes from its content (PLAN item 13).
const round_ground = 160;

/// A scenario's run: the world taken up from the situation, its ticks with the script's pads,
/// the trace and the probe written at each tick's end.
pub const Run = struct {
    gpa: std.mem.Allocator,
    kinds: *const world.Kinds,
    play: world.Play = .{},
    random: world.Random = .{},
    out: world.Output = .{},
    body: Body,
    trace: ?*world.trace.Writer,
    probe: ?*Probe,
    v: u64,
    t: u64,
    /// The trace ids of the entities, by their place in the world (the situation's, then the
    /// trace's own), for the conditions.
    ids: [world.entity.capacity]u32 = @splat(0),
    /// What stopped the run before the script's end, and the kinds the situation had that the
    /// content does not.
    failure: ?[]const u8 = null,
    skipped: std.ArrayList([]const u8) = .empty,
    /// The script's tick 0's display tick.
    script_v: u64,

    pub fn init(gpa: std.mem.Allocator, kinds: *const world.Kinds, script: *const Script, situation: *const Situation, trace: ?*world.trace.Writer, probe: ?*Probe) !Run {
        var r: Run = .{
            .gpa = gpa,
            .kinds = kinds,
            .body = .{ .commands = script.commands },
            .trace = trace,
            .probe = probe,
            .v = situation.v,
            .t = situation.t,
            .script_v = situation.v,
        };
        const w = &r.play.world;
        w.ground = .pixels(round_ground);
        w.camera = .{
            .x = .of(situation.camera[0]),
            .y = .of(situation.camera[1]),
            .x_min = .of(situation.camera[0]),
            .x_max = .of(situation.camera_stop[0]),
            .y_min = .of(situation.camera_stop[1]),
            .y_max = .of(situation.camera_stop[2]),
            .follows = true,
        };
        if (script.start != .players) return error.NoPlayers;
        const players = script.start.players;
        for (situation.entities) |e| {
            var kind_name = e.kind;
            if (e.player) |p| {
                // The trace names a player by its character; the script chose it.
                kind_name = if (p == 1) players.first else players.second orelse e.kind;
            }
            const kind = kinds.find(kind_name) orelse {
                try r.skipped.append(gpa, e.kind);
                continue;
            };
            const h = try w.spawn(kinds, kind, .{ .x = .of(e.position[0]), .depth = .of(e.position[1]), .height = .of(e.position[2]) }, if (e.left) .left else .right);
            const x = w.get(h).?;
            x.velocity = .{ .x = .of(e.velocity[0]), .depth = .of(e.velocity[1]), .height = .of(e.velocity[2]) };
            if (x.position.height.lessThan(w.ground)) x.flags.airborne = true;
            if (e.health) |hp| x.health = @intCast(hp);
            if (e.state) |st| _ = world.behaviours.setState(&x.mind, st);
            if (e.player) |p| {
                w.players[p - 1] = .{ .entity = h, .lives = situation.lives[p - 1][0], .specials = situation.lives[p - 1][1] };
            }
            r.ids[h.index] = e.id;
            if (trace) |tw| tw.assignId(h.index, h.generation, e.id);
            var t: world.tick.Tick = .{ .world = w, .kinds = kinds, .random = &r.random, .out = &r.out };
            t.takeUp(h);
        }
        if (trace) |tw| {
            tw.next_id = situation.next_id;
            tw.takeUpScene(.{ .name = "round", .round = situation.round }, situation.t);
            tw.setPhase("play");
            try tw.observe(r.v, w, kinds, &r.out);
        }
        if (probe) |p| try p.observe(r.v, r.t, w, kinds, &r.ids);
        return r;
    }

    pub fn deinit(self: *Run) void {
        self.skipped.deinit(self.gpa);
    }

    /// One logic tick: the script's pads, the world's tick, the observations. False when the
    /// script is done.
    pub fn step(self: *Run) !bool {
        const pads = self.body.tick(self, holds) orelse {
            if (self.body.timed_out != null) self.failure = "a condition did not come in time";
            return false;
        };
        // The pads are held over both display ticks of the logic tick.
        _ = self.play.displayTick(self.kinds, &self.random, pads, &self.out);
        _ = self.play.displayTick(self.kinds, &self.random, pads, &self.out);
        self.v += 2;
        self.t += 1;
        const w = &self.play.world;
        if (self.trace) |tw| {
            tw.setPhase(if (w.special) "special" else "play");
            try tw.observe(self.v, w, self.kinds, &self.out);
        }
        self.noteIds();
        if (self.probe) |p| try p.observe(self.v, self.t, w, self.kinds, &self.ids);
        return true;
    }

    /// The ids of entities new at this tick: the trace's, or in order of their places.
    fn noteIds(self: *Run) void {
        const w = &self.play.world;
        for (&w.entities, 0..) |*e, i| {
            if (!e.alive()) {
                self.ids[i] = 0;
                continue;
            }
            if (self.ids[i] != 0) continue;
            const h = w.handleAt(i).?;
            self.ids[i] = if (self.trace) |tw| tw.idOf(i, e.generation) orelse 0 else 0;
            if (self.ids[i] == 0) if (w.playerOf(h)) |p| {
                self.ids[i] = @as(u32, p) + 1;
            };
        }
    }

    fn holds(self: *Run, c: Condition) bool {
        const w = &self.play.world;
        switch (c) {
            .scene => |name| return std.mem.eql(u8, name, "round"),
            .phase => |name| return std.mem.eql(u8, name, if (w.special) "special" else "play"),
            .camera => |x| return w.camera.x.whole() >= x,
            .state => |st| {
                for (&w.entities, 0..) |*e, i| {
                    if (!e.alive() or !self.is(i, e, st.who)) continue;
                    const now = world.behaviours.stateName(&e.mind) orelse continue;
                    var found = false;
                    for (st.states[0..st.count]) |name| found = found or std.mem.eql(u8, name, now);
                    if (found != st.negate) return true;
                }
                return false;
            },
            .near => |nr| {
                const ph = w.players[nr.pad].entity orelse return false;
                const p = w.getConst(ph) orelse return false;
                for (&w.entities, 0..) |*e, i| {
                    if (!e.alive() or !self.is(i, e, .{ .kind = nr.kind })) continue;
                    const now = world.behaviours.stateName(&e.mind) orelse "";
                    if (std.mem.eql(u8, now, "appear") or std.mem.eql(u8, now, "knocked_out")) continue;
                    const dx = @abs(e.position.x.whole() - p.position.x.whole());
                    const dd = @abs(e.position.depth.whole() - p.position.depth.whole());
                    if (dx <= nr.across and (nr.depth == null or dd <= nr.depth.?)) return true;
                }
                return false;
            },
        }
    }

    fn is(self: *const Run, i: usize, e: *const world.Entity, who: Who) bool {
        return switch (who) {
            .id => |id| self.ids[i] == id,
            .kind => |k| std.mem.eql(u8, self.kinds.get(e.kind.?).name(), k),
        };
    }
};

// The probe --------------------------------------------------------------------------------------

/// The probe (sor-remaster's docs/scenarios.md): a JSON line per fighter whose frame or boxes
/// changed since its last line, at each tick's end: `anim` (the animation's name), `frame`,
/// `atk` and `body` (the boxes as [x from, x to, depth from, depth to, height from, height to]
/// from its place, facing as it faces), and `power` (a player's: the damage its blow does now;
/// another's: the damage its blows do).
pub const Probe = struct {
    w: *std.Io.Writer,
    last: [world.entity.capacity]?Line = @splat(null),

    const Line = struct {
        id: u32,
        anim: ?u8,
        frame: u8,
        atk: ?[6]i16,
        body: ?[6]i16,
        power: i16,

        fn eql(a: Line, b: Line) bool {
            return a.id == b.id and a.anim == b.anim and a.frame == b.frame and std.meta.eql(a.atk, b.atk) and std.meta.eql(a.body, b.body) and a.power == b.power;
        }
    };

    pub fn observe(self: *Probe, v: u64, t: u64, w: *const world.World, kinds: *const world.Kinds, ids: *const [world.entity.capacity]u32) !void {
        for (&w.entities, 0..) |*e, i| {
            if (!e.alive()) {
                self.last[i] = null;
                continue;
            }
            const k = kinds.get(e.kind.?);
            switch (k.family()) {
                .player, .enemy, .boss => {},
                else => continue,
            }
            const line: Line = .{
                .id = ids[i],
                .anim = e.animation.index,
                .frame = e.animation.frame,
                .atk = box(k, e, e.boxes.attack),
                .body = box(k, e, e.boxes.body),
                .power = power(k, e),
            };
            if (self.last[i]) |was| if (was.eql(line)) continue;
            self.last[i] = line;
            try self.w.print("{{\"v\":{d},\"t\":{d},\"e\":{d},\"anim\":", .{ v, t, line.id });
            if (line.anim) |a| try self.w.print("\"{s}\"", .{k.definition.animations[a].name}) else try self.w.writeAll("null");
            try self.w.print(",\"frame\":{d},\"atk\":", .{line.frame});
            try writeBox(self.w, line.atk);
            try self.w.writeAll(",\"body\":");
            try writeBox(self.w, line.body);
            try self.w.print(",\"power\":{d}}}\n", .{line.power});
        }
    }

    fn box(k: *const world.kinds.Kind, e: *const world.Entity, index: ?u8) ?[6]i16 {
        const b = &k.definition.boxes[index orelse return null];
        const x = b.across(e.boxes.mirrored);
        return .{ x.from, x.to, b.depth.from, b.depth.to, b.height.from, b.height.to };
    }

    /// A player's: the damage its blow does now; another's (an enemy's, as sor-remaster's
    /// probe gives it): the damage its blows do.
    fn power(k: *const world.kinds.Kind, e: *const world.Entity) i16 {
        if (k.family() != .player) {
            // Not yet out of hiding, it has no blows.
            if (std.mem.eql(u8, world.behaviours.stateName(&e.mind) orelse "", "appear")) return 0;
            var most: u16 = 0;
            for (k.definition.moves) |m| most = @max(most, m.damage);
            return @intCast(most);
        }
        const m = e.move orelse return 0;
        const index = e.animation.index orelse return 0;
        if (!k.definition.animations[index].frames[e.animation.frame].blow) return 0;
        return @intCast(k.definition.moves[m].damage);
    }

    fn writeBox(w: *std.Io.Writer, b: ?[6]i16) !void {
        const x = b orelse return w.writeAll("null");
        try w.print("[{d},{d},{d},{d},{d},{d}]", .{ x[0], x[1], x[2], x[3], x[4], x[5] });
    }
};

test "a script: its start, presses, holds, waits and conditions" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var s = try parse(gpa,
        \\# a comment
        \\start axel
        \\until state 1 ready
        \\+right
        \\until near galsia 75 8 within 40
        \\-right
        \\attack+jump 2
        \\wait 3
    , &diag);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings("axel", s.start.players.first);
    try std.testing.expectEqual(@as(usize, 6), s.commands.len);
    try std.testing.expectEqual(@as(u32, 40), s.commands[2].op.until.within);
    try std.testing.expectEqual(@as(u8, 0b0110_0000), s.commands[4].op.press.buttons);
    try std.testing.expectError(error.BadScenario, parse(gpa, "start axel\nkick\n", &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
}

test "the body: a press holds a tick and releases one; a hold lasts until released" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var s = try parse(gpa, "start axel\nattack\n+right\nwait 2\n-right\n", &diag);
    defer s.deinit(gpa);
    var b: Body = .{ .commands = s.commands };
    const never = struct {
        fn f(_: void, _: Condition) bool {
            return false;
        }
    }.f;
    var held: [6]u8 = undefined;
    for (&held) |*h| h.* = @bitCast((b.tick({}, never) orelse input.Pads{}).pad1);
    // B at tick 0, released at 1; right from 2 to 3, released at 4.
    try std.testing.expectEqualSlices(u8, &.{ 0b10_0000, 0, 0b1000, 0b1000, 0, 0 }, &held);
}

test "a recorded play's start: its pads by display tick, a malformed line refused" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var s = try parse(gpa, "start pads game.pads 31400\nwait 1\n", &diag);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings("game.pads", s.start.pads.path);
    try std.testing.expectEqual(@as(u64, 31400), s.start.pads.vblanks);
    const pads = (try parsePads(gpa, "000 000\n088 001\n\n")).?;
    defer gpa.free(pads);
    try std.testing.expectEqual(@as(usize, 2), pads.len);
    try std.testing.expect(pads[1].pad1.start and pads[1].pad1.right and pads[1].pad2.up);
    try std.testing.expectEqual(@as(?[]input.Pads, null), try parsePads(gpa, "000\n"));
}

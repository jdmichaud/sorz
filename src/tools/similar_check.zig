//! sorz-similar-check: the gate of Axel (PLAN items 05 and 11): his moves in sorz similar to the
//! original's (DESIGN.md V3), as sor-remaster (the original's logic, in lockstep with it) plays
//! them in the catalogue's scenarios.
//!
//!   sorz-similar-check ROM REMASTER_AGENT SCENARIOS_DIR OUT_DIR [SCENARIO...]
//!
//! For each scenario of `scenarios` below (its file SCENARIOS_DIR/NAME.scn; a family, whose
//! header says the values its `{N}` takes, is a run per value), sor-remaster's agent runs it from
//! power-on and writes its trace and probe into OUT_DIR; sorz runs it in this process, on the
//! content extracted from ROM, taken up from the reference's situation at play's start
//! (agent/scenario.zig), and writes its own. Then, per run:
//!
//! - the traces from that start (agent/trace_compare.zig), with what sorz does not have yet left
//!   out: the effects the special attack's stand-in car does not draw (`ignored_kinds`), the
//!   round's timer (PLAN item 13), and the speed up and down (`vh`): after a knock-down's last
//!   landing the original's Galsia keeps its last bounce's, which nothing reads, where sorz's
//!   landing clears it (the places it would move, compared, are equal);
//! - the probes, tick by tick: each fighter's boxes and power, the frame's index within its
//!   animation and the ticks frames start (where sorz composes an animation of another's frames,
//!   `composed`, its frames are taken as that other's);
//! - the catalogue's measurements of each move (its tools' m_player, m_combo, m_grab, m_hit),
//!   recomputed from both runs and compared within `Tolerance`s: the ticks of start-up, active
//!   and recovery, the states and their ticks, the damage, the health, the pushes and the arcs,
//!   the speeds, the boxes and the power equal; the special attack's times (its car a stand-in)
//!   within a tick.
//!
//! Prints a line per move, `equal`, `within tolerance` or `different`, with sorz's numbers (and
//! the reference's where they differ) and why; writes the same into OUT_DIR/report.txt; exits
//! with 1 when a move differs or a run fails.
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const extract = @import("extract");

const compare = agent.trace_compare;
const Event = compare.Event;
const json = std.json;

const Kind = enum { walk, jumps, jump_kick, jab, special, special_enemies, combo_chain, combo_window, grab, hit_stand };

const Scenario = struct {
    name: []const u8,
    kind: Kind,
    /// The move it measures, as the report names it (a family's runs all count for it).
    move: []const u8,
};

/// The catalogue's scenarios of Axel (sorz's copies in tests/scenarios/axel).
pub const scenarios = [_]Scenario{
    .{ .name = "player-walk-axel", .kind = .walk, .move = "walk" },
    .{ .name = "player-jumps-axel", .kind = .jumps, .move = "jump" },
    .{ .name = "player-jumpkick-axel", .kind = .jump_kick, .move = "jump kick" },
    .{ .name = "player-jumpkick-forward-axel", .kind = .jump_kick, .move = "jump kick, forward" },
    .{ .name = "player-jab-axel", .kind = .jab, .move = "jab and back attack" },
    .{ .name = "combo-chain-axel", .kind = .combo_chain, .move = "combo chain" },
    .{ .name = "combo-window-1-axel", .kind = .combo_window, .move = "combo window after blow 1" },
    .{ .name = "combo-window-2-axel", .kind = .combo_window, .move = "combo window after blow 2" },
    .{ .name = "combo-window-3-axel", .kind = .combo_window, .move = "combo window after blow 3" },
    .{ .name = "grab-knees-axel", .kind = .grab, .move = "grab: knees" },
    .{ .name = "grab-throw-axel", .kind = .grab, .move = "grab: throw" },
    .{ .name = "grab-vault-axel", .kind = .grab, .move = "grab: vault" },
    .{ .name = "grab-back_drop-axel", .kind = .grab, .move = "grab: back drop" },
    .{ .name = "grab-jump_back-axel", .kind = .grab, .move = "grab: jump back" },
    .{ .name = "grab-release-axel", .kind = .grab, .move = "grab: release" },
    .{ .name = "hit-stand-axel", .kind = .hit_stand, .move = "hurt, knocked down, getting up" },
    .{ .name = "player-special-axel", .kind = .special, .move = "special attack" },
    .{ .name = "player-special-enemies-axel", .kind = .special_enemies, .move = "special attack on enemies" },
};

/// The effects sorz's special attack does not draw (its car is a stand-in, PLAN item 11), and
/// the hit sparks (PLAN item 12): their events are left out of the traces' comparison.
const ignored_kinds = [_][]const u8{ "hit_spark", "police_car", "special_blast", "special_knockdown" };
const ignored_events = [_][]const u8{"timer"};
const ignored_fields = [_][]const u8{"vh"};

/// How far a measurement may be from the reference's and still be similar.
const Tolerance = enum {
    /// Equal: DESIGN.md V3's frame data, damage, pushes, speeds and arcs, and the rest.
    exact,
    /// The special attack's times: its car is a stand-in, timed from measurements.
    stand_in,

    fn within(t: Tolerance) f64 {
        return switch (t) {
            .exact => 0,
            .stand_in => 1,
        };
    }

    fn why(t: Tolerance) []const u8 {
        return switch (t) {
            .exact => "",
            .stand_in => "the special attack's car is a stand-in timed from measurements: 1 tick",
        };
    }
};

const Value = union(enum) {
    num: f64,
    text: []const u8,

    fn eql(a: Value, b: Value, within: f64) bool {
        return switch (a) {
            .num => |x| b == .num and @abs(x - b.num) <= within + 1e-9,
            .text => |x| b == .text and std.mem.eql(u8, x, b.text),
        };
    }

    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (v) {
            .num => |x| if (x == @round(x)) try w.print("{d}", .{@as(i64, @intFromFloat(x))}) else try w.print("{d:.4}", .{x}),
            .text => |s| try w.writeAll(s),
        }
    }
};

/// A measurement of a run: its name and values, and how near the reference's they must be.
const Measure = struct {
    what: []const u8,
    values: []const Value,
    tolerance: Tolerance = .exact,
};

const Measures = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Measure) = .empty,
    /// Put before each name (a family's run, a jump's label).
    prefix: []const u8 = "",

    fn add(m: *Measures, what: []const u8, values: []const Value, tolerance: Tolerance) !void {
        const name = if (m.prefix.len == 0) what else try std.fmt.allocPrint(m.arena, "{s} {s}", .{ m.prefix, what });
        try m.list.append(m.arena, .{ .what = name, .values = values, .tolerance = tolerance });
    }

    fn num(m: *Measures, what: []const u8, x: anytype) !void {
        try m.add(what, try m.arena.dupe(Value, &.{numValue(x)}), .exact);
    }

    fn numIn(m: *Measures, what: []const u8, x: anytype, tolerance: Tolerance) !void {
        try m.add(what, try m.arena.dupe(Value, &.{numValue(x)}), tolerance);
    }

    fn text(m: *Measures, what: []const u8, s: []const u8) !void {
        try m.add(what, try m.arena.dupe(Value, &.{.{ .text = s }}), .exact);
    }
};

fn numValue(x: anytype) Value {
    return switch (@typeInfo(@TypeOf(x))) {
        .float, .comptime_float => .{ .num = x },
        .bool => .{ .num = if (x) 1 else 0 },
        .optional => if (x) |y| numValue(y) else .{ .text = "none" },
        else => .{ .num = @floatFromInt(x) },
    };
}

/// A list of values, built.
const Values = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Value) = .empty,

    fn num(v: *Values, x: anytype) !void {
        try v.list.append(v.arena, numValue(x));
    }

    fn text(v: *Values, s: []const u8) !void {
        try v.list.append(v.arena, .{ .text = s });
    }

    fn box(v: *Values, b: ?Box) !void {
        if (b) |x| {
            for (x) |n| try v.num(n);
        } else try v.text("none");
    }
};

// Runs ------------------------------------------------------------------------------------------

const Box = [6]i64;

const ProbeLine = struct {
    v: i64,
    t: i64,
    e: i64,
    frame: ?i64,
    anim: []const u8,
    atk: ?Box,
    body: ?Box,
    power: i64,
};

/// A run's trace (its last round scene) and probe, sound names in the content's terms.
const Run = struct {
    arena: std.mem.Allocator,
    /// Every event of the trace, and those of the last round scene.
    all: []const Event,
    round: []const Event,
    /// The display tick the round scene began at, and its last tick.
    v0: i64,
    last: i64,
    probe: []const ProbeLine,

    fn load(arena: std.mem.Allocator, trace_text: []const u8, probe_text: []const u8, sound_names: []const compare.Rename) !Run {
        var diag: compare.Diagnostic = .{};
        const full = try compare.parse(arena, trace_text, &diag);
        const round = try compare.restrict(arena, &full, .{ .from_scene = "round", .sound_names = sound_names }, true);
        if (round.events.len == 0) return error.BadTrace;
        var last: i64 = 0;
        for (round.events) |e| last = @max(last, e.t);
        if (round.end) |end| last = @max(last, end.t);
        var probe: std.ArrayList(ProbeLine) = .empty;
        var lines = std.mem.splitScalar(u8, probe_text, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
            const v = try json.parseFromSliceLeaky(json.Value, arena, line, .{});
            if (v != .object) return error.BadProbe;
            const o = v.object;
            try probe.append(arena, .{
                .v = int(o, "v") orelse return error.BadProbe,
                .t = int(o, "t") orelse return error.BadProbe,
                .e = int(o, "e") orelse return error.BadProbe,
                .frame = int(o, "frame"),
                .anim = switch (o.get("anim") orelse .null) {
                    .string => |s| s,
                    .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
                    else => "",
                },
                .atk = boxOf(o.get("atk")),
                .body = boxOf(o.get("body")),
                .power = int(o, "power") orelse 0,
            });
        }
        return .{ .arena = arena, .all = full.events, .round = round.events, .v0 = round.events[0].v, .last = last, .probe = probe.items };
    }

    /// The ticks a button was newly held on pad 1 (`B`, `C`, `A`, `L`...).
    fn presses(r: *const Run, button: u8) ![]const i64 {
        var out: std.ArrayList(i64) = .empty;
        var held: []const u8 = "";
        for (r.round) |e| {
            if (!is(e, "pad") or int(e.object, "pad") != 1) continue;
            const now = str(e.object, "held") orelse "";
            if (std.mem.indexOfScalar(u8, now, button) != null and std.mem.indexOfScalar(u8, held, button) == null) try out.append(r.arena, e.t);
            held = now;
        }
        return out.items;
    }

    /// The round scene's events `ev` from tick `t0` to `t1`.
    fn events(r: *const Run, ev: []const u8, t0: i64, t1: i64) ![]const Event {
        var out: std.ArrayList(Event) = .empty;
        for (r.round) |e| if (is(e, ev) and e.t >= t0 and e.t <= t1) try out.append(r.arena, e);
        return out.items;
    }

    fn timeline(r: *const Run, e: i64) !Timeline {
        const ticks = try r.arena.alloc(?At, @intCast(r.last + 1));
        @memset(ticks, null);
        var cur: At = .{};
        var alive = false;
        for (r.probe) |p| if (p.e == e and p.v < r.v0) cur.see(p);
        // What the scenes before the round said of it (the players come in the round's intro).
        for (r.all) |x| {
            if (x.v >= r.v0) break;
            if (int(x.object, "e") == e) cur.apply(x, &alive);
        }
        var i: usize = 0;
        var j: usize = 0;
        while (j < r.probe.len and r.probe[j].v < r.v0) j += 1;
        var t: i64 = 0;
        while (t <= r.last) : (t += 1) {
            while (i < r.round.len and r.round[i].t <= t) : (i += 1) {
                const x = r.round[i];
                if (int(x.object, "e") == e) cur.apply(x, &alive);
            }
            while (j < r.probe.len and r.probe[j].t <= t) : (j += 1) {
                if (r.probe[j].e == e) cur.see(r.probe[j]);
            }
            if (alive) ticks[@intCast(t)] = cur;
        }
        return .{ .ticks = ticks };
    }
};

/// An entity at a tick's end: its state, place (pixels), health, frame and boxes.
const At = struct {
    state: []const u8 = "",
    facing: []const u8 = "",
    x: f64 = 0,
    d: f64 = 0,
    h: f64 = 0,
    health: ?i64 = null,
    anim: []const u8 = "",
    frame: ?i64 = null,
    atk: ?Box = null,
    body: ?Box = null,
    power: i64 = 0,

    /// What event `x` about it says.
    fn apply(a: *At, x: Event, alive: *bool) void {
        if (is(x, "spawn")) {
            alive.* = true;
            a.state = str(x.object, "state") orelse "";
            a.facing = str(x.object, "facing") orelse "";
            a.place(x.object);
            a.health = int(x.object, "health");
        } else if (is(x, "remove")) {
            alive.* = false;
        } else if (is(x, "state")) {
            a.state = str(x.object, "state") orelse "";
            a.facing = str(x.object, "facing") orelse "";
        } else if (is(x, "pos")) {
            a.place(x.object);
        } else if (is(x, "health")) {
            a.health = int(x.object, "health");
        }
    }

    fn place(a: *At, o: json.ObjectMap) void {
        a.x = pixels(int(o, "x") orelse 0);
        a.d = pixels(int(o, "d") orelse 0);
        a.h = pixels(int(o, "h") orelse 0);
    }

    fn see(a: *At, p: ProbeLine) void {
        a.anim = p.anim;
        a.frame = p.frame;
        a.atk = p.atk;
        a.body = p.body;
        a.power = p.power;
    }

    fn in(a: *const At, states: []const []const u8) bool {
        for (states) |s| if (std.mem.eql(u8, a.state, s)) return true;
        return false;
    }
};

const Timeline = struct {
    ticks: []const ?At,

    fn at(tl: *const Timeline, t: i64) ?*const At {
        if (t < 0 or t >= tl.ticks.len) return null;
        if (tl.ticks[@intCast(t)]) |*a| return a;
        return null;
    }

    /// The first tick from `t0` to `t1` whose state is (or, `in` false, is not) among `states`.
    fn first(tl: *const Timeline, t0: i64, t1: i64, states: []const []const u8, in: bool) ?i64 {
        var t = t0;
        while (t <= t1) : (t += 1) {
            const a = tl.at(t) orelse continue;
            if (a.in(states) == in) return t;
        }
        return null;
    }

    /// The ticks from `t0` while the state is among `states`: the last one.
    fn spanEnd(tl: *const Timeline, t0: i64, states: []const []const u8) ?i64 {
        const a = tl.at(t0) orelse return null;
        if (!a.in(states)) return null;
        var t = t0;
        while (tl.at(t + 1)) |n| {
            if (!n.in(states)) break;
            t += 1;
        }
        return t;
    }

    fn lastTick(tl: *const Timeline) i64 {
        var t: i64 = @intCast(tl.ticks.len);
        while (t > 0) {
            t -= 1;
            if (tl.ticks[@intCast(t)] != null) return t;
        }
        return 0;
    }
};

fn pixels(raw: i64) f64 {
    return @as(f64, @floatFromInt(raw)) / 65536.0;
}

fn round4(x: f64) f64 {
    return @round(x * 10000) / 10000;
}

fn is(e: Event, ev: []const u8) bool {
    return std.mem.eql(u8, e.ev, ev);
}

fn str(o: json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(o: json.ObjectMap, name: []const u8) ?i64 {
    const v = o.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn boxOf(v: ?json.Value) ?Box {
    const a = v orelse return null;
    if (a != .array or a.array.items.len != 6) return null;
    var out: Box = undefined;
    for (a.array.items, &out) |x, *o| o.* = if (x == .integer) x.integer else 0;
    return out;
}

// The measurements (the catalogue's tools) --------------------------------------------------------

const control = [_][]const u8{ "ready", "idle", "walk" };

fn measure(kind: Kind, r: *const Run, m: *Measures) !void {
    switch (kind) {
        .walk => try walk(r, m),
        .jumps => try jumps(r, m),
        .jump_kick => try jumpKick(r, m),
        .jab => try jab(r, m),
        .special => try special(r, m),
        .special_enemies => try specialOnEnemies(r, m),
        .combo_chain => try comboChain(r, m),
        .combo_window => try comboWindow(r, m),
        .grab => try grab(r, m),
        .hit_stand => try hitStand(r, m),
    }
}

/// Each direction held 8 ticks: whether the first tick moves, the distance across and in depth
/// in the 8 ticks, the stop at the release; the walk's reach (a box without power).
fn walk(r: *const Run, m: *Measures) !void {
    const tl = try r.timeline(1);
    const labels = [_][]const u8{ "right", "left", "up", "down", "up+right", "down+right", "up+left", "down+left" };
    var pads: std.ArrayList(i64) = .empty;
    for (r.round) |e| if (is(e, "pad") and int(e.object, "pad") == 1 and (str(e.object, "held") orelse @as([]const u8, "")).len != 0) try pads.append(r.arena, e.t);
    if (pads.items.len < labels.len) return error.Unmeasured;
    for (labels, pads.items[0..labels.len]) |label, t| {
        const s0 = tl.at(t) orelse return error.Unmeasured;
        const prev = tl.at(t - 1) orelse return error.Unmeasured;
        const s1 = tl.at(t + 7) orelse return error.Unmeasured;
        const after = tl.at(t + 8) orelse return error.Unmeasured;
        var v: Values = .{ .arena = r.arena };
        try v.num(s0.x != prev.x or s0.d != prev.d);
        try v.num(round4(s1.x - prev.x));
        try v.num(round4(s1.d - prev.d));
        try v.num(after.x == s1.x and after.d == s1.d);
        try v.text(s0.state);
        try m.add(try std.fmt.allocPrint(r.arena, "{s} (moves at once, dx and dd in 8 ticks, stops, state)", .{label}), v.list.items, .exact);
    }
    var t = pads.items[0];
    while (t < pads.items[0] + 8) : (t += 1) {
        const s = tl.at(t) orelse continue;
        if (s.atk == null) continue;
        var v: Values = .{ .arena = r.arena };
        try v.box(s.atk);
        try v.num(s.power);
        try m.add("reach box and power", v.list.items, .exact);
        break;
    }
}

const Arc = struct { crouch: i64, air: i64, landing: i64, total: i64, peak: f64, length: f64, dx: []const Value, height: []const Value };

fn jumpArc(r: *const Run, tl: *const Timeline, t_press: i64) !Arc {
    const crouch_end = tl.spanEnd(t_press, &.{"jump_crouch"}) orelse return error.Unmeasured;
    const t_air = crouch_end + 1;
    const air_end = tl.spanEnd(t_air, &.{ "jump", "jump_kick" }) orelse return error.Unmeasured;
    const t_land = air_end + 1;
    const land_end = tl.spanEnd(t_land, &.{"land"}) orelse return error.Unmeasured;
    const ground = tl.at(t_press - 1) orelse return error.Unmeasured;
    var dx: Values = .{ .arena = r.arena };
    var height: Values = .{ .arena = r.arena };
    var peak: f64 = 0;
    var t = t_air;
    while (t <= t_land) : (t += 1) {
        const s = tl.at(t) orelse return error.Unmeasured;
        try dx.num(round4(s.x - ground.x));
        try height.num(round4(ground.h - s.h));
        peak = @max(peak, round4(ground.h - s.h));
    }
    return .{
        .crouch = crouch_end - t_press + 1,
        .air = air_end - t_air + 1,
        .landing = land_end - t_land + 1,
        .total = land_end + 1 - t_press,
        .peak = peak,
        .length = round4((tl.at(t_land) orelse return error.Unmeasured).x - ground.x),
        .dx = dx.list.items,
        .height = height.list.items,
    };
}

/// The jumps in place, right and left: the crouch, the air and the landing's ticks, the peak, the
/// length and the arc.
fn jumps(r: *const Run, m: *Measures) !void {
    const tl = try r.timeline(1);
    const ps = try r.presses('C');
    const labels = [_][]const u8{ "in place", "right", "left" };
    if (ps.len < labels.len) return error.Unmeasured;
    for (labels, ps[0..labels.len]) |label, t| {
        const a = try jumpArc(r, &tl, t);
        m.prefix = label;
        try m.num("crouch ticks", a.crouch);
        try m.num("air ticks", a.air);
        try m.num("landing ticks", a.landing);
        try m.num("total ticks", a.total);
        try m.num("peak height", a.peak);
        try m.num("length across", a.length);
        try m.add("arc across", a.dx, .exact);
        try m.add("arc height", a.height, .exact);
    }
    m.prefix = "";
}

/// A jump, then B: the ticks from the jump's press of the kick, the landing and the control
/// back; the ticks with the kick's box, its boxes and power.
fn jumpKick(r: *const Run, m: *Measures) !void {
    const tl = try r.timeline(1);
    const cs = try r.presses('C');
    if (cs.len == 0) return error.Unmeasured;
    const tj = cs[0];
    const bs = try r.presses('B');
    const kick = tl.first(tj, tj + 60, &.{"jump_kick"}, true);
    const land = tl.first(tj + 1, tj + 60, &.{"land"}, true);
    const ready = if (land) |l| tl.first(l, l + 30, &control, true) else null;
    try m.num("B after the jump's press", if (bs.len != 0) bs[0] - tj else null);
    try m.num("kick tick", if (kick) |k| k - tj else null);
    try m.num("landing tick", if (land) |l| l - tj else null);
    try m.num("control tick", if (ready) |x| x - tj else null);
    var ticks: Values = .{ .arena = r.arena };
    var boxes: Values = .{ .arena = r.arena };
    if (kick) |k| if (land) |l| {
        var t = k;
        var last: ?Box = null;
        while (t < l) : (t += 1) {
            const s = tl.at(t) orelse continue;
            const b = s.atk orelse continue;
            try ticks.num(t - tj);
            if (last == null or !std.mem.eql(i64, &last.?, &b)) {
                try boxes.box(b);
                try boxes.num(s.power);
            }
            last = b;
        }
    };
    try m.add("box ticks", ticks.list.items, .exact);
    try m.add("boxes and power", boxes.list.items, .exact);
}

/// A move's frame data from its press: the ticks of its blow (a box with power), the start-up,
/// the recovery, the total until it ends (out of `states`, or back in control), its boxes.
fn frameData(r: *const Run, tl: *const Timeline, t_press: i64, states: ?[]const []const u8, m: *Measures) !i64 {
    const t_end = (if (states) |s| tl.first(t_press + 1, t_press + 80, s, false) else tl.first(t_press + 1, t_press + 80, &control, true)) orelse return error.Unmeasured;
    var first: ?i64 = null;
    var last: i64 = 0;
    var active: i64 = 0;
    var boxes: Values = .{ .arena = r.arena };
    var t = t_press;
    while (t < t_end) : (t += 1) {
        const s = tl.at(t) orelse continue;
        const b = s.atk orelse continue;
        if (s.power == 0) continue;
        if (first == null) {
            try boxes.box(b);
            try boxes.num(s.power);
        }
        first = first orelse t;
        last = t;
        active += 1;
    }
    try m.num("start-up ticks", if (first) |f| f - t_press else null);
    try m.num("active ticks", active);
    try m.num("recovery ticks", if (first != null) t_end - 1 - last else null);
    try m.num("total ticks", t_end - t_press);
    try m.text("ends in", (tl.at(t_end) orelse return error.Unmeasured).state);
    try m.add("first box and power", boxes.list.items, .exact);
    return t_end - t_press;
}

/// B alone, then B and C (the back attack): their frame data; the back attack's states, and its
/// arc when it leaves the ground.
fn jab(r: *const Run, m: *Measures) !void {
    const tl = try r.timeline(1);
    const pb = try r.presses('B');
    if (pb.len < 2) return error.Unmeasured;
    m.prefix = "jab:";
    _ = try frameData(r, &tl, pb[0], &.{"attack1"}, m);
    m.prefix = "back attack:";
    const total = try frameData(r, &tl, pb[1], null, m);
    var states: Values = .{ .arena = r.arena };
    var dx: Values = .{ .arena = r.arena };
    var height: Values = .{ .arena = r.arena };
    const base = tl.at(pb[1] - 1) orelse return error.Unmeasured;
    var state: []const u8 = "";
    var n: i64 = 0;
    var t = pb[1];
    while (t < pb[1] + total) : (t += 1) {
        const s = tl.at(t) orelse return error.Unmeasured;
        if (!std.mem.eql(u8, s.state, state)) {
            if (n != 0) {
                try states.text(state);
                try states.num(n);
            }
            state = s.state;
            n = 0;
        }
        n += 1;
        try dx.num(round4(s.x - base.x));
        try height.num(round4(base.h - s.h));
    }
    try states.text(state);
    try states.num(n);
    try m.add("states and ticks", states.list.items, .exact);
    try m.add("arc across", dx.list.items, .exact);
    try m.add("arc height", height.list.items, .exact);
    m.prefix = "";
}

/// A's press to play's end: the phase's start and length, the specials, the sounds by tick.
fn special(r: *const Run, m: *Measures) !void {
    const pa = try firstPress(r, 'A');
    const start = firstPhase(r, "special", pa - 1) orelse return error.Unmeasured;
    const end = firstPhase(r, "play", start) orelse return error.Unmeasured;
    try m.numIn("phase special from the press", start - pa, .stand_in);
    try m.numIn("phase special ticks", end - start, .stand_in);
    var before: ?i64 = null;
    var after: ?i64 = null;
    var after_t: ?i64 = null;
    var past_round = false;
    const round = lastRoundScene(r);
    for (r.all) |e| {
        if (e.scene == round) past_round = true;
        if (!is(e, "lives") or int(e.object, "player") != 1) continue;
        if (!past_round or e.t < pa) {
            before = int(e.object, "specials");
        } else if (after == null) {
            after = int(e.object, "specials");
            after_t = e.t - pa;
        }
    }
    try m.num("specials before", before);
    try m.num("specials after", after);
    try m.num("specials change tick", after_t);
    var ticks: Values = .{ .arena = r.arena };
    var names: Values = .{ .arena = r.arena };
    for (try r.events("sound", pa, end)) |e| {
        try ticks.num(e.t - pa);
        try names.text(str(e.object, "sound") orelse "");
    }
    try m.add("sounds' ticks", ticks.list.items, .stand_in);
    try m.add("sounds", names.list.items, .exact);
}

fn firstPress(r: *const Run, button: u8) !i64 {
    const ps = try r.presses(button);
    if (ps.len == 0) return error.Unmeasured;
    return ps[0];
}

fn lastRoundScene(r: *const Run) u32 {
    var s: u32 = 0;
    for (r.all) |e| if (is(e, "scene") and std.mem.eql(u8, str(e.object, "scene") orelse "", "round")) {
        s = e.scene;
    };
    return s;
}

fn firstPhase(r: *const Run, phase: []const u8, after: i64) ?i64 {
    for (r.round) |e| {
        if (is(e, "phase") and e.t > after and std.mem.eql(u8, str(e.object, "phase") orelse "", phase)) return e.t;
    }
    return null;
}

/// The special attack with Galsias near: the phase's length, their hits and states.
fn specialOnEnemies(r: *const Run, m: *Measures) !void {
    const pa = try firstPress(r, 'A');
    const end = firstPhase(r, "play", pa) orelse return error.Unmeasured;
    try m.numIn("phase ticks", end - pa, .stand_in);
    var hits: Values = .{ .arena = r.arena };
    var struck: std.ArrayList(i64) = .empty;
    for (try r.events("hit", pa, end + 60)) |h| {
        const e = int(h.object, "e") orelse continue;
        if (e == 1 or e == 2) continue;
        try hits.num(h.t - pa);
        try hits.num(e);
        try hits.num(int(h.object, "damage"));
        try hits.num(int(h.object, "health"));
        try hits.text(str(h.object, "reaction") orelse "");
        if (std.mem.indexOfScalar(i64, struck.items, e) == null) try struck.append(r.arena, e);
    }
    try m.add("hits (tick, entity, damage, health, reaction)", hits.list.items, .stand_in);
    for (struck.items) |e| {
        const tl = try r.timeline(e);
        var states: Values = .{ .arena = r.arena };
        var state: ?[]const u8 = null;
        var t = pa;
        while (t < end + 60) : (t += 1) {
            const s: []const u8 = if (tl.at(t)) |a| a.state else "gone";
            if (state == null or !std.mem.eql(u8, state.?, s)) {
                try states.text(s);
                try states.num(t - pa);
                state = s;
            }
        }
        try m.add(try std.fmt.allocPrint(r.arena, "entity {d}'s states from the press", .{e}), states.list.items, .stand_in);
    }
}

const attacks = [_][]const u8{ "attack1", "attack2", "attack3", "attack4", "back_attack" };

/// B every 2 ticks on the first Galsia: each blow's state, start, ticks, active ticks, box,
/// power and hits; the knock-down's arc.
fn comboChain(r: *const Run, m: *Measures) !void {
    const Blow = struct {
        state: []const u8,
        start: i64,
        end: i64,
        active: Values,
        hits: Values,
        box: ?Box = null,
        power: ?i64 = null,
    };
    const tl = try r.timeline(1);
    const ps = try r.presses('B');
    if (ps.len == 0) return error.Unmeasured;
    const hits = try r.events("hit", 0, r.last);
    var blows: std.ArrayList(Blow) = .empty;
    var target: ?i64 = null;
    var t = ps[0];
    while (t <= tl.lastTick()) : (t += 1) {
        const s = tl.at(t) orelse continue;
        const prev = tl.at(t - 1) orelse continue;
        const pressed = std.mem.indexOfScalar(i64, ps, t) != null;
        if (s.in(&attacks) and (!std.mem.eql(u8, prev.state, s.state) or (pressed and s.frame == 0 and prev.frame != 0))) {
            try blows.append(r.arena, .{ .state = s.state, .start = t, .end = t, .active = .{ .arena = r.arena }, .hits = .{ .arena = r.arena } });
        }
        if (blows.items.len == 0) continue;
        const cur = &blows.items[blows.items.len - 1];
        if (!std.mem.eql(u8, s.state, cur.state)) continue;
        if (s.atk != null and s.power != 0) {
            try cur.active.num(t - cur.start);
            cur.box = cur.box orelse s.atk;
            cur.power = cur.power orelse s.power;
        }
        for (hits) |h| {
            if (h.t != t or int(h.object, "by") != 1) continue;
            try cur.hits.num(t - cur.start);
            try cur.hits.num(int(h.object, "damage"));
            try cur.hits.num(int(h.object, "health"));
            try cur.hits.text(str(h.object, "reaction") orelse "");
            target = target orelse int(h.object, "e");
        }
        cur.end = t;
    }
    try m.num("blows", blows.items.len);
    for (blows.items, 1..) |*b, n| {
        var row: Values = .{ .arena = r.arena };
        try row.text(b.state);
        try row.num(b.start - blows.items[0].start);
        try row.num(b.end - b.start + 1);
        try row.box(b.box);
        try row.num(b.power);
        try m.add(try std.fmt.allocPrint(r.arena, "blow {d} (state, start, ticks, box, power)", .{n}), row.list.items, .exact);
        try m.add(try std.fmt.allocPrint(r.arena, "blow {d} active ticks", .{n}), b.active.list.items, .exact);
        try m.add(try std.fmt.allocPrint(r.arena, "blow {d} hits (tick, damage, health, reaction)", .{n}), b.hits.list.items, .exact);
    }
    const e = target orelse return;
    for (hits) |h| {
        if (int(h.object, "e") != e or !std.mem.eql(u8, str(h.object, "reaction") orelse "", "knocked_down")) continue;
        const gt = try r.timeline(e);
        const base = gt.at(h.t - 1) orelse return error.Unmeasured;
        try knockDownArc(r, m, &gt, h.t, "knock-down", base.x, 1, 160);
        break;
    }
}

/// The arc of a knock-down from tick `t0` while its state lasts: across from `x0` (times
/// `sign`) and the height above `h0`; then its ticks and the state after.
fn knockDownArc(r: *const Run, m: *Measures, tl: *const Timeline, t0: i64, what: []const u8, x0: f64, sign: f64, h0: f64) !void {
    var dx: Values = .{ .arena = r.arena };
    var height: Values = .{ .arena = r.arena };
    var t = t0;
    while (tl.at(t)) |s| : (t += 1) {
        if (!std.mem.eql(u8, s.state, "knocked_down")) break;
        try dx.num(round4(sign * (s.x - x0)));
        try height.num(round4(h0 - s.h));
    }
    try m.add(try std.fmt.allocPrint(r.arena, "{s} arc across", .{what}), dx.list.items, .exact);
    try m.add(try std.fmt.allocPrint(r.arena, "{s} arc height", .{what}), height.list.items, .exact);
    try m.num(try std.fmt.allocPrint(r.arena, "{s} ticks", .{what}), t - t0);
    try m.text(try std.fmt.allocPrint(r.arena, "{s} then", .{what}), if (tl.at(t)) |a| a.state else "gone");
}

/// Blows pressed once each, then B again N ticks after the last: the states the presses start,
/// the blows landed, the ticks from the last hit.
fn comboWindow(r: *const Run, m: *Measures) !void {
    const tl = try r.timeline(1);
    const ps = try r.presses('B');
    if (ps.len == 0) return error.Unmeasured;
    const last = ps[ps.len - 1];
    var states: Values = .{ .arena = r.arena };
    for (ps) |p| try states.text((tl.at(p) orelse return error.Unmeasured).state);
    try m.add("the presses' states", states.list.items, .exact);
    var landed: i64 = 0;
    var last_hit: ?i64 = null;
    for (try r.events("hit", 0, last - 1)) |h| {
        if (int(h.object, "by") != 1) continue;
        landed += 1;
        last_hit = h.t;
    }
    try m.num("blows landed", landed);
    try m.num("ticks from the last hit", if (last_hit) |h| last - h else null);
}

const Segment = struct { state: []const u8, from: i64, ticks: i64, bare: i64 };

/// The states from tick `t0` to `t1`: each with its first tick (from `t0`), its ticks, and its
/// ticks without a body box.
fn segments(r: *const Run, tl: *const Timeline, t0: i64, t1: i64) ![]const Segment {
    var out: std.ArrayList(Segment) = .empty;
    var t = t0;
    while (t <= t1) : (t += 1) {
        const a = tl.at(t);
        const s: []const u8 = if (a) |x| x.state else "gone";
        if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1].state, s)) {
            try out.append(r.arena, .{ .state = s, .from = t - t0, .ticks = 0, .bare = 0 });
        }
        const last = &out.items[out.items.len - 1];
        last.ticks += 1;
        if (a == null or a.?.body == null) last.bare += 1;
    }
    return out.items;
}

fn segmentValues(r: *const Run, segs: []const Segment, bare: bool) ![]const Value {
    var v: Values = .{ .arena = r.arena };
    for (segs) |s| {
        try v.text(s.state);
        try v.num(s.from);
        try v.num(s.ticks);
        if (bare) try v.num(s.bare);
    }
    return v.list.items;
}

/// The grab: its tick, the reach and the hold's place; after the first press, both fighters'
/// states, the hits and the knock-down's arc.
fn grab(r: *const Run, m: *Measures) !void {
    const tl = try r.timeline(1);
    const t_grab = tl.first(0, r.last, &.{"grab"}, true) orelse return error.Unmeasured;
    var target: ?i64 = null;
    for (try r.events("state", t_grab - 2, t_grab)) |e| {
        if (std.mem.eql(u8, str(e.object, "state") orelse "", "held")) target = int(e.object, "e");
    }
    const held = target orelse return error.Unmeasured;
    const gt = try r.timeline(held);
    try m.num("grab tick", t_grab);
    try m.num("reach across", round4((gt.at(t_grab - 1) orelse return error.Unmeasured).x - (tl.at(t_grab - 1) orelse return error.Unmeasured).x));
    try m.num("held at", round4((gt.at(t_grab) orelse return error.Unmeasured).x - (tl.at(t_grab) orelse return error.Unmeasured).x));
    var ps: std.ArrayList(i64) = .empty;
    for ([_]u8{ 'B', 'C', 'L' }) |button| for (try r.presses(button)) |p| {
        if (p > t_grab and std.mem.indexOfScalar(i64, ps.items, p) == null) try ps.append(r.arena, p);
    };
    std.mem.sort(i64, ps.items, {}, std.sort.asc(i64));
    const first = if (ps.items.len != 0) ps.items[0] else t_grab;
    var presses: Values = .{ .arena = r.arena };
    for (ps.items) |p| try presses.num(p - first);
    try m.add("presses", presses.list.items, .exact);
    try m.add("player's states (state, tick, ticks)", try segmentValues(r, try segments(r, &tl, first, tl.lastTick()), false), .exact);
    try m.add("held's states (state, tick, ticks)", try segmentValues(r, try segments(r, &gt, first, gt.lastTick()), false), .exact);
    var hits: Values = .{ .arena = r.arena };
    var knock: ?Event = null;
    for (try r.events("hit", first, r.last)) |h| {
        const e = int(h.object, "e") orelse continue;
        if (e != 1 and e != held) continue;
        try hits.num(h.t - first);
        try hits.text(if (e == 1) "player" else "held");
        try hits.num(int(h.object, "damage"));
        try hits.num(int(h.object, "health"));
        try hits.text(str(h.object, "reaction") orelse "");
        if (e == held and knock == null and std.mem.eql(u8, str(h.object, "reaction") orelse "", "knocked_down")) knock = h;
    }
    try m.add("hits (tick, who, damage, health, reaction)", hits.list.items, .exact);
    if (knock) |kd| {
        const p = tl.at(kd.t) orelse return error.Unmeasured;
        try m.text("player facing at the knock-down", p.facing);
        try knockDownArc(r, m, &gt, kd.t, "held's knock-down", p.x, if (std.mem.eql(u8, p.facing, "right")) 1 else -1, 160);
    }
}

/// Standing while the Galsia punches: the states with their ticks without a body box, the hits,
/// the knock-downs' arcs, and the ticks without a body box after getting up.
fn hitStand(r: *const Run, m: *Measures) !void {
    const tl = try r.timeline(1);
    var hits: std.ArrayList(Event) = .empty;
    for (try r.events("hit", 0, r.last)) |h| if (int(h.object, "e") == 1) try hits.append(r.arena, h);
    if (hits.items.len == 0) return error.Unmeasured;
    const t0 = hits.items[0].t - 1;
    const t1 = tl.lastTick();
    const segs = try segments(r, &tl, t0, t1);
    try m.add("states (state, tick, ticks, ticks without a body)", try segmentValues(r, segs, true), .exact);
    var v: Values = .{ .arena = r.arena };
    for (hits.items) |h| {
        try v.num(h.t - t0);
        try v.num(int(h.object, "by"));
        try v.num(int(h.object, "damage"));
        try v.num(int(h.object, "health"));
        try v.text(str(h.object, "reaction") orelse "");
    }
    try m.add("hits (tick, by, damage, health, reaction)", v.list.items, .exact);
    var k: usize = 0;
    for (hits.items) |h| {
        if (!std.mem.eql(u8, str(h.object, "reaction") orelse "", "knocked_down")) continue;
        k += 1;
        const base = tl.at(h.t - 1) orelse return error.Unmeasured;
        const sign: f64 = if (std.mem.eql(u8, base.facing, "right")) -1 else 1;
        try knockDownArc(r, m, &tl, h.t, try std.fmt.allocPrint(r.arena, "knock-down {d} (back from its place)", .{k}), base.x, sign, base.h);
    }
    // After getting up: the ticks until the body box is back.
    var g: usize = 0;
    for (segs) |s| {
        if (!std.mem.eql(u8, s.state, "getting_up")) continue;
        g += 1;
        const t = t0 + s.from + s.ticks;
        var n: i64 = 0;
        while (tl.at(t + n)) |a| : (n += 1) {
            if (a.body != null or n >= 300) break;
        }
        try m.num(try std.fmt.allocPrint(r.arena, "getting up {d}: ticks without a body after", .{g}), n);
    }
}

// The probes ------------------------------------------------------------------------------------

/// The probes from tick `t0`, entity by entity: the ticks whose boxes or power differ, whose
/// frame starts differ, whose frame's index differs.
fn compareProbes(arena: std.mem.Allocator, ref: *const Run, z: *const Run, t0: i64, m: *Measures) !void {
    var ids: std.ArrayList(i64) = .empty;
    for (ref.probe) |p| if (p.v >= ref.v0 and std.mem.indexOfScalar(i64, ids.items, p.e) == null) try ids.append(arena, p.e);
    std.mem.sort(i64, ids.items, {}, std.sort.asc(i64));
    const t1 = @min(ref.last, z.last);
    var boxes: Values = .{ .arena = arena };
    var starts: Values = .{ .arena = arena };
    var indexes: Values = .{ .arena = arena };
    var missing: Values = .{ .arena = arena };
    for (ids.items) |e| {
        const a = try ref.timeline(e);
        const b = try z.timeline(e);
        var nb: std.ArrayList(i64) = .empty;
        var ns: std.ArrayList(i64) = .empty;
        var ni: std.ArrayList(i64) = .empty;
        var t = t0 + 1;
        while (t <= t1) : (t += 1) {
            const x = a.at(t) orelse continue;
            const y = canonical((b.at(t) orelse {
                try missing.num(e);
                break;
            }).*);
            if (!sameBox(x.atk, y.atk) or !sameBox(x.body, y.body) or x.power != y.power) try nb.append(arena, t);
            // A frame starts where its index changes, or its animation: the programs name the
            // animations each its own way (sorz has one of its own for a hurried jab, composes
            // another of the original's frames), so a start differs when it differs both ways.
            const px = a.at(t - 1);
            const py: ?At = if (b.at(t - 1)) |q| canonical(q.*) else null;
            const ix = px == null or px.?.frame != x.frame;
            const iy = py == null or py.?.frame != y.frame;
            const ax = ix or !std.mem.eql(u8, px.?.anim, x.anim);
            const ay = iy or !std.mem.eql(u8, py.?.anim, y.anim);
            if (ix != iy and ax != ay) try ns.append(arena, t);
            if (x.frame != y.frame) try ni.append(arena, t);
        }
        if (nb.items.len != 0) try boxes.list.append(arena, try entityTicks(arena, e, nb.items));
        if (ns.items.len != 0) try starts.list.append(arena, try entityTicks(arena, e, ns.items));
        if (ni.items.len != 0) try indexes.list.append(arena, try entityTicks(arena, e, ni.items));
    }
    try m.add("probe: ticks whose boxes or power differ", boxes.list.items, .exact);
    try m.add("probe: ticks whose frame starts differ", starts.list.items, .exact);
    try m.add("probe: ticks whose frame's index differs", indexes.list.items, .exact);
    try m.add("probe: entities sorz lacks", missing.list.items, .exact);
}

/// sorz's animations composed of another's frames in another order, by the extractor
/// (extract/entities.zig): their frames as that other animation's, as the original shows them.
const composed = [_]struct { name: []const u8, of: []const u8, frames: []const i64 }{
    // The back drop's landing: the vault's frames 3, 2 and 1, backward.
    .{ .name = "vault_land", .of = "vault", .frames = &.{ 3, 2, 1 } },
};

fn canonical(a: At) At {
    const frame = a.frame orelse return a;
    for (composed) |c| {
        if (!std.mem.eql(u8, a.anim, c.name) or frame < 0 or frame >= c.frames.len) continue;
        var out = a;
        out.anim = c.of;
        out.frame = c.frames[@intCast(frame)];
        return out;
    }
    return a;
}

/// "entity E at T T T" (the first ticks), or with their count.
fn entityTicks(arena: std.mem.Allocator, e: i64, ticks: []const i64) !Value {
    var w: std.Io.Writer.Allocating = .init(arena);
    try w.writer.print("(entity {d} at", .{e});
    for (ticks[0..@min(ticks.len, 6)]) |t| try w.writer.print(" {d}", .{t});
    if (ticks.len > 6) try w.writer.print(" ...: {d} ticks", .{ticks.len});
    try w.writer.writeAll(")");
    return .{ .text = w.written() };
}

fn sameBox(a: ?Box, b: ?Box) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(i64, &a.?, &b.?);
}

// Running ---------------------------------------------------------------------------------------

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    rom_path: []const u8,
    remaster: []const u8,
    assets: sorz.platform.AssetSource,
    sound_names: []const compare.Rename,
    out_path: []const u8,
};

/// One run of a scenario: both programs, then the trace's and the probes' comparisons and the
/// move's measurements, from each into `ref` and `z`.
fn runOne(c: *const Context, sc: *const Scenario, name: []const u8, text: []const u8, ref: *Measures, z: *Measures) !void {
    const arena = c.arena;
    const cwd = std.Io.Dir.cwd();
    const path = struct {
        fn of(a: std.mem.Allocator, dir: []const u8, prefix: []const u8, n: []const u8, ext: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "{s}/{s}{s}{s}", .{ dir, prefix, n, ext });
        }
    }.of;
    const scn = try path(arena, c.out_path, "", name, ".scn");
    try cwd.writeFile(c.io, .{ .sub_path = scn, .data = text });
    const ref_trace = try path(arena, c.out_path, "ref-", name, ".jsonl");
    const ref_probe = try path(arena, c.out_path, "ref-", name, ".probe");
    const z_trace = try path(arena, c.out_path, "z-", name, ".jsonl");
    const z_probe = try path(arena, c.out_path, "z-", name, ".probe");

    // The reference.
    const ran = try std.process.run(c.gpa, c.io, .{ .argv = &.{ c.remaster, c.rom_path, "--scenario", scn, "--trace-events", ref_trace, "--probe", ref_probe, "--frames", "100000" } });
    defer c.gpa.free(ran.stdout);
    defer c.gpa.free(ran.stderr);
    if (ran.term != .exited or ran.term.exited != 0 or std.mem.indexOf(u8, ran.stdout, "\"scenario\":\"done\"") == null) {
        std.log.err("{s}: sor-remaster's run did not end as the scenario does: {s}{s}", .{ name, ran.stdout, ran.stderr });
        return error.ReferenceFailed;
    }

    // sorz, from the reference's situation, with its round's clock.
    const game_tick: ?u32 = blk: {
        const line = std.json.parseFromSliceLeaky(json.Value, arena, std.mem.trim(u8, ran.stdout, " \r\n"), .{}) catch break :blk null;
        if (line != .object) break :blk null;
        break :blk if (int(line.object, "script_game_tick")) |g| @intCast(g) else null;
    };
    var said: std.Io.Writer.Allocating = .init(arena);
    const done = try agent.scenario_cmd.run(c.gpa, c.io, c.assets, .{ .scenario = scn, .situation = ref_trace, .game_tick = game_tick, .trace = z_trace, .probe = z_probe }, &said.writer);
    if (!done) {
        std.log.err("{s}: sorz's run did not end as the scenario does: {s}", .{ name, said.written() });
        return error.RunFailed;
    }

    const ref_text = try cwd.readFileAlloc(c.io, ref_trace, arena, .limited(1 << 30));
    const z_text = try cwd.readFileAlloc(c.io, z_trace, arena, .limited(1 << 30));
    const ref_run = try Run.load(arena, ref_text, try cwd.readFileAlloc(c.io, ref_probe, arena, .limited(1 << 30)), c.sound_names);
    const z_run = try Run.load(arena, z_text, try cwd.readFileAlloc(c.io, z_probe, arena, .limited(1 << 30)), &.{});
    const t0: i64 = @intCast((try agent.scenario.situationOf(arena, ref_text, null)).t);

    // The traces from the situation's tick.
    const options: compare.Options = .{
        .from_scene = "round",
        .after = t0,
        .ignore_kinds = &ignored_kinds,
        .ignore = &ignored_events,
        .ignore_fields = &ignored_fields,
        .sound_names = c.sound_names,
    };
    var diag: compare.Diagnostic = .{};
    const a_full = try compare.parse(arena, ref_text, &diag);
    const b_full = try compare.parse(arena, z_text, &diag);
    const a = try compare.restrict(arena, &a_full, options, true);
    const b = try compare.restrict(arena, &b_full, options, false);
    var written: std.Io.Writer.Allocating = .init(arena);
    const result = try compare.compare(arena, &a, &b, options, &written.writer);
    var events: usize = 0;
    for (result.counts) |n| events += n.a;
    const verdict: []const u8 = if (result.differences == 0)
        try std.fmt.allocPrint(arena, "no difference in {d} events", .{events})
    else
        std.mem.trimEnd(u8, written.written()[0 .. std.mem.indexOf(u8, written.written(), "\nevent ") orelse written.written().len], "\n");
    const no_difference = try std.fmt.allocPrint(arena, "no difference in {d} events", .{events});
    ref.prefix = if (sc.kind == .jump_kick or sc.kind == .combo_window) name else "";
    z.prefix = ref.prefix;
    try ref.text("trace", no_difference);
    try z.text("trace", verdict);

    // The probes (the reference's against itself: nothing differs).
    try compareProbes(arena, &ref_run, &ref_run, t0, ref);
    try compareProbes(arena, &ref_run, &z_run, t0, z);

    // The move's measurements.
    try measure(sc.kind, &ref_run, ref);
    try measure(sc.kind, &z_run, z);
    ref.prefix = "";
    z.prefix = "";
}

/// A family's values of `{N}`, from its header: "# A family: {N} takes the values A to B".
fn familyValues(text: []const u8) ?[2]u32 {
    const key = "takes the values ";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    var it = std.mem.tokenizeAny(u8, text[at + key.len ..], " ()\n");
    const from = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (!std.mem.eql(u8, it.next() orelse return null, "to")) return null;
    const to = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    return .{ from, to };
}

const Verdict = enum { equal, within, different };

/// A move's measurements from both programs, compared and written: its verdict.
fn report(arena: std.mem.Allocator, move: []const u8, ref: []const Measure, z: []const Measure, w: *std.Io.Writer) !Verdict {
    var verdict: Verdict = .equal;
    var lines: std.Io.Writer.Allocating = .init(arena);
    var whys: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(arena);
    for (ref) |a| try seen.put(a.what, {});
    for (ref) |a| {
        const b = for (z) |x| {
            if (std.mem.eql(u8, x.what, a.what)) break x;
        } else null;
        const v: Verdict = if (b) |x|
            (if (same(a.values, x.values, 0))
                .equal
            else if (same(a.values, x.values, a.tolerance.within()))
                .within
            else
                .different)
        else
            .different;
        if (@backingInt(v) > @backingInt(verdict)) verdict = v;
        if (v == .within) {
            const why = a.tolerance.why();
            for (whys.items) |y| {
                if (std.mem.eql(u8, y, why)) break;
            } else try whys.append(arena, why);
        }
        try lines.writer.print("    {s}: ", .{a.what});
        try writeValues(&lines.writer, if (b) |x| x.values else a.values);
        if (v != .equal) {
            try lines.writer.writeAll(if (v == .within) "  [within tolerance; reference: " else "  [DIFFERENT; reference: ");
            try writeValues(&lines.writer, a.values);
            try lines.writer.writeAll("]");
        }
        try lines.writer.writeAll("\n");
    }
    for (z) |x| if (!seen.contains(x.what)) {
        verdict = .different;
        try lines.writer.print("    {s}: ", .{x.what});
        try writeValues(&lines.writer, x.values);
        try lines.writer.writeAll("  [DIFFERENT: the reference has no such measurement]\n");
    };
    try w.print("{s}: {s}", .{ move, switch (verdict) {
        .equal => "equal",
        .within => "within tolerance",
        .different => "different",
    } });
    for (whys.items, 0..) |y, i| try w.print("{s}{s}", .{ if (i == 0) " (" else "; ", y });
    if (whys.items.len != 0) try w.writeAll(")");
    try w.writeAll("\n");
    try w.writeAll(lines.written());
    return verdict;
}

fn same(a: []const Value, b: []const Value, within: f64) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y, within)) return false;
    return true;
}

fn writeValues(w: *std.Io.Writer, values: []const Value) !void {
    if (values.len == 0) return w.writeAll("-");
    const most = 24;
    for (values[0..@min(values.len, most)], 0..) |v, i| try w.print("{s}{f}", .{ if (i == 0) "" else " ", v });
    if (values.len > most) try w.print(" ... ({d} values)", .{values.len});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const rom_path = args.next() orelse return usage(io);
    const remaster = args.next() orelse return usage(io);
    const scenarios_dir = args.next() orelse return usage(io);
    const out_path = args.next() orelse return usage(io);
    var only: std.ArrayList([]const u8) = .empty;
    while (args.next()) |name| try only.append(arena, name);

    const rom = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(extract.rom.size + 1)) catch |e| {
        return fail(io, try std.fmt.allocPrint(arena, "cannot read the ROM {s}: {s}\n", .{ rom_path, @errorName(e) }));
    };
    defer gpa.free(rom);
    var tree = extract.extract(gpa, rom) catch |e| return fail(io, try std.fmt.allocPrint(arena, "cannot extract the ROM: {s}\n", .{@errorName(e)}));
    defer tree.deinit();
    var source = sorz.memory.MemoryAssetSource.init(gpa);
    defer source.deinit();
    try tree.addTo(&source);
    const sounds_json = for (tree.files) |f| {
        if (std.mem.eql(u8, f.path, "sound/sounds.json")) break f.bytes;
    } else return fail(io, "the content has no sound/sounds.json\n");
    try std.Io.Dir.cwd().createDirPath(io, out_path);

    const c: Context = .{
        .gpa = gpa,
        .io = io,
        .arena = arena,
        .rom_path = rom_path,
        .remaster = remaster,
        .assets = source.assetSource(),
        .sound_names = try compare.soundNames(arena, sounds_json),
        .out_path = out_path,
    };

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    try w.writeAll(
        \\similar-check: Axel's moves in sorz against sor-remaster's, scenario by scenario (DESIGN.md V3).
        \\Tolerances: start-up, active and recovery ticks, states and their ticks, damage, health,
        \\pushes, arcs, speeds, frames, boxes and power: equal; the special attack's times: 1 tick
        \\(its car is a stand-in). Left out of the traces: the special attack's and the hits' effects,
        \\the round's timer, the speed up and down (a Galsia keeps its last bounce's once it lies in
        \\the original, which nothing reads; the places are compared).
        \\
        \\
    );
    var counts: [3]usize = .{ 0, 0, 0 };
    var failed = false;
    var runs: usize = 0;
    var printed: usize = 0;
    for (&scenarios) |*sc| {
        if (only.items.len != 0) {
            for (only.items) |n| {
                if (std.mem.eql(u8, n, sc.name)) break;
            } else continue;
        }
        const file = try std.fmt.allocPrint(arena, "{s}/{s}.scn", .{ scenarios_dir, sc.name });
        const scn = std.Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(1 << 20)) catch |e| {
            return fail(io, try std.fmt.allocPrint(arena, "cannot read the scenario {s}: {s}\n", .{ file, @errorName(e) }));
        };
        // The scenario's runs, their traces and measurements, in an arena of their own.
        var scenario_arena: std.heap.ArenaAllocator = .init(gpa);
        defer scenario_arena.deinit();
        var sc_context = c;
        sc_context.arena = scenario_arena.allocator();
        var ref: Measures = .{ .arena = sc_context.arena };
        var z: Measures = .{ .arena = sc_context.arena };
        var ok = true;
        if (familyValues(scn)) |values| {
            var n = values[0];
            while (n <= values[1]) : (n += 1) {
                const number = try std.fmt.allocPrint(arena, "{d}", .{n});
                const name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ sc.name, n });
                const expanded = try std.mem.replaceOwned(u8, arena, scn, "{N}", number);
                runs += 1;
                runOne(&sc_context, sc, name, expanded, &ref, &z) catch |e| {
                    try w.print("{s}: the run {s} failed: {s}\n", .{ sc.move, name, @errorName(e) });
                    ok = false;
                };
            }
        } else {
            runs += 1;
            runOne(&sc_context, sc, sc.name, scn, &ref, &z) catch |e| {
                try w.print("{s}: the run {s} failed: {s}\n", .{ sc.move, sc.name, @errorName(e) });
                ok = false;
            };
        }
        if (ok) {
            const v = try report(sc_context.arena, sc.move, ref.list.items, z.list.items, w);
            counts[@backingInt(v)] += 1;
        } else failed = true;
        try out.interface.writeAll(text.written()[printed..]);
        try out.interface.flush();
        printed = text.written().len;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/report.txt", .{out_path}), .data = text.written() });
    }
    const summary = try std.fmt.allocPrint(arena, "{{\"runs\":{d},\"moves\":{d},\"equal\":{d},\"within_tolerance\":{d},\"different\":{d},\"failed\":{}}}\n", .{ runs, counts[0] + counts[1] + counts[2], counts[0], counts[1], counts[2], failed });
    try w.writeAll(summary);
    try out.interface.writeAll(summary);
    try out.interface.flush();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/report.txt", .{out_path}), .data = text.written() });
    if (failed or counts[2] != 0) std.process.exit(1);
}

fn usage(io: std.Io) !void {
    return fail(io, "usage: sorz-similar-check ROM REMASTER_AGENT SCENARIOS_DIR OUT_DIR [SCENARIO...]\n");
}

fn fail(io: std.Io, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(message);
    try w.interface.flush();
    std.process.exit(2);
}

test "a family's values come from its header" {
    try std.testing.expectEqual([2]u32{ 0, 15 }, familyValues("# A family: {N} takes the values 0 to 15 (16 runs).\nstart axel\n").?);
    try std.testing.expect(familyValues("start axel\n") == null);
}

test "values compare within their tolerance" {
    try std.testing.expect((Value{ .num = 3 }).eql(.{ .num = 4 }, 1));
    try std.testing.expect(!(Value{ .num = 3 }).eql(.{ .num = 5 }, 1));
    try std.testing.expect(!(Value{ .num = 3 }).eql(.{ .text = "3" }, 1));
}

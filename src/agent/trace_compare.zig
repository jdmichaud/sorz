//! The comparison of two semantic traces (sor-remaster's docs/traces.md; carried over from
//! sor-remaster's trace/compare.zig, reviewed): it matches each event of the first with an event
//! of the second of the same kind, about the same entity, in the same scene and within a
//! tolerance of ticks, compares their fields with tolerances per field, names the first
//! difference, and counts the matches and differences per kind of event.
//!
//! sorz adds what a run taken up from another's situation needs (`Options`): the comparison from
//! a scene on (the last scene of that name in each trace, its ticks after a given one), the
//! events about kinds of entity left out (the effects one program has and the other draws
//! otherwise), fields left out, and the first trace's sound names translated into the second's
//! (sor-remaster names a sound by the original's request number, sorz by the content's name).
//!
//! Two events are about the same thing when they have the same `ev`, the same scene (its
//! ordinal: the scenes in the order the trace entered them) and the same key: the entity (`e`)
//! for the events of an entity, the player for `lives` and `score`, the pad for `pad`, the
//! sound's name for `sound`. Their times are the scene's tick (`t`), or the display tick (`v`)
//! with `by_vblank`. Fields whose name starts with `_` are the program's own (a slot, a type
//! number) and are not compared.
const std = @import("std");
const json = std.json;

pub const Options = struct {
    /// The ticks an event may be early or late.
    ticks: i64 = 0,
    /// Only the last scene of this name of each trace (its ordinal then 1), and its events after
    /// tick `after`.
    from_scene: ?[]const u8 = null,
    after: ?i64 = null,
    /// The events about an entity of these kinds (its spawn's) are left out, and so are these
    /// fields.
    ignore_kinds: []const []const u8 = &.{},
    ignore_fields: []const []const u8 = &.{},
    /// The first trace's sound names, translated: each `from` becomes `to`.
    sound_names: []const Rename = &.{},
    /// Per field, the difference allowed (in the field's unit: 1/65536 pixel for positions).
    tolerances: []const Tolerance = &.{},
    /// The kinds of event left out.
    ignore: []const []const u8 = &.{},
    /// Time is the display tick, and scenes are not matched.
    by_vblank: bool = false,
    /// Every difference is written, not only the first (up to `max_written`).
    all: bool = false,
    /// The entities are renumbered in each trace by the order they appear (their spawns, the
    /// ignored kinds left out; the players keep 1 and 2): two runs from power-on whose front
    /// ends make other entities (sor-remaster's screen objects) number the round's alike.
    renumber: bool = false,
    max_written: usize = 50,
};

pub const Tolerance = struct { field: []const u8, within: i64 };

pub const Rename = struct { from: []const u8, to: []const u8 };

/// The fields that hold positions and speeds, which a position tolerance covers.
pub const position_fields = [_][]const u8{ "x", "d", "h", "vx", "vd", "vh", "y", "y_min", "y_max" };

pub const Event = struct {
    /// The line in its file, from 1.
    line: usize,
    scene: u32,
    v: i64,
    t: i64,
    ev: []const u8,
    key: ?Key,
    object: json.ObjectMap,
    text: []const u8,

    fn time(self: *const Event, by_vblank: bool) i64 {
        return if (by_vblank) self.v else self.t;
    }
};

pub const Key = union(enum) { int: i64, str: []const u8 };

pub const Trace = struct {
    events: []Event,
    /// The `end` line's place: the last scene and tick observed (null: no end line, cut short).
    end: ?struct { scene: u32, v: i64, t: i64 },
    /// The scenes' names, by ordinal from 1.
    scenes: [][]const u8,
};

pub const Error = error{ BadTrace, OutOfMemory };

/// Reads a trace: its `begin` line (format and version), then an event per line.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: *Diagnostic) Error!Trace {
    var events: std.ArrayList(Event) = .empty;
    var scenes: std.ArrayList([]const u8) = .empty;
    var trace: Trace = .{ .events = &.{}, .end = null, .scenes = &.{} };
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    var scene: u32 = 0;
    var begun = false;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const value = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch return diag.fail(n, "not a JSON object");
        if (value != .object) return diag.fail(n, "not a JSON object");
        const o = value.object;
        const ev = str(o, "ev") orelse return diag.fail(n, "no \"ev\"");
        if (!begun) {
            if (!std.mem.eql(u8, ev, "begin")) return diag.fail(n, "the first line is not \"begin\"");
            const f = str(o, "format") orelse return diag.fail(n, "no \"format\"");
            if (!std.mem.eql(u8, f, "sor-trace")) return diag.fail(n, "not a sor-trace");
            if (int(o, "version") != 1) return diag.fail(n, "a version other than 1");
            begun = true;
            continue;
        }
        const v = int(o, "v") orelse return diag.fail(n, "no \"v\"");
        const t = int(o, "t") orelse return diag.fail(n, "no \"t\"");
        if (std.mem.eql(u8, ev, "end")) {
            trace.end = .{ .scene = scene, .v = v, .t = t };
            break;
        }
        if (std.mem.eql(u8, ev, "scene")) {
            scene += 1;
            try scenes.append(arena, str(o, "scene") orelse "?");
        }
        try events.append(arena, .{ .line = n, .scene = scene, .v = v, .t = t, .ev = ev, .key = keyOf(ev, o), .object = o, .text = line });
    }
    if (!begun) return diag.fail(n, "no \"begin\" line");
    trace.events = events.items;
    trace.scenes = scenes.items;
    return trace;
}

/// `trace` restricted as `options` ask (`from_scene`, `after`, `ignore_kinds`, `sound_names`;
/// `rename` says whether its sound names are translated).
pub fn restrict(arena: std.mem.Allocator, trace: *const Trace, options: Options, rename: bool) Error!Trace {
    var kinds: std.AutoHashMapUnmanaged(i64, []const u8) = .empty;
    var keep_scene: ?u32 = null;
    if (options.from_scene) |name| {
        for (trace.scenes, 0..) |s, i| if (std.mem.eql(u8, s, name)) {
            keep_scene = @intCast(i + 1);
        };
        if (keep_scene == null) return error.BadTrace;
    }
    var events: std.ArrayList(Event) = .empty;
    var numbers: std.AutoHashMapUnmanaged(i64, i64) = .empty;
    var next_number: i64 = 3;
    for (trace.events) |e| {
        if (std.mem.eql(u8, e.ev, "spawn")) if (int(e.object, "e")) |id| {
            const kind = str(e.object, "kind") orelse "";
            try kinds.put(arena, id, kind);
            if (options.renumber and !listed(options.ignore_kinds, kind) and id > 2) {
                try numbers.put(arena, id, next_number);
                next_number += 1;
            }
        };
        if (keep_scene) |k| {
            if (e.scene != k) continue;
        }
        if (options.after) |a| if (e.t <= a) continue;
        if (int(e.object, "e")) |id| if (kinds.get(id)) |kind| if (listed(options.ignore_kinds, kind)) continue;
        if (str(e.object, "kind")) |kind| if (listed(options.ignore_kinds, kind)) continue;
        var x = e;
        if (keep_scene != null) x.scene = 1;
        if (options.renumber) x = try renumbered(arena, x, &numbers);
        if (rename and std.mem.eql(u8, e.ev, "sound")) if (str(e.object, "sound")) |name| {
            for (options.sound_names) |r| if (std.mem.eql(u8, r.from, name)) {
                var o = try e.object.clone(arena);
                try o.put(arena, "sound", .{ .string = r.to });
                x.object = o;
                x.key = .{ .str = r.to };
            };
        };
        try events.append(arena, x);
    }
    var end = trace.end;
    // The scene kept is whole when the trace went on past it: no end within it.
    if (keep_scene) |k| if (end) |*x| {
        if (x.scene > k) end = null else x.scene = 1;
    };
    return .{
        .events = events.items,
        .end = end,
        .scenes = if (keep_scene) |k| try arena.dupe([]const u8, trace.scenes[k - 1 .. k]) else trace.scenes,
    };
}

/// `e` with its entities (`e`, `by`) numbered as `numbers` says.
fn renumbered(arena: std.mem.Allocator, e: Event, numbers: *const std.AutoHashMapUnmanaged(i64, i64)) !Event {
    var x = e;
    var o: ?json.ObjectMap = null;
    for ([_][]const u8{ "e", "by" }) |field| {
        const id = int(e.object, field) orelse continue;
        const number = numbers.get(id) orelse continue;
        if (o == null) o = try e.object.clone(arena);
        try o.?.put(arena, field, .{ .integer = number });
    }
    if (o) |obj| {
        x.object = obj;
        x.key = keyOf(x.ev, obj);
    }
    return x;
}

/// The translations of sor-remaster's sound names into the sound content's (sounds.json's
/// `request` numbers): `sfx_b2` (an effect), `song_83`, `sample_d9`, and the driver's commands.
pub fn soundNames(arena: std.mem.Allocator, sounds_json: []const u8) Error![]const Rename {
    const v = json.parseFromSliceLeaky(json.Value, arena, sounds_json, .{}) catch return error.BadTrace;
    if (v != .object) return error.BadTrace;
    const list = v.object.get("sounds") orelse return error.BadTrace;
    if (list != .array) return error.BadTrace;
    var out: std.ArrayList(Rename) = .empty;
    for (list.array.items) |s| {
        if (s != .object) return error.BadTrace;
        const name = str(s.object, "name") orelse return error.BadTrace;
        const request = int(s.object, "request") orelse continue;
        const id: u8 = std.math.cast(u8, request) orelse return error.BadTrace;
        try out.append(arena, .{ .from = try remasterName(arena, id), .to = name });
    }
    return out.items;
}

/// sor-remaster's name for the request `id` (its trace/names.zig).
fn remasterName(arena: std.mem.Allocator, id: u8) Error![]const u8 {
    return switch (id) {
        0xE0 => "fade_out",
        0xE1, 0xE3 => "stop_all",
        0xE2 => "stop_sfx",
        else => std.fmt.allocPrint(arena, "{s}_{x:0>2}", .{ switch (id) {
            0x81...0x9F => "song",
            0xA0...0xCF => "sfx",
            0xD0...0xDF => "sample",
            else => "request",
        }, id }),
    };
}

fn listed(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

pub const Diagnostic = struct {
    line: usize = 0,
    what: []const u8 = "",

    fn fail(self: *Diagnostic, line: usize, what: []const u8) Error {
        self.line = line;
        self.what = what;
        return error.BadTrace;
    }
};

fn str(o: json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(o: json.ObjectMap, name: []const u8) ?i64 {
    const v = o.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

/// What an event is about, beyond its kind.
fn keyOf(ev: []const u8, o: json.ObjectMap) ?Key {
    const field: []const u8 = if (std.mem.eql(u8, ev, "lives") or std.mem.eql(u8, ev, "score"))
        "player"
    else if (std.mem.eql(u8, ev, "pad"))
        "pad"
    else if (std.mem.eql(u8, ev, "sound"))
        "sound"
    else
        "e";
    const v = o.get(field) orelse return null;
    return switch (v) {
        .integer => |i| .{ .int = i },
        .string => |s| .{ .str = s },
        else => null,
    };
}

fn sameKey(a: ?Key, b: ?Key) bool {
    if (a == null or b == null) return a == null and b == null;
    return switch (a.?) {
        .int => |i| b.? == .int and b.?.int == i,
        .str => |s| b.? == .str and std.mem.eql(u8, b.?.str, s),
    };
}

/// The counts of one kind of event.
pub const Count = struct {
    ev: []const u8,
    a: usize = 0,
    b: usize = 0,
    matched: usize = 0,
    differ: usize = 0,
    missing: usize = 0,
    extra: usize = 0,
};

pub const Kind = enum { differs, missing, extra };

pub const Difference = struct {
    kind: Kind,
    /// The event of the first trace (none for `extra`) and of the second (none for `missing`).
    a: ?*const Event,
    b: ?*const Event,
    /// For `differs`: the first field that differs.
    field: []const u8 = "",
};

pub const Result = struct {
    differences: usize,
    first: ?Difference,
    counts: []Count,
};

/// Compares `b` with `a` (the reference), and writes the first difference (or all of them) and
/// the counts per kind of event.
pub fn compare(arena: std.mem.Allocator, a: *const Trace, b: *const Trace, options: Options, out: *std.Io.Writer) !Result {
    // The second trace's events by kind, key and scene, in their order (by time).
    var index: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    for (b.events, 0..) |*e, i| {
        if (ignored(options, e.ev)) continue;
        const name = try groupName(arena, e, options.by_vblank);
        const gop = try index.getOrPut(arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, @intCast(i));
    }
    const matched = try arena.alloc(bool, b.events.len);
    @memset(matched, false);
    var counts: std.ArrayList(Count) = .empty;
    var diffs: std.ArrayList(Difference) = .empty;

    for (a.events) |*e| {
        if (ignored(options, e.ev)) continue;
        if (beyond(e, b, options.by_vblank)) continue;
        const c = try countOf(arena, &counts, e.ev);
        c.a += 1;
        const name = try groupName(arena, e, options.by_vblank);
        const group = index.get(name) orelse {
            c.missing += 1;
            try diffs.append(arena, .{ .kind = .missing, .a = e, .b = null });
            continue;
        };
        const at = e.time(options.by_vblank);
        // The candidates within the ticks' tolerance: one whose fields match, the nearest in
        // time first; else the nearest, which then differs.
        var best: ?u32 = null;
        var nearest: ?u32 = null;
        var lo: usize = 0;
        var hi: usize = group.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (b.events[group.items[mid]].time(options.by_vblank) < at - options.ticks) lo = mid + 1 else hi = mid;
        }
        var k = lo;
        while (k < group.items.len) : (k += 1) {
            const j = group.items[k];
            const be = &b.events[j];
            const bt = be.time(options.by_vblank);
            if (bt > at + options.ticks) break;
            if (matched[j]) continue;
            const dist = @abs(bt - at);
            if (nearest == null or dist < @abs(b.events[nearest.?].time(options.by_vblank) - at)) nearest = j;
            if (firstFieldDifference(e, be, options) == null) {
                if (best == null or dist < @abs(b.events[best.?].time(options.by_vblank) - at)) best = j;
            }
        }
        if (best) |j| {
            matched[j] = true;
            c.matched += 1;
        } else if (nearest) |j| {
            matched[j] = true;
            c.differ += 1;
            try diffs.append(arena, .{ .kind = .differs, .a = e, .b = &b.events[j], .field = firstFieldDifference(e, &b.events[j], options).? });
        } else {
            c.missing += 1;
            try diffs.append(arena, .{ .kind = .missing, .a = e, .b = null });
        }
    }
    for (b.events, 0..) |*e, j| {
        if (ignored(options, e.ev)) continue;
        if (beyond(e, a, options.by_vblank)) continue;
        const c = try countOf(arena, &counts, e.ev);
        c.b += 1;
        if (matched[j]) continue;
        c.extra += 1;
        try diffs.append(arena, .{ .kind = .extra, .a = null, .b = e });
    }

    // The differences in the order of time, the first trace's order among equals.
    std.mem.sort(Difference, diffs.items, options.by_vblank, earlier);
    const first: ?Difference = if (diffs.items.len != 0) diffs.items[0] else null;
    const shown = if (options.all) @min(diffs.items.len, options.max_written) else @min(diffs.items.len, 1);
    for (diffs.items[0..shown], 0..) |d, i| try writeDifference(out, a, b, d, if (i == 0) "first difference" else "difference");
    if (diffs.items.len == 0) try out.writeAll("no difference\n");
    try out.print("{s: <14} {s: >8} {s: >8} {s: >8} {s: >8} {s: >8} {s: >8}\n", .{ "event", "first", "second", "matched", "differ", "missing", "extra" });
    std.mem.sort(Count, counts.items, {}, struct {
        fn less(_: void, x: Count, y: Count) bool {
            return std.mem.order(u8, x.ev, y.ev) == .lt;
        }
    }.less);
    for (counts.items) |c| try out.print("{s: <14} {d: >8} {d: >8} {d: >8} {d: >8} {d: >8} {d: >8}\n", .{ c.ev, c.a, c.b, c.matched, c.differ, c.missing, c.extra });
    return .{ .differences = diffs.items.len, .first = first, .counts = counts.items };
}

fn ignored(options: Options, ev: []const u8) bool {
    for (options.ignore) |i| if (std.mem.eql(u8, i, ev)) return true;
    return false;
}

/// Whether event `e` is past the end of trace `other` (which then cannot have it).
fn beyond(e: *const Event, other: *const Trace, by_vblank: bool) bool {
    const end = other.end orelse return false;
    if (by_vblank) return e.v > end.v;
    if (e.scene != end.scene) return e.scene > end.scene;
    return e.t > end.t;
}

fn groupName(arena: std.mem.Allocator, e: *const Event, by_vblank: bool) ![]const u8 {
    const scene: u32 = if (by_vblank) 0 else e.scene;
    return if (e.key) |k| switch (k) {
        .int => |i| std.fmt.allocPrint(arena, "{s}|{d}|i{d}", .{ e.ev, scene, i }),
        .str => |s| std.fmt.allocPrint(arena, "{s}|{d}|s{s}", .{ e.ev, scene, s }),
    } else std.fmt.allocPrint(arena, "{s}|{d}|", .{ e.ev, scene });
}

fn countOf(arena: std.mem.Allocator, counts: *std.ArrayList(Count), ev: []const u8) !*Count {
    for (counts.items) |*c| if (std.mem.eql(u8, c.ev, ev)) return c;
    try counts.append(arena, .{ .ev = ev });
    return &counts.items[counts.items.len - 1];
}

fn earlier(by_vblank: bool, x: Difference, y: Difference) bool {
    const ex = x.a orelse x.b.?;
    const ey = y.a orelse y.b.?;
    if (!by_vblank and ex.scene != ey.scene) return ex.scene < ey.scene;
    const tx = ex.time(by_vblank);
    const ty = ey.time(by_vblank);
    if (tx != ty) return tx < ty;
    // Among equals, the first trace's before the second's extras, each in its line order.
    if ((x.a == null) != (y.a == null)) return x.a != null;
    return ex.line < ey.line;
}

/// The first field of `a` that `b` does not have the same (within its tolerance), or that `b`
/// has and `a` has not; null when they agree.
fn firstFieldDifference(a: *const Event, b: *const Event, options: Options) ?[]const u8 {
    var it = a.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (skipped(name) or listed(options.ignore_fields, name)) continue;
        const other = b.object.get(name) orelse return name;
        if (!sameValue(entry.value_ptr.*, other, tolerance(options, name))) return name;
    }
    var bit = b.object.iterator();
    while (bit.next()) |entry| {
        const name = entry.key_ptr.*;
        if (skipped(name) or listed(options.ignore_fields, name)) continue;
        if (a.object.get(name) == null) return name;
    }
    return null;
}

fn skipped(name: []const u8) bool {
    return std.mem.eql(u8, name, "v") or std.mem.eql(u8, name, "t") or std.mem.eql(u8, name, "ev") or (name.len != 0 and name[0] == '_');
}

fn tolerance(options: Options, field: []const u8) i64 {
    var within: i64 = 0;
    for (options.tolerances) |t| if (std.mem.eql(u8, t.field, field)) {
        within = t.within;
    };
    return within;
}

fn sameValue(x: json.Value, y: json.Value, within: i64) bool {
    return switch (x) {
        .integer => |i| y == .integer and @abs(i - y.integer) <= within,
        .string => |s| y == .string and std.mem.eql(u8, s, y.string),
        .bool => |b| y == .bool and y.bool == b,
        .null => y == .null,
        .array => |arr| blk: {
            if (y != .array or y.array.items.len != arr.items.len) break :blk false;
            for (arr.items, y.array.items) |p, q| if (!sameValue(p, q, within)) break :blk false;
            break :blk true;
        },
        .float => |f| y == .float and @abs(f - y.float) <= @as(f64, @floatFromInt(within)),
        .number_string => |s| y == .number_string and std.mem.eql(u8, s, y.number_string),
        .object => false,
    };
}

fn writeDifference(out: *std.Io.Writer, a: *const Trace, b: *const Trace, d: Difference, label: []const u8) !void {
    const e = d.a orelse d.b.?;
    const scenes = if (d.a != null) a.scenes else b.scenes;
    const scene_name = if (e.scene >= 1 and e.scene <= scenes.len) scenes[e.scene - 1] else "?";
    try out.print("{s}: {s}, {s} at scene {d} ({s}) tick {d}, VBlank {d}\n", .{ label, switch (d.kind) {
        .differs => "a field differs",
        .missing => "an event of the first trace is not in the second",
        .extra => "an event of the second trace is not in the first",
    }, e.ev, e.scene, scene_name, e.t, e.v });
    if (d.a) |x| try out.print("  first  (line {d}): {s}\n", .{ x.line, x.text });
    if (d.b) |y| try out.print("  second (line {d}): {s}\n", .{ y.line, y.text });
    if (d.kind == .differs) {
        try out.print("  field {s}: ", .{d.field});
        try writeValue(out, d.a.?.object.get(d.field));
        try out.writeAll(" against ");
        try writeValue(out, d.b.?.object.get(d.field));
        try out.writeAll("\n");
    }
}

fn writeValue(out: *std.Io.Writer, v: ?json.Value) !void {
    const value = v orelse return out.writeAll("(none)");
    switch (value) {
        .integer => |i| try out.print("{d}", .{i}),
        .string => |s| try out.print("\"{s}\"", .{s}),
        .bool => |b| try out.writeAll(if (b) "true" else "false"),
        .null => try out.writeAll("null"),
        else => try out.writeAll("(a value)"),
    }
}

// Tests -------------------------------------------------------------------------------------------

const header = "{\"ev\":\"begin\",\"format\":\"sor-trace\",\"version\":1,\"program\":\"test\",\"fixed\":16,\"start\":\"power-on\"}\n";

const sample = header ++
    \\{"v":0,"t":0,"ev":"scene","scene":"round","round":1,"demo":false,"_mode":22}
    \\{"v":0,"t":0,"ev":"spawn","e":3,"kind":"galsia","x":100,"d":0,"h":0,"_slot":5}
    \\{"v":2,"t":1,"ev":"pos","e":3,"x":110,"d":0,"h":0,"vx":10,"vd":0,"vh":0}
    \\{"v":4,"t":2,"ev":"hit","e":3,"by":1,"damage":3,"health":17,"reaction":"reel"}
    \\{"v":4,"t":2,"ev":"sound","sound":"sfx_b2","_id":178}
    \\{"v":6,"t":3,"ev":"end","events":5}
    \\
;

fn run(a_text: []const u8, b_text: []const u8, options: Options, out: *std.Io.Writer.Allocating) !Result {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const a = try parse(arena, a_text, &diag);
    const b = try parse(arena, b_text, &diag);
    const r = try compare(arena, &a, &b, options, &out.writer);
    return .{ .differences = r.differences, .first = null, .counts = &.{} };
}

test "a trace against itself, and a slot that differs, are the same" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const other_slot = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "\"_slot\":5", "\"_slot\":9");
    defer std.testing.allocator.free(other_slot);
    try std.testing.expectEqual(@as(usize, 0), (try run(sample, other_slot, .{}, &out)).differences);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "no difference") != null);
}

test "a planted difference is named: the field, both lines" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const planted = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "\"damage\":3", "\"damage\":4");
    defer std.testing.allocator.free(planted);
    try std.testing.expectEqual(@as(usize, 1), (try run(sample, planted, .{}, &out)).differences);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "first difference: a field differs, hit at scene 1 (round) tick 2, VBlank 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field damage: 3 against 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "second (line 5)") != null);
}

test "tolerances: positions within N, ticks within M" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const moved = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "\"x\":110", "\"x\":112");
    defer std.testing.allocator.free(moved);
    try std.testing.expectEqual(@as(usize, 1), (try run(sample, moved, .{}, &out)).differences);
    const tol = [_]Tolerance{.{ .field = "x", .within = 2 }};
    try std.testing.expectEqual(@as(usize, 0), (try run(sample, moved, .{ .tolerances = &tol }, &out)).differences);
    const late = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "{\"v\":4,\"t\":2,\"ev\":\"hit\"", "{\"v\":6,\"t\":3,\"ev\":\"hit\"");
    defer std.testing.allocator.free(late);
    try std.testing.expectEqual(@as(usize, 2), (try run(sample, late, .{}, &out)).differences);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), (try run(sample, late, .{ .ticks = 1 }, &out)).differences);
    out.clearRetainingCapacity();
    // Left out: the kind of event that differs.
    try std.testing.expectEqual(@as(usize, 0), (try run(sample, moved, .{ .ignore = &.{"pos"} }, &out)).differences);
}

test "missing and extra events; a shorter trace is compared up to its end" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const no_sound = try std.mem.replaceOwned(u8, std.testing.allocator, sample, "{\"v\":4,\"t\":2,\"ev\":\"sound\",\"sound\":\"sfx_b2\",\"_id\":178}\n", "");
    defer std.testing.allocator.free(no_sound);
    try std.testing.expectEqual(@as(usize, 1), (try run(sample, no_sound, .{}, &out)).differences);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "an event of the first trace is not in the second, sound") != null);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 1), (try run(no_sound, sample, .{}, &out)).differences);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "an event of the second trace is not in the first, sound") != null);
    out.clearRetainingCapacity();
    // Cut after tick 1: the hit and the sound are past its end.
    const cut = header ++
        \\{"v":0,"t":0,"ev":"scene","scene":"round","round":1,"demo":false,"_mode":22}
        \\{"v":0,"t":0,"ev":"spawn","e":3,"kind":"galsia","x":100,"d":0,"h":0,"_slot":5}
        \\{"v":2,"t":1,"ev":"pos","e":3,"x":110,"d":0,"h":0,"vx":10,"vd":0,"vh":0}
        \\{"v":2,"t":1,"ev":"end","events":3}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), (try run(sample, cut, .{}, &out)).differences);
}

test "a malformed trace is refused with its line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.BadTrace, parse(arena_state.allocator(), "{\"ev\":\"spawn\"}\n", &diag));
    try std.testing.expectEqual(@as(usize, 1), diag.line);
    try std.testing.expectError(error.BadTrace, parse(arena_state.allocator(), header ++ "{\"ev\":\"pos\",\"v\":1}\n", &diag));
    try std.testing.expectEqualStrings("no \"t\"", diag.what);
}

test "a run taken up from a situation: its scene from a tick, kinds left out, sounds renamed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reference = header ++
        \\{"v":0,"t":0,"ev":"scene","scene":"title","_mode":8}
        \\{"v":5,"t":0,"ev":"scene","scene":"round","round":1,"demo":false,"_mode":22}
        \\{"v":5,"t":0,"ev":"spawn","e":3,"kind":"galsia","x":100,"d":0,"h":0,"_slot":5}
        \\{"v":7,"t":1,"ev":"spawn","e":4,"kind":"hit_spark","x":0,"d":0,"h":0,"_slot":6}
        \\{"v":9,"t":2,"ev":"hit","e":3,"by":1,"damage":3,"health":17,"reaction":"reel"}
        \\{"v":9,"t":2,"ev":"sound","sound":"sfx_b2","_id":178}
        \\{"v":11,"t":3,"ev":"end","events":5}
        \\
    ;
    const ours = header ++
        \\{"v":5,"t":0,"ev":"scene","scene":"round","round":1,"demo":false}
        \\{"v":5,"t":0,"ev":"spawn","e":3,"kind":"galsia","x":100,"d":0,"h":0,"_slot":1}
        \\{"v":9,"t":2,"ev":"hit","e":3,"by":1,"damage":3,"health":17,"reaction":"reel"}
        \\{"v":9,"t":2,"ev":"sound","sound":"enemy hit"}
        \\{"v":11,"t":3,"ev":"end","events":3}
        \\
    ;
    var diag: Diagnostic = .{};
    const a = try parse(arena, reference, &diag);
    const b = try parse(arena, ours, &diag);
    const options: Options = .{
        .from_scene = "round",
        .after = 0,
        .ignore_kinds = &.{"hit_spark"},
        .sound_names = &.{.{ .from = "sfx_b2", .to = "enemy hit" }},
    };
    const ra = try restrict(arena, &a, options, true);
    const rb = try restrict(arena, &b, options, false);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try compare(arena, &ra, &rb, options, &out.writer)).differences);
    // Without the renaming, the sound differs.
    const plain = try restrict(arena, &a, options, false);
    try std.testing.expectEqual(@as(usize, 2), (try compare(arena, &plain, &rb, options, &out.writer)).differences);
}

test "sor-remaster's sound names from the content's request numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const names = try soundNames(arena_state.allocator(),
        \\{"sounds": [{"name": "enemy hit", "request": 178}, {"name": "round 1 music", "request": 129},
        \\  {"name": "axel shout", "request": 219}, {"name": "stop", "request": 225}, {"name": "none"}]}
    );
    try std.testing.expectEqual(@as(usize, 4), names.len);
    try std.testing.expectEqualStrings("sfx_b2", names[0].from);
    try std.testing.expectEqualStrings("enemy hit", names[0].to);
    try std.testing.expectEqualStrings("song_81", names[1].from);
    try std.testing.expectEqualStrings("sample_db", names[2].from);
    try std.testing.expectEqualStrings("stop_all", names[3].from);
}

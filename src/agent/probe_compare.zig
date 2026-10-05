//! The comparison of two runs' probes (sor-remaster's docs/scenarios.md, `--probe`): each
//! fighter's frames, entity by entity, within a scene: the ticks its frames start and the index
//! of each. The programs name their animations each their own way (sor-remaster by its own
//! numbers), so a frame starts where the index changes; sorz's animations composed of another's
//! frames in another order count as that other's frames (`canonical`). The entities are numbered
//! as the traces' comparison numbers them (`trace_compare.numbering`), so that two runs from
//! power-on whose front ends make other entities number the round's alike.
const std = @import("std");
const json = std.json;
const trace_compare = @import("trace_compare.zig");

/// A probe's line: the display tick, the scene's tick, the entity, its animation and frame.
pub const Line = struct {
    v: i64,
    t: i64,
    e: i64,
    anim: []const u8,
    frame: i64,
};

pub const Error = error{ BadProbe, OutOfMemory };

/// The lines of a probe (its other fields, the boxes and the power, are not read).
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error![]const Line {
    var out: std.ArrayList(Line) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        const value = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch return error.BadProbe;
        if (value != .object) return error.BadProbe;
        const o = value.object;
        try out.append(arena, .{
            .v = int(o, "v") orelse return error.BadProbe,
            .t = int(o, "t") orelse return error.BadProbe,
            .e = int(o, "e") orelse return error.BadProbe,
            .anim = switch (o.get("anim") orelse .null) {
                .string => |s| s,
                .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
                else => "",
            },
            .frame = int(o, "frame") orelse 0,
        });
    }
    return out.items;
}

fn int(o: json.ObjectMap, name: []const u8) ?i64 {
    return switch (o.get(name) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

/// sorz's animations composed of another's frames in another order, by the extractor
/// (extract/entities.zig): their frames as that other animation's, as the original shows them.
pub const composed = [_]struct { name: []const u8, of: []const u8, frames: []const i64 }{
    // The back drop's landing: the vault's frames 3, 2 and 1, backward.
    .{ .name = "vault_land", .of = "vault", .frames = &.{ 3, 2, 1 } },
};

pub const Frame = struct { anim: []const u8, frame: i64 };

/// Frame `frame` of animation `anim` as the original shows it (`composed`).
pub fn canonical(anim: []const u8, frame: i64) Frame {
    for (composed) |c| {
        if (!std.mem.eql(u8, anim, c.name) or frame < 0 or frame >= c.frames.len) continue;
        return .{ .anim = c.of, .frame = c.frames[@intCast(frame)] };
    }
    return .{ .anim = anim, .frame = frame };
}

/// A run's probe and what places it: its lines, its trace's numbers, and the display ticks of
/// the scene compared (from `v0`, before `v1`); the lines before it say where each entity was.
pub const Run = struct {
    lines: []const Line,
    numbers: *const trace_compare.Numbers,
    v0: i64,
    v1: i64,
};

/// A frame that starts: its tick and index.
pub const Start = struct { t: i64, frame: i64 };

pub const Difference = struct {
    /// The entity's number, and the tick of the first start that differs.
    e: i64,
    t: i64,
    /// What each run started then (null: it started nothing more).
    a: ?Start,
    b: ?Start,
};

pub const Result = struct {
    entities: usize,
    differing: usize,
    /// The first difference by tick.
    first: ?Difference,
};

/// Compares the frames `b` starts with those `a` (the reference) starts, entity by entity.
pub fn compare(arena: std.mem.Allocator, a: Run, b: Run) Error!Result {
    var sa = try startsOf(arena, a);
    var sb = try startsOf(arena, b);
    var ids: std.ArrayList(i64) = .empty;
    for ([_]*std.AutoArrayHashMapUnmanaged(i64, std.ArrayList(Start)){ &sa, &sb }) |m| {
        for (m.keys()) |e| if (std.mem.indexOfScalar(i64, ids.items, e) == null) try ids.append(arena, e);
    }
    var result: Result = .{ .entities = ids.items.len, .differing = 0, .first = null };
    for (ids.items) |e| {
        const x: []const Start = if (sa.get(e)) |l| l.items else &.{};
        const y: []const Start = if (sb.get(e)) |l| l.items else &.{};
        for (0..@max(x.len, y.len)) |i| {
            const p: ?Start = if (i < x.len) x[i] else null;
            const q: ?Start = if (i < y.len) y[i] else null;
            if (p != null and q != null and std.meta.eql(p.?, q.?)) continue;
            const t = @min(if (p) |s| s.t else std.math.maxInt(i64), if (q) |s| s.t else std.math.maxInt(i64));
            result.differing += 1;
            if (result.first == null or t < result.first.?.t or (t == result.first.?.t and e < result.first.?.e))
                result.first = .{ .e = e, .t = t, .a = p, .b = q };
            break;
        }
    }
    return result;
}

/// Each entity's frame starts within the run's scene: where its frame's index changes (its
/// first line in the scene, when none came before, too).
fn startsOf(arena: std.mem.Allocator, r: Run) Error!std.AutoArrayHashMapUnmanaged(i64, std.ArrayList(Start)) {
    var last: std.AutoHashMapUnmanaged(i64, i64) = .empty;
    var out: std.AutoArrayHashMapUnmanaged(i64, std.ArrayList(Start)) = .empty;
    for (r.lines) |l| {
        if (l.v >= r.v1) break;
        const e = if (l.e <= 2) l.e else r.numbers.get(l.e) orelse continue;
        const frame = canonical(l.anim, l.frame).frame;
        const was = last.get(e);
        try last.put(arena, e, frame);
        if (l.v < r.v0 or (was != null and was.? == frame)) continue;
        const gop = try out.getOrPut(arena, e);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, .{ .t = l.t, .frame = frame });
    }
    return out;
}

/// The display ticks of the last scene named `name` in `trace` (from its first event, before
/// the next scene's), as `Run` takes them.
pub fn sceneTicks(trace: *const trace_compare.Trace, name: []const u8) ?[2]i64 {
    var k: ?u32 = null;
    for (trace.scenes, 0..) |s, i| if (std.mem.eql(u8, s, name)) {
        k = @intCast(i + 1);
    };
    const scene = k orelse return null;
    var v0: ?i64 = null;
    for (trace.events) |e| {
        if (e.scene == scene and v0 == null) v0 = e.v;
        if (e.scene > scene) return .{ v0 orelse e.v, e.v };
    }
    return .{ v0 orelse 0, std.math.maxInt(i64) };
}

const testing = std.testing;

test "frames compared by their starts: the first that differs, entities renumbered" {
    const arena_state = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(arena_state);
    defer arena.deinit();
    const a = arena.allocator();
    const ref = try parse(a,
        \\{"v":8,"t":0,"e":1,"anim":16,"frame":0}
        \\{"v":10,"t":1,"e":1,"anim":24,"frame":1}
        \\{"v":10,"t":1,"e":40,"anim":0,"frame":0}
        \\{"v":12,"t":2,"e":1,"anim":24,"frame":1,"atk":[0,1,2,3,4,5]}
        \\{"v":16,"t":4,"e":1,"anim":8,"frame":2}
        \\{"v":16,"t":4,"e":40,"anim":2,"frame":1}
    );
    const z = try parse(a,
        \\{"v":8,"t":0,"e":1,"anim":"jump","frame":0}
        \\{"v":10,"t":1,"e":1,"anim":"walk","frame":1}
        \\{"v":10,"t":1,"e":7,"anim":"down","frame":0}
        \\{"v":14,"t":3,"e":1,"anim":"walk","frame":2}
        \\{"v":16,"t":4,"e":7,"anim":"walk","frame":1}
    );
    var na: trace_compare.Numbers = .empty;
    try na.put(a, 40, 3);
    var nb: trace_compare.Numbers = .empty;
    try nb.put(a, 7, 3);
    const r = try compare(a, .{ .lines = ref, .numbers = &na, .v0 = 10, .v1 = 100 }, .{ .lines = z, .numbers = &nb, .v0 = 10, .v1 = 100 });
    try testing.expectEqual(@as(usize, 2), r.entities);
    try testing.expectEqual(@as(usize, 1), r.differing);
    // Entity 1's second frame starts a tick early in the second run.
    try testing.expectEqual(@as(i64, 1), r.first.?.e);
    try testing.expectEqual(@as(i64, 3), r.first.?.t);
    try testing.expectEqual(Start{ .t = 4, .frame = 2 }, r.first.?.a.?);
    try testing.expectEqual(Start{ .t = 3, .frame = 2 }, r.first.?.b.?);
    // sorz's composed animation: the vault's frames.
    try testing.expectEqual(@as(i64, 3), canonical("vault_land", 0).frame);
}

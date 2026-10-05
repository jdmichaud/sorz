//! similar-check's enemies and items (PLAN item 12): the catalogue's ai-* and item-* families
//! (sorz's copies in tests/scenarios/enemies, with item-knife and item-bat, sorz's own: the knife
//! and the bat in a player's hand): round 1's recorded play (`start pads`, the file the check is
//! given, which the repository does not hold) to a wave, then the player stands, presses B every
//! other tick, or goes for an item. Each run, sor-remaster plays it from power-on (its runs kept in
//! OUT_DIR/enemies while its agent and the scenario stay the same, several at once) and sorz
//! takes it up from the reference's situation at the script's start, as the moves' runs do.
//! Then:
//!
//! - run by run (both programs are deterministic from the same situation): the traces from the
//!   situation's tick, as the moves' are compared, the same or not; where not, the first
//!   difference and the kind of the entity it is about;
//! - per kind of enemy and of thing thrown, over every run (DESIGN.md V3: the AI's delays,
//!   ranges and choices, as distributions over many runs), the catalogue's measures (its tool
//!   m_ai) from each program's trace: each state's ticks and the states it goes to; an attack's
//!   place from player 1 at its start and its blows (their tick, damage and reaction); the
//!   health coming out of hiding; a thrown thing's flights and hits. (Not the speeds m_ai lists:
//!   a walk's toward a point takes as many values as places, which the runs compare.)
//!
//! An enemy (or a thrown thing) is equal when every measure is; within tolerance when every
//! measure is within its `How`'s; else different. An item's family is equal when all its runs
//! are the same, else different.
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");

const compare = agent.trace_compare;
const Event = compare.Event;
const json = std.json;

pub const Family = struct {
    name: []const u8,
    /// What it plays, as the report says it.
    what: []const u8,
    /// An item's family, judged run by run.
    item: bool = false,
    /// sorz plays it from power-on too, as sor-remaster does, not taken up at the script's
    /// start: a second player's join is the round screen's, and the run is the game's own
    /// (compared from the script's start all the same).
    power_on: bool = false,
};

/// The catalogue's families of the enemies and the items.
pub const families = [_]Family{
    .{ .name = "ai-first-wave", .what = "the first wave, from the round's start" },
    .{ .name = "ai-s1", .what = "the first stop: stalkers and Galsias" },
    .{ .name = "ai-s1-mash", .what = "the first stop, B pressed" },
    .{ .name = "ai-s1b", .what = "past the first stop: Galsias, one by a shutter, Signal" },
    .{ .name = "ai-s1b-mash", .what = "past the first stop, B pressed" },
    .{ .name = "ai-s2", .what = "the second stop: Galsias, Signal" },
    .{ .name = "ai-s2-mash", .what = "the second stop, B pressed" },
    .{ .name = "ai-s2b", .what = "past the second stop: an acrobat, Galsias, stalkers" },
    .{ .name = "ai-s2b-mash", .what = "past the second stop, B pressed" },
    .{ .name = "ai-s2c", .what = "past the second stop: the pipe Galsia, a stalker" },
    .{ .name = "ai-s2c-mash", .what = "the pipe Galsia, B pressed" },
    .{ .name = "ai-s3", .what = "the third stop: stalkers, Galsias, the pipe Galsia, an acrobat" },
    .{ .name = "ai-s3-mash", .what = "the third stop, B pressed" },
    .{ .name = "ai-s3b", .what = "past the third stop: brawlers, Galsias, a stalker" },
    .{ .name = "ai-s3b-mash", .what = "past the third stop, B pressed" },
    .{ .name = "ai-s3c", .what = "past the third stop: the knife Galsia" },
    .{ .name = "ai-s3c-mash", .what = "the knife Galsia, B pressed" },
    .{ .name = "ai-s4", .what = "the last stop: the knife Galsia, a Galsia, a brawler" },
    .{ .name = "ai-s4-mash", .what = "the last stop, B pressed" },
    .{ .name = "ai-boss", .what = "Antonio's arrival" },
    .{ .name = "ai-boss-mash", .what = "Antonio, B pressed" },
    // Not the catalogue's: taken up before Antonio comes, so that the round's script brings him.
    .{ .name = "ai-boss-script", .what = "Antonio brought by the round's script, the player standing" },
    .{ .name = "ai-boss-script-mash", .what = "Antonio brought by the round's script, B pressed to his end" },
    // Not the catalogue's: the acrobat under each character's lifting or launching blows, the
    // characters a recorded play of Axel brings to it (Adam joining as player 2).
    .{ .name = "ai-acrobat-adam-lift", .what = "the acrobat lifted by Adam's uppercut, knocked off by his fourth blow", .power_on = true },
    .{ .name = "ai-acrobat-axel-combo", .what = "the acrobat knocked down by the end of Axel's combo", .power_on = true },
    .{ .name = "item-apple-reach", .what = "the apple: taken from across", .item = true },
    .{ .name = "item-beef", .what = "the beef: taken after a knock-down", .item = true },
    .{ .name = "item-pipe", .what = "the pipe: dropped by its Galsia, picked up and swung", .item = true },
    // Not the catalogue's: the knife in a player's hand, its stab and its throw.
    .{ .name = "item-knife", .what = "the knife: dropped by its Galsia, picked up, stabbed and thrown", .item = true },
    // Not the catalogue's: the bat out of its breakable, swung until it splinters.
    .{ .name = "item-bat", .what = "the bat: out of its breakable, picked up, swung until it splinters, then a stab", .item = true },
};

/// The kinds measured: the enemies, and the things they throw (and the players pick up).
const fighters = [_][]const u8{ "galsia", "galsia_stalker", "galsia_knife", "galsia_pipe", "signal", "acrobat", "brawler", "antonio" };
const thrown = [_][]const u8{ "knife", "boomerang", "pipe" };
/// The states that are attacks: their place at the start and their blows are measured.
const attacks = [_][]const u8{ "punch", "slide", "hold", "stab", "throw", "swing", "grab", "sneak", "jump_in", "jump_kick", "somersault", "dash", "lunge", "throw_knives", "charge", "slash", "burst", "hug", "close_in", "flip" };
/// Left out of the traces, as the moves' comparison leaves them: none.
const ignored_kinds = [_][]const u8{};
const ignored_events = [_][]const u8{"timer"};
/// A run from power-on: the front end's objects (sor-remaster's) and sorz's own section events
/// left out as round-check leaves them, the entities numbered by their order of appearance.
const front_end_kinds = [_][]const u8{ "screen_object", "select_cursor", "select_portrait" };
const power_on_ignored_events = [_][]const u8{ "timer", "section" };
const ignored_fields = [_][]const u8{"vh"};

pub const Config = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Lives as long as the check.
    arena: std.mem.Allocator,
    rom_path: []const u8,
    remaster: []const u8,
    assets: sorz.platform.AssetSource,
    sound_names: []const compare.Rename,
    scenarios_dir: []const u8,
    out_path: []const u8,
    /// The recorded play the scenarios start from.
    pads: []const u8,
    /// Every `every`-th run of each family.
    every: u32 = 1,
    /// sor-remaster's runs at once.
    jobs: u32 = 4,
    /// The families to run (all when empty).
    only: []const []const u8 = &.{},
};

pub const Summary = struct {
    runs: usize = 0,
    same: usize = 0,
    /// The enemies' and the items' verdicts: equal, within tolerance, different.
    counts: [3]usize = .{ 0, 0, 0 },
    failed: bool = false,
};

const Verdict = enum { equal, within, different };

/// A run: its family, its name and its scenario's text.
const Spec = struct {
    family: usize,
    name: []const u8,
    text: []const u8,
};

/// A run's outcome by run: whether it is the same, else its first difference and its kind.
const Outcome = struct {
    same: bool,
    failed: bool = false,
    /// The first difference, as trace-compare writes it, and the kind of entity it is about.
    first: []const u8 = "",
    kind: []const u8 = "",
};

/// The report's text, and where it is shown as it grows.
pub const Report = struct {
    text: *std.Io.Writer.Allocating,
    out: *std.Io.Writer,
    /// How much of the text is shown.
    shown: *usize,

    fn flush(r: Report) !void {
        try r.out.writeAll(r.text.written()[r.shown.*..]);
        try r.out.flush();
        r.shown.* = r.text.written().len;
    }
};

/// Runs the families, writes their report.
pub fn check(c: *const Config, report: Report) !Summary {
    const arena = c.arena;
    const w = &report.text.writer;
    const dir = try std.fmt.allocPrint(arena, "{s}/enemies", .{c.out_path});
    try std.Io.Dir.cwd().createDirPath(c.io, dir);

    // The runs.
    var specs: std.ArrayList(Spec) = .empty;
    for (families, 0..) |f, k| {
        if (c.only.len != 0) {
            for (c.only) |n| {
                if (std.mem.eql(u8, n, f.name)) break;
            } else continue;
        }
        const file = try std.fmt.allocPrint(arena, "{s}/{s}.scn", .{ c.scenarios_dir, f.name });
        const text = std.Io.Dir.cwd().readFileAlloc(c.io, file, arena, .limited(1 << 20)) catch |e| {
            try w.print("{s}: cannot read {s}: {s}\n", .{ f.name, file, @errorName(e) });
            return error.NoScenario;
        };
        const padded = try withPads(arena, text, c.pads);
        if (try familyOf(arena, text)) |fam| {
            var i: usize = 0;
            while (i < fam.values.len) : (i += c.every) {
                const v = fam.values[i];
                var expanded = try std.mem.replaceOwned(u8, arena, padded, fam.variable, try std.fmt.allocPrint(arena, "{d}", .{v}));
                if (fam.other) |o| expanded = try std.mem.replaceOwned(u8, arena, expanded, o.variable, o.value);
                try specs.append(arena, .{ .family = k, .name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ f.name, v }), .text = expanded });
            }
        } else try specs.append(arena, .{ .family = k, .name = f.name, .text = padded });
    }

    try w.print(
        \\
        \\The enemies and the items (PLAN item 12): the catalogue's ai-* and item-* families, {s}
        \\of each, sorz taken up from sor-remaster's situation at the script's start.
        \\Run by run, the traces from there (the moves' events left out the same); per enemy and
        \\thing thrown, the catalogue's measures over every run (m_ai): equal when all are; within
        \\tolerance when as many (a tenth, at least one) with medians and means within a tenth (at
        \\least a tick or a pixel), shares within 0.1, the same values seen; else different.
        \\
        \\
    , .{if (c.every == 1) "every run" else try std.fmt.allocPrint(arena, "every {d}{s} run", .{ c.every, ordinalSuffix(c.every) })});
    try report.flush();

    const reference_ok = try references(c, dir, specs.items);

    // Each run: sorz, the comparison, the measures, in an arena of its own.
    var ref_acc: Acc = .{ .arena = arena };
    var z_acc: Acc = .{ .arena = arena };
    const outcomes = try arena.alloc(Outcome, specs.items.len);
    var summary: Summary = .{};
    for (specs.items, 0..) |s, i| {
        summary.runs += 1;
        if (!reference_ok[i]) {
            outcomes[i] = .{ .same = false, .failed = true, .first = "sor-remaster's run did not end as the scenario does" };
            summary.failed = true;
            continue;
        }
        var run_arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer run_arena.deinit();
        outcomes[i] = runOne(c, run_arena.allocator(), dir, s, &ref_acc, &z_acc) catch |e| blk: {
            summary.failed = true;
            break :blk .{ .same = false, .failed = true, .first = try std.fmt.allocPrint(arena, "the run failed: {s}", .{@errorName(e)}) };
        };
        if (outcomes[i].same) summary.same += 1;
    }

    // Run by run, family by family.
    for (families, 0..) |f, k| {
        var runs: usize = 0;
        var same: usize = 0;
        for (specs.items, outcomes) |s, o| if (s.family == k) {
            runs += 1;
            if (o.same) same += 1;
        };
        if (runs == 0) continue;
        if (f.item) {
            const v: Verdict = if (same == runs) .equal else .different;
            summary.counts[@backingInt(v)] += 1;
            try w.print("{s} ({s}): {s}, {d} runs, {d} the same\n", .{ f.name, f.what, verdictName(v), runs, same });
        } else try w.print("{s} ({s}): {d} runs, {d} the same\n", .{ f.name, f.what, runs, same });
        var shown: usize = 0;
        for (specs.items, outcomes) |s, o| if (s.family == k and !o.same) {
            if (shown == 3) {
                try w.print("    and {d} more\n", .{runs - same - shown});
                break;
            }
            try w.print("    {s}: {s}{s}{s}\n", .{ s.name, o.first, if (o.kind.len != 0) " -- about " else "", o.kind });
            shown += 1;
        };
    }
    try w.writeAll("\n");
    try report.flush();

    // Per kind.
    var kinds: std.ArrayList([]const u8) = .empty;
    for (fighters ++ thrown) |k| {
        if (ref_acc.kinds.get(k) != null or z_acc.kinds.get(k) != null) try kinds.append(arena, k);
    }
    for (kinds.items) |k| {
        const r = ref_acc.kinds.getPtr(k);
        const z = z_acc.kinds.getPtr(k);
        // Nothing to measure: no state of its began and ended within the runs (in hiding all along).
        if ((r == null or r.?.measures.count() == 0) and (z == null or z.?.measures.count() == 0)) {
            try w.print("{s}: not measured (none of its states began and ended within the runs)\n", .{k});
            continue;
        }
        const v = try reportKind(arena, k, r, z, specs.items, outcomes, w);
        summary.counts[@backingInt(v)] += 1;
        try report.flush();
    }
    return summary;
}

fn ordinalSuffix(n: u32) []const u8 {
    if (n % 100 >= 11 and n % 100 <= 13) return "th";
    return switch (n % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
}

fn verdictName(v: Verdict) []const u8 {
    return switch (v) {
        .equal => "equal",
        .within => "within tolerance",
        .different => "different",
    };
}

// The scenarios ------------------------------------------------------------------------------

/// The scenario with its recorded play's file replaced by `pads`.
fn withPads(arena: std.mem.Allocator, text: []const u8, pads: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const a = words.next() orelse "";
        const b = words.next() orelse "";
        _ = words.next() orelse "";
        const v = words.next() orelse "";
        if (std.mem.eql(u8, a, "start") and std.mem.eql(u8, b, "pads") and words.next() == null) {
            try out.writer.print("start pads {s} {s}", .{ pads, v });
        } else try out.writer.writeAll(line);
    }
    return out.written();
}

/// The display ticks of the recorded play a scenario starts with (`start pads FILE V`), if it
/// does.
fn padsStart(text: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        if (!std.mem.eql(u8, words.next() orelse continue, "start")) continue;
        if (!std.mem.eql(u8, words.next() orelse return null, "pads")) return null;
        _ = words.next() orelse return null;
        return std.fmt.parseInt(u64, words.next() orelse return null, 10) catch null;
    }
    return null;
}

const FamilyOf = struct {
    variable: []const u8,
    values: []const u32,
    other: ?struct { variable: []const u8, value: []const u8 } = null,
};

/// A family's header: "# A family: {V} takes the values A to B (R runs)", the values evenly
/// spread from A to B, or "... the values A, B, C (R runs)"; then maybe "; {X} is WORD".
fn familyOf(arena: std.mem.Allocator, text: []const u8) !?FamilyOf {
    const head = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    const key = "# A family: ";
    if (!std.mem.startsWith(u8, head, key)) return null;
    const rest = head[key.len..];
    const close = std.mem.indexOfScalar(u8, rest, '}') orelse return error.BadFamily;
    const variable = rest[0 .. close + 1];
    const values_key = " takes the values ";
    const at = std.mem.indexOf(u8, rest, values_key) orelse return error.BadFamily;
    const open = std.mem.indexOfScalarPos(u8, rest, at, '(') orelse return error.BadFamily;
    const list = std.mem.trim(u8, rest[at + values_key.len .. open], " ");
    const runs = std.fmt.parseInt(u32, rest[open + 1 .. std.mem.indexOfScalarPos(u8, rest, open, ' ') orelse return error.BadFamily], 10) catch return error.BadFamily;
    var values: std.ArrayList(u32) = .empty;
    if (std.mem.indexOf(u8, list, " to ")) |to| {
        const a = std.fmt.parseInt(u32, list[0..to], 10) catch return error.BadFamily;
        const b = std.fmt.parseInt(u32, list[to + 4 ..], 10) catch return error.BadFamily;
        if (runs < 2) return error.BadFamily;
        const span = if (b > a) b - a else a - b;
        if (span % (runs - 1) != 0) return error.BadFamily;
        const step = span / (runs - 1);
        for (0..runs) |i| try values.append(arena, if (b > a) a + step * @as(u32, @intCast(i)) else a - step * @as(u32, @intCast(i)));
    } else {
        var it = std.mem.tokenizeAny(u8, list, ", ");
        while (it.next()) |n| try values.append(arena, std.fmt.parseInt(u32, n, 10) catch return error.BadFamily);
        if (values.items.len != runs) return error.BadFamily;
    }
    var fam: FamilyOf = .{ .variable = variable, .values = values.items };
    if (std.mem.indexOf(u8, rest[open..], "; {")) |semi| {
        const o = rest[open + semi + 2 ..];
        const o_close = std.mem.indexOfScalar(u8, o, '}') orelse return error.BadFamily;
        const is_key = "} is ";
        if (!std.mem.startsWith(u8, o[o_close..], is_key)) return error.BadFamily;
        const value = std.mem.trimEnd(u8, o[o_close + is_key.len ..], ". ");
        fam.other = .{ .variable = o[0 .. o_close + 1], .value = value };
    }
    return fam;
}

// sor-remaster's runs --------------------------------------------------------------------------

/// sor-remaster's run of each spec, `jobs` at once, unless the one kept is of the same agent and
/// scenario. Returns whether each ended as its scenario does.
fn references(c: *const Config, dir: []const u8, specs: []const Spec) ![]bool {
    const arena = c.arena;
    const cwd = std.Io.Dir.cwd();
    const io = c.io;
    // The agent's mark: its path, size and time. Another empties what was kept.
    const st = try cwd.statFile(io, c.remaster, .{});
    const mark = try std.fmt.allocPrint(arena, "{s} {d} {d}\n", .{ c.remaster, st.size, st.mtime.nanoseconds });
    const mark_path = try std.fmt.allocPrint(arena, "{s}/agent", .{dir});
    const kept_mark = cwd.readFileAlloc(io, mark_path, arena, .limited(4096)) catch "";
    const keep = std.mem.eql(u8, kept_mark, mark);
    try cwd.writeFile(io, .{ .sub_path = mark_path, .data = mark });

    const ok = try arena.alloc(bool, specs.len);
    var due: std.ArrayList(usize) = .empty;
    for (specs, 0..) |s, i| {
        ok[i] = false;
        const scn = try std.fmt.allocPrint(arena, "{s}/ref-{s}.scn", .{ dir, s.name });
        if (keep) {
            const kept = cwd.readFileAlloc(io, scn, arena, .limited(1 << 20)) catch "";
            if (std.mem.eql(u8, kept, s.text) and ended(c, dir, s.name)) {
                ok[i] = true;
                continue;
            }
        }
        try cwd.writeFile(io, .{ .sub_path = scn, .data = s.text });
        try due.append(arena, i);
    }

    // The runs due, `jobs` at a time, each writing its summary into its .out file.
    const Running = struct { child: std.process.Child, file: std.Io.File };
    var running: std.ArrayList(Running) = .empty;
    var next: usize = 0;
    while (next < due.items.len or running.items.len != 0) {
        while (next < due.items.len and running.items.len < c.jobs) : (next += 1) {
            const s = specs[due.items[next]];
            const p = struct {
                fn of(a: std.mem.Allocator, d: []const u8, n: []const u8, ext: []const u8) ![]const u8 {
                    return std.fmt.allocPrint(a, "{s}/ref-{s}{s}", .{ d, n, ext });
                }
            }.of;
            const file = try cwd.createFile(io, try p(arena, dir, s.name, ".out"), .{});
            const child = std.process.spawn(io, .{
                .argv = &.{ c.remaster, c.rom_path, "--scenario", try p(arena, dir, s.name, ".scn"), "--trace-events", try p(arena, dir, s.name, ".jsonl"), "--probe", try p(arena, dir, s.name, ".probe"), "--frames", "100000" },
                .stdin = .ignore,
                .stdout = .{ .file = file },
                .stderr = .ignore,
            }) catch |e| {
                file.close(io);
                return e;
            };
            try running.append(arena, .{ .child = child, .file = file });
        }
        var r = running.orderedRemove(0);
        _ = try r.child.wait(io);
        r.file.close(io);
    }
    for (due.items) |i| ok[i] = ended(c, dir, specs[i].name);
    return ok;
}

/// Whether sor-remaster's kept run of `name` ended as its scenario does.
fn ended(c: *const Config, dir: []const u8, name: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/ref-{s}.out", .{ dir, name }) catch return false;
    var text_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&text_buf);
    const text = std.Io.Dir.cwd().readFileAlloc(c.io, path, fba.allocator(), .limited(text_buf.len)) catch return false;
    return std.mem.indexOf(u8, text, "\"scenario\":\"done\"") != null;
}

// A run ----------------------------------------------------------------------------------------

/// sorz's run of `s` from the reference's situation (or from power-on, a `power_on` family's);
/// both traces compared and measured.
fn runOne(c: *const Config, arena: std.mem.Allocator, dir: []const u8, s: Spec, ref_acc: *Acc, z_acc: *Acc) !Outcome {
    const cwd = std.Io.Dir.cwd();
    const io = c.io;
    const p = struct {
        fn of(a: std.mem.Allocator, d: []const u8, prefix: []const u8, n: []const u8, ext: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "{s}/{s}{s}{s}", .{ d, prefix, n, ext });
        }
    }.of;
    const scn = try p(arena, dir, "ref-", s.name, ".scn");
    const ref_trace = try p(arena, dir, "ref-", s.name, ".jsonl");
    const ref_probe = try p(arena, dir, "ref-", s.name, ".probe");
    const z_trace = try p(arena, dir, "z-", s.name, ".jsonl");
    const said_ref = try cwd.readFileAlloc(io, try p(arena, dir, "ref-", s.name, ".out"), arena, .limited(1 << 20));
    const game_tick: ?u32 = blk: {
        const line = json.parseFromSliceLeaky(json.Value, arena, std.mem.trim(u8, said_ref, " \r\n"), .{}) catch break :blk null;
        if (line != .object) break :blk null;
        const g = line.object.get("script_game_tick") orelse break :blk null;
        break :blk if (g == .integer) @intCast(g.integer) else null;
    };
    var said: std.Io.Writer.Allocating = .init(arena);
    const done = if (families[s.family].power_on)
        try agent.scenario_cmd.run(c.gpa, io, c.assets, .{ .scenario = scn, .trace = z_trace }, &said.writer)
    else
        try agent.scenario_cmd.run(c.gpa, io, c.assets, .{ .scenario = scn, .situation = ref_trace, .situation_probe = ref_probe, .game_tick = game_tick, .trace = z_trace }, &said.writer);
    if (!done) return .{ .same = false, .failed = true, .first = try c.arena.dupe(u8, std.mem.trim(u8, said.written(), " \r\n")) };

    const ref_text = try cwd.readFileAlloc(io, ref_trace, arena, .limited(1 << 30));
    const z_text = try cwd.readFileAlloc(io, z_trace, arena, .limited(1 << 30));
    // The situation sorz took up: at play's start, or after the recorded play's last display tick.
    const at: ?u64 = if (padsStart(s.text)) |v| v + 1 else null;
    const t0: i64 = @intCast((try agent.scenario.situationOf(arena, ref_text, at)).t);
    const power_on = families[s.family].power_on;
    const options: compare.Options = .{
        .from_scene = "round",
        .after = t0,
        .ignore_kinds = if (power_on) &front_end_kinds else &ignored_kinds,
        .ignore = if (power_on) &power_on_ignored_events else &ignored_events,
        .ignore_fields = &ignored_fields,
        .sound_names = c.sound_names,
        .renumber = power_on,
    };
    var diag: compare.Diagnostic = .{};
    const a_full = try compare.parse(arena, ref_text, &diag);
    const b_full = try compare.parse(arena, z_text, &diag);
    const a = try compare.restrict(arena, &a_full, options, true);
    const b = try compare.restrict(arena, &b_full, options, false);
    var written: std.Io.Writer.Allocating = .init(arena);
    const result = try compare.compare(arena, &a, &b, options, &written.writer);
    var outcome: Outcome = .{ .same = result.differences == 0 };
    if (result.first) |d| {
        const text = written.written();
        const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        outcome.first = try c.arena.dupe(u8, text[0..line_end]);
        const e: ?*const Event = d.a orelse d.b;
        if (e) |x| {
            const in_a = d.a != null;
            outcome.kind = try c.arena.dupe(u8, kindOf(if (in_a) a_full.events else b_full.events, x) orelse x.ev);
        }
    }

    // The measures, from the round's events of each.
    const round_options: compare.Options = .{ .from_scene = "round", .sound_names = c.sound_names };
    const a_round = try compare.restrict(arena, &a_full, round_options, true);
    const b_round = try compare.restrict(arena, &b_full, round_options, false);
    try measureRun(ref_acc, arena, a_full.events, a_round.events, t0, s.name);
    try measureRun(z_acc, arena, b_full.events, b_round.events, t0, s.name);
    return outcome;
}

/// The kind of the entity event `x` is about, from the spawns and the changes of kind before it.
fn kindOf(events: []const Event, x: *const Event) ?[]const u8 {
    const e = int(x.object, "e") orelse return null;
    var kind: ?[]const u8 = null;
    for (events) |y| {
        if (y.line > x.line) break;
        if (int(y.object, "e") != e) continue;
        if (std.mem.eql(u8, y.ev, "spawn") or std.mem.eql(u8, y.ev, "morph")) kind = str(y.object, "kind") orelse kind;
    }
    if (kind == null) {
        if (e == 1 or e == 2) return "player";
    }
    return kind;
}

// The measures -------------------------------------------------------------------------------

/// How a measure may differ from the reference's and still be within tolerance.
const How = enum {
    /// Numbers (ticks, pixels): as many (within a tenth, at least one), with the medians and
    /// the means within a tenth (at least one).
    distribution,
    /// Outcomes counted: each one's share within 0.1 of the reference's.
    shares,
    /// Values seen: the same ones, however often.
    seen,
};

const Measure = struct {
    how: How,
    nums: std.ArrayList(i64) = .empty,
    counts: std.StringArrayHashMapUnmanaged(u32) = .empty,
};

/// One program's measures, by kind, then by name.
const Acc = struct {
    arena: std.mem.Allocator,
    kinds: std.StringArrayHashMapUnmanaged(Kind) = .empty,

    const Kind = struct {
        entities: u32 = 0,
        runs: std.StringArrayHashMapUnmanaged(void) = .empty,
        measures: std.StringArrayHashMapUnmanaged(Measure) = .empty,
    };

    fn kind(acc: *Acc, name: []const u8) !*Kind {
        const gop = try acc.kinds.getOrPut(acc.arena, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try acc.arena.dupe(u8, name);
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    fn measure(acc: *Acc, k: *Kind, what: []const u8, how: How) !*Measure {
        const gop = try k.measures.getOrPut(acc.arena, what);
        if (!gop.found_existing) {
            gop.key_ptr.* = try acc.arena.dupe(u8, what);
            gop.value_ptr.* = .{ .how = how };
        }
        return gop.value_ptr;
    }

    fn num(acc: *Acc, k: *Kind, what: []const u8, how: How, x: i64) !void {
        const m = try acc.measure(k, what, how);
        try m.nums.append(acc.arena, x);
    }

    fn count(acc: *Acc, k: *Kind, what: []const u8, how: How, key: []const u8) !void {
        const m = try acc.measure(k, what, how);
        const gop = try m.counts.getOrPut(acc.arena, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try acc.arena.dupe(u8, key);
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }
};

/// An entity through the run's ticks.
const Ent = struct {
    kind: []const u8 = "",
    alive: bool = false,
    state: []const u8 = "",
    x: i64 = 0,
    d: i64 = 0,
    health: ?i64 = null,
    /// Seen in hiding (`appear`) in the window: its health coming out is measured.
    hiding: bool = false,
    thrown: bool = false,
    segments: std.ArrayList(Segment) = .empty,
};

/// A stretch of ticks in one state.
const Segment = struct {
    kind: []const u8,
    state: []const u8,
    start: i64,
    ticks: i64 = 0,
    end: enum { open, next, removed } = .open,
    /// Its place across and in depth from player 1 at its start (pixels), if player 1 was there.
    from_player: ?[2]i64,
    /// Its place across at its start, and the farthest it went across from there (pixels).
    x0: i64,
    reach: i64 = 0,
};

fn isOf(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const Hit = struct { t: i64, e: i64, by: ?i64, damage: i64, reaction: []const u8 };

/// The run's measures from its round's events (`events`; what the scenes before said of the
/// entities from `all`, the whole trace: the players and the round's first enemies come in its
/// intro), in the window from tick `t0` (the situation's) to the last.
fn measureRun(acc: *Acc, arena: std.mem.Allocator, all: []const Event, events: []const Event, t0: i64, run: []const u8) !void {
    var ents: std.AutoArrayHashMapUnmanaged(i64, Ent) = .empty;
    var hits: std.ArrayList(Hit) = .empty;
    var last: i64 = t0;
    for (events) |x| last = @max(last, x.t);
    if (events.len != 0) for (all) |x| {
        if (x.v >= events[0].v) break;
        const e = int(x.object, "e") orelse continue;
        if (std.mem.eql(u8, x.ev, "hit")) continue;
        const gop = try ents.getOrPut(arena, e);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        apply(gop.value_ptr, x);
    };
    // Player 1's place, when it is in play.
    var player: ?[2]i64 = null;
    var i: usize = 0;
    var t: i64 = t0;
    while (t <= last) : (t += 1) {
        while (i < events.len and events[i].t <= t) : (i += 1) {
            const x = events[i];
            const e = int(x.object, "e") orelse continue;
            if (std.mem.eql(u8, x.ev, "hit")) {
                if (x.t >= t0) try hits.append(arena, .{ .t = x.t, .e = e, .by = int(x.object, "by"), .damage = int(x.object, "damage") orelse 0, .reaction = str(x.object, "reaction") orelse "" });
                continue;
            }
            const gop = try ents.getOrPut(arena, e);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            apply(gop.value_ptr, x);
        }
        if (ents.getPtr(1)) |p| player = if (p.alive) .{ p.x, p.d } else null;
        for (ents.keys(), ents.values()) |id, *n| {
            if (id == 1 or id == 2) continue;
            if (!isOf(&fighters, n.kind) and !isOf(&thrown, n.kind)) {
                closeSegment(n, .removed);
                continue;
            }
            if (isOf(&thrown, n.kind)) n.thrown = true;
            if (!n.alive) {
                closeSegment(n, .removed);
                continue;
            }
            if (std.mem.eql(u8, n.state, "appear")) n.hiding = true else if (n.hiding and t > t0) {
                n.hiding = false;
                if (n.health) |h| if (isOf(&fighters, n.kind)) {
                    var buf: [24]u8 = undefined;
                    try acc.count(try acc.kind(n.kind), "health coming out of hiding", .seen, try std.fmt.bufPrint(&buf, "{d}", .{h}));
                };
            }
            const open = if (n.segments.items.len != 0) &n.segments.items[n.segments.items.len - 1] else null;
            if (open) |o| if (o.end == .open and (!std.mem.eql(u8, o.state, n.state) or !std.mem.eql(u8, o.kind, n.kind))) {
                o.end = .next;
            };
            const cur = if (n.segments.items.len != 0 and n.segments.items[n.segments.items.len - 1].end == .open) &n.segments.items[n.segments.items.len - 1] else blk: {
                try n.segments.append(arena, .{
                    .kind = n.kind,
                    .state = n.state,
                    .start = t,
                    .from_player = if (player) |pl| .{ pixels(n.x - pl[0]), pixels(n.d - pl[1]) } else null,
                    .x0 = n.x,
                });
                break :blk &n.segments.items[n.segments.items.len - 1];
            };
            cur.ticks += 1;
            cur.reach = @max(cur.reach, pixels(n.x - cur.x0));
        }
    }

    // The segments' measures.
    for (ents.keys(), ents.values()) |id, *n| {
        if (n.segments.items.len == 0) continue;
        var counted: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (n.segments.items, 0..) |s, k| {
            const kd = try acc.kind(s.kind);
            if (!counted.contains(s.kind)) {
                try counted.put(arena, s.kind, {});
                kd.entities += 1;
                try kd.runs.put(acc.arena, try acc.arena.dupe(u8, run), {});
            }
            var buf: [96]u8 = undefined;
            const complete = s.end != .open and s.start > t0;
            if (complete) {
                try acc.num(kd, try std.fmt.bufPrint(&buf, "{s}: ticks", .{s.state}), .distribution, s.ticks);
                const next = if (s.end == .next and k + 1 < n.segments.items.len) n.segments.items[k + 1].state else "(removed)";
                try acc.count(kd, try std.fmt.bufPrint(&buf, "{s}: next", .{s.state}), .shares, next);
            }
            if (n.thrown) {
                if ((std.mem.eql(u8, s.state, "flying") or std.mem.eql(u8, s.state, "out")) and complete) {
                    try acc.num(kd, "flight ticks", .distribution, s.ticks);
                    try acc.num(kd, "flight reach", .distribution, s.reach);
                }
                continue;
            }
            if (!isOf(&attacks, s.state) or s.start <= t0) continue;
            const fp = s.from_player orelse continue;
            try acc.num(kd, try std.fmt.bufPrint(&buf, "{s}: across from player 1 at its start", .{s.state}), .distribution, fp[0]);
            try acc.num(kd, try std.fmt.bufPrint(&buf, "{s}: in depth from player 1 at its start", .{s.state}), .distribution, fp[1]);
            var landed = false;
            for (hits.items) |h| {
                if (h.by != id or (h.e != 1 and h.e != 2)) continue;
                if (h.t < s.start or h.t >= s.start + s.ticks) continue;
                landed = true;
                try acc.num(kd, try std.fmt.bufPrint(&buf, "{s}: its blow's tick", .{s.state}), .distribution, h.t - s.start);
                var key: [48]u8 = undefined;
                try acc.count(kd, try std.fmt.bufPrint(&buf, "{s}: its blows (damage, reaction)", .{s.state}), .shares, try std.fmt.bufPrint(&key, "{d} {s}", .{ h.damage, h.reaction }));
            }
            try acc.count(kd, try std.fmt.bufPrint(&buf, "{s}: a blow landed", .{s.state}), .shares, if (landed) "yes" else "no");
        }
        // A thrown thing's hits.
        if (n.thrown) {
            const kd = try acc.kind(n.segments.items[0].kind);
            for (hits.items) |h| {
                if (h.by != id) continue;
                var key: [48]u8 = undefined;
                try acc.count(kd, if (h.e == 1 or h.e == 2) "hits on the players (damage, reaction)" else "hits on the enemies (damage, reaction)", .shares, try std.fmt.bufPrint(&key, "{d} {s}", .{ h.damage, h.reaction }));
            }
        }
    }
}

/// A distance in whole pixels (rounded) from one in 1/65536 pixel.
fn pixels(raw: i64) i64 {
    return @intFromFloat(@round(@abs(@as(f64, @floatFromInt(raw))) / 65536.0));
}

fn closeSegment(n: *Ent, how: @FieldType(Segment, "end")) void {
    if (n.segments.items.len == 0) return;
    const s = &n.segments.items[n.segments.items.len - 1];
    if (s.end == .open) s.end = how;
}

/// What event `x` says of the entity.
fn apply(n: *Ent, x: Event) void {
    const o = x.object;
    if (std.mem.eql(u8, x.ev, "spawn")) {
        n.* = .{ .segments = n.segments, .thrown = n.thrown };
        // A new entity under the same id (another program's numbering): its segments go on.
        n.alive = true;
        n.kind = str(o, "kind") orelse "";
        n.state = str(o, "state") orelse "";
        n.health = int(o, "health");
        place(n, o);
    } else if (std.mem.eql(u8, x.ev, "morph")) {
        n.kind = str(o, "kind") orelse n.kind;
    } else if (std.mem.eql(u8, x.ev, "remove")) {
        n.alive = false;
    } else if (std.mem.eql(u8, x.ev, "state")) {
        n.state = str(o, "state") orelse "";
    } else if (std.mem.eql(u8, x.ev, "pos")) {
        place(n, o);
    } else if (std.mem.eql(u8, x.ev, "health")) {
        n.health = int(o, "health");
    }
}

fn place(n: *Ent, o: json.ObjectMap) void {
    n.x = int(o, "x") orelse n.x;
    n.d = int(o, "d") orelse n.d;
}

// The report ---------------------------------------------------------------------------------

/// A kind's measures from both programs, compared and written: its verdict.
fn reportKind(arena: std.mem.Allocator, name: []const u8, ref: ?*Acc.Kind, z: ?*Acc.Kind, specs: []const Spec, outcomes: []const Outcome, w: *std.Io.Writer) !Verdict {
    var verdict: Verdict = .equal;
    var lines: std.Io.Writer.Allocating = .init(arena);
    var whats: std.ArrayList([]const u8) = .empty;
    if (ref) |r| for (r.measures.keys()) |k| try whats.append(arena, k);
    if (z) |zz| for (zz.measures.keys()) |k| {
        if (ref == null or ref.?.measures.get(k) == null) try whats.append(arena, k);
    };
    std.mem.sort([]const u8, whats.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var equal_measures: usize = 0;
    for (whats.items) |what| {
        const a: ?*const Measure = if (ref) |r| r.measures.getPtr(what) else null;
        const b: ?*const Measure = if (z) |zz| zz.measures.getPtr(what) else null;
        const v = try judge(arena, a, b);
        if (@backingInt(v) > @backingInt(verdict)) verdict = v;
        if (v == .equal) {
            equal_measures += 1;
            continue;
        }
        try lines.writer.print("    {s}: ", .{what});
        try writeMeasure(arena, &lines.writer, b);
        try lines.writer.writeAll(if (v == .within) "  [within tolerance; reference: " else "  [DIFFERENT; reference: ");
        try writeMeasure(arena, &lines.writer, a);
        try lines.writer.writeAll("]\n");
    }
    const entities = if (ref) |r| r.entities else 0;
    const runs = if (ref) |r| r.runs.count() else 0;
    try w.print("{s}: {s} ({d} entities in {d} runs; {d} of {d} measures equal)\n", .{ name, verdictName(verdict), entities, runs, equal_measures, whats.items.len });
    // The runs whose first difference is about it.
    var about: usize = 0;
    for (specs, outcomes) |s, o| if (!o.same and std.mem.eql(u8, o.kind, name)) {
        if (about < 3) try w.print("    first difference in {s}: {s}\n", .{ s.name, o.first });
        about += 1;
    };
    if (about > 3) try w.print("    and {d} more runs whose first difference is about it\n", .{about - 3});
    try w.writeAll(lines.written());
    return verdict;
}

fn judge(arena: std.mem.Allocator, a: ?*const Measure, b: ?*const Measure) !Verdict {
    const x = a orelse return .different;
    const y = b orelse return .different;
    switch (x.how) {
        .distribution => {
            const p = try sorted(arena, x.nums.items);
            const q = try sorted(arena, y.nums.items);
            if (std.mem.eql(i64, p, q)) return .equal;
            if (p.len == 0 or q.len == 0) return .different;
            if (!near(@floatFromInt(p.len), @floatFromInt(q.len))) return .different;
            if (!near(median(p), median(q))) return .different;
            if (!near(mean(p), mean(q))) return .different;
            return .within;
        },
        .shares, .seen => {
            var same = x.counts.count() == y.counts.count();
            if (same) for (x.counts.keys(), x.counts.values()) |k, n| {
                if (y.counts.get(k) != n) same = false;
            };
            if (same) return .equal;
            if (x.how == .seen) {
                if (x.counts.count() != y.counts.count()) return .different;
                for (x.counts.keys()) |k| if (y.counts.get(k) == null) return .different;
                return .within;
            }
            const tx: f64 = @floatFromInt(total(x));
            const ty: f64 = @floatFromInt(total(y));
            for (x.counts.keys(), x.counts.values()) |k, n| {
                const m: f64 = @floatFromInt(y.counts.get(k) orelse 0);
                if (@abs(@as(f64, @floatFromInt(n)) / tx - m / ty) > 0.1 + 1e-9) return .different;
            }
            for (y.counts.keys(), y.counts.values()) |k, m| {
                if (x.counts.get(k) != null) continue;
                if (@as(f64, @floatFromInt(m)) / ty > 0.1 + 1e-9) return .different;
            }
            return .within;
        },
    }
}

/// Within a tenth of the reference's, and at least one.
fn near(a: f64, b: f64) bool {
    return @abs(a - b) <= @max(1.0, @abs(a) / 10.0) + 1e-9;
}

fn total(m: *const Measure) u32 {
    var n: u32 = 0;
    for (m.counts.values()) |c| n += c;
    return n;
}

fn sorted(arena: std.mem.Allocator, xs: []const i64) ![]i64 {
    const out = try arena.dupe(i64, xs);
    std.mem.sort(i64, out, {}, std.sort.asc(i64));
    return out;
}

fn median(xs: []const i64) f64 {
    const n = xs.len;
    if (n % 2 == 1) return @floatFromInt(xs[n / 2]);
    return (@as(f64, @floatFromInt(xs[n / 2 - 1])) + @as(f64, @floatFromInt(xs[n / 2]))) / 2.0;
}

fn mean(xs: []const i64) f64 {
    var s: f64 = 0;
    for (xs) |x| s += @floatFromInt(x);
    return s / @as(f64, @floatFromInt(xs.len));
}

fn writeMeasure(arena: std.mem.Allocator, w: *std.Io.Writer, m: ?*const Measure) !void {
    const x = m orelse return w.writeAll("none");
    switch (x.how) {
        .distribution => {
            const p = try sorted(arena, x.nums.items);
            if (p.len == 0) return w.writeAll("none");
            try w.print("{d} of them, from {d} to {d}, median {d}, mean {d:.2}", .{ p.len, p[0], p[p.len - 1], median(p), mean(p) });
        },
        .shares, .seen => {
            const keys = try arena.dupe([]const u8, x.counts.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.less);
            for (keys, 0..) |k, i| {
                if (i == 12) {
                    try w.print(" ... ({d} values)", .{keys.len});
                    break;
                }
                try w.print("{s}{s} x{d}", .{ if (i == 0) "" else ", ", k, x.counts.get(k).? });
            }
        },
    }
}

fn str(o: json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(o: json.ObjectMap, name: []const u8) ?i64 {
    const v = o.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

test "a family's values: spread evenly, listed, and another variable's word" {
    const arena = std.testing.allocator;
    var state: std.heap.ArenaAllocator = .init(arena);
    defer state.deinit();
    const a = state.allocator();
    const f = (try familyOf(a, "# A family: {V} takes the values 2280 to 2342 (32 runs).\nstart pads x {V}\n")).?;
    try std.testing.expectEqualStrings("{V}", f.variable);
    try std.testing.expectEqual(@as(usize, 32), f.values.len);
    try std.testing.expectEqual(@as(u32, 2282), f.values[1]);
    const g = (try familyOf(a, "# A family: {N} takes the values 40, 30, 8 (3 runs); {DIR} is left.\n")).?;
    try std.testing.expectEqualSlices(u32, &.{ 40, 30, 8 }, g.values);
    try std.testing.expectEqualStrings("{DIR}", g.other.?.variable);
    try std.testing.expectEqualStrings("left", g.other.?.value);
    try std.testing.expect(try familyOf(a, "start axel\n") == null);
}

test "the recorded play's file is the one given" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const text = try withPads(state.allocator(), "# a\nstart pads ../../game.pads {V}\nwait 900\n", "/r/game.pads");
    try std.testing.expectEqualStrings("# a\nstart pads /r/game.pads {V}\nwait 900\n", text);
}

test "measures within tolerance: as many, medians and means within a tenth; shares within 0.1" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var x: Measure = .{ .how = .distribution };
    var y: Measure = .{ .how = .distribution };
    for ([_]i64{ 20, 22, 24 }) |n| try x.nums.append(a, n);
    for ([_]i64{ 21, 22, 24 }) |n| try y.nums.append(a, n);
    try std.testing.expectEqual(Verdict.within, try judge(a, &x, &y));
    y.nums.items[2] = 60;
    try std.testing.expectEqual(Verdict.different, try judge(a, &x, &y));
    var s: Measure = .{ .how = .shares };
    var u: Measure = .{ .how = .shares };
    try s.counts.put(a, "lurk", 9);
    try s.counts.put(a, "walk_off", 1);
    try u.counts.put(a, "lurk", 10);
    try std.testing.expectEqual(Verdict.within, try judge(a, &s, &u));
    try u.counts.put(a, "punch", 5);
    try std.testing.expectEqual(Verdict.different, try judge(a, &s, &u));
}

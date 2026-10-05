//! sorz-round-check: the gate of round 1's scene (PLAN item 13): round 1's scenarios
//! (tests/scenarios/round1) run from power-on, the whole game, in sor-remaster and in sorz, and
//! their round scenes' semantic traces compared event by event (agent/trace_compare.zig): the
//! round's tick at which each comes, the camera and the stop it follows to, the timer, play's
//! phases (the intro, play, the time overs, the end), the players' places, states, health, lives
//! and deaths, the continue's question and the game over, the entities the script places and
//! their first moves, the sounds.
//!
//!   sorz-round-check ROM REMASTER_AGENT SCENARIOS_DIR OUT_DIR [SCENARIO...]
//!
//! For each scenario (`scenarios` below, the file SCENARIOS_DIR/NAME.scn), sor-remaster's agent
//! runs it and writes its trace into OUT_DIR; sorz runs it in this process, on the content
//! extracted from the ROM (agent/game_run.zig), and writes its own. The comparison takes each
//! trace's round scene, its entities numbered by their order of appearance (sor-remaster's front
//! end makes objects that sorz's screens do not), without the effects sorz does not have yet (the
//! hit sparks) and sorz's own section events; and the game's clock as each script begins (which
//! the enemies' choices read) must be the same. Prints a line per scenario, its events and the
//! first difference; writes the comparisons into OUT_DIR/report.txt; exits with 1 when a
//! scenario's traces differ or a run fails.
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const extract = @import("extract");

const compare = agent.trace_compare;

pub const Scenario = struct {
    name: []const u8,
    /// What it shows, for the reader.
    what: []const u8,
};

/// Round 1's scenarios (tests/scenarios/round1).
pub const scenarios = [_]Scenario{
    .{ .name = "walk", .what = "a walk to the first wall: the camera's follow, the placed Galsias coming out" },
    .{ .name = "idle", .what = "standing still: the timer, three time overs and deaths, new lives, the continue's question" },
    .{ .name = "continue", .what = "the continue's YES: a new game's lives, the next life" },
    .{ .name = "gameover", .what = "the continue's NO: the game over's count, the fade out, the high scores" },
    .{ .name = "pause", .what = "two pauses: the pause's sounds, its ticks on the game's clock, play after it" },
};

/// The front end's objects (sor-remaster's) and the hit sparks (PLAN item 12): their events
/// are left out; and sorz's own section events.
const ignored_kinds = [_][]const u8{ "screen_object", "select_cursor", "select_portrait", "hit_spark" };
const ignored_events = [_][]const u8{"section"};

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    rom_path: []const u8,
    remaster: []const u8,
    assets: sorz.platform.AssetSource,
    sound_names: []const compare.Rename,
    scenarios_dir: []const u8,
    out_path: []const u8,
};

/// A scenario's run in both programs and its comparison: the verdict line.
fn runOne(c: *const Context, sc: *const Scenario, w: *std.Io.Writer) !bool {
    const arena = c.arena;
    const cwd = std.Io.Dir.cwd();
    const scn = try std.fmt.allocPrint(arena, "{s}/{s}.scn", .{ c.scenarios_dir, sc.name });
    const ref_trace = try std.fmt.allocPrint(arena, "{s}/ref-{s}.jsonl", .{ c.out_path, sc.name });
    const z_trace = try std.fmt.allocPrint(arena, "{s}/z-{s}.jsonl", .{ c.out_path, sc.name });

    const ran = try std.process.run(c.gpa, c.io, .{ .argv = &.{ c.remaster, c.rom_path, "--scenario", scn, "--trace-events", ref_trace, "--frames", "200000" } });
    defer c.gpa.free(ran.stdout);
    defer c.gpa.free(ran.stderr);
    if (ran.term != .exited or ran.term.exited != 0 or std.mem.indexOf(u8, ran.stdout, "\"scenario\":\"done\"") == null) {
        try w.print("{s}: sor-remaster's run did not end as the scenario does: {s}{s}\n", .{ sc.name, ran.stdout, ran.stderr });
        return false;
    }
    var said: std.Io.Writer.Allocating = .init(arena);
    const done = try agent.scenario_cmd.run(c.gpa, c.io, c.assets, .{ .scenario = scn, .trace = z_trace }, &said.writer);
    if (!done) {
        try w.print("{s}: sorz's run did not end as the scenario does: {s}", .{ sc.name, said.written() });
        return false;
    }

    // The game's clock as the script begins, which the enemies' choices read: the same.
    const ref_clock = numberAfter(ran.stdout, "\"script_game_tick\":");
    const z_clock = numberAfter(said.written(), "\"script_game_tick\":");
    if (ref_clock == null or z_clock == null or ref_clock.? != z_clock.?) {
        try w.print("{s}: the game's clock as the script begins differs: {?d} against {?d}\n", .{ sc.name, ref_clock, z_clock });
        return false;
    }

    const options: compare.Options = .{
        .from_scene = "round",
        .renumber = true,
        .ignore_kinds = &ignored_kinds,
        .ignore = &ignored_events,
        .sound_names = c.sound_names,
    };
    var diag: compare.Diagnostic = .{};
    const a_full = try compare.parse(arena, try cwd.readFileAlloc(c.io, ref_trace, arena, .limited(1 << 30)), &diag);
    const b_full = try compare.parse(arena, try cwd.readFileAlloc(c.io, z_trace, arena, .limited(1 << 30)), &diag);
    const a = try compare.restrict(arena, &a_full, options, true);
    const b = try compare.restrict(arena, &b_full, options, false);
    var written: std.Io.Writer.Allocating = .init(arena);
    const result = try compare.compare(arena, &a, &b, options, &written.writer);
    var events: usize = 0;
    for (result.counts) |n| events += n.a;
    if (result.differences == 0) {
        try w.print("{s}: equal, {d} events ({s})\n", .{ sc.name, events, sc.what });
        return true;
    }
    try w.print("{s}: {d} differences in {d} events ({s})\n{s}\n", .{ sc.name, result.differences, events, sc.what, written.written() });
    return false;
}

/// The number after `key` in `text`.
fn numberAfter(text: []const u8, key: []const u8) ?u64 {
    const at = (std.mem.indexOf(u8, text, key) orelse return null) + key.len;
    var end = at;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(u64, text[at..end], 10) catch null;
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

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var text: std.Io.Writer.Allocating = .init(arena);
    try text.writer.writeAll("round-check: round 1's scenes in sorz against sor-remaster's, from power-on (PLAN item 13).\n\n");
    var failed = false;
    var printed: usize = 0;
    for (&scenarios) |*sc| {
        if (only.items.len != 0) {
            for (only.items) |n| {
                if (std.mem.eql(u8, n, sc.name)) break;
            } else continue;
        }
        var scenario_arena: std.heap.ArenaAllocator = .init(gpa);
        defer scenario_arena.deinit();
        const c: Context = .{
            .gpa = gpa,
            .io = io,
            .arena = scenario_arena.allocator(),
            .rom_path = rom_path,
            .remaster = remaster,
            .assets = source.assetSource(),
            .sound_names = try compare.soundNames(arena, sounds_json),
            .scenarios_dir = scenarios_dir,
            .out_path = out_path,
        };
        const ok = runOne(&c, sc, &text.writer) catch |e| blk: {
            try text.writer.print("{s}: the run failed: {s}\n", .{ sc.name, @errorName(e) });
            break :blk false;
        };
        if (!ok) failed = true;
        try out.interface.writeAll(text.written()[printed..]);
        try out.interface.flush();
        printed = text.written().len;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/report.txt", .{out_path}), .data = text.written() });
    if (failed) std.process.exit(1);
}

fn usage(io: std.Io) !void {
    return fail(io, "usage: sorz-round-check ROM REMASTER_AGENT SCENARIOS_DIR OUT_DIR [SCENARIO...]\n");
}

fn fail(io: std.Io, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(message);
    try w.interface.flush();
    std.process.exit(2);
}

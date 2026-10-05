//! sorz-round-check: the gate of round 1's scene (PLAN item 13): round 1's scenarios
//! (tests/scenarios/round1) run from power-on, the whole game, in sor-remaster and in sorz, and
//! their round scenes' semantic traces compared event by event (agent/trace_compare.zig): the
//! round's tick at which each comes, the camera and the stop it follows to, the timer, play's
//! phases (the intro, play, the time overs, the end), the players' places, states, health, lives
//! and deaths, the continue's question and the game over, the entities the script places and
//! their first moves, the sounds; the fighters' frames (the probes: where each frame starts,
//! agent/probe_compare.zig); and the pictures, pixel by pixel, around each scene's start in
//! sor-remaster's trace and every `picture_every` display ticks from the round's start.
//!
//!   sorz-round-check ROM REMASTER_AGENT SCENARIOS_DIR OUT_DIR [SCENARIO...] [--reach FILE...]
//!       [--reach-min TRACE,FRAMES,SOUND] [--reach-take-up FILE...] [--every-tick FILE...]
//!       [--every-tick-min TICK]
//!
//! A scenario given with `--every-tick` (any run: the attract demo's from power-on, a round's
//! script) is compared at every display tick: the events of its round scenes by display tick,
//! its sound, its pictures from a few ticks before its first round on. Its reach is the first
//! display tick where any differs; with `--every-tick-min`, a reach below that floor fails.
//!
//! A scenario given with `--reach` (a recorded play, `start pads FILE V`, kept out of the
//! repository) is not a gate: its line says how far each comparison stays equal (the trace's
//! and the frames' first difference by the round's tick, the sound's by display tick). With
//! `--reach-min`, it is one: a reach below its floor fails the check (the trace's and the
//! frames' round ticks, the sound's display tick; a floor left empty is none). One given with
//! `--reach-take-up` reaches where sorz's own play does not (the round's end, its clear): sorz
//! runs the whole game with the recorded pads, but takes the round's world up from
//! sor-remaster's trace at the script's start (agent/game_run.zig); its trace and frames are
//! compared from there, its pictures from the next, and its sound says where it differs (the
//! chips sound on with sorz's own play until each has played anew) and from where it is equal.
//!
//! For each scenario (`scenarios` below, the file SCENARIOS_DIR/NAME.scn), sor-remaster's agent
//! runs it and writes its trace into OUT_DIR; sorz runs it in this process, on the content
//! extracted from the ROM (agent/game_run.zig), and writes its own. The comparison takes each
//! trace's round scene, its entities numbered by their order of appearance (sor-remaster's front
//! end makes objects that sorz's screens do not), without the effects sorz does not have yet (the
//! hit sparks) and sorz's own section events; the game's clock as each script begins (which
//! the enemies' choices read) must be the same; and the sound, the whole run's from power-on,
//! sample by sample (both programs' 48 kHz output: DESIGN.md's sound exact from the start).
//! Prints a line per scenario, its events and the
//! first difference; writes the comparisons into OUT_DIR/report.txt; exits with 1 when a
//! scenario's traces differ or a run fails.
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const extract = @import("extract");

const compare = agent.trace_compare;
const probes = agent.probe_compare;

pub const Scenario = struct {
    name: []const u8,
    /// What it shows, for the reader.
    what: []const u8,
    /// Its file, when not SCENARIOS_DIR/NAME.scn; and whether it is a reach's report, not a gate.
    path: ?[]const u8 = null,
    reach: bool = false,
    /// The events' fields left out of its comparison.
    ignore_fields: []const []const u8 = &.{},
    /// Whether its pictures are compared, and before which display tick.
    pictures: bool = true,
    pictures_before: ?u64 = null,
    /// A reach's floors: the trace's, the frames' (round ticks), the sound's (display ticks).
    reach_min: [3]?u64 = .{ null, null, null },
    /// A reach whose round's world sorz takes up from sor-remaster's at its script's start
    /// (`--reach-take-up`): its comparisons start there.
    take_up: bool = false,
    /// A run compared at every display tick (`--every-tick`): its rounds' events by display
    /// tick, its sound, its pictures from its first round on; its reach the first display tick
    /// where one differs, and its floor (`--every-tick-min`).
    every_tick: bool = false,
    tick_min: ?u64 = null,
};

/// Where a run took the round's world up: the display tick of the script's start, and the
/// round's tick of sor-remaster's last observation by then.
const TakenUp = struct { v: i64, t: i64 };

/// The display ticks of the pictures compared: from a few before each scene's start to some
/// after, and every this many in the round (with the next, the other half of a logic tick).
const picture_before = 4;
const picture_after = 20;
const picture_every = 64;

/// Round 1's scenarios (tests/scenarios/round1).
pub const scenarios = [_]Scenario{
    .{ .name = "walk", .what = "a walk to the first wall: the camera's follow, the placed Galsias coming out" },
    .{ .name = "idle", .what = "standing still: the timer, three time overs and deaths, new lives, the continue's question" },
    .{ .name = "continue", .what = "the continue's YES: a new game's lives, the next life" },
    .{ .name = "gameover", .what = "the continue's NO: the game over's count, the fade out, the high scores" },
    .{ .name = "pause", .what = "two pauses: the pause's sounds, its ticks on the game's clock, play after it" },
    .{ .name = "join", .what = "player 2's PRESS 2UP START mid-round, the timer down: its drop-in as Adam, the timer again" },
    .{ .name = "join_enemies", .what = "player 2's PRESS 2UP START with the first Galsias on the screen: its drop-in as Adam knocks them back" },
    .{ .name = "blaze", .what = "Blaze chosen at the select: her walk to the first Galsia, her blows, her jump kick" },
    .{ .name = "two", .what = "two players, Axel and Blaze, chosen at the select: their walk and a jump, the Galsias coming" },
};

/// The front end's objects (sor-remaster's): their events are left out; and sorz's own section
/// events.
const ignored_kinds = [_][]const u8{ "screen_object", "select_cursor", "select_portrait" };
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
    const scn = sc.path orelse try std.fmt.allocPrint(arena, "{s}/{s}.scn", .{ c.scenarios_dir, sc.name });
    const ref_trace = try std.fmt.allocPrint(arena, "{s}/ref-{s}.jsonl", .{ c.out_path, sc.name });
    const z_trace = try std.fmt.allocPrint(arena, "{s}/z-{s}.jsonl", .{ c.out_path, sc.name });
    const ref_wav = try std.fmt.allocPrint(arena, "{s}/ref-{s}.wav", .{ c.out_path, sc.name });
    const z_wav = try std.fmt.allocPrint(arena, "{s}/z-{s}.wav", .{ c.out_path, sc.name });
    const ref_probe = try std.fmt.allocPrint(arena, "{s}/ref-{s}.probe", .{ c.out_path, sc.name });
    const z_probe = try std.fmt.allocPrint(arena, "{s}/z-{s}.probe", .{ c.out_path, sc.name });

    const ran = try std.process.run(c.gpa, c.io, .{ .argv = &.{ c.remaster, c.rom_path, "--scenario", scn, "--trace-events", ref_trace, "--probe", ref_probe, "--wav", ref_wav, "--frames", "200000" } });
    defer c.gpa.free(ran.stdout);
    defer c.gpa.free(ran.stderr);
    if (ran.term != .exited or ran.term.exited != 0 or std.mem.indexOf(u8, ran.stdout, "\"scenario\":\"done\"") == null) {
        try w.print("{s}: sor-remaster's run did not end as the scenario does: {s}{s}\n", .{ sc.name, ran.stdout, ran.stderr });
        return false;
    }
    var said: std.Io.Writer.Allocating = .init(arena);
    const done = try agent.scenario_cmd.run(c.gpa, c.io, c.assets, .{ .scenario = scn, .trace = z_trace, .probe = z_probe, .wav = z_wav, .situation = if (sc.take_up) ref_trace else null, .situation_probe = if (sc.take_up) ref_probe else null, .take_up = sc.take_up }, &said.writer);
    if (!done) {
        try w.print("{s}: sorz's run did not end as the scenario does: {s}", .{ sc.name, said.written() });
        return false;
    }

    // The game's clock as the script begins, which the enemies' choices read: the same.
    const ref_clock = numberAfter(ran.stdout, "\"script_game_tick\":");
    const z_clock = numberAfter(said.written(), "\"script_game_tick\":");
    // (A recorded play's script begins past its pads, where the reach's runs need not agree; a run
    // compared at every tick says where they part.)
    if (!sc.reach and !sc.every_tick and (ref_clock == null or z_clock == null or ref_clock.? != z_clock.?)) {
        try w.print("{s}: the game's clock as the script begins differs: {?d} against {?d}\n", .{ sc.name, ref_clock, z_clock });
        return false;
    }

    var diag: compare.Diagnostic = .{};
    var a_full = try compare.parse(arena, try cwd.readFileAlloc(c.io, ref_trace, arena, .limited(1 << 30)), &diag);
    var b_full = try compare.parse(arena, try cwd.readFileAlloc(c.io, z_trace, arena, .limited(1 << 30)), &diag);
    if (sc.every_tick) return everyTick(c, sc, scn, &a_full, &b_full, ref_wav, z_wav, w);
    const taken: ?TakenUp = if (sc.take_up) try takenUp(ran.stdout, &a_full) else null;
    // A run taken up is compared to its round's clear's end (the next round's is a stand-in in
    // sorz until PLAN item 15).
    var sound_to: ?usize = null;
    if (taken) |tu| {
        a_full = untilNextRound(&a_full, tu.v);
        b_full = untilNextRound(&b_full, tu.v);
        if (a_full.end) |e| sound_to = frameOf(@intCast(e.v));
    }
    // A run taken up: its entities have sor-remaster's ids; the ids its hit sparks took after
    // the take-up are given up.
    const options: compare.Options = .{
        .from_scene = "round",
        .renumber = taken == null,
        .close_ids = taken != null,
        .after = if (taken) |tu| tu.t else null,
        .ignore_kinds = &ignored_kinds,
        .ignore = &ignored_events,
        .ignore_fields = sc.ignore_fields,
        .sound_names = c.sound_names,
    };
    const a = try compare.restrict(arena, &a_full, options, true);
    const b = try compare.restrict(arena, &b_full, options, false);
    var written: std.Io.Writer.Allocating = .init(arena);
    const result = try compare.compare(arena, &a, &b, options, &written.writer);
    var events: usize = 0;
    for (result.counts) |n| events += n.a;
    const frames = try framesOf(c, &a_full, &b_full, ref_probe, z_probe, taken);
    const sound = try soundOf(c, ref_wav, z_wav, if (taken) |tu| frameOf(@intCast(tu.v)) else 0, sound_to);
    const pictures: Pictures = if ((sc.reach and taken == null) or !sc.pictures) .{} else try picturesOf(c, sc, scn, &a_full, ref_trace, ref_probe, taken);
    // The runs end a few ticks apart past the round (the runners count the start-up's ticks
    // differently: the original's is a scene of its own): the sound is compared where both are.
    const sound_same = sound.first == null;
    const common = @min(sound.frames, sound.reference_frames);
    if (taken) |tu| {
        try w.print("{s}: ({s}: display tick {d}, the round's tick {d})\n  the trace: ", .{ sc.name, sc.what, tu.v, tu.t });
        if (result.first) |d| try w.print("equal before the round's tick {d}, {d} differences in {d} events\n", .{ firstTick(d), result.differences, events }) else try w.print("equal, {d} events\n", .{events});
        try w.writeAll("  the frames: ");
        if (frames.first) |d| try w.print("equal before the round's tick {d} (entity {d}: {f} against {f}), {d} of {d} entities differ\n", .{ d.t, d.e, startOf(d.a), startOf(d.b), frames.differing, frames.entities }) else try w.print("equal, {d} entities\n", .{frames.entities});
        // The chips sound on with what sorz's own play left them before the take-up, until
        // each has played anew.
        try w.writeAll("  the sound: ");
        if (sound.last) |l| {
            if (l + 1 < common) try w.print("differs from display tick {d} to {d} (sorz's own sound before the take-up), then equal to {d}\n", .{ ticksOf(sound.first.?), ticksOf(l), ticksOf(common) }) else try w.print("differs from display tick {d} to the end ({d})\n", .{ ticksOf(sound.first.?), ticksOf(common) });
        } else try w.print("equal, to display tick {d}\n", .{ticksOf(common)});
        try w.print("  the pictures: {d} of {d} differ ({d} lines past the sprites' limits left out)", .{ pictures.differing, pictures.compared, pictures.lines_left_out });
        if (pictures.first) |f| try w.print(", the first after display tick {d} ({d} pixels: {s}/{s}-z-{d}.png, its -ref- and -diff-); after display ticks {any}", .{ f.tick, f.pixels, c.out_path, sc.name, f.tick, pictures.ticks[0..@min(pictures.differing, pictures.ticks.len)] });
        try w.writeAll("\n");
        return true;
    }
    if (sc.reach) {
        try w.print("{s}: ({s})\n  the trace: ", .{ sc.name, sc.what });
        if (result.first) |d| try w.print("equal before the round's tick {d}, {d} differences in {d} events\n", .{ firstTick(d), result.differences, events }) else try w.print("equal, {d} events\n", .{events});
        try w.writeAll("  the frames: ");
        if (frames.first) |d| try w.print("equal before the round's tick {d} (entity {d}: {f} against {f}), {d} of {d} entities differ\n", .{ d.t, d.e, startOf(d.a), startOf(d.b), frames.differing, frames.entities }) else try w.print("equal, {d} entities\n", .{frames.entities});
        try w.writeAll("  the sound: ");
        if (sound.first) |f| try w.print("equal before display tick {d} of {d}\n", .{ ticksOf(f), ticksOf(common) }) else try w.print("equal, {d} display ticks\n", .{ticksOf(common)});
        // Its floors: how far each must reach.
        const reached = [3]?u64{
            if (result.first) |d| @intCast(@max(firstTick(d), 0)) else null,
            if (frames.first) |d| @intCast(@max(d.t, 0)) else null,
            if (sound.first) |f| ticksOf(f) else null,
        };
        var above = true;
        for (reached, sc.reach_min, [_][]const u8{ "the trace", "the frames", "the sound" }) |r, floor, what| {
            const least = floor orelse continue;
            const at = r orelse continue;
            if (at >= least) continue;
            try w.print("  {s} reaches {d}, below its floor {d}\n", .{ what, at, least });
            above = false;
        }
        return above;
    }
    if (result.differences == 0 and frames.first == null and sound_same and pictures.first == null) {
        try w.print("{s}: equal, {d} events, {d} entities' frames, the sound's {d} display ticks, {d} pictures ({d} lines past the sprites' limits left out) ({s})\n", .{ sc.name, events, frames.entities, ticksOf(common), pictures.compared, pictures.lines_left_out, sc.what });
        return true;
    }
    if (pictures.first) |f| try w.print("{s}: {d} of {d} pictures differ, the first after display tick {d} ({d} pixels: {s}/{s}-z-{d}.png, its -ref- and -diff-); after display ticks {any}\n", .{ sc.name, pictures.differing, pictures.compared, f.tick, f.pixels, c.out_path, sc.name, f.tick, pictures.ticks[0..@min(pictures.differing, pictures.ticks.len)] });
    if (result.differences != 0) try w.print("{s}: {d} differences in {d} events ({s})\n{s}\n", .{ sc.name, result.differences, events, sc.what, written.written() });
    if (frames.first) |d| try w.print("{s}: the frames differ: entity {d} at the round's tick {d}, {f} against {f}; {d} of {d} entities differ\n", .{ sc.name, d.e, d.t, startOf(d.a), startOf(d.b), frames.differing, frames.entities });
    if (!sound_same) {
        try w.print("{s}: the sound differs ({d} frames, sor-remaster's {d})", .{ sc.name, sound.frames, sound.reference_frames });
        if (sound.first) |f| try w.print("; from frame {d} (display tick {d}), {d} frames differ, by {d} at most", .{ f, ticksOf(f), sound.differing, sound.largest });
        try w.writeAll("\n");
    }
    return false;
}

/// The events a run compared at every tick leaves out: the scenes' changes (the runners see
/// them a tick apart), sorz's own section events, the traces' ends.
const tick_ignored = [_][]const u8{ "scene", "section", "end" };

/// A run compared at every display tick: the events of its round scenes (the world's, play's)
/// by display tick, the entities numbered by their order of appearance; its sound, sample by
/// sample from power-on; its pictures, pixel by pixel from a few ticks before its first round's
/// start. Its lines say where each first differs, and its reach, the first display tick where
/// any does, which must not be below its floor.
fn everyTick(c: *const Context, sc: *const Scenario, scn: []const u8, a_full: *const compare.Trace, b_full: *const compare.Trace, ref_wav: []const u8, z_wav: []const u8, w: *std.Io.Writer) !bool {
    const arena = c.arena;
    const options: compare.Options = .{
        .by_vblank = true,
        .renumber = true,
        .ignore_kinds = &ignored_kinds,
        .ignore = &tick_ignored,
        .sound_names = c.sound_names,
    };
    const a_rounds = roundsOf(a_full);
    const b_rounds = roundsOf(b_full);
    const a_only = try a_rounds.of(arena);
    const b_only = try b_rounds.of(arena);
    const a = try compare.restrict(arena, &a_only, options, true);
    const b = try compare.restrict(arena, &b_only, options, false);
    var written: std.Io.Writer.Allocating = .init(arena);
    const result = try compare.compare(arena, &a, &b, options, &written.writer);
    var events: usize = 0;
    for (result.counts) |n| events += n.a;
    const sound = try soundOf(c, ref_wav, z_wav, 0, null);
    const common = ticksOf(@min(sound.frames, sound.reference_frames));
    const pictures = try everyPicture(c, sc, scn, a_full);
    const end: u64 = @intCast((a_full.end orelse return error.BadTrace).v);

    try w.print("{s}: ({s}; compared at every display tick)\n  the trace: ", .{ sc.name, sc.what });
    const trace_at: ?u64 = if (result.first) |d| @intCast(@max(firstV(d), 0)) else null;
    if (trace_at) |v| try w.print("equal before display tick {d}, {d} differences in {d} events of its rounds\n", .{ v, result.differences, events }) else try w.print("equal, {d} events of its rounds\n", .{events});
    const sound_at: ?u64 = if (sound.first) |f| ticksOf(f) else null;
    try w.writeAll("  the sound: ");
    if (sound_at) |v| try w.print("equal before display tick {d} of {d}, {d} frames differ, by {d} at most\n", .{ v, common, sound.differing, sound.largest }) else try w.print("equal, {d} display ticks\n", .{common});
    try w.print("  the pictures: {d} compared ({d} lines past the sprites' limits left out), ", .{ pictures.compared, pictures.lines_left_out });
    if (pictures.first) |f| {
        try w.print("equal before display tick {d} ({d} pixels: {s}/{s}-z-{d}.png, its -ref- and -diff-); {d} differ, after display ticks", .{ f.tick, f.pixels, c.out_path, sc.name, f.tick, pictures.differing });
        for (pictures.spans[0..pictures.span_count]) |span| {
            if (span[0] == span[1]) try w.print(" {d}", .{span[0]}) else try w.print(" {d}-{d}", .{ span[0], span[1] });
        }
        try w.writeAll(if (pictures.span_count == pictures.spans.len) " ...\n" else "\n");
    } else try w.writeAll("all equal\n");
    var reach: u64 = end;
    for ([_]?u64{ trace_at, sound_at, if (pictures.first) |f| f.tick else null }) |at| {
        if (at) |v| reach = @min(reach, v);
    }
    try w.print("  the reach: display tick {d} of {d}\n", .{ reach, end });
    if (result.first != null) try w.print("{s}\n", .{written.written()});
    if (sc.tick_min) |floor| if (reach < floor) {
        try w.print("  the reach is below its floor, display tick {d}\n", .{floor});
        return false;
    };
    return true;
}

/// The display tick of a trace's difference: its earlier event's.
fn firstV(d: compare.Difference) i64 {
    const a = if (d.a) |e| e.v else std.math.maxInt(i64);
    const b = if (d.b) |e| e.v else std.math.maxInt(i64);
    return @min(a, b);
}

/// A trace's events in its round scenes.
const Rounds = struct {
    trace: *const compare.Trace,

    fn of(self: Rounds, arena: std.mem.Allocator) !compare.Trace {
        var events: std.ArrayList(compare.Event) = .empty;
        for (self.trace.events) |e| {
            if (std.mem.eql(u8, self.trace.scenes[e.scene - 1], "round")) try events.append(arena, e);
        }
        var t = self.trace.*;
        t.events = events.items;
        return t;
    }
};

fn roundsOf(trace: *const compare.Trace) Rounds {
    return .{ .trace = trace };
}

/// The pictures of a run compared at every display tick: from a few ticks before its first
/// round's start (its load's scene, or the round's) to the reference's end, `picture_batch` at a
/// time: sor-remaster's run writes them, sorz's compares its own as they come, and they go.
fn everyPicture(c: *const Context, sc: *const Scenario, scn: []const u8, ref: *const compare.Trace) !Pictures {
    const arena = c.arena;
    const end: u64 = @intCast((ref.end orelse return error.BadTrace).v);
    var from: ?u64 = null;
    for (ref.events) |e| {
        if (!std.mem.eql(u8, e.ev, "scene")) continue;
        const name = ref.scenes[e.scene - 1];
        if (std.mem.eql(u8, name, "round_intro") or std.mem.eql(u8, name, "round")) {
            from = @intCast(@max(e.v - picture_before, 0));
            break;
        }
    }
    var total: Pictures = .{};
    var at = from orelse return total;
    const dir = try std.fmt.allocPrint(arena, "{s}/pictures-{s}", .{ c.out_path, sc.name });
    while (at < end) {
        const to = @min(at + picture_batch, end);
        try std.Io.Dir.cwd().createDirPath(c.io, dir);
        var wanted: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ c.remaster, c.rom_path, "--scenario", scn, "--frames", "200000" });
        var v = at;
        while (v < to) : (v += 1) {
            try wanted.put(arena, v, {});
            try argv.append(arena, "--shot");
            try argv.append(arena, try std.fmt.allocPrint(arena, "{d}:{s}/ref-{d}.png", .{ v, dir, v }));
        }
        const ran = try std.process.run(c.gpa, c.io, .{ .argv = argv.items });
        c.gpa.free(ran.stdout);
        c.gpa.free(ran.stderr);
        if (ran.term != .exited or ran.term.exited != 0) return error.ReferencePictures;
        // The first that differs is written once, its tick then known.
        var taker: PictureTaker = .{ .c = c, .sc = sc, .dir = dir, .wanted = &wanted, .result = .{ .first = total.first } };
        var said: std.Io.Writer.Allocating = .init(arena);
        const sink: agent.scenario_cmd.Pictures = .{ .ctx = &taker, .wanted = PictureTaker.isWanted, .take = PictureTaker.take };
        const done = try agent.scenario_cmd.run(c.gpa, c.io, c.assets, .{ .scenario = scn, .pictures = sink }, &said.writer);
        std.Io.Dir.cwd().deleteTree(c.io, dir) catch {};
        if (!done) return error.ScenarioStopped;
        const r = taker.result;
        total.first = r.first;
        total.compared += r.compared;
        total.lines_left_out += r.lines_left_out;
        for (r.spans[0..r.span_count]) |span| {
            var t = span[0];
            while (t <= span[1]) : (t += 1) total.note(t);
        }
        // (Past the batch's spans, only their count.)
        var noted: usize = 0;
        for (r.spans[0..r.span_count]) |span| noted += span[1] - span[0] + 1;
        total.differing += r.differing -| noted;
        at = to;
    }
    return total;
}

/// The pictures a run compared at every tick takes in each of sor-remaster's runs.
const picture_batch = 500;

const Pictures = struct {
    compared: usize = 0,
    differing: usize = 0,
    first: ?struct { tick: u64, pixels: usize } = null,
    /// The first display ticks whose pictures differ.
    ticks: [12]u64 = undefined,
    /// The pictures' lines left out (past the sprites' limits).
    lines_left_out: usize = 0,
    /// The runs of display ticks whose pictures differ (the first `spans.len`), as they come.
    spans: [24][2]u64 = undefined,
    span_count: usize = 0,

    fn note(self: *Pictures, tick: u64) void {
        if (self.differing < self.ticks.len) self.ticks[self.differing] = tick;
        self.differing += 1;
        if (self.span_count != 0 and self.spans[self.span_count - 1][1] + 1 == tick) {
            self.spans[self.span_count - 1][1] = tick;
        } else if (self.span_count < self.spans.len) {
            self.spans[self.span_count] = .{ tick, tick };
            self.span_count += 1;
        }
    }
};

/// The pictures compared (`picture_before`, `picture_after`, `picture_every`): sor-remaster's run
/// again writing its pictures at those display ticks, sorz's run again comparing its own with
/// them as they come; the first that differs written beside the reference's, with the
/// difference.
fn picturesOf(c: *const Context, sc: *const Scenario, scn: []const u8, ref: *const compare.Trace, ref_trace: []const u8, ref_probe: []const u8, taken: ?TakenUp) !Pictures {
    const arena = c.arena;
    const end: i64 = if (ref.end) |e| e.v else return error.BadTrace;
    var wanted: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    var round_from: ?i64 = null;
    // A run taken up: from the second picture after the take-up (the first shows the world
    // before it), every `picture_every` display ticks.
    const first: i64 = if (taken) |tu| tu.v + 2 else 0;
    if (taken != null) round_from = first;
    for (ref.events) |e| {
        if (!std.mem.eql(u8, e.ev, "scene")) continue;
        const name = ref.scenes[e.scene - 1];
        if (round_from == null and std.mem.eql(u8, name, "round_intro")) round_from = e.v;
        var v = @max(e.v - picture_before, first);
        while (v <= @min(e.v + picture_after, end - 1)) : (v += 1) try wanted.put(arena, @intCast(v), {});
    }
    if (round_from) |from| {
        var v = from;
        while (v + 1 < end) : (v += picture_every) {
            try wanted.put(arena, @intCast(v), {});
            try wanted.put(arena, @intCast(v + 1), {});
        }
    }
    if (sc.pictures_before) |before| {
        var k: usize = 0;
        while (k < wanted.count()) {
            if (wanted.keys()[k] >= before) wanted.swapRemoveAt(k) else k += 1;
        }
    }
    const dir = try std.fmt.allocPrint(arena, "{s}/pictures-{s}", .{ c.out_path, sc.name });
    try std.Io.Dir.cwd().createDirPath(c.io, dir);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ c.remaster, c.rom_path, "--scenario", scn, "--frames", "200000" });
    for (wanted.keys()) |v| {
        try argv.append(arena, "--shot");
        try argv.append(arena, try std.fmt.allocPrint(arena, "{d}:{s}/ref-{d}.png", .{ v, dir, v }));
    }
    const ran = try std.process.run(c.gpa, c.io, .{ .argv = argv.items });
    c.gpa.free(ran.stdout);
    c.gpa.free(ran.stderr);
    if (ran.term != .exited or ran.term.exited != 0) return error.ReferencePictures;
    var taker: PictureTaker = .{ .c = c, .sc = sc, .dir = dir, .wanted = &wanted };
    var said: std.Io.Writer.Allocating = .init(arena);
    const sink: agent.scenario_cmd.Pictures = .{ .ctx = &taker, .wanted = PictureTaker.isWanted, .take = PictureTaker.take };
    const done = try agent.scenario_cmd.run(c.gpa, c.io, c.assets, .{ .scenario = scn, .pictures = sink, .situation = if (taken != null) ref_trace else null, .situation_probe = if (taken != null) ref_probe else null, .take_up = taken != null }, &said.writer);
    // The reference's pictures go but the first that differs (beside sorz's).
    std.Io.Dir.cwd().deleteTree(c.io, dir) catch {};
    if (!done) return error.ScenarioStopped;
    return taker.result;
}

/// sorz's pictures against sor-remaster's, as sorz's run presents them.
const PictureTaker = struct {
    c: *const Context,
    sc: *const Scenario,
    dir: []const u8,
    wanted: *const std.AutoArrayHashMapUnmanaged(u64, void),
    result: Pictures = .{},

    fn isWanted(ctx: *anyopaque, frame: u64) bool {
        const self: *PictureTaker = @ptrCast(@alignCast(ctx));
        return self.wanted.contains(frame);
    }

    fn take(ctx: *anyopaque, frame: u64, picture: sorz.platform.RgbaFrame, over_limits: *const [sorz.render.height]bool) anyerror!void {
        const self: *PictureTaker = @ptrCast(@alignCast(ctx));
        const c = self.c;
        const gpa = c.gpa;
        const cwd = std.Io.Dir.cwd();
        const path = try std.fmt.allocPrint(c.arena, "{s}/ref-{d}.png", .{ self.dir, frame });
        const bytes = try cwd.readFileAlloc(c.io, path, gpa, .limited(1 << 22));
        defer gpa.free(bytes);
        var ref = try sorz.formats.png.decode(gpa, bytes);
        defer ref.deinit(gpa);
        self.result.compared += 1;
        var n: usize = 0;
        const diff = try gpa.alloc(u8, picture.width * picture.height * 4);
        defer gpa.free(diff);
        if (ref.width != picture.width or ref.height != picture.height) {
            n = picture.width * picture.height;
        } else for (0..picture.height) |y| for (0..picture.width) |x| {
            const want = ref.palette[ref.pixels[y * picture.width + x]];
            const got = picture.pixels[y * picture.stride + x * 4 ..][0..3];
            const d = diff[(y * picture.width + x) * 4 ..][0..4];
            // A line past the sprites' limits: the original's drops sprites there (D4).
            if (y < over_limits.len and over_limits[y]) {
                if (x == 0) self.result.lines_left_out += 1;
                d.* = .{ 0, 0, 255, 255 };
                continue;
            }
            if (std.mem.eql(u8, &want, got)) {
                d.* = .{ want[0] / 3, want[1] / 3, want[2] / 3, 255 };
            } else {
                d.* = .{ 255, 0, 0, 255 };
                n += 1;
            }
        };
        if (n == 0) return;
        self.result.note(frame);
        if (self.result.first != null) return;
        self.result.first = .{ .tick = frame, .pixels = n };
        try cwd.writeFile(c.io, .{ .sub_path = try std.fmt.allocPrint(c.arena, "{s}/{s}-ref-{d}.png", .{ c.out_path, self.sc.name, frame }), .data = bytes });
        const shot = try agent.png.encode(gpa, picture.width, picture.height, picture.pixels[0 .. picture.stride * picture.height]);
        defer gpa.free(shot);
        try cwd.writeFile(c.io, .{ .sub_path = try std.fmt.allocPrint(c.arena, "{s}/{s}-z-{d}.png", .{ c.out_path, self.sc.name, frame }), .data = shot });
        const diff_png = try agent.png.encode(gpa, picture.width, picture.height, diff);
        defer gpa.free(diff_png);
        try cwd.writeFile(c.io, .{ .sub_path = try std.fmt.allocPrint(c.arena, "{s}/{s}-diff-{d}.png", .{ c.out_path, self.sc.name, frame }), .data = diff_png });
    }
};

/// The tick of a trace's difference: its earlier event's.
fn firstTick(d: compare.Difference) i64 {
    const a = if (d.a) |e| e.t else std.math.maxInt(i64);
    const b = if (d.b) |e| e.t else std.math.maxInt(i64);
    return @min(a, b);
}

/// The two runs' frames in their round scenes (the last of each), the entities numbered as the
/// traces' comparison numbers them; in a run taken up, after the take-up, by their ids.
fn framesOf(c: *const Context, a: *const compare.Trace, b: *const compare.Trace, ref_probe: []const u8, z_probe: []const u8, taken: ?TakenUp) !probes.Result {
    const cwd = std.Io.Dir.cwd();
    const na = if (taken != null) try idsOf(c.arena, &.{ a, b }) else try compare.numbering(c.arena, a, &ignored_kinds);
    const nb = if (taken != null) na else try compare.numbering(c.arena, b, &ignored_kinds);
    var ta = probes.sceneTicks(a, "round") orelse return error.BadTrace;
    var tb = probes.sceneTicks(b, "round") orelse return error.BadTrace;
    if (taken) |tu| {
        ta[0] = @max(ta[0], tu.v + 1);
        tb[0] = @max(tb[0], tu.v + 1);
    }
    const la = try probes.parse(c.arena, try cwd.readFileAlloc(c.io, ref_probe, c.arena, .limited(1 << 30)));
    const lb = try probes.parse(c.arena, try cwd.readFileAlloc(c.io, z_probe, c.arena, .limited(1 << 30)));
    return probes.compare(c.arena, .{ .lines = la, .numbers = &na, .v0 = ta[0], .v1 = ta[1] }, .{ .lines = lb, .numbers = &nb, .v0 = tb[0], .v1 = tb[1] });
}

/// The traces' entities numbered by their own ids (a run taken up has the other's).
fn idsOf(arena: std.mem.Allocator, traces: []const *const compare.Trace) !compare.Numbers {
    var numbers: compare.Numbers = .empty;
    for (traces) |t| for (t.events) |e| {
        if (!std.mem.eql(u8, e.ev, "spawn")) continue;
        const id = switch (e.object.get("e") orelse continue) {
            .integer => |n| n,
            else => continue,
        };
        try numbers.put(arena, id, id);
    };
    return numbers;
}

/// A trace up to the next round after display tick `v`: its events before the first scene after
/// the round's clear, where it ends.
fn untilNextRound(trace: *const compare.Trace, v: i64) compare.Trace {
    var t = trace.*;
    for (trace.events, 0..) |e, i| {
        if (e.v <= v or !std.mem.eql(u8, e.ev, "scene")) continue;
        if (std.mem.eql(u8, trace.scenes[e.scene - 1], "round_clear")) continue;
        t.events = trace.events[0..i];
        t.scenes = trace.scenes[0 .. e.scene - 1];
        t.end = .{ .scene = e.scene, .v = e.v, .t = e.t };
        break;
    }
    return t;
}

/// Where sor-remaster's run of a recorded play took the round's world up (its script's start):
/// the display tick, and the round's tick of the last observation by then.
fn takenUp(stdout: []const u8, ref: *const compare.Trace) !TakenUp {
    const v: i64 = @intCast(numberAfter(stdout, "\"script_vblank\":") orelse return error.BadTrace);
    var t: ?i64 = null;
    for (ref.events) |e| {
        if (e.v > v) break;
        if (std.mem.eql(u8, ref.scenes[e.scene - 1], "round")) t = e.t;
    }
    return .{ .v = v, .t = t orelse return error.BadTrace };
}

/// A frame's start as the report writes it: "frame F at T", or "none".
const StartText = struct {
    s: ?probes.Start,
    pub fn format(self: StartText, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = self.s orelse return w.writeAll("none");
        try w.print("frame {d} at {d}", .{ s.frame, s.t });
    }
};

fn startOf(s: ?probes.Start) StartText {
    return .{ .s = s };
}

const Sound = struct { frames: usize, reference_frames: usize, first: ?usize = null, last: ?usize = null, differing: usize = 0, largest: u32 = 0 };

/// The display tick of 48 kHz frame `frame` (a tick is 896,040 periods of the 53,693,175 Hz clock).
fn ticksOf(frame: usize) u64 {
    return @as(u64, frame) * 53_693_175 / (896_040 * 48_000);
}

/// The first 48 kHz frame of display tick `tick`.
fn frameOf(tick: u64) usize {
    return @intCast((tick * 896_040 * 48_000 + 53_693_175 - 1) / 53_693_175);
}

/// The two runs' sound (16-bit stereo WAV files, a 44-byte header), frame by frame from frame
/// `from` (before frame `to`, when given): their lengths, the first and the last frames that
/// differ, how many do and by how much at most.
fn soundOf(c: *const Context, ref_path: []const u8, z_path: []const u8, from: usize, to: ?usize) !Sound {
    const cwd = std.Io.Dir.cwd();
    const a = try cwd.readFileAlloc(c.io, ref_path, c.arena, .limited(1 << 30));
    const b = try cwd.readFileAlloc(c.io, z_path, c.arena, .limited(1 << 30));
    const da = if (a.len > 44) a[44..] else a[0..0];
    const db = if (b.len > 44) b[44..] else b[0..0];
    var s: Sound = .{ .frames = db.len / 4, .reference_frames = da.len / 4 };
    if (to) |last| {
        s.frames = @min(s.frames, last);
        s.reference_frames = @min(s.reference_frames, last);
    }
    for (@min(from, s.frames, s.reference_frames)..@min(s.frames, s.reference_frames)) |i| {
        if (std.mem.eql(u8, da[4 * i ..][0..4], db[4 * i ..][0..4])) continue;
        if (s.first == null) s.first = i;
        s.last = i;
        s.differing += 1;
        for (0..2) |k| {
            const x = std.mem.readInt(i16, da[4 * i + 2 * k ..][0..2], .little);
            const y = std.mem.readInt(i16, db[4 * i + 2 * k ..][0..2], .little);
            s.largest = @max(s.largest, @abs(@as(i32, x) - y));
        }
    }
    return s;
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
    var reach: std.ArrayList(Scenario) = .empty;
    var reach_min: [3]?u64 = .{ null, null, null };
    var tick_min: ?u64 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--reach-min")) {
            var floors = std.mem.splitScalar(u8, args.next() orelse return usage(io), ',');
            for (&reach_min) |*f| {
                const text = floors.next() orelse break;
                f.* = if (text.len == 0) null else std.fmt.parseInt(u64, text, 10) catch return usage(io);
            }
        } else if (std.mem.eql(u8, arg, "--every-tick-min")) {
            tick_min = std.fmt.parseInt(u64, args.next() orelse return usage(io), 10) catch return usage(io);
        } else if (std.mem.eql(u8, arg, "--every-tick")) {
            const path = args.next() orelse return usage(io);
            const base = std.fs.path.basename(path);
            const name = if (std.mem.endsWith(u8, base, ".scn")) base[0 .. base.len - 4] else base;
            try reach.append(arena, .{ .name = name, .what = "a run from power-on", .path = path, .reach = true, .every_tick = true });
        } else if (std.mem.eql(u8, arg, "--reach") or std.mem.eql(u8, arg, "--reach-take-up")) {
            const take_up = std.mem.eql(u8, arg, "--reach-take-up");
            const path = args.next() orelse return usage(io);
            const base = std.fs.path.basename(path);
            const name = if (std.mem.endsWith(u8, base, ".scn")) base[0 .. base.len - 4] else base;
            try reach.append(arena, .{ .name = name, .what = if (take_up) "a recorded play, the round's world taken up from sor-remaster's at its script's start" else "a recorded play: how far it stays equal", .path = path, .reach = true, .take_up = take_up });
        } else try only.append(arena, arg);
    }

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
    for (reach.items) |*sc| {
        if (sc.every_tick) sc.tick_min = tick_min else if (!sc.take_up) sc.reach_min = reach_min;
    }
    const all = try std.mem.concat(arena, Scenario, &.{ &scenarios, reach.items });
    for (all) |*sc| {
        if (only.items.len != 0 and !sc.reach) {
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
    return fail(io, "usage: sorz-round-check ROM REMASTER_AGENT SCENARIOS_DIR OUT_DIR [SCENARIO...] [--reach FILE...] [--reach-min TRACE,FRAMES,SOUND] [--reach-take-up FILE...] [--every-tick FILE...] [--every-tick-min TICK]\n");
}

fn fail(io: std.Io, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(message);
    try w.interface.flush();
    std.process.exit(2);
}

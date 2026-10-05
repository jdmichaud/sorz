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
//!       [--reach-min TRACE,FRAMES,SOUND]
//!
//! A scenario given with `--reach` (a recorded play, `start pads FILE V`, kept out of the
//! repository) is not a gate: its line says how far each comparison stays equal (the trace's
//! and the frames' first difference by the round's tick, the sound's by display tick). With
//! `--reach-min`, it is one: a reach below its floor fails the check (the trace's and the
//! frames' round ticks, the sound's display tick; a floor left empty is none).
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
};

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
    const done = try agent.scenario_cmd.run(c.gpa, c.io, c.assets, .{ .scenario = scn, .trace = z_trace, .probe = z_probe, .wav = z_wav }, &said.writer);
    if (!done) {
        try w.print("{s}: sorz's run did not end as the scenario does: {s}", .{ sc.name, said.written() });
        return false;
    }

    // The game's clock as the script begins, which the enemies' choices read: the same.
    const ref_clock = numberAfter(ran.stdout, "\"script_game_tick\":");
    const z_clock = numberAfter(said.written(), "\"script_game_tick\":");
    // (A recorded play's script begins past its pads, where the reach's runs need not agree.)
    if (!sc.reach and (ref_clock == null or z_clock == null or ref_clock.? != z_clock.?)) {
        try w.print("{s}: the game's clock as the script begins differs: {?d} against {?d}\n", .{ sc.name, ref_clock, z_clock });
        return false;
    }

    const options: compare.Options = .{
        .from_scene = "round",
        .renumber = true,
        .ignore_kinds = &ignored_kinds,
        .ignore = &ignored_events,
        .ignore_fields = sc.ignore_fields,
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
    const frames = try framesOf(c, &a_full, &b_full, ref_probe, z_probe);
    const sound = try soundOf(c, ref_wav, z_wav);
    const pictures: Pictures = if (sc.reach or !sc.pictures) .{} else try picturesOf(c, sc, scn, &a_full);
    // The runs end a few ticks apart past the round (the runners count the start-up's ticks
    // differently: the original's is a scene of its own): the sound is compared where both are.
    const sound_same = sound.first == null;
    const common = @min(sound.frames, sound.reference_frames);
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
        try w.print("{s}: equal, {d} events, {d} entities' frames, the sound's {d} display ticks, {d} pictures ({s})\n", .{ sc.name, events, frames.entities, ticksOf(common), pictures.compared, sc.what });
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

const Pictures = struct {
    compared: usize = 0,
    differing: usize = 0,
    first: ?struct { tick: u64, pixels: usize } = null,
    /// The first display ticks whose pictures differ.
    ticks: [12]u64 = undefined,
};

/// The pictures compared (`picture_before`, `picture_after`, `picture_every`): sor-remaster's run
/// again writing its pictures at those display ticks, sorz's run again comparing its own with
/// them as they come; the first that differs written beside the reference's, with the
/// difference.
fn picturesOf(c: *const Context, sc: *const Scenario, scn: []const u8, ref: *const compare.Trace) !Pictures {
    const arena = c.arena;
    const end: i64 = if (ref.end) |e| e.v else return error.BadTrace;
    var wanted: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    var round_from: ?i64 = null;
    for (ref.events) |e| {
        if (!std.mem.eql(u8, e.ev, "scene")) continue;
        const name = ref.scenes[e.scene - 1];
        if (round_from == null and std.mem.eql(u8, name, "round_intro")) round_from = e.v;
        var v = @max(e.v - picture_before, 0);
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
    const done = try agent.scenario_cmd.run(c.gpa, c.io, c.assets, .{ .scenario = scn, .pictures = sink }, &said.writer);
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

    fn take(ctx: *anyopaque, frame: u64, picture: sorz.platform.RgbaFrame) anyerror!void {
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
            if (std.mem.eql(u8, &want, got)) {
                d.* = .{ want[0] / 3, want[1] / 3, want[2] / 3, 255 };
            } else {
                d.* = .{ 255, 0, 0, 255 };
                n += 1;
            }
        };
        if (n == 0) return;
        if (self.result.differing < self.result.ticks.len) self.result.ticks[self.result.differing] = frame;
        self.result.differing += 1;
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
/// traces' comparison numbers them.
fn framesOf(c: *const Context, a: *const compare.Trace, b: *const compare.Trace, ref_probe: []const u8, z_probe: []const u8) !probes.Result {
    const cwd = std.Io.Dir.cwd();
    const na = try compare.numbering(c.arena, a, &ignored_kinds);
    const nb = try compare.numbering(c.arena, b, &ignored_kinds);
    const ta = probes.sceneTicks(a, "round") orelse return error.BadTrace;
    const tb = probes.sceneTicks(b, "round") orelse return error.BadTrace;
    const la = try probes.parse(c.arena, try cwd.readFileAlloc(c.io, ref_probe, c.arena, .limited(1 << 30)));
    const lb = try probes.parse(c.arena, try cwd.readFileAlloc(c.io, z_probe, c.arena, .limited(1 << 30)));
    return probes.compare(c.arena, .{ .lines = la, .numbers = &na, .v0 = ta[0], .v1 = ta[1] }, .{ .lines = lb, .numbers = &nb, .v0 = tb[0], .v1 = tb[1] });
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

const Sound = struct { frames: usize, reference_frames: usize, first: ?usize = null, differing: usize = 0, largest: u32 = 0 };

/// The display tick of 48 kHz frame `frame` (a tick is 896,040 periods of the 53,693,175 Hz clock).
fn ticksOf(frame: usize) u64 {
    return @as(u64, frame) * 53_693_175 / (896_040 * 48_000);
}

/// The two runs' sound (16-bit stereo WAV files, a 44-byte header), frame by frame: their lengths,
/// the first frame that differs, how many do and by how much at most.
fn soundOf(c: *const Context, ref_path: []const u8, z_path: []const u8) !Sound {
    const cwd = std.Io.Dir.cwd();
    const a = try cwd.readFileAlloc(c.io, ref_path, c.arena, .limited(1 << 30));
    const b = try cwd.readFileAlloc(c.io, z_path, c.arena, .limited(1 << 30));
    const da = if (a.len > 44) a[44..] else a[0..0];
    const db = if (b.len > 44) b[44..] else b[0..0];
    var s: Sound = .{ .frames = db.len / 4, .reference_frames = da.len / 4 };
    for (0..@min(s.frames, s.reference_frames)) |i| {
        if (std.mem.eql(u8, da[4 * i ..][0..4], db[4 * i ..][0..4])) continue;
        if (s.first == null) s.first = i;
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
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--reach-min")) {
            var floors = std.mem.splitScalar(u8, args.next() orelse return usage(io), ',');
            for (&reach_min) |*f| {
                const text = floors.next() orelse break;
                f.* = if (text.len == 0) null else std.fmt.parseInt(u64, text, 10) catch return usage(io);
            }
        } else if (std.mem.eql(u8, arg, "--reach")) {
            const path = args.next() orelse return usage(io);
            const base = std.fs.path.basename(path);
            const name = if (std.mem.endsWith(u8, base, ".scn")) base[0 .. base.len - 4] else base;
            try reach.append(arena, .{ .name = name, .what = "a recorded play: how far it stays equal", .path = path, .reach = true });
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
    for (reach.items) |*sc| sc.reach_min = reach_min;
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
    return fail(io, "usage: sorz-round-check ROM REMASTER_AGENT SCENARIOS_DIR OUT_DIR [SCENARIO...] [--reach FILE...] [--reach-min TRACE,FRAMES,SOUND]\n");
}

fn fail(io: std.Io, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(message);
    try w.interface.flush();
    std.process.exit(2);
}

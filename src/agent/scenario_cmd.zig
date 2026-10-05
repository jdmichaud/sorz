//! `sorz-agent DIR --scenario FILE [--situation TRACE] [--trace-events OUT] [--probe OUT]`: a
//! scenario's run, its trace and its probe written, and one JSON line: the scenario's end
//! (`done`, or what stopped it, with the `line` of a condition that did not come in time), the
//! display tick of the script's tick 0 and the kinds the situation had that the content does not
//! define. Without a situation, the whole game runs from power-on (game_run.zig: no probe);
//! with one, the round's world alone from that situation (scenario.zig). A scenario that stops
//! early exits with status 1, its trace written up to there.
const std = @import("std");
const sorz = @import("sorz");
const scenario = @import("scenario.zig");
const game_run = @import("game_run.zig");
const agent_wav = @import("wav.zig");
const input = sorz.input;

pub const Options = struct {
    scenario: []const u8,
    situation: ?[]const u8 = null,
    /// The other program's probe of the same run, for the entities' frames at the situation.
    situation_probe: ?[]const u8 = null,
    /// The other program's tick counter at the script's start (its `script_game_tick`).
    game_tick: ?u32 = null,
    trace: ?[]const u8 = null,
    probe: ?[]const u8 = null,
    /// Where a run from power-on writes its sound (a WAV file).
    wav: ?[]const u8 = null,
    /// The most logic ticks the script runs.
    ticks: u64 = 100_000,
};

/// Runs the scenario on the content of `assets`; returns whether it ran to its end.
pub fn run(gpa: std.mem.Allocator, io: std.Io, assets: sorz.platform.AssetSource, options: Options, out: *std.Io.Writer) !bool {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();

    const text = try cwd.readFileAlloc(io, options.scenario, arena, .limited(1 << 20));
    var diag: scenario.Diagnostic = .{};
    var script = scenario.parse(gpa, text, &diag) catch |e| switch (e) {
        error.BadScenario => {
            std.log.err("{s}:{d}: {s}", .{ options.scenario, diag.line, diag.message });
            return error.BadScenario;
        },
        else => return e,
    };
    defer script.deinit(gpa);
    const situation_path = options.situation orelse return runFromPowerOn(gpa, io, assets, options, &script, out);
    const situation_text = try cwd.readFileAlloc(io, situation_path, arena, .limited(1 << 30));
    const at: ?u64 = switch (script.start) {
        .players => null,
        .pads => |p| p.vblanks + 1,
    };
    var situation = scenario.situationOf(arena, situation_text, at) catch |e| {
        std.log.err("{s}: no situation in the trace ({s}): a round scene's play is needed", .{ situation_path, @errorName(e) });
        return e;
    };
    if (options.situation_probe) |path| {
        const probe_text = try cwd.readFileAlloc(io, path, arena, .limited(1 << 30));
        scenario.framesOf(&situation, arena, probe_text) catch |e| {
            std.log.err("{s}: not a probe ({s})", .{ path, @errorName(e) });
            return e;
        };
    }

    var content_diag: sorz.content.Diagnostic = .{};
    const c = sorz.content.load(arena, assets, &content_diag) catch |e| {
        std.log.err("the content does not load: {f}", .{&content_diag});
        return e;
    };
    var bind_diag: sorz.formats.json.Diagnostic = .{};
    const kinds = sorz.world.Kinds.bind(arena, c.entities, &c.art, &bind_diag) catch |e| {
        std.log.err("the kinds of entity do not bind: {f}", .{&bind_diag});
        return e;
    };

    var trace_file: ?std.Io.File = null;
    defer if (trace_file) |f| f.close(io);
    var trace_buf: [1 << 16]u8 = undefined;
    var trace_writer: std.Io.File.Writer = undefined;
    var tw: sorz.world.trace.Writer = undefined;
    if (options.trace) |path| {
        trace_file = try cwd.createFile(io, path, .{});
        trace_writer = trace_file.?.writerStreaming(io, &trace_buf);
        tw = .init(&trace_writer.interface);
        try tw.begin("reference");
    }
    var probe_file: ?std.Io.File = null;
    defer if (probe_file) |f| f.close(io);
    var probe_buf: [1 << 16]u8 = undefined;
    var probe_writer: std.Io.File.Writer = undefined;
    var probe: scenario.Probe = undefined;
    if (options.probe) |path| {
        probe_file = try cwd.createFile(io, path, .{});
        probe_writer = probe_file.?.writerStreaming(io, &probe_buf);
        probe = .{ .w = &probe_writer.interface };
    }

    // TODO(PLAN item 13): the round's script's records, until its content holds them.
    var r = try scenario.Run.init(gpa, &kinds, &script, &situation, .{ .game_tick = options.game_tick, .round = if (c.rounds.len != 0) &c.rounds[0] else null }, if (options.trace != null) &tw else null, if (options.probe != null) &probe else null);
    defer r.deinit();
    var ticks: u64 = 0;
    while (ticks < options.ticks) : (ticks += 1) {
        if (!try r.step()) break;
    } else r.failure = "the run reached its most ticks";

    if (options.trace != null) {
        try tw.end();
        try trace_writer.interface.flush();
    }
    if (options.probe != null) try probe_writer.interface.flush();

    try out.print("{{\"scenario\":\"{s}\"", .{r.failure orelse "done"});
    if (r.body.timed_out) |line| try out.print(",\"line\":{d}", .{line});
    try out.print(",\"script_vblank\":{d},\"ticks\":{d},\"skipped\":[", .{ r.script_v, ticks });
    for (r.skipped.items, 0..) |k, i| try out.print("{s}\"{s}\"", .{ if (i == 0) "" else ",", k });
    try out.writeAll("]}\n");
    return r.failure == null;
}

/// The scenario from power-on: the whole game, its start through the screens (game_run.zig).
fn runFromPowerOn(gpa: std.mem.Allocator, io: std.Io, assets: sorz.platform.AssetSource, options: Options, script: *const scenario.Script, out: *std.Io.Writer) !bool {
    if (options.probe != null) {
        std.log.err("a run from power-on writes no probe (--probe needs --situation)", .{});
        return error.BadOptions;
    }
    var diag: sorz.formats.json.Diagnostic = .{};
    const c = sorz.library.load(gpa, assets, &diag) catch |e| {
        std.log.err("the content does not load: {f}", .{&diag});
        return e;
    };
    defer {
        c.destroy();
        gpa.destroy(c);
    }
    const assets_found = sorz.scene.Assets.find(c, &diag) catch |e| {
        std.log.err("the scenes' assets are not in the content: {f}", .{&diag});
        return e;
    };
    const cwd = std.Io.Dir.cwd();
    var trace_file: ?std.Io.File = null;
    defer if (trace_file) |f| f.close(io);
    var trace_buf: [1 << 16]u8 = undefined;
    var trace_writer: std.Io.File.Writer = undefined;
    var tw: sorz.world.trace.Writer = undefined;
    if (options.trace) |path| {
        trace_file = try cwd.createFile(io, path, .{});
        trace_writer = trace_file.?.writerStreaming(io, &trace_buf);
        tw = .init(&trace_writer.interface);
        try tw.begin("power-on");
    }
    var pads: []input.Pads = &.{};
    defer gpa.free(pads);
    if (script.start == .pads) {
        const name = script.start.pads.path;
        const dir = std.fs.path.dirname(options.scenario) orelse ".";
        const full = if (std.fs.path.isAbsolute(name)) try gpa.dupe(u8, name) else try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(full);
        const text = try cwd.readFileAlloc(io, full, gpa, .limited(1 << 26));
        defer gpa.free(text);
        pads = try scenario.parsePads(gpa, text) orelse {
            std.log.err("the pads file {s} has a malformed line", .{full});
            return error.BadScenario;
        };
    }
    var r: game_run.Run = .init(c, &assets_found, script, pads, if (options.trace != null) &tw else null);
    var sound: ?game_run.Sound = if (options.wav != null) try .init(gpa, &c.sounds) else null;
    defer if (sound) |*s| s.deinit();
    if (sound) |*s| r.sound = s;
    // The start's display ticks, then two a logic tick of the script's.
    var ticks: u64 = 0;
    while (ticks < 2 * options.ticks + 10_000) : (ticks += 1) {
        if (!try r.step()) break;
    } else r.failure = "the run reached its most ticks";
    if (options.trace != null) {
        try tw.end();
        try trace_writer.interface.flush();
    }
    if (sound) |*s| try agent_wav.write(gpa, io, options.wav.?, s.pcm.items, sorz.sound_out.channels, sorz.sound_out.rate);
    try out.print("{{\"scenario\":\"{s}\"", .{r.failure orelse "done"});
    if (r.body.timed_out) |line| try out.print(",\"line\":{d}", .{line});
    try out.print(",\"script_vblank\":{d}", .{r.body_v orelse 0});
    if (r.body_clock) |clock| try out.print(",\"script_game_tick\":{d}", .{clock});
    try out.print(",\"ticks\":{d}}}\n", .{ticks});
    return r.failure == null;
}

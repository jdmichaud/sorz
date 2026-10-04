//! `sorz-agent DIR --scenario FILE --situation TRACE [--trace-events OUT] [--probe OUT]`: a
//! scenario's run (scenario.zig), its trace and its probe written, and one JSON line: the
//! scenario's end (`done`, or what stopped it, with the `line` of a condition that did not come
//! in time), the display tick of the script's tick 0 and the kinds the situation had that the
//! content does not define. A scenario that stops early exits with status 1, its trace written up
//! to there.
const std = @import("std");
const sorz = @import("sorz");
const scenario = @import("scenario.zig");

pub const Options = struct {
    scenario: []const u8,
    situation: ?[]const u8 = null,
    trace: ?[]const u8 = null,
    probe: ?[]const u8 = null,
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
    const situation_path = options.situation orelse {
        std.log.err("a scenario's start takes up round 1 from another program's trace: --situation TRACE (until the round's content, PLAN item 13)", .{});
        return error.NoSituation;
    };
    const situation_text = try cwd.readFileAlloc(io, situation_path, arena, .limited(1 << 30));
    const situation = scenario.situationOf(arena, situation_text) catch |e| {
        std.log.err("{s}: no situation in the trace ({s}): a round scene's `phase play` is needed", .{ situation_path, @errorName(e) });
        return e;
    };

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

    var r = try scenario.Run.init(gpa, &kinds, &script, &situation, if (options.trace != null) &tw else null, if (options.probe != null) &probe else null);
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

//! sorz-cpus-check: the two CPUs play the whole game (PLAN item 34), from power-on on the content
//! extracted from the user's ROM, as the hosts run it (the game in the agent backend, its keys
//! injected): the game menu's 0 PLAYERS - 2 CPU, Adam for CPU 1 and Axel for CPU 2, then no key
//! until the ending or the game's end, `--limit` display ticks at most. A seed draws the CPUs'
//! own random draws apart (their memories' seeds, set as each round begins, before their first
//! look; 0 leaves them); the game's draws are the original's.
//!
//!   sorz-cpus-check ROM [--lives N] [--seeds S,S,...] [--limit TICKS] [--shots DIR]
//!
//! - `--lives`: the lives a game and a continue give (the settings' rules); 3 by default.
//! - `--shots`: a picture at each round's clear, each life lost and the end, into DIR.
//!
//! Prints a JSON line per seed: how it ended (`ending`, `game_over`, `limit`), the round reached
//! and the display ticks; per round its display ticks, the lives lost, the time overs and the
//! damage the CPUs took by the kind of what dealt it. Build it fast (-Doptimize=ReleaseFast): a
//! game takes about a minute then.
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const extract = @import("extract");

const Key = sorz.platform.Key;
const frame_ns = agent.netplay_cmd.frame_ns;

/// A game in the agent backend, one display tick per update.
const Run = struct {
    backend: agent.AgentBackend,
    storage: sorz.memory.MemoryStorage,
    game: sorz.Game,
    updates: u32 = 0,

    fn create(gpa: std.mem.Allocator, assets: sorz.platform.AssetSource) !*Run {
        const r = try gpa.create(Run);
        errdefer gpa.destroy(r);
        r.backend = agent.AgentBackend.init(gpa, .{});
        r.storage = sorz.memory.MemoryStorage.init(gpa);
        r.game = try sorz.Game.init(gpa, assets, r.storage.storage());
        r.game.pacing = .per_update;
        r.game.variant = .extended;
        r.updates = 0;
        return r;
    }

    fn destroy(r: *Run, gpa: std.mem.Allocator) void {
        r.game.deinit();
        r.storage.deinit();
        r.backend.deinit();
        gpa.destroy(r);
    }

    fn update(r: *Run) !void {
        var p = r.backend.asPlatform();
        _ = try r.game.update(&p);
        r.backend.advance(frame_ns);
        r.updates += 1;
    }

    /// `k` pressed for an update, then released for one.
    fn press(r: *Run, k: Key) !void {
        try r.backend.inject(.{ .time_ns = r.backend.clock_ns, .payload = .{ .key_down = .{ .key = k } } });
        try r.update();
        try r.backend.inject(.{ .time_ns = r.backend.clock_ns, .payload = .{ .key_up = .{ .key = k } } });
        try r.update();
    }

    fn scene(r: *const Run) sorz.flow.Kind {
        return std.meta.activeTag(r.game.state.scenes.base);
    }

    /// Updates until `cond` holds, `limit` updates at most.
    fn until(r: *Run, cond: *const fn (*const Run) bool, limit: u32) !void {
        var n: u32 = 0;
        while (!cond(r)) : (n += 1) {
            if (n == limit) return error.FlowStuck;
            try r.update();
        }
    }
};

fn choosing(r: *const Run) bool {
    return switch (r.game.state.scenes.base) {
        .menu => |*m| m.phase == .choosing and !r.game.overlays.holds(),
        else => false,
    };
}

fn inSelect(r: *const Run) bool {
    return switch (r.game.state.scenes.base) {
        .select => |*s| s.phase == .first_half or s.phase == .second_half,
        else => false,
    };
}

fn againForCpu2(r: *const Run) bool {
    return inSelect(r) and r.game.state.scenes.base.select.cpu_pass;
}

/// A round's measures.
const RoundStats = struct {
    number: u8,
    ticks: u32 = 0,
    lives_lost: u32 = 0,
    time_overs: u32 = 0,
    damage: [max_kinds]struct { kind: []const u8, damage: i32 } = undefined,
    kinds: usize = 0,

    const max_kinds = 32;

    fn hurt(s: *RoundStats, kind: []const u8, damage: i16) void {
        for (s.damage[0..s.kinds]) |*d| if (std.mem.eql(u8, d.kind, kind)) {
            d.damage += damage;
            return;
        };
        if (s.kinds == max_kinds) return;
        s.damage[s.kinds] = .{ .kind = kind, .damage = damage };
        s.kinds += 1;
    }
};

const Options = struct {
    lives: u8 = 3,
    limit: u32 = 900_000,
    shots: ?[]const u8 = null,
};

/// One game the two CPUs play with seed `seed`, reported as a JSON line on `out`.
fn play(gpa: std.mem.Allocator, io: std.Io, assets: sorz.platform.AssetSource, seed: u32, o: Options, out: *std.Io.Writer) !void {
    const r = try Run.create(gpa, assets);
    defer r.destroy(gpa);
    r.game.settings.rules.lives = o.lives;
    // START on the intro, then on the title; right twice on 2 PLAYERS; Adam, then Axel.
    while (r.updates < 500) try r.update();
    try r.press(.enter);
    while (r.updates < 560) try r.update();
    try r.press(.enter);
    try r.until(choosing, 400);
    try r.press(.down);
    try r.press(.right);
    try r.press(.right);
    try r.press(.enter);
    try r.until(inSelect, 600);
    try r.press(.z);
    try r.until(againForCpu2, 600);
    try r.press(.right);
    try r.press(.z);

    var rounds: [16]RoundStats = undefined;
    var n: usize = 0;
    var lives: [2]u8 = .{ 0, 0 };
    var timed_out = false;
    var shots: u32 = 0;
    const how: []const u8 = while (r.updates < o.limit) {
        try r.update();
        switch (r.scene()) {
            .ending, .boss_ending => break "ending",
            .high_scores, .title, .intro, .menu => if (n != 0) break "game_over",
            else => {},
        }
        const round = switch (r.game.state.scenes.base) {
            .round => |*x| x,
            else => continue,
        };
        const w = &r.game.state.scenes.base.round.play.world;
        if (n == 0 or rounds[n - 1].number != round.number) {
            if (n == rounds.len) break "limit";
            if (n != 0 and o.shots != null) try shot(gpa, io, r, o.shots.?, &shots, "clear");
            rounds[n] = .{ .number = round.number };
            n += 1;
            // Each round's world is new, its CPUs' memories too.
            if (seed != 0) for (&w.players, [2]u32{ 0x2545F491, 0x9E3779B9 }) |*pl, mix| {
                pl.cpu.seed = mix *% (seed *% 31 +% round.number) | 1;
            };
        }
        const stats = &rounds[n - 1];
        stats.ticks += 1;
        if (round.phase == .time_over and !timed_out) stats.time_overs += 1;
        timed_out = round.phase == .time_over;
        for (w.players, &lives) |pl, *was| {
            if (pl.lives < was.*) {
                stats.lives_lost += was.* - pl.lives;
                if (o.shots) |dir| try shot(gpa, io, r, dir, &shots, "life");
            }
            was.* = pl.lives;
        }
        if (!round.logic_ran) continue;
        const v = if (r.game.view) |*v| v else continue;
        for (v.world_out.hits.slice()) |hit| {
            const to_player = for (w.players) |pl| {
                if (pl.entity) |h| if (h.eql(hit.target)) break true;
            } else false;
            if (!to_player or hit.damage <= 0) continue;
            const by = if (hit.attacker) |h| w.getConst(h) else null;
            stats.hurt(if (by) |e| r.game.scene_assets.?.round.kinds.get(e.kind.?).name() else "gone", hit.damage);
        }
    } else "limit";
    if (o.shots) |dir| try shot(gpa, io, r, dir, &shots, "end");

    try out.print("{{\"seed\":{d},\"outcome\":\"{s}\",\"round\":{d},\"ticks\":{d},\"rounds\":[", .{ seed, how, if (n == 0) 0 else rounds[n - 1].number, r.updates });
    for (rounds[0..n], 0..) |*s, i| {
        if (i != 0) try out.writeAll(",");
        try out.print("{{\"round\":{d},\"ticks\":{d},\"lives_lost\":{d},\"time_overs\":{d},\"damage\":{{", .{ s.number, s.ticks, s.lives_lost, s.time_overs });
        for (s.damage[0..s.kinds], 0..) |d, j| try out.print("{s}\"{s}\":{d}", .{ if (j == 0) "" else ",", d.kind, d.damage });
        try out.writeAll("}}");
    }
    try out.writeAll("]}\n");
    try out.flush();
}

/// The picture just presented, as DIR/NNNN-TICKS-WHAT.png.
fn shot(gpa: std.mem.Allocator, io: std.Io, r: *const Run, dir: []const u8, count: *u32, what: []const u8) !void {
    const f = r.game.frame();
    const bytes = try agent.png.encode(gpa, f.width, f.height, f.pixels[0 .. f.stride * f.height]);
    defer gpa.free(bytes);
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{d:0>4}-{d}-{s}.png", .{ dir, count.*, r.updates, what });
    count.* += 1;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn usage(io: std.Io) noreturn {
    std.Io.File.stderr().writeStreamingAll(io, "usage: sorz-cpus-check ROM [--lives N] [--seeds S,S,...] [--limit TICKS] [--shots DIR]\n") catch {};
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const rom_path = args.next() orelse usage(io);
    var o: Options = .{};
    var seeds_text: []const u8 = "1";
    while (args.next()) |arg| {
        const value = args.next() orelse usage(io);
        if (std.mem.eql(u8, arg, "--lives")) {
            o.lives = std.fmt.parseInt(u8, value, 10) catch usage(io);
        } else if (std.mem.eql(u8, arg, "--seeds")) {
            seeds_text = value;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            o.limit = std.fmt.parseInt(u32, value, 10) catch usage(io);
        } else if (std.mem.eql(u8, arg, "--shots")) {
            o.shots = value;
        } else usage(io);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(extract.rom.size + 1));
    defer gpa.free(rom);
    var tree = try extract.extract(gpa, rom);
    defer tree.deinit();
    var source = sorz.memory.MemoryAssetSource.init(gpa);
    defer source.deinit();
    try tree.addTo(&source);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var seeds = std.mem.tokenizeScalar(u8, seeds_text, ',');
    while (seeds.next()) |text| {
        const seed = std.fmt.parseInt(u32, text, 10) catch usage(io);
        try play(gpa, io, source.assetSource(), seed, o, &out.interface);
    }
}

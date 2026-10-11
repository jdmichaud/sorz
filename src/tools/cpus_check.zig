//! sorz-cpus-check: the two CPUs play the whole game (PLAN item 34), from power-on on the content
//! extracted from the user's ROM, as the hosts run it (the game in the agent backend, its keys
//! injected): the game menu's 0 PLAYERS - 2 CPU, Adam for CPU 1 and Axel for CPU 2 (`--chars`),
//! then no key until the ending or the game's end, `--limit` display ticks at most. A seed draws
//! the CPUs' own random draws apart (their memories' seeds, set as each round begins, before their
//! first look; 0 leaves them); the game's draws are the original's.
//!
//!   sorz-cpus-check ROM [--lives N] [--chars C1,C2] [--seeds S,S,...] [--limit TICKS] [--shots DIR]
//!
//! - `--lives`: the lives a game and a continue give (the settings' rules); 3 by default.
//! - `--chars`: the CPUs' characters (adam, axel, blaze); adam,axel by default.
//! - `--shots`: a picture at each round's clear, each life lost and the end, into DIR.
//!
//! Prints a JSON line per seed: the characters, how it ended (`ending`, `game_over`, `limit`), the
//! round reached, the display ticks, each CPU's blows landed on the other by what struck
//! (`Causes`) and where the one struck stood (`HitSpot`), and the ticks with foes on both sides of
//! the CPUs by where the CPUs went (`Sides`); per round its display ticks, the lives lost, the time overs, the
//! damage the CPUs took by the kind of what dealt it, and each CPU's blows landed (what it threw
//! too) on the enemies and on the other CPU. Build it fast (-Doptimize=ReleaseFast): a game
//! takes about a minute then.
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

fn inRound(r: *const Run) bool {
    return r.scene() == .round;
}

/// A round's measures.
const RoundStats = struct {
    number: u8,
    ticks: u32 = 0,
    lives_lost: u32 = 0,
    time_overs: u32 = 0,
    damage: [max_kinds]struct { kind: []const u8, damage: i32 } = undefined,
    kinds: usize = 0,
    /// Each CPU's blows landed (with what it threw), on the enemies and on the other CPU.
    blows: [2]struct { enemies: u32 = 0, partner: u32 = 0 } = .{ .{}, .{} },

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

/// A CPU's blows landed on the other CPU, by what struck: `how` the way (`blow` with the
/// state the striker struck in, `hold`, `throw`, `thrown` and the kind of the thing thrown,
/// `other` and the state the one struck was in), `what` its name.
const Causes = struct {
    list: [most]struct { how: []const u8, what: []const u8, count: u32 } = undefined,
    len: usize = 0,

    const most = 48;

    fn add(c: *Causes, how: []const u8, what: []const u8) void {
        for (c.list[0..c.len]) |*x| if (std.mem.eql(u8, x.how, how) and std.mem.eql(u8, x.what, what)) {
            x.count += 1;
            return;
        };
        if (c.len == most) return;
        c.list[c.len] = .{ .how = how, .what = what, .count = 1 };
        c.len += 1;
    }
};

const Character = sorz.setup.Character;

const Options = struct {
    lives: u8 = 3,
    characters: [2]Character = .{ .adam, .axel },
    limit: u32 = 900_000,
    shots: ?[]const u8 = null,
};

/// One game the two CPUs play with seed `seed`, reported as a JSON line on `out`.
fn play(gpa: std.mem.Allocator, io: std.Io, assets: sorz.platform.AssetSource, seed: u32, o: Options, out: *std.Io.Writer) !void {
    const r = try Run.create(gpa, assets);
    defer r.destroy(gpa);
    r.game.settings.rules.lives = o.lives;
    // START on the intro, then on the title; right twice on 2 PLAYERS; each CPU's character, its
    // cursor from Adam.
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
    for (0..@backingInt(o.characters[0])) |_| try r.press(.right);
    try r.press(.z);
    try r.until(againForCpu2, 600);
    for (0..@backingInt(o.characters[1])) |_| try r.press(.right);
    try r.press(.z);
    try r.until(inRound, 600);
    for (r.game.state.setup.characters, o.characters) |got, want| if (got != want) return error.WrongCharacter;

    var rounds: [16]RoundStats = undefined;
    var n: usize = 0;
    var lives: [2]u8 = .{ 0, 0 };
    var timed_out = false;
    var stage: @TypeOf(r.game.state.scenes.base.round.play.world.script.stage) = .opening;
    var shots: u32 = 0;
    var causes: [2]Causes = .{ .{}, .{} };
    // Each CPU's state at the last logic tick, and the state its partner struck it in then (a
    // blow is felt, its damage taken, at the tick after it lands).
    var was_in: [2]?PlayerState = .{ null, null };
    var struck_in: [2]?PlayerState = .{ null, null };
    var was_at: [2]?@FieldType(sorz.world.entity.Entity, "position") = .{ null, null };
    var sides: Sides = .{};
    var spots: std.ArrayList(HitSpot) = .empty;
    defer spots.deinit(gpa);
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
        // The time over's end, and the boss's fall, credit their harm to the last striker.
        const harm_told = (timed_out and round.phase != .time_over) or (w.script.stage != stage and (w.script.stage == .fight_over or w.script.stage == .won));
        timed_out = round.phase == .time_over;
        stage = w.script.stage;
        for (w.players, &lives) |pl, *was| {
            if (pl.lives < was.*) {
                stats.lives_lost += was.* - pl.lives;
                if (o.shots) |dir| try shot(gpa, io, r, dir, &shots, "life");
            }
            was.* = pl.lives;
        }
        if (!round.logic_ran) continue;
        sides.see(w, r.game.scene_assets.?.round.kinds);
        const v = if (r.game.view) |*v| v else continue;
        for (v.world_out.hits.slice()) |hit| {
            const to_player = w.playerOf(hit.target) != null;
            if (!harm_told) if (striker(w, hit.attacker)) |p| {
                if (w.playerOf(hit.target)) |q| {
                    if (q != p) {
                        stats.blows[p].partner += 1;
                        const c = cause(r, w, hit.attacker.?, struck_in[q], was_in[q]);
                        causes[p].add(c[0], c[1]);
                    }
                } else if (w.getConst(hit.target)) |e| if (e.team == .enemy) {
                    stats.blows[p].enemies += 1;
                };
            };
            if (!to_player or hit.damage <= 0) continue;
            const by = if (hit.attacker) |h| w.getConst(h) else null;
            stats.hurt(if (by) |e| r.game.scene_assets.?.round.kinds.get(e.kind.?).name() else "gone", hit.damage);
        }
        for (0..2) |i| {
            const p: u1 = @intCast(i);
            was_in[p] = playerState(w, p);
            struck_in[p] = null;
            const m = playerMind(w, p) orelse continue;
            const t = m.taken orelse continue;
            if (w.playerOf(t.by) == 1 - p) {
                struck_in[p] = playerState(w, 1 - p);
                if (spotOf(w, 1 - p, was_at[p])) |x| try spots.append(gpa, x);
            }
        }
        for (0..2) |i| was_at[i] = if (w.players[i].entity) |h| if (w.getConst(h)) |e| e.position else null else null;
    } else "limit";
    if (o.shots) |dir| try shot(gpa, io, r, dir, &shots, "end");

    try out.print("{{\"seed\":{d},\"characters\":[\"{t}\",\"{t}\"],\"outcome\":\"{s}\",\"round\":{d},\"ticks\":{d},\"partner_causes\":[", .{ seed, o.characters[0], o.characters[1], how, if (n == 0) 0 else rounds[n - 1].number, r.updates });
    for (causes, 0..) |c, i| {
        try out.writeAll(if (i == 0) "{" else ",{");
        for (c.list[0..c.len], 0..) |x, j| try out.print("{s}\"{s}{s}{s}\":{d}", .{ if (j == 0) "" else ",", x.how, if (x.what.len == 0) "" else " ", x.what, x.count });
        try out.writeAll("}");
    }
    try out.print("],\"sides\":{{\"ticks\":{d},\"same\":{d},\"split\":{d},\"other\":{d}}}", .{ sides.ticks, sides.same, sides.split, sides.other });
    try out.writeAll(",\"partner_hits\":[");
    for (spots.items, 0..) |x, i| try out.print("{s}[{d},{d},{d},\"{t}\",\"{s}\",{d},\"{s}\",{},{d},{d},\"{t}\"]", .{ if (i == 0) "" else ",", x.striker, x.ahead, x.depth, x.state, x.foe, x.foe_ahead, x.goal, x.same_foe, x.moved_ahead, x.moved_depth, x.striker_state });
    try out.writeAll("],\"rounds\":[");
    for (rounds[0..n], 0..) |*s, i| {
        if (i != 0) try out.writeAll(",");
        try out.print("{{\"round\":{d},\"ticks\":{d},\"lives_lost\":{d},\"time_overs\":{d},\"damage\":{{", .{ s.number, s.ticks, s.lives_lost, s.time_overs });
        for (s.damage[0..s.kinds], 0..) |d, j| try out.print("{s}\"{s}\":{d}", .{ if (j == 0) "" else ",", d.kind, d.damage });
        try out.writeAll("},\"blows\":[");
        for (s.blows, 0..) |b, j| try out.print("{s}{{\"enemies\":{d},\"partner\":{d}}}", .{ if (j == 0) "" else ",", b.enemies, b.partner });
        try out.writeAll("]}");
    }
    try out.writeAll("]}\n");
    try out.flush();
}

const PlayerState = sorz.world.behaviours.player.State;

fn playerMind(w: *const sorz.world.World, p: u1) ?*const sorz.world.behaviours.player.Mind {
    const e = w.getConst(w.players[p].entity orelse return null) orelse return null;
    return switch (e.mind) {
        .player => |*m| m,
        else => null,
    };
}

fn playerState(w: *const sorz.world.World, p: u1) ?PlayerState {
    return (playerMind(w, p) orelse return null).state;
}

/// What struck a CPU from its partner, `attacker`: a thing it threw; the blow it felt, landed at
/// the last tick (`struck`: the striker's state then); a knee in a hold, or a throw's fall (by
/// the state it was in at the last tick, `was`).
fn cause(r: *const Run, w: *const sorz.world.World, attacker: sorz.world.Handle, struck: ?PlayerState, was: ?PlayerState) struct { []const u8, []const u8 } {
    if (w.playerOf(attacker) == null) {
        const e = w.getConst(attacker) orelse return .{ "thrown", "gone" };
        return .{ "thrown", r.game.scene_assets.?.round.kinds.get(e.kind.?).name() };
    }
    if (struck) |s| return .{ "blow", @tagName(s) };
    const s = was orelse return .{ "other", "none" };
    return switch (s) {
        .held, .held_behind => .{ "hold", "" },
        .thrown, .tossed, .thrown_fall, .slammed, .air_fall, .air_slam, .lift, .shaken, .slam_pause => .{ "throw", @tagName(s) },
        else => .{ "other", @tagName(s) },
    };
}

/// The logic ticks foes stood on both sides of the two CPUs (on the screen, left of both and right
/// of both), by where the CPUs' goals lay then: both foes on one side (`same`), one on each
/// (`split`), or else (a goal between them, or not a foe).
const Sides = struct {
    ticks: u32 = 0,
    same: u32 = 0,
    split: u32 = 0,
    other: u32 = 0,

    fn see(s: *Sides, w: *const sorz.world.World, kinds: anytype) void {
        var at: [2]i32 = undefined;
        for (0..2) |i| {
            const p: u1 = @intCast(i);
            if (playerMind(w, p) == null) return;
            at[p] = w.getConst(w.players[p].entity.?).?.position.x.whole();
        }
        const lo = @min(at[0], at[1]);
        const hi = @max(at[0], at[1]);
        const left = w.camera.x.whole();
        var foes_left = false;
        var foes_right = false;
        for (&w.entities) |*e| {
            if (!foe(e, kinds)) continue;
            const x = e.position.x.whole();
            if (x < left or x >= left + 320) continue;
            if (x < lo) foes_left = true;
            if (x > hi) foes_right = true;
        }
        if (!foes_left or !foes_right) return;
        s.ticks += 1;
        var side: [2]i32 = .{ 0, 0 };
        for (w.players, &side) |pl, *d| switch (pl.cpu.goal) {
            .foe => |h| if (w.getConst(h)) |e| {
                const x = e.position.x.whole();
                d.* = if (x < lo) -1 else if (x > hi) 1 else 0;
            },
            else => {},
        };
        if (side[0] == 0 or side[1] == 0) {
            s.other += 1;
        } else if (side[0] == side[1]) s.same += 1 else s.split += 1;
    }

    fn foe(e: *const sorz.world.entity.Entity, kinds: anytype) bool {
        if (!e.alive() or e.flags.hidden or e.team != .enemy or e.health < 0) return false;
        switch (kinds.get(e.kind.?).family()) {
            .enemy, .boss => {},
            else => return false,
        }
        const B = sorz.world.behaviours;
        return !B.inState(&e.mind, "appear") and !B.inState(&e.mind, "enter") and !B.inState(&e.mind, "knocked_out");
    }
};

/// Where a CPU stood as its partner's blow landed on it, at the end of that tick: across ahead of
/// the striker (by its facing) and in depth from it; its state, its goal and whether that is the
/// striker's foe; how far it moved at the tick (ahead by the striker's facing, and in depth); the
/// nearest enemy in the striker's line ahead (`foe`: `beyond` it stood past one, `before` it stood
/// between the striker and one, `none`) and how far ahead.
const HitSpot = struct {
    striker: u1,
    striker_state: PlayerState,
    ahead: i32,
    depth: i32,
    state: PlayerState,
    foe: []const u8,
    foe_ahead: i32,
    goal: []const u8,
    same_foe: bool,
    moved_ahead: i32,
    moved_depth: i32,
};

fn spotOf(w: *const sorz.world.World, k: u1, was: ?@FieldType(sorz.world.entity.Entity, "position")) ?HitSpot {
    const p = w.getConst(w.players[k].entity orelse return null) orelse return null;
    const q = w.getConst(w.players[1 - k].entity orelse return null) orelse return null;
    const s: i32 = if (p.facing == .left) -1 else 1;
    const ahead = (q.position.x.whole() - p.position.x.whole()) * s;
    var foe_ahead: i32 = std.math.maxInt(i32);
    for (&w.entities) |*e| {
        if (!e.alive() or e.flags.hidden or e.team != .enemy or e.boxes.body == null) continue;
        if (@abs(e.position.depth.whole() - p.position.depth.whole()) > 16) continue;
        const x = (e.position.x.whole() - p.position.x.whole()) * s;
        if (x > -8 and x < foe_ahead) foe_ahead = x;
    }
    const goals = .{ w.players[k].cpu.goal, w.players[1 - k].cpu.goal };
    return .{
        .striker = k,
        .striker_state = p.mind.player.state,
        .ahead = ahead,
        .depth = q.position.depth.whole() - p.position.depth.whole(),
        .state = q.mind.player.state,
        .foe = if (foe_ahead == std.math.maxInt(i32)) "none" else if (foe_ahead < ahead) "beyond" else "before",
        .foe_ahead = if (foe_ahead == std.math.maxInt(i32)) -1 else foe_ahead,
        .goal = @tagName(goals[1]),
        .same_foe = goals[0] == .foe and goals[1] == .foe and goals[0].foe.eql(goals[1].foe),
        .moved_ahead = if (was) |x| (q.position.x.whole() - x.x.whole()) * s else 0,
        .moved_depth = if (was) |x| q.position.depth.whole() - x.depth.whole() else 0,
    };
}

/// The CPU whose blow `attacker` is: the player itself, or the thing it threw.
fn striker(w: *const sorz.world.World, attacker: ?sorz.world.Handle) ?u1 {
    const h = attacker orelse return null;
    if (w.playerOf(h)) |p| return p;
    const m = (w.getConst(h) orelse return null).missile orelse return null;
    return w.playerOf(m.by);
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
    std.Io.File.stderr().writeStreamingAll(io, "usage: sorz-cpus-check ROM [--lives N] [--chars C1,C2] [--seeds S,S,...] [--limit TICKS] [--shots DIR]\n") catch {};
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
        } else if (std.mem.eql(u8, arg, "--chars")) {
            var it = std.mem.tokenizeScalar(u8, value, ',');
            for (&o.characters) |*c| c.* = std.meta.stringToEnum(Character, it.next() orelse usage(io)) orelse usage(io);
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

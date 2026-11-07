//! sorz-cpus-check: the two CPUs play the whole game (PLAN item 34), from power-on on the content
//! extracted from the user's ROM, as the hosts run it (the game in the agent backend, its keys
//! injected): the game menu's 0 PLAYERS - 2 CPU, Adam for CPU 1 and Axel for CPU 2 (`--chars`),
//! then no key until the ending or the game's end, `--limit` display ticks at most. A seed draws
//! the CPUs' own random draws apart (their memories' seeds, set as each round begins, before their
//! first look; 0 leaves them); the game's draws are the original's.
//!
//!   sorz-cpus-check ROM [--lives N] [--level L] [--from R] [--to R] [--chars C1,C2]
//!                       [--seeds S,S,...] [--limit TICKS] [--shots DIR] [--scenes on]
//!                       [--player1 cpu|bot] [--turns on]
//!
//! - `--lives`: the lives a game and a continue give (the settings' rules); 3 by default.
//! - `--level`: the options' LEVEL, 0 easy to 3 hardest; 1 (normal) by default.
//! - `--from`, `--to`: the rounds played, 1 to 8 by default: the game starts at `--from` (the
//!   options' first round) and is left as the round after `--to` begins (`to`).
//! - `--chars`: the CPUs' characters (adam, axel, blaze); adam,axel by default.
//! - `--shots`: a picture at each round's clear, each life lost and the end, into DIR.
//! - `--scenes on`: each scene's start told on stderr; the game followed past the ending.
//! - `--player1 bot`: 1 PLAYER - 1 CPU instead, player 1 played by item 30's rule (`cpu.fight`,
//!   the agent host's bot: on to the right, at the nearest foe), the CPU player 2 (`--chars`
//!   player 1's, then the CPU's). Not for round 8, which goes left.
//! - `--turns on`: each CPU's quick turns (`Turns`) told on stderr, with its memory (`tellTurn`).
//!
//! Prints a JSON line per seed: the characters, how it ended (`ending`, `game_over`, `limit`,
//! `to`), the round reached, the display ticks, each CPU's blows landed on the other by what
//! struck (`Causes`) and where the one struck stood (`HitSpot`), the ticks with foes on both sides
//! of the CPUs by where the CPUs went (`Sides`), and what each CPU did of a player's skills (holds
//! broken, weapons, food: `Skills`), each player's turns that look unnatural (`Turns`), lives
//! lost and damage taken from the foes, player 2's pace with player 1 on a free screen (`Pace`);
//! per round its display ticks, the lives lost, the time overs, the damage the CPUs took by the
//! kind of what dealt it, and each CPU's blows landed (what it threw too) on the enemies and on
//! the other CPU. Build it fast and alone: `zig build
//! cpus-check-exe -Doptimize=ReleaseFast --prefix DIR`; a whole game takes about a minute then.
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

/// What each CPU did of a player's skills: held from behind by an enemy (its holds, those it may
/// jump out of: not round 5's twins'), its jumps out and its throws of the holder; held from the
/// front by one; thrown by one, and landed on its feet; the weapons it
/// picked up, its logic ticks armed and its blows landed armed on the foes; the food it ate; its
/// logic ticks badly hurt (under 40% of its health), and of those, with food lying on the
/// screen; its logic ticks in play, the damage it dealt the foes, and of it, armed.
const Skills = struct {
    held_behind: u32 = 0,
    escapable: u32 = 0,
    escapes: u32 = 0,
    counters: u32 = 0,
    held_front: u32 = 0,
    thrown: u32 = 0,
    on_feet: u32 = 0,
    weapons: u32 = 0,
    armed_ticks: u32 = 0,
    armed_blows: u32 = 0,
    food: u32 = 0,
    hurt_ticks: u32 = 0,
    hurt_food_ticks: u32 = 0,
    play_ticks: u32 = 0,
    dealt: u32 = 0,
    armed_dealt: u32 = 0,
};

const Options = struct {
    lives: u8 = 3,
    /// The options' LEVEL: 0 easy to 3 hardest.
    level: u8 = 1,
    /// The rounds played: from the first (the options' hidden line), to the last (the game left
    /// as the next begins).
    from: u8 = 1,
    to: u8 = 8,
    characters: [2]Character = .{ .adam, .axel },
    limit: u32 = 900_000,
    shots: ?[]const u8 = null,
    /// Each scene's start told on stderr, and the game followed past the ending to the title.
    scenes: bool = false,
    /// Who plays player 1: the CPU (0 PLAYERS - 2 CPU), or item 30's rule (`cpu.fight`, the
    /// agent host's bot) in 1 PLAYER - 1 CPU, the CPU player 2.
    player1: enum { cpu, bot } = .cpu,
    /// Each CPU's quick turns told on stderr (`tellTurn`).
    turns: bool = false,
};

/// One game the two CPUs play with seed `seed`, reported as a JSON line on `out`.
fn play(gpa: std.mem.Allocator, io: std.Io, assets: sorz.platform.AssetSource, seed: u32, o: Options, out: *std.Io.Writer) !void {
    const r = try Run.create(gpa, assets);
    defer r.destroy(gpa);
    r.game.settings.rules.lives = o.lives;
    r.game.state.setup.level = o.level;
    // START on the intro, then on the title; right twice on 2 PLAYERS; each CPU's character, its
    // cursor from Adam.
    while (r.updates < 500) try r.update();
    try r.press(.enter);
    while (r.updates < 560) try r.update();
    try r.press(.enter);
    try r.until(choosing, 400);
    r.game.state.setup.first_round = o.from - 1;
    try r.press(.down);
    try r.press(.right);
    if (o.player1 == .cpu) try r.press(.right);
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
    var skills: [2]Skills = .{ .{}, .{} };
    var spots: std.ArrayList(HitSpot) = .empty;
    defer spots.deinit(gpa);
    var was_scene = r.scene();
    var ended = false;
    var turns: [2]Turns = .{ .{}, .{} };
    var pace: Pace = .{};
    var held: sorz.input.Pad = .{};
    var logic: u32 = 0;
    // Each player's lives lost, and the damage it took from the foes.
    var each: struct { lives_lost: [2]u32 = .{ 0, 0 }, damage: [2]u32 = .{ 0, 0 } } = .{};
    const how: []const u8 = while (r.updates < o.limit) {
        if (o.player1 == .bot) try hold(r, &held, botPad(r));
        try r.update();
        if (o.scenes and r.scene() != was_scene) {
            was_scene = r.scene();
            std.debug.print("seed {d}: {t} at display tick {d}\n", .{ seed, was_scene, r.updates });
        }
        switch (r.scene()) {
            .ending, .boss_ending => if (o.scenes) {
                ended = true;
            } else break "ending",
            .high_scores, .title, .intro, .menu, .sega_logo => if (ended) break "ending" else if (n != 0) break "game_over",
            else => {},
        }
        const round = switch (r.game.state.scenes.base) {
            .round => |*x| x,
            else => continue,
        };
        const w = &r.game.state.scenes.base.round.play.world;
        if (n == 0 or rounds[n - 1].number != round.number) {
            if (n == rounds.len) break "limit";
            if (round.number > o.to) break "to";
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
        if (o.scenes and w.script.stage != stage) std.debug.print("seed {d}: round {d} {t} at display tick {d}\n", .{ seed, round.number, w.script.stage, r.updates });
        stage = w.script.stage;
        for (w.players, &lives, &each.lives_lost) |pl, *was, *lost| {
            if (pl.lives < was.*) {
                stats.lives_lost += was.* - pl.lives;
                lost.* += was.* - pl.lives;
                if (o.shots) |dir| try shot(gpa, io, r, dir, &shots, "life");
            }
            was.* = pl.lives;
        }
        if (!round.logic_ran) continue;
        logic += 1;
        sides.see(w, r.game.scene_assets.?.round.kinds);
        for (&turns, 0..) |*t, i| t.see(w, r.game.scene_assets.?.round.kinds, @intCast(i), logic, o.turns and (o.player1 == .cpu or i == 1));
        pace.see(w, r.game.scene_assets.?.round.kinds);
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
                    skills[p].dealt += @intCast(@max(hit.damage, 0));
                    // An armed player's blow is its weapon's, a thing that strikes in its hand.
                    if (w.getConst(hit.attacker.?)) |x| if (r.game.scene_assets.?.round.kinds.get(x.kind.?).family() == .weapon) if (playerState(w, p)) |st| if (armed(st)) {
                        skills[p].armed_blows += 1;
                        skills[p].armed_dealt += @intCast(@max(hit.damage, 0));
                    };
                };
            };
            if (!to_player or hit.damage <= 0) continue;
            if (striker(w, hit.attacker) == null) each.damage[w.playerOf(hit.target).?] += @intCast(hit.damage);
            const by = if (hit.attacker) |h| w.getConst(h) else null;
            stats.hurt(if (by) |e| r.game.scene_assets.?.round.kinds.get(e.kind.?).name() else "gone", hit.damage);
        }
        const kinds = r.game.scene_assets.?.round.kinds;
        for (v.world_out.pickups.slice()) |pick| {
            const p = w.playerOf(pick.by) orelse continue;
            const k = kinds.get(pick.kind);
            if (k.family() == .weapon) skills[p].weapons += 1;
            if (isFood(k)) skills[p].food += 1;
        }
        const food_lying = foodLying(w, kinds);
        for (0..2) |i| {
            const p: u1 = @intCast(i);
            const m = playerMind(w, p) orelse continue;
            const e = w.getConst(w.players[p].entity.?).?;
            const by_enemy = if (e.holder) |h| w.playerOf(h) == null else false;
            const sk = &skills[p];
            if (was_in[p]) |was| if (m.state != was) switch (m.state) {
                .held_behind => if (was != .escape and by_enemy) {
                    sk.held_behind += 1;
                    if (w.getConst(e.holder.?)) |x| if (x.mind != .boss_r5) {
                        sk.escapable += 1;
                    };
                },
                .escape => sk.escapes += 1,
                .grab_blow => if (was == .held_behind) {
                    sk.counters += 1;
                },
                .held => if (by_enemy) {
                    sk.held_front += 1;
                },
                .thrown => if (if (m.thrower) |h| w.playerOf(h) == null else true) {
                    sk.thrown += 1;
                },
                .land => if (was == .knocked_down) {
                    sk.on_feet += 1;
                },
                else => {},
            };
            if (armed(m.state)) sk.armed_ticks += 1;
            sk.play_ticks += 1;
            const full: i32 = kinds.get(e.kind.?).definition.health;
            if (full != 0 and @as(i32, e.health) * 100 < full * 40) {
                sk.hurt_ticks += 1;
                if (food_lying) sk.hurt_food_ticks += 1;
            }
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
    try out.writeAll(",\"skills\":[");
    for (skills, 0..) |sk, i| {
        try out.writeAll(if (i == 0) "{" else ",{");
        inline for (@typeInfo(Skills).@"struct".field_names, 0..) |name, j| try out.print("{s}\"{s}\":{d}", .{ if (j == 0) "" else ",", name, @field(sk, name) });
        try out.writeAll("}");
    }
    try out.writeAll("],\"turns\":[");
    for (turns, 0..) |t, i| {
        try out.writeAll(if (i == 0) "{" else ",{");
        inline for (.{ "calm_ticks", "flips", "quick_flips", "calm_quick_flips", "depth_turns", "quick_depth_turns", "calm_quick_depth_turns" }, 0..) |name, j| try out.print("{s}\"{s}\":{d}", .{ if (j == 0) "" else ",", name, @field(t, name) });
        try out.writeAll("}");
    }
    try out.print("],\"lives_lost\":[{d},{d}],\"damage_taken\":[{d},{d}]", .{ each.lives_lost[0], each.lives_lost[1], each.damage[0], each.damage[1] });
    try out.print(",\"pace\":{{\"free_ticks\":{d},\"held_ticks\":{d},\"behind_ticks\":{d},\"trail_sum\":{d}}}", .{ pace.free_ticks, pace.held_ticks, pace.behind_ticks, pace.trail_sum });
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

fn armed(s: PlayerState) bool {
    return std.mem.startsWith(u8, @tagName(s), "armed_");
}

fn isFood(k: *const sorz.world.kinds.Kind) bool {
    return k.behaviour == .item and sorz.world.kinds.numbersOf(sorz.world.behaviours.module(.item), k).health > 0;
}

/// Whether food lies on the screen.
fn foodLying(w: *const sorz.world.World, kinds: anytype) bool {
    const left = w.camera.x.whole();
    for (&w.entities) |*e| {
        if (!e.alive() or e.flags.hidden or e.mind != .item or e.mind.item.state != .lying or e.holder != null) continue;
        const x = e.position.x.whole();
        if (x < left or x >= left + 320) continue;
        if (isFood(kinds.get(e.kind.?))) return true;
    }
    return false;
}

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

/// Player 1's pad by item 30's rule (`cpu.fight`, the agent host's bot) while it fights; out of
/// the fight (the offer's choice, the continue's question, the name entry) the CPU's own answers.
fn botPad(r: *const Run) sorz.input.Pad {
    const cpu = sorz.world.cpu;
    const a = if (r.game.scene_assets) |*a| a else return .{};
    const layout = a.round.screen.buttons.of(r.game.state.setup.control);
    const letters = a.round.screen.name_entry.letters;
    switch (r.game.state.scenes.base) {
        .round => |*round| {
            const w = &round.play.world;
            if (!w.room.choosing[0]) if (cpu.fight(w, a.round.kinds, 0, r.updates)) |p| return p;
            var m: cpu.Memory = .{};
            return cpu.pad(w, .{ .kinds = a.round.kinds, .letters = letters, .layout = layout }, &m, 0);
        },
        .round_clear => |*c| if (c.names[0]) |*m| if (!c.named[0]) return cpu.entry(m, letters, layout, r.updates % 2 == 0),
        else => {},
    }
    return .{};
}

/// Player 1's keys held as `want` plays them (the default keys), from `held`.
fn hold(r: *Run, held: *sorz.input.Pad, want: sorz.input.Pad) !void {
    const keys = .{ .{ "up", Key.up }, .{ "down", Key.down }, .{ "left", Key.left }, .{ "right", Key.right }, .{ "a", Key.z }, .{ "b", Key.x }, .{ "c", Key.c }, .{ "start", Key.enter } };
    inline for (keys) |kv| if (@field(want, kv[0]) != @field(held.*, kv[0])) {
        try r.backend.inject(.{ .time_ns = r.backend.clock_ns, .payload = if (@field(want, kv[0])) .{ .key_down = .{ .key = kv[1] } } else .{ .key_up = .{ .key = kv[1] } } });
    };
    held.* = want;
}

/// A quick turn of player `k`'s CPU told on stderr (`--turns on`): `what` (`flip`, `depth`, with
/// a foe near `fflip`, `fdepth`), the world's clock, its place (across, on the screen, in depth),
/// facing and state; its goal and where it lies from it; player 1's place from it, state and
/// facing; its memory's actions chosen and walk wanted (bits from the right: up, down, left,
/// right, special, attack, jump, start) and its counters.
fn tellTurn(w: *const sorz.world.World, k: u1, what: []const u8) void {
    const e = w.getConst(w.players[k].entity.?).?;
    const m = &w.players[k].cpu;
    const q = if (w.players[1 - k].entity) |h| w.getConst(h) else null;
    const px = e.position.x.whole();
    const pd = e.position.depth.whole();
    std.debug.print("turn {s} t={d} cpu={d} x={d} sx={d} d={d} f={t} st={t} goal={t}", .{ what, w.tick, k, px, px - w.camera.x.whole(), pd, e.facing, e.mind.player.state, m.goal });
    switch (m.goal) {
        .roam => |s| std.debug.print(" at=({d},{d})", .{ s.x - px, s.depth - pd }),
        inline else => |h| if (w.getConst(h)) |x| std.debug.print(" at=({d},{d})", .{ x.position.x.whole() - px, x.position.depth.whole() - pd }),
    }
    if (q) |p1| if (p1.mind == .player) std.debug.print(" p1=({d},{d}) p1st={t} p1f={t}", .{ p1.position.x.whole() - px, p1.position.depth.whole() - pd, p1.mind.player.state, p1.facing });
    std.debug.print(" chose={b:0>8} wanted={b:0>8} wait={d} detour={d} linger={d} stuck={d} dodge={} back={d} look={d}\n", .{ @as(u8, @bitCast(m.chose)), @as(u8, @bitCast(m.wanted)), m.wait, m.detour, m.linger, m.stuck, m.dodge, m.back_off, m.look });
}

/// A CPU's turns that look unnatural: its facing turned round, and its walk in depth reversed,
/// while it stands free to act (ready, idle or walking) at both logic ticks; quick, within
/// `quick_ticks` of its last turn with nothing else in between (no blow, no hurt: neither leaves
/// it free); calm, with no foe within `calm_px` (across plus in depth). Its logic ticks free to
/// act and calm.
const Turns = struct {
    calm_ticks: u32 = 0,
    flips: u32 = 0,
    quick_flips: u32 = 0,
    calm_quick_flips: u32 = 0,
    depth_turns: u32 = 0,
    quick_depth_turns: u32 = 0,
    calm_quick_depth_turns: u32 = 0,
    /// Its facing and depth at the last logic tick (null: not free to act then), the tick of its
    /// last turn round, its walk's way in depth and the tick that way began.
    facing: ?sorz.world.entity.Facing = null,
    depth: i32 = 0,
    flip_at: ?u32 = null,
    way: i2 = 0,
    way_at: ?u32 = null,

    const quick_ticks = 15;
    const calm_px = 120;

    fn see(t: *Turns, w: *const sorz.world.World, kinds: anytype, k: u1, now: u32, tell: bool) void {
        const m = playerMind(w, k) orelse return t.reset();
        switch (m.state) {
            .ready, .idle, .walk, .armed_stand, .armed_walk => {},
            else => return t.reset(),
        }
        const e = w.getConst(w.players[k].entity.?).?;
        var calm = true;
        for (&w.entities) |*f| {
            if (Sides.foe(f, kinds) and @abs(f.position.x.whole() - e.position.x.whole()) + @abs(f.position.depth.whole() - e.position.depth.whole()) <= calm_px) calm = false;
        }
        if (calm) t.calm_ticks += 1;
        const depth = e.position.depth.raw;
        if (t.facing) |f| {
            if (f != e.facing) {
                t.flips += 1;
                if (t.flip_at) |at| if (now - at < quick_ticks) {
                    t.quick_flips += 1;
                    if (calm) t.calm_quick_flips += 1;
                    if (tell) tellTurn(w, k, if (calm) "flip" else "fflip");
                };
                t.flip_at = now;
            }
            const way: i2 = if (depth > t.depth) 1 else if (depth < t.depth) -1 else 0;
            if (way != 0 and way != t.way) {
                if (t.way != 0) {
                    t.depth_turns += 1;
                    if (t.way_at) |at| if (now - at < quick_ticks) {
                        t.quick_depth_turns += 1;
                        if (calm) t.calm_quick_depth_turns += 1;
                        if (tell) tellTurn(w, k, if (calm) "depth" else "fdepth");
                    };
                }
                t.way = way;
                t.way_at = now;
            }
        }
        t.facing = e.facing;
        t.depth = depth;
    }

    fn reset(t: *Turns) void {
        t.facing = null;
        t.flip_at = null;
        t.way = 0;
        t.way_at = null;
    }
};

/// Player 2 keeping up with player 1 while no foe is on the screen and both fight (the screen
/// free): its logic ticks (`free_ticks`); those it held the camera back (the camera would move on
/// the round's way, further by player 1 alone, and is not at its wall: it follows two players
/// only as both let it); those it trailed player 1 by more than `behind_px` on the round's way;
/// and how far it trailed in all (pixels, ahead counted less).
const Pace = struct {
    free_ticks: u32 = 0,
    held_ticks: u32 = 0,
    behind_ticks: u32 = 0,
    trail_sum: i64 = 0,

    const behind_px = 32;

    fn see(s: *Pace, w: *const sorz.world.World, kinds: anytype) void {
        const c = &w.camera;
        const rules = c.follows orelse return;
        if (c.run != null) return;
        var at: [2]i32 = undefined;
        for (0..2) |i| {
            const p: u1 = @intCast(i);
            if (playerMind(w, p) == null) return;
            at[p] = w.getConst(w.players[p].entity.?).?.position.x.whole();
        }
        const left = c.x.whole();
        for (&w.entities) |*e| {
            if (!Sides.foe(e, kinds)) continue;
            const x = e.position.x.whole();
            if (x >= left and x < left + 320) return;
        }
        const way: i32 = if (rules.leftward) -1 else 1;
        s.free_ticks += 1;
        const trail = (at[0] - at[1]) * way;
        s.trail_sum += trail;
        if (trail > behind_px) s.behind_ticks += 1;
        const d0 = c.drawn[0] orelse return;
        const d1 = c.drawn[1] orelse return;
        const alone = std.math.clamp(follow(c, rules, &.{d0}), -rules.most, rules.most) * way;
        const both = std.math.clamp(follow(c, rules, &.{ d0, d1 }), -rules.most, rules.most) * way;
        const wall = if (rules.leftward) c.x.whole() <= c.x_min.whole() else c.x.whole() >= c.x_max.whole();
        if (alone > 0 and both < alone and !wall) s.held_ticks += 1;
    }

    /// The camera's move across by the players drawn at `drawn` (systems.zig `followSpeed`).
    fn follow(c: *const sorz.world.Camera, rules: sorz.world.Camera.Rules, drawn: []const sorz.world.Fixed) i32 {
        const start: i32 = rules.band[0];
        const end: i32 = rules.band[1];
        var xs: [2]i32 = undefined;
        for (drawn, 0..) |d, i| xs[i] = d.whole() - c.x.whole();
        if (drawn.len == 1) {
            if (xs[0] < start) return xs[0] - start;
            if (xs[0] >= end) return xs[0] - end;
            return 0;
        }
        const fore = @max(xs[0], xs[1]);
        const hind = @min(xs[0], xs[1]);
        if (fore >= end) return if (hind < start) 0 else @min(fore - end, hind - start);
        if (hind >= start) return 0;
        return @max(fore - end, hind - start);
    }
};

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
    std.Io.File.stderr().writeStreamingAll(io, "usage: sorz-cpus-check ROM [--lives N] [--level L] [--from R] [--to R] [--chars C1,C2] [--seeds S,S,...] [--limit TICKS] [--shots DIR] [--scenes on] [--player1 cpu|bot] [--turns on]\n") catch {};
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
        } else if (std.mem.eql(u8, arg, "--level")) {
            o.level = std.fmt.parseInt(u8, value, 10) catch usage(io);
            if (o.level > 3) usage(io);
        } else if (std.mem.eql(u8, arg, "--from") or std.mem.eql(u8, arg, "--to")) {
            const r = std.fmt.parseInt(u8, value, 10) catch usage(io);
            if (r < 1 or r > 8) usage(io);
            if (arg[2] == 'f') o.from = r else o.to = r;
        } else if (std.mem.eql(u8, arg, "--chars")) {
            var it = std.mem.tokenizeScalar(u8, value, ',');
            for (&o.characters) |*c| c.* = std.meta.stringToEnum(Character, it.next() orelse usage(io)) orelse usage(io);
        } else if (std.mem.eql(u8, arg, "--seeds")) {
            seeds_text = value;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            o.limit = std.fmt.parseInt(u32, value, 10) catch usage(io);
        } else if (std.mem.eql(u8, arg, "--shots")) {
            o.shots = value;
        } else if (std.mem.eql(u8, arg, "--scenes")) {
            o.scenes = std.mem.eql(u8, value, "on");
        } else if (std.mem.eql(u8, arg, "--turns")) {
            o.turns = std.mem.eql(u8, value, "on");
        } else if (std.mem.eql(u8, arg, "--player1")) {
            o.player1 = std.meta.stringToEnum(@FieldType(Options, "player1"), value) orelse usage(io);
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

//! Play: a round, from its load to its end (DESIGN.md S1, W6; PLAN item 13). The scene runs the
//! round's world (world/) on play's clock and draws it: the round's planes scrolled by the
//! camera, the entities' sprites, the status bar on the fixed layer.
//!
//! Its parts, as the original's (measured against sor-remaster):
//! - the set-up: the game under way taken up (a new game: the lives of the options, three
//!   continues), the players dropping in and the first section's placed in the world; the flow's
//!   load follows, the screen dark;
//! - the banner: the first tick after the load shows the world as it was set up; then the status
//!   bar's first colours fade in, the banner slides in, the round's music, the banner stays,
//!   slides back out, and a wait;
//! - the round's first tick, then its colours fade in, a step a tick of the screen (the world
//!   waits);
//! - play: a logic tick of the world every other display tick (its timer, its script). START at
//!   a logic tick's start pauses, and at any tick of the pause resumes (each time the pause's
//!   sound; the pause's text while it lasts). The time running out is the time over: its sound
//!   and text for its ticks, then the round's music again, and each player in play loses its
//!   health;
//! - the end: the round won (its boss beaten), the screen fades out, and the round's clear
//!   follows.
//!
//! The semantic traces see two scenes: `round_intro` (the set-up to the banner's end) and
//! `round` (from the fade in), whose ticks are display ticks but in play, where a tick is a
//! logic tick (`trace_scene`, `trace_t`).
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const input = @import("../input.zig");
const art = @import("../content/art.zig");
const content_round = @import("../content/round.zig");
const records = @import("../content/screens.zig");
const world = @import("../world/root.zig");
const setup_mod = @import("../setup.zig");
const Colours = @import("colours.zig").Colours;
const Setup = setup_mod.Setup;

/// The palette cycles of a round's colours at most.
const max_cycles = 8;

pub const Phase = enum(u8) {
    setup,
    /// The first tick after the load: the world as it was set up.
    loaded,
    banner_fade,
    banner_in,
    banner_wait,
    banner_out,
    banner_after,
    /// The round's first tick.
    start,
    /// Its colours start fading in.
    fade_in,
    /// The fade in's steps: play from the tick after the last.
    intro,
    play,
    paused,
    time_over,
    leaving,
};

/// What the semantic traces call the scene.
pub const TraceScene = enum(u8) { round_intro, round };

/// A palette cycle's place: the ticks to its next step, and the step shown.
pub const Cycle = struct { countdown: u16 = 0, step: u16 = 0 };

/// What the status bar shows, by part: a part not shown is null.
pub const Bar = struct {
    names: [2]bool = .{ false, false },
    scores: [2]?u32 = .{ null, null },
    lives: [2]?u8 = .{ null, null },
    specials: [2]?u8 = .{ null, null },
    health: [2]?u8 = .{ null, null },
    time: u8 = 0,
    join: bool = false,
};

/// Player 2's invitation to join, while it does not play: the logic ticks to its next blink,
/// and whether it shows.
pub const Join = struct {
    ticks: u8 = 0,
    shown: bool = false,

    /// A logic tick: while player 2 is `out`, the text shows or hides every `every` ticks.
    pub fn blink(self: *Join, out: bool, every: u8) void {
        if (!out) {
            self.shown = false;
            return;
        }
        self.ticks -|= 1;
        if (self.ticks != 0) return;
        self.ticks = every;
        self.shown = !self.shown;
    }
};

pub const Round = struct {
    phase: Phase = .setup,
    /// The phase's ticks left (a wait, a slide).
    left: u16 = 0,
    /// The banner's parts' moves from their places, in pixels.
    banner: i16 = 0,
    play: world.Play = .{},
    colours: Colours = .{},
    cycles: [max_cycles]Cycle = @splat(.{}),
    /// START pressed since the last logic tick began (the pause's).
    start_pressed: bool = false,
    /// The logic tick ran at this display tick (the traces observe the world then).
    logic_ran: bool = false,
    /// The exit after the fade out.
    outcome: flow.Exit = .cleared,
    trace_scene: TraceScene = .round_intro,
    trace_t: u32 = 0,
    /// What the picture shows is the tick before's (the console takes its sprite table and the
    /// status bar's image as a frame starts, like its colours): the phase, the banner's place and
    /// the status bar then.
    shown_phase: Phase = .setup,
    shown_banner: i16 = 0,
    shown_bar: Bar = .{},
    join: Join = .{},

    pub const Assets = struct {
        kinds: *const world.Kinds,
        script: *const content_round.Round,
        screen: *const records.Round,
        plane_a: *const art.TileMap,
        plane_b: *const art.TileMap,
        round_set: *const art.ArtSet,
        round_colours: *const art.Palette,
        play_colours: *const art.Palette,
        players_colours: *const art.Palette,
        status_bar: *const art.TileMap,
        time_digits: *const art.TileMap,
        health_1: *const art.TileMap,
        health_2: *const art.TileMap,
        police_icon: *const art.TileMap,
        fills: *const art.TileSheet,
        text: library.Text,
        banner_left: *const art.Frame,
        banner_number: *const art.Frame,
        banner_right: *const art.Frame,
        pause_text: *const art.Frame,
        time_over_text: *const art.Frame,
        sounds: *const library.Sounds,
        music: library.Sound,
        stop: library.Sound,
        pause: library.Sound,
        time_up: library.Sound,
        pub const names = .{
            .kinds = "entities",
            .script = "rounds/round1",
            .screen = "screens/round",
            .plane_a = "round1/plane_a",
            .plane_b = "round1/plane_b",
            .round_set = "round1",
            .round_colours = "round1/colours",
            .play_colours = "play/colours",
            .players_colours = "play/players",
            .status_bar = "play/status_bar",
            .time_digits = "play/time_digits",
            .health_1 = "play/health_1",
            .health_2 = "play/health_2",
            .police_icon = "play/police_icon",
            .fills = "play/fills",
            .text = "fonts/main",
            .banner_left = "play/banner_left",
            .banner_number = "play/banner_number",
            .banner_right = "play/banner_right",
            .pause_text = "play/pause",
            .time_over_text = "play/time_over",
            .sounds = "sound",
            .music = "round 1 music",
            .stop = "stop",
            .pause = "pause",
            .time_up = "time up",
        };
    };

    pub const layout: view.Layout = .{
        .a = .{ .width = 672, .height = 32 },
        .b = .{ .width = 672, .height = 32 },
        .window = .{ .width = 40, .height = 4 },
    };

    /// The status bar's lines (the fixed layer's), above the sprites'.
    const bar_lines = 32;

    pub fn start(_: *const Setup) Round {
        return .{};
    }

    /// The plan of the round's script the world follows: the script, the options' level.
    fn plan(setup: *const Setup, a: *const Assets) world.script.Plan {
        return .{ .round = a.script, .level = @intCast(@min(setup.level, 3)) };
    }

    /// One display tick.
    pub fn tick(self: *Round, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.colours.latch();
        self.shown_phase = self.phase;
        self.shown_banner = self.banner;
        self.shown_bar = self.bar();
        if (turn.world_out) |o| o.latch();
        self.logic_ran = false;
        if (self.phase != .setup and self.phase != .play) self.trace_t += 1;
        const b = &a.screen.banner;
        switch (self.phase) {
            .setup => {
                turn.releasePads();
                self.setUp(turn, a);
                self.phase = .loaded;
            },
            .loaded => {
                self.colours.startFade(.target);
                self.colours.fade.?.colours = b.fade;
                self.phase = .banner_fade;
            },
            .banner_fade => if (self.colours.stepFade()) {
                self.phase = .banner_in;
                self.left = b.in_ticks;
            },
            .banner_in => {
                self.banner += b.in;
                self.left -|= 1;
                if (self.left != 0) return null;
                self.phase = .banner_wait;
                self.left = b.wait;
                turn.play(a.music);
            },
            .banner_wait => {
                self.left -|= 1;
                if (self.left != 0) return null;
                self.phase = .banner_out;
                self.left = b.out_ticks;
            },
            .banner_out => {
                self.banner -= b.out;
                self.left -|= 1;
                if (self.left != 0) return null;
                self.phase = .banner_after;
                self.left = b.after;
            },
            .banner_after => {
                self.left -|= 1;
                if (self.left == 0) self.phase = .start;
            },
            .start => {
                // The round's own scene, its tick 0.
                self.trace_scene = .round;
                self.trace_t = 0;
                self.phase = .fade_in;
            },
            .fade_in => {
                self.colours.startFade(.target);
                self.phase = .intro;
            },
            .intro => if (self.colours.stepFade()) {
                self.phase = .play;
                self.play.schedule = .{ .rate = .play };
            },
            .play => return self.playTick(turn, a),
            .paused => if (self.startPressed(turn)) {
                self.phase = .play;
                turn.play(a.pause);
                self.play.schedule = .{ .rate = .play };
                return self.playTick(turn, a);
            },
            .time_over => {
                if (self.left == a.screen.time_over.ticks) turn.play(a.time_up);
                self.left -|= 1;
                if (self.left == 0) self.timeOverEnds(turn, a);
            },
            .leaving => if (self.colours.stepFade()) {
                turn.play(a.stop);
                return self.outcome;
            },
        }
        return null;
    }

    /// START on the pad of a player in play.
    fn startPressed(self: *const Round, turn: *const scene.Turn) bool {
        const w = &self.play.world;
        if (w.players[0].entity != null and turn.pressed.pad1.start) return true;
        if (w.players[1].entity != null and turn.pressed.pad2.start) return true;
        return false;
    }

    /// A display tick of play: START is heard (a pause at the next logic tick's start), and at
    /// a logic tick's end the world's sounds go out, the colours cycle, and the time running out,
    /// the round won, end play.
    fn playTick(self: *Round, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        if (self.startPressed(turn)) self.start_pressed = true;
        if (self.play.schedule.into == 0 and self.start_pressed) {
            self.start_pressed = false;
            self.phase = .paused;
            self.trace_t += 1;
            turn.play(a.pause);
            return null;
        }
        var scratch: world.Output = undefined;
        const out = turn.world_out orelse blk: {
            scratch = .{};
            break :blk &scratch;
        };
        const p = plan(turn.setup, a);
        if (!self.play.roundTick(a.kinds, turn.random.?, turn.pads, out, &p)) return null;
        self.logic_ran = true;
        self.trace_t += 1;
        for (out.sounds.slice()) |s| if (a.sounds.find(s.name)) |id| turn.play(id);
        self.cycle(a);
        const w = &self.play.world;
        self.join.blink(w.players[1].entity == null, a.screen.status_bar.join.blink);
        if (w.timer.up) {
            turn.play(a.stop);
            self.phase = .time_over;
            self.left = a.screen.time_over.ticks;
        } else if (w.script.stage == .won) {
            self.leave(.cleared);
        }
        return null;
    }

    /// The time over's end: the round's music again, the timer's seconds, and each player in
    /// play's health lost (its behaviour then dies); play goes on.
    fn timeOverEnds(self: *Round, turn: *scene.Turn, a: *const Assets) void {
        const t = &a.screen.time_over;
        turn.play(a.music);
        const w = &self.play.world;
        w.timer.seconds = t.seconds;
        for (w.players) |pl| {
            const h = pl.entity orelse continue;
            const e = w.get(h) orelse continue;
            e.health -|= t.health;
            if (e.health < 0) e.health = 0;
            if (turn.world_out) |out| out.hits.append(.{ .attacker = null, .target = h, .damage = t.health });
        }
        self.phase = .play;
        self.play.schedule = .{ .rate = .play };
    }

    /// The round ends with `outcome` once the screen has faded out.
    fn leave(self: *Round, outcome: flow.Exit) void {
        self.outcome = outcome;
        self.phase = .leaving;
        self.colours.startFade(.black);
    }

    /// The round's set-up: the game under way (a new one at the first round), the world at the
    /// round's start: the camera, the players dropping in, the first section's placed; the
    /// colours to fade in.
    fn setUp(self: *Round, turn: *scene.Turn, a: *const Assets) void {
        const setup = turn.setup;
        const g = &setup.progress;
        if (g.round == 0) g.* = .new(setup);
        const w = &self.play.world;
        w.* = .{};
        w.ground = .pixels(a.script.ground);
        const p = plan(setup, a);
        world.script.start(w, &p);
        var scratch: world.Output = .{};
        const out = turn.world_out orelse &scratch;
        out.* = .{};
        var t: world.tick.Tick = .{ .world = w, .kinds = a.kinds, .random = turn.random.?, .out = out, .plan = &p };
        const r = a.script;
        for (&w.players, g.players, 0..) |*wp, gp, k| {
            wp.* = .{ .lives = gp.lives, .specials = gp.specials, .score = gp.score };
            if (!gp.in_play) continue;
            const character = setup.characters[k] orelse continue;
            const kind = a.kinds.find(@tagName(character)) orelse {
                std.log.warn("the content defines no {s} yet: player {d} sits out", .{ @tagName(character), k + 1 });
                continue;
            };
            const at: world.Vec3 = .{ .x = w.camera.x.add(.pixels(r.players.x)), .depth = .pixels(r.players.depth[k]), .height = .pixels(r.players.height) };
            const h = w.spawn(a.kinds, kind, at, .right) catch continue;
            wp.entity = h;
            wp.specials = 1;
            if (t.actor(world.behaviours.player, h)) |act| world.behaviours.player.startLife(act);
        }
        world.script.placeFirst(&t, &p);
        world.systems.picture(&t);
        self.join = .{ .ticks = a.screen.status_bar.join.blink };
        self.colours.palettes = .{};
        self.colours.aim(a.round_colours);
        self.colours.aim(a.play_colours);
        self.colours.aim(a.players_colours);
        const n = @min(a.round_set.cycles.len, max_cycles);
        for (a.round_set.cycles[0..n], self.cycles[0..n]) |c, *s| s.* = .{ .countdown = c.period };
    }

    /// The round's colour cycles, a step every period of logic ticks.
    fn cycle(self: *Round, a: *const Assets) void {
        const n = @min(a.round_set.cycles.len, max_cycles);
        for (a.round_set.cycles[0..n], self.cycles[0..n]) |c, *s| {
            s.countdown -|= 1;
            if (s.countdown != 0) continue;
            s.countdown = c.period;
            s.step += 1;
            if (s.step == c.steps.len) s.step = 0;
            for (c.steps[s.step], 0..) |line, i| for (line, 0..) |colour, k| {
                if (colour) |x| self.colours.palettes.shown[i][k] = x;
            };
            self.colours.copy = true;
        }
    }

    /// What the status bar shows.
    fn bar(self: *const Round) Bar {
        const w = &self.play.world;
        var out: Bar = .{ .time = w.timer.seconds, .join = self.join.shown };
        for (w.players, 0..) |p, k| {
            const e = w.getConst(p.entity orelse continue) orelse continue;
            out.names[k] = true;
            out.scores[k] = p.score;
            out.lives[k] = p.lives;
            out.specials[k] = p.specials;
            out.health[k] = @intCast(std.math.clamp(e.health, 0, 80));
        }
        return out;
    }

    pub fn draw(self: *const Round, prev: ?*const Round, v: *view.View, a: *const Assets) !void {
        const now = self.shown_bar;
        if (prev == null) {
            try v.board(.a).drawMap(a.plane_a, 0, 0);
            try v.board(.b).drawMap(a.plane_b, 0, 0);
            try v.board(.window).drawMapAtPlace(a.status_bar);
            try drawBar(v, a, now, null);
        } else try drawBar(v, a, now, prev.?.shown_bar);
        const c = self.play.world.camera;
        const r = a.script;
        v.screen.plane_a.x = c.x.whole();
        v.screen.plane_a.y = c.y.whole();
        v.screen.plane_b.x = @divFloor(c.x.whole() * r.camera.plane_b[0], r.camera.plane_b[1]);
        v.screen.plane_b.y = c.y.whole();
        v.screen.window.lines = .{ .top = 0, .bottom = bar_lines };
        v.screen.sprite_lines = .{ .top = bar_lines, .bottom = render.height };
        v.screen.colours = self.colours.shown;
        try v.sprites.appendSlice(v.gpa, v.world_out.shown_sprites.slice());
        switch (self.shown_phase) {
            .banner_in, .banner_wait, .banner_out => {
                try v.sprites.append(v.gpa, .of(a.banner_left, self.shown_banner, 0));
                try v.sprites.append(v.gpa, .of(a.banner_number, 0, self.shown_banner));
                try v.sprites.append(v.gpa, .of(a.banner_right, -self.shown_banner, 0));
            },
            .paused => try v.sprites.append(v.gpa, .of(a.pause_text, 0, 0)),
            .time_over => try v.sprites.append(v.gpa, .of(a.time_over_text, 0, 0)),
            else => {},
        }
    }
};

/// The status bar's parts that changed since `was` (all of them when null).
fn drawBar(v: *view.View, a: *const Round.Assets, now: Bar, was: ?Bar) !void {
    const board = v.board(.window);
    const sb = &a.screen.status_bar;
    for (sb.players, 0..) |p, k| {
        const before: Bar = was orelse .{ .time = now.time +% 1 };
        if (was == null or now.names[k] != before.names[k]) {
            if (now.names[k]) {
                try v.write(.window, a.text, p.name_at.x, p.name_at.y, p.name, .{});
                try board.write(a.text.sheet, a.text.font, p.lives_mark.x, p.lives_mark.y, "x", .{});
                try board.write(a.text.sheet, a.text.font, p.specials_mark.x, p.specials_mark.y, "x", .{});
                try board.drawMap(a.police_icon, p.icon.x, p.icon.y);
            }
        }
        if (now.scores[k]) |s| if (was == null or before.scores[k] != s) {
            var buf: [8]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d:0>6}", .{@min(s, 999_999)}) catch unreachable;
            try v.write(.window, a.text, p.score.x, p.score.y, text, .{});
        };
        if (now.lives[k]) |n| if (was == null or before.lives[k] != n) try bigDigit(board, a, p.lives, n);
        if (now.specials[k]) |n| if (was == null or before.specials[k] != n) try bigDigit(board, a, p.specials, n);
        if (now.health[k]) |h| if (was == null or before.health[k] != h) {
            try healthBar(board, a, if (k == 0) a.health_1 else a.health_2, p.health, h);
        };
    }
    if (was == null or was.?.time != now.time) {
        try bigDigit(board, a, a.screen.status_bar.time, now.time / 10);
        try bigDigit(board, a, .{ .x = a.screen.status_bar.time.x + 1, .y = a.screen.status_bar.time.y }, now.time % 10);
    }
    if ((was == null and now.join) or (was != null and was.?.join != now.join)) try drawJoin(v, a, now.join);
}

/// Player 2's invitation to join, or the status bar's cells under it; its words only (a space
/// leaves the bar's cell).
fn drawJoin(v: *view.View, a: *const Round.Assets, shown: bool) !void {
    const board = v.board(.window);
    const j = &a.screen.status_bar.join;
    const place = a.status_bar.place orelse art.Place{ .layer = .window, .x = 0, .y = 0 };
    var x: i32 = j.at.x;
    var words = std.mem.splitScalar(u8, j.text, ' ');
    while (words.next()) |word| : (x += 1) {
        if (shown) {
            try v.write(.window, a.text, x, j.at.y, word, .{});
            x += @intCast(word.len);
            continue;
        }
        for (0..word.len) |_| {
            board.erase(x, j.at.y, 1, 1);
            const mx = x - place.x;
            const my = @as(i32, j.at.y) - place.y;
            if (mx >= 0 and my >= 0 and mx < a.status_bar.width and my < a.status_bar.height)
                try putCell(board, a.status_bar, @intCast(mx), @intCast(my), @intCast(x), j.at.y);
            x += 1;
        }
    }
}

/// A digit two cells high (`play/time_digits`) at `at`; 10 or more shows 9.
fn bigDigit(board: *render.Board, a: *const Round.Assets, at: records.Cell, n: u8) !void {
    const d = @min(n, 9);
    try putCell(board, a.time_digits, d, 0, at.x, at.y);
    try putCell(board, a.time_digits, d, 1, at.x, at.y + 1);
}

/// A health bar of `health` points: its full cells, its partial cell of the eighths left
/// (`play/fills`), its empty cells, from the bar map's cells (`(10 - full)` on).
fn healthBar(board: *render.Board, a: *const Round.Assets, map: *const art.TileMap, at: records.Cell, health: u8) !void {
    const full = health / 8;
    const rest = health % 8;
    for (0..10) |i| {
        const m = 10 - full + i;
        if (m == 10) {
            const c = map.cell(m, 0);
            try board.put(at.x + @as(i32, @intCast(i)), at.y, &a.fills.tiles[rest], .{ .palette = c.palette, .priority = c.priority });
        } else try putCell(board, map, m, 0, at.x + @as(u8, @intCast(i)), at.y);
    }
}

/// Cell (mx, my) of `map` at (x, y) of the board.
fn putCell(board: *render.Board, map: *const art.TileMap, mx: usize, my: usize, x: u8, y: u8) !void {
    const c = map.cell(mx, my);
    if (c.isEmpty()) return;
    try board.put(x, y, &map.tiles[c.tile], .{ .palette = c.palette, .flip_x = c.flip_x, .flip_y = c.flip_y, .priority = c.priority });
}

test "player 2's invitation blinks every `blink` logic ticks while it does not play" {
    var j: Join = .{ .ticks = 8 };
    var shown: [24]bool = undefined;
    for (&shown) |*s| {
        j.blink(true, 8);
        s.* = j.shown;
    }
    for (shown, 0..) |s, k| try std.testing.expectEqual((k + 1) / 8 % 2 == 1, s);
    j.blink(false, 8);
    try std.testing.expect(!j.shown);
}

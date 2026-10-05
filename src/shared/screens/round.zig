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
//!   health. A player dies, and its next life drops in (world/lives.zig); out of lives, it asks
//!   the continue's question on its part of the status bar; out of the game, its part shows its
//!   name, its score and a blinking GAME OVER; the last one out counts the game over down, its
//!   text over the picture;
//! - the end: the round won (its boss beaten), the screen fades out, and the round's clear
//!   follows, the game under way kept; or the game over, the screen fades out, and the high
//!   scores follow.
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

const Answer = world.behaviours.player_waiting.Answer;

/// What the status bar shows of a player.
pub const PlayerBar = union(enum) {
    /// Not in the game: the bar's own cells.
    none,
    playing: Playing,
    /// Out of lives: the continue's question.
    asking: Asking,
    /// Out of the game.
    out: Out,

    pub const Playing = struct { score: u32, lives: u8, specials: u8, health: u8 };
    /// The continues left, the second answer (NEW GAME, or GAME OVER), the cursor (null: hidden
    /// by its blink).
    pub const Asking = struct { continues: u8, new_game: bool, cursor: ?Answer };
    /// Its name and score (not at the tick its part is cleared), and the game over's text,
    /// which blinks.
    pub const Out = struct { name: bool, score: u32, game_over: bool };
};

/// What the status bar shows.
pub const Bar = struct {
    players: [2]PlayerBar = .{ .none, .none },
    time: u8 = 0,
    join: bool = false,
};

/// A player out of the game: its game over's text on the status bar blinks. The logic ticks to
/// the next blink, its phase, and whether the text shows.
pub const OutBlink = struct {
    /// It counts from the tick after the player went out.
    counting: bool = false,
    ticks: u8 = first_out_blink,
    phase: bool = false,
    shown: bool = false,

    /// The ticks to the first blink (the original's count, left as the round starts).
    const first_out_blink = 8;

    /// A logic tick of a player out of the game (`out`), the text shown first (`shown_first`:
    /// none after a NO); every `every` ticks the text, then its blanks, in turn.
    pub fn blink(self: *OutBlink, out: bool, shown_first: bool, every: u8) void {
        if (!out) {
            self.* = .{};
            return;
        }
        if (!self.counting) {
            self.counting = true;
            self.shown = shown_first;
            return;
        }
        self.ticks -%= 1;
        if (self.ticks != 0) return;
        self.ticks = every;
        self.shown = !self.phase;
        self.phase = !self.phase;
    }
};

/// Player 2's invitation to join, while it does not play: the logic ticks to its next blink,
/// the blink's phase, and whether the bar shows it.
pub const Join = struct {
    ticks: u8 = 0,
    phase: bool = false,
    shown: bool = false,

    /// A logic tick: while player 2 is `out`, the text shows or hides every `every` ticks; while
    /// player 1 waits to continue (`held`), the bar's cells there are cleared and the blink
    /// holds.
    pub fn blink(self: *Join, out: bool, held: bool, every: u8) void {
        if (!out or held) {
            self.shown = false;
            return;
        }
        self.ticks -|= 1;
        if (self.ticks != 0) return;
        self.ticks = every;
        self.phase = !self.phase;
        self.shown = self.phase;
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
    shown_game_over: bool = false,
    /// The pause's text shows: in the pause, and a display tick after it ended (`resumed`).
    shown_pause: bool = false,
    resumed: bool = false,
    join: Join = .{},
    out_blinks: [2]OutBlink = .{ .{}, .{} },
    /// The last player out of the game is at its game over: the round ends at the next tick.
    over: bool = false,

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
        game_over_text: *const art.Frame,
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
            .game_over_text = "play/game_over",
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

    /// The plan of the round's script the world follows: the script, the options' level, the
    /// lives a continue gives (the options').
    fn plan(setup: *const Setup, a: *const Assets) world.script.Plan {
        return .{ .round = a.script, .level = @intCast(@min(setup.level, 3)), .lives = setup_mod.Progress.livesOf(setup) };
    }

    /// One display tick.
    pub fn tick(self: *Round, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.colours.latch();
        self.shown_phase = self.phase;
        self.shown_pause = self.phase == .paused or self.resumed;
        self.resumed = false;
        self.shown_banner = self.banner;
        self.shown_bar = self.bar();
        self.shown_game_over = self.gameOver() != null;
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
            .play => return self.playTick(turn, a, true),
            // START in the pause ends it (its text shows a display tick longer).
            .paused => if (self.startPressed(turn)) {
                self.phase = .play;
                self.resumed = true;
                turn.play(a.pause);
                self.play.schedule = .{ .rate = .play };
                return self.playTick(turn, a, false);
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

    /// START on the pad of a player in play (not waiting to continue).
    fn startPressed(self: *const Round, turn: *const scene.Turn) bool {
        const w = &self.play.world;
        if (self.fighting(0) and turn.pressed.pad1.start) return true;
        if (self.fighting(1) and turn.pressed.pad2.start) return true;
        _ = w;
        return false;
    }

    /// Whether player `k` plays as a fighter.
    fn fighting(self: *const Round, k: usize) bool {
        const w = &self.play.world;
        const e = w.getConst(w.players[k].entity orelse return false) orelse return false;
        return e.mind == .player;
    }

    /// Whether the player (out of the game) answered NO to the continue.
    fn answeredNo(self: *const Round, p: world.Player) bool {
        const e = self.play.world.getConst(p.entity orelse return false) orelse return false;
        return switch (e.mind) {
            .player_waiting => |m| m.answered_no,
            else => false,
        };
    }

    /// Whether player `k` waits to continue (out of lives).
    fn waiting(self: *const Round, k: usize) bool {
        const w = &self.play.world;
        const e = w.getConst(w.players[k].entity orelse return false) orelse return false;
        return e.mind == .player_waiting;
    }

    /// The last player out of the game, counting the game over down: its state (null: the
    /// game is not over).
    fn gameOver(self: *const Round) ?world.behaviours.player_waiting.State {
        const w = &self.play.world;
        for (w.players) |p| {
            const e = w.getConst(p.entity orelse continue) orelse continue;
            switch (e.mind) {
                // The game over's text shows from the count's first tick.
                .player_waiting => |m| if (m.state == .game_over or (m.state == .countdown and m.music)) return m.state,
                else => {},
            }
        }
        return null;
    }

    /// A display tick of play: START is heard (`hear_start`: not at the tick a pause ends; a pause
    /// at the next logic tick's start), and at a logic tick's end the world's sounds go out, the
    /// colours cycle, and the time running out, the round won, the game over end play.
    fn playTick(self: *Round, turn: *scene.Turn, a: *const Assets, hear_start: bool) ?flow.Exit {
        if (hear_start and self.startPressed(turn)) self.start_pressed = true;
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
        self.join.blink(w.players[1].entity == null, self.waiting(0), a.screen.status_bar.join.blink);
        for (&self.out_blinks, w.players) |*b, pl| b.blink(pl.out, !self.answeredNo(pl), a.screen.status_bar.join.blink);
        if (w.timer.up) {
            turn.play(a.stop);
            self.phase = .time_over;
            self.left = a.screen.time_over.ticks;
        } else if (w.script.stage == .won) {
            self.leave(turn, .cleared);
        } else if (self.over) {
            self.leave(turn, .game_over);
        } else if (self.gameOver() == .game_over) {
            // The game ends at the next tick (the original's leaving starts then).
            self.over = true;
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
        for (w.players, 0..) |pl, k| {
            if (!self.fighting(k)) continue;
            const h = pl.entity orelse continue;
            const e = w.get(h) orelse continue;
            e.health -|= t.health;
            if (e.health < 0) e.health = 0;
            if (turn.world_out) |out| out.hits.append(.{ .attacker = null, .target = h, .damage = t.health });
        }
        self.phase = .play;
        self.play.schedule = .{ .rate = .play };
    }

    /// The round ends with `outcome` once the screen has faded out; the game under way keeps
    /// the players' parts for the next round, or ends.
    fn leave(self: *Round, turn: *scene.Turn, outcome: flow.Exit) void {
        self.outcome = outcome;
        self.phase = .leaving;
        self.colours.startFade(.black);
        const g = &turn.setup.progress;
        if (outcome == .game_over) {
            g.* = .{};
            return;
        }
        const w = &self.play.world;
        g.timer = w.timer.seconds;
        for (&g.players, w.players) |*gp, wp| gp.* = .{
            .in_play = wp.entity != null,
            .score = wp.score,
            .lives = wp.lives,
            .specials = wp.specials,
            .continues = wp.continues,
            .health = if (wp.entity) |h| if (w.getConst(h)) |e| @intCast(std.math.clamp(e.health, 0, 80)) else 0 else 0,
        };
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
            wp.* = .{ .lives = gp.lives, .specials = gp.specials, .score = gp.score, .continues = gp.continues };
            if (!gp.in_play) continue;
            const character = setup.characters[k] orelse continue;
            const kind = a.kinds.find(@tagName(character)) orelse {
                std.log.warn("the content defines no {s} yet: player {d} sits out", .{ @tagName(character), k + 1 });
                continue;
            };
            const at: world.Vec3 = .{ .x = w.camera.x.add(.pixels(r.players.x)), .depth = .pixels(r.players.depth[k]), .height = .pixels(r.players.height) };
            const h = w.spawn(a.kinds, kind, at, .right) catch continue;
            wp.entity = h;
            wp.character = kind;
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
        var out: Bar = .{ .time = w.timer.shown, .join = self.join.shown };
        for (w.players, &out.players, self.out_blinks, 0..) |p, *o, ob, k| {
            const playing: PlayerBar = .{ .playing = .{ .score = p.score, .lives = p.lives, .specials = p.specials, .health = 0 } };
            const gone: PlayerBar = .{ .out = .{ .name = true, .score = p.score, .game_over = ob.shown } };
            const h = p.entity orelse {
                if (p.out) o.* = gone;
                continue;
            };
            const e = w.getConst(h) orelse continue;
            const new_game = k == 0 and w.players[1].entity == null and !w.players[1].out;
            o.* = switch (e.mind) {
                .player => .{ .playing = .{ .score = p.score, .lives = p.lives, .specials = p.specials, .health = @intCast(std.math.clamp(e.health, 0, 80)) } },
                .player_waiting => |m| switch (m.state) {
                    // Its first tick: the bar as it was (the question still, after a NO).
                    .begin => if (m.answered_no) .{ .asking = .{ .continues = m.count, .new_game = new_game, .cursor = if (m.shown) m.cursor else null } } else playing,
                    .continue_choose, .continue_chosen => .{ .asking = .{ .continues = m.count, .new_game = new_game, .cursor = if (m.shown) m.cursor else null } },
                    // The tick it went out its part is cleared: its name comes at the next.
                    .countdown, .game_over => .{ .out = .{ .name = m.state != .countdown or m.music, .score = p.score, .game_over = ob.shown } },
                },
                else => .none,
            };
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
            .time_over => try v.sprites.append(v.gpa, .of(a.time_over_text, 0, 0)),
            else => {},
        }
        if (self.shown_pause) try v.sprites.append(v.gpa, .of(a.pause_text, 0, 0));
        if (self.shown_game_over) try v.sprites.append(v.gpa, .of(a.game_over_text, 0, 0));
    }
};

/// The status bar's parts that changed since `was` (all of them when null). A player's part
/// that changes its kind (playing, asking, out) is cleared, then drawn whole.
pub fn drawBar(v: *view.View, a: anytype, now: Bar, was: ?Bar) !void {
    const board = v.board(.window);
    for (now.players, 0..) |p, k| {
        const before: ?PlayerBar = if (was) |w| w.players[k] else null;
        if (before) |b| {
            if (std.meta.eql(b, p)) continue;
            if (std.meta.activeTag(b) != std.meta.activeTag(p)) {
                try clearPlayer(v, a, k);
                try drawPlayer(v, a, k, p, null);
                continue;
            }
        }
        try drawPlayer(v, a, k, p, before);
    }
    if (was == null or was.?.time != now.time) {
        try bigDigit(board, a, a.screen.status_bar.time, now.time / 10);
        try bigDigit(board, a, .{ .x = a.screen.status_bar.time.x + 1, .y = a.screen.status_bar.time.y }, now.time % 10);
    }
    if ((was == null and now.join) or (was != null and was.?.join != now.join)) try drawJoin(v, a, now.join);
}

/// Player `k`'s part of the bar, the parts that changed since `was` (all when null).
pub fn drawPlayer(v: *view.View, a: anytype, k: usize, now: PlayerBar, was: ?PlayerBar) !void {
    const board = v.board(.window);
    const p = &a.screen.status_bar.players[k];
    const cq = &a.screen.continue_question;
    const places = &cq.players[k];
    switch (now) {
        .none => {},
        .playing => |x| {
            const before: ?PlayerBar.Playing = if (was) |w| w.playing else null;
            if (before == null) {
                try v.write(.window, a.text, p.name_at.x, p.name_at.y, p.name, .{});
                try board.write(a.text.sheet, a.text.font, p.lives_mark.x, p.lives_mark.y, "x", .{});
                try board.write(a.text.sheet, a.text.font, p.specials_mark.x, p.specials_mark.y, "x", .{});
                try board.drawMap(a.police_icon, p.icon.x, p.icon.y);
            }
            if (before == null or before.?.score != x.score) try drawScore(v, a, p.score, x.score);
            if (before == null or before.?.lives != x.lives) try bigDigit(board, a, p.lives, x.lives);
            if (before == null or before.?.specials != x.specials) try bigDigit(board, a, p.specials, x.specials);
            if (before == null or before.?.health != x.health) try healthBar(board, a, if (k == 0) a.health_1 else a.health_2, p.health, x.health);
        },
        .asking => |x| {
            const before: ?PlayerBar.Asking = if (was) |w| w.asking else null;
            if (before == null) try writeWords(v, a, places.question, cq.question);
            if (before == null or before.?.continues != x.continues) {
                var buf: [4]u8 = undefined;
                const digit = std.fmt.bufPrint(&buf, "{d}", .{@min(x.continues, 9)}) catch unreachable;
                try v.write(.window, a.text, places.question.x + cq.count, places.question.y, digit, .{});
            }
            if (before == null or before.?.new_game != x.new_game) {
                restore(board, a, places.answer, @intCast(@max(cq.new_game.len, cq.game_over.len)));
                try writeWords(v, a, places.answer, if (x.new_game) cq.new_game else cq.game_over);
            }
            if (before == null or before.?.cursor != x.cursor) {
                restore(board, a, places.yes, 1);
                restore(board, a, places.no, 1);
                if (x.cursor) |c| {
                    const at = if (c == .yes) places.yes else places.no;
                    try v.write(.window, a.text, at.x, at.y, cq.cursor, .{});
                }
            }
        },
        .out => |x| {
            const before: ?PlayerBar.Out = if (was) |w| w.out else null;
            const named = if (before) |b| b.name else false;
            if (x.name and !named) try v.write(.window, a.text, p.name_at.x, p.name_at.y, p.name, .{});
            if (x.name and (!named or before.?.score != x.score)) try drawScore(v, a, p.score, x.score);
            if (before == null or before.?.game_over != x.game_over) {
                restore(board, a, places.out, @intCast(cq.game_over.len));
                if (x.game_over) try writeWords(v, a, places.out, cq.game_over);
            }
        },
    }
}

/// A score's six digits at `at`.
pub fn drawScore(v: *view.View, a: anytype, at: records.Cell, score: u32) !void {
    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:0>6}", .{@min(score, 999_999)}) catch unreachable;
    try v.write(.window, a.text, at.x, at.y, text, .{});
}

/// Player `k`'s cells of the bar, back to the bar's own: on each row, the original's count
/// from its first.
pub fn clearPlayer(v: *view.View, a: anytype, k: usize) !void {
    const cq = &a.screen.continue_question;
    for (cq.players[k].cleared) |at| restore(v.board(.window), a, at, cq.cleared);
}

/// `n` cells from `at`, back to the status bar's own.
pub fn restore(board: *render.Board, a: anytype, at: records.Cell, n: u8) void {
    const place = a.status_bar.place orelse art.Place{ .layer = .window, .x = 0, .y = 0 };
    for (0..n) |i| {
        const x = @as(i32, at.x) + @as(i32, @intCast(i));
        board.erase(x, at.y, 1, 1);
        const mx = x - place.x;
        const my = @as(i32, at.y) - place.y;
        if (mx >= 0 and my >= 0 and mx < a.status_bar.width and my < a.status_bar.height)
            putCell(board, a.status_bar, @intCast(mx), @intCast(my), @intCast(x), at.y) catch {};
    }
}

/// A text's words from `at`: a space leaves the bar's cell.
pub fn writeWords(v: *view.View, a: anytype, at: records.Cell, text: []const u8) !void {
    var x: i32 = at.x;
    var words = std.mem.splitScalar(u8, text, ' ');
    while (words.next()) |word| : (x += @intCast(word.len + 1)) try v.write(.window, a.text, x, at.y, word, .{});
}

/// Player 2's invitation to join, or the status bar's cells under it.
pub fn drawJoin(v: *view.View, a: anytype, shown: bool) !void {
    const j = &a.screen.status_bar.join;
    if (shown) return writeWords(v, a, j.at, j.text);
    restore(v.board(.window), a, j.at, @intCast(j.text.len));
}

/// A digit two cells high (`play/time_digits`) at `at`; 10 or more shows 9.
pub fn bigDigit(board: *render.Board, a: anytype, at: records.Cell, n: u8) !void {
    const d = @min(n, 9);
    try putCell(board, a.time_digits, d, 0, at.x, at.y);
    try putCell(board, a.time_digits, d, 1, at.x, at.y + 1);
}

/// A health bar of `health` points: its full cells, its partial cell of the eighths left
/// (`play/fills`), its empty cells, from the bar map's cells (`(10 - full)` on).
pub fn healthBar(board: *render.Board, a: anytype, map: *const art.TileMap, at: records.Cell, health: u8) !void {
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
pub fn putCell(board: *render.Board, map: *const art.TileMap, mx: usize, my: usize, x: u8, y: u8) !void {
    const c = map.cell(mx, my);
    if (c.isEmpty()) return;
    try board.put(x, y, &map.tiles[c.tile], .{ .palette = c.palette, .flip_x = c.flip_x, .flip_y = c.flip_y, .priority = c.priority });
}

test "player 2's invitation blinks every `blink` logic ticks while it does not play" {
    var j: Join = .{ .ticks = 8 };
    var shown: [24]bool = undefined;
    for (&shown) |*s| {
        j.blink(true, false, 8);
        s.* = j.shown;
    }
    for (shown, 0..) |s, k| try std.testing.expectEqual((k + 1) / 8 % 2 == 1, s);
    // Player 1 waiting to continue: hidden, the blink held; then on from where it was.
    j.blink(true, true, 8);
    try std.testing.expect(!j.shown and j.ticks == 8);
    for (0..8) |_| j.blink(true, false, 8);
    try std.testing.expect(!j.shown and j.phase == false);
    j.blink(false, false, 8);
    try std.testing.expect(!j.shown);
}

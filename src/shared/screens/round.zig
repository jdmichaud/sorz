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
//!   sound; the pause's text while it lasts); where the variant says so, it opens the settings in
//!   place of the pause instead (`startOpensSettings`). The time running out is the time over: its sound
//!   and text for its ticks, then the round's music again, and each player in play loses its
//!   health. Player 2's invitation blinks while it does not play, and at a blink's tick with its
//!   START held it joins (`joinTick`, `dropIn`): the character after player 1's, and its first
//!   life drops in. A player dies, and its next life drops in (world/lives.zig); out of lives, it
//!   enters its name on its part of the status bar when its score enters the high-score table (the
//!   table takes its entry), then asks the continue's question there; out of the game, its part
//!   shows its name, its score and a blinking GAME OVER; the last one out counts the game over
//!   down, its text over the picture;
//! - the end: the round won (its boss beaten), the screen fades out, and the round's clear
//!   follows, the game under way kept; or the game over, the screen fades out, and the high
//!   scores follow.
//!
//! The round it plays is the game under way's; its script, planes, colours and music are the ones
//! its record in the content names (`library.Rounds`), so that every round is data.
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
const records = @import("../content/screens.zig");
const content_round = @import("../content/round.zig");
const world = @import("../world/root.zig");
const setup_mod = @import("../setup.zig");
const Colours = @import("colours.zig").Colours;
const transfers = @import("transfers.zig");
const HighScores = @import("high_scores.zig").HighScores;
const Setup = setup_mod.Setup;
const Score = setup_mod.Score;

/// The cells across of a plane as the original's video memory holds it: an animation's map is
/// written on all of them.
const plane_cells = 64;

/// The palette cycles of a round's colours at most.
const max_cycles = library.Rounds.most_cycles;

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
    /// Out of lives, its score in the high-score table: its name entered.
    naming: Naming,
    /// Out of lives: the continue's question.
    asking: Asking,
    /// Out of the game.
    out: Out,

    pub const Playing = struct { score: u32, lives: u8, specials: u8, health: u8 };
    /// Its score, and the letter each place of the name shows (a number of the name entry's
    /// letters; null: none).
    pub const Naming = struct { score: u32, places: [world.behaviours.player_waiting.places]?u8 };
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
    /// The bosses' bars, from the tick after a boss's first in its section.
    bosses: ?BossesBar = null,
};

/// The bosses' bars as the status bar shows them: whether a second shows (twins'), and the
/// pixels each shows (none for a boss gone).
pub const BossesBar = struct {
    second: bool,
    pixels: [2]u16,
};

/// A player out of the game: its game over's text on the status bar blinks. The logic ticks to
/// the next blink, its phase, and whether the text shows.
pub const OutBlink = struct {
    /// It counts from the tick after the player went out.
    counting: bool = false,
    ticks: u8 = 0,
    phase: bool = false,
    shown: bool = false,

    /// A logic tick of a player out of the game (`out`), the text shown first (`shown_first`:
    /// none after a NO); every `every` ticks the text, then its blanks, in turn. The first blink
    /// comes `every` ticks after it went out (the original's count, as the round starts it).
    pub fn blink(self: *OutBlink, out: bool, shown_first: bool, every: u8) void {
        if (!out) {
            self.* = .{ .ticks = every };
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
    /// player 1 waits to continue (`held`), the bar's cells there are cleared and the blink holds.
    pub fn blink(self: *Join, out: bool, held: bool, every: u8) void {
        if (self.due(out, held, every)) self.turn();
    }

    /// The count of a logic tick (see `blink`): true at a blink's tick, the moment player 2 may
    /// join; the caller then turns the blink (`turn`), or player 2 joins and the text goes.
    pub fn due(self: *Join, out: bool, held: bool, every: u8) bool {
        if (!out or held) {
            self.shown = false;
            return false;
        }
        self.ticks -|= 1;
        if (self.ticks != 0) return false;
        self.ticks = every;
        return true;
    }

    pub fn turn(self: *Join) void {
        self.phase = !self.phase;
        self.shown = self.phase;
    }
};

pub const Round = struct {
    phase: Phase = .setup,
    /// The round played (the game under way's at the set-up), and its planes' sizes in cells.
    number: u8 = 0,
    planes: [2]?view.Size = .{ null, null },
    /// The phase's ticks left (a wait, a slide).
    left: u16 = 0,
    /// The banner's parts' moves from their places, in pixels.
    banner: i16 = 0,
    play: world.Play = .{},
    colours: Colours = .{},
    cycles: [max_cycles]Cycle = @splat(.{}),
    /// START pressed since the last logic tick began (the pause's), and by which player first.
    start_pressed: ?u1 = null,
    /// The logic tick ran at this display tick (the traces observe the world then).
    logic_ran: bool = false,
    /// The display tick was the first of a logic tick's two (no picture ends there).
    split: bool = false,
    /// What the next picture's frame carries (screens/transfers.zig): each player's art for its
    /// new frame (its copies' tiles), its health bar's partial cell built (`health` the health
    /// it shows, null before its first), the planes' columns the camera brought in.
    art_due: [2][2]u16 = @splat(.{ 0, 0 }),
    /// Each player's state as the original numbers it, at the last tick (`poseOf`).
    pose: [2]?u16 = .{ null, null },
    colours_due: bool = false,
    bar_due: [2]bool = .{ false, false },
    health: [2]?i16 = .{ null, null },
    strips_due: u8 = 0,
    strip_blocks_due: u16 = 0,
    strip_rows_due: u8 = 0,
    /// The round's animation's step the picture shows (null: none since the round's start, the
    /// planes' own), and the rows of its map due at the next picture.
    animation_shown: ?u8 = null,
    animation_rows_due: u8 = 0,
    /// The step the picture shows: the one before the tick (`animation_shown` as it began).
    shown_animation: ?u8 = null,
    /// The art play streams in (a section's, the boss's, an arriving enemy's, the special
    /// attack's): its list, and the display tick of it that comes next.
    art: world.script.ArtQueue = .{},
    /// The players' scores as the status bar draws them (those the last logic tick began with).
    drawn_scores: [2]u32 = .{ 0, 0 },
    /// The colours shown as the special attack was called, which it gives back.
    kept: render.palettes.Colours = render.palettes.black,
    /// The round ended (its last tick).
    done: bool = false,
    /// The exit after the fade out.
    outcome: flow.Exit = .cleared,
    trace_scene: TraceScene = .round_intro,
    trace_t: u32 = 0,
    /// What the picture shows is the tick before's (the console takes its sprite table, the
    /// status bar's image and the planes' scroll as a frame starts, like its colours): the phase,
    /// the banner's place, the status bar and the camera's place then (across, down, and down
    /// without its shake, which plane B does not take: the original shakes plane A alone).
    shown_phase: Phase = .setup,
    shown_camera: [3]i32 = .{ 0, 0, 0 },
    shown_banner: i16 = 0,
    shown_bar: Bar = .{},
    shown_game_over: bool = false,
    /// The pause's text shows: in the pause, and a display tick after it ended (`resumed`).
    shown_pause: bool = false,
    resumed: bool = false,
    join: Join = .{},
    /// Player 2 joins at the next logic tick as this character (network play's: `dropIn`).
    join_as: ?setup_mod.Character = null,
    /// The character of the join under way.
    joining: ?setup_mod.Character = null,
    out_blinks: [2]OutBlink = .{ .{}, .{} },
    /// The last player out of the game is at its game over: the round ends at the next tick.
    over: bool = false,
    /// The attract demo (`startDemo`): the round played on the content's pads (`records.Demo`),
    /// their next reading, and its play's ticks left.
    demo: bool = false,
    demo_reading: u16 = 0,
    demo_left: u16 = 0,
    /// The pads the tick read: the hosts' (the demo's: its readings, the real START).
    pads_read: input.Pads = .{},
    /// The special attacks the status bar shows of each player, and the world's when it last
    /// drew them: it draws them as they change (the demo's own are not drawn until then).
    bar_specials: [2]u8 = .{ 0, 0 },
    seen_specials: [2]u8 = .{ 0, 0 },

    pub const Assets = struct {
        kinds: *const world.Kinds,
        rounds: library.Rounds,
        screen: *const records.Round,
        play_colours: *const art.Palette,
        players_colours: *const art.Palette,
        status_bar: *const art.TileMap,
        time_digits: *const art.TileMap,
        health_1: *const art.TileMap,
        health_2: *const art.TileMap,
        bosses_bars: *const art.TileMap,
        boss_bar_1: *const art.TileMap,
        boss_bar_2: *const art.TileMap,
        bosses_label: *const art.TileMap,
        boss_bar_over: *const art.TileMap,
        police_icon: *const art.TileMap,
        fills: *const art.TileSheet,
        text: library.Text,
        banner_left: *const art.Frame,
        banner_right: *const art.Frame,
        pause_text: *const art.Frame,
        time_over_text: *const art.Frame,
        game_over_text: *const art.Frame,
        first_scores: *const records.HighScores,
        enemy_colours: library.EnemyColours,
        sounds: *const library.Sounds,
        stop: library.Sound,
        pause: library.Sound,
        time_up: library.Sound,
        pub const names = .{
            .kinds = "entities",
            .rounds = "rounds",
            .screen = "screens/round",
            .play_colours = "play/colours",
            .players_colours = "play/players",
            .status_bar = "play/status_bar",
            .time_digits = "play/time_digits",
            .health_1 = "play/health_1",
            .health_2 = "play/health_2",
            .bosses_bars = "play/enemy_bar",
            .boss_bar_1 = "play/enemy_bar_1",
            .boss_bar_2 = "play/enemy_bar_2",
            .bosses_label = "play/enemy_bar_label",
            .boss_bar_over = "play/enemy_bar_over",
            .police_icon = "play/police_icon",
            .fills = "play/fills",
            .text = "fonts/main",
            .banner_left = "play/banner_left",
            .banner_right = "play/banner_right",
            .pause_text = "play/pause",
            .time_over_text = "play/time_over",
            .game_over_text = "play/game_over",
            .first_scores = "screens/high_scores",
            .enemy_colours = "enemy_colours",
            .sounds = "sound",
            .stop = "stop",
            .pause = "pause",
            .time_up = "time up",
        };
    };

    /// The boards: the round's planes' (none before its set-up), the status bar's (with the
    /// bosses' bars' row).
    pub fn layoutOf(self: *const Round) view.Layout {
        return .{ .a = self.planes[0], .b = self.planes[1], .window = .{ .width = 40, .height = 5 } };
    }

    /// The round played's content. The flow plays only a round the content has (round 1, then
    /// the next round's stand-in after its clear, until PLAN item 15).
    fn stage(self: *const Round, a: *const Assets) *const library.RoundAssets {
        return a.rounds.of(self.number).?;
    }

    /// The status bar's lines (the fixed layer's, its map's), above the sprites'.
    fn barLines(a: *const Assets) u16 {
        const top: u16 = if (a.status_bar.place) |p| @intCast(@max(p.y, 0)) else 0;
        return (top + a.status_bar.height) * art.tile_side;
    }

    /// The rows the bosses' bars' rectangle adds below the status bar's.
    fn bossesRows(a: *const Assets) u16 {
        const top: u16 = if (a.bosses_bars.place) |p| @intCast(@max(p.y, 0)) else 0;
        return (top + a.bosses_bars.height) -| (barLines(a) / art.tile_side);
    }

    pub fn start(_: *const Setup) Round {
        return .{};
    }

    /// The attract demo: round 1 played on the pads the content holds, its own players; its
    /// load leads straight to the round's fade in (no banner), its trace's scene the round's.
    pub fn startDemo(_: *const Setup) Round {
        return .{ .demo = true, .trace_scene = .round };
    }

    /// The plan of the round's script the world follows: the script, the options' level, the
    /// lives a continue gives (the options'), the high-score table's last entry.
    fn plan(self: *const Round, setup: *const Setup, a: *const Assets) world.script.Plan {
        const table = scoreTable(setup, a);
        const last = table[table.len - 1];
        return .{
            .round = self.stage(a).script,
            .level = @intCast(@min(setup.level, 3)),
            .lives = setup_mod.Progress.livesOf(setup),
            // The demo's pads are read as they are (the cartridge's first layout).
            .buttons = a.screen.buttons.of(if (self.demo) 0 else setup.control),
            .last_score = .{ .score = last.score, .level = last.level, .round = last.round },
            .art_loading = self.art.loading(self.stage(a).script),
            .colour_lines = a.enemy_colours.lines,
            .own_colours = ownColours(&a.enemy_colours),
        };
    }

    /// The high-score table as the game keeps it: the content's first one until a game changes
    /// it.
    fn scoreTable(setup: *const Setup, a: *const Assets) [setup_mod.high_scores]Score {
        return setup.high_scores orelse HighScores.firstTable(a.first_scores);
    }

    /// The tick's rankings in the high-score table: a player ranked loses its marks there; a name
    /// entered makes its entry in the last one's place (the player's score, the round, the
    /// options' level, the name; marked as its player's new entry), and the table is sorted again.
    fn rank(self: *const Round, setup: *Setup, a: *const Assets, rankings: []const world.output.Ranking) void {
        if (rankings.len == 0) return;
        var table = scoreTable(setup, a);
        const was = table;
        for (rankings) |r| {
            const entry: ?Score = if (r.name) |name| .{
                .score = self.play.world.players[r.player].score,
                .round = self.number,
                .name = nameOf(a.screen.name_entry.letters, name),
                .level = setup.level,
            } else null;
            rankIn(&table, r.player, entry);
        }
        if (setup.high_scores != null or !std.meta.eql(table, was)) setup.high_scores = table;
    }

    /// One display tick.
    pub fn tick(self: *Round, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        const was = self.phase;
        defer turn.frame = self.pictureOf(a, was);
        defer turn.streamed = self.nextStreamed(a);
        self.colours.latch();
        self.shown_phase = self.phase;
        self.shown_pause = self.phase == .paused or self.resumed;
        self.resumed = false;
        self.shown_banner = self.banner;
        const cam = &self.play.world.camera;
        // The shake's move down, at an odd tick of it left (world/systems.zig).
        const shaken: i32 = if (cam.shake & 1 != 0) if (cam.follows) |rules| rules.shake_by else 0 else 0;
        self.shown_camera = .{ cam.x.whole(), cam.y.whole(), cam.y.whole() - shaken };
        self.shown_bar = self.bar(a);
        self.shown_game_over = self.gameOver() != null;
        self.shown_animation = self.animation_shown;
        if (turn.world_out) |o| o.latch();
        self.logic_ran = false;
        self.split = false;
        if (self.demo) {
            self.readDemo(turn, a);
            turn.demo_pads = true;
        }
        self.pads_read = turn.pads;
        // A tick of the pause is counted as it goes on: the one it ends at is play's.
        if (self.phase != .setup and self.phase != .play and self.phase != .paused) self.waited();
        const b = &a.screen.banner;
        switch (self.phase) {
            .setup => {
                turn.releasePads();
                self.setUp(turn, a);
                // The demo's load leads to the round's fade in, its music then.
                self.phase = if (self.demo) .fade_in else .loaded;
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
                turn.play(self.stage(a).music);
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
                // The demo has no banner: its music with the fade in.
                if (self.demo) turn.play(self.stage(a).music);
            },
            .intro => if (self.colours.stepFade()) {
                self.phase = .play;
                self.play.schedule = .{ .rate = .play };
                // The first section's art, queued with the round's load, streams in from play's
                // first tick, the list from the tick before.
                self.art.start(.{ .part = 0 });
            },
            .play => return self.playTick(turn, a, true),
            // START in the pause ends it (its text shows a display tick longer).
            .paused => if (self.startPressed(turn) != null) {
                self.phase = .play;
                self.resumed = true;
                turn.play(a.pause);
                self.play.schedule = .{ .rate = .play };
                return self.playTick(turn, a, false);
            } else self.waited(),
            .time_over => {
                if (self.left == a.screen.time_over.ticks) turn.play(a.time_up);
                self.left -|= 1;
                if (self.left == 0) self.timeOverEnds(turn, a);
            },
            .leaving => if (self.colours.stepFade()) {
                turn.play(a.stop);
                self.done = true;
                return self.outcome;
            },
        }
        return null;
    }

    /// The demo's pads at this display tick: the next reading of each pad (one at each tick but
    /// the load's, from the set-up's), the hosts' START over it (it ends the demo).
    fn readDemo(self: *Round, turn: *scene.Turn, a: *const Assets) void {
        const d = &a.screen.demo;
        const k = self.demo_reading;
        self.demo_reading +|= 1;
        var pads: input.Pads = .{ .pad1 = @bitCast(d.reading(0, k)), .pad2 = @bitCast(d.reading(1, k)) };
        pads.pad1.start = pads.pad1.start or turn.pads.pad1.start;
        pads.pad2.start = pads.pad2.start or turn.pads.pad2.start;
        turn.pads = pads;
    }

    /// The demo's sign, fixed on the screen at its definition's place, in front of the layers,
    /// never culled.
    fn placeSign(w: *world.World, a: *const Assets, name: []const u8) void {
        const kind = a.kinds.find(name) orelse return;
        const def = a.kinds.get(kind).definition;
        const n = struct {
            fn of(dd: anytype, key: []const u8) i32 {
                return dd.number(key) orelse 0;
            }
        };
        const at: world.Vec3 = .pixels(n.of(def, "x"), n.of(def, "depth"), n.of(def, "height"));
        const h = w.spawn(a.kinds, kind, at, .right) catch return;
        const e = w.get(h).?;
        e.flags.on_screen = true;
        e.flags.stays = true;
        e.flags.in_front = true;
        // The load's turn drew it once: its frame's first tick is gone.
        if (e.animation.left > 1) e.animation.left -= 1;
    }

    /// START on the pad of a player in play (not waiting to continue): the player, player 1's
    /// first.
    fn startPressed(self: *const Round, turn: *const scene.Turn) ?u1 {
        if (self.fighting(0) and turn.pressed.pad1.start) return 0;
        if (self.fighting(1) and turn.pressed.pad2.start) return 1;
        return null;
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

    /// What the frame that follows the tick carries to the picture (screens/transfers.zig):
    /// nothing after the set-up (its load follows) or in the middle of a logic tick (`was`: the
    /// phase the tick began in); else play's picture: the status bar's image, the colours when
    /// they changed.
    fn pictureOf(self: *Round, a: *const Assets, was: Phase) ?transfers.Frame {
        // What a tick without a picture changes waits for the next one.
        if (self.colours.copy) self.colours_due = true;
        if (was == .setup or self.split) return null;
        const sb = &a.screen.status_bar;
        var f: transfers.Frame = .{ .play = true, .colours = self.colours_due, .status_rows = sb.image_rows, .status_cells = sb.image_cells };
        // The round ended at this tick: its next frame is the next scene's set-up's, without the
        // bar after a game over; the clear's writes the bar, without the bosses' bars.
        if (self.done and self.outcome != .cleared) f.status_rows = 0;
        self.colours_due = false;
        for (&self.art_due) |*due| {
            for (due) |tiles| f.tiles.add(tiles * transfers.words_per_tile);
            due.* = .{ 0, 0 };
        }
        // The bosses' bars' rectangle, written whole while they show; their partial cells built
        // at every frame from a boss's first tick, but at a frame that builds player 2's (the
        // original returns before them then).
        if (self.shown_bar.bosses != null and !self.done) {
            f.bosses_rows = @intCast(a.bosses_bars.height);
            f.bosses_cells = @intCast(@as(u32, a.bosses_bars.width) * a.bosses_bars.height);
        }
        if (!self.bar_due[1]) for (self.play.world.bosses) |h| {
            if (h != null) f.bar_parts += 1;
        };
        for (&self.bar_due) |*due| {
            if (due.*) f.bar_parts += 1;
            due.* = false;
        }
        f.strips = self.strips_due;
        f.strip_blocks = self.strip_blocks_due;
        f.strip_rows = self.strip_rows_due;
        self.strips_due = 0;
        self.strip_blocks_due = 0;
        self.strip_rows_due = 0;
        if (self.animation_shown) |step| if (self.animation_rows_due != 0) {
            f.plane_rows = self.animation_rows_due;
            f.plane_row_cells = @intCast(self.stage(a).steps()[step].map.width);
            self.animation_rows_due = 0;
        };
        return f;
    }

    /// The display tick's share of the art streamed in: the next of its list's.
    fn nextStreamed(self: *Round, a: *const Assets) content_round.Streamed {
        return self.art.next(self.stage(a).script);
    }

    /// The columns and rows of blocks the camera's move from `before` to `after` brings into the
    /// planes (the round's bands: each band's place across crossing a column of blocks, the
    /// camera's down crossing a row), due at the next picture.
    fn noteStrips(self: *Round, r: *const content_round.Round, before: world.Camera, after: world.Camera) void {
        const block = 16;
        const pb = r.camera.plane_b;
        const planes = [2][2]i32{
            .{ before.x.whole(), after.x.whole() },
            .{ @divFloor(before.x.whole() * pb[0], pb[1]), @divFloor(after.x.whole() * pb[0], pb[1]) },
        };
        for (r.camera.bands, planes) |bands, x| for (bands) |b| {
            const from = @divTrunc(x[0] * b.times, b.per);
            const to = @divTrunc(x[1] * b.times, b.per);
            if (@divFloor(from, block) == @divFloor(to, block)) continue;
            self.strips_due +|= 1;
            self.strip_blocks_due +|= b.rows;
        };
        if (@divFloor(before.y.whole(), block) != @divFloor(after.y.whole(), block)) {
            for (r.camera.bands) |bands| if (bands.len != 0) {
                self.strip_rows_due +|= 1;
            };
        }
    }

    /// After the world's tick (`out` its output): each player's new frame's art, and its health
    /// bar's partial cell when its health changed, are due at the next picture.
    fn noteTransfers(self: *Round, kinds: *const world.Kinds, out: *const world.Output) void {
        const w = &self.play.world;
        for (w.players, 0..) |p, k| {
            const h = p.entity orelse continue;
            const e = w.getConst(h) orelse continue;
            // The original copies a player's art at each new frame, and at each of its states it
            // enters, a side and a walk's way each a state of its own (the frame may stay).
            const pose = poseOf(e);
            const entered = pose != null and (self.pose[k] == null or self.pose[k].? != pose.?);
            self.pose[k] = pose;
            if (out.new_frames[h.index] or entered) if (e.animation.index) |index| {
                const c = kinds.get(e.kind.?).frames[index][e.animation.frame].copied;
                self.art_due[k] = .{ if (c.len > 0) c[0] else 0, if (c.len > 1) c[1] else 0 };
            };
        }
        self.noteBars();
    }

    /// A player's state as the original numbers its states: its behaviour's state, and a walk's
    /// way (across, up, down, or across and up or down) and side; null for one not playing.
    /// Another state's side is not a state of its own: the original turns a blow or a jump in
    /// place (its art not copied again).
    fn poseOf(e: *const world.Entity) ?u16 {
        const m = switch (e.mind) {
            .player => |m| m,
            else => return null,
        };
        var way: u16 = 0;
        if (m.state == .walk) {
            const across = e.velocity.x.raw != 0;
            const depth = e.velocity.depth.raw;
            way = if (depth < 0) (if (across) 1 else 2) else if (depth > 0) (if (across) 3 else 4) else 0;
        }
        const side: u16 = if (m.state == .walk) @intFromBool(e.facingLeft()) else 0;
        return @as(u16, @backingInt(m.state)) << 4 | way << 1 | side;
    }

    /// Each player's health bar's partial cell is built again when its health changed.
    fn noteBars(self: *Round) void {
        const w = &self.play.world;
        for (w.players, 0..) |p, k| {
            const h = p.entity orelse continue;
            const e = w.getConst(h) orelse continue;
            if (e.mind != .player) continue;
            if (self.health[k] == null or self.health[k].? != e.health) self.bar_due[k] = true;
            self.health[k] = e.health;
        }
    }

    /// Player 2's invitation, at a logic tick's start: its blink, and at a blink's tick with
    /// player 2's START held (a second pad there, no special attack under way), player 2 joins as
    /// the character after player 1's (the content's): the join the world's turn then makes, and
    /// the text goes. A join asked for (`join_as`: network play's second player) is made at once.
    fn joinTick(self: *Round, turn: *scene.Turn, a: *const Assets) ?world.tick.Join {
        const j = &a.screen.status_bar.join;
        const w = &self.play.world;
        if (self.join_as) |c| {
            self.join_as = null;
            if (w.players[1].entity == null) if (self.joinOf(turn, a, c)) |x| return x;
        }
        // The special attack holds the invitation as it is (its count, its blink).
        if (w.special) return null;
        if (!self.join.due(w.players[1].entity == null, self.waiting(0), j.blink)) return null;
        const first = turn.setup.characters[0];
        if (!turn.pads.pad2.start or w.special or !turn.second_pad or first == null) {
            self.join.turn();
            return null;
        }
        const x = self.joinOf(turn, a, j.next[@backingInt(first.?)]) orelse {
            self.join.turn();
            return null;
        };
        self.join.shown = false;
        return x;
    }

    /// The join of player 2 as `character`: null when the content lacks it.
    fn joinOf(self: *Round, turn: *const scene.Turn, a: *const Assets, character: setup_mod.Character) ?world.tick.Join {
        const kind = a.kinds.find(@tagName(character)) orelse {
            std.log.warn("the content defines no {s}: player 2 cannot join", .{@tagName(character)});
            return null;
        };
        self.joining = character;
        return .{ .player = 1, .kind = kind, .lives = a.screen.status_bar.join.lives, .colours = playerColours(turn, 1, character, kind, a) };
    }

    /// The colours player `k` playing `character` (of kind `kind`) is drawn with: the variant's
    /// for a second player playing the first's character (`Policies.duplicate_colours`), when
    /// the character's definition has them; else its own.
    fn playerColours(turn: *const scene.Turn, k: u1, character: setup_mod.Character, kind: world.entity.KindId, a: *const Assets) ?u8 {
        const name = turn.policies.duplicate_colours orelse return null;
        if (k != 1 or turn.setup.characters[0] != character) return null;
        return a.kinds.get(kind).definition.colourMap(name);
    }

    /// Player 2 joined at this logic tick, as `joining`: two players in the game from now on.
    fn joined(self: *Round, turn: *scene.Turn) void {
        const w = &self.play.world;
        if (w.players[1].entity == null) return;
        turn.setup.characters[1] = self.joining;
        turn.setup.players = .two;
    }

    /// Player 2 joins the round under way as `character` at its next logic tick, its first life
    /// dropping in as the original's PRESS 2UP START's does (network play's second player joining
    /// a game, DESIGN.md 9). False when player 2 plays already.
    pub fn dropIn(self: *Round, character: setup_mod.Character) bool {
        if (self.play.world.players[1].entity != null) return false;
        self.join_as = character;
        return true;
    }

    /// Player `k` leaves the game under way (network play's second player who quits): as the
    /// original treats a player out of lives who does not continue, out of the game, its
    /// fighter gone. Another may join later (`dropIn`).
    pub fn dropOut(self: *Round, k: u1) void {
        const w = &self.play.world;
        const p = &w.players[k];
        if (p.entity) |h| w.remove(h);
        p.entity = null;
        p.lives = 0;
        p.continues = 0;
        p.out = true;
        if (self.join_as != null and k == 1) self.join_as = null;
    }

    /// The world's draw list made again into `out`, the world as it stands (a game loaded from
    /// another's form, network play's join: its picture right from its first frame).
    pub fn redrawWorld(self: *const Round, out: *world.Output, a: *const Assets) void {
        if (self.phase == .setup) return;
        // A copy: making the list changes nothing of the game.
        var w = self.play.world;
        var random: world.Random = .{};
        var t: world.tick.Tick = .{ .world = &w, .kinds = a.kinds, .random = &random, .out = out };
        world.systems.redraw(&t);
    }

    /// The music the round plays now: its own, the boss's once it came, none before the banner's
    /// or while it fades for the boss.
    pub fn music(self: *const Round, a: *const Assets) ?library.Sound {
        switch (self.phase) {
            .setup, .loaded, .banner_fade, .banner_in, .leaving => return null,
            else => {},
        }
        const s = &self.play.world.script;
        const r = self.stage(a).script;
        if (r.boss) |b| if (s.part >= r.sections.len) return switch (s.stage) {
            .boss_opening, .boss_music => null,
            else => a.sounds.find(b.music),
        };
        return self.stage(a).music;
    }

    /// START opens the settings in place of the pause (the extended and network variants): the
    /// game holds them as it holds the pause (game.zig: the pause's jingle with them), and the
    /// logic tick that START was seen at waits, as the pause's first tick does; play goes on with
    /// it once they close.
    fn startOpensSettings(_: *Round, turn: *scene.Turn, who: u1) ?flow.Exit {
        turn.settings = who;
        return null;
    }

    /// A display tick ends while the world waits (the round's start, the pause, the time over, the
    /// end): the game's clock counts it, as the original counts every tick of its logic that ends
    /// (`World.tick`; in play the world counts its own logic ticks), and so does the trace's.
    fn waited(self: *Round) void {
        self.play.world.tick +%= 1;
        self.trace_t += 1;
    }

    /// A display tick of play: START is heard (`hear_start`: not at the tick a pause ends; a pause
    /// at the next logic tick's start), and at a logic tick's end the world's sounds go out, the
    /// colours cycle, and the time running out, the round won, the game over end play.
    fn playTick(self: *Round, turn: *scene.Turn, a: *const Assets, hear_start: bool) ?flow.Exit {
        if (hear_start and self.start_pressed == null) self.start_pressed = self.startPressed(turn);
        if (self.play.schedule.into == 0) if (self.start_pressed) |who| {
            self.start_pressed = null;
            self.waited();
            // START ends the demo: its fade out, then the start-up.
            if (self.demo) {
                self.leave(turn, a, .start);
                return null;
            }
            if (turn.policies.start_opens_settings) return self.startOpensSettings(turn, who);
            self.phase = .paused;
            turn.play(a.pause);
            return null;
        };
        var scratch: world.Output = undefined;
        const out = turn.world_out orelse blk: {
            scratch = .{};
            break :blk &scratch;
        };
        const p = self.plan(turn.setup, a);
        const camera_before = self.play.world.camera;
        // Player 2's invitation counts at a logic tick's start, before the world's turn, as the
        // original's does (it sees the players as the tick before left them), and a player joins
        // in that turn.
        const join = if (self.play.logicNext()) self.joinTick(turn, a) else null;
        // The players' turn draws their scores as the tick begins: points scored later in the
        // tick (an enemy's turn) show at the next.
        if (self.play.logicNext()) for (&self.drawn_scores, self.play.world.players) |*d, pl| {
            d.* = pl.score;
        };
        if (!self.play.roundTickJoined(a.kinds, turn.random.?, turn.pads, out, &p, join)) {
            self.split = true;
            return null;
        }
        self.logic_ran = true;
        self.trace_t += 1;
        if (out.streamed) |of| self.art.start(of);
        self.loadColours(a, out.colour_loads.slice(), .shown);
        self.noteTransfers(a.kinds, out);
        self.rank(turn.setup, a, out.rankings.slice());
        if (out.colours) self.colours_due = true;
        self.noteStrips(self.stage(a).script, camera_before, self.play.world.camera);
        // The players' sounds are the logic tick's first half's (the original updates its players
        // before the wait in its middle), the others' its second's.
        for (out.sounds.slice()) |s| if (a.sounds.find(s.name)) |id| {
            if (s.first) turn.playNow(id) else turn.play(id);
        };
        self.cycle(a);
        self.animate(a);
        const w = &self.play.world;
        if (join != null) self.joined(turn);
        for (&self.out_blinks, w.players) |*b, pl| b.blink(pl.out, !self.answeredNo(pl), a.screen.status_bar.join.blink);
        for (w.players, &self.seen_specials, &self.bar_specials) |pl, *seen, *shown| if (pl.specials != seen.*) {
            seen.* = pl.specials;
            shown.* = pl.specials;
        };
        // The demo's ticks of play counted down: at the last, it ends.
        if (self.demo) {
            self.demo_left -|= 1;
            if (self.demo_left == 0) {
                self.leave(turn, a, .done);
                return null;
            }
        }
        if (w.timer.up) {
            // The timer is the logic tick's first half's: its sound with the players'.
            turn.playNow(a.stop);
            self.phase = .time_over;
            self.left = a.screen.time_over.ticks;
        } else if (w.script.stage == .won) {
            self.leave(turn, a, .cleared);
        } else if (self.over) {
            self.leave(turn, a, .game_over);
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
        turn.play(self.stage(a).music);
        const w = &self.play.world;
        w.timer.seconds = t.seconds;
        for (w.players, 0..) |pl, k| {
            if (!self.fighting(k)) continue;
            const h = pl.entity orelse continue;
            const e = w.get(h) orelse continue;
            // What it had left, at most the time over's (its health holds at none).
            const lost = @min(t.health, @max(e.health, 0));
            e.health -= lost;
            if (turn.world_out) |out| out.hits.append(.{ .attacker = null, .target = h, .damage = lost });
        }
        self.noteBars();
        self.phase = .play;
        self.play.schedule = .{ .rate = .play };
    }

    /// The round ends with `outcome` once the screen has faded out; the game under way keeps
    /// the players' parts for the next round, or ends.
    fn leave(self: *Round, turn: *scene.Turn, a: *const Assets, outcome: flow.Exit) void {
        self.outcome = outcome;
        self.phase = .leaving;
        self.colours.startFade(.black);
        // The demo plays no game.
        if (self.demo) return;
        const g = &turn.setup.progress;
        if (outcome == .game_over) {
            g.* = .{};
            return;
        }
        const w = &self.play.world;
        g.timer = w.timer.seconds;
        g.boss_bars = 0;
        for (w.bosses) |h| g.boss_bars += @intFromBool(h != null);
        for (&g.players, w.players) |*gp, wp| gp.* = .{
            .in_play = wp.entity != null,
            .score = wp.score,
            .lives = wp.lives,
            .specials = wp.specials,
            .continues = wp.continues,
            .health = if (wp.entity) |h| if (w.getConst(h)) |e| healthOf(a, e) else 0 else 0,
        };
    }

    /// The round's set-up: the game under way (a new one at the first round), the world at the
    /// round's start: the camera, the players dropping in, the first section's placed; the
    /// colours to fade in.
    fn setUp(self: *Round, turn: *scene.Turn, a: *const Assets) void {
        const setup = turn.setup;
        // The demo's players, round 1: a game of its own, which leaves the game's alone.
        const d = &a.screen.demo;
        var demo_game: setup_mod.Progress = .{ .round = 1 };
        var characters = setup.characters;
        if (self.demo) for (&demo_game.players, &characters, d.players) |*gp, *c, name| {
            gp.* = .{ .in_play = true, .lives = d.lives };
            c.* = std.meta.stringToEnum(setup_mod.Character, name);
        };
        const g = if (self.demo) &demo_game else &setup.progress;
        if (g.round == 0) g.* = .new(setup);
        self.number = g.round;
        self.demo_left = d.ticks;
        const s = self.stage(a);
        self.planes = .{
            .{ .width = s.plane_a.width, .height = s.plane_a.height },
            .{ .width = s.plane_b.width, .height = s.plane_b.height },
        };
        const w = &self.play.world;
        w.* = .{};
        w.ground = .pixels(s.script.ground);
        w.score_most = a.screen.status_bar.score_most;
        const p = self.plan(setup, a);
        world.script.start(w, &p);
        var scratch: world.Output = .{};
        const out = turn.world_out orelse &scratch;
        out.* = .{};
        var t: world.tick.Tick = .{ .world = w, .kinds = a.kinds, .random = turn.random.?, .out = out, .plan = &p };
        const r = s.script;
        for (&w.players, g.players, 0..) |*wp, gp, k| {
            wp.* = .{ .lives = gp.lives, .specials = gp.specials, .score = gp.score, .continues = gp.continues };
            self.drawn_scores[k] = gp.score;
            if (!gp.in_play) continue;
            const character = characters[k] orelse continue;
            const kind = a.kinds.find(@tagName(character)) orelse {
                std.log.warn("the content defines no {s} yet: player {d} sits out", .{ @tagName(character), k + 1 });
                continue;
            };
            const at: world.Vec3 = .{ .x = w.camera.x.add(.pixels(r.players.x)), .depth = .pixels(r.players.depth[k]), .height = .pixels(r.players.height) };
            const h = w.spawn(a.kinds, kind, at, .right) catch continue;
            wp.entity = h;
            wp.character = kind;
            wp.colours = playerColours(turn, @intCast(k), character, kind, a);
            wp.specials = 1;
            if (t.actor(world.behaviours.player, h)) |act| world.behaviours.player.startLife(act);
        }
        // The status bar shows the special attacks a new life gives; the demo's players have
        // their own, which it shows once they change.
        for (&w.players, &self.bar_specials, &self.seen_specials) |*wp, *shown, *seen| {
            shown.* = wp.specials;
            if (self.demo and wp.entity != null) wp.specials = d.specials;
            seen.* = wp.specials;
        }
        world.script.placeFirst(&t, &p);
        world.systems.loadTurns(&t);
        if (self.demo) {
            placeSign(w, a, d.sign);
            // The demo's load runs its players' turn too: the camera keeps them in its view.
            world.systems.keepPlayers(&t);
        }
        const first_colours = out.colour_loads;
        // The demo's load is in play's mode: the shadows with it.
        if (self.demo) world.systems.pictureInPlay(&t) else world.systems.picture(&t);
        self.noteTransfers(a.kinds, out);
        self.join = .{ .ticks = a.screen.status_bar.join.blink };
        self.colours.palettes = .{};
        self.colours.aim(s.colours);
        // The first section's enemies' colours, after the round's (0xE5C).
        self.loadColours(a, first_colours.slice(), .target);
        self.colours.aim(a.play_colours);
        self.colours.aim(a.players_colours);
        for (s.set.cycles, self.cycles[0..s.set.cycles.len]) |c, *x| x.* = .{ .countdown = c.period };
    }

    /// The colours the world loaded at its tick, in their order, into the colours shown (or, at
    /// the round's set-up, the colours its fade in goes to): an enemies' colours into the first,
    /// the second or the other, the boss's, the police car's; the colours shown kept as the
    /// special attack is called, and given back after it.
    fn loadColours(self: *Round, a: *const Assets, loads: []const world.output.ColourLoad, into: enum { shown, target }) void {
        const p = &self.colours.palettes;
        for (loads) |l| {
            const palette: ?*const art.Palette = switch (l) {
                .enemies => |e| if (a.enemy_colours.of(e.colours)) |set| switch (e.into) {
                    world.script.Held.first => set.first,
                    world.script.Held.second => set.second,
                    else => set.own,
                } else null,
                .boss => self.stage(a).boss_colours,
                .police => a.enemy_colours.police,
                .keep => {
                    self.kept = p.shown;
                    continue;
                },
                .back => {
                    p.shown = self.kept;
                    self.colours_due = true;
                    continue;
                },
            };
            const pal = palette orelse continue;
            switch (into) {
                // The next frame copies the colours shown.
                .shown => {
                    p.show(pal);
                    self.colours_due = true;
                },
                .target => p.aim(pal),
            }
        }
    }

    /// The round's colour cycles, a step every period of logic ticks.
    fn cycle(self: *Round, a: *const Assets) void {
        const set = self.stage(a).set;
        for (set.cycles, self.cycles[0..set.cycles.len]) |c, *s| {
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

    /// The round's animation: a new step's colours in the colours shown, its map drawn at the
    /// next picture (written on the plane's 64 cells across, its map's width at a time).
    fn animate(self: *Round, a: *const Assets) void {
        const steps = self.stage(a).steps();
        if (steps.len == 0) return;
        const step = self.play.world.script.animation.step;
        if (self.animation_shown) |shown| {
            if (shown == step) return;
        } else if (step == 0) return;
        self.animation_shown = step;
        self.colours.palettes.show(steps[step].colours);
        self.colours_due = true;
        const m = steps[step].map;
        self.animation_rows_due = @intCast(@as(u32, m.height) * (plane_cells / m.width));
    }

    /// What the status bar shows.
    fn bar(self: *const Round, a: *const Assets) Bar {
        const w = &self.play.world;
        var out: Bar = .{ .time = w.timer.shown, .join = self.join.shown };
        for (w.players, &out.players, self.out_blinks, 0..) |p, *o, ob, k| {
            const playing: PlayerBar = .{ .playing = .{ .score = self.drawn_scores[k], .lives = p.lives, .specials = self.bar_specials[k], .health = 0 } };
            const gone: PlayerBar = .{ .out = .{ .name = true, .score = p.score, .game_over = ob.shown } };
            const h = p.entity orelse {
                if (p.out) o.* = gone;
                continue;
            };
            const e = w.getConst(h) orelse continue;
            const new_game = k == 0 and w.players[1].entity == null and !w.players[1].out;
            o.* = switch (e.mind) {
                .player => .{ .playing = .{ .score = self.drawn_scores[k], .lives = p.lives, .specials = self.bar_specials[k], .health = healthOf(a, e) } },
                .player_waiting => |m| switch (m.state) {
                    // Its first tick: the bar as it was (the question still, after a NO; the name,
                    // the tick it was entered).
                    .begin => if (m.answered_no)
                        .{ .asking = .{ .continues = m.count, .new_game = new_game, .cursor = if (m.shown) m.cursor else null } }
                    else if (m.named) naming(p, &m) else playing,
                    .name_entry => naming(p, &m),
                    .continue_choose, .continue_chosen => .{ .asking = .{ .continues = m.count, .new_game = new_game, .cursor = if (m.shown) m.cursor else null } },
                    // The tick it went out its part is cleared: its name comes at the next.
                    .countdown, .game_over => .{ .out = .{ .name = m.state != .countdown or m.music, .score = p.score, .game_over = ob.shown } },
                },
                else => .none,
            };
        }
        // The bosses' bars: their entry, set at a boss's first tick in its section, shows them
        // from the next tick, each its boss's health (none once the boss is gone).
        if (w.boss_bar) |entry| {
            const bs = &a.screen.status_bar.bosses;
            var b: BossesBar = .{ .second = entry < bs.second.len and bs.second[entry], .pixels = .{ 0, 0 } };
            for (w.bosses, &b.pixels) |h, *px| {
                const e = w.getConst(h orelse continue) orelse continue;
                px.* = @intCast(@min(@as(u32, @intCast(@max(e.health, 0))) * bs.points, std.math.maxInt(u16)));
            }
            out.bosses = b;
        }
        return out;
    }

    pub fn draw(self: *const Round, prev: ?*const Round, v: *view.View, a: *const Assets) !void {
        const now = self.shown_bar;
        const s = self.stage(a);
        if (prev == null) {
            try v.board(.a).drawMap(s.plane_a, 0, 0);
            try v.board(.b).drawMap(s.plane_b, 0, 0);
            try v.board(.window).drawMapAtPlace(a.status_bar);
            try drawBar(v, a, now, null);
        } else try drawBar(v, a, now, prev.?.shown_bar);
        // The round's animation's step, drawn whole when it changed: its map at its place,
        // repeated across its plane.
        if (self.shown_animation) |step| if (prev == null or prev.?.shown_animation != self.shown_animation) {
            const m = s.steps()[step].map;
            const place = m.place.?;
            const board = v.board(switch (place.layer) {
                .plane_a => .a,
                .plane_b => .b,
                .window => .window,
            });
            var x: i32 = place.x;
            while (x < board.width) : (x += m.width) try board.drawMap(m, x, place.y);
        };
        try drawBosses(v, a, now.bosses, if (prev) |p| p.shown_bar.bosses else null);
        const c = self.shown_camera;
        const r = s.script;
        v.screen.plane_a.x = c[0];
        v.screen.plane_a.y = c[1];
        v.screen.plane_b.x = @divFloor(c[0] * r.camera.plane_b[0], r.camera.plane_b[1]);
        v.screen.plane_b.y = if (r.camera.plane_b_down) c[1] else c[2];
        // A plane whose bands scroll at their own ratios scrolls by lines, each band's at its
        // place across.
        for ([_]view.Plane{ .a, .b }, r.camera.bands, [_]i32{ v.screen.plane_a.x, v.screen.plane_b.x }) |p, bands, x| {
            if (!ownRatios(bands)) continue;
            var left: [render.height]i16 = undefined;
            bandLines(bands, x, &left);
            v.lineScroll(p, &left);
        }
        // The bosses' bars make the status bar a row taller.
        const lines = barLines(a) + if (now.bosses != null) bossesRows(a) * art.tile_side else 0;
        v.screen.window.lines = .{ .top = 0, .bottom = lines };
        v.screen.sprite_lines = .{ .top = lines, .bottom = render.height };
        v.screen.colours = self.colours.shown;
        try v.sprites.appendSlice(v.gpa, v.world_out.shown_sprites.slice());
        switch (self.shown_phase) {
            .banner_in, .banner_wait, .banner_out => {
                try v.sprites.append(v.gpa, .of(a.banner_left, self.shown_banner, 0));
                try v.sprites.append(v.gpa, .of(s.number, 0, self.shown_banner));
                try v.sprites.append(v.gpa, .of(a.banner_right, -self.shown_banner, 0));
            },
            .time_over => try v.sprites.append(v.gpa, .of(a.time_over_text, 0, 0)),
            else => {},
        }
        if (self.shown_pause) try v.sprites.append(v.gpa, .of(a.pause_text, 0, 0));
        if (self.shown_game_over) try v.sprites.append(v.gpa, .of(a.game_over_text, 0, 0));
    }
};

/// Whether a plane's bands scroll at their own ratios of its place across, not all at it.
fn ownRatios(bands: []const content_round.Band) bool {
    for (bands) |b| if (b.times != b.per) return true;
    return false;
}

/// The place across of each line of the screen in a plane of `bands` at `x`: its band's, `x`
/// times the band's ratio (toward zero, as the original's division), each band `rows` blocks
/// of lines from the top; the lines past the last band, the last band's.
fn bandLines(bands: []const content_round.Band, x: i32, left: *[render.height]i16) void {
    const block = 16;
    var line: usize = 0;
    var last: i16 = @intCast(x);
    for (bands) |b| {
        last = @intCast(@divTrunc(x * b.times, b.per));
        const end = @min(line + @as(usize, b.rows) * block, left.len);
        @memset(left[line..end], last);
        line = end;
    }
    @memset(left[line..], last);
}

test "a plane's lines at their bands' ratios" {
    const bands = [_]content_round.Band{ .{ .rows = 6, .times = 1, .per = 4 }, .{ .rows = 3, .times = 1, .per = 2 }, .{ .rows = 6, .times = 1, .per = 1 } };
    var left: [render.height]i16 = undefined;
    bandLines(&bands, 803, &left);
    try std.testing.expect(ownRatios(&bands));
    try std.testing.expectEqual([4]i16{ 200, 200, 401, 803 }, [4]i16{ left[0], left[95], left[96], left[223] });
}

/// Which enemies' colours (by number, a bit each) are a kind's own.
fn ownColours(ec: *const library.EnemyColours) u16 {
    var bits: u16 = 0;
    for (ec.sets[0..ec.len], 0..) |set, n| {
        if (set.own != null) bits |= @as(u16, 1) << @intCast(n);
    }
    return bits;
}

/// A player entering its name, as its part of the bar shows it.
fn naming(p: world.Player, m: *const world.behaviours.player_waiting.Mind) PlayerBar {
    var x: PlayerBar.Naming = .{ .score = p.score, .places = undefined };
    for (&x.places, 0..) |*q, k| q.* = world.behaviours.player_waiting.shownAt(m, k);
    return .{ .naming = x };
}

/// A player ranked in the high-score table: its marks leave it; its entry, when it entered its
/// name, takes the last one's place, marked as its player's new one, and the table is sorted
/// again.
pub fn rankIn(table: []Score, player: u1, entry: ?Score) void {
    for (table) |*e| if (e.new == player) {
        e.new = null;
    };
    var x = entry orelse return;
    x.new = player;
    table[table.len - 1] = x;
    HighScores.sort(table);
}

/// A name entered (the numbers of the name entry's `letters` taken at its places) as the
/// high-score table keeps it: letters of the font; none taken, and the end mark (the last
/// letter), a space.
pub fn nameOf(letters: []const []const u8, name: [world.behaviours.player_waiting.places]?u8) [3]u8 {
    var out: [3]u8 = @splat(' ');
    for (&out, name) |*c, letter| {
        const l = letter orelse continue;
        if (@as(usize, l) + 1 >= letters.len) continue;
        if (letters[l].len == 1) c.* = letters[l][0];
    }
    return out;
}

/// A fighter's health as its bar shows it: none to its kind's most.
fn healthOf(a: *const Round.Assets, e: *const world.Entity) u8 {
    const most = a.kinds.get(e.kind.?).definition.health;
    return @intCast(std.math.clamp(e.health, 0, @min(most, std.math.maxInt(u8))));
}

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

/// The bosses' bars that changed since `was`: shown, their rectangle and its label, then each
/// bar; gone, the status bar's own row again.
fn drawBosses(v: *view.View, a: *const Round.Assets, now: ?BossesBar, was: ?BossesBar) !void {
    const board = v.board(.window);
    const bs = &a.screen.status_bar.bosses;
    const b = now orelse {
        if (was == null) return;
        // The status bar's rows the rectangle covered.
        const place = a.bosses_bars.place orelse return;
        for (0..a.bosses_bars.height) |r| {
            const y: u8 = @intCast(@max(place.y, 0) + @as(i32, @intCast(r)));
            restore(board, a, .{ .x = @intCast(@max(place.x, 0)), .y = y }, @intCast(a.bosses_bars.width));
        }
        return;
    };
    if (was == null) {
        try board.drawMapAtPlace(a.bosses_bars);
        try board.drawMap(a.bosses_label, bs.label.x, bs.label.y);
    }
    for (0..2) |k| {
        if (k == 1 and !b.second) continue;
        const before = if (was) |w| (if (k == 0 or w.second) w.pixels[k] else null) else null;
        if (before != null and before.? == b.pixels[k]) continue;
        try bossBar(board, a, if (k == 0) a.boss_bar_1 else a.boss_bar_2, bs.bars[k], b.pixels[k]);
    }
}

/// A boss's bar at `at`: its pixels, eight a cell (`map`'s ten from the full ones on: the full,
/// the partial, its fill the enemies' of `play/fills` by the pixels left, the empty); from the
/// over-full pixels, its ten cells all of a look (`play/enemy_bar_over`'s).
fn bossBar(board: *render.Board, a: *const Round.Assets, map: *const art.TileMap, at: records.Cell, pixels: u16) !void {
    const bs = &a.screen.status_bar.bosses;
    const cells = (map.width - 1) / 2;
    if (pixels >= bs.over[0]) {
        const look: usize = if (pixels >= bs.over[1]) 1 else 0;
        for (0..cells) |i| try putCell(board, a.boss_bar_over, look, 0, at.x + @as(u8, @intCast(i)), at.y);
        return;
    }
    const full = @min(pixels / art.tile_side, cells);
    const rest = pixels % art.tile_side;
    for (0..cells) |i| {
        const m = cells - full + i;
        if (m == cells) {
            const c = map.cell(m, 0);
            try board.put(at.x + @as(i32, @intCast(i)), at.y, &a.fills.tiles[art.tile_side + rest], .{ .palette = c.palette, .priority = c.priority });
        } else try putCell(board, map, m, 0, at.x + @as(u8, @intCast(i)), at.y);
    }
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
        .naming => |x| {
            const before: ?PlayerBar.Naming = if (was) |w| w.naming else null;
            const ne = &a.screen.name_entry;
            const at = &ne.players[k];
            if (before == null) {
                try v.write(.window, a.text, p.name_at.x, p.name_at.y, p.name, .{});
                try writeWords(v, a, at.label, ne.label);
                if (ne.letters.len != 0) try v.write(.window, a.text, at.mark.x, at.mark.y, ne.letters[ne.letters.len - 1], .{});
            }
            if (before == null or before.?.score != x.score) try drawScore(v, a, p.score, x.score);
            for (x.places, 0..) |letter, q| {
                if (before) |b| if (std.meta.eql(b.places[q], letter)) continue;
                const cell: records.Cell = .{ .x = at.first.x + @as(u8, @intCast(q)), .y = at.first.y };
                restore(board, a, cell, 1);
                if (letter) |l| if (l < ne.letters.len) try v.write(.window, a.text, cell.x, cell.y, ne.letters[l], .{});
            }
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

/// A score at `at`: as many digits as the most a score holds has (play's record's).
pub fn drawScore(v: *view.View, a: anytype, at: records.Cell, score: u32) !void {
    const most = a.screen.status_bar.score_most;
    var buf: [10]u8 = undefined;
    try v.write(.window, a.text, at.x, at.y, digits(&buf, @min(score, most), digitsOf(most)), .{});
}

/// The decimal digits of `most`.
pub fn digitsOf(most: u32) u8 {
    var n: u8 = 1;
    var x = most / 10;
    while (x != 0) : (x /= 10) n += 1;
    return n;
}

/// `value`'s last `width` decimal digits, zeros first, in `buf` (10 bytes at least).
pub fn digits(buf: *[10]u8, value: u32, width: u8) []const u8 {
    var x = value;
    var k: usize = buf.len;
    while (k > buf.len - width) {
        k -= 1;
        buf[k] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
    }
    return buf[k..];
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

/// A health bar of `health` points, a point a pixel: its full cells, its partial cell of the
/// pixels left (`play/fills`, a tile by the pixels), its empty cells. The bar's map is its full
/// cells, the partial one, its empty cells: the bar shows the cells from `(cells - full)` on.
pub fn healthBar(board: *render.Board, a: anytype, map: *const art.TileMap, at: records.Cell, health: u8) !void {
    const cells = (map.width - 1) / 2;
    const full = @min(health / art.tile_side, cells);
    const rest = if (full == cells) 0 else health % art.tile_side;
    for (0..cells) |i| {
        const m = cells - full + i;
        if (m == cells) {
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

test "a name entered in the high-score table: the last entry's place, marked, sorted" {
    var t: [setup_mod.high_scores]Score = undefined;
    for (&t, 0..) |*e, k| e.* = .{ .score = @intCast(10_000 * (10 - k)), .round = 1, .level = 1 };
    t[3].new = 0;
    t[4].new = 1;
    const letters = [_][]const u8{ "A", "B", "C", "(ED)" };
    const name = nameOf(&letters, .{ 2, 3, null });
    try std.testing.expectEqualStrings("C  ", &name);
    rankIn(&t, 0, .{ .score = 55_000, .round = 2, .level = 1, .name = name });
    try std.testing.expectEqual(@as(u32, 55_000), t[5].score);
    try std.testing.expectEqual(@as(?u1, 0), t[5].new);
    try std.testing.expectEqual(@as(?u1, null), t[3].new);
    try std.testing.expectEqual(@as(?u1, 1), t[4].new);
    try std.testing.expectEqual(@as(u32, 20_000), t[9].score);
    // Ranked without an entry: its marks only leave.
    rankIn(&t, 1, null);
    try std.testing.expectEqual(@as(?u1, null), t[4].new);
    try std.testing.expectEqual(@as(?u1, 0), t[5].new);
}

test "a number's digits: its last ones, zeros first" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 6), digitsOf(999_900));
    try std.testing.expectEqualStrings("003100", digits(&buf, 3100, 6));
    try std.testing.expectEqualStrings("45", digits(&buf, 12345, 2));
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

test "the invitation's blink's tick is the join's moment: due once every `blink` logic ticks" {
    var j: Join = .{ .ticks = 8 };
    var due: usize = 0;
    for (0..24) |k| if (j.due(true, false, 8)) {
        try std.testing.expectEqual(@as(usize, 7), k % 8);
        due += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), due);
    // Due but not turned (player 2 joins there): the blink's phase stays.
    try std.testing.expect(!j.phase and !j.shown);
}

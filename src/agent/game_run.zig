//! A scenario from power-on (`start CHARACTER [CHARACTER]` without a situation, decision D14):
//! the whole game runs as the hosts run it, a display tick at a time, with the pads the runner
//! decides. The start passes the screens as sor-remaster's runner does (its agent's scenario.zig):
//! START tapped (held 3 display ticks, released 9) until the game menu; the menu's arrow down to 2
//! PLAYERS when two play, then START; 60 display ticks into the character select, then each
//! player's cursor right until it is on the character, START; then nothing until the round's
//! play begins. The script's tick 0 is the first logic tick of play; a command runs at a logic
//! tick's start, and its pads are held over the tick's two display ticks.
//!
//! The trace: the scenes, as sor-remaster's trace names them; in a round, play's phases, the
//! world at each display tick of the round's scenes but at each logic tick in play (the scene's
//! tick `t` the round's), the scenes' sounds; the probe (the fighters' frames and boxes) as the
//! trace observes the round's world. The runner reads the game's state and never writes it.
const std = @import("std");
const sorz = @import("sorz");
const scenario = @import("scenario.zig");

const world = sorz.world;
const input = sorz.input;
const scene = sorz.scene;
const library = sorz.library;

/// The start's taps: a button held `tap_on` display ticks, then released `tap_off`.
const tap_on = 3;
const tap_off = 9;
/// The display ticks the start may take before it fails.
const start_most = 6000;

/// A run's sound, when it is kept: the game's sound as the hosts make it (`game.tickSound`), its
/// frames at 48 kHz.
pub const Sound = struct {
    gpa: std.mem.Allocator,
    out: sorz.sound_out.SoundOut,
    /// The frame's transfers and work due at the next tick.
    due: sorz.game.Due = .{},
    pcm: std.ArrayList(i16) = .empty,

    pub fn init(gpa: std.mem.Allocator, sounds: *const sorz.library.Sounds) !Sound {
        return .{ .gpa = gpa, .out = try .init(gpa, sorz.sound_out.rate, sounds) };
    }

    pub fn deinit(self: *Sound) void {
        self.out.deinit(self.gpa);
        self.pcm.deinit(self.gpa);
    }
};

/// The game's canonical form at each display tick (canonical.zig): its size, and, with `reload`,
/// the state read back from it, which the run goes on from (a round trip: the state read must be
/// the one written, its form the same bytes).
pub const Forms = struct {
    gpa: std.mem.Allocator,
    reload: bool,
    /// A line a display tick: the tick, the scene, the world's entities, the form's bytes.
    sizes: ?*std.Io.Writer,
    form: []u8,
    again: []u8,
    read: *sorz.game.State,
    /// The largest form, and its tick.
    largest: usize = 0,
    largest_at: u32 = 0,
    reloads: u64 = 0,

    const canonical = sorz.canonical;
    const State = sorz.game.State;

    pub fn init(gpa: std.mem.Allocator, reload: bool, sizes: ?*std.Io.Writer) !Forms {
        const form = try gpa.alloc(u8, canonical.maxSize(State));
        errdefer gpa.free(form);
        const again = try gpa.alloc(u8, canonical.maxSize(State));
        errdefer gpa.free(again);
        return .{ .gpa = gpa, .reload = reload, .sizes = sizes, .form = form, .again = again, .read = try gpa.create(State) };
    }

    pub fn deinit(self: *Forms) void {
        self.gpa.free(self.form);
        self.gpa.free(self.again);
        self.gpa.destroy(self.read);
    }

    /// After a display tick: the form's size noted; with `reload`, the state replaced by the one
    /// read from its form. False when that is not the state written.
    fn after(self: *Forms, state: *State) !bool {
        const form = canonical.write(State, state, self.form);
        if (form.len > self.largest) {
            self.largest = form.len;
            self.largest_at = state.tick;
        }
        if (self.sizes) |w| {
            var live: usize = 0;
            var play: usize = 0;
            if (state.scenes.base == .round) {
                const p = &state.scenes.base.round.play;
                for (&p.world.entities) |*e| live += @intFromBool(e.alive());
                play = canonical.sizeOf(sorz.world.Play, p);
            }
            try w.print("{d} {s} {d} {d} {d}\n", .{ state.tick, @tagName(std.meta.activeTag(state.scenes.base)), live, form.len, play });
        }
        if (!self.reload) return true;
        canonical.read(State, form, self.read) catch |err| {
            std.log.err("tick {d}: the form does not read: {s}", .{ state.tick, @errorName(err) });
            return false;
        };
        if (!std.meta.eql(self.read.*, state.*)) {
            std.log.err("tick {d}: the state read from the form is not the state", .{state.tick});
            return false;
        }
        if (!std.mem.eql(u8, form, canonical.write(State, self.read, self.again))) {
            std.log.err("tick {d}: the state read writes another form", .{state.tick});
            return false;
        }
        state.* = self.read.*;
        self.reloads += 1;
        return true;
    }
};

pub const Run = struct {
    content: *const library.Content,
    assets: *const scene.Assets,
    script: *const scenario.Script,
    /// A recorded play's pads, by display tick (`start pads`).
    pads: []const input.Pads = &.{},
    state: sorz.game.State,
    out: world.Output = .{},
    body: scenario.Body,
    trace: ?*world.trace.Writer,
    /// The probe, written with the trace (its entities' ids are the trace's).
    probe: ?*scenario.Probe = null,
    stage: Stage = .to_menu,
    /// The display ticks into the stage, and into the tap under way (its button and pad).
    in_stage: u64 = 0,
    tap: u64 = 0,
    tap_button: input.Button = .start,
    tap_pad: u1 = 0,
    /// The player choosing on the select.
    chooser: u1 = 0,
    /// The pads held over the logic tick under way.
    current: input.Pads = .{},
    /// The sound, when the run keeps it.
    sound: ?*Sound = null,
    /// The canonical form at each display tick (`--reload`, `--form-sizes`), when the run looks.
    forms: ?*Forms = null,
    /// The display tick of the body's tick 0.
    body_v: ?u64 = null,
    /// The game's clock as the script's tick 0 begins, as sor-remaster tells it: its value at
    /// the display tick before (the world reads one more during the tick).
    body_clock: ?u32 = null,
    failure: ?[]const u8 = null,
    /// What the trace saw last: the scene (its serial, its trace name), the round's tick.
    seen_serial: u32 = 0,
    seen_scene: []const u8 = "",
    seen_t: u64 = 0,
    scene_t: u64 = 0,
    /// The trace ids of the world's entities, by place, for the conditions.
    ids: [world.entity.capacity]u32 = @splat(0),
    /// Sounds the trace writes with the next scene.
    deferred: [8]library.Sound = undefined,
    deferred_len: u8 = 0,
    /// The load the script counted its one tick of (its serial).
    load_counted: u32 = 0,
    /// The other program's situation at the script's tick 0, which the round's world is taken
    /// up from there (`takeUp`), and the allocator its take-up uses.
    take_up: ?TakeUp = null,

    pub const TakeUp = struct { gpa: std.mem.Allocator, situation: *const scenario.Situation };

    const Stage = enum { to_menu, menu, select_wait, select, to_play, pads, body, done };

    /// `pads`: a recorded play's (the script's start is `start pads`).
    pub fn init(content: *const library.Content, assets: *const scene.Assets, script: *const scenario.Script, pads: []const input.Pads, trace: ?*world.trace.Writer) Run {
        return .{
            .content = content,
            .assets = assets,
            .script = script,
            .pads = pads,
            .state = .powerOn(.{ .variant = .original }),
            .body = .{ .commands = script.commands },
            .trace = trace,
            .stage = switch (script.start) {
                .players => .to_menu,
                .pads => .pads,
                .power_on => .body,
            },
        };
    }

    /// One display tick: the pads, the game's tick, the trace. False when the run is over.
    pub fn step(self: *Run) !bool {
        if (self.stage == .done) return false;
        const pads = self.next() orelse return false;
        const turn = self.state.stepWith(pads, .{}, self.assets, &self.out);
        if (self.sound) |s| try s.pcm.appendSlice(s.gpa, sorz.game.tickSound(&s.out, &s.due, &turn, 0));
        if (self.trace) |tw| {
            // The pads the game read: the attract demo's own.
            const read = if (self.round()) |r| r.pads_read else pads;
            tw.held = .{ read.pad1, read.pad2 };
        }
        try self.observe(&turn);
        if (self.forms) |f| if (!try f.after(&self.state)) {
            self.failure = "the state read from its form is not the one written";
            self.stage = .done;
        };
        return true;
    }

    /// The round scene (a round, or the attract demo's), when it is the game's scene (no overlay
    /// over it).
    fn round(self: *Run) ?*scene.Round {
        const s = self.topScene() orelse return null;
        return switch (s.*) {
            .round, .demo => |*r| r,
            else => null,
        };
    }

    /// The scene on top, when it is the flow's (no overlay over it).
    fn topScene(self: *Run) ?*scene.Scene {
        return switch (self.state.scenes.top()) {
            .scene => |s| s,
            .overlay => null,
        };
    }

    /// The pads of the next display tick; null when the run ends.
    fn next(self: *Run) ?input.Pads {
        if (self.stage == .pads) {
            const v = self.state.tick;
            if (v < self.script.start.pads.vblanks) return if (v < self.pads.len) self.pads[v] else .{};
            self.enter(.body);
        }
        if (self.stage != .body) {
            if (self.state.tick >= start_most) return self.fail("the start did not reach play");
            const in = self.startStep() orelse return if (self.stage == .done) null else self.next();
            return in;
        }
        // A logic tick starts at the next display tick (a screen's: each; a load's: one, its
        // scene's set-up's, as sor-remaster's runner counts the original's step that loads): the
        // script's commands, then its pads.
        const starts = switch (self.state.scenes.top()) {
            .overlay => if (self.state.scenes.topSerial() != self.load_counted) blk: {
                self.load_counted = self.state.scenes.topSerial();
                break :blk true;
            } else false,
            .scene => if (self.round()) |r| r.phase != .play or r.play.schedule.into == 0 else true,
        };
        if (!starts) return self.current;
        if (self.body_v == null) {
            self.body_v = self.state.tick;
            if (self.take_up) |tu| self.takeUp(tu) catch |e| {
                std.log.err("the round's world is not taken up at display tick {d}: {s}", .{ self.state.tick, @errorName(e) });
                return self.fail("the round's world was not taken up");
            };
            if (self.round()) |r| self.body_clock = r.play.world.tick -% 1;
        }
        self.current = self.body.tick(self, holds) orelse {
            if (self.body.timed_out != null) self.failure = "a condition did not come in time";
            self.stage = .done;
            return null;
        };
        return self.current;
    }

    /// The round's world replaced by the other program's at the situation (the script's tick 0,
    /// a logic tick's end in play in both): its entities, players, camera, script, timer and
    /// random generator, as the situation's runner takes them up (scenario.zig); the game's
    /// clock and the bosses' bar stay the round's own, the bar showing the bosses taken up. The
    /// trace numbers the entities as the other program's did, and observes the world again at
    /// the tick: the comparisons of such a run start after it.
    fn takeUp(self: *Run, tu: TakeUp) !void {
        const r = self.round() orelse return error.NotInARound;
        if (r.phase != .play) return error.NotInPlay;
        const round_script = (self.assets.round.rounds.of(r.number) orelse return error.NoRound).script;
        const ec = &self.assets.round.enemy_colours;
        var taken = try scenario.Run.init(tu.gpa, &self.content.kinds, self.script, tu.situation, .{ .round = round_script, .colour_lines = ec.lines, .own_colours = ec.ownBits() }, null, null);
        defer taken.deinit();
        if (!taken.scripted) return error.ScriptNotReplayed;
        if (taken.skipped.items.len != 0) return error.KindsMissing;
        const w = &r.play.world;
        const was = w.*;
        w.* = taken.play.world;
        w.tick = was.tick;
        w.score_most = was.score_most;
        // The lives the players' scores gave them by then (the trace does not count them: each
        // came at the turn after its score), so that only a score passing the next gives one.
        const extra = self.assets.round.screen.status_bar.extra_lives;
        for (&w.players) |*p| p.extra_lives = @intCast(for (extra, 0..) |score, n| {
            if (p.score < score) break n;
        } else extra.len);
        w.boss_bar = was.boss_bar;
        w.bosses = .{ null, null };
        // The bosses beaten (none left with health) stopped the timer with their last blow.
        var beaten = false;
        var standing = false;
        for (&w.entities, 0..) |*e, i| {
            if (!e.alive() or e.spawn.bar == null) continue;
            w.bosses[@intFromBool(e.spawn.traits.twin)] = w.handleAt(i);
            if (e.health > 0) standing = true else beaten = true;
        }
        if (beaten and !standing) w.timer.stopped = true;
        // The colours the script loaded before the take-up, as the round shows them.
        r.showHeldColours(&self.assets.round);
        if (scenario.generatorOf(tu.situation)) |g| self.state.random = g;
        for (&r.drawn_scores, &r.bar_specials, &r.seen_specials, w.players) |*d, *shown, *seen, p| {
            d.* = p.score;
            shown.* = p.specials;
            seen.* = p.specials;
        }
        const tw = self.trace orelse return;
        tw.seen = @splat(.{});
        for (taken.ids, taken.generations, 0..) |id, generation, i| if (id != 0) tw.assignId(i, generation, id);
        tw.next_id = @max(tw.next_id, tu.situation.next_id);
        try tw.observeAt(self.state.tick, r.trace_t, w, &self.content.kinds, &self.out);
        self.noteIds(w);
        // The probe tells every fighter's frame again, as taken up.
        if (self.probe) |p| {
            p.last = @splat(null);
            try p.observe(self.state.tick, r.trace_t, w, &self.content.kinds, &self.ids);
        }
    }

    fn fail(self: *Run, why: []const u8) ?input.Pads {
        self.failure = why;
        self.stage = .done;
        return null;
    }

    fn enter(self: *Run, stage: Stage) void {
        self.stage = stage;
        self.in_stage = 0;
        self.tap = 0;
    }

    /// The start's next display tick; null when the start is over (the body begins) or failed.
    fn startStep(self: *Run) ?input.Pads {
        const players = self.script.start.players;
        defer self.in_stage += 1;
        // The scene of the flow as sor-remaster's runner sees it, by the original's mode: from the
        // last scene's exit (the next one due), its load included.
        const top = if (self.state.scenes.next) |n| n.kind else std.meta.activeTag(self.state.scenes.base);
        switch (self.stage) {
            .to_menu => {
                if (top == .menu) {
                    self.enter(.menu);
                    return .{};
                }
                return self.tapping(0, .start);
            },
            .menu => {
                if (top == .select) {
                    self.enter(.select_wait);
                    return .{};
                }
                const s = &self.state.scenes.base;
                // A first round other than 1: the options' first round first, the options opened
                // with pad 2's code (A, B, C and right held as the menu leaves for them); start
                // leaves them when it is set.
                const first_round = players.round - 1;
                switch (s.*) {
                    .options => |*o| switch (o.phase) {
                        // As sor-remaster's runner: while the options come in, it goes on
                        // tapping as at the menu's OPTIONS (to no effect), its taps' rhythm kept.
                        .setup, .aim, .fade_in => {
                            var in = self.tapping(0, .start);
                            in.pad2 = .{ .a = true, .b = true, .c = true, .right = true };
                            return in;
                        },
                        .first_line, .lines => {
                            if (o.values.first_round == first_round or !o.hidden_lines) return self.tapping(0, .start);
                            return self.tapping(0, if (o.line != .first_round) .down else .right);
                        },
                        else => return .{},
                    },
                    else => {},
                }
                const m = switch (s.*) {
                    .menu => |*m| m,
                    else => return .{},
                };
                if (self.state.setup.first_round != first_round) {
                    if (m.choice != .options) return self.tapping(0, .down);
                    var in = self.tapping(0, .start);
                    in.pad2 = .{ .a = true, .b = true, .c = true, .right = true };
                    return in;
                }
                const want: sorz.screens.menu.Line = if (players.second != null) .two_players else .one_player;
                if (@backingInt(m.choice) > @backingInt(want) and players.round == 1) return self.fail("the menu's arrow went past 2 PLAYERS");
                return self.tapping(0, if (@backingInt(m.choice) < @backingInt(want)) .down else if (m.choice != want) .up else .start);
            },
            .select_wait => {
                if (self.in_stage < 60) return .{};
                self.enter(.select);
                self.chooser = 0;
                return .{};
            },
            .select => {
                const s = &self.state.scenes.base;
                const sel = switch (s.*) {
                    .select => |*x| x,
                    else => return self.fail("the character select ended before the choice"),
                };
                const k: usize = self.chooser;
                const name = if (k == 0) players.first else players.second.?;
                const want = std.meta.stringToEnum(sorz.setup.Character, name) orelse return self.fail("no such character");
                const cur = sel.cursors[k];
                if (cur.chosen) {
                    if (k == 0 and players.second != null) {
                        self.chooser = 1;
                        self.tap = 0;
                        return .{};
                    }
                    self.enter(.to_play);
                    return .{};
                }
                if (cur.place == want) return self.tapping(self.chooser, .start);
                const other = sel.cursors[1 - k];
                if (players.second != null and !other.chosen and other.place == want) return self.tapping(1 - self.chooser, .right);
                return self.tapping(self.chooser, .right);
            },
            .to_play => {
                if (self.round()) |r| if (r.phase == .play) {
                    self.enter(.body);
                    return null;
                };
                return .{};
            },
            .pads, .body, .done => unreachable,
        }
    }

    /// A tap of `button` on pad `pad`: held `tap_on` display ticks, released `tap_off`, again;
    /// the button and the pad those wanted at the tap's first display tick.
    fn tapping(self: *Run, pad: u1, button: input.Button) input.Pads {
        const phase = self.tap % (tap_on + tap_off);
        self.tap += 1;
        if (phase == 0) {
            self.tap_button = button;
            self.tap_pad = pad;
        }
        if (phase >= tap_on) return .{};
        const bits: u8 = @as(u8, 1) << @backingInt(self.tap_button);
        return if (self.tap_pad == 0) .{ .pad1 = @bitCast(bits) } else .{ .pad2 = @bitCast(bits) };
    }

    /// The trace of the display tick just run.
    fn observe(self: *Run, turn: *const scene.Turn) !void {
        const v: u64 = self.state.tick;
        const traced = tracedScene(&self.state.scenes);
        const top = traced.kind;
        const serial = traced.serial;
        if (self.round()) |r| {
            const name: []const u8 = @tagName(r.trace_scene);
            const tw = self.trace orelse return self.noteIds(&r.play.world);
            // The round's last tick, its fade out over: the sounds asked for then are the next
            // scene's start's, as sor-remaster's trace has them; a next scene whose set-up and
            // load run the sound's driver (the clear's) begins there, as the original's mode.
            if (r.phase == .leaving and r.colours.fade == null) {
                const after = self.state.scenes.next orelse return self.holdSounds(turn);
                if (after.sound_held) return self.holdSounds(turn);
                const next_name = traceName(after.kind);
                tw.startScene(.{ .name = next_name, .round = r.number, .demo = r.demo });
                self.seen_serial = 0;
                self.seen_scene = next_name;
                self.scene_t = 0;
                try tw.atTick(v, 0);
                return self.sounds(turn);
            }
            if (serial != self.seen_serial or !std.mem.eql(u8, name, self.seen_scene)) {
                tw.startScene(.{ .name = name, .round = r.number, .demo = r.demo });
                self.seen_serial = serial;
                self.seen_scene = name;
                self.seen_t = r.trace_t;
                // The demo's first tick after its load is its tick 1: its scene at its tick 0 (its
                // set-up, under the load), then the world.
                if (r.demo) {
                    tw.forgetRound();
                    try tw.atTick(v, 0);
                } else if (r.trace_scene == .round) {
                    // Its tick 0 tells the scene; the world from its tick 1, its camera and
                    // timer written again (as sor-remaster's observer has them).
                    tw.forgetRound();
                    try tw.atTick(v, r.trace_t);
                    return self.sounds(turn);
                }
            } else if (r.trace_t == self.seen_t) {
                // A sound of a logic tick's first display tick (the pause's, as play resumes) is
                // that logic tick's, as sor-remaster's trace counts the tick as it begins.
                if (r.phase == .play and r.play.schedule.into == 1 and turn.requests.len != 0) try tw.atTick(v, r.trace_t + 1);
                try self.sounds(turn);
                return;
            }
            self.seen_t = r.trace_t;
            if (r.trace_scene == .round) tw.setPhase(phaseName(r));
            try tw.observeAt(v, r.trace_t, &r.play.world, &self.content.kinds, &self.out);
            // The sounds its set-up asked for under the load (a life more for the clear's
            // points), with its first observation, as sor-remaster's trace has them.
            for (self.deferred[0..self.deferred_len]) |id| try tw.sceneSound(self.content.sounds.sounds[id].name);
            self.deferred_len = 0;
            try self.sounds(turn);
            self.noteIds(&r.play.world);
            if (self.probe) |p| try p.observe(v, r.trace_t, &r.play.world, &self.content.kinds, &self.ids);
            return;
        }
        const tw = self.trace orelse return;
        const name = traceName(top);
        // A load goes on with the scene before it, its ticks not counted.
        if (name.len == 0) return self.holdSounds(turn);
        if (serial != self.seen_serial and !std.mem.eql(u8, name, self.seen_scene)) {
            tw.startScene(.{ .name = name });
            self.seen_serial = serial;
            self.seen_scene = name;
            self.scene_t = 0;
        } else self.scene_t += 1;
        try tw.atTick(v, self.scene_t);
        for (self.deferred[0..self.deferred_len]) |id| try tw.sceneSound(self.content.sounds.sounds[id].name);
        self.deferred_len = 0;
        try self.sounds(turn);
    }

    /// The sounds of the tick, for the next scene's line (a load's, the round's last tick's).
    fn holdSounds(self: *Run, turn: *const scene.Turn) void {
        for (turn.requests.items[0..turn.requests.len]) |id| {
            if (self.deferred_len == self.deferred.len) break;
            self.deferred[self.deferred_len] = id;
            self.deferred_len += 1;
        }
    }

    /// The sounds the scene asked for at the tick, but those of the world's tick, which its
    /// observation wrote.
    fn sounds(self: *Run, turn: *const scene.Turn) !void {
        const tw = self.trace orelse return;
        var world_sounds: []const world.output.SoundRequest = &.{};
        if (self.round()) |r| if (r.logic_ran) {
            world_sounds = self.out.sounds.slice();
        };
        var skipped: [world.output.Output.sound_most]bool = @splat(false);
        for ([_][]const sorz.library.Sound{ turn.requests_now.slice(), turn.requests.slice() }) |list| {
            next: for (list) |id| {
                const name = self.content.sounds.sounds[id].name;
                for (world_sounds, 0..) |s, i| if (!skipped[i] and std.mem.eql(u8, s.name, name)) {
                    skipped[i] = true;
                    continue :next;
                };
                try tw.sceneSound(name);
            }
        }
    }

    /// The ids of the entities new at this tick, the trace's, for the conditions.
    fn noteIds(self: *Run, w: *const world.World) void {
        for (&w.entities, 0..) |*e, i| {
            if (!e.alive()) {
                self.ids[i] = 0;
                continue;
            }
            const h = w.handleAt(i).?;
            if (w.playerOf(h)) |p| {
                self.ids[i] = @as(u32, p) + 1;
                continue;
            }
            // Asked again each tick: a place freed and taken in the same tick has a new entity.
            if (self.trace) |tw| self.ids[i] = tw.idOf(i, e.generation) orelse 0;
        }
    }

    fn holds(self: *Run, c: scenario.Condition) bool {
        const r = self.round() orelse return switch (c) {
            .scene => |name| std.mem.eql(u8, name, self.sceneName()),
            else => false,
        };
        const w = &r.play.world;
        switch (c) {
            .scene => |name| return std.mem.eql(u8, name, @tagName(r.trace_scene)),
            .phase => |name| return std.mem.eql(u8, name, phaseName(r)),
            .camera => |x| return w.camera.x.whole() >= x,
            .state => |st| {
                for (&w.entities, 0..) |*e, i| {
                    if (!e.alive() or !self.is(i, e, st.who)) continue;
                    const now = world.behaviours.stateName(&e.mind) orelse continue;
                    var found = false;
                    for (st.states[0..st.count]) |name| found = found or std.mem.eql(u8, name, now);
                    if (found != st.negate) return true;
                }
                return false;
            },
            .near => |nr| {
                const ph = w.players[nr.pad].entity orelse return false;
                const p = w.getConst(ph) orelse return false;
                for (&w.entities, 0..) |*e, i| {
                    if (!e.alive() or !self.is(i, e, .{ .kind = nr.kind })) continue;
                    const now = world.behaviours.stateName(&e.mind) orelse "";
                    if (std.mem.eql(u8, now, "appear") or std.mem.eql(u8, now, "knocked_out")) continue;
                    const dx = @abs(e.position.x.whole() - p.position.x.whole());
                    const dd = @abs(e.position.depth.whole() - p.position.depth.whole());
                    if (dx <= nr.across and (nr.depth == null or dd <= nr.depth.?)) return true;
                }
                return false;
            },
        }
    }

    /// Player 1's pad at the script's tick `now` by the bot's rule (`bot TICKS`, sor-remaster's
    /// runner's), from what the round shows: out of play (the continue's question, a screen),
    /// START now and then; holding a foe, the knees; hurt, food lying goes first; else the
    /// nearest enemy or boss out of hiding, which it lines up with in depth, comes to the jab's
    /// reach of from across, faces, and jabs at every other tick; with none, it walks right,
    /// jabbing at a solid thing that stops it.
    pub fn bot(self: *Run, now: u64) input.Pad {
        const r = self.round() orelse return .{ .start = now % 16 == 0 };
        const w = &r.play.world;
        const ph = w.players[0].entity orelse return .{ .start = now % 16 == 0 };
        const p = w.getConst(ph) orelse return .{ .start = now % 16 == 0 };
        if (p.mind != .player) return .{ .start = now % 16 == 0 };
        const px = p.position.x.whole();
        const pd = p.position.depth.whole();
        const left = p.facing == .left;
        const jab = now % 2 == 0;
        const state = world.behaviours.stateName(&p.mind) orelse "";
        if (std.mem.startsWith(u8, state, "grab")) return .{ .b = jab };
        var pad: input.Pad = .{};
        if (p.health < bot_hungry) if (self.nearest(w, px, pd, .food)) |e| {
            const dx = e.position.x.whole() - px;
            const dd = e.position.depth.whole() - pd;
            if (@abs(dd) > 2) {
                pad.up = dd < 0;
                pad.down = dd > 0;
            }
            if (@abs(dx) > 6) {
                pad.left = dx < 0;
                pad.right = dx > 0;
            }
            if (@as(u8, @bitCast(pad)) == 0) pad.b = jab;
            return pad;
        };
        const foe = self.nearest(w, px, pd, .foe) orelse {
            // No foe: right, but a solid thing ahead at its depth stops the walk, and is jabbed.
            for (&w.entities) |*e| {
                if (!e.alive() or !e.flags.solid or e.flags.hidden) continue;
                const dx = e.position.x.whole() - px;
                if (dx >= 0 and dx <= bot_blocked and @abs(e.position.depth.whole() - pd) <= bot_blocked_depth and !left) return .{ .b = jab };
            }
            return .{ .right = true };
        };
        const dx = foe.position.x.whole() - px;
        const dd = foe.position.depth.whole() - pd;
        if (@abs(dd) > bot_level) {
            pad.up = dd < 0;
            pad.down = dd > 0;
        }
        if (@abs(dx) > bot_reach) {
            pad.left = dx < 0;
            pad.right = dx > 0;
        } else if (@abs(dx) < bot_close) {
            pad.right = dx < 0;
            pad.left = dx >= 0;
        } else if ((dx < 0) != left) {
            pad.left = dx < 0;
            pad.right = dx >= 0;
        } else if (@as(u8, @bitCast(pad)) == 0) pad.b = jab;
        return pad;
    }

    /// The nearest entity (across plus in depth) the bot looks for: an enemy or a boss out of
    /// hiding with health left, or food lying.
    fn nearest(self: *const Run, w: *const world.World, px: i32, pd: i32, what: enum { foe, food }) ?*const world.Entity {
        var best: ?*const world.Entity = null;
        var best_d: u32 = std.math.maxInt(u32);
        for (&w.entities) |*e| {
            if (!e.alive() or e.flags.hidden) continue;
            const k = self.content.kinds.get(e.kind.?);
            switch (what) {
                .foe => {
                    const f = k.family();
                    if (f != .enemy and f != .boss) continue;
                    if (e.health < 0) continue;
                    const now = world.behaviours.stateName(&e.mind) orelse "";
                    if (std.mem.eql(u8, now, "appear") or std.mem.eql(u8, now, "knocked_out")) continue;
                },
                .food => if (!std.mem.eql(u8, k.name(), "apple") and !std.mem.eql(u8, k.name(), "beef")) continue,
            }
            const d = @abs(e.position.x.whole() - px) + @abs(e.position.depth.whole() - pd);
            if (d < best_d) {
                best_d = d;
                best = e;
            }
        }
        return best;
    }

    /// The scene as the traces name it, a load's the one it holds (sor-remaster's runner sees the
    /// original's mode, which the load's set-up set).
    fn sceneName(self: *const Run) []const u8 {
        return switch (self.state.scenes.base) {
            .round, .demo => |*r| @tagName(r.trace_scene),
            else => |k| traceName(std.meta.activeTag(k)),
        };
    }

    fn is(self: *const Run, i: usize, e: *const world.Entity, who: scenario.Who) bool {
        return switch (who) {
            .id => |id| self.ids[i] == id,
            // By its name, or the traces' (the scripts run in both programs).
            .kind => |k| std.mem.eql(u8, self.content.kinds.get(e.kind.?).name(), k) or std.mem.eql(u8, self.content.kinds.get(e.kind.?).tracedName(), k),
        };
    }
};

/// Play's phase as the traces name it.
fn phaseName(r: *const scene.Round) []const u8 {
    return switch (r.phase) {
        .play => if (r.play.world.special) "special" else "play",
        .paused => "paused",
        .time_over => "time_up",
        .leaving => "leaving",
        else => "intro",
    };
}

/// A scene as sor-remaster's traces name it (a load keeps the scene before it).
/// The scene the trace names at this tick: the top one; under a load during which the sound's
/// driver runs (the round's clear's: its set-up leaves the interrupts on), the scene it holds,
/// begun with it (sor-remaster's trace names it from the load's first tick).
fn tracedScene(s: *scene.Stack) struct { kind: scene.Kind, serial: u32 } {
    switch (s.top()) {
        .overlay => |o| if (o.* == .load and !o.load.sound_held and s.overlay_count == 1) return .{ .kind = std.meta.activeTag(s.base), .serial = s.base_serial },
        .scene => {},
    }
    return .{ .kind = s.topKind(), .serial = s.topSerial() };
}

fn traceName(k: scene.Kind) []const u8 {
    return switch (k) {
        .load, .test_pattern => "",
        else => @tagName(k),
    };
}

/// The bot's rule's distances (sor-remaster's runner's): the depth within which it is level with
/// its foe, the reach it jabs from across (its jab's), the least across it keeps; the health
/// under which food comes first; how far ahead across and in depth a solid thing stops its walk.
const bot_level = 3;
const bot_reach = 34;
const bot_close = 14;
const bot_hungry = 40;
const bot_blocked = 48;
const bot_blocked_depth = 12;

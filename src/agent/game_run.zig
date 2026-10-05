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
//! tick `t` the round's), the scenes' sounds. The runner reads the game's state and never writes
//! it.
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
    /// The display tick of the body's tick 0.
    body_v: ?u64 = null,
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

    const Stage = enum { to_menu, menu, select_wait, select, to_play, pads, body, done };

    /// `pads`: a recorded play's (the script's start is `start pads`).
    pub fn init(content: *const library.Content, assets: *const scene.Assets, script: *const scenario.Script, pads: []const input.Pads, trace: ?*world.trace.Writer) Run {
        return .{
            .content = content,
            .assets = assets,
            .script = script,
            .pads = pads,
            .state = .powerOn(&sorz.flow.original),
            .body = .{ .commands = script.commands },
            .trace = trace,
            .stage = switch (script.start) {
                .players => .to_menu,
                .pads => .pads,
            },
        };
    }

    /// One display tick: the pads, the game's tick, the trace. False when the run is over.
    pub fn step(self: *Run) !bool {
        if (self.stage == .done) return false;
        const pads = self.next() orelse return false;
        const turn = self.state.stepWith(pads, true, self.assets, &self.out);
        if (self.trace) |tw| tw.held = .{ pads.pad1, pads.pad2 };
        try self.observe(&turn);
        return true;
    }

    /// The round scene, when it is the game's scene (no overlay over it).
    fn round(self: *Run) ?*scene.Round {
        const s = self.topScene() orelse return null;
        return switch (s.*) {
            .round => |*r| r,
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
        // A logic tick starts at the next display tick (a screen's: each): the script's commands,
        // then its pads.
        const starts = if (self.round()) |r| r.phase != .play or r.play.schedule.into == 0 else true;
        if (!starts) return self.current;
        if (self.body_v == null) self.body_v = self.state.tick;
        self.current = self.body.tick(self, holds) orelse {
            if (self.body.timed_out != null) self.failure = "a condition did not come in time";
            self.stage = .done;
            return null;
        };
        return self.current;
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
        const top = self.state.scenes.topKind();
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
                const s = self.topScene() orelse return .{};
                const m = switch (s.*) {
                    .menu => |*m| m,
                    else => return .{},
                };
                const want: sorz.screens.menu.Line = if (players.second != null) .two_players else .one_player;
                if (@backingInt(m.choice) > @backingInt(want)) return self.fail("the menu's arrow went past 2 PLAYERS");
                return self.tapping(0, if (m.choice != want) .down else .start);
            },
            .select_wait => {
                if (self.in_stage < 60) return .{};
                self.enter(.select);
                self.chooser = 0;
                return .{};
            },
            .select => {
                const s = self.topScene() orelse return self.fail("the character select ended before the choice");
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
        const top = self.state.scenes.topKind();
        const serial = self.state.scenes.topSerial();
        if (self.round()) |r| {
            const name: []const u8 = @tagName(r.trace_scene);
            const tw = self.trace orelse return self.noteIds(&r.play.world);
            // The round's last tick, its fade out over: the sounds asked for then are the next
            // scene's start's, as sor-remaster's trace has them.
            if (r.phase == .leaving and r.colours.fade == null) return self.holdSounds(turn);
            if (serial != self.seen_serial or !std.mem.eql(u8, name, self.seen_scene)) {
                tw.startScene(.{ .name = name, .round = r.number, .demo = false });
                self.seen_serial = serial;
                self.seen_scene = name;
                self.seen_t = r.trace_t;
                if (r.trace_scene == .round) {
                    // Its tick 0 tells the scene; the world from its tick 1, its camera and
                    // timer written again (as sor-remaster's observer has them).
                    tw.forgetRound();
                    try tw.atTick(v, r.trace_t);
                    return self.sounds(turn);
                }
            } else if (r.trace_t == self.seen_t) {
                try self.sounds(turn);
                return;
            }
            self.seen_t = r.trace_t;
            if (r.trace_scene == .round) tw.setPhase(phaseName(r));
            try tw.observeAt(v, r.trace_t, &r.play.world, &self.content.kinds, &self.out);
            try self.sounds(turn);
            self.noteIds(&r.play.world);
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
        next: for (turn.requests.items[0..turn.requests.len]) |id| {
            const name = self.content.sounds.sounds[id].name;
            for (world_sounds, 0..) |s, i| if (!skipped[i] and std.mem.eql(u8, s.name, name)) {
                skipped[i] = true;
                continue :next;
            };
            try tw.sceneSound(name);
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
            if (self.ids[i] != 0) continue;
            if (self.trace) |tw| self.ids[i] = tw.idOf(i, e.generation) orelse 0;
        }
    }

    fn holds(self: *Run, c: scenario.Condition) bool {
        const r = self.round() orelse return switch (c) {
            .scene => |name| std.mem.eql(u8, name, traceName(self.state.scenes.topKind())),
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

    fn is(self: *const Run, i: usize, e: *const world.Entity, who: scenario.Who) bool {
        return switch (who) {
            .id => |id| self.ids[i] == id,
            .kind => |k| std.mem.eql(u8, self.content.kinds.get(e.kind.?).name(), k),
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
fn traceName(k: scene.Kind) []const u8 {
    return switch (k) {
        .load, .test_pattern => "",
        else => @tagName(k),
    };
}

//! Scenarios (sor-remaster's docs/scenarios.md, the same files): a start that reaches a
//! situation, then a script of timed pad events in the game's terms, which the agent host runs
//! (`--scenario FILE`) and traces (`--trace-events`, `--probe`). The runner decides each logic
//! tick's pads from the script and from what the world shows; it reads the world and never
//! writes it, so that a scenario's run is a run of the game with those pads.
//!
//! The start: until the round's scene plays round 1 from its content (PLAN items 08 and 13),
//! `start CHARACTER` takes up round 1 where another program's trace was when its play began
//! (`--situation TRACE`, sor-remaster's trace of the same scenario: DESIGN.md decision D14, a
//! converted starting state): the camera, the ground, the player dropping in, the enemies that
//! wait for their turn, with the trace's ids. The script then runs from the next tick, as in
//! sor-remaster, whose script's tick 0 is the tick after play's phase began. `start pads FILE V`
//! (a recorded play's first V display ticks) takes up round 1 where the trace was at the end of
//! the logic tick that holds display tick V: every entity then, in its state, with the place the
//! round's script gave each enemy (`rounds/round1.json`'s records: its way in, its traits, its
//! offset), the random generator as the trace's draws left it, and the round's clock as the
//! other program counts it (`--game-tick`: its tick counter at the script's start).
const std = @import("std");
const sorz = @import("sorz");
const world = sorz.world;
const input = sorz.input;
const content = sorz.content;

/// A button by its use in play (the default controls: B attacks, C jumps, A is the special
/// attack), by its bit in `input.Pad`.
pub const Button = enum(u3) {
    up = 0,
    down = 1,
    left = 2,
    right = 3,
    special = 4,
    attack = 5,
    jump = 6,
    start = 7,
};

comptime {
    for (std.enums.values(Button)) |b| {
        const pad_name = switch (b) {
            .special => "a",
            .attack => "b",
            .jump => "c",
            else => @tagName(b),
        };
        std.debug.assert(@bitOffsetOf(input.Pad, pad_name) == @backingInt(b));
    }
}

pub const Start = union(enum) {
    /// One player (or two) of these characters, from the start of play in round `round` (2 to 8:
    /// the options' hidden first round set first, opened by pad 2's code as the menu leaves for
    /// the options).
    players: struct { first: []const u8, second: ?[]const u8, round: u8 = 1 },
    /// A recorded play's pads (a line per display tick from power-on: pad 1's and pad 2's
    /// buttons in hexadecimal, sor-remaster's `--pads` format), for its first `vblanks` display
    /// ticks; the file is named from the scenario's directory.
    pads: struct { path: []const u8, vblanks: u64 },
    /// Nothing: the script's ticks are the game's from its first display tick (the screens by
    /// hand, the attract demo).
    power_on,
};

/// The pads of a recorded play's file (`start pads`); null for a malformed line.
pub fn parsePads(gpa: std.mem.Allocator, text: []const u8) !?[]input.Pads {
    var out: std.ArrayList(input.Pads) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const p1 = std.fmt.parseInt(u16, it.next() orelse return null, 16) catch return null;
        const p2 = std.fmt.parseInt(u16, it.next() orelse return null, 16) catch return null;
        if (it.next() != null) return null;
        try out.append(gpa, .{ .pad1 = @bitCast(@as(u8, @truncate(p1))), .pad2 = @bitCast(@as(u8, @truncate(p2))) });
    }
    return try out.toOwnedSlice(gpa);
}

/// Who a condition is about: an entity of the trace by its id, or any entity of a kind.
pub const Who = union(enum) {
    id: u32,
    kind: []const u8,
};

pub const max_states = 8;

pub const Condition = union(enum) {
    scene: []const u8,
    phase: []const u8,
    /// An entity in one of the states (or, negated, in none of them).
    state: struct { who: Who, states: [max_states][]const u8, count: u8, negate: bool },
    /// An entity of the kind, out of hiding and not knocked out, within `across` pixels of the
    /// pad's player across, and `depth` in depth (any when null).
    near: struct { kind: []const u8, across: i32, depth: ?i32, pad: u1 },
    /// The camera's left edge at or past `x` pixels.
    camera: i32,
};

pub const Command = struct {
    line: u32,
    op: union(enum) {
        /// The buttons held `ticks` ticks, then released for one: the script goes on after both.
        press: struct { pad: u1, buttons: u8, ticks: u32 },
        /// The buttons held from now (for `ticks` when given): the script goes on at once.
        hold: struct { pad: u1, buttons: u8, ticks: ?u32 },
        release: struct { pad: u1, buttons: u8 },
        wait: u32,
        until: struct { cond: Condition, within: u32 },
        /// Player 1 played `bot` ticks by the bot's rule (the context's `bot`, as sor-remaster's
        /// runner's): the script goes on after.
        bot: u32,
    },
};

pub const Diagnostic = struct {
    line: u32 = 0,
    message: []const u8 = "",
};

pub const Script = struct {
    start: Start,
    commands: []Command,

    pub fn deinit(self: *Script, gpa: std.mem.Allocator) void {
        gpa.free(self.commands);
    }
};

/// The longest wait of an `until` without `within`, in ticks.
pub const default_within = 3000;

/// The script of `text`, whose names point into `text` (it must outlive the script).
pub fn parse(gpa: std.mem.Allocator, text: []const u8, diag: *Diagnostic) !Script {
    var commands: std.ArrayList(Command) = .empty;
    errdefer commands.deinit(gpa);
    var start: ?Start = null;
    var pad: u1 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 0;
    while (lines.next()) |raw| {
        n += 1;
        const code = if (std.mem.indexOfScalar(u8, raw, '#')) |k| raw[0..k] else raw;
        var words: [8][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, code, " \t\r");
        while (it.next()) |word| {
            if (count == words.len) return refuse(diag, n, "too many words");
            words[count] = word;
            count += 1;
        }
        if (count == 0) continue;
        const w = words[0..count];
        if (std.mem.eql(u8, w[0], "start")) {
            if (start != null or commands.items.len != 0) return refuse(diag, n, "the start comes first, once");
            if (w.len == 2 and std.mem.eql(u8, w[1], "power-on")) {
                start = .power_on;
                continue;
            }
            if (w.len == 4 and std.mem.eql(u8, w[1], "pads")) {
                start = .{ .pads = .{ .path = w[2], .vblanks = number(w[3]) orelse return refuse(diag, n, "`start pads FILE VBLANKS`") } };
                continue;
            }
            var who = w[1..];
            var round: u8 = 1;
            if (who.len >= 3 and std.mem.eql(u8, who[who.len - 2], "round")) {
                const r = number(who[who.len - 1]) orelse 0;
                if (r < 1 or r > 8) return refuse(diag, n, "a round is 1 to 8");
                round = @intCast(r);
                who = who[0 .. who.len - 2];
            }
            if (who.len < 1 or who.len > 2) return refuse(diag, n, "a start is `start CHARACTER [CHARACTER] [round N]`, `start pads FILE VBLANKS` or `start power-on`");
            start = .{ .players = .{ .first = who[0], .second = if (who.len == 2) who[1] else null, .round = round } };
            continue;
        }
        if (start == null) return refuse(diag, n, "the script begins with its start");
        if (std.mem.eql(u8, w[0], "pad")) {
            if (count != 2) return refuse(diag, n, "`pad 1` or `pad 2`");
            pad = if (std.mem.eql(u8, w[1], "1")) 0 else if (std.mem.eql(u8, w[1], "2")) 1 else return refuse(diag, n, "`pad 1` or `pad 2`");
            continue;
        }
        if (std.mem.eql(u8, w[0], "wait")) {
            if (count != 2) return refuse(diag, n, "`wait TICKS`");
            const t = number(w[1]) orelse return refuse(diag, n, "a wait is a number of ticks");
            try commands.append(gpa, .{ .line = n, .op = .{ .wait = t } });
            continue;
        }
        if (std.mem.eql(u8, w[0], "bot")) {
            if (count != 2) return refuse(diag, n, "`bot TICKS`");
            const t = number(w[1]) orelse return refuse(diag, n, "a bot plays a number of ticks");
            try commands.append(gpa, .{ .line = n, .op = .{ .bot = t } });
            continue;
        }
        if (std.mem.eql(u8, w[0], "until")) {
            var rest = w[1..];
            var within: u32 = default_within;
            if (rest.len >= 2 and std.mem.eql(u8, rest[rest.len - 2], "within")) {
                within = number(rest[rest.len - 1]) orelse return refuse(diag, n, "`within TICKS`");
                rest = rest[0 .. rest.len - 2];
            }
            const cond = parseCondition(rest, pad) orelse return refuse(diag, n, "a condition is `scene NAME`, `phase NAME`, `state WHO STATE[|STATE...]` (`!` before: none of them), `near KIND PIXELS [DEPTH]` or `camera PIXELS`");
            try commands.append(gpa, .{ .line = n, .op = .{ .until = .{ .cond = cond, .within = within } } });
            continue;
        }
        const first = w[0];
        const kind: enum { press, hold, release } = if (first[0] == '+') .hold else if (first[0] == '-') .release else .press;
        const list = if (kind == .press) first else first[1..];
        const buttons = parseButtons(list) orelse return refuse(diag, n, "an unknown command or button (up, down, left, right, attack, jump, special, start; joined by +)");
        if (count > 2 or (kind == .release and count != 1)) return refuse(diag, n, "`BUTTONS [TICKS]`, `+BUTTONS [TICKS]` or `-BUTTONS`");
        const ticks: ?u32 = if (count == 2) number(w[1]) orelse return refuse(diag, n, "a number of ticks") else null;
        if (ticks != null and ticks.? == 0) return refuse(diag, n, "at least one tick");
        try commands.append(gpa, .{ .line = n, .op = switch (kind) {
            .press => .{ .press = .{ .pad = pad, .buttons = buttons, .ticks = ticks orelse 1 } },
            .hold => .{ .hold = .{ .pad = pad, .buttons = buttons, .ticks = ticks } },
            .release => .{ .release = .{ .pad = pad, .buttons = buttons } },
        } });
    }
    return .{ .start = start orelse return refuse(diag, n, "no start"), .commands = try commands.toOwnedSlice(gpa) };
}

fn refuse(diag: *Diagnostic, line: u32, message: []const u8) error{BadScenario} {
    diag.* = .{ .line = line, .message = message };
    return error.BadScenario;
}

fn number(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn parseButtons(text: []const u8) ?u8 {
    if (text.len == 0) return null;
    var bits: u8 = 0;
    var it = std.mem.splitScalar(u8, text, '+');
    while (it.next()) |name| {
        const b = std.meta.stringToEnum(Button, name) orelse return null;
        bits |= @as(u8, 1) << @backingInt(b);
    }
    return bits;
}

fn parseCondition(w: []const []const u8, pad: u1) ?Condition {
    if (w.len == 0) return null;
    if (std.mem.eql(u8, w[0], "scene") and w.len == 2) return .{ .scene = w[1] };
    if (std.mem.eql(u8, w[0], "phase") and w.len == 2) return .{ .phase = w[1] };
    if (std.mem.eql(u8, w[0], "camera") and w.len == 2) return .{ .camera = @intCast(number(w[1]) orelse return null) };
    if (std.mem.eql(u8, w[0], "near") and (w.len == 3 or w.len == 4)) {
        const across = number(w[2]) orelse return null;
        const depth: ?i32 = if (w.len == 4) @intCast(number(w[3]) orelse return null) else null;
        return .{ .near = .{ .kind = w[1], .across = @intCast(across), .depth = depth, .pad = pad } };
    }
    if (std.mem.eql(u8, w[0], "state") and w.len == 3) {
        const who: Who = if (number(w[1])) |id| .{ .id = id } else .{ .kind = w[1] };
        var list = w[2];
        const negate = list[0] == '!';
        if (negate) list = list[1..];
        var states: [max_states][]const u8 = undefined;
        var count: u8 = 0;
        var it = std.mem.splitScalar(u8, list, '|');
        while (it.next()) |name| {
            if (name.len == 0 or count == max_states) return null;
            states[count] = name;
            count += 1;
        }
        return .{ .state = .{ .who = who, .states = states, .count = count, .negate = negate } };
    }
    return null;
}

/// The script's body: the commands run at each tick's start, and the buttons they hold.
pub const Body = struct {
    commands: []const Command,
    /// The ticks since the body began, at the tick under way.
    now: u64 = 0,
    pc: usize = 0,
    resume_at: u64 = 0,
    waiting: ?struct { cond: Condition, deadline: u64, line: u32 } = null,
    /// By pad and button, the tick at which a hold ends (`forever` until released), or null.
    holds: [2][8]?u64 = @splat(@splat(null)),
    /// The line of the condition that did not come in time.
    timed_out: ?u32 = null,
    /// The ticks left to the bot's play (`bot TICKS`).
    bot_left: u64 = 0,

    const forever = std.math.maxInt(u64);

    /// At the start of tick `now` (from 0, one more at each call): the commands due, then the
    /// pads to hold over the tick; null when the script is done (or a condition timed out).
    /// `holds_fn(ctx, cond)` tells whether a condition holds at the last tick's end.
    pub fn tick(self: *Body, ctx: anytype, comptime holds_fn: fn (@TypeOf(ctx), Condition) bool) ?input.Pads {
        for (&self.holds) |*pad| for (pad) |*h| {
            if (h.* != null and h.*.? <= self.now) h.* = null;
        };
        while (true) {
            if (self.waiting) |w| {
                if (!holds_fn(ctx, w.cond)) {
                    if (self.now >= w.deadline) {
                        self.timed_out = w.line;
                        return null;
                    }
                    break;
                }
                self.waiting = null;
            }
            if (self.now < self.resume_at) break;
            if (self.pc == self.commands.len) {
                if (self.timedHolds()) break;
                return null;
            }
            const c = self.commands[self.pc];
            self.pc += 1;
            switch (c.op) {
                .press => |p| {
                    self.set(p.pad, p.buttons, self.now + p.ticks);
                    self.resume_at = self.now + p.ticks + 1;
                },
                .hold => |h| self.set(h.pad, h.buttons, if (h.ticks) |t| self.now + t else forever),
                .release => |r| self.set(r.pad, r.buttons, null),
                .wait => |t| self.resume_at = self.now + t,
                .until => |u| self.waiting = .{ .cond = u.cond, .deadline = self.now + u.within, .line = c.line },
                .bot => |t| {
                    self.bot_left = t;
                    self.resume_at = self.now + t;
                },
            }
        }
        var held = self.pads();
        if (self.bot_left != 0) {
            self.bot_left -= 1;
            const Ctx = switch (@typeInfo(@TypeOf(ctx))) {
                .pointer => |ptr| ptr.child,
                else => @TypeOf(ctx),
            };
            const has = switch (@typeInfo(Ctx)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(Ctx, "bot"),
                else => false,
            };
            if (has) held.pad1 = ctx.bot(self.now);
        }
        self.now += 1;
        return held;
    }

    fn set(self: *Body, pad: u1, buttons: u8, until: ?u64) void {
        for (0..8) |b| if (buttons >> @intCast(b) & 1 != 0) {
            self.holds[pad][b] = until;
        };
    }

    fn timedHolds(self: *const Body) bool {
        for (self.holds) |pad| for (pad) |h| if (h != null and h.? != forever) return true;
        return false;
    }

    pub fn pads(self: *const Body) input.Pads {
        var bits: [2]u8 = .{ 0, 0 };
        for (self.holds, 0..) |pad, k| for (pad, 0..) |h, b| {
            if (h != null) bits[k] |= @as(u8, 1) << @intCast(b);
        };
        return .{ .pad1 = @bitCast(bits[0]), .pad2 = @bitCast(bits[1]) };
    }
};

// The situation ----------------------------------------------------------------------------------

/// Where a round's play began in another program's trace: its scene's ticks, the camera, and
/// each entity then (as the trace knows it: its kind, id, place, speed, state, side, health).
pub const Situation = struct {
    /// The display tick and the scene's tick of the situation (play's start, or the tick asked).
    v: u64,
    t: u64,
    round: u8 = 1,
    camera: [2]i32 = .{ 0, 0 },
    camera_stop: [3]i32 = .{ 0, 0, 0 },
    lives: [2][2]u8 = .{ .{ 0, 0 }, .{ 0, 0 } },
    scores: [2]u32 = .{ 0, 0 },
    /// The players' pads as last read by then (their next read's presses are new against them).
    pads: [2]sorz.input.Pad = .{ .{}, .{} },
    next_id: u32 = 3,
    /// The random generator's draws from power-on, and whether its state was set otherwise
    /// (then `last_values` are the last tick's first draws, which tell its state).
    draws: u64 = 0,
    reseeded: bool = false,
    last_values: []const u16 = &.{},
    last_count: u32 = 0,
    /// After a seed set otherwise with no draws before the situation: the first draws after it,
    /// which tell the state it holds until then.
    next_values: []const u16 = &.{},
    special: bool = false,
    /// Round 8's room's script runs (the phase `script`): taken up in its fight.
    script: bool = false,
    /// The round's timer as it last counted or started before the situation: its seconds and
    /// the scene's tick of that count.
    timer: ?Count = null,
    entities: []const Seen,
    /// The round scene's events that the round's script follows, to the situation: the camera,
    /// its walls, play's phases, the sections, the entities that came and went.
    history: []const Step = &.{},
    /// The players' places across (whole pixels) from the round scene's start, by tick: when a
    /// shutter opened (it opens as its player comes near) is read from them.
    players_x: []const PlayerX = &.{},
    /// The enemies and things the round's script brings after the situation, at their ticks,
    /// in the order they came (a stand-in for the round's script: PLAN item 13).
    later: []const Later = &.{},
    /// The other things the other program made after the situation, by tick: the ids of the
    /// kinds the world does not make (sor-remaster's hit sparks) are not the world's.
    others: []const Other = &.{},
    /// Player 2 joining after the situation (PRESS 2UP START): the tick the other program
    /// dropped it in at, its character and its lives (the join's timing is the round screen's,
    /// round-check's to compare).
    join: ?Join = null,

    pub const Later = struct { t: u64, seen: Seen };
    pub const Join = struct { t: u64, kind: []const u8, lives: u8 = 0 };
    pub const Step = struct {
        t: u64,
        what: union(enum) {
            camera: i32,
            wall: i32,
            special: bool,
            section: u8,
            spawn: struct { id: u32, kind: []const u8, x: i32, depth: i32 },
            /// An enemy came out of hiding (its state left `appear`).
            appear: u32,
            /// It went, knocked out or not.
            remove: struct { id: u32, knocked_out: bool },
            /// Mr. X seated ended a laugh (round 8's room: his laughs bring its fight's waves).
            laughed,
            /// Round 8's room began (Mr. X seated came): the corridor's last section cleared.
            room_begun,
        },
    };
    pub const Other = struct { t: u64, id: u32, kind: []const u8 };
    pub const Count = struct { seconds: u8, t: u64 };
    pub const PlayerX = struct { t: u64, x: i32 };

    pub const Seen = struct {
        id: u32,
        kind: []const u8,
        player: ?u8 = null,
        position: [3]i32 = .{ 0, 0, 0 },
        velocity: [3]i32 = .{ 0, 0, 0 },
        state: ?[]const u8 = null,
        left: bool = false,
        health: ?i32 = null,
        /// Where it appeared, and the kind it was before a change (an armed Galsia's).
        spawned_at: [2]i32 = .{ 0, 0 },
        was_kind: ?[]const u8 = null,
        /// The states it has been in, joined by spaces; the scene's tick its state began at, the
        /// state it came from, and the players' depths then (whole pixels, by player).
        states: []const u8 = "",
        since: u64 = 0,
        came_from: ?[]const u8 = null,
        players_depth: [2]?i32 = .{ null, null },
        /// The id of the last one whose blow cost it health; the tick its own blow last cost
        /// another's (up to the situation's next tick, which tells of a blow struck at its own).
        struck_by: ?u32 = null,
        struck_at: ?u64 = null,
        /// A blow that met it at the situation's tick (the trace tells its damage at the next):
        /// who struck, and the damage.
        met_by: ?u32 = null,
        met_damage: i32 = 0,
        landed: ?u64 = null,
        /// A weapon's or an item's: who picked it up last, and how many times it was.
        holder: ?u32 = null,
        taken: u8 = 0,
        /// The frame of its animation at the situation's tick and the tick it began showing, as
        /// the other program's probe tells them (`framesOf`); the original's number of the
        /// animation, when the probe gives one, and the tick it began.
        frame: ?u8 = null,
        frame_since: u64 = 0,
        anim: ?u16 = null,
        anim_since: u64 = 0,
        /// The other program's place for it (its object slot), which the order of updates
        /// follows.
        slot: ?u8 = null,
        /// A player's: the ticks of the pads that newly pressed B in its state, and of its last
        /// press; each is seen by its think `press_lag` ticks later (a press read in the logic
        /// tick's first display tick at once, in its second at the next tick: the trace tells
        /// the tick alone), as the press that began its state was (none: the next tick).
        presses: []const u64 = &.{},
        last_press: ?u64 = null,
        press_lag: u64 = 1,
        /// The tick its speed became what it is, and the last random draws by then (perhaps
        /// another's); the bounces it made in its state (its speed down turned up).
        course_since: u64 = 0,
        course_draws: []const u16 = &.{},
        /// The tick its speed across became what it is.
        across_since: u64 = 0,
        /// A player's: the tick it last got up (its blinking starts then); its knees in the hold
        /// it is in.
        got_up_at: ?u64 = null,
        knees: u8 = 0,
        bounces: u8 = 0,
    };
};

/// The situation of a sor-trace at its round scene's first `phase play`, or at the end of the
/// logic tick that holds display tick `at` (then in play): the events before it (from power-on)
/// replayed for what they say of the entities, the camera, the players and the random draws.
pub fn situationOf(arena: std.mem.Allocator, trace_text: []const u8, at: ?u64) !Situation {
    var seen: std.AutoArrayHashMapUnmanaged(u32, Situation.Seen) = .empty;
    var players_x: std.ArrayList(Situation.PlayerX) = .empty;
    var s: Situation = .{ .v = 0, .t = 0, .entities = &.{} };
    var in_round = false;
    var playing = false;
    var last: ?struct { v: u64, t: u64 } = null;
    // The players' pads at their last read (B held), by player.
    var held_b: [2]bool = .{ false, false };
    // The players' depths (whole pixels) as last seen, by player.
    var players_depth: [2]?i32 = .{ null, null };
    // The last tick's random draws.
    var draws_t: u64 = 0;
    // The round scene's steps for the round's script (and its intro's, as the round's start).
    var history: std.ArrayList(Situation.Step) = .empty;
    var intro = false;
    var draws_values: []const u16 = &.{};
    var lines = std.mem.splitScalar(u8, trace_text, '\n');
    // The first line after the situation, which the spawns after it start from.
    var after: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return error.BadTrace;
        if (v != .object) return error.BadTrace;
        const o = v.object;
        const ev = str(o, "ev") orelse return error.BadTrace;
        if (std.mem.eql(u8, ev, "begin")) {
            // A trace begun from a reference, not from power-on: its draws do not count from
            // the generator's first state, which its last draws tell instead.
            if (str(o, "start")) |st| if (std.mem.eql(u8, st, "reference")) {
                s.reseeded = true;
            };
            continue;
        }
        if (std.mem.eql(u8, ev, "end")) break;
        if (at) |limit| {
            const ev_v: u64 = @intCast(int(o, "v") orelse 0);
            if (ev_v > limit) {
                if (!in_round or !playing) return error.NoPlay;
                after = line;
                break;
            }
            if (in_round) last = .{ .v = ev_v, .t = @intCast(int(o, "t") orelse 0) };
        }
        if (std.mem.eql(u8, ev, "rng")) {
            const count: u32 = @intCast(int(o, "draws") orelse 0);
            s.draws += count;
            if (o.get("reseed")) |r| if (r == .bool and r.bool) {
                s.reseeded = true;
            };
            if (o.get("values")) |vals| if (vals == .array) {
                const out = try arena.alloc(u16, vals.array.items.len);
                for (out, vals.array.items) |*x, y| x.* = @intCast(y.integer);
                s.last_values = out;
                s.last_count = count;
                draws_t = @intCast(int(o, "t") orelse 0);
                draws_values = out;
            };
            continue;
        }
        const ev_t: u64 = @intCast(int(o, "t") orelse 0);
        if (std.mem.eql(u8, ev, "scene")) {
            in_round = std.mem.eql(u8, str(o, "scene") orelse "", "round");
            if (in_round) s.round = @intCast(int(o, "round") orelse 1);
            // The round's intro brings the first section's placed: the round's start.
            if (!in_round) history.clearRetainingCapacity();
            intro = std.mem.eql(u8, str(o, "scene") orelse "", "round_intro");
            playing = false;
            s.timer = null;
        } else if (std.mem.eql(u8, ev, "section")) {
            if (in_round) try history.append(arena, .{ .t = ev_t, .what = .{ .section = @intCast(int(o, "section") orelse 0) } });
        } else if (std.mem.eql(u8, ev, "spawn")) {
            const e: u32 = @intCast(int(o, "e") orelse return error.BadTrace);
            const x: i32 = @intCast(int(o, "x") orelse 0);
            const d: i32 = @intCast(int(o, "d") orelse 0);
            const state = if (str(o, "state")) |st| try arena.dupe(u8, st) else null;
            try seen.put(arena, e, .{
                .id = e,
                .kind = try arena.dupe(u8, str(o, "kind") orelse return error.BadTrace),
                .player = if (int(o, "player")) |p| @intCast(p) else null,
                .position = .{ x, d, @intCast(int(o, "h") orelse 0) },
                .velocity = .{ @intCast(int(o, "vx") orelse 0), @intCast(int(o, "vd") orelse 0), @intCast(int(o, "vh") orelse 0) },
                .state = state,
                .left = if (str(o, "facing")) |f| std.mem.eql(u8, f, "left") else false,
                .health = if (int(o, "health")) |h| @intCast(h) else null,
                .spawned_at = .{ x >> 16, d >> 16 },
                .states = state orelse "",
                .since = @intCast(int(o, "t") orelse 0),
                .course_since = @intCast(int(o, "t") orelse 0),
                .slot = if (int(o, "_slot")) |sl| @intCast(sl) else null,
            });
            s.next_id = @max(s.next_id, e + 1);
            const own = scripted(seen.get(e).?.kind) and !(std.mem.eql(u8, seen.get(e).?.kind, "breakable") and !std.mem.eql(u8, state orelse "", "s0"));
            if ((in_round or intro) and own) try history.append(arena, .{ .t = if (intro) 0 else ev_t, .what = .{ .spawn = .{ .id = e, .kind = seen.get(e).?.kind, .x = x >> 16, .depth = d >> 16 } } });
            if (in_round and std.mem.eql(u8, seen.get(e).?.kind, room_begins)) try history.append(arena, .{ .t = ev_t, .what = .room_begun });
        } else if (std.mem.eql(u8, ev, "remove")) {
            const e: u32 = @intCast(int(o, "e") orelse return error.BadTrace);
            const knocked_out = if (seen.get(e)) |x| std.mem.eql(u8, x.state orelse "", "knocked_out") else false;
            _ = seen.orderedRemove(e);
            if (in_round) try history.append(arena, .{ .t = ev_t, .what = .{ .remove = .{ .id = e, .knocked_out = knocked_out } } });
        } else if (std.mem.eql(u8, ev, "morph")) {
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            x.was_kind = x.kind;
            x.kind = try arena.dupe(u8, str(o, "kind") orelse return error.BadTrace);
        } else if (std.mem.eql(u8, ev, "state")) {
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            const state = str(o, "state") orelse return error.BadTrace;
            if (in_round and x.player == null and std.mem.eql(u8, x.state orelse "", "appear") and !std.mem.eql(u8, state, "appear")) {
                try history.append(arena, .{ .t = @intCast(int(o, "t") orelse 0), .what = .{ .appear = @intCast(int(o, "e") orelse 0) } });
            }
            if (in_round and std.mem.eql(u8, x.kind, "mr_x_seated") and std.mem.eql(u8, x.state orelse "", laughed_state) and !std.mem.eql(u8, state, laughed_state)) {
                try history.append(arena, .{ .t = @intCast(int(o, "t") orelse 0), .what = .laughed });
            }
            if (x.state == null or !std.mem.eql(u8, x.state.?, state)) {
                x.came_from = x.state;
                x.players_depth = players_depth;
                x.since = @intCast(int(o, "t") orelse 0);
                x.presses = &.{};
                // A press read at this tick began it at once (the pads come before the states).
                x.press_lag = if (x.last_press == x.since) 0 else 1;
                x.bounces = 0;
                if (x.player != null and std.mem.eql(u8, state, "recover")) x.got_up_at = x.since;
                if (x.player != null) {
                    if (std.mem.eql(u8, state, "knee") or std.mem.eql(u8, state, "knee_last")) {
                        x.knees +|= 1;
                    } else if (!std.mem.eql(u8, state, "grab")) x.knees = 0;
                }
            }
            x.state = try arena.dupe(u8, state);
            if (str(o, "facing")) |f| x.left = std.mem.eql(u8, f, "left");
            if (std.mem.indexOf(u8, x.states, state) == null) x.states = try std.fmt.allocPrint(arena, "{s} {s}", .{ x.states, state });
        } else if (std.mem.eql(u8, ev, "pos")) {
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            if (x.player != null and in_round) try players_x.append(arena, .{ .t = @intCast(int(o, "t") orelse 0), .x = @intCast((int(o, "x") orelse 0) >> 16) });
            if (x.player) |p| if (p >= 1 and p <= 2) {
                players_depth[p - 1] = @intCast((int(o, "d") orelse 0) >> 16);
            };
            x.position = .{ @intCast(int(o, "x") orelse 0), @intCast(int(o, "d") orelse 0), @intCast(int(o, "h") orelse 0) };
            const speed: [3]i32 = .{ @intCast(int(o, "vx") orelse 0), @intCast(int(o, "vd") orelse 0), @intCast(int(o, "vh") orelse 0) };
            if (speed[0] != x.velocity[0]) x.across_since = @intCast(int(o, "t") orelse 0);
            if (!std.mem.eql(i32, &speed, &x.velocity)) {
                const changed_at: u64 = @intCast(int(o, "t") orelse 0);
                x.course_since = changed_at;
                x.course_draws = &.{};
                // The draws of this tick or the one before, which may be this course's (its
                // behaviour tells by the speed they give).
                if (changed_at == draws_t or changed_at == draws_t + 1) x.course_draws = draws_values;
            }
            if (x.velocity[2] > 0 and speed[2] < 0) x.bounces +|= 1;
            x.velocity = speed;
        } else if (std.mem.eql(u8, ev, "hit")) {
            const by: ?u32 = if (int(o, "by")) |b| @intCast(b) else null;
            if (by) |b| if (seen.getPtr(b)) |s_| {
                s_.landed = @intCast(int(o, "t") orelse 0);
            };
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            if (by) |b| x.struck_by = b;
            x.struck_at = @intCast(int(o, "t") orelse 0);
        } else if (std.mem.eql(u8, ev, "pickup")) {
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            if (int(o, "by")) |by| x.holder = @intCast(by);
            x.taken +|= 1;
        } else if (std.mem.eql(u8, ev, "health")) {
            const x = seen.getPtr(@intCast(int(o, "e") orelse return error.BadTrace)) orelse continue;
            x.health = @intCast(int(o, "health") orelse 0);
        } else if (std.mem.eql(u8, ev, "camera")) {
            s.camera = .{ @intCast(int(o, "x") orelse 0), @intCast(int(o, "y") orelse 0) };
            if (in_round) try history.append(arena, .{ .t = ev_t, .what = .{ .camera = s.camera[0] } });
        } else if (std.mem.eql(u8, ev, "camera_stop")) {
            s.camera_stop = .{ @intCast(int(o, "x") orelse 0), @intCast(int(o, "y_min") orelse 0), @intCast(int(o, "y_max") orelse 0) };
            if (in_round) try history.append(arena, .{ .t = ev_t, .what = .{ .wall = s.camera_stop[0] } });
        } else if (std.mem.eql(u8, ev, "pad")) {
            const p: usize = @intCast((int(o, "pad") orelse 1) - 1);
            if (p >= 2) continue;
            const b = std.mem.indexOfScalar(u8, str(o, "held") orelse "", 'B') != null;
            s.pads[p] = padOf(str(o, "held") orelse "");
            if (b and !held_b[p]) for (seen.values()) |*x| if (x.player != null and x.player.? == p + 1) {
                const read: u64 = @intCast(int(o, "t") orelse 0);
                x.presses = try std.mem.concat(arena, u64, &.{ x.presses, &.{read} });
                x.last_press = read;
            };
            held_b[p] = b;
        } else if (std.mem.eql(u8, ev, "timer")) {
            if (in_round) s.timer = .{ .seconds = @intCast(int(o, "time") orelse 0), .t = @intCast(int(o, "t") orelse 0) };
        } else if (std.mem.eql(u8, ev, "lives")) {
            const p: usize = @intCast((int(o, "player") orelse 1) - 1);
            if (p < 2) s.lives[p] = .{ @intCast(int(o, "lives") orelse 0), @intCast(int(o, "specials") orelse 0) };
        } else if (std.mem.eql(u8, ev, "score")) {
            const p: usize = @intCast((int(o, "player") orelse 1) - 1);
            if (p < 2) s.scores[p] = @intCast(int(o, "score") orelse 0);
        } else if (std.mem.eql(u8, ev, "phase")) {
            const phase = str(o, "phase") orelse "";
            if (in_round) {
                playing = std.mem.eql(u8, phase, "play") or std.mem.eql(u8, phase, "special") or std.mem.eql(u8, phase, "script");
                s.script = std.mem.eql(u8, phase, "script");
                s.special = std.mem.eql(u8, phase, "special");
                try history.append(arena, .{ .t = ev_t, .what = .{ .special = s.special } });
            }
            if (at == null and in_round and std.mem.eql(u8, phase, "play")) {
                s.v = @intCast(int(o, "v") orelse 0);
                s.t = @intCast(int(o, "t") orelse 0);
                s.entities = try arena.dupe(Situation.Seen, seen.values());
                s.history = history.items;
                return s;
            }
        }
    }
    if (at == null or !in_round or !playing) return error.NoPlay;
    const l = last orelse return error.NoPlay;
    // The ticks after the last event to the logic tick at or before display tick `at` (a tick
    // in which nothing changed has no event): two display ticks a tick, keeping the last's place.
    const gap = (at.? - l.v) / 2;
    s.v = l.v + 2 * gap;
    s.t = l.t + gap;
    const entities = try arena.dupe(Situation.Seen, seen.values());
    s.entities = entities;
    s.players_x = players_x.items;
    s.history = history.items;
    // The round's script's spawns after the situation, in the same round scene; the other
    // things' made then.
    var later: std.ArrayList(Situation.Later) = .empty;
    var others: std.ArrayList(Situation.Other) = .empty;
    while (after orelse lines.next()) |line| {
        after = null;
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return error.BadTrace;
        if (v != .object) return error.BadTrace;
        const o = v.object;
        const ev = str(o, "ev") orelse return error.BadTrace;
        if (std.mem.eql(u8, ev, "end") or std.mem.eql(u8, ev, "scene")) break;
        if (std.mem.eql(u8, ev, "rng")) {
            if (!s.reseeded or s.last_values.len >= 2 or s.next_values.len >= 2) continue;
            const vals = o.get("values") orelse continue;
            if (vals != .array) continue;
            const out = try arena.alloc(u16, s.next_values.len + vals.array.items.len);
            @memcpy(out[0..s.next_values.len], s.next_values);
            for (out[s.next_values.len..], vals.array.items) |*x, y| x.* = @intCast(y.integer);
            s.next_values = out;
            continue;
        }
        if (std.mem.eql(u8, ev, "hit")) {
            // A blow struck at the situation's tick costs its health at the next, where the
            // trace names the striker: who struck the one that entered its state then.
            if ((int(o, "t") orelse 0) != s.t + 1) continue;
            const id: u32 = @intCast(int(o, "e") orelse continue);
            const by: u32 = @intCast(int(o, "by") orelse continue);
            // One held takes its holder's blows at their own tick (a knee, the last knee's
            // flip): none of them was struck at the situation's tick.
            const held = for (entities) |*x| {
                if (x.id == id) break std.mem.eql(u8, x.state orelse "", "held");
            } else false;
            if (held) continue;
            for (entities) |*x| {
                if (x.id == id and x.since == s.t) x.struck_by = by;
                if (x.id == id) {
                    x.met_by = by;
                    x.met_damage = @intCast(int(o, "damage") orelse 0);
                }
                if (x.id == by) x.landed = s.t + 1;
            }
            continue;
        }
        if (std.mem.eql(u8, ev, "lives")) {
            if (s.join) |*j| if (int(o, "player") == 2 and int(o, "t") == @as(i64, @intCast(j.t))) {
                j.lives = @intCast(int(o, "lives") orelse 0);
            };
            continue;
        }
        if (!std.mem.eql(u8, ev, "spawn")) continue;
        const kind = str(o, "kind") orelse return error.BadTrace;
        if (int(o, "player") == 2 and s.join == null) {
            s.join = .{ .t = @intCast(int(o, "t") orelse 0), .kind = try arena.dupe(u8, kind) };
            continue;
        }
        // A breakable's pieces (its kind's, not in its first state) are its own, not the script's.
        const piece = std.mem.eql(u8, kind, "breakable") and !std.mem.eql(u8, str(o, "state") orelse "", "s0");
        if (!(scripted(kind) or std.mem.eql(u8, kind, "go_arrow")) or piece) {
            try others.append(arena, .{ .t = @intCast(int(o, "t") orelse 0), .id = @intCast(int(o, "e") orelse continue), .kind = try arena.dupe(u8, kind) });
            continue;
        }
        const x: i32 = @intCast(int(o, "x") orelse 0);
        const d: i32 = @intCast(int(o, "d") orelse 0);
        try later.append(arena, .{ .t = @intCast(int(o, "t") orelse 0), .seen = .{
            .id = @intCast(int(o, "e") orelse return error.BadTrace),
            .kind = try arena.dupe(u8, kind),
            .position = .{ x, d, @intCast(int(o, "h") orelse 0) },
            .state = if (str(o, "state")) |st| try arena.dupe(u8, st) else null,
            .left = if (str(o, "facing")) |f| std.mem.eql(u8, f, "left") else false,
            .health = if (int(o, "health")) |h| @intCast(h) else null,
            .spawned_at = .{ x >> 16, d >> 16 },
            .slot = if (int(o, "_slot")) |sl| @intCast(sl) else null,
        } });
    }
    s.later = later.items;
    s.others = others.items;
    return s;
}

/// What another program's probe (its `--probe` lines, `{"t","e","anim","frame",...}`) says of
/// the situation's entities: the frame each shows at the situation's tick, since its tick.
pub fn framesOf(situation: *Situation, arena: std.mem.Allocator, probe_text: []const u8) !void {
    const entities = @constCast(situation.entities);
    var lines = std.mem.splitScalar(u8, probe_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return error.BadTrace;
        if (v != .object) return error.BadTrace;
        const o = v.object;
        const t: u64 = @intCast(int(o, "t") orelse continue);
        if (t > situation.t) break;
        const id: u32 = @intCast(int(o, "e") orelse continue);
        const f: u8 = @intCast(int(o, "frame") orelse continue);
        const anim: ?u16 = if (int(o, "anim")) |n| @intCast(n) else null;
        for (entities) |*x| if (x.id == id) {
            if (x.frame != f or x.anim != anim) x.frame_since = t;
            if (x.anim != anim) x.anim_since = t;
            x.frame = f;
            x.anim = anim;
        };
    }
}

/// The animation the original's number names (twice its entry in the kind's set, bit 1 drawn
/// facing left), for the kinds whose take-up shows the probe's (sor-remaster's probes number
/// them): round 1's boss, by the quarter of the number, and his boomerang.
fn originalAnimation(kind: []const u8, original: u16) ?struct { name: []const u8, left: bool } {
    const left = original & 2 != 0;
    const boss = [_][]const u8{ "stand", "swing", "knocked", "held", "held_behind", "flight", "bounce", "down", "lifted", "idle", "walk", "taunt", "throw", "wait" };
    const boomerang = [_][]const u8{ "held", "held_high", "spin" };
    const i = original / 4;
    if (std.mem.eql(u8, kind, "antonio") and i < boss.len) return .{ .name = boss[i], .left = left };
    if (std.mem.eql(u8, kind, "boomerang") and i >= boss.len and i - boss.len < boomerang.len) return .{ .name = boomerang[i - boss.len], .left = left };
    return null;
}

/// A pad holding the buttons a trace's letters name (`U D L R A B C S`).
fn padOf(letters: []const u8) sorz.input.Pad {
    var pad: sorz.input.Pad = .{};
    for (letters) |c| switch (c) {
        'U' => pad.up = true,
        'D' => pad.down = true,
        'L' => pad.left = true,
        'R' => pad.right = true,
        'A' => pad.a = true,
        'B' => pad.b = true,
        'C' => pad.c = true,
        'S' => pad.start = true,
        else => {},
    };
    return pad;
}

/// The round's script's place at the situation: the world's own script run from the round's
/// start, tick by tick, over a world whose script entities come and go as the other program's
/// trace says (each of the script's spawns matched to one of the trace's, by tick, kind and
/// place; the trace's removals followed), its camera where the trace has it, and play's phase
/// the trace's. Null when the script's spawns or sections part from the trace's (the stand-in
/// then brings what the trace brought).
/// The round's script, and round 8's room's, as a replay leaves them.
const Replayed = struct { script: world.script.State, room: world.room.State };

fn replayScript(gpa: std.mem.Allocator, kinds: *const world.Kinds, plan: *const world.script.Plan, situation: *const Situation, two: bool) !?Replayed {
    const Replay = struct {
        w: *world.World,
        kinds: *const world.Kinds,
        steps: []const Situation.Step,
        ids: std.AutoHashMapUnmanaged(u32, world.Handle) = .empty,
        known: [world.entity.capacity]u16 = @splat(0),
        alive: [world.entity.capacity]bool = @splat(false),

        /// The script's new entities matched to the trace's spawns of ticks `from` to `to`;
        /// false when one has no match.
        fn match(self: *@This(), alloc: std.mem.Allocator, from: u64, to: u64) !bool {
            for (&self.w.entities, 0..) |*e, i| {
                if (!e.alive()) {
                    self.alive[i] = false;
                    continue;
                }
                if (self.alive[i] and self.known[i] == e.generation) continue;
                self.alive[i] = true;
                self.known[i] = e.generation;
                const h = self.w.handleAt(i).?;
                const name = self.kinds.get(e.kind.?).name();
                // Not the trace's entities that matter (the GO arrow): gone at once.
                if (!scripted(name)) {
                    self.w.remove(h);
                    self.alive[i] = false;
                    continue;
                }
                const id = for (self.steps) |st| {
                    if (st.t < from or st.t > to or st.what != .spawn) continue;
                    const sp = st.what.spawn;
                    if (self.ids.contains(sp.id)) continue;
                    if (!std.mem.eql(u8, sp.kind, name) or sp.x != e.position.x.whole() or sp.depth != e.position.depth.whole()) continue;
                    break sp.id;
                } else {
                    std.log.warn("the round's script, taken up, brings a {s} at ({d}, {d}) at tick {d} the trace has not: its stand-in takes over", .{ name, e.position.x.whole(), e.position.depth.whole(), to });
                    return false;
                };
                try self.ids.put(alloc, id, h);
            }
            return true;
        }
    };
    const w = try gpa.create(world.World);
    defer gpa.destroy(w);
    w.* = .{};
    var out: world.Output = .{};
    var random: world.Random = .{};
    var t: world.tick.Tick = .{ .world = w, .kinds = kinds, .random = &random, .out = &out, .plan = plan };
    world.script.start(w, plan);
    w.ground = .pixels(plan.round.ground);
    w.script.two_players = two;
    var r: Replay = .{ .w = w, .kinds = kinds, .steps = situation.history };
    defer r.ids.deinit(gpa);
    const steps = situation.history;
    var k: usize = 0;
    var camera: i32 = w.camera.x.raw;
    var laughs: u3 = 0;
    var tick: u64 = 1;
    // Round 8's room begun before the situation: the script from the room's beginning (the
    // corridor's sections behind it), else from the round's start.
    const room_at: ?u64 = room: {
        var at: ?u64 = null;
        for (steps) |st| {
            if (st.t > situation.t) break;
            if (st.what == .room_begun) at = st.t;
        }
        break :room at;
    };
    if (room_at) |at| {
        while (k < steps.len and steps[k].t <= at) : (k += 1) switch (steps[k].what) {
            .camera => |x| camera = x,
            .special => |on| w.special = on,
            else => {},
        };
        w.camera.x = .{ .raw = camera };
        world.script.takeUpRoom(&t, plan);
        if (!try r.match(gpa, at, at)) return null;
        tick = at + 1;
    } else {
        // The round's start: the first section's placed, the trace's at its first ticks.
        world.script.placeFirst(&t, plan);
        if (!try r.match(gpa, 0, 1)) return null;
    }
    while (tick <= situation.t) : (tick += 1) {
        var to = k;
        while (to < steps.len and steps[to].t <= tick) to += 1;
        // What the trace says before the script's turn: the removals, the phase.
        for (steps[k..to]) |st| switch (st.what) {
            // An enemy out of hiding shows on the line of its colours as they are held then;
            // one knocked out is counted off the script's tallies.
            .appear => |id| if (r.ids.get(id)) |h| if (w.get(h)) |e| {
                e.flags.hidden = false;
                if (e.spawn.colours) |c| e.palette = world.script.lineOf(&t, c);
            },
            .remove => |rm| if (r.ids.fetchRemove(rm.id)) |kv| {
                if (rm.knocked_out) if (w.get(kv.value)) |e| world.script.countOff(&t, e);
                w.remove(kv.value);
            },
            .special => |on| w.special = on,
            // Mr. X's laughs mark the room's fight's progress (his first, then his second).
            .laughed => {
                w.room.progress |= @as(u8, 1) << laughs;
                laughs +%= 2;
            },
            // Round 8's room opens as its door breaks: where the trace opens it.
            .section => |sec| if (sec == plan.round.sections.len and plan.round.room != null and w.script.part == sec) {
                w.room.opening = true;
                w.room.door_made = true;
                w.room.door_broken = true;
            },
            else => {},
        };
        w.camera.x = .{ .raw = camera };
        if (!w.special) w.camera.x_min = w.camera.x;
        world.script.opening(&t);
        for (steps[k..to]) |st| switch (st.what) {
            .camera => |x| camera = x,
            else => {},
        };
        w.camera.x = .{ .raw = camera };
        world.script.run(&t);
        if (!try r.match(gpa, tick, tick)) return null;
        // The trace's spawns of the tick all the script's, its section the script's.
        for (steps[k..to]) |st| switch (st.what) {
            .spawn => |sp| if (!r.ids.contains(sp.id)) {
                std.log.warn("the round's script, taken up, does not bring the trace's {s} at ({d}, {d}) at tick {d}: its stand-in takes over", .{ sp.kind, sp.x, sp.depth, tick });
                return null;
            },
            .section => |sec| if (sec != w.script.section) {
                std.log.warn("the round's script, taken up, is at section {d} at tick {d}, the trace's at {d}: its stand-in takes over", .{ w.script.section, tick, sec });
                return null;
            },
            else => {},
        };
        k = to;
    }
    return .{ .script = w.script, .room = w.room };
}

/// The kind whose coming begins round 8's room.
const room_begins = "mr_x_seated";

/// Mr. X seated's state at the end of a laugh (behaviours/mr_x_seated.zig's `laughed`, as the
/// other program numbers it).
const laughed_state = "s20";

/// The kinds the round's script places: its enemies, its bosses, its breakables (rounds 1 and 2).
fn scripted(kind: []const u8) bool {
    for ([_][]const u8{ "galsia", "galsia_stalker", "galsia_knife", "galsia_pipe", "signal", "acrobat", "brawler", "antonio", "juggler", "boss_r2", "boss_r4", "breakable" }) |k| {
        if (std.mem.eql(u8, k, kind)) return true;
    }
    return false;
}

/// The random generator's state the situation's draws leave: its draws stepped from power-on;
/// or, after a seed set otherwise, found from the last tick's draws (the state whose next draws
/// they are, the low half sought, then stepped past them).
pub fn generatorOf(s: *const Situation) ?world.Random {
    if (!s.reseeded) {
        var r: world.Random = .{};
        var k: u64 = 0;
        while (k < s.draws) : (k += 1) _ = r.next();
        return r;
    }
    if (s.last_values.len < 2 and s.next_values.len >= 2) return before(s.next_values);
    const vals = s.last_values;
    if (vals.len < 2) return null;
    var low: u32 = 0;
    while (low <= 0xFFFF) : (low += 1) {
        var r: world.Random = .{ .state = @as(u32, vals[0]) << 16 | low };
        const ok = for (vals[1..]) |want| {
            if (r.next() != want) break false;
        } else true;
        if (!ok) continue;
        var k: u32 = @intCast(vals.len);
        while (k < s.last_count) : (k += 1) _ = r.next();
        return r;
    }
    return null;
}

/// The state whose next draws are `vals`: the state after the first (its draw the high half,
/// the low half found by the others), a step back (the product's halves, over the multiplier).
fn before(vals: []const u16) ?world.Random {
    var low: u32 = 0;
    while (low <= 0xFFFF) : (low += 1) {
        var r: world.Random = .{ .state = @as(u32, vals[0]) << 16 | low };
        for (vals[1..]) |want| {
            if (r.next() != want) break;
        } else {
            const high: u32 = vals[0] -% @as(u16, @intCast(low));
            return .{ .state = (high << 16 | low) *% multiplier_inverse };
        }
    }
    return null;
}

/// The inverse of the generator's multiplier, 41, modulo 2^32.
const multiplier_inverse: u32 = 3247414297;

fn str(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(o: std.json.ObjectMap, name: []const u8) ?i64 {
    const v = o.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

// The run ----------------------------------------------------------------------------------------

/// The states in which a fighter holds another, as the traces name them.
const holding_states = [_][]const u8{ "grab", "grab_behind", "knee", "knee_last", "grab_blow", "vault", "vault_land", "throw", "throw_back", "hold" };

/// Whether `state` is one of `names`.
fn stateIn(state: ?[]const u8, names: []const []const u8) bool {
    const st = state orelse return false;
    for (names) |n| if (std.mem.eql(u8, st, n)) return true;
    return false;
}

/// A scenario's run: the world taken up from the situation, its ticks with the script's pads,
/// the trace and the probe written at each tick's end.
pub const Run = struct {
    gpa: std.mem.Allocator,
    kinds: *const world.Kinds,
    play: world.Play = .{},
    random: world.Random = .{},
    out: world.Output = .{},
    body: Body,
    trace: ?*world.trace.Writer,
    probe: ?*Probe,
    v: u64,
    t: u64,
    /// The trace ids of the entities, by their place in the world (the situation's, then the
    /// trace's own), for the conditions.
    ids: [world.entity.capacity]u32 = @splat(0),
    /// The generation each id is of: a place freed and taken in the same tick has a new entity.
    generations: [world.entity.capacity]u16 = @splat(0),
    /// What stopped the run before the script's end, and the kinds the situation had that the
    /// content does not.
    failure: ?[]const u8 = null,
    skipped: std.ArrayList([]const u8) = .empty,
    /// The script's tick 0's display tick.
    script_v: u64,
    /// The round's script's stand-in: the spawns still to come, and the records they take.
    later: []const Situation.Later = &.{},
    next_later: usize = 0,
    /// Player 2 joining after the situation, at the other program's tick.
    join: ?Situation.Join = null,
    others: []const Situation.Other = &.{},
    next_other: usize = 0,
    round: ?*const sorz.content.round.Round = null,
    used: [256]bool = @splat(false),
    /// The round's plan: the round's script (taken up where it was), or, its records left to the
    /// stand-in, the timer and the new lives follow it.
    plan: ?world.script.Plan = null,
    /// The art the world queues (the special attack's car's), streamed in as the round's
    /// picture streams it: a share a display tick.
    art: world.script.ArtQueue = .{},
    /// The round's script was taken up where it was (`replayScript`): it brings its records
    /// itself, and the stand-in does not.
    scripted: bool = false,
    /// A beaten boss has ended the round: the display ticks left of its leaving.
    leaving: ?u8 = null,

    /// What the run takes up besides the situation: the round's clock (the other program's tick
    /// counter at the script's start, when known) and the round's spawn records.
    pub const Extras = struct {
        game_tick: ?u32 = null,
        /// The round's script, whose records placed the enemies.
        round: ?*const sorz.content.round.Round = null,
        /// The high-score table's last entry, which a score must beat for its name to be entered.
        last_score: ?world.script.Ranked = null,
        /// The lines of the enemies' colours, and which are a kind's own (the round's plan's).
        colour_lines: [3]u2 = .{ 1, 2, 1 },
        own_colours: u16 = 0,
        /// The options' LEVEL of the game (the round's plan's), and what it changes in play
        /// (play's record); each player's continues left.
        level: u2 = 1,
        levels: sorz.content.screens.Levels = .{},
        continues: u8 = 0,
    };

    pub fn init(gpa: std.mem.Allocator, kinds: *const world.Kinds, script: *const Script, situation: *const Situation, extras: Extras, trace: ?*world.trace.Writer, probe: ?*Probe) !Run {
        var r: Run = .{
            .gpa = gpa,
            .kinds = kinds,
            .body = .{ .commands = script.commands },
            .trace = trace,
            .probe = probe,
            .v = situation.v,
            .t = situation.t,
            .script_v = situation.v,
        };
        const w = &r.play.world;
        // The round's clock: during the script's first tick, the other program's counter is one
        // past its value at the script's start.
        if (extras.game_tick) |g| w.tick = g + 1;
        if (generatorOf(situation)) |g| r.random = g;
        w.special = situation.special;
        if (situation.script) w.room.offer = world.room.fight;
        const round = extras.round orelse return error.NoRound;
        w.ground = .pixels(round.ground);
        w.camera = .{
            .x = .of(situation.camera[0]),
            .y = .of(situation.camera[1]),
            .x_min = .of(situation.camera[0]),
            .x_max = .of(situation.camera_stop[0]),
            .y_min = .of(situation.camera_stop[1]),
            .y_max = .of(situation.camera_stop[2]),
            .follows = world.script.cameraRules(round),
        };
        r.later = situation.later;
        r.join = situation.join;
        r.others = situation.others;
        r.round = extras.round;
        try takeUpScript(&r, round, situation, extras);
        var made: [world.entity.capacity]?struct { h: world.Handle, e: *const Situation.Seen } = @splat(null);
        // A game of two players: the script's records for two players are its.
        const two = for (situation.entities) |*e| {
            if (e.player == 2) break true;
        } else false;
        for (situation.entities) |*e| {
            var kind_name = e.kind;
            if (e.player) |p| switch (script.start) {
                // The trace names a player by its character; the script chose it.
                .players => |players| kind_name = if (p == 1) players.first else players.second orelse e.kind,
                .pads, .power_on => {},
            };
            const kind = kinds.find(kind_name) orelse {
                try r.skipped.append(gpa, e.kind);
                continue;
            };
            const h = try spawnSeen(w, kinds, kind, e);
            const x = w.get(h).?;
            x.velocity = .{ .x = .of(e.velocity[0]), .depth = .of(e.velocity[1]), .height = .of(e.velocity[2]) };
            if (x.position.height.lessThan(w.ground)) x.flags.airborne = true;
            if (e.health) |hp| x.health = @intCast(hp);
            if (e.state) |st| _ = world.behaviours.setState(&x.mind, st);
            if (e.player) |p| {
                w.players[p - 1] = .{ .entity = h, .character = kind, .lives = situation.lives[p - 1][0], .specials = situation.lives[p - 1][1], .score = situation.scores[p - 1], .continues = extras.continues, .last = situation.pads[p - 1] };
                // The camera follows from where the situation's tick drew the player.
                w.camera.drawn[p - 1] = x.position.x;
                w.camera.drawn_lines[p - 1] = @truncate(world.draw_list.screenPlace(w, x).y);
            }
            if (x.team == .enemy) takeUpSpawn(kinds, x, e, extras.round, two, &r.used) else if (x.mind == .statue) {
                // A statue stands in the pose its record gives (Mr. X's room's).
                if (recordOf(e, extras.round, two, &r.used)) |rec| x.spawn = world.script.placing(rec);
            }
            // A breakable standing still holds the item its record names.
            if (std.mem.eql(u8, e.kind, "breakable") and stateIn(e.state, &.{ "s0", "s1" })) {
                if (recordOf(e, extras.round, two, &r.used)) |rec| if (rec.holds) |name| if (kinds.find(name)) |item| {
                    var t: world.tick.Tick = .{ .world = w, .kinds = kinds, .random = &r.random, .out = &r.out };
                    t.give(h, item);
                };
            }
            made[h.index] = .{ .h = h, .e = e };
        }
        // The animation the other program's probe names by the original's number, for the kinds
        // whose take-up shows it (the boss and his boomerang), and the way it faces.
        for (made) |m_| {
            const m = m_ orelse continue;
            const anim = m.e.anim orelse continue;
            const o = originalAnimation(m.e.kind, anim) orelse continue;
            const x = w.get(m.h).?;
            x.animation.index = kinds.get(x.kind.?).definition.animation(o.name) orelse continue;
            x.animation.frame = 0;
            x.facing = if (o.left) .left else .right;
        }
        // Who struck each last, by the trace's ids; then each takes its state up.
        for (made) |m_| {
            const m = m_ orelse continue;
            const x = w.get(m.h).?;
            if (m.e.struck_by) |by| for (made) |o_| {
                const o = o_ orelse continue;
                if (o.e.id == by) x.struck_by = o.h;
            };
        }
        // A weapon in its holder's hand.
        for (made) |m_| {
            const m = m_ orelse continue;
            const by = m.e.holder orelse continue;
            if (!std.mem.eql(u8, m.e.state orelse "", "held")) continue;
            for (made) |o_| {
                const o = o_ orelse continue;
                if (o.e.id != by) continue;
                w.get(m.h).?.holder = o.h;
                var t: world.tick.Tick = .{ .world = w, .kinds = kinds, .random = &r.random, .out = &r.out };
                t.takeUpWeapon(o.h, m.h);
            }
        }
        for (made) |m_| {
            const m = m_ orelse continue;
            const h = m.h;
            const e = m.e;
            r.ids[h.index] = e.id;
            r.generations[h.index] = h.generation;
            if (trace) |tw| tw.assignId(h.index, h.generation, e.id);
            var t: world.tick.Tick = .{ .world = w, .kinds = kinds, .random = &r.random, .out = &r.out };
            t.takeUp(h, @intCast(situation.t -| e.since));
            t.takeUpSince(h, @intCast(situation.t -| e.across_since), @intCast(situation.t -| e.anim_since));
            if (e.came_from) |from| t.takeUpCameFrom(h, from);
            if (e.got_up_at) |at| t.takeUpBlink(h, @intCast(situation.t -| at));
            if (e.knees != 0) t.takeUpKnees(h, e.knees);
            t.takeUpPlayersThen(h, e.players_depth);
            if (e.taken != 0) t.takeUpTaken(h, e.taken);
            t.takeUpCourse(h, @intCast(situation.t -| e.course_since), e.course_draws);
            if (e.bounces != 0) t.takeUpBounces(h, e.bounces);
            // Its blow that cost another health in its state: at the situation's tick (the
            // trace tells it at the next), or so many ticks before.
            if (e.landed) |at| if (at > e.since) t.takeUpLanded(h, if (at > situation.t) null else @intCast(situation.t - at));
            // A player's presses of B in its state, seen by then.
            if (e.presses.len != 0) {
                var ticks: [16]u32 = undefined;
                var k: usize = 0;
                for (e.presses) |read| {
                    const at = read + e.press_lag;
                    if (at <= e.since or at > situation.t or k == ticks.len) continue;
                    ticks[k] = @intCast(at - e.since);
                    k += 1;
                }
                const landed: ?u32 = if (e.landed) |l| (if (l > e.since and l <= situation.t) @as(u32, @intCast(l - e.since)) else null) else null;
                t.takeUpPresses(h, @intCast(situation.t - e.since), ticks[0..k], landed);
            }
            // A blow that met it at the situation's tick, felt at the next.
            if (e.met_by) |by| for (made) |o_| {
                const o = o_ orelse continue;
                if (o.e.id == by) t.takeUpMet(h, o.h, @intCast(e.met_damage));
            };
            // A blow that cost it health in its state, so many ticks before, its striker still in
            // the state it struck in (its blow may still touch).
            if (e.struck_at) |at| if (at > e.since) {
                var striking = false;
                for (situation.entities) |*o| if (e.struck_by == o.id) {
                    striking = o.since < at;
                };
                t.takeUpStruck(h, @intCast(situation.t - at), striking);
            };
        }
        // A fighter held, and its holder: the nearest across at its depth in a state that holds
        // (the traces do not say who holds whom); they hold as a grab would make them, the blow
        // its holder's move has under way taken already.
        for (made) |m_| {
            const m = m_ orelse continue;
            if (!stateIn(m.e.state, &.{ "held", "held_behind" }) or m.e.holder != null) continue;
            const x = w.get(m.h) orelse continue;
            if (x.holder != null) continue;
            var best: ?world.Handle = null;
            var best_dx: i32 = std.math.maxInt(i32);
            for (made) |o_| {
                const o = o_ orelse continue;
                if (o.h.eql(m.h) or !stateIn(o.e.state, &holding_states)) continue;
                const y = w.get(o.h) orelse continue;
                if (y.holding != null) continue;
                if (@abs(y.position.depth.whole() - x.position.depth.whole()) > 2) continue;
                const dx: i32 = @intCast(@abs(y.position.x.whole() - x.position.x.whole()));
                if (dx >= best_dx) continue;
                best = o.h;
                best_dx = dx;
            }
            const hh = best orelse continue;
            w.get(hh).?.holding = m.h;
            x.holder = hh;
            var t: world.tick.Tick = .{ .world = w, .kinds = kinds, .random = &r.random, .out = &r.out };
            t.grabbed(hh, m.h);
            t.takeUpHeld(m.h, @intCast(situation.t -| m.e.since));
        }
        // A shutter waiting opened when its player first came near it since it was put up.
        if (kinds.find(world.tick.Tick.shutter_kind)) |sk| {
            const near = kinds.get(sk).definition.number("near") orelse 0;
            for (made) |m_| {
                const m = m_ orelse continue;
                const x = w.get(m.h) orelse continue;
                if (x.kind != sk or x.mind.shutter.state != .wait) continue;
                const edge = x.position.x.whole() - near;
                for (situation.players_x) |px| {
                    if (px.t < m.e.since or px.x < edge) continue;
                    var t: world.tick.Tick = .{ .world = w, .kinds = kinds, .random = &r.random, .out = &r.out };
                    t.takeUpOpened(m.h, @intCast(situation.t -| px.t));
                    break;
                }
            }
        }
        // The frames the other program's probe saw at the ends of its ticks (but the players',
        // which step theirs by the ticks of their state), each as far through as it was.
        for (made) |m_| {
            const m = m_ orelse continue;
            if (m.e.player != null) continue;
            const f = m.e.frame orelse continue;
            const x = w.get(m.h) orelse continue;
            const index = x.animation.index orelse continue;
            const an = kinds.get(x.kind.?).definition.animations[index];
            if (f >= an.frames.len) continue;
            x.animation.frame = f;
            // Its boxes those of the frame it shows (where the probe named its animation).
            if (m.e.anim != null and originalAnimation(m.e.kind, m.e.anim.?) != null) {
                x.boxes = .{ .body = an.frames[f].body, .attack = an.frames[f].attack, .mirrored = x.facingLeft() != an.frames[f].flip };
            }
            var t: world.tick.Tick = .{ .world = w, .kinds = kinds, .random = &r.random, .out = &r.out };
            if (t.takeUpFrame(m.h, @intCast(situation.t -| m.e.frame_since), @intCast(situation.t -| m.e.course_since), m.e.course_draws)) continue;
            const ticks: u64 = x.animation.pace orelse an.frames[f].ticks;
            // A pace its state set up counts from the state's start when that came later.
            const since = if (x.animation.pace != null) @max(m.e.frame_since, m.e.since) else m.e.frame_since;
            const shown = situation.t -| since;
            x.animation.left = if (ticks > shown) @intCast(ticks - shown) else 1;
        }
        // What the take-ups asked for is not the tick's.
        r.out.begin();
        if (trace) |tw| {
            tw.next_id = situation.next_id;
            tw.takeUpScene(.{ .name = "round", .round = situation.round }, situation.t);
            tw.setPhase("play");
            try tw.observe(r.v, w, kinds, &r.out);
        }
        if (probe) |p| try p.observe(r.v, r.t, w, kinds, &r.ids);
        return r;
    }

    pub fn deinit(self: *Run) void {
        self.skipped.deinit(self.gpa);
    }

    /// The place the round's script gave the enemy `x` (seen as `e`): the record of its kind
    /// that placed it where it appeared (placed ahead: at its place; brought in: at its depth),
    /// not yet taken by another, and not one for two players in a game of one (`two`). One that
    /// has come in, waited or flanked has the way in and the
    /// place it has now; one that changed kind keeps its old blows' damage.
    fn takeUpSpawn(kinds: *const world.Kinds, x: *world.Entity, e: *const Situation.Seen, round_script: ?*const sorz.content.round.Round, two: bool, used: *[256]bool) void {
        if (recordOf(e, round_script, two, used)) |rec| x.spawn = world.script.placing(rec);
        const state = e.state orelse "";
        if (!std.mem.eql(u8, state, "appear")) x.spawn.traits.waits_for_camera = false;
        // A Galsia that has waited, or one come out of a shutter, fights on as a plain one.
        const plain = world.behaviours.plainEntrance(&x.mind);
        for ([_][]const u8{ " wait", " shutter_entry", " enter" }) |s| {
            if (std.mem.indexOf(u8, e.states, s) != null and !std.mem.eql(u8, state, s[1..])) x.spawn = .{ .entrance = plain, .offset_x = x.spawn.offset_x, .offset_depth = x.spawn.offset_depth };
        }
        if (e.was_kind) |was| {
            x.spawn = .{ .entrance = .close_in, .offset_x = x.spawn.offset_x, .offset_depth = x.spawn.offset_depth };
            if (kinds.find(was)) |k| if (kinds.get(k).definition.number("power")) |p| {
                x.power = @intCast(p);
            };
        }
    }

    /// The round's script, its records left to the stand-in: the section the camera stops at
    /// the wall of, and the timer as it last counted (the ticks of its second since).
    fn takeUpScript(r: *Run, round: *const sorz.content.round.Round, situation: *const Situation, extras: Extras) !void {
        const w = &r.play.world;
        r.plan = .{ .round = round, .level = extras.level, .levels = extras.levels, .last_score = extras.last_score, .colour_lines = extras.colour_lines, .own_colours = extras.own_colours };
        w.script.stage = .stand_in;
        const two = for (situation.entities) |*e| {
            if (e.player == 2) break true;
        } else false;
        if (try replayScript(r.gpa, r.kinds, &r.plan.?, situation, two)) |state| {
            w.script = state.script;
            // Round 8's room's fight as far as the script knows it: Mr. X's laughs, the waves,
            // the walk in begun, the door broken (the offer's step is the phase's).
            const room = &w.room;
            room.progress = state.room.progress;
            room.wave = state.room.wave;
            room.door_made = state.room.door_made;
            room.door_broken = state.room.door_broken;
            if (!situation.script) room.walking = state.room.walking;
            r.scripted = true;
        }
        for (round.sections, 0..) |sec, k| if (sec.wall == situation.camera_stop[0] >> 16) {
            w.script.section = @intCast(k);
        };
        world.script.restartTimer(w, &r.plan.?);
        const count = situation.timer orelse return;
        const pace = round.timer.pace;
        w.timer.seconds = count.seconds;
        w.timer.shown = count.seconds;
        w.timer.ticks = @intCast(pace - @min(situation.t - count.t, pace - 1));
    }

    /// The record of the round's script that placed `e` where it appeared (placed ahead: at
    /// its place; brought in: at its depth), of its kind (its first), not yet taken by another
    /// (`used`), and not one for two players in a game of one (`two`).
    fn recordOf(e: *const Situation.Seen, round_script: ?*const sorz.content.round.Round, two: bool, used: *[256]bool) ?*const sorz.content.round.Spawn {
        const Record = sorz.content.round.Spawn;
        var n: usize = 0;
        const kind = e.was_kind orelse e.kind;
        const r = round_script orelse return null;
        var lists: [64][]const Record = undefined;
        var count: usize = 0;
        for (r.sections) |sec| {
            for ([_][]const Record{ sec.placed, sec.wave, sec.reserve }) |l| {
                if (count < lists.len) lists[count] = l;
                count += 1;
            }
        }
        if (r.boss) |b| for ([_][]const Record{ b.wave, b.reserve }) |l| {
            if (count < lists.len) lists[count] = l;
            count += 1;
        };
        // Round 8's room's: its placed first.
        const room_at = count;
        if (r.room) |rm| {
            for ([_][]const Record{ rm.placed, rm.reserve }) |l| {
                if (count < lists.len) lists[count] = l;
                count += 1;
            }
            for (rm.waves) |l| {
                if (count < lists.len) lists[count] = l;
                count += 1;
            }
        }
        for (lists[0..@min(count, lists.len)], 0..) |list, li| {
            // Placed ahead: by its place; brought in: by its depth.
            const placed = (li % 3 == 0 and li < 3 * r.sections.len) or li == room_at;
            for (list) |*rec| {
                defer n += 1;
                if (n >= used.len or used[n]) continue;
                if (rec.two_players and !two) continue;
                if (!std.mem.eql(u8, rec.kind, kind) or rec.depth != e.spawned_at[1]) continue;
                if (placed and rec.x != e.spawned_at[0]) continue;
                used[n] = true;
                return rec;
            }
        }
        return null;
    }

    /// An entity the other program had, in its place there when it is free (so that the order
    /// of updates is the other program's), else in the first free place.
    fn spawnSeen(w: *world.World, kinds: *const world.Kinds, kind: world.entity.KindId, e: *const Situation.Seen) !world.Handle {
        const at: world.fixed.Vec3 = .{ .x = .of(e.position[0]), .depth = .of(e.position[1]), .height = .of(e.position[2]) };
        const facing: world.entity.Facing = if (e.left) .left else .right;
        if (e.slot) |sl| if (w.spawnIn(kinds, kind, sl, at, facing)) |h| return h else |_| {};
        return w.spawn(kinds, kind, at, facing);
    }

    /// One logic tick: the script's pads, the world's tick, the observations. False when the
    /// script is done.
    pub fn step(self: *Run) !bool {
        if (self.leaving) |*left| return self.leave(left);
        const pads = self.body.tick(self, holds) orelse {
            if (self.body.timed_out != null) self.failure = "a condition did not come in time";
            return false;
        };
        // The pads are held over both display ticks of the logic tick; the art streams a share at
        // each, as the round's picture streams it (screens/round.zig).
        const plan = if (self.plan) |*p| p else null;
        for (0..2) |_| {
            if (self.plan) |*p| p.art_loading = self.art.loading(p.round);
            const ran = self.play.roundTickJoined(self.kinds, &self.random, pads, &self.out, plan, self.joining());
            if (self.plan) |*p| {
                if (ran) if (self.out.streamed) |of| self.art.start(of);
                _ = self.art.next(p.round);
            }
        }
        self.v += 2;
        self.t += 1;
        try self.bringLater();
        const w = &self.play.world;
        // A beaten boss ends the round, which leaves (screens/round.zig): the screen fades out.
        const won = self.plan != null and w.script.stage == .won;
        if (won) self.leaving = sorz.render.palettes.Fade.steps;
        if (self.trace) |tw| {
            // The ids the other program's things the world does not make took are not the
            // world's things'.
            while (self.next_other < self.others.len and self.others[self.next_other].t <= self.t) : (self.next_other += 1) {
                const o = &self.others[self.next_other];
                if (self.kinds.find(o.kind) == null) tw.next_id = @max(tw.next_id, o.id + 1);
            }
            tw.setPhase(if (won) "leaving" else w.playPhase());
            try tw.observe(self.v, w, self.kinds, &self.out);
        }
        self.noteIds();
        if (self.probe) |p| try p.observe(self.v, self.t, w, self.kinds, &self.ids);
        return true;
    }

    /// The round leaving: its world stands still while the screen fades out, a step a display
    /// tick (each a tick of the trace, as the original's counter goes then), the script's pads
    /// still read; the fade's last step ends the round, and the run.
    fn leave(self: *Run, left: *u8) !bool {
        left.* -= 1;
        if (left.* == 0) return false;
        const pads = self.body.tick(self, holds) orelse return false;
        self.v += 1;
        self.t += 1;
        self.out.begin();
        if (self.trace) |tw| {
            tw.held = .{ pads.pad1, pads.pad2 };
            try tw.observe(self.v, &self.play.world, self.kinds, &self.out);
        }
        return true;
    }

    /// Player 2's join at the tick about to run, when the other program's player 2 dropped in
    /// then.
    fn joining(self: *const Run) ?world.tick.Join {
        const j = self.join orelse return null;
        if (j.t != self.t + 1) return null;
        const kind = self.kinds.find(j.kind) orelse return null;
        return .{ .player = 1, .kind = kind, .lives = j.lives };
    }

    /// The round's script's stand-in: what the other program's script brought at the end of this
    /// tick comes now, with its id and the record that placed it (its first tick is the next).
    fn bringLater(self: *Run) !void {
        if (self.scripted) return;
        const w = &self.play.world;
        while (self.next_later < self.later.len and self.later[self.next_later].t <= self.t) : (self.next_later += 1) {
            const l = &self.later[self.next_later];
            if (l.t < self.t) continue;
            const e = &l.seen;
            const kind = self.kinds.find(e.kind) orelse {
                try self.skipped.append(self.gpa, e.kind);
                continue;
            };
            const h = spawnSeen(w, self.kinds, kind, e) catch return error.Full;
            const x = w.get(h).?;
            if (e.health) |hp| x.health = @intCast(hp);
            if (x.team == .enemy) takeUpSpawn(self.kinds, x, e, self.round, w.players[1].entity != null, &self.used);
            self.ids[h.index] = e.id;
            self.generations[h.index] = h.generation;
            if (self.trace) |tw| tw.assignId(h.index, h.generation, e.id);
            var t: world.tick.Tick = .{ .world = w, .kinds = self.kinds, .random = &self.random, .out = &self.out };
            t.takeUp(h, 0);
        }
    }

    /// The ids of entities new at this tick: the trace's, or in order of their places.
    fn noteIds(self: *Run) void {
        const w = &self.play.world;
        for (&w.entities, 0..) |*e, i| {
            if (!e.alive()) {
                self.ids[i] = 0;
                continue;
            }
            if (self.ids[i] != 0 and self.generations[i] == e.generation) continue;
            const h = w.handleAt(i).?;
            self.generations[i] = e.generation;
            self.ids[i] = if (self.trace) |tw| tw.idOf(i, e.generation) orelse 0 else 0;
            if (self.ids[i] == 0) if (w.playerOf(h)) |p| {
                self.ids[i] = @as(u32, p) + 1;
            };
        }
    }

    fn holds(self: *Run, c: Condition) bool {
        const w = &self.play.world;
        switch (c) {
            .scene => |name| return std.mem.eql(u8, name, "round"),
            .phase => |name| return std.mem.eql(u8, name, w.playPhase()),
            .camera => |x| return w.camera.x.whole() >= x,
            .state => |st| {
                for (&w.entities, 0..) |*e, i| {
                    if (!e.alive() or !self.is(i, e, st.who)) continue;
                    const now = world.behaviours.traceName(&e.mind) orelse continue;
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

    fn is(self: *const Run, i: usize, e: *const world.Entity, who: Who) bool {
        return switch (who) {
            .id => |id| self.ids[i] == id,
            // By its name, or the traces' (the scripts run in both programs).
            .kind => |k| std.mem.eql(u8, self.kinds.get(e.kind.?).name(), k) or std.mem.eql(u8, self.kinds.get(e.kind.?).tracedName(), k),
        };
    }
};

// The probe --------------------------------------------------------------------------------------

/// The probe (sor-remaster's docs/scenarios.md): a JSON line per fighter whose frame or boxes
/// changed since its last line, at each tick's end: `anim` (the animation's name), `frame`,
/// `atk` and `body` (the boxes as [x from, x to, depth from, depth to, height from, height to]
/// from its place, facing as it faces; a player's where its turn set them, `Boxes.at`, though
/// it moved since), and `power` (a player's: the damage its blow does now; another's: the
/// damage its blows do).
pub const Probe = struct {
    w: *std.Io.Writer,
    last: [world.entity.capacity]?Line = @splat(null),

    const Line = struct {
        id: u32,
        anim: ?u8,
        frame: u8,
        atk: ?[6]i16,
        body: ?[6]i16,
        power: i16,

        fn eql(a: Line, b: Line) bool {
            return a.id == b.id and a.anim == b.anim and a.frame == b.frame and std.meta.eql(a.atk, b.atk) and std.meta.eql(a.body, b.body) and a.power == b.power;
        }
    };

    pub fn observe(self: *Probe, v: u64, t: u64, w: *const world.World, kinds: *const world.Kinds, ids: *const [world.entity.capacity]u32) !void {
        for (&w.entities, 0..) |*e, i| {
            if (!e.alive()) {
                self.last[i] = null;
                continue;
            }
            const k = kinds.get(e.kind.?);
            switch (k.family()) {
                .player, .enemy, .boss => {},
                else => continue,
            }
            const line: Line = .{
                .id = ids[i],
                .anim = e.animation.index,
                .frame = e.animation.frame,
                .atk = box(k, e, e.boxes.attack),
                .body = box(k, e, e.boxes.body),
                .power = power(k, e),
            };
            if (self.last[i]) |was| if (was.eql(line)) continue;
            self.last[i] = line;
            try self.w.print("{{\"v\":{d},\"t\":{d},\"e\":{d},\"anim\":", .{ v, t, line.id });
            if (line.anim) |a| try self.w.print("\"{s}\"", .{k.definition.animations[a].name}) else try self.w.writeAll("null");
            try self.w.print(",\"frame\":{d},\"atk\":", .{line.frame});
            try writeBox(self.w, line.atk);
            try self.w.writeAll(",\"body\":");
            try writeBox(self.w, line.body);
            try self.w.print(",\"power\":{d}}}\n", .{line.power});
        }
    }

    fn box(k: *const world.kinds.Kind, e: *const world.Entity, index: ?u8) ?[6]i16 {
        const b = &k.definition.boxes[index orelse return null];
        const x = b.across(e.boxes.mirrored);
        const h = b.upDown(e.boxes.mirrored);
        const at = e.boxes.at orelse e.position;
        const dx: i16 = @intCast(at.x.whole() - e.position.x.whole());
        const dd: i16 = @intCast(at.depth.whole() - e.position.depth.whole());
        const dh: i16 = @intCast(at.height.whole() - e.position.height.whole());
        return .{ x.from + dx, x.to + dx, b.depth.from + dd, b.depth.to + dd, h.from + dh, h.to + dh };
    }

    /// A player's: the damage its blow does now; another's (an enemy's, as sor-remaster's
    /// probe gives it): the damage its blows do.
    fn power(k: *const world.kinds.Kind, e: *const world.Entity) i16 {
        if (k.family() != .player) {
            // Not yet out of hiding, it has no blows.
            if (std.mem.eql(u8, world.behaviours.stateName(&e.mind) orelse "", "appear")) return 0;
            if (e.power != 0) return e.power;
            var most: u16 = 0;
            for (k.definition.moves) |m| most = @max(most, m.damage);
            return @intCast(most);
        }
        const m = e.move orelse return 0;
        const index = e.animation.index orelse return 0;
        if (!k.definition.animations[index].frames[e.animation.frame].blow) return 0;
        return @intCast(k.definition.moves[m].damage);
    }

    fn writeBox(w: *std.Io.Writer, b: ?[6]i16) !void {
        const x = b orelse return w.writeAll("null");
        try w.print("[{d},{d},{d},{d},{d},{d}]", .{ x[0], x[1], x[2], x[3], x[4], x[5] });
    }
};

test "a script: its start, presses, holds, waits and conditions" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var s = try parse(gpa,
        \\# a comment
        \\start axel
        \\until state 1 ready
        \\+right
        \\until near galsia 75 8 within 40
        \\-right
        \\attack+jump 2
        \\wait 3
    , &diag);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings("axel", s.start.players.first);
    try std.testing.expectEqual(@as(usize, 6), s.commands.len);
    try std.testing.expectEqual(@as(u32, 40), s.commands[2].op.until.within);
    try std.testing.expectEqual(@as(u8, 0b0110_0000), s.commands[4].op.press.buttons);
    try std.testing.expectError(error.BadScenario, parse(gpa, "start axel\nkick\n", &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expectEqual(@as(u8, 1), s.start.players.round);
    var later = try parse(gpa, "start axel blaze round 2\nwait 1\n", &diag);
    defer later.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), later.start.players.round);
    try std.testing.expectEqualStrings("blaze", later.start.players.second.?);
    try std.testing.expectError(error.BadScenario, parse(gpa, "start axel round 9\n", &diag));
}

test "a start from a recorded play, and the random generator its draws left" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var s = try parse(gpa, "start pads ../../game.pads 2280\nwait 900\n", &diag);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings("../../game.pads", s.start.pads.path);
    try std.testing.expectEqual(@as(u64, 2280), s.start.pads.vblanks);
    // Its draws from power-on, stepped.
    var want: world.Random = .{};
    _ = want.next();
    _ = want.next();
    try std.testing.expectEqual(want.state, generatorOf(&.{ .v = 0, .t = 0, .entities = &.{}, .draws = 2 }).?.state);
    // A seed set otherwise: found from the last tick's draws (three, two of them listed).
    var r: world.Random = .{ .state = 0x12345678 };
    const first = r.next();
    const second = r.next();
    _ = r.next();
    const values = [_]u16{ first, second };
    const found = generatorOf(&.{ .v = 0, .t = 0, .entities = &.{}, .reseeded = true, .last_values = &values, .last_count = 3 }).?;
    try std.testing.expectEqual(r.state, found.state);
    // No draws before the situation: found from the first draws after it.
    const held = r.state;
    const next = [_]u16{ r.next(), r.next(), r.next() };
    try std.testing.expectEqual(held, generatorOf(&.{ .v = 0, .t = 0, .entities = &.{}, .reseeded = true, .next_values = &next }).?.state);
}

test "the body: a press holds a tick and releases one; a hold lasts until released" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var s = try parse(gpa, "start axel\nattack\n+right\nwait 2\n-right\n", &diag);
    defer s.deinit(gpa);
    var b: Body = .{ .commands = s.commands };
    const never = struct {
        fn f(_: void, _: Condition) bool {
            return false;
        }
    }.f;
    var held: [6]u8 = undefined;
    for (&held) |*h| h.* = @bitCast((b.tick({}, never) orelse input.Pads{}).pad1);
    // B at tick 0, released at 1; right from 2 to 3, released at 4.
    try std.testing.expectEqualSlices(u8, &.{ 0b10_0000, 0, 0b1000, 0b1000, 0, 0 }, &held);
}

test "a recorded play's start: its pads by display tick, a malformed line refused" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    var s = try parse(gpa, "start pads game.pads 31400\nwait 1\n", &diag);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings("game.pads", s.start.pads.path);
    try std.testing.expectEqual(@as(u64, 31400), s.start.pads.vblanks);
    const pads = (try parsePads(gpa, "000 000\n088 001\n\n")).?;
    defer gpa.free(pads);
    try std.testing.expectEqual(@as(usize, 2), pads.len);
    try std.testing.expect(pads[1].pad1.start and pads[1].pad1.right and pads[1].pad2.up);
    try std.testing.expectEqual(@as(?[]input.Pads, null), try parsePads(gpa, "000\n"));
}

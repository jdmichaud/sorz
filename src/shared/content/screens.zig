//! The screens' data (docs/content.md, "screens/NAME.json"): what the front-end screens show and
//! play beyond their art, as the original's tables give it: the options' texts and the sound
//! test's entries, the high-score table at power-on, the character select's poses. A record per
//! screen, named by the screen; a tree lists those it has in its manifest's `screens`.
//!
//! Texts are written as the game's font writes them (`fonts/main`'s glyphs: capitals, digits,
//! signs), a sound by its name in the sound content, a frame by its full name in the art.
const std = @import("std");
const json = @import("../formats/json.zig");
const art = @import("art.zig");

pub const Error = json.Error;

/// The sound test's entries: the name it shows, the sound it plays.
pub const SoundTestEntry = struct { name: []const u8, sound: []const u8 };

pub const Options = struct {
    sound_test: []const SoundTestEntry,
    /// The levels' names, the easiest first (the high scores show them too).
    levels: []const []const u8,
    /// The control choices: for each, the lines that say what the buttons do.
    controls: []const []const []const u8,
    /// Where each comes from, for the reader.
    provenance: struct { sound_test: []const u8 = "", levels: []const u8 = "", controls: []const u8 = "" } = .{},
};

/// An entry of the high-score table: the score, the round reached, the name (three letters of the
/// font), the level (a number of `Options.levels`).
pub const Score = struct { score: u32, round: u8, name: []const u8, level: u8 };

pub const HighScores = struct {
    /// The table at power-on, the best first.
    first: []const Score,
    provenance: []const u8 = "",
};

/// A step of an animation: a frame (its full name), shown for `ticks` ticks, mirrored or not, and
/// the tiles the game copies to show it, a copy each (`copied`: the players' frames are copied
/// whole when they come, in a part of 34 tiles and, for the larger ones, a second of 32).
pub const Step = struct { frame: []const u8, ticks: u8, mirrored: bool = false, copied: []const u16 = &.{} };

/// The most copies a step has.
pub const max_copies = 2;

/// A character's poses on the character select, each an animation.
pub const Poses = struct {
    provenance: []const u8 = "",
    stand: []const Step,
    idle: []const Step,
    pose_a: []const Step,
    pose_b: []const Step,
    pose_c: []const Step,
    /// Blaze's, after her jump.
    landing: []const Step = &.{},
};

pub const Select = struct {
    adam: Poses,
    axel: Poses,
    blaze: Poses,
};

/// A character's profile in the intro, typed a character a tick: its text in `fonts/intro`'s
/// glyphs, with `_` a blank cell, `/` a new line and `|` a pause (the cursor blinks), and where
/// its first character goes (a cell of plane A or B).
pub const Profile = struct { text: []const u8, plane: art.Layer, x: u16, y: u16 };

/// An entry of the intro's script: the part it starts (by its name in the intro's code), the
/// ticks until the next entry, and the part's life (its ticks, for the parts that have one).
pub const ScriptEntry = struct { part: []const u8, wait: u16, life: u16 };

pub const Intro = struct {
    /// The story's lines, in `fonts/italic`'s glyphs, each the width it takes on the screen.
    story: []const []const u8,
    /// The profiles, in the order they are typed: Adam, Blaze, Axel.
    profiles: []const Profile,
    script: []const ScriptEntry,
    provenance: struct { story: []const u8 = "", profiles: []const u8 = "", script: []const u8 = "" } = .{},
};

/// A cell of the fixed layer (the status bar's): its column and its row.
pub const Cell = struct { x: u8, y: u8 };

/// The round's banner at its start: three frames drawn at the screen's top-left (its left part,
/// the round's number, its right part). The status bar's first `fade` colours fade in; then the
/// parts slide in (the left one right, the number down, the right one left) by `in` pixels a tick
/// for `in_ticks` ticks, stay `wait` ticks (the round's music at their start), slide back out by
/// `out` for `out_ticks`, and the round starts `after` ticks later.
pub const Banner = struct {
    provenance: []const u8 = "",
    left: []const u8,
    number: []const u8,
    right: []const u8,
    fade: u8,
    in: u8,
    in_ticks: u16,
    wait: u16,
    out: u8,
    out_ticks: u16,
    after: u16,
};

/// A fixed text of play, a frame drawn at the screen's top-left.
pub const Text = struct { provenance: []const u8 = "", frame: []const u8 };

/// The time over: its text shows `ticks` ticks; then each player in play loses `health` and the
/// timer shows `seconds`.
pub const TimeOver = struct {
    provenance: []const u8 = "",
    frame: []const u8,
    ticks: u16,
    health: u8,
    seconds: u8,
};

/// A player's parts of the status bar: its name, and the cells of its parts.
pub const BarPlayer = struct {
    name: []const u8,
    name_at: Cell,
    score: Cell,
    health: Cell,
    lives: Cell,
    lives_mark: Cell,
    icon: Cell,
    specials: Cell,
    specials_mark: Cell,
};

/// Player 2's invitation to join while it does not play: its text (`fonts/main`) from its cell,
/// shown and hidden in turn every `blink` logic ticks of play.
pub const Join = struct { text: []const u8, at: Cell, blink: u8 };

/// The status bar, on the fixed layer: each player's parts, the timer's, the invitation to join.
pub const StatusBar = struct {
    provenance: []const u8 = "",
    players: [2]BarPlayer,
    time: Cell,
    join: Join,
};

/// Play's screen (`screens/round`): its fixed texts and its status bar.
pub const Round = struct {
    banner: Banner,
    pause: Text,
    time_over: TimeOver,
    status_bar: StatusBar,
};

/// The screens' records a tree has.
pub const Screens = struct {
    options: ?Options = null,
    high_scores: ?HighScores = null,
    select: ?Select = null,
    intro: ?Intro = null,
    round: ?Round = null,

    /// The names of the records it has, in name order (the manifest's `screens`).
    pub fn names(self: *const Screens, out: *[record_names.len][]const u8) []const []const u8 {
        var n: usize = 0;
        inline for (record_names) |name| {
            if (@field(self, name) != null) {
                out[n] = name;
                n += 1;
            }
        }
        return out[0..n];
    }
};

/// The records' names, in name order: their files are `screens/NAME.json`.
pub const record_names = [_][]const u8{ "high_scores", "intro", "options", "round", "select" };

pub fn path(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "screens/{s}.json", .{name});
}

// --- Writing ---------------------------------------------------------------------------------

fn obj(arena: std.mem.Allocator, fields: []const json.Field) !json.Value {
    return .{ .object = try arena.dupe(json.Field, fields) };
}

fn strings(arena: std.mem.Allocator, xs: []const []const u8) !json.Value {
    const out = try arena.alloc(json.Value, xs.len);
    for (out, xs) |*o, x| o.* = .{ .str = x };
    return .{ .array = out };
}

/// A list with its provenance: `{"provenance": "...", KEY: [...]}`.
fn listed(arena: std.mem.Allocator, provenance: []const u8, key: []const u8, list: json.Value) !json.Value {
    if (provenance.len == 0) return obj(arena, &.{.{ .key = key, .value = list }});
    return obj(arena, &.{ .{ .key = "provenance", .value = .{ .str = provenance } }, .{ .key = key, .value = list } });
}

fn steps(arena: std.mem.Allocator, xs: []const Step) !json.Value {
    const out = try arena.alloc(json.Value, xs.len);
    for (out, xs) |*o, s| {
        var fields: std.ArrayList(json.Field) = .empty;
        try fields.append(arena, .{ .key = "frame", .value = .{ .str = s.frame } });
        try fields.append(arena, .{ .key = "ticks", .value = json.Value.num(s.ticks) });
        if (s.mirrored) try fields.append(arena, .{ .key = "mirrored", .value = .{ .bool = true } });
        if (s.copied.len != 0) {
            const copied = try arena.alloc(json.Value, s.copied.len);
            for (copied, s.copied) |*c, t| c.* = json.Value.num(t);
            try fields.append(arena, .{ .key = "copied", .value = .{ .array = copied } });
        }
        o.* = .{ .object = fields.items };
    }
    return .{ .array = out };
}

fn cellValue(arena: std.mem.Allocator, c: Cell) !json.Value {
    return .{ .array = try arena.dupe(json.Value, &.{ json.Value.num(c.x), json.Value.num(c.y) }) };
}

fn withProvenance(arena: std.mem.Allocator, provenance: []const u8, rest: []const json.Field) !json.Value {
    var fields: std.ArrayList(json.Field) = .empty;
    if (provenance.len != 0) try fields.append(arena, .{ .key = "provenance", .value = .{ .str = provenance } });
    try fields.appendSlice(arena, rest);
    return .{ .object = fields.items };
}

fn roundValue(arena: std.mem.Allocator, r: *const Round) !json.Value {
    const b = &r.banner;
    const players = try arena.alloc(json.Value, 2);
    for (players, &r.status_bar.players) |*o, *p| o.* = try obj(arena, &.{
        .{ .key = "name", .value = .{ .str = p.name } },
        .{ .key = "at", .value = try obj(arena, &.{
            .{ .key = "name", .value = try cellValue(arena, p.name_at) },
            .{ .key = "score", .value = try cellValue(arena, p.score) },
            .{ .key = "health", .value = try cellValue(arena, p.health) },
            .{ .key = "lives", .value = try cellValue(arena, p.lives) },
            .{ .key = "lives_mark", .value = try cellValue(arena, p.lives_mark) },
            .{ .key = "icon", .value = try cellValue(arena, p.icon) },
            .{ .key = "specials", .value = try cellValue(arena, p.specials) },
            .{ .key = "specials_mark", .value = try cellValue(arena, p.specials_mark) },
        }) },
    });
    const t = &r.time_over;
    return obj(arena, &.{
        .{ .key = "banner", .value = try withProvenance(arena, b.provenance, &.{
            .{ .key = "left", .value = .{ .str = b.left } },
            .{ .key = "number", .value = .{ .str = b.number } },
            .{ .key = "right", .value = .{ .str = b.right } },
            .{ .key = "fade", .value = json.Value.num(b.fade) },
            .{ .key = "in", .value = json.Value.num(b.in) },
            .{ .key = "in_ticks", .value = json.Value.num(b.in_ticks) },
            .{ .key = "wait", .value = json.Value.num(b.wait) },
            .{ .key = "out", .value = json.Value.num(b.out) },
            .{ .key = "out_ticks", .value = json.Value.num(b.out_ticks) },
            .{ .key = "after", .value = json.Value.num(b.after) },
        }) },
        .{ .key = "pause", .value = try withProvenance(arena, r.pause.provenance, &.{.{ .key = "frame", .value = .{ .str = r.pause.frame } }}) },
        .{ .key = "time_over", .value = try withProvenance(arena, t.provenance, &.{
            .{ .key = "frame", .value = .{ .str = t.frame } },
            .{ .key = "ticks", .value = json.Value.num(t.ticks) },
            .{ .key = "health", .value = json.Value.num(t.health) },
            .{ .key = "seconds", .value = json.Value.num(t.seconds) },
        }) },
        .{ .key = "status_bar", .value = try withProvenance(arena, r.status_bar.provenance, &.{
            .{ .key = "players", .value = .{ .array = players } },
            .{ .key = "time", .value = try cellValue(arena, r.status_bar.time) },
            .{ .key = "join", .value = try obj(arena, &.{
                .{ .key = "text", .value = .{ .str = r.status_bar.join.text } },
                .{ .key = "at", .value = try cellValue(arena, r.status_bar.join.at) },
                .{ .key = "blink", .value = json.Value.num(r.status_bar.join.blink) },
            }) },
        }) },
    });
}

/// The JSON of record `name` of `s`.
pub fn value(arena: std.mem.Allocator, s: *const Screens, name: []const u8) error{OutOfMemory}!json.Value {
    if (std.mem.eql(u8, name, "round")) return roundValue(arena, &s.round.?);
    if (std.mem.eql(u8, name, "options")) {
        const o = s.options.?;
        const entries = try arena.alloc(json.Value, o.sound_test.len);
        for (entries, o.sound_test) |*e, t| e.* = try obj(arena, &.{ .{ .key = "name", .value = .{ .str = t.name } }, .{ .key = "sound", .value = .{ .str = t.sound } } });
        const choices = try arena.alloc(json.Value, o.controls.len);
        for (choices, o.controls) |*c, lines| c.* = try strings(arena, lines);
        return obj(arena, &.{
            .{ .key = "sound_test", .value = try listed(arena, o.provenance.sound_test, "entries", .{ .array = entries }) },
            .{ .key = "levels", .value = try listed(arena, o.provenance.levels, "names", try strings(arena, o.levels)) },
            .{ .key = "controls", .value = try listed(arena, o.provenance.controls, "choices", .{ .array = choices }) },
        });
    }
    if (std.mem.eql(u8, name, "high_scores")) {
        const h = s.high_scores.?;
        const entries = try arena.alloc(json.Value, h.first.len);
        for (entries, h.first) |*e, x| e.* = try obj(arena, &.{
            .{ .key = "score", .value = json.Value.num(x.score) },
            .{ .key = "round", .value = json.Value.num(x.round) },
            .{ .key = "name", .value = .{ .str = x.name } },
            .{ .key = "level", .value = json.Value.num(x.level) },
        });
        return obj(arena, &.{.{ .key = "first", .value = try listed(arena, h.provenance, "entries", .{ .array = entries }) }});
    }
    if (std.mem.eql(u8, name, "intro")) {
        const it = s.intro.?;
        const profiles = try arena.alloc(json.Value, it.profiles.len);
        for (profiles, it.profiles) |*o, p| o.* = try obj(arena, &.{
            .{ .key = "text", .value = .{ .str = p.text } },
            .{ .key = "plane", .value = .{ .str = @tagName(p.plane) } },
            .{ .key = "at", .value = .{ .array = try arena.dupe(json.Value, &.{ json.Value.num(p.x), json.Value.num(p.y) }) } },
        });
        const entries = try arena.alloc(json.Value, it.script.len);
        for (entries, it.script) |*o, e| o.* = try obj(arena, &.{
            .{ .key = "part", .value = .{ .str = e.part } },
            .{ .key = "wait", .value = json.Value.num(e.wait) },
            .{ .key = "life", .value = json.Value.num(e.life) },
        });
        return obj(arena, &.{
            .{ .key = "story", .value = try listed(arena, it.provenance.story, "lines", try strings(arena, it.story)) },
            .{ .key = "profiles", .value = try listed(arena, it.provenance.profiles, "entries", .{ .array = profiles }) },
            .{ .key = "script", .value = try listed(arena, it.provenance.script, "entries", .{ .array = entries }) },
        });
    }
    if (std.mem.eql(u8, name, "select")) {
        const sel = s.select.?;
        var fields: [3]json.Field = undefined;
        inline for (.{ "adam", "axel", "blaze" }, 0..) |who, i| {
            const p = @field(sel, who);
            var pf: std.ArrayList(json.Field) = .empty;
            if (p.provenance.len != 0) try pf.append(arena, .{ .key = "provenance", .value = .{ .str = p.provenance } });
            inline for (.{ "stand", "idle", "pose_a", "pose_b", "pose_c" }) |pose| {
                try pf.append(arena, .{ .key = pose, .value = try steps(arena, @field(p, pose)) });
            }
            if (p.landing.len != 0) try pf.append(arena, .{ .key = "landing", .value = try steps(arena, p.landing) });
            fields[i] = .{ .key = who, .value = .{ .object = pf.items } };
        }
        return obj(arena, &.{.{ .key = "characters", .value = try obj(arena, &fields) }});
    }
    unreachable;
}

// --- Reading ---------------------------------------------------------------------------------

fn readStrings(arena: std.mem.Allocator, n: json.Node) Error![]const []const u8 {
    const out = try arena.alloc([]const u8, try n.len());
    for (out, 0..) |*o, i| o.* = try (try n.at(i)).string();
    return out;
}

/// A list with its provenance; returns the list's node.
fn readListed(n: json.Node, key: []const u8, provenance: *[]const u8) Error!json.Node {
    try n.only(&.{ "provenance", key });
    provenance.* = if (try n.opt("provenance")) |p| try p.string() else "";
    return n.get(key);
}

fn readSteps(arena: std.mem.Allocator, n: json.Node, a: ?*const art.Art) Error![]const Step {
    const out = try arena.alloc(Step, try n.len());
    if (out.len == 0) return n.fail("no step");
    for (out, 0..) |*s, i| {
        const e = try n.at(i);
        try e.only(&.{ "frame", "ticks", "mirrored", "copied" });
        const frame = try e.get("frame");
        s.* = .{
            .frame = try frame.string(),
            .ticks = try (try e.get("ticks")).int(u8),
            .mirrored = if (try e.opt("mirrored")) |m| try m.boolean() else false,
        };
        if (try e.opt("copied")) |c| {
            const copied = try arena.alloc(u16, try c.len());
            if (copied.len > max_copies) return c.fail("more copies than a frame has");
            for (copied, 0..) |*t, k| t.* = try (try c.at(k)).int(u16);
            s.copied = copied;
        }
        if (a) |x| if (x.frame(s.frame) == null) return frame.fail("no frame of this name in the art");
        if (s.ticks == 0) return (try e.get("ticks")).fail("not 1 or more");
    }
    return out;
}

fn readCell(n: json.Node) Error!Cell {
    if (try n.len() != 2) return n.fail("not [x, y]");
    const c: Cell = .{ .x = try (try n.at(0)).int(u8), .y = try (try n.at(1)).int(u8) };
    if (c.x >= 40 or c.y >= 4) return n.fail("not a cell of the status bar (40 x 4)");
    return c;
}

/// A frame's name, checked against the art when given.
fn readFrame(n: json.Node, a: ?*const art.Art) Error![]const u8 {
    const f = try n.string();
    if (a) |x| if (x.frame(f) == null) return n.fail("no frame of this name in the art");
    return f;
}

fn readRound(n: json.Node, a: ?*const art.Art) Error!Round {
    try n.only(&.{ "banner", "pause", "time_over", "status_bar" });
    const b = try n.get("banner");
    try b.only(&.{ "provenance", "left", "number", "right", "fade", "in", "in_ticks", "wait", "out", "out_ticks", "after" });
    const p = try n.get("pause");
    try p.only(&.{ "provenance", "frame" });
    const t = try n.get("time_over");
    try t.only(&.{ "provenance", "frame", "ticks", "health", "seconds" });
    const s = try n.get("status_bar");
    try s.only(&.{ "provenance", "players", "time", "join" });
    const j = try s.get("join");
    try j.only(&.{ "text", "at", "blink" });
    const ps = try s.get("players");
    if (try ps.len() != 2) return ps.fail("not the two players'");
    var players: [2]BarPlayer = undefined;
    for (&players, 0..) |*o, k| {
        const e = try ps.at(k);
        try e.only(&.{ "name", "at" });
        const at = try e.get("at");
        try at.only(&.{ "name", "score", "health", "lives", "lives_mark", "icon", "specials", "specials_mark" });
        o.* = .{
            .name = try (try e.get("name")).string(),
            .name_at = try readCell(try at.get("name")),
            .score = try readCell(try at.get("score")),
            .health = try readCell(try at.get("health")),
            .lives = try readCell(try at.get("lives")),
            .lives_mark = try readCell(try at.get("lives_mark")),
            .icon = try readCell(try at.get("icon")),
            .specials = try readCell(try at.get("specials")),
            .specials_mark = try readCell(try at.get("specials_mark")),
        };
    }
    const r: Round = .{
        .banner = .{
            .provenance = if (try b.opt("provenance")) |x| try x.string() else "",
            .left = try readFrame(try b.get("left"), a),
            .number = try readFrame(try b.get("number"), a),
            .right = try readFrame(try b.get("right"), a),
            .fade = try (try b.get("fade")).int(u8),
            .in = try (try b.get("in")).int(u8),
            .in_ticks = try (try b.get("in_ticks")).int(u16),
            .wait = try (try b.get("wait")).int(u16),
            .out = try (try b.get("out")).int(u8),
            .out_ticks = try (try b.get("out_ticks")).int(u16),
            .after = try (try b.get("after")).int(u16),
        },
        .pause = .{ .provenance = if (try p.opt("provenance")) |x| try x.string() else "", .frame = try readFrame(try p.get("frame"), a) },
        .time_over = .{
            .provenance = if (try t.opt("provenance")) |x| try x.string() else "",
            .frame = try readFrame(try t.get("frame"), a),
            .ticks = try (try t.get("ticks")).int(u16),
            .health = try (try t.get("health")).int(u8),
            .seconds = try (try t.get("seconds")).int(u8),
        },
        .status_bar = .{
            .provenance = if (try s.opt("provenance")) |x| try x.string() else "",
            .players = players,
            .time = try readCell(try s.get("time")),
            .join = .{ .text = try (try j.get("text")).string(), .at = try readCell(try j.get("at")), .blink = try (try j.get("blink")).int(u8) },
        },
    };
    if (r.status_bar.join.blink == 0) return (try j.get("blink")).fail("not 1 or more");
    if (r.banner.fade == 0 or r.banner.fade > 64) return (try b.get("fade")).fail("not 1 to 64 colours");
    if (r.banner.in_ticks == 0 or r.banner.out_ticks == 0 or r.banner.wait == 0 or r.banner.after == 0) return b.fail("a part of no ticks");
    if (r.time_over.ticks == 0) return (try t.get("ticks")).fail("not 1 or more");
    return r;
}

/// Reads record `name` (its file's parsed `root`) into `into`; frames are checked against `a`.
pub fn read(arena: std.mem.Allocator, name: []const u8, root: json.Node, a: ?*const art.Art, into: *Screens) Error!void {
    if (std.mem.eql(u8, name, "round")) {
        into.round = try readRound(root, a);
        return;
    }
    if (std.mem.eql(u8, name, "options")) {
        try root.only(&.{ "sound_test", "levels", "controls" });
        var o: Options = .{ .sound_test = &.{}, .levels = &.{}, .controls = &.{} };
        const entries = try readListed(try root.get("sound_test"), "entries", &o.provenance.sound_test);
        const st = try arena.alloc(SoundTestEntry, try entries.len());
        for (st, 0..) |*e, i| {
            const n = try entries.at(i);
            try n.only(&.{ "name", "sound" });
            e.* = .{ .name = try (try n.get("name")).string(), .sound = try (try n.get("sound")).string() };
        }
        o.sound_test = st;
        const levels = try readListed(try root.get("levels"), "names", &o.provenance.levels);
        o.levels = try readStrings(arena, levels);
        const c = try readListed(try root.get("controls"), "choices", &o.provenance.controls);
        const choices = try arena.alloc([]const []const u8, try c.len());
        for (choices, 0..) |*x, i| x.* = try readStrings(arena, try c.at(i));
        o.controls = choices;
        if (o.levels.len == 0) return levels.fail("no level");
        if (o.controls.len == 0) return c.fail("no choice");
        if (o.sound_test.len == 0) return entries.fail("no entry");
        into.options = o;
        return;
    }
    if (std.mem.eql(u8, name, "high_scores")) {
        try root.only(&.{"first"});
        var h: HighScores = .{ .first = &.{} };
        const entries = try readListed(try root.get("first"), "entries", &h.provenance);
        const out = try arena.alloc(Score, try entries.len());
        for (out, 0..) |*e, i| {
            const n = try entries.at(i);
            try n.only(&.{ "score", "round", "name", "level" });
            e.* = .{
                .score = try (try n.get("score")).int(u32),
                .round = try (try n.get("round")).int(u8),
                .name = try (try n.get("name")).string(),
                .level = try (try n.get("level")).int(u8),
            };
            if (e.score > 999_999) return (try n.get("score")).fail("more than 999999");
            if (e.name.len != 3) return (try n.get("name")).fail("not three letters");
        }
        h.first = out;
        into.high_scores = h;
        return;
    }
    if (std.mem.eql(u8, name, "intro")) {
        try root.only(&.{ "story", "profiles", "script" });
        var it: Intro = .{ .story = &.{}, .profiles = &.{}, .script = &.{} };
        it.story = try readStrings(arena, try readListed(try root.get("story"), "lines", &it.provenance.story));
        const ps = try readListed(try root.get("profiles"), "entries", &it.provenance.profiles);
        const profiles = try arena.alloc(Profile, try ps.len());
        for (profiles, 0..) |*p, i| {
            const n = try ps.at(i);
            try n.only(&.{ "text", "plane", "at" });
            const plane = try n.get("plane");
            const at = try n.get("at");
            if (try at.len() != 2) return at.fail("not [x, y]");
            p.* = .{
                .text = try (try n.get("text")).string(),
                .plane = std.meta.stringToEnum(art.Layer, try plane.string()) orelse return plane.fail("not plane_a or plane_b"),
                .x = try (try at.at(0)).int(u16),
                .y = try (try at.at(1)).int(u16),
            };
            if (p.plane == .window) return plane.fail("not plane_a or plane_b");
        }
        it.profiles = profiles;
        const es = try readListed(try root.get("script"), "entries", &it.provenance.script);
        const script = try arena.alloc(ScriptEntry, try es.len());
        for (script, 0..) |*e, i| {
            const n = try es.at(i);
            try n.only(&.{ "part", "wait", "life" });
            e.* = .{ .part = try (try n.get("part")).string(), .wait = try (try n.get("wait")).int(u16), .life = try (try n.get("life")).int(u16) };
        }
        it.script = script;
        into.intro = it;
        return;
    }
    if (std.mem.eql(u8, name, "select")) {
        try root.only(&.{"characters"});
        const chars = try root.get("characters");
        try chars.only(&.{ "adam", "axel", "blaze" });
        var sel: Select = undefined;
        inline for (.{ "adam", "axel", "blaze" }) |who| {
            const n = try chars.get(who);
            try n.only(&.{ "provenance", "stand", "idle", "pose_a", "pose_b", "pose_c", "landing" });
            var p: Poses = .{ .stand = &.{}, .idle = &.{}, .pose_a = &.{}, .pose_b = &.{}, .pose_c = &.{} };
            p.provenance = if (try n.opt("provenance")) |x| try x.string() else "";
            inline for (.{ "stand", "idle", "pose_a", "pose_b", "pose_c" }) |pose| {
                @field(p, pose) = try readSteps(arena, try n.get(pose), a);
            }
            if (try n.opt("landing")) |l| p.landing = try readSteps(arena, l, a);
            @field(sel, who) = p;
        }
        into.select = sel;
        return;
    }
    return root.fail("no screen's record of this name");
}

const testing = std.testing;

test "the screens' records write and read back the same" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stand = [_]Step{.{ .frame = "adam/001", .ticks = 100 }};
    const pose = [_]Step{ .{ .frame = "adam/002", .ticks = 1, .mirrored = true, .copied = &.{ 34, 32 } }, .{ .frame = "adam/012", .ticks = 5, .copied = &.{34} } };
    const poses: Poses = .{ .provenance = "synthetic", .stand = &stand, .idle = &pose, .pose_a = &pose, .pose_b = &pose, .pose_c = &pose };
    var blaze = poses;
    blaze.landing = &stand;
    const s: Screens = .{
        .options = .{
            .provenance = .{ .sound_test = "synthetic", .controls = "synthetic" },
            .sound_test = &.{ .{ .name = "ROUND1", .sound = "round 1 music" }, .{ .name = "SE 1", .sound = "jump" } },
            .levels = &.{ "EASY", "NORMAL" },
            .controls = &.{&.{ "A-ATTACK", "", "B-JUMP" }},
        },
        .high_scores = .{ .first = &.{.{ .score = 100000, .round = 1, .name = "AAA", .level = 1 }} },
        .select = .{ .adam = poses, .axel = poses, .blaze = blaze },
        .round = .{
            .banner = .{ .left = "play/l", .number = "play/n", .right = "play/r", .fade = 17, .in = 4, .in_ticks = 35, .wait = 96, .out = 6, .out_ticks = 24, .after = 48 },
            .pause = .{ .frame = "play/pause" },
            .time_over = .{ .provenance = "synthetic", .frame = "play/time_over", .ticks = 256, .health = 80, .seconds = 55 },
            .status_bar = .{
                .players = @splat(.{ .name = "1UP-", .name_at = .{ .x = 1, .y = 1 }, .score = .{ .x = 5, .y = 1 }, .health = .{ .x = 1, .y = 2 }, .lives = .{ .x = 12, .y = 1 }, .lives_mark = .{ .x = 11, .y = 2 }, .icon = .{ .x = 14, .y = 1 }, .specials = .{ .x = 17, .y = 1 }, .specials_mark = .{ .x = 16, .y = 2 } }),
                .time = .{ .x = 19, .y = 1 },
                .join = .{ .text = "PRESS 2UP START", .at = .{ .x = 24, .y = 1 }, .blink = 8 },
            },
        },
    };
    var names_buf: [record_names.len][]const u8 = undefined;
    for (s.names(&names_buf)) |name| {
        const text = try json.write(arena, try value(arena, &s, name));
        var diag: json.Diagnostic = .{};
        const root = try json.parse(arena, try path(arena, name), text, &diag);
        var back: Screens = .{};
        try read(arena, name, root, null, &back);
        const again = try json.write(arena, try value(arena, &back, name));
        try testing.expectEqualStrings(text, again);
    }
    // A refusal names the field.
    var diag: json.Diagnostic = .{};
    const bad = try json.parse(arena, "screens/high_scores.json", "{\"first\": {\"entries\": [{\"score\": 1, \"round\": 1, \"name\": \"AB\", \"level\": 0}]}}", &diag);
    var out: Screens = .{};
    try testing.expectError(error.BadAsset, read(arena, "high_scores", bad, null, &out));
    try testing.expectEqualStrings("first.entries[0].name", diag.fieldName());
}

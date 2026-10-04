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

/// The screens' records a tree has.
pub const Screens = struct {
    options: ?Options = null,
    high_scores: ?HighScores = null,
    select: ?Select = null,
    intro: ?Intro = null,

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
pub const record_names = [_][]const u8{ "high_scores", "intro", "options", "select" };

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

/// The JSON of record `name` of `s`.
pub fn value(arena: std.mem.Allocator, s: *const Screens, name: []const u8) error{OutOfMemory}!json.Value {
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

/// Reads record `name` (its file's parsed `root`) into `into`; frames are checked against `a`.
pub fn read(arena: std.mem.Allocator, name: []const u8, root: json.Node, a: ?*const art.Art, into: *Screens) Error!void {
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

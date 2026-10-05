//! A round's script (docs/content.md, "rounds/NAME.json"; DESIGN.md W6): what the round shows and
//! who comes, as the original's level events run it. The extractor writes it from the ROM's
//! tables; a modder moves a wall or a wave by editing it.
//!
//! - The round's art set (its planes, colours and cycles), its music, where its camera starts and
//!   how far it may go, where the players drop in, the timer's pace.
//! - Its sections, each the stretch up to a wall the camera stops at until the section is
//!   cleared. When a section opens, its `placed` enemies and props wait at their places, hidden
//!   until their place is on the screen; when the camera reaches its wall, its `wave` comes in
//!   one after the other at the screen's edges; once the wave is in, each of its enemies that
//!   goes calls one of its `reserve`. The section is cleared when the last of its enemies goes:
//!   the next section's placed enemies come, and after its art's load the wall moves on, the GO
//!   arrow shows and the timer starts again.
//! - The boss's section: after the last section, the camera stops where it is, the music fades,
//!   the boss's music comes, then its wave. A beaten boss ends the round.
//!
//! A spawn names the kind of entity by its definition's name (`entities/NAME.json`); a kind the
//! content does not define is kept (the game skips it, with a warning), so that a round's script
//! is whole before every kind is written.
const std = @import("std");
const json = @import("../formats/json.zig");
const art = @import("art.zig");

pub const Error = json.Error;

/// The screen's edge a wave's or a reserve's enemy comes in at.
pub const Side = enum { right, left };

/// How an enemy comes in (its behaviour's way of approaching first), by its record.
pub const Entrance = enum { approach, close_in, edge, wait, shutter, square_up, jump_in, size_up, follow, enter, circle };

/// What an enemy's record says of it besides its entrance, or a piece of scenery's of it, each
/// written only when true.
pub const Trait = enum {
    /// It waits hidden until the camera has reached its place, not only until its place is on
    /// the screen.
    waits_for_camera,
    slow,
    closes_in_after_lurking,
    pipe_b,
    slides,
    flips_away,
    drops_in,
    flips_at_close_range,
    unflinching,
    walks_off,
    twin,
    /// A piece of scenery stirs while a flight passes (round 2's posters' corners).
    stirs,
};

pub const Traits = std.EnumSet(Trait);

/// How a drifting piece of scenery moves (round 3's, on the beach): it stays; it drifts away; it
/// drifts and stops in turn; it rides the waves, rising as each comes and coming back.
pub const Drift = enum { still, drifts, stops, waves };

pub const Offset = struct { x: i16 = 0, depth: i16 = 0 };

/// A display tick's share of the art the round streams in while it plays (its enemies' and its
/// boss's, loaded as they come): the tiles it decodes and the decoder's reads, its codes (those
/// written out in full, `long_codes`, among them) and its bytes: the game's work before the
/// sound's driver in that display tick (screens/transfers.zig). A list of them runs from the end
/// of the tick of what loads the art, a display tick each (the next tick's middle, its end...);
/// a display tick decoding nothing is all zeros.
pub const Streamed = struct {
    tiles: u8 = 0,
    codes: u16 = 0,
    long_codes: u8 = 0,
    bytes: u16 = 0,
};

/// Which of a round's streamed lists: a section's (the boss's, `part` the sections' count), or
/// one of its reserve's records'; a section's art again after the special attack (`again`); or
/// the special attack's of a caller (`special`: player 1's, player 2's), as its police car comes.
pub const StreamOf = struct {
    part: u8 = 0,
    record: ?u8 = null,
    again: bool = false,
    special: ?u1 = null,

    pub fn of(self: StreamOf, r: *const Round) []const Streamed {
        if (self.special) |k| return r.special.streamed[k];
        if (self.part < r.sections.len) {
            const s = &r.sections[self.part];
            if (self.again) return s.again;
            return if (self.record) |k| s.reserve[k].streamed else s.streamed;
        }
        const b = &(r.boss orelse return &.{});
        if (self.again) return b.again;
        return if (self.record) |k| b.reserve[k].streamed else b.streamed;
    }
};

/// The enemies' colours a section holds as it begins, each by its number (play's
/// `enemy_colours`): the first (the enemies' first palette line), the second (their second line)
/// and the other (the first line's other colours, some kinds' own); null: none given.
pub const Colours = struct { first: ?u8 = null, second: ?u8 = null, other: ?u8 = null };

/// One entity the script brings: placed ahead at its place, or coming in at the screen's edge.
pub const Spawn = struct {
    /// The kind's name (`entities/NAME.json`).
    kind: []const u8,
    /// Placed: its place across the level, in pixels. A wave's or a reserve's comes in at the
    /// screen's `side`.
    x: i32 = 0,
    side: Side = .right,
    /// Its depth on the ground, in pixels.
    depth: i32,
    /// A wave's: the ticks after the one before it (the first: after the camera reached the
    /// wall).
    after: u16 = 0,
    /// A reserve's: the ticks from its call (one of the section's enemies going) to its coming
    /// in.
    arrives_after: u16 = 0,
    /// The lowest LEVEL of the options it comes at (0, the easiest: always).
    level: u2 = 0,
    /// It comes only with two players.
    two_players: bool = false,
    /// An enemy's way in, its traits, where it keeps from its target, its strength.
    entrance: ?Entrance = null,
    traits: Traits = .empty,
    offset: ?Offset = null,
    strength: u8 = 0,
    /// A breakable's: the kind of item it holds.
    holds: ?[]const u8 = null,
    /// Placed: the height a piece of scenery takes as it starts (on a wall), placed on the ground.
    height: ?i32 = null,
    /// Placed: how a drifting piece of scenery moves.
    drift: ?Drift = null,
    /// A boss's: its entry in the status bar's names and bars.
    bar: ?u8 = null,
    /// A reserve's: its kind's art streamed in from its call.
    streamed: []const Streamed = &.{},
    /// An enemy's colours, by their number (play's `enemy_colours`); null: its kind's own.
    colours: ?u8 = null,
};

pub const Section = struct {
    provenance: []const u8 = "",
    /// The camera's right limit until the section is cleared, in pixels across the level.
    wall: i32,
    /// The timer's seconds when the section opens.
    timer: u8,
    /// The ticks from the section's start (the last section's clear; for the first, the round's
    /// start, the tick before its first tick of play) to its opening: the wall in place, the GO
    /// arrow and the timer (the first section's are the round's own), and its wave waiting for
    /// the camera.
    opens_after: u16,
    /// Its art (its kinds' and the boss's), streamed in from its start (the first section's
    /// from the round's start).
    streamed: []const Streamed = &.{},
    /// The art of its enemies the special attack's car took the place of (the boss's, or its
    /// second art kind's), streamed in again as the camera comes back.
    again: []const Streamed = &.{},
    /// The enemies' colours it holds as it begins.
    colours: Colours = .{},
    placed: []const Spawn = &.{},
    wave: []const Spawn = &.{},
    reserve: []const Spawn = &.{},
};

pub const Boss = struct {
    provenance: []const u8 = "",
    /// The sound asked for when the section opens (the music fading), and the music.
    fade: []const u8,
    music: []const u8,
    /// The ticks from the last section's clear to the boss's music, and from the music to the
    /// wave.
    music_after: u16,
    wave_after: u16,
    /// The boss's art, then the section's and the boss's again, streamed in from the last
    /// section's clear.
    streamed: []const Streamed = &.{},
    /// The boss's art again after the special attack, as a section's (`Section.again`).
    again: []const Streamed = &.{},
    /// The enemies' colours its section holds as it begins (`Section.colours`), and the boss's
    /// own (a palette of the art, full name), shown as its music is asked for.
    section_colours: Colours = .{},
    colours: ?[]const u8 = null,
    wave: []const Spawn = &.{},
    reserve: []const Spawn = &.{},
};

/// The special attack's art, streamed in as its police car comes, by its caller (player 1's,
/// player 2's): the car's, then the caller's weapon's.
pub const Special = struct {
    provenance: []const u8 = "",
    streamed: [2][]const Streamed = .{ &.{}, &.{} },
};

pub const Camera = struct {
    provenance: []const u8 = "",
    /// The view's top-left corner at the round's start, in pixels of the level.
    x: i32,
    y: i32,
    /// How far it may go at the start: across, from `x_min` (the wall is the first section's),
    /// and down.
    x_min: i32,
    y_min: i32,
    y_max: i32,
    /// Plane B scrolls across by `times` / `per` of the camera's move.
    plane_b: [2]u8 = .{ 1, 1 },
    /// Plane B moves down as plane A does (the camera's shake too); else it keeps its place
    /// down, the camera's at the start.
    plane_b_down: bool = false,
    /// The camera has reached a section's wall when it is less than this from it.
    wall_within: i32 = 4,
    /// Where a wave's or a reserve's record comes in, across from the camera's left edge: on the
    /// left, on the right.
    edges: [2]i32 = .{ -8, 328 },
    /// Where the enemies left behind come back to when the camera reaches the wall: across from
    /// the camera's left edge (those at or behind it come), and the depth.
    left_behind: [2]i32 = .{ -32, 96 },
    /// A player drawn left of `follow[0]` or from `follow[1]` on, across the screen, moves the
    /// camera by as much, at most `follow_most` pixels a tick.
    follow: [2]i16,
    follow_most: i16,
    /// The players are kept within `kept_x` across from the camera's left edge (but in a hold),
    /// and within the depths `kept_depth`.
    kept_x: [2]i16,
    kept_depth: [2]i16,
    /// A heavy fall shakes the camera `shake[0]` ticks, `shake[1]` pixels down and up in turn.
    shake: [2]i16,
    /// Each plane's bands (plane A's, then plane B's), from the top: as a band's place across
    /// (its plane's times `times` / `per`) crosses a column of blocks (16 pixels), the game
    /// writes the column of blocks coming in, `rows` blocks high; as the camera crosses a row of
    /// blocks, the row (32 blocks).
    bands: [2][]const Band = .{ &.{}, &.{} },
};

pub const Band = struct { rows: u8, times: u8, per: u8 };

pub const Players = struct {
    provenance: []const u8 = "",
    /// Where a life starts, and the drop's place: across from the camera's left edge, the
    /// depth of each player, the height (from the top: they drop in).
    x: i32,
    depth: [2]i32,
    height: i32,
};

pub const Timer = struct {
    provenance: []const u8 = "",
    /// The ticks a second lasts.
    pace: u8,
};

pub const Round = struct {
    /// The round's number, from 1.
    number: u8,
    provenance: []const u8 = "",
    /// The art set of its planes, colours and cycles.
    art: []const u8,
    /// The sound of its music.
    music: []const u8,
    /// The height of its ground, where its enemies stand and its players land (it grows
    /// downward, as the screen's lines).
    ground: i32,
    /// The display ticks its load holds the picture dark after its set-up, as the original's
    /// lasts; null: the flow's.
    load: ?u16 = null,
    camera: Camera,
    players: Players,
    timer: Timer,
    sections: []const Section,
    /// The special attack's art (its police car's), streamed in as the car comes.
    special: Special = .{},
    boss: ?Boss = null,
    /// A sound the round plays by itself.
    own_sound: ?OwnSound = null,
};

/// A sound a round plays by itself (round 3's waves): `sound` (a name of the sound content),
/// `times` times, the first at play's `first`th tick, then every `every` ticks; counted again
/// from each section's opening. It counts in play, the special attack's too.
pub const OwnSound = struct {
    provenance: []const u8 = "",
    sound: []const u8,
    first: u8,
    every: u8,
    times: u8,
};

/// The rounds a tree may have, by their files' names.
pub fn path(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "rounds/{s}.json", .{name});
}

/// The name of round `number`'s file ("round1").
pub fn nameOf(buf: []u8, number: u8) []const u8 {
    return std.fmt.bufPrint(buf, "round{d}", .{number}) catch unreachable;
}

// --- Writing ---------------------------------------------------------------------------------

fn obj(arena: std.mem.Allocator, fields: []const json.Field) !json.Value {
    return .{ .object = try arena.dupe(json.Field, fields) };
}

fn bandsValue(arena: std.mem.Allocator, bands: [2][]const Band) !json.Value {
    const planes = try arena.alloc(json.Value, 2);
    for (planes, bands) |*o, list| {
        const items = try arena.alloc(json.Value, list.len);
        for (items, list) |*v, b| v.* = .{ .array = try arena.dupe(json.Value, &.{ json.Value.num(b.rows), json.Value.num(b.times), json.Value.num(b.per) }) };
        o.* = .{ .array = items };
    }
    return .{ .array = planes };
}

fn pair(arena: std.mem.Allocator, a: anytype, b: anytype) !json.Value {
    return .{ .array = try arena.dupe(json.Value, &.{ json.Value.num(a), json.Value.num(b) }) };
}

/// The fields of a record, its provenance first when it has one.
fn cameraValue(arena: std.mem.Allocator, c: *const Camera) !json.Value {
    var f: std.ArrayList(json.Field) = .empty;
    try f.appendSlice(arena, &.{
        .{ .key = "at", .value = try pair(arena, c.x, c.y) },
        .{ .key = "x_min", .value = json.Value.num(c.x_min) },
        .{ .key = "y", .value = try pair(arena, c.y_min, c.y_max) },
        .{ .key = "plane_b", .value = try pair(arena, c.plane_b[0], c.plane_b[1]) },
        .{ .key = "wall_within", .value = json.Value.num(c.wall_within) },
        .{ .key = "edges", .value = try pair(arena, c.edges[0], c.edges[1]) },
        .{ .key = "left_behind", .value = try pair(arena, c.left_behind[0], c.left_behind[1]) },
        .{ .key = "follow", .value = try pair(arena, c.follow[0], c.follow[1]) },
        .{ .key = "follow_most", .value = json.Value.num(c.follow_most) },
        .{ .key = "kept_x", .value = try pair(arena, c.kept_x[0], c.kept_x[1]) },
        .{ .key = "kept_depth", .value = try pair(arena, c.kept_depth[0], c.kept_depth[1]) },
        .{ .key = "shake", .value = try pair(arena, c.shake[0], c.shake[1]) },
        .{ .key = "bands", .value = try bandsValue(arena, c.bands) },
    });
    if (c.plane_b_down) try f.append(arena, .{ .key = "plane_b_down", .value = .{ .bool = true } });
    return withProvenance(arena, c.provenance, f.items);
}

fn withProvenance(arena: std.mem.Allocator, provenance: []const u8, rest: []const json.Field) !json.Value {
    var fields: std.ArrayList(json.Field) = .empty;
    if (provenance.len != 0) try fields.append(arena, .{ .key = "provenance", .value = .{ .str = provenance } });
    try fields.appendSlice(arena, rest);
    return .{ .object = fields.items };
}

pub const Where = enum { placed, wave, reserve };

fn spawnValue(arena: std.mem.Allocator, s: *const Spawn, where: Where) !json.Value {
    var f: std.ArrayList(json.Field) = .empty;
    try f.append(arena, .{ .key = "kind", .value = .{ .str = s.kind } });
    switch (where) {
        .placed => try f.append(arena, .{ .key = "x", .value = json.Value.num(s.x) }),
        .wave, .reserve => try f.append(arena, .{ .key = "side", .value = .{ .str = @tagName(s.side) } }),
    }
    try f.append(arena, .{ .key = "depth", .value = json.Value.num(s.depth) });
    if (s.height) |h| try f.append(arena, .{ .key = "height", .value = json.Value.num(h) });
    if (s.drift) |d| try f.append(arena, .{ .key = "drift", .value = .{ .str = @tagName(d) } });
    if (where == .wave) try f.append(arena, .{ .key = "after", .value = json.Value.num(s.after) });
    if (where == .reserve) try f.append(arena, .{ .key = "arrives_after", .value = json.Value.num(s.arrives_after) });
    if (s.level != 0) try f.append(arena, .{ .key = "level", .value = json.Value.num(s.level) });
    if (s.two_players) try f.append(arena, .{ .key = "two_players", .value = .{ .bool = true } });
    if (s.entrance) |e| try f.append(arena, .{ .key = "entrance", .value = .{ .str = @tagName(e) } });
    var it = s.traits.iterator();
    while (it.next()) |t| try f.append(arena, .{ .key = @tagName(t), .value = .{ .bool = true } });
    if (s.offset) |o| try f.append(arena, .{ .key = "offset", .value = try obj(arena, &.{
        .{ .key = "x", .value = json.Value.num(o.x) },
        .{ .key = "depth", .value = json.Value.num(o.depth) },
    }) });
    if (s.strength != 0) try f.append(arena, .{ .key = "strength", .value = json.Value.num(s.strength) });
    if (s.holds) |h| try f.append(arena, .{ .key = "holds", .value = .{ .str = h } });
    if (s.bar) |b| try f.append(arena, .{ .key = "bar", .value = json.Value.num(b) });
    if (where == .reserve and s.streamed.len != 0) try f.append(arena, .{ .key = "streamed", .value = try streamedValue(arena, s.streamed) });
    if (s.colours) |c| try f.append(arena, .{ .key = "colours", .value = json.Value.num(c) });
    return .{ .object = f.items };
}

fn coloursValue(arena: std.mem.Allocator, c: Colours) !json.Value {
    var f: std.ArrayList(json.Field) = .empty;
    inline for (.{ "first", "second", "other" }) |name| if (@field(c, name)) |n| try f.append(arena, .{ .key = name, .value = json.Value.num(n) });
    return .{ .object = f.items };
}

fn readColours(n: json.Node) Error!Colours {
    try n.only(&.{ "first", "second", "other" });
    var c: Colours = .{};
    inline for (.{ "first", "second", "other" }) |name| if (try n.opt(name)) |x| {
        @field(c, name) = try x.int(u8);
    };
    return c;
}

/// A list of display ticks' streaming: each [tiles, codes, long codes, bytes].
fn streamedValue(arena: std.mem.Allocator, list: []const Streamed) !json.Value {
    const out = try arena.alloc(json.Value, list.len);
    for (out, list) |*o, s| {
        const four = try arena.alloc(json.Value, 4);
        four[0] = json.Value.num(s.tiles);
        four[1] = json.Value.num(s.codes);
        four[2] = json.Value.num(s.long_codes);
        four[3] = json.Value.num(s.bytes);
        o.* = .{ .array = four };
    }
    return .{ .array = out };
}

fn spawnsValue(arena: std.mem.Allocator, list: []const Spawn, where: Where) !json.Value {
    const out = try arena.alloc(json.Value, list.len);
    for (out, list) |*o, *s| o.* = try spawnValue(arena, s, where);
    return .{ .array = out };
}

/// The JSON of round `r`.
pub fn value(arena: std.mem.Allocator, r: *const Round) error{OutOfMemory}!json.Value {
    const sections = try arena.alloc(json.Value, r.sections.len);
    for (sections, r.sections) |*o, *s| o.* = try withProvenance(arena, s.provenance, &.{
        .{ .key = "wall", .value = json.Value.num(s.wall) },
        .{ .key = "timer", .value = json.Value.num(s.timer) },
        .{ .key = "opens_after", .value = json.Value.num(s.opens_after) },
        .{ .key = "streamed", .value = try streamedValue(arena, s.streamed) },
        .{ .key = "again", .value = try streamedValue(arena, s.again) },
        .{ .key = "colours", .value = try coloursValue(arena, s.colours) },
        .{ .key = "placed", .value = try spawnsValue(arena, s.placed, .placed) },
        .{ .key = "wave", .value = try spawnsValue(arena, s.wave, .wave) },
        .{ .key = "reserve", .value = try spawnsValue(arena, s.reserve, .reserve) },
    });
    const c = &r.camera;
    const p = &r.players;
    var fields: std.ArrayList(json.Field) = .empty;
    try fields.appendSlice(arena, &.{
        .{ .key = "round", .value = json.Value.num(r.number) },
        .{ .key = "art", .value = .{ .str = r.art } },
        .{ .key = "music", .value = .{ .str = r.music } },
        .{ .key = "ground", .value = json.Value.num(r.ground) },
        .{ .key = "camera", .value = try cameraValue(arena, c) },
        .{ .key = "players", .value = try withProvenance(arena, p.provenance, &.{
            .{ .key = "x", .value = json.Value.num(p.x) },
            .{ .key = "depth", .value = try pair(arena, p.depth[0], p.depth[1]) },
            .{ .key = "height", .value = json.Value.num(p.height) },
        }) },
        .{ .key = "timer", .value = try withProvenance(arena, r.timer.provenance, &.{
            .{ .key = "pace", .value = json.Value.num(r.timer.pace) },
        }) },
        .{ .key = "sections", .value = .{ .array = sections } },
    });
    if (r.load) |l| try fields.append(arena, .{ .key = "load", .value = json.Value.num(l) });
    if (r.special.streamed[0].len != 0 or r.special.streamed[1].len != 0) {
        const both = try arena.alloc(json.Value, 2);
        for (both, r.special.streamed) |*o, list| o.* = try streamedValue(arena, list);
        try fields.append(arena, .{ .key = "special", .value = try withProvenance(arena, r.special.provenance, &.{
            .{ .key = "streamed", .value = .{ .array = both } },
        }) });
    }
    if (r.own_sound) |o| try fields.append(arena, .{ .key = "own_sound", .value = try withProvenance(arena, o.provenance, &.{
        .{ .key = "sound", .value = .{ .str = o.sound } },
        .{ .key = "first", .value = json.Value.num(o.first) },
        .{ .key = "every", .value = json.Value.num(o.every) },
        .{ .key = "times", .value = json.Value.num(o.times) },
    }) });
    if (r.boss) |*b| try fields.append(arena, .{ .key = "boss", .value = try withProvenance(arena, b.provenance, &.{
        .{ .key = "fade", .value = .{ .str = b.fade } },
        .{ .key = "music", .value = .{ .str = b.music } },
        .{ .key = "music_after", .value = json.Value.num(b.music_after) },
        .{ .key = "wave_after", .value = json.Value.num(b.wave_after) },
        .{ .key = "streamed", .value = try streamedValue(arena, b.streamed) },
        .{ .key = "again", .value = try streamedValue(arena, b.again) },
        .{ .key = "section_colours", .value = try coloursValue(arena, b.section_colours) },
        .{ .key = "colours", .value = if (b.colours) |name| .{ .str = name } else .null },
        .{ .key = "wave", .value = try spawnsValue(arena, b.wave, .wave) },
        .{ .key = "reserve", .value = try spawnsValue(arena, b.reserve, .reserve) },
    }) });
    return withProvenance(arena, r.provenance, fields.items);
}

// --- Reading ---------------------------------------------------------------------------------

fn provenanceOf(n: json.Node) Error![]const u8 {
    return if (try n.opt("provenance")) |p| try p.string() else "";
}

fn readBands(arena: std.mem.Allocator, n: json.Node) Error![2][]const Band {
    if (try n.len() != 2) return n.fail("not the two planes' bands");
    var out: [2][]const Band = undefined;
    for (&out, 0..) |*o, k| {
        const list = try n.at(k);
        const bands = try arena.alloc(Band, try list.len());
        for (bands, 0..) |*b, i| {
            const e = try list.at(i);
            if (try e.len() != 3) return e.fail("not [rows, times, per]");
            b.* = .{ .rows = try (try e.at(0)).int(u8), .times = try (try e.at(1)).int(u8), .per = try (try e.at(2)).int(u8) };
            if (b.per == 0 or b.rows == 0) return e.fail("a band of no rows or a ratio per 0");
        }
        o.* = bands;
    }
    return out;
}

fn readPair(n: json.Node, comptime T: type) Error![2]T {
    if (try n.len() != 2) return n.fail("not a pair of numbers");
    return .{ try (try n.at(0)).int(T), try (try n.at(1)).int(T) };
}

/// The fields a spawn record may have, by where it is.
fn spawnFields(comptime where: Where) []const []const u8 {
    const common = [_][]const u8{ "kind", "depth", "level", "two_players", "entrance", "offset", "strength", "holds", "bar", "colours" };
    const own: []const []const u8 = switch (where) {
        .placed => &.{ "x", "height", "drift" },
        .wave => &.{ "side", "after" },
        .reserve => &.{ "side", "arrives_after", "streamed" },
    };
    var traits: [std.enums.values(Trait).len][]const u8 = undefined;
    for (std.enums.values(Trait), &traits) |t, *n| n.* = @tagName(t);
    return &(common ++ own[0..own.len].* ++ traits);
}

fn readStreamed(arena: std.mem.Allocator, n: json.Node) Error![]const Streamed {
    const out = try arena.alloc(Streamed, try n.len());
    for (out, 0..) |*s, i| {
        const e = try n.at(i);
        if (try e.len() != 4) return e.fail("not [tiles, codes, long codes, bytes]");
        s.* = .{ .tiles = try (try e.at(0)).int(u8), .codes = try (try e.at(1)).int(u16), .long_codes = try (try e.at(2)).int(u8), .bytes = try (try e.at(3)).int(u16) };
    }
    return out;
}

fn readSpawn(arena: std.mem.Allocator, n: json.Node, comptime where: Where) Error!Spawn {
    try n.only(comptime spawnFields(where));
    var s: Spawn = .{ .kind = try (try n.get("kind")).string(), .depth = try (try n.get("depth")).int(i32) };
    if (!art.validName(s.kind)) return (try n.get("kind")).fail("not a kind's name (lower case letters, digits and _)");
    switch (where) {
        .placed => {
            s.x = try (try n.get("x")).int(i32);
            if (try n.opt("height")) |h| s.height = try h.int(i16);
            if (try n.opt("drift")) |d| s.drift = std.meta.stringToEnum(Drift, try d.string()) orelse return d.fail("not still, drifts, stops or waves");
        },
        .wave, .reserve => {
            const side = try n.get("side");
            s.side = std.meta.stringToEnum(Side, try side.string()) orelse return side.fail("not right or left");
        },
    }
    if (where == .wave) s.after = try (try n.get("after")).int(u16);
    if (where == .reserve) s.arrives_after = try (try n.get("arrives_after")).int(u16);
    if (try n.opt("level")) |l| s.level = try l.int(u2);
    if (try n.opt("two_players")) |t| s.two_players = try t.boolean();
    if (try n.opt("entrance")) |e| s.entrance = std.meta.stringToEnum(Entrance, try e.string()) orelse return e.fail("not a way of coming in");
    inline for (comptime std.enums.values(Trait)) |t| {
        if (try n.opt(@tagName(t))) |b| if (try b.boolean()) s.traits.insert(t);
    }
    if (try n.opt("offset")) |o| {
        try o.only(&.{ "x", "depth" });
        s.offset = .{ .x = try (try o.get("x")).int(i16), .depth = try (try o.get("depth")).int(i16) };
    }
    if (try n.opt("strength")) |x| s.strength = try x.int(u8);
    if (try n.opt("holds")) |h| {
        s.holds = try h.string();
        if (!art.validName(s.holds.?)) return h.fail("not a kind's name (lower case letters, digits and _)");
    }
    if (try n.opt("bar")) |b| s.bar = try b.int(u8);
    if (where == .reserve) if (try n.opt("streamed")) |l| {
        s.streamed = try readStreamed(arena, l);
    };
    if (try n.opt("colours")) |c| s.colours = try c.int(u8);
    return s;
}

fn readSpawns(arena: std.mem.Allocator, n: json.Node, comptime where: Where) Error![]const Spawn {
    const out = try arena.alloc(Spawn, try n.len());
    for (out, 0..) |*s, i| s.* = try readSpawn(arena, try n.at(i), where);
    return out;
}

/// Reads round `name`'s file (its parsed `root`); `a`, when given, must have its art set.
pub fn read(arena: std.mem.Allocator, name: []const u8, root: json.Node, a: ?*const art.Art) Error!Round {
    try root.only(&.{ "provenance", "round", "art", "music", "ground", "load", "camera", "players", "timer", "sections", "special", "boss", "own_sound" });
    const number = try root.get("round");
    var r: Round = .{
        .number = try number.int(u8),
        .provenance = try provenanceOf(root),
        .art = try (try root.get("art")).string(),
        .music = try (try root.get("music")).string(),
        .ground = try (try root.get("ground")).int(i32),
        .camera = undefined,
        .players = undefined,
        .timer = undefined,
        .sections = &.{},
    };
    if (try root.opt("load")) |l| r.load = try l.int(u16);
    var buf: [16]u8 = undefined;
    if (r.number == 0 or !std.mem.eql(u8, nameOf(&buf, r.number), name)) return number.fail("not the round of this file's name");
    if (a) |x| for (x.sets) |s| {
        if (std.mem.eql(u8, s.name, r.art)) break;
    } else return (try root.get("art")).fail("no art set of this name");

    const c = try root.get("camera");
    try c.only(&.{ "provenance", "at", "x_min", "y", "plane_b", "plane_b_down", "wall_within", "edges", "left_behind", "follow", "follow_most", "kept_x", "kept_depth", "shake", "bands" });
    const at = try readPair(try c.get("at"), i32);
    const y = try readPair(try c.get("y"), i32);
    r.camera = .{
        .provenance = try provenanceOf(c),
        .x = at[0],
        .y = at[1],
        .x_min = try (try c.get("x_min")).int(i32),
        .y_min = y[0],
        .y_max = y[1],
        .plane_b = try readPair(try c.get("plane_b"), u8),
        .plane_b_down = if (try c.opt("plane_b_down")) |n| try n.boolean() else false,
        .wall_within = try (try c.get("wall_within")).int(i32),
        .edges = try readPair(try c.get("edges"), i32),
        .left_behind = try readPair(try c.get("left_behind"), i32),
        .follow = try readPair(try c.get("follow"), i16),
        .follow_most = try (try c.get("follow_most")).int(i16),
        .kept_x = try readPair(try c.get("kept_x"), i16),
        .kept_depth = try readPair(try c.get("kept_depth"), i16),
        .shake = try readPair(try c.get("shake"), i16),
        .bands = try readBands(arena, try c.get("bands")),
    };
    if (r.camera.shake[0] <= 0 or r.camera.shake[0] > 255) return (try c.get("shake")).fail("not 1 to 255 ticks");
    if (r.camera.follow[0] > r.camera.follow[1]) return (try c.get("follow")).fail("its first after its second");
    if (r.camera.follow_most <= 0) return (try c.get("follow_most")).fail("not 1 or more");
    if (r.camera.kept_x[0] > r.camera.kept_x[1]) return (try c.get("kept_x")).fail("its first after its second");
    if (r.camera.kept_depth[0] > r.camera.kept_depth[1]) return (try c.get("kept_depth")).fail("its first after its second");
    if (r.camera.plane_b[1] == 0) return (try c.get("plane_b")).fail("a ratio of 0 per");
    if (r.camera.y_min > r.camera.y_max) return (try c.get("y")).fail("its first above its second");

    const p = try root.get("players");
    try p.only(&.{ "provenance", "x", "depth", "height" });
    r.players = .{
        .provenance = try provenanceOf(p),
        .x = try (try p.get("x")).int(i32),
        .depth = try readPair(try p.get("depth"), i32),
        .height = try (try p.get("height")).int(i32),
    };

    const t = try root.get("timer");
    try t.only(&.{ "provenance", "pace" });
    r.timer = .{ .provenance = try provenanceOf(t), .pace = try (try t.get("pace")).int(u8) };
    if (r.timer.pace == 0) return (try t.get("pace")).fail("not 1 or more");

    const ss = try root.get("sections");
    const sections = try arena.alloc(Section, try ss.len());
    if (sections.len == 0) return ss.fail("no section");
    for (sections, 0..) |*s, i| {
        const n = try ss.at(i);
        try n.only(&.{ "provenance", "wall", "timer", "opens_after", "streamed", "again", "colours", "placed", "wave", "reserve" });
        s.* = .{
            .provenance = try provenanceOf(n),
            .wall = try (try n.get("wall")).int(i32),
            .timer = try (try n.get("timer")).int(u8),
            .opens_after = try (try n.get("opens_after")).int(u16),
            .streamed = try readStreamed(arena, try n.get("streamed")),
            .again = if (try n.opt("again")) |x| try readStreamed(arena, x) else &.{},
            .colours = if (try n.opt("colours")) |x| try readColours(x) else .{},
            .placed = try readSpawns(arena, try n.get("placed"), .placed),
            .wave = try readSpawns(arena, try n.get("wave"), .wave),
            .reserve = try readSpawns(arena, try n.get("reserve"), .reserve),
        };
        if (s.timer > 99) return (try n.get("timer")).fail("more than 99 seconds");
        const before = if (i == 0) r.camera.x else sections[i - 1].wall;
        if (s.wall < before) return (try n.get("wall")).fail("behind the camera's place before it");
    }
    r.sections = sections;

    if (try root.opt("special")) |sp| {
        try sp.only(&.{ "provenance", "streamed" });
        const both = try sp.get("streamed");
        if (try both.len() != 2) return both.fail("not the two callers' lists");
        r.special = .{ .provenance = try provenanceOf(sp), .streamed = .{ try readStreamed(arena, try both.at(0)), try readStreamed(arena, try both.at(1)) } };
    }
    if (try root.opt("own_sound")) |o| {
        try o.only(&.{ "provenance", "sound", "first", "every", "times" });
        r.own_sound = .{
            .provenance = try provenanceOf(o),
            .sound = try (try o.get("sound")).string(),
            .first = try (try o.get("first")).int(u8),
            .every = try (try o.get("every")).int(u8),
            .times = try (try o.get("times")).int(u8),
        };
        if (r.own_sound.?.first == 0) return (try o.get("first")).fail("not 1 or more");
        if (r.own_sound.?.every == 0) return (try o.get("every")).fail("not 1 or more");
    }
    if (try root.opt("boss")) |b| {
        try b.only(&.{ "provenance", "fade", "music", "music_after", "wave_after", "streamed", "again", "section_colours", "colours", "wave", "reserve" });
        r.boss = .{
            .provenance = try provenanceOf(b),
            .fade = try (try b.get("fade")).string(),
            .music = try (try b.get("music")).string(),
            .music_after = try (try b.get("music_after")).int(u16),
            .wave_after = try (try b.get("wave_after")).int(u16),
            .streamed = try readStreamed(arena, try b.get("streamed")),
            .again = if (try b.opt("again")) |x| try readStreamed(arena, x) else &.{},
            .section_colours = if (try b.opt("section_colours")) |x| try readColours(x) else .{},
            .colours = if (try b.opt("colours")) |x| try x.string() else null,
            .wave = try readSpawns(arena, try b.get("wave"), .wave),
            .reserve = try readSpawns(arena, try b.get("reserve"), .reserve),
        };
    }
    return r;
}

const testing = std.testing;

/// A small round, for the tests of the script.
pub const example: Round = .{
    .number = 1,
    .provenance = "synthetic",
    .art = "round1",
    .music = "round 1 music",
    .ground = 160,
    .camera = .{ .x = 768, .y = 0, .x_min = 768, .y_min = 0, .y_max = 0, .follow = .{ 144, 176 }, .follow_most = 3, .kept_x = .{ 32, 288 }, .kept_depth = .{ 2, 112 }, .shake = .{ 8, 3 }, .bands = .{ &.{.{ .rows = 15, .times = 1, .per = 1 }}, &.{.{ .rows = 15, .times = 1, .per = 1 }} } },
    .players = .{ .x = 0, .depth = .{ 64, 32 }, .height = 0 },
    .timer = .{ .pace = 90 },
    .sections = &.{
        .{
            .wall = 1216,
            .timer = 40,
            .opens_after = 61,
            .placed = &.{
                .{ .kind = "galsia", .x = 1104, .depth = 64, .entrance = .wait, .offset = .{ .x = 56, .depth = 0 } },
                .{ .kind = "galsia", .x = 1016, .depth = 41, .level = 1, .two_players = true, .traits = .initOne(.waits_for_camera) },
            },
            .wave = &.{
                .{ .kind = "galsia_stalker", .side = .left, .depth = 32, .after = 16 },
                .{ .kind = "galsia", .depth = 88, .after = 48 },
            },
            .reserve = &.{.{ .kind = "galsia", .side = .left, .depth = 72, .arrives_after = 32 }},
        },
        .{
            .wall = 1984,
            .timer = 50,
            .opens_after = 63,
            .placed = &.{.{ .kind = "breakable", .x = 2016, .depth = 32, .holds = "apple" }},
        },
    },
    .boss = .{
        .fade = "fade out",
        .music = "boss music",
        .music_after = 86,
        .wave_after = 59,
        .wave = &.{.{ .kind = "antonio", .depth = 16, .after = 16, .bar = 4 }},
    },
};

test "a round writes and reads back the same" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try json.write(arena, try value(arena, &example));
    var diag: json.Diagnostic = .{};
    const root = try json.parse(arena, "rounds/round1.json", text, &diag);
    const back = try read(arena, "round1", root, null);
    try testing.expectEqualStrings(text, try json.write(arena, try value(arena, &back)));
    try testing.expect(back.sections[0].placed[1].traits.contains(.waits_for_camera));
    try testing.expectEqual(@as(?Entrance, .wait), back.sections[0].placed[0].entrance);
    try testing.expectEqual(@as(u16, 32), back.sections[0].reserve[0].arrives_after);
    try testing.expectEqualStrings("antonio", back.boss.?.wave[0].kind);
}

test "a refusal names the field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try json.write(arena, try value(arena, &example));
    var diag: json.Diagnostic = .{};
    // A misspelt field of a spawn.
    const bad = try std.mem.replaceOwned(u8, arena, text, "\"after\": 48", "\"afetr\": 48");
    try testing.expectError(error.BadAsset, read(arena, "round1", try json.parse(arena, "rounds/round1.json", bad, &diag), null));
    try testing.expectEqualStrings("sections[0].wave[1].afetr", diag.fieldName());
    // A wall behind the one before it.
    const behind = try std.mem.replaceOwned(u8, arena, text, "\"wall\": 1984", "\"wall\": 1000");
    try testing.expectError(error.BadAsset, read(arena, "round1", try json.parse(arena, "rounds/round1.json", behind, &diag), null));
    try testing.expectEqualStrings("sections[1].wall", diag.fieldName());
    // The round's number and its file's name.
    try testing.expectError(error.BadAsset, read(arena, "round2", try json.parse(arena, "rounds/round2.json", text, &diag), null));
    try testing.expectEqualStrings("round", diag.fieldName());
}

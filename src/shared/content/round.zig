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
pub const Entrance = enum { approach, close_in, edge, wait, shutter, square_up, jump_in, size_up, follow, enter, circle, keep_away, leap };

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
    /// A juggler juggles the other knives.
    knives_b,
    /// A boss whose beating is not the round's end: he goes as an enemy (round 5's round 3's
    /// bosses).
    goes_as_enemy,
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

/// A boss's kind that comes as one of a reserve's enemies (round 5's round 3's bosses): its art
/// and colours are a boss's, not an enemy's. Its art, a load of art by number, takes the boss's
/// art slot (once no enemy shows the second's, the third's or the boss's, unless it holds it
/// already); its colours, by their number among those the lines hold (its record's palette byte,
/// apart from the enemies' numbers), take the other's place and the first's, and `palette`, a
/// palette of the art, is loaded over the first line (once no enemy shows on the first or the
/// other, unless the other holds them already).
pub const ReserveBoss = struct {
    art: u8,
    colours: u8,
    palette: []const u8,
};

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
    /// The two indices its offset comes from (across in the high nibble, in depth in the low:
    /// its kind's offsets table), for a kind that counts on from them (a trio's others).
    offset_nibbles: ?u8 = null,
    strength: u8 = 0,
    /// A breakable's: the kind of item it holds.
    holds: ?[]const u8 = null,
    /// Placed: the height a piece of scenery takes as it starts (on a wall), placed on the ground.
    height: ?i32 = null,
    /// Placed: how a drifting piece of scenery moves.
    drift: ?Drift = null,
    /// Placed: its place among the round's things of its kind (a press: the cells of the plane
    /// it shakes).
    place: ?u8 = null,
    /// A boss's: its entry in the status bar's names and bars.
    bar: ?u8 = null,
    /// A reserve's: its kind's art streamed in from its call.
    streamed: []const Streamed = &.{},
    /// An enemy's colours, by their number (play's `enemy_colours`); null: its kind's own.
    colours: ?u8 = null,
    /// An enemy's art, by its number (the art slots hold enemies' art by number; 128 and more:
    /// art none of them holds).
    art: ?u8 = null,
    /// A reserve's boss's kind: its art and colours a boss's.
    reserve_boss: ?ReserveBoss = null,
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
    /// The enemies' art its art slots hold as it begins, by number (0: none): the three slots
    /// of the enemies' and the boss's.
    art: [4]u8 = .{ 0, 0, 0, 0 },
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
    /// The art its slots hold as its section begins (`Section.art`): the boss's in the last.
    art: [4]u8 = .{ 0, 0, 0, 0 },
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
    /// How each frame of play copies the planes' scroll: not at all (they scroll whole), a value
    /// a row of cells, or a value a line.
    scroll: Scroll = .whole,
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
    /// The camera rocks down and up by itself (round 5's ship), from the round's start and again
    /// from each special attack's call: its speed down grows by `accel` (16.16 pixels) each tick
    /// of the camera's, which turns to its opposite after `ticks` ticks, then every `period`.
    wobble: ?Wobble = null,
    /// Each plane's bands (plane A's, then plane B's), from the top: as a band's place across
    /// (its plane's times `times` / `per`) crosses a column of blocks (16 pixels), the game
    /// writes the column of blocks coming in, `rows` blocks high; as the camera crosses a row of
    /// blocks, the row (32 blocks).
    bands: [2][]const Band = .{ &.{}, &.{} },
    /// Plane B is water that ripples by lines (round 4's river under the bridge).
    water: ?Water = null,
};

/// Plane B's water, scrolled by lines: its first `from` lines at the plane's place; then `half`
/// lines, each at the place less half of one of the ripple's last places (their whole pixels),
/// the oldest first; then `whole` lines, each less a whole one of the next, the last line at the
/// plane's place (the original never refreshes its copy's last place); the lines below at 0. The
/// ripple's place starts at `start` and moves by `speed` a tick (1/65536 pixel), turning about
/// at every `turn`th tick; the round's start runs it `half` + `whole` ticks.
pub const Water = struct {
    from: u8,
    half: u8,
    whole: u8,
    start: i32,
    speed: i32,
    turn: u8,

    /// The ripple's place after its `step`th tick (the ticks counted from the round's start,
    /// the start's own among them), in 1/65536 pixel: up by `speed` until its first turn, then
    /// down and up again by `turn` ticks.
    pub fn place(w: Water, step: u32) i32 {
        const t: u32 = w.turn;
        const moves: i32 = if (step < t) @intCast(step) else blk: {
            const m = (step - (t - 1)) % (2 * t);
            break :blk if (m <= t) @as(i32, @intCast(t - 1)) - @as(i32, @intCast(m)) else @as(i32, @intCast(m)) - @as(i32, @intCast(t)) - 1;
        };
        return w.start +% w.speed *% moves;
    }

    /// The places across of the screen's lines (`left`, from the top) of plane B, the camera at
    /// `camera_x`, after the ripple's `steps` ticks (its places before the first: 0). The plane's
    /// place is half the camera's, rounded up (the original halves the scroll, its negation).
    pub fn lines(w: Water, camera_x: i32, steps: u32, left: []i16) void {
        @memset(left, 0);
        const x = -@divFloor(-camera_x, 2);
        const count = @as(u32, w.half) + w.whole;
        for (left, 0..) |*l, i| {
            if (i < w.from) {
                l.* = @intCast(x);
                continue;
            }
            const k = i - w.from;
            if (k >= count) break;
            // The place it showed: its ripple's before this tick's, the last never.
            const was = steps -% count +% @as(u32, @intCast(k));
            const whole: i32 = if (k + 1 == count or was == 0 or was > steps) 0 else w.place(was) >> 16;
            // The original scrolls by the plane's place negated: half of the whole, rounded down.
            l.* = @intCast(if (k < w.half) x - (@divFloor(-whole, 2)) else x + whole);
        }
    }
};

/// A plane's band: `rows` blocks high, its place across `times` / `per` of its plane's; or,
/// drifting (round 5's sea), its place moved at each tick of the camera's by its `drift` and the
/// camera's move across, at its ratio, the plane drawn once (a ring of `drift_ring` pixels).
pub const Band = struct { rows: u8, times: u8, per: u8, drift: ?i8 = null };

/// The width of the ring a drifting plane is drawn in once (the console's plane, 64 cells).
pub const drift_ring = 512;

pub const Wobble = struct { ticks: u8, period: u8, accel: i32 };

pub const Scroll = enum { whole, cells, lines };

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
    /// A part of its planes the round animates by itself.
    animation: ?Animation = null,
    /// The first of the enemies' art slots a waiting enemy's art may take (round 1's second: its
    /// first stays), and a boss's art that leaves no slot to a waiting enemy's.
    art_from: u8 = 0,
    boss_art_full: u8 = 0,
    /// Its floor by cells, when they differ (round 4's holes): null, its ground everywhere.
    floor: ?Floor = null,
    /// The way its enemies walk off in depth, whatever their kind's and their target's (round
    /// 4's: up, away from the screen); null: theirs.
    walk_off: ?WalkOff = null,
    /// What it draws in front of its layers' cells that are in front of the sprites.
    in_front: InFront = .{},
    /// Its lift (round 7's): the camera stays, plane B rides by.
    lift: ?Lift = null,
    /// Its walls stop the players' moves in depth (all but round 7's), as they stop those across.
    depth_walls: bool = true,
    /// A new life knocks the enemies on the screen back to the left, facing right (rounds 7's
    /// and 8's); else to the right, facing left.
    knocked_back_left: bool = false,
    /// How it ends without a boss (round 7's): the players walk out.
    exit: ?Exit = null,
};

/// A round on a lift (round 7's): the camera stays where it starts; plane B, the face the lift
/// rides up, moves on its own. It is `from` pixels down at the round's start; each section's
/// opening starts the lift, and plane B moves up `speed` pixels a tick to the section's entry of
/// `heights` (the first section's first), where the lift stops. As it starts and as it stops the
/// camera jolts: it moves down by each of `jolts` in turn, one every `period` ticks, the first a
/// period after; the ride begins a period after the last. A section's wave waits `wait` ticks from
/// its opening, then for the lift's next jolt (its stop's).
pub const Lift = struct {
    provenance: []const u8 = "",
    from: i32,
    heights: []const i32,
    speed: i32,
    jolts: []const i8,
    period: u8,
    wait: u8,
};

/// How a round without a boss ends (round 7's): once its last section is cleared, its timer stops
/// and the players walk out by themselves (their pads but in the air not theirs; nothing keeps
/// them on the screen): each left until it is before `x`, then up or down into the depths
/// `depth` (from the first, before the second); there it walks on left, and the round ends
/// `ticks` turns of a player there later (the last to get there counts them again), as a boss's
/// beating ends one.
pub const Exit = struct {
    provenance: []const u8 = "",
    x: i32,
    depth: [2]i32,
    ticks: u16,
};

/// What a round draws in front of its layers' cells that are in front of the sprites: the
/// entities its script brings, the players from each life's start, the things the fights leave
/// and throw (the items, the weapons, the pepper, the special attack's car, blast and fire).
pub const InFront = struct {
    provenance: []const u8 = "",
    script: bool = false,
    players: bool = false,
    things: bool = false,
};

/// A round's way for its enemies' walk off: up (away from the screen) or down; with
/// `down_before`, down before that place across and up from it.
pub const WalkOff = struct { up: bool = false, down_before: ?i32 = null };

/// A round's floor by cells (round 4's bridge and its holes): the level in cells `cell[0]` pixels
/// across and `cell[1]` in depth, from its top-left corner, a row of them by `cell[1]` pixels of
/// depth, each cell one of `kinds` (a hex digit). A cell's kind has a floor at its height (where
/// a thing stands, lands, falls to), or none (a hole: a thing over it falls through, toward its
/// height far below). A place past the rows or the columns, or before them, takes the nearest
/// cell.
pub const Floor = struct {
    provenance: []const u8 = "",
    cell: [2]u8,
    kinds: []const FloorKind,
    rows: []const []const u8,

    /// The kind of the cell at `x` across and `depth` (whole pixels).
    pub fn at(f: *const Floor, x: i32, depth: i32) FloorKind {
        const row = f.rows[@intCast(std.math.clamp(@divFloor(depth, f.cell[1]), 0, @as(i32, @intCast(f.rows.len)) - 1))];
        const c = row[@intCast(std.math.clamp(@divFloor(x, f.cell[0]), 0, @as(i32, @intCast(row.len)) - 1))];
        return f.kinds[std.fmt.charToDigit(c, 16) catch 0];
    }
};

/// A kind of the floor's cells: its height (0: a wall, nothing stands there), whether it has a
/// floor (a hole has none), and a conveyor's carry across a tick (whole pixels: 1 to the right,
/// -1 to the left; 0 none).
pub const FloorKind = struct { height: i32, floor: bool, carry: i8 = 0 };

/// A part of a round's planes it animates by itself (round 3's waves): every `every` ticks of
/// play (the special attack's too), the next of its `steps` (after the last, the first again),
/// each a map of the round's art set written at its place, repeated across its plane, and colours
/// of the art set put in the colours shown. Until its first step, the planes show their own.
pub const Animation = struct {
    provenance: []const u8 = "",
    every: u8,
    steps: []const AnimationStep,
};

pub const AnimationStep = struct { map: []const u8, colours: []const u8 };

/// A sound a round plays by itself (round 3's waves, round 5's horn): `sound` (a name of the
/// sound content), `times` times (none: endlessly), the first at play's `first`th tick, then every
/// `every` ticks; counted again from each section's opening when `per_section`. It counts in
/// play, the special attack's too.
pub const OwnSound = struct {
    provenance: []const u8 = "",
    sound: []const u8,
    first: u16,
    every: u16,
    times: ?u8 = null,
    per_section: bool = true,
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
        for (items, list) |*v, b| v.* = .{ .array = if (b.drift) |d|
            try arena.dupe(json.Value, &.{ json.Value.num(b.rows), json.Value.num(b.times), json.Value.num(b.per), json.Value.num(d) })
        else
            try arena.dupe(json.Value, &.{ json.Value.num(b.rows), json.Value.num(b.times), json.Value.num(b.per) }) };
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
    if (c.water) |w| try f.append(arena, .{ .key = "water", .value = try obj(arena, &.{
        .{ .key = "from", .value = json.Value.num(w.from) },
        .{ .key = "half", .value = json.Value.num(w.half) },
        .{ .key = "whole", .value = json.Value.num(w.whole) },
        .{ .key = "start", .value = json.Value.num(w.start) },
        .{ .key = "speed", .value = json.Value.num(w.speed) },
        .{ .key = "turn", .value = json.Value.num(w.turn) },
    }) });
    if (c.plane_b_down) try f.append(arena, .{ .key = "plane_b_down", .value = .{ .bool = true } });
    if (c.wobble) |wb| try f.append(arena, .{ .key = "wobble", .value = .{ .array = try arena.dupe(json.Value, &.{ json.Value.num(wb.ticks), json.Value.num(wb.period), json.Value.num(wb.accel) }) } });
    if (c.scroll != .whole) try f.append(arena, .{ .key = "scroll", .value = .{ .str = @tagName(c.scroll) } });
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
    if (s.place) |p| try f.append(arena, .{ .key = "place", .value = json.Value.num(p) });
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
    if (s.offset_nibbles) |o| try f.append(arena, .{ .key = "offset_nibbles", .value = json.Value.num(o) });
    if (s.strength != 0) try f.append(arena, .{ .key = "strength", .value = json.Value.num(s.strength) });
    if (s.holds) |h| try f.append(arena, .{ .key = "holds", .value = .{ .str = h } });
    if (s.bar) |b| try f.append(arena, .{ .key = "bar", .value = json.Value.num(b) });
    if (where == .reserve and s.streamed.len != 0) try f.append(arena, .{ .key = "streamed", .value = try streamedValue(arena, s.streamed) });
    if (s.colours) |c| try f.append(arena, .{ .key = "colours", .value = json.Value.num(c) });
    if (s.art) |x| try f.append(arena, .{ .key = "art", .value = json.Value.num(x) });
    if (where == .reserve) if (s.reserve_boss) |b| try f.append(arena, .{ .key = "reserve_boss", .value = try obj(arena, &.{
        .{ .key = "art", .value = json.Value.num(b.art) },
        .{ .key = "colours", .value = json.Value.num(b.colours) },
        .{ .key = "palette", .value = .{ .str = b.palette } },
    }) });
    return .{ .object = f.items };
}

fn artValue(arena: std.mem.Allocator, a: [4]u8) !json.Value {
    const items = try arena.alloc(json.Value, 4);
    for (items, a) |*v, x| v.* = json.Value.num(x);
    return .{ .array = items };
}

fn readArt(n: json.Node) Error![4]u8 {
    if (try n.len() != 4) return n.fail("not the four art slots");
    var out: [4]u8 = undefined;
    for (&out, 0..) |*o, i| o.* = try (try n.at(i)).int(u8);
    return out;
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
        .{ .key = "art", .value = try artValue(arena, s.art) },
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
    if (r.art_from != 0) try fields.append(arena, .{ .key = "art_from", .value = json.Value.num(r.art_from) });
    if (r.boss_art_full != 0) try fields.append(arena, .{ .key = "boss_art_full", .value = json.Value.num(r.boss_art_full) });
    if (r.special.streamed[0].len != 0 or r.special.streamed[1].len != 0) {
        const both = try arena.alloc(json.Value, 2);
        for (both, r.special.streamed) |*o, list| o.* = try streamedValue(arena, list);
        try fields.append(arena, .{ .key = "special", .value = try withProvenance(arena, r.special.provenance, &.{
            .{ .key = "streamed", .value = .{ .array = both } },
        }) });
    }
    if (r.animation) |an| {
        const steps = try arena.alloc(json.Value, an.steps.len);
        for (steps, an.steps) |*v, st| v.* = try obj(arena, &.{
            .{ .key = "map", .value = .{ .str = st.map } },
            .{ .key = "colours", .value = .{ .str = st.colours } },
        });
        try fields.append(arena, .{ .key = "animation", .value = try withProvenance(arena, an.provenance, &.{
            .{ .key = "every", .value = json.Value.num(an.every) },
            .{ .key = "steps", .value = .{ .array = steps } },
        }) });
    }
    if (r.floor) |fl| {
        const kinds = try arena.alloc(json.Value, fl.kinds.len);
        for (kinds, fl.kinds) |*v, k| v.* = try obj(arena, &.{
            .{ .key = "height", .value = json.Value.num(k.height) },
            .{ .key = "floor", .value = .{ .bool = k.floor } },
            .{ .key = "carry", .value = json.Value.num(k.carry) },
        });
        const rows = try arena.alloc(json.Value, fl.rows.len);
        for (rows, fl.rows) |*v, row| v.* = .{ .str = row };
        try fields.append(arena, .{ .key = "floor", .value = try withProvenance(arena, fl.provenance, &.{
            .{ .key = "cell", .value = try pair(arena, fl.cell[0], fl.cell[1]) },
            .{ .key = "kinds", .value = .{ .array = kinds } },
            .{ .key = "rows", .value = .{ .array = rows } },
        }) });
    }
    if (r.walk_off) |wo| {
        var wf: std.ArrayList(json.Field) = .empty;
        try wf.append(arena, .{ .key = "up", .value = .{ .bool = wo.up } });
        if (wo.down_before) |x| try wf.append(arena, .{ .key = "down_before", .value = json.Value.num(x) });
        try fields.append(arena, .{ .key = "walk_off", .value = .{ .object = wf.items } });
    }
    if (r.lift) |lf| {
        const heights = try arena.alloc(json.Value, lf.heights.len);
        for (heights, lf.heights) |*v, x| v.* = json.Value.num(x);
        const jolts = try arena.alloc(json.Value, lf.jolts.len);
        for (jolts, lf.jolts) |*v, x| v.* = json.Value.num(x);
        try fields.append(arena, .{ .key = "lift", .value = try withProvenance(arena, lf.provenance, &.{
            .{ .key = "from", .value = json.Value.num(lf.from) },
            .{ .key = "heights", .value = .{ .array = heights } },
            .{ .key = "speed", .value = json.Value.num(lf.speed) },
            .{ .key = "jolts", .value = .{ .array = jolts } },
            .{ .key = "period", .value = json.Value.num(lf.period) },
            .{ .key = "wait", .value = json.Value.num(lf.wait) },
        }) });
    }
    if (!r.depth_walls) try fields.append(arena, .{ .key = "depth_walls", .value = .{ .bool = false } });
    if (r.knocked_back_left) try fields.append(arena, .{ .key = "knocked_back_left", .value = .{ .bool = true } });
    if (r.exit) |ex| try fields.append(arena, .{ .key = "exit", .value = try withProvenance(arena, ex.provenance, &.{
        .{ .key = "x", .value = json.Value.num(ex.x) },
        .{ .key = "depth", .value = try pair(arena, ex.depth[0], ex.depth[1]) },
        .{ .key = "ticks", .value = json.Value.num(ex.ticks) },
    }) });
    if (r.in_front.script or r.in_front.players or r.in_front.things) try fields.append(arena, .{ .key = "in_front", .value = try withProvenance(arena, r.in_front.provenance, &.{
        .{ .key = "script", .value = .{ .bool = r.in_front.script } },
        .{ .key = "players", .value = .{ .bool = r.in_front.players } },
        .{ .key = "things", .value = .{ .bool = r.in_front.things } },
    }) });
    if (r.own_sound) |o| try fields.append(arena, .{ .key = "own_sound", .value = try withProvenance(arena, o.provenance, &.{
        .{ .key = "sound", .value = .{ .str = o.sound } },
        .{ .key = "first", .value = json.Value.num(o.first) },
        .{ .key = "every", .value = json.Value.num(o.every) },
        .{ .key = "times", .value = if (o.times) |n| json.Value.num(n) else .null },
        .{ .key = "per_section", .value = .{ .bool = o.per_section } },
    }) });
    if (r.boss) |*b| try fields.append(arena, .{ .key = "boss", .value = try withProvenance(arena, b.provenance, &.{
        .{ .key = "fade", .value = .{ .str = b.fade } },
        .{ .key = "music", .value = .{ .str = b.music } },
        .{ .key = "music_after", .value = json.Value.num(b.music_after) },
        .{ .key = "wave_after", .value = json.Value.num(b.wave_after) },
        .{ .key = "streamed", .value = try streamedValue(arena, b.streamed) },
        .{ .key = "again", .value = try streamedValue(arena, b.again) },
        .{ .key = "section_colours", .value = try coloursValue(arena, b.section_colours) },
        .{ .key = "art", .value = try artValue(arena, b.art) },
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
            const fields = try e.len();
            if (fields != 3 and fields != 4) return e.fail("not [rows, times, per] or [rows, times, per, drift]");
            b.* = .{ .rows = try (try e.at(0)).int(u8), .times = try (try e.at(1)).int(u8), .per = try (try e.at(2)).int(u8) };
            if (fields == 4) b.drift = try (try e.at(3)).int(i8);
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
    const common = [_][]const u8{ "kind", "depth", "level", "two_players", "entrance", "offset", "offset_nibbles", "strength", "holds", "bar", "colours", "art" };
    const own: []const []const u8 = switch (where) {
        .placed => &.{ "x", "height", "drift", "place" },
        .wave => &.{ "side", "after" },
        .reserve => &.{ "side", "arrives_after", "streamed", "reserve_boss" },
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
            if (try n.opt("place")) |p| s.place = try p.int(u8);
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
    if (try n.opt("offset_nibbles")) |o| s.offset_nibbles = try o.int(u8);
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
    if (try n.opt("art")) |x| s.art = try x.int(u8);
    if (where == .reserve) if (try n.opt("reserve_boss")) |b| {
        try b.only(&.{ "art", "colours", "palette" });
        s.reserve_boss = .{ .art = try (try b.get("art")).int(u8), .colours = try (try b.get("colours")).int(u8), .palette = try (try b.get("palette")).string() };
        if (s.art != null or s.colours != null) return b.fail("a reserve's boss with an enemy's art or colours");
    };
    return s;
}

fn readSpawns(arena: std.mem.Allocator, n: json.Node, comptime where: Where) Error![]const Spawn {
    const out = try arena.alloc(Spawn, try n.len());
    for (out, 0..) |*s, i| s.* = try readSpawn(arena, try n.at(i), where);
    return out;
}

/// Reads round `name`'s file (its parsed `root`); `a`, when given, must have its art set.
pub fn read(arena: std.mem.Allocator, name: []const u8, root: json.Node, a: ?*const art.Art) Error!Round {
    try root.only(&.{ "provenance", "round", "art", "music", "ground", "load", "camera", "players", "timer", "sections", "special", "boss", "own_sound", "animation", "art_from", "boss_art_full", "floor", "walk_off", "in_front", "lift", "exit", "depth_walls", "knocked_back_left" });
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
    if (try root.opt("art_from")) |x| {
        r.art_from = try x.int(u8);
        if (r.art_from > 2) return x.fail("not 0 to 2");
    }
    if (try root.opt("boss_art_full")) |x| r.boss_art_full = try x.int(u8);
    var buf: [16]u8 = undefined;
    if (r.number == 0 or !std.mem.eql(u8, nameOf(&buf, r.number), name)) return number.fail("not the round of this file's name");
    if (a) |x| for (x.sets) |s| {
        if (std.mem.eql(u8, s.name, r.art)) break;
    } else return (try root.get("art")).fail("no art set of this name");

    const c = try root.get("camera");
    try c.only(&.{ "provenance", "at", "x_min", "y", "plane_b", "plane_b_down", "scroll", "wall_within", "edges", "left_behind", "follow", "follow_most", "kept_x", "kept_depth", "shake", "wobble", "bands", "water" });
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
        .scroll = if (try c.opt("scroll")) |n| std.meta.stringToEnum(Scroll, try n.string()) orelse return n.fail("not whole, cells or lines") else .whole,
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
    if (try c.opt("wobble")) |wb| {
        if (try wb.len() != 3) return wb.fail("not [ticks, period, accel]");
        r.camera.wobble = .{ .ticks = try (try wb.at(0)).int(u8), .period = try (try wb.at(1)).int(u8), .accel = try (try wb.at(2)).int(i32) };
        if (r.camera.wobble.?.ticks == 0 or r.camera.wobble.?.period == 0) return wb.fail("a turn after no ticks");
    }
    if (r.camera.shake[0] <= 0 or r.camera.shake[0] > 255) return (try c.get("shake")).fail("not 1 to 255 ticks");
    if (r.camera.follow[0] > r.camera.follow[1]) return (try c.get("follow")).fail("its first after its second");
    if (r.camera.follow_most <= 0) return (try c.get("follow_most")).fail("not 1 or more");
    if (r.camera.kept_x[0] > r.camera.kept_x[1]) return (try c.get("kept_x")).fail("its first after its second");
    if (r.camera.kept_depth[0] > r.camera.kept_depth[1]) return (try c.get("kept_depth")).fail("its first after its second");
    if (r.camera.plane_b[1] == 0) return (try c.get("plane_b")).fail("a ratio of 0 per");
    if (r.camera.y_min > r.camera.y_max) return (try c.get("y")).fail("its first above its second");
    if (try c.opt("water")) |w| {
        try w.only(&.{ "from", "half", "whole", "start", "speed", "turn" });
        r.camera.water = .{
            .from = try (try w.get("from")).int(u8),
            .half = try (try w.get("half")).int(u8),
            .whole = try (try w.get("whole")).int(u8),
            .start = try (try w.get("start")).int(i32),
            .speed = try (try w.get("speed")).int(i32),
            .turn = try (try w.get("turn")).int(u8),
        };
        if (r.camera.water.?.turn == 0) return (try w.get("turn")).fail("not 1 or more");
        if (r.camera.water.?.whole == 0) return (try w.get("whole")).fail("not 1 or more");
    }

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
        try n.only(&.{ "provenance", "wall", "timer", "opens_after", "streamed", "again", "colours", "art", "placed", "wave", "reserve" });
        s.* = .{
            .provenance = try provenanceOf(n),
            .wall = try (try n.get("wall")).int(i32),
            .timer = try (try n.get("timer")).int(u8),
            .opens_after = try (try n.get("opens_after")).int(u16),
            .streamed = try readStreamed(arena, try n.get("streamed")),
            .again = if (try n.opt("again")) |x| try readStreamed(arena, x) else &.{},
            .colours = if (try n.opt("colours")) |x| try readColours(x) else .{},
            .art = if (try n.opt("art")) |x| try readArt(x) else .{ 0, 0, 0, 0 },
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
    if (try root.opt("animation")) |an| {
        try an.only(&.{ "provenance", "every", "steps" });
        const list = try an.get("steps");
        const steps = try arena.alloc(AnimationStep, try list.len());
        if (steps.len == 0) return list.fail("no step");
        for (steps, 0..) |*st, i| {
            const n = try list.at(i);
            try n.only(&.{ "map", "colours" });
            st.* = .{ .map = try (try n.get("map")).string(), .colours = try (try n.get("colours")).string() };
        }
        r.animation = .{ .provenance = try provenanceOf(an), .every = try (try an.get("every")).int(u8), .steps = steps };
        if (r.animation.?.every == 0) return (try an.get("every")).fail("not 1 or more");
    }
    if (try root.opt("walk_off")) |wo| {
        try wo.only(&.{ "up", "down_before" });
        r.walk_off = .{
            .up = try (try wo.get("up")).boolean(),
            .down_before = if (try wo.opt("down_before")) |x| try x.int(i32) else null,
        };
    }
    if (try root.opt("floor")) |fl| {
        try fl.only(&.{ "provenance", "cell", "kinds", "rows" });
        const cell = try readPair(try fl.get("cell"), u8);
        if (cell[0] == 0 or cell[1] == 0) return (try fl.get("cell")).fail("a cell of no size");
        const kn = try fl.get("kinds");
        const kinds = try arena.alloc(FloorKind, try kn.len());
        if (kinds.len == 0 or kinds.len > 16) return kn.fail("not 1 to 16 kinds");
        for (kinds, 0..) |*k, i| {
            const n = try kn.at(i);
            try n.only(&.{ "height", "floor", "carry" });
            k.* = .{ .height = try (try n.get("height")).int(i32), .floor = try (try n.get("floor")).boolean() };
            if (try n.opt("carry")) |cn| k.carry = try cn.int(i8);
        }
        const rn = try fl.get("rows");
        const rows = try arena.alloc([]const u8, try rn.len());
        if (rows.len == 0) return rn.fail("no row");
        for (rows, 0..) |*row, i| {
            const n = try rn.at(i);
            row.* = try n.string();
            if (row.len == 0 or row.len != rows[0].len) return n.fail("not a row as long as the first");
            for (row.*) |ch| {
                const d = std.fmt.charToDigit(ch, 16) catch return n.fail("not a hex digit a cell");
                if (d >= kinds.len) return n.fail("a cell of no kind");
            }
        }
        r.floor = .{ .provenance = try provenanceOf(fl), .cell = cell, .kinds = kinds, .rows = rows };
    }
    if (try root.opt("lift")) |lf| {
        try lf.only(&.{ "provenance", "from", "heights", "speed", "jolts", "period", "wait" });
        const hn = try lf.get("heights");
        const heights = try arena.alloc(i32, try hn.len());
        for (heights, 0..) |*x, i| x.* = try (try hn.at(i)).int(i32);
        const jn = try lf.get("jolts");
        const jolts = try arena.alloc(i8, try jn.len());
        for (jolts, 0..) |*x, i| x.* = try (try jn.at(i)).int(i8);
        r.lift = .{
            .provenance = try provenanceOf(lf),
            .from = try (try lf.get("from")).int(i32),
            .heights = heights,
            .speed = try (try lf.get("speed")).int(i32),
            .jolts = jolts,
            .period = try (try lf.get("period")).int(u8),
            .wait = try (try lf.get("wait")).int(u8),
        };
        if (heights.len < r.sections.len) return hn.fail("not a height for each section");
        if (r.lift.?.speed <= 0) return (try lf.get("speed")).fail("not 1 or more");
        if (r.lift.?.period == 0) return (try lf.get("period")).fail("not 1 or more");
        if (r.lift.?.wait == 0) return (try lf.get("wait")).fail("not 1 or more");
    }
    if (try root.opt("depth_walls")) |dw| r.depth_walls = try dw.boolean();
    if (try root.opt("knocked_back_left")) |kb| r.knocked_back_left = try kb.boolean();
    if (try root.opt("exit")) |ex| {
        try ex.only(&.{ "provenance", "x", "depth", "ticks" });
        r.exit = .{
            .provenance = try provenanceOf(ex),
            .x = try (try ex.get("x")).int(i32),
            .depth = try readPair(try ex.get("depth"), i32),
            .ticks = try (try ex.get("ticks")).int(u16),
        };
        if (r.exit.?.ticks == 0) return (try ex.get("ticks")).fail("not 1 or more");
    }
    if (try root.opt("in_front")) |f| {
        try f.only(&.{ "provenance", "script", "players", "things" });
        r.in_front = .{
            .provenance = try provenanceOf(f),
            .script = try (try f.get("script")).boolean(),
            .players = try (try f.get("players")).boolean(),
            .things = try (try f.get("things")).boolean(),
        };
    }
    if (try root.opt("own_sound")) |o| {
        try o.only(&.{ "provenance", "sound", "first", "every", "times", "per_section" });
        const times = try o.get("times");
        r.own_sound = .{
            .provenance = try provenanceOf(o),
            .sound = try (try o.get("sound")).string(),
            .first = try (try o.get("first")).int(u16),
            .every = try (try o.get("every")).int(u16),
            .times = if (times.isNull()) null else try times.int(u8),
            .per_section = if (try o.opt("per_section")) |n| try n.boolean() else true,
        };
        if (r.own_sound.?.first == 0) return (try o.get("first")).fail("not 1 or more");
        if (r.own_sound.?.every == 0) return (try o.get("every")).fail("not 1 or more");
    }
    if (try root.opt("boss")) |b| {
        try b.only(&.{ "provenance", "fade", "music", "music_after", "wave_after", "streamed", "again", "section_colours", "colours", "art", "wave", "reserve" });
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
            .art = if (try b.opt("art")) |x| try readArt(x) else .{ 0, 0, 0, 0 },
            .wave = try readSpawns(arena, try b.get("wave"), .wave),
            .reserve = try readSpawns(arena, try b.get("reserve"), .reserve),
        };
    }
    if (r.exit != null and r.boss != null) return (try root.get("exit")).fail("an exit in a round with a boss");
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

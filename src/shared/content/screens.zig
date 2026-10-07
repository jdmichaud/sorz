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
pub const Character = @import("../setup.zig").Character;

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

/// The ending after round 8 (screens/ending.zig), as the original's script and objects run it.
pub const Ending = struct {
    provenance: []const u8 = "",
    /// Its script: each entry the part it starts, the ticks to the next, the part's life.
    script: []const ScriptEntry,
    /// Its texts, typed a code every `type_period` ticks and erased so, one after the other: each
    /// where its first row starts (a cell of a plane), its rows (`fonts/italic`'s glyphs, a space
    /// a blank cell, a row a code too), and the ticks it stays typed. The font shows as its
    /// dissolves let it (its pixels in or out every `dissolve_period` ticks).
    texts: []const EndingText,
    /// The pictures (their maps, in the order they are drawn), and their moments: the pictures
    /// drawn then, the palette lines faded in (towards their colours) and out, the ticks to the
    /// next moment.
    pictures: []const []const u8,
    moments: []const EndingMoment,
    /// The last scene's steps: its next palette (`scene_colours`'s), the sky's next colours
    /// (`sky`), the clouds sent off, the star's blink begun; the ticks to the next (0: until the
    /// sun has set).
    scene: []const SceneStep,
    scene_colours: []const []const u8,
    sky: []const u8,
    /// The clouds crossing from the right and back, the setting sun, THE END glowing; the star.
    clouds: []const Sprite,
    sun: Sprite,
    glow: Sprite,
    star: []const Blink,
    numbers: EndingNumbers,
};

pub const EndingText = struct { plane: art.Layer, x: u16, y: u16, rows: []const []const u8, stays: u16 };
pub const EndingMoment = struct { pictures: u8, fade_in: []const LineColours, fade_out: []const u8, after: u16 };
pub const LineColours = struct { line: u8, colours: []const u8 };
/// A step of the last scene: what it shows; the ticks to the next (none: until the sun has set
/// when `until_sun`, else for good).
pub const SceneStep = struct { palette: bool, sky: bool, clouds_off: bool, star: bool, after: u16, until_sun: bool };
/// A sprite of the ending: its frame, its place, its speed (in 1/65536 of a pixel a tick, across
/// for a cloud, down for the sun), its palette and priority.
pub const Sprite = struct { frame: []const u8, x: i16, y: i16, speed: i32, palette: u2, priority: bool };
/// A star's look (its map) and the ticks it shows.
pub const Blink = struct { map: []const u8, ticks: u16 };

pub const EndingNumbers = struct {
    type_period: u8,
    erase_gap: u16,
    dissolve_period: u8,
    dissolve_step: u16,
    dissolve_from: u16,
    dissolve_span: u16,
    fade_period: u8,
    fade_life: u16,
    /// The palette line the last picture's wait blackens, so many ticks before its end.
    black_line: u8,
    black_before: u16,
    /// A cloud past `cloud_turn` across comes back at `cloud_back`, its height `cloud_height`
    /// and a draw's low bits (`cloud_spread`).
    cloud_turn: i16,
    cloud_back: i16,
    cloud_height: i16,
    cloud_spread: u8,
    /// The sun sets to `sun_until`.
    sun_until: i16,
    /// THE END glows: its line's colour `glow_colour` towards `glow_colours`, a step every
    /// `glow_period` ticks.
    glow_line: u8,
    glow_colour: u8,
    glow_period: u8,
    glow_colours: []const u8,
    /// The car's plane's lines from `scroll_first` (`scroll_lines` of them) scroll left a pixel
    /// a tick, `scroll_ticks` ticks.
    scroll_first: u16,
    scroll_lines: u16,
    scroll_ticks: u16,
    /// START ends it from the script's entry `skip_from` on, `skip_within` ticks from the next.
    skip_from: u8,
    skip_within: u16,
};

/// The ending in the boss's chair (screens/boss_ending.zig), when a player kept Mr. X's offer.
pub const BossEnding = struct {
    provenance: []const u8 = "",
    /// The lines typed a letter at a time (each faded in from black, in the game's font) and
    /// erased so: the two first, then, after the credits, the last; each its first cell of
    /// plane A and its text (a space a blank that takes no time).
    lines: []const BossLine,
    /// The credits rolling up plane A: each the row (16 pixels each) the plane's place comes to
    /// as it is written below the view, and its text; written from `credit_column`, a row of
    /// `credit_cells` cells.
    credits: []const CreditLine,
    credit_column: u8,
    credit_cells: u8,
    /// The character in the chair, by its name: its place, palette, frames sitting and turning,
    /// colours, and its colours' steps.
    chairs: []const Chair,
    room_colours: []const u8,
    room_steps: []const []const u8,
    credits_colours: []const u8,
    /// A letter's colour: palette `letter_line`'s colour `letter_colour`, a level a tick to
    /// `letter_levels`; white at the end; the waits, the turn, the colours' steps' period, the
    /// credits' speed down (in 1/65536 of a pixel a tick).
    letter_line: u2,
    letter_colour: u8,
    letter_levels: u8,
    white_colour: u8,
    wait: u16,
    turn: u16,
    step_period: u8,
    scroll: i32,
    music: []const u8,
    leave: []const u8,
};

pub const BossLine = struct { x: u16, y: u16, text: []const u8 };
pub const CreditLine = struct { row: u8, text: []const u8 };
pub const Chair = struct { character: []const u8, x: i16, y: i16, palette: u2, sit: []const ChairFrame, turn: []const ChairFrame, colours: []const u8, steps: []const []const u8 };
pub const ChairFrame = struct { frame: []const u8, ticks: u8 };

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
    /// The round's number, a frame by round (round 1's first).
    numbers: []const []const u8,
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
/// shown and hidden in turn every `blink` logic ticks of play; at a blink's tick with player 2's
/// START held, player 2 joins with `lives` (the one it plays counted) as the character `next`
/// gives by player 1's (indexed by the game's characters: Adam, Axel, Blaze).
pub const Join = struct {
    text: []const u8,
    at: Cell,
    blink: u8,
    lives: u8 = 3,
    next: [3]Character = .{ .blaze, .adam, .axel },
};

/// The bosses' bars (the original's enemies' bars: round 1's Antonio's, and those after), shown
/// below the players' from the tick after a boss's first in its section: the fixed layer a row
/// taller, the bars' rectangle (`play/enemy_bar`, at its place) and on it each bar's ten cells
/// from its cell in `bars` (`play/enemy_bar_1` and `_2`: ten full, the partial one, ten empty;
/// the partial cell's fill `play/fills`' second eight), the label after the first bar at `label`
/// (`play/enemy_bar_label`). A bar shows its boss's health at `points` pixels a point, eight a
/// cell; from `over[0]` pixels its ten cells all show the first over-full look
/// (`play/enemy_bar_over`'s first cell), from `over[1]` the second. `second`, by the bars'
/// entry (a boss's record's `bar`): whether the entry shows a second bar (twins').
pub const Bosses = struct {
    provenance: []const u8 = "",
    bars: [2]Cell,
    label: Cell,
    points: u8,
    over: [2]u16,
    second: []const bool,
};

/// The status bar, on the fixed layer: each player's parts, the timer's, the invitation to join;
/// the most a score holds (its digits the bar's), and the scores that give a life more; the
/// bosses' bars.
pub const StatusBar = struct {
    provenance: []const u8 = "",
    players: [2]BarPlayer,
    time: Cell,
    join: Join,
    score_most: u32,
    /// The score that gives a player its next life, by the lives its score gave it already
    /// (past the last: none more).
    extra_lives: []const u32 = &.{},
    /// The bar's image the game keeps and writes at every frame of play: its rows of cells
    /// (from the bar's second), and the cells of a row.
    image_rows: u8,
    image_cells: u8,
    bosses: Bosses,
};

/// A player's cells on the status bar for the continue's question and the game over.
pub const ContinuePlaces = struct {
    /// The first of the cells cleared on each of the bar's rows (its name's, its bar's).
    cleared: [2]Cell,
    question: Cell,
    answer: Cell,
    /// Where the cursor shows for each answer.
    yes: Cell,
    no: Cell,
    /// The game over's text when no continue is left.
    out: Cell,
};

/// The continue's question, which a player out of lives answers on the status bar, and the game
/// over. Texts of `fonts/main`, their words only (a space leaves the bar's cell).
pub const Continue = struct {
    provenance: []const u8 = "",
    /// The question, the continues left a digit `count` cells after its first.
    question: []const u8,
    count: u8,
    /// The second answer: `new_game` for player 1 while player 2 has not gone out of the game,
    /// `game_over` else; the answers' cursor, which blinks.
    new_game: []const u8,
    game_over: []const u8,
    cursor: []const u8,
    /// The cells cleared on each row from its first.
    cleared: u8,
    players: [2]ContinuePlaces,
    /// The game over's text over the picture, while the last player counts down.
    frame: []const u8,
};

/// A player's places of the name entry: the label's first cell, the first letter's (the others
/// follow it), the end mark's after them.
pub const NamePlaces = struct { label: Cell, first: Cell, mark: Cell };

/// The name entry of a player out of lives whose score enters the high-score table, on its part
/// of the status bar: its part cleared, its name and score where play shows them, then on the
/// second row the label, the name's letters and the end mark after them. Texts of `fonts/main`.
pub const NameEntry = struct {
    provenance: []const u8 = "",
    label: []const u8,
    /// The letters a place goes through, in their order; the last is the end mark, which ends the
    /// entry (the table shows it as a space).
    letters: []const []const u8,
    players: [2]NamePlaces,
};

/// An enemies' colours: a kind's for the enemies' first palette line and for their second (a
/// palette giving each), or its own (a palette giving its own colours, over the first line).
pub const ColourSet = struct { first: ?[]const u8 = null, second: ?[]const u8 = null, own: ?[]const u8 = null };

/// The enemies' colours, which the round loads into the enemies' palette lines as they come
/// (the round's records name them by number), and the lines they show on.
pub const EnemyColours = struct {
    provenance: []const u8 = "",
    /// By number.
    sets: []const ColourSet,
    /// The palette line of an enemy whose colours are in the first, the second, the other (its
    /// own, over the first line).
    lines: [3]u2,
    /// The police car's colours, over the enemies' while the car is there.
    police: []const u8,
};

/// A line of the round's clear: its text (`fonts/main`) from its cell of plane A.
pub const ClearLine = struct { text: []const u8, at: Cell };

/// The round's clear and its bonuses.
pub const Clear = struct {
    provenance: []const u8 = "",
    /// "ROUND n CLEAR": its map on plane A from its cell, the round's number a big digit at the
    /// map's cell `number`.
    header: []const u8,
    header_at: Cell,
    number: Cell,
    /// The bonuses' lines (the clear's, the time's, the level's; the last round's: its players
    /// left's header, then player 1's lives' and player 2's); a bonus's six digits from the
    /// line's `digits`th letter on.
    lines: [6]ClearLine,
    digits: u8,
    /// The palettes of a line, and of the line counted.
    normal: u2,
    counted: u2,
    /// The waits between the steps, in ticks.
    wait: u8,
    /// The bonuses: the clear's, for the round and each special attack left; the time's, a second
    /// left; the level's, a LEVEL of the options; the points a tick of the count gives.
    clear_bonus: u32,
    time_bonus: u32,
    level_bonus: u32,
    count: u32,
    /// The colours faded in, over the status bar's.
    colours: []const u8,
    /// The last round's clear (`last_round`) counts each player's lives left (`Levels.life_bonus`
    /// a life).
    last_round: u8 = 8,
};

/// A pad's buttons that the options' CONTROL gives actions to.
pub const Button = enum { a, b, c };

/// The button that gives each of a player's actions: the special attack, the attack, the jump.
pub const Layout = struct { special: Button = .a, attack: Button = .b, jump: Button = .c };

/// The layouts of the options' CONTROL choices, in their order (the first, the cartridge's
/// default).
pub const Buttons = struct {
    provenance: []const u8 = "",
    layouts: []const Layout = &.{.{}},

    /// Choice `control`'s layout (past the last: the first's).
    pub fn of(self: *const Buttons, control: u8) Layout {
        return if (control < self.layouts.len) self.layouts[control] else self.layouts[0];
    }
};

/// Play's screen (`screens/round`): its fixed texts and its status bar.
pub const Round = struct {
    banner: Banner,
    pause: Text,
    time_over: TimeOver,
    status_bar: StatusBar,
    continue_question: Continue,
    name_entry: NameEntry,
    enemy_colours: EnemyColours,
    clear: Clear,
    /// The players' buttons by the options' CONTROL.
    buttons: Buttons = .{},
    /// What the options' LEVEL changes in play.
    levels: Levels = .{},
    /// The attract demo.
    demo: Demo = .{},
};

/// What the options' LEVEL changes in play, by level (0, the easiest, to 3): a thing heading for
/// a point (an enemy walking to its place, a knife sent off) at `slower_from` or faster goes
/// `slower` less fast, in 1/65536 pixel a tick; the common enemies come with `enemy_health` more
/// health, and their blows do `enemy_power` more damage; the last round's clear gives
/// `life_bonus` points a life left. Left out, the level changes none.
pub const Levels = struct {
    provenance: []const u8 = "",
    slower_from: i32 = 0,
    slower: [4]i32 = @splat(0),
    enemy_health: [4]u8 = @splat(0),
    enemy_power: [4]u8 = @splat(0),
    life_bonus: [4]u32 = @splat(0),
};

/// The attract demo: round 1 played by the game on the pads the cartridge holds, both players in
/// play, each the character `players` names, with `lives` and `specials` (the status bar shows
/// those a new life gives until they change); it lasts `ticks` ticks of play, then fades out;
/// its `sign` (a kind of entity, fixed on the screen) stays over it. `pads` holds each pad's
/// readings, one at each display tick of the demo but its load's, from its set-up's: the buttons
/// held (the bits of the engine's pad: up, down, left, right, A, B, C, START from the lowest),
/// two hexadecimal digits a reading; those before `first_reading` read none (the stream is not
/// there yet); the real START pressed ends the demo (a fade out).
pub const Demo = struct {
    provenance: []const u8 = "",
    players: [2][]const u8 = .{ "", "" },
    lives: u8 = 0,
    specials: u8 = 0,
    ticks: u16 = 0,
    sign: []const u8 = "",
    pads: [2][]const u8 = .{ "", "" },
    first_reading: u8 = 0,

    /// Pad `pad`'s reading `k`: the buttons held (none before `first_reading` or past the
    /// readings).
    pub fn reading(self: *const Demo, pad: u1, k: usize) u8 {
        const text = self.pads[pad];
        if (k < self.first_reading or 2 * k + 2 > text.len) return 0;
        return std.fmt.parseInt(u8, text[2 * k ..][0..2], 16) catch 0;
    }
};

/// The screens' records a tree has.
pub const Screens = struct {
    options: ?Options = null,
    high_scores: ?HighScores = null,
    select: ?Select = null,
    intro: ?Intro = null,
    round: ?Round = null,
    ending: ?Ending = null,
    boss_ending: ?BossEnding = null,

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
pub const record_names = [_][]const u8{ "boss_ending", "ending", "high_scores", "intro", "options", "round", "select" };

pub fn path(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "screens/{s}.json", .{name});
}

// --- Writing ---------------------------------------------------------------------------------

/// A plain record (numbers, booleans, strings, enums, lists and records of them) as JSON, its
/// fields by name.
fn plainValue(arena: std.mem.Allocator, x: anytype) error{OutOfMemory}!json.Value {
    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .int => return json.Value.num(x),
        .bool => return .{ .bool = x },
        .@"enum" => return .{ .str = @tagName(x) },
        .array => {
            const out = try arena.alloc(json.Value, x.len);
            for (out, x) |*o, e| o.* = try plainValue(arena, e);
            return .{ .array = out };
        },
        .pointer => |ptr| {
            if (ptr.child == u8) return .{ .str = x };
            const out = try arena.alloc(json.Value, x.len);
            for (out, x) |*o, e| o.* = try plainValue(arena, e);
            return .{ .array = out };
        },
        .@"struct" => |st| {
            var fields: std.ArrayList(json.Field) = .empty;
            inline for (st.field_names) |name| {
                if (comptime std.mem.eql(u8, name, "provenance")) {
                    if (x.provenance.len != 0) try fields.append(arena, .{ .key = name, .value = .{ .str = x.provenance } });
                } else try fields.append(arena, .{ .key = name, .value = try plainValue(arena, @field(x, name)) });
            }
            return .{ .object = fields.items };
        },
        else => @compileError("not a plain record's field: " ++ @typeName(T)),
    }
}

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

fn bossesValue(arena: std.mem.Allocator, b: *const Bosses) !json.Value {
    const second = try arena.alloc(json.Value, b.second.len);
    for (second, b.second) |*o, s| o.* = .{ .bool = s };
    return withProvenance(arena, b.provenance, &.{
        .{ .key = "bars", .value = .{ .array = try arena.dupe(json.Value, &.{ try cellValue(arena, b.bars[0]), try cellValue(arena, b.bars[1]) }) } },
        .{ .key = "label", .value = try cellValue(arena, b.label) },
        .{ .key = "points", .value = json.Value.num(b.points) },
        .{ .key = "over", .value = .{ .array = try arena.dupe(json.Value, &.{ json.Value.num(b.over[0]), json.Value.num(b.over[1]) }) } },
        .{ .key = "second", .value = .{ .array = second } },
    });
}

/// The scores that give a life more, each more than the one before.
fn readExtraLives(arena: std.mem.Allocator, n: json.Node) Error![]const u32 {
    const out = try arena.alloc(u32, try n.len());
    for (out, 0..) |*o, i| {
        o.* = try (try n.at(i)).int(u32);
        if (i > 0 and o.* <= out[i - 1]) return (try n.at(i)).fail("not more than the score before");
    }
    return out;
}

fn readBosses(arena: std.mem.Allocator, n: json.Node) Error!Bosses {
    try n.only(&.{ "provenance", "bars", "label", "points", "over", "second" });
    const bars = try n.get("bars");
    if (try bars.len() != 2) return bars.fail("not the two bars' cells");
    const over = try n.get("over");
    if (try over.len() != 2) return over.fail("not [first look, second look]");
    const sn = try n.get("second");
    const second = try arena.alloc(bool, try sn.len());
    for (second, 0..) |*o, i| o.* = try (try sn.at(i)).boolean();
    const b: Bosses = .{
        .provenance = if (try n.opt("provenance")) |x| try x.string() else "",
        .bars = .{ try readCell(try bars.at(0)), try readCell(try bars.at(1)) },
        .label = try readCell(try n.get("label")),
        .points = try (try n.get("points")).int(u8),
        .over = .{ try (try over.at(0)).int(u16), try (try over.at(1)).int(u16) },
        .second = second,
    };
    if (b.points == 0) return (try n.get("points")).fail("not 1 or more");
    if (b.over[0] > b.over[1]) return over.fail("the second look before the first");
    return b;
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

fn clearValue(arena: std.mem.Allocator, c: *const Clear) !json.Value {
    const lines = try arena.alloc(json.Value, c.lines.len);
    for (lines, c.lines) |*o, l| o.* = try obj(arena, &.{
        .{ .key = "text", .value = .{ .str = l.text } },
        .{ .key = "at", .value = try cellValue(arena, l.at) },
    });
    return withProvenance(arena, c.provenance, &.{
        .{ .key = "header", .value = .{ .str = c.header } },
        .{ .key = "header_at", .value = try cellValue(arena, c.header_at) },
        .{ .key = "number", .value = try cellValue(arena, c.number) },
        .{ .key = "lines", .value = .{ .array = lines } },
        .{ .key = "digits", .value = json.Value.num(c.digits) },
        .{ .key = "normal", .value = json.Value.num(c.normal) },
        .{ .key = "counted", .value = json.Value.num(c.counted) },
        .{ .key = "wait", .value = json.Value.num(c.wait) },
        .{ .key = "clear_bonus", .value = json.Value.num(c.clear_bonus) },
        .{ .key = "time_bonus", .value = json.Value.num(c.time_bonus) },
        .{ .key = "level_bonus", .value = json.Value.num(c.level_bonus) },
        .{ .key = "count", .value = json.Value.num(c.count) },
        .{ .key = "colours", .value = .{ .str = c.colours } },
        .{ .key = "last_round", .value = json.Value.num(c.last_round) },
    });
}

fn readClear(n: json.Node) Error!Clear {
    try n.only(&.{ "provenance", "header", "header_at", "number", "lines", "digits", "normal", "counted", "wait", "clear_bonus", "time_bonus", "level_bonus", "count", "colours", "last_round" });
    const ls = try n.get("lines");
    if (try ls.len() != 6) return ls.fail("not the six bonuses' lines");
    var lines: [6]ClearLine = undefined;
    for (&lines, 0..) |*l, k| {
        const e = try ls.at(k);
        try e.only(&.{ "text", "at" });
        l.* = .{ .text = try (try e.get("text")).string(), .at = try readPlaneCell(try e.get("at")) };
    }
    const c: Clear = .{
        .provenance = if (try n.opt("provenance")) |x| try x.string() else "",
        .header = try (try n.get("header")).string(),
        .header_at = try readPlaneCell(try n.get("header_at")),
        .number = try readPlaneCell(try n.get("number")),
        .lines = lines,
        .digits = try (try n.get("digits")).int(u8),
        .normal = try (try n.get("normal")).int(u2),
        .counted = try (try n.get("counted")).int(u2),
        .wait = try (try n.get("wait")).int(u8),
        .clear_bonus = try (try n.get("clear_bonus")).int(u32),
        .time_bonus = try (try n.get("time_bonus")).int(u32),
        .level_bonus = try (try n.get("level_bonus")).int(u32),
        .count = try (try n.get("count")).int(u32),
        .colours = try (try n.get("colours")).string(),
        .last_round = try (try n.get("last_round")).int(u8),
    };
    for (c.lines, 0..) |l, k| if (k != 3 and l.text.len < @as(usize, c.digits) + 6) return (try ls.at(k)).fail("shorter than its digits");
    if (c.wait == 0 or c.count == 0) return n.fail("a wait or a count of none");
    return c;
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
    const extra_lives = try arena.alloc(json.Value, r.status_bar.extra_lives.len);
    for (extra_lives, r.status_bar.extra_lives) |*o, score| o.* = json.Value.num(score);
    const t = &r.time_over;
    const cq = &r.continue_question;
    const places = try arena.alloc(json.Value, 2);
    for (places, &cq.players) |*o, *p| o.* = try obj(arena, &.{
        .{ .key = "cleared", .value = .{ .array = try arena.dupe(json.Value, &.{ try cellValue(arena, p.cleared[0]), try cellValue(arena, p.cleared[1]) }) } },
        .{ .key = "question", .value = try cellValue(arena, p.question) },
        .{ .key = "answer", .value = try cellValue(arena, p.answer) },
        .{ .key = "yes", .value = try cellValue(arena, p.yes) },
        .{ .key = "no", .value = try cellValue(arena, p.no) },
        .{ .key = "out", .value = try cellValue(arena, p.out) },
    });
    const record = try obj(arena, &.{
        .{ .key = "banner", .value = try withProvenance(arena, b.provenance, &.{
            .{ .key = "left", .value = .{ .str = b.left } },
            .{ .key = "numbers", .value = try strings(arena, b.numbers) },
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
            .{ .key = "score_most", .value = json.Value.num(r.status_bar.score_most) },
            .{ .key = "extra_lives", .value = .{ .array = extra_lives } },
            .{ .key = "image", .value = .{ .array = try arena.dupe(json.Value, &.{ json.Value.num(r.status_bar.image_rows), json.Value.num(r.status_bar.image_cells) }) } },
            .{ .key = "bosses", .value = try bossesValue(arena, &r.status_bar.bosses) },
            .{ .key = "join", .value = try obj(arena, &.{
                .{ .key = "text", .value = .{ .str = r.status_bar.join.text } },
                .{ .key = "at", .value = try cellValue(arena, r.status_bar.join.at) },
                .{ .key = "blink", .value = json.Value.num(r.status_bar.join.blink) },
                .{ .key = "lives", .value = json.Value.num(r.status_bar.join.lives) },
                .{ .key = "next", .value = try nextValue(arena, &r.status_bar.join.next) },
            }) },
        }) },
        .{ .key = "clear", .value = try clearValue(arena, &r.clear) },
        .{ .key = "continue", .value = try withProvenance(arena, cq.provenance, &.{
            .{ .key = "question", .value = .{ .str = cq.question } },
            .{ .key = "count", .value = json.Value.num(cq.count) },
            .{ .key = "new_game", .value = .{ .str = cq.new_game } },
            .{ .key = "game_over", .value = .{ .str = cq.game_over } },
            .{ .key = "cursor", .value = .{ .str = cq.cursor } },
            .{ .key = "cleared", .value = json.Value.num(cq.cleared) },
            .{ .key = "players", .value = .{ .array = places } },
            .{ .key = "frame", .value = .{ .str = cq.frame } },
        }) },
        .{ .key = "name_entry", .value = try nameEntryValue(arena, &r.name_entry) },
        .{ .key = "enemy_colours", .value = try enemyColoursValue(arena, &r.enemy_colours) },
        .{ .key = "buttons", .value = try buttonsValue(arena, &r.buttons) },
        .{ .key = "levels", .value = try levelsValue(arena, &r.levels) },
    });
    // The attract demo, when the record has one.
    if (r.demo.ticks == 0) return record;
    return .{ .object = try std.mem.concat(arena, json.Field, &.{ record.object, &.{.{ .key = "demo", .value = try demoValue(arena, &r.demo) }} }) };
}

fn demoValue(arena: std.mem.Allocator, d: *const Demo) !json.Value {
    return withProvenance(arena, d.provenance, &.{
        .{ .key = "players", .value = .{ .array = try arena.dupe(json.Value, &.{ .{ .str = d.players[0] }, .{ .str = d.players[1] } }) } },
        .{ .key = "lives", .value = json.Value.num(d.lives) },
        .{ .key = "specials", .value = json.Value.num(d.specials) },
        .{ .key = "ticks", .value = json.Value.num(d.ticks) },
        .{ .key = "sign", .value = .{ .str = d.sign } },
        .{ .key = "pads", .value = .{ .array = try arena.dupe(json.Value, &.{ .{ .str = d.pads[0] }, .{ .str = d.pads[1] } }) } },
        .{ .key = "first_reading", .value = json.Value.num(d.first_reading) },
    });
}

fn readDemo(n: json.Node) Error!Demo {
    try n.only(&.{ "provenance", "players", "lives", "specials", "ticks", "sign", "pads", "first_reading" });
    var d: Demo = .{
        .provenance = if (try n.opt("provenance")) |x| try x.string() else "",
        .lives = try (try n.get("lives")).int(u8),
        .specials = try (try n.get("specials")).int(u8),
        .ticks = try (try n.get("ticks")).int(u16),
        .sign = try (try n.get("sign")).string(),
        .first_reading = try (try n.get("first_reading")).int(u8),
    };
    const ps = try n.get("players");
    if (try ps.len() != 2) return ps.fail("not the two players' characters");
    const pads = try n.get("pads");
    if (try pads.len() != 2) return pads.fail("not the two pads' readings");
    for (0..2) |k| {
        d.players[k] = try (try ps.at(k)).string();
        const p = try pads.at(k);
        const text = try p.string();
        if (text.len % 2 != 0) return p.fail("not two hexadecimal digits a reading");
        for (text) |c| if (!std.ascii.isHex(c)) return p.fail("not hexadecimal digits");
        d.pads[k] = text;
    }
    if (d.ticks == 0) return n.fail("a demo of no ticks");
    return d;
}

fn buttonsValue(arena: std.mem.Allocator, b: *const Buttons) !json.Value {
    const layouts = try arena.alloc(json.Value, b.layouts.len);
    for (layouts, b.layouts) |*o, l| {
        const f = try arena.alloc(json.Field, 3);
        f[0] = .{ .key = "special", .value = .{ .str = @tagName(l.special) } };
        f[1] = .{ .key = "attack", .value = .{ .str = @tagName(l.attack) } };
        f[2] = .{ .key = "jump", .value = .{ .str = @tagName(l.jump) } };
        o.* = .{ .object = f };
    }
    return withProvenance(arena, b.provenance, &.{.{ .key = "layouts", .value = .{ .array = layouts } }});
}

fn levelsValue(arena: std.mem.Allocator, l: *const Levels) !json.Value {
    var slower: [4]json.Value = undefined;
    var health: [4]json.Value = undefined;
    var power: [4]json.Value = undefined;
    var life: [4]json.Value = undefined;
    for (&slower, &health, &power, &life, l.slower, l.enemy_health, l.enemy_power, l.life_bonus) |*s, *h, *p, *b, sv, hv, pv, bv| {
        s.* = json.Value.num(sv);
        h.* = json.Value.num(hv);
        p.* = json.Value.num(pv);
        b.* = json.Value.num(bv);
    }
    return withProvenance(arena, l.provenance, &.{
        .{ .key = "enemy_health", .value = .{ .array = try arena.dupe(json.Value, &health) } },
        .{ .key = "enemy_power", .value = .{ .array = try arena.dupe(json.Value, &power) } },
        .{ .key = "life_bonus", .value = .{ .array = try arena.dupe(json.Value, &life) } },
        .{ .key = "slower", .value = .{ .array = try arena.dupe(json.Value, &slower) } },
        .{ .key = "slower_from", .value = json.Value.num(l.slower_from) },
    });
}

fn readLevels(n: json.Node) Error!Levels {
    try n.only(&.{ "provenance", "slower_from", "slower", "enemy_health", "enemy_power", "life_bonus" });
    var l: Levels = .{
        .provenance = if (try n.opt("provenance")) |x| try x.string() else "",
        .slower_from = try (try n.get("slower_from")).int(i32),
    };
    const s = try n.get("slower");
    const h = try n.get("enemy_health");
    const p = try n.get("enemy_power");
    if (try s.len() != 4) return s.fail("not 4 speeds, one a level");
    if (try h.len() != 4) return h.fail("not 4 healths, one a level");
    if (try p.len() != 4) return p.fail("not 4 powers, one a level");
    for (&l.slower, &l.enemy_health, &l.enemy_power, 0..) |*sv, *hv, *pv, k| {
        sv.* = try (try s.at(k)).int(i32);
        if (sv.* < 0) return (try s.at(k)).fail("a speed less than 0");
        hv.* = try (try h.at(k)).int(u8);
        pv.* = try (try p.at(k)).int(u8);
    }
    if (try n.opt("life_bonus")) |b| {
        if (try b.len() != 4) return b.fail("not 4 bonuses, one a level");
        for (&l.life_bonus, 0..) |*bv, k| bv.* = try (try b.at(k)).int(u32);
    }
    return l;
}

fn readButtons(arena: std.mem.Allocator, n: json.Node) Error!Buttons {
    try n.only(&.{ "provenance", "layouts" });
    const ls = try n.get("layouts");
    const count = try ls.len();
    if (count == 0 or count > 8) return ls.fail("not 1 to 8 layouts");
    const layouts = try arena.alloc(Layout, count);
    for (layouts, 0..) |*o, k| {
        const e = try ls.at(k);
        try e.only(&.{ "special", "attack", "jump" });
        inline for (.{ "special", "attack", "jump" }) |action| {
            const v = try e.get(action);
            @field(o, action) = std.meta.stringToEnum(Button, try v.string()) orelse return v.fail("not a button (a, b or c)");
        }
        if (o.special == o.attack or o.special == o.jump or o.attack == o.jump) return e.fail("a button for two actions");
    }
    return .{ .provenance = if (try n.opt("provenance")) |x| try x.string() else "", .layouts = layouts };
}

fn enemyColoursValue(arena: std.mem.Allocator, ec: *const EnemyColours) !json.Value {
    const sets = try arena.alloc(json.Value, ec.sets.len);
    for (sets, ec.sets) |*o, set| {
        var f: std.ArrayList(json.Field) = .empty;
        inline for (.{ "first", "second", "own" }) |name| if (@field(set, name)) |p| try f.append(arena, .{ .key = name, .value = .{ .str = p } });
        o.* = .{ .object = f.items };
    }
    const lines = try arena.alloc(json.Value, 3);
    for (lines, ec.lines) |*o, l| o.* = json.Value.num(l);
    return withProvenance(arena, ec.provenance, &.{
        .{ .key = "sets", .value = .{ .array = sets } },
        .{ .key = "lines", .value = .{ .array = lines } },
        .{ .key = "police", .value = .{ .str = ec.police } },
    });
}

fn readEnemyColours(arena: std.mem.Allocator, n: json.Node, a: ?*const art.Art) Error!EnemyColours {
    try n.only(&.{ "provenance", "sets", "lines", "police" });
    const ss = try n.get("sets");
    const sets = try arena.alloc(ColourSet, try ss.len());
    for (sets, 0..) |*o, k| {
        const e = try ss.at(k);
        try e.only(&.{ "first", "second", "own" });
        o.* = .{};
        inline for (.{ "first", "second", "own" }) |name| if (try e.opt(name)) |x| {
            @field(o, name) = try readPalette(x, a);
        };
        if ((o.own == null) == (o.first == null and o.second == null)) return e.fail("not a first and a second, or an own");
    }
    const ls = try n.get("lines");
    if (try ls.len() != 3) return ls.fail("not the first's, the second's and the other's");
    var lines: [3]u2 = undefined;
    for (&lines, 0..) |*l, k| l.* = try (try ls.at(k)).int(u2);
    return .{
        .provenance = if (try n.opt("provenance")) |x| try x.string() else "",
        .sets = sets,
        .lines = lines,
        .police = try readPalette(try n.get("police"), a),
    };
}

/// A palette's full name; with `a`, one of its palettes.
fn readPalette(n: json.Node, a: ?*const art.Art) Error![]const u8 {
    const name = try n.string();
    if (a) |x| if (x.palette(name) == null) return n.fail("not a palette of the art");
    return name;
}

fn nameEntryValue(arena: std.mem.Allocator, ne: *const NameEntry) !json.Value {
    const places = try arena.alloc(json.Value, 2);
    for (places, &ne.players) |*o, *p| o.* = try obj(arena, &.{
        .{ .key = "label", .value = try cellValue(arena, p.label) },
        .{ .key = "first", .value = try cellValue(arena, p.first) },
        .{ .key = "mark", .value = try cellValue(arena, p.mark) },
    });
    return withProvenance(arena, ne.provenance, &.{
        .{ .key = "label", .value = .{ .str = ne.label } },
        .{ .key = "letters", .value = try strings(arena, ne.letters) },
        .{ .key = "players", .value = .{ .array = places } },
    });
}

fn readNameEntry(arena: std.mem.Allocator, n: json.Node) Error!NameEntry {
    try n.only(&.{ "provenance", "label", "letters", "players" });
    const l = try n.get("letters");
    const letters = try arena.alloc([]const u8, try l.len());
    for (letters, 0..) |*o, k| o.* = try (try l.at(k)).string();
    if (letters.len == 0) return l.fail("no letters");
    const ps = try n.get("players");
    if (try ps.len() != 2) return ps.fail("not the two players'");
    var places: [2]NamePlaces = undefined;
    for (&places, 0..) |*o, k| {
        const e = try ps.at(k);
        try e.only(&.{ "label", "first", "mark" });
        o.* = .{ .label = try readCell(try e.get("label")), .first = try readCell(try e.get("first")), .mark = try readCell(try e.get("mark")) };
    }
    return .{
        .provenance = if (try n.opt("provenance")) |x| try x.string() else "",
        .label = try (try n.get("label")).string(),
        .letters = letters,
        .players = places,
    };
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
    if (std.mem.eql(u8, name, "ending")) return plainValue(arena, s.ending.?);
    if (std.mem.eql(u8, name, "boss_ending")) return plainValue(arena, s.boss_ending.?);
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

/// A plain record of type `T` from JSON (`plainValue`'s): every field it has, none it has not.
fn plainRead(comptime T: type, arena: std.mem.Allocator, n: json.Node) Error!T {
    switch (@typeInfo(T)) {
        .int => return n.int(T),
        .bool => return n.boolean(),
        .@"enum" => return std.meta.stringToEnum(T, try n.string()) orelse n.fail("not one of its names"),
        .array => |arr| {
            if (try n.len() != arr.len) return n.fail("not its count of entries");
            var out: T = undefined;
            for (&out, 0..) |*o, i| o.* = try plainRead(arr.child, arena, try n.at(i));
            return out;
        },
        .pointer => |ptr| {
            if (ptr.child == u8) return n.string();
            const out = try arena.alloc(ptr.child, try n.len());
            for (out, 0..) |*o, i| o.* = try plainRead(ptr.child, arena, try n.at(i));
            return out;
        },
        .@"struct" => |st| {
            const names = comptime blk: {
                var out: [st.field_names.len][]const u8 = undefined;
                for (st.field_names, 0..) |name, i| out[i] = name;
                break :blk out;
            };
            try n.only(&names);
            var out: T = undefined;
            inline for (st.field_names, st.field_types) |name, F| {
                if (comptime std.mem.eql(u8, name, "provenance")) {
                    out.provenance = if (try n.opt("provenance")) |p| try p.string() else "";
                } else @field(out, name) = try plainRead(F, arena, try n.get(name));
            }
            return out;
        },
        else => @compileError("not a plain record's field: " ++ @typeName(T)),
    }
}

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
    const c = try readPlaneCell(n);
    if (c.x >= 40 or c.y >= 4) return n.fail("not a cell of the status bar (40 x 4)");
    return c;
}

/// A cell of a plane (64 x 32).
fn readPlaneCell(n: json.Node) Error!Cell {
    if (try n.len() != 2) return n.fail("not [x, y]");
    const c: Cell = .{ .x = try (try n.at(0)).int(u8), .y = try (try n.at(1)).int(u8) };
    if (c.x >= 64 or c.y >= 32) return n.fail("not a cell of a plane (64 x 32)");
    return c;
}

/// A frame's name, checked against the art when given.
fn readFrame(n: json.Node, a: ?*const art.Art) Error![]const u8 {
    const f = try n.string();
    if (a) |x| if (x.frame(f) == null) return n.fail("no frame of this name in the art");
    return f;
}

fn readRound(arena: std.mem.Allocator, n: json.Node, a: ?*const art.Art) Error!Round {
    try n.only(&.{ "banner", "pause", "time_over", "status_bar", "continue", "name_entry", "enemy_colours", "clear", "buttons", "levels", "demo" });
    const b = try n.get("banner");
    try b.only(&.{ "provenance", "left", "numbers", "right", "fade", "in", "in_ticks", "wait", "out", "out_ticks", "after" });
    const ns = try b.get("numbers");
    const count = try ns.len();
    if (count == 0 or count > 8) return ns.fail("not a number for each of 1 to 8 rounds");
    const numbers = try arena.alloc([]const u8, count);
    for (numbers, 0..) |*o, k| o.* = try readFrame(try ns.at(k), a);
    const p = try n.get("pause");
    try p.only(&.{ "provenance", "frame" });
    const t = try n.get("time_over");
    try t.only(&.{ "provenance", "frame", "ticks", "health", "seconds" });
    const s = try n.get("status_bar");
    try s.only(&.{ "provenance", "players", "time", "join", "score_most", "extra_lives", "image", "bosses" });
    const image = try s.get("image");
    if (try image.len() != 2) return image.fail("not [rows, cells]");
    const j = try s.get("join");
    try j.only(&.{ "text", "at", "blink", "lives", "next" });
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
    const c = try n.get("continue");
    try c.only(&.{ "provenance", "question", "count", "new_game", "game_over", "cursor", "cleared", "players", "frame" });
    const cps = try c.get("players");
    if (try cps.len() != 2) return cps.fail("not the two players'");
    var places: [2]ContinuePlaces = undefined;
    for (&places, 0..) |*o, k| {
        const e = try cps.at(k);
        try e.only(&.{ "cleared", "question", "answer", "yes", "no", "out" });
        const cl = try e.get("cleared");
        if (try cl.len() != 2) return cl.fail("not the two rows'");
        o.* = .{
            .cleared = .{ try readCell(try cl.at(0)), try readCell(try cl.at(1)) },
            .question = try readCell(try e.get("question")),
            .answer = try readCell(try e.get("answer")),
            .yes = try readCell(try e.get("yes")),
            .no = try readCell(try e.get("no")),
            .out = try readCell(try e.get("out")),
        };
    }
    const r: Round = .{
        .clear = try readClear(try n.get("clear")),
        .continue_question = .{
            .provenance = if (try c.opt("provenance")) |x| try x.string() else "",
            .question = try (try c.get("question")).string(),
            .count = try (try c.get("count")).int(u8),
            .new_game = try (try c.get("new_game")).string(),
            .game_over = try (try c.get("game_over")).string(),
            .cursor = try (try c.get("cursor")).string(),
            .cleared = try (try c.get("cleared")).int(u8),
            .players = places,
            .frame = try readFrame(try c.get("frame"), a),
        },
        .name_entry = try readNameEntry(arena, try n.get("name_entry")),
        .enemy_colours = try readEnemyColours(arena, try n.get("enemy_colours"), a),
        .buttons = if (try n.opt("buttons")) |x| try readButtons(arena, x) else .{},
        .levels = if (try n.opt("levels")) |x| try readLevels(x) else .{},
        .demo = if (try n.opt("demo")) |x| try readDemo(x) else .{},
        .banner = .{
            .provenance = if (try b.opt("provenance")) |x| try x.string() else "",
            .left = try readFrame(try b.get("left"), a),
            .numbers = numbers,
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
            .join = .{
                .text = try (try j.get("text")).string(),
                .at = try readCell(try j.get("at")),
                .blink = try (try j.get("blink")).int(u8),
                .lives = try (try j.get("lives")).int(u8),
                .next = try readNext(try j.get("next")),
            },
            .score_most = try (try s.get("score_most")).int(u32),
            .extra_lives = if (try s.opt("extra_lives")) |x| try readExtraLives(arena, x) else &.{},
            .image_rows = try (try image.at(0)).int(u8),
            .image_cells = try (try image.at(1)).int(u8),
            .bosses = try readBosses(arena, try s.get("bosses")),
        },
    };
    if (r.status_bar.join.blink == 0) return (try j.get("blink")).fail("not 1 or more");
    if (r.status_bar.join.lives == 0 or r.status_bar.join.lives > 9) return (try j.get("lives")).fail("not 1 to 9");
    if (r.status_bar.score_most == 0 or r.status_bar.score_most > 999_999_999) return (try s.get("score_most")).fail("not 1 to 9 digits");
    if (r.banner.fade == 0 or r.banner.fade > 64) return (try b.get("fade")).fail("not 1 to 64 colours");
    if (r.banner.in_ticks == 0 or r.banner.out_ticks == 0 or r.banner.wait == 0 or r.banner.after == 0) return b.fail("a part of no ticks");
    if (r.time_over.ticks == 0) return (try t.get("ticks")).fail("not 1 or more");
    return r;
}

/// The join's characters: by each character's name, the character player 2 joins as.
fn nextValue(arena: std.mem.Allocator, next: *const [3]Character) !json.Value {
    var fields: [3]json.Field = undefined;
    for (&fields, std.enums.values(Character)) |*f, c| f.* = .{ .key = @tagName(c), .value = .{ .str = @tagName(next[@backingInt(c)]) } };
    return obj(arena, &fields);
}

fn readNext(n: json.Node) Error![3]Character {
    try n.only(&.{ "adam", "axel", "blaze" });
    var out: [3]Character = undefined;
    for (std.enums.values(Character)) |c| {
        const v = try n.get(@tagName(c));
        out[@backingInt(c)] = std.meta.stringToEnum(Character, try v.string()) orelse return v.fail("not a character (adam, axel, blaze)");
        if (out[@backingInt(c)] == c) return v.fail("player 1's own character");
    }
    return out;
}

/// Reads record `name` (its file's parsed `root`) into `into`; frames are checked against `a`.
pub fn read(arena: std.mem.Allocator, name: []const u8, root: json.Node, a: ?*const art.Art, into: *Screens) Error!void {
    if (std.mem.eql(u8, name, "round")) {
        into.round = try readRound(arena, root, a);
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
    if (std.mem.eql(u8, name, "boss_ending")) {
        into.boss_ending = try plainRead(BossEnding, arena, root);
        if (into.boss_ending.?.lines.len != 3) return (try root.get("lines")).fail("not its three lines");
        return;
    }
    if (std.mem.eql(u8, name, "ending")) {
        const e = try plainRead(Ending, arena, root);
        for (e.texts) |t| for (t.rows) |row| for (row) |c| if (c >= 0x80) return root.fail("a text's glyph not of the font");
        if (e.clouds.len != 2) return (try root.get("clouds")).fail("not the two clouds");
        into.ending = e;
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
            .banner = .{ .left = "play/l", .numbers = &.{"play/n"}, .right = "play/r", .fade = 17, .in = 4, .in_ticks = 35, .wait = 96, .out = 6, .out_ticks = 24, .after = 48 },
            .pause = .{ .frame = "play/pause" },
            .time_over = .{ .provenance = "synthetic", .frame = "play/time_over", .ticks = 256, .health = 80, .seconds = 55 },
            .status_bar = .{
                .players = @splat(.{ .name = "1UP-", .name_at = .{ .x = 1, .y = 1 }, .score = .{ .x = 5, .y = 1 }, .health = .{ .x = 1, .y = 2 }, .lives = .{ .x = 12, .y = 1 }, .lives_mark = .{ .x = 11, .y = 2 }, .icon = .{ .x = 14, .y = 1 }, .specials = .{ .x = 17, .y = 1 }, .specials_mark = .{ .x = 16, .y = 2 } }),
                .time = .{ .x = 19, .y = 1 },
                .join = .{ .text = "PRESS 2UP START", .at = .{ .x = 24, .y = 1 }, .blink = 8 },
                .score_most = 999_900,
                .extra_lives = &.{ 50_000, 150_000 },
                .image_rows = 3,
                .image_cells = 40,
                .bosses = .{ .bars = .{ .{ .x = 1, .y = 3 }, .{ .x = 27, .y = 3 } }, .label = .{ .x = 17, .y = 3 }, .points = 4, .over = .{ 81, 97 }, .second = &.{ false, true } },
            },
            .continue_question = .{
                .question = "CONTINUE",
                .count = 9,
                .new_game = "NEW GAME",
                .game_over = "GAME OVER",
                .cursor = "->",
                .cleared = 18,
                .players = .{
                    .{ .cleared = .{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } }, .question = .{ .x = 3, .y = 1 }, .answer = .{ .x = 3, .y = 2 }, .yes = .{ .x = 1, .y = 1 }, .no = .{ .x = 1, .y = 2 }, .out = .{ .x = 1, .y = 2 } },
                    .{ .cleared = .{ .{ .x = 21, .y = 1 }, .{ .x = 21, .y = 2 } }, .question = .{ .x = 29, .y = 1 }, .answer = .{ .x = 29, .y = 2 }, .yes = .{ .x = 27, .y = 1 }, .no = .{ .x = 27, .y = 2 }, .out = .{ .x = 27, .y = 2 } },
                },
                .frame = "play/game_over",
            },
            .enemy_colours = .{
                .sets = &.{ .{ .first = "e/c0_1", .second = "e/c0_2" }, .{ .own = "e/c1" } },
                .lines = .{ 1, 2, 1 },
                .police = "e/police",
            },
            .name_entry = .{
                .label = "NAME",
                .letters = &.{ "A", "B", "(ED)" },
                .players = .{
                    .{ .label = .{ .x = 1, .y = 2 }, .first = .{ .x = 6, .y = 2 }, .mark = .{ .x = 9, .y = 2 } },
                    .{ .label = .{ .x = 27, .y = 2 }, .first = .{ .x = 32, .y = 2 }, .mark = .{ .x = 35, .y = 2 } },
                },
            },
            .clear = .{
                .header = "round_end/header",
                .header_at = .{ .x = 7, .y = 7 },
                .number = .{ .x = 13, .y = 0 },
                .lines = .{
                    .{ .text = "CLEAR BONUS  000000 PTS", .at = .{ .x = 8, .y = 12 } },
                    .{ .text = " TIME BONUS  000000 PTS", .at = .{ .x = 8, .y = 14 } },
                    .{ .text = "LEVEL BONUS  000000 PTS", .at = .{ .x = 8, .y = 16 } },
                    .{ .text = "PLAYERS LEFT BONUS", .at = .{ .x = 8, .y = 19 } },
                    .{ .text = "        1UP  000000 PTS", .at = .{ .x = 8, .y = 21 } },
                    .{ .text = "        2UP  000000 PTS", .at = .{ .x = 8, .y = 23 } },
                },
                .digits = 13,
                .normal = 1,
                .counted = 2,
                .wait = 32,
                .clear_bonus = 10000,
                .time_bonus = 100,
                .level_bonus = 10000,
                .count = 100,
                .colours = "round_end/colours",
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

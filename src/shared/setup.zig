//! What the screens before play decide for the game that follows, kept from power-on to power-on
//! (the original keeps it in its memory; it has no saves, decision D2): the options' values, the
//! players and their characters, the high-score table; and the game under way, which play keeps
//! from one round to the next. It is part of the game's canonical state.
const std = @import("std");

pub const Players = enum(u8) { one, two };

pub const Character = enum(u8) { adam, axel, blaze };

/// An entry of the high-score table.
pub const Score = struct {
    score: u32 = 0,
    round: u8 = 0,
    /// Three letters of the game's font.
    name: [3]u8 = .{ ' ', ' ', ' ' },
    /// A level of the options (0 the easiest).
    level: u8 = 0,
    /// A new entry, shown once in its player's colours.
    new: ?u1 = null,
};

pub const high_scores = 10;

/// A player's part of the game under way.
pub const Gamer = struct {
    /// Playing (the game menu's choice; not out of the game).
    in_play: bool = false,
    /// Points, as the original counts them.
    score: u32 = 0,
    /// The lives, the one under way counted, and the special attacks.
    lives: u8 = 0,
    specials: u8 = 0,
    /// The continues left.
    continues: u8 = 0,
};

/// The game under way, kept from one round to the next (the original keeps it in its memory):
/// the round reached and each player's part. Round 0 is no game: the next round starts one.
pub const Progress = struct {
    round: u8 = 0,
    players: [2]Gamer = .{ .{}, .{} },
    /// The round's timer when its round was won, for the clear's time bonus.
    timer: u8 = 0,

    /// A new game: the players of the game menu's choice in play, each with the lives of the
    /// options (1, 3, 5 or 7) and three continues (the original's, set as the character select
    /// ends), the other player's lives set too, as the original's are. It starts at round 1
    /// (TODO(PLAN item 15): the options' first round, once rounds 2 to 8 are there).
    pub fn new(setup: *const Setup) Progress {
        var p: Progress = .{ .round = 1 };
        for (&p.players, 0..) |*g, k| g.* = .{
            .in_play = k == 0 or setup.players == .two,
            .lives = 2 * setup.lives + 1,
            .continues = 3,
        };
        return p;
    }
};

pub const Setup = struct {
    /// The game menu's choice: one or two players.
    players: Players = .one,
    /// The options' values: LEVEL (0 easy to 3 hardest; normal at power-on), CONTROL (0 to 2),
    /// the lives (0 to 3: 1, 3, 5 or 7 lives), the first round (0 to 7, back to 0 at each intro),
    /// the sound test's entry.
    level: u8 = 1,
    control: u8 = 0,
    lives: u8 = 1,
    first_round: u8 = 0,
    sound_test: u8 = 0,
    /// The options' hidden lines (the lives, the first round), opened by a code on pad 2 at the
    /// game menu, for one visit of the options.
    hidden_lines: bool = false,
    /// Each player's character, once chosen.
    characters: [2]?Character = .{ null, null },
    /// The high-score table; null until a game changes it: the content's first one stands.
    high_scores: ?[high_scores]Score = null,
    /// The game under way.
    progress: Progress = .{},
};

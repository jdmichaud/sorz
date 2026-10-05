//! The flow between the scenes (DESIGN.md 10.4, S2): one table of the scenes and their exits. A
//! scene ends with an exit of its own (`Exit`: its time is out, START, a choice...), and the table
//! says which scene follows, and how long the load between them lasts (T4: the original's waits
//! with the screen dark, scenes of their own with their measured length). A variant of the game
//! (DESIGN.md 10.7) is another table: the browser's flow, for example, will have its own.
const std = @import("std");

/// The scenes of the game, by kind.
pub const Kind = enum {
    /// What the game shows without its content: the repository's checks run on it.
    test_pattern,
    /// A load: the screen dark for its measured time, then the scene that follows (`Load`).
    load,
    sega_logo,
    /// The story, the profiles and the title they end on.
    intro,
    /// The title when START skips the intro: its pictures already in place.
    title,
    /// 1 PLAYER, 2 PLAYERS, OPTIONS.
    menu,
    options,
    /// The character select.
    select,
    /// The attract demo: round 1 played by the game (PLAN items 11-13); a stand-in until then.
    demo,
    high_scores,
    /// Play: a round, from its load to its end (round 1: PLAN item 13).
    round,
    /// The round's clear and its bonuses.
    round_clear,
    /// The next round: round 2 and on are PLAN item 15, a stand-in until then, which says so.
    next_round,
};

/// How a scene ends.
pub const Exit = enum {
    /// Its time is out, or its last part is done.
    done,
    /// START (pressed where the scene leaves on it).
    start,
    /// START where it leaves for the game menu (the intro once its title is up).
    menu,
    one_player,
    two_players,
    options,
    /// The characters are chosen.
    chosen,
    /// The round is won.
    cleared,
    /// Every player is out of the game.
    game_over,
};

/// One edge of the graph: scene `from`, ended by `exit`, goes to `to`, after a load of `load`
/// display ticks (0: none) during which the screen is dark and, when `sound_held`, the sound's
/// driver does not run (the original's loads hold its interrupts).
pub const Edge = struct {
    from: Kind,
    exit: Exit,
    to: Kind,
    load: u16 = 0,
    sound_held: bool = true,
};

/// A flow graph: its edges, and the scene the game starts on at power-on, after `power_on`
/// dark ticks.
pub const Graph = struct {
    first: Kind,
    power_on: u16,
    edges: []const Edge,

    /// Where `from` goes by `exit`.
    pub fn next(self: *const Graph, from: Kind, exit: Exit) ?*const Edge {
        for (self.edges) |*e| if (e.from == from and e.exit == exit) return e;
        return null;
    }
};

/// The cartridge's flow (sor-remaster's docs/workflows.md, G1 to G9): the Sega logo, the intro
/// and its title, the attract demo and the high scores, around again; START on the title to the
/// game menu, the options and back, the character select, play: a round won to its clear and the
/// next round, the game over to the high scores. The loads are the original's
/// measured waits (in display ticks, the picture dark).
pub const original: Graph = .{
    .first = .sega_logo,
    .power_on = 76,
    .edges = &.{
        .{ .from = .sega_logo, .exit = .done, .to = .intro, .load = 35 },
        .{ .from = .intro, .exit = .done, .to = .demo, .load = 47 },
        .{ .from = .intro, .exit = .start, .to = .title },
        .{ .from = .intro, .exit = .menu, .to = .menu, .load = 3 },
        .{ .from = .title, .exit = .done, .to = .demo, .load = 47 },
        .{ .from = .title, .exit = .start, .to = .menu, .load = 3 },
        .{ .from = .demo, .exit = .done, .to = .high_scores, .load = 4 },
        .{ .from = .demo, .exit = .start, .to = .sega_logo, .load = 14 },
        .{ .from = .high_scores, .exit = .done, .to = .sega_logo, .load = 14 },
        .{ .from = .high_scores, .exit = .start, .to = .sega_logo, .load = 14 },
        .{ .from = .menu, .exit = .one_player, .to = .select, .load = 31 },
        .{ .from = .menu, .exit = .two_players, .to = .select, .load = 31 },
        .{ .from = .menu, .exit = .options, .to = .options },
        .{ .from = .options, .exit = .done, .to = .menu, .load = 3 },
        .{ .from = .select, .exit = .chosen, .to = .round, .load = 53 },
        .{ .from = .round, .exit = .cleared, .to = .round_clear },
        .{ .from = .round, .exit = .game_over, .to = .high_scores, .load = 4 },
        .{ .from = .round_clear, .exit = .done, .to = .next_round },
    },
};

test "every scene but the test pattern and the load has a way in, and every edge's way is one" {
    const g = original;
    for (std.enums.values(Kind)) |k| {
        if (k == .test_pattern or k == .load) continue;
        var into = k == g.first;
        for (g.edges) |e| into = into or e.to == k;
        try std.testing.expect(into);
    }
    for (g.edges, 0..) |a, i| for (g.edges[i + 1 ..]) |b| {
        try std.testing.expect(!(a.from == b.from and a.exit == b.exit));
    };
    try std.testing.expectEqual(Kind.intro, g.next(.sega_logo, .done).?.to);
    try std.testing.expect(g.next(.round, .done) == null);
}

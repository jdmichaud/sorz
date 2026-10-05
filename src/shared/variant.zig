//! The variants of the game (DESIGN.md 10.7, E2): configurations of the same scenes and systems,
//! never tests of a flag spread through the code. A variant is a flow graph (flow.zig) and a set of
//! named policies (E1: each rule a small function, with a default); the content is the same for
//! all three today, and a variant's content overlay goes with its configuration when one needs it.
//!
//! - **original** (`--original`): the cartridge exactly: its flow, its game menu (1 PLAYER,
//!   2 PLAYERS, OPTIONS), its options. It is the variant that the lockstep and the checks against
//!   sor-remaster compare.
//! - **extended**, the default: the port's liberties: SETTINGS in the game menu after 2 PLAYERS,
//!   the native game's VOLUME in OPTIONS; later the same character twice (PLAN item 20, a policy
//!   and the content's palettes).
//! - **network**: network play and the browser, one player a machine: the players are the
//!   machines' (one alone, two in a session), chosen before the game starts, so the game menu has
//!   no 1 PLAYER or 2 PLAYERS but START, then SETTINGS and OPTIONS, and either player's pad drives
//!   it (SETTINGS opens the settings of the player who chose it).
//!
//! A variant is chosen when the game starts (`Start`), and is part of the game's canonical state:
//! in network play the host's start is both games' (the session's welcome carries it).
const std = @import("std");
const flow = @import("flow.zig");
const input = @import("input.zig");
const setup_mod = @import("setup.zig");

const Character = setup_mod.Character;

pub const Variant = enum(u8) {
    original,
    extended,
    network,

    pub fn config(v: Variant) *const Config {
        return switch (v) {
            .original => &original,
            .extended => &extended,
            .network => &network,
        };
    }

    /// The variant of a run without an option: network play's, or the default.
    pub fn of(options: struct { original: bool = false, network: bool = false }) Variant {
        if (options.original) return .original;
        return if (options.network) .network else .extended;
    }
};

/// What a game starts with, which decides it from power-on with the pads alone: the variant and
/// what the machines give it. Part of the game's canonical state (game.zig).
pub const Start = struct {
    variant: Variant = .original,
    /// The players from power-on, where the variant takes them from the machines (`players_chosen`
    /// is false: network play's two, a browser's one); else the game menu chooses them.
    players: setup_mod.Players = .one,
    /// The value of OPTIONS' VOLUME line at power-on, null without the line: the settings' volume
    /// of player 1's machine, where the variant has the line and that machine sounds the game
    /// itself (a native game; a browser's page applies its own volume, its settings').
    volume: ?u8 = null,

    /// The start of a game with `variant` on a machine whose settings' volume is `volume`;
    /// `native`: the machine sounds the game itself (not a browser's page); `players`: those the
    /// machines have (two in network play).
    pub fn of(variant: Variant, native: bool, volume: u8, players: setup_mod.Players) Start {
        const p = &variant.config().policies;
        return .{
            .variant = variant,
            .players = if (p.players_chosen) .one else players,
            .volume = if (p.volumeLine(native)) volume else null,
        };
    }
};

/// The game menu's lines.
pub const MenuLine = enum(u8) {
    one_player,
    two_players,
    /// The network variant's start: the game for the players the machines have.
    start,
    /// The port's settings (an overlay over the game, held while it is open).
    settings,
    options,
};

/// The pad that drives the game menu at a tick, and whose it is.
pub const MenuPad = struct { pressed: input.Pad, player: u1 };

/// The rules that a variant may change, each a named function with a default (the cartridge's).
/// The scenes ask them through their turn (scene.Turn.policies); nothing else knows the variant.
pub const Policies = struct {
    /// The game menu's lines, from the top.
    menuLines: *const fn () []const MenuLine = cartridgeMenu,
    /// Which pad drives the game menu at a tick.
    menuPad: *const fn (pressed: input.Pads) MenuPad = firstPad,
    /// Whether the game menu chooses the players (1 PLAYER, 2 PLAYERS): else the machines do.
    players_chosen: bool = true,
    /// Whether OPTIONS has the port's VOLUME line, given whether player 1's machine sounds the
    /// game itself.
    volumeLine: *const fn (native: bool) bool = never,
    /// Whether character `wanted` is taken for a player, the other player's cursor on `other` at
    /// the character select (two players): their cursor then passes it.
    characterTaken: *const fn (other: Character, wanted: Character) bool = takenByTheOther,
};

pub const Config = struct {
    graph: *const flow.Graph,
    policies: Policies,
};

pub const original: Config = .{ .graph = &flow.original, .policies = .{} };

pub const extended: Config = .{ .graph = &flow.extended, .policies = .{
    .menuLines = extendedMenu,
    .volumeLine = whenNative,
} };

pub const network: Config = .{ .graph = &flow.network, .policies = .{
    .menuLines = networkMenu,
    .menuPad = eitherPad,
    .players_chosen = false,
    .volumeLine = whenNative,
} };

// --- the policies -------------------------------------------------------------------------------

/// The cartridge's game menu.
pub fn cartridgeMenu() []const MenuLine {
    return &.{ .one_player, .two_players, .options };
}

/// The extended game menu: the settings right after the players, before OPTIONS.
pub fn extendedMenu() []const MenuLine {
    return &.{ .one_player, .two_players, .settings, .options };
}

/// One player a machine: the players are known; the menu starts the game, or opens the settings
/// or the options.
pub fn networkMenu() []const MenuLine {
    return &.{ .start, .settings, .options };
}

/// Pad 1, as the cartridge's menu reads it.
pub fn firstPad(pressed: input.Pads) MenuPad {
    return .{ .pressed = pressed.pad1, .player = 0 };
}

/// Either player's pad, player 1's first: each machine has its player, and each player opens
/// their own settings.
pub fn eitherPad(pressed: input.Pads) MenuPad {
    if (@as(u8, @bitCast(pressed.pad1)) != 0 or @as(u8, @bitCast(pressed.pad2)) == 0) return firstPad(pressed);
    return .{ .pressed = pressed.pad2, .player = 1 };
}

pub fn never(_: bool) bool {
    return false;
}

pub fn whenNative(native: bool) bool {
    return native;
}

/// The cartridge's rule: one character a player.
pub fn takenByTheOther(other: Character, wanted: Character) bool {
    return other == wanted;
}

const testing = std.testing;

test "each variant: its graph, its menu, the players and the VOLUME line it starts with" {
    try testing.expectEqual(Variant.original, Variant.of(.{ .original = true, .network = true }));
    try testing.expectEqual(Variant.network, Variant.of(.{ .network = true }));
    try testing.expectEqual(Variant.extended, Variant.of(.{}));

    const o = Start.of(.original, true, 70, .two);
    try testing.expect(o.volume == null and o.players == .one);
    try testing.expectEqualSlices(MenuLine, &.{ .one_player, .two_players, .options }, Variant.original.config().policies.menuLines());
    try testing.expect(Variant.original.config().graph == &flow.original);

    const e = Start.of(.extended, true, 70, .two);
    try testing.expect(e.volume.? == 70 and e.players == .one);
    try testing.expectEqualSlices(MenuLine, &.{ .one_player, .two_players, .settings, .options }, Variant.extended.config().policies.menuLines());

    // The network variant: the machines' players; the line only with a native game as player 1.
    const n = Start.of(.network, true, 40, .two);
    try testing.expect(n.volume.? == 40 and n.players == .two);
    try testing.expect(Start.of(.network, false, 40, .one).volume == null);
    try testing.expectEqualSlices(MenuLine, &.{ .start, .settings, .options }, Variant.network.config().policies.menuLines());
}

test "the menu's pad: pad 1 in the cartridge's, either player's in the network variant" {
    const both: input.Pads = .{ .pad1 = .{ .down = true }, .pad2 = .{ .a = true } };
    const two: input.Pads = .{ .pad2 = .{ .a = true } };
    try testing.expectEqual(@as(u1, 0), firstPad(two).player);
    try testing.expect(!firstPad(two).pressed.a);
    try testing.expectEqual(@as(u1, 1), eitherPad(two).player);
    try testing.expect(eitherPad(two).pressed.a);
    try testing.expect(eitherPad(both).player == 0 and eitherPad(both).pressed.down);
    try testing.expect(takenByTheOther(.axel, .axel) and !takenByTheOther(.adam, .axel));
}

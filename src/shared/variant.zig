//! The variants of the game (DESIGN.md 10.7, E2): configurations of the same scenes and systems,
//! never tests of a flag spread through the code. A variant is a flow graph (flow.zig) and a set of
//! named policies (E1: each rule a small function, with a default); the content is the same for
//! all three today, and a variant's content overlay goes with its configuration when one needs it.
//!
//! - **original** (`--original`): the cartridge exactly: its flow, its game menu (1 PLAYER,
//!   2 PLAYERS, OPTIONS), its options, its pause on START; the port's settings by the settings key
//!   (F1) alone. It is the variant that the checks against sor-remaster compare.
//! - **extended**, the default: the port's liberties: ADVANCED SETTINGS in OPTIONS, before EXIT,
//!   START during play opening the settings in place of the pause, the same character for both
//!   players (PLAN item 20: its rule, and the content's colours for the second), and the game's
//!   rules from the settings (the lives, the continues, the friendly hits) in place of the
//!   options' hidden lives.
//! - **network**: network play and the browser, one player a machine. Each machine runs its own
//!   front end; its game menu is 2 PLAYERS and OPTIONS: 2 PLAYERS goes to the character select
//!   with this machine's player alone, and the other machine's player joins there or in the round
//!   (DESIGN.md 9). Its OPTIONS and START are the extended game's.
//!
//! A variant is chosen when the game starts (`Start`), and is part of the game's canonical state:
//! in network play the join carries the host's game, its variant with it.
const std = @import("std");
const flow = @import("flow.zig");
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

/// What a game starts with, which decides it from power-on with the pads alone. Part of the
/// game's canonical state (game.zig).
pub const Start = struct {
    variant: Variant = .original,
};

/// The game menu's lines.
pub const MenuLine = enum(u8) { one_player, two_players, options };

/// The rules that a variant may change, each a named function or value with a default (the
/// cartridge's). The scenes ask them through their turn (scene.Turn.policies), and the game for
/// its overlays; nothing else knows the variant.
pub const Policies = struct {
    /// The game menu's lines, from the top.
    menuLines: *const fn () []const MenuLine = cartridgeMenu,
    /// The players that the game menu's 2 PLAYERS puts in the game on this machine: both (the
    /// cartridge's), or this machine's alone, the other player joining from another machine.
    two_players_here: bool = true,
    /// OPTIONS has ADVANCED SETTINGS, before EXIT: the port's settings.
    advanced_settings: bool = false,
    /// START during play opens the settings, which hold the game as the pause does, in place of
    /// the pause.
    start_opens_settings: bool = false,
    /// The settings key opens the settings, in any scene.
    settings_key: bool = true,
    /// The game's rules are the settings' (setup.zig `Rules`: the lives, the continues, the
    /// friendly hits), which replace the options' hidden lives; else the cartridge's.
    settings_rules: bool = false,
    /// Whether character `wanted` is taken for a player, the other player's cursor on `other` at
    /// the character select (two players): their cursor then passes it.
    characterTaken: *const fn (other: Character, wanted: Character) bool = takenByTheOther,
    /// The colours a second player playing the first player's character is drawn with: the
    /// colour map of that name in the character's definition (`colour_maps`); none: its own.
    duplicate_colours: ?[]const u8 = null,
};

pub const Config = struct {
    graph: *const flow.Graph,
    policies: Policies,
};

pub const original: Config = .{ .graph = &flow.original, .policies = .{} };

pub const extended: Config = .{ .graph = &flow.extended, .policies = .{
    .advanced_settings = true,
    .start_opens_settings = true,
    .settings_key = false,
    .settings_rules = true,
    .characterTaken = neverTaken,
    .duplicate_colours = "duplicate",
} };

pub const network: Config = .{ .graph = &flow.network, .policies = .{
    .menuLines = networkMenu,
    .two_players_here = false,
    .advanced_settings = true,
    .start_opens_settings = true,
    .settings_key = false,
    .settings_rules = true,
} };

// --- the policies -------------------------------------------------------------------------------

/// The cartridge's game menu.
pub fn cartridgeMenu() []const MenuLine {
    return &.{ .one_player, .two_players, .options };
}

/// One player a machine: 2 PLAYERS plays with the other machine's player, who may join later.
pub fn networkMenu() []const MenuLine {
    return &.{ .two_players, .options };
}

/// The cartridge's rule: one character a player.
pub fn takenByTheOther(other: Character, wanted: Character) bool {
    return other == wanted;
}

/// The port's: both players may play the same character.
pub fn neverTaken(other: Character, wanted: Character) bool {
    _ = other;
    _ = wanted;
    return false;
}

const testing = std.testing;

test "each variant: its graph, its menu, its options' lines, START and the settings key" {
    try testing.expectEqual(Variant.original, Variant.of(.{ .original = true, .network = true }));
    try testing.expectEqual(Variant.network, Variant.of(.{ .network = true }));
    try testing.expectEqual(Variant.extended, Variant.of(.{}));

    const o = &Variant.original.config().policies;
    try testing.expectEqualSlices(MenuLine, &.{ .one_player, .two_players, .options }, o.menuLines());
    try testing.expect(Variant.original.config().graph == &flow.original);
    try testing.expect(o.two_players_here and !o.advanced_settings and !o.start_opens_settings and o.settings_key);

    const e = &Variant.extended.config().policies;
    try testing.expectEqualSlices(MenuLine, &.{ .one_player, .two_players, .options }, e.menuLines());
    try testing.expect(e.advanced_settings and e.start_opens_settings and !e.settings_key);
    try testing.expect(!e.characterTaken(.axel, .axel) and o.characterTaken(.axel, .axel));
    try testing.expectEqualStrings("duplicate", e.duplicate_colours.?);
    try testing.expect(o.duplicate_colours == null);

    const n = &Variant.network.config().policies;
    try testing.expectEqualSlices(MenuLine, &.{ .two_players, .options }, n.menuLines());
    try testing.expect(!n.two_players_here and n.advanced_settings and n.start_opens_settings and !n.settings_key);
    try testing.expect(n.characterTaken(.axel, .axel) and n.duplicate_colours == null);
    try testing.expect(takenByTheOther(.axel, .axel) and !takenByTheOther(.adam, .axel));
}

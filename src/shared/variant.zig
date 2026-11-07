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
//!   players (PLAN item 20: its rule, and the content's colours for the second), the game's
//!   rules from the settings (the lives, the continues, the friendly hits) in place of the
//!   options' hidden lives, the CPU as player 2 (PLAN item 30), and 3 and 4 PLAYERS on one
//!   machine (DESIGN.md 10.7, E4).
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

/// The game menu's lines: the cartridge's, and network play's (DESIGN.md 9): the host's NETWORK
/// PLAY, a client's NAME, JOIN and OBSERVE.
pub const MenuLine = enum(u8) { one_player, two_players, options, network_play, name, join, observe };

/// What this machine is in network play: none, the host (or one that may host: the native game,
/// the first page of a server), or a client.
pub const NetRole = enum(u8) { none, host, client };

/// The rules that a variant may change, each a named function or value with a default (the
/// cartridge's). The scenes ask them through their turn (scene.Turn.policies), and the game for
/// its overlays; nothing else knows the variant.
pub const Policies = struct {
    /// The game menu's lines, from the top, for this machine's part in network play.
    menuLines: *const fn (role: NetRole) []const MenuLine = cartridgeMenu,
    /// The players that the game menu's 2 PLAYERS puts in the game on this machine: both (the
    /// cartridge's), or this machine's alone, the other player joining from another machine.
    two_players_here: bool = true,
    /// OPTIONS has ADVANCED SETTINGS, before EXIT: the port's settings.
    advanced_settings: bool = false,
    /// Left and right on the game menu's 2 PLAYERS make it 1 PLAYER - 1 CPU: player 2 the CPU's.
    cpu_player: bool = false,
    /// The most players the game menu's 2 PLAYERS puts in the game on one machine: the
    /// cartridge's two, or up to four (DESIGN.md 10.7, E4: right on it, 3 PLAYERS and 4 PLAYERS,
    /// as many as the machine's input methods, before the CPU's readings).
    local_players: u8 = 2,
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
    /// The colours a player playing a character that players before it play is drawn with, by
    /// how many play it before it (the second on a character, the third, the fourth: DESIGN.md
    /// 10.7, E4): the colour maps of these names in the character's definition (`colour_maps`);
    /// none (or past the list): its own.
    duplicate_colours: []const []const u8 = &.{},

    /// The colour map (`duplicate_colours`) of a player playing `character`, the players before
    /// it playing `before`: none on a character none of them plays (its own colours).
    pub fn coloursOf(p: *const Policies, before: []const ?Character, character: Character) ?[]const u8 {
        var on: usize = 0;
        for (before) |c| on += @intFromBool(c == character);
        if (on == 0 or on > p.duplicate_colours.len) return null;
        return p.duplicate_colours[on - 1];
    }
};

pub const Config = struct {
    graph: *const flow.Graph,
    policies: Policies,
};

pub const original: Config = .{ .graph = &flow.original, .policies = .{} };

pub const extended: Config = .{ .graph = &flow.extended, .policies = .{
    .advanced_settings = true,
    .cpu_player = true,
    .local_players = 4,
    .start_opens_settings = true,
    .settings_key = false,
    .settings_rules = true,
    .menuLines = extendedMenu,
    .characterTaken = neverTaken,
    .duplicate_colours = &same_character_colours,
} };

pub const network: Config = .{ .graph = &flow.network, .policies = .{
    .menuLines = networkMenu,
    .two_players_here = false,
    .advanced_settings = true,
    .start_opens_settings = true,
    .settings_key = false,
    .settings_rules = true,
    .duplicate_colours = &same_character_colours,
} };

/// The colour maps of the second, the third and the fourth player of one character: the
/// content's `duplicate` (PLAN item 20), `third` and `fourth` (item 49).
const same_character_colours = [_][]const u8{ "duplicate", "third", "fourth" };

// --- the policies -------------------------------------------------------------------------------

/// The cartridge's game menu.
pub fn cartridgeMenu(_: NetRole) []const MenuLine {
    return &.{ .one_player, .two_players, .options };
}

/// The extended game's: the cartridge's, and NETWORK PLAY on a machine that may host.
pub fn extendedMenu(role: NetRole) []const MenuLine {
    return if (role == .host) &.{ .one_player, .two_players, .network_play, .options } else &.{ .one_player, .two_players, .options };
}

/// One player a machine: the host page's 1 PLAYER and NETWORK PLAY; a client's NAME, JOIN (the
/// host's game, as its second player) and OBSERVE (watching it). Without a part yet (the page
/// waiting for its role): 2 PLAYERS, which waits for one.
pub fn networkMenu(role: NetRole) []const MenuLine {
    return switch (role) {
        .host => &.{ .one_player, .network_play, .options },
        .client => &.{ .name, .join, .observe, .options },
        .none => &.{ .two_players, .options },
    };
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
    try testing.expectEqualSlices(MenuLine, &.{ .one_player, .two_players, .options }, o.menuLines(.host));
    try testing.expect(Variant.original.config().graph == &flow.original);
    try testing.expect(o.two_players_here and !o.advanced_settings and !o.start_opens_settings and o.settings_key);

    const e = &Variant.extended.config().policies;
    try testing.expectEqualSlices(MenuLine, &.{ .one_player, .two_players, .options }, e.menuLines(.none));
    try testing.expectEqualSlices(MenuLine, &.{ .one_player, .two_players, .network_play, .options }, e.menuLines(.host));
    try testing.expect(e.advanced_settings and e.start_opens_settings and !e.settings_key);
    try testing.expect(e.cpu_player and !o.cpu_player and !Variant.network.config().policies.cpu_player);
    try testing.expect(e.local_players == 4 and o.local_players == 2 and Variant.network.config().policies.local_players == 2);
    try testing.expect(!e.characterTaken(.axel, .axel) and o.characterTaken(.axel, .axel));
    try testing.expectEqualStrings("duplicate", e.duplicate_colours[0]);
    try testing.expectEqualStrings("fourth", e.duplicate_colours[2]);
    try testing.expect(o.duplicate_colours.len == 0);
    // A character's first player its own colours, the second `duplicate`, the third and fourth
    // theirs; in the cartridge, its own.
    const four = [_]?Character{ .adam, .axel, .adam, .adam };
    try testing.expect(e.coloursOf(four[0..0], .adam) == null and e.coloursOf(four[0..1], .axel) == null);
    try testing.expectEqualStrings("duplicate", e.coloursOf(four[0..2], .adam).?);
    try testing.expectEqualStrings("third", e.coloursOf(four[0..3], .adam).?);
    try testing.expectEqualStrings("duplicate", e.coloursOf(four[0..3], .axel).?);
    try testing.expectEqualStrings("fourth", e.coloursOf(&four, .adam).?);
    try testing.expect(o.coloursOf(four[0..1], .adam) == null);

    const n = &Variant.network.config().policies;
    try testing.expectEqualSlices(MenuLine, &.{ .two_players, .options }, n.menuLines(.none));
    try testing.expectEqualSlices(MenuLine, &.{ .one_player, .network_play, .options }, n.menuLines(.host));
    try testing.expectEqualSlices(MenuLine, &.{ .name, .join, .observe, .options }, n.menuLines(.client));
    try testing.expect(!n.two_players_here and n.advanced_settings and n.start_opens_settings and !n.settings_key);
    try testing.expect(n.characterTaken(.axel, .axel));
    try testing.expect(takenByTheOther(.axel, .axel) and !takenByTheOther(.adam, .axel));
}

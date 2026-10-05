//! Network play as each machine's game runs it (DESIGN.md 9): each machine its own front end, the
//! players meeting in one game.
//!
//! - **The host** (player 1: the native game of `--netplay`, the first page of a relay to choose 2
//!   PLAYERS) plays its own game and says what it is (`status`: its front end, a character select
//!   a second player may join, or play, with player 1's character). When a guest asks to join, its
//!   game takes it at the next tick it can (`State.joining`): the select's second cursor, or the
//!   round's drop-in, at once; between two rounds, later; in play without a character, the guest
//!   is asked to choose first. Its game's canonical form then crosses (`Netplay.begin`), and from
//!   that tick on both games run in lockstep. A guest that leaves, or does not come back in time
//!   after its connection dropped, leaves the game (`State.dropOut`), and the host plays on.
//! - **The guest** (player 2) plays its own front end too; its player's 2 PLAYERS goes to its own
//!   character select, where it asks to join: at once when the host's game is at its select; once
//!   it chose a character when the host plays (that character taken: `Turn.taken`); once the host
//!   has a game when it has none (it waits, its choice made). It loads the host's game when it
//!   comes (`Game.load`), and when that game ends it plays on alone. When the host leaves the game
//!   under way, its player plays on alone, as player 2, until that game ends (`Game.seat`); at
//!   the select, or when its own connection did not come back in time (its player left the game),
//!   it goes back to its own menu. A guest turned away (two play there, other data) plays alone.
//! - **The session's end**: both machines end it at the same tick, the one their game ends at.
//!
//! What crosses the network is the session's (net/); what the player is told is this machine's
//! own (overlay.zig: the network's messages, which hold the game while it waits).
const std = @import("std");
const platform = @import("platform.zig");
const net = @import("net/root.zig");
const overlay = @import("overlay.zig");
const setup_mod = @import("setup.zig");
const canonical = @import("canonical.zig");
const game_mod = @import("game.zig");

const protocol = net.protocol;
const Game = game_mod.Game;
const State = game_mod.State;
const Character = setup_mod.Character;
const Message = overlay.Message;

/// Once per update, after the events and the driver's update: what the session said, then the
/// host's status and the join it takes, or the guest's wish to join; the waits and their messages.
pub fn update(g: *Game, p: *platform.Platform) void {
    const np = g.netplay orelse return;
    var alone = false;
    for (np.pending()) |n| switch (n) {
        // A session starts: what was said of the last one is over.
        .started => |st| if (!st.resumed) g.tellNetwork(null),
        .joined => if (np.role == .guest) joined(g, p, np),
        .ended => |why| ended(g, p, np.role, why),
        .refused => |r| if (np.role == .guest and np.phase() == .ended) {
            g.tellNetwork(if (r == .busy) .busy else .other_game);
            alone = true;
        },
        else => {},
    };
    np.clearNotes();
    if (alone) return g.playAlone();
    switch (np.role) {
        .host => host(g, p, np),
        .guest => guest(g, p, np),
    }
    waits(g, p, np);
}

/// The host's game: its status, and the join asked of it, taken now when it can be.
fn host(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    if (np.inSession() or g.scene_assets == null) return;
    np.setStatus(p, statusOf(&g.state));
    if (np.phase() != .lobby) return;
    const asked = np.session.join_asked orelse return;
    const character: ?Character = if (asked == protocol.no_character) null else @fromBackingInt(@as(u8, asked));
    switch (g.state.joining(character)) {
        .now => {
            g.state.join(character, &g.scene_assets.?);
            var buf: [canonical.maxSize(State)]u8 = undefined;
            np.begin(p, canonical.write(State, &g.state, &buf));
            // The guest's game starts from this state: the host's next tick is the session's
            // first.
            g.redraw = true;
        },
        .later => {},
        .character => np.needCharacter(p),
    }
}

/// What the host's game is, as the guest hears it.
pub fn statusOf(s: *const State) protocol.Status {
    if (!s.inGame()) return .{};
    if (s.scenes.next == null) switch (s.scenes.base) {
        .select => |*sel| if (sel.joinable()) return .{ .game = .select },
        else => {},
    };
    const c = s.setup.characters[0] orelse return .{};
    return .{ .game = .play, .character = @backingInt(c) };
}

/// The guest's game: its player, at its own select, wants to join; it asks when it can.
fn guest(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    if (np.inSession()) return;
    const wanted = wantsToJoin(&g.state);
    np.want(p, wanted);
    if (!wanted or np.phase() != .lobby) return;
    const st = np.session.peer_status;
    const chosen = choice(&g.state);
    switch (st.game) {
        .select => np.askJoin(p, if (chosen) |c| @backingInt(c) else protocol.no_character),
        .play => if (chosen) |c| if (@backingInt(c) != st.character) np.askJoin(p, @backingInt(c)),
        .none => {},
    }
}

/// Whether this machine's player wants to join another's game: its 2 PLAYERS led it to its
/// character select (network play's), where it chooses alone.
pub fn wantsToJoin(s: *const State) bool {
    if (s.start.variant.config().policies.two_players_here) return false;
    const k = if (s.scenes.next) |n| n.kind else std.meta.activeTag(s.scenes.base);
    if (k != .select) return false;
    return switch (s.scenes.base) {
        .select => |*sel| sel.players == .one,
        else => true,
    };
}

/// The character the guest's player chose at its own select, alone.
fn choice(s: *const State) ?Character {
    return switch (s.scenes.base) {
        .select => |*sel| sel.chosenAlone(),
        else => null,
    };
}

/// The character this machine's player cannot choose to join: the host's player 1's in play.
pub fn taken(g: *const Game) ?Character {
    const np = g.netplay orelse return null;
    if (np.role != .guest or np.inSession()) return null;
    const st = np.session.peer_status;
    if (st.game != .play or st.character >= protocol.characters) return null;
    return @fromBackingInt(st.character);
}

/// The guest has the host's game: it loads it, and plays it from now on.
fn joined(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    g.load(p, np.session.gameForm()) catch |err| {
        std.log.err("the host's game does not load ({s}): this game leaves the session", .{@errorName(err)});
        np.quit(p);
        g.playAlone();
    };
}

/// The session ended: the game went on to its end on both machines (each plays on alone from
/// there), or the other player left: the host's game goes on without player 2; the guest's, past
/// its select, without player 1 when the host left it, else back to its own menu.
fn ended(g: *Game, p: *platform.Platform, role: net.netplay.Role, why: net.session.End) void {
    if (why == .game_over) return;
    switch (role) {
        .host => {
            if (g.scene_assets) |*a| g.state.dropOut(1, a);
            g.tellNetwork(.player_2_left);
        },
        .guest => if (why == .left and g.state.inRounds() and g.scene_assets != null) {
            g.state.dropOut(0, &g.scene_assets.?);
            g.seat = 1;
            g.tellNetwork(.player_1_left);
        } else {
            g.state.backToMenu(g.own_setup orelse g.state.setup);
            g.own_setup = null;
            g.rebuild(p);
            g.tellNetwork(.player_1_left);
        },
    }
}

/// The waits network play holds the game for, and their messages: the guest's choice made
/// before the host has a game, its join on its way; a session whose connection is down (given up
/// after `rejoin_ns`); two games that differ.
fn waits(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    var message: ?Message = null;
    if (np.phase() == .desynced) {
        message = .desynced;
    } else if (np.lostFor()) |t| {
        message = if (np.role == .host) .player_2_away else .player_1_away;
        if (t > net.session.rejoin_ns) np.end(p, .lost);
    } else if (np.role == .guest and !np.inSession() and wantsToJoin(&g.state)) {
        if (np.phase() == .joining) {
            message = .joining;
        } else if (choice(&g.state) != null) {
            message = .waiting_for_player_1;
        }
    }
    g.showWait(message);
}

test "the host's status: its front end, a select one may join, play with player 1's character" {
    var s: State = .{};
    try std.testing.expectEqual(protocol.Status{}, statusOf(&s));
    s.scenes.base = .{ .select = .{} };
    try std.testing.expectEqual(protocol.Status.Game.select, statusOf(&s).game);
    s.scenes.base.select.phase = .wait;
    s.setup.characters[0] = .blaze;
    try std.testing.expectEqual(protocol.Status{ .game = .play, .character = 2 }, statusOf(&s));
    s.scenes.base = .{ .round = .{} };
    try std.testing.expectEqual(protocol.Status{ .game = .play, .character = 2 }, statusOf(&s));
    s.scenes.base = .{ .high_scores = .{} };
    try std.testing.expectEqual(protocol.Status{}, statusOf(&s));
}

test "the guest wants to join from its own select, in the network variant alone" {
    var s: State = .{ .start = .{ .variant = .network } };
    s.scenes.base = .{ .menu = .{} };
    try std.testing.expect(!wantsToJoin(&s));
    s.scenes.next = .{ .kind = .select, .load = 31, .sound_held = true };
    try std.testing.expect(wantsToJoin(&s));
    s.scenes.next = null;
    s.scenes.base = .{ .select = .{} };
    try std.testing.expect(wantsToJoin(&s));
    s.scenes.base.select.players = .two;
    try std.testing.expect(!wantsToJoin(&s));
    s.start.variant = .extended;
    s.scenes.base.select.players = .one;
    try std.testing.expect(!wantsToJoin(&s));
}

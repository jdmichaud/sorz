//! Network play as each machine's game runs it (DESIGN.md 9): each machine its own front end, the
//! players meeting in one game, others watching it.
//!
//! - **The host** (the native game's NETWORK PLAY, the first page of a server) plays its own game
//!   and says what it is (`statusOf`: its front end, a character select a second player may join,
//!   or play, with player 1's character); its session is open from the network options' START
//!   until its game goes back to its menu. When a client asks to join, its game takes it at the
//!   next tick it can (`State.joining`): the select's second cursor, or the round's drop-in, at
//!   once; between two rounds, later; in play without a character, the client is asked to choose
//!   first. Its game's canonical form then crosses (`Netplay.begin`), its sound as it plays beside
//!   it (`Game.joinForm`), and from that tick on both games run in lockstep. A client that asks to
//!   watch gets the game too (`beginObserve`), then each tick's pads; whenever the game changes
//!   otherwise (a player joins or leaves) the observers get it again (`resync`). A player that
//!   leaves, or does not come back within five seconds after its connection dropped (counted to
//!   the others), leaves the game (`State.dropOut`), and the host plays on.
//! - **A client** plays its own front end: its menu's JOIN goes to its own character select, where
//!   it asks to join: at once when the host's game is at its select; once it chose a character
//!   when the host plays (that character taken, unless the host allows the same character:
//!   `Turn.taken`); once the host has a game when it has none (it waits, its choice made). It loads
//!   the host's game when it comes (`Game.load`). OBSERVE loads the host's game as it comes, and
//!   runs the host's ticks; START leaves it. When the host leaves, or the session is given up,
//!   the client goes back to its own menu.
//! - **The session's end**: the host and its player end it at the same tick, the one their game
//!   ends at; each plays on to its own front end.
//!
//! What crosses the network is the session's (net/); what the player is told is this machine's
//! own (overlay.zig: the network's messages, which hold the game while it waits).
const std = @import("std");
const platform = @import("platform.zig");
const net = @import("net/root.zig");
const overlay = @import("overlay.zig");
const setup_mod = @import("setup.zig");
const game_mod = @import("game.zig");

const protocol = net.protocol;
const Game = game_mod.Game;
const State = game_mod.State;
const Character = setup_mod.Character;
const Message = overlay.Message;

/// Once per update, after the events and the driver's update: what the session said, then the
/// host's status, the join and the observers it takes, or the client's wish to join; the waits
/// and their messages.
pub fn update(g: *Game, p: *platform.Platform) void {
    const np = g.netplay orelse return;
    for (np.pending()) |n| switch (n) {
        // A session starts: what was said of the last one is over.
        .started => |st| if (!st.resumed) g.tellNetwork(null),
        .joined => if (np.role == .guest) load(g, p, np),
        .observing => if (np.role == .guest) load(g, p, np),
        .ended => |why| ended(g, p, np, why),
        .refused => |r| if (np.role == .guest) g.tellNetwork(if (r == .busy) .busy else .other_game),
        .away => |seconds| g.away_seconds = seconds,
        else => {},
    };
    np.clearNotes();
    switch (np.role) {
        .host => host(g, p, np),
        .guest => guest(g, p, np),
    }
    waits(g, p, np);
}

/// The host's game: its status, the join asked of it (taken now when it can be), the observers;
/// its session closes as its game goes back to its menu.
fn host(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    const assets = if (g.scene_assets) |*a| a else return;
    if (np.open) {
        if (g.state.inGame()) {
            g.net_game = true;
        } else if (g.net_game) {
            np.closeSession(p);
            g.net_game = false;
        }
    }
    np.setStatus(p, statusOf(&g.state));
    if (!np.inSession()) if (np.joinAsked()) |ask| {
        const character: ?Character = if (ask.character == protocol.no_character) null else @fromBackingInt(@as(u8, ask.character));
        switch (g.state.joining(character)) {
            .now => {
                g.state.join(character, assets);
                var buf: [Game.join_max]u8 = undefined;
                const form = g.joinForm(&buf);
                np.begin(p, ask.peer, form);
                np.resync(p, form);
                // The client's game starts from this state: the host's next tick is the session's
                // first.
                g.redraw = true;
            },
            .later => {},
            .character => np.needCharacter(p, ask.peer),
        }
    };
    if (np.observeAsked()) |peer| {
        var buf: [Game.join_max]u8 = undefined;
        np.beginObserve(p, peer, g.joinForm(&buf));
    }
}

/// What the host's game is, as its clients hear it.
pub fn statusOf(s: *const State) protocol.Status {
    if (!s.inGame()) return .{};
    if (s.scenes.next == null) switch (s.scenes.base) {
        .select => |*sel| if (sel.joinable()) return .{ .game = .select },
        else => {},
    };
    const c = s.setup.characters[0] orelse return .{};
    return .{ .game = .play, .character = @backingInt(c) };
}

/// The client's game: an observer leaves with START; its player, at its own select, wants to
/// join: it asks when it can.
fn guest(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    if (np.observing()) {
        if (g.startPressed()) {
            np.stopObserve(p);
            backToMenu(g, p);
        }
        return;
    }
    if (np.inSession()) return;
    if (!wantsToJoin(&g.state) or np.phase() != .lobby) return;
    const st = np.hostStatus();
    if (!st.open) return;
    const chosen = choice(&g.state);
    switch (st.game) {
        .select => np.askJoin(p, if (chosen) |c| @backingInt(c) else protocol.no_character),
        .play => if (chosen) |c| if (st.same_character or @backingInt(c) != st.character) np.askJoin(p, @backingInt(c)),
        .none => {},
    }
}

/// Whether this machine's player wants to join another's game: its JOIN led it to its character
/// select (network play's), where it chooses alone.
pub fn wantsToJoin(s: *const State) bool {
    if (s.start.variant.config().policies.two_players_here) return false;
    const k = if (s.scenes.next) |n| n.kind else std.meta.activeTag(s.scenes.base);
    if (k != .select) return false;
    return switch (s.scenes.base) {
        .select => |*sel| sel.players == .one,
        else => true,
    };
}

/// The character the client's player chose at its own select, alone.
fn choice(s: *const State) ?Character {
    return switch (s.scenes.base) {
        .select => |*sel| sel.chosenAlone(),
        else => null,
    };
}

/// The character this machine's player cannot choose to join: the host's player 1's in play,
/// unless the host allows the same character.
pub fn taken(g: *const Game) ?Character {
    const np = g.netplay orelse return null;
    if (np.role != .guest or np.inSession()) return null;
    const st = np.hostStatus();
    if (st.game != .play or st.character >= protocol.characters or st.same_character) return null;
    return @fromBackingInt(st.character);
}

/// The client has the host's game (to play it, or to watch it): it loads it, and runs it from
/// now on.
fn load(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    g.load(p, np.gameForm()) catch |err| {
        std.log.err("the host's game does not load ({s}): this client leaves it", .{@errorName(err)});
        if (np.observing()) np.stopObserve(p) else np.end(p, .left);
        backToMenu(g, p);
    };
}

/// The client back to its own menu, with its own game's set-up and variant (the host's came with
/// its game).
fn backToMenu(g: *Game, p: *platform.Platform) void {
    g.state.start = g.start();
    g.state.backToMenu(g.own_setup orelse g.state.setup);
    g.own_setup = null;
    g.rebuild(p);
}

/// The session ended: the game went on to its end on both machines (each plays on to its own
/// front end), or the other left: the host's game goes on without player 2, its observers getting
/// it again; a client goes back to its own menu.
fn ended(g: *Game, p: *platform.Platform, np: *net.Netplay, why: net.session.End) void {
    if (why == .game_over) return;
    switch (np.role) {
        .host => {
            if (g.scene_assets) |*a| g.state.dropOut(1, a);
            g.tellNetwork(.player_2_left);
            var buf: [Game.join_max]u8 = undefined;
            np.resync(p, g.joinForm(&buf));
        },
        .guest => {
            if (!g.state.inGame() and g.own_setup == null) return;
            backToMenu(g, p);
            g.tellNetwork(.player_1_left);
        },
    }
}

/// The waits network play holds the game for, and their messages: a player's dropped connection
/// counted down (given up after `rejoin_ns`); the client's own connection down; the client's
/// choice made before the host has a game, its join or its watch on their way; two games that
/// differ.
fn waits(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    var message: ?Message = null;
    var seconds: u8 = 0;
    if (np.phase() == .desynced) {
        message = .desynced;
    } else if (np.lostFor()) |t| {
        if (np.role == .host) {
            message = .player_2_away;
            seconds = @intCast((net.session.rejoin_ns -| t + std.time.ns_per_s - 1) / std.time.ns_per_s);
            if (t > net.session.rejoin_ns) np.end(p, .lost);
        } else message = .player_1_away;
    } else if (np.role == .guest and np.observing() and g.away_seconds != 0) {
        message = .player_2_away;
        seconds = g.away_seconds;
    } else if (np.role == .guest and !np.inSession() and (np.joining() or np.observeWanted())) {
        message = .joining;
    } else if (np.role == .guest and !np.inSession() and wantsToJoin(&g.state) and choice(&g.state) != null) {
        message = .waiting_for_player_1;
    }
    g.showWait(message, seconds);
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

test "the client wants to join from its own select, in the network variant alone" {
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

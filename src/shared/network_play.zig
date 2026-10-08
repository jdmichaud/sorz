//! Network play as each machine's game runs it (DESIGN.md 9): each machine its own front end, the
//! players meeting in one game, others watching it.
//!
//! - **The host** (the native game's NETWORK PLAY, the first page of a server) plays its own game
//!   and says what it is (`statusOf`: its front end, a character select a second player may join,
//!   or play, with player 1's character, and whether its game has room for a second player); its
//!   session is open from the network options' START SERVER or START GAME on, from game to game,
//!   until STOP SERVER, which sends its clients back to their menus. When a client asks to join,
//!   its game takes it at the
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
//!   runs the host's ticks; START leaves it, and so does the game's end (the observer plays on to
//!   its own front end). When the host leaves or stops its server, or the session is given up,
//!   the client goes back to its own menu, told why.
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
    var stopped = false;
    for (np.pending()) |n| switch (n) {
        // A session starts: what was said of the last one is over.
        .started => |st| if (!st.resumed) g.tellNetwork(null),
        .joined => if (np.role == .guest) load(g, p, np),
        .observing => if (np.role == .guest) load(g, p, np),
        .ended => |why| ended(g, p, np, why),
        // A stopped host's refusal: the client tries again, quietly.
        .refused => |r| if (np.role == .guest and r != .stopped) g.tellNetwork(if (r == .busy) .busy else .other_game),
        .left => |r| stopped = stopped or (np.role == .guest and r == .stopped),
        .away => |seconds| g.away_seconds = seconds,
        else => {},
    };
    np.clearNotes();
    // The host stopped its server: the client back to its menu from its select or a game it
    // watched, told why.
    if (stopped) {
        if (wantsToJoin(&g.state) or g.state.inGame()) backToMenu(g, p);
        g.tellNetwork(.host_stopped);
    }
    switch (np.role) {
        .host => host(g, p, np),
        .guest => guest(g, p, np),
    }
    waits(g, p, np);
}

/// The host's game: its status, the join asked of it (taken now when it can be), the observers.
/// The game its player left for its client ends (its rounds over, or no client left in it): with
/// the lobby over it, the host's menu under the lobby; else its player watched it, and plays on
/// to its own front end.
fn host(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    const assets = if (g.scene_assets) |*a| a else return;
    if (g.state.inGame()) g.net_start_game = false;
    if (g.net_left and !(np.inSession() and g.state.inRounds())) {
        g.net_left = false;
        if (g.overlays.find(.net_options)) |o| if (o.net_options.in_game) {
            o.net_options.in_game = false;
            backToMenu(g, p);
        };
    }
    np.setStatus(p, statusOf(&g.state));
    if (!np.inSession()) if (np.joinAsked()) |ask| {
        const character: ?Character = if (ask.character == protocol.no_character) null else @fromBackingInt(@as(u8, ask.character));
        const cursor: ?Character = if (ask.cursor == protocol.no_character) null else @fromBackingInt(@as(u8, ask.cursor));
        switch (g.state.joining(character)) {
            .now => {
                g.state.join(character, cursor, assets);
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

/// What the host's game is, as its clients hear it, and whether it has room for a second player
/// (`place`): in a round, while player 2 has no fighter; between two, while it is not in play;
/// else with one player.
pub fn statusOf(s: *const State) protocol.Status {
    if (!s.inGame()) return .{ .place = true };
    // The select takes a second player once it shows (faded in): a client at its own select sees
    // the host's player come, its screen as it was.
    if (s.scenes.next == null) switch (s.scenes.base) {
        .select => |*sel| if (sel.joinable()) return if (sel.settled()) .{ .game = .select, .place = true } else .{ .place = true },
        else => {},
    };
    const c = s.setup.characters[0] orelse return .{ .place = true };
    const place = switch (s.scenes.base) {
        .round => |*r| r.play.world.players[1].entity == null,
        .round_clear, .next_round => !s.setup.progress.players[1].in_play,
        else => s.setup.players == .one,
    };
    return .{ .game = .play, .character = @backingInt(c), .place = place };
}

/// The client's game: an observer leaves with START, back to its menu, or as the game it
/// watches ends, playing on to its own front end; its player, at its own select, wants to join:
/// it asks when it can.
fn guest(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    np.sayWhere(p, whereOf(&g.state));
    if (np.observing()) {
        if (g.startPressed()) {
            np.stopObserve(p);
            backToMenu(g, p);
        } else if (!g.state.inGame()) {
            np.stopObserve(p);
            g.state.start = g.start();
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
        .play => if (chosen) |c| if (st.place and (st.same_character or @backingInt(c) != st.character)) np.askJoin(p, @backingInt(c)),
        .none => {},
    }
}

/// Where this machine's player is in its own game, for the host's lists and its join: its
/// select to join, its cursor there; else its menu.
fn whereOf(s: *const State) protocol.Where {
    if (!wantsToJoin(s)) return .{};
    return switch (s.scenes.base) {
        .select => |*sel| .{ .at = .select, .cursor = @backingInt(sel.cursors[0].place) },
        else => .{ .at = .select },
    };
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

/// Escape in a game: this machine's player leaves it, not the program, back to its menu (a host
/// whose server runs, to its lobby: the network options over its menu); the other machines are
/// told (the host's player 2 dies and is out, its client goes back to its menu, its observers
/// too). The host's player who leaves a round its client plays: the game runs on for the client,
/// player 1 dying out of it at a tick both machines make it (`protocol.Event`), the lobby over
/// the game (again, should its player have been watching it). False outside a game: the game
/// quits.
pub fn leaveGame(g: *Game, p: *platform.Platform) bool {
    if (!g.state.inGame()) return false;
    if (g.netplay) |np| if (np.role == .host and np.open and np.inSession() and g.state.inRounds()) {
        if (!g.net_left) {
            if (!np.schedule(p, .leave, protocol.no_character)) return true;
            g.net_left = true;
        }
        g.openLobby(p, true);
        return true;
    };
    if (g.netplay) |np| {
        np.leaveGame(p);
        g.net_lobby = np.role == .host and np.open;
    }
    backToMenu(g, p);
    return true;
}

/// The client back to its own menu, with its own game's set-up and variant (the host's came with
/// its game).
pub fn backToMenu(g: *Game, p: *platform.Platform) void {
    g.state.start = g.start();
    g.state.backToMenu(g.own_setup orelse g.state.setup);
    g.own_setup = null;
    g.rebuild(p);
}

/// The client's game at the select it shared with the host's player, who left it: the select
/// its own again (its cursor as it was, player 2's), with its own set-up and variant. False when
/// it is not at that select.
fn toOwnSelect(g: *Game) bool {
    if (g.state.scenes.next != null) return false;
    const sel = switch (g.state.scenes.base) {
        .select => |*s| s,
        else => return false,
    };
    const a = if (g.scene_assets) |*x| &x.select else return false;
    if (!sel.keepSecond(a)) return false;
    var own = g.own_setup orelse g.state.setup;
    own.progress = .{};
    own.players = .one;
    own.characters = .{ if (sel.cursors[0].chosen) sel.cursors[0].place else null, null };
    own.same_character = null;
    g.state.setup = own;
    g.state.start = g.start();
    g.own_setup = null;
    g.redraw = true;
    return true;
}

/// The session ended: the game went on to its end on both machines (each plays on to its own
/// front end), or the other left: the host's game goes on without player 2, its observers getting
/// it again; a client goes back to its own menu.
fn ended(g: *Game, p: *platform.Platform, np: *net.Netplay, why: net.session.End) void {
    // Each plays on to its own front end: the client in its own variant again.
    if (why == .game_over) {
        if (np.role == .guest) g.state.start = g.start();
        return;
    }
    switch (np.role) {
        .host => {
            // Its own player left the game first (Escape): nothing to say.
            if (!g.state.inGame()) return;
            if (g.scene_assets) |*a| g.state.dropOut(1, a);
            g.tellNetwork(.player_2_left);
            var buf: [Game.join_max]u8 = undefined;
            np.resync(p, g.joinForm(&buf));
        },
        .guest => {
            if (!g.state.inGame() and g.own_setup == null) return;
            // The host's player left the select they shared: the client keeps it, its own again.
            if (!toOwnSelect(g)) backToMenu(g, p);
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
    } else if (np.role == .guest and !np.inSession() and (np.observeWanted() or (np.joining() and !wantsToJoin(&g.state)))) {
        // A join from the client's own select comes at once, its screen as it is.
        message = .joining;
    } else if (np.role == .guest and !np.inSession() and wantsToJoin(&g.state) and choice(&g.state) != null) {
        message = .waiting_for_player_1;
    }
    g.showWait(message, seconds);
}

test "the host's status: its front end, a select one may join, play with player 1's character; room" {
    var s: State = .{};
    try std.testing.expectEqual(protocol.Status{ .place = true }, statusOf(&s));
    // The select offered once it shows.
    s.scenes.base = .{ .select = .{} };
    try std.testing.expectEqual(protocol.Status.Game.none, statusOf(&s).game);
    s.scenes.base.select.phase = .first_half;
    try std.testing.expectEqual(protocol.Status.Game.select, statusOf(&s).game);
    s.scenes.base.select.phase = .wait;
    s.setup.characters[0] = .blaze;
    try std.testing.expectEqual(protocol.Status{ .game = .play, .character = 2, .place = true }, statusOf(&s));
    s.scenes.base = .{ .round = .{} };
    try std.testing.expectEqual(protocol.Status{ .game = .play, .character = 2, .place = true }, statusOf(&s));
    // Player 2 in the round: no room.
    s.scenes.base.round.play.world.players[1].entity = .{ .index = 1, .generation = 0 };
    try std.testing.expect(!statusOf(&s).place);
    s.scenes.base = .{ .high_scores = .{} };
    try std.testing.expectEqual(protocol.Status{ .place = true }, statusOf(&s));
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

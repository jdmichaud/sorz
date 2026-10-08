//! Network play as each machine's game runs it (DESIGN.md 9): each machine its own front end, the
//! players meeting in one game, others watching it. One owner, `NetPlay` (the game's `net`),
//! holds this machine's part as two state machines, the host's and the client's; the game asks it
//! what follows from them (the menu's next step, whether the game holds, whether its sound is
//! silent), and network play's driver (net/) carries the sessions.
//!
//! **The host's player** (`HostPlayer`), its server open or closed beside it (`net.Netplay.open`):
//!
//! | state      | what it is                                           | leaves for                     |
//! |------------|------------------------------------------------------|--------------------------------|
//! | `front`    | its front end (the menu, the title...)               | `lobby` (NETWORK PLAY), `game` |
//! | `lobby`    | the network options over its menu, or pending there: | `front` (EXIT), `starting`     |
//! |            | the menu opens them as it comes                      | (START GAME)                   |
//! | `starting` | START GAME chosen: the menu goes on to the select    | `game` (the select comes)      |
//! | `game`     | in a game: alone, with its local players, or with a  | `front` (the game's end),      |
//! |            | client in a session                                  | `left`, `lobby` (Escape)       |
//! | `left`     | it left a round its client plays: the game runs on   | `game` (RETURN TO GAME),       |
//! |            | under its lobby (not held, silent), player 1 out     | `watching` (EXIT), `lobby`     |
//! | `watching` | the same, the lobby closed: its player watches       | `left` (Escape), `lobby`       |
//!
//! Escape in `game`: in a round its client plays, player 1 leaves at a tick both machines share
//! (`protocol.Event`), and `left`; else the session ends (the client told, its connection kept)
//! and the host's menu comes back, its lobby while the server runs. The game `left` or `watching`
//! ends (its rounds over, or no client left in it): its observers are let go, and the menu comes
//! back under the lobby. STOP SERVER (in the lobby) lets every client go; the lobby stays.
//!
//! **A client's player** (`ClientPlayer`):
//!
//! | state         | what it is                                        | leaves for                   |
//! |---------------|---------------------------------------------------|------------------------------|
//! | `menu`        | its front end                                     | `own_select` (JOIN),         |
//! |               |                                                   | `watch_asked` (OBSERVE)      |
//! | `own_select`  | its own select (its cursor player 2's), choosing  | `asking`, `menu` (Escape)    |
//! |               | or chosen, waiting for the host's offer           |                              |
//! | `asking`      | it asked to join what the host offered            | `playing` (the game comes),  |
//! |               |                                                   | `own_select` (a new status)  |
//! | `watch_asked` | it asked to watch                                 | `observing`, `menu`          |
//! | `observing`   | it watches the host's game                        | `menu` (START, Escape, the   |
//! |               |                                                   | watch ended), `after_game`   |
//! | `playing`     | it plays the host's game, player 2                | `after_game` (its end),      |
//! |               |                                                   | `own_select` (the host left  |
//! |               |                                                   | the select), `menu`          |
//! | `after_game`  | its game ended: it plays on to its own front end  | `menu`                       |
//!
//! Its own set-up is kept while its game is the host's (`own_setup`), and comes back (with its
//! own variant) as the client leaves that game: `backToMenu`, `toOwnSelect`, `after_game`'s
//! menu. THE HOST STOPPED sends it to its menu from anywhere.
//!
//! **The offer**: what the host's game takes (`statusOf`, the status its clients hear, and
//! `takes`, the join it takes, from one reading): its select once it shows, with one player;
//! play, its player 2 free in the round, when JOIN IN PROGRESS allows; nothing between rounds,
//! in a local game of two, nor outside a game. A client asks only what the offer allows; the
//! host takes it if its game still offers it, else answers with its status, and the client
//! decides again.
const std = @import("std");
const platform = @import("platform.zig");
const net = @import("net/root.zig");
const overlay = @import("overlay.zig");
const setup_mod = @import("setup.zig");
const scene = @import("scene.zig");
const settings_mod = @import("settings/root.zig");
const game_mod = @import("game.zig");

const protocol = net.protocol;
const Game = game_mod.Game;
const State = game_mod.State;
const Setup = setup_mod.Setup;
const Character = setup_mod.Character;
const Message = overlay.Message;
const NetOptions = settings_mod.net_screens.NetOptions;

pub const HostPlayer = enum { front, lobby, starting, game, left, watching };
pub const ClientPlayer = enum { menu, own_select, asking, watch_asked, observing, playing, after_game };

/// The host's session options: its lobby's.
pub const Options = NetOptions.Choice;

pub const NetPlay = struct {
    host: HostPlayer = .front,
    client: ClientPlayer = .menu,
    options: Options = .{},
    /// The host's game is a local game of two (its 2 PLAYERS): it offers no place.
    local_two: bool = false,
    /// A client's own set-up while its game is the host's.
    own_setup: ?Setup = null,
    /// A client's count of a player's dropped connection (the seconds left, as the host said).
    away_seconds: u8 = 0,
    /// START held at the last update (an observer leaves with a new press).
    start_held: bool = false,

    /// Whether the lobby is over a game the host's player left: the game runs on under it (it
    /// does not hold), silent, its pad playing nothing.
    pub fn lobbyOverGame(self: *const NetPlay) bool {
        return self.host == .left;
    }
};

// --- once per update -------------------------------------------------------------------------

/// Once per update, after the events and the driver's update: what the sessions said, then the
/// host's or the client's step, the waits and their messages.
pub fn update(g: *Game, p: *platform.Platform) void {
    const np = g.netplay orelse return;
    const start_now = g.controls.pads().pad1.start;
    const start_new = start_now and !g.net.start_held;
    g.net.start_held = start_now;
    var stopped = false;
    for (np.pending()) |n| switch (np.role) {
        .host => hostNote(g, p, np, n),
        .guest => stopped = clientNote(g, p, np, n) or stopped,
    };
    np.clearNotes();
    switch (np.role) {
        .host => host(g, p, np),
        .guest => {
            // THE HOST STOPPED: back to the menu from wherever the client was.
            if (stopped) {
                if (g.net.client != .menu) backToMenu(g, p);
                g.notify(.host_stopped);
            }
            client(g, p, np, start_new);
        },
    }
    waits(g, p, np);
}

fn hostNote(g: *Game, p: *platform.Platform, np: *net.Netplay, n: net.netplay.Note) void {
    switch (n) {
        .started => |st| if (!st.resumed) g.notify(null),
        // The client left the game (quit, Escape, or not back in time) while the host's player
        // was in it, or out of it for its client: player 2 dies and is out, the observers get
        // the game again. (The host's own leaving ends the session too: nothing to say.)
        .ended => |why| if (why != .game_over and (g.net.host == .game or g.net.host == .left or g.net.host == .watching) and g.state.inGame()) {
            if (g.scene_assets) |*a| g.state.dropOut(1, a);
            g.notify(.player_2_left);
            var buf: [Game.join_max]u8 = undefined;
            np.resync(p, g.joinForm(&buf));
        },
        else => {},
    }
}

/// A note for the client; true for the host's farewell as it stops its server.
fn clientNote(g: *Game, p: *platform.Platform, np: *net.Netplay, n: net.netplay.Note) bool {
    switch (n) {
        .started => |st| if (!st.resumed) g.notify(null),
        // The host's game, to play: taken only when this client asked for it (a late answer to
        // an ask withdrawn is left at once).
        .joined => if (g.net.client == .own_select or g.net.client == .asking) {
            loadGame(g, p, np, .playing);
        } else np.leaveGame(p),
        .observing => if (g.net.client == .watch_asked or g.net.client == .observing) {
            loadGame(g, p, np, .observing);
        } else np.stopObserve(p),
        .ended => |why| if (g.net.client == .playing) switch (why) {
            // Each plays on to its own front end: the client's variant again, its set-up once
            // its menu comes.
            .game_over => {
                g.state.start = g.start();
                g.net.client = .after_game;
            },
            // The host's player left the select they shared: the client keeps it, its own again;
            // else (the host left, or was not back in time) its menu.
            .left, .lost => {
                if (why == .lost or !toOwnSelect(g)) backToMenu(g, p);
                g.notify(.player_1_left);
            },
        },
        .watch_ended => if (g.net.client == .observing) {
            backToMenu(g, p);
            g.notify(.player_1_left);
        },
        // A new status answers an ask: the client decides again.
        .status => if (g.net.client == .asking) {
            g.net.client = .own_select;
        },
        .refused => |r| if (r != .stopped) g.notify(if (r == .busy) .busy else .other_game),
        .left => |r| return r == .stopped,
        .away => |seconds| g.net.away_seconds = seconds,
        else => {},
    }
    return false;
}

// --- the host ----------------------------------------------------------------------------------

/// The host's step: its player's state as the scenes move it, its status, the join and the
/// watches asked of it.
fn host(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    const assets = if (g.scene_assets) |*a| a else return;
    switch (g.net.host) {
        .front, .starting => if (g.state.inGame()) {
            // START GAME's game, or a local one from the menu (with two players: no place).
            g.net.local_two = g.net.host == .front and g.state.setup.players == .two;
            g.net.host = .game;
        },
        .game => if (!g.state.inGame()) {
            g.net.host = .front;
            g.net.local_two = false;
        },
        // The game the host's player left is over (its rounds, or no client left in it): the
        // observers let go, the menu under the lobby.
        .left, .watching => if (!(np.inSession() and g.state.inRounds())) {
            np.endWatches(p);
            backToMenu(g, p);
            g.net.host = .lobby;
            if (lobbyOf(g)) |x| x.in_game = false;
        },
        .lobby => {},
    }
    np.setStatus(p, statusOf(&g.state, g.net.local_two));
    if (np.joinAsked()) |ask_| {
        const character: ?Character = if (ask_.character == protocol.no_character) null else @fromBackingInt(@as(u8, ask_.character));
        const cursor: ?Character = if (ask_.cursor == protocol.no_character) null else @fromBackingInt(@as(u8, ask_.cursor));
        if (g.net.host == .game and !np.inSession() and takes(&g.state, g.net.local_two, np.join_in_progress, character)) {
            g.state.join(character, cursor, assets);
            var buf: [Game.join_max]u8 = undefined;
            const form = g.joinForm(&buf);
            np.begin(p, ask_.peer, form);
            np.resync(p, form);
            // The client's game starts from this state: the host's next tick is the session's
            // first.
            g.redraw = true;
        } else np.declineJoin(p, ask_.peer);
    }
    if (np.observeAsked()) |peer| {
        const watchable = g.net.options.observers and g.state.inGame() and (g.net.host == .game or g.net.host == .left or g.net.host == .watching);
        if (watchable) {
            var buf: [Game.join_max]u8 = undefined;
            np.beginObserve(p, peer, g.joinForm(&buf));
        } else np.declineObserve(p, peer);
    }
}

/// What the host's game offers, as its clients hear it: its front end (`none`, a place free for
/// a client to wait at its own select), its select (a place free once it shows, one player at
/// it), or play with player 1's character, a place free while player 2 has no fighter in the
/// round. Between rounds, in a local game of two, or a select not shown yet: no place now; a
/// game to watch all the same. (Netplay adds the session's flags: open, a player already in,
/// JOIN IN PROGRESS.)
pub fn statusOf(s: *const State, local_two: bool) protocol.Status {
    if (!s.inGame()) return .{ .place = true };
    if (s.scenes.next == null) switch (s.scenes.base) {
        .select => |*sel| if (sel.phase != .wait and sel.phase != .fade_out and sel.phase != .leaving) {
            return .{ .game = .select, .place = sel.joinable() and sel.settled() and !local_two };
        },
        else => {},
    };
    const c = s.setup.characters[0] orelse return .{};
    const place = !local_two and switch (s.scenes.base) {
        .round => |*r| s.scenes.next == null and r.play.world.players[1].entity == null,
        else => false,
    };
    return .{ .game = .play, .character = @backingInt(c), .place = place };
}

/// Whether the host's game takes a join now, as `character` (null: none chosen): its offer, the
/// same reading as `statusOf`'s.
fn takes(s: *const State, local_two: bool, join_in_progress: bool, character: ?Character) bool {
    const st = statusOf(s, local_two);
    return switch (st.game) {
        .none => false,
        .select => st.place,
        .play => st.place and join_in_progress and character != null,
    };
}

/// The host's lobby: over its menu (fading in), or over the game its player left for its client
/// (`over_game`: at once, the game running on under it).
pub fn openLobby(g: *Game, p: *platform.Platform, over_game: bool) void {
    const np = g.netplay orelse return;
    const o = g.net.options;
    const options: NetOptions = .{
        .observers = o.observers,
        .same_character = o.same_character,
        .join_in_progress = o.join_in_progress,
        .port = np.port(),
        .port_fixed = np.portFixed(),
        .serving = np.open,
        .in_game = over_game,
        .players = g.controls.players(),
    };
    g.openModal(.{ .net_options = options.open() }, if (over_game) null else p.nowNs());
    lists(g, p);
}

fn lobbyOf(g: *Game) ?*NetOptions {
    const o = g.overlays.find(.net_options) orelse return null;
    return &o.net_options;
}

/// The host's server opens (START SERVER, START GAME): it listens (at the lobby's port, the first
/// time), with the lobby's options.
fn openServer(g: *Game, p: *platform.Platform, x: *const NetOptions) void {
    const np = g.netplay orelse return;
    g.net.options = x.choice();
    if (x.port) |port| np.setPort(port) catch {};
    np.openSession(p, g.net.options.observers, g.net.options.same_character, g.net.options.join_in_progress) catch |err| {
        std.log.err("network play cannot listen at {s}: {s}", .{ np.address, @errorName(err) });
        g.notify(.cannot_host);
    };
}

/// What the lobby's line did (`result`): the server started or stopped (the lobby stays); START
/// GAME, RETURN TO GAME, EXIT. Returns whether the lobby closes.
pub fn lobbyAction(g: *Game, p: *platform.Platform, x: *NetOptions, result: settings_mod.net_screens.Result) bool {
    const np = g.netplay orelse return true;
    switch (result) {
        .stay => return false,
        .acted => {
            switch (x.action) {
                .start_server => openServer(g, p, x),
                else => {
                    np.stopSession(p);
                    // The game its player left goes with its client: the menu under the lobby.
                    if (g.net.host == .left or g.net.host == .watching) {
                        backToMenu(g, p);
                        g.net.host = .lobby;
                        x.in_game = false;
                    }
                },
            }
            x.served(np.open, np.portFixed());
            lists(g, p);
            return false;
        },
        .done => switch (x.action) {
            // Player 1 drops back in at a tick both machines share.
            .return_to_game => {
                const c = g.state.setup.characters[0] orelse return false;
                if (!np.schedule(p, .back, @backingInt(c))) return false;
                g.net.host = .game;
                return true;
            },
            else => {
                openServer(g, p, x);
                g.net.host = .starting;
                return true;
            },
        },
        // EXIT: over the game its player left, the game shown (watching); else the menu.
        .cancel => {
            g.net.host = if (g.net.host == .left) .watching else .front;
            return true;
        },
    }
}

/// The host's lists of who is connected: the lobby's (its values applied to the session while
/// the server runs; whether player 1 can come back), and the one at the bottom left of its front
/// end, outside the lobby.
pub fn lists(g: *Game, p: *platform.Platform) void {
    const np = g.netplay orelse return;
    if (np.role != .host) return;
    if (lobbyOf(g)) |x| {
        if (!std.meta.eql(x.choice(), g.net.options)) {
            g.net.options = x.choice();
            if (np.open) np.setOptions(p, x.observers, x.same_character, x.join_in_progress);
        }
        const can_return = g.net.host == .left and x.join_in_progress and !np.eventDue() and np.inSession() and switch (g.state.scenes.base) {
            .round => |*r| g.state.scenes.next == null and r.play.world.players[0].entity == null,
            else => false,
        };
        if (can_return != x.can_return) {
            x.can_return = can_return;
            g.overlay_dirty = true;
        }
        var entries: [NetOptions.max_clients]net.netplay.Entry = undefined;
        const now = if (np.open) np.roster(&entries) else entries[0..0];
        var same = x.client_count == now.len;
        if (same) for (x.clients[0..now.len], now) |a, b| {
            same = same and std.meta.eql(a, b);
        };
        if (!same) {
            @memcpy(x.clients[0..now.len], now);
            x.client_count = @intCast(now.len);
            g.overlay_dirty = true;
        }
    }
    const show = np.open and !g.state.inRounds() and !g.modalOpen();
    if (!show) {
        if (g.overlays.find(.roster) != null) {
            g.overlays.remove(.roster);
            g.overlay_dirty = true;
        }
        return;
    }
    var r: overlay.Roster = .{};
    r.len = @intCast(np.roster(&r.entries).len);
    if (g.overlays.find(.roster)) |o| if (o.roster.eql(r)) return;
    g.overlays.push(.{ .roster = r });
    g.overlay_dirty = true;
}

// --- the client --------------------------------------------------------------------------------

/// The client's step: its own select's asks; a watch left with START or ended with its game; its
/// menu after a game; where its player is, said to the host.
fn client(g: *Game, p: *platform.Platform, np: *net.Netplay, start_new: bool) void {
    switch (g.net.client) {
        .menu => if (atOwnSelect(&g.state)) {
            g.net.client = .own_select;
        },
        .own_select => ask(g, p, np),
        .asking => {},
        .watch_asked => if (!np.observeWanted() and !np.observing()) {
            g.net.client = .menu;
        },
        .observing => if (start_new) {
            np.stopObserve(p);
            backToMenu(g, p);
        } else if (!g.state.inGame()) {
            np.stopObserve(p);
            g.state.start = g.start();
            g.net.client = .after_game;
        },
        .playing => {},
        .after_game => if (std.meta.activeTag(g.state.scenes.base) == .menu) {
            if (g.net.own_setup) |own| {
                g.state.setup = own;
                g.state.setup.progress = .{};
                g.net.own_setup = null;
            }
            g.net.client = .menu;
        },
    }
    np.sayWhere(p, whereOf(g));
}

/// The client at its own select asks what the host offers: at its select, at once (its
/// character, if chosen); in play, once chosen (not player 1's character unless both may choose
/// one).
fn ask(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    if (np.phase() != .lobby) return;
    const st = np.hostStatus();
    if (!st.open or !st.place) return;
    const chosen = choice(&g.state);
    switch (st.game) {
        .select => np.askJoin(p, if (chosen) |c| @backingInt(c) else protocol.no_character),
        .play => {
            const c = chosen orelse return;
            if (!st.join_in_progress or (!st.same_character and @backingInt(c) == st.character)) return;
            np.askJoin(p, @backingInt(c));
        },
        .none => return,
    }
    g.net.client = .asking;
}

/// Where the client's player is in its own game, for the host's lists and its join: its select
/// (its cursor there), or its menu.
fn whereOf(g: *const Game) protocol.Where {
    if (g.net.client != .own_select and g.net.client != .asking) return .{};
    return switch (g.state.scenes.base) {
        .select => |*sel| .{ .at = .select, .cursor = @backingInt(sel.cursors[0].place) },
        else => .{ .at = .select },
    };
}

/// Whether the client's game is at its own select (its JOIN led it there: a network client's
/// select has one player).
fn atOwnSelect(s: *const State) bool {
    const k = if (s.scenes.next) |n| n.kind else std.meta.activeTag(s.scenes.base);
    if (k != .select) return false;
    return switch (s.scenes.base) {
        .select => |*sel| sel.players == .one,
        else => true,
    };
}

/// The character the client's player chose at its own select.
fn choice(s: *const State) ?Character {
    return switch (s.scenes.base) {
        .select => |*sel| sel.chosenAlone(),
        else => null,
    };
}

/// The character the client's player cannot choose to join: the host's player 1's in play,
/// unless the host allows the same character.
pub fn taken(g: *const Game) ?Character {
    const np = g.netplay orelse return null;
    if (np.role != .guest or np.inSession()) return null;
    const st = np.hostStatus();
    if (st.game != .play or st.character >= protocol.characters or st.same_character) return null;
    return @fromBackingInt(st.character);
}

/// The client has the host's game, to play it or to watch it: it loads it (its own set-up kept),
/// and runs it from now on; a game that does not load is left.
fn loadGame(g: *Game, p: *platform.Platform, np: *net.Netplay, as: ClientPlayer) void {
    if (g.net.own_setup == null) g.net.own_setup = g.state.setup;
    g.load(p, np.gameForm()) catch |err| {
        std.log.err("the host's game does not load ({s}): this client leaves it", .{@errorName(err)});
        np.leaveGame(p);
        backToMenu(g, p);
        return;
    };
    g.net.client = as;
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
    var own = g.net.own_setup orelse g.state.setup;
    own.progress = .{};
    own.players = .one;
    own.characters = .{ if (sel.cursors[0].chosen) sel.cursors[0].place else null, null };
    own.same_character = null;
    g.state.setup = own;
    g.state.start = g.start();
    g.net.own_setup = null;
    g.net.client = .own_select;
    g.redraw = true;
    return true;
}

// --- both --------------------------------------------------------------------------------------

/// This machine back at its menu, with its own set-up and variant (a client's came with the
/// host's game): the client's player at its menu; the host's at its lobby while its server
/// runs, else at its front end.
pub fn backToMenu(g: *Game, p: *platform.Platform) void {
    const own = g.net.own_setup orelse g.state.setup;
    g.state.start = g.start();
    g.state.backToMenu(own);
    g.net.own_setup = null;
    g.rebuild(p);
    if (g.netplay) |np| switch (np.role) {
        .host => g.net.host = if (np.open) .lobby else .front,
        .guest => g.net.client = .menu,
    };
}

/// Escape on this machine: its player leaves the game it is in, not the program (true), or, at
/// its front end, the program quits (false). The host's player who leaves a round its client
/// plays: player 1 leaves at a tick both machines share, the game running on under its lobby.
pub fn escape(g: *Game, p: *platform.Platform) bool {
    const np = g.netplay orelse {
        if (!g.state.inGame()) return false;
        g.state.backToMenu(g.state.setup);
        g.rebuild(p);
        return true;
    };
    switch (np.role) {
        .host => switch (g.net.host) {
            .game => {
                if (np.phase() == .playing and g.state.inRounds()) {
                    if (np.schedule(p, .leave, protocol.no_character)) {
                        g.net.host = .left;
                        openLobby(g, p, true);
                    }
                    return true;
                }
                // Alone, at the select, or stopped at a mismatch: the session ends (the client
                // told), the observers let go, the menu (the lobby while the server runs).
                np.leaveGame(p);
                np.endWatches(p);
                backToMenu(g, p);
                return true;
            },
            .watching => {
                g.net.host = .left;
                openLobby(g, p, true);
                return true;
            },
            .front, .lobby, .starting, .left => return g.state.inGame(),
        },
        .guest => switch (g.net.client) {
            .menu, .after_game => return false,
            .watch_asked => {
                np.leaveGame(p);
                g.net.client = .menu;
                return true;
            },
            // Its ask withdrawn, its watch or its game left: its menu.
            .own_select, .asking, .observing, .playing => {
                np.leaveGame(p);
                backToMenu(g, p);
                return true;
            },
        },
    }
}

/// What the game menu asked of network play at this tick.
pub fn request(g: *Game, p: *platform.Platform, r: scene.NetRequest) void {
    const np = g.netplay orelse return;
    switch (r) {
        .network_options => {
            g.net.host = .lobby;
            if (lobbyOf(g) == null) openLobby(g, p, false);
        },
        .observe => {
            np.askObserve(p);
            g.net.client = .watch_asked;
        },
        .name => {},
    }
}

/// This machine's part in network play, for its menus.
pub fn facts(g: *const Game) scene.Net {
    const np = g.netplay orelse return .{};
    var n: scene.Net = .{
        .role = if (np.role == .host) .host else .client,
        .hosting = np.open,
        .intent = switch (g.net.host) {
            .lobby => .open_lobby,
            .starting => .start_game,
            else => .none,
        },
        .same_character = g.net.options.same_character,
        .observe_wait = g.net.client == .watch_asked,
        .named = g.settings.named(),
        .name = g.settings.name,
    };
    if (np.role == .guest) {
        n.intent = .none;
        if (np.welcomed()) {
            const st = np.hostStatus();
            n.can_join = st.open and st.place;
            n.can_observe = st.open and st.observers and st.game != .none;
        }
    }
    return n;
}

/// A change of the game in the session before this tick (`protocol.Event`), on both machines:
/// the host's player leaving it (its fighter dies, out) or coming back (it drops in: in a round
/// alone; between two, the host is back in its lobby, out still). The host's observers take the
/// game again.
pub fn applyEvent(g: *Game, p: *platform.Platform, np: *net.Netplay, e: protocol.Event) void {
    const a = if (g.scene_assets) |*x| x else return;
    switch (e.what) {
        .leave => {
            g.state.dropOut(0, a);
            if (np.role == .guest) g.notify(.player_1_left);
        },
        .back => {
            const in_round = g.state.scenes.next == null and std.meta.activeTag(g.state.scenes.base) == .round;
            if (in_round and e.character < protocol.characters) {
                g.state.dropIn(0, @fromBackingInt(e.character));
            } else if (np.role == .host) {
                g.net.host = .left;
                openLobby(g, p, true);
            }
        },
    }
    if (np.role == .host) {
        var buf: [Game.join_max]u8 = undefined;
        np.resync(p, g.joinForm(&buf));
    }
}

/// The waits network play holds the game for, and their messages: a player's dropped connection
/// counted down (the host gives it up after `rejoin_ns`, the client a second later); a player's
/// connection down for an observer; the client's watch asked, or its choice made at its own
/// select before the host's game takes it; two games that differ.
fn waits(g: *Game, p: *platform.Platform, np: *net.Netplay) void {
    var message: ?Message = null;
    var seconds: u8 = 0;
    if (np.phase() == .desynced) {
        message = .desynced;
    } else if (np.lostFor()) |t| switch (np.role) {
        .host => {
            message = .player_2_away;
            seconds = @intCast((net.session.rejoin_ns -| t + std.time.ns_per_s - 1) / std.time.ns_per_s);
            if (t > net.session.rejoin_ns) np.end(p, .lost);
        },
        .guest => {
            message = .player_1_away;
            if (t > net.session.rejoin_ns + std.time.ns_per_s) np.end(p, .lost);
        },
    } else if (np.role == .guest) switch (g.net.client) {
        .observing => if (g.net.away_seconds != 0) {
            message = .player_2_away;
            seconds = g.net.away_seconds;
        },
        .watch_asked => message = .joining,
        .own_select, .asking => if (choice(&g.state) != null) {
            message = .waiting_for_player_1;
        },
        else => {},
    };
    g.showWait(message, seconds);
}

/// The options' CONTROL this machine's player plays with: its own, in the host's game too (its
/// own set-up kept).
pub fn ownControl(g: *const Game) u8 {
    if (g.net.own_setup) |o| return o.control;
    return g.state.setup.control;
}

test "the host's status: its front end, a select once it shows, play with player 1's character; room" {
    var s: State = .{};
    try std.testing.expectEqual(protocol.Status{ .place = true }, statusOf(&s, false));
    // The select: no place before it shows, none with two players at it; a game to watch.
    s.scenes.base = .{ .select = .{} };
    try std.testing.expectEqual(protocol.Status{ .game = .select }, statusOf(&s, false));
    s.scenes.base.select.players = .two;
    s.scenes.base.select.phase = .first_half;
    try std.testing.expectEqual(protocol.Status{ .game = .select }, statusOf(&s, false));
    s.scenes.base.select.players = .one;
    try std.testing.expectEqual(protocol.Status{ .game = .select, .place = true }, statusOf(&s, false));
    // A local game of two offers no place.
    try std.testing.expect(!statusOf(&s, true).place);
    s.scenes.base.select.phase = .wait;
    s.setup.characters[0] = .blaze;
    try std.testing.expectEqual(protocol.Status{ .game = .play, .character = 2 }, statusOf(&s, false));
    s.scenes.base = .{ .round = .{} };
    try std.testing.expectEqual(protocol.Status{ .game = .play, .character = 2, .place = true }, statusOf(&s, false));
    // Player 2 in the round: no room; between rounds: none now.
    s.scenes.base.round.play.world.players[1].entity = .{ .index = 1, .generation = 0 };
    try std.testing.expect(!statusOf(&s, false).place);
    s.scenes.base = .{ .round_clear = .{} };
    try std.testing.expect(!statusOf(&s, false).place);
    s.scenes.base = .{ .high_scores = .{} };
    try std.testing.expectEqual(protocol.Status{ .place = true }, statusOf(&s, false));
}

test "the join the host takes is its offer: its select at once, play with a character when allowed" {
    var s: State = .{};
    try std.testing.expect(!takes(&s, false, true, .adam));
    s.scenes.base = .{ .select = .{ .phase = .first_half } };
    try std.testing.expect(takes(&s, false, true, null));
    s.setup.characters[0] = .axel;
    s.scenes.base = .{ .round = .{} };
    try std.testing.expect(takes(&s, false, true, .adam));
    try std.testing.expect(!takes(&s, false, true, null));
    try std.testing.expect(!takes(&s, false, false, .adam));
}

test "a client's own select is the select alone" {
    var s: State = .{ .start = .{ .variant = .network } };
    s.scenes.base = .{ .menu = .{} };
    try std.testing.expect(!atOwnSelect(&s));
    s.scenes.next = .{ .kind = .select, .load = 31, .sound_held = true };
    try std.testing.expect(atOwnSelect(&s));
    s.scenes.next = null;
    s.scenes.base = .{ .select = .{} };
    try std.testing.expect(atOwnSelect(&s));
    s.scenes.base.select.players = .two;
    try std.testing.expect(!atOwnSelect(&s));
}

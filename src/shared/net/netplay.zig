//! Network play as the game drives it (DESIGN.md 9): the sessions of the protocol (session.zig)
//! over the platform's transport.
//!
//! - **The host** keeps a session for each client that connects (`Peer`), up to `max_clients`:
//!   in its menu, one of its players (up to three, each in its place of the game, player 2 to 4:
//!   `members`, in lockstep with the host's game), or an observer. It listens once its session
//!   opens (`open`, NETWORK PLAY's START; a page behind a relay has its connections brought by the
//!   page). The game gives the host's status (`setStatus`: the driver adds whether the session is
//!   open, a place free, observers taken and the same character allowed), takes a join
//!   (`joinAsked`, then `begin`, `scheduleJoin` in a session under way, or `declineJoin`) or a
//!   wish to watch (`observeAsked`, then `beginObserve`), gives each tick's pads to the observers
//!   (`observed`) and its game again when it changed otherwise (`resync`), and ends its players'
//!   sessions (`end`). A player whose connection comes back (its hello names the session) takes
//!   up its session again.
//! - **The host's session of play**: its clients' sessions run the same ticks. The host merges
//!   their pads with its own (`pads`), relays each client's pads to the others (`relay`), and
//!   changes the game at a tick no machine has run yet, the same change on each (`schedule`: a
//!   player leaving or coming back, the rules; a client that joins a session under way joins at
//!   such a tick, `scheduleJoin`, and its session begins there, `beginJoin`). The session's input
//!   delay suits its slowest links: a client's pads reach another through the host. A client
//!   that leaves (its goodbye, or its connection not back in time) goes at the tick its pads ran
//!   out, the others told ahead; the last goes as the session ends.
//! - **A client** connects as it starts, and again every second while it is apart: it is in the
//!   host's lobby from then on. Its game asks to join (`askJoin`) or to watch (`askObserve`,
//!   `stopObserve`), and hears the host's status (`hostStatus`).
//! - **The session in play** gives each display tick's pads (`pads`), the changes before it
//!   (`takeEvent`), the tick's end (`ran`) and the state checks (`checkDue`, `check`); what
//!   happened comes to the game as notes (`pending`, which the game clears), the notes of the
//!   sessions of play alone.
//! - **The stats** (DESIGN.md 9): in a session of play, each second, the ticks this machine's game
//!   ran, the percent of the time it worked (the game's `worked`) and the percent it held for the
//!   others' pads, with the round trip it measured last, told to the other machines (the host
//!   tells each client the others'); `stats` gives every machine's, and the input delay.
//!
//! What happens is logged (`std.log`, scope `netplay`): the connections, the welcomes and their
//! delays, the sessions, the holds, a refusal, a mismatch and its first differing field.
const std = @import("std");
const platform = @import("../platform.zig");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const canonical = @import("../canonical.zig");
const input = @import("../input.zig");

const log = std.log.scoped(.netplay);
const Session = session_mod.Session;

pub const Role = session_mod.Role;
pub const Note = session_mod.Note;

pub const Options = struct {
    role: Role,
    /// The host's `[ADDRESS:]PORT`, or the client's `ws://ADDRESS:PORT`. Empty when the platform
    /// brings the connections itself (a browser page behind the relay server, or a page of the
    /// native host): the driver then neither listens nor connects.
    address: []const u8,
    build: protocol.Build,
    data: protocol.DataId,
    /// The host's input delay (2 to 6) instead of the round trip's.
    delay: ?u8 = null,
    /// Whether to log what happens.
    log: bool = true,
    /// The client's player's name.
    name: protocol.Name = .{ ' ', ' ', ' ' },
};

/// The client's pause between two attempts to connect.
pub const reconnect_ns: u64 = std.time.ns_per_s;
/// A hold this long is logged (once per hold).
const hold_log_ns: u64 = std.time.ns_per_s / 2;
/// Messages waiting for room in the transport's queue before the connection is given up.
const max_backlog = 1024;
/// The clients a host keeps at once (a client past them is turned away, `busy`).
pub const max_clients = 16;
/// The players of a game (the host's and its clients').
pub const max_players = input.max_players;

/// A client of the host (on a client: its host), its connection and its session.
pub const Peer = struct {
    connection: ?platform.ConnectionId = null,
    session: Session,
    /// The host: this client's leave is a change of the game the others make at its tick.
    leave_made: bool = false,
};

/// What a client of the host does, as the host lists it.
pub const Doing = enum { menu, select, player, observing };

/// A client of the host as its screens list it.
pub const Entry = struct {
    name: protocol.Name,
    doing: Doing,
    /// Its player in the game (from 0: player 2 is 1), when it plays.
    place: u8 = 1,

    /// Its line on the host's screens: NAME - MENU (PLAYER 2, OBSERVING). The font has no
    /// parentheses.
    pub fn line(e: *const Entry, buf: *[24]u8) []const u8 {
        var player_buf: [8]u8 = undefined;
        const doing: []const u8 = switch (e.doing) {
            .menu => "MENU",
            .select => "SELECT",
            .player => std.fmt.bufPrint(&player_buf, "PLAYER {d}", .{@as(u8, e.place) + 1}) catch unreachable,
            .observing => "OBSERVING",
        };
        return std.fmt.bufPrint(buf, "{s} - {s}", .{ &e.name, doing }) catch unreachable;
    }
};

/// The host's own line on its screens.
pub const local_line = "LOCAL - PLAYER 1";

/// The stats' measure of a second of this machine's game in a session of play: the ticks it ran,
/// its work, and its holds for the other's pads (the hold under way counted from `hold_from`).
const Meter = struct {
    since_ns: ?u64 = null,
    ticks: u32 = 0,
    busy_ns: u64 = 0,
    wait_ns: u64 = 0,
    hold_from: ?u64 = null,
    last: ?protocol.Load = null,
};

/// Network play's stats of the session of play (DESIGN.md 9): this machine's last second and the
/// others' as they (or the host) said them (none before their first), each with the round trip it
/// measured; the input delay; whether this machine is the host; and the client's name.
pub const Stats = struct {
    local: protocol.Load,
    /// The other machine's: the host's on a client, a client's on the host (its first).
    peer: ?protocol.Load,
    delay: u8,
    host: bool,
    client: protocol.Name,
    /// Each player's machine in the session (by player: the host's first), its last second.
    machines: [max_players]Machine = @splat(.{}),

    pub const Machine = struct {
        /// In the session, its load (null before its first second), and the name of a client
        /// as its session has it (the game's names may say it better).
        in: bool = false,
        load: ?protocol.Load = null,
        name: protocol.Name = .{ ' ', ' ', ' ' },
    };
};

/// `part` of `whole`, in percent (at most 100).
fn percent(part: u64, whole: u64) u8 {
    return @intCast(@min(100, (part * 100 + whole / 2) / whole));
}

/// The changes of the game the host's own game makes (`schedule`), in their ticks' order.
const Changes = struct {
    items: [session_mod.max_events]protocol.Event = undefined,
    len: u8 = 0,

    fn room(c: *const Changes) bool {
        return c.len < c.items.len;
    }

    fn add(c: *Changes, e: protocol.Event) void {
        var i: usize = c.len;
        while (i > 0 and c.items[i - 1].tick > e.tick) : (i -= 1) c.items[i] = c.items[i - 1];
        c.items[i] = e;
        c.len += 1;
    }

    fn drop(c: *Changes, i: usize) void {
        std.mem.copyForwards(protocol.Event, c.items[i .. c.len - 1], c.items[i + 1 .. c.len]);
        c.len -= 1;
    }

    fn slice(c: *const Changes) []const protocol.Event {
        return c.items[0..c.len];
    }
};

pub const Netplay = struct {
    allocator: std.mem.Allocator,
    role: Role,
    address: []u8,
    log_enabled: bool,
    config: session_mod.Config,
    diff: canonical.DiffFn,
    /// The host's clients; a client's host, always there (index 0).
    peers: std.ArrayList(*Peer) = .empty,
    /// The host: the clients that play its game in a session, by their player (1 to 3), and those
    /// whose join is a change to come (`scheduleJoin`).
    members: [max_players]?*Peer = @splat(null),
    joiners: [max_players]?*Peer = @splat(null),
    /// The host: the player whose place its client took from the CPU (the CPU takes it back as the
    /// client leaves; the game says it).
    cpu_place: ?input.Player = null,
    /// The host: its session's input delay, and the changes of the game its own game makes at
    /// their ticks (the same as each client's).
    group_delay: u8 = 0,
    changes: Changes = .{},
    /// The host's session is open (its server started, or its game: the network options), and
    /// what it takes; stopped (STOP SERVER), it turns clients away until it opens again.
    open: bool = false,
    stopped: bool = false,
    observers: bool = false,
    same_character: bool = false,
    join_in_progress: bool = true,
    listening: bool = false,
    /// The host's game, as the game last said it (without the driver's flags).
    status: protocol.Status = .{},
    started: bool = false,
    /// The client's next attempt to connect, and the connection it is opening.
    reconnect_at: ?u64 = null,
    connecting: ?platform.ConnectionId = null,
    /// The time the current hold began, and whether it was logged.
    held_since: ?u64 = null,
    hold_logged: bool = false,
    /// The stats' second under way, and the last one's.
    meter: Meter = .{},
    /// A refused connection was logged (the client retries quietly until one opens).
    refused_logged: bool = false,
    now_ns: u64 = 0,
    /// The first differing field of a mismatch, once the peers compared their states.
    difference: ?canonical.Difference = null,
    /// What happened since the game last looked, in order.
    notes: std.ArrayList(Note) = .empty,
    /// Sessions started so far (a count for the checks; on the host, from its first client's
    /// join).
    sessions: u32 = 0,
    /// The seconds of a player's drop last said to the others, and that player.
    away_said: u8 = 0,
    away_player: input.Player = 1,

    pub fn init(allocator: std.mem.Allocator, options: Options, diff: canonical.DiffFn) error{OutOfMemory}!Netplay {
        const address = try allocator.dupe(u8, options.address);
        errdefer allocator.free(address);
        var self: Netplay = .{
            .allocator = allocator,
            .role = options.role,
            .address = address,
            .log_enabled = options.log,
            .config = .{ .role = options.role, .build = options.build, .data = options.data, .delay = options.delay, .name = options.name },
            .diff = diff,
        };
        if (options.role == .guest) _ = try self.newPeer(null);
        return self;
    }

    pub fn deinit(self: *Netplay) void {
        for (self.peers.items) |peer| self.destroyPeer(peer);
        self.peers.deinit(self.allocator);
        self.notes.deinit(self.allocator);
        self.allocator.free(self.address);
        self.* = undefined;
    }

    fn newPeer(self: *Netplay, connection: ?platform.ConnectionId) error{OutOfMemory}!*Peer {
        const peer = try self.allocator.create(Peer);
        errdefer self.allocator.destroy(peer);
        peer.* = .{ .connection = connection, .session = try Session.init(self.allocator, self.config, self.diff) };
        errdefer peer.session.deinit();
        try self.peers.append(self.allocator, peer);
        return peer;
    }

    fn destroyPeer(self: *Netplay, peer: *Peer) void {
        peer.session.deinit();
        self.allocator.destroy(peer);
    }

    fn removePeer(self: *Netplay, peer: *Peer) void {
        if (std.mem.indexOfScalar(*Peer, self.peers.items, peer)) |i| _ = self.peers.orderedRemove(i);
        for (&self.members) |*m| if (m.* == peer) {
            m.* = null;
        };
        for (&self.joiners) |*m| if (m.* == peer) {
            m.* = null;
        };
        self.destroyPeer(peer);
    }

    fn peerOf(self: *const Netplay, connection: platform.ConnectionId) ?*Peer {
        for (self.peers.items) |peer| if (peer.connection == connection) return peer;
        return null;
    }

    /// The host's client that plays player `k` in its session, if any.
    pub fn member(self: *const Netplay, k: usize) ?*Peer {
        return self.members[k];
    }

    /// The host's first client in its session of play (the one of player 2, with two machines).
    pub fn player(self: *const Netplay) ?*Peer {
        for (self.members) |m| if (m) |x| return x;
        return null;
    }

    /// Whether `peer` plays the host's game in a session.
    fn isMember(self: *const Netplay, peer: *const Peer) bool {
        for (self.members) |m| if (m == peer) return true;
        return false;
    }

    fn placeOf(self: *const Netplay, peer: *const Peer) ?input.Player {
        for (self.members, 0..) |m, k| if (m == peer) return @intCast(k);
        return null;
    }

    /// The host's clients in its session of play (held or stopped at a mismatch too).
    pub fn memberCount(self: *const Netplay) usize {
        var n: usize = 0;
        for (self.members) |m| if (m) |x| {
            if (x.session.inSession()) n += 1;
        };
        return n;
    }

    /// The host's clients that play on in its session (not leaving it), but `but`.
    fn stayingBut(self: *const Netplay, but: ?*const Peer) usize {
        var n: usize = 0;
        for (self.members) |m| if (m) |x| {
            if (x != but and x.session.phase == .playing and x.session.leaving == null and !x.session.peer_left) n += 1;
        };
        return n;
    }

    /// Whether player `k`'s place is taken in the host's session (a client plays it, or its
    /// join is to come).
    pub fn placeTaken(self: *const Netplay, k: usize) bool {
        return self.members[k] != null or self.joiners[k] != null;
    }

    /// The session of play: the host's with its first client, the client's with its host.
    fn main(self: *const Netplay) ?*Session {
        return switch (self.role) {
            .host => if (self.player()) |p| &p.session else null,
            .guest => &self.peers.items[0].session,
        };
    }

    /// The client's host.
    fn hostPeer(self: *const Netplay) *Peer {
        std.debug.assert(self.role == .guest);
        return self.peers.items[0];
    }

    /// The client connects at once (unless the platform brings its connection); the host waits
    /// for its session to open.
    pub fn start(self: *Netplay, p: *platform.Platform) platform.NetError!void {
        if (self.started) return;
        self.now_ns = p.nowNs();
        self.started = true;
        if (self.address.len == 0) return;
        errdefer self.started = false;
        switch (self.role) {
            .host => {},
            .guest => {
                _ = try platform.WsUrl.parse(self.address);
                self.connect(p);
            },
        }
    }

    /// The host's session opens (NETWORK PLAY's START): the host listens (once), and clients
    /// may join and, when `observers`, watch.
    pub fn openSession(self: *Netplay, p: *platform.Platform, observers: bool, same_character: bool, join_in_progress: bool) platform.NetError!void {
        if (self.role != .host) return;
        if (self.address.len != 0 and !self.listening) {
            try p.netListen(self.address);
            self.listening = true;
            if (self.log_enabled) log.info("hosting at {s}", .{self.address});
        } else if (self.stopped and self.log_enabled) log.info("the server started again", .{});
        self.open = true;
        self.stopped = false;
        self.setOptions(p, observers, same_character, join_in_progress);
    }

    /// What the host's session takes, changed while it is open (the lobby's values).
    pub fn setOptions(self: *Netplay, p: *platform.Platform, observers: bool, same_character: bool, join_in_progress: bool) void {
        self.observers = observers;
        self.same_character = same_character;
        self.join_in_progress = join_in_progress;
        self.sendStatus(p);
    }

    /// The port the host listens at, or will: its address's (null: the platform brings the
    /// connections, or not the host).
    pub fn port(self: *const Netplay) ?u16 {
        if (self.role != .host or self.address.len == 0) return null;
        const a = platform.parseListenAddress(self.address) catch return null;
        return a.port;
    }

    /// Whether the host listens already: its port can no longer change.
    pub fn portFixed(self: *const Netplay) bool {
        return self.listening;
    }

    /// The host listens at `new` (its address's interface kept), before it listens.
    pub fn setPort(self: *Netplay, new: u16) error{OutOfMemory}!void {
        if (self.role != .host or self.address.len == 0 or self.listening) return;
        const a = platform.parseListenAddress(self.address) catch return;
        if (a.port == new) return;
        const colon = std.mem.lastIndexOfScalar(u8, self.address, ':');
        const host = if (colon) |c| self.address[0 .. c + 1] else "";
        const address = try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ host, new });
        self.allocator.free(self.address);
        self.address = address;
    }

    /// The host stops its server (STOP SERVER, its game at its menu): each client is told and let
    /// go, and the host stops listening (DESIGN.md 9: its port closes), so that those that come
    /// find no host until the session opens again (`openSession` listens anew). A platform that
    /// brings the connections itself (no address) keeps turning them away (`stopped`).
    pub fn stopSession(self: *Netplay, p: *platform.Platform) void {
        if (self.role != .host) return;
        self.open = false;
        self.stopped = true;
        while (self.peers.items.len != 0) {
            const peer = self.peers.items[0];
            peer.session.leave(.stopped);
            self.flush(p, peer);
            if (peer.connection) |id| p.netClose(id);
            self.removePeer(peer);
        }
        self.changes = .{};
        if (self.listening) {
            p.netUnlisten();
            self.listening = false;
        }
        if (self.log_enabled) log.info("the server stopped: its clients let go, its port closed", .{});
    }

    fn connect(self: *Netplay, p: *platform.Platform) void {
        self.reconnect_at = null;
        self.connecting = p.netConnect(self.address) catch |err| {
            if (self.log_enabled and !self.refused_logged) log.warn("cannot connect to {s}: {s}", .{ self.address, @errorName(err) });
            self.refused_logged = true;
            self.reconnect_at = self.now_ns + reconnect_ns;
            return;
        };
    }

    /// Takes a platform event if it is the transport's; returns whether it was.
    pub fn handle(self: *Netplay, p: *platform.Platform, e: platform.Event) bool {
        self.now_ns = @max(self.now_ns, e.time_ns);
        switch (e.payload) {
            .net_connected => |c| switch (self.role) {
                .host => {
                    if (self.stopped) {
                        var buf: [protocol.max_len]u8 = undefined;
                        p.netSend(c.connection, protocol.encode(.{ .reject = .stopped }, &buf)) catch {};
                        p.netClose(c.connection);
                        return true;
                    }
                    if (self.peers.items.len >= max_clients) {
                        var buf: [protocol.max_len]u8 = undefined;
                        p.netSend(c.connection, protocol.encode(.{ .reject = .busy }, &buf)) catch {};
                        p.netClose(c.connection);
                        if (self.log_enabled) log.info("a client was turned away: {d} are there", .{max_clients});
                        return true;
                    }
                    const peer = self.newPeer(c.connection) catch {
                        p.netClose(c.connection);
                        return true;
                    };
                    peer.session.connectedAt(self.now_ns);
                    if (self.log_enabled) log.info("a client connected", .{});
                    self.flush(p, peer);
                },
                .guest => {
                    const host = self.hostPeer();
                    const ours = self.address.len == 0 or self.connecting == c.connection;
                    if (host.connection != null or !ours) {
                        p.netClose(c.connection);
                        return true;
                    }
                    host.connection = c.connection;
                    self.connecting = null;
                    if (self.log_enabled and !self.refused_logged) log.info("connected to the host", .{});
                    host.session.connectedAt(self.now_ns);
                    self.flush(p, host);
                },
            },
            .net_disconnected => |d| {
                if (self.connecting == d.connection) {
                    self.connecting = null;
                    self.lost(self.hostPeer(), d.reason);
                    return true;
                }
                const peer = self.peerOf(d.connection) orelse return true;
                self.lost(peer, d.reason);
            },
            .net_received => |m| {
                const peer = self.peerOf(m.connection) orelse return true;
                // A player whose connection came back: its hello names the session it plays. Its
                // old connection, not yet seen gone (the player's side broke first), is lost now:
                // the newer one wins. (One that leaves the session already is a new client.)
                if (self.role == .host and !self.isMember(peer)) for (self.members) |mem| if (mem) |pl| {
                    if (pl.session.phase == .playing and pl.session.leaving == null) if (protocol.decode(m.bytes)) |msg| switch (msg) {
                        .hello => |h| if (h.session == pl.session.id) {
                            if (pl.connection) |old| {
                                p.netClose(old);
                                self.lost(pl, .lost);
                            }
                            pl.connection = m.connection;
                            peer.connection = null;
                            self.removePeer(peer);
                            pl.session.connectedAt(self.now_ns);
                            return self.receive(p, pl, m.bytes);
                        },
                        else => {},
                    } else |_| {};
                };
                return self.receive(p, peer, m.bytes);
            },
            else => return false,
        }
        return true;
    }

    fn receive(self: *Netplay, p: *platform.Platform, peer: *Peer, bytes: []const u8) bool {
        const left_before = peer.session.peer_left;
        const verdict = peer.session.receive(bytes, self.now_ns);
        switch (verdict) {
            .malformed, .conflict, .unexpected, .ahead => if (self.log_enabled) log.warn("a message from {s}: {s}", .{ if (self.role == .host) "a client" else "the host", @tagName(verdict) }),
            else => {},
        }
        if (self.role == .host) {
            // A client's status: the host tells it what it is once it is welcomed.
            if (peer.session.welcomed and peer.session.phase == .lobby) peer.session.setStatus(self.statusFor());
            if (self.placeOf(peer)) |k| {
                // A player's pads go on to the session's other clients.
                self.relay(p, k);
                // A player who said goodbye goes at the tick its pads run out; the others play on,
                // told ahead.
                if (!left_before and peer.session.peer_left and peer.session.phase == .playing) self.leaveLater(p, peer, .left);
            }
        }
        self.flush(p, peer);
        self.takeNotes(peer);
        return true;
    }

    fn lost(self: *Netplay, peer: *Peer, reason: platform.DisconnectReason) void {
        const was_playing = peer.session.phase == .playing and !peer.session.peer_left and peer.session.leaving == null;
        peer.connection = null;
        peer.session.disconnected(self.now_ns);
        if (self.log_enabled) {
            if (was_playing) {
                log.warn("the connection is lost ({s}); the game holds until {s}", .{
                    @tagName(reason), if (self.role == .host) "the player reconnects" else "it is back",
                });
            } else if (reason == .refused) {
                if (!self.refused_logged) log.info("no host at {s} yet; trying every second", .{self.address});
                self.refused_logged = true;
            } else if (!self.refused_logged) log.info("the connection ended ({s})", .{@tagName(reason)});
        }
        self.takeNotes(peer);
        switch (self.role) {
            // The host keeps a player's session while it may come back (or its last pads run);
            // a client in its menu or watching goes.
            .host => if (!(self.isMember(peer) and peer.session.phase == .playing)) self.removePeer(peer),
            .guest => if (self.address.len != 0 and peer.session.phase != .ended) {
                self.reconnect_at = self.now_ns + reconnect_ns;
            },
        }
    }

    /// Once per update, after the events: the sessions' timers, the client's reconnection, the
    /// player's drop said to the others, the notes, and the messages still to send.
    pub fn update(self: *Netplay, p: *platform.Platform) void {
        self.now_ns = @max(self.now_ns, p.nowNs());
        if (!self.started) return;
        self.measure();
        if (self.role == .guest and self.hostPeer().connection == null and self.connecting == null) {
            if (self.reconnect_at) |t| if (self.now_ns >= t) self.connect(p);
        }
        if (self.role == .host) self.sayAway(p);
        var i: usize = 0;
        while (i < self.peers.items.len) {
            const peer = self.peers.items[i];
            peer.session.tick(self.now_ns);
            peer.session.flushTicks();
            self.flush(p, peer);
            self.takeNotes(peer);
            if (peer.session.close_requested) {
                peer.session.close_requested = false;
                if (peer.connection) |id| {
                    p.netClose(id);
                    const gone = self.role == .host and !(self.isMember(peer) and peer.session.phase == .playing);
                    self.lost(peer, .closed);
                    if (gone) continue;
                }
            }
            i += 1;
        }
    }

    /// A player's dropped connection, counted down to the others in seconds, once a second.
    fn sayAway(self: *Netplay, p: *platform.Platform) void {
        const down = self.lostPlayer();
        const seconds: u8 = if (down) |d| @intCast((session_mod.rejoin_ns -| d.ns + std.time.ns_per_s - 1) / std.time.ns_per_s) else 0;
        const who: input.Player = if (down) |d| d.player else self.away_player;
        if (seconds == self.away_said and who == self.away_player) return;
        // Another player's count replaces one that ended: its end said first.
        if (who != self.away_player and self.away_said != 0) self.tellAway(p, 0, self.away_player);
        self.away_said = seconds;
        self.away_player = who;
        self.tellAway(p, seconds, who);
    }

    fn tellAway(self: *Netplay, p: *platform.Platform, seconds: u8, who: input.Player) void {
        for (self.peers.items) |peer| if (self.members[who] != peer) {
            peer.session.sayAway(seconds, who);
            self.flush(p, peer);
        };
    }

    /// Sends a peer's messages in order; those that find the queue full wait for the next update,
    /// and a backlog that keeps growing gives the connection up.
    fn flush(self: *Netplay, p: *platform.Platform, peer: *Peer) void {
        const out = &peer.session.outbox;
        var sent: usize = 0;
        if (peer.connection) |id| {
            for (out.items) |m| {
                p.netSend(id, m) catch |err| switch (err) {
                    error.QueueFull => break,
                    else => {},
                };
                sent += 1;
            }
        } else sent = out.items.len;
        for (out.items[0..sent]) |m| self.allocator.free(m);
        const rest = out.items.len - sent;
        std.mem.copyForwards([]u8, out.items[0..rest], out.items[sent..]);
        out.shrinkRetainingCapacity(rest);
        if (rest > max_backlog) {
            if (self.log_enabled) log.warn("a peer does not take its messages; the connection is given up", .{});
            peer.session.close_requested = true;
        }
    }

    fn flushAll(self: *Netplay, p: *platform.Platform) void {
        for (self.peers.items) |peer| self.flush(p, peer);
    }

    /// A peer's notes, logged; those of the sessions of play (or the client's) for the game. The
    /// host's player whose session ended is a client in its menu again (or goes, its connection
    /// down); the game hears which player it was (`member_ended`).
    fn takeNotes(self: *Netplay, peer: *Peer) void {
        const place = self.placeOf(peer);
        const for_game = self.role == .guest or place != null;
        var ended: ?session_mod.End = null;
        var stop_others = false;
        var resumed = false;
        for (peer.session.notes.items) |n| {
            self.logNote(peer, n);
            // A stopped host's refusal is said once; the client tries again quietly.
            if (self.role == .guest) switch (n) {
                .refused => |r| if (r == .stopped) {
                    if (self.log_enabled and !self.refused_logged) log.info("the host stopped its server; trying every second", .{});
                    self.refused_logged = true;
                },
                .welcomed => self.refused_logged = false,
                else => {},
            };
            if (!for_game) continue;
            switch (n) {
                .started => |s| {
                    // The host counts its session from its first client; a client its own.
                    if (!s.resumed and (self.role == .guest or s.tick == 0)) self.sessions += 1;
                    resumed = resumed or s.resumed;
                },
                .diagnosed => |d| self.difference = d,
                .desync => stop_others = self.role == .host,
                // A client's settings screen holds the others too: they are told whose it is.
                .settings => |x| if (self.role == .host) self.relaySettings(@intCast(x.player), x.open),
                .ended => |why| {
                    ended = why;
                    if (self.role == .host) continue;
                },
                else => {},
            }
            self.notes.append(self.allocator, n) catch {};
        }
        peer.session.notes.clearRetainingCapacity();
        // A client back on its connection gets the other clients' pads it may have lost.
        if (resumed and self.role == .host) if (place) |k| {
            peer.session.relayAgain();
            for (self.members, 0..) |m, j| if (m != null and j != k) peer.session.relayOf(@intCast(j), &m.?.session);
        };
        // A mismatch with one client stops the session for every machine.
        if (stop_others) for (self.members) |m| if (m) |x| if (x != peer) x.session.stopAtDesync();
        if (self.role == .host) if (place) |k| if (ended) |why| if (!peer.session.inSession()) {
            self.members[k] = null;
            self.notes.append(self.allocator, .{ .member_ended = .{ .player = k, .why = why, .made = peer.leave_made } }) catch {};
            peer.leave_made = false;
            // Its settings no longer hold the others.
            if (peer.session.peer_settings) self.relaySettings(k, false);
            peer.session.peer_settings = false;
            if (self.memberCount() == 0) self.changes = .{};
            if (peer.connection == null) self.removePeer(peer);
        };
    }

    fn logNote(self: *const Netplay, peer: *const Peer, n: Note) void {
        if (!self.log_enabled) return;
        const s = &peer.session;
        const who: []const u8 = if (self.role == .host) &s.peer_name else "the host";
        switch (n) {
            .welcomed => log.info("{s} welcomed: input delay {d} ticks", .{ if (self.role == .host) who else "this client", s.delay }),
            .started => |st| if (st.resumed) {
                log.info("the session resumes at tick {d}", .{st.tick});
            } else log.info("a session starts at tick {d}: the host's game{s}, input delay {d} ticks", .{ st.tick, if (self.role == .host) "" else ", loaded", st.delay }),
            .joined => log.info("the host's game is in ({d} bytes): player {d}", .{ s.gameForm().len, @as(u8, s.place) + 1 }),
            .join_asked => |c| log.info("{s} asks to join{s}{s}", .{ who, if (c == protocol.no_character) "" else " as ", if (c == protocol.no_character) "" else characterName(c) }),
            .observe_asked => log.info("{s} asks to watch", .{who}),
            .observing => log.info("watching the host's game ({d} bytes)", .{s.gameForm().len}),
            .away => |a| log.debug("player {d}'s connection is down: {d} s left", .{ @as(u8, a.player) + 1, a.seconds }),
            .status => |st| log.debug("the host's game: {s}", .{@tagName(st.game)}),
            .refused => |r| {
                if (s.phase == .playing) {
                    log.info("the host still has the old connection; trying again", .{});
                } else if (r != .stopped) log.err("refused: {s}", .{refusal(r)});
            },
            .desync => |t| log.err("the games differ at tick {d}: {s}", .{ t, if (s.phase == .desynced and self.role == .guest and s.observe_asked == false) "the game stops" else "both stop; comparing their states" }),
            .diagnosed => |d| if (d) |x| log.err("first difference: {f}", .{x}) else log.err("the states could not be compared", .{}),
            .left => |r| log.info("{s} left ({s})", .{ if (self.role == .host) who else "the host", @tagName(r) }),
            .ended => |e| log.info("{s} ended ({s})", .{ if (self.isMember(peer) or self.role == .guest) "the session" else "a client's watch", @tagName(e) }),
            .watch_ended => log.info("the watch of the host's game ended", .{}),
            .settings => |x| if (x.open) {
                log.info("player {d} is on the settings screen: the game holds", .{@as(u8, x.player) + 1});
            } else log.info("player {d} left the settings screen", .{@as(u8, x.player) + 1}),
            .member_ended => {},
        }
    }

    fn characterName(c: u8) []const u8 {
        return switch (c) {
            0 => "Adam",
            1 => "Axel",
            2 => "Blaze",
            else => "?",
        };
    }

    pub fn refusal(r: protocol.RejectReason) []const u8 {
        return switch (r) {
            .protocol => "another protocol version",
            .build => "another build of the game",
            .data => "other game data (each player needs the same ROM or game directory)",
            .busy => "the host has too many clients",
            .malformed => "a message out of the protocol",
            .stopped => "the host stopped its server",
            _ => "unknown reason",
        };
    }

    /// The notes since the game last looked; the game clears them (`clearNotes`).
    pub fn pending(self: *const Netplay) []const Note {
        return self.notes.items;
    }

    pub fn clearNotes(self: *Netplay) void {
        self.notes.clearRetainingCapacity();
    }

    // --- the host's lobby: its status, joins, observers --------------------------------------

    /// The host's status with the driver's word on its session.
    fn statusFor(self: *const Netplay) protocol.Status {
        var s = self.status;
        s.open = self.open;
        // The game says whether it has room for another player (`status.place`, and the place);
        // a game under way takes one when joins in progress are allowed.
        s.place = self.open and self.status.place and (self.status.game != .play or self.join_in_progress);
        if (!s.place) s.next_place = 0;
        s.observers = self.open and self.observers;
        s.same_character = self.same_character;
        s.join_in_progress = self.join_in_progress;
        return s;
    }

    fn sendStatus(self: *Netplay, p: *platform.Platform) void {
        const s = self.statusFor();
        for (self.peers.items) |peer| {
            peer.session.setStatus(s);
            self.flush(p, peer);
        }
    }

    /// The host's game, as its clients hear it (when they are in its lobby).
    pub fn setStatus(self: *Netplay, p: *platform.Platform, s: protocol.Status) void {
        self.status = s;
        self.sendStatus(p);
    }

    /// The host: a client that asks to join, its character, and its cursor's place at its own
    /// select (`no_character`: none); the game decides whether a place is free for it.
    pub fn joinAsked(self: *const Netplay) ?struct { peer: *Peer, character: u8, cursor: u8 } {
        if (self.role != .host or !self.open) return null;
        for (self.peers.items) |peer| if (peer.session.phase == .lobby and !self.isJoining(peer)) if (peer.session.join_asked) |c| {
            return .{ .peer = peer, .character = c, .cursor = peer.session.peer_where.cursor };
        };
        return null;
    }

    fn isJoining(self: *const Netplay, peer: *const Peer) bool {
        for (self.joiners) |m| if (m == peer) return true;
        return false;
    }

    /// The host's game takes `peer` as its player `place` in a new session: from the host's
    /// game's form now.
    pub fn begin(self: *Netplay, p: *platform.Platform, peer: *Peer, place: input.Player, form: []const u8) void {
        std.debug.assert(self.memberCount() == 0);
        self.members = @splat(null);
        self.changes = .{};
        self.members[place] = peer;
        peer.session.place = place;
        peer.session.begin(form, self.now_ns);
        self.group_delay = peer.session.delay;
        self.flush(p, peer);
        self.takeNotes(peer);
        self.sendStatus(p);
    }

    /// The host's game takes `peer` as its player `place` in the session under way: it joins at
    /// the first tick whose pads the host has not sent (every machine adds the player then, its
    /// first pads empty), the delay longer from then if its link needs it; its game comes then
    /// (`beginJoin`). False when the session cannot take it now.
    pub fn scheduleJoin(self: *Netplay, p: *platform.Platform, peer: *Peer, place: input.Player, character: u8, cursor: u8, name: protocol.Name) bool {
        const first = self.player() orelse return false;
        const join_delay = self.joinDelay(peer);
        const e: protocol.Event = .{ .tick = 0, .what = .join, .player = place, .character = character, .cursor = cursor, .delay = join_delay, .name = name };
        if (!self.scheduleOn(p, e, first.session.local_count, null)) return false;
        self.joiners[place] = peer;
        peer.session.place = place;
        peer.session.join_asked = null;
        self.sendStatus(p);
        if (self.log_enabled) log.info("{s} joins as player {d} at tick {d}", .{ &peer.session.peer_name, @as(u8, place) + 1, first.session.local_count });
        return true;
    }

    /// The input delay a session with `joiner` among its clients needs: a client's pads reach
    /// another through the host, so the two longest links' one-way times, in ticks rounded up,
    /// plus one (the given delay instead, when the host has one); never shorter than the
    /// session's.
    fn joinDelay(self: *const Netplay, joiner: *const Peer) u8 {
        if (self.config.delay) |d| return d;
        var longest: [2]u64 = .{ 0, 0 };
        var rtts: [max_players]u64 = @splat(0);
        for (self.members, 0..) |m, k| if (m) |x| {
            rtts[k] = @max(x.session.rtt_ns, x.session.handshake_rtt_ns);
        };
        const joiner_rtt = @max(joiner.session.rtt_ns, joiner.session.handshake_rtt_ns);
        for (rtts ++ [_]u64{joiner_rtt}) |r| {
            if (r > longest[0]) {
                longest[1] = longest[0];
                longest[0] = r;
            } else if (r > longest[1]) longest[1] = r;
        }
        return @max(self.group_delay, Session.delayFor(longest[0] + longest[1]));
    }

    /// The join of player `place` was made at this tick on the host's game, whose form is now
    /// `form` (the player in): its client's session begins here, the host's pads it sent the
    /// others with it, the other clients' pads relayed to it from now, its pads to them. A client
    /// gone before its join: the others drop its player once its empty pads are over.
    pub fn beginJoin(self: *Netplay, p: *platform.Platform, place: input.Player, form: []const u8) void {
        const first = self.player() orelse return;
        const tick_ = first.session.next;
        const peer = self.joiners[place] orelse {
            const gone: protocol.Event = .{ .tick = 0, .what = .leave, .player = place };
            _ = self.scheduleOn(p, gone, tick_ + self.group_delay, null);
            return;
        };
        self.joiners[place] = null;
        if (peer.session.phase != .lobby) {
            const gone: protocol.Event = .{ .tick = 0, .what = .leave, .player = place };
            _ = self.scheduleOn(p, gone, tick_ + self.group_delay, null);
            return;
        }
        var players: u8 = 1;
        for (self.members, 0..) |m, k| if (m) |x| if (x.session.phase == .playing) {
            players |= @as(u8, 1) << @intCast(k);
        };
        var host_pads: [protocol.max_delay + 1]u8 = undefined;
        const n = first.session.local_count - tick_;
        for (0..n) |i| host_pads[i] = first.session.localPad(tick_ + @as(u32, @intCast(i)));
        peer.session.beginAt(form, self.now_ns, .{ .tick = tick_, .delay = self.group_delay, .players = players, .host_pads = host_pads[0..n] });
        peer.session.local_count = first.session.local_count;
        peer.session.flushPads();
        self.members[place] = peer;
        for (self.members, 0..) |m, k| if (m) |x| if (x != peer) {
            x.session.relayFrom(place, tick_ + self.group_delay);
            peer.session.relayFrom(@intCast(k), tick_);
        };
        // The changes still to come, which its game's form does not have.
        for (self.changes.slice()) |e| if (e.tick >= tick_) {
            _ = peer.session.scheduleAt(e, e.tick);
        };
        for (0..max_players) |k| self.relay(p, @intCast(k));
        self.flush(p, peer);
        self.takeNotes(peer);
        self.sendStatus(p);
    }

    /// The host's game does not take `peer`'s ask now: it hears the host's status again.
    pub fn declineJoin(self: *Netplay, p: *platform.Platform, peer: *Peer) void {
        peer.session.declineJoin();
        self.flush(p, peer);
    }

    /// The host: a client that asks to watch, or to watch again (an observer that lost the
    /// host's ticks); the game decides: `beginObserve`, or `declineObserve`.
    pub fn observeAsked(self: *const Netplay) ?*Peer {
        if (self.role != .host or !self.open) return null;
        for (self.peers.items) |peer| if ((peer.session.phase == .lobby or peer.session.phase == .observing) and peer.session.observe_asked and !self.isJoining(peer)) return peer;
        return null;
    }

    /// The host has no game for `peer` to watch now: it hears the host's status again.
    pub fn declineObserve(self: *Netplay, p: *platform.Platform, peer: *Peer) void {
        peer.session.declineObserve();
        self.flush(p, peer);
    }

    /// The host's game the observers watched is over for them (its player left it, or it ended
    /// under the host's lobby): they are told, and go back to their menus.
    pub fn endWatches(self: *Netplay, p: *platform.Platform) void {
        for (self.peers.items) |peer| if (peer.session.phase == .observing) {
            peer.session.leaveGame();
            self.flush(p, peer);
        };
        self.sendStatus(p);
    }

    /// The host sends `peer` its game, `form`: the client watches it from now on.
    pub fn beginObserve(self: *Netplay, p: *platform.Platform, peer: *Peer, form: []const u8) void {
        peer.session.beginObserve(form, self.now_ns);
        self.flush(p, peer);
    }

    /// Whether a client watches the host's game.
    pub fn watched(self: *const Netplay) bool {
        for (self.peers.items) |peer| if (peer.session.phase == .observing) return true;
        return false;
    }

    /// The host's game changed otherwise than by its pads: its observers get it again.
    pub fn resync(self: *Netplay, p: *platform.Platform, form: []const u8) void {
        for (self.peers.items) |peer| if (peer.session.phase == .observing) self.beginObserve(p, peer, form);
    }

    /// The host's game ran a tick with `pads`, those of its first `players` players: its
    /// observers get them, at once.
    pub fn observed(self: *Netplay, p: *platform.Platform, pads_: input.Pads, players: u8) void {
        for (self.peers.items) |peer| if (peer.session.phase == .observing) {
            peer.session.observed(pads_, players);
            peer.session.flushTicks();
            self.flush(p, peer);
        };
    }

    /// The clients of the host, as its screens list them.
    pub fn roster(self: *const Netplay, out: []Entry) []Entry {
        var n: usize = 0;
        for (self.peers.items) |peer| {
            if (n == out.len) break;
            const place = self.placeOf(peer);
            if (!peer.session.welcomed and place == null) continue;
            const s = &peer.session;
            out[n] = .{ .name = s.peer_name, .place = place orelse 1, .doing = if (place != null) .player else if (s.phase == .observing) .observing else if (s.peer_where.at == .select) .select else .menu };
            n += 1;
        }
        return out[0..n];
    }

    // --- the client ------------------------------------------------------------------------

    /// The host's game and session, as the client last heard them.
    pub fn hostStatus(self: *const Netplay) protocol.Status {
        if (self.role != .guest) return .{};
        const s = &self.hostPeer().session;
        if (!s.welcomed) return .{};
        return s.peer_status;
    }

    /// The client is in the host's lobby (connected and welcomed).
    pub fn welcomed(self: *const Netplay) bool {
        return self.role == .guest and self.hostPeer().session.welcomed;
    }

    pub fn askJoin(self: *Netplay, p: *platform.Platform, character: u8) void {
        if (self.role != .guest) return;
        self.hostPeer().session.askJoin(character);
        self.flush(p, self.hostPeer());
    }

    pub fn askObserve(self: *Netplay, p: *platform.Platform) void {
        if (self.role != .guest) return;
        self.hostPeer().session.askObserve();
        self.flush(p, self.hostPeer());
    }

    pub fn stopObserve(self: *Netplay, p: *platform.Platform) void {
        if (self.role != .guest) return;
        self.hostPeer().session.stopObserve();
        self.flush(p, self.hostPeer());
    }

    /// The client's wish to watch, on its way (the host's game not in yet).
    pub fn observeWanted(self: *const Netplay) bool {
        if (self.role != .guest) return false;
        const s = &self.hostPeer().session;
        return s.observe_asked and s.phase == .lobby;
    }

    /// Where the client's player is in its own game (its menu, its select to join), for the
    /// host's lists.
    pub fn sayWhere(self: *Netplay, p: *platform.Platform, x: protocol.Where) void {
        if (self.role != .guest) return;
        const host = self.hostPeer();
        host.session.sayWhere(x);
        self.flush(p, host);
    }

    /// The client's player's name changed: the host hears it at once (`name`), or in the hello of
    /// its next connection.
    pub fn rename(self: *Netplay, p: *platform.Platform, name: protocol.Name) void {
        self.config.name = name;
        for (self.peers.items) |peer| peer.session.rename(name);
        self.flushAll(p);
    }

    /// The host's game the client loads (after `joined` or `observing`).
    pub fn gameForm(self: *const Netplay) []const u8 {
        if (self.role != .guest) return &.{};
        return self.hostPeer().session.gameForm();
    }

    /// The client watches the host's game.
    pub fn observing(self: *const Netplay) bool {
        if (self.role != .guest) return false;
        const s = &self.hostPeer().session;
        return s.phase == .observing or (s.phase == .desynced and s.id != 0 and s.observe_asked == false and s.remote_count == 0 and s.local_count == 0);
    }

    /// The client's wish to join or watch, still on its way.
    pub fn joining(self: *const Netplay) bool {
        if (self.role != .guest) return false;
        return self.hostPeer().session.phase == .joining;
    }

    // --- the session of play ---------------------------------------------------------------

    /// The pads of the next tick of the session, or null while the game must hold. `local` is the
    /// local player's pad. The host merges its clients' with its own: a client whose session
    /// ended here (its last pads ran out) is out of it; with none left, the session is over.
    pub fn pads(self: *Netplay, p: *platform.Platform, local: input.Pad) ?input.Pads {
        var merged: ?input.Pads = null;
        var playing = false;
        var next: u32 = 0;
        switch (self.role) {
            .guest => {
                const s = self.main().?;
                merged = s.pads(local);
                playing = s.phase == .playing;
                next = s.next;
                self.flushAll(p);
                self.takeNotes(self.hostPeer());
            },
            .host => {
                const first = self.player() orelse return null;
                next = first.session.next;
                // A join at this tick makes the delay longer from now on.
                for (self.changes.slice()) |e| if (e.tick == next and e.what == .join and e.delay > self.group_delay) {
                    self.group_delay = e.delay;
                };
                var out: input.Pads = .{};
                var ready = true;
                var any = false;
                var stopped = false;
                for (self.members, 0..) |m, k| if (m) |x| {
                    const s = &x.session;
                    if (s.phase == .desynced) stopped = true;
                    if (s.phase != .playing) continue;
                    s.delay = @max(s.delay, self.group_delay);
                    const r = s.pads(local);
                    // Its pads ran out after its goodbye: out of the session from this tick.
                    if (s.phase != .playing) continue;
                    any = true;
                    if (r) |x_| {
                        out.at(0).* = x_.of(0);
                        out.at(k).* = x_.of(k);
                    } else ready = false;
                };
                playing = any and !stopped;
                self.flushAll(p);
                for (self.members) |m| if (m) |x| self.takeNotes(x);
                if (playing and ready) merged = out;
            },
        }
        if (playing) {
            if (merged == null) {
                if (self.meter.hold_from == null) self.meter.hold_from = self.now_ns;
            } else if (self.meter.hold_from) |from| {
                self.meter.wait_ns += self.now_ns -| from;
                self.meter.hold_from = null;
            }
        }
        if (merged == null) {
            if (self.held_since == null) {
                self.held_since = self.now_ns;
                self.hold_logged = false;
            } else if (!self.hold_logged and self.now_ns -| self.held_since.? >= hold_log_ns and playing) {
                self.hold_logged = true;
                if (self.log_enabled) log.info("holding at tick {d}: waiting for another player's pads", .{next});
            }
        } else {
            if (self.hold_logged and self.log_enabled) log.info("going on after {d} ms", .{(self.now_ns -| self.held_since.?) / std.time.ns_per_ms});
            self.held_since = null;
            self.hold_logged = false;
        }
        return merged;
    }

    /// The host relays player `k`'s pads (its client's, as they came) to the session's other
    /// clients.
    fn relay(self: *Netplay, p: *platform.Platform, k: input.Player) void {
        const src = self.members[k] orelse return;
        if (src.session.phase != .playing) return;
        for (self.members) |m| if (m) |x| if (x != src) {
            x.session.relayOf(k, &src.session);
            self.flush(p, x);
        };
    }

    /// The host relays client player `k`'s settings screen to the session's other clients.
    fn relaySettings(self: *Netplay, k: input.Player, open: bool) void {
        for (self.members) |m| if (m) |x| if (self.members[k] != x) x.session.relaySettings(open, k);
    }

    /// The host's client `peer` leaves the session at the tick its pads run out (`why`: it said
    /// goodbye, or its connection did not come back in time), the other clients told ahead; the
    /// last client of the session goes as the session ends, the host's game told then.
    fn leaveLater(self: *Netplay, p: *platform.Platform, peer: *Peer, why: session_mod.End) void {
        const k = self.placeOf(peer) orelse return;
        if (self.stayingBut(peer) == 0) {
            if (why == .lost) peer.session.end(.lost);
            return;
        }
        peer.session.leaveWhenOut(why);
        peer.leave_made = true;
        const e: protocol.Event = .{ .tick = 0, .what = if (self.cpu_place == k) .cpu else .leave, .player = k };
        if (!self.scheduleOn(p, e, peer.session.remote_count, peer)) {
            // No room for the change: the client goes at once, as the last would.
            peer.leave_made = false;
            peer.session.leaving = null;
            peer.session.end(why);
        }
        if (self.log_enabled) log.info("player {d} leaves at tick {d}", .{ @as(u8, k) + 1, peer.session.remote_count });
    }

    /// The host's clients whose dropped connection did not come back in time leave the game.
    pub fn giveUp(self: *Netplay, p: *platform.Platform) void {
        for (self.members) |m| if (m) |x| if (x.session.lostFor(self.now_ns)) |t| if (t > session_mod.rejoin_ns) {
            self.leaveLater(p, x, .lost);
        };
        self.flushAll(p);
        for (self.members) |m| if (m) |x| self.takeNotes(x);
        self.sendStatus(p);
    }

    /// `e` at tick `at` on each of the host's clients in its session (but `but`) and on its own
    /// game: false when one of them has no room for it, or no session runs.
    fn scheduleOn(self: *Netplay, p: *platform.Platform, e: protocol.Event, at: u32, but: ?*const Peer) bool {
        if (!self.changes.room()) return false;
        var any = false;
        for (self.members) |m| if (m) |x| if (x != but and x.session.phase == .playing) {
            if (x.session.events_len == session_mod.max_events) return false;
            any = true;
        };
        if (!any and but == null) return false;
        for (self.members) |m| if (m) |x| if (x != but and x.session.phase == .playing) {
            _ = x.session.scheduleAt(e, at);
        };
        var made = e;
        made.tick = at;
        self.changes.add(made);
        self.flushAll(p);
        return true;
    }

    /// The host changes the game in its session (its player leaves, or comes back, or the rules
    /// change: `change`) at the first tick whose pads it has not sent, on every machine; false
    /// when it cannot now.
    pub fn schedule(self: *Netplay, p: *platform.Platform, change: protocol.Event) bool {
        if (self.role != .host) return false;
        const first = self.player() orelse return false;
        const at = first.session.local_count;
        if (!self.scheduleOn(p, change, at, null)) return false;
        if (self.log_enabled) log.info("{s} at tick {d}", .{ switch (change.what) {
            .leave => "player 1 leaves the game",
            .back => "player 1 comes back",
            .rules => "the rules change",
            .join => "a player joins",
            .cpu => "a player goes back to the CPU",
        }, at });
        return true;
    }

    /// The change of the game before the session's next tick, if any (the first of them).
    pub fn eventAt(self: *const Netplay) ?protocol.Event {
        switch (self.role) {
            .guest => return self.main().?.eventAt(),
            .host => {
                const first = self.player() orelse return null;
                if (self.changes.len == 0 or first.session.phase != .playing) return null;
                const e = self.changes.items[0];
                return if (e.tick == first.session.next) e else null;
            },
        }
    }

    /// The same, taken: the game makes each change before the next tick in turn.
    pub fn takeEvent(self: *Netplay) ?protocol.Event {
        switch (self.role) {
            .guest => return self.main().?.takeEvent(),
            .host => {
                const e = self.eventAt() orelse return null;
                self.changes.drop(0);
                return e;
            },
        }
    }

    /// Whether a change of the game is still to come.
    pub fn eventDue(self: *const Netplay) bool {
        return switch (self.role) {
            .host => self.changes.len != 0,
            .guest => self.main().?.events_len != 0,
        };
    }

    /// The tick that `pads` gave the pads of ran.
    pub fn ran(self: *Netplay) void {
        switch (self.role) {
            .guest => self.main().?.ran(),
            .host => {
                for (self.members) |m| if (m) |x| if (x.session.phase == .playing) x.session.ran();
                // A change no game took (its tick passed): dropped.
                if (self.player()) |first| {
                    while (self.changes.len != 0 and self.changes.items[0].tick < first.session.next) self.changes.drop(0);
                }
            },
        }
        self.meter.ticks += 1;
    }

    /// The game worked `ns` in an update (its events, ticks and picture; not its presenting,
    /// which may wait for the display): the stats' busy share.
    pub fn worked(self: *Netplay, ns: u64) void {
        if (self.meter.since_ns != null) self.meter.busy_ns += ns;
    }

    /// The stats' second: once one has gone by in a session of play, its measure is kept and told
    /// to the other machines (sent with the update's messages; the host tells each client the
    /// others' too); outside one, nothing is measured.
    fn measure(self: *Netplay) void {
        const s = self.main() orelse {
            self.meter = .{};
            return;
        };
        if (s.phase != .playing) {
            self.meter = .{};
            return;
        }
        const m = &self.meter;
        const since = m.since_ns orelse {
            m.* = .{ .since_ns = self.now_ns };
            return;
        };
        const span = self.now_ns -| since;
        if (span < std.time.ns_per_s) return;
        if (m.hold_from) |from| m.wait_ns += self.now_ns -| from;
        // The host's round trip: its longest link's.
        var rtt = s.rtt_ns;
        if (self.role == .host) for (self.members) |x| if (x) |y| {
            rtt = @max(rtt, y.session.rtt_ns);
        };
        const l: protocol.Load = .{
            .ticks = @intCast(@min(255, (@as(u64, m.ticks) * std.time.ns_per_s + span / 2) / span)),
            .busy = percent(m.busy_ns, span),
            .wait = percent(m.wait_ns, span),
            .ping = @intCast(@min(rtt / std.time.ns_per_ms, protocol.max_ping)),
        };
        m.* = .{ .since_ns = self.now_ns, .hold_from = if (m.hold_from != null) self.now_ns else null, .last = l };
        switch (self.role) {
            .guest => s.sayLoad(l),
            .host => for (self.members) |x| if (x) |to| {
                to.session.sayLoad(l);
                for (self.members, 0..) |y, k| if (y) |from| if (from != to) if (from.session.peer_load) |theirs| {
                    to.session.sayLoadOf(@intCast(k), theirs);
                };
            },
        }
    }

    /// The stats of the session of play, from its first second on (null before, or outside one).
    pub fn stats(self: *const Netplay) ?Stats {
        const s = self.main() orelse return null;
        if (s.phase != .playing) return null;
        var out: Stats = .{
            .local = self.meter.last orelse return null,
            .peer = s.peer_load,
            .delay = s.delay,
            .host = self.role == .host,
            .client = if (self.role == .host) s.peer_name else s.config.name,
        };
        switch (self.role) {
            .host => {
                out.machines[0] = .{ .in = true, .load = out.local };
                for (self.members, 0..) |m, k| if (m) |x| if (x.session.phase == .playing) {
                    out.machines[k] = .{ .in = true, .load = x.session.peer_load, .name = x.session.peer_name };
                };
            },
            .guest => {
                out.machines[0] = .{ .in = true, .load = s.peer_load };
                out.machines[s.place] = .{ .in = true, .load = out.local, .name = s.config.name };
                for (s.others, 0..) |o, k| if (o.active(s.next)) {
                    out.machines[k] = .{ .in = true, .load = s.loads[k] };
                };
            },
        }
        return out;
    }

    /// Whether the state before the next tick is due for a check (then give it to `check`): the
    /// sessions', or an observer's.
    pub fn checkDue(self: *const Netplay) bool {
        switch (self.role) {
            .guest => if (self.main().?.checkDue()) return true,
            .host => for (self.members) |m| if (m) |x| if (x.session.checkDue()) return true,
        }
        for (self.peers.items) |peer| if (peer.session.observerCheckDue()) return true;
        return false;
    }

    /// The state's hash and its canonical form, before the next tick.
    pub fn check(self: *Netplay, p: *platform.Platform, hash: u64, form: []const u8) void {
        switch (self.role) {
            .guest => {
                const s = self.main().?;
                if (s.checkDue()) s.check(hash, form);
            },
            .host => for (self.members) |m| if (m) |x| if (x.session.checkDue()) x.session.check(hash, form),
        }
        for (self.peers.items) |peer| peer.session.observerHash(hash);
        self.flushAll(p);
        switch (self.role) {
            .guest => self.takeNotes(self.hostPeer()),
            .host => for (self.members) |m| if (m) |x| self.takeNotes(x),
        }
    }

    /// The session's first tick on this machine (a guest's join; the host's, its first
    /// client's: 0).
    pub fn firstTick(self: *const Netplay) u32 {
        const s = self.main() orelse return 0;
        return if (self.role == .host) 0 else s.start;
    }

    /// The next tick of the session.
    pub fn tick(self: *const Netplay) u32 {
        const s = self.main() orelse return 0;
        return s.next;
    }

    /// The session of play's phase: on the host, stopped at a mismatch with any client, else
    /// playing while one plays.
    pub fn phase(self: *const Netplay) session_mod.Phase {
        if (self.role == .host) {
            var any: ?session_mod.Phase = null;
            for (self.members) |m| if (m) |x| {
                if (x.session.phase == .desynced) return .desynced;
                if (x.session.inSession()) any = x.session.phase;
            };
            return any orelse if (self.open) .lobby else .idle;
        }
        const s = self.main() orelse return if (self.open) .lobby else .idle;
        return s.phase;
    }

    /// This machine's player in the session's game (`Session.localPlayer`): the host's player
    /// 1, a guest's its place (player 2 until a session says otherwise).
    pub fn localPlayer(self: *const Netplay) input.Player {
        const s = self.main() orelse return if (self.role == .host) 0 else 1;
        return s.localPlayer();
    }

    /// The other machine's player in the session's game (the host's first client's on the
    /// host).
    pub fn peerPlayer(self: *const Netplay) input.Player {
        const s = self.main() orelse return if (self.role == .host) 1 else 0;
        return s.peerPlayer();
    }

    /// Whether a session runs (held or not, stopped at a mismatch), or the client watches.
    pub fn inSession(self: *const Netplay) bool {
        if (self.role == .host) return self.memberCount() != 0;
        const s = self.main() orelse return false;
        return s.inSession();
    }

    /// The input delay of the session of play.
    pub fn delay(self: *const Netplay) u8 {
        if (self.role == .host) return if (self.player() != null) self.group_delay else 0;
        const s = self.main() orelse return 0;
        return s.delay;
    }

    /// Whether the session of play's connections are up.
    pub fn connected(self: *const Netplay) bool {
        if (self.role == .host) {
            var any = false;
            for (self.members) |m| if (m) |x| {
                if (!x.session.connected) return false;
                any = true;
            };
            return any;
        }
        const s = self.main() orelse return false;
        return s.connected;
    }

    /// How long the session's connection has been down (null: it is up, or no session): on the
    /// host, the longest of its clients' that may still come back.
    pub fn lostFor(self: *const Netplay) ?u64 {
        if (self.role == .host) return if (self.lostPlayer()) |d| d.ns else null;
        const s = self.main() orelse return null;
        return s.lostFor(self.now_ns);
    }

    /// The host's client player whose connection has been down longest, and for how long.
    pub const Lost = struct { player: input.Player, ns: u64 };

    pub fn lostPlayer(self: *const Netplay) ?Lost {
        var out: ?Lost = null;
        for (self.members, 0..) |m, k| if (m) |x| if (x.session.lostFor(self.now_ns)) |t| {
            if (out == null or t > out.?.ns) out = .{ .player = @intCast(k), .ns = t };
        };
        return out;
    }

    /// The session of play ends on this machine (its game ended): the host's players are clients
    /// in its menu again (or go, their connections down).
    pub fn end(self: *Netplay, p: *platform.Platform, why: session_mod.End) void {
        switch (self.role) {
            .guest => {
                self.main().?.end(why);
                self.flushAll(p);
                self.takeNotes(self.hostPeer());
            },
            .host => {
                for (self.members) |m| if (m) |x| x.session.end(why);
                self.flushAll(p);
                for (self.members) |m| if (m) |x| self.takeNotes(x);
                self.joiners = @splat(null);
                self.changes = .{};
                self.sendStatus(p);
            },
        }
    }

    /// Our player opened the settings screen (`open`) or closed it: the other players are told.
    pub fn inSettings(self: *Netplay, p: *platform.Platform, open: bool) void {
        switch (self.role) {
            .guest => {
                const s = self.main().?;
                if (open == s.local_settings) return;
                s.inSettings(open);
            },
            .host => for (self.members) |m| if (m) |x| x.session.inSettings(open),
        }
        self.flushAll(p);
    }

    /// Whether another player is on the settings screen, as it said on the live connection.
    pub fn peerInSettings(self: *const Netplay) bool {
        return self.settingsPlayer() != null;
    }

    /// The first other player on the settings screen, if any.
    pub fn settingsPlayer(self: *const Netplay) ?input.Player {
        switch (self.role) {
            .host => {
                for (self.members, 0..) |m, k| if (m) |x| if (x.session.connected and x.session.peer_settings) return @intCast(k);
                return null;
            },
            .guest => {
                const s = self.main().?;
                if (!s.connected or s.settings_of == 0) return null;
                return @intCast(@ctz(s.settings_of));
            },
        }
    }

    /// The stretch of the sound for the clock balancing, in parts per million: on the host, as
    /// much as it is ahead of its furthest client.
    pub fn stretchPpm(self: *const Netplay) u32 {
        if (self.role == .host) {
            var most: u32 = 0;
            for (self.members) |m| if (m) |x| {
                most = @max(most, x.session.stretchPpm());
            };
            return most;
        }
        const s = self.main() orelse return 0;
        return s.stretchPpm();
    }

    /// This machine's player leaves the game (Escape), not the program: the other players and
    /// the observers are told, the connections stay.
    pub fn leaveGame(self: *Netplay, p: *platform.Platform) void {
        for (self.peers.items) |peer| {
            peer.session.leaveGame();
            self.flush(p, peer);
            self.takeNotes(peer);
        }
        if (self.role == .host) {
            self.joiners = @splat(null);
            self.changes = .{};
            self.sendStatus(p);
        }
    }

    /// The game quits: a farewell to each peer, then the connections close.
    pub fn quit(self: *Netplay, p: *platform.Platform) void {
        for (self.peers.items) |peer| {
            peer.session.leave(.quit);
            self.flush(p, peer);
            if (peer.connection) |id| p.netClose(id);
            peer.connection = null;
        }
    }
};

test "the host's port: its address's, changed with its interface kept, fixed once it listens" {
    const S = struct { x: u8 = 0 };
    const opts: Options = .{ .role = .host, .address = "0.0.0.0:8080", .build = protocol.buildId("test"), .data = @splat(1), .log = false };
    var np = try Netplay.init(std.testing.allocator, opts, canonical.diffFn(S));
    defer np.deinit();
    try std.testing.expectEqual(@as(?u16, 8080), np.port());
    try np.setPort(27015);
    try std.testing.expectEqualStrings("0.0.0.0:27015", np.address);
    np.listening = true;
    try np.setPort(9000);
    try std.testing.expectEqual(@as(?u16, 27015), np.port());
    var bare = try Netplay.init(std.testing.allocator, .{ .role = .host, .address = "8000", .build = opts.build, .data = opts.data, .log = false }, canonical.diffFn(S));
    defer bare.deinit();
    try bare.setPort(8001);
    try std.testing.expectEqualStrings("8001", bare.address);
    var page = try Netplay.init(std.testing.allocator, .{ .role = .host, .address = "", .build = opts.build, .data = opts.data, .log = false }, canonical.diffFn(S));
    defer page.deinit();
    try std.testing.expectEqual(@as(?u16, null), page.port());
}

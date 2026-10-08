//! Network play as the game drives it (DESIGN.md 9): the sessions of the protocol (session.zig)
//! over the platform's transport.
//!
//! - **The host** keeps a session for each client that connects (`Peer`), up to `max_clients`:
//!   in its menu, its player (one at a time, in lockstep with the host's game: `player`), or an
//!   observer. It listens once its session opens (`open`, NETWORK PLAY's START; a page behind a
//!   relay has its connections brought by the page). The game gives the host's status
//!   (`setStatus`: the driver adds whether the session is open, a place free, observers taken and
//!   the same character allowed), takes a join (`joinAsked`, then `begin` or `needCharacter`) or a
//!   wish to watch (`observeAsked`, then `beginObserve`), gives each tick's pads to the observers
//!   (`observed`) and its game again when it changed otherwise (`resync`), and ends the player's
//!   session (`end`). A player whose connection comes back (its hello names the session) takes
//!   up its session again.
//! - **A client** connects as it starts, and again every second while it is apart: it is in the
//!   host's lobby from then on. Its game asks to join (`askJoin`) or to watch (`askObserve`,
//!   `stopObserve`), and hears the host's status (`hostStatus`).
//! - **The session in play** (the host's with its player, the client's with its host) gives each
//!   display tick's pads (`pads`), the tick's end (`ran`) and the state checks (`checkDue`,
//!   `check`); what happened comes to the game as notes (`pending`, which the game clears), the
//!   notes of that session alone.
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

/// A client of the host (on a client: its host), its connection and its session.
pub const Peer = struct {
    connection: ?platform.ConnectionId = null,
    session: Session,
};

/// What a client of the host does, as the host lists it.
pub const Doing = enum { menu, player, observing };

/// A client of the host as its screens list it.
pub const Entry = struct { name: protocol.Name, doing: Doing };

pub const Netplay = struct {
    allocator: std.mem.Allocator,
    role: Role,
    address: []u8,
    log_enabled: bool,
    config: session_mod.Config,
    diff: canonical.DiffFn,
    /// The host's clients; a client's host, always there (index 0).
    peers: std.ArrayList(*Peer) = .empty,
    /// The host: the client that plays (in a session), if any.
    player: ?*Peer = null,
    /// The host's session is open (NETWORK PLAY's START), and what it takes.
    open: bool = false,
    observers: bool = false,
    same_character: bool = false,
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
    /// A refused connection was logged (the client retries quietly until one opens).
    refused_logged: bool = false,
    now_ns: u64 = 0,
    /// The first differing field of a mismatch, once the peers compared their states.
    difference: ?canonical.Difference = null,
    /// What happened since the game last looked, in order.
    notes: std.ArrayList(Note) = .empty,
    /// Sessions started so far (a count for the checks).
    sessions: u32 = 0,
    /// The seconds of a player's drop last said to the others.
    away_said: u8 = 0,

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
        if (self.player == peer) self.player = null;
        self.destroyPeer(peer);
    }

    fn peerOf(self: *const Netplay, connection: platform.ConnectionId) ?*Peer {
        for (self.peers.items) |peer| if (peer.connection == connection) return peer;
        return null;
    }

    /// The session of play: the host's with its player, the client's with its host.
    fn main(self: *const Netplay) ?*Session {
        return switch (self.role) {
            .host => if (self.player) |p| &p.session else null,
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
    pub fn openSession(self: *Netplay, p: *platform.Platform, observers: bool, same_character: bool) platform.NetError!void {
        if (self.role != .host) return;
        if (self.address.len != 0 and !self.listening) {
            try p.netListen(self.address);
            self.listening = true;
            if (self.log_enabled) log.info("hosting at {s}", .{self.address});
        }
        self.open = true;
        self.observers = observers;
        self.same_character = same_character;
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

    /// The host's session closes (its game went back to the menu): its clients stay, apart.
    pub fn closeSession(self: *Netplay, p: *platform.Platform) void {
        if (!self.open) return;
        self.open = false;
        for (self.peers.items) |peer| if (peer.session.phase == .observing) {
            peer.session.phase = .lobby;
        };
        self.sendStatus(p);
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
                    self.refused_logged = false;
                    if (self.log_enabled) log.info("connected to the host", .{});
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
                // A player whose connection came back: its hello names the session it plays.
                if (self.role == .host and peer != self.player) if (self.player) |pl| {
                    if (pl.connection == null and pl.session.phase == .playing) if (protocol.decode(m.bytes)) |msg| switch (msg) {
                        .hello => |h| if (h.session == pl.session.id) {
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
        const verdict = peer.session.receive(bytes, self.now_ns);
        switch (verdict) {
            .malformed, .conflict, .unexpected, .ahead => if (self.log_enabled) log.warn("a message from {s}: {s}", .{ if (self.role == .host) "a client" else "the host", @tagName(verdict) }),
            else => {},
        }
        // A client's status: the host tells it what it is once it is welcomed.
        if (self.role == .host and peer.session.welcomed and peer.session.phase == .lobby) peer.session.setStatus(self.statusFor());
        self.flush(p, peer);
        self.takeNotes(peer);
        return true;
    }

    fn lost(self: *Netplay, peer: *Peer, reason: platform.DisconnectReason) void {
        const was_playing = peer.session.phase == .playing and !peer.session.peer_left;
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
            } else log.info("the connection ended ({s})", .{@tagName(reason)});
        }
        self.takeNotes(peer);
        switch (self.role) {
            // The host keeps a player's session while it may come back; a client in its menu or
            // watching goes.
            .host => if (!(peer == self.player and peer.session.phase == .playing)) self.removePeer(peer),
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
                    const gone = self.role == .host and !(peer == self.player and peer.session.phase == .playing);
                    self.lost(peer, .closed);
                    if (gone) continue;
                }
            }
            i += 1;
        }
    }

    /// The player's dropped connection, counted down to the others in seconds, once a second.
    fn sayAway(self: *Netplay, p: *platform.Platform) void {
        const seconds: u8 = if (self.lostFor()) |t| @intCast((session_mod.rejoin_ns -| t + std.time.ns_per_s - 1) / std.time.ns_per_s) else 0;
        if (seconds == self.away_said) return;
        self.away_said = seconds;
        for (self.peers.items) |peer| if (peer != self.player) {
            peer.session.sayAway(seconds);
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

    /// A peer's notes, logged; those of the session of play (or the client's) for the game. The
    /// host's player whose session ended is a client in its menu again (or goes, its connection
    /// down).
    fn takeNotes(self: *Netplay, peer: *Peer) void {
        const for_game = self.role == .guest or peer == self.player;
        var ended = false;
        for (peer.session.notes.items) |n| {
            self.logNote(peer, n);
            if (!for_game) continue;
            switch (n) {
                .started => |s| {
                    if (!s.resumed) self.sessions += 1;
                },
                .diagnosed => |d| self.difference = d,
                .ended => ended = true,
                else => {},
            }
            self.notes.append(self.allocator, n) catch {};
        }
        peer.session.notes.clearRetainingCapacity();
        if (ended and self.role == .host and peer == self.player and !peer.session.inSession()) {
            self.player = null;
            if (peer.connection == null) self.removePeer(peer);
        }
    }

    fn logNote(self: *const Netplay, peer: *const Peer, n: Note) void {
        if (!self.log_enabled) return;
        const s = &peer.session;
        const who: []const u8 = if (self.role == .host) &s.peer_name else "the host";
        switch (n) {
            .welcomed => log.info("{s} welcomed: input delay {d} ticks", .{ if (self.role == .host) who else "this client", s.delay }),
            .started => |st| if (st.resumed) {
                log.info("the session resumes at tick {d}", .{st.tick});
            } else log.info("a session starts: the host's game{s}, input delay {d} ticks", .{ if (self.role == .host) "" else ", loaded", st.delay }),
            .joined => log.info("the host's game is in ({d} bytes)", .{s.gameForm().len}),
            .join_asked => |c| log.info("{s} asks to join{s}{s}", .{ who, if (c == protocol.no_character) "" else " as ", if (c == protocol.no_character) "" else characterName(c) }),
            .observe_asked => log.info("{s} asks to watch", .{who}),
            .observing => log.info("watching the host's game ({d} bytes)", .{s.gameForm().len}),
            .away => |sec| log.debug("the player's connection is down: {d} s left", .{sec}),
            .status => |st| log.debug("the host's game: {s}", .{@tagName(st.game)}),
            .refused => |r| {
                if (s.phase == .playing) {
                    log.info("the host still has the old connection; trying again", .{});
                } else log.err("refused: {s}", .{refusal(r)});
            },
            .desync => |t| log.err("the games differ at tick {d}: {s}", .{ t, if (s.phase == .desynced and self.role == .guest and s.observe_asked == false) "the game stops" else "both stop; comparing their states" }),
            .diagnosed => |d| if (d) |x| log.err("first difference: {f}", .{x}) else log.err("the states could not be compared", .{}),
            .left => |r| log.info("{s} left ({s})", .{ if (self.role == .host) who else "the host", @tagName(r) }),
            .ended => |e| log.info("{s} ended ({s})", .{ if (peer == self.player or self.role == .guest) "the session" else "a client's watch", @tagName(e) }),
            .settings => |open| if (open) {
                log.info("the other player is on the settings screen: the game holds", .{});
            } else log.info("the other player left the settings screen", .{}),
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
        s.place = self.open and self.player == null;
        s.observers = self.open and self.observers;
        s.same_character = self.same_character;
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

    /// The host: a client that asks to join while a place is free, and its character.
    pub fn joinAsked(self: *const Netplay) ?struct { peer: *Peer, character: u8 } {
        if (self.role != .host or !self.open or self.player != null) return null;
        for (self.peers.items) |peer| if (peer.session.phase == .lobby) if (peer.session.join_asked) |c| {
            return .{ .peer = peer, .character = c };
        };
        return null;
    }

    /// The host's game takes `peer` as its player: a session from the host's game's form now.
    pub fn begin(self: *Netplay, p: *platform.Platform, peer: *Peer, form: []const u8) void {
        self.player = peer;
        peer.session.begin(form, self.now_ns);
        self.flush(p, peer);
        self.takeNotes(peer);
        self.sendStatus(p);
    }

    /// The host's game cannot take `peer` without a character: it chooses first.
    pub fn needCharacter(self: *Netplay, p: *platform.Platform, peer: *Peer) void {
        peer.session.needCharacter();
        self.flush(p, peer);
    }

    /// The host: a client that asks to watch, when the session takes observers.
    pub fn observeAsked(self: *const Netplay) ?*Peer {
        if (self.role != .host or !self.open or !self.observers) return null;
        for (self.peers.items) |peer| if (peer.session.phase == .lobby and peer.session.observe_asked) return peer;
        return null;
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

    /// The host's game ran a tick with `pads`: its observers get them, at once.
    pub fn observed(self: *Netplay, p: *platform.Platform, pads_: input.Pads) void {
        for (self.peers.items) |peer| if (peer.session.phase == .observing) {
            peer.session.observed(pads_);
            peer.session.flushTicks();
            self.flush(p, peer);
        };
    }

    /// The clients of the host, as its screens list them.
    pub fn roster(self: *const Netplay, out: []Entry) []Entry {
        var n: usize = 0;
        for (self.peers.items) |peer| {
            if (n == out.len) break;
            if (!peer.session.welcomed and peer != self.player) continue;
            out[n] = .{ .name = peer.session.peer_name, .doing = if (peer == self.player) .player else if (peer.session.phase == .observing) .observing else .menu };
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
    /// local player's pad.
    pub fn pads(self: *Netplay, p: *platform.Platform, local: input.Pad) ?input.Pads {
        const s = self.main() orelse return null;
        const merged = s.pads(local);
        // Read before the notes, which may let the host's player go.
        const playing = s.phase == .playing;
        const next = s.next;
        self.flushAll(p);
        if (self.role == .host) self.takeNotes(self.player.?) else self.takeNotes(self.hostPeer());
        if (merged == null) {
            if (self.held_since == null) {
                self.held_since = self.now_ns;
                self.hold_logged = false;
            } else if (!self.hold_logged and self.now_ns -| self.held_since.? >= hold_log_ns and playing) {
                self.hold_logged = true;
                if (self.log_enabled) log.info("holding at tick {d}: waiting for the other player's pads", .{next});
            }
        } else {
            if (self.hold_logged and self.log_enabled) log.info("going on after {d} ms", .{(self.now_ns -| self.held_since.?) / std.time.ns_per_ms});
            self.held_since = null;
            self.hold_logged = false;
        }
        return merged;
    }

    /// The tick that `pads` gave the pads of ran.
    pub fn ran(self: *Netplay) void {
        if (self.main()) |s| s.ran();
    }

    /// Whether the state before the next tick is due for a check (then give it to `check`): the
    /// session's, or an observer's.
    pub fn checkDue(self: *const Netplay) bool {
        if (self.main()) |s| if (s.checkDue()) return true;
        for (self.peers.items) |peer| if (peer.session.observerCheckDue()) return true;
        return false;
    }

    /// The state's hash and its canonical form, before the next tick.
    pub fn check(self: *Netplay, p: *platform.Platform, hash: u64, form: []const u8) void {
        if (self.main()) |s| if (s.checkDue()) s.check(hash, form);
        for (self.peers.items) |peer| peer.session.observerHash(hash);
        self.flushAll(p);
        if (self.main() != null) self.takeNotes(if (self.role == .host) self.player.? else self.hostPeer());
    }

    /// The next tick of the session.
    pub fn tick(self: *const Netplay) u32 {
        const s = self.main() orelse return 0;
        return s.next;
    }

    pub fn phase(self: *const Netplay) session_mod.Phase {
        const s = self.main() orelse return if (self.open) .lobby else .idle;
        return s.phase;
    }

    /// Whether a session runs (held or not, stopped at a mismatch), or the client watches.
    pub fn inSession(self: *const Netplay) bool {
        const s = self.main() orelse return false;
        return s.inSession();
    }

    /// The input delay of the session of play.
    pub fn delay(self: *const Netplay) u8 {
        const s = self.main() orelse return 0;
        return s.delay;
    }

    /// Whether the session of play's connection is up.
    pub fn connected(self: *const Netplay) bool {
        const s = self.main() orelse return false;
        return s.connected;
    }

    /// How long the session's connection has been down (null: it is up, or no session).
    pub fn lostFor(self: *const Netplay) ?u64 {
        const s = self.main() orelse return null;
        return s.lostFor(self.now_ns);
    }

    /// The session of play ends on this machine (its game ended, or a player that did not come
    /// back): the host's player is a client in its menu again (or goes, its connection down).
    pub fn end(self: *Netplay, p: *platform.Platform, why: session_mod.End) void {
        const s = self.main() orelse return;
        s.end(why);
        self.flushAll(p);
        if (self.role == .host) {
            self.takeNotes(self.player.?);
            self.sendStatus(p);
        } else self.takeNotes(self.hostPeer());
    }

    /// Our player opened the settings screen (`open`) or closed it: the other player is told.
    pub fn inSettings(self: *Netplay, p: *platform.Platform, open: bool) void {
        const s = self.main() orelse return;
        if (open == s.local_settings) return;
        s.inSettings(open);
        self.flushAll(p);
    }

    /// Whether the other player is on the settings screen, as it said on the live connection.
    pub fn peerInSettings(self: *const Netplay) bool {
        const s = self.main() orelse return false;
        return s.connected and s.peer_settings;
    }

    /// The stretch of the sound for the clock balancing, in parts per million.
    pub fn stretchPpm(self: *const Netplay) u32 {
        const s = self.main() orelse return 0;
        return s.stretchPpm();
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

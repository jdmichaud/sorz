//! Network play as the game drives it (DESIGN.md 9): the session (session.zig) over the
//! platform's transport. The host listens from the start and keeps one guest at a time; the
//! guest connects when its player wants to join (`want`), and while it does, connects again every
//! second after a lost connection, so that a session in play resumes. The game gives the host's
//! status (`setStatus`), the guest's wish to join (`askJoin`), the host's game when it takes the
//! guest (`begin`), and, in a session, asks for each display tick's pads (`pads`), tells when the
//! tick ran (`ran`) and gives the state's hash and canonical form when a check is due (`checkDue`,
//! `check`); what happened comes to the game as notes (`notes`, which the game clears).
//!
//! What happens is logged (`std.log`, scope `netplay`): the connection, the welcome and its delay,
//! the sessions, the holds, a refusal, a mismatch and its first differing field.
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
    /// The host's `[ADDRESS:]PORT`, or the guest's `ws://ADDRESS:PORT`. Empty when the platform
    /// brings the connection itself (a browser page behind the relay server, PLAN A2): the
    /// driver then neither listens nor connects, and takes the first connection as its peer.
    address: []const u8,
    build: protocol.Build,
    data: protocol.DataId,
    /// The host's input delay (2 to 6) instead of the round trip's.
    delay: ?u8 = null,
    /// Whether to log what happens.
    log: bool = true,
};

/// The guest's pause between two attempts to connect.
pub const reconnect_ns: u64 = std.time.ns_per_s;
/// A hold this long is logged (once per hold).
const hold_log_ns: u64 = std.time.ns_per_s / 2;
/// Messages waiting for room in the transport's queue before the connection is given up.
const max_backlog = 1024;

pub const Netplay = struct {
    allocator: std.mem.Allocator,
    role: Role,
    address: []u8,
    log_enabled: bool,
    session: Session,
    /// The peer's connection (the guest's, while it connects too).
    peer: ?platform.ConnectionId = null,
    started: bool = false,
    /// The guest's player wants to join: the guest connects, and connects again after a loss.
    wanted: bool = false,
    /// The guest's next attempt to connect.
    reconnect_at: ?u64 = null,
    /// The time the current hold began, and whether it was logged.
    held_since: ?u64 = null,
    hold_logged: bool = false,
    /// A refused connection was logged (the guest retries quietly until one opens).
    refused_logged: bool = false,
    now_ns: u64 = 0,
    /// The first differing field of a mismatch, once the peers compared their states.
    difference: ?canonical.Difference = null,
    /// What happened since the game last looked, in order.
    notes: std.ArrayList(Note) = .empty,
    /// Sessions started so far (a count for the checks).
    sessions: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options, diff: canonical.DiffFn) error{OutOfMemory}!Netplay {
        const address = try allocator.dupe(u8, options.address);
        errdefer allocator.free(address);
        return .{
            .allocator = allocator,
            .role = options.role,
            .address = address,
            .log_enabled = options.log,
            .session = try Session.init(allocator, .{ .role = options.role, .build = options.build, .data = options.data, .delay = options.delay }, diff),
        };
    }

    pub fn deinit(self: *Netplay) void {
        self.notes.deinit(self.allocator);
        self.session.deinit();
        self.allocator.free(self.address);
        self.* = undefined;
    }

    /// The host listens (its failure to is the caller's to report); the guest waits for its
    /// player to want to join.
    pub fn start(self: *Netplay, p: *platform.Platform) platform.NetError!void {
        if (self.started) return;
        self.now_ns = p.nowNs();
        self.started = true;
        if (self.address.len == 0) return;
        errdefer self.started = false;
        switch (self.role) {
            .host => {
                try p.netListen(self.address);
                if (self.log_enabled) log.info("hosting at {s}; waiting for a guest", .{self.address});
            },
            // The URL is checked now; the connection comes when the player wants to join.
            .guest => _ = try platform.WsUrl.parse(self.address),
        }
    }

    /// The guest's player wants to join (or no longer does): it connects at once, and again after
    /// a lost connection while it does.
    pub fn want(self: *Netplay, p: *platform.Platform, yes: bool) void {
        if (self.role != .guest or yes == self.wanted) return;
        self.wanted = yes;
        if (yes and self.peer == null and self.address.len != 0 and self.session.phase != .ended) self.connect(p);
    }

    fn connect(self: *Netplay, p: *platform.Platform) void {
        self.reconnect_at = null;
        self.peer = p.netConnect(self.address) catch |err| {
            if (self.log_enabled) log.warn("cannot connect to {s}: {s}", .{ self.address, @errorName(err) });
            self.reconnect_at = self.now_ns + reconnect_ns;
            return;
        };
    }

    /// Takes a platform event if it is the transport's; returns whether it was.
    pub fn handle(self: *Netplay, p: *platform.Platform, e: platform.Event) bool {
        self.now_ns = @max(self.now_ns, e.time_ns);
        switch (e.payload) {
            .net_connected => |c| {
                if (self.role == .host) {
                    if (self.peer != null) {
                        // One guest at a time.
                        var buf: [protocol.max_len]u8 = undefined;
                        p.netSend(c.connection, protocol.encode(.{ .reject = .busy }, &buf)) catch {};
                        p.netClose(c.connection);
                        if (self.log_enabled) log.info("a second guest was turned away", .{});
                        return true;
                    }
                    self.peer = c.connection;
                } else if (self.address.len == 0 and self.peer == null) {
                    self.peer = c.connection;
                } else if (self.peer != c.connection) {
                    p.netClose(c.connection);
                    return true;
                }
                self.refused_logged = false;
                if (self.log_enabled) log.info("{s} connected", .{if (self.role == .host) "a guest" else "the host"});
                self.session.connectedAt(self.now_ns);
                self.flush(p);
            },
            .net_disconnected => |d| {
                if (self.peer != d.connection) return true;
                self.lost(d.reason);
            },
            .net_received => |m| {
                if (self.peer != m.connection) return true;
                const verdict = self.session.receive(m.bytes, self.now_ns);
                switch (verdict) {
                    .malformed, .conflict, .unexpected, .ahead => if (self.log_enabled) log.warn("a message from the peer: {s}", .{@tagName(verdict)}),
                    else => {},
                }
                self.flush(p);
                self.takeNotes();
            },
            else => return false,
        }
        return true;
    }

    fn lost(self: *Netplay, reason: platform.DisconnectReason) void {
        const was_playing = self.session.phase == .playing and !self.session.peer_left;
        self.peer = null;
        self.session.disconnected(self.now_ns);
        if (self.log_enabled) {
            if (was_playing) {
                log.warn("the connection is lost ({s}); the game holds until {s}", .{
                    @tagName(reason), if (self.role == .host) "the guest reconnects" else "it is back",
                });
            } else if (reason == .refused) {
                if (!self.refused_logged) log.info("no host at {s} yet; trying every second", .{self.address});
                self.refused_logged = true;
            } else log.info("the connection ended ({s})", .{@tagName(reason)});
        }
        if (self.role == .guest and self.reconnects()) self.reconnect_at = self.now_ns + reconnect_ns;
        self.takeNotes();
    }

    /// Whether the guest connects again after a loss: its player wants to join, or a session
    /// waits for it.
    fn reconnects(self: *const Netplay) bool {
        return self.address.len != 0 and self.session.phase != .ended and (self.wanted or self.session.phase == .playing);
    }

    /// Once per update, after the events: the session's timers, the guest's reconnection, the
    /// notes, and the messages still to send.
    pub fn update(self: *Netplay, p: *platform.Platform) void {
        self.now_ns = @max(self.now_ns, p.nowNs());
        if (!self.started) return;
        self.session.tick(self.now_ns);
        if (self.role == .guest and self.peer == null) {
            if (self.reconnect_at) |t| if (self.now_ns >= t and self.reconnects()) self.connect(p);
        }
        self.flush(p);
        self.takeNotes();
        if (self.session.close_requested) {
            if (self.peer) |id| {
                p.netClose(id);
                self.lost(.closed);
            }
            self.session.close_requested = false;
        }
    }

    /// Sends the session's messages in order; those that find the queue full wait for the next
    /// update, and a backlog that keeps growing gives the connection up.
    fn flush(self: *Netplay, p: *platform.Platform) void {
        const out = &self.session.outbox;
        var sent: usize = 0;
        if (self.peer) |id| {
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
            if (self.log_enabled) log.warn("the peer does not take its messages; the connection is given up", .{});
            if (self.peer) |id| p.netClose(id);
            self.lost(.lost);
        }
    }

    /// The session's notes, logged, for the game.
    fn takeNotes(self: *Netplay) void {
        for (self.session.notes.items) |n| {
            self.logNote(n);
            switch (n) {
                .started => |s| {
                    if (!s.resumed) self.sessions += 1;
                },
                .diagnosed => |d| self.difference = d,
                else => {},
            }
            self.notes.append(self.allocator, n) catch {};
        }
        self.session.notes.clearRetainingCapacity();
    }

    fn logNote(self: *const Netplay, n: Note) void {
        if (!self.log_enabled) return;
        switch (n) {
            .welcomed => log.info("welcomed: input delay {d} ticks", .{self.session.delay}),
            .started => |s| if (s.resumed) {
                log.info("the session resumes at tick {d}", .{s.tick});
            } else log.info("a session starts: the {s} game, input delay {d} ticks", .{ if (self.role == .host) "host's" else "host's, loaded", s.delay }),
            .joined => log.info("the host's game is in ({d} bytes)", .{self.session.gameForm().len}),
            .join_asked => |c| log.info("the guest asks to join{s}{s}", .{ if (c == protocol.no_character) "" else " as ", if (c == protocol.no_character) "" else characterName(c) }),
            .status => |s| log.debug("the host's game: {s}", .{@tagName(s.game)}),
            .refused => |r| {
                if (self.session.phase == .playing) {
                    log.info("the host still has the old connection; trying again", .{});
                } else log.err("refused: {s}", .{refusal(r)});
            },
            .desync => |t| log.err("the games differ at tick {d}: both stop; comparing their states", .{t}),
            .diagnosed => |d| if (d) |x| log.err("first difference: {f}", .{x}) else log.err("the states could not be compared", .{}),
            .left => |r| log.info("the other player left ({s})", .{@tagName(r)}),
            .ended => |e| log.info("the session ended ({s})", .{@tagName(e)}),
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
            .busy => "the host already has a guest",
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

    // --- the lobby and the join ------------------------------------------------------------

    /// The host's game, as the guest hears it (when welcomed).
    pub fn setStatus(self: *Netplay, p: *platform.Platform, s: protocol.Status) void {
        self.session.setStatus(s);
        self.flush(p);
    }

    pub fn askJoin(self: *Netplay, p: *platform.Platform, character: u8) void {
        self.session.askJoin(character);
        self.flush(p);
    }

    pub fn needCharacter(self: *Netplay, p: *platform.Platform) void {
        self.session.needCharacter();
        self.flush(p);
    }

    /// The host's game takes the guest: a session from the host's game's form now.
    pub fn begin(self: *Netplay, p: *platform.Platform, form: []const u8) void {
        self.session.begin(form, self.now_ns);
        self.flush(p);
        self.takeNotes();
    }

    /// The session ends on this machine (its game ended, or a guest that did not come back).
    pub fn end(self: *Netplay, p: *platform.Platform, why: session_mod.End) void {
        self.session.end(why);
        self.flush(p);
        self.takeNotes();
    }

    // --- the session's ticks ---------------------------------------------------------------

    /// The pads of the next tick of the session, or null while the game must hold. `local` is the
    /// local player's pad.
    pub fn pads(self: *Netplay, p: *platform.Platform, local: input.Pad) ?input.Pads {
        const merged = self.session.pads(local);
        self.flush(p);
        self.takeNotes();
        if (merged == null) {
            if (self.held_since == null) {
                self.held_since = self.now_ns;
                self.hold_logged = false;
            } else if (!self.hold_logged and self.now_ns -| self.held_since.? >= hold_log_ns and self.session.phase == .playing) {
                self.hold_logged = true;
                if (self.log_enabled) log.info("holding at tick {d}: waiting for the other player's pads", .{self.session.next});
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
        self.session.ran();
    }

    /// Whether the state before the next tick is due for a check (then give it to `check`).
    pub fn checkDue(self: *const Netplay) bool {
        return self.session.checkDue();
    }

    /// The state's hash and its canonical form, before the next tick.
    pub fn check(self: *Netplay, p: *platform.Platform, hash: u64, form: []const u8) void {
        self.session.check(hash, form);
        self.flush(p);
        self.takeNotes();
    }

    /// The next tick of the session.
    pub fn tick(self: *const Netplay) u32 {
        return self.session.next;
    }

    pub fn phase(self: *const Netplay) session_mod.Phase {
        return self.session.phase;
    }

    /// Whether a session runs (held or not, stopped at a mismatch).
    pub fn inSession(self: *const Netplay) bool {
        return self.session.inSession();
    }

    /// How long the session's connection has been down (null: it is up, or no session).
    pub fn lostFor(self: *const Netplay) ?u64 {
        return self.session.lostFor(self.now_ns);
    }

    /// Our player opened the settings screen (`open`) or closed it: the other player is told.
    pub fn inSettings(self: *Netplay, p: *platform.Platform, open: bool) void {
        if (open == self.session.local_settings) return;
        self.session.inSettings(open);
        self.flush(p);
    }

    /// Whether the other player is on the settings screen, as it said on the live connection.
    pub fn peerInSettings(self: *const Netplay) bool {
        return self.session.connected and self.session.peer_settings;
    }

    /// The stretch of the sound for the clock balancing, in parts per million.
    pub fn stretchPpm(self: *const Netplay) u32 {
        return self.session.stretchPpm();
    }

    /// The game quits: a farewell, then the connection closes.
    pub fn quit(self: *Netplay, p: *platform.Platform) void {
        self.session.leave(.quit);
        self.flush(p);
        if (self.peer) |id| p.netClose(id);
        self.peer = null;
    }
};

//! The netplay session of one peer (DESIGN.md 9): two machines, each running its own game, whose
//! players meet in one: a host (player 1) and a guest (player 2), outside the simulation and
//! without I/O. The driver (netplay.zig) gives it the connection's events and messages, the game's
//! status, pads and state checks; it answers with the merged pads of each display tick of a
//! session, the messages to send (`outbox`) and what happened (`notes`).
//!
//! - **Handshake.** The guest connects when its player wants to join, and sends `hello`
//!   (versions, data identity, the session it had). The host pings to measure the round trip,
//!   picks the input delay D from it (2 to 6 ticks) and answers `welcome`; or, for the session it
//!   still plays after a dropped connection, `welcome` with that session, and each peer resends
//!   the pads the other lacks. Different versions or data: `reject`.
//! - **The lobby.** Welcomed, each machine plays its own game. The host says what its game is
//!   (`status`, `setStatus`); the guest asks to join (`askJoin`, with its player's character or
//!   none), and the host's game decides when (a note `join_asked`, then `begin` or `declineJoin`).
//! - **The join.** `begin` starts a session with the host's game's canonical form: a new id, its
//!   form in `game` chunks, then the session's pads; the guest gathers the chunks (a note `joined`:
//!   its game loads `gameForm`). From that tick, both run the same game.
//! - **Pads.** Before tick N runs, the peer samples its pad for tick N + D and sends it; the pads
//!   of ticks 0 to D - 1 are empty on both sides. Tick N runs once both pads for N are in; until
//!   then the game holds (`pads` returns null).
//! - **State checks.** Every `check_interval` ticks each peer sends the hash of its state's
//!   canonical form before that tick, and keeps the form. A hash that differs from the peer's stops
//!   the session (`desynced`): the peers exchange those forms and name the first differing field.
//! - **Clock balancing.** Each peer measures its slack, how many of the peer's pads it holds beyond
//!   the tick it runs, and sends it; the peer ahead (the one with less slack) stretches its sound
//!   (`stretchPpm`) until they are level.
//! - **Stats.** Every second of a session, each peer says what its game did over the last one
//!   (`sayLoad`: the driver's measure), and keeps the other's (`peer_load`).
//! - **The settings screen.** A game whose player opens it holds, and sends no pads: the other
//!   holds too once the pads it has run out (D ticks at most). Each side says when its player
//!   opens or closes the screen (`inSettings`), so that the other can tell its player why it holds
//!   (`peer_settings`); a connection that comes back or a new session says it again.
//! - **The end.** Both games end the session at the same tick, when their game ends (`end`); a
//!   peer that leaves says goodbye (`bye`), and the ticks whose pads are in run, then the session
//!   ends (a note `ended`). A dropped connection holds the session while it is down; the guest
//!   that comes back resumes it, and the host gives up after `rejoin_ns` (`lostFor`, then `end`).
//!
//! Every incoming message gets a verdict (`Verdict`), so that the tests can check duplicate,
//! stale, malformed and out-of-order messages.
const std = @import("std");
const protocol = @import("protocol.zig");
const canonical = @import("../canonical.zig");
const input = @import("../input.zig");

pub const Role = enum { host, guest };

pub const Config = struct {
    role: Role,
    build: protocol.Build,
    data: protocol.DataId,
    /// The host's input delay (2 to 6), instead of the one that the round trip gives.
    delay: ?u8 = null,
    /// The client's player's name, which its hello carries.
    name: protocol.Name = .{ ' ', ' ', ' ' },
};

/// The pads that the session keeps on each side, ticks in a ring.
pub const window = 256;
/// The peer's pads kept after their tick ran, to tell a duplicate from a conflict.
pub const keep = 128;
/// Ticks between two state checks (twice a second: a corrupted byte is found within one).
pub const check_interval = 30;
/// The pings of the handshake.
pub const handshake_pings = 4;
/// Pings while welcomed, which keep the round trip known and the connection alive.
pub const ping_interval_ns: u64 = std.time.ns_per_s;
/// A connection silent this long is dead: the driver closes it (and the guest reconnects).
pub const silence_ns: u64 = 10 * std.time.ns_per_s;
/// How long a session whose connection dropped waits for the guest to come back (DESIGN.md 9:
/// the host's game holds a few seconds).
pub const rejoin_ns: u64 = 5 * std.time.ns_per_s;
/// The largest stretch of the sound, in parts per million (0.5 %).
pub const max_stretch_ppm: u32 = 5000;
/// The ticks an observer has in hand before it starts running the host's.
pub const observe_cushion = 4;

/// A display tick's time in nanoseconds, for the input delay.
const tick_ns: u64 = @import("../sound_out.zig").tick_ps / 1000;

pub const Phase = enum {
    /// No connection: the host waits for a guest, the guest has none (yet, or any more).
    idle,
    /// A connection is up and the handshake runs.
    handshake,
    /// Welcomed: each machine plays its own game; the host's status and the guest's join cross.
    lobby,
    /// The guest asked to join, and waits for the host's game.
    joining,
    /// A session: both games run the same game in lockstep (held while the connection is down).
    playing,
    /// The client watches the host's game: the host sends its game and each tick's pads, the
    /// client runs them; no one waits for the client.
    observing,
    /// The states differed at a check: the session stopped.
    desynced,
    /// Refused: no session can come of this connection.
    ended,
};

pub const Verdict = enum {
    /// Applied.
    accepted,
    /// Already had: the same pads, a hash already compared, a chunk already received.
    duplicate,
    /// About ticks too old to matter any more.
    stale,
    /// Pads after a gap: kept until the gap fills.
    out_of_order,
    /// Pads too far ahead of the window.
    ahead,
    /// Pads that differ from the ones already had for the same ticks (the first stay).
    conflict,
    /// Not a message of the protocol.
    malformed,
    /// A message of the protocol out of place (pads outside a session, a second hello...).
    unexpected,
    /// A hello that the host refused (another version, build or data), or the host's refusal.
    refused,
};

/// Why a session ended.
pub const End = enum {
    /// The game ended on both machines (`end`).
    game_over,
    /// The peer said goodbye, and its last pads ran out.
    left,
    /// The connection dropped and did not come back in time (the guest: the host had given the
    /// session up when it came back).
    lost,
};

pub const Note = union(enum) {
    /// The handshake is done: each machine plays its own game.
    welcomed,
    /// A session starts (the host's `begin`, the guest's game joined) or resumes.
    started: struct { resumed: bool, delay: u8, tick: u32 },
    /// The guest has the host's game: its form is `gameForm`, which the guest's game loads.
    joined,
    /// The guest asks to join, as this character (`protocol.no_character`: none yet).
    join_asked: u8,
    /// The host's game changed (`status`).
    status: protocol.Status,
    /// The client asks to watch the host's game.
    observe_asked,
    /// The observer has the host's game (again): its form is `gameForm`, which it loads.
    observing,
    /// A player's dropped connection: the seconds before it leaves the game (0: over).
    away: u8,
    /// The host refused the guest, or was refused.
    refused: protocol.RejectReason,
    /// The states differed at the check before tick `tick`.
    desync: u32,
    /// The first differing field (null: the forms were the same after all, or ours was not
    /// kept).
    diagnosed: ?canonical.Difference,
    /// The peer said goodbye.
    left: protocol.ByeReason,
    /// The session ended.
    ended: End,
    /// The client's watch of the host's game ended from the host's side (the host left the game,
    /// or its connection went).
    watch_ended,
    /// The peer's player opened the settings screen (true) or closed it.
    settings: bool,
};

/// A state's canonical form, kept for a check or gathered from chunks (owned room for the
/// longest).
const Form = struct {
    bytes: []u8,
    len: u32 = 0,

    fn slice(f: *const Form) []const u8 {
        return f.bytes[0..f.len];
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    config: Config,
    diff: canonical.DiffFn,
    phase: Phase = .idle,
    /// A connection is up.
    connected: bool = false,
    /// The handshake of this connection is done: statuses, joins, pads and hashes may cross.
    welcomed: bool = false,
    /// The driver should close the connection (after a refusal, a farewell or a silence).
    close_requested: bool = false,
    /// The peer said farewell: the ticks whose pads are in still run, then the session ends.
    peer_left: bool = false,
    /// The session (0: none), and the input delay of this connection.
    id: u64 = 0,
    delay: u8 = 0,
    random: std.Random.SplitMix64 = .init(0),
    /// When the connection of a session in play dropped (the host gives up `rejoin_ns` later).
    lost_at: ?u64 = null,
    /// The client's player's name (the host's session, from its hello).
    peer_name: protocol.Name = .{ ' ', ' ', ' ' },
    /// Where the client's player is in its own game (the host's, from `where`), and where the
    /// client last said (the client's; null: not said on this connection).
    peer_where: protocol.Where = .{},
    where_said: ?protocol.Where = null,
    /// A change of the game at a tick to come (the host's player leaving or coming back): the
    /// host's, as it scheduled it, kept until the client has the pads past its tick (a resumed
    /// connection gets it again); the client's, as it heard it, and the tick of the last it made.
    event: ?protocol.Event = null,
    event_made: ?u32 = null,
    /// The client asked to watch (on both sides, until the host's game comes or it stops).
    observe_asked: bool = false,
    /// The host: the ticks of an observer's game sent so far, and the pads still to send (a pair
    /// a tick, from tick `ticks_first`).
    ticks_sent: u32 = 0,
    ticks_first: u32 = 0,
    ticks_out: [2 * protocol.max_pads]u8 = undefined,
    ticks_len: u8 = 0,
    /// The observer: the host's ticks in hand (a pair a tick, in a ring), the count of them,
    /// and whether it started running them (after `observe_cushion`).
    seen: [window][2]u8 = undefined,
    seen_count: u32 = 0,
    watching: bool = false,

    /// The host's game as the guest last heard it, and as the host last said it.
    peer_status: protocol.Status = .{},
    status_sent: ?protocol.Status = null,
    /// The host: the guest's join that its game has not answered yet.
    join_asked: ?u8 = null,
    /// The guest: the host's game gathered from its chunks (`game_chunks` the chunks in, a bit
    /// each), for the session `game_id`.
    game_form: Form,
    game_chunks: u8 = 0,
    game_id: u64 = 0,

    /// The next tick to run.
    next: u32 = 0,
    /// Local pads exist for the ticks before `local_count`, the peer's for all before
    /// `remote_count`.
    local_count: u32 = 0,
    remote_count: u32 = 0,
    /// The peer has our pads for the ticks before `peer_ack`; this connection carried them up to
    /// `sent_upto`.
    peer_ack: u32 = 0,
    sent_upto: u32 = 0,
    local: [window]u8 = @splat(0),
    remote: [window]u8 = @splat(0),
    have: std.StaticBitSet(window) = .empty,

    /// The peer's game over its last second of this session (its `load`), for the stats.
    peer_load: ?protocol.Load = null,

    /// The balancing: our slack and the peer's, in 1/256 tick.
    slack: i32 = 0,
    peer_slack: ?i32 = null,

    /// Our player is on the settings screen, and the peer's (as it last said, on this
    /// connection).
    local_settings: bool = false,
    peer_settings: bool = false,

    ping_seq: u32 = 0,
    last_ping_ns: u64 = 0,
    last_heard_ns: u64 = 0,
    /// The last round trip measured, and the handshake's pongs and largest round trip.
    rtt_ns: u64 = 0,
    handshake_pongs: u8 = 0,
    handshake_rtt_ns: u64 = 0,

    /// Our hashes of the last checks (and whether the peer's was compared), and the peer's that
    /// came before ours.
    own: [checks_kept]?Own = @splat(null),
    theirs: [checks_kept]?protocol.Hash = @splat(null),
    /// The canonical forms of the last two checks, by tick.
    snapshots: [2]?u32 = .{ null, null },
    snapshot_forms: [2]Form,
    /// After a mismatch: the tick, and the peer's form as its chunks come (`peer_chunks` the
    /// chunks in, a bit each; all of them once it is compared).
    desync_at: ?u32 = null,
    peer_form: Form,
    peer_chunks: u8 = 0,
    /// The tick of chunks that came before this peer saw the mismatch.
    early_tick: ?u32 = null,

    /// Encoded messages to send, in order (owned).
    outbox: std.ArrayList([]u8) = .empty,
    notes: std.ArrayList(Note) = .empty,

    const checks_kept = 8;
    const Own = struct { hash: protocol.Hash, compared: bool = false };
    const done_chunks: u8 = 0xFF;

    comptime {
        // The chunks of the longest form fit `peer_chunks`' bits.
        std.debug.assert(protocol.chunks(protocol.max_state_len) < 8);
    }

    pub fn init(allocator: std.mem.Allocator, config: Config, diff: canonical.DiffFn) error{OutOfMemory}!Session {
        const room = try allocator.alloc(u8, 4 * protocol.max_state_len);
        const n = protocol.max_state_len;
        return .{
            .allocator = allocator,
            .config = config,
            .diff = diff,
            .snapshot_forms = .{ .{ .bytes = room[0..n] }, .{ .bytes = room[n .. 2 * n] } },
            .peer_form = .{ .bytes = room[2 * n .. 3 * n] },
            .game_form = .{ .bytes = room[3 * n ..] },
        };
    }

    pub fn deinit(self: *Session) void {
        self.clearOutbox();
        self.outbox.deinit(self.allocator);
        self.notes.deinit(self.allocator);
        self.allocator.free(self.snapshot_forms[0].bytes.ptr[0 .. 4 * protocol.max_state_len]);
        self.* = undefined;
    }

    pub fn clearOutbox(self: *Session) void {
        for (self.outbox.items) |m| self.allocator.free(m);
        self.outbox.clearRetainingCapacity();
    }

    fn note(self: *Session, n: Note) void {
        self.notes.append(self.allocator, n) catch {};
    }

    fn send(self: *Session, m: protocol.Message) void {
        if (!self.connected) return;
        var buf: [protocol.max_len]u8 = undefined;
        const bytes = protocol.encode(m, &buf);
        const copy = self.allocator.dupe(u8, bytes) catch return;
        self.outbox.append(self.allocator, copy) catch self.allocator.free(copy);
    }

    fn hello(self: *const Session) protocol.Message {
        return .{ .hello = .{ .build = self.config.build, .data = self.config.data, .session = self.id, .resume_from = self.remote_count, .name = self.config.name } };
    }

    /// Whether a session runs (held or not), or the client watches the host's game.
    pub fn inSession(self: *const Session) bool {
        return self.phase == .playing or self.phase == .desynced or self.phase == .observing;
    }

    // --- the connection --------------------------------------------------------------------

    /// The connection to the peer is up. The guest opens the handshake.
    pub fn connectedAt(self: *Session, now_ns: u64) void {
        self.connected = true;
        self.welcomed = false;
        self.where_said = null;
        self.peer_where = .{};
        self.close_requested = false;
        self.last_heard_ns = now_ns;
        self.last_ping_ns = now_ns;
        self.handshake_pongs = 0;
        self.handshake_rtt_ns = 0;
        self.status_sent = null;
        if (self.phase == .idle or self.phase == .lobby or self.phase == .joining) self.phase = .handshake;
        if (self.config.role == .guest and self.phase != .ended) self.send(self.hello());
    }

    /// The connection is down: a session in play holds until the guest is back (or the host gives
    /// it up); without one, the machines are apart again.
    pub fn disconnected(self: *Session, now_ns: u64) void {
        self.connected = false;
        self.welcomed = false;
        self.peer_settings = false;
        self.close_requested = false;
        self.join_asked = null;
        self.game_chunks = 0;
        self.clearOutbox();
        self.observe_asked = false;
        switch (self.phase) {
            .handshake, .lobby, .joining => self.phase = .idle,
            .observing => {
                self.phase = .idle;
                self.note(.watch_ended);
            },
            // A peer that said goodbye: its last pads run, then the session ends (`pads`).
            .playing => if (!self.peer_left) {
                self.lost_at = now_ns;
            },
            else => {},
        }
    }

    /// Timers: the pings while welcomed, the silence of a dead connection. (The handshake's pings
    /// go one after the other, each on the pong of the one before.)
    pub fn tick(self: *Session, now_ns: u64) void {
        if (!self.connected) return;
        if (now_ns -| self.last_heard_ns > silence_ns) {
            self.close_requested = true;
            return;
        }
        if (self.welcomed and now_ns -| self.last_ping_ns >= ping_interval_ns) self.ping(now_ns);
    }

    /// How long the session's connection has been down (null: it is up, or there is none).
    pub fn lostFor(self: *const Session, now_ns: u64) ?u64 {
        if (self.phase != .playing) return null;
        const at = self.lost_at orelse return null;
        return now_ns -| at;
    }

    fn ping(self: *Session, now_ns: u64) void {
        self.ping_seq +%= 1;
        self.last_ping_ns = now_ns;
        self.send(.{ .ping = .{ .seq = self.ping_seq, .time_ns = now_ns } });
    }

    /// A message from the peer.
    pub fn receive(self: *Session, bytes: []const u8, now_ns: u64) Verdict {
        self.last_heard_ns = now_ns;
        const m = protocol.decode(bytes) catch {
            if (!self.welcomed) self.refuse(.malformed);
            return .malformed;
        };
        return switch (m) {
            .hello => |h| self.onHello(h, now_ns),
            .welcome => |w| self.onWelcome(w),
            .reject => |r| blk: {
                if (self.config.role != .guest or self.welcomed) break :blk .unexpected;
                // A host still busy with this guest's broken connection, or whose server is
                // stopped: the guest tries again.
                if (!(r == .busy and self.phase == .playing) and r != .stopped) self.phase = .ended;
                self.close_requested = true;
                self.note(.{ .refused = r });
                break :blk .refused;
            },
            .ping => |p| blk: {
                self.send(.{ .pong = p });
                break :blk .accepted;
            },
            .pong => |p| self.onPong(p, now_ns),
            .pads => |p| self.onPads(p),
            .hash => |h| self.onHash(h),
            .state => |s| self.onState(s),
            .settings => |open| self.onSettings(open),
            .status => |s| self.onStatus(s),
            .join => |c| self.onJoin(c),
            .game => |g| self.onGame(g),
            .observe => |yes| self.onObserve(yes),
            .ticks => |t| self.onTicks(t),
            .event => |e| self.onEvent(e),
            .load => |l| self.onLoad(l),
            .away => |seconds| blk: {
                if (self.config.role != .guest or !self.welcomed) break :blk .unexpected;
                self.note(.{ .away = seconds });
                break :blk .accepted;
            },
            // After its hello, on the same connection.
            .name => |n| blk: {
                if (self.config.role != .host) break :blk .unexpected;
                self.peer_name = n;
                break :blk .accepted;
            },
            // Back at its menu, the client's ask to join is over.
            .where => |x| blk: {
                if (self.config.role != .host) break :blk .unexpected;
                self.peer_where = x;
                if (x.at == .menu) self.join_asked = null;
                break :blk .accepted;
            },
            .bye => |r| blk: {
                self.note(.{ .left = r });
                // A player who left the game alone (`ended`): the connection stays, the client in
                // the host's lobby.
                const stays = r == .ended;
                if (!stays) self.close_requested = true;
                // The ticks whose pads are in still run; then the session is over. Stopped at a
                // mismatch, it is over at once.
                switch (self.phase) {
                    .playing => self.peer_left = true,
                    .desynced => self.over(.left),
                    else => {
                        if (self.phase == .observing) {
                            self.observe_asked = false;
                            self.note(.watch_ended);
                        }
                        self.phase = if (self.phase == .ended) .ended else if (stays and self.welcomed) .lobby else .idle;
                    },
                }
                break :blk .accepted;
            },
        };
    }

    /// The session ends: both machines play their own games again (the host waits for a guest,
    /// the guest is apart until it asks to join again).
    fn over(self: *Session, why: End) void {
        self.peer_left = false;
        self.event = null;
        self.event_made = null;
        self.lost_at = null;
        self.id = 0;
        self.next = 0;
        self.phase = if (self.connected) .lobby else .idle;
        self.status_sent = null;
        self.note(.{ .ended = why });
    }

    fn refuse(self: *Session, reason: protocol.RejectReason) void {
        if (self.config.role == .host) self.send(.{ .reject = reason });
        self.close_requested = true;
    }

    fn onHello(self: *Session, h: protocol.Hello, now_ns: u64) Verdict {
        if (self.config.role != .host or self.welcomed) return .unexpected;
        const reason: ?protocol.RejectReason = if (h.protocol != protocol.version)
            .protocol
        else if (!std.mem.eql(u8, &h.build, &self.config.build))
            .build
        else if (!std.mem.eql(u8, &h.data, &self.config.data))
            .data
        else
            null;
        if (reason) |r| {
            self.refuse(r);
            self.note(.{ .refused = r });
            return .refused;
        }
        self.peer_name = h.name;
        const resumable = h.session != 0 and h.session == self.id and self.phase == .playing and
            h.resume_from <= self.local_count and self.local_count - h.resume_from < window;
        if (resumable) {
            self.send(.{ .welcome = .{ .session = self.id, .delay = self.delay, .resume_from = self.remote_count } });
            self.resumeFrom(h.resume_from);
            return .accepted;
        }
        // A session the guest had and the host has not: given up.
        if (self.phase == .playing) self.over(.lost);
        self.phase = .handshake;
        if (self.config.delay) |d| {
            self.welcome(d);
        } else self.ping(now_ns);
        return .accepted;
    }

    fn onPong(self: *Session, p: protocol.Ping, now_ns: u64) Verdict {
        if (p.time_ns > now_ns) return .malformed;
        self.rtt_ns = now_ns - p.time_ns;
        if (self.config.role == .host and self.phase == .handshake and !self.welcomed) {
            if (p.seq != self.ping_seq) return .stale;
            self.handshake_pongs += 1;
            self.handshake_rtt_ns = @max(self.handshake_rtt_ns, self.rtt_ns);
            if (self.handshake_pongs >= handshake_pings) {
                self.welcome(delayFor(self.handshake_rtt_ns));
            } else self.ping(now_ns);
        }
        return .accepted;
    }

    /// The host welcomes the guest to its games, with the input delay of this connection.
    fn welcome(self: *Session, delay: u8) void {
        self.delay = delay;
        self.send(.{ .welcome = .{ .session = 0, .delay = delay, .resume_from = 0 } });
        self.welcomed = true;
        self.phase = .lobby;
        self.note(.welcomed);
    }

    /// A session's id, from the clock through SplitMix64, never 0 and never the last one's: a
    /// new session never takes an old one's id by chance.
    fn newId(self: *Session, now_ns: u64) u64 {
        self.random.s +%= now_ns;
        const z = self.random.next();
        return if (z == 0 or z == self.id) z +% 1 else z;
    }

    fn onWelcome(self: *Session, w: protocol.Welcome) Verdict {
        if (self.config.role != .guest or self.welcomed or !self.connected) return .unexpected;
        if (w.session == 0) {
            // The session this guest had is gone.
            if (self.phase == .playing) self.over(.lost);
            self.delay = w.delay;
            self.welcomed = true;
            self.phase = .lobby;
            self.note(.welcomed);
            return .accepted;
        }
        if (w.session != self.id or self.phase != .playing or w.delay != self.delay or
            w.resume_from > self.local_count or self.local_count - w.resume_from >= window)
        {
            return .malformed;
        }
        self.resumeFrom(w.resume_from);
        return .accepted;
    }

    // --- the lobby and the join --------------------------------------------------------------

    /// The host says what its game is, when it changed (or the guest has not heard it yet).
    pub fn setStatus(self: *Session, s: protocol.Status) void {
        if (self.config.role != .host or !self.welcomed or self.phase != .lobby) return;
        if (self.status_sent) |was| if (std.meta.eql(was, s)) return;
        self.status_sent = s;
        self.send(.{ .status = s });
    }

    /// The host's status, kept whenever it comes (a session's last ticks running out too: the
    /// host sends it as the session ends). While the client asks to join, it is the host's answer
    /// that its game does not take it now: the client is in the lobby again, and asks again as
    /// the status lets it; a wish to watch that the status no longer lets is over.
    fn onStatus(self: *Session, s: protocol.Status) Verdict {
        if (self.config.role != .guest or !self.welcomed) return .unexpected;
        self.peer_status = s;
        if (self.phase == .joining) self.phase = .lobby;
        if (self.observe_asked and self.phase == .lobby and !(s.open and s.observers and s.game != .none)) self.observe_asked = false;
        self.note(.{ .status = s });
        return .accepted;
    }

    /// The guest asks to join the host's game, as `character` (`protocol.no_character`: none, at
    /// the select).
    pub fn askJoin(self: *Session, character: u8) void {
        if (self.config.role != .guest or !self.welcomed or self.phase != .lobby) return;
        self.phase = .joining;
        self.game_chunks = 0;
        self.send(.{ .join = character });
    }

    fn onJoin(self: *Session, character: u8) Verdict {
        if (self.config.role != .host or !self.welcomed) return .unexpected;
        if (self.phase != .lobby) return .stale;
        self.join_asked = character;
        self.note(.{ .join_asked = character });
        return .accepted;
    }

    /// The host's game does not take the guest's ask now (its offer changed, or wants a character
    /// first): the ask is dropped, and the guest hears the host's status again, its answer.
    pub fn declineJoin(self: *Session) void {
        self.join_asked = null;
        if (self.status_sent) |s| self.send(.{ .status = s });
    }

    /// The host has no game for the client to watch now: its wish is dropped, and it hears the
    /// host's status again.
    pub fn declineObserve(self: *Session) void {
        self.observe_asked = false;
        if (self.status_sent) |s| self.send(.{ .status = s });
    }

    /// The host's game takes the guest: a session starts at the next tick, the guest's game
    /// loading `form`, the host's game's canonical form now.
    pub fn begin(self: *Session, form: []const u8, now_ns: u64) void {
        std.debug.assert(self.config.role == .host and self.phase == .lobby and form.len <= protocol.max_state_len);
        self.join_asked = null;
        const id = self.newId(now_ns);
        var offset: u32 = 0;
        const length: u32 = @intCast(form.len);
        while (offset < length) : (offset += protocol.chunk_size) {
            self.send(.{ .game = .{ .session = id, .delay = self.delay, .length = length, .offset = offset, .bytes = form[offset..][0..protocol.chunkLen(length, offset)] } });
        }
        self.startSession(id);
    }

    fn onGame(self: *Session, g: protocol.GameChunk) Verdict {
        if (self.config.role != .guest or !self.welcomed) return .unexpected;
        // An observer takes the host's game again; a player's game comes once.
        if (g.observe != (self.observe_asked or self.phase == .observing)) return .unexpected;
        if (!g.observe and self.inSession()) return .stale;
        if (self.game_chunks == 0 or g.session != self.game_id or g.length != self.game_form.len) {
            self.game_chunks = 0;
            self.game_id = g.session;
            self.game_form.len = g.length;
        }
        const bit: u8 = @as(u8, 1) << @intCast(g.offset / protocol.chunk_size);
        if (self.game_chunks & bit != 0) return .duplicate;
        @memcpy(self.game_form.bytes[g.offset..][0..g.bytes.len], g.bytes);
        self.game_chunks |= bit;
        const all: u8 = @intCast((@as(u16, 1) << @intCast(protocol.chunks(g.length))) - 1);
        if (self.game_chunks != all) return .accepted;
        self.game_chunks = 0;
        self.delay = g.delay;
        if (g.observe) {
            self.startWatching(g.session);
            return .accepted;
        }
        self.startSession(g.session);
        self.note(.joined);
        return .accepted;
    }

    // --- observers -------------------------------------------------------------------------

    /// The client asks to watch the host's game.
    pub fn askObserve(self: *Session) void {
        if (self.config.role != .guest or !self.welcomed or self.phase != .lobby) return;
        self.observe_asked = true;
        self.game_chunks = 0;
        self.send(.{ .observe = true });
    }

    /// The observer stops watching: back to its own game.
    pub fn stopObserve(self: *Session) void {
        if (self.config.role != .guest or !(self.phase == .observing or self.observe_asked)) return;
        self.observe_asked = false;
        if (self.phase == .observing or self.phase == .desynced) self.phase = if (self.connected) .lobby else .idle;
        self.send(.{ .observe = false });
    }

    /// This machine's player leaves the game alone (Escape), not the program: a session or a
    /// watch ends here, the peer told (`bye`, `ended`; a client's watch, `observe`), and the
    /// connection stays.
    /// With the connection down, the session ends here all the same (a peer back later is
    /// welcomed to the lobby). A client's ask to join or to watch is withdrawn.
    pub fn leaveGame(self: *Session) void {
        switch (self.phase) {
            .playing, .desynced => {
                if (self.welcomed) self.send(.{ .bye = .ended });
                self.over(.left);
            },
            .observing => if (self.config.role == .host) {
                if (self.welcomed) self.send(.{ .bye = .ended });
                self.phase = if (self.connected) .lobby else .idle;
                self.status_sent = null;
            } else self.stopObserve(),
            .joining => self.phase = .lobby,
            .lobby => if (self.observe_asked) self.stopObserve(),
            else => {},
        }
    }

    fn onObserve(self: *Session, yes: bool) Verdict {
        if (self.config.role != .host or !self.welcomed) return .unexpected;
        if (yes) {
            if (self.phase != .lobby) return .stale;
            self.observe_asked = true;
            self.note(.observe_asked);
        } else {
            self.observe_asked = false;
            if (self.phase == .observing) self.phase = .lobby;
            self.status_sent = null;
        }
        return .accepted;
    }

    /// The host sends the observer its game, `form` (its canonical form now, with its sound: a
    /// join's), from which the ticks count from 0; again whenever its game changed otherwise than
    /// by its pads.
    pub fn beginObserve(self: *Session, form: []const u8, now_ns: u64) void {
        std.debug.assert(self.config.role == .host and form.len <= protocol.max_state_len);
        if (!(self.phase == .lobby and self.observe_asked) and self.phase != .observing) return;
        self.observe_asked = false;
        self.id = self.newId(now_ns);
        var offset: u32 = 0;
        const length: u32 = @intCast(form.len);
        while (offset < length) : (offset += protocol.chunk_size) {
            self.send(.{ .game = .{ .session = self.id, .delay = protocol.min_delay, .observe = true, .length = length, .offset = offset, .bytes = form[offset..][0..protocol.chunkLen(length, offset)] } });
        }
        self.phase = .observing;
        self.ticks_sent = 0;
        self.ticks_first = 0;
        self.ticks_len = 0;
    }

    /// The host's game ran a tick with `pads`: the observer gets them (sent in runs).
    pub fn observed(self: *Session, pads_: input.Pads) void {
        if (self.config.role != .host or self.phase != .observing) return;
        if (self.ticks_len == 0) self.ticks_first = self.ticks_sent;
        self.ticks_out[self.ticks_len] = @bitCast(pads_.pad1);
        self.ticks_out[self.ticks_len + 1] = @bitCast(pads_.pad2);
        self.ticks_len += 2;
        self.ticks_sent += 1;
        if (self.ticks_len == self.ticks_out.len) self.flushTicks();
    }

    /// Sends the observer the ticks' pads in hand.
    pub fn flushTicks(self: *Session) void {
        if (self.ticks_len == 0) return;
        self.send(.{ .ticks = .{ .first = self.ticks_first, .pads = self.ticks_out[0..self.ticks_len] } });
        self.ticks_len = 0;
    }

    /// The host's state hash before the observer's tick `ticks_sent`, when it is due (every
    /// `check_interval` ticks of the observer's game).
    pub fn observerCheckDue(self: *const Session) bool {
        return self.config.role == .host and self.phase == .observing and self.ticks_sent != 0 and self.ticks_sent % check_interval == 0;
    }

    pub fn observerHash(self: *Session, hash: u64) void {
        if (!self.observerCheckDue()) return;
        self.flushTicks();
        self.send(.{ .hash = .{ .tick = self.ticks_sent, .hash = hash } });
    }

    /// The client's player gave its name again: the host hears it (a hello to come carries it).
    /// Where the client's player is in its own game: the host hears it when it changes (and on
    /// each connection, once welcomed).
    pub fn sayWhere(self: *Session, x: protocol.Where) void {
        if (self.config.role != .guest or !self.welcomed) return;
        if (self.where_said) |was| if (std.meta.eql(was, x)) return;
        self.where_said = x;
        self.send(.{ .where = x });
    }

    pub fn rename(self: *Session, name: protocol.Name) void {
        self.config.name = name;
        if (self.config.role == .guest and self.connected) self.send(.{ .name = name });
    }

    /// The host says a player's connection is down, the seconds before it leaves the game (0:
    /// over), to a client that waits for it.
    pub fn sayAway(self: *Session, seconds: u8) void {
        if (self.config.role != .host or !self.welcomed) return;
        self.send(.{ .away = seconds });
    }

    /// The observer starts from the host's game: its ticks count from 0.
    fn startWatching(self: *Session, id: u64) void {
        self.id = id;
        self.observe_asked = false;
        self.phase = .observing;
        self.next = 0;
        self.seen_count = 0;
        self.watching = false;
        self.own = @splat(null);
        self.theirs = @splat(null);
        self.snapshots = .{ null, null };
        self.desync_at = null;
        self.note(.observing);
    }

    fn onTicks(self: *Session, t: protocol.Ticks) Verdict {
        if (self.config.role != .guest or self.phase != .observing) return .unexpected;
        const count: u32 = @intCast(t.pads.len / 2);
        if (t.first + count <= self.seen_count) return .duplicate;
        if (t.first > self.seen_count) return .out_of_order;
        var i = self.seen_count - t.first;
        while (i < count) : (i += 1) {
            const tick_ = t.first + i;
            if (tick_ >= self.next + window) return .ahead;
            self.seen[tick_ % window] = .{ t.pads[2 * i], t.pads[2 * i + 1] };
            self.seen_count = tick_ + 1;
        }
        return .accepted;
    }

    /// The observer's next tick's pads, the host's: none until it has `observe_cushion` in hand,
    /// then as they come.
    fn observedPads(self: *Session) ?input.Pads {
        if (!self.watching) {
            if (self.seen_count < self.next + observe_cushion) return null;
            self.watching = true;
        }
        if (self.next >= self.seen_count) return null;
        const pair = self.seen[self.next % window];
        return .{ .pad1 = @bitCast(pair[0]), .pad2 = @bitCast(pair[1]) };
    }

    /// The host's game, which the guest's game loads (after the note `joined`).
    pub fn gameForm(self: *const Session) []const u8 {
        return self.game_form.slice();
    }

    /// Both sides start the session from the same game, with empty pads for the first `delay`
    /// ticks.
    fn startSession(self: *Session, id: u64) void {
        self.id = id;
        self.phase = .playing;
        self.event = null;
        self.event_made = null;
        self.peer_left = false;
        self.lost_at = null;
        self.next = 0;
        self.local_count = self.delay;
        self.remote_count = self.delay;
        self.peer_ack = self.delay;
        self.sent_upto = self.delay;
        self.local = @splat(0);
        self.remote = @splat(0);
        self.have = .empty;
        for (0..self.delay) |i| self.have.set(i);
        self.slack = 0;
        self.peer_slack = null;
        self.peer_load = null;
        self.own = @splat(null);
        self.theirs = @splat(null);
        self.snapshots = .{ null, null };
        self.desync_at = null;
        self.peer_chunks = 0;
        self.early_tick = null;
        if (self.local_settings) self.send(.{ .settings = true });
        self.note(.{ .started = .{ .resumed = false, .delay = self.delay, .tick = 0 } });
    }

    /// The same session goes on: the pads the peer lacks, and our recent hashes, again.
    fn resumeFrom(self: *Session, peer_has: u32) void {
        self.welcomed = true;
        self.lost_at = null;
        self.peer_ack = @max(self.peer_ack, peer_has);
        self.sent_upto = peer_has;
        // A change of the game the client may not have heard: before the pads of its tick.
        if (self.event) |e| self.send(.{ .event = e });
        self.flushPads();
        for (self.own) |h| if (h) |x| self.send(.{ .hash = x.hash });
        if (self.local_settings) self.send(.{ .settings = true });
        self.note(.{ .started = .{ .resumed = true, .delay = self.delay, .tick = self.next } });
    }

    /// The session ends here, on this machine: its game ended (both machines end at the same
    /// tick, since they run the same game), or the host gave up a guest that did not come back
    /// (`lost`).
    pub fn end(self: *Session, why: End) void {
        if (!self.inSession()) return;
        if (why == .lost and self.connected) {
            self.close_requested = true;
        }
        self.over(why);
    }

    /// The input delay for a round trip: the one-way time in ticks, rounded up, plus one.
    pub fn delayFor(rtt_ns: u64) u8 {
        const one_way = rtt_ns / 2;
        const ticks = (one_way + tick_ns - 1) / tick_ns + 1;
        return @intCast(std.math.clamp(ticks, protocol.min_delay, protocol.max_delay));
    }

    // --- the stats ---------------------------------------------------------------------------

    /// What our game did over its last second of the session: the peer is told.
    pub fn sayLoad(self: *Session, l: protocol.Load) void {
        if (self.welcomed and self.phase == .playing) self.send(.{ .load = l });
    }

    /// One that crosses the session's end is of no use any more.
    fn onLoad(self: *Session, l: protocol.Load) Verdict {
        if (!self.welcomed) return .unexpected;
        if (self.phase != .playing) return .stale;
        self.peer_load = l;
        return .accepted;
    }

    // --- the settings screen -----------------------------------------------------------------

    /// Our player opened the settings screen (`open`) or closed it: the peer is told.
    pub fn inSettings(self: *Session, open: bool) void {
        if (open == self.local_settings) return;
        self.local_settings = open;
        if (self.welcomed and self.phase == .playing) self.send(.{ .settings = open });
    }

    fn onSettings(self: *Session, open: bool) Verdict {
        if (!self.welcomed or self.phase != .playing) return .unexpected;
        if (open == self.peer_settings) return .duplicate;
        self.peer_settings = open;
        self.note(.{ .settings = open });
        return .accepted;
    }

    // --- pads ------------------------------------------------------------------------------

    fn onPads(self: *Session, p: protocol.Pads) Verdict {
        if (!self.welcomed or self.phase != .playing) return .unexpected;
        self.peer_ack = @max(self.peer_ack, @min(p.ack, self.local_count));
        self.peer_slack = p.slack;
        var result: Verdict = .stale;
        const low = self.next -| keep;
        const high = low + window;
        for (p.pads, 0..) |v, k| {
            const i = p.first + @as(u32, @intCast(k));
            const slot = i % window;
            var v_this: Verdict = undefined;
            if (i < low) {
                v_this = .stale;
            } else if (i >= high) {
                v_this = .ahead;
            } else if (self.have.isSet(slot)) {
                v_this = if (self.remote[slot] == v) .duplicate else .conflict;
            } else {
                self.remote[slot] = v;
                self.have.set(slot);
                v_this = if (i > self.remote_count) .out_of_order else .accepted;
                while (self.remote_count < high and self.have.isSet(self.remote_count % window)) self.remote_count += 1;
            }
            result = worse(result, v_this);
        }
        return result;
    }

    fn worse(a: Verdict, b: Verdict) Verdict {
        const rank = struct {
            fn of(v: Verdict) u8 {
                return switch (v) {
                    .stale => 0,
                    .duplicate => 1,
                    .accepted => 2,
                    .out_of_order => 3,
                    .ahead => 4,
                    .conflict => 5,
                    else => 6,
                };
            }
        };
        return if (rank.of(b) > rank.of(a)) b else a;
    }

    /// Sends the local pads this connection has not carried yet.
    fn flushPads(self: *Session) void {
        if (!self.welcomed) return;
        while (self.sent_upto < self.local_count) {
            const n = @min(self.local_count - self.sent_upto, protocol.max_pads);
            var run: [protocol.max_pads]u8 = undefined;
            for (0..n) |k| run[k] = self.local[(self.sent_upto + @as(u32, @intCast(k))) % window];
            self.send(.{ .pads = .{
                .first = self.sent_upto,
                .ack = self.remote_count,
                .slack = @intCast(std.math.clamp(self.slack, std.math.minInt(i16), std.math.maxInt(i16))),
                .pads = run[0..n],
            } });
            self.sent_upto += n;
        }
    }

    /// The pads of the next tick of the session, or null while it must hold. `local` is the local
    /// player's pad now: it becomes the pad of tick `next + delay`, sampled once per tick.
    pub fn pads(self: *Session, local: input.Pad) ?input.Pads {
        if (self.phase == .observing and self.config.role == .guest) return self.observedPads();
        if (self.phase != .playing) return null;
        const target = self.next + self.delay;
        if (self.local_count == target and self.local_count - self.peer_ack < window - 1) {
            self.local[target % window] = @bitCast(local);
            self.local_count += 1;
            self.flushPads();
        }
        if (self.remote_count <= self.next or self.local_count <= self.next) {
            // The peer left, and its last pads ran out.
            if (self.peer_left) self.over(.left);
            return null;
        }
        const slot = self.next % window;
        const mine: input.Pad = @bitCast(self.local[slot]);
        const theirs: input.Pad = @bitCast(self.remote[slot]);
        return switch (self.config.role) {
            .host => .{ .pad1 = mine, .pad2 = theirs },
            .guest => .{ .pad1 = theirs, .pad2 = mine },
        };
    }

    /// The host changes the game at the first tick whose pads it has not sent (`change`, its tick
    /// set here: its player leaves, or comes back, or the rules change): the client hears it
    /// before those pads. Returns the tick, or null when no session runs or a change is still to
    /// come.
    pub fn schedule(self: *Session, change: protocol.Event) ?u32 {
        if (self.config.role != .host or self.phase != .playing or self.event != null) return null;
        var e = change;
        e.tick = self.local_count;
        self.event = e;
        self.send(.{ .event = e });
        return e.tick;
    }

    fn onEvent(self: *Session, e: protocol.Event) Verdict {
        if (self.config.role != .guest or self.phase != .playing) return .unexpected;
        if (self.event) |was| if (std.meta.eql(was, e)) return .duplicate;
        // Sent again on a resumed connection, after its tick ran here.
        if (self.event_made == e.tick) return .duplicate;
        // Its tick ran already: the games would differ.
        if (e.tick < self.next or self.event != null) return .malformed;
        self.event = e;
        return .accepted;
    }

    /// The change of the game before the next tick, if any (the game makes it, then runs the
    /// tick).
    pub fn eventAt(self: *const Session) ?protocol.Event {
        const e = self.event orelse return null;
        return if (e.tick == self.next and self.phase == .playing) e else null;
    }

    /// Tick `next` ran with the pads that `pads` gave.
    pub fn ran(self: *Session) void {
        if (self.phase == .observing) {
            self.next += 1;
            return;
        }
        if (self.event) |e| if (e.tick <= self.next) switch (self.config.role) {
            // The host keeps it until the client has its pads past its tick.
            .host => if (self.peer_ack > e.tick) {
                self.event = null;
            },
            .guest => {
                self.event = null;
                self.event_made = e.tick;
            },
        };
        // The slack: the peer's pads in hand beyond this tick, averaged over about 16.
        const sample: i32 = @as(i32, @intCast(self.remote_count - self.next - 1)) * 256;
        self.slack += @divFloor(sample - self.slack, 16);
        self.next += 1;
        // The slot that leaves the window's bottom is the one its top takes next.
        if (self.next > keep) self.have.unset((self.next - keep - 1) % window);
    }

    /// How much the local peer is ahead of the other, in 1/256 tick (half the difference of the
    /// two slacks); positive when ahead.
    pub fn advantage(self: *const Session) i32 {
        const theirs = self.peer_slack orelse return 0;
        return @divFloor(theirs - self.slack, 2);
    }

    /// The stretch of the sound that brings the peers level: 0 unless this peer is ahead by more
    /// than a quarter of a tick, the whole 0.5 % from a tick and a quarter.
    pub fn stretchPpm(self: *const Session) u32 {
        if (self.phase != .playing) return 0;
        const a = self.advantage() - 64;
        if (a <= 0) return 0;
        return @intCast(@min(@as(i64, max_stretch_ppm), @divFloor(@as(i64, a) * max_stretch_ppm, 256)));
    }

    // --- state checks ----------------------------------------------------------------------

    /// Whether the state before tick `next` is due for a check.
    pub fn checkDue(self: *const Session) bool {
        const o = self.own[slotOf(self.next)];
        const runs = self.phase == .playing or (self.phase == .observing and self.config.role == .guest);
        return runs and self.next != 0 and self.next % check_interval == 0 and
            (o == null or o.?.hash.tick != self.next);
    }

    fn slotOf(t: u32) usize {
        return (t / check_interval) % checks_kept;
    }

    /// The state's hash and its canonical form before tick `next` (see `checkDue`); a form longer
    /// than the protocol carries is checked by its hash alone.
    pub fn check(self: *Session, hash: u64, form: []const u8) void {
        const t = self.next;
        const s = (t / check_interval) % 2;
        if (form.len <= protocol.max_state_len) {
            @memcpy(self.snapshot_forms[s].bytes[0..form.len], form);
            self.snapshot_forms[s].len = @intCast(form.len);
            self.snapshots[s] = t;
        } else self.snapshots[s] = null;
        const h: protocol.Hash = .{ .tick = t, .hash = hash };
        self.own[slotOf(t)] = .{ .hash = h };
        // An observer checks against the host's hashes and sends none.
        if (self.phase != .observing) self.send(.{ .hash = h });
        if (self.theirs[slotOf(t)]) |x| {
            if (x.tick == t) {
                self.theirs[slotOf(t)] = null;
                self.own[slotOf(t)].?.compared = true;
                if (x.hash != hash) self.mismatch(t);
            }
        }
    }

    fn onHash(self: *Session, h: protocol.Hash) Verdict {
        if (!self.welcomed) return .unexpected;
        if (h.tick == 0 or h.tick % check_interval != 0) return .malformed;
        const checks = self.phase == .playing or (self.phase == .observing and self.config.role == .guest);
        if (!checks) return if (self.phase == .desynced) .stale else .unexpected;
        const slot = slotOf(h.tick);
        if (self.own[slot]) |*o| {
            if (o.hash.tick == h.tick) {
                if (o.compared) return .duplicate;
                o.compared = true;
                if (o.hash.hash != h.hash) self.mismatch(h.tick);
                return .accepted;
            }
            if (o.hash.tick > h.tick) return .stale;
        }
        // Ours is still to come.
        if (h.tick < self.next) return .stale;
        if (self.theirs[slot]) |t| if (t.tick == h.tick) return if (t.hash == h.hash) .duplicate else .conflict;
        self.theirs[slot] = h;
        return .accepted;
    }

    fn mismatch(self: *Session, t: u32) void {
        const observer = self.phase == .observing;
        self.phase = .desynced;
        self.desync_at = t;
        self.note(.{ .desync = t });
        // An observer's game stops; the host's goes on, and no form crosses.
        if (observer) {
            self.peer_chunks = done_chunks;
            self.note(.{ .diagnosed = null });
            return;
        }
        // Our form of that tick, for the peer's diagnosis. Without it (longer than the protocol
        // carries, or a later check's in its place) there is nothing to compare: chunks that come
        // are not taken, and the note says so.
        const s = (t / check_interval) % 2;
        if (self.snapshots[s] != t) {
            self.early_tick = null;
            self.peer_chunks = done_chunks;
            self.note(.{ .diagnosed = null });
            return;
        }
        const form = self.snapshot_forms[s].slice();
        const length: u32 = @intCast(form.len);
        var offset: u32 = 0;
        while (offset < length) : (offset += protocol.chunk_size) {
            self.send(.{ .state = .{ .tick = t, .length = length, .offset = offset, .bytes = form[offset..][0..protocol.chunkLen(length, offset)] } });
        }
        self.diagnose();
    }

    fn onState(self: *Session, s: protocol.State) Verdict {
        if (self.desync_at) |t| if (s.tick != t) return .unexpected;
        // Before this peer saw the mismatch (the peer's hash is on its way), the chunk is kept for
        // the tick it names; chunks of another tick start the form again.
        if (self.desync_at == null) {
            if (self.phase != .playing) return .unexpected;
            if (self.early_tick != s.tick) self.peer_chunks = 0;
            self.early_tick = s.tick;
        }
        if (self.peer_chunks == done_chunks) return .duplicate;
        if (self.peer_chunks != 0 and s.length != self.peer_form.len) return .unexpected;
        const bit: u8 = @as(u8, 1) << @intCast(s.offset / protocol.chunk_size);
        if (self.peer_chunks & bit != 0) return .duplicate;
        self.peer_form.len = s.length;
        @memcpy(self.peer_form.bytes[s.offset..][0..s.bytes.len], s.bytes);
        self.peer_chunks |= bit;
        self.diagnose();
        return .accepted;
    }

    fn diagnose(self: *Session) void {
        const t = self.desync_at orelse return;
        if (self.early_tick != null and self.early_tick.? != t) self.peer_chunks = 0;
        self.early_tick = null;
        if (self.peer_chunks == done_chunks or self.peer_chunks == 0) return;
        const all: u8 = @intCast((@as(u16, 1) << @intCast(protocol.chunks(self.peer_form.len))) - 1);
        if (self.peer_chunks != all) return;
        self.peer_chunks = done_chunks;
        const s = (t / check_interval) % 2;
        if (self.snapshots[s] != t) return self.note(.{ .diagnosed = null });
        self.note(.{ .diagnosed = self.diff(self.snapshot_forms[s].slice(), self.peer_form.slice()) });
    }

    /// The farewell of a game that quits.
    pub fn leave(self: *Session, reason: protocol.ByeReason) void {
        if (self.welcomed) self.send(.{ .bye = reason });
    }
};

// --- tests -------------------------------------------------------------------------------------

const testing = std.testing;

const TestState = struct {
    x: u32 = 0,
    y: u16 = 0,
};

fn testSession(role: Role, delay: ?u8) !Session {
    return Session.init(testing.allocator, .{ .role = role, .build = protocol.buildId("test"), .data = @splat(1), .delay = delay }, canonical.diffFn(TestState));
}

/// Gives `to` every message in `from`'s outbox; returns the last verdict.
fn pump(from: *Session, to: *Session, now_ns: u64) Verdict {
    var last: Verdict = .accepted;
    for (from.outbox.items) |m| last = to.receive(m, now_ns);
    from.clearOutbox();
    return last;
}

fn encodeMsg(m: protocol.Message, buf: *[protocol.max_len]u8) []const u8 {
    return protocol.encode(m, buf);
}

/// The connection and its handshake, both in the lobby.
fn welcomePair(host: *Session, guest: *Session) !void {
    host.connectedAt(0);
    guest.connectedAt(0);
    while (host.phase != .lobby or guest.phase != .lobby) {
        _ = pump(guest, host, 1000);
        _ = pump(host, guest, 1000);
        if (host.phase == .ended or guest.phase == .ended) return error.Refused;
    }
}

/// The guest joins the host's game, whose form is `form`: both in a session.
fn joinPair(host: *Session, guest: *Session, form: []const u8) !void {
    guest.askJoin(protocol.no_character);
    try testing.expectEqual(Verdict.accepted, pump(guest, host, 1000));
    try testing.expectEqual(@as(?u8, protocol.no_character), host.join_asked);
    host.begin(form, 1000);
    _ = pump(host, guest, 1000);
    try testing.expectEqual(Phase.playing, guest.phase);
    try testing.expectEqualSlices(u8, form, guest.gameForm());
}

fn startPair(host: *Session, guest: *Session) !void {
    try welcomePair(host, guest);
    var buf: [canonical.maxSize(TestState)]u8 = undefined;
    try joinPair(host, guest, canonical.write(TestState, &.{}, &buf));
}

/// Both peers run `n` ticks in turn, each with its pad from a script.
fn runBoth(host: *Session, guest: *Session, n: u32) !void {
    for (0..n) |_| {
        const t = host.next;
        const a = host.pads(@bitCast(@as(u8, @truncate(t)))) orelse return error.Held;
        _ = pump(host, guest, 0);
        const b = guest.pads(@bitCast(@as(u8, @truncate(t *% 3)))) orelse return error.Held;
        _ = pump(guest, host, 0);
        try testing.expectEqual(a, b);
        host.ran();
        guest.ran();
    }
}

fn formOf(s: TestState, buf: *[canonical.maxSize(TestState)]u8) []const u8 {
    return canonical.write(TestState, &s, buf);
}

fn hasNote(s: *const Session, comptime tag: std.meta.Tag(Note)) bool {
    for (s.notes.items) |n| if (n == tag) return true;
    return false;
}

test "an observer: it asks, takes the host's game, then runs its ticks behind; hashes checked" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var watcher = try Session.init(testing.allocator, .{ .role = .guest, .build = protocol.buildId("test"), .data = @splat(1), .name = "ANN".* }, canonical.diffFn(TestState));
    defer watcher.deinit();
    try welcomePair(&host, &watcher);
    try testing.expectEqualSlices(u8, "ANN", &host.peer_name);
    // Its name given again reaches the host on the same connection.
    watcher.rename("ZED".*);
    try testing.expectEqual(Verdict.accepted, pump(&watcher, &host, 0));
    try testing.expectEqualSlices(u8, "ZED", &host.peer_name);
    watcher.askObserve();
    try testing.expectEqual(Verdict.accepted, pump(&watcher, &host, 0));
    try testing.expect(hasNote(&host, .observe_asked));
    var buf: [canonical.maxSize(TestState)]u8 = undefined;
    host.beginObserve(formOf(.{ .x = 7 }, &buf), 5);
    _ = pump(&host, &watcher, 0);
    try testing.expect(watcher.phase == .observing and watcher.inSession() and hasNote(&watcher, .observing));
    try testing.expectEqualSlices(u8, formOf(.{ .x = 7 }, &buf), watcher.gameForm());
    // The host runs 40 ticks; the observer, nothing in hand, holds; then, past its cushion, runs
    // them in order, the host's pads.
    try testing.expect(watcher.pads(.{}) == null);
    for (0..40) |t| {
        if (host.observerCheckDue()) host.observerHash(1000 + t);
        host.observed(.{ .pad1 = @bitCast(@as(u8, @intCast(t))), .pad2 = @bitCast(@as(u8, @intCast(t + 100))) });
    }
    host.flushTicks();
    _ = pump(&host, &watcher, 0);
    try testing.expectEqual(@as(u32, 40), watcher.seen_count);
    for (0..40) |t| {
        if (watcher.checkDue()) watcher.check(1000 + t, formOf(.{}, &buf));
        const got = watcher.pads(.{ .a = true }) orelse return error.Held;
        try testing.expectEqual(@as(u8, @intCast(t)), @as(u8, @bitCast(got.pad1)));
        try testing.expectEqual(@as(u8, @intCast(t + 100)), @as(u8, @bitCast(got.pad2)));
        watcher.ran();
    }
    try testing.expect(watcher.phase == .observing and watcher.pads(.{}) == null);
    // The observer stops: the host sends no more ticks.
    watcher.stopObserve();
    _ = pump(&watcher, &host, 0);
    try testing.expect(host.phase == .lobby and watcher.phase == .lobby);
    host.observed(.{});
    try testing.expectEqual(@as(usize, 0), host.outbox.items.len);
}

test "an observer whose hash differs from the host's stops, and the host goes on" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var watcher = try testSession(.guest, null);
    defer watcher.deinit();
    try welcomePair(&host, &watcher);
    watcher.askObserve();
    _ = pump(&watcher, &host, 0);
    var buf: [canonical.maxSize(TestState)]u8 = undefined;
    host.beginObserve(formOf(.{}, &buf), 5);
    for (0..31) |_| {
        if (host.observerCheckDue()) host.observerHash(1);
        host.observed(.{});
    }
    host.flushTicks();
    _ = pump(&host, &watcher, 0);
    for (0..30) |_| {
        _ = watcher.pads(.{}) orelse return error.Held;
        watcher.ran();
    }
    watcher.check(2, formOf(.{}, &buf));
    try testing.expect(watcher.phase == .desynced and hasNote(&watcher, .desync));
    try testing.expectEqual(Phase.observing, host.phase);
}

test "the handshake: the round trip picks the delay; welcomed, each plays its own game" {
    var host = try testSession(.host, null);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    host.connectedAt(0);
    guest.connectedAt(0);
    try testing.expectEqual(Phase.handshake, guest.phase);
    // The hello, then four pings answered after 40 ms each: 20 ms one way is 2 ticks rounded up,
    // and D = 3.
    try testing.expectEqual(Verdict.accepted, pump(&guest, &host, 0));
    var now: u64 = 0;
    for (0..handshake_pings) |_| {
        try testing.expectEqual(Phase.handshake, host.phase);
        _ = pump(&host, &guest, now);
        now += 40 * std.time.ns_per_ms;
        try testing.expectEqual(Verdict.accepted, pump(&guest, &host, now));
    }
    try testing.expectEqual(Phase.lobby, host.phase);
    try testing.expectEqual(@as(u8, 3), host.delay);
    _ = pump(&host, &guest, now);
    try testing.expectEqual(Phase.lobby, guest.phase);
    try testing.expectEqual(host.delay, guest.delay);
    try testing.expect(hasNote(&guest, .welcomed) and hasNote(&host, .welcomed));
    try testing.expectEqual(@as(u8, 2), Session.delayFor(0));
    try testing.expectEqual(@as(u8, 4), Session.delayFor(100 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u8, 6), Session.delayFor(std.time.ns_per_s));
    // In the lobby no pads run, and pads sent are out of place.
    try testing.expectEqual(@as(?input.Pads, null), host.pads(.{}));
    var buf: [protocol.max_len]u8 = undefined;
    try testing.expectEqual(Verdict.unexpected, guest.receive(encodeMsg(.{ .pads = .{ .first = 0, .ack = 0, .slack = 0, .pads = &.{1} } }, &buf), 0));
    // The host's status crosses when it changes, once.
    host.setStatus(.{ .game = .select });
    host.setStatus(.{ .game = .select });
    try testing.expectEqual(@as(usize, 1), host.outbox.items.len);
    _ = pump(&host, &guest, now);
    try testing.expectEqual(protocol.Status.Game.select, guest.peer_status.game);
}

test "the join: the host's game crosses, and both run the same game from its next tick" {
    var host = try testSession(.host, 3);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try welcomePair(&host, &guest);
    host.setStatus(.{ .game = .play, .character = 1 });
    _ = pump(&host, &guest, 0);
    // The guest's player chose Blaze; the host's game takes it: its form (three chunks) crosses.
    guest.askJoin(2);
    try testing.expectEqual(Phase.joining, guest.phase);
    _ = pump(&guest, &host, 0);
    try testing.expect(hasNote(&host, .join_asked) and host.join_asked.? == 2);
    const form = try testing.allocator.alloc(u8, 2 * protocol.chunk_size + 7);
    defer testing.allocator.free(form);
    for (form, 0..) |*b, i| b.* = @truncate(i *% 7);
    host.begin(form, 5);
    try testing.expectEqual(Phase.playing, host.phase);
    try testing.expectEqual(@as(usize, 3), host.outbox.items.len);
    _ = pump(&host, &guest, 5);
    try testing.expect(hasNote(&guest, .joined));
    try testing.expectEqual(host.id, guest.id);
    try testing.expectEqualSlices(u8, form, guest.gameForm());
    // The first `delay` ticks need no message; tick 3 needs the guest's pad for it, which the
    // guest sends before its tick 0.
    for (0..3) |_| {
        try testing.expect(host.pads(.{}) != null);
        host.ran();
    }
    try testing.expectEqual(@as(?input.Pads, null), host.pads(.{}));
    _ = guest.pads(.{ .b = true });
    _ = pump(&guest, &host, 5);
    try testing.expect(host.pads(.{}).?.pad2.b);
}

test "a join at the select that came too late: the guest chooses, then joins the game in play" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try welcomePair(&host, &guest);
    host.setStatus(.{ .game = .select });
    _ = pump(&host, &guest, 0);
    guest.askJoin(protocol.no_character);
    _ = pump(&guest, &host, 0);
    // The host's select ended meanwhile: its game plays, and it needs the guest's character.
    host.setStatus(.{ .game = .play, .character = 1 });
    host.declineJoin();
    _ = pump(&host, &guest, 0);
    try testing.expectEqual(Phase.lobby, guest.phase);
    try testing.expectEqual(@as(u8, 1), guest.peer_status.character);
    guest.askJoin(0);
    _ = pump(&guest, &host, 0);
    try testing.expectEqual(@as(?u8, 0), host.join_asked);
}

test "different versions, builds or data are refused" {
    for ([_]protocol.RejectReason{ .protocol, .build, .data }) |reason| {
        var host = try testSession(.host, 2);
        defer host.deinit();
        var guest = try testSession(.guest, null);
        defer guest.deinit();
        switch (reason) {
            .build => guest.config.build = protocol.buildId("other"),
            .data => guest.config.data = @splat(2),
            else => {},
        }
        host.connectedAt(0);
        guest.connectedAt(0);
        if (reason == .protocol) {
            var buf: [protocol.max_len]u8 = undefined;
            var h = guest.hello();
            h.hello.protocol = protocol.version + 1;
            guest.clearOutbox();
            try testing.expectEqual(Verdict.refused, host.receive(encodeMsg(h, &buf), 0));
        } else try testing.expectEqual(Verdict.refused, pump(&guest, &host, 0));
        try testing.expect(host.close_requested);
        try testing.expectEqual(Verdict.refused, pump(&host, &guest, 0));
        try testing.expectEqual(Phase.ended, guest.phase);
        try testing.expectEqual(reason, guest.notes.items[0].refused);
    }
}

test "pads messages: duplicate, stale, out of order, ahead, conflicting, malformed, unexpected" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    var buf: [protocol.max_len]u8 = undefined;
    try startPair(&host, &guest);
    try runBoth(&host, &guest, 200);

    const at = host.remote_count;
    try testing.expectEqual(Verdict.duplicate, host.receive(encodeMsg(.{ .pads = .{ .first = at - 3, .ack = 0, .slack = 0, .pads = &.{ guest.local[(at - 3) % window], guest.local[(at - 2) % window] } } }, &buf), 0));
    try testing.expectEqual(Verdict.conflict, host.receive(encodeMsg(.{ .pads = .{ .first = at - 1, .ack = 0, .slack = 0, .pads = &.{guest.local[(at - 1) % window] +% 1} } }, &buf), 0));
    try testing.expectEqual(Verdict.stale, host.receive(encodeMsg(.{ .pads = .{ .first = 10, .ack = 0, .slack = 0, .pads = &.{0} } }, &buf), 0));
    try testing.expectEqual(Verdict.ahead, host.receive(encodeMsg(.{ .pads = .{ .first = at + window, .ack = 0, .slack = 0, .pads = &.{0} } }, &buf), 0));
    // Out of order: tick at + 1 before at; the gap holds the count until at arrives.
    try testing.expectEqual(Verdict.out_of_order, host.receive(encodeMsg(.{ .pads = .{ .first = at + 1, .ack = 0, .slack = 0, .pads = &.{5} } }, &buf), 0));
    try testing.expectEqual(at, host.remote_count);
    try testing.expectEqual(Verdict.accepted, host.receive(encodeMsg(.{ .pads = .{ .first = at, .ack = 0, .slack = 0, .pads = &.{4} } }, &buf), 0));
    try testing.expectEqual(at + 2, host.remote_count);
    try testing.expectEqual(Verdict.malformed, host.receive(&.{ 6, 0, 0 }, 0));
    try testing.expectEqual(Verdict.malformed, host.receive("", 0));
    // A hello once welcomed, a welcome to the host, a join to the guest, a status to the host,
    // are out of place.
    try testing.expectEqual(Verdict.unexpected, host.receive(encodeMsg(guest.hello(), &buf), 0));
    try testing.expectEqual(Verdict.unexpected, host.receive(encodeMsg(.{ .welcome = .{ .session = 1, .delay = 2, .resume_from = 0 } }, &buf), 0));
    try testing.expectEqual(Verdict.unexpected, guest.receive(encodeMsg(.{ .join = 1 }, &buf), 0));
    try testing.expectEqual(Verdict.unexpected, host.receive(encodeMsg(.{ .status = .{} }, &buf), 0));
    // A status during the session is kept (the host sends one as the session ends); a game is
    // stale.
    try testing.expectEqual(Verdict.accepted, guest.receive(encodeMsg(.{ .status = .{} }, &buf), 0));
    // The session goes on after all of them.
    try testing.expectEqual(Phase.playing, host.phase);
}

test "a dropped connection holds both; the same session resumes with the pads that were lost" {
    var host = try testSession(.host, 3);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    try runBoth(&host, &guest, 100);
    // The host's pads for three ticks are lost in the cable.
    for (0..3) |_| {
        _ = host.pads(.{ .a = true });
        host.clearOutbox();
        if (host.remote_count > host.next) host.ran() else break;
    }
    host.disconnected(10);
    guest.disconnected(10);
    try testing.expectEqual(Phase.playing, host.phase);
    try testing.expectEqual(@as(?u64, 5), host.lostFor(15));
    // Both hold: the guest lacks the host's pads.
    var held = false;
    for (0..8) |_| {
        if (guest.pads(.{}) == null) {
            held = true;
            break;
        }
        guest.ran();
    }
    try testing.expect(held);
    // The guest reconnects with the session's id: the host resends from where the guest is.
    guest.clearOutbox();
    host.connectedAt(5);
    guest.connectedAt(5);
    try testing.expectEqual(Verdict.accepted, pump(&guest, &host, 5));
    try testing.expect(host.notes.getLast().started.resumed);
    try testing.expectEqual(@as(?u64, null), host.lostFor(20));
    try testing.expectEqual(Verdict.accepted, pump(&host, &guest, 5));
    // The guest resends its own, which it sampled while the connection was down.
    try testing.expectEqual(Verdict.accepted, pump(&guest, &host, 5));
    try testing.expectEqual(host.remote_count, guest.local_count);
    try testing.expectEqual(guest.remote_count, host.local_count);
    // Level again, they run on together.
    while (guest.next < host.next) {
        _ = guest.pads(.{}).?;
        guest.ran();
        _ = pump(&guest, &host, 5);
    }
    while (host.next < guest.next) {
        _ = host.pads(.{}).?;
        host.ran();
        _ = pump(&host, &guest, 5);
    }
    try runBoth(&host, &guest, 50);
}

test "a guest that does not come back in time: the host ends the session, the guest is told when back" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    try runBoth(&host, &guest, 20);
    const old = host.id;
    host.disconnected(0);
    guest.disconnected(0);
    try testing.expect(host.lostFor(rejoin_ns + 1).? > rejoin_ns);
    host.end(.lost);
    try testing.expectEqual(Phase.idle, host.phase);
    try testing.expectEqual(End.lost, host.notes.getLast().ended);
    // Back too late: the hello names the old session, which the host no longer has.
    guest.clearOutbox();
    host.connectedAt(1);
    guest.connectedAt(1);
    try testing.expectEqual(old, guest.id);
    try welcomePair(&host, &guest);
    try testing.expectEqual(End.lost, guest.notes.items[guest.notes.items.len - 2].ended);
    try testing.expectEqual(Phase.lobby, guest.phase);
}

test "the game ends on both at the same tick: back in the lobby, and a new join starts a new session" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    try runBoth(&host, &guest, 40);
    const first = host.id;
    host.end(.game_over);
    guest.end(.game_over);
    try testing.expect(host.phase == .lobby and guest.phase == .lobby and host.id == 0);
    // The pads still on their way are out of place now.
    _ = pump(&host, &guest, 0);
    _ = pump(&guest, &host, 0);
    var buf: [canonical.maxSize(TestState)]u8 = undefined;
    try joinPair(&host, &guest, formOf(.{ .x = 9 }, &buf));
    try testing.expect(host.id != first and host.next == 0);
    try runBoth(&host, &guest, 40);
}

test "a guest that says goodbye: its last pads run, then the session ends; the host waits for another" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    try runBoth(&host, &guest, 10);
    _ = guest.pads(.{});
    guest.leave(.quit);
    _ = pump(&guest, &host, 0);
    try testing.expect(host.peer_left);
    var ran: u32 = 0;
    while (host.pads(.{})) |_| : (ran += 1) host.ran();
    try testing.expectEqual(@as(u32, 3), ran);
    try testing.expectEqual(End.left, host.notes.getLast().ended);
    try testing.expect(host.phase == .lobby and host.close_requested);
    host.disconnected(0);
    try testing.expectEqual(Phase.idle, host.phase);
}

test "a state mismatch stops both and names the first differing field" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    var a_buf: [canonical.maxSize(TestState)]u8 = undefined;
    var b_buf: [canonical.maxSize(TestState)]u8 = undefined;
    try runBoth(&host, &guest, check_interval);
    try testing.expect(host.checkDue() and guest.checkDue());
    host.check(1, formOf(.{}, &a_buf));
    guest.check(1, formOf(.{}, &b_buf));
    try testing.expect(!host.checkDue());
    try testing.expectEqual(Verdict.accepted, pump(&host, &guest, 0));
    try testing.expectEqual(Verdict.accepted, pump(&guest, &host, 0));
    var hbuf: [protocol.max_len]u8 = undefined;
    try testing.expectEqual(Verdict.duplicate, guest.receive(encodeMsg(.{ .hash = .{ .tick = check_interval, .hash = 1 } }, &hbuf), 0));
    try runBoth(&host, &guest, check_interval);
    // The guest's y differs (a corrupted byte).
    host.check(2, formOf(.{}, &a_buf));
    guest.check(3, formOf(.{ .y = 64 }, &b_buf));
    _ = pump(&host, &guest, 0);
    _ = pump(&guest, &host, 0);
    _ = pump(&host, &guest, 0);
    try testing.expectEqual(Phase.desynced, host.phase);
    try testing.expectEqual(Phase.desynced, guest.phase);
    try testing.expectEqual(@as(?input.Pads, null), host.pads(.{}));
    const hd = host.notes.getLast().diagnosed.?;
    try testing.expectEqualStrings("y", hd.name());
    try testing.expectEqual(@as(u64, 0), hd.ours);
    try testing.expectEqual(@as(u64, 64), hd.theirs);
    const gd = guest.notes.getLast().diagnosed.?;
    try testing.expectEqualStrings("y", gd.name());
    try testing.expectEqual(@as(u64, 64), gd.ours);
    // A stale hash, and one off the grid.
    var buf: [protocol.max_len]u8 = undefined;
    try testing.expectEqual(Verdict.malformed, host.receive(encodeMsg(.{ .hash = .{ .tick = 31, .hash = 0 } }, &buf), 0));
    try testing.expectEqual(Verdict.stale, host.receive(encodeMsg(.{ .hash = .{ .tick = 30, .hash = 0 } }, &buf), 0));
}

test "a mismatch whose state was not kept is noted, and takes no chunk" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    try runBoth(&host, &guest, check_interval);
    // The host's form is longer than the protocol carries: only its hash is checked.
    const long = try testing.allocator.alloc(u8, protocol.max_state_len + 1);
    defer testing.allocator.free(long);
    @memset(long, 0);
    var b_buf: [canonical.maxSize(TestState)]u8 = undefined;
    host.check(1, long);
    guest.check(2, formOf(.{}, &b_buf));
    _ = pump(&guest, &host, 0);
    try testing.expectEqual(Phase.desynced, host.phase);
    try testing.expectEqual(@as(?canonical.Difference, null), host.notes.getLast().diagnosed);
    var buf: [protocol.max_len]u8 = undefined;
    try testing.expectEqual(Verdict.duplicate, host.receive(encodeMsg(.{ .state = .{ .tick = check_interval, .length = 1, .offset = 0, .bytes = &.{0} } }, &buf), 0));
}

test "a form of several chunks crosses whole, and a chunk of another tick is refused" {
    // A state whose form takes three chunks, the last one short.
    const Big = struct { values: [2 * protocol.chunk_size + 100]u8 = @splat(7) };
    var host = try Session.init(testing.allocator, .{ .role = .host, .build = protocol.buildId("test"), .data = @splat(1), .delay = 2 }, canonical.diffFn(Big));
    defer host.deinit();
    var guest = try Session.init(testing.allocator, .{ .role = .guest, .build = protocol.buildId("test"), .data = @splat(1) }, canonical.diffFn(Big));
    defer guest.deinit();
    try startPair(&host, &guest);
    try runBoth(&host, &guest, check_interval);
    const ours = try testing.allocator.create(Big);
    defer testing.allocator.destroy(ours);
    ours.* = .{};
    const theirs = try testing.allocator.create(Big);
    defer testing.allocator.destroy(theirs);
    theirs.* = .{};
    theirs.values[2 * protocol.chunk_size + 50] = 9;
    host.check(1, std.mem.asBytes(&ours.values));
    guest.check(2, std.mem.asBytes(&theirs.values));
    _ = pump(&host, &guest, 0);
    _ = pump(&guest, &host, 0);
    _ = pump(&host, &guest, 0);
    const d = host.notes.getLast().diagnosed.?;
    try testing.expectEqualStrings("values[32818]", d.name());
    try testing.expectEqual(@as(u64, 9), d.theirs);
    try testing.expectEqualStrings("values[32818]", guest.notes.getLast().diagnosed.?.name());
    var buf: [protocol.max_len]u8 = undefined;
    try testing.expectEqual(Verdict.unexpected, host.receive(encodeMsg(.{ .state = .{ .tick = 60, .length = 1, .offset = 0, .bytes = &.{0} } }, &buf), 0));
    try testing.expectEqual(Verdict.duplicate, host.receive(encodeMsg(.{ .state = .{ .tick = 30, .length = 1, .offset = 0, .bytes = &.{0} } }, &buf), 0));
}

test "a host busy with another guest: a new guest gives up, a returning one tries again" {
    var buf: [protocol.max_len]u8 = undefined;
    const busy = encodeMsg(.{ .reject = .busy }, &buf);
    var fresh = try testSession(.guest, null);
    defer fresh.deinit();
    fresh.connectedAt(0);
    try testing.expectEqual(Verdict.refused, fresh.receive(busy, 0));
    try testing.expectEqual(Phase.ended, fresh.phase);
    // A guest whose session goes on (its old connection not yet seen closed by the host).
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    guest.disconnected(0);
    guest.connectedAt(0);
    try testing.expectEqual(Verdict.refused, guest.receive(busy, 0));
    try testing.expectEqual(Phase.playing, guest.phase);
    try testing.expect(guest.close_requested);
}

test "the peer ahead stretches its sound, up to 0.5 %" {
    var host = try testSession(.host, 3);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    var s = &host;
    s.peer_slack = 3 * 256;
    s.slack = 3 * 256;
    try testing.expectEqual(@as(u32, 0), s.stretchPpm());
    // One tick ahead: two ticks less slack than the peer.
    s.slack = 1 * 256;
    try testing.expectEqual(@as(i32, 256), s.advantage());
    try testing.expectEqual(@as(u32, 3750), s.stretchPpm());
    s.slack = -2 * 256;
    try testing.expectEqual(max_stretch_ppm, s.stretchPpm());
    // Behind: no stretch.
    s.slack = 5 * 256;
    try testing.expectEqual(@as(u32, 0), s.stretchPpm());
}

test "the stats: each peer's load crosses in a session, none outside it" {
    var host = try testSession(.host, 3);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try welcomePair(&host, &guest);
    // In the lobby: nothing is said.
    guest.sayLoad(.{ .ticks = 60 });
    try testing.expectEqual(@as(usize, 0), guest.outbox.items.len);
    var buf: [canonical.maxSize(TestState)]u8 = undefined;
    try joinPair(&host, &guest, canonical.write(TestState, &.{}, &buf));
    guest.sayLoad(.{ .ticks = 58, .busy = 97, .wait = 0 });
    try testing.expectEqual(Verdict.accepted, pump(&guest, &host, 0));
    try testing.expectEqual(@as(?protocol.Load, .{ .ticks = 58, .busy = 97, .wait = 0 }), host.peer_load);
    host.sayLoad(.{ .ticks = 58, .busy = 30, .wait = 12 });
    _ = pump(&host, &guest, 0);
    try testing.expectEqual(@as(u8, 12), guest.peer_load.?.wait);
    // One that comes after the session's end is stale.
    var msg: [protocol.max_len]u8 = undefined;
    host.end(.game_over);
    try testing.expectEqual(Verdict.stale, host.receive(encodeMsg(.{ .load = .{} }, &msg), 0));
}

test "the settings screen: the peer is told, holds once its pads run out, and both go on in step" {
    var host = try testSession(.host, 3);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    try runBoth(&host, &guest, 20);
    // The host's player opens the screen: the host runs no tick and samples no pad; the guest is
    // told, and runs the ticks whose pads it has, then holds.
    host.inSettings(true);
    host.inSettings(true);
    try testing.expectEqual(Verdict.accepted, pump(&host, &guest, 0));
    try testing.expect(guest.peer_settings and !host.peer_settings);
    var ran: u32 = 0;
    while (guest.pads(.{})) |_| : (ran += 1) {
        _ = pump(&guest, &host, 0);
        guest.ran();
    }
    try testing.expectEqual(@as(u32, 3), ran);
    try testing.expectEqual(host.next + 3, guest.next);
    // A duplicate or a word out of place.
    var buf: [protocol.max_len]u8 = undefined;
    try testing.expectEqual(Verdict.duplicate, guest.receive(encodeMsg(.{ .settings = true }, &buf), 0));
    // A connection lost and back: the guest forgets, and the host says it again.
    host.disconnected(0);
    guest.disconnected(0);
    try testing.expect(!guest.peer_settings);
    host.connectedAt(0);
    guest.connectedAt(0);
    _ = pump(&guest, &host, 0);
    _ = pump(&host, &guest, 0);
    try testing.expect(guest.welcomed and guest.peer_settings);
    // Closed: told, and both run on, the host through the ticks the guest ran ahead.
    host.inSettings(false);
    _ = pump(&host, &guest, 0);
    try testing.expect(!guest.peer_settings);
    for (0..3) |_| {
        try testing.expect(host.pads(.{}) != null);
        _ = pump(&host, &guest, 0);
        host.ran();
    }
    try testing.expectEqual(host.next, guest.next);
    try runBoth(&host, &guest, 10);
    try testing.expectEqual(@as(usize, 0), host.outbox.items.len);
    // Before the handshake, the word is out of place.
    var fresh = try testSession(.guest, null);
    defer fresh.deinit();
    try testing.expectEqual(Verdict.unexpected, fresh.receive(encodeMsg(.{ .settings = true }, &buf), 0));
}

test "an event: the host schedules its player's leave ahead of its pads; both make it at one tick" {
    var host = try testSession(.host, 3);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    try runBoth(&host, &guest, 10);
    const at = host.schedule(.{ .tick = 0, .what = .leave }).?;
    try testing.expect(at > host.next);
    // One change at a time.
    try testing.expectEqual(@as(?u32, null), host.schedule(.{ .tick = 0, .what = .back, .character = 1 }));
    var seen: [2]?u32 = .{ null, null };
    for (0..10) |_| {
        const t = host.next;
        if (host.eventAt() != null) seen[0] = t;
        _ = host.pads(.{}) orelse return error.Held;
        _ = pump(&host, &guest, 0);
        if (guest.eventAt() != null) seen[1] = t;
        _ = guest.pads(.{}) orelse return error.Held;
        _ = pump(&guest, &host, 0);
        host.ran();
        guest.ran();
    }
    try testing.expectEqual(@as(?u32, at), seen[0]);
    try testing.expectEqual(@as(?u32, at), seen[1]);
    try testing.expect(host.event == null and guest.event == null);
    // A change whose tick ran already is refused.
    var buf: [protocol.max_len]u8 = undefined;
    try testing.expectEqual(Verdict.malformed, guest.receive(encodeMsg(.{ .event = .{ .tick = 2, .what = .leave } }, &buf), 0));
}

test "a player who leaves the game alone: its last pads run, the session ends, the connection stays" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    try runBoth(&host, &guest, 10);
    _ = guest.pads(.{});
    guest.leaveGame();
    try testing.expect(guest.phase == .lobby and !guest.inSession());
    _ = pump(&guest, &host, 0);
    try testing.expect(host.peer_left);
    while (host.pads(.{})) |_| host.ran();
    try testing.expectEqual(End.left, host.notes.getLast().ended);
    try testing.expect(host.phase == .lobby and !host.close_requested and host.welcomed);
}

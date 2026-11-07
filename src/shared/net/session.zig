//! The netplay session of one connection (DESIGN.md 9): two machines, each running its own game,
//! whose players meet in one: a host (player 1) and a guest (its `place`, player 2 to 4: the game
//! holds up to four players, DESIGN.md 10.7, E4), outside the simulation and without I/O. The
//! host keeps one for each client, and its driver (netplay.zig) merges their pads; a guest's
//! session also holds the pads of the session's other clients, which the host relays. The driver
//! gives it the connection's events and messages, the game's status, pads and state checks; it
//! answers with the merged pads of each display tick of a session, the messages to send
//! (`outbox`) and what happened (`notes`).
//!
//! - **Handshake.** The guest connects when its player wants to join, and sends `hello`
//!   (versions, data identity, the session it had). The host pings to measure the round trip,
//!   picks the input delay D from it (2 to 6 ticks) and answers `welcome`; or, for the session it
//!   still plays after a dropped connection, `welcome` with that session, and each peer resends
//!   the pads the other lacks. Different versions or data: `reject`.
//! - **The lobby.** Welcomed, each machine plays its own game. The host says what its game is
//!   (`status`, `setStatus`); the guest asks to join (`askJoin`, with its player's character or
//!   none), and the host's game decides when (a note `join_asked`, then `begin` or `declineJoin`).
//! - **The join.** `begin` starts a session with the host's game's canonical form: its id, the
//!   guest's player in it (`place`), its first tick and the players in it then, its form in
//!   `game` chunks, then the session's pads; the guest gathers the chunks (a note `joined`: its
//!   game loads `gameForm`). From that tick, both run the same game, each machine's pad its own
//!   player's. A session's ticks count from its first client's join: a client that joins a
//!   session under way starts at the tick the host chose (a join `event` for the others).
//! - **Pads.** Before tick N runs, the peer samples its pad for tick N + D and sends it; a
//!   client's pads of the session's first D ticks are empty on every machine, and the host sends
//!   its own from the first (empty in a new session). Tick N runs once every player's pad for N is
//!   in (the host's, this machine's, and on a guest the other clients', relayed: `relay`); until
//!   then the game holds (`pads` returns null).
//! - **State checks.** Every `check_interval` ticks each peer sends the hash of its state's
//!   canonical form before that tick, and keeps the form. A hash that differs from the peer's stops
//!   the session (`desynced`): the peers exchange those forms and name the first differing field.
//! - **Clock balancing.** Each peer measures its slack, how many of the peer's pads it holds beyond
//!   the tick it runs, and sends it; the peer ahead (the one with less slack) stretches its sound
//!   (`stretchPpm`) until they are level.
//! - **Stats.** Every second of a session, each peer says what its game did over the last one
//!   (`sayLoad`: the driver's measure), and keeps the other's (`peer_load`).
//! - **The settings screen.** A game whose player opens it holds, and sends no pads: the others
//!   hold too once the pads they have run out (D ticks at most). Each side says when its player
//!   opens or closes the screen (`inSettings`), and the host relays a client's to the others, so
//!   that each can tell its player who holds it (`peer_settings`, `settings_of`); a connection
//!   that comes back or a new session says it again.
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
    away: protocol.Away,
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
    /// A player of the session opened the settings screen or closed it.
    settings: protocol.Settings,
    /// The host's driver (netplay.zig): a client's session of play ended (its `ended`), the
    /// client player `player`; `made`, its leave was a change of the game the others made at
    /// its tick (the session went on without it), else the game makes it now.
    member_ended: struct { player: input.Player, why: End, made: bool },
};

/// The changes of the game a session keeps at once (`schedule`).
pub const max_events = 8;

/// Another client's pads in a guest's session, as the host relays them: in the session from tick
/// `from` (null: not in it), out of it from `until`, in hand for the ticks before `count`.
pub const Relayed = struct {
    from: ?u32 = null,
    until: ?u32 = null,
    count: u32 = 0,
    pads: [window]u8 = @splat(0),

    pub fn active(r: *const Relayed, t: u32) bool {
        const from = r.from orelse return false;
        return t >= from and (r.until == null or t < r.until.?);
    }
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
    /// The changes of the game at ticks to come (a player leaving, coming back or joining, the
    /// rules), in their ticks' order: the host's, as it scheduled them, each kept until the client
    /// has the pads past its tick (a resumed connection gets them again); the client's, as it
    /// heard them, and the last it made (a resumed connection's again are duplicates).
    events: [max_events]protocol.Event = undefined,
    events_len: u8 = 0,
    made: [max_events]?protocol.Event = @splat(null),
    made_at: u8 = 0,
    /// The host: this client leaves the session once its pads run out (it said goodbye, or its
    /// connection did not come back in time while others play on), and why.
    leaving: ?End = null,
    /// The client asked to watch (on both sides, until the host's game comes or it stops); the
    /// host also hears it from a client that watches already, which asks for its game again.
    observe_asked: bool = false,
    /// An observer whose ticks outran its window (`onTicks`) asked for the host's game again,
    /// once, until it comes.
    resync_asked: bool = false,
    /// The host: the ticks of an observer's game sent so far, and the pads still to send (those
    /// of `ticks_players` players a tick, from tick `ticks_first`).
    ticks_sent: u32 = 0,
    ticks_first: u32 = 0,
    ticks_out: [input.max_players * protocol.max_pads]u8 = undefined,
    ticks_len: u16 = 0,
    ticks_players: u8 = 2,
    /// The observer: the host's ticks in hand (every player's pad a tick, none for a player the
    /// host's ticks did not carry; in a ring), the count of them, and whether it started running
    /// them (after `observe_cushion`).
    seen: [window][input.max_players]u8 = undefined,
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

    /// The guest's player in the session's game (from 0: player 2 is 1): the host's choice, the
    /// guest's as the game's chunks said.
    place: input.Player = 1,
    /// The session's first tick, and the players in it then (a bit each), as the host's `begin`
    /// said.
    start: u32 = 0,
    players: u8 = 0b11,
    /// The guest: the session's other clients' pads, by player, as the host relays them.
    others: [input.max_players]Relayed = @splat(.{}),
    /// The host: by player, the next tick of another client's pads to relay to this one, and the
    /// first of them this one needs.
    relay_next: [input.max_players]u32 = @splat(0),
    relay_from: [input.max_players]u32 = @splat(0),

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

    /// The peer's game over its last second of this session (its `load`), for the stats; on a
    /// guest, each player's machine's as the host said (the host's own, player 1's, the same as
    /// `peer_load`).
    peer_load: ?protocol.Load = null,
    loads: [input.max_players]?protocol.Load = @splat(null),

    /// The balancing: our slack and the peer's, in 1/256 tick.
    slack: i32 = 0,
    peer_slack: ?i32 = null,

    /// Our player is on the settings screen, and the peer's (as it last said, on this
    /// connection); on a guest, any other player of the session (by player in `settings_of`, as
    /// the host said).
    local_settings: bool = false,
    peer_settings: bool = false,
    settings_of: u8 = 0,

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
        std.debug.assert(protocol.max_players == input.max_players);
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
        self.settings_of = 0;
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
            .relay => |r| self.onRelay(r),
            .away => |a| blk: {
                if (self.config.role != .guest or !self.welcomed) break :blk .unexpected;
                self.note(.{ .away = a });
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
                // The host stopped the session at another client's mismatch: this game stops too.
                if (r == .desync and self.config.role == .guest and self.phase == .playing) {
                    self.phase = .desynced;
                    self.desync_at = self.next;
                    self.peer_chunks = done_chunks;
                    self.note(.{ .desync = self.next });
                    self.note(.{ .diagnosed = null });
                    break :blk .accepted;
                }
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
        self.events_len = 0;
        self.made = @splat(null);
        self.leaving = null;
        self.others = @splat(.{});
        self.settings_of = 0;
        self.loads = @splat(null);
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
        const resumable = h.session != 0 and h.session == self.id and self.phase == .playing and self.leaving == null and
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
    /// loading `form`, the host's game's canonical form now: a new session (`at` null), or the
    /// host's session under way (the tick, its players with the guest's, and the host's
    /// pads it sent the others for the tick and those after it).
    pub fn begin(self: *Session, form: []const u8, now_ns: u64) void {
        self.beginAt(form, now_ns, null);
    }

    pub const At = struct { tick: u32, delay: u8, players: u8, host_pads: []const u8 };

    pub fn beginAt(self: *Session, form: []const u8, now_ns: u64, at: ?At) void {
        std.debug.assert(self.config.role == .host and self.phase == .lobby and form.len <= protocol.max_state_len);
        self.join_asked = null;
        const id = self.newId(now_ns);
        const tick_ = if (at) |x| x.tick else 0;
        if (at) |x| self.delay = x.delay;
        const players = if (at) |x| x.players | @as(u8, 1) << self.place else 1 | @as(u8, 1) << self.place;
        var offset: u32 = 0;
        const length: u32 = @intCast(form.len);
        while (offset < length) : (offset += protocol.chunk_size) {
            self.send(.{ .game = .{ .session = id, .delay = self.delay, .place = self.place, .tick = tick_, .players = players, .length = length, .offset = offset, .bytes = form[offset..][0..protocol.chunkLen(length, offset)] } });
        }
        self.startSession(id, tick_, players);
        if (at) |x| for (x.host_pads, 0..) |b, i| {
            self.local[(tick_ + @as(u32, @intCast(i))) % window] = b;
        };
    }

    /// This machine's player in the session's game: the host's player 1, the guest's `place`.
    pub fn localPlayer(self: *const Session) input.Player {
        return if (self.config.role == .host) 0 else self.place;
    }

    /// The other machine's player in the session's game.
    pub fn peerPlayer(self: *const Session) input.Player {
        return if (self.config.role == .host) self.place else 0;
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
        if (!g.observe) self.place = @intCast(g.place);
        if (g.observe) {
            self.startWatching(g.session);
            return .accepted;
        }
        self.startSession(g.session, g.tick, g.players);
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
            // From the lobby, or from an observer that lost the host's ticks and asks again.
            if (self.phase != .lobby and self.phase != .observing) return .stale;
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
            self.send(.{ .game = .{ .session = self.id, .delay = protocol.min_delay, .observe = true, .players = 0, .length = length, .offset = offset, .bytes = form[offset..][0..protocol.chunkLen(length, offset)] } });
        }
        self.phase = .observing;
        self.ticks_sent = 0;
        self.ticks_first = 0;
        self.ticks_len = 0;
    }

    /// The host's game ran a tick with `pads`, the pads of its first `players` players (2 to 4;
    /// the others hold none): the observer gets them (sent in runs).
    pub fn observed(self: *Session, pads_: input.Pads, players: u8) void {
        std.debug.assert(players >= 1 and players <= input.max_players);
        if (self.config.role != .host or self.phase != .observing) return;
        if (players != self.ticks_players) self.flushTicks();
        self.ticks_players = players;
        if (self.ticks_len == 0) self.ticks_first = self.ticks_sent;
        for (0..players) |k| self.ticks_out[self.ticks_len + k] = @bitCast(pads_.of(k));
        self.ticks_len += players;
        self.ticks_sent += 1;
        if (self.ticks_len == @as(u16, players) * protocol.max_pads) self.flushTicks();
    }

    /// Sends the observer the ticks' pads in hand.
    pub fn flushTicks(self: *Session) void {
        if (self.ticks_len == 0) return;
        self.send(.{ .ticks = .{ .first = self.ticks_first, .players = self.ticks_players, .pads = self.ticks_out[0..self.ticks_len] } });
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
    pub fn sayAway(self: *Session, seconds: u8, player: input.Player) void {
        if (self.config.role != .host or !self.welcomed) return;
        self.send(.{ .away = .{ .seconds = seconds, .player = player } });
    }

    /// The observer starts from the host's game: its ticks count from 0.
    fn startWatching(self: *Session, id: u64) void {
        self.id = id;
        self.observe_asked = false;
        self.phase = .observing;
        self.next = 0;
        self.seen_count = 0;
        self.watching = false;
        self.resync_asked = false;
        self.own = @splat(null);
        self.theirs = @splat(null);
        self.snapshots = .{ null, null };
        self.desync_at = null;
        self.note(.observing);
    }

    /// The host's ticks, in hand as they come. Ticks past the window (an observer that ran none
    /// for a while: a page hidden, a slow machine) are lost, and every later run then starts past
    /// those in hand: the observer asks for the host's game again (`resync`), and watches on from
    /// it.
    fn onTicks(self: *Session, t: protocol.Ticks) Verdict {
        if (self.config.role != .guest or self.phase != .observing) return .unexpected;
        const count: u32 = @intCast(t.pads.len / t.players);
        if (t.first + count <= self.seen_count) return .duplicate;
        if (t.first > self.seen_count) {
            self.resync();
            return .out_of_order;
        }
        var i = self.seen_count - t.first;
        while (i < count) : (i += 1) {
            const tick_ = t.first + i;
            if (tick_ >= self.next + window) {
                self.resync();
                return .ahead;
            }
            const slot = &self.seen[tick_ % window];
            slot.* = @splat(0);
            @memcpy(slot[0..t.players], t.pads[t.players * i ..][0..t.players]);
            self.seen_count = tick_ + 1;
        }
        return .accepted;
    }

    /// The observer asks for the host's game again, once until it comes.
    fn resync(self: *Session) void {
        if (self.resync_asked) return;
        self.resync_asked = true;
        self.send(.{ .observe = true });
    }

    /// The observer's next tick's pads, the host's: none until it has `observe_cushion` in hand,
    /// then as they come.
    fn observedPads(self: *Session) ?input.Pads {
        if (!self.watching) {
            if (self.seen_count < self.next + observe_cushion) return null;
            self.watching = true;
        }
        if (self.next >= self.seen_count) return null;
        const slot = self.seen[self.next % window];
        var out: input.Pads = .{};
        for (slot, 0..) |b, k| out.at(k).* = @bitCast(b);
        return out;
    }

    /// The host's game, which the guest's game loads (after the note `joined`).
    pub fn gameForm(self: *const Session) []const u8 {
        return self.game_form.slice();
    }

    /// Both sides start the session from the same game at tick `tick_`, the client's pads empty
    /// for the first `delay` ticks; the host's for those ticks are sent (empty in a new session,
    /// the host's `beginAt` gives those it sampled for one under way). On a guest, the other
    /// clients in the session then (`players`) have their pads relayed from that tick.
    fn startSession(self: *Session, id: u64, tick_: u32, players: u8) void {
        self.id = id;
        self.phase = .playing;
        self.events_len = 0;
        self.made = @splat(null);
        self.leaving = null;
        self.peer_left = false;
        self.lost_at = null;
        self.start = tick_;
        self.players = players;
        self.next = tick_;
        self.local = @splat(0);
        self.remote = @splat(0);
        self.have = .empty;
        self.others = @splat(.{});
        self.relay_next = @splat(tick_);
        self.relay_from = @splat(tick_);
        self.settings_of = 0;
        self.loads = @splat(null);
        const ahead = tick_ + self.delay;
        switch (self.config.role) {
            .host => {
                self.local_count = ahead;
                self.sent_upto = tick_;
                self.peer_ack = tick_;
                self.remote_count = ahead;
                for (tick_..ahead) |i| self.have.set(i % window);
            },
            .guest => {
                self.local_count = ahead;
                self.sent_upto = ahead;
                self.peer_ack = ahead;
                self.remote_count = tick_;
                for (1..input.max_players) |k| if (k != self.place and players & @as(u8, 1) << @intCast(k) != 0) {
                    self.others[k] = .{ .from = tick_, .count = tick_ };
                };
            },
        }
        self.slack = 0;
        self.peer_slack = null;
        self.peer_load = null;
        self.own = @splat(null);
        self.theirs = @splat(null);
        self.snapshots = .{ null, null };
        self.desync_at = null;
        self.peer_chunks = 0;
        self.early_tick = null;
        if (self.local_settings) self.send(.{ .settings = .{ .open = true, .player = self.localPlayer() } });
        self.note(.{ .started = .{ .resumed = false, .delay = self.delay, .tick = tick_ } });
    }

    /// The same session goes on: the pads the peer lacks, and our recent hashes, again.
    fn resumeFrom(self: *Session, peer_has: u32) void {
        self.welcomed = true;
        self.lost_at = null;
        self.peer_ack = @max(self.peer_ack, peer_has);
        self.sent_upto = peer_has;
        // The changes of the game the client may not have heard: before the pads of their ticks.
        for (self.events[0..self.events_len]) |e| self.send(.{ .event = e });
        self.flushPads();
        for (self.own) |h| if (h) |x| self.send(.{ .hash = x.hash });
        if (self.local_settings) self.send(.{ .settings = .{ .open = true, .player = self.localPlayer() } });
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
        self.sayLoadOf(self.localPlayer(), l);
    }

    /// The host tells its client another client's load (player `player`'s machine's).
    pub fn sayLoadOf(self: *Session, player: input.Player, l: protocol.Load) void {
        if (self.welcomed and self.phase == .playing) self.send(.{ .load = .{ .player = player, .load = l } });
    }

    /// One that crosses the session's end is of no use any more.
    fn onLoad(self: *Session, pl: protocol.PlayerLoad) Verdict {
        if (!self.welcomed) return .unexpected;
        if (self.phase != .playing) return .stale;
        switch (self.config.role) {
            .host => self.peer_load = pl.load,
            .guest => {
                self.loads[pl.player] = pl.load;
                if (pl.player == 0) self.peer_load = pl.load;
            },
        }
        return .accepted;
    }

    // --- the settings screen -----------------------------------------------------------------

    /// Our player opened the settings screen (`open`) or closed it: the peer is told.
    pub fn inSettings(self: *Session, open: bool) void {
        if (open == self.local_settings) return;
        self.local_settings = open;
        if (self.welcomed and self.phase == .playing) self.send(.{ .settings = .{ .open = open, .player = self.localPlayer() } });
    }

    /// The host tells its client that another client's player (`player`) opened the settings
    /// screen or closed it.
    pub fn relaySettings(self: *Session, open: bool, player: input.Player) void {
        if (self.config.role == .host and self.welcomed and self.phase == .playing) self.send(.{ .settings = .{ .open = open, .player = player } });
    }

    /// A client says its own player's (whatever player it names); the host, its own or another
    /// client's.
    fn onSettings(self: *Session, x: protocol.Settings) Verdict {
        if (!self.welcomed or self.phase != .playing) return .unexpected;
        switch (self.config.role) {
            .host => {
                if (x.open == self.peer_settings) return .duplicate;
                self.peer_settings = x.open;
                self.note(.{ .settings = .{ .open = x.open, .player = self.place } });
            },
            .guest => {
                const bit = @as(u8, 1) << @intCast(x.player);
                if ((self.settings_of & bit != 0) == x.open) return .duplicate;
                if (x.open) self.settings_of |= bit else self.settings_of &= ~bit;
                self.peer_settings = self.settings_of != 0;
                self.note(.{ .settings = x });
            },
        }
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
    pub fn flushPads(self: *Session) void {
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
        // A join at this tick may make the delay longer from now on (the host's driver sets its
        // own).
        if (self.config.role == .guest) for (self.events[0..self.events_len]) |e| {
            if (e.tick == self.next and e.what == .join and e.delay > self.delay) self.delay = e.delay;
        };
        self.sample(local);
        if (self.remote_count <= self.next or self.local_count <= self.next) {
            // The peer left, and its last pads ran out.
            if (self.peer_left or self.leaving != null) self.over(self.leaving orelse .left);
            return null;
        }
        for (&self.others) |*o| if (o.active(self.next) and o.count <= self.next) return null;
        const slot = self.next % window;
        var out: input.Pads = .{};
        out.at(self.localPlayer()).* = @bitCast(self.local[slot]);
        out.at(self.peerPlayer()).* = @bitCast(self.remote[slot]);
        for (&self.others, 0..) |*o, k| if (o.active(self.next)) {
            out.at(k).* = @bitCast(o.pads[slot]);
        };
        return out;
    }

    /// The local player's pad `local` is the pad of the ticks from the last sampled to tick
    /// `next + delay` (one a tick; more when the delay grew), and the peer gets them.
    pub fn sample(self: *Session, local: input.Pad) void {
        if (self.phase != .playing) return;
        const target = self.next + self.delay;
        var sampled = false;
        while (self.local_count <= target and self.local_count - self.peer_ack < window - 1) {
            self.local[self.local_count % window] = @bitCast(local);
            self.local_count += 1;
            sampled = true;
        }
        if (sampled or self.sent_upto < self.local_count) self.flushPads();
    }

    /// The host's own pad of tick `t` as this session has it (sampled, `t` before
    /// `local_count`).
    pub fn localPad(self: *const Session, t: u32) u8 {
        return self.local[t % window];
    }

    /// The host: this client leaves the session once its pads run out (`why`: it said goodbye,
    /// or did not come back in time), at the tick its pads reach (`remote_count`).
    pub fn leaveWhenOut(self: *Session, why: End) void {
        if (self.config.role != .host or self.phase != .playing) return;
        self.leaving = why;
        self.lost_at = null;
    }

    /// The host relays player `player`'s pads, as `src` (that client's session) has them, from
    /// the first this client lacks.
    pub fn relayOf(self: *Session, player: input.Player, src: *const Session) void {
        if (self.config.role != .host or self.phase != .playing or !self.welcomed) return;
        const n_ = &self.relay_next[player];
        // What `src` no longer keeps is past this client's need (both run the same ticks).
        n_.* = @max(n_.*, src.next -| keep);
        while (n_.* < src.remote_count) {
            const n = @min(src.remote_count - n_.*, protocol.max_pads);
            var run: [protocol.max_pads]u8 = undefined;
            for (0..n) |k| run[k] = src.remote[(n_.* + @as(u32, @intCast(k))) % window];
            self.send(.{ .relay = .{ .player = player, .first = n_.*, .pads = run[0..n] } });
            n_.* += n;
        }
    }

    /// The host relays player `player`'s pads to this client from tick `from` on (its first
    /// `delay` pads there empty for each machine when it joined after this client).
    pub fn relayFrom(self: *Session, player: input.Player, from: u32) void {
        self.relay_from[player] = from;
        self.relay_next[player] = from;
    }

    /// A connection that came back gets the other clients' pads again, from those it may lack.
    pub fn relayAgain(self: *Session) void {
        for (&self.relay_next, self.relay_from) |*n_, from| n_.* = @max(from, @min(n_.*, self.next -| self.delay -| 1));
    }

    fn onRelay(self: *Session, r: protocol.Relay) Verdict {
        if (self.config.role != .guest or self.phase != .playing or r.player == self.place) return .unexpected;
        const o = &self.others[r.player];
        if (o.from == null) return .unexpected;
        const count: u32 = @intCast(r.pads.len);
        if (r.first + count <= o.count) return .duplicate;
        if (r.first > o.count) return .out_of_order;
        var i = o.count - r.first;
        while (i < count) : (i += 1) {
            const t = r.first + i;
            if (t >= self.next + window - 1) return .ahead;
            o.pads[t % window] = r.pads[i];
            o.count = t + 1;
        }
        return .accepted;
    }

    /// The host changes the game at the first tick whose pads it has not sent (`change`, its tick
    /// set here: its player leaves, or comes back, or the rules change): the client hears it
    /// before those pads. Returns the tick, or null when no session runs or a change is still to
    /// come.
    pub fn schedule(self: *Session, change: protocol.Event) ?u32 {
        return self.scheduleAt(change, self.local_count);
    }

    /// The same at tick `at`, which no machine of the session has run yet (the host's driver
    /// chooses it: a player who leaves goes at the tick its pads ran out).
    pub fn scheduleAt(self: *Session, change: protocol.Event, at: u32) ?u32 {
        if (self.config.role != .host or self.phase != .playing or at < self.next) return null;
        var e = change;
        e.tick = at;
        if (!self.keepEvent(e)) return null;
        self.send(.{ .event = e });
        return e.tick;
    }

    /// `e` among the changes to come, in their ticks' order (after those of its tick); false
    /// when there is no room.
    fn keepEvent(self: *Session, e: protocol.Event) bool {
        if (self.events_len == max_events) return false;
        var i: usize = self.events_len;
        while (i > 0 and self.events[i - 1].tick > e.tick) : (i -= 1) self.events[i] = self.events[i - 1];
        self.events[i] = e;
        self.events_len += 1;
        return true;
    }

    fn dropEvent(self: *Session, i: usize) void {
        std.mem.copyForwards(protocol.Event, self.events[i .. self.events_len - 1], self.events[i + 1 .. self.events_len]);
        self.events_len -= 1;
    }

    fn onEvent(self: *Session, e: protocol.Event) Verdict {
        if (self.config.role != .guest or self.phase != .playing) return .unexpected;
        for (self.events[0..self.events_len]) |was| if (std.meta.eql(was, e)) return .duplicate;
        // Sent again on a resumed connection, after its tick ran here.
        for (self.made) |m| if (m) |x| if (std.meta.eql(x, e)) return .duplicate;
        // Its tick ran already: the games would differ.
        if (e.tick < self.next or !self.keepEvent(e)) return .malformed;
        switch (e.what) {
            // Another client joins: in the session from its tick, its first pads empty.
            .join => if (e.player != self.place) {
                const o = &self.others[e.player];
                o.* = .{ .from = e.tick, .count = e.tick + e.delay };
            },
            // Another client leaves: its pads are not needed from its tick.
            .leave, .cpu => if (e.player != 0 and e.player != self.place) {
                self.others[e.player].until = e.tick;
            },
            else => {},
        }
        return .accepted;
    }

    /// The first change of the game before the next tick, if any (the game makes it, then runs
    /// the tick).
    pub fn eventAt(self: *const Session) ?protocol.Event {
        if (self.events_len == 0 or self.phase != .playing) return null;
        const e = self.events[0];
        return if (e.tick == self.next) e else null;
    }

    /// The same, taken: the guest's game makes each change before the next tick in turn.
    pub fn takeEvent(self: *Session) ?protocol.Event {
        const e = self.eventAt() orelse return null;
        if (self.config.role == .guest) {
            self.dropEvent(0);
            self.made[self.made_at] = e;
            self.made_at = (self.made_at + 1) % max_events;
        }
        return e;
    }

    /// Tick `next` ran with the pads that `pads` gave.
    pub fn ran(self: *Session) void {
        if (self.phase == .observing) {
            self.next += 1;
            return;
        }
        var i: usize = 0;
        while (i < self.events_len) {
            const e = self.events[i];
            // The host keeps one until the client has its pads past its tick; the guest made it.
            const done = e.tick <= self.next and (self.config.role == .guest or self.peer_ack > e.tick);
            if (!done) {
                i += 1;
                continue;
            }
            self.dropEvent(i);
            if (self.config.role == .guest) {
                self.made[self.made_at] = e;
                self.made_at = (self.made_at + 1) % max_events;
            }
        }
        // The slack: the peer's pads in hand beyond this tick, averaged over about 16.
        const in_hand: i32 = @as(i32, @intCast(self.remote_count - self.next - 1)) * 256;
        self.slack += @divFloor(in_hand - self.slack, 16);
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

    /// The host stops this session at another client's mismatch: its client is told, and stops.
    pub fn stopAtDesync(self: *Session) void {
        if (self.config.role != .host or self.phase != .playing) return;
        self.send(.{ .bye = .desync });
        self.phase = .desynced;
        self.desync_at = self.next;
        self.peer_chunks = done_chunks;
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
        host.observed(.{ .pad1 = @bitCast(@as(u8, @intCast(t))), .pad2 = @bitCast(@as(u8, @intCast(t + 100))) }, 2);
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
    host.observed(.{}, 2);
    try testing.expectEqual(@as(usize, 0), host.outbox.items.len);
}

test "an observer whose ticks outran its window asks for the host's game again, and watches on" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var watcher = try Session.init(testing.allocator, .{ .role = .guest, .build = protocol.buildId("test"), .data = @splat(1), .name = "ANN".* }, canonical.diffFn(TestState));
    defer watcher.deinit();
    try welcomePair(&host, &watcher);
    watcher.askObserve();
    _ = pump(&watcher, &host, 0);
    var buf: [canonical.maxSize(TestState)]u8 = undefined;
    host.beginObserve(formOf(.{ .x = 7 }, &buf), 5);
    _ = pump(&host, &watcher, 0);
    try testing.expect(watcher.phase == .observing);
    // The host runs 300 ticks while the observer runs none (its page hidden): those past its
    // window are lost, and it asks for the game again, once.
    for (0..300) |t| host.observed(.{ .pad1 = @bitCast(@as(u8, @truncate(t))) }, 2);
    host.flushTicks();
    _ = pump(&host, &watcher, 0);
    try testing.expect(watcher.resync_asked and watcher.outbox.items.len == 1);
    try testing.expectEqual(Verdict.accepted, pump(&watcher, &host, 0));
    try testing.expect(host.phase == .observing and host.observe_asked);
    // The host's game as it is now: the observer watches on from it, its ticks from 0.
    host.beginObserve(formOf(.{ .x = 9 }, &buf), 6);
    _ = pump(&host, &watcher, 0);
    try testing.expect(watcher.phase == .observing and !watcher.resync_asked and watcher.seen_count == 0);
    try testing.expectEqualSlices(u8, formOf(.{ .x = 9 }, &buf), watcher.gameForm());
    for (0..10) |t| host.observed(.{ .pad1 = @bitCast(@as(u8, @intCast(t + 50))) }, 2);
    host.flushTicks();
    _ = pump(&host, &watcher, 0);
    for (0..10) |t| {
        const got = watcher.pads(.{}) orelse return error.Held;
        try testing.expectEqual(@as(u8, @intCast(t + 50)), @as(u8, @bitCast(got.pad1)));
        watcher.ran();
    }
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
        host.observed(.{}, 2);
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

test "a guest in player 4's place: the game's chunks say it, and each machine's pad is its player's" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try welcomePair(&host, &guest);
    host.setStatus(.{ .game = .play, .character = 1 });
    _ = pump(&host, &guest, 0);
    guest.askJoin(2);
    _ = pump(&guest, &host, 0);
    host.place = 3;
    var buf: [canonical.maxSize(TestState)]u8 = undefined;
    host.begin(formOf(.{ .x = 3 }, &buf), 5);
    _ = pump(&host, &guest, 5);
    try testing.expect(hasNote(&guest, .joined));
    try testing.expectEqual(@as(input.Player, 3), guest.place);
    try testing.expectEqual(@as(input.Player, 3), guest.localPlayer());
    try testing.expectEqual(@as(input.Player, 0), guest.peerPlayer());
    // Past the delay, each side's pad of tick 2 is in player 1's and player 4's places alike (the
    // host's first two pads, empty, reach the guest with its third).
    for (0..2) |_| {
        _ = host.pads(.{ .a = true }) orelse return error.Held;
        host.ran();
        _ = pump(&host, &guest, 5);
        _ = guest.pads(.{ .c = true }) orelse return error.Held;
        guest.ran();
    }
    _ = pump(&host, &guest, 5);
    _ = pump(&guest, &host, 5);
    const h = host.pads(.{}) orelse return error.Held;
    const g = guest.pads(.{}) orelse return error.Held;
    try testing.expect(std.meta.eql(h, g));
    try testing.expect(h.pad1.a and h.pad4.c and @as(u8, @bitCast(h.pad2)) == 0 and @as(u8, @bitCast(h.pad3)) == 0);
}

test "an observer of a game of four players gets each tick's four pads" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var watcher = try testSession(.guest, null);
    defer watcher.deinit();
    try welcomePair(&host, &watcher);
    watcher.askObserve();
    _ = pump(&watcher, &host, 0);
    var buf: [canonical.maxSize(TestState)]u8 = undefined;
    host.beginObserve(formOf(.{}, &buf), 5);
    _ = pump(&host, &watcher, 0);
    // Two ticks of a game of two, then a run of a game of four (its message apart).
    for (0..2) |t| host.observed(.{ .pad1 = @bitCast(@as(u8, @intCast(t + 1))), .pad2 = @bitCast(@as(u8, 9)) }, 2);
    for (0..6) |t| {
        const b: u8 = @intCast(10 * t);
        host.observed(.{ .pad1 = @bitCast(b + 1), .pad2 = @bitCast(b + 2), .pad3 = @bitCast(b + 3), .pad4 = @bitCast(b + 4) }, 4);
    }
    host.flushTicks();
    try testing.expectEqual(@as(usize, 2), host.outbox.items.len);
    _ = pump(&host, &watcher, 0);
    try testing.expectEqual(@as(u32, 8), watcher.seen_count);
    for (0..8) |t| {
        const got = watcher.pads(.{}) orelse return error.Held;
        if (t < 2) {
            try testing.expectEqual(@as(u8, @intCast(t + 1)), @as(u8, @bitCast(got.pad1)));
            try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(got.pad3)));
        } else {
            const b: u8 = @intCast(10 * (t - 2));
            for (0..4) |k| try testing.expectEqual(b + @as(u8, @intCast(k)) + 1, @as(u8, @bitCast(got.of(k))));
        }
        watcher.ran();
    }
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
    try testing.expectEqual(Verdict.duplicate, guest.receive(encodeMsg(.{ .settings = .{ .open = true } }, &buf), 0));
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
    try testing.expectEqual(Verdict.unexpected, fresh.receive(encodeMsg(.{ .settings = .{ .open = true } }, &buf), 0));
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
    // A second change before the same tick comes after the first.
    try testing.expectEqual(@as(?u32, at), host.schedule(.{ .tick = 0, .what = .back, .character = 1 }));
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
    try testing.expect(host.events_len == 0 and guest.events_len == 0);
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

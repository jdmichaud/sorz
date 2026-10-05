//! The netplay session of one peer (DESIGN.md 9): delay-based input lockstep between a host
//! (player 1) and a guest (player 2), outside the simulation and without I/O. The driver
//! (netplay.zig) gives it the connection's events and messages and the game's pads and state
//! checks; it answers with the merged pads of each display tick, the messages to send (`outbox`)
//! and what happened (`notes`).
//!
//! - **Handshake.** The guest sends `hello` (versions, data identity, the session it had). A new
//!   session: the host pings to measure the round trip, picks the input delay D from it (2 to 6
//!   ticks) and answers `welcome` (fresh), with what its game starts with (`start`, its variant:
//!   the guest's game takes it); both games then start from power-on. The same session
//!   after a dropped connection: `welcome` (not fresh), and each peer resends the pads the other
//!   lacks. Different versions or data: `reject`.
//! - **Pads.** Before tick N runs, the peer samples its pad for tick N + D and sends it; the pads
//!   of ticks 0 to D - 1 are empty on both sides. Tick N runs once both pads for N are in; until
//!   then the game holds (`pads` returns null).
//! - **State checks.** Every `check_interval` ticks each peer sends the hash of its state's
//!   canonical form before that tick, and keeps the form. A hash that differs from the peer's stops
//!   the session (`desynced`): the peers exchange those forms and name the first differing field.
//! - **Clock balancing.** Each peer measures its slack, how many of the peer's pads it holds beyond
//!   the tick it runs, and sends it; the peer ahead (the one with less slack) stretches its sound
//!   (`stretchPpm`) until they are level.
//! - **The settings screen.** A game whose player opens it holds, and sends no pads: the other
//!   holds too once the pads it has run out (D ticks at most). Each side says when its player
//!   opens or closes the screen (`inSettings`), so that the other can tell its player why it holds
//!   (`peer_settings`); a connection that comes back or a new session says it again.
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
    /// What the host's game starts with, which its welcome gives the guest (the game sets it
    /// before the session starts).
    start: protocol.Start = .{},
};

/// The pads that the session keeps on each side, ticks in a ring.
pub const window = 256;
/// The peer's pads kept after their tick ran, to tell a duplicate from a conflict.
pub const keep = 128;
/// Ticks between two state checks (twice a second: a corrupted byte is found within one).
pub const check_interval = 30;
/// The pings of a new session's handshake.
pub const handshake_pings = 4;
/// Pings in play, which keep the round trip known and the connection alive.
pub const ping_interval_ns: u64 = std.time.ns_per_s;
/// A connection silent this long is dead: the driver closes it (and the guest reconnects).
pub const silence_ns: u64 = 10 * std.time.ns_per_s;
/// The largest stretch of the sound, in parts per million (0.5 %).
pub const max_stretch_ppm: u32 = 5000;

/// A display tick's time in nanoseconds, for the input delay.
const tick_ns: u64 = @import("../sound_out.zig").tick_ps / 1000;

pub const Phase = enum {
    /// No session yet: the host waits for a guest, the guest for its connection.
    idle,
    /// A connection is up and the handshake runs.
    handshake,
    /// The session runs (held while the connection is down).
    playing,
    /// The states differed at a check: the session stopped.
    desynced,
    /// Refused, or the peer left.
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
    /// A message of the protocol out of place (pads before the welcome, a second hello...).
    unexpected,
    /// A hello that the host refused (another version, build or data), or the host's refusal.
    refused,
};

pub const Note = union(enum) {
    /// The session starts (`fresh`: from power-on, so the game resets) or resumes.
    started: struct { fresh: bool, delay: u8, tick: u32 },
    /// The host refused the guest, or was refused.
    refused: protocol.RejectReason,
    /// The states differed at the check before tick `tick`.
    desync: u32,
    /// The first differing field (null: the forms were the same after all, or ours was not
    /// kept).
    diagnosed: ?canonical.Difference,
    /// The peer left.
    left: protocol.ByeReason,
    /// The peer's player opened the settings screen (true) or closed it.
    settings: bool,
};

/// A state's canonical form, kept for a check (owned room for the longest).
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
    /// The handshake of this connection is done: pads and hashes may be sent.
    welcomed: bool = false,
    /// The driver should close the connection (after a refusal, a farewell or a silence).
    close_requested: bool = false,
    /// The peer said farewell: the ticks whose pads are in still run, then the session ends.
    peer_left: bool = false,
    id: u64 = 0,
    delay: u8 = 0,
    /// What both games start with, once the session has started: the host's.
    start: ?protocol.Start = null,
    random: std.Random.SplitMix64 = .init(0),

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
        const room = try allocator.alloc(u8, 3 * protocol.max_state_len);
        return .{
            .allocator = allocator,
            .config = config,
            .diff = diff,
            .snapshot_forms = .{ .{ .bytes = room[0..protocol.max_state_len] }, .{ .bytes = room[protocol.max_state_len .. 2 * protocol.max_state_len] } },
            .peer_form = .{ .bytes = room[2 * protocol.max_state_len ..] },
        };
    }

    pub fn deinit(self: *Session) void {
        self.clearOutbox();
        self.outbox.deinit(self.allocator);
        self.notes.deinit(self.allocator);
        self.allocator.free(self.snapshot_forms[0].bytes.ptr[0 .. 3 * protocol.max_state_len]);
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
        return .{ .hello = .{ .build = self.config.build, .data = self.config.data, .session = self.id, .resume_from = self.remote_count } };
    }

    // --- the connection --------------------------------------------------------------------

    /// The connection to the peer is up. The guest opens the handshake.
    pub fn connectedAt(self: *Session, now_ns: u64) void {
        self.connected = true;
        self.welcomed = false;
        self.close_requested = false;
        self.last_heard_ns = now_ns;
        self.last_ping_ns = now_ns;
        self.handshake_pongs = 0;
        self.handshake_rtt_ns = 0;
        if (self.phase == .idle) self.phase = .handshake;
        if (self.config.role == .guest and self.phase != .ended) self.send(self.hello());
    }

    /// The connection is down: a session in play holds until the guest is back.
    pub fn disconnected(self: *Session) void {
        self.connected = false;
        self.welcomed = false;
        self.peer_settings = false;
        self.close_requested = false;
        self.clearOutbox();
        if (self.phase == .handshake) self.phase = .idle;
    }

    /// Timers: the pings in play, the silence of a dead connection. (The handshake's pings go one
    /// after the other, each on the pong of the one before.)
    pub fn tick(self: *Session, now_ns: u64) void {
        if (!self.connected) return;
        if (now_ns -| self.last_heard_ns > silence_ns) {
            self.close_requested = true;
            return;
        }
        if (self.welcomed and now_ns -| self.last_ping_ns >= ping_interval_ns) self.ping(now_ns);
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
                // A host still busy with this guest's broken connection: the guest tries again.
                if (!(r == .busy and self.phase == .playing)) self.phase = .ended;
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
            .bye => |r| blk: {
                self.note(.{ .left = r });
                self.close_requested = true;
                // The ticks whose pads are in still run; then the session is over.
                if (self.phase == .playing) {
                    self.peer_left = true;
                } else self.over();
                break :blk .accepted;
            },
        };
    }

    /// The peer left: the host waits for a new guest (a new session), the guest is done.
    fn over(self: *Session) void {
        self.peer_left = false;
        if (self.config.role == .host and self.phase != .desynced) {
            self.phase = .idle;
            self.id = 0;
        } else self.phase = .ended;
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
        const resumable = h.session != 0 and h.session == self.id and self.phase == .playing and
            h.resume_from <= self.local_count and self.local_count - h.resume_from < window;
        if (resumable) {
            self.send(.{ .welcome = .{ .session = self.id, .delay = self.delay, .fresh = false, .resume_from = self.remote_count, .start = self.start orelse self.config.start } });
            self.resumeFrom(h.resume_from);
            return .accepted;
        }
        // A new session. With a fixed delay it starts at once; else after the pings.
        self.phase = .handshake;
        if (self.config.delay) |d| {
            self.startFresh(self.newId(now_ns), d);
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
                self.startFresh(self.newId(now_ns), delayFor(self.handshake_rtt_ns));
            } else self.ping(now_ns);
        }
        return .accepted;
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
        if (w.fresh) {
            self.start = w.start;
            self.startFresh(w.session, w.delay);
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

    /// Both sides start from power-on with empty pads for the first `delay` ticks.
    fn startFresh(self: *Session, id: u64, delay: u8) void {
        if (self.config.role == .host) {
            self.start = self.config.start;
            self.send(.{ .welcome = .{ .session = id, .delay = delay, .fresh = true, .resume_from = 0, .start = self.config.start } });
        }
        self.id = id;
        self.delay = delay;
        self.phase = .playing;
        self.welcomed = true;
        self.peer_left = false;
        self.next = 0;
        self.local_count = delay;
        self.remote_count = delay;
        self.peer_ack = delay;
        self.sent_upto = delay;
        self.local = @splat(0);
        self.remote = @splat(0);
        self.have = .empty;
        for (0..delay) |i| self.have.set(i);
        self.slack = 0;
        self.peer_slack = null;
        self.own = @splat(null);
        self.theirs = @splat(null);
        self.snapshots = .{ null, null };
        self.desync_at = null;
        self.peer_chunks = 0;
        self.early_tick = null;
        self.peer_settings = false;
        if (self.local_settings) self.send(.{ .settings = true });
        self.note(.{ .started = .{ .fresh = true, .delay = delay, .tick = 0 } });
    }

    /// The same session goes on: the pads the peer lacks, and our recent hashes, again.
    fn resumeFrom(self: *Session, peer_has: u32) void {
        self.welcomed = true;
        self.peer_ack = @max(self.peer_ack, peer_has);
        self.sent_upto = peer_has;
        self.flushPads();
        for (self.own) |h| if (h) |x| self.send(.{ .hash = x.hash });
        if (self.local_settings) self.send(.{ .settings = true });
        self.note(.{ .started = .{ .fresh = false, .delay = self.delay, .tick = self.next } });
    }

    /// The input delay for a round trip: the one-way time in ticks, rounded up, plus one.
    pub fn delayFor(rtt_ns: u64) u8 {
        const one_way = rtt_ns / 2;
        const ticks = (one_way + tick_ns - 1) / tick_ns + 1;
        return @intCast(std.math.clamp(ticks, protocol.min_delay, protocol.max_delay));
    }

    // --- the settings screen -----------------------------------------------------------------

    /// Our player opened the settings screen (`open`) or closed it: the peer is told.
    pub fn inSettings(self: *Session, open: bool) void {
        if (open == self.local_settings) return;
        self.local_settings = open;
        if (self.welcomed) self.send(.{ .settings = open });
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

    /// The pads of the next tick, or null while it must hold. `local` is the local player's pad
    /// now: it becomes the pad of tick `next + delay`, sampled once per tick.
    pub fn pads(self: *Session, local: input.Pad) ?input.Pads {
        if (self.phase != .playing) return null;
        const target = self.next + self.delay;
        if (self.local_count == target and self.local_count - self.peer_ack < window - 1) {
            self.local[target % window] = @bitCast(local);
            self.local_count += 1;
            self.flushPads();
        }
        if (self.remote_count <= self.next or self.local_count <= self.next) {
            // The peer left, and its last pads ran out.
            if (self.peer_left) self.over();
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

    /// Tick `next` ran with the pads that `pads` gave.
    pub fn ran(self: *Session) void {
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
        const a = self.advantage() - 64;
        if (a <= 0) return 0;
        return @intCast(@min(@as(i64, max_stretch_ppm), @divFloor(@as(i64, a) * max_stretch_ppm, 256)));
    }

    // --- state checks ----------------------------------------------------------------------

    /// Whether the state before tick `next` is due for a check.
    pub fn checkDue(self: *const Session) bool {
        const o = self.own[slotOf(self.next)];
        return self.phase == .playing and self.next != 0 and self.next % check_interval == 0 and
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
        self.send(.{ .hash = h });
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
        if (self.phase != .playing) return if (self.phase == .desynced) .stale else .unexpected;
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
        self.phase = .desynced;
        self.desync_at = t;
        self.note(.{ .desync = t });
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

fn startPair(host: *Session, guest: *Session) !void {
    host.connectedAt(0);
    guest.connectedAt(0);
    while (host.phase != .playing or guest.phase != .playing) {
        _ = pump(guest, host, 1000);
        _ = pump(host, guest, 1000);
        if (host.phase == .ended or guest.phase == .ended) return error.Refused;
    }
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

fn formOf(s: TestState, buf: *[canonical.size(TestState)]u8) []const u8 {
    return canonical.write(TestState, &s, buf);
}

test "a new session: the round trip picks the delay, both start at power-on" {
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
    try testing.expectEqual(Phase.playing, host.phase);
    try testing.expectEqual(@as(u8, 3), host.delay);
    _ = pump(&host, &guest, now);
    try testing.expectEqual(Phase.playing, guest.phase);
    try testing.expectEqual(host.id, guest.id);
    try testing.expectEqual(host.delay, guest.delay);
    try testing.expect(guest.notes.items[0].started.fresh);
    try testing.expectEqual(@as(u8, 2), Session.delayFor(0));
    try testing.expectEqual(@as(u8, 4), Session.delayFor(100 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u8, 6), Session.delayFor(std.time.ns_per_s));
    // The first `delay` ticks need no message.
    for (0..3) |_| {
        try testing.expect(host.pads(.{}) != null);
        host.ran();
    }
    // Tick 3 needs the guest's pad for it, which the guest sends before its tick 0.
    try testing.expectEqual(@as(?input.Pads, null), host.pads(.{}));
    _ = guest.pads(.{ .b = true });
    _ = pump(&guest, &host, now);
    try testing.expect(host.pads(.{}).?.pad2.b);
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
    // Pads before the session: out of place.
    host.connectedAt(0);
    guest.connectedAt(0);
    _ = pump(&guest, &host, 0);
    try testing.expectEqual(Phase.playing, host.phase);
    try testing.expectEqual(Verdict.unexpected, guest.receive(encodeMsg(.{ .pads = .{ .first = 2, .ack = 0, .slack = 0, .pads = &.{1} } }, &buf), 0));
    _ = pump(&host, &guest, 0);
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
    // A hello once welcomed, and a welcome to the host, are out of place.
    try testing.expectEqual(Verdict.unexpected, host.receive(encodeMsg(guest.hello(), &buf), 0));
    try testing.expectEqual(Verdict.unexpected, host.receive(encodeMsg(.{ .welcome = .{ .session = 1, .delay = 2, .fresh = true, .resume_from = 0 } }, &buf), 0));
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
    host.disconnected();
    guest.disconnected();
    try testing.expectEqual(Phase.playing, host.phase);
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
    try testing.expect(!host.notes.getLast().started.fresh);
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

    // A guest that restarted (no session) starts a new session: both from power-on.
    host.disconnected();
    var fresh = try testSession(.guest, null);
    defer fresh.deinit();
    host.connectedAt(9);
    fresh.connectedAt(9);
    _ = pump(&fresh, &host, 9);
    _ = pump(&host, &fresh, 9);
    try testing.expect(host.notes.getLast().started.fresh);
    try testing.expectEqual(@as(u32, 0), host.next);
    try testing.expectEqual(host.id, fresh.id);
    try testing.expect(host.id != guest.id);
}

test "a state mismatch stops both and names the first differing field" {
    var host = try testSession(.host, 2);
    defer host.deinit();
    var guest = try testSession(.guest, null);
    defer guest.deinit();
    try startPair(&host, &guest);
    var a_buf: [canonical.size(TestState)]u8 = undefined;
    var b_buf: [canonical.size(TestState)]u8 = undefined;
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
    var b_buf: [canonical.size(TestState)]u8 = undefined;
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
    guest.disconnected();
    guest.connectedAt(0);
    try testing.expectEqual(Verdict.refused, guest.receive(busy, 0));
    try testing.expectEqual(Phase.playing, guest.phase);
    try testing.expect(guest.close_requested);
}

test "the peer ahead stretches its sound, up to 0.5 %" {
    var s = try testSession(.host, 3);
    defer s.deinit();
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
    host.disconnected();
    guest.disconnected();
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

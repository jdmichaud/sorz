//! Network play between agent hosts in one process (DESIGN.md 9): two to four agent backends joined
//! by the in-memory network, each with its netplay driver and a small deterministic state in place
//! of the game. Each peer does what game.zig does with the session: the host's game alone until
//! the first guest joins it (its form crossing), then one tick per update, the local pad sampled
//! for tick N + D, the changes of the game at their ticks (another guest's join, its session
//! beginning there), the hold, the state checks. The real game's joins are netplay-check's (the
//! user's ROM).
const std = @import("std");
const sorz = @import("sorz");
const AgentBackend = @import("backend.zig").AgentBackend;

const platform = sorz.platform;
const net = sorz.net;
const canonical = sorz.canonical;
const Pad = sorz.input.Pad;
const Pads = sorz.input.Pads;

const frame_ns: u64 = sorz.sound_out.tick_ps / 1000 + 1;

/// A stand-in for the game's state: two players that move, score and draw from a random
/// generator, in a canonical form so that a mismatch names its field.
const FakeState = struct {
    frame: u32 = 0,
    seed: u32 = 625341585,
    x: [2]u16 = .{ 100, 200 },
    y: [2]u16 = .{ 50, 50 },
    score: [2]u16 = .{ 0, 0 },
    /// Players 3 and 4's.
    more: [2]u16 = .{ 0, 0 },

    fn step(s: *FakeState, pads: Pads) void {
        s.frame +%= 1;
        s.seed = s.seed *% 1103515245 +% 12345;
        for ([2]Pad{ pads.pad1, pads.pad2 }, 0..) |b, i| {
            if (b.left) s.x[i] -%= 1;
            if (b.right) s.x[i] +%= 1;
            if (b.up) s.y[i] -%= 1;
            if (b.down) s.y[i] +%= 1;
            if (b.b and (s.seed >> 16) & 3 == 0) s.score[i] +%= 1;
            if (b.start) s.x[i] ^= @truncate(s.seed);
        }
        for ([2]Pad{ pads.pad3, pads.pad4 }, &s.more) |b, *m| m.* = m.* *% 31 +% @as(u8, @bitCast(b));
    }

    fn hash(s: *const FakeState) u64 {
        return canonical.hash(FakeState, s);
    }
};

/// The pads a player holds when its game is about to run tick `t`: changes every few ticks.
fn hostScript(t: u32) Pad {
    return @bitCast(@as(u8, @truncate((t / 7) *% 2654435761 >> 13)));
}

fn guestScript(t: u32) Pad {
    return @bitCast(@as(u8, @truncate((t / 5 + 11) *% 2246822507 >> 17)));
}

fn thirdScript(t: u32) Pad {
    return @bitCast(@as(u8, @truncate((t / 3 + 5) *% 3266489917 >> 11)));
}

fn fourthScript(t: u32) Pad {
    return @bitCast(@as(u8, @truncate((t / 4 + 7) *% 668265263 >> 15)) | 1);
}

const Peer = struct {
    backend: AgentBackend,
    np: net.netplay.Netplay,
    script: *const fn (u32) Pad,
    state: FakeState = .{},
    /// The merged pads of each tick run.
    pads: std.ArrayList(Pads) = .empty,
    held: u32 = 0,
    /// The session's ticks it ran before the join (its own game alone: the host's runs on).
    alone: u32 = 0,
    /// Test hook: the tick before which one byte of the state is corrupted.
    corrupt_at: ?u32 = null,
    /// The work its game does in each update (the stats' busy share).
    work_ns: u64 = 0,
    /// The host: its game's players (its network options' PLAYERS).
    places: u8 = 2,
    /// The guest: another player's dropped connection the host said (its player, its seconds).
    away: ?net.protocol.Away = null,

    fn create(network: *net.memory.Network, role: net.netplay.Role, delay: ?u8, script: *const fn (u32) Pad) !*Peer {
        return createAs(network, role, delay, script, .{ ' ', ' ', ' ' });
    }

    fn createAs(network: *net.memory.Network, role: net.netplay.Role, delay: ?u8, script: *const fn (u32) Pad, name: net.protocol.Name) !*Peer {
        const gpa = std.testing.allocator;
        const peer = try gpa.create(Peer);
        errdefer gpa.destroy(peer);
        peer.* = .{
            .backend = AgentBackend.init(gpa, .{}),
            .np = try net.netplay.Netplay.init(gpa, .{
                .role = role,
                .address = if (role == .host) "7000" else "ws://localhost:7000",
                .build = net.protocol.buildId("test"),
                .data = @splat(7),
                .delay = delay,
                .log = false,
                .name = name,
            }, canonical.diffFn(FakeState)),
            .script = script,
        };
        peer.backend.transport = (try network.endpoint()).transport();
        var p = peer.backend.asPlatform();
        _ = try p.start();
        try peer.np.start(&p);
        // The host's session opens at once (its network options' START); the guest connects as it
        // starts.
        if (role == .host) try peer.np.openSession(&p, true, false, true);
        return peer;
    }

    fn destroy(peer: *Peer) void {
        peer.np.deinit();
        peer.backend.deinit();
        peer.pads.deinit(std.testing.allocator);
        std.testing.allocator.destroy(peer);
    }

    /// One update of the agent host: the events, the session, at most one tick.
    fn update(peer: *Peer) !void {
        return peer.updateTo(std.math.maxInt(u32));
    }

    /// An update that runs no session tick past `limit`. Before the join, the host's game runs
    /// alone, a tick an update; the guest asks to join once welcomed, and takes the host's game.
    fn updateTo(peer: *Peer, limit: u32) !void {
        var p = peer.backend.asPlatform();
        var buf: [16]platform.Event = undefined;
        while (true) {
            const n = p.pollEvents(&buf);
            if (n == 0) break;
            for (buf[0..n]) |e| _ = peer.np.handle(&p, e);
        }
        peer.np.update(&p);
        peer.np.worked(peer.work_ns);
        for (peer.np.pending()) |note| switch (note) {
            .joined => {
                try canonical.read(FakeState, peer.np.gameForm(), &peer.state);
                peer.pads.clearRetainingCapacity();
            },
            .welcomed => if (peer.np.role == .guest) peer.np.askJoin(&p, net.protocol.no_character),
            .away => |a| peer.away = a,
            else => {},
        };
        peer.np.clearNotes();
        // The host takes a join in its first free place: a new session, or the one under way at a
        // tick to come.
        if (peer.np.role == .host) if (peer.np.joinAsked()) |ask| {
            var place: ?sorz.input.Player = null;
            for (1..peer.places) |k| if (!peer.np.placeTaken(k)) {
                place = @intCast(k);
                break;
            };
            if (place) |k| {
                if (!peer.np.inSession()) {
                    var form: [canonical.maxSize(FakeState)]u8 = undefined;
                    peer.np.begin(&p, ask.peer, k, canonical.write(FakeState, &peer.state, &form));
                    peer.pads.clearRetainingCapacity();
                } else if (!peer.np.scheduleJoin(&p, ask.peer, k, net.protocol.no_character, net.protocol.no_character, ask.peer.session.peer_name)) {
                    peer.np.declineJoin(&p, ask.peer);
                }
            } else if (!peer.np.inSession()) {
                peer.np.declineJoin(&p, ask.peer);
            }
        };
        // A client's connection not back in time: it leaves the game.
        if (peer.np.role == .host) if (peer.np.lostFor()) |t| if (t > net.session.rejoin_ns) peer.np.giveUp(&p);
        if (!peer.np.inSession()) {
            // Its own game, alone (the guest's is replaced at the join).
            if (peer.np.role == .host) {
                peer.state.step(.{ .pad1 = peer.script(peer.alone) });
                peer.alone += 1;
            }
            peer.backend.advance(frame_ns);
            return;
        }
        const t = peer.np.tick();
        const merged = if (t < limit) peer.np.pads(&p, peer.script(t)) else null;
        if (merged) |pads| {
            // A join at this tick: on the host, its client's session begins from the game now.
            while (peer.np.takeEvent()) |e| if (peer.np.role == .host and e.what == .join) {
                var form: [canonical.maxSize(FakeState)]u8 = undefined;
                peer.np.beginJoin(&p, @intCast(e.player), canonical.write(FakeState, &peer.state, &form));
            };
            peer.state.step(pads);
            try peer.pads.append(std.testing.allocator, pads);
            peer.np.ran();
            if (peer.corrupt_at) |c| if (c == peer.np.tick()) {
                peer.state.score[1] ^= 64;
            };
            if (peer.np.checkDue()) {
                var form: [canonical.maxSize(FakeState)]u8 = undefined;
                peer.np.check(&p, peer.state.hash(), canonical.write(FakeState, &peer.state, &form));
            }
        } else peer.held += 1;
        peer.backend.advance(frame_ns);
    }
};

/// Updates both peers in turn until both ran `ticks` ticks of a session, or `max_updates` pass.
fn runUntil(host: *Peer, guest: *Peer, ticks: u32, max_updates: u32) !void {
    var n: u32 = 0;
    while (!host.np.inSession() or !guest.np.inSession() or host.np.tick() < ticks or guest.np.tick() < ticks) : (n += 1) {
        if (n == max_updates) return error.Timeout;
        try host.updateTo(ticks);
        try guest.updateTo(ticks);
    }
}

/// The state that one game reaches from `from` with the pads that the two scripts give through a
/// session of input delay `delay`: the pad sampled before tick N is the pad of tick N + D.
fn reference(from: FakeState, ticks: u32, delay: u32) FakeState {
    var s = from;
    for (0..ticks) |i| {
        const t: u32 = @intCast(i);
        const pads: Pads = if (t < delay) .{} else .{ .pad1 = hostScript(t - delay), .pad2 = guestScript(t - delay) };
        s.step(pads);
    }
    return s;
}

/// The host's game alone for `alone` ticks: where the session starts.
fn aloneFor(alone: u32) FakeState {
    var s: FakeState = .{};
    for (0..alone) |i| s.step(.{ .pad1 = hostScript(@intCast(i)) });
    return s;
}

fn expectSameGame(host: *Peer, guest: *Peer, ticks: u32) !void {
    try std.testing.expectEqual(host.pads.items.len, guest.pads.items.len);
    for (host.pads.items, guest.pads.items) |a, b| try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(host.state.hash(), guest.state.hash());
    const want = reference(aloneFor(host.alone), ticks, host.np.delay());
    try std.testing.expectEqual(want.hash(), host.state.hash());
}

test "two agent hosts: the guest joins the host's game, and both play it with the merged pads" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try Peer.create(&network, .host, 3, hostScript);
    defer host.destroy();
    const guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    try runUntil(host, guest, 600, 700);
    try std.testing.expectEqual(@as(u8, 3), guest.np.delay());
    // The host's game ran alone while the guest came: the session starts from where it was.
    try std.testing.expect(host.alone > 0);
    try expectSameGame(host, guest, 600);
    // Twenty checks passed; no hold after the start.
    try std.testing.expectEqual(net.session.Phase.playing, host.np.phase());
    try std.testing.expect(host.np.player().?.session.own[0] != null);
}

test "with latency, the round trip picks the delay and the game holds when a pad is late" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    network.latency_ns = 45 * std.time.ns_per_ms;
    const host = try Peer.create(&network, .host, null, hostScript);
    defer host.destroy();
    const guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    try runUntil(host, guest, 400, 900);
    // 45 ms each way, seen at 60 updates a second: 5 or 6 ticks of delay.
    try std.testing.expect(host.np.delay() >= 5);
    try expectSameGame(host, guest, 400);

    // A delay too short for the latency: both hold, and still play the same game.
    var n2 = net.memory.Network.init(std.testing.allocator);
    defer n2.deinit();
    n2.latency_ns = 80 * std.time.ns_per_ms;
    const h2 = try Peer.create(&n2, .host, 2, hostScript);
    defer h2.destroy();
    const g2 = try Peer.create(&n2, .guest, null, guestScript);
    defer g2.destroy();
    try runUntil(h2, g2, 300, 2000);
    try std.testing.expect(h2.held > 100 and g2.held > 100);
    try expectSameGame(h2, g2, 300);
}

test "the stats: each machine's second, and the other's beside it; a busy machine, a slow link" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try Peer.create(&network, .host, 3, hostScript);
    defer host.destroy();
    const guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    // The guest's game works 15 ms of each update's 16.7.
    guest.work_ns = 15 * std.time.ns_per_ms;
    try runUntil(host, guest, 300, 400);
    const h = host.np.stats().?;
    const g = guest.np.stats().?;
    try std.testing.expect(h.local.ticks >= 59 and h.local.ticks <= 61 and h.local.busy == 0 and h.local.wait == 0);
    try std.testing.expect(g.local.busy >= 88 and g.local.busy <= 92);
    // Each has the other's: the host sees its guest busy.
    try std.testing.expectEqual(g.local, h.peer.?);
    try std.testing.expectEqual(h.local, g.peer.?);
    try std.testing.expect(h.host and !g.host);
    try std.testing.expectEqual(@as(u8, 3), h.delay);

    // A delay too short for an 80 ms link: both wait, and run fewer ticks; the ping shows it.
    var n2 = net.memory.Network.init(std.testing.allocator);
    defer n2.deinit();
    n2.latency_ns = 80 * std.time.ns_per_ms;
    const h2 = try Peer.create(&n2, .host, 2, hostScript);
    defer h2.destroy();
    const g2 = try Peer.create(&n2, .guest, null, guestScript);
    defer g2.destroy();
    try runUntil(h2, g2, 200, 2000);
    const s2 = h2.np.stats().?;
    try std.testing.expect(s2.local.wait > 20 and s2.peer.?.wait > 20 and s2.local.ticks < 50 and s2.local.busy == 0);
    try std.testing.expect(s2.local.ping >= 150 and s2.peer.?.ping >= 150);
    // Outside a session: none.
    const apart = try Peer.create(&n2, .guest, null, guestScript);
    defer apart.destroy();
    try std.testing.expectEqual(@as(?net.netplay.Stats, null), apart.np.stats());
}

test "a dropped connection holds both games; the guest reconnects and the same session resumes" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try Peer.create(&network, .host, 4, hostScript);
    defer host.destroy();
    const guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    try runUntil(host, guest, 200, 300);
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(host.backend.transport.?.context));
    network.breakLink(endpoint, host.np.player().?.connection.?);
    const at = host.np.tick();
    // For half a second of updates, neither runs more than the pads it already had.
    for (0..30) |_| {
        try host.update();
        try guest.update();
    }
    try std.testing.expect(host.np.tick() <= at + 4 and guest.np.tick() <= at + 4);
    try std.testing.expect(host.np.player().?.connection == null and host.np.lostFor() != null);
    // The guest tries again after a second, and both go on.
    try runUntil(host, guest, 600, 800);
    try std.testing.expectEqual(@as(u32, 1), host.np.sessions);
    try expectSameGame(host, guest, 600);
}

test "a guest that reconnects before the host sees its old connection go resumes its session" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try Peer.create(&network, .host, 4, hostScript);
    defer host.destroy();
    const guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    try runUntil(host, guest, 200, 300);
    // The guest's side alone breaks (its network roams): the host hears nothing, and still has
    // the old connection when the guest's comes back, a second later.
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(guest.backend.transport.?.context));
    network.breakOneSide(endpoint, guest.np.peers.items[0].connection.?);
    try runUntil(host, guest, 600, 800);
    try std.testing.expectEqual(@as(u32, 1), host.np.sessions);
    try expectSameGame(host, guest, 600);
}

test "a byte corrupted on one side is found within a second and its field is named" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try Peer.create(&network, .host, 3, hostScript);
    defer host.destroy();
    const guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    guest.corrupt_at = 131;
    runUntil(host, guest, 400, 600) catch {};
    try std.testing.expectEqual(net.session.Phase.desynced, host.np.phase());
    try std.testing.expectEqual(net.session.Phase.desynced, guest.np.phase());
    // The corruption before tick 131 is seen at the check before tick 150: 19 ticks.
    const at = host.np.player().?.session.desync_at.?;
    try std.testing.expectEqual(@as(u32, 150), at);
    for ([_]*Peer{ host, guest }) |peer| {
        const d = peer.np.difference.?;
        try std.testing.expectEqualStrings("score[1]", d.name());
        try std.testing.expectEqual(@as(u32, 18 * 8), d.offset);
    }
    try std.testing.expectEqual(host.np.difference.?.ours, guest.np.difference.?.theirs);
    // Both games stopped at once.
    try std.testing.expect(host.np.tick() < at + 10 and guest.np.tick() < at + 10);
}

test "a guest that quits ends the session; a new guest joins the host's game as it is; a third waits in the lobby" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try Peer.create(&network, .host, 2, hostScript);
    defer host.destroy();
    var guest = try Peer.create(&network, .guest, null, guestScript);
    try runUntil(host, guest, 150, 250);
    // The guest's game quits (a farewell).
    var p = guest.backend.asPlatform();
    guest.np.quit(&p);
    guest.destroy();
    // The host heard the farewell, ran the ticks whose pads it had (the delay's two), and plays its
    // own game alone again, waiting for another guest.
    for (0..5) |_| try host.update();
    try std.testing.expect(!host.np.inSession() and host.np.phase() == .lobby);
    try std.testing.expectEqual(@as(u32, 152), host.np.tick() + 152);
    guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    host.alone = 0;
    host.state = .{};
    try runUntil(host, guest, 100, 200);
    try std.testing.expectEqual(@as(u32, 2), host.np.sessions);
    try expectSameGame(host, guest, 100);

    // A third game asks to join while the guest plays: it is welcomed to the host's lobby, but no
    // place is free; the guest plays on.
    const third = try Peer.create(&network, .guest, null, guestScript);
    defer third.destroy();
    for (0..20) |_| {
        try host.update();
        try guest.update();
        try third.update();
    }
    try std.testing.expect(third.np.welcomed() and !third.np.hostStatus().place and !third.np.inSession());
    try std.testing.expectEqual(net.session.Phase.playing, guest.np.phase());
    try std.testing.expectEqual(@as(usize, 2), host.np.peers.items.len);
}

test "a game without content has no game to join: its network play waits in the lobby" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const gpa = std.testing.allocator;
    var games: [2]struct { backend: AgentBackend, game: sorz.Game } = undefined;
    for (&games, [_]net.netplay.Role{ .host, .guest }) |*x, role| {
        x.* = .{ .backend = AgentBackend.init(gpa, .{}), .game = try sorz.Game.init(gpa, null, null) };
        x.backend.transport = (try network.endpoint()).transport();
        x.game.pacing = .per_update;
        x.game.variant = .network;
        try x.game.startNetplay(.{
            .role = role,
            .address = if (role == .host) "7000" else "ws://localhost:7000",
            .build = net.protocol.buildId(sorz.version.build),
            .data = @splat(0),
            .delay = if (role == .host) 2 else null,
            .log = false,
        });
    }
    defer for (&games) |*x| {
        x.game.deinit();
        x.backend.deinit();
    };
    for (0..120) |_| for (&games) |*x| {
        var p = x.backend.asPlatform();
        _ = try x.game.update(&p);
        x.backend.advance(frame_ns);
    };
    // Each runs its own test pattern; the guest never wanted to join: no session.
    try std.testing.expect(games[0].game.state.tick >= 119 and games[1].game.state.tick >= 119);
    try std.testing.expect(!games[0].game.netplay.?.inSession() and games[1].game.netplay.?.phase() == .idle);
    try std.testing.expect(games[1].game.isClient() and !games[0].game.isClient());
}

// --- three and four machines (PLAN item 51) ------------------------------------------------------

/// Updates every peer in turn (but the frozen) until each ran `ticks` ticks of a session, or
/// `max_updates` pass.
fn runAll(peers: []const *Peer, ticks: u32, max_updates: u32) !void {
    var n: u32 = 0;
    while (true) : (n += 1) {
        var done = true;
        for (peers) |x| done = done and x.np.inSession() and x.np.tick() >= ticks;
        if (done) return;
        if (n == max_updates) return error.Timeout;
        for (peers) |x| try x.updateTo(ticks);
    }
}

/// The session's first tick on a guest (its join).
fn startOf(peer: *const Peer) u32 {
    return peer.np.peers.items[0].session.start;
}

/// Every guest ran the host's ticks from its join with the same pads, to the same state.
fn expectSameGames(host: *Peer, guests: []const *Peer) !void {
    for (guests) |g| {
        const from = startOf(g);
        try std.testing.expectEqual(host.np.tick(), g.np.tick());
        try std.testing.expectEqual(host.pads.items.len - from, g.pads.items.len);
        for (host.pads.items[from..], g.pads.items) |a, b| try std.testing.expectEqual(a, b);
        try std.testing.expectEqual(host.state.hash(), g.state.hash());
    }
}

/// Whether player `k`'s pads were ever pressed in the host's ticks from `from` to `to`.
fn pressed(host: *const Peer, k: usize, from: u32, to: u32) bool {
    for (host.pads.items[from..to]) |x| if (@as(u8, @bitCast(x.of(k))) != 0) return true;
    return false;
}

const Four = struct {
    network: net.memory.Network,
    host: *Peer,
    guests: [3]*Peer,

    fn init(self: *Four, n: usize) !void {
        self.network = net.memory.Network.init(std.testing.allocator);
        self.host = try Peer.create(&self.network, .host, 3, hostScript);
        self.host.places = @intCast(n);
        const scripts = [3]*const fn (u32) Pad{ guestScript, thirdScript, fourthScript };
        const names = [3][3]u8{ "ANN".*, "BOB".*, "CAT".* };
        for (&self.guests, scripts, names, 0..) |*g, sc, name, i| g.* = if (i < n - 1) try Peer.createAs(&self.network, .guest, null, sc, name) else undefined;
    }

    fn deinit(self: *Four, n: usize) void {
        for (self.guests[0 .. n - 1]) |g| g.destroy();
        self.host.destroy();
        self.network.deinit();
    }
};

test "four agent hosts: clients join one after another, each its place; the same game everywhere" {
    var r: Four = undefined;
    try r.init(4);
    defer r.deinit(4);
    const host = r.host;
    // The first client alone, then the second joins the session under way, then the third.
    try runAll(&.{ host, r.guests[0] }, 100, 300);
    try runAll(&.{ host, r.guests[0], r.guests[1] }, 250, 400);
    try runAll(&.{ host, r.guests[0], r.guests[1], r.guests[2] }, 450, 500);
    for (r.guests, 1..) |g, k| try std.testing.expectEqual(@as(sorz.input.Player, @intCast(k)), g.np.localPlayer());
    try std.testing.expect(startOf(r.guests[0]) == 0 and startOf(r.guests[1]) > 100 and startOf(r.guests[2]) > 250);
    try expectSameGames(host, &r.guests);
    // Each player's pads are its own machine's, relayed to the others: players 3 and 4 pressed
    // nothing before their joins (and their first D ticks), something after.
    const third = startOf(r.guests[1]);
    const fourth = startOf(r.guests[2]);
    try std.testing.expect(!pressed(host, 2, 0, third + 3) and pressed(host, 2, third + 3, fourth));
    try std.testing.expect(!pressed(host, 3, 0, fourth + 3) and pressed(host, 3, fourth + 3, 450));
    try std.testing.expectEqual(@as(u32, 1), host.np.sessions);
    // A fifth game finds no place: welcomed, it waits in the lobby; the others play on.
    const fifth = try Peer.create(&r.network, .guest, null, guestScript);
    defer fifth.destroy();
    try runAll(&.{ host, r.guests[0], r.guests[1], r.guests[2] }, 500, 200);
    for (0..20) |_| for ([_]*Peer{ host, r.guests[0], r.guests[1], r.guests[2], fifth }) |x| try x.update();
    try std.testing.expect(fifth.np.welcomed() and !fifth.np.inSession());
    try std.testing.expectEqual(@as(usize, 3), host.np.memberCount());
    // The roster: every client by its name and player.
    var entries: [8]net.netplay.Entry = undefined;
    const list = host.np.roster(&entries);
    var buf: [24]u8 = undefined;
    var lines: [3][]const u8 = undefined;
    var n: usize = 0;
    for (list) |e| if (e.doing == .player) {
        lines[n] = try std.testing.allocator.dupe(u8, e.line(&buf));
        n += 1;
    };
    defer for (lines[0..n]) |l| std.testing.allocator.free(l);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("ANN - PLAYER 2", lines[0]);
    try std.testing.expectEqualStrings("BOB - PLAYER 3", lines[1]);
    try std.testing.expectEqualStrings("CAT - PLAYER 4", lines[2]);
}

test "three agent hosts: the stats list every machine, the host relaying each client's" {
    var r: Four = undefined;
    try r.init(3);
    defer r.deinit(3);
    r.guests[1].work_ns = 15 * std.time.ns_per_ms;
    try runAll(&.{ r.host, r.guests[0], r.guests[1] }, 400, 600);
    const h = r.host.np.stats().?;
    const a = r.guests[0].np.stats().?;
    const b = r.guests[1].np.stats().?;
    for ([_]net.netplay.Stats{ h, a, b }) |x| {
        for (x.machines[0..3]) |m| try std.testing.expect(m.in and m.load != null);
        try std.testing.expect(!x.machines[3].in);
    }
    // The busy third machine, as itself, the host and the second see it.
    try std.testing.expect(b.machines[2].load.?.busy >= 88);
    try std.testing.expect(h.machines[2].load.?.busy >= 88 and a.machines[2].load.?.busy >= 88);
    try std.testing.expect(a.machines[1].load.?.busy == 0 and std.mem.eql(u8, &h.machines[1].name, "ANN"));
}

test "a client that leaves a session of four: the others play on, its player out from the tick its pads ran out" {
    var r: Four = undefined;
    try r.init(4);
    const host = r.host;
    try runAll(&.{ host, r.guests[0], r.guests[1], r.guests[2] }, 200, 600);
    // Player 3's game quits.
    var p = r.guests[1].backend.asPlatform();
    r.guests[1].np.quit(&p);
    r.guests[1].destroy();
    const rest = [_]*Peer{ host, r.guests[0], r.guests[2] };
    try runAll(&rest, 400, 400);
    try std.testing.expectEqual(@as(usize, 2), host.np.memberCount());
    try std.testing.expect(!host.np.placeTaken(2));
    try expectSameGames(host, &.{ r.guests[0], r.guests[2] });
    // From some tick on, player 3 presses nothing on any machine; players 2 and 4 play on.
    try std.testing.expect(!pressed(host, 2, 220, 400) and pressed(host, 1, 220, 400) and pressed(host, 3, 220, 400));
    r.guests[2].destroy();
    r.guests[0].destroy();
    host.destroy();
    r.network.deinit();
}

test "a dropped connection in a session of three: every machine holds, told whose; back in time, it goes on; not back, the others play on" {
    var r: Four = undefined;
    try r.init(3);
    defer r.deinit(3);
    const host = r.host;
    const all = [_]*Peer{ host, r.guests[0], r.guests[1] };
    try runAll(&all, 200, 400);
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(host.backend.transport.?.context));
    r.network.breakLink(endpoint, host.np.member(2).?.connection.?);
    const at = host.np.tick();
    for (0..30) |_| for (all) |x| try x.update();
    for (all) |x| try std.testing.expect(x.np.tick() <= at + 4);
    try std.testing.expectEqual(@as(sorz.input.Player, 2), host.np.lostPlayer().?.player);
    // The other client is told whose connection is down, and the seconds left.
    try std.testing.expect(r.guests[0].away != null and r.guests[0].away.?.player == 2 and r.guests[0].away.?.seconds > 0);
    // Back a second later: the same session goes on, every machine in step.
    try runAll(&all, 500, 800);
    try std.testing.expectEqual(@as(u32, 1), host.np.sessions);
    try expectSameGames(host, &.{ r.guests[0], r.guests[1] });
    // Down again, and not back in time (its machine gone quiet): after the wait, the host and the
    // other client play on without it.
    r.network.breakLink(endpoint, host.np.member(2).?.connection.?);
    const two = [_]*Peer{ host, r.guests[0] };
    var n: u32 = 0;
    while (host.np.tick() < 700) : (n += 1) {
        if (n == 1200) return error.Timeout;
        for (two) |x| try x.update();
    }
    try std.testing.expect(n > 290);
    try runAll(&two, 720, 100);
    try std.testing.expectEqual(@as(usize, 1), host.np.memberCount());
    const from = startOf(r.guests[0]);
    for (host.pads.items[from..720], r.guests[0].pads.items[0..720]) |a, b| try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(host.state.hash(), r.guests[0].state.hash());
    try std.testing.expect(r.guests[0].away.?.seconds == 0);
}

test "a byte corrupted on one client of three is found and named; every machine stops" {
    var r: Four = undefined;
    try r.init(3);
    defer r.deinit(3);
    r.guests[1].corrupt_at = 131;
    runAll(&.{ r.host, r.guests[0], r.guests[1] }, 400, 600) catch {};
    for ([_]*Peer{ r.host, r.guests[0], r.guests[1] }) |x| try std.testing.expectEqual(net.session.Phase.desynced, x.np.phase());
    try std.testing.expectEqualStrings("score[1]", r.host.np.difference.?.name());
    try std.testing.expectEqualStrings("score[1]", r.guests[1].np.difference.?.name());
    // The other client stopped with them, told, with no field of its own to name.
    try std.testing.expect(r.guests[0].np.difference == null and r.guests[0].np.tick() < 160);
}

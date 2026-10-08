//! Network play between agent hosts in one process (DESIGN.md 9): two agent backends joined by the
//! in-memory network, each with its netplay driver and a small deterministic state in place of the
//! game. Each peer does what game.zig does with the session: the host's game alone until the
//! guest joins it (its form crossing), then one tick per update, the local pad sampled for tick
//! N + D, the hold, the state checks. The real game's joins are netplay-check's (the user's ROM).
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

    fn create(network: *net.memory.Network, role: net.netplay.Role, delay: ?u8, script: *const fn (u32) Pad) !*Peer {
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
        for (peer.np.pending()) |note| switch (note) {
            .joined => {
                try canonical.read(FakeState, peer.np.gameForm(), &peer.state);
                peer.pads.clearRetainingCapacity();
            },
            .welcomed => if (peer.np.role == .guest) peer.np.askJoin(&p, net.protocol.no_character),
            else => {},
        };
        peer.np.clearNotes();
        if (peer.np.role == .host and !peer.np.inSession()) if (peer.np.joinAsked()) |ask| {
            var form: [canonical.maxSize(FakeState)]u8 = undefined;
            peer.np.begin(&p, ask.peer, canonical.write(FakeState, &peer.state, &form));
            peer.pads.clearRetainingCapacity();
        };
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
    try std.testing.expect(host.np.player.?.session.own[0] != null);
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

test "a dropped connection holds both games; the guest reconnects and the same session resumes" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try Peer.create(&network, .host, 4, hostScript);
    defer host.destroy();
    const guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    try runUntil(host, guest, 200, 300);
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(host.backend.transport.?.context));
    network.breakLink(endpoint, host.np.player.?.connection.?);
    const at = host.np.tick();
    // For half a second of updates, neither runs more than the pads it already had.
    for (0..30) |_| {
        try host.update();
        try guest.update();
    }
    try std.testing.expect(host.np.tick() <= at + 4 and guest.np.tick() <= at + 4);
    try std.testing.expect(host.np.player.?.connection == null and host.np.lostFor() != null);
    // The guest tries again after a second, and both go on.
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
    const at = host.np.player.?.session.desync_at.?;
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
    try std.testing.expect(games[1].game.guest and !games[0].game.guest);
}

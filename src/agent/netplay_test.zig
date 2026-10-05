//! Network play between agent hosts in one process (DESIGN.md 9): two agent backends joined by the
//! in-memory network, each with its netplay driver and a small deterministic state in place of the
//! game, then the game itself. Each peer does what game.zig does with the session: one tick per
//! update, the local pad sampled for tick N + D, the hold, the reset of a new session, the state
//! checks.
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
    epoch: u32 = 0,
    /// The merged pads of each tick run.
    pads: std.ArrayList(Pads) = .empty,
    held: u32 = 0,
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

    /// An update that runs no tick past `limit`.
    fn updateTo(peer: *Peer, limit: u32) !void {
        var p = peer.backend.asPlatform();
        var buf: [16]platform.Event = undefined;
        while (true) {
            const n = p.pollEvents(&buf);
            if (n == 0) break;
            for (buf[0..n]) |e| _ = peer.np.handle(&p, e);
        }
        peer.np.update(&p);
        if (peer.np.epoch != peer.epoch) {
            // A new session: power-on.
            peer.epoch = peer.np.epoch;
            peer.state = .{};
            peer.pads.clearRetainingCapacity();
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

/// Updates both peers in turn until both ran `ticks` ticks, or `max_updates` pass.
fn runUntil(host: *Peer, guest: *Peer, ticks: u32, max_updates: u32) !void {
    var n: u32 = 0;
    while (host.np.tick() < ticks or guest.np.tick() < ticks) : (n += 1) {
        if (n == max_updates) return error.Timeout;
        try host.updateTo(ticks);
        try guest.updateTo(ticks);
    }
}

/// The state that one game reaches with the pads that the two scripts give through a session of
/// input delay `delay`: the pad sampled before tick N is the pad of tick N + D.
fn reference(ticks: u32, delay: u32) FakeState {
    var s: FakeState = .{};
    for (0..ticks) |i| {
        const t: u32 = @intCast(i);
        const pads: Pads = if (t < delay) .{} else .{ .pad1 = hostScript(t - delay), .pad2 = guestScript(t - delay) };
        s.step(pads);
    }
    return s;
}

fn expectSameGame(host: *Peer, guest: *Peer, ticks: u32) !void {
    try std.testing.expectEqual(host.pads.items.len, guest.pads.items.len);
    for (host.pads.items, guest.pads.items) |a, b| try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(host.state.hash(), guest.state.hash());
    const want = reference(ticks, host.np.session.delay);
    try std.testing.expectEqual(want.hash(), host.state.hash());
    try std.testing.expectEqual(ticks, host.state.frame);
}

test "two agent hosts play a scripted session: the state of one game given the merged pads" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try Peer.create(&network, .host, 3, hostScript);
    defer host.destroy();
    const guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    try runUntil(host, guest, 600, 700);
    try std.testing.expectEqual(@as(u8, 3), guest.np.session.delay);
    try expectSameGame(host, guest, 600);
    // Twenty checks passed; no hold after the start.
    try std.testing.expectEqual(net.session.Phase.playing, host.np.phase());
    try std.testing.expect(host.np.session.own[0] != null);
}

test "with latency, the round trip picks the delay and the game holds when a pad is late" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    network.latency_ns = 45 * std.time.ns_per_ms;
    const host = try Peer.create(&network, .host, null, hostScript);
    defer host.destroy();
    const guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    try runUntil(host, guest, 400, 800);
    // 45 ms each way, seen at 60 updates a second: 5 or 6 ticks of delay.
    try std.testing.expect(host.np.session.delay >= 5);
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
    network.breakLink(endpoint, host.np.peer.?);
    const at = host.np.tick();
    // For half a second of updates, neither runs more than the pads it already had.
    for (0..30) |_| {
        try host.update();
        try guest.update();
    }
    try std.testing.expect(host.np.tick() <= at + 4 and guest.np.tick() <= at + 4);
    try std.testing.expect(host.np.peer == null);
    // The guest tries again after a second, and both go on.
    try runUntil(host, guest, 600, 800);
    try std.testing.expectEqual(@as(u32, 1), host.np.epoch);
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
    runUntil(host, guest, 400, 500) catch {};
    try std.testing.expectEqual(net.session.Phase.desynced, host.np.phase());
    try std.testing.expectEqual(net.session.Phase.desynced, guest.np.phase());
    // The corruption before tick 131 is seen at the check before tick 150: 19 ticks.
    const at = host.np.session.desync_at.?;
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

test "a guest that restarts starts a new session: both games from power-on; a second is turned away" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try Peer.create(&network, .host, 2, hostScript);
    defer host.destroy();
    var guest = try Peer.create(&network, .guest, null, guestScript);
    try runUntil(host, guest, 150, 200);
    // The guest's game quits (a farewell) and starts again.
    var p = guest.backend.asPlatform();
    guest.np.quit(&p);
    guest.destroy();
    // The host heard the farewell, ran the ticks whose pads it had (the delay's two), and waits for
    // a new guest; its game holds.
    for (0..5) |_| try host.update();
    try std.testing.expectEqual(net.session.Phase.idle, host.np.phase());
    try std.testing.expectEqual(@as(u32, 152), host.np.tick());
    guest = try Peer.create(&network, .guest, null, guestScript);
    defer guest.destroy();
    try runUntil(host, guest, 100, 200);
    try std.testing.expectEqual(@as(u32, 2), host.np.epoch);
    try expectSameGame(host, guest, 100);

    // A third game asks to join while the guest plays: it is refused.
    const third = try Peer.create(&network, .guest, null, guestScript);
    defer third.destroy();
    for (0..5) |_| {
        try host.update();
        try guest.update();
        try third.update();
    }
    try std.testing.expectEqual(net.session.Phase.ended, third.np.phase());
    try std.testing.expectEqual(net.session.Phase.playing, guest.np.phase());
}

/// A game of the agent host in a session: only the session's ticks run, through game.zig.
const GamePeer = struct {
    backend: AgentBackend,
    game: sorz.Game,

    fn create(network: *net.memory.Network, role: net.netplay.Role) !*GamePeer {
        const gpa = std.testing.allocator;
        const g = try gpa.create(GamePeer);
        errdefer gpa.destroy(g);
        g.* = .{ .backend = AgentBackend.init(gpa, .{}), .game = try sorz.Game.init(gpa, null, null) };
        g.backend.transport = (try network.endpoint()).transport();
        g.game.pacing = .per_update;
        try g.game.startNetplay(.{
            .role = role,
            .address = if (role == .host) "7000" else "ws://localhost:7000",
            .build = net.protocol.buildId(sorz.version.build),
            .data = @splat(0),
            .delay = if (role == .host) 2 else null,
            .log = false,
        });
        return g;
    }

    fn destroy(g: *GamePeer) void {
        g.game.deinit();
        g.backend.deinit();
        std.testing.allocator.destroy(g);
    }

    fn update(g: *GamePeer) !sorz.game.UpdateResult {
        var p = g.backend.asPlatform();
        const r = try g.game.update(&p);
        g.backend.advance(frame_ns);
        return r;
    }

    fn key(g: *GamePeer, k: platform.Key, down: bool) !void {
        const e: platform.Event.KeyEvent = .{ .key = k };
        try g.backend.inject(.{ .time_ns = g.backend.clock_ns, .payload = if (down) .{ .key_down = e } else .{ .key_up = e } });
    }
};

test "two games in a session run the session's ticks in step, with both players' pads, hold together, and part" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try GamePeer.create(&network, .host);
    defer host.destroy();
    const guest = try GamePeer.create(&network, .guest);
    defer guest.destroy();
    // Each holds pad 1's right on its machine: the host's player 1 and the guest's player 2 move.
    try host.key(.right, true);
    try guest.key(.right, true);
    for (0..300) |_| {
        _ = try host.update();
        _ = try guest.update();
    }
    const h = host.game.state.tick;
    try std.testing.expect(h > 290);
    try std.testing.expect(h >= guest.game.state.tick -| 2 and h <= guest.game.state.tick + 2);
    try std.testing.expectEqual(@as(u32, 1), host.game.net_epoch);
    const markers = host.game.state.scenes.base.test_pattern.markers;
    try std.testing.expect(markers[0].x > 96 + 200 and markers[1].x > 216);
    // At one tick, both games have one state.
    while (guest.game.state.tick < host.game.state.tick) _ = try guest.update();
    while (host.game.state.tick < guest.game.state.tick) _ = try host.update();
    try std.testing.expectEqual(host.game.stateHash(), guest.game.stateHash());
    // The cable is pulled: neither runs more than the delay's ticks.
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(host.backend.transport.?.context));
    network.breakLink(endpoint, host.game.netplay.?.peer.?);
    const at = host.game.state.tick;
    for (0..40) |_| {
        _ = try host.update();
        _ = try guest.update();
    }
    try std.testing.expect(host.game.state.tick <= at + 4);
    // The guest is back after a second; they go on together.
    for (0..100) |_| {
        _ = try host.update();
        _ = try guest.update();
    }
    try std.testing.expect(host.game.state.tick > at + 30);
    try std.testing.expectEqual(@as(u32, 1), guest.game.net_epoch);
    // The guest quits: the host waits for another.
    try guest.key(.escape, true);
    try std.testing.expectEqual(sorz.game.UpdateResult.finished, try guest.update());
    for (0..5) |_| _ = try host.update();
    try std.testing.expectEqual(net.session.Phase.idle, host.game.netplay.?.phase());
}

test "a game whose state was corrupted stops at the next check, and both name the field" {
    var network = net.memory.Network.init(std.testing.allocator);
    defer network.deinit();
    const host = try GamePeer.create(&network, .host);
    defer host.destroy();
    const guest = try GamePeer.create(&network, .guest);
    defer guest.destroy();
    var corrupted = false;
    for (0..100) |_| {
        _ = try host.update();
        _ = try guest.update();
        if (!corrupted and guest.game.state.tick >= 47) {
            guest.game.state.scenes.base.test_pattern.markers[1].y ^= 1;
            corrupted = true;
        }
    }
    for ([_]*GamePeer{ host, guest }) |g| {
        const np = g.game.netplay.?;
        try std.testing.expectEqual(net.session.Phase.desynced, np.phase());
        try std.testing.expectEqualStrings("scenes.base.test_pattern.markers[1].y", np.difference.?.name());
        try std.testing.expect(g.game.state.tick <= 70);
    }
}

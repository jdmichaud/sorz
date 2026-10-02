//! The agent host's network play (DESIGN.md 9): the game in a session, driven by scripted keys.
//!
//! - `process`: `sorz-agent [DIR] --netplay [ADDRESS:]PORT` or `--join ws://ADDRESS:PORT`, over the
//!   native WebSocket transport, so that two processes (or an agent and the SDL game, or a page)
//!   play one session. `--frames N` counts the session's ticks; the virtual clock advances a tick
//!   per tick run, and an update that holds waits a millisecond of real time for the peer and
//!   advances the clock as much.
//! - `pair`: `sorz-agent [DIR] --pair`, two games in one process over the in-memory network, the
//!   host's keys from `--key` and the guest's from `--guest-key`, then a third game alone with the
//!   merged pads: the three states must be the same. `--corrupt TICK` flips a bit of the guest's
//!   state before that tick: both games must stop at the next check and name the field.
//!
//! In a session a key is pressed by tick: `--key F:NAME:H` holds the key from the update that
//! samples the pad of tick F + D (D the input delay) and releases it H ticks later. The keys are
//! pad 1's on both machines (the arrows, Z, X, C, Enter).
const std = @import("std");
const sorz = @import("sorz");
const AgentBackend = @import("backend.zig").AgentBackend;
const native = @import("native");

const platform = sorz.platform;
const net = sorz.net;

/// A tick's time, as the agent host's clock counts it (rounded up).
pub const frame_ns: u64 = sorz.sound_out.tick_ps / 1000 + 1;

pub const Press = struct { frame: u64, key: platform.Key, hold: u64 = 1 };

/// A game's scripted keys, injected by the session's tick.
const Script = struct {
    presses: []const Press,
    /// Per press: 0 not yet pressed, 1 held, 2 released.
    done: []u2,

    fn init(gpa: std.mem.Allocator, presses: []const Press) !Script {
        const done = try gpa.alloc(u2, presses.len);
        @memset(done, 0);
        return .{ .presses = presses, .done = done };
    }

    fn deinit(s: *Script, gpa: std.mem.Allocator) void {
        gpa.free(s.done);
    }

    /// Injects the key events due before the update that samples the pad at tick `t`.
    fn inject(s: *Script, backend: *AgentBackend, t: u64) !void {
        for (s.presses, s.done) |press, *d| {
            if (d.* == 0 and t >= press.frame) {
                try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_down = .{ .key = press.key } } });
                d.* = 1;
            }
            if (d.* == 1 and t >= press.frame +| press.hold) {
                try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_up = .{ .key = press.key } } });
                d.* = 2;
            }
        }
    }
};

fn writeGame(w: *std.Io.Writer, label: []const u8, game: *const sorz.Game) !void {
    try w.print("\"{s}\":{{\"ticks\":{d},\"updates\":{d},\"state_hash\":\"{x:0>16}\"", .{ label, game.state.tick, game.update_count, game.stateHash() });
    if (game.netplay) |n| {
        try w.print(",\"phase\":\"{s}\",\"delay\":{d},\"epoch\":{d}", .{ @tagName(n.phase()), n.session.delay, n.epoch });
        if (n.difference) |d| try w.print(",\"difference\":\"{f}\"", .{d});
    }
    try w.writeAll("}");
}

/// One game of a session over WebSockets, until it ran `frames` of the session's ticks. Returns
/// false when the session did not get there (refused, stalled, desynced). A host serves the page
/// and the game's files of `served` (its own data) to a guest's browser.
pub fn process(
    gpa: std.mem.Allocator,
    io: std.Io,
    assets: ?platform.AssetSource,
    storage: platform.Storage,
    options: sorz.net.netplay.Options,
    page: native.net.Page,
    served: ?platform.AssetSource,
    frames: u64,
    presses: []const Press,
    out: *std.Io.Writer,
) !bool {
    var side: native.cli.Netplay = undefined;
    try side.init(gpa, io, page, if (options.role == .host) served else null);
    defer side.deinit();
    var backend = AgentBackend.init(gpa, .{});
    defer backend.deinit();
    backend.transport = side.transport.transport();
    var game = try sorz.Game.init(gpa, assets, storage);
    defer game.deinit();
    game.pacing = .per_update;
    try game.startNetplay(options);
    var script = try Script.init(gpa, presses);
    defer script.deinit(gpa);
    var p = backend.asPlatform();
    // No progress for this long (real time) ends the run: no peer, or a stopped session.
    const stall_ns: i96 = 60 * std.time.ns_per_s;
    var last_progress = std.Io.Clock.awake.now(io).toNanoseconds();
    var last_tick: u64 = 0;
    var finished = false;
    while (true) {
        const t: u64 = if (game.started) game.netplay.?.tick() else 0;
        if (t >= frames) break;
        try script.inject(&backend, t);
        if (try game.update(&p) == .finished) {
            finished = true;
            break;
        }
        const np = game.netplay.?;
        if (np.phase() == .ended or (np.phase() == .desynced and np.difference != null)) break;
        const now = std.Io.Clock.awake.now(io).toNanoseconds();
        if (np.tick() != last_tick) {
            last_tick = np.tick();
            last_progress = now;
            backend.advance(frame_ns);
        } else {
            if (now - last_progress > stall_ns) break;
            // While it holds, the clock follows the real time the peer takes, so that the
            // session's timers (the pings, a silent connection) count real time.
            try io.sleep(.fromMilliseconds(1), .awake);
            backend.advance(std.time.ns_per_ms);
        }
    }
    const np = game.netplay.?;
    const ok = !finished and np.tick() >= frames and np.phase() == .playing;
    // The peer may still need this game's last pads: the transport's close sends them first. (A
    // game that finished has quit already.)
    if (!finished) game.netplay.?.quit(&p);
    try out.writeAll("{");
    try writeGame(out, if (options.role == .host) "host" else "guest", &game);
    try out.print(",\"verdict\":\"{s}\"}}\n", .{if (ok) "ok" else "incomplete"});
    return ok;
}

/// Two games in one process over the in-memory network, and a third alone with their merged
/// pads. Returns whether the three ended in the same state (with `corrupt`: whether both games
/// stopped and named the field).
pub fn pair(
    gpa: std.mem.Allocator,
    assets: ?platform.AssetSource,
    identity: net.protocol.DataId,
    delay: u8,
    frames: u64,
    host_presses: []const Press,
    guest_presses: []const Press,
    /// The negative control: before this tick, one bit of the guest's state flips.
    corrupt: ?u64,
    out: *std.Io.Writer,
) !bool {
    var network = net.memory.Network.init(gpa);
    defer network.deinit();
    const Side = struct {
        backend: AgentBackend,
        game: sorz.Game,
        script: Script,
    };
    var sides: [2]Side = undefined;
    var made: usize = 0;
    defer for (sides[0..made]) |*s| {
        s.game.deinit();
        s.backend.deinit();
        s.script.deinit(gpa);
    };
    for (&sides, 0..) |*s, i| {
        const host = i == 0;
        // Each part made, then the side counted: the defer above releases whole sides only.
        var script = try Script.init(gpa, if (host) host_presses else guest_presses);
        const game = sorz.Game.init(gpa, assets, null) catch |err| {
            script.deinit(gpa);
            return err;
        };
        s.* = .{ .backend = AgentBackend.init(gpa, .{}), .game = game, .script = script };
        made += 1;
        s.backend.transport = (try network.endpoint()).transport();
        s.game.pacing = .per_update;
        try s.game.startNetplay(.{
            .role = if (host) .host else .guest,
            .address = if (host) "7000" else "ws://localhost:7000",
            .build = net.protocol.buildId(sorz.version.build),
            .data = identity,
            .delay = if (host) delay else null,
            .log = false,
        });
    }
    // One update each in turn; a game that reached the end waits for the other.
    var updates: u64 = 0;
    const limit = frames * 4 + 1000;
    var corrupted: ?u64 = null;
    while (updates < limit) : (updates += 1) {
        var all = true;
        for (&sides, 0..) |*s, i| {
            const t: u64 = if (s.game.started) s.game.netplay.?.tick() else 0;
            if (i == 1 and corrupt != null and corrupted == null and t == corrupt.? and s.game.net_epoch != 0) {
                s.game.state.tick ^= 64;
                corrupted = t;
            }
            if (t < frames) {
                all = false;
                try s.script.inject(&s.backend, t);
                var p = s.backend.asPlatform();
                _ = try s.game.update(&p);
            }
            s.backend.advance(frame_ns);
        }
        if (all) break;
        // A mismatch: both stop, and name the field once their states crossed.
        if (sides[0].game.netplay.?.difference != null and sides[1].game.netplay.?.difference != null) break;
    }

    // The reference: one game, pad 1 the host's keys and pad 2 the guest's, D ticks later.
    var ref_backend = AgentBackend.init(gpa, .{});
    defer ref_backend.deinit();
    var reference = try sorz.Game.init(gpa, assets, null);
    defer reference.deinit();
    reference.pacing = .per_update;
    const shifted = try gpa.alloc(Press, host_presses.len + guest_presses.len);
    defer gpa.free(shifted);
    for (host_presses, 0..) |press, i| shifted[i] = .{ .frame = press.frame + delay, .key = press.key, .hold = press.hold };
    for (guest_presses, 0..) |press, i| shifted[host_presses.len + i] = .{ .frame = press.frame + delay, .key = padTwo(press.key), .hold = press.hold };
    var ref_script = try Script.init(gpa, shifted);
    defer ref_script.deinit(gpa);
    var rp = ref_backend.asPlatform();
    for (0..frames) |t| {
        try ref_script.inject(&ref_backend, t);
        _ = try reference.update(&rp);
        ref_backend.advance(frame_ns);
    }

    const same = sides[0].game.stateHash() == reference.stateHash() and sides[1].game.stateHash() == reference.stateHash() and
        sides[0].game.state.tick == frames and sides[1].game.state.tick == frames;
    try out.writeAll("{");
    try writeGame(out, "host", &sides[0].game);
    try out.writeAll(",");
    try writeGame(out, "guest", &sides[1].game);
    try out.writeAll(",");
    try writeGame(out, "reference", &reference);
    if (corrupted) |c| {
        const found = sides[0].game.netplay.?.session.desync_at;
        try out.print(",\"corrupted_before\":{d},\"found_at\":{?d}", .{ c, found });
    }
    try out.print(",\"same\":{}}}\n", .{same});
    return if (corrupt != null) sides[0].game.netplay.?.difference != null and sides[1].game.netplay.?.difference != null else same;
}

/// The key of pad 2 that does what `key` does on pad 1 (input.zig's default keys); other keys
/// stay.
fn padTwo(key: platform.Key) platform.Key {
    const keys = sorz.input.default_keys;
    for (keys) |b| {
        if (b.pad != 0 or b.key != key) continue;
        for (keys) |c| if (c.pad == 1 and c.button == b.button) return c.key;
    }
    return key;
}

test "a pad 1 key maps to the pad 2 key of the same button" {
    try std.testing.expectEqual(platform.Key.w, padTwo(.up));
    try std.testing.expectEqual(platform.Key.tab, padTwo(.enter));
    try std.testing.expectEqual(platform.Key.g, padTwo(.x));
    try std.testing.expectEqual(platform.Key.f2, padTwo(.f2));
}

test "two games in one process: the pair mode's verdict" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const presses = [_]Press{ .{ .frame = 10, .key = .x, .hold = 5 }, .{ .frame = 20, .key = .right, .hold = 40 } };
    const guest = [_]Press{.{ .frame = 30, .key = .down, .hold = 30 }};
    try std.testing.expect(try pair(std.testing.allocator, null, @splat(0), 3, 120, &presses, &guest, null, &w));
    try std.testing.expect(std.mem.find(u8, w.buffered(), "\"same\":true") != null);
}

test "a bit of the guest's state flipped: both games stop at the next check and name the field" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.testing.expect(try pair(std.testing.allocator, null, @splat(0), 2, 300, &.{}, &.{}, 47, &w));
    const text = w.buffered();
    try std.testing.expect(std.mem.find(u8, text, "\"corrupted_before\":47,\"found_at\":60") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"difference\":\"tick (byte 0, 4 bytes): ours 60, theirs 124\"") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"difference\":\"tick (byte 0, 4 bytes): ours 124, theirs 60\"") != null);
}

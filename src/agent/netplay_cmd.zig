//! The agent host's network play (DESIGN.md 9): the game with network play, driven by scripted
//! keys, over the native WebSocket transport, so that two processes (or an agent and the SDL game,
//! or a page) play together: `sorz-agent [DIR] --netplay [ADDRESS:]PORT` or `--join
//! ws://ADDRESS:PORT`. Each game plays its own front end with its keys (pad 1's on both machines:
//! the arrows, Z, X, C, Enter), pressed by update (`--key F:NAME:H` holds the key from update F, H
//! updates); the guest's player's JOIN and its character join the host's game. The virtual clock
//! advances a tick's time per update, its own screens open too (their fades count time); an update
//! whose game holds for the peer waits a millisecond of real time and advances the clock as much.
//! The run ends after `--frames` updates, or once
//! the session ran `--until-session` ticks; it prints the game's hashes, its network play, and its
//! sound since the session began (its frames' hash, their number and their peak): two machines in
//! a session play the same sound from its first tick, the guest's carried over at the join.
const std = @import("std");
const sorz = @import("sorz");
const AgentBackend = @import("backend.zig").AgentBackend;
const native = @import("native");

const platform = sorz.platform;

/// A tick's time, as the agent host's clock counts it (rounded up).
pub const frame_ns: u64 = sorz.sound_out.tick_ps / 1000 + 1;

/// A key pressed at update `frame` for `hold` updates; a guest's `after_place` press counts its
/// updates from the first at which the host offers a place in its round (its status), whatever
/// the two processes' speeds.
pub const Press = struct { frame: u64, key: platform.Key, hold: u64 = 1, after_place: bool = false };

/// A game's scripted keys, injected by update.
pub const Script = struct {
    presses: []const Press,
    /// Per press: 0 not yet pressed, 1 held, 2 released.
    done: []u2,

    pub fn init(gpa: std.mem.Allocator, presses: []const Press) !Script {
        const done = try gpa.alloc(u2, presses.len);
        @memset(done, 0);
        return .{ .presses = presses, .done = done };
    }

    pub fn deinit(s: *Script, gpa: std.mem.Allocator) void {
        gpa.free(s.done);
    }

    /// Injects the key events due before update `t`; `place_at`, the update at which the host
    /// first offered a place in its round, if it has.
    pub fn inject(s: *Script, backend: *AgentBackend, t: u64, place_at: ?u64) !void {
        for (s.presses, s.done) |p, *d| {
            var press = p;
            if (press.after_place) press.frame +|= place_at orelse continue;
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

/// A game's line: its ticks and hashes, its scene, its network play.
pub fn writeGame(w: *std.Io.Writer, label: []const u8, game: *const sorz.Game) !void {
    try w.print("\"{s}\":{{\"ticks\":{d},\"updates\":{d},\"state_hash\":\"{x:0>16}\"", .{ label, game.state.tick, game.update_count, game.stateHash() });
    try w.print(",\"variant\":\"{s}\",\"scene\":\"{s}\",\"players\":\"{s}\"", .{ @tagName(game.state.start.variant), @tagName(std.meta.activeTag(game.state.scenes.base)), @tagName(game.state.setup.players) });
    if (game.netplay) |n| {
        try w.print(",\"phase\":\"{s}\",\"delay\":{d},\"sessions\":{d},\"session_tick\":{d}", .{ @tagName(n.phase()), n.delay(), n.sessions, n.tick() });
        if (n.difference) |d| try w.print(",\"difference\":\"{f}\"", .{d});
    }
    try w.writeAll("}");
}

/// One game with network play over WebSockets, for `frames` updates or until its session ran
/// `until_session` ticks. Returns false when it stopped otherwise (refused, stalled, desynced, a
/// session that did not get there). A host serves the page and the game's files of `served` (its
/// own data) to a guest's browser.
pub fn process(
    gpa: std.mem.Allocator,
    io: std.Io,
    assets: ?platform.AssetSource,
    storage: platform.Storage,
    options: sorz.net.netplay.Options,
    page: native.net.Page,
    served: ?platform.AssetSource,
    frames: u64,
    until_session: ?u32,
    presses: []const Press,
    out: *std.Io.Writer,
) !bool {
    var side: native.cli.Netplay = undefined;
    try side.init(gpa, io, page, if (options.role == .host) served else null);
    defer side.deinit();
    var backend = AgentBackend.init(gpa, .{});
    defer backend.deinit();
    backend.transport = side.transport.transport();
    backend.audio.record = true;
    var game = try sorz.Game.init(gpa, assets, storage);
    defer game.deinit();
    game.pacing = .per_update;
    game.variant = .network;
    try game.startNetplay(options);
    // The sound since the session began.
    var sound: Sound = .{};
    var script = try Script.init(gpa, presses);
    defer script.deinit(gpa);
    var p = backend.asPlatform();
    // No progress for this long (real time) ends the run: no peer, or a stopped session.
    const stall_ns: i96 = 60 * std.time.ns_per_s;
    var last_progress = std.Io.Clock.awake.now(io).toNanoseconds();
    var last_tick: u32 = 0;
    var finished = false;
    var updates: u64 = 0;
    var place_at: ?u64 = null;
    while (updates < frames) : (updates += 1) {
        if (until_session) |n| if (game.netplay) |np| if (np.inSession() and np.tick() >= n) break;
        if (place_at == null) if (game.netplay) |np| {
            const st = np.hostStatus();
            if (np.role == .guest and st.game == .play and st.place) place_at = updates;
        };
        try script.inject(&backend, updates, place_at);
        if (try game.update(&p) == .finished) {
            finished = true;
            break;
        }
        if (game.netplay) |n| if (n.inSession()) sound.add(backend.audio.pcm.items);
        backend.audio.pcm.clearRetainingCapacity();
        const np = game.netplay orelse break;
        if (np.phase() == .ended or (np.phase() == .desynced and np.difference != null)) break;
        const now = std.Io.Clock.awake.now(io).toNanoseconds();
        if (game.state.tick != last_tick or game.settingsOpen() or game.modalOpen()) {
            // A tick ran, or this machine's own screen holds the game (the settings, network
            // play's screens): a tick's time an update, as the game would run.
            last_tick = game.state.tick;
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
    const np = game.netplay;
    const ok = !finished and np != null and if (until_session) |n| np.?.inSession() and np.?.tick() >= n and np.?.phase() == .playing else np.?.phase() != .desynced;
    // The peer may still need this game's last pads: the transport's close sends them first. (A
    // game that finished has quit already.)
    if (!finished) if (game.netplay) |n| n.quit(&p);
    try out.writeAll("{");
    try writeGame(out, if (options.role == .host) "host" else "guest", &game);
    try out.print(",\"sound_hash\":\"{x:0>16}\",\"sound_frames\":{d},\"sound_peak\":{d}", .{ sound.hash.final(), sound.values / 2, sound.peak });
    try out.print(",\"verdict\":\"{s}\"}}\n", .{if (ok) "ok" else "incomplete"});
    return ok;
}

/// The sound's frames in a session: their hash, their number of values, their peak.
const Sound = struct {
    hash: std.hash.Fnv1a_64 = .init(),
    values: u64 = 0,
    peak: u32 = 0,

    fn add(s: *Sound, pcm: []const i16) void {
        s.hash.update(std.mem.sliceAsBytes(pcm));
        s.values += pcm.len;
        for (pcm) |v| s.peak = @max(s.peak, @abs(v));
    }
};

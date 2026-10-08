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

pub const Press = struct { frame: u64, key: platform.Key, hold: u64 = 1 };

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

    /// Injects the key events due before update `t`.
    pub fn inject(s: *Script, backend: *AgentBackend, t: u64) !void {
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
    while (updates < frames) : (updates += 1) {
        if (until_session) |n| if (game.netplay) |np| if (np.inSession() and np.tick() >= n) break;
        try script.inject(&backend, updates);
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

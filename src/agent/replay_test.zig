//! The rolling recording and F5 in the game as the agent host runs it (DESIGN.md 10.8, replay.zig):
//! the game without content (its test pattern), the keys injected, the storage in memory. The
//! real game's replays are replay-check's (the user's ROM).
const std = @import("std");
const sorz = @import("sorz");
const AgentBackend = @import("backend.zig").AgentBackend;

const platform = sorz.platform;
const replay = sorz.replay;
const frame_ns = @import("netplay_cmd.zig").frame_ns;
const testing = std.testing;

const Run = struct {
    backend: AgentBackend,
    storage: sorz.memory.MemoryStorage,
    game: sorz.Game,

    fn init(r: *Run) !void {
        r.backend = AgentBackend.init(testing.allocator, .{});
        r.storage = sorz.memory.MemoryStorage.init(testing.allocator);
        r.game = try sorz.Game.init(testing.allocator, null, r.storage.storage());
        r.game.pacing = .per_update;
    }

    fn deinit(r: *Run) void {
        r.game.deinit();
        r.storage.deinit();
        r.backend.deinit();
    }

    fn key(r: *Run, k: platform.Key, down: bool) !void {
        try r.backend.inject(.{ .time_ns = r.backend.clock_ns, .payload = if (down) .{ .key_down = .{ .key = k } } else .{ .key_up = .{ .key = k } } });
    }

    fn update(r: *Run) !void {
        var p = r.backend.asPlatform();
        _ = try r.game.update(&p);
        r.backend.advance(frame_ns);
    }
};

/// Pad 1's Right held at update `i` (its key down and up as it changes).
fn rightHeld(i: usize) bool {
    return i % 90 < 40;
}

test "F5 saves the last 20 seconds as a replay: the pads read and shown at each tick" {
    var r: Run = undefined;
    try r.init();
    defer r.deinit();
    const updates = 3000;
    var shown: [updates]sorz.input.Pads = undefined;
    for (0..updates) |i| {
        if (rightHeld(i) != (i > 0 and rightHeld(i - 1))) try r.key(.right, rightHeld(i));
        try r.update();
        shown[i] = r.game.shown;
    }
    try testing.expect(r.game.usesKey(.f5));
    try r.key(.f5, true);
    try r.update();
    try r.key(.f5, false);
    try r.update();
    try testing.expectEqual(sorz.game.Notice.replay_saved, r.game.notice);
    try testing.expectEqual(@as(u64, 1), r.game.replays_saved);
    // Without the date, the first counter's name.
    var bytes = try r.storage.storage().load("replay-0001" ++ replay.extension);
    defer bytes.deinit();
    var rp = try replay.Replay.read(testing.allocator, bytes.bytes, try r.game.replayIdentity());
    defer rp.deinit();
    // 20 seconds at least, and no more than the recording's room; to the tick F5 came at.
    const ticks = rp.header.ticks;
    try testing.expect(ticks >= replay.ticks_kept and ticks <= replay.tick_room);
    try testing.expectEqual(@as(u32, updates), rp.header.first_tick + ticks);
    var i: usize = rp.header.first_tick;
    for (rp.steps) |s| switch (s) {
        .tick => |t| {
            try testing.expectEqual(rightHeld(i), t.pads.pad1.right);
            try testing.expectEqual(shown[i], t.shown);
            i += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, updates), i);
}

test "a page keeps F5: no replay, no recording" {
    var r: Run = undefined;
    try r.init();
    defer r.deinit();
    r.game.replays = false;
    for (0..10) |_| try r.update();
    try testing.expect(!r.game.usesKey(.f5));
    try testing.expectEqual(@as(u64, 0), r.game.recording.kept());
}

test "a replay plays the recorded ticks: each state the recorded game's, paused, stepped and slowed" {
    var a: Run = undefined;
    try a.init();
    defer a.deinit();
    const updates = 2000;
    var hashes: [updates + 2]u64 = undefined;
    for (0..updates) |i| {
        if (rightHeld(i) != (i > 0 and rightHeld(i - 1))) try a.key(.right, rightHeld(i));
        if (i % 50 == 0) try a.key(.enter, true);
        if (i % 50 == 1) try a.key(.enter, false);
        try a.update();
        hashes[a.game.state.tick] = a.game.state.hash();
    }
    try a.key(.f5, true);
    try a.update();
    hashes[a.game.state.tick] = a.game.state.hash();
    var bytes = try a.storage.storage().load("replay-0001" ++ replay.extension);
    defer bytes.deinit();

    var b: Run = undefined;
    try b.init();
    defer b.deinit();
    try b.game.playReplay(try replay.Replay.read(testing.allocator, bytes.bytes, try b.game.replayIdentity()));
    const ticks = b.game.replay.?.replay.header.ticks;
    var n: usize = 0;
    var compared: u32 = 0;
    var last: ?u32 = null;
    while (!b.game.replay.?.ended()) : (n += 1) {
        try testing.expect(n < 10 * updates);
        // Paused at 10, a step at 20, on at 30; half speed from 40, a quarter from 60, full at 100.
        if (n == 10 or n == 30) try b.key(.space, true);
        if (n == 11 or n == 31) try b.key(.space, false);
        if (n == 20) try b.key(.right, true);
        if (n == 21) try b.key(.right, false);
        if (n == 40 or n == 60 or n == 100) try b.key(.s, true);
        if (n == 41 or n == 61 or n == 101) try b.key(.s, false);
        try b.update();
        const t = b.game.state.tick;
        if (last == t) continue;
        last = t;
        try testing.expectEqual(hashes[t], b.game.state.hash());
        compared += 1;
    }
    try testing.expectEqual(ticks, compared);
    // Played to the tick F5 came at, and held there.
    try testing.expectEqual(@as(u32, updates), b.game.state.tick);
    try b.update();
    try testing.expectEqual(@as(u32, updates), b.game.state.tick);
    // A replay saves none, and its game takes no other key.
    try testing.expect(!b.game.usesKey(.f5));
}

test "a replay goes back to its snapshots, from the keys and the gamepad, and plays on as recorded" {
    var a: Run = undefined;
    try a.init();
    defer a.deinit();
    const updates = 2000;
    var hashes: [updates + 2]u64 = undefined;
    for (0..updates) |i| {
        if (rightHeld(i) != (i > 0 and rightHeld(i - 1))) try a.key(.right, rightHeld(i));
        try a.update();
        hashes[a.game.state.tick] = a.game.state.hash();
    }
    try a.key(.f5, true);
    try a.update();
    var bytes = try a.storage.storage().load("replay-0001" ++ replay.extension);
    defer bytes.deinit();

    var b: Run = undefined;
    try b.init();
    defer b.deinit();
    try b.game.playReplay(try replay.Replay.read(testing.allocator, bytes.bytes, try b.game.replayIdentity()));
    const r = b.game.replay.?;
    const first = r.replay.header.first_tick;
    const ticks = r.replay.header.ticks;
    const every = replay.Playback.snapshot_every;
    var n: usize = 0;
    while (!r.ended()) : (n += 1) {
        try testing.expect(n < 2 * updates);
        try b.update();
    }
    // Left at the end: the newest snapshot before it, paused there, the recorded game's state.
    try b.key(.left, true);
    try b.update();
    try b.key(.left, false);
    const newest = (ticks - 1) / every * every;
    try testing.expectEqual(newest, r.played);
    try testing.expect(r.paused);
    try testing.expectEqual(first + newest, b.game.state.tick);
    try testing.expectEqual(hashes[b.game.state.tick], b.game.state.hash());
    // Held there while paused.
    try b.update();
    try testing.expectEqual(first + newest, b.game.state.tick);
    // The gamepad's Left: the one before.
    const pad: platform.ControllerId = @fromBackingInt(@intCast(1));
    try b.backend.inject(.{ .time_ns = b.backend.clock_ns, .payload = .{ .controller_added = pad } });
    try b.backend.inject(.{ .time_ns = b.backend.clock_ns, .payload = .{ .controller_button_down = .{ .controller = pad, .button = .dpad_left } } });
    try b.update();
    try testing.expectEqual(newest - every, r.played);
    try testing.expectEqual(hashes[b.game.state.tick], b.game.state.hash());
    // The gamepad's Right: a tick.
    try b.backend.inject(.{ .time_ns = b.backend.clock_ns, .payload = .{ .controller_button_down = .{ .controller = pad, .button = .dpad_right } } });
    try b.update();
    try b.backend.inject(.{ .time_ns = b.backend.clock_ns, .payload = .{ .controller_button_up = .{ .controller = pad, .button = .dpad_right } } });
    try b.update();
    try testing.expectEqual(newest - every + 1, r.played);
    // A d-pad that comes as the stick (SDL's generic mapping): to the left, back to the snapshot;
    // to the right, a tick; back to the middle, Right no longer held.
    try b.backend.inject(.{ .time_ns = b.backend.clock_ns, .payload = .{ .controller_axis = .{ .controller = pad, .axis = .left_x, .value = -32768 } } });
    try b.update();
    try testing.expectEqual(newest - every, r.played);
    try testing.expectEqual(hashes[b.game.state.tick], b.game.state.hash());
    try b.backend.inject(.{ .time_ns = b.backend.clock_ns, .payload = .{ .controller_axis = .{ .controller = pad, .axis = .left_x, .value = 0 } } });
    try b.backend.inject(.{ .time_ns = b.backend.clock_ns, .payload = .{ .controller_axis = .{ .controller = pad, .axis = .left_x, .value = 32767 } } });
    try b.update();
    try b.backend.inject(.{ .time_ns = b.backend.clock_ns, .payload = .{ .controller_axis = .{ .controller = pad, .axis = .left_x, .value = 0 } } });
    try b.update();
    try testing.expectEqual(newest - every + 1, r.played);
    try testing.expect(r.right_held == null);
    // The gamepad came untold.
    try testing.expect(b.game.overlays.find(.gamepad) == null);
    // Its START: on again, every tick the recorded game's to the end.
    try b.backend.inject(.{ .time_ns = b.backend.clock_ns, .payload = .{ .controller_button_down = .{ .controller = pad, .button = .start } } });
    var compared: u32 = 0;
    var last: ?u32 = null;
    n = 0;
    while (!r.ended()) : (n += 1) {
        try testing.expect(n < 2 * updates);
        try b.update();
        const t = b.game.state.tick;
        if (last == t) continue;
        last = t;
        try testing.expectEqual(hashes[t], b.game.state.hash());
        compared += 1;
    }
    try testing.expect(compared >= every);
    try testing.expectEqual(@as(u32, updates), b.game.state.tick);
}

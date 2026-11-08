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

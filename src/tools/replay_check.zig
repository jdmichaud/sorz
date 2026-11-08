//! sorz-replay-check: the gate of the replays (PLAN item 57, DESIGN.md 10.8): games played on the
//! content extracted from the user's ROM as the hosts run them (the game in the agent backend, its
//! keys injected), saved by F5, and played back from the file in another game: each display
//! tick's state hash and the controller overlay's buttons are the recorded game's, while the
//! replay is paused, stepped, slowed and let go again.
//!
//!   sorz-replay-check ROM
//!
//! - fight: 1 PLAYER to round 1, then a fight of 30 seconds (walking, blows, jumps, a special
//!   attack), F5: the last 20 seconds and more replayed.
//! - cut: the fight, Escape back to the menu during it (the state changed between two ticks: a
//!   cut, its state in the file), the menu for 5 seconds, F5: the replay crosses the cut.
//! - refused: the fight's file with another build's identity, then with other data's.
//!
//! Prints a JSON line per case, and exits with 1 when one fails.
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const extract = @import("extract");

const platform = sorz.platform;
const Key = platform.Key;
const replay = sorz.replay;
const frame_ns = agent.netplay_cmd.frame_ns;

/// A game in the agent backend, one tick per update.
const Run = struct {
    backend: agent.AgentBackend,
    storage: sorz.memory.MemoryStorage,
    game: sorz.Game,
    updates: u32 = 0,
    gpa: std.mem.Allocator,
    /// The recorded game's: what each tick was.
    seen: ?*Seen = null,

    fn create(gpa: std.mem.Allocator, assets: platform.AssetSource) !*Run {
        const r = try gpa.create(Run);
        errdefer gpa.destroy(r);
        r.backend = agent.AgentBackend.init(gpa, .{});
        r.storage = sorz.memory.MemoryStorage.init(gpa);
        r.game = try sorz.Game.init(gpa, assets, r.storage.storage());
        r.game.pacing = .per_update;
        r.updates = 0;
        r.gpa = gpa;
        r.seen = null;
        return r;
    }

    fn destroy(r: *Run, gpa: std.mem.Allocator) void {
        r.game.deinit();
        r.storage.deinit();
        r.backend.deinit();
        gpa.destroy(r);
    }

    fn update(r: *Run) !void {
        var p = r.backend.asPlatform();
        _ = try r.game.update(&p);
        r.backend.advance(frame_ns);
        r.updates += 1;
        if (r.seen) |s| try s.note(r.gpa, r);
    }

    fn key(r: *Run, k: Key, down: bool) !void {
        try r.backend.inject(.{ .time_ns = r.backend.clock_ns, .payload = if (down) .{ .key_down = .{ .key = k } } else .{ .key_up = .{ .key = k } } });
    }

    /// `k` pressed for an update, then released for one.
    fn press(r: *Run, k: Key) !void {
        try r.key(k, true);
        try r.update();
        try r.key(k, false);
        try r.update();
    }

    fn until(r: *Run, cond: *const fn (*const Run) bool, limit: u32) !void {
        var n: u32 = 0;
        while (!cond(r)) : (n += 1) {
            if (n == limit) return error.NotReached;
            try r.update();
        }
    }
};

fn choosing(r: *const Run) bool {
    return switch (r.game.state.scenes.base) {
        .menu => |*m| m.phase == .choosing and !r.game.overlays.holds(),
        else => false,
    };
}

fn inSelect(r: *const Run) bool {
    return switch (r.game.state.scenes.base) {
        .select => |*s| s.phase == .first_half or s.phase == .second_half,
        else => false,
    };
}

fn playing(r: *const Run) bool {
    return switch (r.game.state.scenes.base) {
        .round => |*x| x.phase == .play and r.game.state.scenes.overlay_count == 0 and !r.game.overlays.holds(),
        else => false,
    };
}

/// What the recorded game was at each display tick (by the state's tick after it): its state's
/// hash and form, and the buttons the overlay showed.
const Seen = struct {
    hash: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    form: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    shown: std.AutoHashMapUnmanaged(u32, sorz.input.Pads) = .empty,

    fn deinit(s: *Seen, gpa: std.mem.Allocator) void {
        s.hash.deinit(gpa);
        var it = s.form.valueIterator();
        while (it.next()) |f| gpa.free(f.*);
        s.form.deinit(gpa);
        s.shown.deinit(gpa);
    }

    fn note(s: *Seen, gpa: std.mem.Allocator, r: *const Run) !void {
        const t = r.game.state.tick;
        try s.hash.put(gpa, t, r.game.state.hash());
        try s.shown.put(gpa, t, r.game.shown);
        var buf: [sorz.canonical.maxSize(sorz.game.State)]u8 = undefined;
        const form = try gpa.dupe(u8, sorz.canonical.write(sorz.game.State, &r.game.state, &buf));
        if (try s.form.fetchPut(gpa, t, form)) |old| gpa.free(old.value);
    }
};

/// The fight: from power-on, 1 PLAYER, the select's second character, round 1's play, then
/// `ticks` display ticks of walking and blows.
fn fight(r: *Run, ticks: u32) !void {
    while (r.updates < 500) try r.update();
    try r.press(.enter);
    while (r.updates < 560) try r.update();
    try r.press(.enter);
    try r.until(choosing, 400);
    try r.press(.enter);
    try r.until(inSelect, 600);
    try r.press(.right);
    try r.press(.z);
    try r.until(playing, 2400);
    for (0..ticks) |i| {
        // Right held for 2 seconds in 3, Left at times, a blow every 12 ticks, a jump and a
        // special attack now and then, Up and Down to change lanes.
        const t: u32 = @intCast(i);
        try keyFor(r, .right, t % 180 < 120 and t % 900 < 700);
        try keyFor(r, .left, t % 900 >= 760 and t % 900 < 820);
        try keyFor(r, .up, t % 600 >= 300 and t % 600 < 330);
        try keyFor(r, .down, t % 600 >= 450 and t % 600 < 470);
        try keyFor(r, .x, t % 12 < 3);
        try keyFor(r, .c, t % 240 >= 200 and t % 240 < 203);
        try keyFor(r, .z, t % 1000 >= 500 and t % 1000 < 502);
        try r.update();
    }
    for (fight_keys) |k| try keyFor(r, k, false);
}

/// The fight's keys, and those held.
const fight_keys = [_]Key{ .right, .left, .up, .down, .x, .c, .z };
var fight_held: [fight_keys.len]bool = @splat(false);

/// The key `k` (one of the fight's) down or up as asked, each change an event.
fn keyFor(r: *Run, k: Key, down: bool) !void {
    const i = std.mem.indexOfScalar(Key, &fight_keys, k).?;
    if (fight_held[i] == down) return;
    fight_held[i] = down;
    try r.key(k, down);
}

/// F5, and the file it saved.
fn save(gpa: std.mem.Allocator, r: *Run) ![]u8 {
    try r.key(.f5, true);
    try r.update();
    try r.key(.f5, false);
    if (r.game.notice != .replay_saved) return error.NotSaved;
    var names = try r.storage.storage().listSaves();
    defer names.deinit();
    for (names.names) |n| if (std.mem.endsWith(u8, n, replay.extension)) {
        var bytes = try r.storage.storage().load(n);
        defer bytes.deinit();
        return gpa.dupe(u8, bytes.bytes);
    };
    return error.NotSaved;
}

const Result = struct {
    ticks: u32 = 0,
    first_tick: u32 = 0,
    compared: u32 = 0,
    differing: u32 = 0,
    shown_differing: u32 = 0,
    first_difference: ?u32 = null,
    first_field: ?sorz.canonical.Difference = null,
    held_updates: u32 = 0,
    /// The ticks run while paused (three steps asked for), at half speed (300 updates) and at
    /// quarter speed (400 updates).
    paused: u32 = 0,
    half: u32 = 0,
    quarter: u32 = 0,
    loads: u64 = 0,
    ended: bool = false,
    /// Left twice at the end: the tick gone back to (the snapshot before the newest), its
    /// state the recorded game's; then on again to the end, the ticks compared.
    back_to: ?u32 = null,
    back_to_want: u32 = 0,
    back_same: bool = false,
    again: u32 = 0,
};

/// Plays `bytes` in a new game, its keys pausing, stepping, slowing and letting it go, and
/// compares each display tick's state with the recorded game's.
fn replayed(gpa: std.mem.Allocator, assets: platform.AssetSource, bytes: []const u8, seen: *const Seen) !Result {
    const r = try Run.create(gpa, assets);
    defer r.destroy(gpa);
    const rp = try replay.Replay.read(gpa, bytes, try r.game.replayIdentity());
    try r.game.playReplay(rp);
    var out: Result = .{ .ticks = rp.header.ticks, .first_tick = rp.header.first_tick };
    var last_tick: ?u32 = null;
    var n: u32 = 0;
    while (!r.game.replay.?.ended()) : (n += 1) {
        if (n == 20_000) return error.NotEnded;
        // Space at 100 (paused), Right three times (three steps), Space; S at 400 (half speed),
        // 700 (quarter), 1100 (full again).
        switch (n) {
            100, 140, 400, 700, 1100 => try r.key(if (n == 100 or n == 140) .space else .s, true),
            101, 141, 401, 701, 1101 => try r.key(if (n == 101 or n == 141) .space else .s, false),
            110, 120, 130 => try r.key(.right, true),
            111, 121, 131 => try r.key(.right, false),
            else => {},
        }
        const before = r.game.replay.?.played;
        try r.update();
        const ran = r.game.replay.?.played - before;
        if (n > 100 and n < 140) out.paused += ran;
        if (n >= 400 and n < 700) out.half += ran;
        if (n >= 700 and n < 1100) out.quarter += ran;
        const t = r.game.state.tick;
        if (last_tick != null and last_tick.? == t) {
            out.held_updates += 1;
            continue;
        }
        last_tick = t;
        out.compared += 1;
        compare(&out, r, seen);
    }
    out.ended = r.game.replay.?.ended();
    // Left twice at the end: back to the snapshot before the newest, paused; Space, on again to
    // the end, every tick compared.
    const pb = r.game.replay.?;
    const every = replay.Playback.snapshot_every;
    out.back_to_want = ((pb.replay.header.ticks - 1) / every - 1) * every;
    for (0..2) |_| {
        try r.key(.left, true);
        try r.update();
        try r.key(.left, false);
        try r.update();
    }
    out.back_to = pb.played;
    out.back_same = pb.paused and seen.hash.get(r.game.state.tick) == r.game.state.hash();
    try r.key(.space, true);
    n = 0;
    while (!pb.ended()) : (n += 1) {
        if (n == 20_000) return error.NotEnded;
        if (n == 1) try r.key(.space, false);
        const before = pb.played;
        try r.update();
        if (pb.played == before) continue;
        out.again += pb.played - before;
        compare(&out, r, seen);
    }
    out.loads = r.game.loads_done;
    return out;
}

/// The display tick's state and buttons shown against the recorded game's.
fn compare(out: *Result, r: *Run, seen: *const Seen) void {
    const t = r.game.state.tick;
    const want = seen.hash.get(t);
    if (want == null or want.? != r.game.state.hash()) {
        out.differing += 1;
        if (out.first_difference == null) {
            out.first_difference = t;
            if (seen.form.get(t)) |theirs| {
                var buf: [sorz.canonical.maxSize(sorz.game.State)]u8 = undefined;
                const ours = sorz.canonical.write(sorz.game.State, &r.game.state, &buf);
                out.first_field = sorz.canonical.firstDifference(sorz.game.State, ours, theirs);
            }
        }
    }
    const shown = seen.shown.get(t);
    if (shown == null or !std.meta.eql(shown.?, r.game.shown)) out.shown_differing += 1;
}

fn report(w: *std.Io.Writer, case: []const u8, res: Result, bytes: usize) !bool {
    const pass = res.ended and res.differing == 0 and res.shown_differing == 0 and res.compared == res.ticks and res.ticks >= replay.ticks_kept and
        res.paused == 3 and res.half == 150 and res.quarter == 100 and res.back_to == res.back_to_want and res.back_same and
        res.again == res.ticks - res.back_to_want;
    try w.print("{{\"case\":\"{s}\",\"pass\":{},\"ticks\":{d},\"first_tick\":{d},\"bytes\":{d},\"compared\":{d},\"differing\":{d},\"shown_differing\":{d},\"held_updates\":{d},\"paused_ticks\":{d},\"half_ticks\":{d},\"quarter_ticks\":{d},\"states_loaded\":{d}", .{
        case, pass, res.ticks, res.first_tick, bytes, res.compared, res.differing, res.shown_differing, res.held_updates, res.paused, res.half, res.quarter, res.loads,
    });
    try w.print(",\"back_to\":{?d},\"back_same\":{},\"again\":{d}", .{ res.back_to, res.back_same, res.again });
    if (res.first_difference) |t| try w.print(",\"first_difference\":{d}", .{t});
    if (res.first_field) |d| try w.print(",\"first_field\":\"{f}\"", .{d});
    try w.writeAll("}\n");
    try w.flush();
    return pass;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const rom_path = args.next() orelse {
        try std.Io.File.stderr().writeStreamingAll(io, "usage: sorz-replay-check ROM\n");
        std.process.exit(2);
    };
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(extract.rom.size + 1));
    defer gpa.free(rom);
    var tree = try extract.extract(gpa, rom);
    defer tree.deinit();
    var source = sorz.memory.MemoryAssetSource.init(gpa);
    defer source.deinit();
    try tree.addTo(&source);
    const assets = source.assetSource();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    var all = true;

    // The fight, then F5.
    const fight_bytes = blk: {
        var seen: Seen = .{};
        defer seen.deinit(gpa);
        const r = try Run.create(gpa, assets);
        defer r.destroy(gpa);
        r.seen = &seen;
        try fight(r, 1800);
        const bytes = try save(gpa, r);
        all = try report(w, "fight", try replayed(gpa, assets, bytes, &seen), bytes.len) and all;
        break :blk bytes;
    };
    defer gpa.free(fight_bytes);

    // The fight, Escape to the menu (a cut), 5 seconds of it, then F5.
    {
        var seen: Seen = .{};
        defer seen.deinit(gpa);
        const r = try Run.create(gpa, assets);
        defer r.destroy(gpa);
        r.seen = &seen;
        try fight(r, 1000);
        try r.key(.escape, true);
        try r.update();
        try r.key(.escape, false);
        for (0..300) |_| try r.update();
        const bytes = try save(gpa, r);
        defer gpa.free(bytes);
        const res = try replayed(gpa, assets, bytes, &seen);
        // Its first state and the cut's.
        all = try report(w, "cut", res, bytes.len) and res.loads == 2 and all;
    }

    // Another build's file, other data's: refused.
    {
        const r = try Run.create(gpa, assets);
        defer r.destroy(gpa);
        const id = try r.game.replayIdentity();
        const other_build = try gpa.dupe(u8, fight_bytes);
        defer gpa.free(other_build);
        @memcpy(other_build[replay.magic.len + 2 ..][0..32], &sorz.net.protocol.buildId("another build"));
        const other_data = try gpa.dupe(u8, fight_bytes);
        defer gpa.free(other_data);
        other_data[replay.magic.len + 2 + 32] ^= 1;
        const build_refused = if (replay.Replay.read(gpa, other_build, id)) |x| blk: {
            var y = x;
            y.deinit();
            break :blk false;
        } else |err| err == error.OtherBuild;
        const data_refused = if (replay.Replay.read(gpa, other_data, id)) |x| blk: {
            var y = x;
            y.deinit();
            break :blk false;
        } else |err| err == error.OtherData;
        try w.print("{{\"case\":\"refused\",\"pass\":{},\"other_build\":{},\"other_data\":{}}}\n", .{ build_refused and data_refused, build_refused, data_refused });
        try w.flush();
        all = all and build_refused and data_refused;
    }
    if (!all) std.process.exit(1);
}

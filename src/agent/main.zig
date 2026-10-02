//! sorz-agent: the headless host. It runs the game on the agent backend for a number of frames,
//! one display tick each on a virtual clock, presses keys at the frames it is told, and prints one
//! JSON line with the counts, the hashes of the state, of the last frame and of the settings, and
//! what the game has to tell about its settings record; it writes the frames it is asked for as PNG
//! files and the sound as a WAV file. Two runs with the same arguments print the same line on every
//! machine; the checks and the debugging build on this.
//!
//! With a game directory, the game reads it; with `--saves`, it saves there (its settings record
//! among them). Without them, it runs on in-memory providers, so the run touches no file and never
//! the user's saves (DESIGN.md 5.1). `--netplay`, `--join` and `--pair` play a session of network
//! play (netplay_cmd.zig).
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const native = @import("native");
const web_page = @import("web_page");

const usage =
    \\usage: sorz-agent [--frames N] [--key FRAME:NAME[:HOLD]]... [--shot FRAME:PATH]... [--wav PATH]
    \\                  [DIR] [--saves DIR]
    \\       sorz-agent [DIR] (--netplay [ADDRESS:]PORT [--delay N] | --join ws://ADDRESS:PORT)
    \\                  [--frames N] [--key FRAME:NAME[:HOLD]]...
    \\       sorz-agent [DIR] --pair [--delay N] [--frames N] [--key ...]... [--guest-key ...]...
    \\                  [--corrupt TICK]
    \\       sorz-agent DIR --server [ADDRESS:]PORT
    \\  --frames N       run N frames, a display tick each (default 120)
    \\  --key FRAME:NAME[:HOLD]  press the key NAME (a platform.Key, as `enter` or `left`) at
    \\                   frame FRAME, release it HOLD frames later (default 1); repeats
    \\  --shot FRAME:PATH  write the picture presented at frame FRAME as a PNG file; repeats
    \\  --wav PATH       write the sound played as a WAV file
    \\  DIR              the game directory
    \\  --saves DIR      where saves are kept, the settings record (settings.json) among them
    \\  --netplay, --join  network play over WebSockets, as the host (player 1) or the guest
    \\                   (player 2); --frames counts the session's ticks, and --key presses a
    \\                   pad 1 key by tick (it reaches the game --delay ticks later); prints the
    \\                   game's hashes and the session's end
    \\  --delay N        the host's input delay, 2 to 6 (default: from the round trip; 2 with
    \\                   --pair)
    \\  --pair           two games in one process over the in-memory network, the host's keys
    \\                   from --key and the guest's from --guest-key, and a third game alone
    \\                   with their merged pads; prints the three and whether they are the same;
    \\                   --corrupt flips a bit of the guest's tick count before that tick (a
    \\                   negative control: both games stop and name the field)
    \\  --server         server mode, as sorz-server: serve the page and the game's files of
    \\                   DIR, and relay network play between two browsers, with no game
    \\
;

/// A frame is a display tick: 896,040 periods of the console's 53,693,175 Hz clock, rounded up so
/// that the clock never falls behind the ticks.
const frame_ns: u64 = agent.netplay_cmd.frame_ns;
const Press = agent.netplay_cmd.Press;
const Shot = struct { frame: u64, path: []const u8 };

/// The browser build built into the binary, which `--netplay` and `--server` serve.
const page: native.net.Page = .{ .index_html = web_page.index_html, .script_js = web_page.script_js, .module_wasm = web_page.module_wasm };

/// Every log line as the binaries' (native/log.zig).
pub const std_options: std.Options = .{ .logFn = native.log.logFn };

pub fn main(init: std.process.Init) !void {
    native.log.program = "sorz-agent";
    const gpa = init.gpa;
    const io = init.io;
    var frames: u64 = 120;
    var presses: std.ArrayList(Press) = .empty;
    defer presses.deinit(gpa);
    var shots: std.ArrayList(Shot) = .empty;
    defer shots.deinit(gpa);
    var wav_path: ?[]const u8 = null;
    var guest_presses: std.ArrayList(Press) = .empty;
    defer guest_presses.deinit(gpa);
    var pair = false;
    var corrupt: ?u64 = null;
    var options: native.cli.Options = .{};
    // `iterateAllocator` is the form that Windows needs; the arena keeps the arguments for the
    // whole run.
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    while (args.next()) |arg| {
        if (options.take(arg, &args) catch return fail(io)) continue;
        if (std.mem.eql(u8, arg, "--frames")) {
            frames = std.fmt.parseInt(u64, args.next() orelse return fail(io), 10) catch return fail(io);
        } else if (std.mem.eql(u8, arg, "--key")) {
            try presses.append(gpa, parsePress(args.next() orelse return fail(io)) orelse return fail(io));
        } else if (std.mem.eql(u8, arg, "--shot")) {
            try shots.append(gpa, parseShot(args.next() orelse return fail(io)) orelse return fail(io));
        } else if (std.mem.eql(u8, arg, "--wav")) {
            wav_path = args.next() orelse return fail(io);
        } else if (std.mem.eql(u8, arg, "--guest-key")) {
            try guest_presses.append(gpa, parsePress(args.next() orelse return fail(io)) orelse return fail(io));
        } else if (std.mem.eql(u8, arg, "--pair")) {
            pair = true;
        } else if (std.mem.eql(u8, arg, "--corrupt")) {
            corrupt = std.fmt.parseInt(u64, args.next() orelse return fail(io), 10) catch return fail(io);
        } else {
            return fail(io);
        }
    }

    // Server mode: the relay and the game's files, as sorz-server runs it.
    if (options.server) |address| {
        _ = options.network() catch return fail(io);
        if (pair or presses.items.len != 0 or guest_presses.items.len != 0 or corrupt != null or shots.items.len != 0 or wav_path != null) return fail(io);
        const status = try native.relay.serve(gpa, io, options.assets.?, address, page);
        if (status != 0) std.process.exit(status);
        return;
    }

    // Real providers when the options name them, else in-memory ones. They outlive the game.
    var providers: native.cli.Providers = .empty;
    defer providers.deinit();
    var memory_assets = sorz.memory.MemoryAssetSource.init(gpa);
    defer memory_assets.deinit();
    var memory_storage = sorz.memory.MemoryStorage.init(gpa);
    defer memory_storage.deinit();
    var assets: ?sorz.platform.AssetSource = memory_assets.assetSource();
    var storage = memory_storage.storage();
    if (options.saves != null) {
        providers.open(gpa, io, init.environ_map, options) catch |err| {
            std.log.err("cannot open the providers: {s}", .{native.cli.openErrorText(err)});
            std.process.exit(2);
        };
        assets = providers.assetSource() orelse assets;
        storage = providers.storage();
    } else if (options.assets) |path| {
        // Without `--saves`, only the game's data is opened: the user's save directory is not even
        // created.
        providers.openAssets(gpa, io, path) catch |err| {
            std.log.err("cannot open the game data {s}: {s}", .{ path, native.cli.openErrorText(err) });
            std.process.exit(2);
        };
        assets = providers.assetSource() orelse assets;
    }

    // Network play: a session over WebSockets, or two games in one process. (`--delay` goes with
    // `--netplay`, or with `--pair`.)
    const network = if (pair) .none else options.network() catch return fail(io);
    const netplay = network == .netplay or (pair and (options.netplay != null or options.join != null));
    if (netplay or pair) {
        if (shots.items.len != 0 or wav_path != null or (pair and netplay) or (!pair and (guest_presses.items.len != 0 or corrupt != null))) return fail(io);
        const identity = providers.dataIdentity() catch |err| {
            std.log.err("cannot read the game data for its identity: {s}", .{@errorName(err)});
            std.process.exit(2);
        };
        var obuf: [2048]u8 = undefined;
        var ow = std.Io.File.stdout().writerStreaming(io, &obuf);
        const ok = if (pair)
            try agent.netplay_cmd.pair(gpa, assets, identity, options.delay orelse 2, frames, presses.items, guest_presses.items, corrupt, &ow.interface)
        else
            try agent.netplay_cmd.process(gpa, io, assets, storage, options.netplayOptions(identity), page, providers.assetSource(), frames, presses.items, &ow.interface);
        try ow.interface.flush();
        if (!ok) std.process.exit(1);
        return;
    }
    if (guest_presses.items.len != 0 or corrupt != null) return fail(io);

    var backend = agent.AgentBackend.init(gpa, .{});
    defer backend.deinit();
    backend.audio.record = wav_path != null;
    var game = try sorz.Game.init(gpa, assets, storage);
    defer game.deinit();
    game.pacing = .per_update;
    var p = backend.asPlatform();
    var frame: u64 = 0;
    while (frame < frames) : (frame += 1) {
        for (presses.items) |press| {
            if (press.frame == frame) try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_down = .{ .key = press.key } } });
            if (press.frame + press.hold == frame) try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_up = .{ .key = press.key } } });
        }
        if (try game.update(&p) == .finished) break;
        for (shots.items) |shot| if (shot.frame == frame) try writeShot(gpa, io, &game, shot.path);
        backend.advance(frame_ns);
    }
    if (wav_path) |path| try writeWav(gpa, io, path, backend.audio.pcm.items, backend.audio.format);

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.print("{{\"updates\":{d},\"frames_presented\":{d},\"events_consumed\":{d},\"ticks\":{d},\"saves\":{d},\"loads\":{d},\"state_hash\":\"{x:0>16}\",\"frame_hash\":\"{x:0>16}\",\"settings\":\"{x:0>16}\",\"notice\":\"{s}\"}}\n", .{
        game.update_count,                         game.frames_presented, game.events_consumed, game.state.tick, game.saves_written, game.loads_done, game.stateHash(), game.lastFrameHash(),
        sorz.settings.record.hash(&game.settings), @tagName(game.notice),
    });
    try w.interface.flush();
}

/// `FRAME:NAME[:HOLD]`, as `30:enter` or `400:left:5`.
fn parsePress(text: []const u8) ?Press {
    var it = std.mem.splitScalar(u8, text, ':');
    const frame = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const key = std.meta.stringToEnum(sorz.platform.Key, it.next() orelse return null) orelse return null;
    const hold = if (it.next()) |h| std.fmt.parseInt(u64, h, 10) catch return null else 1;
    if (it.next() != null or hold == 0) return null;
    return .{ .frame = frame, .key = key, .hold = hold };
}

/// `FRAME:PATH`, as `250:/tmp/sor/frame.png`.
fn parseShot(text: []const u8) ?Shot {
    const colon = std.mem.findScalar(u8, text, ':') orelse return null;
    const frame = std.fmt.parseInt(u64, text[0..colon], 10) catch return null;
    if (colon + 1 == text.len) return null;
    return .{ .frame = frame, .path = text[colon + 1 ..] };
}

/// The frame just presented, as a PNG file.
fn writeShot(gpa: std.mem.Allocator, io: std.Io, game: *const sorz.Game, path: []const u8) !void {
    const bytes = try agent.png.encode(gpa, sorz.picture.width, sorz.picture.height, game.pic.pixels);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// The sound played, as a 16-bit PCM WAV file.
fn writeWav(gpa: std.mem.Allocator, io: std.Io, path: []const u8, pcm: []const i16, format: sorz.platform.AudioFormat) !void {
    const data_bytes: u32 = @intCast(pcm.len * 2);
    const bytes = try gpa.alloc(u8, 44 + data_bytes);
    defer gpa.free(bytes);
    const channels: u32 = format.channels;
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_bytes, .little);
    @memcpy(bytes[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], @intCast(channels), .little);
    std.mem.writeInt(u32, bytes[24..28], format.sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], format.sample_rate * channels * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], @intCast(channels * 2), .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);
    for (pcm, 0..) |v, i| std.mem.writeInt(i16, bytes[44 + 2 * i ..][0..2], v, .little);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn fail(io: std.Io) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(usage);
    try w.interface.flush();
    std.process.exit(2);
}

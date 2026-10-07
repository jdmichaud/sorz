//! sorz-agent: the headless host. It runs the game on the agent backend for a number of frames,
//! one display tick each on a virtual clock, presses keys at the frames it is told, and prints one
//! JSON line with the counts, the hashes of the state, of the last frame and of the settings, and
//! what the game has to tell about its settings record; it writes the frames it is asked for as PNG
//! files and the sound as a WAV file. Two runs with the same arguments print the same line on every
//! machine; the checks and the debugging build on this.
//!
//! With a game directory or the ROM (its content extracted in memory), the game reads it; with
//! `--saves`, it saves there (its settings record among them). Without them, it runs on in-memory
//! providers, so the run touches no file and never the user's saves (DESIGN.md 5.1). `--netplay`,
//! `--join` play with another game over the network (netplay_cmd.zig).
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const native = @import("native");
const web_page = @import("web_page");

const usage =
    \\usage: sorz-agent [--frames N] [--key FRAME:NAME[:HOLD]]... [--shot FRAME:PATH]... [--wav PATH]
    \\                  [DIR|ROM] [--saves DIR] [--original | --page]
    \\       sorz-agent [DIR|ROM] (--netplay [ADDRESS:]PORT [--delay N] | --join ws://ADDRESS:PORT)
    \\                  [--frames N] [--until-session N] [--key FRAME:NAME[:HOLD]]...
    \\       sorz-agent DIR|ROM --server [ADDRESS:]PORT
    \\       sorz-agent DIR|ROM --scenario FILE [--situation TRACE [--situation-probe PROBE]
    \\                  [--game-tick N | --take-up] [--level N] [--continues N]] [--trace-events OUT]
    \\                  [--probe OUT]
    \\                  [--reload]
    \\                  [--form-sizes OUT] [--wav PATH] [--shot FRAME:PATH]...
    \\       sorz-agent trace-compare FIRST SECOND [--ticks M] [--pos PIXELS] [--tol FIELD=N]...
    \\                  [--ignore EV[,EV...]] [--scene NAME] [--after TICK] [--ignore-kind K[,K...]]
    \\                  [--ignore-field F[,F...]] [--sounds SOUNDS_JSON] [--renumber] [--close-ids]
    \\                  [--all]
    \\  --frames N       run N frames, a display tick each (default 120)
    \\  --key FRAME:NAME[:HOLD]  press the key NAME (a platform.Key, as `enter` or `left`) at
    \\                   frame FRAME, release it HOLD frames later (default 1); repeats
    \\  --shot FRAME:PATH  write the picture presented at frame FRAME as a PNG file; repeats
    \\  --wav PATH       write the sound played as a WAV file
    \\  DIR|ROM          the game directory (its content tree), or the user's ROM, whose content
    \\                   is extracted in memory; without either, a test pattern
    \\  --saves DIR      where saves are kept, the settings record (settings.json) among them
    \\  --original       the cartridge's variant (DESIGN.md 10.7): its game menu, options and
    \\                   pause, the settings by the settings key; the default is the extended
    \\                   game, network play's the network variant
    \\  --page           the game as a browser's page runs it alone: the network variant, one
    \\                   player (pad 1's keys and every gamepad), the page's own volume
    \\  --netplay, --join  network play over WebSockets, as the host (player 1) or the guest
    \\                   (player 2): each game plays its own front end with its keys (--key by
    \\                   update), and the guest's 2 PLAYERS and character join the host's game;
    \\                   --frames counts the updates, --until-session N ends the run once the
    \\                   session ran N ticks; prints the game's hashes and its network play
    \\  --delay N        the host's input delay, 2 to 6 (default: from the round trip)
    \\  --server         server mode, as sorz-server: serve the page and the game's files of
    \\                   DIR|ROM, and relay network play between two browsers, with no game
    \\  --scenario FILE  run a scenario (sor-remaster's format): from power-on, the whole game
    \\                   (its start through the screens, or a recorded play's pads), or with
    \\                   --situation from round 1's play in TRACE (another program's trace of
    \\                   it: play's start, or the tick of `start pads FILE V`'s display tick V);
    \\                   its script of pad events to its end; --situation-probe gives the other
    \\                   program's probe of the same run (the frames its entities show);
    \\                   --game-tick gives the round's clock (the other program's tick counter at
    \\                   the script's start, its `script_game_tick`); --level gives the options'
    \\                   LEVEL of the game taken up (0, the easiest, to 3; 1 by default), --continues
    \\                   each player's continues left (a trace from a reference does not tell them;
    \\                   0 by default); --take-up runs the whole
    \\                   game from power-on with the recorded play's pads, the round's world
    \\                   taken up from TRACE's at the script's start (from there, the other
    \\                   program's world goes on in sorz's game); --trace-events writes its
    \\                   semantic trace, --probe the fighters' frames, boxes and power (from
    \\                   power-on, with the trace); a condition that does not come in time ends
    \\                   the run with status 1; from power-on, --reload reads the state back
    \\                   from its canonical form at each display tick and goes on from the state
    \\                   read (a round trip: it must be the state written), --form-sizes writes
    \\                   the form's size at each (tick, scene, entities, bytes), --wav its sound,
    \\                   --shot its pictures (FRAME the display tick from 0, as without one)
    \\  trace-compare    compare two semantic traces (sor-remaster's docs/traces.md): the first
    \\                   difference and the counts per kind of event; events match within
    \\                   --ticks M ticks, positions and speeds within --pos PIXELS, a field
    \\                   within --tol's N (its own unit); --ignore leaves kinds of event out,
    \\                   --ignore-kind the events about entities of those kinds, --ignore-field
    \\                   fields; --scene compares the last scene of that name in each, after
    \\                   tick --after; --sounds names the first trace's sounds (sor-remaster's
    \\                   `sfx_b2`) as the sound content's sounds.json does (\"enemy hit\");
    \\                   --renumber numbers the entities by their order of appearance (the
    \\                   ignored kinds left out); --close-ids gives up the numbers the ignored
    \\                   kinds took after --after; --all writes every difference; exits 1 when
    \\                   they differ
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
    var until_session: ?u32 = null;
    var as_page = false;
    var scenario: ?agent.scenario_cmd.Options = null;
    var situation: ?[]const u8 = null;
    var situation_probe: ?[]const u8 = null;
    var game_tick: ?u32 = null;
    var take_up = false;
    var level: ?u2 = null;
    var continues: ?u8 = null;
    var trace_events: ?[]const u8 = null;
    var probe: ?[]const u8 = null;
    var reload = false;
    var form_sizes: ?[]const u8 = null;
    var options: native.cli.Options = .{};
    // `iterateAllocator` is the form that Windows needs; the arena keeps the arguments for the
    // whole run.
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    var first_arg = true;
    while (args.next()) |arg| {
        if (first_arg and std.mem.eql(u8, arg, "trace-compare")) {
            var obuf: [4096]u8 = undefined;
            var ow = std.Io.File.stdout().writerStreaming(io, &obuf);
            const same = try traceCompare(init, &args, &ow.interface);
            try ow.interface.flush();
            if (!same) std.process.exit(1);
            return;
        }
        first_arg = false;
        if (options.take(arg, &args) catch return fail(io)) continue;
        if (std.mem.eql(u8, arg, "--frames")) {
            frames = std.fmt.parseInt(u64, args.next() orelse return fail(io), 10) catch return fail(io);
        } else if (std.mem.eql(u8, arg, "--key")) {
            try presses.append(gpa, parsePress(args.next() orelse return fail(io)) orelse return fail(io));
        } else if (std.mem.eql(u8, arg, "--shot")) {
            try shots.append(gpa, parseShot(args.next() orelse return fail(io)) orelse return fail(io));
        } else if (std.mem.eql(u8, arg, "--wav")) {
            wav_path = args.next() orelse return fail(io);
        } else if (std.mem.eql(u8, arg, "--until-session")) {
            until_session = std.fmt.parseInt(u32, args.next() orelse return fail(io), 10) catch return fail(io);
        } else if (std.mem.eql(u8, arg, "--page")) {
            as_page = true;
        } else if (std.mem.eql(u8, arg, "--scenario")) {
            scenario = .{ .scenario = args.next() orelse return fail(io) };
        } else if (std.mem.eql(u8, arg, "--situation")) {
            situation = args.next() orelse return fail(io);
        } else if (std.mem.eql(u8, arg, "--situation-probe")) {
            situation_probe = args.next() orelse return fail(io);
        } else if (std.mem.eql(u8, arg, "--game-tick")) {
            game_tick = std.fmt.parseInt(u32, args.next() orelse return fail(io), 10) catch return fail(io);
        } else if (std.mem.eql(u8, arg, "--take-up")) {
            take_up = true;
        } else if (std.mem.eql(u8, arg, "--level")) {
            level = std.fmt.parseInt(u2, args.next() orelse return fail(io), 10) catch return fail(io);
        } else if (std.mem.eql(u8, arg, "--continues")) {
            continues = std.fmt.parseInt(u8, args.next() orelse return fail(io), 10) catch return fail(io);
        } else if (std.mem.eql(u8, arg, "--trace-events")) {
            trace_events = args.next() orelse return fail(io);
        } else if (std.mem.eql(u8, arg, "--probe")) {
            probe = args.next() orelse return fail(io);
        } else if (std.mem.eql(u8, arg, "--reload")) {
            reload = true;
        } else if (std.mem.eql(u8, arg, "--form-sizes")) {
            form_sizes = args.next() orelse return fail(io);
        } else {
            return fail(io);
        }
    }

    // Server mode: the relay and the game's files, as sorz-server runs it.
    if (options.server) |address| {
        _ = options.network() catch return fail(io);
        if (presses.items.len != 0 or until_session != null or shots.items.len != 0 or wav_path != null) return fail(io);
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

    // A scenario's run, on the game's data.
    if (scenario) |*sc| {
        if (options.assets == null or until_session != null or presses.items.len != 0) return fail(io);
        // A situation's world alone has no sound and no pictures; one taken up in the whole
        // game has, and no clock of its own.
        if (take_up and (situation == null or game_tick != null)) return fail(io);
        // The level of a game taken up: a world taken up alone (the whole game's options give it).
        if ((level != null or continues != null) and (situation == null or take_up)) return fail(io);
        if (situation != null and !take_up and (wav_path != null or shots.items.len != 0)) return fail(io);
        sc.situation = situation;
        sc.situation_probe = situation_probe;
        sc.game_tick = game_tick;
        sc.take_up = take_up;
        if (level) |l| sc.level = l;
        if (continues) |n| sc.continues = n;
        sc.trace = trace_events;
        sc.probe = probe;
        sc.wav = wav_path;
        const scenario_shots = try gpa.alloc(agent.scenario_cmd.Shot, shots.items.len);
        defer gpa.free(scenario_shots);
        for (scenario_shots, shots.items) |*o, s| o.* = .{ .frame = s.frame, .path = s.path };
        sc.shots = scenario_shots;
        sc.reload = reload;
        sc.form_sizes = form_sizes;
        var obuf: [512]u8 = undefined;
        var ow = std.Io.File.stdout().writerStreaming(io, &obuf);
        const done = agent.scenario_cmd.run(gpa, io, assets.?, sc.*, &ow.interface) catch |err| {
            std.log.err("the scenario did not run: {s}", .{@errorName(err)});
            std.process.exit(2);
        };
        try ow.interface.flush();
        if (!done) std.process.exit(1);
        return;
    }
    if (situation != null or situation_probe != null or game_tick != null or take_up or trace_events != null or probe != null or reload or form_sizes != null) return fail(io);

    // Network play over WebSockets (`--delay` goes with `--netplay`).
    const network = options.network() catch return fail(io);
    if (network == .netplay) {
        if (shots.items.len != 0 or wav_path != null or options.original) return fail(io);
        const identity = providers.dataIdentity() catch |err| {
            std.log.err("cannot read the game data for its identity: {s}", .{@errorName(err)});
            std.process.exit(2);
        };
        var obuf: [2048]u8 = undefined;
        var ow = std.Io.File.stdout().writerStreaming(io, &obuf);
        const ok = try agent.netplay_cmd.process(gpa, io, assets, storage, options.netplayOptions(identity), page, providers.assetSource(), frames, until_session, presses.items, &ow.interface);
        try ow.interface.flush();
        if (!ok) std.process.exit(1);
        return;
    }
    if (until_session != null) return fail(io);

    var backend = agent.AgentBackend.init(gpa, .{});
    defer backend.deinit();
    backend.audio.record = wav_path != null;
    var game = try sorz.Game.init(gpa, assets, storage);
    defer game.deinit();
    game.pacing = .per_update;
    game.variant = options.variant();
    if (as_page) {
        // The game as a browser's page runs it alone (web/main.zig).
        game.variant = .network;
        game.setOnePlayer();
        game.host_volume = true;
    }
    var p = backend.asPlatform();
    var frame: u64 = 0;
    var shots_written: usize = 0;
    while (frame < frames) : (frame += 1) {
        for (presses.items) |press| {
            if (press.frame == frame) try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_down = .{ .key = press.key } } });
            if (press.frame +| press.hold == frame) try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_up = .{ .key = press.key } } });
        }
        if (try game.update(&p) == .finished) break;
        for (shots.items) |shot| if (shot.frame == frame) {
            try writeShot(gpa, io, &game, shot.path);
            shots_written += 1;
        };
        backend.advance(frame_ns);
    }
    // A picture asked for and not written (its frame past the run's end, or the game finished
    // before it) fails the run: a check must not compare a picture that is not there.
    if (shots_written != shots.items.len) {
        for (shots.items) |shot| if (shot.frame >= frame) std.log.err("no picture for --shot {d}:{s}: the run ended at frame {d}", .{ shot.frame, shot.path, frame });
        std.process.exit(1);
    }
    if (wav_path) |path| try agent.wav.write(gpa, io, path, backend.audio.pcm.items, backend.audio.format.channels, backend.audio.format.sample_rate);

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
    const f = game.frame();
    std.debug.assert(f.stride == f.width * 4);
    const bytes = try agent.png.encode(gpa, f.width, f.height, f.pixels[0 .. f.stride * f.height]);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// `trace-compare FIRST SECOND [options]`: true when the traces agree.
fn traceCompare(init: std.process.Init, args: anytype, out: *std.Io.Writer) !bool {
    const io = init.io;
    const arena = init.arena.allocator();
    const compare = agent.trace_compare;
    var paths: [2][]const u8 = undefined;
    var n: usize = 0;
    var options: compare.Options = .{};
    var tolerances: std.ArrayList(compare.Tolerance) = .empty;
    var ignore: std.ArrayList([]const u8) = .empty;
    var ignore_kinds: std.ArrayList([]const u8) = .empty;
    var ignore_fields: std.ArrayList([]const u8) = .empty;
    var sounds: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ticks")) {
            options.ticks = std.fmt.parseInt(i64, args.next() orelse return failed(io), 10) catch return failed(io);
        } else if (std.mem.eql(u8, arg, "--pos")) {
            const px = std.fmt.parseInt(i64, args.next() orelse return failed(io), 10) catch return failed(io);
            for (compare.position_fields) |f| try tolerances.append(arena, .{ .field = f, .within = px * 65536 });
        } else if (std.mem.eql(u8, arg, "--tol")) {
            const spec = args.next() orelse return failed(io);
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return failed(io);
            const within = std.fmt.parseInt(i64, spec[eq + 1 ..], 10) catch return failed(io);
            try tolerances.append(arena, .{ .field = spec[0..eq], .within = within });
        } else if (std.mem.eql(u8, arg, "--ignore") or std.mem.eql(u8, arg, "--ignore-kind") or std.mem.eql(u8, arg, "--ignore-field")) {
            const list = if (std.mem.eql(u8, arg, "--ignore")) &ignore else if (std.mem.eql(u8, arg, "--ignore-kind")) &ignore_kinds else &ignore_fields;
            var it = std.mem.splitScalar(u8, args.next() orelse return failed(io), ',');
            while (it.next()) |x| if (x.len != 0) try list.append(arena, x);
        } else if (std.mem.eql(u8, arg, "--scene")) {
            options.from_scene = args.next() orelse return failed(io);
        } else if (std.mem.eql(u8, arg, "--after")) {
            options.after = std.fmt.parseInt(i64, args.next() orelse return failed(io), 10) catch return failed(io);
        } else if (std.mem.eql(u8, arg, "--sounds")) {
            sounds = args.next() orelse return failed(io);
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.all = true;
        } else if (std.mem.eql(u8, arg, "--renumber")) {
            options.renumber = true;
        } else if (std.mem.eql(u8, arg, "--close-ids")) {
            options.close_ids = true;
        } else if (n < 2 and arg.len != 0 and arg[0] != '-') {
            paths[n] = arg;
            n += 1;
        } else return failed(io);
    }
    if (n != 2) return failed(io);
    options.tolerances = tolerances.items;
    options.ignore = ignore.items;
    options.ignore_kinds = ignore_kinds.items;
    options.ignore_fields = ignore_fields.items;
    if (sounds) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24)) catch |err| {
            std.log.err("cannot read the sounds {s}: {s}", .{ path, @errorName(err) });
            std.process.exit(2);
        };
        options.sound_names = compare.soundNames(arena, text) catch |err| {
            std.log.err("the sounds {s} are refused: {s}", .{ path, @errorName(err) });
            std.process.exit(2);
        };
    }
    var traces: [2]compare.Trace = undefined;
    for (paths, 0..) |path, k| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 31)) catch |err| {
            std.log.err("cannot read the trace {s}: {s}", .{ path, @errorName(err) });
            std.process.exit(2);
        };
        var diag: compare.Diagnostic = .{};
        const t = compare.parse(arena, text, &diag) catch |err| {
            std.log.err("the trace {s} is refused at line {d}: {s} ({s})", .{ path, diag.line, diag.what, @errorName(err) });
            std.process.exit(2);
        };
        traces[k] = compare.restrict(arena, &t, options, k == 0) catch |err| {
            std.log.err("the trace {s} has no scene {s} ({s})", .{ path, options.from_scene orelse "", @errorName(err) });
            std.process.exit(2);
        };
    }
    const result = try compare.compare(arena, &traces[0], &traces[1], options, out);
    try out.print("{{\"same\":{},\"differences\":{d}}}\n", .{ result.differences == 0, result.differences });
    return result.differences == 0;
}

fn failed(io: std.Io) bool {
    fail(io) catch {};
    return false;
}

fn fail(io: std.Io) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(usage);
    try w.interface.flush();
    std.process.exit(2);
}

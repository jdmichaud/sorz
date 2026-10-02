//! The sound's exactness check (PLAN 09, DESIGN.md A4): the sequencer against sor-remaster's
//! driver, the reference. Both play the same requests from the user's ROM, update by update: their
//! chip writes and sample requests are compared call by call, and the bus holds that time the
//! samples; then their PCM, byte by byte. `zig build sound-check -Drom=ROM -Dremaster=DIR` (DIR: a
//! sor-remaster checkout, built as a library, never written to).
//!
//! The scenarios: every song alone for minutes, every effect alone and over a song, every ordered
//! pair of effects, song changes, fades, pauses, voices over songs (the drum hold), the stops, and
//! random requests. The first difference of a scenario is named: the call, the write, both sides.
const std = @import("std");
const sorz = @import("sorz");
const extract = @import("extract");
const remaster = @import("remaster");
const audio = sorz.audio;
const R = remaster.audio;

/// A request at a call: the sound's index in the content, into a free slot or into the first.
const Ask = struct { call: u32, sound: u16, first: bool = false };

const Scenario = struct {
    name: []const u8,
    calls: u32,
    asks: []const Ask,
};

const Result = struct {
    calls: u32 = 0,
    writes: u64 = 0,
    /// The first difference, if any.
    differs: ?[]const u8 = null,
    reference_fault: ?[]const u8 = null,
    sequencer_fault: ?[]const u8 = null,
};

/// sor-remaster's driver with its own state, as its game runs it.
const Reference = struct {
    ram: R.Ram = .{},
    fade: u8 = 0,
    slots: [3]u8 = @splat(0),
    out: R.Output = .{},

    fn ask(r: *Reference, request: u8, first: bool) void {
        if (first) {
            r.slots[0] = request;
            return;
        }
        for (r.slots) |s| if (s == request) return;
        for (&r.slots) |*s| if (s.* == 0) {
            s.* = request;
            return;
        };
    }
};

/// The content's files in memory, as the loader reads them.
const Files = struct {
    list: []const audio.files.File,
    pub fn read(f: Files, path: []const u8) error{FileNotFound}![]const u8 {
        for (f.list) |file| if (std.mem.eql(u8, file.path, path)) return file.bytes;
        return error.FileNotFound;
    }
};

const Context = struct {
    arena: std.mem.Allocator,
    content: *const audio.content.Content,
    requests: []const u8,
    source: R.driver.Source,
    samples: []const remaster.assets.model.Sample,
};

fn spell(buf: []u8, port: audio.chips.registers.Port, value: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{X:0>2}", .{ @tagName(port), value }) catch "?";
}

/// A reference write in the sequencer's terms.
fn fromReference(w: R.Write) audio.sequencer.Write {
    return switch (w.chip) {
        .ym => .{ .port = @fromBackingInt(@intCast(w.port & 3)), .value = w.value },
        .psg => .{ .port = .psg, .value = w.value },
        .z80 => .{ .port = .sample, .value = if (w.value >= 0x81 and w.value <= 0x91) w.value - 0x81 else if (w.value & 0x80 != 0) audio.sequencer.stop_code else audio.sequencer.none_code },
    };
}

fn run(ctx: *const Context, sc: Scenario) !Result {
    var res: Result = .{};
    const ref = try ctx.arena.create(Reference);
    defer ctx.arena.destroy(ref);
    ref.* = .{};
    const seq = try ctx.arena.create(audio.Sequencer);
    defer ctx.arena.destroy(seq);
    seq.* = .init(ctx.content);
    for (0..sc.calls) |c| {
        const call: u32 = @intCast(c);
        for (sc.asks) |a| if (a.call == call) {
            ref.ask(ctx.requests[a.sound], a.first);
            if (a.first) seq.requestFirst(a.sound) else seq.request(a.sound);
        };
        ref.out.clear();
        ref.ram.z80.vblank();
        if (R.update(&ref.ram, .{ .fade = &ref.fade, .requests = &ref.slots }, ctx.source, &ref.out)) |f| {
            res.reference_fault = try std.fmt.allocPrint(ctx.arena, "call {d}: {s} (0x{X})", .{ call, f.what, f.address orelse 0 });
            return res;
        }
        const tick = seq.update();
        if (seq.fault) |f| {
            var asked: std.ArrayList(u8) = .empty;
            for (sc.asks) |a| if (a.call + 400 >= call and a.call <= call) try asked.print(ctx.arena, " {d}:{s}", .{ a.call, ctx.content.sounds[a.sound].name });
            res.sequencer_fault = try std.fmt.allocPrint(ctx.arena, "call {d}: {s} ({X}); asked:{s}; reference wrote {d}{s}", .{ call, f.what, f.detail, asked.items, ref.out.items().len, try context(ctx.arena, ref.out.items(), tick.items(), 0) });
            return res;
        }
        const theirs = ref.out.items();
        const ours = tick.items();
        res.calls = call + 1;
        res.writes += theirs.len;
        const n = @min(theirs.len, ours.len);
        var first: ?usize = null;
        for (0..n) |i| {
            const t = fromReference(theirs[i]);
            if (t.port != ours[i].port or t.value != ours[i].value) {
                first = i;
                break;
            }
        }
        if (first == null and theirs.len != ours.len) first = n;
        if (first) |i| {
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            const t = if (i < theirs.len) spell(&b1, fromReference(theirs[i]).port, fromReference(theirs[i]).value) else "(none)";
            const o = if (i < ours.len) spell(&b2, ours[i].port, ours[i].value) else "(none)";
            res.differs = try std.fmt.allocPrint(ctx.arena, "call {d}, write {d} of {d}/{d}: reference {s}, sequencer {s}{s}", .{ call, i, theirs.len, ours.len, t, o, try context(ctx.arena, theirs, ours, i) });
            return res;
        }
        const hold = if (ref.out.calls > 0) ref.out.call(0).hold else 0;
        if (hold != tick.hold) {
            res.differs = try std.fmt.allocPrint(ctx.arena, "call {d}: bus hold reference {d}, sequencer {d}", .{ call, hold, tick.hold });
            return res;
        }
    }
    return res;
}

/// The PCM of both sides at 48 kHz with the model 1 stage: sor-remaster's player on its driver's
/// writes, the output stage on the sequencer's.
fn runPcm(ctx: *const Context, gpa: std.mem.Allocator, sc: Scenario) !Result {
    var res: Result = .{};
    const ref = try ctx.arena.create(Reference);
    defer ctx.arena.destroy(ref);
    ref.* = .{};
    const seq = try ctx.arena.create(audio.Sequencer);
    defer ctx.arena.destroy(seq);
    seq.* = .init(ctx.content);
    var player = try R.Player.init(gpa, ctx.samples, 48000, true);
    defer player.deinit(gpa);
    var out = try audio.output.Output.init(gpa, ctx.content, 48000, true);
    defer out.deinit(gpa);
    for (0..sc.calls) |c| {
        const call: u32 = @intCast(c);
        for (sc.asks) |a| if (a.call == call) {
            ref.ask(ctx.requests[a.sound], a.first);
            if (a.first) seq.requestFirst(a.sound) else seq.request(a.sound);
        };
        ref.out.clear();
        ref.ram.z80.vblank();
        if (R.update(&ref.ram, .{ .fade = &ref.fade, .requests = &ref.slots }, ctx.source, &ref.out)) |f| {
            res.reference_fault = try std.fmt.allocPrint(ctx.arena, "call {d}: {s}", .{ call, f.what });
            return res;
        }
        const tick = seq.update();
        const theirs = player.vblank(ref.out.items(), if (ref.out.calls > 0) ref.out.call(0).hold else 0);
        const ours = out.tick(tick);
        res.calls = call + 1;
        res.writes += theirs.len;
        if (!std.mem.eql(i16, theirs, ours)) {
            const at = std.mem.indexOfDiff(i16, theirs, ours) orelse 0;
            res.differs = try std.fmt.allocPrint(ctx.arena, "call {d}: {d}/{d} values, first difference at {d}", .{ call, theirs.len, ours.len, at });
            return res;
        }
    }
    return res;
}

/// The writes around a difference, both sides.
fn context(arena: std.mem.Allocator, theirs: []const R.Write, ours: []const audio.sequencer.Write, at: usize) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    const from = at -| 6;
    try text.appendSlice(arena, "\n      reference:");
    for (theirs[from..@min(theirs.len, at + 6)]) |w| {
        var b: [32]u8 = undefined;
        const s = fromReference(w);
        try text.print(arena, " {s}", .{spell(&b, s.port, s.value)});
    }
    try text.appendSlice(arena, "\n      sequencer:");
    for (ours[@min(from, ours.len)..@min(ours.len, at + 6)]) |w| {
        var b: [32]u8 = undefined;
        try text.print(arena, " {s}", .{spell(&b, w.port, w.value)});
    }
    return text.items;
}

const Suite = struct {
    ctx: *const Context,
    passed: u32 = 0,
    failed: u32 = 0,
    calls: u64 = 0,
    writes: u64 = 0,
    shown: u32 = 0,
    /// The scenarios that differed, over every group.
    differed: u32 = 0,

    fn check(s: *Suite, sc: Scenario) !void {
        return s.record(sc, try run(s.ctx, sc));
    }

    fn checkPcm(s: *Suite, gpa: std.mem.Allocator, sc: Scenario) !void {
        return s.record(sc, try runPcm(s.ctx, gpa, sc));
    }

    fn record(s: *Suite, sc: Scenario, r: Result) !void {
        s.calls += r.calls;
        s.writes += r.writes;
        if (r.differs == null and r.reference_fault == null and r.sequencer_fault == null) {
            s.passed += 1;
            return;
        }
        s.failed += 1;
        if (s.shown >= 12) return;
        s.shown += 1;
        if (r.reference_fault) |f| std.debug.print("  {s}: the reference faults at {s}\n", .{ sc.name, f });
        if (r.sequencer_fault) |f| std.debug.print("  {s}: the sequencer faults at {s}\n", .{ sc.name, f });
        if (r.differs) |d| std.debug.print("  {s}: {s}\n", .{ sc.name, d });
    }

    fn report(s: *Suite, what: []const u8) void {
        const unit = if (std.mem.startsWith(u8, what, "PCM")) "PCM values" else "writes";
        std.debug.print("{s}: {d} of {d} equal ({d} calls, {d} {s})\n", .{ what, s.passed, s.passed + s.failed, s.calls, s.writes, unit });
        s.* = .{ .ctx = s.ctx, .differed = s.differed + s.failed };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const rom_path = args.next() orelse return error.Usage;
    // Options: `--only GROUP` runs one group of scenarios; `--tree DIR` writes the content's
    // files there.
    var only: ?[]const u8 = null;
    var tree_dir: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--only")) {
            only = args.next() orelse return error.Usage;
        } else if (std.mem.eql(u8, arg, "--tree")) {
            tree_dir = args.next() orelse return error.Usage;
        } else return error.Usage;
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, arena, .limited(1 << 20));
    var why: extract.sound.Refusal = .{};
    const x = extract.sound.extract(arena, rom, &why) catch |err| {
        std.debug.print("extraction refused: {s} at 0x{X} ({s})\n", .{ why.why, why.at, @errorName(err) });
        return err;
    };
    // The content's files, written twice (byte for byte the same), then loaded: the sequencer
    // plays what the files hold.
    const tree = try extract.sound.files(arena, &x.content);
    const again = try extract.sound.files(arena, &(try extract.sound.extract(arena, rom, &why)).content);
    var bytes: usize = 0;
    for (tree, again) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.bytes, b.bytes)) {
            std.debug.print("two extractions differ at {s}\n", .{a.path});
            return error.NotRepeatable;
        }
        bytes += a.bytes.len;
        if (tree_dir) |dir| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, a.path });
            try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = a.bytes });
        }
    }
    var diag: sorz.formats.json.Diagnostic = .{};
    const loaded = audio.files.load(arena, Files{ .list = tree }, &diag) catch |err| {
        std.debug.print("the content's files do not load: {f}\n", .{diag});
        return err;
    };
    std.debug.print("content: {d} files, {d} bytes, the same from two extractions; loaded back\n", .{ tree.len, bytes });
    const data = try remaster.exporter.rom.decode(arena, rom);
    // The reference reads the ROM's bytes where its asset tree has no record of them: effect $C5
    // reads its volume table past the twenty levels the tree keeps.
    const whole = try arena.dupe(remaster.assets.model.Region, &.{.{ .source = 0, .bytes = rom }});
    const ctx: Context = .{
        .arena = arena,
        .content = &loaded,
        .requests = x.requests,
        .source = .{ .assets = &data.assets, .regions = whole },
        .samples = data.assets.samples,
    };
    const c = &loaded;
    var songs: std.ArrayList(u16) = .empty;
    var effects: std.ArrayList(u16) = .empty;
    var voices: std.ArrayList(u16) = .empty;
    var fade: u16 = 0;
    var stop: u16 = 0;
    var stop_effects: u16 = 0;
    var pause: u16 = 0;
    for (c.sounds, 0..) |snd, i| switch (snd.plays) {
        .song => try songs.append(arena, @intCast(i)),
        .effect => {
            try effects.append(arena, @intCast(i));
            if (std.mem.eql(u8, snd.name, "pause")) pause = @intCast(i);
        },
        .sample => try voices.append(arena, @intCast(i)),
        .fade_out => fade = @intCast(i),
        .stop => stop = @intCast(i),
        .stop_effects => stop_effects = @intCast(i),
    };
    var suite: Suite = .{ .ctx = &ctx };
    const want = struct {
        fn f(o: ?[]const u8, name: []const u8) bool {
            return o == null or std.mem.eql(u8, o.?, name);
        }
    }.f;

    if (want(only, "songs")) {
        for (songs.items) |s| try suite.check(.{ .name = c.sounds[s].name, .calls = 30_000, .asks = &.{.{ .call = 0, .sound = s }} });
        suite.report("songs alone, 30,000 calls each");
    }
    if (want(only, "round6")) {
        for (songs.items) |s| if (std.mem.eql(u8, c.sounds[s].name, "round 6 music")) {
            try suite.check(.{ .name = c.sounds[s].name, .calls = 300_000, .asks = &.{.{ .call = 0, .sound = s }} });
        };
        suite.report("round 6 music for 300,000 calls (its stray loop end)");
    }
    if (want(only, "effects")) {
        for (effects.items) |e| try suite.check(.{ .name = c.sounds[e].name, .calls = 900, .asks = &.{.{ .call = 0, .sound = e }} });
        suite.report("effects alone");
        for (songs.items) |s| for (effects.items) |e| {
            const asks = try arena.dupe(Ask, &.{ .{ .call = 0, .sound = s }, .{ .call = 250, .sound = e }, .{ .call = 700, .sound = e } });
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s} over {s}", .{ c.sounds[e].name, c.sounds[s].name }), .calls = 1500, .asks = asks });
        };
        suite.report("every effect over every song, twice");
    }
    if (want(only, "pairs")) {
        for (effects.items) |a| for (effects.items) |b| for ([_]u32{ 0, 1, 7 }) |gap| {
            const asks = try arena.dupe(Ask, &.{ .{ .call = 0, .sound = songs.items[0] }, .{ .call = 100, .sound = a }, .{ .call = 100 + gap, .sound = b } });
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s} then {s} {d} later", .{ c.sounds[a].name, c.sounds[b].name, gap }), .calls = 400, .asks = asks });
        };
        suite.report("every ordered pair of effects over round 1, 0, 1 and 7 calls apart");
    }
    if (want(only, "changes")) {
        for (songs.items) |a| for (songs.items) |b| {
            const asks = try arena.dupe(Ask, &.{ .{ .call = 0, .sound = a }, .{ .call = 1200, .sound = b } });
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s} then {s}", .{ c.sounds[a].name, c.sounds[b].name }), .calls = 2400, .asks = asks });
        };
        suite.report("every song change");
    }
    if (want(only, "fades")) {
        for (songs.items) |s| {
            const asks = try arena.dupe(Ask, &.{ .{ .call = 0, .sound = s }, .{ .call = 600, .sound = effects.items[2] }, .{ .call = 610, .sound = fade }, .{ .call = 630, .sound = effects.items[0] }, .{ .call = 700, .sound = effects.items[1] }, .{ .call = 750, .sound = s } });
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s} faded", .{c.sounds[s].name}), .calls = 1500, .asks = asks });
        }
        suite.report("fades, with requests during and after");
    }
    if (want(only, "pauses")) {
        for (songs.items) |s| {
            const asks = try arena.dupe(Ask, &.{ .{ .call = 0, .sound = s }, .{ .call = 300, .sound = pause, .first = true }, .{ .call = 360, .sound = effects.items[0] }, .{ .call = 420, .sound = voices.items[0] }, .{ .call = 500, .sound = pause, .first = true }, .{ .call = 520, .sound = effects.items[5] } });
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s} paused", .{c.sounds[s].name}), .calls = 1200, .asks = asks });
        }
        suite.report("pauses");
    }
    if (want(only, "stops")) {
        for (songs.items) |s| {
            const asks = try arena.dupe(Ask, &.{ .{ .call = 0, .sound = s }, .{ .call = 200, .sound = effects.items[3] }, .{ .call = 205, .sound = stop_effects }, .{ .call = 400, .sound = effects.items[13] }, .{ .call = 410, .sound = stop }, .{ .call = 420, .sound = effects.items[6] }, .{ .call = 500, .sound = s } });
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s} stopped", .{c.sounds[s].name}), .calls = 900, .asks = asks });
        }
        suite.report("stops");
    }
    if (want(only, "voices")) {
        for (songs.items) |s| for (voices.items, 0..) |v, k| {
            var asks: std.ArrayList(Ask) = .empty;
            try asks.append(arena, .{ .call = 0, .sound = s });
            var call: u32 = 50 + @as(u32, @intCast(k)) * 7;
            while (call < 6000) : (call += 61 + @as(u32, @intCast(k))) try asks.append(arena, .{ .call = call, .sound = v });
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s} over {s}", .{ c.sounds[v].name, c.sounds[s].name }), .calls = 6000, .asks = asks.items });
        };
        suite.report("voices over every song (the drum hold)");
    }
    if (want(only, "quirks")) {
        // An effect on FM4 started at each update of an FM3 effect's play, alone and over a song:
        // one of them lands on the update that gives FM3 back, whose PassQuirk makes the FM4
        // effect load the song's instruments (or, with no song, the cartridge's first bytes).
        var fm4: std.ArrayList(u16) = .empty;
        for (effects.items) |e| if (c.effects[c.sounds[e].plays.effect].channel == .fm4) try fm4.append(arena, e);
        for (fm4.items) |b| for (effects.items) |a| {
            if (c.effects[c.sounds[a].plays.effect].channel != .fm3) continue;
            for ([_]bool{ false, true }) |with_song| {
                var at: u32 = 1;
                while (at < 120) : (at += 1) {
                    var asks: std.ArrayList(Ask) = .empty;
                    if (with_song) try asks.append(arena, .{ .call = 0, .sound = songs.items[1] });
                    try asks.append(arena, .{ .call = 10, .sound = a });
                    try asks.append(arena, .{ .call = 10 + at, .sound = b });
                    try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s} {d} after {s}{s}", .{ c.sounds[b].name, at, c.sounds[a].name, if (with_song) " over a song" else "" }), .calls = 400, .asks = asks.items });
                }
            }
        };
        suite.report("an FM4 effect at every update of an FM3 effect (the PassQuirk)");
        // Three requests in one update, in every order of priorities; a fourth dropped.
        for (effects.items[0..12]) |a| for (effects.items[12..24]) |b| {
            const asks = try arena.dupe(Ask, &.{ .{ .call = 0, .sound = songs.items[0] }, .{ .call = 50, .sound = a }, .{ .call = 50, .sound = b }, .{ .call = 50, .sound = voices.items[2] }, .{ .call = 50, .sound = effects.items[30] }, .{ .call = 51, .sound = b }, .{ .call = 51, .sound = b } });
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s}, {s}, a voice and a fourth together", .{ c.sounds[a].name, c.sounds[b].name }), .calls = 300, .asks = asks });
        };
        suite.report("full slots");
        // A pause during a fade, a song change and a stop while paused.
        for (songs.items) |s| {
            const asks = try arena.dupe(Ask, &.{ .{ .call = 0, .sound = s }, .{ .call = 100, .sound = fade }, .{ .call = 120, .sound = pause, .first = true }, .{ .call = 300, .sound = s }, .{ .call = 320, .sound = pause, .first = true }, .{ .call = 400, .sound = songs.items[3] }, .{ .call = 500, .sound = pause, .first = true }, .{ .call = 560, .sound = stop }, .{ .call = 600, .sound = pause, .first = true }, .{ .call = 610, .sound = pause, .first = true } });
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "{s} paused across a fade, a change and a stop", .{c.sounds[s].name}), .calls = 900, .asks = asks });
        }
        suite.report("pauses across fades, changes and stops");
    }
    if (want(only, "pcm")) {
        for (songs.items) |s| try suite.checkPcm(gpa, .{ .name = c.sounds[s].name, .calls = 3600, .asks = &.{.{ .call = 0, .sound = s }} });
        suite.report("PCM: songs alone, a minute each");
        for (effects.items) |e| {
            const asks = try arena.dupe(Ask, &.{ .{ .call = 0, .sound = songs.items[0] }, .{ .call = 100, .sound = e } });
            try suite.checkPcm(gpa, .{ .name = c.sounds[e].name, .calls = 500, .asks = asks });
        }
        suite.report("PCM: every effect over round 1");
        for (voices.items, 0..) |v, k| {
            var asks: std.ArrayList(Ask) = .empty;
            try asks.append(arena, .{ .call = 0, .sound = songs.items[k % songs.items.len] });
            var call: u32 = 40;
            while (call < 1500) : (call += 53 + @as(u32, @intCast(k))) try asks.append(arena, .{ .call = call, .sound = v });
            try suite.checkPcm(gpa, .{ .name = c.sounds[v].name, .calls = 1500, .asks = asks.items });
        }
        suite.report("PCM: voices over songs");
        var prng = std.Random.DefaultPrng.init(0x5EED_0FC3);
        const r = prng.random();
        for (0..10) |k| {
            var asks: std.ArrayList(Ask) = .empty;
            try asks.append(arena, .{ .call = 0, .sound = songs.items[(3 * k) % songs.items.len] });
            var call: u32 = 1;
            while (call < 3000) {
                call += r.uintLessThan(u32, 60);
                const pick = r.uintLessThan(u32, 100);
                const sound: u16 = if (pick < 60) effects.items[r.uintLessThan(usize, effects.items.len)] else if (pick < 90) voices.items[r.uintLessThan(usize, voices.items.len)] else if (pick < 97) songs.items[r.uintLessThan(usize, songs.items.len)] else fade;
                try asks.append(arena, .{ .call = call, .sound = sound });
            }
            try suite.checkPcm(gpa, .{ .name = try std.fmt.allocPrint(arena, "random run {d}", .{k}), .calls = 3000, .asks = asks.items });
        }
        suite.report("PCM: random requests, 10 runs");
    }
    if (want(only, "random")) {
        var prng = std.Random.DefaultPrng.init(0x5EED_50E7);
        const r = prng.random();
        for (0..400) |k| {
            var asks: std.ArrayList(Ask) = .empty;
            try asks.append(arena, .{ .call = 0, .sound = songs.items[k % songs.items.len] });
            var call: u32 = 1;
            while (call < 5000) {
                call += r.uintLessThan(u32, 90);
                const pick = r.uintLessThan(u32, 100);
                const sound: u16 = if (pick < 55) effects.items[r.uintLessThan(usize, effects.items.len)] else if (pick < 85) voices.items[r.uintLessThan(usize, voices.items.len)] else if (pick < 95) songs.items[r.uintLessThan(usize, songs.items.len)] else switch (r.uintLessThan(u32, 4)) {
                    0 => fade,
                    1 => stop,
                    2 => stop_effects,
                    else => pause,
                };
                try asks.append(arena, .{ .call = call, .sound = sound, .first = sound == pause });
            }
            try suite.check(.{ .name = try std.fmt.allocPrint(arena, "random run {d}", .{k}), .calls = 5000, .asks = asks.items });
        }
        suite.report("random requests, 400 runs");
    }
    if (suite.differed != 0) {
        std.debug.print("{d} scenarios differ\n", .{suite.differed});
        std.process.exit(1);
    }
}

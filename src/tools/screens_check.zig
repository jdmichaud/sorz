//! sorz-screens-check: the gate of the screens (PLAN item 08): each screen's pictures equal
//! sor-remaster's at the same display ticks from power-on, with the same keys, and its sound.
//!
//!   sorz-screens-check ROM REMASTER_PREFIX OUT_DIR [SCENARIO...]
//!
//! For each scenario (`scenarios` below: the keys pressed and the ticks compared), sor-remaster's
//! agent (REMASTER_PREFIX/bin/sorz-agent, built from its checkout by the build) runs from
//! power-on with the keys and writes its pictures at the ticks compared, and its sound; sorz runs
//! the same keys in this process, on the content extracted from ROM, and each of its pictures is
//! compared with sor-remaster's, pixel by pixel, then the sound, sample by sample. The pictures
//! of a stand-in (a scene sorz does not have yet: the attract demo, play) are not compared. Prints
//! a JSON line per scenario: the pictures compared and the first that differs (its picture and a
//! diff are written in OUT_DIR), the first tick whose sound differs; exits with 1 when anything
//! differs.
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const extract = @import("extract");

const png = sorz.formats.png;
const Press = agent.netplay_cmd.Press;

/// Ticks `from` to `to` (included), every `every`.
const Span = struct { from: u32, to: u32, every: u32 = 1 };

const Scenario = struct {
    name: []const u8,
    /// What it shows, for the reader.
    what: []const u8,
    frames: u32,
    keys: []const Press = &.{},
    /// The ticks whose pictures are compared.
    pictures: []const Span,
    /// Whether the sound is compared (over the whole run).
    sound: bool = true,
};

/// The scenarios: the pictures at the ticks where each screen's parts begin and end, from
/// power-on, with sor-remaster's keys.
pub const scenarios = [_]Scenario{
    .{
        .name = "power_on",
        .what = "power-on, the Sega logo's colour sweep, its wait and its fade, the load of the intro",
        .frames = 330,
        .pictures = &.{.{ .from = 0, .to = 329 }},
    },
    .{
        .name = "logo_start",
        .what = "START during the Sega logo's sweep (and at its first tick and in its hold, where it is not read): its fade, the intro's load",
        .frames = 240,
        .keys = &.{ .{ .frame = 77, .key = .enter }, .{ .frame = 100, .key = .enter }, .{ .frame = 180, .key = .enter } },
        .pictures = &.{.{ .from = 70, .to = 239 }},
    },
    .{
        .name = "logo_start_pad2",
        .what = "pad 2's START during the Sega logo's sweep",
        .frames = 200,
        .keys = &.{.{ .frame = 120, .key = .tab }},
        .pictures = &.{.{ .from = 110, .to = 199 }},
    },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const rom_path = args.next() orelse return usage(io);
    const remaster_prefix = args.next() orelse return usage(io);
    const out_path = args.next() orelse return usage(io);
    var only: std.ArrayList([]const u8) = .empty;
    while (args.next()) |name| try only.append(arena, name);

    const rom = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(extract.rom.size + 1)) catch |e| {
        return fail(io, try std.fmt.allocPrint(arena, "cannot read the ROM {s}: {s}\n", .{ rom_path, @errorName(e) }));
    };
    defer gpa.free(rom);
    var tree = extract.extract(gpa, rom) catch |e| return fail(io, try std.fmt.allocPrint(arena, "cannot extract the ROM: {s}\n", .{@errorName(e)}));
    defer tree.deinit();
    var source = sorz.memory.MemoryAssetSource.init(gpa);
    defer source.deinit();
    try tree.addTo(&source);

    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out_dir.close(io);
    const remaster_agent = try std.fs.path.join(arena, &.{ remaster_prefix, "bin", "sorz-agent" });

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var all_same = true;
    for (scenarios) |sc| {
        if (only.items.len != 0) {
            for (only.items) |n| {
                if (std.mem.eql(u8, n, sc.name)) break;
            } else continue;
        }
        const r = try run(gpa, io, arena, source.assetSource(), remaster_agent, rom_path, out_dir, out_path, &sc);
        all_same = all_same and r.same;
        try out.interface.print("{s}\n", .{r.line});
        try out.interface.flush();
    }
    if (!all_same) std.process.exit(1);
}

const Result = struct { same: bool, line: []const u8 };

fn shotName(arena: std.mem.Allocator, sc: *const Scenario, tick: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}_{d:0>5}.png", .{ sc.name, tick });
}

fn compared(sc: *const Scenario, tick: u32) bool {
    for (sc.pictures) |s| {
        if (tick >= s.from and tick <= s.to and (tick - s.from) % s.every == 0) return true;
    }
    return false;
}

fn run(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, assets: sorz.platform.AssetSource, remaster_agent: []const u8, rom_path: []const u8, out_dir: std.Io.Dir, out_path: []const u8, sc: *const Scenario) !Result {
    // sor-remaster's run: its pictures at the ticks compared, and its sound.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ remaster_agent, rom_path, "--frames", try std.fmt.allocPrint(arena, "{d}", .{sc.frames}) });
    for (sc.keys) |k| try argv.appendSlice(arena, &.{ "--key", try std.fmt.allocPrint(arena, "{d}:{s}:{d}", .{ k.frame, @tagName(k.key), k.hold }) });
    var tick: u32 = 0;
    while (tick < sc.frames) : (tick += 1) {
        if (!compared(sc, tick)) continue;
        const path = try std.fs.path.join(arena, &.{ out_path, "reference", try shotName(arena, sc, tick) });
        try argv.appendSlice(arena, &.{ "--shot", try std.fmt.allocPrint(arena, "{d}:{s}", .{ tick, path }) });
    }
    try out_dir.createDirPath(io, "reference");
    const wav_path = try std.fs.path.join(arena, &.{ out_path, "reference", try std.fmt.allocPrint(arena, "{s}.wav", .{sc.name}) });
    if (sc.sound) try argv.appendSlice(arena, &.{ "--wav", wav_path });
    const ran = try std.process.run(gpa, io, .{ .argv = argv.items });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (ran.term != .exited or ran.term.exited != 0) {
        return .{ .same = false, .line = try std.fmt.allocPrint(arena, "{{\"scenario\":\"{s}\",\"error\":\"sor-remaster's agent failed: {s}\"}}", .{ sc.name, std.mem.trim(u8, ran.stderr, " \n") }) };
    }

    // sorz's run, the same keys, in this process.
    var backend = agent.AgentBackend.init(gpa, .{});
    defer backend.deinit();
    backend.audio.record = sc.sound;
    var memory_storage = sorz.memory.MemoryStorage.init(gpa);
    defer memory_storage.deinit();
    var game = try sorz.Game.init(gpa, assets, memory_storage.storage());
    defer game.deinit();
    game.pacing = .per_update;
    var p = backend.asPlatform();
    var pictures: usize = 0;
    var differing: usize = 0;
    var first: ?struct { tick: u32, pixels: usize } = null;
    tick = 0;
    while (tick < sc.frames) : (tick += 1) {
        for (sc.keys) |k| {
            if (k.frame == tick) try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_down = .{ .key = k.key } } });
            if (k.frame +| k.hold == tick) try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_up = .{ .key = k.key } } });
        }
        if (try game.update(&p) == .finished) break;
        if (compared(sc, tick)) {
            pictures += 1;
            const name = try shotName(arena, sc, tick);
            const ref_bytes = try out_dir.readFileAlloc(io, try std.fs.path.join(arena, &.{ "reference", name }), gpa, .limited(1 << 22));
            defer gpa.free(ref_bytes);
            var ref = try png.decode(gpa, ref_bytes);
            defer ref.deinit(gpa);
            const n = try differ(gpa, io, out_dir, &ref, game.frame(), if (first == null) name else null);
            if (n != 0) {
                differing += 1;
                if (first == null) first = .{ .tick = tick, .pixels = n };
            }
        }
        backend.advance(agent.netplay_cmd.frame_ns);
    }

    var line: std.ArrayList(u8) = .empty;
    try line.print(arena, "{{\"scenario\":\"{s}\",\"frames\":{d},\"pictures\":{d},\"differing\":{d}", .{ sc.name, sc.frames, pictures, differing });
    if (first) |f| try line.print(arena, ",\"first\":{{\"tick\":{d},\"pixels\":{d},\"picture\":\"{s}/sorz_{s}\"}}", .{ f.tick, f.pixels, out_path, try shotName(arena, sc, f.tick) });
    var sound_same = true;
    if (sc.sound) {
        const wav = try std.Io.Dir.cwd().readFileAlloc(io, wav_path, gpa, .limited(1 << 30));
        defer gpa.free(wav);
        const s = soundDifference(wav, backend.audio.pcm.items);
        sound_same = s.first == null;
        try line.print(arena, ",\"sound\":{{\"frames\":{d},\"reference_frames\":{d}", .{ s.frames, s.reference_frames });
        // A tick is 896,040 periods of the 53,693,175 Hz clock: 801 frames at 48 kHz.
        if (s.first) |frame| try line.print(arena, ",\"first_difference\":{{\"frame\":{d},\"tick\":{d}}}", .{ frame, @as(u64, frame) * 53_693_175 / (896_040 * 48_000) });
        try line.appendSlice(arena, "}");
    }
    try line.appendSlice(arena, "}");
    return .{ .same = differing == 0 and sound_same, .line = line.items };
}

/// The pixels of `frame` that differ from the reference picture; when `name` is given and they
/// differ, writes sorz's picture as `sorz_NAME` and the difference as `diff_NAME` (the
/// reference dimmed where equal, red where not).
fn differ(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, ref: *const png.Image, frame: sorz.platform.RgbaFrame, name: ?[]const u8) !usize {
    if (ref.width != frame.width or ref.height != frame.height) return frame.width * frame.height;
    var n: usize = 0;
    for (0..frame.height) |y| for (0..frame.width) |x| {
        const want = ref.palette[ref.pixels[y * frame.width + x]];
        const got = frame.pixels[y * frame.stride + x * 4 ..][0..3];
        if (!std.mem.eql(u8, &want, got)) n += 1;
    };
    if (n == 0 or name == null) return n;
    const shot = try agent.png.encode(gpa, frame.width, frame.height, frame.pixels[0 .. frame.stride * frame.height]);
    defer gpa.free(shot);
    var buf: [128]u8 = undefined;
    try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "sorz_{s}", .{name.?}), .data = shot });
    const diff = try gpa.alloc(u8, frame.width * frame.height * 4);
    defer gpa.free(diff);
    for (0..frame.height) |y| for (0..frame.width) |x| {
        const want = ref.palette[ref.pixels[y * frame.width + x]];
        const got = frame.pixels[y * frame.stride + x * 4 ..][0..3];
        const d = diff[(y * frame.width + x) * 4 ..][0..4];
        d.* = if (std.mem.eql(u8, &want, got)) .{ want[0] / 3, want[1] / 3, want[2] / 3, 255 } else .{ 255, 0, 0, 255 };
    };
    const diff_png = try agent.png.encode(gpa, frame.width, frame.height, diff);
    defer gpa.free(diff_png);
    try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "diff_{s}", .{name.?}), .data = diff_png });
    return n;
}

const SoundDifference = struct { frames: usize, reference_frames: usize, first: ?usize };

/// The first stereo frame where sorz's sound differs from the reference's WAV (16-bit stereo, a
/// 44-byte header), over the length both have.
fn soundDifference(wav: []const u8, pcm: []const i16) SoundDifference {
    const data = if (wav.len > 44) wav[44..] else wav[0..0];
    const ref_frames = data.len / 4;
    const frames = pcm.len / 2;
    for (0..@min(frames, ref_frames)) |i| {
        const l = std.mem.readInt(i16, data[i * 4 ..][0..2], .little);
        const r = std.mem.readInt(i16, data[i * 4 + 2 ..][0..2], .little);
        if (l != pcm[2 * i] or r != pcm[2 * i + 1]) return .{ .frames = frames, .reference_frames = ref_frames, .first = i };
    }
    return .{ .frames = frames, .reference_frames = ref_frames, .first = null };
}

fn usage(io: std.Io) !void {
    return fail(io, "usage: sorz-screens-check ROM REMASTER_PREFIX OUT_DIR [SCENARIO...]\n");
}

fn fail(io: std.Io, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(message);
    try w.interface.flush();
    std.process.exit(2);
}

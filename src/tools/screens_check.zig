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
//! and the sound of a stand-in (a scene sorz does not have yet: the attract demo, play) are left
//! out of the ticks compared. sorz runs its original variant (the cartridge's flow, game menu and
//! options: variant.zig), and sor-remaster's agent its own default, which is the cartridge's too:
//! the options without the port's VOLUME line (its `--options-volume` adds it). Prints
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
    /// Whether the sound is compared, and up to which tick (the attract demo's stand-in plays
    /// round 1's music without the demo's own sounds: the sound is compared before it).
    sound: bool = true,
    sound_until: ?u32 = null,
};

/// The way to the character select: START on the intro, on the title, 1 PLAYER; or 2 PLAYERS.
const select_one = [_]Press{ .{ .frame = 500, .key = .enter }, .{ .frame = 560, .key = .enter }, .{ .frame = 640, .key = .enter } };
const select_two = [_]Press{ .{ .frame = 500, .key = .enter }, .{ .frame = 560, .key = .enter }, .{ .frame = 600, .key = .down }, .{ .frame = 640, .key = .enter } };

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
        .name = "intro",
        .what = "the whole intro and its title with no keys, to the attract demo's load",
        .frames = 5700,
        .pictures = &.{.{ .from = 280, .to = 5695 }},
        .sound_until = 5696,
    },
    .{
        .name = "intro_start",
        .what = "START in the story (the fade to the title in place), the title's colour steps and blink, its timeout to the demo",
        .frames = 760,
        .keys = &.{.{ .frame = 400, .key = .enter }},
        .pictures = &.{.{ .from = 395, .to = 759 }},
    },
    .{
        .name = "intro_start_profiles",
        .what = "START during the profiles (boards 128 cells wide): the fade, the title in place",
        .frames = 3560,
        .keys = &.{.{ .frame = 3500, .key = .enter }},
        .pictures = &.{.{ .from = 3495, .to = 3559 }},
    },
    .{
        .name = "intro_start_flash",
        .what = "START at the first frame of the city's flash's split tick: taken",
        .frames = 4700,
        .keys = &.{.{ .frame = 4659, .key = .enter }},
        .pictures = &.{.{ .from = 4655, .to = 4699 }},
    },
    .{
        .name = "intro_start_lost",
        .what = "START at the second frame of the city's flash's split tick: lost (quirk Q3)",
        .frames = 4700,
        .keys = &.{.{ .frame = 4660, .key = .enter }},
        .pictures = &.{.{ .from = 4655, .to = 4699 }},
    },
    .{
        .name = "intro_start_press",
        .what = "START at the tick PRESS START BUTTON comes (the title path still), and after it (the menu)",
        .frames = 5130,
        .keys = &.{ .{ .frame = 5047, .key = .enter }, .{ .frame = 5100, .key = .enter } },
        .pictures = &.{.{ .from = 5040, .to = 5129 }},
    },
    .{
        .name = "intro_start_menu",
        .what = "START on the script's title: the game menu at once",
        .frames = 5180,
        .keys = &.{.{ .frame = 5100, .key = .enter }},
        .pictures = &.{.{ .from = 5095, .to = 5179 }},
    },
    .{
        .name = "menu",
        .what = "the title by START, the game menu's fade in, the arrow's blink and moves, 1 PLAYER chosen, its fade out",
        .frames = 760,
        .keys = &.{ .{ .frame = 500, .key = .enter }, .{ .frame = 560, .key = .enter }, .{ .frame = 565, .key = .down }, .{ .frame = 566, .key = .down }, .{ .frame = 600, .key = .up }, .{ .frame = 627, .key = .z }, .{ .frame = 640, .key = .enter } },
        .pictures = &.{.{ .from = 500, .to = 759 }},
    },
    .{
        .name = "options",
        .what = "the options: the sound test (its names and sounds), the level, the control, EXIT, back to the menu",
        .frames = 1260,
        .keys = &.{
            .{ .frame = 500, .key = .enter },  .{ .frame = 560, .key = .enter },  .{ .frame = 640, .key = .down },   .{ .frame = 660, .key = .down },
            .{ .frame = 720, .key = .z },      .{ .frame = 852, .key = .enter },  .{ .frame = 870, .key = .right },  .{ .frame = 880, .key = .right },
            .{ .frame = 890, .key = .left },   .{ .frame = 900, .key = .left },   .{ .frame = 910, .key = .left },   .{ .frame = 920, .key = .z },
            .{ .frame = 940, .key = .c },      .{ .frame = 960, .key = .down },   .{ .frame = 961, .key = .right },  .{ .frame = 980, .key = .right },
            .{ .frame = 1000, .key = .right }, .{ .frame = 1010, .key = .right }, .{ .frame = 1020, .key = .left },  .{ .frame = 1030, .key = .down },
            .{ .frame = 1040, .key = .right }, .{ .frame = 1050, .key = .right }, .{ .frame = 1060, .key = .right }, .{ .frame = 1070, .key = .down },
            .{ .frame = 1080, .key = .down },  .{ .frame = 1090, .key = .up },    .{ .frame = 1100, .key = .up },    .{ .frame = 1110, .key = .up },
            .{ .frame = 1120, .key = .up },    .{ .frame = 1130, .key = .up },    .{ .frame = 1140, .key = .z },
        },
        .pictures = &.{.{ .from = 700, .to = 1259 }},
    },
    .{
        .name = "options_hidden",
        .what = "the options' hidden lines opened by pad 2 (A, B, C and right held), the lives and the first round, START leaving",
        .frames = 1200,
        .keys = &.{
            .{ .frame = 500, .key = .enter },          .{ .frame = 560, .key = .enter },          .{ .frame = 640, .key = .down },           .{ .frame = 660, .key = .down },
            .{ .frame = 700, .key = .f, .hold = 100 }, .{ .frame = 700, .key = .g, .hold = 100 }, .{ .frame = 700, .key = .h, .hold = 100 }, .{ .frame = 700, .key = .d, .hold = 100 },
            .{ .frame = 720, .key = .z },              .{ .frame = 860, .key = .down },           .{ .frame = 870, .key = .down },           .{ .frame = 880, .key = .down },
            .{ .frame = 890, .key = .right },          .{ .frame = 900, .key = .right },          .{ .frame = 910, .key = .down },           .{ .frame = 920, .key = .right },
            .{ .frame = 930, .key = .right },          .{ .frame = 940, .key = .right },          .{ .frame = 950, .key = .right },          .{ .frame = 960, .key = .right },
            .{ .frame = 970, .key = .right },          .{ .frame = 980, .key = .right },          .{ .frame = 990, .key = .right },          .{ .frame = 1000, .key = .left },
            .{ .frame = 1010, .key = .down },          .{ .frame = 1020, .key = .down },          .{ .frame = 1030, .key = .up },            .{ .frame = 1040, .key = .up },
            .{ .frame = 1050, .key = .up },            .{ .frame = 1060, .key = .up },            .{ .frame = 1070, .key = .up },            .{ .frame = 1080, .key = .up },
            .{ .frame = 1090, .key = .up },            .{ .frame = 1100, .key = .enter },
        },
        .pictures = &.{.{ .from = 780, .to = 1199 }},
    },
    .{
        .name = "high_scores",
        .what = "the high scores after the attract demo (whose stand-in is not compared), START on them, the Sega logo again",
        .frames = 7720,
        .keys = &.{.{ .frame = 7631, .key = .enter }},
        .pictures = &.{.{ .from = 7625, .to = 7719 }},
        .sound_until = 5696,
    },
    .{
        .name = "high_scores_timeout",
        .what = "the high scores' 600 ticks, then the start-up and the Sega logo again",
        .frames = 8260,
        .pictures = &.{ .{ .from = 7625, .to = 7700 }, .{ .from = 8200, .to = 8259 } },
        .sound_until = 5696,
    },
    .{
        .name = "select_idle",
        .what = "1 PLAYER to the character select: its load, the fade in, Adam posing, the others idle, the eye's blinks",
        .frames = 2200,
        .keys = &select_one,
        .pictures = &.{ .{ .from = 700, .to = 1110 }, .{ .from = 1395, .to = 1425 }, .{ .from = 2015, .to = 2045 } },
    },
    .{
        .name = "select_moves",
        .what = "the cursor's moves (right, round the ends, left, up and down as left, a key at either display tick), the choice, the wait, the fade out, round 1's load",
        .frames = 1170,
        .keys = &(select_one ++ [_]Press{ .{ .frame = 850, .key = .right }, .{ .frame = 869, .key = .right }, .{ .frame = 900, .key = .right }, .{ .frame = 930, .key = .left }, .{ .frame = 960, .key = .up }, .{ .frame = 990, .key = .down }, .{ .frame = 1020, .key = .x } }),
        .pictures = &.{.{ .from = 800, .to = 1158 }},
        .sound_until = 1158,
    },
    .{
        .name = "select_early",
        .what = "presses lost before the select's first tick (in the load, the fade in), then one at a second display tick",
        .frames = 900,
        .keys = &(select_one ++ [_]Press{ .{ .frame = 737, .key = .right }, .{ .frame = 760, .key = .right }, .{ .frame = 803, .key = .right }, .{ .frame = 805, .key = .right } }),
        .pictures = &.{.{ .from = 730, .to = 899 }},
    },
    .{
        .name = "select_two",
        .what = "2 PLAYERS: moves past the other's portrait, both moving in one tick, a press after the choice, both chosen, round 1's load",
        .frames = 1230,
        .keys = &(select_two ++ [_]Press{
            .{ .frame = 850, .key = .right },  .{ .frame = 869, .key = .a },     .{ .frame = 900, .key = .right }, .{ .frame = 930, .key = .left },
            .{ .frame = 930, .key = .d },      .{ .frame = 960, .key = .enter }, .{ .frame = 990, .key = .a },     .{ .frame = 1020, .key = .a },
            .{ .frame = 1050, .key = .right }, .{ .frame = 1080, .key = .g },
        }),
        .pictures = &.{.{ .from = 800, .to = 1218 }},
        .sound_until = 1218,
    },
    .{
        .name = "select_blaze",
        .what = "Blaze's poses and three jumps, each landing a pixel apart (her height keeps its fraction)",
        .frames = 1300,
        .keys = &(select_one ++ [_]Press{.{ .frame = 804, .key = .left }}),
        .pictures = &.{.{ .from = 800, .to = 1299 }},
    },
    .{
        .name = "select_leave",
        .what = "the cursor leaving Blaze in her jump (on the ground at once), and back",
        .frames = 1200,
        .keys = &(select_one ++ [_]Press{ .{ .frame = 804, .key = .left }, .{ .frame = 894, .key = .right }, .{ .frame = 924, .key = .left } }),
        .pictures = &.{.{ .from = 800, .to = 1199 }},
    },
    .{
        .name = "select_two_idle",
        .what = "2 PLAYERS idle: both labels, Adam and Blaze posing, the eye's blinks",
        .frames = 2300,
        .keys = &select_two,
        .pictures = &.{ .{ .from = 700, .to = 1100 }, .{ .from = 1395, .to = 1425 }, .{ .from = 2015, .to = 2045 } },
    },
    .{
        .name = "select_overlap",
        .what = "player 2 on Axel beside Adam: Adam's fist over Axel",
        .frames = 900,
        .keys = &(select_two ++ [_]Press{.{ .frame = 824, .key = .a }}),
        .pictures = &.{.{ .from = 800, .to = 899 }},
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
    game.variant = .original;
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
        // A tick is 896,040 periods of the 53,693,175 Hz clock: about 801 frames at 48 kHz.
        const until: ?usize = if (sc.sound_until) |t| @intCast(@as(u64, t) * 896_040 * 48_000 / 53_693_175) else null;
        const s = soundDifference(wav, backend.audio.pcm.items, until);
        sound_same = s.first == null;
        try line.print(arena, ",\"sound\":{{\"frames\":{d},\"reference_frames\":{d}", .{ s.frames, s.reference_frames });
        // A tick is 896,040 periods of the 53,693,175 Hz clock: 801 frames at 48 kHz.
        if (s.first) |frame| {
            try line.print(arena, ",\"first_difference\":{{\"frame\":{d},\"tick\":{d}}},\"differing_frames\":{d},\"largest\":{d}", .{ frame, @as(u64, frame) * 53_693_175 / (896_040 * 48_000), s.differing, s.largest });
            // sorz's sound beside the reference's, to listen to and to compare.
            var name_buf: [128]u8 = undefined;
            try writeWav(gpa, io, out_dir, try std.fmt.bufPrint(&name_buf, "sorz_{s}.wav", .{sc.name}), backend.audio.pcm.items, wav);
        }
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

const SoundDifference = struct { frames: usize, reference_frames: usize, first: ?usize, differing: usize = 0, largest: u32 = 0 };

/// The first stereo frame where sorz's sound differs from the reference's WAV (16-bit stereo, a
/// 44-byte header), over the length both have, the frames that differ and the largest difference.
fn soundDifference(wav: []const u8, pcm: []const i16, until: ?usize) SoundDifference {
    const data = if (wav.len > 44) wav[44..] else wav[0..0];
    const ref_frames = data.len / 4;
    const frames = pcm.len / 2;
    var d: SoundDifference = .{ .frames = frames, .reference_frames = ref_frames, .first = null };
    for (0..@min(frames, ref_frames, until orelse frames)) |i| {
        const l = std.mem.readInt(i16, data[i * 4 ..][0..2], .little);
        const r = std.mem.readInt(i16, data[i * 4 + 2 ..][0..2], .little);
        if (l == pcm[2 * i] and r == pcm[2 * i + 1]) continue;
        if (d.first == null) d.first = i;
        d.differing += 1;
        d.largest = @max(d.largest, @abs(@as(i32, l) - pcm[2 * i]), @abs(@as(i32, r) - pcm[2 * i + 1]));
    }
    return d;
}

/// `pcm` as a WAV file with the reference's header (the same format).
fn writeWav(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, pcm: []const i16, reference: []const u8) !void {
    const bytes = try gpa.alloc(u8, 44 + pcm.len * 2);
    defer gpa.free(bytes);
    @memcpy(bytes[0..44], reference[0..44]);
    std.mem.writeInt(u32, bytes[4..8], @intCast(36 + pcm.len * 2), .little);
    std.mem.writeInt(u32, bytes[40..44], @intCast(pcm.len * 2), .little);
    for (pcm, 0..) |v, i| std.mem.writeInt(i16, bytes[44 + 2 * i ..][0..2], v, .little);
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
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

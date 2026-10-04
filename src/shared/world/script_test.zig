//! The round's script's tests (script.zig) on a synthetic round and synthetic kinds: a section
//! starts and opens, the wave comes when the camera reaches the wall, the reserve answers the
//! enemies that go, the section is cleared, the next opens with its wall, GO arrow and timer, the
//! boss's section; and the timer.
const std = @import("std");
const testing = std.testing;
const json = @import("../formats/json.zig");
const art = @import("../content/art.zig");
const content_entity = @import("../content/entity.zig");
const content_round = @import("../content/round.zig");
const fixed = @import("fixed.zig");
const random = @import("random.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const world_mod = @import("world.zig");
const output = @import("output.zig");
const systems = @import("systems.zig");
const tick_mod = @import("tick.zig");
const script = @import("script.zig");

const Fixed = fixed.Fixed;
const World = world_mod.World;
const Kinds = kinds_mod.Kinds;

const test_art = blk: {
    const px: [16]u8 = @splat(1);
    const frames = [_]art.Frame{.{ .name = "f", .file = "f.png", .width = 4, .height = 4, .origin_x = 2, .origin_y = 4, .pixels = &px }};
    const sets = [_]art.ArtSet{.{ .name = "t", .frames = &frames }};
    break :blk art.Art{ .sets = &sets };
};

const definitions = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "punk", .text =
    \\{"family": "enemy", "team": "enemy", "behaviour": "none",
    \\ "animations": {"stand": {"loop": true, "frames": [{"frame": "t/f", "ticks": 1}]}}}
    },
    .{ .name = "boss", .text =
    \\{"family": "boss", "team": "enemy", "behaviour": "none",
    \\ "animations": {"stand": {"loop": true, "frames": [{"frame": "t/f", "ticks": 1}]}}}
    },
    .{ .name = "crate", .text =
    \\{"family": "scenery", "team": "neutral", "behaviour": "none",
    \\ "animations": {"stand": {"loop": true, "frames": [{"frame": "t/f", "ticks": 1}]}}}
    },
    .{ .name = "go_arrow", .text =
    \\{"family": "effect", "team": "neutral", "behaviour": "go_arrow",
    \\ "numbers": {"x": 240, "depth": 113, "blinks": 5, "shown": 12, "hidden": 6, "wait": 48},
    \\ "sounds": {"blink": "go arrow"},
    \\ "animations": {"arrow": {"loop": true, "frames": [{"frame": "t/f", "ticks": 1}]}}}
    },
};

/// A round of two sections and a boss: the first section's wall at 400, a placed punk and a
/// crate, a wave of two, a reserve of one; the second's wall at 800; the boss after it.
const round: content_round.Round = .{
    .number = 1,
    .art = "t",
    .music = "music",
    .camera = .{ .x = 0, .y = 0, .x_min = 0, .y_min = 0, .y_max = 0 },
    .players = .{ .x = 0, .depth = .{ 64, 32 }, .height = 0 },
    .timer = .{ .pace = 10 },
    .sections = &.{
        .{
            .wall = 400,
            .timer = 40,
            .opens_after = 5,
            .placed = &.{
                .{ .kind = "punk", .x = 300, .depth = 50 },
                .{ .kind = "crate", .x = 320, .depth = 40 },
                .{ .kind = "punk", .x = 330, .depth = 41, .level = 2 },
                .{ .kind = "punk", .x = 340, .depth = 42, .two_players = true },
                .{ .kind = "unknown_kind", .x = 350, .depth = 43 },
            },
            .wave = &.{
                .{ .kind = "punk", .side = .left, .depth = 32, .after = 3 },
                .{ .kind = "punk", .side = .right, .depth = 60, .after = 4 },
            },
            .reserve = &.{.{ .kind = "punk", .side = .left, .depth = 70, .arrives_after = 6 }},
        },
        .{ .wall = 800, .timer = 50, .opens_after = 7 },
    },
    .boss = .{
        .fade = "fade out",
        .music = "boss music",
        .music_after = 4,
        .wave_after = 3,
        .wave = &.{.{ .kind = "boss", .depth = 16, .after = 2 }},
    },
};

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    kinds: Kinds,
    w: World = .{},
    rng: random.Random = .{},
    out: output.Output = .{},
    plan: script.Plan = .{ .round = &round, .level = 1 },

    fn init() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .arena = .init(testing.allocator), .kinds = undefined };
        errdefer f.deinit();
        const arena = f.arena.allocator();
        var defs: [definitions.len]content_entity.Definition = undefined;
        var diag: json.Diagnostic = .{};
        for (&defs, definitions) |*d, src| {
            const root = try json.parse(arena, src.name, src.text, &diag);
            d.* = try content_entity.read(arena, src.name, root, &test_art);
        }
        f.kinds = try Kinds.bind(arena, try arena.dupe(content_entity.Definition, &defs), &test_art, &diag);
        script.start(&f.w, &f.plan);
        var t = f.tick();
        script.placeFirst(&t, &f.plan);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        testing.allocator.destroy(f);
    }

    fn tick(f: *Fixture) tick_mod.Tick {
        return .{ .world = &f.w, .kinds = &f.kinds, .random = &f.rng, .out = &f.out, .plan = &f.plan };
    }

    /// One logic tick of the world.
    fn step(f: *Fixture) void {
        systems.runRound(&f.w, &f.kinds, &f.rng, .{}, &f.out, &f.plan);
    }

    /// The live entities of kind `name`.
    fn count(f: *const Fixture, name: []const u8) usize {
        const k = f.kinds.find(name).?;
        var n: usize = 0;
        for (&f.w.entities) |*e| {
            if (e.alive() and e.kind == k) n += 1;
        }
        return n;
    }

    /// Removes every live entity of kind `name` (they go, as a knocked-out enemy does).
    fn knockOut(f: *Fixture, name: []const u8) void {
        const k = f.kinds.find(name).?;
        for (&f.w.entities, 0..) |*e, i| {
            if (e.alive() and e.kind == k) f.w.remove(f.w.handleAt(i).?);
        }
    }

    fn soundAsked(f: *const Fixture, name: []const u8) bool {
        for (f.out.sounds.slice()) |s| if (std.mem.eql(u8, s.name, name)) return true;
        return false;
    }
};

test "a section: its placed come, it opens, its wave comes at the wall, its reserve answers, it is cleared" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var f = try Fixture.init();
    defer f.deinit();
    // The placed that come at this level and with one player, the unknown kind skipped.
    try testing.expectEqual(@as(usize, 1), f.count("punk"));
    try testing.expectEqual(@as(usize, 1), f.count("crate"));
    try testing.expectEqual(@as(u8, 1), f.w.script.enemies);
    try testing.expectEqual(script.Stage.opening, f.w.script.stage);
    try testing.expectEqual(@as(i32, 400), f.w.camera.x_max.whole());
    // It opens after its 5 ticks; no GO arrow for the first.
    for (0..4) |_| f.step();
    try testing.expectEqual(script.Stage.opening, f.w.script.stage);
    f.step();
    try testing.expectEqual(script.Stage.wall, f.w.script.stage);
    try testing.expectEqual(@as(usize, 0), f.count("go_arrow"));
    // The camera far from the wall: nothing comes.
    for (0..10) |_| f.step();
    try testing.expectEqual(@as(usize, 1), f.count("punk"));
    // The camera at the wall: the wave, 3 then 4 ticks later, at the screen's edges.
    f.w.camera.x = .pixels(398);
    f.w.camera.x_min = .pixels(398);
    f.step();
    try testing.expectEqual(script.Stage.wave, f.w.script.stage);
    for (0..2) |_| f.step();
    try testing.expectEqual(@as(usize, 1), f.count("punk"));
    f.step();
    try testing.expectEqual(@as(usize, 2), f.count("punk"));
    for (0..4) |_| f.step();
    try testing.expectEqual(@as(usize, 3), f.count("punk"));
    // The punk left behind the camera came back to its left edge when it reached the wall.
    var at_left: usize = 0;
    for (&f.w.entities) |*e| {
        if (e.alive() and e.kind == f.kinds.find("punk").? and e.position.x.whole() == 398 + round.camera.left_behind[0]) at_left += 1;
    }
    try testing.expectEqual(@as(usize, 1), at_left);
    // The wave's end, two ticks on; then an enemy that goes calls the reserve, 6 ticks later.
    for (0..2) |_| f.step();
    try testing.expectEqual(script.Stage.reserve, f.w.script.stage);
    const h = blk: {
        for (&f.w.entities, 0..) |*e, i| if (e.alive() and e.kind == f.kinds.find("punk").?) break :blk f.w.handleAt(i).?;
        unreachable;
    };
    f.w.remove(h);
    f.step();
    try testing.expectEqual(@as(usize, 2), f.count("punk"));
    for (0..5) |_| f.step();
    try testing.expectEqual(@as(usize, 2), f.count("punk"));
    f.step();
    try testing.expectEqual(@as(usize, 3), f.count("punk"));
    // All gone: the section is cleared, the next starts (its opening in 7 ticks).
    f.knockOut("punk");
    f.step();
    try testing.expectEqual(script.Stage.opening, f.w.script.stage);
    try testing.expectEqual(@as(u8, 1), f.w.script.part);
    try testing.expectEqual(@as(u8, 0), f.w.script.section);
    f.w.timer.seconds = 12;
    for (0..6) |_| f.step();
    try testing.expectEqual(@as(i32, 400), f.w.camera.x_max.whole());
    f.step();
    // It opens: the wall, the GO arrow, the timer.
    try testing.expectEqual(@as(u8, 1), f.w.script.section);
    try testing.expectEqual(@as(i32, 800), f.w.camera.x_max.whole());
    try testing.expectEqual(@as(usize, 1), f.count("go_arrow"));
    try testing.expectEqual(@as(u8, 50), f.w.timer.seconds);
}

test "the boss's section: the camera stops, the music fades, the boss's music, its wave" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var f = try Fixture.init();
    defer f.deinit();
    // Straight to the second section's reserve, empty: its clear starts the boss's.
    f.w.script = .{ .section = 1, .part = 1, .stage = .wave_end, .ticks = 1 };
    f.knockOut("punk");
    f.w.camera.x = .pixels(700);
    f.w.camera.x_max = .pixels(800);
    f.step();
    try testing.expectEqual(script.Stage.boss_opening, f.w.script.stage);
    f.step();
    try testing.expect(f.soundAsked("fade out"));
    try testing.expectEqual(@as(i32, 700), f.w.camera.x_max.whole());
    try testing.expectEqual(@as(i32, 700), f.w.camera.x_min.whole());
    for (0..2) |_| f.step();
    try testing.expect(!f.soundAsked("boss music"));
    f.step();
    try testing.expect(f.soundAsked("boss music"));
    for (0..3 + 2 - 1) |_| f.step();
    try testing.expectEqual(@as(usize, 0), f.count("boss"));
    f.step();
    try testing.expectEqual(@as(usize, 1), f.count("boss"));
    // The section waits for the boss's behaviour to end the round.
    for (0..20) |_| f.step();
    try testing.expectEqual(script.Stage.reserve, f.w.script.stage);
    script.won(&f.w);
    f.step();
    try testing.expectEqual(script.Stage.won, f.w.script.stage);
}

test "the GO arrow: placed on the screen, five blinks with their sound; it goes once the camera moved" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var f = try Fixture.init();
    defer f.deinit();
    f.w.script.stage = .won;
    _ = try f.w.spawn(&f.kinds, f.kinds.find("go_arrow").?, .zero, .right);
    f.step();
    const e = blk: {
        for (&f.w.entities) |*e| if (e.alive() and e.kind == f.kinds.find("go_arrow").?) break :blk e;
        unreachable;
    };
    try testing.expect(e.flags.on_screen and !e.flags.hidden);
    try testing.expectEqual(@as(i32, 240), e.position.x.whole());
    try testing.expect(!f.soundAsked("go arrow"));
    var blinks: usize = 0;
    var ticks: usize = 0;
    while (ticks < 200 and f.count("go_arrow") == 1) : (ticks += 1) {
        f.step();
        if (f.soundAsked("go arrow")) blinks += 1;
        // The camera moves during the blinks: the arrow goes after them.
        if (ticks == 10) f.w.camera.x = f.w.camera.x.add(.pixels(1));
    }
    try testing.expectEqual(@as(usize, 5), blinks);
    // It goes 91 ticks after it came, as the original's: its first blink a tick after.
    try testing.expectEqual(@as(usize, 1 + 5 * 18), ticks);
}

test "the timer: a second every pace's ticks, held in the special attack, up at zero" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var f = try Fixture.init();
    defer f.deinit();
    f.w.timer = .{ .seconds = 2, .ticks = 10 };
    for (0..9) |_| f.step();
    try testing.expectEqual(@as(u8, 2), f.w.timer.seconds);
    f.step();
    try testing.expectEqual(@as(u8, 1), f.w.timer.seconds);
    f.w.special = true;
    for (0..30) |_| {
        var t = f.tick();
        script.timer(&t);
    }
    try testing.expectEqual(@as(u8, 1), f.w.timer.seconds);
    f.w.special = false;
    for (0..9) |_| f.step();
    try testing.expect(!f.w.timer.up);
    f.step();
    try testing.expectEqual(@as(u8, 0), f.w.timer.seconds);
    try testing.expect(f.w.timer.up);
    f.step();
    try testing.expect(!f.w.timer.up);
}

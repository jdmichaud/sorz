//! The world's tests on synthetic content (DESIGN.md V1): a pawn the pad plays, sparring
//! partners, a prop; the definitions are read from their JSON as the content's are.
const std = @import("std");
const testing = std.testing;
const json = @import("../formats/json.zig");
const art = @import("../content/art.zig");
const content_entity = @import("../content/entity.zig");
const input = @import("../input.zig");
const fixed = @import("fixed.zig");
const random = @import("random.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const world_mod = @import("world.zig");
const output = @import("output.zig");
const systems = @import("systems.zig");
const tick_mod = @import("tick.zig");
const draw_list = @import("draw_list.zig");
const schedule = @import("schedule.zig");
const trace = @import("trace.zig");

const Fixed = fixed.Fixed;
const Vec3 = fixed.Vec3;
const World = world_mod.World;
const Kinds = kinds_mod.Kinds;
const Output = output.Output;
const Handle = entity.Handle;
const Input = tick_mod.Input;

const frame_names = [_][]const u8{ "stand", "walk_0", "walk_1", "punch_0", "punch_1", "reel", "down", "item", "shadow", "a", "b" };

/// The synthetic art: a 4 x 4 frame of each name in set `test`, palette 1 for `item`.
const test_art = blk: {
    const px: [16]u8 = @splat(1);
    var frames: [frame_names.len]art.Frame = undefined;
    for (&frames, frame_names) |*f, n| f.* = .{
        .name = n,
        .file = n ++ ".png",
        .width = 4,
        .height = 4,
        .origin_x = 2,
        .origin_y = 4,
        .pixels = &px,
        .palette = if (std.mem.eql(u8, n, "item")) 1 else 0,
    };
    const fs = frames;
    const sets = [_]art.ArtSet{.{ .name = "test", .frames = &fs }};
    break :blk art.Art{ .sets = &sets };
};

const boxes =
    \\ "boxes": {
    \\   "body": {"x": [-8, 8], "depth": [-4, 4], "height": [-60, 0]},
    \\   "fist": {"x": [8, 30], "depth": [-4, 4], "height": [-50, -40]}
    \\ },
;

const definitions = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "hero", .text = "{" ++
        \\ "family": "player", "team": "player", "behaviour": "pawn", "health": 80,
        \\ "gravity": 32768, "shadow": true,
        \\ "numbers": {"walk_x": 131072, "walk_depth": 65536, "jump": 262144, "hurt": 6},
    ++ boxes ++
        \\ "animations": {
        \\   "stand": {"loop": true, "frames": [{"frame": "test/stand", "ticks": 10, "body": "body"}]},
        \\   "walk": {"loop": true, "frames": [{"frame": "test/walk_0", "ticks": 4, "body": "body"},
        \\                                     {"frame": "test/walk_1", "ticks": 4, "body": "body"}]},
        \\   "attack": {"frames": [{"frame": "test/punch_0", "ticks": 2, "body": "body"},
        \\                         {"frame": "test/punch_1", "ticks": 3, "body": "body", "attack": "fist"},
        \\                         {"frame": "test/punch_0", "ticks": 2, "body": "body"}]},
        \\   "jump": {"frames": [{"frame": "test/walk_1", "ticks": 1, "body": "body"}]},
        \\   "hurt": {"frames": [{"frame": "test/reel", "ticks": 6}]}
        \\ },
        \\ "moves": {"attack": {"animation": "attack", "damage": 10, "push": {"x": 65536},
        \\                      "sound": "swing", "hit_sound": "smack"}}
        \\}
    },
    .{ .name = "dummy", .text = "{" ++
        \\ "family": "enemy", "team": "enemy", "behaviour": "sparring", "health": 24,
        \\ "gravity": 49152, "shadow": true,
        \\ "numbers": {"walk_speed": 65536, "reach": 24, "depth_reach": 2, "wait": 4, "reel": 5,
        \\             "knocked_out": 8},
        \\ "sounds": {"hurt": "ouch"},
    ++ boxes ++
        \\ "animations": {
        \\   "stand": {"loop": true, "frames": [{"frame": "test/stand", "ticks": 10, "body": "body"}]},
        \\   "walk": {"loop": true, "frames": [{"frame": "test/walk_0", "ticks": 4, "body": "body"},
        \\                                     {"frame": "test/walk_1", "ticks": 4, "body": "body"}]},
        \\   "punch": {"frames": [{"frame": "test/punch_0", "ticks": 3, "body": "body"},
        \\                        {"frame": "test/punch_1", "ticks": 3, "body": "body", "attack": "fist"},
        \\                        {"frame": "test/punch_0", "ticks": 3, "body": "body"}]},
        \\   "reel": {"frames": [{"frame": "test/reel", "ticks": 5}]},
        \\   "down": {"frames": [{"frame": "test/down", "ticks": 1}]}
        \\ },
        \\ "moves": {"punch": {"animation": "punch", "damage": 6, "hit_sound": "smack"}}
        \\}
    },
    .{ .name = "prop", .text =
    \\{"family": "scenery", "team": "neutral", "behaviour": "none", "gravity": 32768,
    \\ "boxes": {"body": {"x": [-4, 4], "depth": [-2, 2], "height": [-8, 0]}},
    \\ "animations": {
    \\   "lie": {"loop": true, "frames": [{"frame": "test/a", "ticks": 2, "body": "body"},
    \\                                    {"frame": "test/b", "ticks": 3}]},
    \\   "once": {"frames": [{"frame": "test/a", "ticks": 1}, {"frame": "test/b", "ticks": 2, "flip": true}]}
    \\ }}
    },
    .{ .name = "apple", .text =
    \\{"family": "item", "team": "neutral", "behaviour": "none", "palette": 2,
    \\ "boxes": {"body": {"x": [-4, 4], "depth": [-2, 2], "height": [-8, 0]}},
    \\ "animations": {"lie": {"loop": true, "frames": [{"frame": "test/item", "ticks": 1, "body": "body"}]}}}
    },
};

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    kinds: Kinds,

    fn init() !Fixture {
        var f: Fixture = .{ .arena = .init(testing.allocator), .kinds = undefined };
        errdefer f.arena.deinit();
        const arena = f.arena.allocator();
        var defs: [definitions.len]content_entity.Definition = undefined;
        var diag: json.Diagnostic = .{};
        for (&defs, definitions) |*d, src| {
            const root = try json.parse(arena, src.name, src.text, &diag);
            d.* = content_entity.read(arena, src.name, root, &test_art) catch |e| {
                std.debug.print("{f}\n", .{&diag});
                return e;
            };
        }
        f.kinds = try Kinds.bind(arena, try arena.dupe(content_entity.Definition, &defs), &test_art, &diag);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }

    fn kind(f: *const Fixture, name: []const u8) entity.KindId {
        return f.kinds.find(name).?;
    }
};

/// A world on the ground at height 0, with the pawn played by player 1.
fn withHero(f: *const Fixture, w: *World) !Handle {
    w.* = .{};
    const hero = try w.spawn(&f.kinds, f.kind("hero"), .pixels(100, 100, 0), .right);
    w.players[0].entity = hero;
    return hero;
}

fn step(w: *World, f: *const Fixture, rng: *random.Random, out: *Output, pads: input.Pads) void {
    systems.run(w, &f.kinds, rng, Input.steady(pads), out);
}

test "the systems run in their order" {
    var names: [systems.pipeline.len][]const u8 = undefined;
    for (&names, systems.pipeline) |*n, s| n.* = s.name;
    const want = [_][]const u8{ "commands", "control", "ai", "movement", "hits", "grabs", "pickups", "script", "camera", "animation", "sounds", "draw_list" };
    try testing.expectEqual(want.len, names.len);
    for (want, names) |a, b| try testing.expectEqualStrings(a, b);
}

test "handles: a removed entity's handle finds nothing, not the entity in its place since" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = .{};
    const a = try w.spawn(&f.kinds, f.kind("prop"), .pixels(10, 50, 0), .right);
    const b = try w.spawn(&f.kinds, f.kind("prop"), .pixels(20, 50, 0), .right);
    try testing.expect(w.get(a) != null and w.get(b) != null);
    w.remove(a);
    try testing.expect(w.get(a) == null);
    const c = try w.spawn(&f.kinds, f.kind("apple"), .pixels(30, 50, 0), .right);
    try testing.expectEqual(a.index, c.index);
    try testing.expect(w.get(a) == null);
    try testing.expectEqual(@as(i32, 30), w.get(c).?.position.x.whole());
    w.remove(a); // a stale handle removes nothing
    try testing.expect(w.get(c) != null);
    // A grab ends when either side goes.
    w.get(b).?.holding = c;
    w.get(c).?.holder = b;
    w.remove(c);
    try testing.expect(w.get(b).?.holding == null);
    // The pool is fixed: b and 127 more.
    var n: usize = 0;
    while (w.spawn(&f.kinds, f.kind("prop"), .zero, .right)) |_| n += 1 else |err| try testing.expectEqual(error.Full, err);
    try testing.expectEqual(@as(usize, entity.capacity - 1), n);
}

test "an entity from its definition: team, health, palette, first animation, behaviour" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = .{};
    const d = try w.spawn(&f.kinds, f.kind("dummy"), .pixels(1, 2, 3), .left);
    const e = w.get(d).?;
    try testing.expectEqual(entity.Team.enemy, e.team);
    try testing.expectEqual(@as(i16, 24), e.health);
    try testing.expectEqual(@as(?u8, 0), e.animation.index);
    try testing.expectEqual(@as(u8, 10), e.animation.left);
    try testing.expect(e.mind == .sparring);
    try testing.expect(e.boxes.mirrored);
    try testing.expectEqual(@as(u2, 2), w.get(try w.spawn(&f.kinds, f.kind("apple"), .zero, .right)).?.palette);
}

test "animation: each frame shows its ticks from the tick its animation starts; loop or hold" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = .{};
    var rng: random.Random = .{};
    var out: Output = .{};
    const p = try w.spawn(&f.kinds, f.kind("prop"), .pixels(50, 50, 0), .right);
    // "lie": a for 2 ticks, b for 3, looping.
    var seen: [12]u8 = undefined;
    for (&seen) |*s| {
        step(&w, &f, &rng, &out, .{});
        s.* = out.shown[p.index].?.frame.name[0];
    }
    try testing.expectEqualStrings("aabbbaabbbaa", &seen);
    try testing.expect(w.get(p).?.animation.done);
    // The boxes in use are the shown frame's: b has none.
    const e = w.get(p).?;
    f.kinds.startAnimation(e, 1); // "once": a for 1, b for 2 mirrored, then b stays.
    try testing.expect(!e.animation.done);
    var once: [5]u8 = undefined;
    var mirrored: [5]bool = undefined;
    for (&once, &mirrored) |*s, *m| {
        step(&w, &f, &rng, &out, .{});
        s.* = out.shown[p.index].?.frame.name[0];
        m.* = out.shown[p.index].?.mirrored;
    }
    try testing.expectEqualStrings("abbbb", &once);
    try testing.expectEqualSlices(bool, &.{ false, true, true, true, true }, &mirrored);
    try testing.expect(w.get(p).?.animation.done);
    try testing.expect(w.get(p).?.boxes.mirrored);
}

test "movement: speeds, gravity's arc, the landing, the ground's depths" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = .{};
    var rng: random.Random = .{};
    var out: Output = .{};
    const p = try w.spawn(&f.kinds, f.kind("prop"), .pixels(50, 50, 0), .right);
    const e = w.get(p).?;
    e.velocity = .{ .x = .of(0x18000), .height = .pixels(-4) };
    e.flags.airborne = true;
    var heights: [17]i32 = undefined;
    var landed_at: ?usize = null;
    for (&heights, 0..) |*h, i| {
        step(&w, &f, &rng, &out, .{});
        h.* = e.position.height.raw;
        if (e.flags.landed) landed_at = i + 1;
    }
    // Gravity 1/2: up 4, 3.5, 3... a peak of 18, and down again to the ground.
    try testing.expectEqual(Fixed.pixels(-4).raw, heights[0]);
    try testing.expectEqual(Fixed.parts(-8, 0x8000).raw, heights[1]);
    try testing.expectEqual(Fixed.pixels(-18).raw, heights[7]);
    try testing.expectEqual(Fixed.pixels(-18).raw, heights[8]);
    try testing.expectEqual(@as(?usize, 17), landed_at);
    try testing.expectEqual(@as(i32, 0), heights[16]);
    try testing.expect(!e.flags.airborne and e.velocity.height.raw == 0);
    // Across, 1.5 a tick all the way (nothing stops it).
    try testing.expectEqual(Fixed.pixels(50).add(Fixed.of(0x18000).times(17)), e.position.x);

    // The ground's depths keep the fraction.
    e.velocity = .zero;
    e.position.depth = .parts(-2, 0x8000);
    step(&w, &f, &rng, &out, .{});
    try testing.expectEqual(Fixed.of(0x8000), e.position.depth);
    e.position.depth = .parts(245, 0x4000);
    step(&w, &f, &rng, &out, .{});
    try testing.expectEqual(Fixed.parts(240, 0x4000), e.position.depth);
}

test "the commands: directions from the last read, buttons from either; a press counts once" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = undefined;
    _ = try withHero(&f, &w);
    var rng: random.Random = .{};
    var out: Output = .{};
    const b: input.Pad = .{ .b = true };
    // B pressed at the first display tick only, then released: still pressed for the tick.
    systems.run(&w, &f.kinds, &rng, .{ .pads = .{ .{ .pad1 = b }, .{} } }, &out);
    try testing.expect(w.players[0].command.pressed.b and w.players[0].command.held.b);
    // Right at the first display tick only: the last read decides the directions.
    systems.run(&w, &f.kinds, &rng, .{ .pads = .{ .{ .pad1 = .{ .right = true } }, .{} } }, &out);
    try testing.expect(!w.players[0].command.held.right and !w.players[0].command.pressed.b);
    // B held across ticks is pressed once.
    systems.run(&w, &f.kinds, &rng, Input.steady(.{ .pad1 = b }), &out);
    try testing.expect(w.players[0].command.pressed.b);
    systems.run(&w, &f.kinds, &rng, Input.steady(.{ .pad1 = b }), &out);
    try testing.expect(w.players[0].command.held.b and !w.players[0].command.pressed.b);
    // Pressed at the last read, after a release at the first.
    systems.run(&w, &f.kinds, &rng, .{ .pads = .{ .{}, .{ .pad1 = b } } }, &out);
    try testing.expect(w.players[0].command.pressed.b);
}

test "a blow lands: its frame's attack box meets a body, the damage, the reaction, the sounds" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = undefined;
    const hero = try withHero(&f, &w);
    const dummy = try w.spawn(&f.kinds, f.kind("dummy"), .pixels(120, 100, 0), .left);
    const other = try w.spawn(&f.kinds, f.kind("dummy"), .pixels(118, 100, 0), .left);
    var rng: random.Random = .{};
    var out: Output = .{};
    // The pawn strikes at tick 1: its attack frame shows at ticks 3 to 5, so its box is in use
    // from tick 4 (the frame shown at tick 3).
    step(&w, &f, &rng, &out, .{ .pad1 = .{ .b = true } });
    try testing.expectEqual(@as(usize, 1), out.sounds.len);
    try testing.expectEqualStrings("swing", out.sounds.items[0].name);
    var hit_at: ?usize = null;
    for (2..8) |i| {
        step(&w, &f, &rng, &out, .{});
        if (out.hits.len != 0 and hit_at == null) {
            hit_at = i;
            // Both partners in reach are struck, once each.
            try testing.expectEqual(@as(usize, 2), out.hits.len);
            try testing.expect(out.hits.items[0].attacker.?.eql(hero));
            try testing.expectEqual(@as(i16, 10), out.hits.items[0].damage);
            // "ouch" twice and "smack" twice are asked for once each.
            try testing.expectEqual(@as(usize, 2), out.sounds.len);
            try testing.expectEqualStrings("ouch", out.sounds.items[0].name);
            try testing.expectEqualStrings("smack", out.sounds.items[1].name);
        }
    }
    try testing.expectEqual(@as(?usize, 4), hit_at);
    const d = w.get(dummy).?;
    try testing.expectEqual(@as(i16, 14), d.health);
    try testing.expect(d.struck_by.?.eql(hero));
    try testing.expectEqualStrings("reel", @tagName(d.mind.sparring.state));
    try testing.expectEqual(@as(i16, 14), w.get(other).?.health);
    // The pawn's blow lands on enemies only once a blow: the second partner was not struck by
    // the first, nor the first by the second.
    try testing.expect(systems.blowsLand(.enemy, .player) and !systems.blowsLand(.enemy, .enemy));
}

test "the sparring partner draws its wait, closes in, punches, and the pawn reels" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = undefined;
    const hero = try withHero(&f, &w);
    const dummy = try w.spawn(&f.kinds, f.kind("dummy"), .pixels(160, 104, 0), .left);
    var rng: random.Random = .{};
    var out: Output = .{};
    step(&w, &f, &rng, &out, .{});
    // Its first wait: 4 and the low 4 bits of the first draw from power-on (7).
    try testing.expectEqual(@as(u32, 1), out.draws.count);
    try testing.expectEqualStrings("sparring_wait", out.draws.purposes[0]);
    try testing.expectEqual(@as(u16, 11), w.get(dummy).?.mind.sparring.wait);
    var struck_at: ?usize = null;
    for (2..60) |i| {
        step(&w, &f, &rng, &out, .{});
        if (out.hits.len != 0 and struck_at == null) {
            struck_at = i;
            try testing.expect(out.hits.items[0].target.eql(hero));
        }
    }
    try testing.expect(struck_at != null);
    try testing.expectEqual(@as(i16, 80 - 6), w.get(hero).?.health);
    // It stopped within reach, on the pawn's depth.
    const d = w.get(dummy).?;
    try testing.expect(@abs(d.position.x.whole() - 100) <= 24 and @abs(d.position.depth.whole() - 100) <= 2);
}

test "knocked out: the last health knocks it down, it lands, lies, and goes" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = undefined;
    _ = try withHero(&f, &w);
    const dummy = try w.spawn(&f.kinds, f.kind("dummy"), .pixels(120, 100, 0), .left);
    w.get(dummy).?.health = 5;
    var rng: random.Random = .{};
    var out: Output = .{};
    step(&w, &f, &rng, &out, .{ .pad1 = .{ .b = true } });
    var gone_at: ?usize = null;
    for (2..40) |i| {
        step(&w, &f, &rng, &out, .{});
        if (w.get(dummy) == null and gone_at == null) gone_at = i;
    }
    // Struck at 4 (knocked down, in the air), lands at 5, lies 8 ticks, gone at 13.
    try testing.expectEqual(@as(?usize, 13), gone_at);
}

test "grabs and pick-ups: asked for, answered, then the asks cleared" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = undefined;
    const hero = try withHero(&f, &w);
    const apple = try w.spawn(&f.kinds, f.kind("apple"), .pixels(104, 100, 0), .right);
    const far = try w.spawn(&f.kinds, f.kind("apple"), .pixels(300, 100, 0), .right);
    const dummy = try w.spawn(&f.kinds, f.kind("dummy"), .pixels(110, 100, 0), .left);
    var rng: random.Random = .{};
    var out: Output = .{};
    w.get(hero).?.flags.wants_pickup = true;
    w.get(hero).?.flags.wants_grab = true;
    step(&w, &f, &rng, &out, .{});
    try testing.expectEqual(@as(usize, 1), out.pickups.len);
    try testing.expect(out.pickups.items[0].item.eql(apple) and out.pickups.items[0].by.eql(hero));
    try testing.expect(w.get(apple) == null and w.get(far) != null);
    // The sparring partner does not let itself be grabbed (no `grabbable`): no grab.
    try testing.expect(w.get(hero).?.holding == null and w.get(dummy).?.holder == null);
    try testing.expect(!w.get(hero).?.flags.wants_grab and !w.get(hero).?.flags.wants_pickup);
}

test "the draw list: back to front by depth, the original's order among equals, shadows" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = .{};
    var rng: random.Random = .{};
    var out: Output = .{};
    const prop = f.kind("prop");
    // Three in one band: a and b at depth 10, c at 11, in that order: the original's sort puts
    // c, b, a front to back, where a stable one would give c, a, b.
    const a = try w.spawn(&f.kinds, prop, .pixels(10, 10, 0), .right);
    const b = try w.spawn(&f.kinds, prop, .pixels(20, 10, 0), .right);
    _ = try w.spawn(&f.kinds, prop, .pixels(30, 11, 0), .right);
    // Far behind, in another band.
    _ = try w.spawn(&f.kinds, prop, .pixels(40, 2, 0), .right);
    step(&w, &f, &rng, &out, .{});
    try testing.expectEqualSlices(i32, &.{ 40, 10, 20, 30 }, try xs(&out));
    // `behind` makes b give way to a, at the next drawing only.
    w.get(b).?.flags.behind = true;
    step(&w, &f, &rng, &out, .{});
    try testing.expectEqualSlices(i32, &.{ 40, 20, 10, 30 }, try xs(&out));
    try testing.expect(!w.get(b).?.flags.behind);
    step(&w, &f, &rng, &out, .{});
    try testing.expectEqualSlices(i32, &.{ 40, 10, 20, 30 }, try xs(&out));
    // Nearer is in front, whatever the order of the world.
    w.get(a).?.position.depth = .pixels(200);
    step(&w, &f, &rng, &out, .{});
    try testing.expectEqualSlices(i32, &.{ 40, 20, 30, 10 }, try xs(&out));

    // The place on the screen, the camera, the mirror, the palettes, the shadow behind its owner.
    w = .{};
    f.kinds.shadow = test_art.frame("test/shadow").?;
    w.camera.x = .pixels(100);
    w.camera.y = .pixels(10);
    w.ground = .pixels(4);
    const hero = try w.spawn(&f.kinds, f.kind("hero"), .{ .x = .pixels(150), .depth = .pixels(100), .height = .pixels(-20) }, .left);
    _ = try w.spawn(&f.kinds, f.kind("apple"), .pixels(160, 90, 0), .right);
    step(&w, &f, &rng, &out, .{});
    const s = out.sprites.slice();
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqualStrings("item", s[0].frame.name);
    try testing.expectEqual(@as(u2, 1 + 2), s[0].palette);
    try testing.expectEqualStrings("shadow", s[1].frame.name);
    try testing.expectEqual(@as(i32, 50), s[1].x);
    try testing.expectEqual(@as(i32, 50 + 4 - 10), s[1].y);
    try testing.expectEqualStrings("stand", s[2].frame.name);
    try testing.expectEqual(@as(i32, 50), s[2].x);
    try testing.expectEqual(@as(i32, 50 - 20 - 10), s[2].y);
    try testing.expect(s[2].flip_x and !s[0].flip_x);
    try testing.expect(w.get(hero) != null);
}

test "far off the screen an entity leaves the world, unless it stays" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = .{};
    var rng: random.Random = .{};
    var out: Output = .{};
    const near = try w.spawn(&f.kinds, f.kind("prop"), .pixels(1100, 50, 0), .right);
    const gone = try w.spawn(&f.kinds, f.kind("prop"), .pixels(1160, 50, 0), .right);
    const kept = try w.spawn(&f.kinds, f.kind("prop"), .pixels(-2000, 50, 0), .right);
    const above = try w.spawn(&f.kinds, f.kind("prop"), .pixels(10, 0, -120), .right);
    w.get(kept).?.flags.stays = true;
    step(&w, &f, &rng, &out, .{});
    try testing.expect(w.get(near) != null and w.get(gone) == null and w.get(kept) != null and w.get(above) == null);
    try testing.expectEqual(@as(usize, 2), out.sprites.len);
    try testing.expectEqual(draw_list.Place{ .x = 1100, .y = 25 }, draw_list.screenPlace(&w, w.get(near).?));
}

fn xs(out: *const Output) ![]const i32 {
    const S = struct {
        var buf: [32]i32 = undefined;
    };
    for (out.sprites.slice(), 0..) |s, i| S.buf[i] = s.x;
    return S.buf[0..out.sprites.len];
}

/// The pads of tick `i` of a scripted run: the pawn walks, strikes and jumps.
fn scripted(i: usize) input.Pads {
    return .{ .pad1 = .{
        .right = i % 40 < 15,
        .left = i % 40 >= 25 and i % 40 < 30,
        .down = i % 23 < 4,
        .up = i % 31 < 3,
        .b = i % 9 == 0,
        .c = i % 57 == 0,
    } };
}

const Replay = struct { hits: usize = 0, draws: usize = 0, sounds: usize = 0, removed: usize = 0 };

/// A run of `ticks` logic ticks: the pawn, three sparring partners and an apple; from tick
/// `change_at` on, the pad's right is turned over. Each tick's hash of the world and the
/// generator in `hashes`.
fn replay(f: *const Fixture, ticks: usize, change_at: ?usize, hashes: []u64) !Replay {
    var w: World = undefined;
    _ = try withHero(f, &w);
    var ids: [3]Handle = undefined;
    for (&ids, 0..) |*h, k| h.* = try w.spawn(&f.kinds, f.kind("dummy"), .pixels(@intCast(180 + 40 * k), @intCast(90 + 8 * k), 0), .left);
    _ = try w.spawn(&f.kinds, f.kind("apple"), .pixels(130, 104, 0), .right);
    var rng: random.Random = .{};
    var out: Output = .{};
    var r: Replay = .{};
    for (0..ticks) |i| {
        var pads = scripted(i);
        if (change_at) |c| if (i >= c) {
            pads.pad1.right = !pads.pad1.right;
        };
        step(&w, f, &rng, &out, pads);
        hashes[i] = w.hash() ^ @as(u64, rng.state) << 32;
        r.hits += out.hits.len;
        r.draws += out.draws.count;
        r.sounds += out.sounds.len;
    }
    for (ids) |h| r.removed += @intFromBool(w.get(h) == null);
    return r;
}

test "a world of synthetic entities replays identically, and another input parts it" {
    var f = try Fixture.init();
    defer f.deinit();
    const n = 600;
    var first: [n]u64 = undefined;
    var second: [n]u64 = undefined;
    var other: [n]u64 = undefined;
    const r = try replay(&f, n, null, &first);
    _ = try replay(&f, n, null, &second);
    try testing.expectEqualSlices(u64, &first, &second);
    _ = try replay(&f, n, 200, &other);
    try testing.expectEqualSlices(u64, first[0..200], other[0..200]);
    try testing.expect(first[n - 1] != other[n - 1]);
    // The run did something: blows landed, numbers were drawn, sounds asked for, and partners
    // were knocked out and went.
    try testing.expect(r.hits >= 5 and r.draws >= 3 and r.sounds >= 10 and r.removed >= 1);
}

test "the world's canonical form names a differing field" {
    var f = try Fixture.init();
    defer f.deinit();
    var a: World = undefined;
    _ = try withHero(&f, &a);
    var b = a;
    b.entities[0].position.depth = .pixels(7);
    const canonical = @import("../canonical.zig");
    const buf_a = try testing.allocator.alloc(u8, canonical.size(World));
    defer testing.allocator.free(buf_a);
    const buf_b = try testing.allocator.alloc(u8, canonical.size(World));
    defer testing.allocator.free(buf_b);
    const d = canonical.firstDifference(World, canonical.write(World, &a, buf_a), canonical.write(World, &b, buf_b)).?;
    try testing.expectEqualStrings("entities[0].position.depth", d.name());
    try testing.expect(a.hash() != b.hash());
}

test "play: the logic at every other display tick, with both display ticks' pads" {
    var f = try Fixture.init();
    defer f.deinit();
    var play: schedule.Play = .{};
    _ = try withHero(&f, &play.world);
    var rng: random.Random = .{};
    var out: Output = .{};
    // B only at a first display tick: the logic tick at the next display tick sees the press.
    try testing.expect(!play.displayTick(&f.kinds, &rng, .{ .pad1 = .{ .b = true } }, &out));
    try testing.expectEqual(@as(u32, 0), play.world.tick);
    try testing.expect(play.displayTick(&f.kinds, &rng, .{}, &out));
    try testing.expectEqual(@as(u32, 1), play.world.tick);
    try testing.expect(play.world.players[0].command.pressed.b);
    try testing.expectEqualStrings("swing", out.sounds.items[0].name);
    // The draw list stays for the display tick in between.
    try testing.expect(!play.displayTick(&f.kinds, &rng, .{}, &out));
    try testing.expectEqual(@as(usize, 1), out.sprites.len);
    try testing.expectEqualStrings("punch_0", out.sprites.items[0].frame.name);
    // A screen at 60 a second runs its logic at each display tick, with that tick's pads twice.
    var screen: schedule.Play = .{ .schedule = .{ .rate = .display } };
    _ = try withHero(&f, &screen.world);
    for (0..3) |_| try testing.expect(screen.displayTick(&f.kinds, &rng, .{}, &out));
    try testing.expectEqual(@as(u32, 3), screen.world.tick);
}

test "binding refuses a definition its behaviour cannot run, and names the field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const far_reach = try std.mem.replaceOwned(u8, a, definitions[1].text, "\"reach\": 24", "\"reach\": 100000");
    const no_sound = try std.mem.replaceOwned(u8, a, definitions[1].text, "\"hurt\": \"ouch\"", "\"cry\": \"ouch\"");
    const cases = [_]struct { text: []const u8, want: []const u8 }{
        .{ .text = "{\"family\": \"enemy\", \"team\": \"enemy\", \"behaviour\": \"robot\"}", .want = "entities/x.json: field behaviour: no behaviour of this name" },
        .{ .text = "{\"family\": \"player\", \"team\": \"player\", \"behaviour\": \"pawn\"}", .want = "entities/x.json: field animations.stand: missing: the behaviour pawn reads it" },
        .{ .text = far_reach, .want = "entities/x.json: field numbers.reach: out of range for the behaviour sparring" },
        .{ .text = no_sound, .want = "entities/x.json: field sounds.hurt: missing: the behaviour sparring reads it" },
    };
    for (cases) |c| {
        var diag: json.Diagnostic = .{};
        const root = try json.parse(a, "x", c.text, &diag);
        const d = try content_entity.read(a, "x", root, &test_art);
        try testing.expectError(error.BadAsset, Kinds.bind(a, &.{d}, &test_art, &diag));
        var buf: [128]u8 = undefined;
        try testing.expectEqualStrings(c.want, try std.fmt.bufPrint(&buf, "{f}", .{&diag}));
    }
}

test "the semantic trace: sor-remaster's vocabulary, line by line" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = undefined;
    _ = try withHero(&f, &w);
    _ = try w.spawn(&f.kinds, f.kind("dummy"), .pixels(120, 100, 0), .left);
    var rng: random.Random = .{};
    var out: Output = .{};
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    var tw: trace.Writer = .init(&text.writer);
    try tw.begin("power-on");
    tw.startScene(.{ .name = "round", .round = 1 });
    tw.setPhase("play");
    for (1..6) |i| {
        step(&w, &f, &rng, &out, if (i == 1) .{ .pad1 = .{ .b = true } } else .{});
        try tw.observe(2 * i, &w, &f.kinds, &out);
    }
    try tw.end();
    try testing.expectEqualStrings(
        \\{"ev":"begin","format":"sor-trace","version":1,"program":"sorz","fixed":16,"start":"power-on"}
        \\{"v":2,"t":0,"ev":"scene","scene":"round","round":1,"demo":false}
        \\{"v":2,"t":0,"ev":"phase","phase":"play"}
        \\{"v":2,"t":0,"ev":"pad","pad":1,"held":"B"}
        \\{"v":2,"t":0,"ev":"pad","pad":2,"held":""}
        \\{"v":2,"t":0,"ev":"rng","draws":1,"values":[32743],"_draws":["sparring_wait"]}
        \\{"v":2,"t":0,"ev":"spawn","e":1,"kind":"hero","player":1,"x":6553600,"d":6553600,"h":0,"vx":0,"vd":0,"vh":0,"state":"attack","facing":"right","health":80,"_slot":0}
        \\{"v":2,"t":0,"ev":"spawn","e":3,"kind":"dummy","x":7864320,"d":6553600,"h":0,"vx":0,"vd":0,"vh":0,"state":"stand","facing":"left","health":24,"_slot":1}
        \\{"v":2,"t":0,"ev":"lives","player":1,"lives":0,"specials":0}
        \\{"v":2,"t":0,"ev":"lives","player":2,"lives":0,"specials":0}
        \\{"v":2,"t":0,"ev":"score","player":1,"score":0}
        \\{"v":2,"t":0,"ev":"score","player":2,"score":0}
        \\{"v":2,"t":0,"ev":"camera","x":0,"y":0}
        \\{"v":2,"t":0,"ev":"camera_stop","x":2147483647,"y_min":0,"y_max":2147483647}
        \\{"v":2,"t":0,"ev":"section","section":0}
        \\{"v":2,"t":0,"ev":"sound","sound":"swing"}
        \\{"v":4,"t":1,"ev":"pad","pad":1,"held":""}
        \\{"v":8,"t":3,"ev":"state","e":3,"state":"reel","facing":"left"}
        \\{"v":8,"t":3,"ev":"hit","e":3,"by":1,"damage":10,"health":14,"reaction":"reel"}
        \\{"v":8,"t":3,"ev":"health","e":3,"health":14,"delta":-10}
        \\{"v":8,"t":3,"ev":"sound","sound":"ouch"}
        \\{"v":8,"t":3,"ev":"sound","sound":"smack"}
        \\{"v":10,"t":4,"ev":"end","events":22}
        \\
    , text.written());
}

test "the trace's ids: new entities by kind's name and place; removals; pick-ups by id" {
    var f = try Fixture.init();
    defer f.deinit();
    var w: World = .{};
    var rng: random.Random = .{};
    var out: Output = .{};
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    var tw: trace.Writer = .init(&text.writer);
    // Spawned in one tick: the apples (by their x) before the prop, whatever their places.
    _ = try w.spawn(&f.kinds, f.kind("prop"), .pixels(5, 50, 0), .right);
    _ = try w.spawn(&f.kinds, f.kind("apple"), .pixels(30, 50, 0), .right);
    const apple = try w.spawn(&f.kinds, f.kind("apple"), .pixels(20, 50, 0), .right);
    step(&w, &f, &rng, &out, .{});
    try tw.observe(2, &w, &f.kinds, &out);
    try testing.expect(std.mem.indexOf(u8, text.written(), "\"e\":3,\"kind\":\"apple\",\"x\":1310720,") != null);
    try testing.expect(std.mem.indexOf(u8, text.written(), "\"e\":4,\"kind\":\"apple\",\"x\":1966080,") != null);
    try testing.expect(std.mem.indexOf(u8, text.written(), "\"e\":5,\"kind\":\"prop\",") != null);
    text.clearRetainingCapacity();
    // The hero arrives and picks up the apple at x 20 (id 3); the apple goes.
    const hero = try w.spawn(&f.kinds, f.kind("hero"), .pixels(16, 50, 0), .right);
    w.players[0].entity = hero;
    w.get(hero).?.flags.wants_pickup = true;
    step(&w, &f, &rng, &out, .{});
    try tw.observe(4, &w, &f.kinds, &out);
    try testing.expect(w.get(apple) == null);
    const lines = text.written();
    try testing.expect(std.mem.indexOf(u8, lines, "{\"v\":4,\"t\":1,\"ev\":\"remove\",\"e\":3,\"kind\":\"apple\"}\n") != null);
    try testing.expect(std.mem.indexOf(u8, lines, "\"ev\":\"spawn\",\"e\":1,\"kind\":\"hero\",\"player\":1,") != null);
    try testing.expect(std.mem.indexOf(u8, lines, "{\"v\":4,\"t\":1,\"ev\":\"pickup\",\"e\":3,\"kind\":\"apple\",\"by\":1}\n") != null);
    // The order of the kinds of event: remove, spawn, pickup.
    try testing.expect(std.mem.indexOf(u8, lines, "remove").? < std.mem.indexOf(u8, lines, "spawn").?);
    try testing.expect(std.mem.indexOf(u8, lines, "spawn").? < std.mem.indexOf(u8, lines, "pickup").?);
}

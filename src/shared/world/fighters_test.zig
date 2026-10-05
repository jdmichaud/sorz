//! The fighters' tests on synthetic content (DESIGN.md V1): a player (`player` behaviour), a punk
//! (`galsia`), the special attack's car (`police_car`) and a player out of lives
//! (`player_waiting`), whose definitions here take the
//! extractor's numbers for Axel and round 1's Galsias, so that the timings checked are the ones
//! sor-remaster measures (the catalogue's), on frames and boxes of the tests' own.
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
const behaviours = @import("behaviours.zig");
const script = @import("script.zig");
const content_round = @import("../content/round.zig");

const Fixed = fixed.Fixed;
const World = world_mod.World;
const Kinds = kinds_mod.Kinds;
const Output = output.Output;
const Handle = entity.Handle;

const frame_names = [_][]const u8{ "f0", "f1", "f2", "f3", "f4", "f5", "f6" };

const test_art = blk: {
    const px: [16]u8 = @splat(1);
    var frames: [frame_names.len]art.Frame = undefined;
    for (&frames, frame_names) |*f, n| f.* = .{ .name = n, .file = n ++ ".png", .width = 4, .height = 4, .origin_x = 2, .origin_y = 4, .pixels = &px };
    const fs = frames;
    const sets = [_]art.ArtSet{.{ .name = "t", .frames = &fs }};
    break :blk art.Art{ .sets = &sets };
};

/// A frame of `ticks` ticks with the body box, and more fields.
fn fr(comptime ticks: []const u8, comptime more: []const u8) []const u8 {
    return "{\"frame\": \"t/f0\", \"ticks\": " ++ ticks ++ ", \"body\": \"body\"" ++ more ++ "}";
}

/// A frame without a body (the hurt, the falls).
fn bare(comptime ticks: []const u8, comptime more: []const u8) []const u8 {
    return "{\"frame\": \"t/f1\", \"ticks\": " ++ ticks ++ more ++ "}";
}

fn anim(comptime name: []const u8, comptime frames: []const u8) []const u8 {
    return "\"" ++ name ++ "\": {\"loop\": true, \"frames\": [" ++ frames ++ "]}";
}

const place = ", \"place\": {\"x\": -3, \"height\": -44}";

const hero =
    \\{"family": "player", "team": "player", "behaviour": "player", "health": 80, "gravity": 59392,
    \\ "shadow": true,
    \\ "numbers": {"back_attack_ends": 3, "blink": 48, "blow_ends": 3, "combo_window": 10,
    \\   "diagonal_depth": 131072, "diagonal_x": 147456, "down": 10, "drop": 98304,
    \\   "fall_most": 786432, "getting_up_ends": 4, "grab_blow_ends": 2, "hit_pause": 4,
    \\   "hurry_first": 1, "hurry_later": 2, "hurt": 10, "idle_ends": 2, "jump": -491520,
    \\   "jump_x": 196608, "kick_falling_gravity": 34816, "knee_last_ends": 2,
    \\   "knocked_down_up": -327680, "knocked_down_x": -147456, "last_blow_ends": 4, "let_go": 3,
    \\   "pick_depth": 16, "pick_height": 8, "pick_x": 20, "recover_ends": 2, "steer": 24576,
    \\   "steer_most": 229376, "throw_ends": 6, "vault_ends": 4, "walk_depth": 155648,
    \\   "walk_x": 196608, "dying_x": -262144, "dying_up": -589824, "dead": 38},
    \\ "sounds": {"jump": "jump", "land": "landing", "hurt": "player hit", "thud": "heavy fall",
    \\   "death": "axel death cry"},
    \\ "boxes": {"body": {"x": [0, 13], "depth": [-8, 8], "height": [-51, 0]},
    \\   "reach": {"x": [0, 16], "depth": [-8, 8], "height": [-57, 0]},
    \\   "fist": {"x": [16, 57], "depth": [-8, 8], "height": [-64, -32]}},
    \\ "animations": {
++ anim("ready", fr("100", "")) ++ "," ++
    anim("idle", fr("12", "") ++ "," ++ fr("8", "") ++ "," ++ fr("1", "")) ++ "," ++
    anim("walk", fr("6", ", \"attack\": \"reach\"") ++ "," ++ fr("6", ", \"attack\": \"reach\"") ++ "," ++ fr("6", ", \"attack\": \"reach\"") ++ "," ++ fr("6", ", \"attack\": \"reach\"")) ++ "," ++
    anim("jump_crouch", fr("5", "")) ++ "," ++
    anim("jump", fr("6", "")) ++ "," ++
    anim("jump_kick", fr("100", ", \"attack\": \"fist\", \"blow\": true")) ++ "," ++
    anim("attack1", fr("1", "") ++ "," ++ fr("5", ", \"attack\": \"fist\", \"blow\": true, \"sound\": \"swing\"") ++ "," ++ fr("1", "") ++ "," ++ fr("2", "")) ++ "," ++
    anim("attack1_hurried", fr("1", "") ++ "," ++ fr("2", ", \"attack\": \"fist\", \"blow\": true, \"sound\": \"swing\"") ++ "," ++ fr("1", "") ++ "," ++ fr("1", "")) ++ "," ++
    anim("attack3", fr("1", "") ++ "," ++ fr("5", ", \"attack\": \"fist\", \"blow\": true") ++ "," ++ fr("1", "") ++ "," ++ fr("2", "")) ++ "," ++
    anim("attack4", fr("1", "") ++ "," ++ fr("1", "") ++ "," ++ fr("7", ", \"attack\": \"fist\", \"blow\": true") ++ "," ++ fr("1", "") ++ "," ++ fr("2", "")) ++ "," ++
    anim("back_attack", fr("1", "") ++ "," ++ fr("5", ", \"attack\": \"fist\", \"blow\": true") ++ "," ++ fr("2", "") ++ "," ++ fr("1", "")) ++ "," ++
    anim("pick_up", fr("7", "")) ++ "," ++
    anim("hurt", bare("1", "") ++ "," ++ bare("1", "")) ++ "," ++
    anim("knocked_down", bare("100", "")) ++ "," ++
    anim("down", bare("6", "")) ++ "," ++
    anim("getting_up", bare("6", "") ++ "," ++ bare("6", "") ++ "," ++ bare("6", "") ++ "," ++ bare("6", "") ++ "," ++ bare("6", "")) ++ "," ++
    anim("lying_dead", bare("8", "") ++ "," ++ bare("8", "")) ++ "," ++
    anim("recover", bare("6", "") ++ "," ++ bare("6", "") ++ "," ++ bare("4", "")) ++ "," ++
    anim("grab", fr("100", ", \"held\": {\"x\": 32}")) ++ "," ++
    anim("grab_behind", fr("100", ", \"held\": {\"x\": 28}")) ++ "," ++
    anim("knee", fr("8", ", \"blow\": true, \"held\": {\"x\": 32}")) ++ "," ++
    anim("knee_last", fr("6", "") ++ "," ++ fr("8", ", \"blow\": true") ++ "," ++ fr("2", ", \"blow\": true")) ++ "," ++
    anim("grab_blow", fr("5", ", \"blow\": true, \"held\": {\"x\": -16, \"pose\": 0}") ++ "," ++ fr("15", ", \"blow\": true, \"held\": {\"x\": 40, \"height\": -32, \"lets_go\": true}") ++ "," ++ fr("4", ", \"blow\": true")) ++ "," ++
    anim("vault", fr("6", ", \"blow\": true, \"held\": {\"x\": 5, \"pose\": 0}") ++ "," ++ fr("4", ", \"blow\": true, \"held\": {\"x\": -8, \"height\": -16, \"pose\": 1}") ++ "," ++ fr("4", ", \"blow\": true, \"held\": {\"x\": -40, \"height\": -32, \"pose\": 5}") ++ "," ++ fr("18", ", \"blow\": true, \"held\": {\"x\": -48, \"lets_go\": true}") ++ "," ++ fr("8", ", \"blow\": true")) ++ "," ++
    anim("vault_land", fr("2", ", \"blow\": true") ++ "," ++ fr("2", ", \"blow\": true") ++ "," ++ fr("2", ", \"blow\": true")) ++ "," ++
    anim("throw", fr("3", ", \"place\": {\"x\": -28, \"height\": -8}") ++ "," ++ fr("3", place) ++ "," ++ fr("3", place) ++ "," ++ fr("3", place) ++ "," ++ fr("3", place) ++ "," ++ fr("3", ", \"place\": {\"x\": 28}") ++ "," ++ fr("6", ", \"place\": {\"x\": 48}")) ++ "," ++
    anim("throw_back", fr("3", ", \"place\": {\"x\": -28, \"height\": -8}") ++ "," ++ fr("3", place) ++ "," ++ fr("3", place) ++ "," ++ fr("3", place) ++ "," ++ fr("3", place) ++ "," ++ fr("3", ", \"place\": {\"x\": 32}") ++ "," ++ fr("6", ", \"place\": {\"x\": 48}")) ++
    \\ },
    \\ "moves": {"attack1": {"animation": "attack1", "damage": 1},
    \\   "attack2": {"animation": "attack1", "damage": 1},
    \\   "attack3": {"animation": "attack3", "damage": 1},
    \\   "attack4": {"animation": "attack4", "damage": 2, "reaction": "knock_down"},
    \\   "back_attack": {"animation": "back_attack", "damage": 3, "reaction": "knock_down"},
    \\   "jump_kick": {"animation": "jump_kick", "damage": 3, "reaction": "knock_down", "sound": "shout"},
    \\   "knee": {"animation": "knee", "damage": 2},
    \\   "knee_last": {"animation": "knee_last", "damage": 3, "reaction": "knock_down"},
    \\   "grab_blow": {"animation": "grab_blow", "damage": 4, "reaction": "thrown", "sound": "shout"},
    \\   "throw": {"animation": "throw"},
    \\   "vault": {"animation": "vault", "damage": 5, "reaction": "slammed", "sound": "shout"},
    \\   "throw_back": {"animation": "throw_back"}}
    \\}
;

/// A punk's frame of `ticks` ticks with its body, and more fields.
fn pf(comptime ticks: []const u8, comptime more: []const u8) []const u8 {
    return "{\"frame\": \"t/f2\", \"ticks\": " ++ ticks ++ ", \"body\": \"body\"" ++ more ++ "}";
}

fn pb(comptime ticks: []const u8) []const u8 {
    return "{\"frame\": \"t/f3\", \"ticks\": " ++ ticks ++ "}";
}

const punk =
    \\{"family": "enemy", "team": "enemy", "behaviour": "galsia", "health": 4, "gravity": 73728,
    \\ "shadow": true,
    \\ "numbers": {"appears_from": -16, "appears_to": 335, "blink": 3, "blinks": 8, "points": 500,
    \\   "bounce_most": 393216, "bounce_slowing": 16384, "close_in_beside": 32, "close_in_pace": 3,
    \\   "close_in_speed": 196608, "close_in_ticks": 48, "fall_most": 1048576, "first_blink": 16,
    \\   "flipped_up": -327680, "flipped_x": 196608, "gets_up_frame": 4, "grab_height": 8,
    \\   "knocked_out_x": 655360, "knocked_slowing": 21504, "knocked_up": -589824,
    \\   "knocked_x": 458752, "last_punch_frame": 7, "last_punch_test": 6, "lying": 16,
    \\   "lying_least": 3, "pacing_0": 16, "pacing_1": 8, "pacing_2": 10, "pacing_3": 5,
    \\   "pacing_pace_0": 6, "pacing_pace_1": 5, "pacing_pace_2": 4, "pacing_pace_3": 4,
    \\   "pacing_speed_0": 163840, "pacing_speed_1": 196608, "pacing_speed_2": 262144,
    \\   "pacing_speed_3": 327680, "punch_ends": 9, "reach_frame": 0, "reel": 24, "reel_nudge": 2,
    \\   "slam_ticks": 8, "slammed_up": -393216, "slammed_x": 294912, "special_down_frame": 3,
    \\   "special_shake_pace": 3, "special_shake_turn": 8, "special_spin_frame": 2,
    \\   "special_spin_turn": 10, "struck_held": 10, "thrown_slide": 7, "thrown_up": -393216,
    \\   "thrown_x": 360448, "walk_off_again": 7, "walk_off_depth": 196608, "walk_off_down_to": 88,
    \\   "walk_off_faster": 655360, "walk_off_faster_after": 5, "walk_off_fastest": 851968,
    \\   "walk_off_fastest_after": 16, "walk_off_near": 80, "walk_off_pace": 4,
    \\   "walk_off_up_from": 56, "walk_off_up_to": 24},
    \\ "sounds": {"hurt": "enemy hit", "thud": "heavy fall", "cry": "enemy cry", "cry_odd": "enemy cry high"},
    \\ "boxes": {"body": {"x": [-9, 9], "depth": [-8, 8], "height": [-60, 0]},
    \\   "jab": {"x": [0, 40], "depth": [-8, 8], "height": [-50, -44]},
    \\   "punch": {"x": [16, 51], "depth": [-8, 8], "height": [-48, -42]}},
    \\ "animations": {
++ anim("walk", pf("5", "") ++ "," ++ pf("5", "") ++ "," ++ pf("5", "") ++ "," ++ pf("5", "")) ++ "," ++
    anim("down", pf("5", "") ++ "," ++ pb("5") ++ "," ++ pb("5") ++ "," ++ pb("5") ++ "," ++ pf("5", "") ++ "," ++ pb("5")) ++ "," ++
    anim("reel", pf("1", "") ++ "," ++ pf("1", "") ++ "," ++ pf("1", "") ++ "," ++ pf("1", "")) ++ "," ++
    anim("stand", pf("6", "") ++ "," ++ pf("6", "") ++ "," ++ pf("6", "")) ++ "," ++
    anim("thrown", pf("6", "") ++ "," ++ pb("6") ++ "," ++ pf("6", "")) ++ "," ++
    anim("slammed", pf("5", "") ++ "," ++ pb("5") ++ "," ++ pb("5") ++ "," ++ pb("5") ++ "," ++ pf("5", "") ++ "," ++ pb("5")) ++ "," ++
    anim("punch", pf("4", ", \"attack\": \"jab\", \"blow\": true") ++ "," ++ pf("4", "") ++ "," ++ pf("4", "") ++ "," ++ pf("4", ", \"attack\": \"jab\", \"blow\": true") ++ "," ++ pf("4", "") ++ "," ++ pf("4", "") ++ "," ++ pf("4", "") ++ "," ++ pf("4", ", \"attack\": \"punch\", \"blow\": true") ++ "," ++ pf("4", ", \"attack\": \"punch\", \"blow\": true") ++ "," ++ pf("4", ", \"attack\": \"punch\", \"blow\": true")) ++
    \\ },
    \\ "moves": {"punch": {"animation": "punch", "damage": 4},
    \\   "punch_last": {"animation": "punch", "damage": 4, "reaction": "knock_down"}}
    \\}
;

const car =
    \\{"family": "effect", "team": "neutral", "behaviour": "police_car",
    \\ "numbers": {"run": 1048576, "run_most": 50331648, "comes": 33554432, "siren": 29,
    \\   "brakes": 44, "bazooka": 82, "shell": 148, "explosion": 201, "blast": 245, "run_ahead": 100,
    \\   "ends": 286},
    \\ "sounds": {"siren": "police siren", "brakes": "police car brakes", "bazooka": "police bazooka",
    \\   "shell": "bazooka shell", "explosion": "explosion"},
    \\ "animations": {"car": {"loop": true, "frames": [{"frame": "t/f4", "ticks": 1}]}}}
;

const waiting =
    \\{"family": "player", "team": "neutral", "behaviour": "player_waiting",
    \\ "numbers": {"cursor_blink": 8, "out_wait": 250},
    \\ "sounds": {"cursor": "menu move", "game_over": "game over music"}}
;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    kinds: Kinds,

    fn init() !Fixture {
        var f: Fixture = .{ .arena = .init(testing.allocator), .kinds = undefined };
        errdefer f.arena.deinit();
        const arena = f.arena.allocator();
        const sources = [_]struct { name: []const u8, text: []const u8 }{
            .{ .name = "hero", .text = hero },
            .{ .name = "punk", .text = punk },
            .{ .name = "police_car", .text = car },
            .{ .name = "player_waiting", .text = waiting },
        };
        var defs: [sources.len]content_entity.Definition = undefined;
        var diag: json.Diagnostic = .{};
        for (&defs, sources) |*d, src| {
            const root = try json.parse(arena, src.name, src.text, &diag);
            d.* = content_entity.read(arena, src.name, root, &test_art) catch |e| {
                std.debug.print("{f}\n", .{&diag});
                return e;
            };
        }
        f.kinds = Kinds.bind(arena, try arena.dupe(content_entity.Definition, &defs), &test_art, &diag) catch |e| {
            std.debug.print("{f}\n", .{&diag});
            return e;
        };
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }
};

/// Round 1's place: the ground at 160, the camera at 768 following the player, who stands at
/// x 800 (its life started: no blinking).
const Round = struct {
    f: Fixture,
    w: World = .{},
    rng: random.Random = .{},
    out: Output = .{},
    hero: Handle = undefined,

    fn init() !Round {
        var r: Round = .{ .f = try Fixture.init() };
        r.w.ground = .pixels(160);
        r.w.camera = .{ .x = .pixels(768), .x_min = .pixels(768), .x_max = .pixels(1216), .y_max = .zero, .follows = true };
        r.hero = try r.w.spawn(&r.f.kinds, r.f.kinds.find("hero").?, .pixels(800, 64, 160), .right);
        r.w.players[0] = .{ .entity = r.hero, .character = r.f.kinds.find("hero").?, .lives = 3, .specials = 1, .continues = 3 };
        const e = r.w.get(r.hero).?;
        e.mind.player.state = .ready;
        e.mind.player.started = true;
        r.f.kinds.startAnimation(e, r.f.kinds.get(e.kind.?).definition.animation("ready").?);
        return r;
    }

    fn deinit(r: *Round) void {
        r.f.deinit();
    }

    fn step(r: *Round, pads: input.Pads) void {
        systems.run(&r.w, &r.f.kinds, &r.rng, tick_mod.Input.steady(pads), &r.out);
    }

    /// A tick of the round's world following `plan` (its script, its timer, its lives); the
    /// buttons pressed at its last read (as the waiting player reads them).
    fn stepPlan(r: *Round, pads: input.Pads, plan: *const script.Plan) void {
        systems.runRound(&r.w, &r.f.kinds, &r.rng, .{ .pads = .{ .{}, pads } }, &r.out, plan);
    }

    fn player(r: *Round) *entity.Entity {
        return r.w.get(r.hero).?;
    }

    fn state(r: *Round) []const u8 {
        return behaviours.stateName(&r.player().mind).?;
    }

    fn punk(r: *Round, x: i32) !Handle {
        const h = try r.w.spawn(&r.f.kinds, r.f.kinds.find("punk").?, .pixels(x, 64, 160), .left);
        const e = r.w.get(h).?;
        e.mind.galsia.state = .close_in;
        e.mind.galsia.target = r.hero;
        return h;
    }
};

const b_pad: input.Pads = .{ .pad1 = .{ .b = true } };
const c_pad: input.Pads = .{ .pad1 = .{ .c = true } };

test "the jab: pressed at tick 0, its blow at ticks 1 to 5, back in control at tick 7" {
    var r = try Round.init();
    defer r.deinit();
    var power: [8]i16 = undefined;
    var states: [8][]const u8 = undefined;
    for (&power, &states, 0..) |*p, *s, i| {
        r.step(if (i == 0) b_pad else .{});
        var t: tick_mod.Tick = .{ .world = &r.w, .kinds = &r.f.kinds, .random = &r.rng, .out = &r.out };
        p.* = t.power(r.player());
        s.* = r.state();
    }
    try testing.expectEqualSlices(i16, &.{ 0, 1, 1, 1, 1, 1, 0, 0 }, &power);
    try testing.expectEqualStrings("attack1", states[6]);
    try testing.expectEqualStrings("ready", states[7]);
}

test "the jump: a crouch of 5 ticks, the arc with gravity before the move, the landing" {
    var r = try Round.init();
    defer r.deinit();
    var heights: [30]i32 = undefined;
    var land_at: ?usize = null;
    var ready_at: ?usize = null;
    for (&heights, 0..) |*h, i| {
        r.step(if (i == 0) c_pad else .{});
        h.* = r.player().position.height.raw;
        if (land_at == null and std.mem.eql(u8, r.state(), "land")) land_at = i;
        if (land_at != null and ready_at == null and std.mem.eql(u8, r.state(), "ready")) ready_at = i;
    }
    // Up 7.5 at tick 5, 14.0938 at tick 6 (the catalogue's Axel), 34.875 at its peak.
    const ground = Fixed.pixels(160).raw;
    try testing.expectEqual(ground, heights[4]);
    try testing.expectEqual(ground - 491520, heights[5]);
    try testing.expectEqual(ground - 923648, heights[6]);
    var peak: i32 = 0;
    for (heights) |h| peak = @max(peak, ground - h);
    try testing.expectEqual(@as(i32, 2285568), peak);
    try testing.expectEqual(@as(?usize, 22), land_at);
    try testing.expectEqual(@as(?usize, 27), ready_at);
}

test "a punk's string of blows: hurt, hurt, knocked down; down, getting up, blinking" {
    var r = try Round.init();
    defer r.deinit();
    _ = try r.punk(840);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    var last: []const u8 = "";
    var no_body_after_getting_up: usize = 0;
    var recovered = false;
    for (0..150) |_| {
        r.step(.{});
        const s = r.state();
        if (!std.mem.eql(u8, s, last)) {
            try seen.appendSlice(testing.allocator, s);
            try seen.append(testing.allocator, ' ');
            last = s;
        }
        if (std.mem.eql(u8, s, "recover")) recovered = true;
        if (recovered and r.player().boxes.body == null) no_body_after_getting_up += 1;
    }
    try testing.expect(std.mem.startsWith(u8, seen.items, "ready hurt ready hurt ready knocked_down down getting_up recover ready"));
    try testing.expectEqual(@as(i16, 80 - 12), r.player().health);
    // Blinking from the end of the getting up: 48 ticks without a body.
    try testing.expectEqual(@as(usize, 48), no_body_after_getting_up);
}

test "the combo on a punk: the chain's blows land, the fourth knocks it down" {
    var r = try Round.init();
    defer r.deinit();
    const p = try r.punk(850);
    // B every other tick.
    var knocked_at: ?usize = null;
    var chain: std.ArrayList(u8) = .empty;
    defer chain.deinit(testing.allocator);
    var last: []const u8 = "";
    for (0..60) |i| {
        r.step(if (i % 2 == 0) b_pad else .{});
        const s = r.state();
        if (!std.mem.eql(u8, s, last) and std.mem.startsWith(u8, s, "attack")) {
            try chain.appendSlice(testing.allocator, s);
            try chain.append(testing.allocator, ' ');
        }
        last = s;
        if (knocked_at == null) if (r.w.get(p)) |e| if (e.mind.galsia.state == .knocked_down) {
            knocked_at = i;
        };
    }
    try testing.expect(std.mem.indexOf(u8, chain.items, "attack2 attack3 attack4") != null);
    try testing.expect(knocked_at != null);
}

test "a grab: the walk's reach catches the punk; two knees, and the last knocks it down" {
    var r = try Round.init();
    defer r.deinit();
    const p = try r.punk(880);
    r.w.get(p).?.mind.galsia.state = .stand;
    r.w.get(p).?.mind.galsia.fresh = true;
    var grab_at: ?usize = null;
    for (0..40) |i| {
        r.step(.{ .pad1 = .{ .right = true } });
        if (std.mem.eql(u8, r.state(), "grab")) {
            grab_at = i;
            break;
        }
    }
    try testing.expect(grab_at != null);
    try testing.expect(r.player().holding.?.eql(p));
    // Held 32 pixels ahead.
    r.step(.{});
    try testing.expectEqual(r.player().position.x.whole() + 32, r.w.get(p).?.position.x.whole());
    var health: [3]i16 = undefined;
    for (&health) |*h| {
        r.step(b_pad);
        for (0..10) |_| r.step(.{});
        h.* = r.w.get(p).?.health;
    }
    try testing.expectEqualSlices(i16, &.{ 2, 0, -3 }, &health);
    try testing.expect(r.w.get(p).?.mind.galsia.state == .knocked_down);
    try testing.expect(r.player().holding == null);
}

test "the special attack: the camera runs back, the car comes, the punk stands without health, the blast, the end" {
    var r = try Round.init();
    defer r.deinit();
    const p = try r.punk(900);
    r.step(.{});
    r.step(.{ .pad1 = .{ .a = true } });
    try testing.expect(r.w.special);
    try testing.expectEqual(@as(u8, 0), r.w.players[0].specials);
    try testing.expectEqual(@as(i16, -1), r.w.get(p).?.health);
    try testing.expect(r.w.get(p).?.mind.galsia.state == .stand);
    // At the call's tick the camera still follows the player, on the left of its band.
    try testing.expectEqual(@as(i32, 765), r.w.camera.x.whole());
    const x = r.player().position.x;
    var knocked_at: ?usize = null;
    var ended_at: ?usize = null;
    var back_at: ?usize = null;
    var ahead_at: ?usize = null;
    var returned_at: ?usize = null;
    for (1..330) |i| {
        const was = r.w.camera.x.whole();
        r.step(.{ .pad1 = .{ .right = true } });
        const now = r.w.camera.x.whole();
        if (back_at == null and now == 0) back_at = i;
        if (ahead_at == null and now > was) ahead_at = i;
        if (returned_at == null and ahead_at != null and r.w.camera.run == null) returned_at = i;
        if (knocked_at == null) if (r.w.get(p)) |e| if (e.mind.galsia.state == .knocked_down) {
            knocked_at = i;
        };
        if (ended_at == null and !r.w.special) ended_at = i;
        if (ended_at == null) try testing.expect(r.player().position.x.eql(x));
    }
    // 765 to 0 at 16 a tick; the car comes when the camera is 512 back from 768 (tick 32).
    try testing.expectEqual(@as(?usize, 48), back_at);
    try testing.expectEqual(@as(?usize, 32 + 100 + 1), ahead_at);
    try testing.expectEqual(@as(?usize, 32 + 100 + 48), returned_at);
    try testing.expectEqual(@as(i32, 768), r.w.camera.x.whole());
    try testing.expectEqual(@as(?usize, 32 + 245), knocked_at);
    try testing.expectEqual(@as(?usize, 32 + 286), ended_at);
    // A second call needs a special left.
    r.step(.{ .pad1 = .{ .a = true } });
    try testing.expect(!r.w.special);
    // Knocked out, the punk blinks and goes, and the player it went after scores its points.
    try testing.expectEqual(@as(u32, 0), r.w.players[0].score);
    for (0..200) |_| {
        if (r.w.get(p) == null) break;
        r.step(.{});
    }
    try testing.expect(r.w.get(p) == null);
    try testing.expectEqual(@as(u32, 500), r.w.players[0].score);
}

/// A round with a single section and no enemies, for the lives' tests.
const lives_round: content_round.Round = blk: {
    var r = content_round.example;
    r.sections = &.{.{ .wall = 1216, .timer = 40, .opens_after = 61 }};
    r.boss = .{ .fade = "fade out", .music = "boss music", .music_after = 86, .wave_after = 59 };
    break :blk r;
};

/// The states the player's entity goes through in `ticks` ticks, each named once in a row.
fn statesOf(r: *Round, plan: *const script.Plan, ticks: usize, pads: input.Pads) ![]const u8 {
    var seen: std.ArrayList(u8) = .empty;
    var last: []const u8 = "";
    for (0..ticks) |_| {
        r.stepPlan(pads, plan);
        const s = r.state();
        if (std.mem.eql(u8, s, last)) continue;
        if (seen.items.len != 0) try seen.append(r.f.arena.allocator(), ' ');
        try seen.appendSlice(r.f.arena.allocator(), s);
        last = s;
    }
    return seen.items;
}

test "a death: no health left (the time over's), it dies at the next tick; one bounce, lying dead, the next life" {
    var r = try Round.init();
    defer r.deinit();
    const plan: script.Plan = .{ .round = &lives_round, .lives = 3 };
    script.start(&r.w, &plan);
    r.player().health = 0;
    r.stepPlan(.{}, &plan);
    try testing.expectEqualStrings("dying", r.state());
    try testing.expectEqual(@as(u8, 2), r.w.players[0].lives);
    var lying: usize = 0;
    var bounces: usize = 0;
    for (0..200) |_| {
        const was = r.player().velocity.height.raw;
        r.stepPlan(.{}, &plan);
        if (std.mem.eql(u8, r.state(), "lying_dead")) lying += 1;
        if (std.mem.eql(u8, r.state(), "dying") and was > 0 and r.player().velocity.height.raw < 0) bounces += 1;
        if (std.mem.eql(u8, r.state(), "fall")) break;
    }
    try testing.expectEqual(@as(usize, 1), bounces);
    // Its 38 ticks from the landing; the next life starts at the 39th.
    try testing.expectEqual(@as(usize, 38), lying);
    try testing.expectEqualStrings("fall", r.state());
    const e = r.player();
    try testing.expectEqual(@as(i16, 80), e.health);
    try testing.expect(e.position.height.lessThan(r.w.ground));
    try testing.expectEqual(@as(u8, 1), r.w.players[0].specials);
    try testing.expectEqual(@as(u8, 40), r.w.timer.seconds);
}

test "out of lives: the continue's question; YES spends a continue for the lives of a new game" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var r = try Round.init();
    defer r.deinit();
    const plan: script.Plan = .{ .round = &lives_round, .lives = 3 };
    script.start(&r.w, &plan);
    r.w.players[0].lives = 1;
    r.w.players[0].score = 5000;
    r.player().health = 0;
    const states = try statesOf(&r, &plan, 80, .{});
    try testing.expectEqualStrings("dying lying_dead begin continue_choose", states);
    try testing.expect(r.player().flags.hidden);
    try testing.expect(r.w.get(r.hero).?.mind == .player_waiting);
    // The timer stops while it waits.
    const seconds = r.w.timer.seconds;
    for (0..200) |_| r.stepPlan(.{}, &plan);
    try testing.expectEqual(seconds, r.w.timer.seconds);
    // B answers YES (the cursor's first place): the next tick, its next life.
    r.stepPlan(b_pad, &plan);
    try testing.expectEqualStrings("continue_chosen", r.state());
    r.stepPlan(.{}, &plan);
    try testing.expectEqualStrings("fall", r.state());
    try testing.expectEqual(@as(u8, 3), r.w.players[0].lives);
    try testing.expectEqual(@as(u8, 2), r.w.players[0].continues);
    try testing.expectEqual(@as(u32, 0), r.w.players[0].score);
}

test "the continue's NO, or none left: out of the game, the game over's count" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var r = try Round.init();
    defer r.deinit();
    const plan: script.Plan = .{ .round = &lives_round, .lives = 3 };
    script.start(&r.w, &plan);
    r.w.players[0].lives = 1;
    r.player().health = 0;
    _ = try statesOf(&r, &plan, 80, .{});
    try testing.expectEqualStrings("continue_choose", r.state());
    // Down moves the cursor to NO; B answers.
    r.stepPlan(.{ .pad1 = .{ .down = true } }, &plan);
    r.stepPlan(.{}, &plan);
    const states = try statesOf(&r, &plan, 260, b_pad);
    try testing.expectEqualStrings("continue_chosen begin countdown game_over", states);
    try testing.expect(r.w.players[0].out);
    try testing.expectEqual(@as(u8, 0), r.w.players[0].continues);

    // No continue left: out at once, the shorter count.
    var r2 = try Round.init();
    defer r2.deinit();
    script.start(&r2.w, &plan);
    r2.w.players[0].lives = 1;
    r2.w.players[0].continues = 0;
    r2.player().health = 0;
    while (!std.mem.eql(u8, r2.state(), "countdown")) r2.stepPlan(.{}, &plan);
    var ticks: usize = 0;
    while (!std.mem.eql(u8, r2.state(), "game_over")) : (ticks += 1) r2.stepPlan(.{}, &plan);
    try testing.expectEqual(@as(usize, 250), ticks);
}

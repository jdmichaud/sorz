//! The fighters' tests on synthetic content (DESIGN.md V1): a player (`player` behaviour), a punk
//! (`galsia`), a stalker (`stalker`), Signal (`signal`), the special attack's car (`police_car`)
//! and a player out of lives (`player_waiting`), whose definitions here take the extractor's
//! numbers for Axel and round 1's enemies, so that the timings checked are the ones sor-remaster
//! measures (the catalogue's), on frames and boxes of the tests' own.
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
    \\   "knocked_down_up": -327680, "knocked_down_x": -147456, "last_blow_ends": 4, "let_go": 3, "special_beyond": 352,
    \\   "pick_depth": 16, "pick_height": 8, "pick_x": 20, "recover_ends": 2, "steer": 24576,
    \\   "steer_most": 229376, "throw_ends": 6, "vault_ends": 4, "walk_depth": 155648,
    \\   "walk_x": 196608, "dying_x": -262144, "dying_up": -589824, "dead": 38,
    \\   "escape_frame": 3, "escape_window": 8, "thrown_first": 5, "thrown_pace": 3,
    \\   "thrown_falls": 2, "thrown_ahead": 32, "thrown_up": -196608, "thrown_x": 229376,
    \\   "held_ahead": 16},
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
    anim("throw_back", fr("3", ", \"place\": {\"x\": -28, \"height\": -8}") ++ "," ++ fr("3", place) ++ "," ++ fr("3", place) ++ "," ++ fr("3", place) ++ "," ++ fr("3", place) ++ "," ++ fr("3", ", \"place\": {\"x\": 32}") ++ "," ++ fr("6", ", \"place\": {\"x\": 48}")) ++ "," ++
    anim("held", fr("30", "")) ++ "," ++
    anim("held_behind", fr("30", "")) ++ "," ++
    anim("escape", fr("4", "") ++ "," ++ fr("6", "") ++ "," ++ fr("2", "") ++ "," ++ fr("4", "")) ++ "," ++
    anim("counter", fr("5", ", \"held\": {\"x\": 16, \"pose\": 0}") ++ "," ++ fr("15", ", \"blow\": true, \"held\": {\"x\": 40, \"height\": -32, \"lets_go\": true}") ++ "," ++ fr("4", "")) ++ "," ++
    anim("thrown", bare("100", ", \"place\": {\"x\": -24}") ++ "," ++ bare("12", ", \"place\": {\"x\": -4, \"height\": -48}") ++ "," ++ bare("8", ", \"place\": {\"x\": 16, \"height\": -40}") ++ "," ++ bare("1", ", \"place\": {}")) ++
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
    \\   "throw_back": {"animation": "throw_back"},
    \\   "counter": {"animation": "counter", "damage": 4, "reaction": "thrown"}}
    \\}
;

/// A punk's frame of `ticks` ticks with its body, and more fields.
fn pf(comptime ticks: []const u8, comptime more: []const u8) []const u8 {
    return "{\"frame\": \"t/f2\", \"ticks\": " ++ ticks ++ ", \"body\": \"body\"" ++ more ++ "}";
}

fn pb(comptime ticks: []const u8) []const u8 {
    return "{\"frame\": \"t/f3\", \"ticks\": " ++ ticks ++ "}";
}

/// The numbers every enemy has (enemy.zig's common states), round 1's Galsias'.
const enemy_numbers =
    \\"appears_from": -16, "appears_to": 335, "blink": 3, "blinks": 8, "bounce_most": 393216,
    \\ "bounce_slowing": 16384, "fall_most": 1048576, "first_blink": 16, "flipped_up": -327680,
    \\ "flipped_x": 196608, "gets_up_frame": 4, "grab_height": 8, "knocked_out_x": 655360,
    \\ "knocked_slowing": 21504, "knocked_up": -589824, "knocked_x": 458752, "lying": 16,
    \\ "knocked_back_x": 262144, "knocked_back_up": -458752,
    \\ "lying_least": 3, "middle_from": 0, "middle_to": 320, "points": 500, "reel": 24,
    \\ "reel_nudge": 2, "slam_hurt": 5, "slam_ticks": 8, "slammed_up": -393216, "slammed_x": 294912,
    \\ "special_down_frame": 3, "special_shake_pace": 3, "special_shake_turn": 8,
    \\ "special_spin_frame": 2, "special_spin_turn": 10, "stand": 160, "struck_from": -8,
    \\ "struck_held": 10, "struck_to": 328, "thrown_damage": 2, "thrown_hurt": 4, "thrown_slide": 7,
    \\ "thrown_up": -393216, "thrown_x": 360448, "walk_depth_least": 2, "walk_depth_most": 112,
    \\ "walk_off_again": 7, "walk_off_depth": 196608, "walk_off_down_to": 88,
    \\ "walk_off_faster": 655360, "walk_off_faster_after": 5, "walk_off_fastest": 851968,
    \\ "walk_off_fastest_after": 16, "walk_off_near": 80, "walk_off_pace": 4, "walk_off_up_from": 56,
    \\ "walk_off_up_to": 24, "walk_x_most": 5392
;

/// The numbers of the punks that close in and punch (galsia.zig's `Punk`).
const punch_numbers =
    \\"close_in_beside": 32, "close_in_pace": 3, "close_in_slow": 196608, "close_in_speed": 294912,
    \\ "close_in_ticks": 48, "edge_punch_pace": 4, "last_punch_frame": 7, "last_punch_test": 6,
    \\ "punch_ends": 9, "reach_frame": 0, "too_close": 48
;

/// Every enemy's walk off paces by these.
const pacing_tables =
    \\"pacing": [16, 8, 10, 5], "pacing_pace": [6, 5, 4, 4],
    \\ "pacing_speed": [163840, 196608, 262144, 327680]
;

const enemy_sounds =
    \\"hurt": "enemy hit", "thud": "heavy fall", "cry": "enemy cry", "cry_odd": "enemy cry high"
;

/// Every enemy's common animations: its walk, its fall and lying, its reel, its stand, thrown
/// and slammed.
fn enemyAnimations(comptime walk: []const u8) []const u8 {
    return anim("walk", walk ++ "," ++ walk ++ "," ++ walk ++ "," ++ walk) ++ "," ++
        anim("down", pf("5", "") ++ "," ++ pb("5") ++ "," ++ pb("5") ++ "," ++ pb("5") ++ "," ++ pf("5", "") ++ "," ++ pb("5")) ++ "," ++
        anim("reel", pf("1", "") ++ "," ++ pf("1", "") ++ "," ++ pf("1", "") ++ "," ++ pf("1", "")) ++ "," ++
        anim("stand", pf("6", "") ++ "," ++ pf("6", "") ++ "," ++ pf("6", "")) ++ "," ++
        anim("thrown", pf("6", "") ++ "," ++ pb("6") ++ "," ++ pf("6", "")) ++ "," ++
        anim("slammed", pf("5", "") ++ "," ++ pb("5") ++ "," ++ pb("5") ++ "," ++ pb("5") ++ "," ++ pf("5", "") ++ "," ++ pb("5"));
}

const punch_animation =
    anim("punch", pf("4", ", \"attack\": \"jab\", \"blow\": true") ++ "," ++ pf("4", "") ++ "," ++ pf("4", "") ++ "," ++ pf("4", ", \"attack\": \"jab\", \"blow\": true") ++ "," ++ pf("4", "") ++ "," ++ pf("4", "") ++ "," ++ pf("4", "") ++ "," ++ pf("4", ", \"attack\": \"punch\", \"blow\": true") ++ "," ++ pf("4", ", \"attack\": \"punch\", \"blow\": true") ++ "," ++ pf("4", ", \"attack\": \"punch\", \"blow\": true"));

const punch_moves =
    \\"punch": {"animation": "punch", "damage": 4},
    \\   "punch_last": {"animation": "punch", "damage": 4, "reaction": "knock_down"}
;

const punk =
    \\{"family": "enemy", "team": "enemy", "behaviour": "galsia", "health": 4, "gravity": 73728,
    \\ "shadow": true,
    \\ "numbers": {
++ enemy_numbers ++ ", " ++ punch_numbers ++ ", " ++
    \\ "power": 4, "approach_speed": 163840, "approach_ticks": 80, "edge_depth": 16,
    \\   "edge_left": 16, "edge_near": 88, "edge_right": 304, "edge_speed": 262144, "edge_ticks": 96,
    \\   "flank_beside": 32, "flank_speed": 327680, "square_level": 16, "square_ticks": 16,
    \\   "taunt_ends": 6, "taunt_pace": 3, "taunts": 3, "wait_frame": 3, "wait_near": 80,
    \\   "wait_ticks": 128, "shutter_beside": 32, "shutter_above": 18, "shutter_drop": 1,
    \\   "shutter_depth": 3},
    \\ "tables": {"circle_depth": [16, 16, 0, 16, -16, 0, -16, -16, 16, 8, 0, 8, -8, 0, -8, -16],
    \\   "circle_pace": [7, 6, 5, 3], "circle_speed": [65536, 98304, 131072, 196608],
    \\   "circle_x": [16, 0, 16, -16, 16, -16, 0, -16, 8, 0, 8, -16, 16, -8, 0, -8],
    \\   "hesitate": [35, 4, 20, 8],
++ pacing_tables ++ "}," ++
    \\ "choices": {"after_circle": ["circle", "circle", "circle", "hesitate", "close_in", "hesitate", "choose", "close_in"]},
    \\ "sounds": {
++ enemy_sounds ++ "}," ++
    \\ "boxes": {"body": {"x": [-9, 9], "depth": [-8, 8], "height": [-60, 0]},
    \\   "jab": {"x": [0, 40], "depth": [-8, 8], "height": [-50, -44]},
    \\   "punch": {"x": [16, 51], "depth": [-8, 8], "height": [-48, -42]}},
    \\ "animations": {
++ enemyAnimations(pf("5", "")) ++ "," ++ punch_animation ++
    \\ },
    \\ "moves": {
++ punch_moves ++ "}}";

/// A stalker: the punk's, but it lurks and sneaks up to grab from behind with its grab's box.
const stalker =
    \\{"family": "enemy", "team": "enemy", "behaviour": "stalker", "health": 4, "gravity": 73728,
    \\ "shadow": true,
    \\ "numbers": {
++ enemy_numbers ++ ", " ++ punch_numbers ++ ", " ++
    \\ "power": 4, "approach_speed": 131072, "approach_ticks": 80, "lurk_ticks": 40,
    \\   "sneak_pace": 3, "sneak_speed": 294912},
    \\ "tables": {
++ pacing_tables ++ "}," ++
    \\ "sounds": {
++ enemy_sounds ++ "}," ++
    \\ "boxes": {"body": {"x": [-9, 9], "depth": [-8, 8], "height": [-60, 0]},
    \\   "jab": {"x": [0, 40], "depth": [-8, 8], "height": [-50, -44]},
    \\   "punch": {"x": [16, 51], "depth": [-8, 8], "height": [-48, -42]},
    \\   "sneak_grab": {"x": [-13, 13], "depth": [-10, 10], "height": [-60, 0]}},
    \\ "animations": {
++ enemyAnimations(pf("5", "")) ++ "," ++ punch_animation ++ "," ++ anim("grab", pf("3", "")) ++
    \\ },
    \\ "moves": {
++ punch_moves ++ "}}";

/// Signal: its walk's reach holds a player it walks into; it slides in with a kick.
const signal =
    \\{"family": "enemy", "team": "enemy", "behaviour": "signal", "health": 4, "gravity": 73728,
    \\ "shadow": true,
    \\ "numbers": {
++ enemy_numbers ++ ", " ++
    \\ "power": 8, "approach_speed": 131072, "approach_ticks": 96, "close_in_pace": 3,
    \\   "close_in_speed": 229376, "close_in_ticks": 48, "diagonal_depth": 131072,
    \\   "diagonal_x": 163840, "far": 8388608, "hold_ends": 3, "hold_middle": 160, "hold_place": 48,
    \\   "size_up_ticks": 24, "slide_end_frame": 3, "slide_end_ticks": 8, "slide_level": 8,
    \\   "slide_slowing": 10240, "slide_speed": 458752, "slide_ticks": 26},
    \\ "tables": {
++ pacing_tables ++ "}," ++
    \\ "sounds": {
++ enemy_sounds ++ ", \"slide\": \"slide kick\"}," ++
    \\ "boxes": {"body": {"x": [-9, 9], "depth": [-8, 8], "height": [-60, 0]},
    \\   "reach": {"x": [-11, 11], "depth": [-8, 8], "height": [-60, 0]},
    \\   "kick": {"x": [-24, 24], "depth": [-8, 8], "height": [-14, 0]}},
    \\ "animations": {
++ enemyAnimations(pf("6", ", \"attack\": \"reach\"")) ++ "," ++
    anim("hold", pb("8") ++ "," ++ pb("8") ++ "," ++ pb("8") ++ "," ++ pb("8")) ++ "," ++
    anim("slide", pb("8") ++ "," ++ pf("8", ", \"attack\": \"kick\", \"blow\": true") ++ "," ++ pb("8") ++ "," ++ pb("8")) ++
    \\ },
    \\ "moves": {"slide": {"animation": "slide", "damage": 8, "reaction": "knock_down"}}}
;

/// A pipe Galsia: its walk and its swing hold its pipe (their frames' hands), its swing strikes.
const galsia_pipe =
    \\{"family": "enemy", "team": "enemy", "behaviour": "galsia_pipe", "health": 6, "gravity": 73728,
    \\ "shadow": true,
    \\ "numbers": {
++ enemy_numbers ++ ", " ++
    \\ "power": 12, "approach_speed": 163840, "wait_ticks": 16, "wait_level": 16,
    \\   "close_in_pace": 3, "close_in_ticks": 48, "close_in_speed": 229376, "close_in_beside": 64,
    \\   "swing_pace": 3, "swing_sound_frame": 1, "swing_ends": 5},
    \\ "tables": {
++ pacing_tables ++ "}," ++
    \\ "sounds": {
++ enemy_sounds ++ ", \"swing\": \"pipe swing\"}," ++
    \\ "boxes": {"body": {"x": [-9, 9], "depth": [-8, 8], "height": [-60, 0]},
    \\   "swing": {"x": [24, 72], "depth": [-8, 8], "height": [-56, -40]}},
    \\ "animations": {
++ enemyAnimations(pf("5", "")) ++ "," ++
    anim("walk_pipe", pf("5", ", \"hand\": {\"x\": -9, \"height\": -60, \"pose\": \"upright\"}") ++ "," ++ pf("5", ", \"hand\": {\"x\": -9, \"height\": -61, \"pose\": \"upright\"}")) ++ "," ++
    anim("walk_pipe_b", pf("5", ", \"hand\": {\"x\": -9, \"height\": -60, \"pose\": \"upright\"}")) ++ "," ++
    anim("swing", pf("3", ", \"hand\": {\"x\": -9, \"height\": -60, \"pose\": \"upright\"}") ++ "," ++ pf("3", ", \"hand\": {\"x\": 5, \"height\": -50, \"pose\": \"upright\", \"front\": true}") ++ "," ++ pf("3", "") ++ "," ++
        pf("3", ", \"attack\": \"swing\", \"blow\": true, \"hand\": {\"x\": 53, \"height\": -51, \"pose\": \"level\"}") ++ "," ++ pf("3", ", \"attack\": \"swing\", \"blow\": true") ++ "," ++ pf("3", ", \"attack\": \"swing\", \"blow\": true")) ++ "," ++
    anim("swing_b", pf("3", "") ++ "," ++ pf("3", "") ++ "," ++ pf("3", "") ++ "," ++ pf("3", "") ++ "," ++ pf("3", "") ++ "," ++ pf("3", "")) ++
    \\ },
    \\ "moves": {"swing": {"animation": "swing", "damage": 12}, "swing_b": {"animation": "swing_b", "damage": 12}}}
;

/// A pipe: its poses, how long it lasts and falls.
const pipe =
    \\{"family": "weapon", "team": "neutral", "behaviour": "weapon", "gravity": 34816,
    \\ "numbers": {"power": 4, "uses": 3, "blink": 16, "drop": 131072, "left_behind": 96},
    \\ "animations": {
++ anim("lying", bare("1", "")) ++ "," ++ anim("level", bare("1", "")) ++ "," ++ anim("upright", bare("1", "")) ++ "," ++ anim("blinking", bare("1", "") ++ "," ++ bare("1", "")) ++
    \\ }}
;

/// A rolling shutter: five slats that roll up when its player comes near.
const shutter =
    \\{"family": "scenery", "team": "neutral", "behaviour": "shutter",
    \\ "numbers": {"slats": 5, "above": 18, "spacing": 16, "roll": 64, "less": 16, "top": 64,
    \\   "roll_speed": -65536, "near": 32, "beside": 32},
    \\ "sounds": {"roll": "shutter"},
    \\ "animations": {
++ anim("slat", bare("1", "")) ++
    \\ }}
;

/// A breakable: it stands (its body, its solid box), blinks broken; three pieces fly off.
const breakable =
    \\{"family": "scenery", "team": "neutral", "behaviour": "breakable",
    \\ "numbers": {"height": 160, "breaking": 10, "going": 8, "pieces": 3, "piece_x": -12,
    \\   "piece_depth": 4, "piece_above": 8, "piece_gravity": 61440, "left_behind": 96,
    \\   "screen_from": -8, "screen_to": 328},
    \\ "tables": {"piece_speed_x": [-65536, 81920, -81920, 0, 0, 0, 0, 0, 0, 0],
    \\   "piece_speed_up": [-163840, -131072, -196608, 0, 0, 0, 0, 0, 0, 0],
    \\   "piece_frame": [2, 3, 1, 1, 1, 1, 1, 1, 1, 1],
    \\   "piece_offset": [0, 24, 0, 0, 0, 0, 0, 0, 0, 0]},
    \\ "sounds": {"shatter": "smash"},
    \\ "boxes": {"body": {"x": [-16, 16], "depth": [-10, 10], "height": [-80, 0]},
    \\   "solid": {"x": [-27, 27], "depth": [-9, 3], "height": [-80, 0]}},
    \\ "animations": {
++ anim("stand", fr("2", "")) ++ "," ++ anim("blink", bare("2", "") ++ "," ++ bare("2", "")) ++ "," ++
    anim("piece_1", bare("1", "")) ++ "," ++ anim("piece_2", bare("1", "")) ++ "," ++ anim("piece_3", bare("1", "")) ++
    \\ }}
;

/// An apple: 20 health, up to 80.
const apple =
    \\{"family": "item", "team": "neutral", "behaviour": "item",
    \\ "numbers": {"fall": 196608, "left_behind": 96, "health_most": 80, "health": 20, "lives": 0,
    \\   "specials": 0, "points": 0},
    \\ "sounds": {"picked": "food"},
    \\ "boxes": {"body": {"x": [-8, 8], "depth": [-8, 8], "height": [-16, 0]}},
    \\ "animations": {
++ anim("lying", fr("1", "")) ++
    \\ }}
;

/// A gold bar: 5000 points.
const gold =
    \\{"family": "item", "team": "neutral", "behaviour": "item",
    \\ "numbers": {"fall": 196608, "left_behind": 96, "health_most": 80, "health": 0, "lives": 0,
    \\   "specials": 0, "points": 5000},
    \\ "sounds": {"picked": "pickup"},
    \\ "boxes": {"body": {"x": [-8, 8], "depth": [-8, 8], "height": [-16, 0]}},
    \\ "animations": {
++ anim("lying", fr("1", "")) ++
    \\ }}
;

/// A knife: a pipe's poses but upright, and its flight thrown.
const knife =
    \\{"family": "weapon", "team": "neutral", "behaviour": "knife", "gravity": 34816,
    \\ "numbers": {"power": 5, "uses": 3, "blink": 16, "drop": 131072, "left_behind": 96,
    \\   "throw_speed": 1048576, "throw_ahead": 48, "throw_below": 16, "flight_from": -16,
    \\   "flight_to": 336, "bounce_shift": 2, "bounce_gravity": 38912},
    \\ "boxes": {"blade": {"x": [-8, 8], "depth": [-8, 8], "height": [-8, 0]}},
    \\ "animations": {
++ anim("lying", bare("1", "")) ++ "," ++ anim("level", "{\"frame\": \"t/f1\", \"ticks\": 1, \"body\": \"blade\", \"attack\": \"blade\"}") ++ "," ++ anim("blinking", bare("1", "") ++ "," ++ bare("1", "")) ++
    \\ }}
;

/// A knife Galsia: its walk holds its knife, its stab strikes within its reach, its throw lets
/// it go at its second frame.
const galsia_knife =
    \\{"family": "enemy", "team": "enemy", "behaviour": "galsia_knife", "health": 6, "gravity": 73728,
    \\ "shadow": true,
    \\ "numbers": {
++ enemy_numbers ++ ", " ++
    \\ "power": 10, "jump_in_speed": 327680, "jump_in_pace": 6, "jump_in_slowing": 12288,
    \\   "close_in_speed": 147456, "close_in_first": 1, "size_up_ticks": 24, "size_up_level": 8,
    \\   "stab_near": 96, "stab_speed": 196608, "stab_beside": 32, "stab_pace": 4, "stab_again": 2,
    \\   "throw_frame": 1, "throw_ends": 2},
    \\ "tables": {
++ pacing_tables ++ "}," ++
    \\ "sounds": {
++ enemy_sounds ++ ", \"throw\": \"knife throw\"}," ++
    \\ "boxes": {"body": {"x": [-9, 9], "depth": [-8, 8], "height": [-60, 0]},
    \\   "stab_reach": {"x": [0, 40], "depth": [-8, 8], "height": [-60, -20]},
    \\   "stab": {"x": [10, 40], "depth": [-8, 8], "height": [-56, -40]}},
    \\ "animations": {
++ enemyAnimations(pf("5", "")) ++ "," ++
    anim("walk_knife", pf("5", ", \"hand\": {\"x\": -9, \"height\": -40, \"pose\": \"lying\"}") ++ "," ++ pf("5", ", \"hand\": {\"x\": -9, \"height\": -40, \"pose\": \"lying\"}")) ++ "," ++
    anim("jump_in", pf("6", ", \"attack\": \"stab\", \"blow\": true, \"hand\": {\"x\": -9, \"height\": -40, \"pose\": \"lying\"}")) ++ "," ++
    anim("stab", pf("4", ", \"hand\": {\"x\": 5, \"height\": -50, \"pose\": \"level\"}") ++ "," ++ pf("4", ", \"attack\": \"stab\", \"blow\": true, \"hand\": {\"x\": 20, \"height\": -50, \"pose\": \"level\"}") ++ "," ++ pf("4", "")) ++ "," ++
    anim("throw", pf("3", ", \"hand\": {\"x\": -9, \"height\": -50, \"pose\": \"lying\"}") ++ "," ++ pf("3", ", \"hand\": {\"x\": 9, \"height\": -50, \"pose\": \"level\"}") ++ "," ++ pf("3", "")) ++
    \\ },
    \\ "moves": {"stab": {"animation": "stab", "damage": 10, "hit_sound": "knife stab"},
    \\   "jump_in": {"animation": "jump_in", "damage": 10, "reaction": "knock_down"}}}
;

/// A brawler: it follows, closes in and punches (knocking down); struck it reels a tick later,
/// or shrugs the blow off.
const brawler =
    \\{"family": "enemy", "team": "enemy", "behaviour": "brawler", "health": 12, "gravity": 73728,
    \\ "shadow": true,
    \\ "numbers": {
++ enemy_numbers ++ ", " ++
    \\ "power": 8, "follow_speed": 98304, "follow_first": 1, "follow_turns": 2, "follow_stops": 80,
    \\   "follow_ticks": 80, "close_in_pace": 3, "close_in_punches": 3, "close_in_ticks": 80,
    \\   "close_in_beside": 56, "punch_ends": 4, "shrug_frame": 3, "shrug_ticks": 128,
    \\   "shrug_near": 80, "sides_from": -16, "sides_to": 336,
    \\   "shutter_beside": 32, "shutter_above": 18, "shutter_drop": 1, "shutter_depth": 3},
    \\ "tables": {
++ pacing_tables ++ "}," ++
    \\ "sounds": {
++ enemy_sounds ++ ", \"shrug\": \"grunt\"}," ++
    \\ "boxes": {"body": {"x": [-9, 9], "depth": [-8, 8], "height": [-60, 0]},
    \\   "punch_reach": {"x": [0, 40], "depth": [-8, 8], "height": [-60, -20]},
    \\   "fist": {"x": [10, 40], "depth": [-8, 8], "height": [-56, -40]}},
    \\ "animations": {
++ enemyAnimations(pf("5", "")) ++ "," ++
    anim("punch", pf("3", "") ++ "," ++ pf("3", ", \"attack\": \"fist\", \"blow\": true") ++ "," ++ pf("3", "") ++ "," ++ pf("3", "") ++ "," ++ pf("3", "")) ++
    \\ },
    \\ "moves": {"punch": {"animation": "punch", "damage": 8, "reaction": "knock_down"}}}
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

/// Round 1's boss and his boomerang, as the extractor writes them (their frames on the test art).
const antonio_fixture =
    \\{"animations": {"bounce": {"frames": [{"attack": "bounce_attack", "flip": true,
    \\"frame": "t/f0", "ticks": 1}], "loop": true}, "down": {"frames": [{"frame": "t/f0",
    \\"ticks": 1}], "loop": true}, "flight": {"frames": [{"attack": "flight_attack",
    \\"frame": "t/f0", "ticks": 1}], "loop": true}, "held": {"frames": [{"body": "knocked_body",
    \\"frame": "t/f0", "ticks": 1}], "loop": true},
    \\"held_behind": {"frames": [{"body": "held_behind_body", "frame": "t/f0", "ticks": 1}],
    \\"loop": true}, "idle": {"frames": [{"body": "stand_body", "frame": "t/f0",
    \\"hand": {"height": -80, "pose": "held", "x": -18}, "ticks": 6}, {"body": "stand_body",
    \\"frame": "t/f0", "hand": {"height": -76, "pose": "held", "x": -14}, "ticks": 6},
    \\{"body": "stand_body", "frame": "t/f0", "hand": {"height": -84, "pose": "held", "x": -24},
    \\"ticks": 6}, {"body": "stand_body", "frame": "t/f0", "hand": {"height": -76,
    \\"pose": "held", "x": -14}, "ticks": 6}], "loop": true},
    \\"knocked": {"frames": [{"body": "knocked_body", "frame": "t/f0", "ticks": 1}],
    \\"loop": true}, "lifted": {"frames": [{"attack": "lifted_attack", "frame": "t/f0",
    \\"ticks": 1}], "loop": true}, "stand": {"frames": [{"body": "stand_body", "frame": "t/f0",
    \\"hand": {"height": -80, "pose": "held", "x": -18}, "ticks": 6}, {"body": "stand_body",
    \\"frame": "t/f0", "hand": {"height": -81, "pose": "held", "x": -18}, "ticks": 6},
    \\{"body": "stand_body", "frame": "t/f0", "hand": {"height": -80, "pose": "held", "x": -18},
    \\"ticks": 6}, {"body": "stand_body", "frame": "t/f0", "hand": {"height": -81,
    \\"pose": "held", "x": -18}, "ticks": 6}], "loop": true},
    \\"swing": {"frames": [{"body": "stand_body", "frame": "t/f0", "ticks": 3},
    \\{"attack": "swing_attack", "blow": true, "body": "swing_body", "frame": "t/f0",
    \\"ticks": 3}, {"attack": "swing_attack_2", "blow": true, "body": "swing_body",
    \\"frame": "t/f0", "ticks": 3}, {"attack": "swing_attack_3", "blow": true,
    \\"body": "swing_body_2", "frame": "t/f0", "ticks": 3}, {"attack": "swing_attack_3",
    \\"blow": true, "body": "swing_body_2", "frame": "t/f0", "ticks": 3},
    \\{"attack": "swing_attack_3", "blow": true, "body": "swing_body_2", "frame": "t/f0",
    \\"ticks": 3}, {"attack": "swing_attack_3", "blow": true, "body": "swing_body_2",
    \\"frame": "t/f0", "ticks": 3}, {"body": "stand_body", "frame": "t/f0", "ticks": 3},
    \\{"body": "stand_body", "frame": "t/f0", "ticks": 3}], "loop": true},
    \\"taunt": {"frames": [{"body": "stand_body", "frame": "t/f0", "hand": {"height": -80,
    \\"pose": "held", "x": -18}, "ticks": 6}, {"body": "taunt_body", "frame": "t/f0",
    \\"hand": {"height": -80, "pose": "held", "x": -36}, "ticks": 6}], "loop": true},
    \\"throw": {"frames": [{"body": "stand_body", "frame": "t/f0", "hand": {"height": -80,
    \\"pose": "held", "x": -18}, "ticks": 6}, {"body": "throw_body", "frame": "t/f0",
    \\"hand": {"height": -45, "pose": "held_high", "x": -36}, "ticks": 6}, {"body": "throw_body",
    \\"frame": "t/f0", "hand": {"height": -48, "pose": "spin", "x": 64}, "ticks": 6},
    \\{"body": "throw_body", "frame": "t/f0", "hand": {"height": -48, "pose": "spin", "x": 64},
    \\"ticks": 6}, {"body": "throw_body", "frame": "t/f0", "hand": {"height": -48,
    \\"pose": "spin", "x": 64}, "ticks": 6}, {"body": "stand_body", "frame": "t/f0",
    \\"hand": {"height": -80, "pose": "held", "x": -18}, "ticks": 6}], "loop": true},
    \\"wait": {"frames": [{"body": "stand_body", "frame": "t/f0", "hand": {"height": -45,
    \\"pose": "held_high", "x": -36}, "ticks": 6}, {"body": "stand_body", "frame": "t/f0",
    \\"hand": {"height": -45, "pose": "held_high", "x": -36}, "ticks": 6}, {"body": "stand_body",
    \\"frame": "t/f0", "hand": {"height": -45, "pose": "held_high", "x": -36}, "ticks": 6},
    \\{"body": "stand_body", "frame": "t/f0", "hand": {"height": -45, "pose": "held_high",
    \\"x": -36}, "ticks": 6}], "loop": true}, "walk": {"frames": [{"body": "stand_body",
    \\"frame": "t/f0", "hand": {"height": -80, "pose": "held", "x": -18}, "ticks": 6},
    \\{"body": "stand_body", "frame": "t/f0", "hand": {"height": -76, "pose": "held", "x": -14},
    \\"ticks": 6}, {"body": "stand_body", "frame": "t/f0", "hand": {"height": -84,
    \\"pose": "held", "x": -24}, "ticks": 6}, {"body": "stand_body", "frame": "t/f0",
    \\"hand": {"height": -76, "pose": "held", "x": -14}, "ticks": 6}], "loop": true}},
    \\"behaviour": "antonio", "boxes": {"bounce_attack": {"depth": [-8, 8], "height": [-20, -4],
    \\"x": [-48, 4]}, "flight_attack": {"depth": [-8, 8], "height": [-52, -18], "x": [-38, 6]},
    \\"held_behind_body": {"depth": [-8, 8], "height": [-56, 0], "x": [-18, 14]},
    \\"knocked_body": {"depth": [-8, 8], "height": [-56, 0], "x": [-14, 15]},
    \\"lifted_attack": {"depth": [-8, 8], "height": [-42, 0], "x": [-34, -4]},
    \\"stand_body": {"depth": [-8, 8], "height": [-68, 0], "x": [-14, 15]},
    \\"swing_attack": {"depth": [-8, 8], "height": [-36, -6], "x": [-8, 30]},
    \\"swing_attack_2": {"depth": [-8, 8], "height": [-36, -6], "x": [-8, 60]},
    \\"swing_attack_3": {"depth": [-8, 8], "height": [-50, -32], "x": [12, 84]},
    \\"swing_body": {"depth": [-8, 8], "height": [-66, 0], "x": [-6, 22]},
    \\"swing_body_2": {"depth": [-8, 8], "height": [-74, 0], "x": [14, 40]},
    \\"taunt_body": {"depth": [-8, 8], "height": [-68, 0], "x": [-32, 0]},
    \\"throw_body": {"depth": [-8, 8], "height": [-62, 0], "x": [-8, 22]}}, "family": "boss",
    \\"health": 24, "moves": {"swing": {"animation": "swing", "damage": 20,
    \\"reaction": "knock_down"}}, "numbers": {"align_level": 20, "align_speed": 65536,
    \\"back_away_speed": 98304, "back_away_ticks": 32, "blast_bounces": 2, "blast_ticks": 30,
    \\"blast_up": -327680, "blast_x": -196608, "bounce_up": -196608, "catch_hand": 24,
    \\"catch_steer": 65536, "catch_within": 8, "charge_back_from": 224, "charge_back_level": 20,
    \\"charge_from": 40, "charge_level": 20, "charge_speed": 262144, "charge_stop_far": 224,
    \\"charge_stop_level": 16, "charge_stop_near": 40, "dead_ticks": 110, "depth_most": 112,
    \\"down_ticks": 8, "dying_x": -262144, "edge_from": -64, "edge_to": 384, "fling_at": 41,
    \\"fling_bounce": -131072, "fling_bounce_2": -393216, "fling_damage": 4, "fling_lift_at": 45,
    \\"fling_place": 40, "fling_ticks": 50, "fling_turn_at": 33, "fling_up": -524288,
    \\"fling_x": 458752, "grab_height": 8, "hardest_health": 5, "hold_behind": -32,
    \\"hold_front": 40, "keep_at": 18, "keep_far": 32, "keep_near": 8, "keep_step_1": 22,
    \\"keep_step_2": 26, "knee_damage": 2, "knock_back_ticks": 8, "knock_down_ticks": 30,
    \\"knocked_bounces": 2, "knocked_gravity": 65536, "knocked_up": -327680,
    \\"knocked_x": -327680, "last_knee_damage": 3, "level_far": 32, "level_mid": 16,
    \\"level_near": 8, "missile_damage": 1, "near": 120, "on_screen_from": 0,
    \\"on_screen_to": 320, "outside_power": 2, "points": 3000, "points_at": 90, "power": 20,
    \\"push_from": -32, "push_to": 352, "screen_middle": 160, "shake": 2, "special_damage": 10,
    \\"special_grounded": 20, "special_ticks": 300, "special_ticks_second": 390,
    \\"stand_far_level": 144, "stand_far_speed": 98304, "stand_near": 20, "steer": 131072,
    \\"steer_fast": 262144, "steer_slow": 65536, "stroll_speed": 65536, "stroll_ticks": 28,
    \\"stroll_toward_from": 128, "struck_from": -8, "struck_to": 328, "sway_speed": 65536,
    \\"swing_ends": 8, "swing_frame": 1, "swing_from_start": 2, "swing_level": 16,
    \\"swing_level_above": 8, "swing_reach_coming": 120, "swing_reach_going": 80,
    \\"swing_reach_still": 104, "swing_reach_still_left": 80, "taunt_from": 192,
    \\"throw_ticks": 36, "thrown_bounces": 3, "thrown_damage": 2, "thrown_gravity": 131072,
    \\"toss_ahead": 32, "toss_bounce": -524288, "toss_bounce_2": -131072, "toss_damage": 4,
    \\"toss_lift": 64, "toss_lift_at": 41, "toss_place": 16, "toss_ticks": 45,
    \\"toss_up": -327680, "toss_x": 524288, "vault_damage": 5, "vault_down_at": 32,
    \\"vault_fly": -393216, "vault_fly_at": 29, "vault_over_at": 36, "vault_place": -10,
    \\"vault_slide": -196608, "vault_ticks": 45, "vault_turn_at": 40, "walk_in_low": 56,
    \\"walk_in_speed": 262144, "walk_in_ticks": 72, "walk_in_ticks_second": 70,
    \\"zigzag_back": 64, "zigzag_turn": 32}, "shadow": true, "sounds": {"cry": "boss cry",
    \\"hurt": "enemy hit", "swing": "swing", "thud": "heavy fall"}, "tables": {"carried": [8,
    \\-22, 16, 8, 14, 24, 64, -24, 32, -8]}, "team": "enemy"}
;

const boomerang_fixture =
    \\{"animations": {"held": {"frames": [{"frame": "t/f0", "ticks": 1}], "loop": true},
    \\"held_high": {"frames": [{"frame": "t/f0", "ticks": 1}], "loop": true},
    \\"spin": {"frames": [{"attack": "spin_attack", "body": "spin_body", "frame": "t/f0",
    \\"ticks": 1}, {"attack": "spin_attack_2", "body": "spin_body_2", "frame": "t/f0",
    \\"ticks": 1}, {"attack": "spin_attack_3", "body": "spin_body_3", "frame": "t/f0",
    \\"ticks": 1}, {"attack": "spin_attack_4", "body": "spin_body_4", "frame": "t/f0",
    \\"ticks": 1}], "loop": true}}, "behaviour": "boomerang",
    \\"boxes": {"spin_attack": {"depth": [-8, 8], "height": [-18, 0], "x": [-4, 22]},
    \\"spin_attack_2": {"depth": [-8, 8], "height": [-10, 0], "x": [-18, 18]},
    \\"spin_attack_3": {"depth": [-8, 8], "height": [-18, 0], "x": [-20, 6]},
    \\"spin_attack_4": {"depth": [-8, 8], "height": [-18, -8], "x": [-20, 16]},
    \\"spin_body": {"depth": [-8, 8], "height": [-18, 0], "x": [-4, 22]},
    \\"spin_body_2": {"depth": [-8, 8], "height": [-10, 0], "x": [-18, 18]},
    \\"spin_body_3": {"depth": [-8, 8], "height": [-18, 0], "x": [-20, 6]},
    \\"spin_body_4": {"depth": [-8, 8], "height": [-18, -8], "x": [-20, 16]}},
    \\"family": "projectile", "numbers": {"depth_back": 12288, "depth_most": 112,
    \\"depth_slowing": -12288, "depth_within": 4, "dropped_back": 3, "dropped_depth": 262144,
    \\"dropped_ticks": 11, "dropped_up": -720896, "flight_depth": 294912, "flight_speed": 917504,
    \\"flight_ticks": 32, "gone_from": -256, "gone_to": 576, "slowing": 28672, "struck_from": -8,
    \\"struck_to": 328}, "shadow": true, "sounds": {"dropped": "metal clang",
    \\"whirr": "boomerang"}, "team": "enemy"}
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
            .{ .name = "stalker", .text = stalker },
            .{ .name = "signal", .text = signal },
            .{ .name = "galsia", .text = punk },
            .{ .name = "galsia_pipe", .text = galsia_pipe },
            .{ .name = "pipe", .text = pipe },
            .{ .name = "knife", .text = knife },
            .{ .name = "galsia_knife", .text = galsia_knife },
            .{ .name = "brawler", .text = brawler },
            .{ .name = "shutter", .text = shutter },
            .{ .name = "breakable", .text = breakable },
            .{ .name = "apple", .text = apple },
            .{ .name = "gold", .text = gold },
            .{ .name = "antonio", .text = antonio_fixture },
            .{ .name = "boomerang", .text = boomerang_fixture },
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
        r.w.camera = .{ .x = .pixels(768), .x_min = .pixels(768), .x_max = .pixels(1216), .y_max = .zero, .follows = script.cameraRules(&content_round.example) };
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

    /// The tick's view of the round, for what an enemy's behaviour asks of it.
    fn tick(r: *Round) tick_mod.Tick {
        return .{ .world = &r.w, .kinds = &r.f.kinds, .random = &r.rng, .out = &r.out };
    }

    /// A punk standing a while (its stand's 160 ticks) at `x`, a holder for the player.
    fn holder(r: *Round, x: i32) !Handle {
        const h = try r.punk(x);
        r.w.get(h).?.mind.galsia.state = .stand;
        r.w.get(h).?.mind.galsia.body.fresh = true;
        return h;
    }

    fn punk(r: *Round, x: i32) !Handle {
        const h = try r.w.spawn(&r.f.kinds, r.f.kinds.find("punk").?, .pixels(x, 64, 160), .left);
        const e = r.w.get(h).?;
        e.mind.galsia.state = .close_in;
        e.mind.galsia.body.target = r.hero;
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
    r.w.get(p).?.mind.galsia.body.fresh = true;
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

test "held from behind: free after the hold's frame; C jumps out, held again with a moment for B" {
    var r = try Round.init();
    defer r.deinit();
    const p = try r.holder(780);
    var t = r.tick();
    t.catchHeld(p, r.hero, true);
    r.step(.{});
    try testing.expectEqualStrings("held_behind", r.state());
    try testing.expect(r.player().holder.?.eql(p));
    // Its frame's 30 ticks, the first the catch's: then it is free.
    var free_at: ?usize = null;
    for (0..40) |i| {
        r.step(.{});
        if (std.mem.eql(u8, r.state(), "ready")) {
            free_at = i;
            break;
        }
    }
    try testing.expectEqual(@as(?usize, 28), free_at);
    try testing.expect(r.player().holder == null and r.w.get(p).?.holding == null);

    t.catchHeld(p, r.hero, true);
    r.step(.{});
    r.step(c_pad);
    try testing.expectEqualStrings("escape", r.state());
    // The jump out's frames of 4, 6 and 2 ticks: at the fourth it is held again.
    var again_at: ?usize = null;
    for (0..20) |i| {
        r.step(.{});
        if (std.mem.eql(u8, r.state(), "held_behind")) {
            again_at = i;
            break;
        }
    }
    try testing.expectEqual(@as(?usize, 11), again_at);
    // B in that moment throws the holder over: the hold turned.
    r.step(b_pad);
    try testing.expectEqualStrings("grab_blow", r.state());
    try testing.expect(r.player().holding.?.eql(p) and r.player().holder == null);
    // Thrown over, the punk is knocked down, the throw's damage taken.
    var thrown = false;
    for (0..40) |_| {
        r.step(.{});
        if (r.w.get(p).?.mind.galsia.state == .knocked_down) thrown = true;
    }
    try testing.expect(thrown);
    try testing.expectEqual(@as(i16, 0), r.w.get(p).?.health);
}

test "held from the front and thrown: over the holder, ahead, the throw's damage at the landing" {
    var r = try Round.init();
    defer r.deinit();
    const p = try r.holder(820);
    var t = r.tick();
    t.catchHeld(p, r.hero, false);
    r.step(.{});
    try testing.expectEqualStrings("held", r.state());
    t.throwHeld(p, 6);
    r.step(.{});
    try testing.expectEqualStrings("thrown", r.state());
    // Placed from the holder by its frames: 24 behind it, facing the holder.
    try testing.expectEqual(@as(i32, 820 - 24), r.player().position.x.whole());
    // Its first frame's 5 ticks, then 3 a frame: at the end of the third frame it falls ahead.
    var fell_at: ?usize = null;
    for (0..20) |i| {
        r.step(.{});
        if (std.mem.eql(u8, r.state(), "knocked_down")) {
            fell_at = i;
            break;
        }
    }
    try testing.expectEqual(@as(?usize, 10), fell_at);
    try testing.expect(r.player().holder == null and r.w.get(p).?.holding == null);
    try testing.expectEqual(@as(i16, 80), r.player().health);
    for (0..60) |_| {
        r.step(.{});
        if (r.player().health != 80) break;
    }
    try testing.expectEqual(@as(i16, 74), r.player().health);
}

test "thrown, C and up land it on its feet, the throw's damage spared" {
    var r = try Round.init();
    defer r.deinit();
    const p = try r.holder(820);
    var t = r.tick();
    t.catchHeld(p, r.hero, false);
    r.step(.{});
    t.throwHeld(p, 6);
    for (0..12) |_| r.step(.{});
    try testing.expectEqualStrings("knocked_down", r.state());
    r.step(.{ .pad1 = .{ .c = true, .up = true } });
    var landed = false;
    for (0..60) |_| {
        r.step(.{});
        if (std.mem.eql(u8, r.state(), "land")) landed = true;
    }
    try testing.expect(landed);
    try testing.expectEqual(@as(i16, 80), r.player().health);
}

test "a player takes one blow or catch a tick: the first" {
    var r = try Round.init();
    defer r.deinit();
    const p = try r.holder(780);
    var t = r.tick();
    try testing.expect(t.catchable(r.hero));
    t.catchHeld(p, r.hero, true);
    try testing.expect(!t.catchable(r.hero));
    try testing.expect(!t.struck(r.hero, .{ .attacker = p, .damage = 4, .reaction = .knock_down, .push = .zero }));
    r.step(.{});
    try testing.expectEqualStrings("held_behind", r.state());
    try testing.expect(t.catchable(r.hero));
}

/// An enemy of `kind` at `x` on the player's depth, facing `facing`, in its state `state` from
/// its next tick, after the player.
fn enemyAt(r: *Round, comptime kind: []const u8, x: i32, facing: entity.Facing, state: anytype) !Handle {
    const h = try r.w.spawn(&r.f.kinds, r.f.kinds.find(kind).?, .pixels(x, 64, 160), facing);
    const m = &@field(r.w.get(h).?.mind, kind);
    m.state = state;
    m.body.fresh = true;
    m.body.target = r.hero;
    return h;
}

test "a stalker lurks beside the player, sneaks up on its back and holds it; a blow frees it" {
    var r = try Round.init();
    defer r.deinit();
    const s = try enemyAt(&r, "stalker", 760, .right, .lurk);
    r.w.get(s).?.spawn.offset_x = 40;
    // At its place, the player's back turned to it: it sneaks up and grabs.
    var sneaked = false;
    var grabbed_at: ?usize = null;
    for (0..60) |i| {
        r.step(.{});
        const st = r.w.get(s).?.mind.stalker.state;
        if (st == .sneak) sneaked = true;
        if (st == .grab) {
            grabbed_at = i;
            break;
        }
    }
    try testing.expect(sneaked and grabbed_at != null);
    r.step(.{});
    try testing.expectEqualStrings("held_behind", r.state());
    // Held its `held_ahead` ahead of the stalker, a pixel nearer the back.
    r.step(.{});
    const at = r.w.get(s).?.position;
    try testing.expectEqual(at.x.whole() + 16, r.player().position.x.whole());
    try testing.expectEqual(at.depth.whole() - 1, r.player().position.depth.whole());
    // A blow on it frees the player.
    var t = r.tick();
    try testing.expect(t.struck(s, .{ .attacker = r.hero, .damage = 1, .reaction = .reel, .push = .zero }));
    try testing.expect(r.player().holder == null and r.w.get(s).?.holding == null);
    r.step(.{});
    try testing.expectEqualStrings("ready", r.state());
}

test "a stalker coming at a player who faces it takes up the fight again" {
    var r = try Round.init();
    defer r.deinit();
    const s = try enemyAt(&r, "stalker", 760, .right, .sneak);
    r.player().facing = .left;
    r.step(.{});
    r.step(.{});
    try testing.expect(r.w.get(s).?.mind.stalker.state == .approach);
}

test "Signal walks into the player, holds it and throws it over its head, the throw its power" {
    var r = try Round.init();
    defer r.deinit();
    const g = try enemyAt(&r, "signal", 860, .left, .approach);
    var seen: [3]bool = @splat(false);
    for (0..160) |_| {
        r.step(.{});
        for ([_][]const u8{ "held", "thrown", "knocked_down" }, &seen) |name, *b| {
            if (std.mem.eql(u8, r.state(), name)) b.* = true;
        }
        if (seen[2] and r.player().health != 80) break;
    }
    try testing.expect(seen[0] and seen[1] and seen[2]);
    try testing.expectEqual(@as(i16, 72), r.player().health);
    try testing.expect(r.w.get(g).?.holding == null);
}

test "Signal placed to slide, level with the player, slides in with a kick that knocks it down" {
    var r = try Round.init();
    defer r.deinit();
    const g = try enemyAt(&r, "signal", 900, .left, .size_up);
    r.w.get(g).?.spawn.traits.slides = true;
    var slid = false;
    for (0..80) |_| {
        r.step(.{});
        if (r.w.get(g).?.mind.signal.state == .slide) slid = true;
        if (std.mem.eql(u8, r.state(), "knocked_down")) break;
    }
    try testing.expect(slid);
    try testing.expectEqualStrings("knocked_down", r.state());
    for (0..60) |_| r.step(.{});
    try testing.expectEqual(@as(i16, 72), r.player().health);
}

test "a pipe Galsia takes up its pipe, holds it frame by frame, and knocked down lets it fall" {
    var r = try Round.init();
    defer r.deinit();
    const g = try enemyAt(&r, "galsia_pipe", 900, .left, .approach);
    r.w.get(g).?.spawn.offset_x = 64;
    r.step(.{});
    // Its pipe, in the weapons' places, taken up (noted as a pick-up), unseen until in the hand.
    const pipe_h = r.w.handleAt(world_mod.World.weapon_places.from).?;
    try testing.expect(r.w.get(pipe_h).?.holder.?.eql(g));
    try testing.expectEqual(@as(usize, 1), r.out.pickups.len);
    r.step(.{});
    try testing.expectEqualStrings("held", behaviours.stateName(&r.w.get(pipe_h).?.mind).?);
    // In its walk's hand: 9 behind it (it faces left: to its right), 60 or 61 up, behind it.
    for (0..3) |_| {
        const e = r.w.get(g).?;
        const w = r.w.get(pipe_h).?;
        try testing.expectEqual(e.position.x.whole() + 9, w.position.x.whole());
        try testing.expect(e.position.height.whole() - w.position.height.whole() >= 60);
        try testing.expectEqual(e.position.depth.whole() - 1, w.position.depth.whole());
        r.step(.{});
    }
    // A new life knocks it back: its pipe falls, and it fights on as a Galsia, its blows its own.
    var t = r.tick();
    t.knockBack();
    r.step(.{});
    try testing.expectEqualStrings("galsia", r.f.kinds.get(r.w.get(g).?.kind.?).name());
    try testing.expectEqual(@as(u8, 12), r.w.get(g).?.power);
    try testing.expectEqualStrings("falling", behaviours.stateName(&r.w.get(pipe_h).?.mind).?);
    for (0..40) |_| r.step(.{});
    try testing.expectEqualStrings("lying", behaviours.stateName(&r.w.get(pipe_h).?.mind).?);
    try testing.expectEqual(@as(i32, 160), r.w.get(pipe_h).?.position.height.whole());
}

test "a Galsia behind a shutter: unseen until its player comes near, then the slats roll, it drops" {
    var r = try Round.init();
    defer r.deinit();
    const g = try enemyAt(&r, "galsia", 1000, .left, .shutter_entry);
    r.w.get(g).?.flags.hidden = true;
    r.step(.{});
    // Its shutter where it stood, and five slats over it; it waits beside and up behind it.
    var slats: usize = 0;
    for (&r.w.entities) |*e| if (e.alive() and std.mem.eql(u8, r.f.kinds.get(e.kind.?).name(), "shutter")) {
        slats += 1;
    };
    try testing.expectEqual(@as(usize, 6), slats);
    try testing.expectEqual(@as(i32, 1032), r.w.get(g).?.position.x.whole());
    try testing.expectEqual(@as(i32, 160 - 18), r.w.get(g).?.position.height.whole());
    for (0..10) |_| r.step(.{});
    try testing.expect(r.w.get(g).?.flags.hidden);
    // The player near: it shows; the slats roll a while, then it drops in and fights.
    r.player().position.x = .pixels(970);
    r.step(.{});
    try testing.expect(!r.w.get(g).?.flags.hidden);
    var down_at: ?usize = null;
    for (0..120) |i| {
        r.step(.{});
        if (r.w.get(g).?.mind.galsia.state != .shutter_entry) {
            down_at = i;
            break;
        }
    }
    try testing.expect(down_at != null and down_at.? > 64);
    try testing.expectEqual(@as(i32, 160), r.w.get(g).?.position.height.whole());
    try testing.expectEqual(world_mod.Entrance.close_in, r.w.get(g).?.spawn.entrance);
}

test "a breakable stops the player at its side; a blow on the screen breaks it: its item, its pieces, its blink" {
    var r = try Round.init();
    defer r.deinit();
    const b = try r.w.spawnWithin(&r.f.kinds, r.f.kinds.find("breakable").?, 2, 34, .pixels(870, 64, 160), .right);
    var t = r.tick();
    t.give(b, r.f.kinds.find("apple").?);
    r.step(.{});
    try testing.expectEqualStrings("s1", behaviours.traceName(&r.w.get(b).?.mind).?);
    try testing.expect(r.w.get(b).?.flags.solid);
    // Walking right, the player stops against its side, 28 pixels from its place.
    for (0..20) |_| r.step(.{ .pad1 = .{ .right = true } });
    try testing.expectEqual(@as(i32, 842), r.player().position.x.whole());
    r.step(.{});
    // The jab's blow breaks it: the apple where it stood, in the items' places; its pieces after.
    r.step(b_pad);
    for (0..3) |_| r.step(.{});
    try testing.expectEqualStrings("breaking", behaviours.stateName(&r.w.get(b).?.mind).?);
    try testing.expect(!r.w.get(b).?.flags.solid);
    const item = r.w.handleAt(World.item_places.from).?;
    try testing.expectEqualStrings("apple", r.f.kinds.get(r.w.get(item).?.kind.?).name());
    try testing.expectEqual(@as(i32, 870), r.w.get(item).?.position.x.whole());
    try testing.expectEqualStrings("lying", behaviours.stateName(&r.w.get(item).?.mind).?);
    var pieces: usize = 0;
    for (World.item_places.from + 1..World.item_places.to) |i| {
        const ph = r.w.handleAt(i) orelse continue;
        try testing.expectEqualStrings("s2", behaviours.traceName(&r.w.get(ph).?.mind).?);
        pieces += 1;
    }
    try testing.expectEqual(@as(usize, 3), pieces);
    // The pieces fall and go; it blinks 18 ticks and goes.
    for (0..20) |_| r.step(.{});
    try testing.expect(r.w.get(b) == null);
    for (World.item_places.from + 1..World.item_places.to) |i| try testing.expect(r.w.handleAt(i) == null);
}

test "an item picked up gives what it gives and goes: health up to the most, points" {
    var r = try Round.init();
    defer r.deinit();
    r.player().health = 70;
    const a = try r.w.spawnItem(&r.f.kinds, r.f.kinds.find("apple").?, .pixels(810, 64, 160));
    r.step(.{});
    r.step(b_pad);
    try testing.expectEqualStrings("pick_up", r.state());
    try testing.expect(r.w.get(a) == null);
    try testing.expectEqual(@as(i16, 80), r.player().health);
    for (0..10) |_| r.step(.{});
    _ = try r.w.spawnItem(&r.f.kinds, r.f.kinds.find("gold").?, .pixels(810, 64, 160));
    r.step(.{});
    r.step(b_pad);
    try testing.expectEqual(@as(u32, 5000), r.w.players[0].score);
}

test "a knife Galsia closes in, sizes up, stabs near; far it throws its knife, which flies and knocks the player down" {
    var r = try Round.init();
    defer r.deinit();
    const g = try enemyAt(&r, "galsia_knife", 860, .left, .choose);
    r.w.get(g).?.spawn.offset_x = 40;
    var stabbed = false;
    for (0..80) |_| {
        r.step(.{});
        const st = behaviours.stateName(&r.w.get(g).?.mind).?;
        if (std.mem.eql(u8, st, "stab")) stabbed = true;
        if (r.player().health < 80) break;
    }
    try testing.expect(stabbed);
    try testing.expect(r.player().health < 80);
    // Far, level with the player: it throws its knife, and takes up another.
    var r2 = try Round.init();
    defer r2.deinit();
    const g2 = try enemyAt(&r2, "galsia_knife", 1000, .left, .choose);
    r2.w.get(g2).?.spawn.offset_x = 160;
    var flew = false;
    for (0..120) |_| {
        r2.step(.{});
        for (World.weapon_places.from..World.weapon_places.to) |i| {
            const kh = r2.w.handleAt(i) orelse continue;
            if (std.mem.eql(u8, behaviours.stateName(&r2.w.get(kh).?.mind).?, "flying")) flew = true;
        }
        if (std.mem.eql(u8, r2.state(), "knocked_down")) break;
    }
    try testing.expect(flew);
    try testing.expectEqualStrings("knocked_down", r2.state());
    try testing.expectEqual(@as(i16, 75), r2.player().health);
}

test "a brawler: struck, it reels a tick later; placed to, it shrugs the blow off, then closes in and punches" {
    var r = try Round.init();
    defer r.deinit();
    const b = try enemyAt(&r, "brawler", 830, .left, .stand);
    r.step(.{});
    // The jab lands: hit at its tick, the reel from the next, the blow's damage then.
    r.step(b_pad);
    var hit_at: ?usize = null;
    var reel_at: ?usize = null;
    for (0..6) |i| {
        r.step(.{});
        const st = r.w.get(b).?.mind.brawler.state;
        if (st == .hit and hit_at == null) hit_at = i;
        if (st == .reel and reel_at == null) reel_at = i;
    }
    try testing.expect(hit_at != null and reel_at != null);
    try testing.expectEqual(hit_at.? + 1, reel_at.?);
    // Unflinching: it shrugs the blow off (its damage taken), then closes in and punches the
    // player down.
    var r2 = try Round.init();
    defer r2.deinit();
    const b2 = try enemyAt(&r2, "brawler", 830, .left, .stand);
    r2.w.get(b2).?.spawn.traits.unflinching = true;
    r2.step(.{});
    r2.step(b_pad);
    var shrugged = false;
    for (0..200) |_| {
        r2.step(.{});
        if (r2.w.get(b2).?.mind.brawler.state == .shrug_off) shrugged = true;
        if (std.mem.eql(u8, r2.state(), "knocked_down")) break;
    }
    try testing.expect(shrugged);
    try testing.expect(r2.w.get(b2).?.health < 12);
    try testing.expectEqualStrings("knocked_down", r2.state());
}

test "Antonio comes in: on the status bar from his first tick; off the screen he walks in, his boomerang in hand" {
    var r = try Round.init();
    defer r.deinit();
    const h = try r.w.spawnEnemy(&r.f.kinds, r.f.kinds.find("antonio").?, .pixels(768 + 328, 16, 160), .{ .bar = 4 });
    r.step(.{});
    try testing.expectEqual(@as(?u8, 4), r.w.boss_bar);
    try testing.expect(r.w.bosses[0].?.eql(h));
    const e = r.w.get(h).?;
    try testing.expectEqual(@as(i16, 24), e.health);
    try testing.expectEqualStrings("walk", behaviours.stateName(&e.mind).?);
    r.step(.{});
    // Drawn off the screen's right side: in at 4 pixels a tick across, and in depth by the
    // player's (from the depths' lower half, up).
    try testing.expectEqual(@as(i32, -4 << 16), e.velocity.x.raw);
    try testing.expectEqual(@as(i32, -4 << 16), e.velocity.depth.raw);
    try testing.expectEqual(entity.Facing.left, e.facing);
    // His boomerang in his hand: behind him, up.
    const b = r.w.get(r.w.handleAt(h.index + 1).?).?;
    try testing.expectEqualStrings("in_hand", behaviours.stateName(&b.mind).?);
    try testing.expectEqual(e.position.x.whole() + 18, b.position.x.whole());
    try testing.expectEqual(@as(i32, 80), b.position.height.whole());
}

test "Antonio swings at a near player; a jab met then costs him its damage at his next tick, knocked back a while" {
    var r = try Round.init();
    defer r.deinit();
    const h = try r.w.spawnEnemy(&r.f.kinds, r.f.kinds.find("antonio").?, .pixels(830, 64, 160), .{});
    r.step(.{});
    r.step(b_pad);
    const e = r.w.get(h).?;
    try testing.expectEqualStrings("throw", behaviours.traceName(&e.mind).?);
    var hit_at: ?usize = null;
    for (0..4) |k| {
        r.step(.{});
        if (e.health < 24) {
            hit_at = k;
            break;
        }
    }
    try testing.expect(hit_at != null);
    try testing.expectEqual(@as(i16, 23), e.health);
    try testing.expectEqualStrings("knocked_back", behaviours.stateName(&e.mind).?);
    for (0..7) |_| r.step(.{});
    try testing.expectEqualStrings("knocked_back", behaviours.stateName(&e.mind).?);
    r.step(.{});
    try testing.expectEqualStrings("walk", behaviours.stateName(&e.mind).?);
}

test "Antonio throws his boomerang: it leaves his hand at his throw's third frame, flies out, turns, comes back" {
    var r = try Round.init();
    defer r.deinit();
    const h = try r.w.spawnEnemy(&r.f.kinds, r.f.kinds.find("antonio").?, .pixels(960, 64, 160), .{});
    r.step(.{});
    // Not near: level with the player, he throws (from the tick after).
    r.step(.{});
    r.step(.{});
    const e = r.w.get(h).?;
    try testing.expect(e.animation.index.? == r.f.kinds.get(e.kind.?).definition.animation("throw").?);
    const b = r.w.get(r.w.handleAt(h.index + 1).?).?;
    for (0..11) |_| r.step(.{});
    try testing.expectEqualStrings("in_hand", behaviours.stateName(&b.mind).?);
    r.step(.{});
    try testing.expectEqualStrings("out", behaviours.stateName(&b.mind).?);
    try testing.expectEqual(@as(i32, -14 << 16), b.velocity.x.raw);
    try testing.expect(b.missile != null);
    for (0..32) |_| r.step(.{});
    try testing.expectEqualStrings("back", behaviours.stateName(&b.mind).?);
}

//! The definition of a kind of entity (docs/content.md, `entities/NAME.json`): a character, an
//! enemy, a weapon, an item, a piece of scenery. It says what the world needs to make one and
//! what its behaviour reads (DESIGN.md W3: the states are code, their numbers are data):
//! - what it is: its family (for the traces), its team, the behaviour that drives it;
//! - its health, its palette, its gravity, whether it has a shadow;
//! - its numbers (speeds, ranges, durations) and its sounds, by the names its behaviour reads;
//! - its boxes, named, which the frames of its animations put in use;
//! - its animations: frames of the art (by full name), each shown for a number of logic ticks,
//!   with the boxes in use while it shows;
//! - its moves: an animation, the damage, the reaction of the one hit, its push, its sounds.
//!
//! The units are the world's (world/fixed.zig): pixels for the boxes, 1/65536 pixel for speeds
//! (per logic tick, 30 a second in play) and for gravity (added to the height's speed each
//! logic tick in the air).
const std = @import("std");
const json = @import("../formats/json.zig");
const art = @import("art.zig");

/// What an entity is, which decides what the semantic traces say of it (sor-remaster's
/// docs/traces.md).
pub const Family = enum { player, enemy, boss, projectile, weapon, item, scenery, effect, screen };

/// Whose side it is on: blows land on another team's entities (world/systems.zig says which).
pub const Team = enum { player, enemy, neutral };

/// A span of pixels on one axis, from `from` to `to`, both included.
pub const Span = struct {
    from: i16,
    to: i16,

    /// The span mirrored about the origin.
    pub fn mirrored(s: Span) Span {
        return .{ .from = -s.to, .to = -s.from };
    }
};

/// A box of the world: a span across, on the depth and in height (downward), from the entity's
/// place, for the entity facing right. Facing left, the span across is `x_left`, or `x`
/// mirrored about the place.
pub const Box = struct {
    name: []const u8,
    x: Span,
    x_left: ?Span = null,
    depth: Span,
    height: Span,

    pub fn across(b: *const Box, facing_left: bool) Span {
        if (!facing_left) return b.x;
        return b.x_left orelse b.x.mirrored();
    }
};

/// A frame of an animation: a sprite frame of the art, shown for `ticks` logic ticks, mirrored
/// (`flip`, besides the entity's facing) or not, with the boxes in use while it shows.
pub const Frame = struct {
    /// The sprite frame's full name (`galsia/003`).
    frame: []const u8,
    ticks: u8,
    flip: bool = false,
    /// The box the entity is struck in, and the box its blow strikes with, by their index in
    /// `Definition.boxes`.
    body: ?u8 = null,
    attack: ?u8 = null,
};

pub const Animation = struct {
    name: []const u8,
    /// After the last frame the first comes again; without, the last frame stays.
    loop: bool = false,
    frames: []const Frame,
};

/// What the one struck does.
pub const Reaction = enum {
    /// It staggers and recovers where it stands.
    reel,
    /// It is knocked off its feet.
    knock_down,
};

/// A blow or an action: an animation, and what its blow does when it lands.
pub const Move = struct {
    name: []const u8,
    provenance: []const u8 = "",
    /// The animation, by its index in `Definition.animations`.
    animation: u8,
    damage: u16 = 0,
    reaction: Reaction = .reel,
    /// The speed given to the one struck, across (away from the striker) and in height
    /// (negative: up), in 1/65536 pixel a logic tick.
    push_x: i32 = 0,
    push_height: i32 = 0,
    /// The sounds asked for when the move starts and when its blow lands, by the names of the
    /// sound content (DESIGN.md A1).
    sound: ?[]const u8 = null,
    hit_sound: ?[]const u8 = null,
};

/// A number the behaviour reads, by its name.
pub const Number = struct { name: []const u8, value: i32 };

/// A sound the behaviour asks for, by its role (`hurt`) and the sound content's name.
pub const Sound = struct { name: []const u8, sound: []const u8 };

pub const Definition = struct {
    /// The kind's name: the file's (`entities/galsia.json` is `galsia`), which the traces use.
    name: []const u8,
    provenance: []const u8 = "",
    family: Family,
    team: Team,
    /// The behaviour that drives it, by its name (world/behaviours.zig).
    behaviour: []const u8,
    health: u16 = 0,
    /// Added to its frames' palettes.
    palette: u2 = 0,
    /// Added to the height's speed each logic tick in the air, in 1/65536 pixel.
    gravity: i32 = 0,
    shadow: bool = false,
    numbers: []const Number = &.{},
    sounds: []const Sound = &.{},
    boxes: []const Box = &.{},
    animations: []const Animation = &.{},
    moves: []const Move = &.{},

    pub fn animation(d: *const Definition, name: []const u8) ?u8 {
        return indexOf(Animation, d.animations, name);
    }
    pub fn move(d: *const Definition, name: []const u8) ?u8 {
        return indexOf(Move, d.moves, name);
    }
    pub fn box(d: *const Definition, name: []const u8) ?u8 {
        return indexOf(Box, d.boxes, name);
    }
    pub fn number(d: *const Definition, name: []const u8) ?i32 {
        for (d.numbers) |n| if (std.mem.eql(u8, n.name, name)) return n.value;
        return null;
    }
    pub fn sound(d: *const Definition, name: []const u8) ?[]const u8 {
        for (d.sounds) |s| if (std.mem.eql(u8, s.name, name)) return s.sound;
        return null;
    }
};

fn indexOf(comptime T: type, items: []const T, name: []const u8) ?u8 {
    for (items, 0..) |it, i| if (std.mem.eql(u8, it.name, name)) return @intCast(i);
    return null;
}

/// The definitions' directory in the tree, and a definition's file.
pub const directory = "entities";

pub fn path(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, directory ++ "/{s}.json", .{name});
}

/// The most of each list a definition holds: they are numbered in a byte.
pub const max_items = 255;

// --- Reading ---------------------------------------------------------------------------------

/// Reads definition `name` from its file's parsed `root`, checking every value; the frames must
/// be `a`'s. A refusal names the field in the diagnostic.
pub fn read(arena: std.mem.Allocator, name: []const u8, root: json.Node, a: *const art.Art) json.Error!Definition {
    try root.only(&.{ "provenance", "family", "team", "behaviour", "health", "palette", "gravity", "shadow", "numbers", "sounds", "boxes", "animations", "moves" });
    var d: Definition = .{
        .name = name,
        .provenance = if (try root.opt("provenance")) |p| try p.string() else "",
        .family = try enumField(Family, try root.get("family")),
        .team = try enumField(Team, try root.get("team")),
        .behaviour = try (try root.get("behaviour")).string(),
    };
    if (!art.validName(d.behaviour)) return (try root.get("behaviour")).fail("not a behaviour's name (a-z, 0-9, _)");
    if (try root.opt("health")) |n| d.health = try n.int(u16);
    if (try root.opt("palette")) |n| d.palette = std.math.cast(u2, try n.int(i64)) orelse return n.fail("not 0 to 3");
    if (try root.opt("gravity")) |n| d.gravity = try n.int(i32);
    if (try root.opt("shadow")) |n| d.shadow = try n.boolean();

    if (try root.opt("numbers")) |node| {
        var it = try listed(node);
        const out = try arena.alloc(Number, it.count());
        for (out) |*x| {
            const e = (try it.next()).?;
            x.* = .{ .name = try checkedName(e.value, e.key), .value = try e.value.int(i32) };
        }
        d.numbers = out;
    }
    if (try root.opt("sounds")) |node| {
        var it = try listed(node);
        const out = try arena.alloc(Sound, it.count());
        for (out) |*x| {
            const e = (try it.next()).?;
            x.* = .{ .name = try checkedName(e.value, e.key), .sound = try soundName(e.value) };
        }
        d.sounds = out;
    }
    if (try root.opt("boxes")) |node| {
        var it = try listed(node);
        const out = try arena.alloc(Box, it.count());
        for (out) |*b| {
            const e = (try it.next()).?;
            try e.value.only(&.{ "x", "x_left", "depth", "height" });
            b.* = .{
                .name = try checkedName(e.value, e.key),
                .x = try span(try e.value.get("x")),
                .x_left = if (try e.value.opt("x_left")) |n| try span(n) else null,
                .depth = try span(try e.value.get("depth")),
                .height = try span(try e.value.get("height")),
            };
        }
        d.boxes = out;
    }
    if (try root.opt("animations")) |node| {
        var it = try listed(node);
        const out = try arena.alloc(Animation, it.count());
        for (out) |*an| {
            const e = (try it.next()).?;
            try e.value.only(&.{ "loop", "frames" });
            const frames_node = try e.value.get("frames");
            const n = try frames_node.len();
            if (n == 0) return frames_node.fail("no frame");
            if (n > max_items) return frames_node.fail("more than 255 frames");
            const frames = try arena.alloc(Frame, n);
            for (frames, 0..) |*f, i| f.* = try frame(try frames_node.at(i), &d, a);
            an.* = .{
                .name = try checkedName(e.value, e.key),
                .loop = if (try e.value.opt("loop")) |l| try l.boolean() else false,
                .frames = frames,
            };
        }
        d.animations = out;
    }
    if (try root.opt("moves")) |node| {
        var it = try listed(node);
        const out = try arena.alloc(Move, it.count());
        for (out) |*m| {
            const e = (try it.next()).?;
            try e.value.only(&.{ "provenance", "animation", "damage", "reaction", "push", "sound", "hit_sound" });
            const anim_node = try e.value.get("animation");
            m.* = .{
                .name = try checkedName(e.value, e.key),
                .provenance = if (try e.value.opt("provenance")) |p| try p.string() else "",
                .animation = d.animation(try anim_node.string()) orelse return anim_node.fail("no animation of this name"),
            };
            if (try e.value.opt("damage")) |x| m.damage = try x.int(u16);
            if (try e.value.opt("reaction")) |x| m.reaction = try enumField(Reaction, x);
            if (try e.value.opt("push")) |p| {
                try p.only(&.{ "x", "height" });
                if (try p.opt("x")) |x| m.push_x = try x.int(i32);
                if (try p.opt("height")) |x| m.push_height = try x.int(i32);
            }
            if (try e.value.opt("sound")) |x| m.sound = try soundName(x);
            if (try e.value.opt("hit_sound")) |x| m.hit_sound = try soundName(x);
        }
        d.moves = out;
    }
    return d;
}

/// An object of named records, at most `max_items` of them.
fn listed(node: json.Node) json.Error!json.Node.Fields {
    const it = try node.fields();
    if (it.count() > max_items) return node.fail("more than 255 records");
    return it;
}

fn checkedName(node: json.Node, key: []const u8) json.Error![]const u8 {
    if (!art.validName(key)) return node.fail("not a name (a-z, 0-9, _)");
    return key;
}

fn soundName(node: json.Node) json.Error![]const u8 {
    const s = try node.string();
    if (s.len == 0) return node.fail("an empty sound's name");
    return s;
}

fn enumField(comptime E: type, node: json.Node) json.Error!E {
    const s = try node.string();
    return std.meta.stringToEnum(E, s) orelse node.fail(comptime blk: {
        var text: []const u8 = "not one of";
        for (std.meta.fieldNames(E), 0..) |n, i| text = text ++ (if (i == 0) " " else ", ") ++ n;
        break :blk text;
    });
}

fn span(node: json.Node) json.Error!Span {
    if (try node.len() != 2) return node.fail("not [from, to]");
    const s: Span = .{ .from = try (try node.at(0)).int(i16), .to = try (try node.at(1)).int(i16) };
    if (s.from > s.to) return node.fail("from past to");
    return s;
}

fn frame(node: json.Node, d: *const Definition, a: *const art.Art) json.Error!Frame {
    try node.only(&.{ "frame", "ticks", "flip", "body", "attack" });
    const name_node = try node.get("frame");
    const name = try name_node.string();
    if (a.frame(name) == null) return name_node.fail("no sprite frame of this name");
    const ticks_node = try node.get("ticks");
    const ticks = try ticks_node.int(u8);
    if (ticks == 0) return ticks_node.fail("not 1 or more");
    return .{
        .frame = name,
        .ticks = ticks,
        .flip = if (try node.opt("flip")) |f| try f.boolean() else false,
        .body = try boxRef(node, "body", d),
        .attack = try boxRef(node, "attack", d),
    };
}

fn boxRef(node: json.Node, key: []const u8, d: *const Definition) json.Error!?u8 {
    const n = try node.opt(key) orelse return null;
    return d.box(try n.string()) orelse n.fail("no box of this name");
}

// --- Writing ---------------------------------------------------------------------------------

/// The file of `d`: its fields with sorted keys; the optional ones only when they are not their
/// defaults, so that a file read and written again keeps its bytes.
pub fn value(arena: std.mem.Allocator, d: *const Definition) error{OutOfMemory}!json.Value {
    var top: std.ArrayList(json.Field) = .empty;
    if (d.provenance.len != 0) try top.append(arena, .{ .key = "provenance", .value = .{ .str = d.provenance } });
    try top.append(arena, .{ .key = "family", .value = .{ .str = @tagName(d.family) } });
    try top.append(arena, .{ .key = "team", .value = .{ .str = @tagName(d.team) } });
    try top.append(arena, .{ .key = "behaviour", .value = .{ .str = d.behaviour } });
    if (d.health != 0) try top.append(arena, .{ .key = "health", .value = json.Value.num(d.health) });
    if (d.palette != 0) try top.append(arena, .{ .key = "palette", .value = json.Value.num(d.palette) });
    if (d.gravity != 0) try top.append(arena, .{ .key = "gravity", .value = json.Value.num(d.gravity) });
    if (d.shadow) try top.append(arena, .{ .key = "shadow", .value = .{ .bool = true } });

    if (d.numbers.len != 0) {
        const out = try arena.alloc(json.Field, d.numbers.len);
        for (out, d.numbers) |*o, n| o.* = .{ .key = n.name, .value = json.Value.num(n.value) };
        try top.append(arena, .{ .key = "numbers", .value = .{ .object = out } });
    }
    if (d.sounds.len != 0) {
        const out = try arena.alloc(json.Field, d.sounds.len);
        for (out, d.sounds) |*o, s| o.* = .{ .key = s.name, .value = .{ .str = s.sound } };
        try top.append(arena, .{ .key = "sounds", .value = .{ .object = out } });
    }
    if (d.boxes.len != 0) {
        const out = try arena.alloc(json.Field, d.boxes.len);
        for (out, d.boxes) |*o, b| {
            var fs: std.ArrayList(json.Field) = .empty;
            try fs.append(arena, .{ .key = "x", .value = try spanValue(arena, b.x) });
            if (b.x_left) |l| try fs.append(arena, .{ .key = "x_left", .value = try spanValue(arena, l) });
            try fs.append(arena, .{ .key = "depth", .value = try spanValue(arena, b.depth) });
            try fs.append(arena, .{ .key = "height", .value = try spanValue(arena, b.height) });
            o.* = .{ .key = b.name, .value = .{ .object = fs.items } };
        }
        try top.append(arena, .{ .key = "boxes", .value = .{ .object = out } });
    }
    if (d.animations.len != 0) {
        const out = try arena.alloc(json.Field, d.animations.len);
        for (out, d.animations) |*o, an| {
            const frames = try arena.alloc(json.Value, an.frames.len);
            for (frames, an.frames) |*v, f| {
                var fs: std.ArrayList(json.Field) = .empty;
                try fs.append(arena, .{ .key = "frame", .value = .{ .str = f.frame } });
                try fs.append(arena, .{ .key = "ticks", .value = json.Value.num(f.ticks) });
                if (f.flip) try fs.append(arena, .{ .key = "flip", .value = .{ .bool = true } });
                if (f.body) |b| try fs.append(arena, .{ .key = "body", .value = .{ .str = d.boxes[b].name } });
                if (f.attack) |b| try fs.append(arena, .{ .key = "attack", .value = .{ .str = d.boxes[b].name } });
                v.* = .{ .object = fs.items };
            }
            var fs: std.ArrayList(json.Field) = .empty;
            if (an.loop) try fs.append(arena, .{ .key = "loop", .value = .{ .bool = true } });
            try fs.append(arena, .{ .key = "frames", .value = .{ .array = frames } });
            o.* = .{ .key = an.name, .value = .{ .object = fs.items } };
        }
        try top.append(arena, .{ .key = "animations", .value = .{ .object = out } });
    }
    if (d.moves.len != 0) {
        const out = try arena.alloc(json.Field, d.moves.len);
        for (out, d.moves) |*o, m| {
            var fs: std.ArrayList(json.Field) = .empty;
            if (m.provenance.len != 0) try fs.append(arena, .{ .key = "provenance", .value = .{ .str = m.provenance } });
            try fs.append(arena, .{ .key = "animation", .value = .{ .str = d.animations[m.animation].name } });
            if (m.damage != 0) try fs.append(arena, .{ .key = "damage", .value = json.Value.num(m.damage) });
            if (m.reaction != .reel) try fs.append(arena, .{ .key = "reaction", .value = .{ .str = @tagName(m.reaction) } });
            if (m.push_x != 0 or m.push_height != 0) {
                var push: std.ArrayList(json.Field) = .empty;
                if (m.push_x != 0) try push.append(arena, .{ .key = "x", .value = json.Value.num(m.push_x) });
                if (m.push_height != 0) try push.append(arena, .{ .key = "height", .value = json.Value.num(m.push_height) });
                try fs.append(arena, .{ .key = "push", .value = .{ .object = push.items } });
            }
            if (m.sound) |s| try fs.append(arena, .{ .key = "sound", .value = .{ .str = s } });
            if (m.hit_sound) |s| try fs.append(arena, .{ .key = "hit_sound", .value = .{ .str = s } });
            o.* = .{ .key = m.name, .value = .{ .object = fs.items } };
        }
        try top.append(arena, .{ .key = "moves", .value = .{ .object = out } });
    }
    return .{ .object = top.items };
}

fn spanValue(arena: std.mem.Allocator, s: Span) error{OutOfMemory}!json.Value {
    const out = try arena.alloc(json.Value, 2);
    out[0] = json.Value.num(s.from);
    out[1] = json.Value.num(s.to);
    return .{ .array = out };
}

// --- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

/// A synthetic art set with two frames, for the tests.
fn testArt() art.Art {
    const S = struct {
        const px: [4]u8 = @splat(1);
        const frames = [_]art.Frame{
            .{ .name = "000", .file = "000.png", .width = 2, .height = 2, .origin_x = 1, .origin_y = 2, .pixels = &px },
            .{ .name = "001", .file = "001.png", .width = 2, .height = 2, .origin_x = 1, .origin_y = 2, .pixels = &px },
        };
        const sets = [_]art.ArtSet{.{ .name = "dummy", .frames = &frames }};
    };
    return .{ .sets = &S.sets };
}

const sample =
    \\{
    \\  "animations": {
    \\    "punch": {
    \\      "frames": [
    \\        {
    \\          "body": "body",
    \\          "frame": "dummy/000",
    \\          "ticks": 3
    \\        },
    \\        {
    \\          "attack": "fist",
    \\          "body": "body",
    \\          "flip": true,
    \\          "frame": "dummy/001",
    \\          "ticks": 4
    \\        }
    \\      ]
    \\    },
    \\    "stand": {
    \\      "frames": [
    \\        {
    \\          "body": "body",
    \\          "frame": "dummy/000",
    \\          "ticks": 8
    \\        }
    \\      ],
    \\      "loop": true
    \\    }
    \\  },
    \\  "behaviour": "sparring",
    \\  "boxes": {
    \\    "body": {
    \\      "depth": [-3, 3],
    \\      "height": [-56, 0],
    \\      "x": [-8, 8]
    \\    },
    \\    "fist": {
    \\      "depth": [-3, 3],
    \\      "height": [-48, -40],
    \\      "x": [10, 30],
    \\      "x_left": [-31, -11]
    \\    }
    \\  },
    \\  "family": "enemy",
    \\  "gravity": 24576,
    \\  "health": 32,
    \\  "moves": {
    \\    "punch": {
    \\      "animation": "punch",
    \\      "damage": 4,
    \\      "hit_sound": "punch hits",
    \\      "push": {
    \\        "x": 65536
    \\      },
    \\      "reaction": "knock_down",
    \\      "sound": "punch swing"
    \\    }
    \\  },
    \\  "numbers": {
    \\    "reach": 28,
    \\    "walk_speed": 65536
    \\  },
    \\  "palette": 1,
    \\  "provenance": "synthetic",
    \\  "shadow": true,
    \\  "sounds": {
    \\    "hurt": "enemy hit"
    \\  },
    \\  "team": "enemy"
    \\}
    \\
;

test "a definition reads, names its parts, and writes the same bytes again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = testArt();
    var diag: json.Diagnostic = .{};
    const root = try json.parse(arena, "entities/dummy.json", sample, &diag);
    const d = read(arena, "dummy", root, &a) catch |e| {
        std.debug.print("{f}\n", .{&diag});
        return e;
    };
    try testing.expectEqualStrings("dummy", d.name);
    try testing.expectEqual(Family.enemy, d.family);
    try testing.expectEqual(@as(u16, 32), d.health);
    try testing.expectEqual(@as(?i32, 65536), d.number("walk_speed"));
    try testing.expectEqualStrings("enemy hit", d.sound("hurt").?);
    const punch = d.moves[d.move("punch").?];
    try testing.expectEqual(Reaction.knock_down, punch.reaction);
    try testing.expectEqual(@as(i32, 65536), punch.push_x);
    const frames = d.animations[punch.animation].frames;
    try testing.expectEqual(@as(?u8, d.box("fist")), frames[1].attack);
    try testing.expect(frames[1].flip and frames[0].attack == null);
    const fist = d.boxes[d.box("fist").?];
    try testing.expectEqual(Span{ .from = -31, .to = -11 }, fist.across(true));
    const body = d.boxes[d.box("body").?];
    try testing.expectEqual(Span{ .from = -8, .to = 8 }, body.across(true));
    try testing.expect(d.animations[d.animation("stand").?].loop);

    const text = try json.write(arena, try value(arena, &d));
    try testing.expectEqualStrings(sample, text);
}

test "a refused definition names its field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = testArt();
    const cases = [_]struct { text: []const u8, want: []const u8 }{
        .{ .text = "{\"family\": \"enemy\", \"team\": \"enemy\", \"behaviour\": \"x\", \"helth\": 3}", .want = "entities/dummy.json: field helth: not a field of this record" },
        .{ .text = "{\"family\": \"monster\", \"team\": \"enemy\", \"behaviour\": \"x\"}", .want = "entities/dummy.json: field family: not one of player, enemy, boss, projectile, weapon, item, scenery, effect, screen" },
        .{ .text = "{\"family\": \"enemy\", \"team\": \"enemy\", \"behaviour\": \"x\", \"animations\": {\"a\": {\"frames\": [{\"frame\": \"dummy/009\", \"ticks\": 1}]}}}", .want = "entities/dummy.json: field animations.a.frames[0].frame: no sprite frame of this name" },
        .{ .text = "{\"family\": \"enemy\", \"team\": \"enemy\", \"behaviour\": \"x\", \"animations\": {\"a\": {\"frames\": [{\"frame\": \"dummy/000\", \"ticks\": 0}]}}}", .want = "entities/dummy.json: field animations.a.frames[0].ticks: not 1 or more" },
        .{ .text = "{\"family\": \"enemy\", \"team\": \"enemy\", \"behaviour\": \"x\", \"animations\": {\"a\": {\"frames\": [{\"frame\": \"dummy/000\", \"ticks\": 1, \"body\": \"torso\"}]}}}", .want = "entities/dummy.json: field animations.a.frames[0].body: no box of this name" },
        .{ .text = "{\"family\": \"enemy\", \"team\": \"enemy\", \"behaviour\": \"x\", \"boxes\": {\"b\": {\"x\": [3, 1], \"depth\": [0, 0], \"height\": [0, 0]}}}", .want = "entities/dummy.json: field boxes.b.x: from past to" },
        .{ .text = "{\"family\": \"enemy\", \"team\": \"enemy\", \"behaviour\": \"x\", \"moves\": {\"m\": {\"animation\": \"none\"}}}", .want = "entities/dummy.json: field moves.m.animation: no animation of this name" },
        .{ .text = "{\"family\": \"enemy\", \"team\": \"enemy\", \"behaviour\": \"x\", \"palette\": 4}", .want = "entities/dummy.json: field palette: not 0 to 3" },
        .{ .text = "{\"family\": \"enemy\", \"team\": \"enemy\", \"behaviour\": \"Big\"}", .want = "entities/dummy.json: field behaviour: not a behaviour's name (a-z, 0-9, _)" },
    };
    for (cases) |c| {
        var diag: json.Diagnostic = .{};
        const root = try json.parse(arena, "entities/dummy.json", c.text, &diag);
        try testing.expectError(error.BadAsset, read(arena, "dummy", root, &a));
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings(c.want, try std.fmt.bufPrint(&buf, "{f}", .{&diag}));
    }
}

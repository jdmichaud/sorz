//! The accepted differences: where sorz differs from sor-remaster (the original) on purpose, by the
//! user's choice. The exact step (PLAN item 23) revisits them. Each has its name, its reason, and
//! how to recognise it:
//! - in the pictures, sorz's sprites drawn again as the original would draw them (`redraws`, each
//!   a way): a pixel that differs belongs to the difference when one of those pictures shows
//!   there what the reference shows. A picture whose differing pixels all belong to accepted
//!   differences is reported as such; it is not a difference, and the reach goes on past it. A
//!   difference may name the lines its sprites show on (`lines`): its redraws draw them there,
//!   and only the pixels on those lines belong to it;
//! - in the traces, the entities whose own events the comparison leaves out (`leaves_out`: by
//!   their spawn's kind and state), so that they neither differ nor take the numbers the others
//!   are compared by.
const std = @import("std");
const sorz = @import("sorz");

const Sprite = sorz.render.Sprite;
const Lines = sorz.render.Lines;
const Frame = sorz.content.art.Frame;
const Kinds = sorz.world.Kinds;

/// What a redraw knows of sorz's picture besides its sprites.
pub const Context = struct {
    /// The frame of the shadows on the ground.
    shadow: ?*const Frame,
    /// The kinds of entity: their frames tell a sprite's kind.
    kinds: *const Kinds,
    /// The status bar's own lines in play, and the window's lines in the picture (the status
    /// bar's, with the bosses' bars' row while it shows).
    bar_lines: u16 = 0,
    window: Lines = .{},
};

/// sorz's sprites (`sprites`, back to front) as the original would draw them, into `out` (as
/// many at most): their count.
pub const Redraw = *const fn (sprites: []const Sprite, c: Context, out: []Sprite) usize;

/// The entities a trace's comparison leaves out: those spawned of `kind` in `state`.
pub const LeftOut = struct { kind: []const u8, state: []const u8 };

pub const Accepted = struct {
    name: []const u8,
    reason: []const u8,
    redraws: []const Redraw,
    leaves_out: ?LeftOut = null,
    /// The lines its redraws' sprites show on, the only ones whose pixels belong to it (null
    /// from it: it has none in the picture); none: the sprites' own lines, every line.
    lines: ?*const fn (c: Context) ?Lines = null,
};

pub const list = [_]Accepted{
    .{
        .name = "shadows over sprites",
        .reason = "sorz draws a shadow just behind its entity; the original's shadow is an object of its own, drawn at its entity's depth in its place's order, so it may cover another entity (a thrown Galsia's hand and feet on the ground), or go behind one its entity is in front of (an acrobat's foot beside another's shadow). sorz's way is the user's choice (2026-10-05)",
        .redraws = &.{ shadowsInFront, shadowsBehind },
    },
    .{
        .name = "objects past a band's 15",
        .reason = "the original draws at most 15 objects in a band of depths, and one past them neither shows nor steps its animation at that tick (decision D4): round 3's raindrops, about twenty in one band, blink out of step there; and its shadows are objects of their own in eight places they share with the weapons, each entity taking one at each of its turns, so that a shadow may find none (the raindrops', a crowd's: a trio of acrobats knocked down at once). sorz draws every raindrop and every shadow, its shadows taking no place: more correct, the user's rule (2026-10-05)",
        .redraws = &.{ withoutRaindrops, raindropsShown, shadowsOut },
        .leaves_out = .{ .kind = raindrop_kind, .state = raindrop_state },
    },
    .{
        .name = "sprites over the bosses' bar row",
        .reason = "the original draws a player over the row the bosses' bars add below the status bar (round 4's new life dropping in under its boss's bar); sorz shows no sprite over the status bar, that row included: the cleaner picture, kept (2026-10-05)",
        .redraws = &.{playersOnly},
        .lines = bossesRow,
    },
};

/// The row the bosses' bars add below the status bar's own lines, while it shows.
fn bossesRow(c: Context) ?Lines {
    if (c.window.bottom <= c.bar_lines) return null;
    return .{ .top = c.bar_lines, .bottom = c.window.bottom };
}

/// The players' sprites alone (by their frames' kinds).
fn playersOnly(sprites: []const Sprite, c: Context, out: []Sprite) usize {
    var n: usize = 0;
    for (sprites) |s| {
        if (!ofPlayer(c.kinds, s.frame)) continue;
        out[n] = s;
        n += 1;
    }
    return n;
}

/// Whether `frame` is a frame of a player's kind.
fn ofPlayer(kinds: *const Kinds, frame: *const Frame) bool {
    for (kinds.list) |*k| {
        if (k.family() != .player) continue;
        for (k.frames) |animation| for (animation) |f| {
            if (f == frame) return true;
        };
    }
    return false;
}

/// The shadows in front of every other sprite: the pixels where sorz shows a sprite and the
/// reference shows a shadow over it.
fn shadowsInFront(sprites: []const Sprite, c: Context, out: []Sprite) usize {
    return shadowsFirst(sprites, c, out, false);
}

/// The shadows behind every other sprite: the pixels where sorz shows a shadow over a sprite the
/// reference shows in front of it.
fn shadowsBehind(sprites: []const Sprite, c: Context, out: []Sprite) usize {
    return shadowsFirst(sprites, c, out, true);
}

/// The shadows drawn first (behind) or last, the other sprites in their order.
fn shadowsFirst(sprites: []const Sprite, c: Context, out: []Sprite, first: bool) usize {
    var n: usize = 0;
    for ([_]bool{ first, !first }) |shadows| for (sprites) |s| {
        const is_shadow = if (c.shadow) |f| s.frame == f else false;
        if (is_shadow != shadows) continue;
        out[n] = s;
        n += 1;
    };
    return n;
}

/// The raindrops: entities of the rain's kind, made in its falling state (the rain itself is
/// the same kind, in its others); their frames, none then the drops.
const raindrop_kind = "rain";
const raindrop_state = "s3";

/// The raindrop's frames (its animation's: none, the drops), if the content has the rain.
fn raindropFrames(c: Context) ?[2]*const Frame {
    const id = c.kinds.find(raindrop_kind) orelse return null;
    const k = c.kinds.get(id);
    if (k.frames.len == 0 or k.frames[0].len != 2) return null;
    return .{ k.frames[0][0], k.frames[0][1] };
}

/// Without the raindrops: the pixels where sorz shows a raindrop the reference does not.
fn withoutRaindrops(sprites: []const Sprite, c: Context, out: []Sprite) usize {
    const frames = raindropFrames(c) orelse return copy(sprites, out);
    var n: usize = 0;
    for (sprites) |s| {
        if (s.frame == frames[0] or s.frame == frames[1]) continue;
        out[n] = s;
        n += 1;
    }
    return n;
}

/// Every raindrop in its drops' frame: the pixels where the reference shows a raindrop that
/// sorz shows in its blank frame.
fn raindropsShown(sprites: []const Sprite, c: Context, out: []Sprite) usize {
    const frames = raindropFrames(c) orelse return copy(sprites, out);
    for (sprites, out[0..sprites.len]) |s, *o| {
        o.* = s;
        if (s.frame == frames[0]) o.frame = frames[1];
    }
    return sprites.len;
}

/// Without the shadows: the original's shadows, objects of their own in eight places the
/// weapons, the raindrops and every entity's passing shadow take too, may find none (the pixels
/// where sorz shows a shadow the reference does not).
fn shadowsOut(sprites: []const Sprite, c: Context, out: []Sprite) usize {
    const shadow = c.shadow orelse return copy(sprites, out);
    var n: usize = 0;
    for (sprites) |s| {
        if (s.frame == shadow) continue;
        out[n] = s;
        n += 1;
    }
    return n;
}

fn copy(sprites: []const Sprite, out: []Sprite) usize {
    @memcpy(out[0..sprites.len], sprites);
    return sprites.len;
}

test "shadows over sprites: the shadows go in front, the other sprites keep their order" {
    const frame = std.mem.zeroInit(Frame, .{ .name = "a", .file = "", .width = 1, .height = 1, .origin_x = 0, .origin_y = 0, .pixels = &[_]u8{1} });
    const shadow = std.mem.zeroInit(Frame, .{ .name = "shadow", .file = "", .width = 1, .height = 1, .origin_x = 0, .origin_y = 0, .pixels = &[_]u8{1} });
    const sprites = [_]Sprite{ .of(&frame, 1, 0), .of(&shadow, 2, 0), .of(&frame, 3, 0) };
    var out: [3]Sprite = undefined;
    const kinds: Kinds = .{};
    try std.testing.expectEqual(@as(usize, 3), shadowsInFront(&sprites, .{ .shadow = &shadow, .kinds = &kinds }, &out));
    try std.testing.expectEqual([3]i32{ 1, 3, 2 }, [3]i32{ out[0].x, out[1].x, out[2].x });
}

//! The accepted differences: where sorz differs from sor-remaster (the original) on purpose, by the
//! user's choice. The exact step (PLAN item 23) revisits them. Each has its name, its reason, and
//! how to recognise it:
//! - in the pictures, sorz's sprites drawn again as the original would draw them (`redraws`, each
//!   a way): a pixel that differs belongs to the difference when one of those pictures shows
//!   there what the reference shows. A picture whose differing pixels all belong to accepted
//!   differences is reported as such; it is not a difference, and the reach goes on past it. A
//!   difference may name the lines its sprites show on (`lines`): its redraws draw them there,
//!   and only the pixels on those lines belong to it;
//! - in the pictures, the sprites whose pieces' pixels belong to the difference wherever they
//!   differ (`covers`): where the reference draws them wrong (its bug), whatever it shows there;
//! - in the traces, the entities whose own events the comparison leaves out (`leaves_out`: by
//!   their spawn's kind and state), so that they neither differ nor take the numbers the others
//!   are compared by.
const std = @import("std");
const sorz = @import("sorz");

const Sprite = sorz.render.Sprite;
const Lines = sorz.render.Lines;
const Frame = sorz.content.art.Frame;
const Kinds = sorz.world.Kinds;
const SpriteInfo = sorz.world.output.SpriteInfo;

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
    /// What the world's sprites, the first of a picture's, were drawn for (their entities'
    /// places and depths), when known.
    info: []const SpriteInfo = &.{},
};

/// sorz's sprites (`sprites`, back to front) as the original would draw them, into `out` (as
/// many at most): their count.
pub const Redraw = *const fn (sprites: []const Sprite, c: Context, out: []Sprite) usize;

/// The entities a trace's comparison leaves out: those spawned of `kind` in `state`.
pub const LeftOut = struct { kind: []const u8, state: []const u8 };

/// Whether the pixels within sorz's sprite `s`'s pieces belong to the difference.
pub const Covers = *const fn (s: Sprite, c: Context) bool;

pub const Accepted = struct {
    name: []const u8,
    reason: []const u8,
    redraws: []const Redraw = &.{},
    leaves_out: ?LeftOut = null,
    /// The lines its redraws' sprites show on, the only ones whose pixels belong to it (null
    /// from it: it has none in the picture); none: the sprites' own lines, every line.
    lines: ?*const fn (c: Context) ?Lines = null,
    covers: ?Covers = null,
};

pub const list = [_]Accepted{
    .{
        .name = "shadows over sprites",
        .reason = "sorz draws a shadow just behind its entity; the original's shadow is an object of its own, drawn at its entity's depth in its place's order, so it may cover another entity (a thrown Galsia's hand and feet on the ground), or go behind one its entity is in front of (an acrobat's foot beside another's shadow); and its place in the sort of a band of depths reorders the entities at nearly one depth (round 2's brawler and Axel, display tick 5169). Its places, eight it shares with the weapons, move a weapon to a later place than sorz's, which changes their order of updates, no behaviour seen. sorz's way is the user's choice (2026-10-05)",
        .redraws = &.{ originalOrder, shadowsInFront, shadowsBehind },
    },
    .{
        .name = "objects past a band's 15",
        .reason = "the original draws at most 15 objects in a band of depths, and one past them neither shows nor steps its animation at that tick (decision D4): round 3's raindrops, about twenty in one band, blink out of step there; and its shadows are objects of their own in eight places they share with the weapons, each entity taking one at each of its turns, so that a shadow may find none (the raindrops', a crowd's: a trio of acrobats knocked down at once). sorz draws every raindrop, and a shadow under every entity in the air, one the original found no place for too (the places are kept as the original's: world/shadows.zig): more correct, the user's rule (2026-10-05)",
        .redraws = &.{ withoutRaindrops, raindropsShown, shadowsOut },
        .leaves_out = .{ .kind = raindrop_kind, .state = raindrop_state },
    },
    .{
        .name = "sprites over the bosses' bar row",
        .reason = "the original draws a player over the row the bosses' bars add below the status bar (round 4's new life dropping in under its boss's bar); sorz shows no sprite over the status bar, that row included: the cleaner picture, kept (2026-10-05)",
        .redraws = &.{playersOnly},
        .lines = bossesRow,
    },
    .{
        .name = "round 3's boss's art past its first block",
        .reason = "sor-remaster draws the frames of round 3's boss that his code draws at the name bases $343 and $3FE (his slam, knocked away, thrown and slammed, his hug, his part's charge and hug) from other tiles than the boss's load's second and third blocks there: scrambled, its bug (the user's note, 2026-10-05). sorz draws them from the ROM's art",
        .covers = bossLaterBlocks,
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

/// Round 3's boss's frames drawn from his load's second and third blocks: his set's frames
/// from the 15th on (the extractor's runs, sprites.zig), his part's too.
fn bossLaterBlocks(s: Sprite, c: Context) bool {
    for ([_][]const u8{ "boss_r3", "boss_r3_part" }) |name| {
        const id = c.kinds.find(name) orelse continue;
        for (c.kinds.get(id).frames) |animation| for (animation) |f| {
            if (f != s.frame) continue;
            const index = std.fmt.parseInt(u8, f.name, 10) catch return false;
            return index >= boss_first_later;
        };
    }
    return false;
}

/// The first of round 3's boss's frames drawn from the second block of his art.
const boss_first_later = 14;

/// The pixels sprite `s` covers on the screen: its frame's pieces, mirrored about its origin
/// when it is, into `out` (as many at most): their count.
pub fn pieces(s: Sprite, out: []Rect) usize {
    var n: usize = 0;
    for (s.frame.pieces) |p| {
        if (n == out.len) break;
        const w: i32 = @as(i32, p.width) * 8;
        const h: i32 = @as(i32, p.height) * 8;
        const x: i32 = if (s.flip_x) -(@as(i32, p.x) + w) else p.x;
        out[n] = .{ .x = s.x + x, .y = s.y + p.y, .width = w, .height = h };
        n += 1;
    }
    return n;
}

pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };

/// The sprites in the original's order: the shadows objects of their own in the sort, in their
/// places (world/shadows.zig) at their entities' depths, and none for a shadow that found no
/// place; the bands of four depths from the nearest, each sorted as the original sorts
/// (draw_list.zig), the first in front. The pixels where a shadow or an entity at nearly one
/// depth shows over another in the reference. The first must be the world's sprites as sorz
/// draws them (this difference first in the list); the others (a round's texts) stay last.
fn originalOrder(sprites: []const Sprite, c: Context, out: []Sprite) usize {
    const n = @min(c.info.len, sprites.len);
    if (n == 0) return copy(sprites, out);
    var entries: [max_sprites]Entry = undefined;
    if (n > entries.len) return copy(sprites, out);
    var len: usize = 0;
    for (c.info[0..n], 0..) |in, i| {
        if (in.shadow and in.place == sorz.world.output.no_place) continue;
        entries[len] = .{
            .sprite = @intCast(i),
            .key = @as(u32, in.place) * 256 + in.rank,
            .depth = std.math.clamp(in.depth, 0, 240),
            .behind = in.behind,
        };
        len += 1;
    }
    const m0 = len;
    // The world's order (the shadows after the enemies'), then the bands from the nearest.
    std.mem.sort(Entry, entries[0..m0], {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.key < b.key;
        }
    }.less);
    var front: [max_sprites]Entry = undefined;
    var k: usize = 0;
    var b: i32 = 240 / 4;
    while (b >= 0) : (b -= 1) {
        const from = k;
        for (entries[0..m0]) |e| if (@divTrunc(e.depth, 4) == b) {
            front[k] = e;
            k += 1;
        };
        selectionSort(front[from..k]);
    }
    // Back to front.
    var m: usize = 0;
    var i = k;
    while (i > 0) {
        i -= 1;
        out[m] = sprites[front[i].sprite];
        m += 1;
    }
    for (sprites[n..]) |s| {
        out[m] = s;
        m += 1;
    }
    return m;
}

const max_sprites = 160;

const Entry = struct { sprite: u8, key: u32, depth: i32, behind: bool };

/// The original's sort of a band (draw_list.zig's): each position takes the nearest of the
/// rest, swapped there; at an equal depth one marked `behind` gives way.
fn selectionSort(band: []Entry) void {
    if (band.len < 2) return;
    for (0..band.len - 1) |i| {
        var best = band[i];
        for (i + 1..band.len) |j| {
            const cand = band[j];
            if (cand.depth > best.depth or (cand.depth == best.depth and best.behind and !cand.behind)) {
                band[j] = band[i];
                band[i] = cand;
                best = cand;
            }
        }
    }
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

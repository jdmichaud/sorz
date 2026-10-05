//! The accepted differences of the pictures: where sorz's pictures differ from sor-remaster's
//! (the original's) on purpose, by the user's choice. The exact step (PLAN item 23) revisits
//! them. Each has its name, its reason, and how to recognise it: sorz's sprites reordered as the
//! original would draw them (`redraw`). A pixel that differs belongs to the difference when
//! sorz's picture, drawn again with those sprites, shows there what the reference shows. A
//! picture whose differing pixels all belong to accepted differences is reported as such; it is
//! not a difference, and the reach goes on past it.
const std = @import("std");
const sorz = @import("sorz");

const Sprite = sorz.render.Sprite;
const Frame = sorz.content.art.Frame;

pub const Accepted = struct {
    name: []const u8,
    reason: []const u8,
    /// sorz's sprites (`sprites`, back to front) as the original would draw them, into `out`
    /// (as many); `shadow` is the frame of the shadows on the ground.
    redraw: *const fn (sprites: []const Sprite, shadow: ?*const Frame, out: []Sprite) void,
};

pub const list = [_]Accepted{
    .{
        .name = "shadows over sprites",
        .reason = "sorz draws a shadow just behind its entity; the original's shadow is an object of its own, drawn at its entity's depth in its place's order, so it may cover another entity (a thrown Galsia's hand and feet on the ground). sorz's way is the user's choice (2026-10-05)",
        .redraw = shadowsInFront,
    },
};

/// The shadows in front of every other sprite: the pixels where sorz shows a sprite and the
/// reference shows a shadow over it.
fn shadowsInFront(sprites: []const Sprite, shadow: ?*const Frame, out: []Sprite) void {
    var n: usize = 0;
    for ([_]bool{ false, true }) |shadows| for (sprites) |s| {
        const is_shadow = if (shadow) |f| s.frame == f else false;
        if (is_shadow != shadows) continue;
        out[n] = s;
        n += 1;
    };
}

test "shadows over sprites: the shadows go in front, the other sprites keep their order" {
    const frame = std.mem.zeroInit(Frame, .{ .name = "a", .file = "", .width = 1, .height = 1, .origin_x = 0, .origin_y = 0, .pixels = &[_]u8{1} });
    const shadow = std.mem.zeroInit(Frame, .{ .name = "shadow", .file = "", .width = 1, .height = 1, .origin_x = 0, .origin_y = 0, .pixels = &[_]u8{1} });
    const sprites = [_]Sprite{ .of(&frame, 1, 0), .of(&shadow, 2, 0), .of(&frame, 3, 0) };
    var out: [3]Sprite = undefined;
    shadowsInFront(&sprites, &shadow, &out);
    try std.testing.expectEqual([3]i32{ 1, 3, 2 }, [3]i32{ out[0].x, out[1].x, out[2].x });
}

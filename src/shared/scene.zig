//! The game's scenes (DESIGN.md 10.4): a stack whose top scene takes the pads at each tick, advances
//! and draws. An overlay (S3: the settings, network play's messages, the pause) is a scene pushed
//! over another. Each scene owns its state, which is part of the game's canonical state, so a
//! place of the stack that holds no scene is `empty`, never left as it was.
//!
//! Until the game's scenes and their flow graph come (PLAN item 08), the stack holds one scene, the
//! test pattern, on which the hosts, network play and the checks run.
const std = @import("std");
const input = @import("input.zig");
const picture = @import("picture.zig");

pub const Scene = union(enum) {
    /// A place of the stack without a scene.
    empty,
    test_pattern: TestPattern,

    /// One tick of the scene, with the pads of that tick.
    pub fn tick(self: *Scene, pads: input.Pads) void {
        switch (self.*) {
            .empty => {},
            .test_pattern => |*s| s.tick(pads),
        }
    }
};

pub const Stack = struct {
    pub const capacity = 4;

    items: [capacity]Scene = .{ .{ .test_pattern = .{} }, .empty, .empty, .empty },
    len: u8 = 1,

    pub fn top(self: *Stack) *Scene {
        return &self.items[self.len - 1];
    }

    pub fn push(self: *Stack, scene: Scene) error{Full}!void {
        if (self.len == capacity) return error.Full;
        self.items[self.len] = scene;
        self.len += 1;
    }

    /// Takes the top scene off; the one below goes on. The bottom scene stays.
    pub fn pop(self: *Stack) void {
        if (self.len == 1) return;
        self.len -= 1;
        self.items[self.len] = .empty;
    }

    /// One tick of the top scene. The scheduler of DESIGN.md 10.2 (which ticks run the logic, at
    /// 30 a second in play) goes here with the scenes that need it.
    pub fn tick(self: *Stack, pads: input.Pads) void {
        self.top().tick(pads);
    }
};

/// The test pattern: eight colour bars; a marker for each player, which the pad's directions move
/// a pixel a tick, white or black, or in the colours of the face buttons held (A red, B green, C
/// blue); and along the bottom the tick's count in 32 bits, so that each tick has its own picture.
pub const TestPattern = struct {
    markers: [2]Marker = .{ .{ .x = 96, .y = 100 }, .{ .x = 216, .y = 100 } },

    pub const Marker = struct {
        x: u16,
        y: u16,
        /// The pad at the last tick: its face buttons give the colour, and Start's presses count.
        pad: input.Pad = .{},
        starts: u16 = 0,
    };

    pub const marker_size = 8;
    /// The bars cover the picture down to the strip of the tick's bits.
    pub const strip_top = picture.height - 8;
    const strip_cell = picture.width / 32;
    const bar_width = picture.width / bar_colours.len;
    const bar_colours = [8]picture.Rgb{
        .{ 192, 192, 192 }, .{ 192, 192, 0 }, .{ 0, 192, 192 }, .{ 0, 192, 0 },
        .{ 192, 0, 192 },   .{ 192, 0, 0 },   .{ 0, 0, 192 },   .{ 16, 16, 16 },
    };
    const bit_on: picture.Rgb = .{ 255, 255, 255 };
    const bit_off: picture.Rgb = .{ 48, 48, 48 };

    pub fn tick(self: *TestPattern, pads: input.Pads) void {
        for (&self.markers, [2]input.Pad{ pads.pad1, pads.pad2 }) |*m, pad| {
            if (pad.left and m.x > 0) m.x -= 1;
            if (pad.right and m.x < picture.width - marker_size) m.x += 1;
            if (pad.up and m.y > 0) m.y -= 1;
            if (pad.down and m.y < strip_top - marker_size) m.y += 1;
            if (pad.start and !m.pad.start) m.starts +%= 1;
            m.pad = pad;
        }
    }

    /// What the picture shows already, so that a tick draws only what changed. It is the
    /// presentation's, not the game's state.
    pub const Drawn = struct {
        /// Nothing of the pattern is on the picture: the next draw draws it whole.
        whole: bool = false,
        tick: u32 = 0,
        markers: [2]picture.Rect = undefined,
        colours: [2]picture.Rgb = undefined,
    };

    /// Draws the pattern at tick `tick_count` on `pic`, which shows `drawn`.
    pub fn draw(self: *const TestPattern, tick_count: u32, pic: *picture.Picture, drawn: *Drawn) void {
        if (!drawn.whole) {
            bars(pic, .{ .x = 0, .y = 0, .w = picture.width, .h = strip_top });
            for (0..32) |i| bit(pic, tick_count, @intCast(i));
        } else {
            // The bits that changed, and the bars under the markers that moved or changed colour.
            const changed = tick_count ^ drawn.tick;
            for (0..32) |i| if (changed & bitMask(@intCast(i)) != 0) bit(pic, tick_count, @intCast(i));
            for (self.markers, 0..) |m, i| {
                if (!std.meta.eql(rect(m), drawn.markers[i]) or !std.meta.eql(colour(i, m.pad), drawn.colours[i])) {
                    bars(pic, drawn.markers[i]);
                }
            }
        }
        // Both markers again, over the bars that may have covered one.
        for (self.markers, 0..) |m, i| {
            drawn.markers[i] = rect(m);
            drawn.colours[i] = colour(i, m.pad);
            pic.fill(drawn.markers[i], drawn.colours[i]);
        }
        drawn.whole = true;
        drawn.tick = tick_count;
    }

    fn rect(m: Marker) picture.Rect {
        return .{ .x = m.x, .y = m.y, .w = marker_size, .h = marker_size };
    }

    fn colour(player: usize, pad: input.Pad) picture.Rgb {
        if (!(pad.a or pad.b or pad.c)) return if (player == 0) .{ 255, 255, 255 } else .{ 0, 0, 0 };
        return .{ if (pad.a) 255 else 0, if (pad.b) 255 else 0, if (pad.c) 255 else 0 };
    }

    /// The bars within `r`.
    fn bars(pic: *picture.Picture, r: picture.Rect) void {
        for (bar_colours, 0..) |c, i| {
            const left: u32 = @intCast(i * bar_width);
            const x0 = @max(r.x, left);
            const x1 = @min(r.x + r.w, left + bar_width);
            if (x0 < x1) pic.fill(.{ .x = x0, .y = r.y, .w = x1 - x0, .h = r.h }, c);
        }
    }

    /// The mask of the bit that the strip's cell `i` shows: the most significant first.
    fn bitMask(i: u5) u32 {
        return @as(u32, 1) << (31 - i);
    }

    fn bit(pic: *picture.Picture, tick_count: u32, i: u5) void {
        const on = tick_count & bitMask(i) != 0;
        pic.fill(.{ .x = @as(u32, i) * strip_cell, .y = strip_top, .w = strip_cell, .h = 8 }, if (on) bit_on else bit_off);
    }
};

const testing = std.testing;

test "the markers follow their pads within the picture, and Start's presses count" {
    var t: TestPattern = .{};
    const right: input.Pad = .{ .right = true, .start = true };
    for (0..300) |_| t.tick(.{ .pad1 = right, .pad2 = .{ .up = true } });
    try testing.expectEqual(@as(u16, picture.width - TestPattern.marker_size), t.markers[0].x);
    try testing.expectEqual(@as(u16, 0), t.markers[1].y);
    try testing.expectEqual(@as(u16, 1), t.markers[0].starts);
    t.tick(.{});
    t.tick(.{ .pad1 = .{ .start = true } });
    try testing.expectEqual(@as(u16, 2), t.markers[0].starts);
    try testing.expectEqual(@as(u16, 0), t.markers[1].starts);
}

test "drawing only what changed gives the picture that a whole drawing gives" {
    var pic = try picture.Picture.init(testing.allocator);
    defer pic.deinit(testing.allocator);
    var whole = try picture.Picture.init(testing.allocator);
    defer whole.deinit(testing.allocator);
    var t: TestPattern = .{};
    var drawn: TestPattern.Drawn = .{};
    var count: u32 = 0;
    t.draw(count, &pic, &drawn);
    // The markers cross bars, change colour, and the count carries.
    const pads = [_]input.Pads{
        .{ .pad1 = .{ .right = true, .down = true }, .pad2 = .{ .left = true, .b = true } },
        .{ .pad1 = .{ .right = true, .a = true, .c = true }, .pad2 = .{ .left = true } },
        .{ .pad2 = .{ .up = true, .left = true } },
    };
    for (pads) |p| for (0..70) |_| {
        t.tick(p);
        count +%= 1;
        t.draw(count, &pic, &drawn);
        var fresh: TestPattern.Drawn = .{};
        t.draw(count, &whole, &fresh);
        try testing.expectEqualSlices(u8, whole.pixels, pic.pixels);
    };
    count = 255;
    t.draw(count, &pic, &drawn);
    count = 256;
    t.draw(count, &pic, &drawn);
    var fresh: TestPattern.Drawn = .{};
    t.draw(count, &whole, &fresh);
    try testing.expectEqualSlices(u8, whole.pixels, pic.pixels);

    // On one row, player 1's marker goes through player 2's.
    t = .{};
    drawn = .{};
    t.draw(count, &pic, &drawn);
    var overlapped = false;
    for (0..140) |_| {
        t.tick(.{ .pad1 = .{ .right = true, .a = true } });
        count +%= 1;
        t.draw(count, &pic, &drawn);
        var again: TestPattern.Drawn = .{};
        t.draw(count, &whole, &again);
        try testing.expectEqualSlices(u8, whole.pixels, pic.pixels);
        const m = t.markers;
        overlapped = overlapped or @max(m[0].x, m[1].x) - @min(m[0].x, m[1].x) < TestPattern.marker_size;
    }
    try testing.expect(overlapped);
}

test "the stack: its top ticks; a scene pushed over it and taken off" {
    var s: Stack = .{};
    s.tick(.{ .pad1 = .{ .left = true } });
    try testing.expectEqual(@as(u16, 95), s.top().test_pattern.markers[0].x);
    try s.push(.{ .test_pattern = .{} });
    s.tick(.{ .pad1 = .{ .right = true } });
    try testing.expectEqual(@as(u16, 97), s.top().test_pattern.markers[0].x);
    s.pop();
    try testing.expectEqual(@as(u16, 95), s.top().test_pattern.markers[0].x);
    try testing.expectEqual(Scene.empty, s.items[1]);
    s.pop();
    try testing.expectEqual(@as(u8, 1), s.len);
    for (1..Stack.capacity) |_| try s.push(.empty);
    try testing.expectError(error.Full, s.push(.empty));
}

//! The controller overlay (DESIGN.md 10.8): over the picture, for each player in the game, a Mega
//! Drive control pad (pad_art.zig, the port's own pixel art) tagged 1P to 4P in the game's font,
//! semi-transparent, at the bottom of the screen; a button lights plain yellow while pressed.
//! One or two players: a pad at each bottom corner; three or four: smaller pads, made the same
//! way, in a row across the bottom (four at the large width do not fit across the screen).
//!
//! A button lights from the earliest signal the game has: the controls' state before the reads
//! (input.zig `Controls.sampleShown`, taken once a display tick: held now, or pressed since the
//! last sample), and a press shorter than `min_lit_ticks` display ticks stays lit for that many
//! (`Lit`), so that a tap between two display ticks shows. It is this machine's presentation,
//! never the game's state: game.zig draws it over the picture with the other overlays
//! (overlay.zig), under their text.
const std = @import("std");
const input = @import("input.zig");
const pad_art = @import("pad_art.zig");
const panel_mod = @import("panel.zig");
const palettes = @import("render/palettes.zig");
const art = @import("content/art.zig");

/// A button pressed lights at least this many display ticks (a tenth of a second).
pub const min_lit_ticks = 6;

/// Each player's buttons lit, a display tick at a time, from the buttons shown at that tick
/// (`step`): a button shown is lit; one no longer shown stays lit until it has been lit
/// `min_lit_ticks` display ticks since its press.
pub const Lit = struct {
    /// The display ticks each button has been lit, up to `min_lit_ticks` (0: not lit).
    ticks: [input.max_players][8]u8 = @splat(@splat(0)),

    pub fn step(self: *Lit, shown: input.Pads) void {
        for (&self.ticks, 0..) |*buttons, p| {
            const bits: u8 = @bitCast(shown.of(p));
            for (buttons, 0..) |*t, b| {
                if (bits & (@as(u8, 1) << @intCast(b)) != 0) {
                    t.* = @min(t.* + 1, min_lit_ticks);
                } else if (t.* != 0 and t.* < min_lit_ticks) {
                    t.* += 1;
                } else t.* = 0;
            }
        }
    }

    /// The buttons lit now, each player's.
    pub fn pads(self: *const Lit) input.Pads {
        var out: input.Pads = .{};
        for (self.ticks, 0..) |buttons, p| {
            var bits: u8 = 0;
            for (buttons, 0..) |t, b| {
                if (t != 0) bits |= @as(u8, 1) << @intCast(b);
            }
            out.at(p).* = @bitCast(bits);
        }
        return out;
    }
};

/// What the overlay shows: the players in the game (1 to 4) and their buttons lit.
pub const Shown = struct {
    players: u8,
    lit: input.Pads,
};

/// A pad's pixels: a colour index of `pad_art.palette` each (0: none), and the button whose press
/// lights it (`Button`'s backing integer plus one; 0: none).
pub const Art = struct {
    width: u16,
    height: u16,
    pixels: []const u8,
    parts: []const u8,
};

/// A pixel's part: the button whose press lights it, from 1.
fn light(b: input.Button) u8 {
    return @as(u8, @backingInt(b)) + 1;
}

fn decode(comptime rows: []const []const u8, comptime parts: []const []const u8) Art {
    @setEvalBranchQuota(100_000);
    const w = rows[0].len;
    const h = rows.len;
    var pixels: [w * h]u8 = undefined;
    var lights: [w * h]u8 = undefined;
    for (rows, parts, 0..) |row, part, y| {
        if (row.len != w or part.len != w) @compileError("the pad's rows are not all of its width");
        for (row, part, 0..) |ch, pt, x| {
            pixels[y * w + x] = switch (ch) {
                '.' => 0,
                '1'...'9' => ch - '0',
                'a'...'z' => ch - 'a' + 10,
                else => @compileError("not a colour of the pad"),
            };
            if (pixels[y * w + x] >= pad_art.palette.len) @compileError("not a colour of the pad");
            lights[y * w + x] = switch (pt) {
                '.' => 0,
                'u' => light(.up),
                'd' => light(.down),
                'l' => light(.left),
                'r' => light(.right),
                'a' => light(.a),
                'b' => light(.b),
                'c' => light(.c),
                's' => light(.start),
                else => @compileError("not a button of the pad"),
            };
        }
    }
    const p = pixels;
    const l = lights;
    return .{ .width = w, .height = h, .pixels = &p, .parts = &l };
}

/// The pad of one or two players, and the smaller one of three or four.
pub const large = decode(&pad_art.large_rows, &pad_art.large_parts);
pub const small = decode(&pad_art.small_rows, &pad_art.small_parts);

/// The pad's colours as RGB bytes, at the game's levels.
const colours: [pad_art.palette.len][3]u8 = blk: {
    var out: [pad_art.palette.len][3]u8 = undefined;
    for (pad_art.palette, &out) |c, *o| o.* = palettes.rgba(c)[0..3].*;
    break :blk out;
};

/// The overlay's opacity, in 256ths: the picture shows through a quarter.
pub const opacity: u16 = 192;

/// The tag's height over the pad's top (it overlaps the pad by its lower rows), and the tag's
/// size: two glyphs of the font, outlined.
const tag_rise = 6;
const tag_width = 2 * 8 + 2;
const tag_height = 8 + 2;

/// The margin to the screen's sides and its bottom.
const margin_side = 2;
const margin_bottom = 1;

/// Where a player's pad is: its top left corner (the tag above it) and its art.
pub const Place = struct { x: i32, y: i32, art: *const Art };

/// The players' pads' places: one or two players, the large pad at the bottom corners (one
/// alone at the bottom left); three or four, the small one, spread across the bottom.
pub fn place(players: u8, k: usize) Place {
    const a: *const Art = if (players <= 2) &large else &small;
    const n: i32 = @max(players, 1);
    const span: i32 = panel_mod.width - 2 * margin_side - a.width;
    const x: i32 = margin_side + if (n == 1) 0 else @divTrunc(span * @as(i32, @intCast(k)), n - 1);
    return .{ .x = x, .y = panel_mod.height - margin_bottom - @as(i32, a.height), .art = a };
}

/// What the overlay is drawn with: the font of its tags and their colours (the game menu's
/// bright ones), and the pixels it leaves as they are (a panel's own: its text stays over the
/// pads), colour indices of the picture's size (0: none).
pub const Look = struct {
    font: *const art.Font,
    sheet: *const art.TileSheet,
    colours: *const [palettes.size]art.Colour,
    kept: ?[]const u8 = null,

    /// The panel's font and bright colours; its own pixels kept.
    pub fn ofPanel(p: *const panel_mod.Panel) Look {
        return .{ .font = p.font, .sheet = p.sheet, .colours = &p.colours[@backingInt(panel_mod.Tone.bright)], .kept = &p.composer.indices };
    }
};

/// Draws the overlay over `rgba` (a picture of the screen's size, RGBA).
pub fn draw(rgba: []u8, s: Shown, look: Look) void {
    for (0..@min(s.players, input.max_players)) |k| {
        const at = place(s.players, k);
        drawPad(rgba, look.kept, at, s.lit.of(k));
        drawTag(rgba, look, at, k);
    }
}

/// Mixes `c` into the picture's pixel (`x`, `y`) at the overlay's opacity, unless it is off the
/// screen or one of the panel's own.
fn mix(rgba: []u8, indices: ?[]const u8, x: i32, y: i32, c: [3]u8) void {
    if (x < 0 or y < 0 or x >= panel_mod.width or y >= panel_mod.height) return;
    const i: usize = @intCast(y * panel_mod.width + x);
    if (indices) |ix| if (ix[i] != 0) return;
    const to = rgba[i * 4 ..][0..3];
    for (to, c) |*t, v| t.* = @intCast((@as(u16, v) * opacity + @as(u16, t.*) * (256 - opacity)) >> 8);
}

fn drawPad(rgba: []u8, indices: ?[]const u8, at: Place, lit: input.Pad) void {
    const a = at.art;
    const bits: u8 = @bitCast(lit);
    for (0..a.height) |y| for (0..a.width) |x| {
        const i = y * a.width + x;
        var c = a.pixels[i];
        if (c == 0) continue;
        const part = a.parts[i];
        if (part != 0 and bits & (@as(u8, 1) << @intCast(part - 1)) != 0) c = pad_art.pressed[c];
        mix(rgba, indices, at.x + @as(i32, @intCast(x)), at.y + @as(i32, @intCast(y)), colours[c]);
    };
}

/// Player `k`'s tag (1P to 4P) centred over its pad: the font's glyphs, their ground left out, a
/// black line round them.
fn drawTag(rgba: []u8, look: Look, at: Place, k: usize) void {
    var cells: [tag_height][tag_width]u8 = @splat(@splat(0));
    const label = [2]u8{ '1' + @as(u8, @intCast(k)), 'P' };
    for (label, 0..) |ch, n| {
        const g = look.font.glyphAt(&.{ch}) orelse continue;
        const tile = &look.sheet.tiles[g.tile];
        for (0..8) |y| for (0..8) |x| {
            const v = tile[y * 8 + x];
            // The font's ground (0, and 2: the menu's black) is left out.
            if (v != 0 and v != 2) cells[y + 1][x + 1 + 8 * n] = v;
        };
    }
    const x0 = at.x + @divTrunc(@as(i32, at.art.width) - tag_width, 2);
    const y0 = at.y - tag_rise;
    for (0..tag_height) |y| for (0..tag_width) |x| {
        const v = cells[y][x];
        const c: [3]u8 = if (v != 0) palettes.rgba(look.colours[v])[0..3].* else if (nextTo(&cells, x, y)) .{ 0, 0, 0 } else continue;
        mix(rgba, look.kept, x0 + @as(i32, @intCast(x)), y0 + @as(i32, @intCast(y)), c);
    };
}

/// A letter's pixel is next to (`x`, `y`), across or down.
fn nextTo(cells: *const [tag_height][tag_width]u8, x: usize, y: usize) bool {
    if (x > 0 and cells[y][x - 1] != 0) return true;
    if (x + 1 < tag_width and cells[y][x + 1] != 0) return true;
    if (y > 0 and cells[y - 1][x] != 0) return true;
    if (y + 1 < tag_height and cells[y + 1][x] != 0) return true;
    return false;
}

// --- tests -----------------------------------------------------------------------------------------

const testing = std.testing;

test "lit: a tap shown once lights the minimum, a held button until let go" {
    var l: Lit = .{};
    var tap: [min_lit_ticks + 2]bool = undefined;
    for (&tap, 0..) |*x, t| {
        l.step(if (t == 0) .{ .pad2 = .{ .b = true } } else .{});
        x.* = l.pads().pad2.b;
    }
    try testing.expectEqualSlices(bool, &.{ true, true, true, true, true, true, false, false }, &tap);
    // Held ten display ticks: lit those ten, out at once when let go.
    var held: [12]bool = undefined;
    for (&held, 0..) |*x, t| {
        l.step(if (t < 10) .{ .pad1 = .{ .left = true } } else .{});
        x.* = l.pads().pad1.left;
    }
    try testing.expectEqualSlices(bool, &.{ true, true, true, true, true, true, true, true, true, true, false, false }, &held);
    // Held three: lit the minimum; pressed again while lit, it goes on from there.
    var short: [9]bool = undefined;
    for (&short, 0..) |*x, t| {
        l.step(if (t < 3 or t == 4) .{ .pad4 = .{ .start = true } } else .{});
        x.* = l.pads().pad4.start;
    }
    try testing.expectEqualSlices(bool, &.{ true, true, true, true, true, true, false, false, false }, &short);
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(l.pads().pad3)));
}

test "the layout: one or two players at the bottom corners, three or four across, all on screen" {
    try testing.expectEqual(@as(u16, 104), large.width);
    try testing.expect(small.width * 4 + 2 * margin_side <= panel_mod.width);
    for (1..input.max_players + 1) |n| {
        const players: u8 = @intCast(n);
        var right_before: i32 = 0;
        for (0..n) |k| {
            const at = place(players, k);
            try testing.expect(at.x >= margin_side and at.x + at.art.width <= panel_mod.width - margin_side);
            try testing.expectEqual(@as(i32, panel_mod.height - margin_bottom), at.y + at.art.height);
            try testing.expect(at.y - tag_rise >= 0);
            // Each to the right of the one before, apart.
            try testing.expect(k == 0 or at.x > right_before);
            right_before = at.x + at.art.width;
        }
    }
    try testing.expectEqual(Place{ .x = margin_side, .y = place(1, 0).y, .art = &large }, place(1, 0));
    try testing.expectEqual(@as(i32, panel_mod.width - margin_side - 104), place(2, 1).x);
    try testing.expect(place(3, 0).art == &small and place(4, 3).art == &small);
    try testing.expectEqual(@as(i32, panel_mod.width - margin_side - small.width), place(4, 3).x);
}

test "the art: every button has its pixels, and a pressed one lights yellow" {
    for ([_]*const Art{ &large, &small }) |a| {
        var seen: [8]usize = @splat(0);
        for (a.parts, a.pixels) |pt, c| {
            if (pt == 0) continue;
            try testing.expect(c != 0);
            seen[pt - 1] += 1;
        }
        for (seen) |n| try testing.expect(n >= 4);
    }
    // A pressed pixel of B, mixed over black: the yellow of its shade at the opacity.
    var rgba: [panel_mod.width * panel_mod.height * 4]u8 = @splat(0);
    const at = place(2, 0);
    drawPad(&rgba, null, at, .{ .b = true });
    const a = at.art;
    const i = std.mem.indexOfScalar(u8, a.parts, light(.b)).?;
    const x = at.x + @as(i32, @intCast(i % a.width));
    const y = at.y + @as(i32, @intCast(i / a.width));
    const px = rgba[@as(usize, @intCast(y * panel_mod.width + x)) * 4 ..][0..3];
    const want = colours[pad_art.pressed[a.pixels[i]]];
    for (px, want) |got, w| try testing.expectEqual(@as(u8, @intCast(@as(u16, w) * opacity >> 8)), got);
    try testing.expect(want[0] > want[2]);
}

test "the overlay: over the picture at its opacity, under the panel's own pixels" {
    const Fixture = panel_mod.Fixture;
    var menu = palettes.black;
    Fixture.colours.apply(&menu);
    var rgba: [panel_mod.width * panel_mod.height * 4]u8 = @splat(0x80);
    var kept: [panel_mod.width * panel_mod.height]u8 = @splat(0);
    const at = place(1, 0);
    // A pixel of the pad's under the panel's text: kept.
    const i = std.mem.indexOfNone(u8, at.art.pixels, &.{0}).?;
    const x: usize = @intCast(at.x + @as(i32, @intCast(i % at.art.width)));
    const y: usize = @intCast(at.y + @as(i32, @intCast(i / at.art.width)));
    kept[y * panel_mod.width + x + 1] = 5;
    draw(&rgba, .{ .players = 1, .lit = .{} }, .{ .font = &Fixture.font, .sheet = &Fixture.sheet, .colours = &menu[0], .kept = &kept });
    const want = overGrey(at.art.pixels[i]);
    try testing.expectEqual(want, rgba[(y * panel_mod.width + x) * 4 ..][0..3].*);
    if (at.art.pixels[i + 1] != 0) try testing.expectEqual([3]u8{ 0x80, 0x80, 0x80 }, rgba[(y * panel_mod.width + x + 1) * 4 ..][0..3].*);
    // Away from the pads, the picture as it was.
    try testing.expectEqual([3]u8{ 0x80, 0x80, 0x80 }, rgba[0..3].*);
}

/// Colour `c` of the pad mixed over the test's grey at the overlay's opacity.
fn overGrey(c: u8) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, colours[c]) |*o, v| o.* = @intCast((@as(u16, v) * opacity + 0x80 * (256 - opacity)) >> 8);
    return out;
}

//! The fonts (graphics port map 2.5): which tile of a font's sheet draws which character. The
//! game's font (the Nemesis stream 0x1CEC0) codes a character by its tile: blank 0, A-Z 1-26,
//! 0-9 27-36, and its signs 37-48, read off the glyphs; its italic face (the Kosinski block
//! 0x389A0) has the same tiles. The profiles' font (0x38BB0) shares the letters, and has its
//! signs and digits after them.
const std = @import("std");
const sorz = @import("sorz");
const art = sorz.content.art;
const blocks = @import("blocks.zig");
const Builder = @import("builder.zig").Builder;

const Glyph = art.Glyph;

const letters = blk: {
    var g: [26]Glyph = undefined;
    for (&g, 0..) |*x, i| x.* = .{ .text = &[1]u8{'A' + i}, .tile = i + 1 };
    break :blk g;
};

fn digits(comptime first: u16) [10]Glyph {
    var g: [10]Glyph = undefined;
    for (&g, 0..) |*x, i| x.* = .{ .text = &[1]u8{'0' + i}, .tile = first + i };
    return g;
}

const main_glyphs = [_]Glyph{.{ .text = " ", .tile = 0 }} ++ letters ++ digits(27) ++ [_]Glyph{
    .{ .text = "x", .tile = 37 },   .{ .text = "-", .tile = 38 },  .{ .text = "->", .tile = 39 },
    .{ .text = "(c)", .tile = 40 }, .{ .text = ".", .tile = 41 },  .{ .text = ",", .tile = 42 },
    .{ .text = "'", .tile = 43 },   .{ .text = "\"", .tile = 44 }, .{ .text = "?", .tile = 45 },
    .{ .text = "!", .tile = 46 },   .{ .text = ":", .tile = 47 },  .{ .text = ";", .tile = 48 },
};

const intro_glyphs = [_]Glyph{.{ .text = " ", .tile = 0 }} ++ letters ++ [_]Glyph{
    .{ .text = "?", .tile = 29 }, .{ .text = "!", .tile = 30 }, .{ .text = "-", .tile = 31 },
    .{ .text = ".", .tile = 33 }, .{ .text = ",", .tile = 34 }, .{ .text = ":", .tile = 35 },
} ++ digits(36);

const Font = struct { name: []const u8, sheet: []const u8, glyphs: []const Glyph, why: []const u8 };

const fonts = [_]Font{
    .{ .name = "fonts/main", .sheet = "fonts/main", .glyphs = &main_glyphs, .why = "the game's font: a text's byte is its tile (the menus, the status bar; graphics port map 2.5, its signs read off the glyphs)" },
    .{ .name = "fonts/italic", .sheet = "fonts/italic", .glyphs = &main_glyphs, .why = "the game's font, italic: the main font's tiles (the story, the demo's sign, the endings)" },
    .{ .name = "fonts/intro", .sheet = "fonts/intro", .glyphs = &intro_glyphs, .why = "the profiles' font: the main font's letters, then its own signs and digits" },
};

pub fn extract(b: *Builder) !void {
    try b.describe("fonts", "the fonts: their sheets and which tile draws which character");
    for (fonts) |f| {
        const blk = blocks.findName(f.sheet) orelse return error.UnknownBlock;
        const d = try b.sheet(blk.*);
        for (f.glyphs) |g| if (g.tile >= d.tiles.len) return error.BadData;
        try b.font(f.name, .{ .name = "", .provenance = f.why, .sheet = f.sheet, .glyphs = f.glyphs });
    }
}

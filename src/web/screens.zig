//! The page's own screens, drawn by the module with the renderer from the content (DESIGN.md 5.3):
//! the loading screen and its share of the files, and the messages of errors, before the game
//! runs its own front end (the page has no menu of its own). They look like the game's menu:
//! dark, the game's font in the menu's colours (`menu/one_pad`).
//!
//! They need two of the content's art sets, `fonts` and `menu`, which the page fetches before the
//! other files (`sets`); the content's loader reads them, every file checked. They are drawn with
//! the game's panel (panel.zig), as the game draws its own overlays.
const std = @import("std");
const sorz = @import("sorz");
const render = sorz.render;
const art = sorz.content.art;
const json = sorz.formats.json;

pub const width = render.width;
pub const height = render.height;
const columns = sorz.panel.columns;
const rows = sorz.panel.rows;

/// The art sets the screens are drawn from: the page fetches their files (the tree's directories
/// of these names) before the others.
pub const sets = [_][]const u8{ "fonts", "menu" };

/// The loading screen's line (LOADING and its percentage) and its bar's dashes, two rows below.
const loading_row = 13;
const loading_bar = 12;

pub const Screens = struct {
    arena: std.heap.ArenaAllocator,
    panel: sorz.panel.Panel,

    pub const Error = error{ OutOfMemory, BadContent };

    /// Reads the screens' sets from `source`; a refusal's file and field are written to `reason`
    /// (the content's names are gone once it returns). In place: the panel's layer points at its
    /// board.
    pub fn open(self: *Screens, gpa: std.mem.Allocator, source: sorz.platform.AssetSource, reason: *std.Io.Writer) Error!void {
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        var diag: json.Diagnostic = .{};
        const a = sorz.content.tree.loadArt(self.arena.allocator(), source, &sets, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadAsset => {
                reason.print("{f}", .{&diag}) catch {};
                return error.BadContent;
            },
        };
        const missing = struct {
            fn refuse(r: *std.Io.Writer, name: []const u8) Error {
                r.print("the content has no {s}", .{name}) catch {};
                return error.BadContent;
            }
        }.refuse;
        const font = a.font("fonts/main") orelse return missing(reason, "fonts/main");
        const sheet = a.sheet(font.sheet) orelse return missing(reason, font.sheet);
        const colours = a.palette("menu/one_pad") orelse return missing(reason, "menu/one_pad");
        self.panel.init(gpa, font, sheet, colours) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoArrow => return missing(reason, "the font's arrow (->)"),
        };
    }

    pub fn deinit(self: *Screens) void {
        self.panel.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// The loading screen: LOADING and the share of the files that came (LOADING 23%) on one line,
    /// and below, a bar of the font's dashes (bright for the files that came, dim for the others),
    /// both centred on the screen's middle.
    pub fn loading(self: *Screens, done: u32, total: u32) Error![]const u8 {
        const p = &self.panel;
        p.begin();
        const percent: u64 = if (total == 0) 100 else @min(100, @as(u64, done) * 100 / total);
        var buf: [16]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "LOADING {d}%", .{percent}) catch unreachable;
        try p.text((columns - line.len) / 2, loading_row, line, .bright);
        const lit = percent * loading_bar / 100;
        for (0..loading_bar) |i| try p.text((columns - loading_bar) / 2 + i, loading_row + 2, "-", if (i < lit) .bright else .dim);
        return p.finish(null, false);
    }

    /// A message: its lines (split at '\n', each cut at its spaces to fit) centred from row 11, on
    /// a dark screen or over `under` (the game's last picture), each on a dark strip.
    pub fn show(self: *Screens, text_: []const u8, under: ?sorz.platform.RgbaFrame) Error![]const u8 {
        const p = &self.panel;
        p.begin();
        _ = try p.message(text_, 11, under != null);
        return p.finish(under, false);
    }
};

// --- tests -----------------------------------------------------------------------------------------

const testing = std.testing;

/// The `fonts` and `menu` sets of a synthetic content: a font whose tiles are its glyphs' codes
/// in colour 1 on a ground of colour 2 (the blank, A, the dash, the arrow), the menu's lines and
/// its colours (palette 0 white, palette 1 dim).
fn fixture(arena: std.mem.Allocator, source: *sorz.memory.MemoryAssetSource) !void {
    var tiles: [4]art.Tile = undefined;
    for (&tiles, 0..) |*t, k| {
        @memset(t, 2);
        if (k != 0) @memset(t[0..8], 1);
    }
    const sheet: art.TileSheet = .{ .name = "main", .file = "main.png", .tiles = &tiles };
    const glyphs = [_]art.Glyph{ .{ .text = " ", .tile = 0 }, .{ .text = "A", .tile = 1 }, .{ .text = "-", .tile = 2 }, .{ .text = "->", .tile = 3 } };
    const fonts = [_]art.Font{.{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs }};
    var colours: art.Palette = .{ .name = "one_pad" };
    colours.colours[0][1] = .{ .r = 7, .g = 7, .b = 7 };
    colours.colours[0][2] = art.Colour.black;
    colours.colours[1][1] = .{ .r = 1, .g = 1, .b = 1 };
    colours.colours[1][2] = art.Colour.black;
    const cells = [_]art.Cell{.{ .tile = 1 }};
    var maps: [3]art.TileMap = undefined;
    for (&maps, [_][]const u8{ "one_player", "two_players", "options" }, 0..) |*m, name, i| {
        m.* = .{ .name = name, .file = try std.fmt.allocPrint(arena, "{s}.tmj", .{name}), .width = 1, .height = 1, .sheets = &.{"fonts/main"}, .cells = &cells, .place = .{ .layer = .plane_a, .x = 16, .y = @intCast(11 + 2 * i) } };
    }
    const set_list = [_]art.ArtSet{
        .{ .name = "fonts", .sheets = &.{sheet}, .fonts = &fonts },
        .{ .name = "menu", .uses = &.{"fonts"}, .palettes = &.{colours}, .maps = &maps },
    };
    const c: sorz.content.Content = .{ .manifest = .{ .extractor = "test", .rom_sha256 = "", .rom_size = 0, .art = &.{ "fonts", "menu" } }, .art = .{ .sets = &set_list } };
    for (try sorz.content.write(arena, &c)) |f| try source.add(f.path, f.bytes);
}

fn pixelAt(rgba: []const u8, x: usize, y: usize) [3]u8 {
    return rgba[(y * width + x) * 4 ..][0..3].*;
}

const white = [3]u8{ 255, 255, 255 };
const dim = [3]u8{ 49, 49, 49 };
const black = [3]u8{ 0, 0, 0 };

test "the screens are drawn from the content's font and the menu's colours" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var source = sorz.memory.MemoryAssetSource.init(testing.allocator);
    defer source.deinit();
    try fixture(arena.allocator(), &source);
    var reason: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reason.deinit();
    var s: Screens = undefined;
    try s.open(testing.allocator, source.assetSource(), &reason.writer);
    defer s.deinit();

    // The loading screen: LOADING 50% from column 14 of row 13 (its A third), the % the page's
    // own tile; half the dashes of the bar (12 from column 14 of row 15) bright.
    var rgba = try s.loading(5, 10);
    try testing.expectEqual(black, pixelAt(rgba, 14 * 8, 13 * 8));
    try testing.expectEqual(white, pixelAt(rgba, 16 * 8, 13 * 8));
    try testing.expectEqual(white, pixelAt(rgba, 24 * 8 + 3, 13 * 8));
    try testing.expectEqual(white, pixelAt(rgba, 19 * 8, 15 * 8));
    try testing.expectEqual(dim, pixelAt(rgba, 20 * 8, 15 * 8));
    try testing.expectEqual(black, pixelAt(rgba, 26 * 8, 15 * 8));

    // A message over a picture: a dark strip a cell wider than the text on each side.
    const under = try testing.allocator.alloc(u8, width * height * 4);
    defer testing.allocator.free(under);
    @memset(under, 0x80);
    rgba = try s.show("aa", .{ .width = width, .height = height, .stride = width * 4, .pixels = under });
    try testing.expectEqual(white, pixelAt(rgba, 19 * 8, 11 * 8));
    try testing.expectEqual(black, pixelAt(rgba, 18 * 8, 11 * 8));
    try testing.expectEqual([3]u8{ 0x80, 0x80, 0x80 }, pixelAt(rgba, 17 * 8, 11 * 8));
    try testing.expectEqual([3]u8{ 0x80, 0x80, 0x80 }, pixelAt(rgba, 19 * 8, 12 * 8));
    try testing.expectEqual(@as(usize, 13), try s.panel.message("AAAAAAAAA AAAAAAAAA AAAAAAAAA AAAAAAAAA", 11, false));
}

test "without the screens' sets, the screens are refused with the file named" {
    var source = sorz.memory.MemoryAssetSource.init(testing.allocator);
    defer source.deinit();
    var reason: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reason.deinit();
    var s: Screens = undefined;
    try testing.expectError(error.BadContent, s.open(testing.allocator, source.assetSource(), &reason.writer));
    try testing.expect(std.mem.startsWith(u8, reason.written(), "fonts/art.json"));
}

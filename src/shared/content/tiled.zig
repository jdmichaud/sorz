//! Tile maps as Tiled maps (JSON, `.tmj`), so that a map opens in the Tiled editor over the tile
//! sheets it draws from (docs/content.md). A map has two layers of the same size:
//! - `cells`: each cell's gid, Tiled's tile number across the map's tilesets (0 for an empty
//!   cell), with Tiled's flip bits (bit 31 horizontal, bit 30 vertical);
//! - `attributes`: each cell's palette and priority as a tile of the `attributes` tileset, palette
//!   p with priority q being its tile p + 4q; 0 is palette 0 without priority.
//! Its tilesets are the sheets, in the map's order (each named by the sheet's full name, its image
//! the sheet's picture), then `attributes`.
const std = @import("std");
const json = @import("../formats/json.zig");
const art = @import("art.zig");

pub const flip_h: u32 = 1 << 31;
pub const flip_v: u32 = 1 << 30;
pub const flip_d: u32 = 1 << 29;
const gid_mask: u32 = flip_d - 1;

pub const attributes_name = "attributes";
pub const attributes_count = 8;
/// The attributes tileset's picture, at the root of the tree.
pub const attributes_file = "attributes.png";
/// Tiles per row of a sheet's picture.
pub const sheet_columns = 16;

pub const max_side = 4096;

/// A sheet as a map's tileset sees it: its full name, its tile count and its picture's path
/// relative to the map's directory.
pub const SheetRef = struct { name: []const u8, count: usize, image: []const u8 };

/// The `.tmj` text of `map` over `sheets` (the map's sheets, in order). `attributes_image` is the
/// attributes picture's path relative to the map's directory.
pub fn write(arena: std.mem.Allocator, map: *const art.TileMap, sheets: []const SheetRef, attributes_image: []const u8) ![]u8 {
    const n = @as(usize, map.width) * map.height;
    if (map.cells.len != n) return error.BadMap;
    // The first gid of each sheet, then of the attributes.
    const first = try arena.alloc(u32, sheets.len + 1);
    var next: u32 = 1;
    for (sheets, 0..) |s, i| {
        first[i] = next;
        next += @intCast(s.count);
    }
    first[sheets.len] = next;

    const cells = try arena.alloc(json.Value, n);
    const attrs = try arena.alloc(json.Value, n);
    for (map.cells, cells, attrs) |c, *g, *a| {
        if (c.isEmpty()) {
            g.* = json.Value.num(0);
            a.* = json.Value.num(0);
            continue;
        }
        // The sheet the tile falls in.
        var k: usize = 0;
        var base: usize = 0;
        while (k < sheets.len and c.tile >= base + sheets[k].count) : (k += 1) base += sheets[k].count;
        if (k == sheets.len) return error.BadMap;
        var gid: u32 = first[k] + @as(u32, @intCast(c.tile - base));
        if (c.flip_x) gid |= flip_h;
        if (c.flip_y) gid |= flip_v;
        g.* = json.Value.num(gid);
        const at: u32 = @as(u32, c.palette) + 4 * @as(u32, @intFromBool(c.priority));
        a.* = json.Value.num(if (at == 0) 0 else first[sheets.len] + at);
    }

    var tilesets: std.ArrayList(json.Value) = .empty;
    for (sheets, 0..) |s, i| try tilesets.append(arena, try tileset(arena, s.name, s.image, first[i], s.count, sheet_columns));
    try tilesets.append(arena, try tileset(arena, attributes_name, attributes_image, first[sheets.len], attributes_count, attributes_count));
    const v: json.Value = .{ .object = try arena.dupe(json.Field, &.{
        .{ .key = "type", .value = .{ .str = "map" } },
        .{ .key = "version", .value = .{ .str = "1.10" } },
        .{ .key = "orientation", .value = .{ .str = "orthogonal" } },
        .{ .key = "renderorder", .value = .{ .str = "right-down" } },
        .{ .key = "infinite", .value = .{ .bool = false } },
        .{ .key = "width", .value = json.Value.num(map.width) },
        .{ .key = "height", .value = json.Value.num(map.height) },
        .{ .key = "tilewidth", .value = json.Value.num(art.tile_side) },
        .{ .key = "tileheight", .value = json.Value.num(art.tile_side) },
        .{ .key = "nextlayerid", .value = json.Value.num(3) },
        .{ .key = "nextobjectid", .value = json.Value.num(1) },
        .{ .key = "tilesets", .value = .{ .array = tilesets.items } },
        .{ .key = "layers", .value = .{ .array = try arena.dupe(json.Value, &.{
            try layer(arena, 1, "cells", map.width, map.height, cells),
            try layer(arena, 2, "attributes", map.width, map.height, attrs),
        }) } },
    }) };
    return json.write(arena, v);
}

fn layer(arena: std.mem.Allocator, id: u32, name: []const u8, w: usize, h: usize, data: []const json.Value) !json.Value {
    return .{ .object = try arena.dupe(json.Field, &.{
        .{ .key = "id", .value = json.Value.num(id) },
        .{ .key = "name", .value = .{ .str = name } },
        .{ .key = "type", .value = .{ .str = "tilelayer" } },
        .{ .key = "width", .value = json.Value.num(w) },
        .{ .key = "height", .value = json.Value.num(h) },
        .{ .key = "x", .value = json.Value.num(0) },
        .{ .key = "y", .value = json.Value.num(0) },
        .{ .key = "opacity", .value = json.Value.num(1) },
        .{ .key = "visible", .value = .{ .bool = true } },
        .{ .key = "data", .value = .{ .array = data } },
    }) };
}

fn tileset(arena: std.mem.Allocator, name: []const u8, image: []const u8, firstgid: u32, count: usize, columns: usize) !json.Value {
    const rows = (@max(count, 1) + columns - 1) / columns;
    return .{ .object = try arena.dupe(json.Field, &.{
        .{ .key = "firstgid", .value = json.Value.num(firstgid) },
        .{ .key = "name", .value = .{ .str = name } },
        .{ .key = "image", .value = .{ .str = image } },
        .{ .key = "imagewidth", .value = json.Value.num(columns * art.tile_side) },
        .{ .key = "imageheight", .value = json.Value.num(rows * art.tile_side) },
        .{ .key = "tilewidth", .value = json.Value.num(art.tile_side) },
        .{ .key = "tileheight", .value = json.Value.num(art.tile_side) },
        .{ .key = "tilecount", .value = json.Value.num(count) },
        .{ .key = "columns", .value = json.Value.num(columns) },
        .{ .key = "margin", .value = json.Value.num(0) },
        .{ .key = "spacing", .value = json.Value.num(0) },
    }) };
}

/// A map read from its `.tmj`: its size, its sheets' full names and its cells.
pub const Read = struct {
    width: u16,
    height: u16,
    sheets: []const []const u8,
    cells: []art.Cell,
};

/// Reads the map `root` (a parsed `.tmj`). `countOf` gives a sheet's tile count by its full
/// name (null for no such sheet); `imageOf` the path its picture must have from the map's
/// directory, and `attributes_image` the attributes picture's.
pub fn read(
    root: json.Node,
    context: anytype,
    comptime countOf: fn (@TypeOf(context), []const u8) ?usize,
    comptime imageOf: fn (@TypeOf(context), []const u8) error{OutOfMemory}![]const u8,
    attributes_image: []const u8,
) json.Error!Read {
    const arena = root.arena;
    if (!std.mem.eql(u8, try (try root.get("type")).string(), "map")) return (try root.get("type")).fail("not \"map\"");
    if (!std.mem.eql(u8, try (try root.get("orientation")).string(), "orthogonal")) return (try root.get("orientation")).fail("not \"orthogonal\"");
    if (try (try root.get("infinite")).boolean()) return (try root.get("infinite")).fail("an infinite map is not read");
    if (try (try root.get("tilewidth")).int(u32) != art.tile_side) return (try root.get("tilewidth")).fail("not 8");
    if (try (try root.get("tileheight")).int(u32) != art.tile_side) return (try root.get("tileheight")).fail("not 8");
    const width = try (try root.get("width")).int(u16);
    const height = try (try root.get("height")).int(u16);
    if (width == 0 or width > max_side) return (try root.get("width")).fail("not 1 to 4096");
    if (height == 0 or height > max_side) return (try root.get("height")).fail("not 1 to 4096");
    const n = @as(usize, width) * height;

    // The tilesets: the sheets in order, and the attributes.
    const Range = struct { first: u32, count: u32, base: u32, attributes: bool };
    const sets_node = try root.get("tilesets");
    const count = try sets_node.len();
    const ranges = try arena.alloc(Range, count);
    var sheets: std.ArrayList([]const u8) = .empty;
    var tiles: u32 = 0;
    var attributes = false;
    for (ranges, 0..) |*r, i| {
        const ts = try sets_node.at(i);
        if (try ts.opt("source") != null) return (try ts.get("source")).fail("an external tileset is not read: embed it in the map");
        const name = try (try ts.get("name")).string();
        const firstgid = try (try ts.get("firstgid")).int(u32);
        if (firstgid == 0 or firstgid > gid_mask) return (try ts.get("firstgid")).fail("out of range");
        if (i > 0 and firstgid < ranges[i - 1].first + ranges[i - 1].count) return (try ts.get("firstgid")).fail("overlaps the tileset before");
        const tilecount = try (try ts.get("tilecount")).int(u32);
        const image = try (try ts.get("image")).string();
        if (std.mem.eql(u8, name, attributes_name)) {
            if (attributes) return (try ts.get("name")).fail("a second attributes tileset");
            if (tilecount != attributes_count) return (try ts.get("tilecount")).fail("not 8");
            if (!std.mem.eql(u8, image, attributes_image)) return (try ts.get("image")).fail(try std.fmt.allocPrint(arena, "not \"{s}\"", .{attributes_image}));
            attributes = true;
            r.* = .{ .first = firstgid, .count = tilecount, .base = 0, .attributes = true };
            continue;
        }
        const sheet_count = countOf(context, name) orelse return (try ts.get("name")).fail("no tile sheet of this name");
        if (tilecount != sheet_count) return (try ts.get("tilecount")).fail(try std.fmt.allocPrint(arena, "not the sheet's {d} tiles", .{sheet_count}));
        const expected = try imageOf(context, name);
        if (!std.mem.eql(u8, image, expected)) return (try ts.get("image")).fail(try std.fmt.allocPrint(arena, "not the sheet's picture \"{s}\"", .{expected}));
        try sheets.append(arena, name);
        r.* = .{ .first = firstgid, .count = tilecount, .base = tiles, .attributes = false };
        tiles += tilecount;
    }
    if (tiles >= art.Cell.no_tile) return sets_node.fail("too many tiles");

    // The two layers.
    var cells_data: ?json.Node = null;
    var attrs_data: ?json.Node = null;
    const layers = try root.get("layers");
    for (0..try layers.len()) |i| {
        const l = try layers.at(i);
        const name = try (try l.get("name")).string();
        const slot = if (std.mem.eql(u8, name, "cells")) &cells_data else if (std.mem.eql(u8, name, "attributes")) &attrs_data else return (try l.get("name")).fail("not a layer of a tile map (cells, attributes)");
        if (slot.* != null) return (try l.get("name")).fail("a second layer of this name");
        if (!std.mem.eql(u8, try (try l.get("type")).string(), "tilelayer")) return (try l.get("type")).fail("not \"tilelayer\"");
        if (try (try l.get("width")).int(u16) != width or try (try l.get("height")).int(u16) != height) return l.fail("not the map's size");
        if (try l.opt("encoding") != null) return (try l.get("encoding")).fail("an encoded layer is not read: save the map with CSV layers");
        const data = try l.get("data");
        if (try data.len() != n) return data.fail("not one value a cell");
        slot.* = data;
    }
    const cells_node = cells_data orelse return layers.fail("no layer \"cells\"");
    const attrs_node = attrs_data orelse return layers.fail("no layer \"attributes\"");

    const cells = try arena.alloc(art.Cell, n);
    const cell_values = try cells_node.items();
    const attr_values = try attrs_node.items();
    for (cells, 0..) |*c, i| {
        const raw = number(cell_values[i]) orelse return (try cells_node.at(i)).fail("not a gid");
        c.* = .{};
        if (raw & flip_d != 0) return (try cells_node.at(i)).fail("a diagonal flip: the console flips only across and down");
        const gid = raw & gid_mask;
        if (gid != 0) {
            const r = rangeOf(Range, ranges, gid) orelse return (try cells_node.at(i)).fail("no tileset has this gid");
            if (r.attributes) return (try cells_node.at(i)).fail("an attributes tile in the cells layer");
            c.tile = @intCast(r.base + gid - r.first);
            c.flip_x = raw & flip_h != 0;
            c.flip_y = raw & flip_v != 0;
        }
        const araw = number(attr_values[i]) orelse return (try attrs_node.at(i)).fail("not a gid");
        if (araw == 0) continue;
        if (araw & ~gid_mask != 0) return (try attrs_node.at(i)).fail("a flipped attribute");
        const r = rangeOf(Range, ranges, araw) orelse return (try attrs_node.at(i)).fail("no tileset has this gid");
        if (!r.attributes) return (try attrs_node.at(i)).fail("not an attributes tile");
        const a = araw - r.first;
        c.palette = @intCast(a & 3);
        c.priority = a >= 4;
    }
    return .{ .width = width, .height = height, .sheets = sheets.items, .cells = cells };
}

fn number(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => |i| std.math.cast(u32, i),
        else => null,
    };
}

/// The tileset a gid falls in: the one with the largest first gid not above it, if the gid is
/// within its tiles.
fn rangeOf(comptime Range: type, ranges: []const Range, gid: u32) ?Range {
    var best: ?Range = null;
    for (ranges) |r| {
        if (r.first <= gid and (best == null or r.first > best.?.first)) best = r;
    }
    const r = best orelse return null;
    return if (gid - r.first < r.count) r else null;
}

const Sheets = struct {
    names: []const []const u8,
    counts: []const usize,

    fn count(self: *const Sheets, name: []const u8) ?usize {
        for (self.names, self.counts) |n, c| if (std.mem.eql(u8, n, name)) return c;
        return null;
    }
    fn image(_: *const Sheets, name: []const u8) error{OutOfMemory}![]const u8 {
        return if (std.mem.eql(u8, name, "fonts/main")) "../fonts/main.png" else "logo.png";
    }
};

test "a map writes and reads back, flips, palettes, priorities and empty cells" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cells = [_]art.Cell{
        .{ .tile = 0 },
        .{ .tile = 3, .flip_x = true, .palette = 2 },
        .{},
        .{ .tile = 5, .flip_y = true, .priority = true, .palette = 1 },
    };
    const map: art.TileMap = .{ .name = "logo", .file = "logo.tmj", .width = 2, .height = 2, .sheets = &.{ "title/logo", "fonts/main" }, .cells = &cells };
    const refs = [_]SheetRef{
        .{ .name = "title/logo", .count = 4, .image = "logo.png" },
        .{ .name = "fonts/main", .count = 49, .image = "../fonts/main.png" },
    };
    const text = try write(arena, &map, &refs, "../attributes.png");
    var diag: json.Diagnostic = .{};
    const root = try json.parse(arena, "title/logo.tmj", text, &diag);
    const sheets: Sheets = .{ .names = &.{ "title/logo", "fonts/main" }, .counts = &.{ 4, 49 } };
    const r = try read(root, &sheets, Sheets.count, Sheets.image, "../attributes.png");
    try std.testing.expectEqual(@as(u16, 2), r.width);
    try std.testing.expectEqualSlices(art.Cell, &cells, r.cells);
    try std.testing.expectEqualStrings("fonts/main", r.sheets[1]);
    // The same map writes the same bytes.
    try std.testing.expectEqualSlices(u8, text, try write(arena, &map, &refs, "../attributes.png"));
}

test "a map's refused values name their field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cells = [_]art.Cell{.{ .tile = 1 }};
    const map: art.TileMap = .{ .name = "logo", .file = "logo.tmj", .width = 1, .height = 1, .sheets = &.{"title/logo"}, .cells = &cells };
    const refs = [_]SheetRef{.{ .name = "title/logo", .count = 4, .image = "logo.png" }};
    const text = try write(arena, &map, &refs, "../attributes.png");
    var diag: json.Diagnostic = .{};
    // A sheet that has more tiles than the map's tileset says.
    const more: Sheets = .{ .names = &.{"title/logo"}, .counts = &.{5} };
    try std.testing.expectError(error.BadAsset, read(try json.parse(arena, "title/logo.tmj", text, &diag), &more, Sheets.count, Sheets.image, "../attributes.png"));
    try std.testing.expectEqualStrings("tilesets[0].tilecount", diag.fieldName());
    // A diagonal flip.
    const flipped = try std.mem.replaceOwned(u8, arena, text, "\"data\": [2]", "\"data\": [536870914]");
    const ok: Sheets = .{ .names = &.{"title/logo"}, .counts = &.{4} };
    try std.testing.expectError(error.BadAsset, read(try json.parse(arena, "title/logo.tmj", flipped, &diag), &ok, Sheets.count, Sheets.image, "../attributes.png"));
    try std.testing.expectEqualStrings("layers[0].data[0]", diag.fieldName());
    // A gid past the tilesets.
    const past = try std.mem.replaceOwned(u8, arena, text, "\"data\": [2]", "\"data\": [99]");
    try std.testing.expectError(error.BadAsset, read(try json.parse(arena, "title/logo.tmj", past, &diag), &ok, Sheets.count, Sheets.image, "../attributes.png"));
    try std.testing.expectEqualStrings("no tileset has this gid", diag.message);
}

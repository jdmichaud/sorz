//! The content tree's files (docs/content.md): its manifest, and the art written from the model
//! and read back into it. The same content always gives the same bytes, so two extractions of one
//! ROM are identical, and the tree in memory is the tree on disk.
//!
//! Layout: `manifest.json`; `attributes.png` (the attribute tiles of the maps); and a directory per
//! art set with its `art.json` and its pictures and maps.
const std = @import("std");
const json = @import("../formats/json.zig");
const png = @import("../formats/png.zig");
const platform = @import("../platform.zig");
const art = @import("art.zig");
const tiled = @import("tiled.zig");
const entity = @import("entity.zig");

/// The tree's format and version (`manifest.json`). A tree of another version is refused, not
/// converted.
pub const format_name = "sorz-content";
pub const version = 1;

pub const manifest_file = "manifest.json";
pub const art_file = "art.json";

/// A file of the tree: its path (lower case, `/` between directories) and its bytes.
pub const File = struct { path: []const u8, bytes: []const u8 };

/// The tree's description: who made it, from which ROM, and its art sets.
pub const Manifest = struct {
    extractor: []const u8,
    rom_sha256: []const u8,
    rom_size: u32,
    /// The art sets' directories, in order.
    art: []const []const u8,
    /// The kinds of entity the tree defines (`entities/NAME.json`), in order.
    entities: []const []const u8 = &.{},
};

pub const Content = struct {
    manifest: Manifest,
    art: art.Art,
    /// The kinds of entity, in the manifest's order.
    entities: []const entity.Definition = &.{},
};

// --- Writing ---------------------------------------------------------------------------------

pub const WriteError = error{ OutOfMemory, BadContent };

/// The files of `content`, sorted by path.
pub fn write(arena: std.mem.Allocator, content: *const Content) WriteError![]File {
    var files: std.ArrayList(File) = .empty;
    try files.append(arena, .{ .path = manifest_file, .bytes = try writeJson(arena, try manifestValue(arena, &content.manifest)) });
    var any_map = false;
    for (content.art.sets) |*s| {
        try writeSet(arena, &content.art, s, &files);
        any_map = any_map or s.maps.len != 0;
    }
    if (any_map) try files.append(arena, .{ .path = tiled.attributes_file, .bytes = try attributesPicture(arena) });
    if (content.entities.len != content.manifest.entities.len) return error.BadContent;
    for (content.entities, content.manifest.entities) |*d, name| {
        if (!std.mem.eql(u8, d.name, name)) return error.BadContent;
        try files.append(arena, .{ .path = try entity.path(arena, d.name), .bytes = try writeJson(arena, try entity.value(arena, d)) });
    }
    std.mem.sort(File, files.items, {}, fileLess);
    for (files.items[1..], 0..) |f, i| {
        if (std.mem.eql(u8, f.path, files.items[i].path)) return error.BadContent;
    }
    return files.items;
}

fn fileLess(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn writeJson(arena: std.mem.Allocator, v: json.Value) WriteError![]u8 {
    return json.write(arena, v) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadContent,
    };
}

fn manifestValue(arena: std.mem.Allocator, m: *const Manifest) !json.Value {
    const sets = try arena.alloc(json.Value, m.art.len);
    for (sets, m.art) |*v, s| v.* = .{ .str = s };
    var fields: std.ArrayList(json.Field) = .empty;
    try fields.appendSlice(arena, &.{
        .{ .key = "format", .value = .{ .str = format_name } },
        .{ .key = "version", .value = json.Value.num(version) },
        .{ .key = "extractor", .value = .{ .str = m.extractor } },
        .{ .key = "rom", .value = try obj(arena, &.{
            .{ .key = "sha256", .value = .{ .str = m.rom_sha256 } },
            .{ .key = "size", .value = json.Value.num(m.rom_size) },
        }) },
        .{ .key = "art", .value = .{ .array = sets } },
    });
    // A tree without definitions keeps the manifest it had before them.
    if (m.entities.len != 0) {
        const kinds = try arena.alloc(json.Value, m.entities.len);
        for (kinds, m.entities) |*v, s| v.* = .{ .str = s };
        try fields.append(arena, .{ .key = "entities", .value = .{ .array = kinds } });
    }
    return .{ .object = fields.items };
}

fn obj(arena: std.mem.Allocator, fields: []const json.Field) !json.Value {
    return .{ .object = try arena.dupe(json.Field, fields) };
}

fn ints(arena: std.mem.Allocator, xs: anytype) !json.Value {
    const out = try arena.alloc(json.Value, xs.len);
    for (out, xs) |*o, x| o.* = json.Value.num(x);
    return .{ .array = out };
}

/// The fields of an asset: its provenance first, when it has one.
fn assetFields(arena: std.mem.Allocator, provenance: []const u8, rest: []const json.Field) !json.Value {
    var fields: std.ArrayList(json.Field) = .empty;
    if (provenance.len != 0) try fields.append(arena, .{ .key = "provenance", .value = .{ .str = provenance } });
    try fields.appendSlice(arena, rest);
    return .{ .object = fields.items };
}

fn colourValue(arena: std.mem.Allocator, c: art.Colour) !json.Value {
    return ints(arena, &[_]u8{ c.r, c.g, c.b });
}

/// Colours for the four palettes: an object of the palettes given ("0" to "3"), each 16 colours
/// `[r, g, b]` or null.
fn coloursValue(arena: std.mem.Allocator, colours: *const [art.palette_count][art.palette_size]?art.Colour) !json.Value {
    var lines: std.ArrayList(json.Field) = .empty;
    for (colours, 0..) |line, k| {
        for (line) |c| {
            if (c != null) break;
        } else continue;
        const cs = try arena.alloc(json.Value, art.palette_size);
        for (cs, line) |*v, c| v.* = if (c) |colour| try colourValue(arena, colour) else .null;
        try lines.append(arena, .{ .key = try std.fmt.allocPrint(arena, "{d}", .{k}), .value = .{ .array = cs } });
    }
    return .{ .object = lines.items };
}

/// `path`'s join to the set's directory.
fn setPath(arena: std.mem.Allocator, set: []const u8, file: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ set, file });
}

/// The path of `target` (a path from the tree's root) from the directory of set `from`.
fn relative(arena: std.mem.Allocator, from: []const u8, target: []const u8) ![]const u8 {
    const depth = std.mem.count(u8, from, "/") + 1;
    var out: std.ArrayList(u8) = .empty;
    for (0..depth) |_| try out.appendSlice(arena, "../");
    try out.appendSlice(arena, target);
    return out.items;
}

/// The path, from set `from`'s directory, of sheet `name`'s picture.
fn sheetImage(arena: std.mem.Allocator, a: *const art.Art, from: []const u8, name: []const u8) ![]const u8 {
    const sheet = a.sheet(name) orelse return error.BadContent;
    const set = name[0..std.mem.lastIndexOfScalar(u8, name, '/').?];
    if (std.mem.eql(u8, set, from)) return sheet.file;
    return relative(arena, from, try setPath(arena, set, sheet.file));
}

fn writeSet(arena: std.mem.Allocator, a: *const art.Art, s: *const art.ArtSet, files: *std.ArrayList(File)) !void {
    var top: std.ArrayList(json.Field) = .empty;
    if (s.provenance.len != 0) try top.append(arena, .{ .key = "provenance", .value = .{ .str = s.provenance } });
    if (s.uses.len != 0) {
        const uses = try arena.alloc(json.Value, s.uses.len);
        for (uses, s.uses) |*u, n| u.* = .{ .str = n };
        try top.append(arena, .{ .key = "uses", .value = .{ .array = uses } });
    }

    if (s.palettes.len != 0) {
        const entries = try arena.alloc(json.Field, s.palettes.len);
        for (entries, s.palettes) |*e, *p| {
            e.* = .{ .key = p.name, .value = try assetFields(arena, p.provenance, &.{.{ .key = "colours", .value = try coloursValue(arena, &p.colours) }}) };
        }
        try top.append(arena, .{ .key = "palettes", .value = .{ .object = entries } });
    }

    if (s.cycles.len != 0) {
        const entries = try arena.alloc(json.Field, s.cycles.len);
        for (entries, s.cycles) |*e, *c| {
            const steps = try arena.alloc(json.Value, c.steps.len);
            for (steps, c.steps) |*v, *st| v.* = try coloursValue(arena, st);
            e.* = .{ .key = c.name, .value = try assetFields(arena, c.provenance, &.{
                .{ .key = "period", .value = json.Value.num(c.period) },
                .{ .key = "steps", .value = .{ .array = steps } },
            }) };
        }
        try top.append(arena, .{ .key = "cycles", .value = .{ .object = entries } });
    }

    if (s.steps.len != 0) {
        const entries = try arena.alloc(json.Field, s.steps.len);
        for (entries, s.steps) |*e, *c| {
            const steps = try arena.alloc(json.Value, c.steps.len);
            for (steps, c.steps) |*v, *st| v.* = try coloursValue(arena, st);
            e.* = .{ .key = c.name, .value = try assetFields(arena, c.provenance, &.{.{ .key = "steps", .value = .{ .array = steps } }}) };
        }
        try top.append(arena, .{ .key = "steps", .value = .{ .object = entries } });
    }

    if (s.sheets.len != 0) {
        const entries = try arena.alloc(json.Field, s.sheets.len);
        for (entries, s.sheets) |*e, *sh| {
            e.* = .{ .key = sh.name, .value = try assetFields(arena, sh.provenance, &.{
                .{ .key = "file", .value = .{ .str = sh.file } },
                .{ .key = "count", .value = json.Value.num(sh.tiles.len) },
            }) };
            try files.append(arena, .{ .path = try setPath(arena, s.name, sh.file), .bytes = try sheetPicture(arena, sh) });
        }
        try top.append(arena, .{ .key = "tiles", .value = .{ .object = entries } });
    }

    if (s.maps.len != 0) {
        const entries = try arena.alloc(json.Field, s.maps.len);
        for (entries, s.maps) |*e, *m| {
            var rest: std.ArrayList(json.Field) = .empty;
            try rest.append(arena, .{ .key = "file", .value = .{ .str = m.file } });
            if (m.place) |p| try rest.append(arena, .{ .key = "at", .value = try obj(arena, &.{
                .{ .key = "layer", .value = .{ .str = @tagName(p.layer) } },
                .{ .key = "x", .value = json.Value.num(p.x) },
                .{ .key = "y", .value = json.Value.num(p.y) },
            }) });
            e.* = .{ .key = m.name, .value = try assetFields(arena, m.provenance, rest.items) };
            const refs = try arena.alloc(tiled.SheetRef, m.sheets.len);
            for (refs, m.sheets) |*r, name| {
                const sheet = a.sheet(name) orelse return error.BadContent;
                r.* = .{ .name = name, .count = sheet.tiles.len, .image = try sheetImage(arena, a, s.name, name) };
            }
            const text = tiled.write(arena, m, refs, try relative(arena, s.name, tiled.attributes_file)) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.BadContent,
            };
            try files.append(arena, .{ .path = try setPath(arena, s.name, m.file), .bytes = text });
        }
        try top.append(arena, .{ .key = "maps", .value = .{ .object = entries } });
    }

    if (s.frames.len != 0) {
        const entries = try arena.alloc(json.Field, s.frames.len);
        for (entries, s.frames) |*e, *f| {
            const pieces = try arena.alloc(json.Value, f.pieces.len);
            for (pieces, f.pieces) |*v, p| v.* = try ints(arena, &[_]i32{ p.x, p.y, p.width, p.height });
            e.* = .{ .key = f.name, .value = try assetFields(arena, f.provenance, &.{
                .{ .key = "file", .value = .{ .str = f.file } },
                .{ .key = "origin", .value = try ints(arena, &[_]i16{ f.origin_x, f.origin_y }) },
                .{ .key = "palette", .value = json.Value.num(f.palette) },
                .{ .key = "priority", .value = .{ .bool = f.priority } },
                .{ .key = "pieces", .value = .{ .array = pieces } },
            }) };
            try files.append(arena, .{ .path = try setPath(arena, s.name, f.file), .bytes = try picture(arena, f.width, f.height, f.pixels, f.view) });
        }
        try top.append(arena, .{ .key = "frames", .value = .{ .object = entries } });
    }

    if (s.fonts.len != 0) {
        const entries = try arena.alloc(json.Field, s.fonts.len);
        for (entries, s.fonts) |*e, *f| {
            const glyphs = try arena.alloc(json.Field, f.glyphs.len);
            for (glyphs, f.glyphs) |*g, x| g.* = .{ .key = x.text, .value = json.Value.num(x.tile) };
            e.* = .{ .key = f.name, .value = try assetFields(arena, f.provenance, &.{
                .{ .key = "tiles", .value = .{ .str = f.sheet } },
                .{ .key = "glyphs", .value = .{ .object = glyphs } },
            }) };
        }
        try top.append(arena, .{ .key = "fonts", .value = .{ .object = entries } });
    }

    try files.append(arena, .{ .path = try setPath(arena, s.name, art_file), .bytes = try writeJson(arena, .{ .object = top.items }) });
}

fn picture(arena: std.mem.Allocator, w: u32, h: u32, pixels: []const u8, view: [art.palette_size]art.Colour) WriteError![]u8 {
    var pal: [art.palette_size][3]u8 = undefined;
    for (&pal, view) |*p, c| p.* = c.rgb();
    return png.encode(arena, w, h, pixels, &pal) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadContent,
    };
}

/// A sheet's picture: 16 tiles a row, in order; the last row's unused tiles transparent.
fn sheetPicture(arena: std.mem.Allocator, sheet: *const art.TileSheet) WriteError![]u8 {
    const cols = tiled.sheet_columns;
    const rows = (@max(sheet.tiles.len, 1) + cols - 1) / cols;
    const w = cols * art.tile_side;
    const h = rows * art.tile_side;
    const px = try arena.alloc(u8, w * h);
    @memset(px, 0);
    for (sheet.tiles, 0..) |t, i| {
        const tx = (i % cols) * art.tile_side;
        const ty = (i / cols) * art.tile_side;
        for (0..art.tile_side) |y| @memcpy(px[(ty + y) * w + tx ..][0..art.tile_side], t[y * art.tile_side ..][0..art.tile_side]);
    }
    return picture(arena, @intCast(w), @intCast(h), px, sheet.view);
}

/// The attribute tiles: palette p with priority q is tile p + 4q, a swatch of colour 1 + p (with
/// priority, 9 + p) inside a border.
fn attributesPicture(arena: std.mem.Allocator) WriteError![]u8 {
    const w = tiled.attributes_count * art.tile_side;
    const px = try arena.alloc(u8, w * art.tile_side);
    for (0..art.tile_side) |y| for (0..w) |x| {
        const t = x / art.tile_side;
        const edge = x % art.tile_side == 0 or y == 0;
        px[y * w + x] = if (edge) 0 else @intCast(1 + (t % 4) + 8 * (t / 4));
    };
    var view: [art.palette_size]art.Colour = @splat(art.Colour.black);
    const swatches = [4]art.Colour{ .{ .r = 6, .g = 2, .b = 2 }, .{ .r = 2, .g = 6, .b = 2 }, .{ .r = 2, .g = 2, .b = 6 }, .{ .r = 6, .g = 6, .b = 2 } };
    for (swatches, 0..) |c, i| {
        view[1 + i] = c;
        view[9 + i] = .{ .r = c.r / 2, .g = c.g / 2, .b = c.b / 2 };
    }
    return picture(arena, @intCast(w), art.tile_side, px, view);
}

// --- Reading ---------------------------------------------------------------------------------

pub const Error = json.Error;
pub const Diagnostic = json.Diagnostic;

/// The largest file the loader reads.
pub const max_file = 16 << 20;

/// Reads the whole tree's manifest and art from `source`, checking every file and every value;
/// a refusal names the file and the field (or place) in `diag`.
pub fn load(arena: std.mem.Allocator, source: platform.AssetSource, diag: *Diagnostic) Error!Content {
    const m = try loadManifest(arena, source, diag);
    const a = try loadArt(arena, source, m.art, diag);
    return .{ .manifest = m, .art = a, .entities = try loadEntities(arena, source, m.entities, &a, diag) };
}

/// Reads the definitions `names` (`entities/NAME.json`), whose frames are `a`'s.
pub fn loadEntities(arena: std.mem.Allocator, source: platform.AssetSource, names: []const []const u8, a: *const art.Art, diag: *Diagnostic) Error![]const entity.Definition {
    const out = try arena.alloc(entity.Definition, names.len);
    for (out, names) |*d, name| {
        const root = try parseFile(arena, source, try entity.path(arena, name), diag);
        d.* = try entity.read(arena, name, root, a);
    }
    return out;
}

fn readFile(arena: std.mem.Allocator, source: platform.AssetSource, path: []const u8, diag: *Diagnostic) Error![]const u8 {
    var owned = source.readAll(path, max_file) catch |e| {
        diag.* = .{ .file = path };
        diag.message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotFound => "missing",
            error.InvalidName => "not a valid file name",
            error.TooLarge => "too large",
            else => "cannot be read",
        };
        return error.BadAsset;
    };
    defer owned.deinit();
    return arena.dupe(u8, owned.bytes);
}

fn parseFile(arena: std.mem.Allocator, source: platform.AssetSource, path: []const u8, diag: *Diagnostic) Error!json.Node {
    return json.parse(arena, path, try readFile(arena, source, path, diag), diag);
}

pub fn loadManifest(arena: std.mem.Allocator, source: platform.AssetSource, diag: *Diagnostic) Error!Manifest {
    const root = try parseFile(arena, source, manifest_file, diag);
    try root.only(&.{ "format", "version", "extractor", "rom", "art", "entities" });
    const f = try root.get("format");
    if (!std.mem.eql(u8, try f.string(), format_name)) return f.fail("not \"" ++ format_name ++ "\"");
    const v = try root.get("version");
    if (try v.int(i64) != version) return v.fail(std.fmt.comptimePrint("not version {d}: extract the tree again", .{version}));
    const rom = try root.get("rom");
    try rom.only(&.{ "sha256", "size" });
    const sets_node = try root.get("art");
    const sets = try arena.alloc([]const u8, try sets_node.len());
    for (sets, 0..) |*s, i| {
        const n = try sets_node.at(i);
        s.* = try n.string();
        if (!art.validSetName(s.*)) return n.fail("not a set's name (a-z, 0-9, _; / between directories)");
        for (sets[0..i]) |other| if (std.mem.eql(u8, other, s.*)) return n.fail("named twice");
    }
    var kinds: []const []const u8 = &.{};
    if (try root.opt("entities")) |kinds_node| {
        const out = try arena.alloc([]const u8, try kinds_node.len());
        for (out, 0..) |*s, i| {
            const n = try kinds_node.at(i);
            s.* = try n.string();
            if (!art.validName(s.*)) return n.fail("not a kind's name (a-z, 0-9, _)");
            for (out[0..i]) |other| if (std.mem.eql(u8, other, s.*)) return n.fail("named twice");
        }
        kinds = out;
    }
    return .{
        .extractor = try (try root.get("extractor")).string(),
        .rom_sha256 = try (try rom.get("sha256")).string(),
        .rom_size = try (try rom.get("size")).int(u32),
        .art = sets,
        .entities = kinds,
    };
}

/// Reads the art sets `names` (their directories' `art.json` and files).
pub fn loadArt(arena: std.mem.Allocator, source: platform.AssetSource, names: []const []const u8, diag: *Diagnostic) Error!art.Art {
    const sets = try arena.alloc(art.ArtSet, names.len);
    const roots = try arena.alloc(json.Node, names.len);
    // First pass: everything but the maps, which may draw from another set's sheets.
    for (sets, roots, names) |*s, *root, name| {
        root.* = try parseFile(arena, source, try setPath(arena, name, art_file), diag);
        s.* = try loadSet(arena, source, name, root.*, diag);
    }
    const result: art.Art = .{ .sets = sets };
    for (sets, roots) |*s, root| {
        for (s.uses) |u| if (result.set(u) == null) {
            diag.* = .{ .file = try setPath(arena, s.name, art_file) };
            return (try root.get("uses")).fail(try std.fmt.allocPrint(arena, "no art set \"{s}\"", .{u}));
        };
        for (s.fonts) |f| if (result.sheet(f.sheet) == null) {
            diag.* = .{ .file = try setPath(arena, s.name, art_file) };
            const n = try (try root.get("fonts")).get(f.name);
            return (try n.get("tiles")).fail("no tile sheet of this name");
        };
        s.maps = try loadMaps(arena, source, &result, s.name, root, diag);
    }
    for (sets) |*s| for (s.fonts) |f| {
        const count = result.sheet(f.sheet).?.tiles.len;
        for (f.glyphs) |g| if (g.tile >= count) {
            diag.* = .{ .file = try setPath(arena, s.name, art_file) };
            diag.setPlace("fonts.{s}.glyphs.{s}", .{ f.name, g.text });
            diag.message = "past the sheet's tiles";
            return error.BadAsset;
        };
    };
    return result;
}

const Pass = struct {
    arena: std.mem.Allocator,
    source: platform.AssetSource,
    set: []const u8,
    diag: *Diagnostic,
};

fn checkName(node: json.Node, key: []const u8) Error!void {
    if (!art.validName(key)) return node.fail("not an asset's name (a-z, 0-9, _)");
}

/// A `file` field: a relative path within the set's directory.
fn fileField(n: json.Node) Error![]const u8 {
    const f = try n.get("file");
    const s = try f.string();
    platform.validateAssetName(s) catch return f.fail("not a file name of the set's directory");
    return s;
}

fn readProvenance(n: json.Node) Error![]const u8 {
    return if (try n.opt("provenance")) |p| p.string() else "";
}

fn loadSet(arena: std.mem.Allocator, source: platform.AssetSource, name: []const u8, root: json.Node, diag: *Diagnostic) Error!art.ArtSet {
    const p: Pass = .{ .arena = arena, .source = source, .set = name, .diag = diag };
    try root.only(&.{ "provenance", "uses", "palettes", "cycles", "steps", "tiles", "maps", "frames", "fonts" });
    var s: art.ArtSet = .{ .name = name, .provenance = try readProvenance(root) };
    if (try root.opt("uses")) |u| {
        const uses = try arena.alloc([]const u8, try u.len());
        for (uses, 0..) |*x, i| x.* = try (try u.at(i)).string();
        s.uses = uses;
    }
    if (try root.opt("palettes")) |n| s.palettes = try loadPalettes(p, n);
    if (try root.opt("cycles")) |n| s.cycles = try loadCycles(p, n);
    if (try root.opt("steps")) |n| s.steps = try loadSteps(p, n);
    if (try root.opt("tiles")) |n| s.sheets = try loadSheets(p, n, root);
    if (try root.opt("frames")) |n| s.frames = try loadFrames(p, n, root);
    if (try root.opt("fonts")) |n| s.fonts = try loadFonts(p, n);
    return s;
}

fn loadPalettes(p: Pass, node: json.Node) Error![]const art.Palette {
    var it = try node.fields();
    const out = try p.arena.alloc(art.Palette, it.count());
    for (out) |*pal| {
        const e = (try it.next()).?;
        try checkName(e.value, e.key);
        try e.value.only(&.{ "provenance", "colours" });
        pal.* = .{ .name = e.key, .provenance = try readProvenance(e.value), .colours = try readColours(try e.value.get("colours")) };
    }
    return out;
}

/// Colours for the four palettes (a palette's, a cycle's step).
fn readColours(node: json.Node) Error![art.palette_count][art.palette_size]?art.Colour {
    var out: [art.palette_count][art.palette_size]?art.Colour = @splat(@splat(null));
    var lines = try node.fields();
    while (try lines.next()) |l| {
        const k = std.fmt.parseInt(u8, l.key, 10) catch return l.value.fail("not a palette's number (0 to 3)");
        if (k >= art.palette_count or l.key.len != 1) return l.value.fail("not a palette's number (0 to 3)");
        if (try l.value.len() != art.palette_size) return l.value.fail("not 16 colours");
        for (0..art.palette_size) |i| {
            const c = try l.value.at(i);
            if (c.isNull()) continue;
            if (try c.len() != 3) return c.fail("not [red, green, blue]");
            var rgb: [3]u3 = undefined;
            for (&rgb, 0..) |*x, j| {
                const v = try c.at(j);
                x.* = std.math.cast(u3, try v.int(i64)) orelse return v.fail("not 0 to 7");
            }
            out[k][i] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        }
    }
    return out;
}

fn loadCycles(p: Pass, node: json.Node) Error![]const art.Cycle {
    var it = try node.fields();
    const out = try p.arena.alloc(art.Cycle, it.count());
    for (out) |*c| {
        const e = (try it.next()).?;
        try checkName(e.value, e.key);
        try e.value.only(&.{ "provenance", "period", "steps" });
        const period_node = try e.value.get("period");
        const period = try period_node.int(u16);
        if (period == 0) return period_node.fail("not 1 or more");
        const steps_node = try e.value.get("steps");
        const steps = try p.arena.alloc([art.palette_count][art.palette_size]?art.Colour, try steps_node.len());
        if (steps.len == 0) return steps_node.fail("no step");
        for (steps, 0..) |*s, i| s.* = try readColours(try steps_node.at(i));
        c.* = .{ .name = e.key, .provenance = try readProvenance(e.value), .period = period, .steps = steps };
    }
    return out;
}

fn loadSteps(p: Pass, node: json.Node) Error![]const art.PaletteSteps {
    var it = try node.fields();
    const out = try p.arena.alloc(art.PaletteSteps, it.count());
    for (out) |*c| {
        const e = (try it.next()).?;
        try checkName(e.value, e.key);
        try e.value.only(&.{ "provenance", "steps" });
        const steps_node = try e.value.get("steps");
        const steps = try p.arena.alloc([art.palette_count][art.palette_size]?art.Colour, try steps_node.len());
        if (steps.len == 0) return steps_node.fail("no step");
        for (steps, 0..) |*s, i| s.* = try readColours(try steps_node.at(i));
        c.* = .{ .name = e.key, .provenance = try readProvenance(e.value), .steps = steps };
    }
    return out;
}

/// A set's picture: its indices (each 0 to 15) and its palette's first 16 colours.
const Picture = struct { width: u32, height: u32, pixels: []u8, view: [art.palette_size]art.Colour };

fn loadPicture(p: Pass, file: []const u8) Error!Picture {
    const path = try setPath(p.arena, p.set, file);
    const bytes = try readFile(p.arena, p.source, path, p.diag);
    var img = png.decode(p.arena, bytes) catch |e| {
        p.diag.* = .{ .file = path };
        p.diag.message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotPng => "not a PNG picture",
            error.NotIndexed => "not an indexed picture (palette colours)",
            error.Interlaced => "interlaced",
            error.TooLarge => "too large",
            error.NoPalette => "no palette",
            error.IndexOutOfPalette => "a pixel past the palette",
            else => "a damaged PNG picture",
        };
        return error.BadAsset;
    };
    for (img.pixels, 0..) |px, i| if (px >= art.palette_size) {
        p.diag.* = .{ .file = path };
        p.diag.setPlace("pixel ({d}, {d})", .{ i % img.width, i / img.width });
        p.diag.message = "a colour index above 15";
        return error.BadAsset;
    };
    var view: [art.palette_size]art.Colour = @splat(art.Colour.black);
    for (view[0..@min(art.palette_size, img.palette.len)], img.palette[0..@min(art.palette_size, img.palette.len)]) |*v, c| v.* = art.Colour.fromRgb(c);
    return .{ .width = img.width, .height = img.height, .pixels = img.pixels, .view = view };
}

fn loadSheets(p: Pass, node: json.Node, root: json.Node) Error![]const art.TileSheet {
    _ = root;
    var it = try node.fields();
    const out = try p.arena.alloc(art.TileSheet, it.count());
    for (out) |*sheet| {
        const e = (try it.next()).?;
        try checkName(e.value, e.key);
        try e.value.only(&.{ "provenance", "file", "count" });
        const file = try fileField(e.value);
        const count_node = try e.value.get("count");
        const count = try count_node.int(u16);
        const pic = try loadPicture(p, file);
        if (pic.width % art.tile_side != 0 or pic.height % art.tile_side != 0) {
            p.diag.* = .{ .file = try setPath(p.arena, p.set, file), .message = "not a whole number of 8x8 tiles" };
            return error.BadAsset;
        }
        const cols = pic.width / art.tile_side;
        if (count > cols * (pic.height / art.tile_side)) return count_node.fail("more tiles than the picture holds");
        const tiles = try p.arena.alloc(art.Tile, count);
        for (tiles, 0..) |*t, i| {
            const tx = (i % cols) * art.tile_side;
            const ty = (i / cols) * art.tile_side;
            for (0..art.tile_side) |y| @memcpy(t[y * art.tile_side ..][0..art.tile_side], pic.pixels[(ty + y) * pic.width + tx ..][0..art.tile_side]);
        }
        sheet.* = .{ .name = e.key, .provenance = try readProvenance(e.value), .file = file, .tiles = tiles, .view = pic.view };
    }
    return out;
}

fn loadFrames(p: Pass, node: json.Node, root: json.Node) Error![]const art.Frame {
    _ = root;
    var it = try node.fields();
    const out = try p.arena.alloc(art.Frame, it.count());
    for (out) |*f| {
        const e = (try it.next()).?;
        try checkName(e.value, e.key);
        try e.value.only(&.{ "provenance", "file", "origin", "palette", "priority", "pieces" });
        const file = try fileField(e.value);
        const pic = try loadPicture(p, file);
        const origin = try e.value.get("origin");
        if (try origin.len() != 2) return origin.fail("not [x, y]");
        const pieces_node = try e.value.get("pieces");
        const pieces = try p.arena.alloc(art.Piece, try pieces_node.len());
        for (pieces, 0..) |*piece, i| {
            const n = try pieces_node.at(i);
            if (try n.len() != 4) return n.fail("not [x, y, width, height]");
            piece.* = .{ .x = try (try n.at(0)).int(i16), .y = try (try n.at(1)).int(i16), .width = try (try n.at(2)).int(u8), .height = try (try n.at(3)).int(u8) };
            if (piece.width < 1 or piece.width > 4 or piece.height < 1 or piece.height > 4) return n.fail("a piece is 1 to 4 cells wide and high");
        }
        f.* = .{
            .name = e.key,
            .provenance = try readProvenance(e.value),
            .file = file,
            .width = std.math.cast(u16, pic.width) orelse return e.value.fail("too large"),
            .height = std.math.cast(u16, pic.height) orelse return e.value.fail("too large"),
            .origin_x = try (try origin.at(0)).int(i16),
            .origin_y = try (try origin.at(1)).int(i16),
            .pixels = pic.pixels,
            .palette = try (try e.value.get("palette")).int(u2),
            .priority = try (try e.value.get("priority")).boolean(),
            .pieces = pieces,
            .view = pic.view,
        };
    }
    return out;
}

fn loadFonts(p: Pass, node: json.Node) Error![]const art.Font {
    var it = try node.fields();
    const out = try p.arena.alloc(art.Font, it.count());
    for (out) |*f| {
        const e = (try it.next()).?;
        try checkName(e.value, e.key);
        try e.value.only(&.{ "provenance", "tiles", "glyphs" });
        var gl = try (try e.value.get("glyphs")).fields();
        const glyphs = try p.arena.alloc(art.Glyph, gl.count());
        for (glyphs) |*g| {
            const x = (try gl.next()).?;
            if (x.key.len == 0) return x.value.fail("an empty glyph");
            g.* = .{ .text = x.key, .tile = try x.value.int(u16) };
        }
        f.* = .{ .name = e.key, .provenance = try readProvenance(e.value), .sheet = try (try e.value.get("tiles")).string(), .glyphs = glyphs };
    }
    return out;
}

fn loadMaps(arena: std.mem.Allocator, source: platform.AssetSource, a: *const art.Art, set: []const u8, root: json.Node, diag: *Diagnostic) Error![]const art.TileMap {
    const node = try root.opt("maps") orelse return &.{};
    var it = try node.fields();
    const out = try arena.alloc(art.TileMap, it.count());
    const Lookup = struct {
        a: *const art.Art,
        arena: std.mem.Allocator,
        set: []const u8,
        fn count(self: @This(), name: []const u8) ?usize {
            return if (self.a.sheet(name)) |s| s.tiles.len else null;
        }
        fn image(self: @This(), name: []const u8) error{OutOfMemory}![]const u8 {
            return sheetImage(self.arena, self.a, self.set, name) catch |e| switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.BadContent => unreachable, // `count` found the sheet first
            };
        }
    };
    const lookup: Lookup = .{ .a = a, .arena = arena, .set = set };
    for (out) |*m| {
        const e = (try it.next()).?;
        try checkName(e.value, e.key);
        try e.value.only(&.{ "provenance", "file", "at" });
        const file = try fileField(e.value);
        var place: ?art.Place = null;
        if (try e.value.opt("at")) |at| {
            try at.only(&.{ "layer", "x", "y" });
            const l = try at.get("layer");
            place = .{
                .layer = std.meta.stringToEnum(art.Layer, try l.string()) orelse return l.fail("not a layer (plane_a, plane_b, window)"),
                .x = try (try at.get("x")).int(u16),
                .y = try (try at.get("y")).int(u16),
            };
        }
        const prov = try readProvenance(e.value);
        const map_path = try setPath(arena, set, file);
        const map_root = try parseFile(arena, source, map_path, diag);
        const r = try tiled.read(map_root, lookup, Lookup.count, Lookup.image, try relative(arena, set, tiled.attributes_file));
        var tiles: std.ArrayList(art.Tile) = .empty;
        for (r.sheets) |name| try tiles.appendSlice(arena, a.sheet(name).?.tiles);
        m.* = .{
            .name = e.key,
            .provenance = prov,
            .file = file,
            .width = r.width,
            .height = r.height,
            .sheets = r.sheets,
            .tiles = tiles.items,
            .cells = r.cells,
            .place = place,
        };
    }
    return out;
}

test "a tree writes, loads back the same, and writes the same bytes again" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tiles: [3]art.Tile = undefined;
    for (&tiles, 0..) |*t, i| {
        for (t, 0..) |*px, k| px.* = @intCast((i * 5 + k) % 16);
    }
    var view = art.grey;
    view[1] = .{ .r = 7, .g = 0, .b = 0 };
    const sheets = [_]art.TileSheet{.{ .name = "logo", .provenance = "synthetic", .file = "logo.png", .tiles = &tiles, .view = view }};
    const font_tiles: [2]art.Tile = @splat(@splat(0));
    const font_sheets = [_]art.TileSheet{.{ .name = "main", .file = "main.png", .tiles = &font_tiles }};
    const glyphs = [_]art.Glyph{ .{ .text = " ", .tile = 0 }, .{ .text = "A", .tile = 1 } };
    const fonts = [_]art.Font{.{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs }};
    const cells = [_]art.Cell{ .{ .tile = 2, .flip_x = true, .palette = 1 }, .{}, .{ .tile = 4, .priority = true }, .{ .tile = 0 } };
    const maps = [_]art.TileMap{.{ .name = "logo", .file = "logo.tmj", .width = 2, .height = 2, .sheets = &.{ "title/logo", "fonts/main" }, .cells = &cells, .place = .{ .layer = .plane_a, .x = 3, .y = 4 } }};
    var pal: art.Palette = .{ .name = "sky", .provenance = "synthetic" };
    pal.colours[1][3] = .{ .r = 1, .g = 2, .b = 3 };
    var step_1: [art.palette_count][art.palette_size]?art.Colour = @splat(@splat(null));
    step_1[2][10] = .{ .r = 7, .g = 7, .b = 0 };
    var step_2 = step_1;
    step_2[2][10] = .{ .r = 0, .g = 0, .b = 7 };
    const cycles = [_]art.Cycle{.{ .name = "neon", .period = 4, .steps = &.{ step_1, step_2 } }};
    const palette_steps = [_]art.PaletteSteps{.{ .name = "sweep", .provenance = "synthetic", .steps = &.{ step_2, step_1, step_2 } }};
    const pixels = [_]u8{ 0, 1, 2, 3, 4, 5 };
    const pieces = [_]art.Piece{.{ .x = -1, .y = -2, .width = 1, .height = 1 }};
    const frames = [_]art.Frame{.{ .name = "000", .file = "000.png", .width = 3, .height = 2, .origin_x = 1, .origin_y = 2, .pixels = &pixels, .palette = 3, .priority = true, .pieces = &pieces }};
    const sets = [_]art.ArtSet{
        .{ .name = "fonts", .sheets = &font_sheets, .fonts = &fonts },
        .{ .name = "title", .provenance = "synthetic", .uses = &.{"fonts"}, .palettes = &.{pal}, .cycles = &cycles, .steps = &palette_steps, .sheets = &sheets, .maps = &maps, .frames = &frames },
    };
    const boxes = [_]entity.Box{.{ .name = "body", .x = .{ .from = -4, .to = 4 }, .depth = .{ .from = -1, .to = 1 }, .height = .{ .from = -20, .to = 0 } }};
    const steps = [_]entity.Frame{.{ .frame = "title/000", .ticks = 5, .body = 0 }};
    const animations = [_]entity.Animation{.{ .name = "stand", .loop = true, .frames = &steps }};
    const kinds = [_]entity.Definition{.{ .name = "dummy", .family = .scenery, .team = .neutral, .behaviour = "still", .boxes = &boxes, .animations = &animations }};
    const content: Content = .{
        .manifest = .{ .extractor = "test", .rom_sha256 = "00", .rom_size = 1, .art = &.{ "fonts", "title" }, .entities = &.{"dummy"} },
        .art = .{ .sets = &sets },
        .entities = &kinds,
    };
    const files = try write(arena, &content);

    var source = @import("../memory.zig").MemoryAssetSource.init(gpa);
    defer source.deinit();
    for (files) |f| try source.add(f.path, f.bytes);
    var diag: Diagnostic = .{};
    const back = load(arena, source.assetSource(), &diag) catch |e| {
        std.debug.print("{f}\n", .{&diag});
        return e;
    };
    const m = back.art.map("title/logo").?;
    try std.testing.expectEqualSlices(art.Cell, &cells, m.cells);
    try std.testing.expectEqual(@as(usize, 5), m.tiles.len);
    try std.testing.expectEqualSlices(u8, &tiles[2], &m.tiles[2]);
    try std.testing.expectEqual(art.Place{ .layer = .plane_a, .x = 3, .y = 4 }, m.place.?);
    try std.testing.expect(back.art.palette("title/sky").?.colours[1][3].?.eql(.{ .r = 1, .g = 2, .b = 3 }));
    const neon = back.art.cycle("title/neon").?;
    try std.testing.expectEqual(@as(u16, 4), neon.period);
    try std.testing.expect(neon.steps[1][2][10].?.eql(.{ .r = 0, .g = 0, .b = 7 }) and neon.steps[1][2][9] == null);
    const sweep = back.art.steps("title/sweep").?;
    try std.testing.expectEqual(@as(usize, 3), sweep.steps.len);
    try std.testing.expect(sweep.steps[1][2][10].?.eql(.{ .r = 7, .g = 7, .b = 0 }) and sweep.steps[1][0][0] == null);
    try std.testing.expect(back.art.sheet("title/logo").?.view[1].eql(.{ .r = 7, .g = 0, .b = 0 }));
    const f = back.art.frame("title/000").?;
    try std.testing.expectEqualSlices(u8, &pixels, f.pixels);
    try std.testing.expectEqual(@as(i16, 2), f.origin_y);
    try std.testing.expectEqual(@as(u2, 3), f.palette);
    try std.testing.expectEqual(@as(u16, 1), back.art.font("fonts/main").?.glyphAt("A").?.tile);
    try std.testing.expectEqual(@as(usize, 1), back.entities.len);
    try std.testing.expectEqualStrings("title/000", back.entities[0].animations[0].frames[0].frame);
    try std.testing.expectEqual(@as(?u8, 0), back.entities[0].animations[0].frames[0].body);

    const again = try write(arena, &back);
    try std.testing.expectEqual(files.len, again.len);
    for (files, again) |a, b| {
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqualSlices(u8, a.bytes, b.bytes);
    }
}

test "a refused tree names the file and the field" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = @import("../memory.zig").MemoryAssetSource.init(gpa);
    defer source.deinit();
    var diag: Diagnostic = .{};
    var buf: [256]u8 = undefined;

    try std.testing.expectError(error.BadAsset, load(arena, source.assetSource(), &diag));
    try std.testing.expectEqualStrings("manifest.json: missing", try std.fmt.bufPrint(&buf, "{f}", .{&diag}));

    try source.add("manifest.json",
        \\{"format": "sorz-content", "version": 2, "extractor": "x", "rom": {"sha256": "0", "size": 1}, "art": []}
    );
    try std.testing.expectError(error.BadAsset, load(arena, source.assetSource(), &diag));
    try std.testing.expectEqualStrings("manifest.json: field version: not version 1: extract the tree again", try std.fmt.bufPrint(&buf, "{f}", .{&diag}));

    try source.add("manifest.json",
        \\{"format": "sorz-content", "version": 1, "extractor": "x", "rom": {"sha256": "0", "size": 1}, "art": ["title"]}
    );
    try source.add("title/art.json",
        \\{"palettes": {"sky": {"colours": {"1": [null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, [8, 0, 0]]}}}}
    );
    try std.testing.expectError(error.BadAsset, load(arena, source.assetSource(), &diag));
    try std.testing.expectEqualStrings("title/art.json: field palettes.sky.colours.1[15][0]: not 0 to 7", try std.fmt.bufPrint(&buf, "{f}", .{&diag}));

    try source.add("title/art.json",
        \\{"tiles": {"logo": {"file": "logo.png", "count": 1, "colour": 2}}}
    );
    try std.testing.expectError(error.BadAsset, load(arena, source.assetSource(), &diag));
    try std.testing.expectEqualStrings("title/art.json: field tiles.logo.colour: not a field of this record", try std.fmt.bufPrint(&buf, "{f}", .{&diag}));

    // A picture with an index above 15.
    var pal: [32][3]u8 = undefined;
    for (&pal, 0..) |*c, i| c.* = .{ @intCast(i), 0, 0 };
    var px: [64]u8 = @splat(0);
    px[9] = 20;
    try source.add("title/logo.png", try png.encode(arena, 8, 8, &px, &pal));
    try source.add("title/art.json",
        \\{"tiles": {"logo": {"file": "logo.png", "count": 1}}}
    );
    try std.testing.expectError(error.BadAsset, load(arena, source.assetSource(), &diag));
    try std.testing.expectEqualStrings("title/logo.png: pixel (1, 1): a colour index above 15", try std.fmt.bufPrint(&buf, "{f}", .{&diag}));
}

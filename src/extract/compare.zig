//! The extracted art against sor-remaster's exported tree (PLAN 06's gate; DESIGN.md 12): the
//! reference decoded the same ROM into records named by their ROM address, and each asset here
//! names its record through its origin (`builder.Origin`). A tool of the extractor, run by
//! `zig build extract-compare -Drom=PATH -Dremaster-tree=DIR`.
//!
//! - Sheets: the same tiles, pixel for pixel, as the reference's sheet of the same block.
//! - Maps: the same cells as the console reads them (tile slot, palette, flips, priority) as the
//!   reference's record: a word rectangle, an Enigma or Kosinski rectangle, a byte rectangle, a
//!   screen rectangle's RAM words; a round's planes and waves cell by cell against its Tiled maps,
//!   whose tilesets place the round's two blocks, so each cell names the same tile of the same
//!   block.
//! - Frames: the same picture and origin as the reference's composed frame.
//! - Palettes: the same colours at the same places as the reference's list.
//! - Fonts: the same tile for each character.
const std = @import("std");
const sorz = @import("sorz");
const art = sorz.content.art;
const json = sorz.formats.json;
const png = sorz.formats.png;
const builder_mod = @import("builder.zig");
const blocks = @import("blocks.zig");
const screens = @import("screens.zig");

pub const Count = struct { compared: usize = 0, equal: usize = 0, unmatched: usize = 0 };

pub const Report = struct {
    sheets: Count = .{},
    maps: Count = .{},
    frames: Count = .{},
    palettes: Count = .{},
    cycles: Count = .{},
    fonts: Count = .{},
    /// The reference's frames with a picture that the extraction has not.
    frames_missing: usize = 0,
    differences: std.ArrayList([]const u8) = .empty,
    unmatched: std.ArrayList([]const u8) = .empty,
    differing: usize = 0,
};

const Ctx = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    report: *Report,
    diag: json.Diagnostic = .{},
    /// The reference's files by the ROM address they came from.
    sources: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList([]const u8)) = .empty,

    fn read(self: *Ctx, path: []const u8) ![]const u8 {
        return self.dir.readFileAlloc(self.io, path, self.arena, .limited(64 << 20)) catch |e| {
            std.log.err("the reference's {s}: {s}", .{ path, @errorName(e) });
            return e;
        };
    }

    fn readJson(self: *Ctx, path: []const u8) !json.Node {
        return json.parse(self.arena, path, try self.read(path), &self.diag) catch |e| {
            std.log.err("the reference's {f}", .{&self.diag});
            return e;
        };
    }

    fn readPng(self: *Ctx, path: []const u8) !png.Image {
        return png.decode(self.arena, try self.read(path));
    }

    fn differ(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        self.report.differing += 1;
        if (self.report.differences.items.len < 40) try self.report.differences.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn unmatched(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        try self.report.unmatched.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    /// The reference's file of `source` whose path starts with `prefix`.
    fn fileOf(self: *Ctx, source: u32, prefix: []const u8) ?[]const u8 {
        const list = self.sources.get(source) orelse return null;
        for (list.items) |p| if (std.mem.startsWith(u8, p, prefix)) return p;
        return null;
    }
};

fn hexRows(arena: std.mem.Allocator, node: json.Node, comptime T: type) ![]T {
    var out: std.ArrayList(T) = .empty;
    for (0..try node.len()) |i| {
        var it = std.mem.tokenizeScalar(u8, try (try node.at(i)).string(), ' ');
        while (it.next()) |t| try out.append(arena, try std.fmt.parseInt(T, t, 16));
    }
    return out.items;
}

/// A picture's tiles, read left to right and top to bottom.
fn tilesOf(arena: std.mem.Allocator, img: png.Image, count: usize) ![]art.Tile {
    const cols = img.width / 8;
    const tiles = try arena.alloc(art.Tile, count);
    for (tiles, 0..) |*t, i| {
        const tx = (i % cols) * 8;
        const ty = (i / cols) * 8;
        for (0..8) |y| @memcpy(t[y * 8 ..][0..8], img.pixels[(ty + y) * img.width + tx ..][0..8]);
    }
    return tiles;
}

/// Compares the art `a` (built by `b`) with the reference's tree in `dir`.
pub fn compare(arena: std.mem.Allocator, io: std.Io, b: *builder_mod.Builder, a: art.Art, dir: std.Io.Dir) !Report {
    var report: Report = .{};
    var ctx: Ctx = .{ .arena = arena, .io = io, .dir = dir, .report = &report };
    // The reference's manifest names each file's source.
    const manifest = try ctx.readJson("manifest.json");
    var it = try (try manifest.get("sources")).fields();
    while (try it.next()) |f| {
        const source = try f.value.int(u32);
        const gop = try ctx.sources.getOrPut(arena, source);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, f.key);
    }
    try compareSheets(&ctx, b, a);
    try compareMaps(&ctx, b, a);
    try compareFrames(&ctx, b, a);
    try comparePalettes(&ctx, b, a);
    try compareCycles(&ctx, b, a);
    try compareFonts(&ctx, a);
    return report;
}

fn compareSheets(ctx: *Ctx, b: *builder_mod.Builder, a: art.Art) !void {
    const sheets_node = try (try ctx.readJson("art/art.json")).get("sheets");
    for (b.sheets.keys(), b.sheets.values()) |name, blk| {
        const mine = a.sheet(name).?;
        ctx.report.sheets.compared += 1;
        var file: ?[]const u8 = null;
        for (0..try sheets_node.len()) |i| {
            const s = try sheets_node.at(i);
            if (try (try s.get("source")).int(u32) == blk.source) file = try (try s.get("file")).string();
        }
        const path = file orelse {
            ctx.report.sheets.unmatched += 1;
            try ctx.unmatched("sheet {s}: the reference has no sheet of ROM 0x{X:0>5}", .{ name, blk.source });
            continue;
        };
        const img = try ctx.readPng(path);
        const capacity = (img.width / 8) * (img.height / 8);
        if (capacity < mine.tiles.len) {
            try ctx.differ("sheet {s}: {d} tiles, the reference's {s} at most {d}", .{ name, mine.tiles.len, path, capacity });
            continue;
        }
        const theirs = try tilesOf(ctx.arena, img, mine.tiles.len);
        var same = true;
        for (mine.tiles, theirs, 0..) |x, y, i| if (!std.mem.eql(u8, &x, &y)) {
            try ctx.differ("sheet {s}: tile {d} differs from the reference's {s}", .{ name, i, path });
            same = false;
            break;
        };
        // The reference's sheet has no more tiles than this one (the rest of its last row blank).
        for (mine.tiles.len..capacity) |i| {
            const t = (try tilesOf(ctx.arena, img, i + 1))[i];
            if (!std.mem.allEqual(u8, &t, 0)) {
                try ctx.differ("sheet {s}: the reference's {s} has a tile {d} past this sheet's {d}", .{ name, path, i, mine.tiles.len });
                same = false;
                break;
            }
        }
        if (same) ctx.report.sheets.equal += 1;
    }
}

fn compareWords(ctx: *Ctx, name: []const u8, mine: []const u16, theirs: []const u16, what: []const u8) !void {
    ctx.report.maps.compared += 1;
    if (theirs.len < mine.len) return ctx.differ("map {s}: {d} cells, the reference's {s} {d}", .{ name, mine.len, what, theirs.len });
    for (mine, theirs[0..mine.len], 0..) |x, y, i| if (x != y) return ctx.differ("map {s}: cell {d} is ${X:0>4}, the reference's {s} ${X:0>4}", .{ name, i, x, what, y });
    ctx.report.maps.equal += 1;
}

fn compareMaps(ctx: *Ctx, b: *builder_mod.Builder, a: art.Art) !void {
    const arena = ctx.arena;
    const rects = try (try ctx.readJson("screens/screens.json")).get("rectangles");
    // The RAM blocks of words the screen rectangles read (the Kosinski list's blocks that are not
    // whole tiles), at their RAM addresses.
    const Words = struct { ram: u32, bytes: []const u8 };
    var ram_blocks: std.ArrayList(Words) = .empty;
    const kos = try (try ctx.readJson("art/art.json")).get("kosinski_list");
    for (0..try kos.len()) |i| {
        const k = try kos.at(i);
        const file = try (try k.get("file")).string();
        if (!std.mem.endsWith(u8, file, ".json")) continue;
        const block = try ctx.readJson(file);
        try ram_blocks.append(arena, .{ .ram = try (try block.get("ram")).int(u32), .bytes = try hexRows(arena, try block.get("rows"), u8) });
    }

    for (b.origins.keys(), b.origins.values()) |key, o| {
        const name = builder_mod.Builder.originName(key);
        const m = switch (o) {
            .map => |m| m,
            else => continue,
        };
        switch (m.from) {
            .rom_words => |at| {
                const file = ctx.fileOf(at, "maps/words_") orelse {
                    ctx.report.maps.unmatched += 1;
                    try ctx.unmatched("map {s}: the reference has no word rectangle of ROM 0x{X:0>5}", .{ name, at });
                    continue;
                };
                try compareWords(ctx, name, m.words, try hexRows(arena, try (try ctx.readJson(file)).get("words"), u16), file);
            },
            .ram_block => |src| {
                // A Kosinski block of the catalogue, else an Enigma list's entry (0x1F596 is
                // both, in two readings).
                const kosinski = if (blocks.find(src)) |blk| blk.pack == .kosinski else false;
                const file = ctx.fileOf(src, if (kosinski) "maps/kos_" else "maps/eni_") orelse {
                    ctx.report.maps.unmatched += 1;
                    try ctx.unmatched("map {s}: the reference has no map of ROM 0x{X:0>5}", .{ name, src });
                    continue;
                };
                try compareWords(ctx, name, m.words, try hexRows(arena, try (try ctx.readJson(file)).get("words"), u16), file);
            },
            .bytes => |at| {
                const file = ctx.fileOf(at, "maps/bytes_") orelse {
                    ctx.report.maps.unmatched += 1;
                    try ctx.unmatched("map {s}: the reference has no byte rectangle of ROM 0x{X:0>5}", .{ name, at });
                    continue;
                };
                const node = try ctx.readJson(file);
                const base = try (try node.get("base")).int(u16);
                const bytes = try hexRows(arena, try node.get("bytes"), u8);
                const words = try arena.alloc(u16, bytes.len);
                for (words, bytes) |*w, x| w.* = base +% x;
                try compareWords(ctx, name, m.words, words, file);
            },
            .screen_rect => |sr| {
                const r = try rects.at(sr.entry);
                const ram = try (try r.get("ram")).int(u32);
                const n = try (try r.get("width")).int(usize) * try (try r.get("height")).int(usize);
                const words = for (ram_blocks.items) |blk| {
                    if (ram >= blk.ram and ram + 2 * n <= blk.ram + blk.bytes.len) {
                        const w = try arena.alloc(u16, n);
                        for (w, 0..) |*x, k| x.* = std.mem.readInt(u16, blk.bytes[ram - blk.ram + 2 * k ..][0..2], .big) +% sr.add;
                        break w;
                    }
                } else {
                    ctx.report.maps.unmatched += 1;
                    try ctx.unmatched("map {s}: no block of words of the reference holds screen rectangle {d}'s RAM ${X:0>6}", .{ name, sr.entry, ram });
                    continue;
                };
                try compareWords(ctx, name, m.words, words, "screen rectangle");
            },
            .round_plane => |rp| try compareTiled(ctx, a, name, try std.fmt.allocPrint(arena, "levels/round{d}/plane_{c}.tmj", .{ rp.round + 1, @as(u8, if (rp.plane == 0) 'a' else 'b') }), rp.round, 0),
            .waves => |f| try compareTiled(ctx, a, name, "levels/round3/waves.tmj", 2, @as(usize, f) * 6),
            .menu_line => |k| {
                // The reference keeps the table as a text (a write command, then 10 codes of the
                // font) and the words added to the second and third lines as a table.
                const line = try (try (try ctx.readJson("texts/menu_lines.json")).get("lines")).at(k);
                const bytes = try parseText(ctx, try line.string());
                if (bytes.len != 14) return ctx.differ("map {s}: the reference's menu line {d} is not 14 bytes", .{ name, k });
                var add: u16 = 0;
                if (k > 0) {
                    const table = try hexRows(arena, try (try ctx.readJson("tables/menu_line_words.json")).get("rows"), u8);
                    add = @as(u16, table[2 * (k - 1)]) << 8 | table[2 * (k - 1) + 1];
                }
                var words: [10]u16 = undefined;
                for (&words, bytes[4..]) |*w, x| w.* = @as(u16, x) +% add;
                try compareWords(ctx, name, m.words, &words, "texts/menu_lines.json");
            },
            .code => {
                ctx.report.maps.unmatched += 1;
                try ctx.unmatched("map {s}: cells a routine writes; the reference's tree has no record of them", .{name});
            },
        }
    }
}

/// The bytes of a line of the reference's texts: hex bytes in braces, and between them the font's
/// glyphs, the longest first (the play font's codes, fonts/play.json).
fn parseText(ctx: *Ctx, line: []const u8) ![]const u8 {
    const codes = try (try ctx.readJson("fonts/play.json")).get("codes");
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, line, i, '}') orelse return error.BadData;
            var it = std.mem.tokenizeScalar(u8, line[i + 1 .. close], ' ');
            while (it.next()) |t| try out.append(ctx.arena, try std.fmt.parseInt(u8, t, 16));
            i = close + 1;
            continue;
        }
        var best: ?[]const u8 = null;
        var code: u8 = 0;
        var glyphs = try codes.fields();
        while (try glyphs.next()) |g| {
            if (std.mem.startsWith(u8, line[i..], g.key) and (best == null or g.key.len > best.?.len)) {
                best = g.key;
                code = try g.value.int(u8);
            }
        }
        try out.append(ctx.arena, code);
        i += (best orelse return error.BadData).len;
    }
    return out.items;
}

/// A round's map against the reference's Tiled map: each cell names the same tile of the same
/// block (the reference's tilesets `art_1` and `art_2` sit at the blocks' video tiles), with the
/// same flips, palette and priority. `row` is the reference's first row.
fn compareTiled(ctx: *Ctx, a: art.Art, name: []const u8, path: []const u8, round: u8, row: usize) !void {
    const arena = ctx.arena;
    const mine = a.map(name).?;
    ctx.report.maps.compared += 1;
    const t = try ctx.readJson(path);
    const width = try (try t.get("width")).int(usize);
    const sets = try t.get("tilesets");
    const Range = struct { first: u32, count: u32, name: []const u8 };
    var ranges: std.ArrayList(Range) = .empty;
    for (0..try sets.len()) |i| {
        const s = try sets.at(i);
        try ranges.append(arena, .{ .first = try (try s.get("firstgid")).int(u32), .count = try (try s.get("tilecount")).int(u32), .name = try (try s.get("name")).string() });
    }
    const layers = try t.get("layers");
    var cells: []const std.json.Value = &.{};
    var attrs: []const std.json.Value = &.{};
    for (0..try layers.len()) |i| {
        const l = try layers.at(i);
        const lname = try (try l.get("name")).string();
        if (std.mem.eql(u8, lname, "cells")) cells = try (try l.get("data")).items();
        if (std.mem.eql(u8, lname, "attributes")) attrs = try (try l.get("data")).items();
    }
    if (width != mine.width) return ctx.differ("map {s}: {d} cells wide, the reference's {s} {d}", .{ name, mine.width, path, width });
    const own_round = try std.fmt.allocPrint(arena, "round{d}/", .{round + 1});
    for (0..mine.height) |y| for (0..mine.width) |x| {
        const k = (row + y) * width + x;
        if (k >= cells.len) return ctx.differ("map {s}: the reference's {s} has fewer rows", .{ name, path });
        const raw: u32 = @intCast(cells[k].integer);
        const gid = raw & 0x1FFFFFFF;
        const c = mine.cell(x, y);
        // The tile the reference's cell names: a tileset by name, and the tile in it.
        var theirs: ?struct { set: []const u8, tile: u32 } = null;
        for (ranges.items) |r| {
            if (gid >= r.first and gid < r.first + r.count and !std.mem.eql(u8, r.name, "attributes")) theirs = .{ .set = r.name, .tile = gid - r.first };
        }
        var ours: ?struct { set: []const u8, tile: u32 } = null;
        if (!c.isEmpty()) {
            var base: u32 = 0;
            for (mine.sheets) |s| {
                const count: u32 = @intCast(a.sheet(s).?.tiles.len);
                if (c.tile < base + count) {
                    ours = .{ .set = s, .tile = c.tile - base };
                    break;
                }
                base += count;
            }
        }
        const same_tile = if (ours) |o| (theirs != null and std.mem.startsWith(u8, o.set, own_round) and std.mem.eql(u8, o.set[own_round.len..], theirs.?.set) and o.tile == theirs.?.tile) else theirs == null;
        const attr: u32 = @intCast(attrs[k].integer);
        const p = (attr - 2049) & 3;
        const q = (attr - 2049) >= 4;
        const same_attrs = c.isEmpty() or (c.flip_x == (raw & 0x80000000 != 0) and c.flip_y == (raw & 0x40000000 != 0) and c.palette == p and c.priority == q);
        if (!same_tile or !same_attrs) return ctx.differ("map {s}: cell ({d}, {d}) differs from the reference's {s} (gid {d}, attributes {d})", .{ name, x, y, path, raw, attr });
    };
    ctx.report.maps.equal += 1;
}

fn compareFrames(ctx: *Ctx, b: *builder_mod.Builder, a: art.Art) !void {
    const arena = ctx.arena;
    // The reference's frames by their set's and their own address.
    const Ref = struct { set: u32, address: u32, image: ?[]const u8, origin: [2]i16 };
    var refs: std.ArrayList(Ref) = .empty;
    for (ctx.sources.keys(), ctx.sources.values()) |_, list| for (list.items) |path| {
        if (!std.mem.startsWith(u8, path, "sprites/") or !std.mem.endsWith(u8, path, "/sprite.json")) continue;
        const s = try ctx.readJson(path);
        const set = try (try s.get("source")).int(u32);
        const frames = try s.get("frames");
        const dir = path[0 .. path.len - "sprite.json".len];
        for (0..try frames.len()) |i| {
            const f = try frames.at(i);
            var ref: Ref = .{ .set = set, .address = try (try f.get("source")).int(u32), .image = null, .origin = .{ 0, 0 } };
            if (try f.opt("image")) |img| {
                ref.image = try std.fmt.allocPrint(arena, "{s}{s}", .{ dir, try img.string() });
                const o = try f.get("origin");
                ref.origin = .{ try (try o.at(0)).int(i16), try (try o.at(1)).int(i16) };
            }
            try refs.append(arena, ref);
        }
    };
    var matched = try arena.alloc(bool, refs.items.len);
    @memset(matched, false);
    for (b.origins.keys(), b.origins.values()) |key, o| {
        const name = builder_mod.Builder.originName(key);
        const fo = switch (o) {
            .frame => |f| f,
            else => continue,
        };
        const mine = a.frame(name).?;
        ctx.report.frames.compared += 1;
        const k = for (refs.items, 0..) |r, i| {
            if (r.set == fo.set and r.address == fo.address) break i;
        } else {
            ctx.report.frames.unmatched += 1;
            try ctx.unmatched("frame {s}: the reference has no frame 0x{X:0>5} of the set 0x{X:0>5}", .{ name, fo.address, fo.set });
            continue;
        };
        matched[k] = true;
        const ref = refs.items[k];
        const path = ref.image orelse {
            try ctx.differ("frame {s}: the reference composed no picture of it", .{name});
            continue;
        };
        const img = try ctx.readPng(path);
        if (img.width != mine.width or img.height != mine.height or ref.origin[0] != mine.origin_x or ref.origin[1] != mine.origin_y) {
            try ctx.differ("frame {s}: {d}x{d} at ({d}, {d}), the reference's {s} {d}x{d} at ({d}, {d})", .{ name, mine.width, mine.height, mine.origin_x, mine.origin_y, path, img.width, img.height, ref.origin[0], ref.origin[1] });
            continue;
        }
        if (!std.mem.eql(u8, img.pixels, mine.pixels)) {
            try ctx.differ("frame {s}: its pixels differ from the reference's {s}", .{ name, path });
            continue;
        }
        ctx.report.frames.equal += 1;
    }
    for (refs.items, matched) |r, m| if (!m and r.image != null) {
        ctx.report.frames_missing += 1;
        try ctx.differ("the reference's frame {s} (0x{X:0>5} of the set 0x{X:0>5}) is not extracted", .{ r.image.?, r.address, r.set });
    };
}

/// A palette list's words as the colours they give the four palettes.
fn applyWords(words: []const u16, out: *[4][16]?art.Colour) void {
    for (words) |w| {
        const place: usize = (w & 0x10) | ((w >> 12) & 0xF) | ((w & 0x100) >> 3);
        out[place / 16][place % 16] = builder_mod.colourOf(w);
    }
}

fn comparePalettes(ctx: *Ctx, b: *builder_mod.Builder, a: art.Art) !void {
    const arena = ctx.arena;
    for (b.origins.keys(), b.origins.values()) |key, o| {
        const name = builder_mod.Builder.originName(key);
        const list = switch (o) {
            .palette => |p| p,
            else => continue,
        };
        const mine = a.palette(name).?;
        ctx.report.palettes.compared += 1;
        const at = list orelse {
            ctx.report.palettes.unmatched += 1;
            try ctx.unmatched("palette {s}: colours a routine sets; the reference's tree has no list of them", .{name});
            continue;
        };
        var theirs: [4][16]?art.Colour = @splat(@splat(null));
        if (ctx.fileOf(at, "palettes/")) |file| {
            const entries = try (try ctx.readJson(file)).get("entries");
            for (0..try entries.len()) |i| {
                const e = try entries.at(i);
                const slot = try (try e.at(0)).int(u8);
                theirs[slot / 16][slot % 16] = builder_mod.colourOf(try (try e.at(1)).int(u16));
            }
        } else if (at >= 0x1139E and at < 0x1139E + 40) {
            // Round 3's waves: the reference keeps their lists in round 3's level.json.
            const rows = try (try (try ctx.readJson("levels/round3/level.json")).get("waves")).get("palettes");
            const row = try rows.at((at - 0x1139E) / 8);
            var words: [4]u16 = undefined;
            for (&words, 0..) |*w, k| w.* = try (try row.at(k)).int(u16);
            applyWords(&words, &theirs);
        } else {
            ctx.report.palettes.unmatched += 1;
            try ctx.unmatched("palette {s}: the reference has no list of ROM 0x{X:0>5}", .{ name, at });
            continue;
        }
        if (!std.meta.eql(theirs, mine.colours)) {
            try ctx.differ("palette {s}: its colours differ from the reference's list at 0x{X:0>5}", .{ name, at });
            continue;
        }
        ctx.report.palettes.equal += 1;
    }
    _ = arena;
}

/// The rounds' palette cycles against the reference's rounds' `palette_cycles`.
fn compareCycles(ctx: *Ctx, b: *builder_mod.Builder, a: art.Art) !void {
    for (b.origins.keys(), b.origins.values()) |key, o| {
        const c = switch (o) {
            .cycle => |c| c,
            else => continue,
        };
        const name = builder_mod.Builder.originName(key);
        const mine = a.cycle(name).?;
        ctx.report.cycles.compared += 1;
        var found = false;
        for (1..9) |r| {
            const cycles = try (try ctx.readJson(try std.fmt.allocPrint(ctx.arena, "levels/round{d}/level.json", .{r}))).get("palette_cycles");
            for (0..try cycles.len()) |i| {
                const rc = try cycles.at(i);
                if (try (try rc.get("source")).int(u32) != c) continue;
                found = true;
                const per_step = try (try rc.get("per_step")).int(usize);
                const entries = try rc.get("entries");
                var same = try (try rc.get("period")).int(u16) == mine.period and try (try rc.get("steps")).int(usize) == mine.steps.len and try entries.len() == per_step * mine.steps.len;
                if (same) for (mine.steps, 0..) |step, s| {
                    var theirs: [4][16]?art.Colour = @splat(@splat(null));
                    for (0..per_step) |k| {
                        const e = try entries.at(s * per_step + k);
                        const slot = try (try e.at(0)).int(u8);
                        theirs[slot / 16][slot % 16] = builder_mod.colourOf(try (try e.at(1)).int(u16));
                    }
                    if (!std.meta.eql(theirs, step)) same = false;
                };
                if (same) ctx.report.cycles.equal += 1 else try ctx.differ("cycle {s}: differs from the reference's cycle at 0x{X:0>5}", .{ name, c });
            }
        }
        if (!found) {
            ctx.report.cycles.unmatched += 1;
            try ctx.unmatched("cycle {s}: the reference has no cycle at 0x{X:0>5}", .{ name, c });
        }
    }
}

fn compareFonts(ctx: *Ctx, a: art.Art) !void {
    for ([_][2][]const u8{ .{ "fonts/main", "fonts/play.json" }, .{ "fonts/italic", "fonts/play.json" }, .{ "fonts/intro", "fonts/intro.json" } }) |pair| {
        const mine = a.font(pair[0]).?;
        ctx.report.fonts.compared += 1;
        var codes = try (try (try ctx.readJson(pair[1])).get("codes")).fields();
        var same = codes.count() == mine.glyphs.len;
        while (try codes.next()) |c| {
            const tile = try c.value.int(u16);
            const g = for (mine.glyphs) |g| {
                if (std.mem.eql(u8, g.text, c.key)) break g;
            } else null;
            if (g == null or g.?.tile != tile) same = false;
        }
        if (same) ctx.report.fonts.equal += 1 else try ctx.differ("font {s}: its glyphs differ from the reference's {s}", .{ pair[0], pair[1] });
    }
}

comptime {
    _ = blocks;
    _ = screens;
}

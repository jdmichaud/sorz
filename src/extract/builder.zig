//! The art sets as the extractor builds them: each asset added once by its full name (an asset
//! two screens add must be the same), the sheets the maps and fonts draw from, the palette lists
//! by name, and at the end the content's `Art`.
const std = @import("std");
const sorz = @import("sorz");
const art = sorz.content.art;
const blocks = @import("blocks.zig");
const rom_mod = @import("rom.zig");

pub const Error = error{ OutOfMemory, BadData, Conflict, UnknownBlock } || blocks.Error;

const SetBuilder = struct {
    provenance: []const u8 = "",
    uses: std.StringArrayHashMapUnmanaged(void) = .empty,
    palettes: std.ArrayList(art.Palette) = .empty,
    cycles: std.ArrayList(art.Cycle) = .empty,
    sheets: std.ArrayList(art.TileSheet) = .empty,
    maps: std.ArrayList(art.TileMap) = .empty,
    frames: std.ArrayList(art.Frame) = .empty,
    fonts: std.ArrayList(art.Font) = .empty,
};

/// The ROM's record an asset was made from.
pub const Origin = union(enum) {
    /// A map's words: the console's cells (a tile slot, a palette, the flips, the priority), and
    /// where they were read.
    map: struct { words: []const u16, from: MapFrom },
    /// A frame: its animation set's address and its own.
    frame: struct { set: u32, address: u32 },
    /// A palette list's address; none for colours a routine sets itself.
    palette: ?u32,
    /// A palette cycle's record (its period, steps, colours a step, then its list).
    cycle: u32,
};

pub const MapFrom = union(enum) {
    /// A word rectangle in the ROM (its header's address).
    rom_words: u32,
    /// Words in RAM, unpacked there by a block (an Enigma or a Kosinski block's address).
    ram_block: u32,
    /// A byte rectangle (its header's address).
    bytes: u32,
    /// A screen rectangle (its entry), its RAM words plus `add`.
    screen_rect: struct { entry: u8, add: u16 },
    /// A round's plane (0-based round, plane 0 for A).
    round_plane: struct { round: u8, plane: u8 },
    /// Round 3's waves (0-based frame).
    waves: u8,
    /// A line of the game menu's table (0-based).
    menu_line: u8,
    /// Cells a routine writes itself.
    code,
};

pub const Builder = struct {
    arena: std.mem.Allocator,
    rom: []const u8,
    lib: blocks.Library,
    sets: std.StringArrayHashMapUnmanaged(SetBuilder) = .empty,
    /// The sheets maps and fonts draw from: full name to block.
    sheets: std.StringArrayHashMapUnmanaged(blocks.Block) = .empty,
    /// Each sheet's palette line counts, for the colours its picture is shown with.
    views: std.StringArrayHashMapUnmanaged([16]art.Colour) = .empty,
    /// Where each map, frame and palette came from in the ROM, by full name: what the
    /// comparison with sor-remaster's tree reads (src/extract/compare.zig).
    origins: std.StringArrayHashMapUnmanaged(Origin) = .empty,

    pub fn init(arena: std.mem.Allocator, rom: []const u8) Builder {
        return .{ .arena = arena, .rom = rom, .lib = .{ .arena = arena, .rom = rom } };
    }

    pub fn set(self: *Builder, name: []const u8) !*SetBuilder {
        const gop = try self.sets.getOrPut(self.arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    /// The set's provenance (once).
    pub fn describe(self: *Builder, name: []const u8, provenance: []const u8) !void {
        const s = try self.set(name);
        if (s.provenance.len != 0 and !std.mem.eql(u8, s.provenance, provenance)) return error.Conflict;
        s.provenance = provenance;
    }

    pub fn use(self: *Builder, set_name: []const u8, other: []const u8) !void {
        if (std.mem.eql(u8, set_name, other)) return;
        try (try self.set(set_name)).uses.put(self.arena, other, {});
    }

    pub fn split(name: []const u8) struct { set: []const u8, own: []const u8 } {
        const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse unreachable;
        return .{ .set = name[0..slash], .own = name[slash + 1 ..] };
    }

    /// The sheet of block `b` (decoded), added to its set when first used.
    pub fn sheet(self: *Builder, b: blocks.Block) Error!*const blocks.Decoded {
        if (b.data) return error.BadData;
        const d = try self.lib.decode(b);
        const gop = try self.sheets.getOrPut(self.arena, b.name);
        if (!gop.found_existing) gop.value_ptr.* = b;
        return d;
    }

    /// Adds a palette list's colours as the palette `name` (full); the same name twice must be
    /// the same list.
    pub fn palette(self: *Builder, name: []const u8, p: art.Palette) Error!void {
        const n = split(name);
        const s = try self.set(n.set);
        for (s.palettes.items) |q| if (std.mem.eql(u8, q.name, n.own)) {
            if (!std.meta.eql(q.colours, p.colours)) return error.Conflict;
            return;
        };
        var copy = p;
        copy.name = n.own;
        try s.palettes.append(self.arena, copy);
    }

    pub fn map(self: *Builder, name: []const u8, m: art.TileMap) Error!void {
        const n = split(name);
        const s = try self.set(n.set);
        for (s.maps.items) |q| if (std.mem.eql(u8, q.name, n.own)) {
            if (q.width != m.width or q.height != m.height or !std.mem.eql(art.Cell, q.cells, m.cells) or q.sheets.len != m.sheets.len) return error.Conflict;
            for (q.sheets, m.sheets) |a, b| if (!std.mem.eql(u8, a, b)) return error.Conflict;
            return;
        };
        var copy = m;
        copy.name = n.own;
        try s.maps.append(self.arena, copy);
    }

    pub fn cycle(self: *Builder, name: []const u8, c: art.Cycle) Error!void {
        const n = split(name);
        const s = try self.set(n.set);
        for (s.cycles.items) |q| if (std.mem.eql(u8, q.name, n.own)) return error.Conflict;
        var copy = c;
        copy.name = n.own;
        try s.cycles.append(self.arena, copy);
    }

    pub fn frame(self: *Builder, name: []const u8, f: art.Frame) Error!void {
        const n = split(name);
        const s = try self.set(n.set);
        for (s.frames.items) |q| if (std.mem.eql(u8, q.name, n.own)) return error.Conflict;
        var copy = f;
        copy.name = n.own;
        try s.frames.append(self.arena, copy);
    }

    pub fn font(self: *Builder, name: []const u8, f: art.Font) Error!void {
        const n = split(name);
        const s = try self.set(n.set);
        var copy = f;
        copy.name = n.own;
        try s.fonts.append(self.arena, copy);
    }

    /// Records asset `name`'s origin, under its kind ("map:title/hero"): a map and a palette
    /// may share a name.
    pub fn origin(self: *Builder, name: []const u8, o: Origin) !void {
        try self.origins.put(self.arena, try std.fmt.allocPrint(self.arena, "{t}:{s}", .{ o, name }), o);
    }

    /// The asset's full name of an origin's key.
    pub fn originName(key: []const u8) []const u8 {
        return key[std.mem.indexOfScalar(u8, key, ':').? + 1 ..];
    }

    /// The colours `sheet`'s picture is shown with (the first given wins).
    pub fn view(self: *Builder, sheet_name: []const u8, colours: [16]art.Colour) !void {
        const gop = try self.views.getOrPut(self.arena, sheet_name);
        if (!gop.found_existing) gop.value_ptr.* = colours;
    }

    fn byName(comptime T: type) fn (void, T, T) bool {
        return struct {
            fn lt(_: void, a: T, b: T) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt;
    }

    /// The art: the sets in name order, each set's assets in name order.
    pub fn finish(self: *Builder) Error!art.Art {
        // The sheets go to their sets.
        for (self.sheets.keys(), self.sheets.values()) |name, b| {
            const d = try self.lib.decode(b);
            const n = split(name);
            const s = try self.set(n.set);
            try s.sheets.append(self.arena, .{
                .name = n.own,
                .provenance = try blocks.provenanceOf(self.arena, b),
                .file = try std.fmt.allocPrint(self.arena, "{s}.png", .{n.own}),
                .tiles = d.tiles,
                .view = self.views.get(name) orelse art.grey,
            });
        }
        const names = try self.arena.dupe([]const u8, self.sets.keys());
        std.mem.sort([]const u8, names, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        const out = try self.arena.alloc(art.ArtSet, names.len);
        for (out, names) |*o, name| {
            const s = self.sets.getPtr(name).?;
            std.mem.sort(art.Palette, s.palettes.items, {}, byName(art.Palette));
            std.mem.sort(art.Cycle, s.cycles.items, {}, byName(art.Cycle));
            std.mem.sort(art.TileSheet, s.sheets.items, {}, byName(art.TileSheet));
            std.mem.sort(art.TileMap, s.maps.items, {}, byName(art.TileMap));
            std.mem.sort(art.Frame, s.frames.items, {}, byName(art.Frame));
            std.mem.sort(art.Font, s.fonts.items, {}, byName(art.Font));
            const uses = try self.arena.dupe([]const u8, s.uses.keys());
            std.mem.sort([]const u8, uses, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            o.* = .{
                .name = name,
                .provenance = s.provenance,
                .uses = uses,
                .palettes = s.palettes.items,
                .cycles = s.cycles.items,
                .sheets = s.sheets.items,
                .maps = s.maps.items,
                .frames = s.frames.items,
                .fonts = s.fonts.items,
            };
        }
        return .{ .sets = out };
    }
};

/// A colour of the console's palette memory (`0000BBB0GGG0RRR0`).
pub fn colourOf(word: u16) art.Colour {
    return .{ .r = @intCast((word >> 1) & 7), .g = @intCast((word >> 5) & 7), .b = @intCast((word >> 9) & 7) };
}

/// The palette list at `a` (applied by 0x10548): each word a colour whose other bits give its
/// place of the 64 (bits 15-12 its bits 3-0, bit 4 its bit 4, bit 8 its bit 5), bit 0 set on
/// the last word. A later colour for the same place replaces an earlier one, as the original
/// applies them in order.
pub fn paletteList(rom: []const u8, a: u32) error{BadData}!art.Palette {
    var p: art.Palette = .{ .name = "" };
    var at = a;
    var n: usize = 0;
    while (true) : (n += 1) {
        if (at + 2 > rom.len or n > 256) return error.BadData;
        const w = rom_mod.u16be(rom, at);
        at += 2;
        const place: usize = (w & 0x10) | ((w >> 12) & 0xF) | ((w & 0x100) >> 3);
        p.colours[place / 16][place % 16] = colourOf(w);
        if (w & 1 != 0) break;
    }
    return p;
}

test "a palette list's places and colours" {
    // Place 0x2B (palette 2, colour 11): bits 3-0 0xB, bit 4 0, bit 5 1; colour $0EA; the last.
    const rom = [_]u8{ 0xB1, 0xEB };
    const p = try paletteList(&rom, 0);
    try std.testing.expect(p.colours[2][11].?.eql(.{ .r = 5, .g = 7, .b = 0 }));
    try std.testing.expect(p.colours[0][0] == null);
}

//! The ROM's art blocks by name: every packed stream or region of tiles the screens, the rounds
//! and the sprites draw from (graphics port map 2.2), with the name of the tile sheet it becomes
//! when a map draws from it. A block only sprites draw from stays inside the extractor: its
//! frames are composed into pictures, and the content has the pictures (docs/content.md).
const std = @import("std");
const art = @import("sorz").content.art;
const nemesis = @import("nemesis.zig");
const kosinski = @import("kosinski.zig");

pub const Pack = enum { nemesis, kosinski, raw };

pub const Block = struct {
    /// The full name of the sheet the block becomes.
    name: []const u8,
    pack: Pack,
    source: u32,
    /// A raw region's length in bytes.
    size: u32 = 0,
    /// What the block is and who loads it, for the provenance.
    what: []const u8,
    /// Words the screens read as maps, not tiles: the block becomes no sheet.
    data: bool = false,
};

/// The art blocks. The provenance of a sheet names its block's ROM address and packing.
pub const catalogue = [_]Block{
    // The pattern-load list (0xA662) and the art lists (0x8672): Nemesis streams to video memory.
    .{ .name = "segalogo/logo", .pack = .nemesis, .source = 0x722A2, .what = "the Sega logo (pattern-load entries 1 and 55)" },
    .{ .name = "fonts/main", .pack = .nemesis, .source = 0x1CEC0, .what = "the game's font (pattern-load entries 2 and 3)" },
    .{ .name = "play/status_bar", .pack = .nemesis, .source = 0x6F3D4, .what = "the status bar's frame and labels (pattern-load entry 4)" },
    .{ .name = "play/weapons", .pack = .nemesis, .source = 0x6F552, .what = "the weapons (pattern-load entry 5)" },
    .{ .name = "galsia/art", .pack = .nemesis, .source = 0x20172, .what = "Galsia (pattern-load entry 6; art lists 1-4, 11-13)" },
    .{ .name = "signal/art", .pack = .nemesis, .source = 0x21708, .what = "Signal (pattern-load entry 7; art lists 14-16)" },
    .{ .name = "round3_boss/art_1", .pack = .nemesis, .source = 0x31DC4, .what = "round 3's boss (pattern-load entry 8; art lists 7, 8)" },
    .{ .name = "round3_boss/art_2", .pack = .nemesis, .source = 0x32CD6, .what = "round 3's boss (pattern-load entry 9; art lists 7, 8)" },
    .{ .name = "round3_boss/art_3", .pack = .nemesis, .source = 0x339EA, .what = "round 3's boss (pattern-load entry 10; art list 8)" },
    .{ .name = "mrx/seated", .pack = .nemesis, .source = 0x35190, .what = "Mr. X seated (pattern-load entry 11; art list 5)" },
    .{ .name = "round1/props", .pack = .nemesis, .source = 0x6C910, .what = "round 1's items and breakables (pattern-load entry 12)" },
    .{ .name = "round2/props", .pack = .nemesis, .source = 0x6CD68, .what = "round 2's items and breakables (pattern-load entry 13)" },
    .{ .name = "round3/props", .pack = .nemesis, .source = 0x6D366, .what = "round 3's items and breakables (pattern-load entry 14)" },
    .{ .name = "round4/props", .pack = .nemesis, .source = 0x6D698, .what = "round 4's items and breakables (pattern-load entry 15)" },
    .{ .name = "round5/props", .pack = .nemesis, .source = 0x6DC0E, .what = "round 5's items and breakables (pattern-load entry 16)" },
    .{ .name = "round6/props", .pack = .nemesis, .source = 0x6DF0A, .what = "round 6's items and breakables (pattern-load entry 17)" },
    .{ .name = "round7/props", .pack = .nemesis, .source = 0x6E4E8, .what = "round 7's items and breakables (pattern-load entry 18)" },
    .{ .name = "round8/props", .pack = .nemesis, .source = 0x6E870, .what = "round 8's items and breakables (pattern-load entry 19)" },
    .{ .name = "acrobat/art", .pack = .nemesis, .source = 0x22BFE, .what = "the acrobat (pattern-load entry 27; art lists 17-19)" },
    .{ .name = "brawler/art", .pack = .nemesis, .source = 0x245E0, .what = "the brawler (pattern-load entry 28; art lists 20-22)" },
    .{ .name = "fonts/big", .pack = .nemesis, .source = 0x1D0DA, .what = "the big letters, two cells high (pattern-load entry 32)" },
    .{ .name = "play/marks", .pack = .nemesis, .source = 0x6F2FC, .what = "four marks of play (pattern-load entry 33)" },
    .{ .name = "juggler/art", .pack = .nemesis, .source = 0x258F8, .what = "the knife juggler (pattern-load entry 34; art lists 23-25)" },
    .{ .name = "fonts/kana", .pack = .nemesis, .source = 0x1D81A, .what = "the story's kana, in Japan (pattern-load entry 37)" },
    .{ .name = "boss_ending/room", .pack = .nemesis, .source = 0x1E81E, .what = "the boss's room of the ending (pattern-load entry 38)" },
    .{ .name = "boss_ending/characters", .pack = .nemesis, .source = 0x1EB02, .what = "the characters in the boss's chair (pattern-load entries 39-41)" },
    .{ .name = "ending/car", .pack = .nemesis, .source = 0x3BA78, .what = "the ending's car and sky (pattern-load entry 43)" },
    .{ .name = "ending/city", .pack = .nemesis, .source = 0x3BD58, .what = "the ending's city (pattern-load entry 44)" },
    .{ .name = "ending/walkers", .pack = .nemesis, .source = 0x3C744, .what = "the ending's walkers (pattern-load entry 45)" },
    .{ .name = "ending/picture_1", .pack = .nemesis, .source = 0x3C8BC, .what = "the ending's first picture (pattern-load entry 46)" },
    .{ .name = "ending/picture_3", .pack = .nemesis, .source = 0x3D68E, .what = "the ending's third picture (pattern-load entry 47)" },
    .{ .name = "ending/picture_2", .pack = .nemesis, .source = 0x3E3D2, .what = "the ending's second picture (pattern-load entry 48)" },
    .{ .name = "mrx/standing", .pack = .nemesis, .source = 0x2F55A, .what = "Mr. X standing (pattern-load entry 49; art list 6)" },
    .{ .name = "mrx/gun", .pack = .nemesis, .source = 0x2FFC0, .what = "Mr. X's gun (pattern-load entry 50; art list 6)" },
    .{ .name = "mrx/hit", .pack = .nemesis, .source = 0x30FD8, .what = "Mr. X hit (pattern-load entry 51; art list 6)" },
    .{ .name = "play/effects", .pack = .nemesis, .source = 0x6EEC0, .what = "the hit sparks, the shadow and the arrow (pattern-load entry 52)" },
    .{ .name = "select/portraits", .pack = .nemesis, .source = 0x70CB0, .what = "the character select's portraits (pattern-load entry 53)" },
    .{ .name = "play/items", .pack = .nemesis, .source = 0x6F0DC, .what = "the food and the extra life (pattern-load entry 54)" },
    .{ .name = "round1/shutter", .pack = .nemesis, .source = 0x26F90, .what = "round 1's shutter (pattern-load entry 56)" },
    .{ .name = "play/valuables", .pack = .nemesis, .source = 0x72146, .what = "the money and the gold (pattern-load entry 57)" },
    .{ .name = "police/art", .pack = .nemesis, .source = 0x6FDBC, .what = "the police car (art list 0)" },
    .{ .name = "special/blast", .pack = .nemesis, .source = 0x1E35E, .what = "the special attack's shell (art list 9)" },
    .{ .name = "special/fire", .pack = .nemesis, .source = 0x1DC16, .what = "the special attack's fire (art list 10)" },
    .{ .name = "fonts/kana_window", .pack = .nemesis, .source = 0x1D42A, .what = "the kana of round 8's window, in Japan (art list 26)" },
    .{ .name = "round2_boss/art", .pack = .nemesis, .source = 0x27162, .what = "round 2's boss (art lists 27, 30)" },
    .{ .name = "antonio/art", .pack = .nemesis, .source = 0x29264, .what = "Antonio, round 1's boss (art list 28)" },
    .{ .name = "round4_boss/art", .pack = .nemesis, .source = 0x2BC48, .what = "round 4's boss (art list 29)" },

    // The Kosinski list (0xB768) and the other Kosinski blocks the screens unpack into RAM.
    .{ .name = "fonts/italic", .pack = .kosinski, .source = 0x389A0, .what = "the game's font, italic (Kosinski list entry 0)" },
    .{ .name = "fonts/intro", .pack = .kosinski, .source = 0x38BB0, .what = "the profiles' font (Kosinski list entry 1)" },
    .{ .name = "intro/city", .pack = .kosinski, .source = 0x39BE0, .what = "the city at night (Kosinski list entry 2)" },
    .{ .name = "intro/story_frame", .pack = .kosinski, .source = 0x39B80, .what = "the story's frames (Kosinski list entry 3)" },
    .{ .name = "intro/faces", .pack = .kosinski, .source = 0x38D20, .what = "the profiles' faces (Kosinski list entry 4)" },
    .{ .name = "intro/heroes", .pack = .kosinski, .source = 0x37360, .what = "the heroes' pictures (Kosinski list entry 5)" },
    .{ .name = "title/name", .pack = .kosinski, .source = 0x35C50, .what = "the title's name (Kosinski list entry 6)" },
    .{ .name = "title/name_2", .pack = .kosinski, .source = 0x3B8B8, .what = "the title's name (Kosinski list entry 7)" },
    .{ .name = "title/name_japan", .pack = .kosinski, .source = 0x3AF38, .what = "the title's name in Japan (Kosinski list entry 8)" },
    .{ .name = "title/name_japan_2", .pack = .kosinski, .source = 0x3AAC8, .what = "the title's name in Japan (Kosinski list entry 9)" },
    .{ .name = "title/hero", .pack = .kosinski, .source = 0x365A0, .what = "the title's picture of Axel (Kosinski list entry 10)" },
    .{ .name = "title/texts", .pack = .kosinski, .source = 0x35AD0, .what = "the title's texts (Kosinski list entry 11)" },
    .{ .name = "intro/maps", .pack = .kosinski, .source = 0x3A538, .what = "the intro's and the title's maps (Kosinski list entry 12)", .data = true },
    .{ .name = "ending/maps", .pack = .kosinski, .source = 0x3EDA4, .what = "the ending's maps (Kosinski list entry 13)", .data = true },
    .{ .name = "select/frame_map", .pack = .kosinski, .source = 0x71C6C, .what = "the character select's frame (a word rectangle, unpacked by 0x1634)", .data = true },
    .{ .name = "boss_ending/room_map", .pack = .kosinski, .source = 0x1F596, .what = "the boss's room (a word rectangle, unpacked by 0x87C6)", .data = true },

    // The players' art: three uncompressed regions the per-frame transfers read (graphics port
    // map 2.7).
    .{ .name = "players/art_1", .pack = .raw, .source = 0x40000, .size = 0x9E40, .what = "the players' art (the transfer tables 0x1A160 and 0x1A53E)" },
    .{ .name = "players/art_2", .pack = .raw, .source = 0x4A5BE, .size = 0x9B60, .what = "the players' art (the transfer tables 0x1A160 and 0x1A53E)" },
    .{ .name = "players/art_3", .pack = .raw, .source = 0x54A2A, .size = 0xA300, .what = "the players' art (the transfer tables 0x1A160 and 0x1A53E)" },
};

pub fn find(source: u32) ?*const Block {
    for (&catalogue) |*b| if (b.source == source) return b;
    return null;
}

pub fn findName(name: []const u8) ?*const Block {
    for (&catalogue) |*b| if (std.mem.eql(u8, b.name, name)) return b;
    return null;
}

pub const Error = error{ BadData, UnknownBlock } || nemesis.Error || kosinski.Error;

/// A decoded block: its bytes and its tiles.
pub const Decoded = struct {
    block: Block,
    bytes: []const u8,
    tiles: []const art.Tile,
};

/// 4-bit pixels as tiles (the left pixel in the high nibble); a partial tile is dropped.
pub fn tilesOf(arena: std.mem.Allocator, bytes: []const u8) ![]art.Tile {
    const tiles = try arena.alloc(art.Tile, bytes.len / 32);
    for (tiles, 0..) |*t, i| {
        for (0..32) |k| {
            const b = bytes[i * 32 + k];
            t[k * 2] = b >> 4;
            t[k * 2 + 1] = b & 15;
        }
    }
    return tiles;
}

/// The blocks decoded on demand, each once; blocks outside the catalogue (the rounds' art) are
/// added by their users.
pub const Library = struct {
    arena: std.mem.Allocator,
    rom: []const u8,
    decoded: std.AutoArrayHashMapUnmanaged(u32, Decoded) = .empty,

    pub fn get(self: *Library, source: u32) Error!*const Decoded {
        if (self.decoded.getPtr(source)) |d| return d;
        const b = find(source) orelse return error.UnknownBlock;
        return self.decode(b.*);
    }

    pub fn byName(self: *Library, name: []const u8) Error!*const Decoded {
        const b = findName(name) orelse return error.UnknownBlock;
        return self.get(b.source);
    }

    /// Decodes `b`, which need not be in the catalogue.
    pub fn decode(self: *Library, b: Block) Error!*const Decoded {
        if (self.decoded.getPtr(b.source)) |d| return d;
        const bytes: []const u8 = switch (b.pack) {
            .nemesis => (try nemesis.decompress(self.arena, self.rom, b.source)).bytes,
            .kosinski => (try kosinski.decompress(self.arena, self.rom, b.source)).bytes,
            .raw => blk: {
                if (b.source + b.size > self.rom.len) return error.BadData;
                break :blk self.rom[b.source..][0..b.size];
            },
        };
        try self.decoded.put(self.arena, b.source, .{ .block = b, .bytes = bytes, .tiles = try tilesOf(self.arena, bytes) });
        return self.decoded.getPtr(b.source).?;
    }
};

/// "ROM 0x1CEC0: a Nemesis stream, the game's font (…)".
pub fn provenanceOf(arena: std.mem.Allocator, b: Block) ![]const u8 {
    const kind = switch (b.pack) {
        .nemesis => "a Nemesis stream",
        .kosinski => "a Kosinski block",
        .raw => "tiles",
    };
    return std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: {s}, {s}", .{ b.source, kind, b.what });
}

test "the catalogue's names are valid and each block is named once" {
    for (catalogue, 0..) |b, i| {
        const slash = std.mem.lastIndexOfScalar(u8, b.name, '/').?;
        try std.testing.expect(art.validSetName(b.name[0..slash]));
        try std.testing.expect(art.validName(b.name[slash + 1 ..]));
        for (catalogue[0..i]) |o| {
            try std.testing.expect(o.source != b.source);
            try std.testing.expect(!std.mem.eql(u8, o.name, b.name));
        }
    }
}

test "tiles from 4-bit pixels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bytes: [40]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i);
    const t = try tilesOf(arena.allocator(), &bytes);
    try std.testing.expectEqual(@as(usize, 1), t.len);
    try std.testing.expectEqual(@as(u8, 0), t[0][2]);
    try std.testing.expectEqual(@as(u8, 1), t[0][3]);
    try std.testing.expectEqual(@as(u8, 0xF), t[0][63]);
}

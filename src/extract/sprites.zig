//! The sprite frames (graphics port map 2.7, 3.5): the animation sets the code names, the frames
//! their animations show (in address order), and each frame composed into one picture from its
//! pieces, over the art the set is drawn with: the players' per-frame transfers, a Nemesis block
//! at the objects' name base, or the video memory a screen's set-up leaves. Every frame of the
//! ROM uses one palette and one priority in all its pieces, and mirrors about its origin
//! (docs/content.md), so the picture is the frame.
const std = @import("std");
const sorz = @import("sorz");
const art = sorz.content.art;
const rom_mod = @import("rom.zig");
const blocks = @import("blocks.zig");
const vram_mod = @import("vram.zig");
const screens = @import("screens.zig");
const builder_mod = @import("builder.zig");
const Builder = builder_mod.Builder;
const Vram = vram_mod.Vram;

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const s16be = rom_mod.s16be;

/// The players' per-frame transfer tables (0x1A0B4): from index 1, 6 bytes an entry, the source
/// registers $95, $96 and $97 (a ROM word address). Table A's entry fills the player's tiles
/// $580 to $5A1, then table B's $5A0 to $5BF.
pub const transfers_a = 0x1A160;
pub const transfers_b = 0x1A53E;

/// The ROM address an entry of a transfer table names, or null when it is not one.
pub fn transferSource(rom: []const u8, table: u32, index: u32) ?u32 {
    const e = table + 6 * index;
    if (rom[e] != 0x95 or rom[e + 2] != 0x96 or rom[e + 4] != 0x97) return null;
    return ((@as(u32, rom[e + 5]) << 16) | (@as(u32, rom[e + 3]) << 8) | rom[e + 1]) * 2;
}

/// The art a set's frames are drawn with.
const Art = union(enum) {
    /// The players: each frame's two transfers.
    players,
    /// A Nemesis block whose first tile is the pieces' tile `first` (the video tile the block is
    /// loaded at, less the objects' name base); below it, the pieces' tile 0 is play's tile 0,
    /// the first tile of every round's art, blank.
    nemesis: struct { source: u32, first: u16 = 0 },
    /// Runs of frames, each over its own Nemesis block (an object whose name base changes with
    /// its pose).
    runs: []const Run,
    /// The video memory a screen leaves, from the objects' name base.
    screen: []const ScreenRun,
};

const Run = struct { first: u16, last: u16, source: u32 };
const ScreenRun = struct { first: u16, last: u16, layout: Layout, base: u11 };
const Layout = enum { title, title_japan, demo, twins };

/// The colours a set's pictures are shown with in their files.
const View = enum { grey, play, title };

const Set = struct {
    source: u32,
    /// The art set the frames go to, and their names' prefix (none: a character's own set).
    dir: []const u8,
    prefix: []const u8 = "",
    player: bool = false,
    art: Art,
    view: View = .grey,
    what: []const u8,
};

/// Mr. X (0x3468A), by the name base each pose is drawn with, over the block round 8's art lists
/// (5 and 6) load there: standing and walking at $25C, his gun at $2EC, hit at $3B6, seated at
/// $130.
const mrx_runs = [_]Run{
    .{ .first = 0, .last = 10, .source = 0x2F55A },
    .{ .first = 11, .last = 18, .source = 0x2FFC0 },
    .{ .first = 19, .last = 26, .source = 0x30FD8 },
    .{ .first = 27, .last = 34, .source = 0x35190 },
};

/// The intro's and the title's pictures (0x3A300) by animation and name base: the profiles'
/// faces ($x15D), the heroes ($x22F), "press start" ($C031), the title's words ($04E6; in Japan
/// $04D9), the trademark ($822F).
const intro_runs = [_]ScreenRun{
    .{ .first = 0, .last = 2, .layout = .title, .base = 0x15D },
    .{ .first = 3, .last = 4, .layout = .title, .base = 0x22F },
    .{ .first = 5, .last = 8, .layout = .title, .base = 0x031 },
    .{ .first = 9, .last = 10, .layout = .title, .base = 0x4E6 },
    .{ .first = 11, .last = 12, .layout = .title_japan, .base = 0x4D9 },
    .{ .first = 13, .last = 13, .layout = .title, .base = 0x22F },
};

const sets = [_]Set{
    .{ .source = 0x49AE0, .dir = "axel", .player = true, .art = .players, .view = .play, .what = "Axel" },
    .{ .source = 0x53EFE, .dir = "adam", .player = true, .art = .players, .view = .play, .what = "Adam" },
    .{ .source = 0x5E90A, .dir = "blaze", .player = true, .art = .players, .view = .play, .what = "Blaze" },
    .{ .source = 0x1FC70, .dir = "galsia", .art = .{ .nemesis = .{ .source = 0x20172 } }, .view = .play, .what = "Galsia, types $20 to $23" },
    .{ .source = 0x22948, .dir = "signal", .art = .{ .nemesis = .{ .source = 0x21708 } }, .view = .play, .what = "Signal, type $24" },
    .{ .source = 0x2402C, .dir = "acrobat", .art = .{ .nemesis = .{ .source = 0x22BFE } }, .view = .play, .what = "the acrobat, types $25 and $2A" },
    .{ .source = 0x242F8, .dir = "brawler", .art = .{ .nemesis = .{ .source = 0x245E0 } }, .view = .play, .what = "the brawler, type $26" },
    .{ .source = 0x2556C, .dir = "juggler", .art = .{ .nemesis = .{ .source = 0x258F8 } }, .view = .play, .what = "the knife juggler and its knives, types $27 and $28" },
    .{ .source = 0x2E8B4, .dir = "antonio", .art = .{ .nemesis = .{ .source = 0x29264 } }, .view = .play, .what = "Antonio, round 1's boss, and his boomerang (types $56, ...)" },
    .{ .source = 0x2E44A, .dir = "round2_boss", .art = .{ .nemesis = .{ .source = 0x27162 } }, .view = .play, .what = "round 2's boss, type $55" },
    .{ .source = 0x34B94, .dir = "round3_boss", .art = .{ .nemesis = .{ .source = 0x31DC4 } }, .view = .play, .what = "round 3's boss, type $30, and its part, type $31" },
    .{ .source = 0x2EF62, .dir = "round4_boss", .art = .{ .nemesis = .{ .source = 0x2BC48 } }, .view = .play, .what = "round 4's boss, type $57" },
    .{ .source = 0x2DD70, .dir = "twins", .art = .{ .screen = &.{.{ .first = 0, .last = 36, .layout = .twins, .base = 0 }} }, .view = .play, .what = "round 5's bosses, the twins, type $58" },
    .{ .source = 0x3468A, .dir = "mrx", .art = .{ .runs = &mrx_runs }, .view = .play, .what = "Mr. X, round 8's boss" },
    .{ .source = 0x70A78, .dir = "police", .art = .{ .nemesis = .{ .source = 0x6FDBC } }, .view = .play, .what = "the police car of the special attack" },
    .{ .source = 0x1E2B2, .dir = "special", .prefix = "fire", .art = .{ .nemesis = .{ .source = 0x1DC16, .first = 0x4C6 } }, .view = .play, .what = "the special attack's fire" },
    .{ .source = 0x1E78C, .dir = "special", .prefix = "blast", .art = .{ .nemesis = .{ .source = 0x1E35E, .first = 0x4C0 } }, .view = .play, .what = "the special attack's shell" },
    .{ .source = 0x6F06E, .dir = "play", .prefix = "arrow", .art = .{ .nemesis = .{ .source = 0x6EEC0 } }, .view = .play, .what = "the arrow that says go on" },
    .{ .source = 0x6F0A2, .dir = "play", .prefix = "spark", .art = .{ .nemesis = .{ .source = 0x6EEC0 } }, .view = .play, .what = "the hit sparks" },
    .{ .source = 0x6F0CC, .dir = "play", .prefix = "shadow", .art = .{ .nemesis = .{ .source = 0x6EEC0 } }, .view = .play, .what = "the shadow" },
    .{ .source = 0x6F2B0, .dir = "items", .prefix = "beef", .art = .{ .nemesis = .{ .source = 0x6F0DC, .first = 0x4B6 } }, .view = .play, .what = "the beef, type $47" },
    .{ .source = 0x6F2C0, .dir = "items", .prefix = "apple", .art = .{ .nemesis = .{ .source = 0x6F0DC, .first = 0x4B6 } }, .view = .play, .what = "the apple, type $4B" },
    .{ .source = 0x6F2D0, .dir = "items", .prefix = "life", .art = .{ .nemesis = .{ .source = 0x6F0DC, .first = 0x4B6 } }, .view = .play, .what = "the extra life, type $4C" },
    .{ .source = 0x6F2E0, .dir = "items", .prefix = "special", .art = .{ .nemesis = .{ .source = 0x6F0DC, .first = 0x4B6 } }, .view = .play, .what = "the extra special attack, type $4F" },
    .{ .source = 0x7222C, .dir = "items", .prefix = "money", .art = .{ .nemesis = .{ .source = 0x72146, .first = 0x578 } }, .view = .play, .what = "the money, type $3F" },
    .{ .source = 0x7223C, .dir = "items", .prefix = "gold", .art = .{ .nemesis = .{ .source = 0x72146, .first = 0x578 } }, .view = .play, .what = "the gold, type $40" },
    .{ .source = 0x6FA06, .dir = "weapons", .prefix = "knife", .art = .{ .nemesis = .{ .source = 0x6F552, .first = 0x520 } }, .view = .play, .what = "the knife, type $08" },
    .{ .source = 0x6FA9A, .dir = "weapons", .prefix = "pipe", .art = .{ .nemesis = .{ .source = 0x6F552, .first = 0x520 } }, .view = .play, .what = "the pipe, type $0A" },
    .{ .source = 0x6FB5A, .dir = "weapons", .prefix = "pipe_2", .art = .{ .nemesis = .{ .source = 0x6F552, .first = 0x520 } }, .view = .play, .what = "the second pipe, type $0B" },
    .{ .source = 0x6FC1A, .dir = "weapons", .prefix = "bat", .art = .{ .nemesis = .{ .source = 0x6F552, .first = 0x520 } }, .view = .play, .what = "the baseball bat, type $09" },
    .{ .source = 0x6FCAE, .dir = "weapons", .prefix = "bat_broken", .art = .{ .nemesis = .{ .source = 0x6F552, .first = 0x520 } }, .view = .play, .what = "the bat once splintered" },
    .{ .source = 0x6FD42, .dir = "weapons", .prefix = "splinters", .art = .{ .nemesis = .{ .source = 0x6F552, .first = 0x520 } }, .view = .play, .what = "the bat's splinters, type $1E" },
    .{ .source = 0x26F7A, .dir = "round1", .prefix = "shutter", .art = .{ .nemesis = .{ .source = 0x26F90 } }, .view = .play, .what = "round 1's rolling shutter" },
    .{ .source = 0x6CCE8, .dir = "round1", .prefix = "breakable", .art = .{ .nemesis = .{ .source = 0x6C910, .first = 0x223 } }, .view = .play, .what = "the street's breakables, type $11" },
    .{ .source = 0x6D25E, .dir = "round2", .prefix = "obstacle", .art = .{ .nemesis = .{ .source = 0x6CD68, .first = 0xDE } }, .view = .play, .what = "round 2's obstacles, type $19" },
    .{ .source = 0x6D2A6, .dir = "round2", .prefix = "drip", .art = .{ .nemesis = .{ .source = 0x6CD68, .first = 0xDE } }, .view = .play, .what = "round 2's drips, type $14" },
    .{ .source = 0x6D2E6, .dir = "round2", .prefix = "scenery", .art = .{ .nemesis = .{ .source = 0x6CD68, .first = 0xDE } }, .view = .play, .what = "round 2's scenery that flies across" },
    .{ .source = 0x6D32E, .dir = "round2", .prefix = "flight", .art = .{ .nemesis = .{ .source = 0x6CD68, .first = 0xDE } }, .view = .play, .what = "round 2's flights across the screen, type $4D" },
    .{ .source = 0x6D5D2, .dir = "round3", .prefix = "drifter", .art = .{ .nemesis = .{ .source = 0x6D366, .first = 0x109 } }, .view = .play, .what = "round 3's drifting scenery, type $16" },
    .{ .source = 0x6D5EE, .dir = "round3", .prefix = "rain", .art = .{ .nemesis = .{ .source = 0x6D366, .first = 0x109 } }, .view = .play, .what = "round 3's rain, type $17" },
    .{ .source = 0x6D628, .dir = "round3", .prefix = "obstacle", .art = .{ .nemesis = .{ .source = 0x6D366, .first = 0x109 } }, .view = .play, .what = "round 3's obstacle that breaks in four, type $18" },
    .{ .source = 0x6D672, .dir = "round3", .prefix = "lamp", .art = .{ .nemesis = .{ .source = 0x6D366, .first = 0x109 } }, .view = .play, .what = "round 3's lamps, type $4E" },
    .{ .source = 0x6DB60, .dir = "round4", .prefix = "obstacle_1", .art = .{ .nemesis = .{ .source = 0x6D698, .first = 0xDD } }, .view = .play, .what = "round 4's obstacles, type $1B" },
    .{ .source = 0x6DB94, .dir = "round4", .prefix = "obstacle_2", .art = .{ .nemesis = .{ .source = 0x6D698, .first = 0xDD } }, .view = .play, .what = "round 4's obstacles, type $1C" },
    .{ .source = 0x6DBC8, .dir = "round4", .prefix = "obstacle_3", .art = .{ .nemesis = .{ .source = 0x6D698, .first = 0xDD } }, .view = .play, .what = "round 4's obstacles, type $1D" },
    .{ .source = 0x6DEBE, .dir = "round5", .prefix = "obstacle", .art = .{ .nemesis = .{ .source = 0x6DC0E, .first = 0xE2 } }, .view = .play, .what = "round 5's obstacles, type $1F" },
    .{ .source = 0x6E46C, .dir = "round6", .prefix = "shatter", .art = .{ .nemesis = .{ .source = 0x6DF0A, .first = 0xEA } }, .view = .play, .what = "round 6's obstacle that shatters, type $41" },
    .{ .source = 0x6E4A0, .dir = "round6", .prefix = "press", .art = .{ .nemesis = .{ .source = 0x6DF0A, .first = 0xEA } }, .view = .play, .what = "round 6's press, type $42" },
    .{ .source = 0x6E7EA, .dir = "round7", .prefix = "lift_wall", .art = .{ .nemesis = .{ .source = 0x6E4E8, .first = 0xE9 } }, .view = .play, .what = "round 7's lift: its wall" },
    .{ .source = 0x6E822, .dir = "round7", .prefix = "lift_rails", .art = .{ .nemesis = .{ .source = 0x6E4E8, .first = 0xE9 } }, .view = .play, .what = "round 7's lift: its rails" },
    .{ .source = 0x6E84C, .dir = "round7", .prefix = "lift_floor", .art = .{ .nemesis = .{ .source = 0x6E4E8, .first = 0xE9 } }, .view = .play, .what = "round 7's lift: its floor and its opener" },
    .{ .source = 0x6ED4A, .dir = "round8", .prefix = "splinters", .art = .{ .nemesis = .{ .source = 0x6E870, .first = 0xEE } }, .view = .play, .what = "the door's splinters of Mr. X's room, type $44" },
    .{ .source = 0x6ED72, .dir = "round8", .prefix = "trolley", .art = .{ .nemesis = .{ .source = 0x6E870, .first = 0xEE } }, .view = .play, .what = "round 8's trolley, type $45" },
    .{ .source = 0x6EDBC, .dir = "round8", .prefix = "door", .art = .{ .nemesis = .{ .source = 0x6E870, .first = 0xEE } }, .view = .play, .what = "the door and the trapdoors of Mr. X's room, types $46 and $1A" },
    .{ .source = 0x6EDC2, .dir = "round8", .prefix = "statue", .art = .{ .nemesis = .{ .source = 0x6E870, .first = 0xEE } }, .view = .play, .what = "round 8's gold statues, type $15" },
    .{ .source = 0x71EFC, .dir = "select", .prefix = "label", .art = .{ .nemesis = .{ .source = 0x70CB0, .first = 1 } }, .what = "the character select's labels (0x1A8A)" },
    .{ .source = 0x3A300, .dir = "intro", .prefix = "picture", .art = .{ .screen = &intro_runs }, .view = .title, .what = "the intro's and the title's pictures (0x3A300)" },
    .{ .source = 0x0676E, .dir = "demo", .prefix = "press_start", .art = .{ .screen = &.{.{ .first = 0, .last = 1, .layout = .demo, .base = 0 }} }, .what = "the attract demo's sign, type $3E" },
    .{ .source = 0x3ED66, .dir = "ending", .prefix = "sprite", .art = .{ .nemesis = .{ .source = 0x3C744 } }, .what = "the ending's walkers, rider and glow (types $87 to $8C)" },
    .{ .source = 0x1F990, .dir = "boss_ending", .prefix = "axel", .art = .{ .nemesis = .{ .source = 0x1EB02 } }, .what = "Axel in the boss's chair (0x8E62)" },
    .{ .source = 0x7272C, .dir = "boss_ending", .prefix = "adam", .art = .{ .nemesis = .{ .source = 0x1EB02 } }, .what = "Adam in the boss's chair (0x8E62)" },
    .{ .source = 0x1FA46, .dir = "boss_ending", .prefix = "blaze", .art = .{ .nemesis = .{ .source = 0x1EB02 } }, .what = "Blaze in the boss's chair (0x8E62)" },
};

/// A frame of the ROM: its pieces (y, size, name word, x), its two transfers for a player.
const Piece = struct { y: i8, size: u8, name: u16, x: i8 };

const Parsed = struct {
    address: u32,
    pieces: []const Piece,
    transfers: [2]u8 = .{ 0, 0 },
};

/// Whether the frame at `fa` reads as one: a count of pieces less one (negative: none, only $FF),
/// at most $50 pieces, each size byte a width and a height of 1 to 4 cells.
fn validFrame(rom: []const u8, fa: u32, player: bool) bool {
    if (fa + 8 >= rom.len) return false;
    const n = rom[fa];
    if (n & 0x80 != 0) return n == 0xFF;
    if (n > 0x4F) return false;
    const start = fa + 5 + @as(u32, if (player) 2 else 0);
    if (start + 5 * (@as(u32, n) + 1) > rom.len) return false;
    for (0..@as(usize, n) + 1) |i| if (rom[start + 5 * @as(u32, @intCast(i)) + 1] > 0x0F) return false;
    return true;
}

/// The frames the set's animations show, in address order: its table of signed word offsets
/// (no count: it ends where the first animation starts; 0 is no animation), each animation a
/// count, a timing and its frames' offsets (bit 15: drawn mirrored).
fn frameAddresses(arena: std.mem.Allocator, rom: []const u8, base: u32) ![]u32 {
    var anims: std.ArrayList(u32) = .empty;
    var limit: u32 = 256;
    var i: u32 = 0;
    while (i < limit) : (i += 1) {
        const off = s16be(rom, base + 2 * i);
        if (off == 0 and i != 0) continue;
        if (off <= 0) return error.BadData;
        const a = base + @as(u32, @intCast(off));
        limit = @min(limit, @as(u32, @intCast(off)) / 2);
        if (rom[a] < 1 or rom[a] > 64) return error.BadData;
        if (std.mem.indexOfScalar(u32, anims.items, a) == null) try anims.append(arena, a);
    }
    var frames: std.ArrayList(u32) = .empty;
    for (anims.items) |a| {
        for (0..rom[a]) |k| {
            const w = u16be(rom, a + 2 + 2 * @as(u32, @intCast(k)));
            const fa = a + (w & 0x7FFF);
            if (std.mem.indexOfScalar(u32, frames.items, fa) == null) try frames.append(arena, fa);
        }
    }
    std.mem.sort(u32, frames.items, {}, std.sort.asc(u32));
    return frames.items;
}

fn parseFrame(arena: std.mem.Allocator, rom: []const u8, fa: u32, player: bool) !?Parsed {
    if (!validFrame(rom, fa, player)) return null;
    const n = rom[fa];
    var f: Parsed = .{ .address = fa, .pieces = &.{} };
    var a = fa + 5;
    if (player) {
        f.transfers = .{ rom[a], rom[a + 1] };
        a += 2;
    }
    if (n & 0x80 != 0) return f;
    const pieces = try arena.alloc(Piece, @as(usize, n) + 1);
    for (pieces) |*p| {
        p.* = .{ .y = @bitCast(rom[a]), .size = rom[a + 1], .name = u16be(rom, a + 2), .x = @bitCast(rom[a + 4]) };
        a += 5;
    }
    f.pieces = pieces;
    return f;
}

/// Where a frame's tiles come from: the pieces' tile numbers to tiles (null for none).
const Tiles = struct {
    ctx: *const anyopaque,
    get: *const fn (*const anyopaque, u16) ?*const art.Tile,
};

const blank_tile: art.Tile = @splat(0);

const SheetTiles = struct {
    tiles: []const art.Tile,
    first: u16,
    fn get(ctx: *const anyopaque, t: u16) ?*const art.Tile {
        const self: *const SheetTiles = @ptrCast(@alignCast(ctx));
        if (t == 0 and self.first > 0) return &blank_tile;
        if (t < self.first or t - self.first >= self.tiles.len) return null;
        return &self.tiles[t - self.first];
    }
};

const VramTiles = struct {
    tiles: []const ?art.Tile,
    base: u11,
    fn get(ctx: *const anyopaque, t: u16) ?*const art.Tile {
        const self: *const VramTiles = @ptrCast(@alignCast(ctx));
        const v = (@as(usize, self.base) + t) & 0x7FF;
        return if (self.tiles[v]) |*tile| tile else null;
    }
};

/// The players' tiles $580 to $5BF after a frame's two transfers.
const PlayerTiles = struct {
    tiles: [64]?art.Tile = @splat(null),
    fn get(ctx: *const anyopaque, t: u16) ?*const art.Tile {
        const self: *const PlayerTiles = @ptrCast(@alignCast(ctx));
        if (t < 0x580 or t >= 0x5C0) return null;
        return if (self.tiles[t - 0x580]) |*tile| tile else null;
    }
};

const Composed = struct { width: u16, height: u16, origin_x: i16, origin_y: i16, pixels: []u8 };

/// The frame drawn unmirrored as the hardware draws its pieces, the first on top; a piece's
/// tiles go down its columns first. Null when a tile is missing.
fn compose(arena: std.mem.Allocator, pieces: []const Piece, tiles: Tiles) !?Composed {
    if (pieces.len == 0) return null;
    var x0: i32 = std.math.maxInt(i32);
    var y0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var y1: i32 = std.math.minInt(i32);
    for (pieces) |p| {
        const w: i32 = ((p.size >> 2) & 3) + 1;
        const h: i32 = (p.size & 3) + 1;
        x0 = @min(x0, p.x);
        y0 = @min(y0, p.y);
        x1 = @max(x1, @as(i32, p.x) + 8 * w);
        y1 = @max(y1, @as(i32, p.y) + 8 * h);
    }
    const width: usize = @intCast(x1 - x0);
    const height: usize = @intCast(y1 - y0);
    const px = try arena.alloc(u8, width * height);
    @memset(px, 0);
    var k = pieces.len;
    while (k > 0) {
        k -= 1;
        const p = pieces[k];
        const pw: usize = ((p.size >> 2) & 3) + 1;
        const ph: usize = (p.size & 3) + 1;
        const hf = p.name & 0x800 != 0;
        const vf = p.name & 0x1000 != 0;
        const t0: u16 = p.name & 0x7FF;
        for (0..ph * 8) |sy| for (0..pw * 8) |sx| {
            const ux = if (hf) pw * 8 - 1 - sx else sx;
            const uy = if (vf) ph * 8 - 1 - sy else sy;
            const t: u16 = @intCast((t0 + (ux / 8) * ph + uy / 8) & 0x7FF);
            const tile = tiles.get(tiles.ctx, t) orelse return null;
            const v = tile[(uy % 8) * 8 + ux % 8];
            if (v == 0) continue;
            const ox: usize = @intCast(@as(i32, p.x) - x0 + @as(i32, @intCast(sx)));
            const oy: usize = @intCast(@as(i32, p.y) - y0 + @as(i32, @intCast(sy)));
            px[oy * width + ox] = v;
        };
    }
    return .{ .width = @intCast(width), .height = @intCast(height), .origin_x = @intCast(-x0), .origin_y = @intCast(-y0), .pixels = px };
}

/// The video memory of a layout, as tiles (null for a slot no step wrote).
fn layoutTiles(b: *Builder, layout: Layout) ![]?art.Tile {
    const v: *Vram = switch (layout) {
        // The intro's set-up and the title's copies (0xB558 and the VBlank's copy 2).
        .title => try screens.replay(b, screens.title_steps),
        // The same with the name in Japan (Kosinski list entries 9 and 8 at $89A0).
        .title_japan => try screens.replay(b, &(screens.intro_japan_steps ++ [_]screens.Step{
            .{ .copy = .{ .ram = 0xFF2C00, .address = 0x0620, .tiles = 9 * 4 } },
        })),
        .demo => try demoVram(b),
        .twins => try twinsVram(b),
    };
    const out = try b.arena.alloc(?art.Tile, vram_mod.slots);
    for (out, 0..) |*o, s| {
        o.* = if (v.written.isSet(s)) (try blocks.tilesOf(b.arena, &v.bytes[s]))[0] else null;
    }
    return out;
}

/// The attract demo's sign (0x119E0): round 1's art at its video addresses, then the sign's
/// letters: the italic font unpacked at $FF7000, and the tiles the list at 0x11A20 names (to
/// $FF) copied one after the other from video address $D400.
const demo_letters = 0x11A20;

fn demoVram(b: *Builder) !*Vram {
    const rom = b.rom;
    const v = try b.arena.create(Vram);
    v.* = .{};
    v.clear();
    const rounds = @import("rounds.zig");
    const h = rounds.header(rom, 0);
    for (0..2) |k| {
        const cmd = u32be(rom, @intCast(h + 8 * k));
        const src = u32be(rom, @intCast(h + 8 * k + 4));
        const d = try b.lib.decode(.{ .name = if (k == 0) "round1/art_1" else "round1/art_2", .pack = .kosinski, .source = src, .what = "" });
        try v.writeTiles(vram_mod.commandAddress(cmd), src, 0, d.bytes[0 .. d.bytes.len & ~@as(usize, 31)]);
    }
    const font = try b.lib.byName("fonts/italic");
    var at: u32 = demo_letters;
    var address: u32 = 0xD400;
    while (rom[at] != 0xFF) : (at += 1) {
        const t: usize = rom[at];
        if (32 * (t + 1) > font.bytes.len) return error.BadData;
        try v.writeTiles(address, font.block.source, @intCast(t), font.bytes[32 * t ..][0..32]);
        address += 32;
    }
    return v;
}

/// Round 5's bosses' art (0x17FC2): 42 transfers of the table at 0x18018 (10 bytes an entry: an
/// index of transfer table A, B for the last 6, the length registers $93 and $94, the write
/// command), from the players' art to video memory.
const twin_copies = 0x18018;
const twin_copies_end = 0x181BC;
const twin_copies_b = 0x168;

fn twinsVram(b: *Builder) !*Vram {
    const rom = b.rom;
    const v = try b.arena.create(Vram);
    v.* = .{};
    var e: u32 = twin_copies;
    while (e < twin_copies_end) : (e += 10) {
        const table: u32 = if (e - twin_copies < twin_copies_b) transfers_a else transfers_b;
        const source = transferSource(rom, table, u16be(rom, e)) orelse return error.BadData;
        if (rom[e + 2] != 0x93 or rom[e + 4] != 0x94) return error.BadData;
        const bytes = 2 * (@as(u32, rom[e + 5]) << 8 | rom[e + 3]);
        if (source + bytes > rom.len) return error.BadData;
        try v.writeTiles(vram_mod.commandAddress(u32be(rom, e + 6)), 0, 0, rom[source..][0..bytes]);
    }
    return v;
}

fn artText(arena: std.mem.Allocator, a: Art, index: usize) ![]const u8 {
    return switch (a) {
        .players => "its two transfers of the players' art (tables 0x1A160 and 0x1A53E)",
        .nemesis => |n| if (n.first == 0)
            try std.fmt.allocPrint(arena, "the Nemesis block at ROM 0x{X:0>5}", .{n.source})
        else
            try std.fmt.allocPrint(arena, "the Nemesis block at ROM 0x{X:0>5}, its first tile the pieces' tile ${X:0>3}", .{ n.source, n.first }),
        .runs => |runs| for (runs) |r| {
            if (index >= r.first and index <= r.last) break try std.fmt.allocPrint(arena, "the Nemesis block at ROM 0x{X:0>5}", .{r.source});
        } else "",
        .screen => |runs| for (runs) |r| {
            if (index >= r.first and index <= r.last) break try std.fmt.allocPrint(arena, "the video memory of the {s} from tile ${X:0>3}", .{ switch (r.layout) {
                .title => "title's set-up",
                .title_japan => "title's set-up in Japan",
                .demo => "attract demo's sign (0x119E0)",
                .twins => "twins' copies (0x17FC2)",
            }, r.base });
        } else "",
    };
}

/// The colours of play's palettes once a round starts: round 1's colours, then play's.
fn playColours(rom: []const u8) ![art.palette_count][art.palette_size]art.Colour {
    var c: [art.palette_count][art.palette_size]art.Colour = @splat(@splat(art.Colour.black));
    const rounds = @import("rounds.zig");
    const lists = [_]u32{ u32be(rom, rounds.header(rom, 0) + 28), 0x6F2F0, 0x115AC };
    for (lists) |l| (try builder_mod.paletteList(rom, l)).apply(&c);
    return c;
}

fn titleColours(rom: []const u8) ![art.palette_count][art.palette_size]art.Colour {
    var c: [art.palette_count][art.palette_size]art.Colour = @splat(@splat(art.Colour.black));
    for ([_]u8{ 13, 12, 11, 10, 9, 15, 7 }) |i| {
        const off: i16 = @bitCast(u16be(rom, screens.screen_palettes + 2 * @as(u32, i)));
        (try builder_mod.paletteList(rom, @intCast(@as(i32, screens.screen_palettes) + off))).apply(&c);
    }
    return c;
}

pub const Stats = struct { frames: usize = 0, empty: usize = 0, unparsed: usize = 0, missing: usize = 0 };

/// Every set's frames into the builder.
pub fn extract(b: *Builder) !Stats {
    const arena = b.arena;
    const rom = b.rom;
    var stats: Stats = .{};
    const play = try playColours(rom);
    const title_c = try titleColours(rom);
    var layouts: [std.enums.values(Layout).len]?[]?art.Tile = @splat(null);
    for (sets) |set| {
        if (set.prefix.len == 0) try b.describe(set.dir, try std.fmt.allocPrint(arena, "{s}: the frames of the animation set at ROM 0x{X:0>5}", .{ set.what, set.source }));
        const addresses = try frameAddresses(arena, rom, set.source);
        for (addresses, 0..) |fa, index| {
            const parsed = try parseFrame(arena, rom, fa, set.player) orelse {
                stats.unparsed += 1;
                std.log.info("{s}: the frame at ROM 0x{X:0>5} does not read as one: left out", .{ set.dir, fa });
                continue;
            };
            if (parsed.pieces.len == 0) {
                stats.empty += 1;
                continue;
            }
            var player_tiles: PlayerTiles = .{};
            var sheet_tiles: SheetTiles = undefined;
            var vram_tiles: VramTiles = undefined;
            const tiles: Tiles = switch (set.art) {
                .players => blk: {
                    for ([_]struct { table: u32, index: u8, first: usize, count: usize }{
                        .{ .table = transfers_a, .index = parsed.transfers[0], .first = 0, .count = 34 },
                        .{ .table = transfers_b, .index = parsed.transfers[1], .first = 32, .count = 32 },
                    }) |t| {
                        if (t.index == 0) continue;
                        const src = transferSource(rom, t.table, t.index) orelse return error.BadData;
                        if (src + 32 * t.count > rom.len) return error.BadData;
                        const ts = try blocks.tilesOf(arena, rom[src..][0 .. 32 * t.count]);
                        for (ts, 0..) |tile, k| player_tiles.tiles[t.first + k] = tile;
                    }
                    break :blk .{ .ctx = &player_tiles, .get = PlayerTiles.get };
                },
                .nemesis => |n| blk: {
                    sheet_tiles = .{ .tiles = (try b.lib.get(n.source)).tiles, .first = n.first };
                    break :blk .{ .ctx = &sheet_tiles, .get = SheetTiles.get };
                },
                .runs => |runs| blk: {
                    const r = for (runs) |r| {
                        if (index >= r.first and index <= r.last) break r;
                    } else return error.BadData;
                    sheet_tiles = .{ .tiles = (try b.lib.get(r.source)).tiles, .first = 0 };
                    break :blk .{ .ctx = &sheet_tiles, .get = SheetTiles.get };
                },
                .screen => |runs| blk: {
                    const r = for (runs) |r| {
                        if (index >= r.first and index <= r.last) break r;
                    } else return error.BadData;
                    const k = @backingInt(r.layout);
                    if (layouts[k] == null) layouts[k] = try layoutTiles(b, r.layout);
                    vram_tiles = .{ .tiles = layouts[k].?, .base = r.base };
                    break :blk .{ .ctx = &vram_tiles, .get = VramTiles.get };
                },
            };
            const img = try compose(arena, parsed.pieces, tiles) orelse {
                stats.missing += 1;
                std.log.info("{s}: the frame at ROM 0x{X:0>5} names a tile its art does not give: left out", .{ set.dir, fa });
                continue;
            };
            const first = parsed.pieces[0].name;
            const palette: u2 = @intCast((first >> 13) & 3);
            const pieces = try arena.alloc(art.Piece, parsed.pieces.len);
            for (pieces, parsed.pieces) |*o, p| o.* = .{ .x = p.x, .y = p.y, .width = ((p.size >> 2) & 3) + 1, .height = (p.size & 3) + 1 };
            const own = if (set.prefix.len == 0)
                try std.fmt.allocPrint(arena, "{d:0>3}", .{index})
            else
                try std.fmt.allocPrint(arena, "{s}_{d:0>2}", .{ set.prefix, index });
            try b.frame(try std.fmt.allocPrint(arena, "{s}/{s}", .{ set.dir, own }), .{
                .name = "",
                .provenance = try std.fmt.allocPrint(arena, "ROM 0x{X:0>5}: frame {d} of the animation set at ROM 0x{X:0>5} ({s}), {d} pieces, drawn from {s}", .{ fa, index, set.source, set.what, parsed.pieces.len, try artText(arena, set.art, index) }),
                .file = try std.fmt.allocPrint(arena, "{s}.png", .{own}),
                .width = img.width,
                .height = img.height,
                .origin_x = img.origin_x,
                .origin_y = img.origin_y,
                .pixels = img.pixels,
                .palette = palette,
                .priority = first & 0x8000 != 0,
                .pieces = pieces,
                .view = switch (set.view) {
                    .grey => art.grey,
                    .play => play[palette],
                    .title => title_c[palette],
                },
            });
            stats.frames += 1;
        }
    }
    return stats;
}

test "a frame composes with its origin, its pieces' flips and order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tiles: [4]art.Tile = undefined;
    for (&tiles, 0..) |*t, i| {
        @memset(t, 0);
        t[0] = @intCast(i + 1); // the top-left pixel names the tile
    }
    const st: SheetTiles = .{ .tiles = &tiles, .first = 0 };
    // Piece 0: 1 x 2 cells at (-8, -16), tiles 0 and 1, on top. Piece 1: 1 x 1 at (-8, -8),
    // tile 2, mirrored across, under piece 0.
    const pieces = [_]Piece{
        .{ .y = -16, .size = 0b0001, .name = 0, .x = -8 },
        .{ .y = -8, .size = 0, .name = 0x802, .x = -8 },
    };
    const img = (try compose(arena.allocator(), &pieces, .{ .ctx = &st, .get = SheetTiles.get })).?;
    try std.testing.expectEqual(@as(u16, 8), img.width);
    try std.testing.expectEqual(@as(u16, 16), img.height);
    try std.testing.expectEqual(@as(i16, 8), img.origin_x);
    try std.testing.expectEqual(@as(i16, 16), img.origin_y);
    try std.testing.expectEqual(@as(u8, 1), img.pixels[0]);
    try std.testing.expectEqual(@as(u8, 2), img.pixels[8 * 8]);
    // Piece 1's mirrored pixel at column 7 of row 8 shows where piece 0 is transparent.
    try std.testing.expectEqual(@as(u8, 3), img.pixels[8 * 8 + 7]);
    // A tile the art does not give: no picture.
    const bad = [_]Piece{.{ .y = 0, .size = 0, .name = 9, .x = 0 }};
    try std.testing.expect(try compose(arena.allocator(), &bad, .{ .ctx = &st, .get = SheetTiles.get }) == null);
}

test "a set's frames, from its table, in address order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rom: [64]u8 = @splat(0);
    // The table: two entries, the second 0 (no animation); the animation at +4: 2 frames, timing
    // 5, the frames at +8 and +4 from it (the second mirrored), so in address order the second
    // comes first.
    std.mem.writeInt(u16, rom[0..2], 4, .big);
    rom[4] = 2;
    rom[5] = 5;
    std.mem.writeInt(u16, rom[6..8], 8, .big);
    std.mem.writeInt(u16, rom[8..10], 0x8004, .big);
    const frames = try frameAddresses(arena.allocator(), &rom, 0);
    try std.testing.expectEqualSlices(u32, &.{ 8, 12 }, frames);
}

test "a transfer table's entry names a ROM address" {
    var rom: [transfers_a + 12]u8 = @splat(0);
    @memcpy(rom[transfers_a + 6 ..][0..6], &[_]u8{ 0x95, 0x10, 0x96, 0x00, 0x97, 0x02 });
    try std.testing.expectEqual(@as(?u32, 0x40020), transferSource(&rom, transfers_a, 1));
    try std.testing.expectEqual(@as(?u32, null), transferSource(&rom, transfers_a, 0));
}

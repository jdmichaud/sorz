//! The screens' art: each screen's set-up replayed as the original runs it (the loads of art to
//! video memory, the blocks unpacked into RAM and copied, the maps drawn, the palettes applied),
//! and each map it draws turned into a tile map over named sheets (graphics port map 1.1-1.3,
//! 3.3). A step names its source in the ROM; the routine it replays is in its comment.
const std = @import("std");
const sorz = @import("sorz");
const art = sorz.content.art;
const rom_mod = @import("rom.zig");
const blocks = @import("blocks.zig");
const enigma = @import("enigma.zig");
const kosinski = @import("kosinski.zig");
const nemesis = @import("nemesis.zig");
const vram_mod = @import("vram.zig");
const builder_mod = @import("builder.zig");
const Builder = builder_mod.Builder;
const Vram = vram_mod.Vram;

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;

// The ROM's tables of art (graphics port map 2.2, 2.4).
pub const pattern_loads = 0xA662; // 8 bytes an entry, 1-based: a write command, a Nemesis source
pub const kosinski_list = 0xB768; // 8 bytes an entry: a source, a RAM address
pub const enigma_list = 0xA85A; // 10 bytes an entry, 1-based: a RAM address, a source, a base
pub const word_rects = 0xA612; // a long an entry, 1-based
pub const byte_rects = 0xA8D6; // a long an entry, 1-based
pub const screen_rects = 0x3F5B6; // 8 bytes an entry: a RAM address, a video address, w - 1, h - 1
pub const screen_palettes = 0x3F29C; // a word offset an entry
pub const menu_lines = 0x1060; // 3 entries: a write command and 10 codes
pub const menu_line_adds = 0x108A; // the words added to the second and third lines

pub const Step = union(enum) {
    /// The display cleared (0x7FB8): every tile slot blank.
    clear,
    layout: vram_mod.Layout,
    clear_ram: struct { at: u32, len: u32 },
    /// A pattern-load entry (0xA63A): its Nemesis block to its video address.
    pattern: u8,
    /// A Nemesis block to a video address (an art list's entry, 0x8454).
    nemesis: struct { source: u32, address: u16 },
    /// A Kosinski list entry unpacked to its RAM (0xB748).
    kosinski: u8,
    /// A Kosinski block unpacked to RAM (0x85A2).
    unpack: struct { source: u32, ram: u32 },
    /// Tiles of the RAM copied to video memory (0x10496, 0x104C6, the VBlank's 0x19DC4).
    copy: struct { ram: u32, address: u16, tiles: u16 },
    /// An Enigma list entry decoded to its RAM with its header (0xA82A).
    enigma: u8,
    /// A word rectangle of the list (0xA5F4), from the ROM or the RAM, as the map `map`.
    word_rect: struct { entry: u8, map: []const u8 },
    /// A byte rectangle of the list (0xA8B8) as the map `map`.
    byte_rect: struct { entry: u8, map: []const u8 },
    /// A screen rectangle (0xB9BA): RAM words plus `add`, rows `row` bytes apart.
    screen_rect: struct { entry: u8, add: u16, row: u16 = 128, map: []const u8 },
    /// The game menu's three lines (0xFE8), as three maps.
    menu_lines: [3][]const u8,
    /// Cells a routine writes one by one, as the map `map` of one row.
    cells: struct { address: u16, words: []const u16, map: []const u8, why: []const u8 },
    /// A palette list as the palette `name`.
    palette: struct { list: u32, name: []const u8, why: []const u8 = "" },
    /// A screen palette list (0xB736) as the palette `name`.
    screen_palette: struct { index: u8, name: []const u8, why: []const u8 = "" },
    /// The palette list a long of the ROM points at, as the palette `name`.
    palette_long: struct { at: u32, name: []const u8, why: []const u8 },
    /// The palette list of entry `index` of a table of word offsets from the table, as `name`.
    palette_offset: struct { table: u32, index: u8, name: []const u8, why: []const u8 },
    /// Colours a routine sets itself, as the palette `name`.
    colours: struct { places: []const u8, words: []const u16, name: []const u8, why: []const u8 },
};

pub const Screen = struct {
    /// The art set.
    name: []const u8,
    what: []const u8,
    steps: []const Step,
    /// Other sets the screen draws with (its sprites').
    uses: []const []const u8 = &.{},
};

/// The intro's set-up (0xB42E) outside Japan, up to its first maps: the display cleared, the
/// screens' layout (0x3F284: 64 x 64 cells), the intro's blocks unpacked (the Kosinski list's
/// entries 5 to 0) and copied to video memory, the title's name (entries 7 and 6) copied to
/// $89A0, the title's picture, texts and maps unpacked (10, 11, 12), and the story's kana
/// (pattern-load entry 37).
const intro_setup = [_]Step{
    .clear,
    .{ .layout = .{ .width = 64, .height = 64, .window = null } },
    .{ .clear_ram = .{ .at = 0xFF0000, .len = 0x1B4 * 128 } },
    .{ .kosinski = 5 },
    .{ .kosinski = 4 },
    .{ .kosinski = 3 },
    .{ .kosinski = 2 },
    .{ .kosinski = 1 },
    .{ .kosinski = 0 },
    .{ .copy = .{ .ram = 0xFF0000, .address = 0x0000, .tiles = 0x18 * 4 } },
    .{ .copy = .{ .ram = 0xFF0BE0, .address = 0x1AC0, .tiles = 0xB2 * 4 } },
    .{ .kosinski = 7 },
    .{ .kosinski = 6 },
    .{ .copy = .{ .ram = 0xFF0000, .address = 0x89A0, .tiles = 0x35 * 4 } },
    .{ .kosinski = 10 },
    .{ .clear_ram = .{ .at = 0xFF5E00, .len = 8 * 128 } },
    .{ .kosinski = 11 },
    .{ .kosinski = 12 },
    .{ .pattern = 37 },
};

/// The city (screen rectangles 1 and 0 with $20D6: palette 1 over the tiles from $1AC0), on
/// plane B's two halves, drawn by the intro's set-up and the title's.
const city = [_]Step{
    .{ .screen_rect = .{ .entry = 1, .add = 0x20D6, .map = "intro/city_right" } },
    .{ .screen_rect = .{ .entry = 0, .add = 0x20D6, .map = "intro/city_left" } },
};

const intro = Screen{
    .name = "intro",
    .what = "the intro: the city, the story and the profiles (set-up 0xB42E, its objects 0xBxxx-0xDxxx)",
    .uses = &.{"fonts"},
    .steps = &(intro_setup ++ city ++ [_]Step{
        .{ .colours = .{ .places = &.{ 1, 12 }, .words = &.{ 0xEEE, 0x888 }, .name = "intro/start", .why = "the colours the intro's set-up sets itself (0xB44C)" } },
        .{ .screen_palette = .{ .index = 7, .name = "intro/city", .why = "the city's colours, faded in on palette 1 (type $61, 0xD112)" } },
        .{ .screen_palette = .{ .index = 15, .name = "intro/city_lights", .why = "with the city's again (types $6C and $73)" } },
        .{ .screen_palette = .{ .index = 8, .name = "intro/profiles", .why = "the profiles' colours (type $69, 0xCD66)" } },
        .{ .screen_palette = .{ .index = 9, .name = "intro/story_colours_2", .why = "the story's palette 2 after its flash (type $71, 0xD3D6)" } },
        .{ .screen_palette = .{ .index = 10, .name = "intro/story_colours_3", .why = "the story's palette 3 after its flash (type $72, 0xD444)" } },
        // The story's pictures (type $62, 0xD210): the planes cleared, 128 x 32 cells, and the
        // screen rectangles 7 down to 2 with $814D, every other row.
        .{ .layout = .{ .width = 128, .height = 32, .window = null } },
        .{ .screen_rect = .{ .entry = 7, .add = 0x814D, .row = 256, .map = "intro/story_frame_1" } },
        .{ .screen_rect = .{ .entry = 6, .add = 0x814D, .row = 256, .map = "intro/story_frame_2" } },
        .{ .screen_rect = .{ .entry = 5, .add = 0x814D, .row = 256, .map = "intro/story_frame_3" } },
        .{ .screen_rect = .{ .entry = 4, .add = 0x814D, .row = 256, .map = "intro/story_frame_4" } },
        .{ .screen_rect = .{ .entry = 3, .add = 0x814D, .row = 256, .map = "intro/story_frame_5" } },
        .{ .screen_rect = .{ .entry = 2, .add = 0x814D, .row = 256, .map = "intro/story_frame_6" } },
    }),
};

/// The title's video memory over the intro's (0xB558, or the intro's end): its texts copied to
/// $0620 (from $FF2C00) and its picture to $7340 (the VBlank's copy 2, from $FF1600).
pub const title_copies = [_]Step{
    .{ .layout = .{ .width = 64, .height = 64, .window = null } },
    .{ .copy = .{ .ram = 0xFF2C00, .address = 0x0620, .tiles = 9 * 4 } },
    .{ .copy = .{ .ram = 0xFF1600, .address = 0x7340, .tiles = 0x1600 / 32 } },
};

/// The title's video memory outside Japan, the art its sprites are drawn with.
pub const title_layout = intro_setup ++ title_copies;

/// The title (0xB558, or the intro's end): its video memory, its palettes (screen palettes 13,
/// 12, 11, 10, 9, 15 and 7, the last first); the city, the picture (screen rectangle 8 with
/// $C39A) and the name (10 and 9 with $044D).
const title = Screen{
    .name = "title",
    .what = "the title screen (set-up 0xB558, objects $70 to $7F)",
    .uses = &.{"intro"},
    .steps = &(title_layout ++ [_]Step{
        .{ .screen_palette = .{ .index = 13, .name = "title/flash", .why = "the title's flash (type $7D, 0xD548)" } },
        .{ .screen_palette = .{ .index = 12, .name = "title/name", .why = "the title's name (types $77, $81)" } },
        .{ .screen_palette = .{ .index = 11, .name = "title/colours", .why = "the title's colours (type $77, 0xC394)" } },
        .{ .screen_palette = .{ .index = 10, .name = "intro/story_colours_3" } },
        .{ .screen_palette = .{ .index = 9, .name = "intro/story_colours_2" } },
        .{ .screen_palette = .{ .index = 15, .name = "intro/city_lights" } },
        .{ .screen_palette = .{ .index = 7, .name = "intro/city" } },
    } ++ city ++ [_]Step{
        .{ .screen_rect = .{ .entry = 8, .add = 0xC39A, .map = "title/hero" } },
        .{ .screen_rect = .{ .entry = 10, .add = 0x044D, .map = "title/name_1" } },
        .{ .screen_rect = .{ .entry = 9, .add = 0x044D, .map = "title/name_2" } },
        // In Japan (0xC492): the Japanese name (entries 9 and 8) copied to $89A0 instead, and
        // screen rectangles 12 and 11.
        .{ .screen_palette = .{ .index = 14, .name = "title/colours_japan", .why = "the title's colours in Japan (type $81, 0xC492)" } },
        .{ .kosinski = 9 },
        .{ .kosinski = 8 },
        .{ .copy = .{ .ram = 0xFF0000, .address = 0x89A0, .tiles = 0x35 * 4 } },
        .{ .screen_rect = .{ .entry = 12, .add = 0x044D, .map = "title/name_japan_1" } },
        .{ .screen_rect = .{ .entry = 11, .add = 0x044D, .map = "title/name_japan_2" } },
    }),
};

/// The Sega logo (0x8EAC): the display cleared, its colours, the logo's tiles and the font
/// (pattern-load entries 1 and 3), its map (Enigma entry 1 at $FF0000, drawn by word rectangle
/// 1), and outside Japan the trademark's two cells (0x8EFC) in white.
const segalogo = Screen{
    .name = "segalogo",
    .what = "the Sega logo (0x8EAC, mode $02 0x8F44)",
    .steps = &.{
        .clear,
        .{ .palette = .{ .list = 0x7228A, .name = "segalogo/colours", .why = "the Sega logo's colours" } },
        .{ .pattern = 1 },
        .{ .pattern = 3 },
        .{ .enigma = 1 },
        .{ .word_rect = .{ .entry = 1, .map = "segalogo/logo" } },
        .{ .cells = .{ .address = 0xC5B4, .words = &.{ 0x27D4, 0x27CD }, .map = "segalogo/trademark", .why = "the trademark's cells outside Japan (0x8EFC)" } },
        .{ .colours = .{ .places = &.{17}, .words = &.{0xEEE}, .name = "segalogo/trademark", .why = "the trademark's colour outside Japan (0x8EFC)" } },
    },
};

/// The game menu (0xFE8): the font at $0000 (pattern-load entry 2), the three lines (0x1060),
/// the colours with a second pad or without.
const menu = Screen{
    .name = "menu",
    .what = "the game menu (0xFE8, mode $10)",
    .uses = &.{"fonts"},
    .steps = &.{
        .{ .pattern = 2 },
        .{ .menu_lines = .{ "menu/one_player", "menu/two_players", "menu/options" } },
        .{ .palette = .{ .list = 0x7267C, .name = "menu/two_pads", .why = "the menu's colours with a second pad" } },
        .{ .palette = .{ .list = 0x72684, .name = "menu/one_pad", .why = "the menu's colours without a second pad (its second line dimmed)" } },
    },
};

/// The options (0x11BC to 0x14E2, mode $12): its lines (byte rectangles 4 to 16; 11 to 16 the
/// lines of 5 to 10 on palette 1, the chosen one).
const options = Screen{
    .name = "options",
    .what = "the options screen (0x11BC to 0x14E2)",
    .uses = &.{"fonts"},
    .steps = &.{
        .{ .pattern = 2 },
        .{ .palette = .{ .list = 0x7267C, .name = "menu/two_pads" } },
        .{ .byte_rect = .{ .entry = 4, .map = "options/title" } },
        .{ .byte_rect = .{ .entry = 5, .map = "options/sound_test" } },
        .{ .byte_rect = .{ .entry = 6, .map = "options/level" } },
        .{ .byte_rect = .{ .entry = 7, .map = "options/control" } },
        .{ .byte_rect = .{ .entry = 8, .map = "options/players" } },
        .{ .byte_rect = .{ .entry = 9, .map = "options/round" } },
        .{ .byte_rect = .{ .entry = 10, .map = "options/exit" } },
        .{ .byte_rect = .{ .entry = 11, .map = "options/sound_test_chosen" } },
        .{ .byte_rect = .{ .entry = 12, .map = "options/level_chosen" } },
        .{ .byte_rect = .{ .entry = 13, .map = "options/control_chosen" } },
        .{ .byte_rect = .{ .entry = 14, .map = "options/players_chosen" } },
        .{ .byte_rect = .{ .entry = 15, .map = "options/round_chosen" } },
        .{ .byte_rect = .{ .entry = 16, .map = "options/exit_chosen" } },
    },
};

/// The character select (0x1634): its art (pattern-load entries $35, $20 and 3), its frame
/// (0x71C6C unpacked at $FF8000, word rectangle 4), its texts (byte rectangles $11 to $16), the
/// pictures word rectangles 6 and 7 change (0x1AA4), and its colours.
const select = Screen{
    .name = "select",
    .what = "the character select (0x1634, mode $20)",
    .uses = &.{ "fonts", "axel", "adam", "blaze" },
    .steps = &.{
        .{ .pattern = 0x35 },
        .{ .pattern = 0x20 },
        .{ .pattern = 0x03 },
        .{ .unpack = .{ .source = 0x71C6C, .ram = 0xFF8000 } },
        .{ .word_rect = .{ .entry = 4, .map = "select/frame" } },
        .{ .byte_rect = .{ .entry = 0x11, .map = "select/adam_stats" } },
        .{ .byte_rect = .{ .entry = 0x12, .map = "select/axel_stats" } },
        .{ .byte_rect = .{ .entry = 0x13, .map = "select/blaze_stats" } },
        .{ .byte_rect = .{ .entry = 0x14, .map = "select/adam_name" } },
        .{ .byte_rect = .{ .entry = 0x15, .map = "select/axel_name" } },
        .{ .byte_rect = .{ .entry = 0x16, .map = "select/blaze_name" } },
        .{ .word_rect = .{ .entry = 6, .map = "select/picture_1" } },
        .{ .word_rect = .{ .entry = 7, .map = "select/picture_2" } },
        .{ .palette = .{ .list = 0x71F30, .name = "select/colours", .why = "the character select's colours" } },
        .{ .palette = .{ .list = 0x1706, .name = "select/cursors_two", .why = "the cursors' colours with two players" } },
        .{ .palette = .{ .list = 0x1708, .name = "select/cursors_one", .why = "the cursor's colour with one player" } },
        .{ .palette = .{ .list = 0x19F0, .name = "select/frame_dim_1", .why = "a portrait's frame dimmed (0x1916)" } },
        .{ .palette = .{ .list = 0x19F2, .name = "select/frame_dim_2", .why = "a portrait's frame dimmed (0x1916)" } },
        .{ .palette = .{ .list = 0x19F4, .name = "select/frame_dim_3", .why = "a portrait's frame dimmed (0x1916)" } },
        .{ .palette = .{ .list = 0x19F6, .name = "select/frame_lit_1", .why = "a portrait's frame lit (0x1916)" } },
        .{ .palette = .{ .list = 0x19F8, .name = "select/frame_lit_2", .why = "a portrait's frame lit (0x1916)" } },
        .{ .palette = .{ .list = 0x19FA, .name = "select/frame_lit_3", .why = "a portrait's frame lit (0x1916)" } },
    },
};

/// The high scores (0x1260E): the display cleared, the font (pattern-load entry 2), the titles
/// (byte rectangles 1 to 3) and the colours.
const highscores = Screen{
    .name = "highscores",
    .what = "the high scores (0x1260E, mode $0C)",
    .uses = &.{"fonts"},
    .steps = &.{
        .clear,
        .{ .palette = .{ .list = 0x12922, .name = "highscores/colours", .why = "the high scores' colours" } },
        .{ .pattern = 2 },
        .{ .byte_rect = .{ .entry = 1, .map = "highscores/title" } },
        .{ .byte_rect = .{ .entry = 2, .map = "highscores/columns" } },
        .{ .byte_rect = .{ .entry = 3, .map = "highscores/ranks" } },
    },
};

/// Play (0x110AC, 0x11564): the art every round loads after its own (pattern-load entries
/// round + 12, 3, 4, 33, 52, 54, 56 or 57, and 5), the status bar's frame (Enigma entries 2
/// and 5, drawn in the window by word rectangles 2 and 9), and the colours every round shares.
const play = Screen{
    .name = "play",
    .what = "play's own art: the status bar and the colours every round shares (0x110AC, 0x11564)",
    .uses = &.{"fonts"},
    .steps = &.{
        .clear,
        .{ .pattern = 12 },
        .{ .pattern = 3 },
        .{ .pattern = 4 },
        .{ .pattern = 33 },
        .{ .pattern = 52 },
        .{ .pattern = 54 },
        .{ .pattern = 56 },
        .{ .enigma = 2 },
        .{ .enigma = 5 },
        .{ .word_rect = .{ .entry = 2, .map = "play/status_bar" } },
        .{ .pattern = 5 },
        .{ .word_rect = .{ .entry = 9, .map = "play/enemy_bar" } },
        .{ .palette = .{ .list = 0x6F2F0, .name = "play/colours", .why = "the colours of play (0x11132)" } },
        .{ .palette = .{ .list = 0x115AC, .name = "play/players", .why = "palette 0 of play: the players and the status bar (0x11564)" } },
        .{ .palette = .{ .list = 0x5A78, .name = "play/police", .why = "the police special's colours (0x5A22)" } },
    },
};

/// Mr. X's offer in round 8 (0x11C42): its window's frame (Enigma entry 6, in Japan 4), drawn in
/// the window by word rectangle 2.
const offer = Screen{
    .name = "offer",
    .what = "Mr. X's offer in round 8: its window (0x11C42)",
    .uses = &.{ "fonts", "play" },
    .steps = &.{
        .clear,
        .{ .pattern = 19 },
        .{ .pattern = 3 },
        .{ .pattern = 4 },
        .{ .pattern = 33 },
        .{ .pattern = 52 },
        .{ .pattern = 54 },
        .{ .pattern = 57 },
        .{ .pattern = 5 },
        .{ .enigma = 6 },
        .{ .word_rect = .{ .entry = 2, .map = "offer/window" } },
        .{ .enigma = 4 },
        .{ .word_rect = .{ .entry = 2, .map = "offer/window_japan" } },
    },
};

/// The ending after round 8 (0xB3C6): the screens' layout, its art (pattern-load entries $2B to
/// $30), the italic font and the ending's maps unpacked (Kosinski list entries 0 and 13), 48 of
/// the font's tiles copied after the last load's ($7EA0, 0xB3F2), and its pictures (screen
/// rectangles 13 to 20 with the words of 0xC35E added, drawn by 0xC336).
const ending = Screen{
    .name = "ending",
    .what = "the ending after round 8 (0xB3C6, mode $24; its objects $82 to $8D)",
    .uses = &.{"fonts"},
    .steps = &.{
        .clear,
        .{ .layout = .{ .width = 64, .height = 64, .window = null } },
        .{ .pattern = 0x2B },
        .{ .pattern = 0x2C },
        .{ .pattern = 0x2D },
        .{ .pattern = 0x2E },
        .{ .pattern = 0x2F },
        .{ .pattern = 0x30 },
        .{ .kosinski = 0 },
        .{ .kosinski = 13 },
        .{ .copy = .{ .ram = 0xFF0000, .address = 0x7EA0, .tiles = 12 * 4 } },
        .{ .clear_ram = .{ .at = 0xFF0620, .len = 12 * 128 } },
        .{ .screen_rect = .{ .entry = 13, .add = 0x21D3, .map = "ending/picture_1" } },
        .{ .screen_rect = .{ .entry = 14, .add = 0x0000, .map = "ending/picture_2" } },
        .{ .screen_rect = .{ .entry = 15, .add = 0x2299, .map = "ending/picture_3" } },
        .{ .screen_rect = .{ .entry = 16, .add = 0x212E, .map = "ending/picture_4" } },
        .{ .screen_rect = .{ .entry = 17, .add = 0x4100, .map = "ending/scene_1" } },
        .{ .screen_rect = .{ .entry = 18, .add = 0x8100, .map = "ending/scene_2" } },
        .{ .screen_rect = .{ .entry = 19, .add = 0xA12E, .map = "ending/scene_3" } },
        .{ .screen_rect = .{ .entry = 20, .add = 0xA12E, .map = "ending/scene_4" } },
        .{ .screen_palette = .{ .index = 0, .name = "ending/colours_00", .why = "faded in on palette 1 with the first picture (type $83, 0xC17C)" } },
        .{ .screen_palette = .{ .index = 1, .name = "ending/colours_01", .why = "faded in on palette 1 with the second picture (type $83)" } },
        .{ .screen_palette = .{ .index = 2, .name = "ending/colours_02", .why = "faded in on palette 2 with the second picture (type $83)" } },
        .{ .screen_palette = .{ .index = 3, .name = "ending/colours_03", .why = "faded in on palette 1 with the third picture (type $83)" } },
        .{ .screen_palette = .{ .index = 4, .name = "ending/colours_04", .why = "faded in on palette 1 with the fourth picture (type $83)" } },
        .{ .screen_palette = .{ .index = 5, .name = "ending/colours_05", .why = "faded in on palette 2 with the fourth picture (type $83)" } },
        .{ .screen_palette = .{ .index = 6, .name = "ending/colours_06", .why = "faded in on palette 3 with the fourth picture (type $83)" } },
        .{ .screen_palette = .{ .index = 22, .name = "ending/colours_22", .why = "faded in on palette 0 with the fourth picture (type $83)" } },
        .{ .screen_palette = .{ .index = 16, .name = "ending/colours_16", .why = "the ending's scene (type $8B, 0xBD10)" } },
        .{ .screen_palette = .{ .index = 17, .name = "ending/colours_17", .why = "the ending's scene (type $8B)" } },
        .{ .screen_palette = .{ .index = 18, .name = "ending/colours_18", .why = "the ending's scene (type $8B)" } },
        .{ .screen_palette = .{ .index = 19, .name = "ending/colours_19", .why = "the ending's scene (type $8B)" } },
        .{ .screen_palette = .{ .index = 20, .name = "ending/colours_20", .why = "the ending's scene (type $8B)" } },
        .{ .screen_palette = .{ .index = 21, .name = "ending/colours_21", .why = "the ending's scene (type $8B)" } },
    },
};

/// The ending where the players take the boss's place (0x87C6): its art (pattern-load entries
/// $26 and $27), the italic font copied to $F800 (from $FF7000), the room's map (0x1F596
/// unpacked at $FF8000, word rectangle 2) and its colours.
const boss_ending = Screen{
    .name = "boss_ending",
    .what = "the ending where the players take the boss's place (0x87C6, mode $1C)",
    .uses = &.{"fonts"},
    .steps = &([_]Step{
        .clear,
        .{ .pattern = 0x26 },
        .{ .pattern = 0x27 },
        .{ .unpack = .{ .source = 0x389A0, .ram = 0xFF7000 } },
        .{ .copy = .{ .ram = 0xFF7000, .address = 0xF800, .tiles = 50 } },
        .{ .unpack = .{ .source = 0x1F596, .ram = 0xFF8000 } },
        .{ .word_rect = .{ .entry = 2, .map = "boss_ending/room" } },
        .{ .palette_long = .{ .at = 0x8880, .name = "boss_ending/room", .why = "the room's colours (0x87C6)" } },
        .{ .palette_long = .{ .at = 0x8884, .name = "boss_ending/axel", .why = "Axel's colours in the chair (0x87C6)" } },
        .{ .palette_long = .{ .at = 0x8888, .name = "boss_ending/adam", .why = "Adam's colours in the chair (0x87C6)" } },
        .{ .palette_long = .{ .at = 0x888C, .name = "boss_ending/blaze", .why = "Blaze's colours in the chair (0x87C6)" } },
        .{ .palette = .{ .list = 0x1F98C, .name = "boss_ending/credits", .why = "the credits' colours (0x8A4C)" } },
    } ++ boss_ending_steps),
};

/// The boss ending's colour steps (0x8D82): every 4 ticks, the room's next of five, then the
/// character's (the word offsets at 0x1F716: the room's five, then Axel's, Adam's and Blaze's).
const boss_ending_steps = blk: {
    var s: [20]Step = undefined;
    const who = [_][]const u8{ "room", "axel", "adam", "blaze" };
    for (&s, 0..) |*x, i| x.* = .{ .palette_offset = .{
        .table = 0x1F716,
        .index = i,
        .name = std.fmt.comptimePrint("boss_ending/{s}_step_{d}", .{ who[i / 5], i % 5 + 1 }),
        .why = std.fmt.comptimePrint("the {s}'s colours at step {d} of 5 (0x8D82)", .{ if (i < 5) "room" else who[i / 5], i % 5 + 1 }),
    } };
    break :blk s;
};

/// The round's end (0x181EA): the big letters (pattern-load entry $20) and its colours.
const round_end = Screen{
    .name = "round_end",
    .what = "the round's end and its bonuses (0x181EA)",
    .uses = &.{ "fonts", "play" },
    .steps = &.{
        .{ .pattern = 0x20 },
        .{ .palette = .{ .list = 0x1DC0A, .name = "round_end/colours", .why = "the bonuses' colours, faded in (0x18226)" } },
    },
};

pub const screens = [_]*const Screen{ &segalogo, &intro, &title, &menu, &options, &select, &highscores, &play, &offer, &round_end, &ending, &boss_ending };

pub const Error = builder_mod.Error || error{ UnresolvedTile, NoPlace };

/// The state of a screen being replayed.
pub const Run = struct {
    b: *Builder,
    v: *Vram,
    screen: *const Screen,
    /// The palettes as the screen's palette lists leave them, for the sheets' views.
    colours: [art.palette_count][art.palette_size]art.Colour = @splat(@splat(art.Colour.black)),
    /// The palette each sheet's cells use most (counts by palette).
    lines: std.StringArrayHashMapUnmanaged([art.palette_count]u32) = .empty,

    fn rom(self: *const Run) []const u8 {
        return self.b.rom;
    }

    pub fn step(self: *Run, s: Step) Error!void {
        const r = self.rom();
        const v = self.v;
        switch (s) {
            .clear => v.clear(),
            .layout => |l| v.layout = l,
            .clear_ram => |c| v.clearRam(c.at, c.len),
            .pattern => |i| {
                const e: u32 = pattern_loads + (@as(u32, i) - 1) * 8;
                try self.nemesisTo(u32be(r, e + 4), vram_mod.commandAddress(u32be(r, e)));
            },
            .nemesis => |n| try self.nemesisTo(n.source, n.address),
            .kosinski => |i| {
                const e: u32 = kosinski_list + 8 * @as(u32, i);
                try self.unpackTo(u32be(r, e), u32be(r, e + 4));
            },
            .unpack => |u| try self.unpackTo(u.source, u.ram),
            .copy => |c| try v.copy(c.ram, c.address, c.tiles),
            .enigma => |i| {
                const e: u32 = enigma_list + (@as(u32, i) - 1) * 10;
                const ram = u32be(r, e);
                const src = u32be(r, e + 4);
                const base = u16be(r, e + 8);
                const words = (try enigma.decompress(self.b.arena, r, src + 8, base)).words;
                // 0x82D2: the rectangle's header (a write command, width - 1, height - 1) first.
                var bytes = try self.b.arena.alloc(u8, 8 + 2 * words.len);
                @memcpy(bytes[0..8], r[src..][0..8]);
                for (words, 0..) |w, k| std.mem.writeInt(u16, bytes[8 + 2 * k ..][0..2], w, .big);
                v.unpack(ram, src, bytes);
            },
            .word_rect => |w| {
                const at = u32be(r, word_rects + 4 * @as(u32, w.entry));
                const ram = at >= 0xFF0000;
                const read = struct {
                    fn word(vv: *const Vram, rr: []const u8, in_ram: bool, a: u32) u16 {
                        return if (in_ram) vv.ramWord(a) else u16be(rr, a);
                    }
                };
                const cmd = @as(u32, read.word(v, r, ram, at)) << 16 | read.word(v, r, ram, at + 2);
                const width = read.word(v, r, ram, at + 4) + 1;
                const height = read.word(v, r, ram, at + 6) + 1;
                const words = try self.b.arena.alloc(u16, @as(usize, width) * height);
                for (words, 0..) |*x, k| x.* = read.word(v, r, ram, at + 8 + 2 * @as(u32, @intCast(k)));
                const why = if (ram)
                    try std.fmt.allocPrint(self.b.arena, "ROM 0x{X:0>5}: the map unpacked at RAM ${X:0>6}, drawn by word rectangle {d} (0xA5F4)", .{ v.ram_block[at & 0xFFFF], at, w.entry })
                else
                    try std.fmt.allocPrint(self.b.arena, "ROM 0x{X:0>5}: word rectangle {d} (0xA5F4)", .{ at, w.entry });
                try self.map(w.map, words, width, height, vram_mod.commandAddress(cmd), 128, why, if (ram) .{ .ram_block = v.ram_block[at & 0xFFFF] } else .{ .rom_words = at });
            },
            .byte_rect => |w| {
                const at = u32be(r, byte_rects + 4 * @as(u32, w.entry));
                const cmd = u32be(r, at);
                const width = u16be(r, at + 4) + 1;
                const height = u16be(r, at + 6) + 1;
                const base = u16be(r, at + 8);
                const words = try self.b.arena.alloc(u16, @as(usize, width) * height);
                for (words, 0..) |*x, k| x.* = base +% r[at + 10 + k];
                const why = try std.fmt.allocPrint(self.b.arena, "ROM 0x{X:0>5}: byte rectangle {d} (0xA8B8), each byte added to ${X:0>4}", .{ at, w.entry, base });
                try self.map(w.map, words, width, height, vram_mod.commandAddress(cmd), 128, why, .{ .bytes = at });
            },
            .screen_rect => |sr| {
                const e: u32 = screen_rects + 8 * @as(u32, sr.entry);
                const from = u32be(r, e);
                const address = u16be(r, e + 4);
                const width: u16 = @as(u16, r[e + 6]) + 1;
                const height: u16 = @as(u16, r[e + 7]) + 1;
                const words = try self.b.arena.alloc(u16, @as(usize, width) * height);
                for (words, 0..) |*x, k| x.* = v.ramWord(from + 2 * @as(u32, @intCast(k))) +% sr.add;
                const ram_block = v.ram_block[from & 0xFFFF];
                const why = try std.fmt.allocPrint(self.b.arena, "screen rectangle {d} (0x3F5B6, drawn by 0xB9BA) from RAM ${X:0>6} (Kosinski block 0x{X:0>5}), each word plus ${X:0>4}", .{ sr.entry, from, ram_block, sr.add });
                try self.map(sr.map, words, width, height, address, sr.row, why, .{ .screen_rect = .{ .entry = sr.entry, .add = sr.add } });
            },
            .menu_lines => |names| {
                var at: u32 = menu_lines;
                var add: u16 = 0;
                for (names, 0..) |name, k| {
                    const cmd = u32be(r, at);
                    var words: [10]u16 = undefined;
                    for (&words, 0..) |*x, c| x.* = @as(u16, r[at + 4 + c]) +% add;
                    const why = try std.fmt.allocPrint(self.b.arena, "ROM 0x{X:0>5}: the game menu's line {d} (0xFE8), its codes plus ${X:0>4}", .{ at, k + 1, add });
                    try self.map(name, try self.b.arena.dupe(u16, &words), 10, 1, vram_mod.commandAddress(cmd), 128, why, .{ .menu_line = @intCast(k) });
                    at += 14;
                    add = u16be(r, menu_line_adds + 2 * @as(u32, @intCast(k)));
                }
            },
            .cells => |c| try self.map(c.map, c.words, @intCast(c.words.len), 1, c.address, 128, c.why, .code),
            .palette => |p| try self.palette(p.name, p.list, try std.fmt.allocPrint(self.b.arena, "ROM 0x{X:0>5}: a palette list{s}{s}", .{ p.list, if (p.why.len != 0) ", " else "", p.why })),
            .screen_palette => |p| {
                const off: i16 = @bitCast(u16be(r, screen_palettes + 2 * @as(u32, p.index)));
                const list: u32 = @intCast(@as(i32, screen_palettes) + off);
                try self.palette(p.name, list, try std.fmt.allocPrint(self.b.arena, "ROM 0x{X:0>5}: screen palette {d} (0x3F29C){s}{s}", .{ list, p.index, if (p.why.len != 0) ", " else "", p.why }));
            },
            .palette_long => |p| {
                const list = u32be(r, p.at);
                try self.palette(p.name, list, try std.fmt.allocPrint(self.b.arena, "ROM 0x{X:0>5}: a palette list (the long at 0x{X:0>5}), {s}", .{ list, p.at, p.why }));
            },
            .palette_offset => |p| {
                const off: i16 = @bitCast(u16be(r, p.table + 2 * @as(u32, p.index)));
                const list: u32 = @intCast(@as(i32, @intCast(p.table)) + off);
                try self.palette(p.name, list, try std.fmt.allocPrint(self.b.arena, "ROM 0x{X:0>5}: a palette list (entry {d} of the offsets at 0x{X:0>5}), {s}", .{ list, p.index, p.table, p.why }));
            },
            .colours => |c| {
                var p: art.Palette = .{ .name = "", .provenance = c.why };
                for (c.places, c.words) |place, w| p.colours[place / 16][place % 16] = builder_mod.colourOf(w);
                try self.b.palette(c.name, p);
                try self.b.origin(c.name, .{ .palette = null });
                p.apply(&self.colours);
                try self.b.use(self.screen.name, Builder.split(c.name).set);
            },
        }
    }

    fn nemesisTo(self: *Run, source: u32, address: u16) Error!void {
        const d = try self.b.lib.get(source);
        try self.v.writeTiles(address, source, 0, d.bytes);
    }

    fn unpackTo(self: *Run, source: u32, ram: u32) Error!void {
        const d = try self.b.lib.get(source);
        self.v.unpack(ram, source, d.bytes);
    }

    fn palette(self: *Run, name: []const u8, list: u32, why: []const u8) Error!void {
        var p = try builder_mod.paletteList(self.rom(), list);
        p.provenance = why;
        try self.b.palette(name, p);
        try self.b.origin(name, .{ .palette = list });
        p.apply(&self.colours);
        try self.b.use(self.screen.name, Builder.split(name).set);
    }

    /// The map `name` of `words` (cells as the console reads them: a tile slot, a palette, the
    /// flips and the priority), drawn at video address `address` with rows `row` bytes apart.
    pub fn map(self: *Run, name: []const u8, words: []const u16, width: u16, height: u16, address: u16, row: u16, why: []const u8, from: builder_mod.MapFrom) Error!void {
        var place: ?art.Place = null;
        if (self.v.place(address)) |p| {
            // A rectangle drawn with rows another distance apart than the plane's has no place.
            const plane_row: u16 = if (p.layer == .window) 128 else self.v.layout.width * 2;
            if (row == plane_row) place = .{ .layer = switch (p.layer) {
                .plane_a => .plane_a,
                .plane_b => .plane_b,
                .window => .window,
            }, .x = p.x, .y = p.y };
        }
        if (place == null) {
            std.log.warn("{s}: {s}: drawn at ${X:0>4} with rows {d} bytes apart: no layer's cell", .{ self.screen.name, name, address, row });
            return error.NoPlace;
        }
        return self.mapAt(name, words, width, height, place, why, from);
    }

    /// The map `name` of `words` at `place` (none: a round's whole plane).
    pub fn mapAt(self: *Run, name: []const u8, words: []const u16, width: u16, height: u16, place: ?art.Place, why: []const u8, from: builder_mod.MapFrom) Error!void {
        const arena = self.b.arena;
        // The sheets the cells draw from, by name.
        var names: std.ArrayList([]const u8) = .empty;
        for (words) |w| {
            const o = self.v.origin[w & 0x7FF] orelse continue;
            const blk = self.blockOf(o.block);
            for (names.items) |n| {
                if (std.mem.eql(u8, n, blk.name)) break;
            } else try names.append(arena, blk.name);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        const firsts = try arena.alloc(u16, names.items.len);
        var next: u16 = 0;
        for (names.items, firsts) |n, *f| {
            const blk = self.blockOf(self.blockSource(n));
            const d = try self.b.sheet(blk);
            f.* = next;
            next += @intCast(d.tiles.len);
        }
        const cells = try arena.alloc(art.Cell, words.len);
        for (cells, words, 0..) |*c, w, k| {
            const slot = w & 0x7FF;
            if (self.v.origin[slot]) |o| {
                const blk = self.blockOf(o.block);
                const d = try self.b.sheet(blk);
                if (o.tile >= d.tiles.len) return error.UnresolvedTile;
                const i = for (names.items, 0..) |n, j| {
                    if (std.mem.eql(u8, n, blk.name)) break j;
                } else unreachable;
                c.* = .{
                    .tile = firsts[i] + o.tile,
                    .palette = @intCast((w >> 13) & 3),
                    .flip_x = w & 0x800 != 0,
                    .flip_y = w & 0x1000 != 0,
                    .priority = w & 0x8000 != 0,
                };
                const gop = try self.lines.getOrPut(arena, blk.name);
                if (!gop.found_existing) gop.value_ptr.* = @splat(0);
                gop.value_ptr[c.palette] += 1;
            } else if (std.mem.allEqual(u8, &self.v.bytes[slot], 0) and (self.v.cleared or self.v.written.isSet(slot))) {
                c.* = .empty; // a blank slot draws nothing
                if (!self.v.written.isSet(slot)) std.log.debug("{s}: {s}: cell ({d}, {d}) names slot ${X:0>3}, blank since the display was cleared", .{ self.screen.name, name, k % width, k / width, slot });
            } else {
                std.log.warn("{s}: {s}: cell {d} ({d}, {d}) names tile slot ${X:0>3}, which holds no whole tile of a known block", .{ self.screen.name, name, k, k % width, k / width, slot });
                return error.UnresolvedTile;
            }
        }
        try self.b.map(name, .{
            .name = "",
            .provenance = why,
            .file = try std.fmt.allocPrint(arena, "{s}.tmj", .{Builder.split(name).own}),
            .width = width,
            .height = height,
            .sheets = try arena.dupe([]const u8, names.items),
            .cells = cells,
            .place = place,
        });
        try self.b.origin(name, .{ .map = .{ .words = words, .from = from } });
        try self.b.use(self.screen.name, Builder.split(name).set);
        for (names.items) |n| try self.b.use(self.screen.name, Builder.split(n).set);
    }

    fn blockSource(self: *Run, name: []const u8) u32 {
        for (self.b.lib.decoded.values()) |d| if (std.mem.eql(u8, d.block.name, name)) return d.block.source;
        unreachable;
    }

    /// The block decoded from `source` (the catalogue's, or one its user added).
    fn blockOf(self: *Run, source: u32) blocks.Block {
        if (blocks.find(source)) |b| return b.*;
        return self.b.lib.decoded.get(source).?.block;
    }

    /// Each sheet the screen's maps drew from is shown with the palette its cells use most.
    pub fn finish(self: *Run) Error!void {
        for (self.lines.keys(), self.lines.values()) |name, counts| {
            var best: usize = 0;
            for (counts, 0..) |n, i| if (n > counts[best]) {
                best = i;
            };
            try self.b.view(name, self.colours[best]);
        }
    }
};

/// Replays `screen` into the builder.
pub fn extract(b: *Builder, screen: *const Screen) Error!void {
    const v = try b.arena.create(Vram);
    v.* = .{};
    var run: Run = .{ .b = b, .v = v, .screen = screen };
    try b.describe(screen.name, screen.what);
    for (screen.uses) |u| try b.use(screen.name, u);
    for (screen.steps) |s| try run.step(s);
    try run.finish();
}

/// The video memory a screen's steps leave, for the sprites drawn over it.
pub fn replay(b: *Builder, steps: []const Step) Error!*Vram {
    const v = try b.arena.create(Vram);
    v.* = .{};
    const scratch: Screen = .{ .name = "", .what = "", .steps = steps };
    var run: Run = .{ .b = b, .v = v, .screen = &scratch };
    for (steps) |s| switch (s) {
        .palette, .screen_palette, .palette_long, .palette_offset, .colours, .word_rect, .byte_rect, .screen_rect, .menu_lines, .cells => {},
        else => try run.step(s),
    };
    return v;
}

pub const intro_steps: []const Step = &intro_setup;

/// The intro's set-up in Japan: the Japanese name (Kosinski list entries 9 and 8) in place of 7
/// and 6.
pub const intro_japan_steps = blk: {
    var s = intro_setup;
    s[11] = .{ .kosinski = 9 };
    s[12] = .{ .kosinski = 8 };
    break :blk s;
};

test "a map's cells resolve to their blocks' tiles, blank slots to empty cells" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A synthetic image: 3 tiles of raw art at 0x100.
    const rom = try arena.alloc(u8, 0x200);
    @memset(rom, 0);
    for (0..96) |i| rom[0x100 + i] = @intCast(0x11 * (1 + i / 32));
    var b = Builder.init(arena, rom);
    const blk: blocks.Block = .{ .name = "test/art", .pack = .raw, .source = 0x100, .size = 96, .what = "synthetic" };
    const d = try b.lib.decode(blk);
    const v = try arena.create(Vram);
    v.* = .{};
    v.clear();
    try v.writeTiles(0x40, 0x100, 0, d.bytes);
    const screen: Screen = .{ .name = "test", .what = "", .steps = &.{} };
    var run: Run = .{ .b = &b, .v = v, .screen = &screen };
    // Slot 3 (tile 1 of the block), mirrored across, palette 2, high; slot 2 (tile 0); slot 9,
    // blank since the clear.
    try run.map("test/map", &.{ 0x8000 | 0x4000 | 0x800 | 3, 2, 9 }, 3, 1, 0xC000 + 2 * 128 + 4, 128, "synthetic", .code);
    const a = try b.finish();
    const m = a.map("test/map").?;
    try std.testing.expectEqual(art.Place{ .layer = .plane_a, .x = 2, .y = 2 }, m.place.?);
    try std.testing.expectEqualStrings("test/art", m.sheets[0]);
    try std.testing.expectEqual(art.Cell{ .tile = 1, .palette = 2, .flip_x = true, .priority = true }, m.cells[0]);
    try std.testing.expectEqual(art.Cell{ .tile = 0 }, m.cells[1]);
    try std.testing.expect(m.cells[2].isEmpty());
    try std.testing.expectEqual(@as(u8, 2), a.sheet("test/art").?.tiles[1][0]);
    // A slot written with no block's whole tile is refused.
    v.bytes[9][0] = 0x10;
    v.written.set(9);
    try std.testing.expectError(error.UnresolvedTile, run.map("test/map2", &.{9}, 1, 1, 0xC000, 128, "synthetic", .code));
}

//! The screens' records (docs/content.md, `screens/NAME.json`): the original's tables of the
//! front-end screens, turned into texts in the game's font, sounds by name and frames by name.
//! - options: the sound test's names (0x1C684: 73 entries of 12 font codes, 11 shown) and the
//!   sound each plays (0x128A: a request byte an entry); the levels' names (0x12FE: 4 of 7
//!   codes); the controls' tables (0x1C9FC: 3 tables of 5 rows of 16 codes);
//! - high_scores: the table the reset unpacks (0x12842, an Enigma stream of base 0: 10 entries of
//!   12 bytes: the score in packed decimal, the round's word (packed decimal), a byte, the name's
//!   three codes, the level's word);
//! - select: the characters' poses, animations of their animation sets (Axel 0x49AE0, Adam
//!   0x53EFE, Blaze 0x5E90A; a set is a table of word offsets to its animations, an animation its
//!   count of frames, its durations' entry in the table 0x3A30, and a word per frame: the frame's
//!   record's offset from the words, bit 15 mirrored); each frame's copies, from its record's
//!   bytes 5 and 6 (0xB118): the entries of the players' art's transfers (0x1A160, 34 tiles, and
//!   0x1A53E, 32 tiles) the display routine makes when the frame comes (0x1A0D6), 0 for none;
//! - intro: the story outside Japan (0x3FB24: 28 lines of 22 codes of the italic font), the
//!   profiles (0x3F9F2: three pointers to texts of the profiles' font's codes, with 0 a blank, $FF
//!   a new line, $FD a pause and $FE the end; 0xCBE0: where each starts, a cell of a plane 128
//!   cells wide), and the script (0x3F680: the count of its entries, then their list: per entry
//!   a slot group, an object's type, the wait before the next entry and a life).
const std = @import("std");
const sorz = @import("sorz");
const screens = sorz.content.screens;
const rom_mod = @import("rom.zig");
const enigma = @import("enigma.zig");
const fonts = @import("fonts.zig");
const sound_names = @import("sound_names.zig");
const builder_mod = @import("builder.zig");
const Builder = builder_mod.Builder;

const u16be = rom_mod.u16be;
const s16be = rom_mod.s16be;
const u32be = rom_mod.u32be;

pub const sound_test_names = 0x1C684;
pub const sound_test_requests = 0x128A;
const sound_test_entries = 73;
const sound_test_size = 12;
const sound_test_shown = 11;
pub const level_names = 0x12FE;
const levels = 4;
const level_size = 7;
pub const control_tables = 0x1C9FC;
const controls = 3;
const control_rows = 5;
const control_columns = 16;
pub const high_score_table = 0x12842;
const high_scores = 10;
const high_score_size = 12;
pub const durations = 0x3A30;
pub const story = 0x3FB24;
const story_lines = 28;
const story_width = 22;
pub const profile_texts = 0x3F9F2;
pub const profile_places = 0xCBE0;
const profiles = 3;
pub const script = 0x3F680;

/// The intro's parts by the type of the object that the script's entry makes (sor-remaster's
/// frontend/intro_objects.zig, the handlers through the table at 0xB236).
const parts = [_]struct { kind: u8, part: []const u8 }{
    .{ .kind = 0x60, .part = "city_drift" },
    .{ .kind = 0x61, .part = "city_fade_in" },
    .{ .kind = 0x62, .part = "story_fade_out" },
    .{ .kind = 0x63, .part = "city_lights" },
    .{ .kind = 0x64, .part = "story_text" },
    .{ .kind = 0x65, .part = "story_rise" },
    .{ .kind = 0x69, .part = "profiles" },
    .{ .kind = 0x6B, .part = "pictures_out" },
    .{ .kind = 0x6C, .part = "city_again" },
    .{ .kind = 0x6D, .part = "city_rush" },
    .{ .kind = 0x6E, .part = "adam_arrives" },
    .{ .kind = 0x6F, .part = "blaze_arrives" },
    .{ .kind = 0x70, .part = "hero" },
    .{ .kind = 0x71, .part = "flash_adam" },
    .{ .kind = 0x72, .part = "flash_blaze" },
    .{ .kind = 0x73, .part = "flash_city" },
    .{ .kind = 0x74, .part = "heroes_step" },
    .{ .kind = 0x78, .part = "press_start" },
    .{ .kind = 0x7A, .part = "credit_sega" },
    .{ .kind = 0x7B, .part = "credit_music" },
    .{ .kind = 0x7C, .part = "credit_composer" },
    .{ .kind = 0x7E, .part = "title" },
};

/// A character's animation set and the numbers of its poses' animations in it.
const Character = struct {
    name: []const u8,
    set: u32,
    stand: u16,
    idle: u16,
    pose_a: u16,
    pose_b: u16,
    pose_c: u16,
    landing: ?u16 = null,
};

/// The select's poses (sor-remaster's frontend/select.zig, 0x1A12): Adam's animations 0, 4, 24,
/// 28 and 32; Axel's and Blaze's the mirrored ones (2, 6, 26, 30, 34), and Blaze's landing 14.
const characters = [_]Character{
    .{ .name = "adam", .set = 0x53EFE, .stand = 0, .idle = 4, .pose_a = 24, .pose_b = 28, .pose_c = 32 },
    .{ .name = "axel", .set = 0x49AE0, .stand = 2, .idle = 6, .pose_a = 26, .pose_b = 30, .pose_c = 34 },
    .{ .name = "blaze", .set = 0x5E90A, .stand = 2, .idle = 6, .pose_a = 26, .pose_b = 30, .pose_c = 34, .landing = 14 },
};

/// The text of `codes`, codes of the game's font (`fonts/main`), its last blanks left out.
fn text(arena: std.mem.Allocator, codes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (codes) |c| {
        const g = for (fonts.main_glyphs) |g| {
            if (g.tile == c) break g;
        } else return error.BadData;
        try out.appendSlice(arena, g.text);
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

fn soundOf(request: u8) ![]const u8 {
    for (sound_names.entries) |e| if (e.request == request) return e.name;
    return error.BadData;
}

/// Packed decimal digits as a number.
fn decimal(bytes: []const u8) !u32 {
    var v: u32 = 0;
    for (bytes) |b| {
        if (b >> 4 > 9 or b & 15 > 9) return error.BadData;
        v = v * 100 + (b >> 4) * 10 + (b & 15);
    }
    return v;
}

fn options(arena: std.mem.Allocator, rom: []const u8) !screens.Options {
    const entries = try arena.alloc(screens.SoundTestEntry, sound_test_entries);
    for (entries, 0..) |*e, i| {
        const at = sound_test_names + i * sound_test_size;
        e.* = .{ .name = try text(arena, rom[at..][0..sound_test_shown]), .sound = try soundOf(rom[sound_test_requests + i]) };
    }
    const names = try arena.alloc([]const u8, levels);
    for (names, 0..) |*n, i| n.* = try text(arena, rom[level_names + i * level_size ..][0..level_size]);
    const tables = try arena.alloc([]const []const u8, controls);
    for (tables, 0..) |*t, k| {
        const rows = try arena.alloc([]const u8, control_rows);
        for (rows, 0..) |*r, i| r.* = try text(arena, rom[control_tables + (k * control_rows + i) * control_columns ..][0..control_columns]);
        t.* = rows;
    }
    return .{
        .sound_test = entries,
        .levels = names,
        .controls = tables,
        .provenance = .{
            .sound_test = std.fmt.comptimePrint("ROM 0x{X:0>5}: the sound test's names, 12 font codes each, 11 shown (0x11D6); ROM 0x{X:0>4}: the request each plays (0x1218)", .{ sound_test_names, sound_test_requests }),
            .levels = std.fmt.comptimePrint("ROM 0x{X:0>4}: the levels' names, 7 font codes each (0x12E4; the same bytes at 0x12714 for the high scores)", .{level_names}),
            .controls = std.fmt.comptimePrint("ROM 0x{X:0>5}: the controls' tables, 5 rows of 16 font codes each (0x1370)", .{control_tables}),
        },
    };
}

fn highScores(arena: std.mem.Allocator, rom: []const u8) !screens.HighScores {
    const unpacked = try enigma.decompress(arena, rom, high_score_table, 0);
    if (unpacked.words.len < high_scores * high_score_size / 2) return error.BadData;
    var bytes: [high_scores * high_score_size]u8 = undefined;
    for (0..bytes.len / 2) |i| std.mem.writeInt(u16, bytes[2 * i ..][0..2], unpacked.words[i], .big);
    const out = try arena.alloc(screens.Score, high_scores);
    for (out, 0..) |*e, k| {
        const r = bytes[k * high_score_size ..][0..high_score_size];
        e.* = .{
            .score = try decimal(r[1..4]),
            .round = @intCast(try decimal(r[5..6])),
            .name = try text(arena, r[7..10]),
            .level = @intCast(std.mem.readInt(u16, r[10..12], .big)),
        };
        if (e.name.len != 3 or e.level >= levels) return error.BadData;
    }
    return .{ .first = out, .provenance = std.fmt.comptimePrint("ROM 0x{X:0>5}: an Enigma stream of base 0 that the reset unpacks into the high-score table (0x12832): 10 entries of 12 bytes", .{high_score_table}) };
}

/// The frames' names by the address of their record, from the art's origins.
fn frameNames(arena: std.mem.Allocator, b: *const Builder) !std.AutoHashMapUnmanaged(u32, []const u8) {
    var out: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    for (b.origins.keys(), b.origins.values()) |key, o| switch (o) {
        .frame => |f| try out.put(arena, f.address, Builder.originName(key)),
        else => {},
    };
    return out;
}

/// Animation `n` of the animation set at `set`, its frames by name.
fn animation(arena: std.mem.Allocator, rom: []const u8, names: *const std.AutoHashMapUnmanaged(u32, []const u8), set: u32, n: u16) ![]const screens.Step {
    const a: u32 = @intCast(@as(i64, set) + s16be(rom, set + n));
    const count = rom[a];
    const ticks: u32 = @intCast(@as(i64, durations) + s16be(rom, durations + 2 * @as(u32, rom[a + 1])));
    const out = try arena.alloc(screens.Step, count);
    for (out, 0..) |*s, k| {
        const w = u16be(rom, a + 2 + 2 * @as(u32, @intCast(k))) -% 2;
        const frame = a + 2 + (w & 0x7FFF);
        s.* = .{ .frame = names.get(frame) orelse return error.BadData, .ticks = rom[ticks + k], .mirrored = w & 0x8000 != 0, .copied = try copies(arena, rom, frame) };
        if (s.ticks == 0) return error.BadData;
    }
    return out;
}

/// The players' art's transfers: a frame's first part of 34 tiles, its second of 32.
const copy_tiles = [screens.max_copies]u16{ 34, 32 };

/// The tiles copied to show the frame whose record is at `frame`: a copy for each of its two
/// transfers' entries that is not 0. A frame without (bit 7 of its count of pieces) keeps the art
/// of the frame before: not one of the select's.
fn copies(arena: std.mem.Allocator, rom: []const u8, frame: u32) ![]const u16 {
    if (rom[frame] & 0x80 != 0) return error.BadData;
    var out: std.ArrayList(u16) = .empty;
    for (copy_tiles, 0..) |tiles, k| if (rom[frame + 5 + k] != 0) try out.append(arena, tiles);
    return out.items;
}

fn select(arena: std.mem.Allocator, rom: []const u8, b: *const Builder) !screens.Select {
    var names = try frameNames(arena, b);
    var out: screens.Select = undefined;
    inline for (characters) |c| {
        @field(out, c.name) = .{
            .provenance = std.fmt.comptimePrint("the animations {d}, {d}, {d}, {d}, {d}{s} of the animation set at ROM 0x{X:0>5}, their ticks from the table 0x{X:0>4} (the character select's portraits, 0x1A12)", .{
                c.stand,                                                            c.idle, c.pose_a,  c.pose_b, c.pose_c,
                if (c.landing) |l| std.fmt.comptimePrint(" and {d}", .{l}) else "", c.set,  durations,
            }),
            .stand = try animation(arena, rom, &names, c.set, c.stand),
            .idle = try animation(arena, rom, &names, c.set, c.idle),
            .pose_a = try animation(arena, rom, &names, c.set, c.pose_a),
            .pose_b = try animation(arena, rom, &names, c.set, c.pose_b),
            .pose_c = try animation(arena, rom, &names, c.set, c.pose_c),
            .landing = if (c.landing) |l| try animation(arena, rom, &names, c.set, l) else &.{},
        };
    }
    return out;
}

/// The text of the profiles' codes from `a` to their end ($FE): `_` a blank, `/` a new line, `|`
/// a pause.
fn profileText(arena: std.mem.Allocator, rom: []const u8, a: u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at = a;
    while (true) : (at += 1) {
        if (at >= rom.len or out.items.len > 1024) return error.BadData;
        const c = rom[at];
        switch (c) {
            0xFE => break,
            0xFF => try out.append(arena, '/'),
            0xFD => try out.append(arena, '|'),
            0 => try out.append(arena, '_'),
            else => {
                const g = for (fonts.intro_glyphs) |g| {
                    if (g.tile == c) break g;
                } else return error.BadData;
                try out.appendSlice(arena, g.text);
            },
        }
    }
    return out.items;
}

fn intro(arena: std.mem.Allocator, rom: []const u8) !screens.Intro {
    const lines = try arena.alloc([]const u8, story_lines);
    for (lines, 0..) |*l, k| {
        var out: std.ArrayList(u8) = .empty;
        for (rom[story + k * story_width ..][0..story_width]) |c| {
            const g = for (fonts.main_glyphs) |g| {
                if (g.tile == c) break g;
            } else return error.BadData;
            try out.appendSlice(arena, g.text);
        }
        l.* = out.items;
    }
    const ps = try arena.alloc(screens.Profile, profiles);
    for (ps, 0..) |*p, i| {
        const at = u16be(rom, profile_places + 2 * @as(u32, @intCast(i)));
        // A plane of 128 cells a row: plane A's cells from $C000, plane B's from $E000.
        const plane_b = at >= 0xE000;
        const offset = at - @as(u16, if (plane_b) 0xE000 else 0xC000);
        p.* = .{
            .text = try profileText(arena, rom, u32be(rom, profile_texts + 4 * @as(u32, @intCast(i)))),
            .plane = if (plane_b) .plane_b else .plane_a,
            .x = (offset % 256) / 2,
            .y = offset / 256,
        };
    }
    // The entries before the last, which is the script's end (its count is the last's index).
    const count: u32 = rom[script];
    const list = u32be(rom, script + 4);
    const entries = try arena.alloc(screens.ScriptEntry, count);
    for (entries, 0..) |*e, i| {
        const r = list + 8 * @as(u32, @intCast(i));
        const kind = u16be(rom, r + 2);
        const part = for (parts) |p| {
            if (p.kind == kind) break p.part;
        } else return error.BadData;
        e.* = .{ .part = part, .wait = u16be(rom, r + 4), .life = u16be(rom, r + 6) };
    }
    return .{
        .story = lines,
        .profiles = ps,
        .script = entries,
        .provenance = .{
            .story = std.fmt.comptimePrint("ROM 0x{X:0>5}: the story outside Japan, 28 lines of 22 codes of the italic font (0xCBE6)", .{story}),
            .profiles = std.fmt.comptimePrint("ROM 0x{X:0>5}: the profiles' texts in the profiles' font's codes (0 a blank, $FF a new line, $FD a pause, $FE the end), Adam's, Blaze's, Axel's; ROM 0x{X:0>4}: where each starts (0xCD66)", .{ profile_texts, profile_places }),
            .script = std.fmt.comptimePrint("ROM 0x{X:0>5}: the intro's script (0xB6DE): each entry an object's type, here its part, the wait before the next and a life; its last entry is its end", .{script}),
        },
    };
}

// --- The ending ---------------------------------------------------------------------------------

/// The ending's parts by the type of the object that its script's entry makes (sor-remaster's
/// frontend/intro_objects.zig, the handlers $82 to $8D).
const ending_parts = [_]struct { kind: u8, part: []const u8 }{
    .{ .kind = 0x83, .part = "pictures" },
    .{ .kind = 0x84, .part = "texts" },
    .{ .kind = 0x85, .part = "dissolve_in" },
    .{ .kind = 0x86, .part = "dissolve_out" },
    .{ .kind = 0x87, .part = "cloud_1" },
    .{ .kind = 0x89, .part = "cloud_2" },
    .{ .kind = 0x8A, .part = "sun" },
    .{ .kind = 0x8B, .part = "scene" },
    .{ .kind = 0x8C, .part = "glow" },
    .{ .kind = 0x8D, .part = "scroll" },
};

/// The ending's texts: their places and paragraphs (0xC100: a VRAM address and a word each),
/// their codes (word offsets at 0x3F7D0), how long each stays typed (0xBFF2).
const ending_places = 0xC100;
const ending_texts = 0x3F7D0;
const ending_stays = 0xBFF2;
const ending_text_count = 5;

/// The immediate of the instruction at `at` (its word, or its long), when its opcode is `op`.
fn imm(rom: []const u8, at: u32, op: u16) !u32 {
    if (u16be(rom, at) != op) return error.BadData;
    return switch (op) {
        0x217C, 0x223C => u32be(rom, at + 2),
        0x117C => rom[at + 3],
        else => u16be(rom, at + 2),
    };
}

/// The palette line of a tile word.
fn paletteOf(word: u32) u2 {
    return @intCast(word >> 13 & 3);
}

/// A cell's VRAM address as a plane's cell (planes 64 cells wide: A at $C000, B at $E000).
fn planeCell(address: u16) !struct { plane: sorz.content.art.Layer, x: u16, y: u16 } {
    const plane: sorz.content.art.Layer = if (address >= 0xE000) .plane_b else if (address >= 0xC000) .plane_a else return error.BadData;
    const off = address - @as(u16, if (plane == .plane_b) 0xE000 else 0xC000);
    return .{ .plane = plane, .x = off % 128 / 2, .y = off / 128 };
}

fn ending(arena: std.mem.Allocator, rom: []const u8) !screens.Ending {
    // The script: entry 1 of 0x3F680's.
    const at = script + 8;
    const count: u32 = rom[at];
    const list = u32be(rom, at + 4);
    const entries = try arena.alloc(screens.ScriptEntry, count);
    for (entries, 0..) |*e, i| {
        const r = list + 8 * @as(u32, @intCast(i));
        const kind = u16be(rom, r + 2);
        const part = for (ending_parts) |p| {
            if (p.kind == kind) break p.part;
        } else return error.BadData;
        e.* = .{ .part = part, .wait = u16be(rom, r + 4), .life = u16be(rom, r + 6) };
    }
    // The texts: each from its codes to its last paragraph's end ($FC), a row a paragraph.
    const texts = try arena.alloc(screens.EndingText, ending_text_count);
    for (texts, 0..) |*t, n| {
        const place = try planeCell(u16be(rom, ending_places + 4 * @as(u32, @intCast(n))));
        const paragraphs = u16be(rom, ending_places + 4 * @as(u32, @intCast(n)) + 2);
        var a: u32 = @intCast(@as(i32, ending_texts) + s16be(rom, ending_texts + 2 * @as(u32, @intCast(n))));
        const rows = try arena.alloc([]const u8, paragraphs);
        for (rows) |*row| {
            var line: std.ArrayList(u8) = .empty;
            while (rom[a] != 0xFC) : (a += 1) {
                const c = rom[a];
                if (c == 0) {
                    try line.append(arena, ' ');
                    continue;
                }
                if (c >= 0x80) return error.BadData;
                const g = for (fonts.main_glyphs) |g| {
                    if (g.tile == c) break g;
                } else return error.BadData;
                try line.appendSlice(arena, g.text);
            }
            a += 1;
            row.* = line.items;
        }
        t.* = .{ .plane = place.plane, .x = place.x, .y = place.y, .rows = rows, .stays = u16be(rom, ending_stays + 2 * @as(u32, @intCast(n))) };
    }
    // The pictures' moments (type $83, 0xC17C): the counts its states set.
    const waits = [_]u32{ 0xC1AC, 0xC1CC, 0xC20A, 0xC236, 0xC25E, 0xC27E };
    var after: [waits.len]u16 = undefined;
    for (&after, waits) |*w, place| w.* = @intCast(try imm(rom, place, 0x317C));
    const lc = screens.LineColours;
    const moments = try arena.dupe(screens.EndingMoment, &.{
        .{ .pictures = 1, .fade_in = &.{lc{ .line = 1, .colours = "ending/colours_00" }}, .fade_out = &.{}, .after = after[0] },
        .{ .pictures = 0, .fade_in = &.{}, .fade_out = &.{1}, .after = after[1] },
        .{ .pictures = 1, .fade_in = &.{ lc{ .line = 1, .colours = "ending/colours_01" }, lc{ .line = 2, .colours = "ending/colours_02" } }, .fade_out = &.{}, .after = after[2] },
        .{ .pictures = 0, .fade_in = &.{}, .fade_out = &.{ 1, 2 }, .after = after[3] },
        .{ .pictures = 1, .fade_in = &.{lc{ .line = 1, .colours = "ending/colours_03" }}, .fade_out = &.{}, .after = after[4] },
        .{ .pictures = 0, .fade_in = &.{}, .fade_out = &.{1}, .after = after[5] },
        .{ .pictures = 5, .fade_in = &.{ lc{ .line = 1, .colours = "ending/colours_04" }, lc{ .line = 2, .colours = "ending/colours_05" }, lc{ .line = 3, .colours = "ending/colours_06" }, lc{ .line = 0, .colours = "ending/colours_22" } }, .fade_out = &.{}, .after = 0 },
    });
    // The scene's steps (type $8B, 0xBD10): the counts its states set.
    const sc = [_]u32{ 0xBD32, 0xBD48, 0xBD64, 0xBD7C, 0xBD94, 0xBDE2 };
    var ticks: [sc.len]u16 = undefined;
    for (&ticks, sc) |*w, place| w.* = @intCast(try imm(rom, place, 0x317C));
    const scene = try arena.dupe(screens.SceneStep, &.{
        .{ .palette = false, .sky = true, .clouds_off = false, .star = false, .after = ticks[0], .until_sun = false },
        .{ .palette = true, .sky = true, .clouds_off = false, .star = false, .after = ticks[1], .until_sun = false },
        .{ .palette = true, .sky = false, .clouds_off = false, .star = false, .after = ticks[2], .until_sun = false },
        .{ .palette = false, .sky = true, .clouds_off = false, .star = false, .after = ticks[3], .until_sun = false },
        .{ .palette = true, .sky = true, .clouds_off = false, .star = false, .after = ticks[4], .until_sun = false },
        .{ .palette = true, .sky = false, .clouds_off = false, .star = false, .after = 0, .until_sun = true },
        .{ .palette = true, .sky = false, .clouds_off = true, .star = false, .after = ticks[5], .until_sun = false },
        .{ .palette = true, .sky = false, .clouds_off = false, .star = true, .after = 0, .until_sun = false },
    });
    // The star's looks and ticks (0xBEA6: five pairs of a tile, $2B on, and its ticks).
    const blink = 0xBEA6;
    const star = try arena.alloc(screens.Blink, 5);
    for (star, 0..) |*b, k| {
        const tile = u16be(rom, blink + 4 * @as(u32, @intCast(k)));
        const names = [_][]const u8{ "ending/star_1", "ending/star_2", "ending/star_3" };
        if (tile < 0x2B or tile > 0x2D) return error.BadData;
        b.* = .{ .map = names[tile - 0x2B], .ticks = u16be(rom, blink + 4 * @as(u32, @intCast(k)) + 2) };
    }
    const sx = struct {
        fn s16(v: u32) i16 {
            return @bitCast(@as(u16, @truncate(v)));
        }
    };
    const scroll = try imm(rom, 0xBB4A, 0x223C);
    return .{
        .provenance = std.fmt.comptimePrint("the ending (0xB3C6, its script ROM 0x{X:0>5}'s entry 1, run by 0xB6DE): its texts (type $84, 0xBF76: ROM 0x{X:0>5}'s places and paragraphs, 0x{X:0>5}'s codes, 0x{X:0>5}'s ticks typed), its pictures (type $83, 0xC17C) and their line fades (type $82, 0xC114, made by 0xC31E), its dissolves (types $85 and $86, 0xBEBA, 0xBF2A), its clouds (types $87 and $89, 0xBBEE, 0xBC5C, 0xBC2E), its sun (type $8A, 0xBCA2), its scene (type $8B, 0xBD10, its sky 0xBE44, its star 0xBE74), its glow (type $8C, 0xBB94), the car's scroll (type $8D, 0xBB18); START at its end (0x9214)", .{ script, ending_places, ending_texts, ending_stays }),
        .script = entries,
        .texts = texts,
        .pictures = try arena.dupe([]const u8, &.{ "ending/picture_1", "ending/picture_2", "ending/picture_3", "ending/picture_4", "ending/sky", "ending/car", "ending/mask_left", "ending/mask_right" }),
        .moments = moments,
        .scene = scene,
        .scene_colours = try arena.dupe([]const u8, &.{ "ending/colours_16", "ending/colours_17", "ending/colours_18", "ending/colours_19", "ending/colours_20", "ending/colours_21" }),
        .sky = "ending/sky",
        .clouds = try arena.dupe(screens.Sprite, &.{
            .{ .frame = "ending/sprite_02", .x = sx.s16(try imm(rom, 0xBC10, 0x317C)), .y = sx.s16(try imm(rom, 0xBC0A, 0x317C)), .speed = @bitCast(try imm(rom, 0xBC16, 0x217C)), .palette = paletteOf(try imm(rom, 0xBC24, 0x323C)), .priority = try imm(rom, 0xBC24, 0x323C) & 0x8000 != 0 },
            .{ .frame = "ending/sprite_03", .x = sx.s16(try imm(rom, 0xBC7E, 0x317C)), .y = sx.s16(try imm(rom, 0xBC78, 0x317C)), .speed = @bitCast(try imm(rom, 0xBC84, 0x217C)), .palette = paletteOf(try imm(rom, 0xBC92, 0x323C)), .priority = try imm(rom, 0xBC92, 0x323C) & 0x8000 != 0 },
        }),
        .sun = .{ .frame = "ending/sprite_00", .x = sx.s16(try imm(rom, 0xBCD4, 0x317C)), .y = sx.s16(try imm(rom, 0xBCCE, 0x317C)), .speed = @bitCast(try imm(rom, 0xBCDA, 0x217C)), .palette = paletteOf(try imm(rom, 0xBCE8, 0x323C)), .priority = try imm(rom, 0xBCE8, 0x323C) & 0x8000 != 0 },
        .glow = .{ .frame = "ending/sprite_01", .x = sx.s16(try imm(rom, 0xBBB6, 0x317C)), .y = sx.s16(try imm(rom, 0xBBB0, 0x317C)), .speed = 0, .palette = paletteOf(try imm(rom, 0xBBC2, 0x323C)), .priority = try imm(rom, 0xBBC2, 0x323C) & 0x8000 != 0 },
        .star = star,
        .numbers = .{
            .type_period = @intCast(try imm(rom, 0xBFB4, 0x317C)),
            .erase_gap = @intCast(try imm(rom, 0xC048, 0x317C)),
            .dissolve_period = @intCast(try imm(rom, 0xBEDE, 0x317C)),
            .dissolve_step = @intCast(try imm(rom, 0xBF62, 0x0640)),
            .dissolve_from = @intCast(try imm(rom, 0xBED6, 0x217C) >> 16),
            .dissolve_span = @intCast(try imm(rom, 0xBF66, 0x0C40)),
            .fade_period = @intCast(try imm(rom, 0xC142, 0x117C)),
            .fade_life = @intCast(try imm(rom, 0xC32E, 0x337C)),
            .black_line = 0,
            .black_before = 2,
            .cloud_turn = sx.s16(try imm(rom, 0xBC36, 0x0C68)),
            .cloud_back = sx.s16(try imm(rom, 0xBC40, 0x317C)),
            .cloud_height = sx.s16(try imm(rom, 0xBC50, 0x317C)),
            .cloud_spread = @intCast(try imm(rom, 0xBC4C, 0x0240)),
            .sun_until = sx.s16(try imm(rom, 0xBCF0, 0x0C68)),
            .glow_line = 3,
            .glow_colour = 13,
            .glow_period = @intCast(try imm(rom, 0xBBCE, 0x117C)),
            .glow_colours = "ending/glow",
            .scroll_first = @intCast(scroll & 0xFFFF),
            .scroll_lines = @intCast((scroll >> 16) + 1),
            .scroll_ticks = @intCast(try imm(rom, 0xBB34, 0x317C)),
            .skip_from = @intCast(try imm(rom, 0x9214, 0x0C38) & 0xFF),
            .skip_within = @intCast(try imm(rom, 0x921C, 0x0C78)),
        },
    };
}

/// The screens' records of `rom`; the select's frames are named by `b`'s origins.
pub fn extract(arena: std.mem.Allocator, rom: []const u8, b: *const Builder) !screens.Screens {
    return .{
        .options = try options(arena, rom),
        .high_scores = try highScores(arena, rom),
        .select = try select(arena, rom, b),
        .intro = try intro(arena, rom),
        .ending = try ending(arena, rom),
    };
}

test "texts are the font's codes, sounds the requests' names, scores packed decimal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("A-JUMP", try text(arena, &.{ 1, 38, 10, 21, 13, 16, 0, 0 }));
    try std.testing.expectEqualStrings("menu move", try soundOf(0xB9));
    try std.testing.expectEqual(@as(u32, 105000), try decimal(&.{ 0x10, 0x50, 0x00 }));
    try std.testing.expectError(error.BadData, decimal(&.{0x1A}));
    try std.testing.expectError(error.BadData, text(arena, &.{200}));
}

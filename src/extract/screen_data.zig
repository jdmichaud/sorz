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
//!   record's offset from the words, bit 15 mirrored);
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
        s.* = .{ .frame = names.get(frame) orelse return error.BadData, .ticks = rom[ticks + k], .mirrored = w & 0x8000 != 0 };
        if (s.ticks == 0) return error.BadData;
    }
    return out;
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

/// The screens' records of `rom`; the select's frames are named by `b`'s origins.
pub fn extract(arena: std.mem.Allocator, rom: []const u8, b: *const Builder) !screens.Screens {
    return .{
        .options = try options(arena, rom),
        .high_scores = try highScores(arena, rom),
        .select = try select(arena, rom, b),
        .intro = try intro(arena, rom),
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

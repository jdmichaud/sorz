//! The game's content as the scenes use it (DESIGN.md P2): the content tree read from the asset
//! source when the game starts (the art and the sound, docs/content.md and docs/content-sound.md),
//! and each scene's assets and sounds found in it by name, once. A scene declares what it needs as
//! a struct whose fields are the assets (a map, a palette, a frame, a font...) or the sounds, with
//! their names in its `names` declaration; `find` fills it, and a name the content lacks refuses
//! the content at the start, with the name, rather than in the middle of a game.
const std = @import("std");
const platform = @import("platform.zig");
const content = @import("content/root.zig");
const json = @import("formats/json.zig");
const audio = @import("audio/root.zig");

const art = content.art;
const records = content.screens;

/// A sound of the content, as the sequencer plays it.
pub const Sound = audio.sound.Id;

/// The sounds of the options' sound test (`screens/options`), each entry's by its name.
pub const SoundTest = struct {
    pub const max = 128;
    ids: [max]Sound = undefined,
    len: u8 = 0,
};

/// The intro's script (`screens/intro`), its parts by their names in `Part`, an enum of the
/// scene's: a name the scene does not have refuses the content.
pub fn Script(comptime Part: type) type {
    return struct {
        pub const max = 64;
        pub const is_script = true;
        pub const Entry = struct { part: Part, wait: u16, life: u16 };
        entries: [max]Entry = undefined,
        len: u8 = 0,
    };
}

/// A font with the sheet its glyphs are tiles of: what a text is written with.
pub const Text = struct {
    font: *const art.Font,
    sheet: *const art.TileSheet,
};

/// The content tree in memory, owned by its arena.
pub const Content = struct {
    arena: std.heap.ArenaAllocator,
    tree: content.Content,
    sounds: audio.content.Content,

    pub fn destroy(self: *Content) void {
        var arena = self.arena;
        arena.deinit();
    }
};

pub const LoadError = error{ OutOfMemory, BadContent };

/// Whether `assets` holds a content tree: a manifest of the tree's format at its root. A source
/// without one (the repository's checks give the game none, or files of their own) has no
/// content, and the game shows its test pattern.
pub fn hasTree(gpa: std.mem.Allocator, assets: platform.AssetSource) bool {
    var owned = assets.readAll(content.tree.manifest_file, 1 << 16) catch return false;
    defer owned.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), owned.bytes, .{}) catch return false;
    if (parsed != .object) return false;
    const format = parsed.object.get("format") orelse return false;
    return format == .string and std.mem.eql(u8, format.string, content.tree.format_name);
}

/// Reads the whole content tree of `assets`: its art and its sound, every file checked. A refusal
/// names the file and the field in `diag`.
pub fn load(gpa: std.mem.Allocator, assets: platform.AssetSource, diag: *json.Diagnostic) LoadError!*Content {
    const self = try gpa.create(Content);
    self.* = .{ .arena = .init(gpa), .tree = undefined, .sounds = undefined };
    errdefer {
        self.destroy();
        gpa.destroy(self);
    }
    const arena = self.arena.allocator();
    self.tree = content.load(arena, assets, diag) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadAsset => error.BadContent,
    };
    self.sounds = audio.files.loadAssets(arena, assets, diag) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadContent,
    };
    return self;
}

/// Fills `T`, a struct of assets and sounds, from the content by the names of `T.names`; a name
/// the content lacks is written in `diag` and refuses the content.
pub fn find(comptime T: type, c: *const Content, diag: *json.Diagnostic) LoadError!T {
    var out: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |field, F| {
        const name: []const u8 = @field(T.names, field);
        @field(out, field) = try findOne(F, c, name, diag);
    }
    return out;
}

fn findOne(comptime F: type, c: *const Content, name: []const u8, diag: *json.Diagnostic) LoadError!F {
    const a = &c.tree.art;
    const found: ?F = switch (F) {
        *const art.TileMap => a.map(name),
        *const art.Palette => a.palette(name),
        *const art.Frame => a.frame(name),
        *const art.TileSheet => a.sheet(name),
        *const art.Cycle => a.cycle(name),
        *const art.PaletteSteps => a.steps(name),
        // The screens' records, by their files' names (`screens/options`).
        *const records.Options => if (std.mem.eql(u8, name, "screens/options")) if (c.tree.screens.options) |*r| r else null else null,
        *const records.HighScores => if (std.mem.eql(u8, name, "screens/high_scores")) if (c.tree.screens.high_scores) |*r| r else null else null,
        *const records.Select => if (std.mem.eql(u8, name, "screens/select")) if (c.tree.screens.select) |*r| r else null else null,
        *const records.Intro => if (std.mem.eql(u8, name, "screens/intro")) if (c.tree.screens.intro) |*r| r else null else null,
        Text => if (a.font(name)) |f| if (a.sheet(f.sheet)) |s| Text{ .font = f, .sheet = s } else null else null,
        Sound => c.sounds.find(name),
        SoundTest => blk: {
            const o = if (c.tree.screens.options) |*r| r else break :blk null;
            if (o.sound_test.len > SoundTest.max) return refuse(diag, name, "more sound test entries than the game shows");
            var t: SoundTest = .{ .len = @intCast(o.sound_test.len) };
            for (o.sound_test, 0..) |e, i| t.ids[i] = c.sounds.find(e.sound) orelse return refuse(diag, e.sound, "a sound test entry's sound, not in sound/sounds.json");
            break :blk t;
        },
        else => if (comptime @typeInfo(F) == .@"struct" and @hasDecl(F, "is_script")) blk: {
            const it = if (c.tree.screens.intro) |*r| r else break :blk null;
            if (it.script.len > F.max) return refuse(diag, name, "a script longer than the game takes");
            var s: F = .{ .len = @intCast(it.script.len) };
            for (it.script, 0..) |e, i| {
                const part = std.meta.stringToEnum(@FieldType(F.Entry, "part"), e.part) orelse return refuse(diag, e.part, "not a part of the intro");
                s.entries[i] = .{ .part = part, .wait = e.wait, .life = e.life };
            }
            break :blk s;
        } else switch (@typeInfo(F)) {
            // An array of assets: the names of `name` with `_N` added, N from 0 (`intro/picture`
            // gives `intro/picture_00`...). Its length is the type's.
            .array => |arr| blk: {
                var items: F = undefined;
                for (&items, 0..) |*item, i| {
                    var buf: [96]u8 = undefined;
                    const each = std.fmt.bufPrint(&buf, "{s}_{d:0>2}", .{ name, i }) catch return refuse(diag, name, "a name too long");
                    item.* = try findOne(arr.child, c, each, diag);
                }
                break :blk items;
            },
            else => @compileError("not an asset of the content: " ++ @typeName(F)),
        },
    };
    return found orelse refuse(diag, name, switch (F) {
        Sound => "no sound of this name in sound/sounds.json",
        else => "no asset of this name and kind in the content",
    });
}

fn refuse(diag: *json.Diagnostic, name: []const u8, why: []const u8) LoadError {
    diag.* = .{ .file = "the scenes' content", .message = why };
    diag.setPlace("{s}", .{name});
    return error.BadContent;
}

const testing = std.testing;

test "a scene's assets and sounds are found by name, and a missing one refuses the content" {
    const tiles = [_]art.Tile{@splat(1)};
    const sheets = [_]art.TileSheet{.{ .name = "main", .file = "main.png", .tiles = &tiles }};
    const glyphs = [_]art.Glyph{.{ .text = "A", .tile = 0 }};
    const fonts = [_]art.Font{.{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs }};
    const palettes = [_]art.Palette{ .{ .name = "colours" }, .{ .name = "step_00" }, .{ .name = "step_01" } };
    const sets = [_]art.ArtSet{ .{ .name = "fonts", .sheets = &sheets, .fonts = &fonts }, .{ .name = "menu", .palettes = &palettes } };
    const sounds = [_]audio.content.Sound{.{ .name = "menu move", .priority = 111, .plays = .stop }};
    var c: Content = .{
        .arena = .init(testing.allocator),
        .tree = .{ .manifest = .{ .extractor = "", .rom_sha256 = "", .rom_size = 0, .art = &.{} }, .art = .{ .sets = &sets } },
        .sounds = .{ .driver = .{}, .sounds = &sounds },
    };
    defer c.destroy();
    const Assets = struct {
        text: Text,
        colours: *const art.Palette,
        steps: [2]*const art.Palette,
        move: Sound,
        pub const names = .{ .text = "fonts/main", .colours = "menu/colours", .steps = "menu/step", .move = "menu move" };
    };
    var diag: json.Diagnostic = .{};
    const a = try find(Assets, &c, &diag);
    try testing.expectEqualStrings("main", a.text.sheet.name);
    try testing.expectEqualStrings("step_01", a.steps[1].name);
    try testing.expectEqual(@as(Sound, 0), a.move);
    const Missing = struct {
        colours: *const art.Palette,
        pub const names = .{ .colours = "menu/other" };
    };
    try testing.expectError(error.BadContent, find(Missing, &c, &diag));
    try testing.expectEqualStrings("menu/other", diag.fieldName());
}

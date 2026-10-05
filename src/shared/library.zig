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
const Character = @import("setup.zig").Character;
const world = @import("world/root.zig");

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

/// An animation of the character select's poses, its frames found in the art.
pub const Animation = struct {
    pub const max = 16;
    pub const Step = struct {
        frame: *const art.Frame,
        ticks: u8,
        mirrored: bool,
        /// The tiles copied to show it, a copy each (0: none).
        copied: [records.max_copies]u16,
    };
    steps: [max]Step = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Animation) []const Step {
        return self.steps[0..self.len];
    }
};

/// The character select's poses (`screens/select`): each character's animation of each pose.
pub const Poses = struct {
    pub const Pose = enum { stand, idle, pose_a, pose_b, pose_c, landing };
    characters: std.EnumArray(Character, std.EnumArray(Pose, Animation)) = .initFill(.initFill(.{})),

    pub fn of(self: *const Poses, who: Character, pose: Pose) *const Animation {
        return self.characters.getPtrConst(who).getPtrConst(pose);
    }
};

/// A font with the sheet its glyphs are tiles of: what a text is written with.
pub const Text = struct {
    font: *const art.Font,
    sheet: *const art.TileSheet,
};

/// The sound content: the sounds by name (`find`), for a scene that plays those its world asks
/// for by name.
pub const Sounds = audio.content.Content;

/// A round of the content and what its record names (docs/content.md): its script, its art set's
/// planes (`plane_a`, `plane_b`), colours (`colours`) and cycles, its music; and its number on the
/// banner (play's record's `banner.numbers`, by the round).
pub const RoundAssets = struct {
    script: *const content.round.Round,
    set: *const art.ArtSet,
    plane_a: *const art.TileMap,
    plane_b: *const art.TileMap,
    colours: *const art.Palette,
    music: Sound,
    number: *const art.Frame,
    /// The boss's colours, when the round has a boss.
    boss_colours: ?*const art.Palette = null,
    /// The colours of the boss's kind its reserves bring as an enemy (`ReserveBoss.palette`; one
    /// at most), when they bring one.
    reserve_boss_colours: ?*const art.Palette = null,
    /// Its animation's steps (the script's `animation`), their maps and colours found.
    animation: [Rounds.most_steps]AnimationStep = undefined,
    animation_steps: u8 = 0,

    pub const AnimationStep = struct { map: *const art.TileMap, colours: *const art.Palette };

    /// Its animation's steps.
    pub fn steps(self: *const RoundAssets) []const AnimationStep {
        return self.animation[0..self.animation_steps];
    }
};

/// The enemies' colours by number (play's record, `screens/round`'s `enemy_colours`), their
/// palettes found: a kind's for the enemies' first and second lines, or its own; the lines they
/// show on (the first's, the second's, the other's); the police car's.
pub const EnemyColours = struct {
    pub const most = 16;
    pub const Set = struct { first: ?*const art.Palette = null, second: ?*const art.Palette = null, own: ?*const art.Palette = null };
    sets: [most]Set = @splat(.{}),
    len: u8 = 0,
    lines: [3]u2 = .{ 0, 0, 0 },
    police: *const art.Palette,

    /// Number `n`'s, if there is one.
    pub fn of(self: *const EnemyColours, n: u8) ?*const Set {
        return if (n < self.len) &self.sets[n] else null;
    }

    /// Which of them (by number, a bit each) are a kind's own.
    pub fn ownBits(self: *const EnemyColours) u16 {
        var bits: u16 = 0;
        for (self.sets[0..self.len], 0..) |set, n| {
            if (set.own != null) bits |= @as(u16, 1) << @intCast(n);
        }
        return bits;
    }
};

/// The rounds of the content (`rounds`), by their numbers from 1; round 1 is needed.
pub const Rounds = struct {
    pub const most = 8;
    /// The most palette cycles a round's art set may have (the round scene keeps each one's
    /// place).
    pub const most_cycles = 8;
    /// The most steps of a round's animation.
    pub const most_steps = 8;
    items: [most]?RoundAssets = @splat(null),

    /// Round `number`, if the content has it.
    pub fn of(self: *const Rounds, number: u8) ?*const RoundAssets {
        if (number == 0 or number > most) return null;
        return if (self.items[number - 1]) |*r| r else null;
    }
};

/// Each round of the content, its record's names found.
fn findRounds(c: *const Content, diag: *json.Diagnostic) LoadError!Rounds {
    const a = &c.tree.art;
    var out: Rounds = .{};
    const play = if (c.tree.screens.round) |*r| r else return refuse(diag, "screens/round", "the rounds need play's record (their banners' numbers)");
    for (c.tree.rounds) |*r| {
        var buf: [16]u8 = undefined;
        const name = content.round.nameOf(&buf, r.number);
        if (r.number == 0 or r.number > Rounds.most) return refuse(diag, name, "a round the game does not have (1 to 8)");
        if (out.items[r.number - 1] != null) return refuse(diag, name, "a round twice");
        const set = a.set(r.art) orelse return refuse(diag, r.art, "a round's art set, not in the art");
        if (set.cycles.len > Rounds.most_cycles) return refuse(diag, r.art, "more palette cycles than a round takes");
        if (r.number > play.banner.numbers.len) return refuse(diag, name, "a round with no number on the banner (screens/round's banner.numbers)");
        var bufs: [3][64]u8 = undefined;
        const parts = [3][]const u8{ "plane_a", "plane_b", "colours" };
        var full: [3][]const u8 = undefined;
        for (&full, &bufs, parts) |*f, *b, part| f.* = std.fmt.bufPrint(b, "{s}/{s}", .{ r.art, part }) catch return refuse(diag, r.art, "an art set's name too long");
        const number = play.banner.numbers[r.number - 1];
        var round_assets: RoundAssets = .{
            .script = r,
            .set = set,
            .plane_a = a.map(full[0]) orelse return refuse(diag, full[0], "a round's plane, not in its art set"),
            .plane_b = a.map(full[1]) orelse return refuse(diag, full[1], "a round's plane, not in its art set"),
            .colours = a.palette(full[2]) orelse return refuse(diag, full[2], "a round's colours, not in its art set"),
            .music = c.sounds.find(r.music) orelse return refuse(diag, r.music, "a round's music, not in sound/sounds.json"),
            .number = a.frame(number) orelse return refuse(diag, number, "a banner's number, not in the art"),
            .boss_colours = if (r.boss) |b| if (b.colours) |boss| a.palette(boss) orelse return refuse(diag, boss, "a boss's colours, not in the art") else null else null,
        };
        for (r.sections) |*s| for (s.reserve) |*rec| try reserveBossColours(a, rec, &round_assets, diag);
        if (r.boss) |*b| for (b.reserve) |*rec| try reserveBossColours(a, rec, &round_assets, diag);
        if (r.animation) |an| {
            if (an.steps.len > Rounds.most_steps) return refuse(diag, name, "more animation steps than a round takes");
            for (an.steps, round_assets.animation[0..an.steps.len]) |st, *o| {
                var b: [2][64]u8 = undefined;
                const map = std.fmt.bufPrint(&b[0], "{s}/{s}", .{ r.art, st.map }) catch return refuse(diag, st.map, "an art set's name too long");
                const colours = std.fmt.bufPrint(&b[1], "{s}/{s}", .{ r.art, st.colours }) catch return refuse(diag, st.colours, "an art set's name too long");
                o.* = .{
                    .map = a.map(map) orelse return refuse(diag, map, "an animation's map, not in the round's art set"),
                    .colours = a.palette(colours) orelse return refuse(diag, colours, "an animation's colours, not in the round's art set"),
                };
                if (o.map.place == null) return refuse(diag, map, "an animation's map with no place on a plane");
            }
            round_assets.animation_steps = @intCast(an.steps.len);
        }
        out.items[r.number - 1] = round_assets;
    }
    if (out.items[0] == null) return refuse(diag, "rounds/round1", "no round 1");
    return out;
}

/// A reserve's record's boss's colours (`ReserveBoss.palette`) found, the round's one.
fn reserveBossColours(a: *const art.Art, rec: *const content.round.Spawn, out: *RoundAssets, diag: *json.Diagnostic) LoadError!void {
    const b = rec.reserve_boss orelse return;
    const pal = a.palette(b.palette) orelse return refuse(diag, b.palette, "a reserve's boss's colours, not in the art");
    if (out.reserve_boss_colours) |other| if (other != pal) return refuse(diag, b.palette, "a round's reserves with two bosses' colours");
    out.reserve_boss_colours = pal;
}

/// The content tree in memory, owned by its arena.
pub const Content = struct {
    arena: std.heap.ArenaAllocator,
    tree: content.Content,
    sounds: audio.content.Content,
    /// The kinds of entity, bound to their art and behaviours (world/kinds.zig).
    kinds: world.Kinds = .{},

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
        // The refusal's file and message may be in the arena, which goes.
        diag.keep();
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
    self.kinds = world.Kinds.bind(arena, self.tree.entities, &self.tree.art, diag) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadAsset => error.BadContent,
    };
    self.kinds.shadow = self.tree.art.frame(shadow_frame);
    return self;
}

/// The frame of the shadows on the ground (play's art).
const shadow_frame = "play/shadow_00";

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
        // The sound content as a whole, the kinds of entity, a round's script, play's screen,
        // an art set.
        *const Sounds => if (std.mem.eql(u8, name, "sound")) &c.sounds else null,
        *const world.Kinds => if (std.mem.eql(u8, name, "entities")) &c.kinds else null,
        *const content.round.Round => for (c.tree.rounds) |*r| {
            var buf: [16]u8 = undefined;
            if (std.mem.startsWith(u8, name, "rounds/") and std.mem.eql(u8, name["rounds/".len..], content.round.nameOf(&buf, r.number))) break r;
        } else null,
        *const records.Round => if (std.mem.eql(u8, name, "screens/round")) if (c.tree.screens.round) |*r| r else null else null,
        Rounds => if (std.mem.eql(u8, name, "rounds")) try findRounds(c, diag) else null,
        *const art.ArtSet => a.set(name),
        EnemyColours => blk: {
            if (!std.mem.eql(u8, name, "enemy_colours")) break :blk null;
            const play = if (c.tree.screens.round) |*r| r else break :blk null;
            const ec = &play.enemy_colours;
            if (ec.sets.len > EnemyColours.most) return refuse(diag, "screens/round", "more enemies' colours than the game keeps");
            var out: EnemyColours = .{ .len = @intCast(ec.sets.len), .lines = ec.lines, .police = a.palette(ec.police) orelse return refuse(diag, ec.police, "the police car's colours, not in the art") };
            for (ec.sets, out.sets[0..ec.sets.len]) |set, *o| {
                inline for (.{ "first", "second", "own" }) |part| if (@field(set, part)) |p| {
                    @field(o, part) = a.palette(p) orelse return refuse(diag, p, "an enemies' colours, not in the art");
                };
            }
            break :blk out;
        },
        Poses => blk: {
            if (!std.mem.eql(u8, name, "screens/select")) break :blk null;
            const sel = if (c.tree.screens.select) |*r| r else break :blk null;
            var p: Poses = .{};
            inline for (.{ "adam", "axel", "blaze" }) |who| {
                inline for (.{ "stand", "idle", "pose_a", "pose_b", "pose_c", "landing" }) |pose| {
                    const steps = @field(@field(sel.*, who), pose);
                    p.characters.getPtr(@field(Character, who)).set(@field(Poses.Pose, pose), try animation(a, steps, name, diag));
                }
            }
            break :blk p;
        },
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

/// The steps of a pose, their frames found in the art.
fn animation(a: *const art.Art, steps: []const records.Step, name: []const u8, diag: *json.Diagnostic) LoadError!Animation {
    if (steps.len > Animation.max) return refuse(diag, name, "a pose longer than the game takes");
    var out: Animation = .{ .len = @intCast(steps.len) };
    for (steps, out.steps[0..steps.len]) |s, *o| {
        o.* = .{
            .frame = a.frame(s.frame) orelse return refuse(diag, s.frame, "a pose's frame, not in the art"),
            .ticks = s.ticks,
            .mirrored = s.mirrored,
            .copied = @splat(0),
        };
        for (s.copied[0..@min(s.copied.len, records.max_copies)], 0..) |t, k| o.copied[k] = t;
    }
    return out;
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

test "a broken or stale tree is refused with its file named, after the content's memory is gone" {
    var source = @import("memory.zig").MemoryAssetSource.init(testing.allocator);
    defer source.deinit();
    var diag: json.Diagnostic = .{};
    var buf: [256]u8 = undefined;
    // A record the manifest names, missing; then one of another format (its fields missing).
    // The file's name is made in the content's arena, which the refusal frees.
    try source.add("manifest.json",
        \\{"format": "sorz-content", "version": 1, "extractor": "x", "rom": {"sha256": "0", "size": 1}, "art": [], "screens": ["round"]}
    );
    try testing.expectError(error.BadContent, load(testing.allocator, source.assetSource(), &diag));
    try testing.expectEqualStrings("screens/round.json: missing", try std.fmt.bufPrint(&buf, "{f}", .{&diag}));
    try source.add("screens/round.json", "{}");
    try testing.expectError(error.BadContent, load(testing.allocator, source.assetSource(), &diag));
    try testing.expect(std.mem.startsWith(u8, try std.fmt.bufPrint(&buf, "{f}", .{&diag}), "screens/round.json: "));
}

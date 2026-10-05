//! The extractor: the one place that reads the user's ROM, by address, as a parser of its
//! formats (DESIGN.md P1, C1). It checks the ROM's digest and makes the content tree that the
//! game loads (docs/content.md), a module per kind of content, in memory (`extract`) or on disk
//! (`writeDirectory`). Two extractions of one ROM are byte-identical.
const std = @import("std");
const sorz = @import("sorz");
const content = sorz.content;

pub const rom = @import("rom.zig");
pub const kosinski = @import("kosinski.zig");
pub const nemesis = @import("nemesis.zig");
pub const enigma = @import("enigma.zig");
pub const vram = @import("vram.zig");
pub const blocks = @import("blocks.zig");
pub const builder = @import("builder.zig");
pub const screens = @import("screens.zig");
pub const rounds = @import("rounds.zig");
pub const fonts = @import("fonts.zig");
pub const sprites = @import("sprites.zig");
pub const compare = @import("compare.zig");
pub const palettes = @import("palettes.zig");
pub const palette_steps = @import("palette_steps.zig");
pub const screen_data = @import("screen_data.zig");
pub const sound = @import("sound.zig");
pub const entities = @import("entities.zig");
pub const scripts = @import("scripts.zig");
pub const spawns = @import("spawns.zig");
pub const play = @import("play.zig");

/// The extractor's name and version, in the tree's manifest.
pub const name = "sorz-extract 1";

pub const File = content.File;

/// A tree in memory: its files, sorted by path, owned by its arena.
pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    files: []const File,
    /// What the extraction met that the content does not show.
    notes: builder.Builder.Notes = .{},

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The tree as an asset source (the files stay the tree's).
    pub fn addTo(self: *const Tree, source: *sorz.memory.MemoryAssetSource) !void {
        for (self.files) |f| try source.add(f.path, f.bytes);
    }
};

pub const Error = error{ WrongRom, OutOfMemory, BadData, BadContent } || screens.Error;

/// The content tree of `rom_bytes`, after its digest is checked.
pub fn extract(gpa: std.mem.Allocator, rom_bytes: []const u8) Error!Tree {
    try rom.check(rom_bytes);
    return extractUnchecked(gpa, rom_bytes);
}

/// `extract` without the digest's check, for synthetic images.
pub fn extractUnchecked(gpa: std.mem.Allocator, rom_bytes: []const u8) Error!Tree {
    var tree: Tree = .{ .arena = .init(gpa), .files = &.{} };
    errdefer tree.arena.deinit();
    const arena = tree.arena.allocator();

    var b = try build(arena, rom_bytes);
    // Play's screen: its frames and maps, and its record.
    const round_screen = play.extract(&b) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadData,
    };
    const a = try b.finish();

    const sets = try arena.alloc([]const u8, a.sets.len);
    for (sets, a.sets) |*n, s| n.* = s.name;
    // The screens' records (docs/content.md), their frames named by the art's origins.
    var records = screen_data.extract(arena, rom_bytes, &b) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadData,
    };
    records.round = round_screen;
    var names_buf: [content.screens.record_names.len][]const u8 = undefined;
    // The kinds of entity (docs/content.md).
    const definitions = entities.all(arena, rom_bytes) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadData,
    };
    const kinds = try arena.alloc([]const u8, definitions.len);
    for (kinds, definitions) |*n, d| n.* = d.name;
    // The rounds' scripts (docs/content.md).
    const scripts_ = scripts.all(arena, rom_bytes) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadData,
    };
    const round_names = try arena.alloc([]const u8, scripts_.len);
    for (round_names, scripts_) |*n, r| n.* = try std.fmt.allocPrint(arena, "round{d}", .{r.number});
    const c: content.Content = .{
        .manifest = .{
            .extractor = name,
            .rom_sha256 = try arena.dupe(u8, &rom.digest(rom_bytes)),
            .rom_size = @intCast(rom_bytes.len),
            .art = sets,
            .screens = try arena.dupe([]const u8, records.names(&names_buf)),
            .entities = kinds,
            .rounds = round_names,
        },
        .art = a,
        .screens = records,
        .entities = definitions,
        .rounds = scripts_,
    };
    const art_files = try content.write(arena, &c);
    // The sound's files (docs/content-sound.md), with the art's, sorted by path.
    var why: sound.Refusal = .{};
    const s = sound.extract(arena, rom_bytes, &why) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadData,
    };
    const sound_files = sound.files(arena, &s.content) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadContent,
    };
    const files = try arena.alloc(File, art_files.len + sound_files.len);
    @memcpy(files[0..art_files.len], art_files);
    for (files[art_files.len..], sound_files) |*f, sf| f.* = .{ .path = sf.path, .bytes = sf.bytes };
    std.mem.sort(File, files, {}, struct {
        fn less(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    tree.files = files;
    tree.notes = b.notes;
    return tree;
}

/// The art of `rom_bytes` (not checked), with each asset's origin in the ROM.
pub fn build(arena: std.mem.Allocator, rom_bytes: []const u8) Error!builder.Builder {
    var b = builder.Builder.init(arena, rom_bytes);
    try fonts.extract(&b);
    for (screens.screens) |s| try screens.extract(&b, s);
    for (0..rounds.count) |n| try rounds.extract(&b, @intCast(n));
    try palettes.extract(&b);
    try palette_steps.extract(&b);
    try sprites.extract(&b);
    return b;
}

/// Writes `tree` into the directory `dir` (created if needed), each file replaced whole.
pub fn writeDirectory(io: std.Io, tree: *const Tree, dir: std.Io.Dir) !void {
    for (tree.files) |f| {
        if (std.fs.path.dirname(f.path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = f.path, .data = f.bytes });
    }
}

test {
    std.testing.refAllDecls(@This());
}

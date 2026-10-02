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

/// The extractor's name and version, in the tree's manifest.
pub const name = "sorz-extract 1";

pub const File = content.File;

/// A tree in memory: its files, sorted by path, owned by its arena.
pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    files: []const File,

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
    const a = try b.finish();

    const sets = try arena.alloc([]const u8, a.sets.len);
    for (sets, a.sets) |*n, s| n.* = s.name;
    const c: content.Content = .{
        .manifest = .{
            .extractor = name,
            .rom_sha256 = try arena.dupe(u8, &rom.digest(rom_bytes)),
            .rom_size = @intCast(rom_bytes.len),
            .art = sets,
        },
        .art = a,
    };
    tree.files = try content.write(arena, &c);
    return tree;
}

/// The art of `rom_bytes` (not checked), with each asset's origin in the ROM.
pub fn build(arena: std.mem.Allocator, rom_bytes: []const u8) Error!builder.Builder {
    var b = builder.Builder.init(arena, rom_bytes);
    try fonts.extract(&b);
    for (screens.screens) |s| try screens.extract(&b, s);
    for (0..rounds.count) |n| try rounds.extract(&b, @intCast(n));
    try palettes.extract(&b);
    const frames = try sprites.extract(&b);
    std.log.info("sprite frames: {d} pictures, {d} frames without pieces, {d} that do not read as frames, {d} whose art lacks a tile", .{ frames.frames, frames.empty, frames.unparsed, frames.missing });
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

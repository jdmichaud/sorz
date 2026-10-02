//! The game's files that a server gives the pages it serves (DESIGN.md 5.3): the user's copy,
//! read once through the game's `AssetSource` (the game directory, or the content extracted from
//! the ROM in memory), so that the page never asks the player for them. `/assets/manifest.json`
//! lists them as `{"files": [{"name", "size"}]}`, and `/assets/NAME` gives one.
//!
//! The content tree has a `manifest.json` of its own at its root (DESIGN.md 5.3), which the
//! listing's path would hide, so the tree is served under `tree/`: the listing names
//! `tree/manifest.json`, `tree/art/art.json` and so on, and the page gives each file to the module
//! under its name in the tree. The names are the tree's in lower case, as the extractor writes them
//! (the asset sources match names without regard to case).
const std = @import("std");
const sorz = @import("sorz");
const platform = sorz.platform;

pub const Assets = struct {
    allocator: std.mem.Allocator,
    /// The files in the order of their names: each name as the listing has it (`tree/...`) and its
    /// bytes. They never change once read, so the server's tasks read them without a lock.
    files: []File,
    /// The text of `/assets/manifest.json`.
    listing: []u8,

    pub const File = struct { name: []u8, bytes: []u8 };

    /// The directory of `assets/` the tree is served under.
    pub const directory = "tree/";
    /// The listing's path under `assets/`.
    pub const listing_name = "manifest.json";
    /// The largest file read, as the data's identity reads it.
    pub const max_file_bytes = sorz.net.identity.max_file_bytes;

    pub const ReadError = platform.AssetError || error{OutOfMemory};

    /// Reads every file that `source` lists.
    pub fn read(allocator: std.mem.Allocator, source: platform.AssetSource) ReadError!Assets {
        var names = try source.list("");
        defer names.deinit();
        var files: std.ArrayList(File) = .empty;
        defer files.deinit(allocator);
        errdefer for (files.items) |f| {
            allocator.free(f.name);
            allocator.free(f.bytes);
        };
        try files.ensureTotalCapacity(allocator, names.names.len);
        for (names.names) |name| {
            var bytes = try source.readAll(name, max_file_bytes);
            defer bytes.deinit();
            const served = try std.mem.concat(allocator, u8, &.{ directory, name });
            errdefer allocator.free(served);
            _ = std.ascii.lowerString(served, served);
            files.appendAssumeCapacity(.{ .name = served, .bytes = try allocator.dupe(u8, bytes.bytes) });
        }
        std.mem.sort(File, files.items, {}, nameLessThan);
        const listing = try writeListing(allocator, files.items);
        return .{ .allocator = allocator, .files = try files.toOwnedSlice(allocator), .listing = listing };
    }

    pub fn deinit(self: *Assets) void {
        for (self.files) |f| {
            self.allocator.free(f.name);
            self.allocator.free(f.bytes);
        }
        self.allocator.free(self.files);
        self.allocator.free(self.listing);
        self.* = undefined;
    }

    /// The bytes of the file served at `assets/NAME`, or null; `name` is matched without regard to
    /// case, as the asset sources match names.
    pub fn find(self: *const Assets, name: []const u8) ?[]const u8 {
        for (self.files) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, name)) return f.bytes;
        }
        return null;
    }

    /// The bytes of all the files.
    pub fn totalBytes(self: *const Assets) usize {
        var n: usize = 0;
        for (self.files) |f| n += f.bytes.len;
        return n;
    }

    fn nameLessThan(_: void, a: File, b: File) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }

    fn writeListing(allocator: std.mem.Allocator, files: []const File) error{OutOfMemory}![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const w = &out.writer;
        writeFiles(w, files) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writeFiles(w: *std.Io.Writer, files: []const File) std.Io.Writer.Error!void {
        try w.writeAll("{\"files\":[");
        for (files, 0..) |f, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try std.json.Stringify.encodeJsonString(f.name, .{}, w);
            try w.print(",\"size\":{d}}}", .{f.bytes.len});
        }
        try w.writeAll("]}\n");
    }
};

test "the tree's files under tree/, listed with their sizes, its own manifest apart from the listing" {
    var source = sorz.memory.MemoryAssetSource.init(std.testing.allocator);
    defer source.deinit();
    try source.add("manifest.json", "{\"format\":1}");
    try source.add("art/art.json", "{}");
    try source.add("FONTS/Play.json", "{\"codes\":{}}");
    var assets = try Assets.read(std.testing.allocator, source.assetSource());
    defer assets.deinit();
    try std.testing.expectEqualStrings(
        "{\"files\":[{\"name\":\"tree/art/art.json\",\"size\":2},{\"name\":\"tree/fonts/play.json\",\"size\":12}," ++
            "{\"name\":\"tree/manifest.json\",\"size\":12}]}\n",
        assets.listing,
    );
    try std.testing.expectEqualStrings("{\"format\":1}", assets.find("tree/manifest.json").?);
    try std.testing.expectEqualStrings("{\"codes\":{}}", assets.find("TREE/fonts/PLAY.JSON").?);
    try std.testing.expect(assets.find("manifest.json") == null);
    try std.testing.expect(assets.find("tree/absent.json") == null);
    try std.testing.expectEqual(@as(usize, 26), assets.totalBytes());
}

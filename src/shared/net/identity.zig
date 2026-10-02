//! The identities that the session's handshake compares (DESIGN.md 9): the game data's, so that two
//! players with different data never start a session, and the build's.
//!
//! The data is known by its content tree, which is all the game reads: the SHA-256 of its files in
//! the order of their canonical names, for each "file ", the name, a zero byte, its length (u64,
//! little-endian) and its bytes, after "sorz content tree\n". A ROM is known by the tree extracted
//! from it, so a ROM, an unedited extraction of it on disk, and a page's copy of the files its
//! server sent are the same data; a tree is other data as soon as it is edited.
const std = @import("std");
const platform = @import("../platform.zig");
const protocol = @import("protocol.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The identity of the asset tree that `source` holds (every file it lists). Each file is read
/// whole with `max_file_bytes` at most.
pub fn ofTree(source: platform.AssetSource, max_file_bytes: usize) platform.AssetError!protocol.DataId {
    var names = try source.list("");
    defer names.deinit();
    const sorted = source.allocator.dupe([]const u8, names.names) catch return error.OutOfMemory;
    defer source.allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, platform.assetNameLessThan);
    var h = Sha256.init(.{});
    h.update("sorz content tree\n");
    for (sorted) |name| {
        var bytes = try source.readAll(name, max_file_bytes);
        defer bytes.deinit();
        h.update("file ");
        h.update(name);
        h.update(&.{0});
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, bytes.bytes.len, .little);
        h.update(&len);
        h.update(bytes.bytes);
    }
    var out: protocol.DataId = undefined;
    h.final(&out);
    return out;
}

/// The identity as hexadecimal text, for the messages.
pub fn hex(id: *const protocol.DataId) [64]u8 {
    return std.fmt.bytesToHex(id.*, .lower);
}

test "a tree's identity follows its files, not the order they were added in" {
    const memory = @import("../memory.zig");
    var a = memory.MemoryAssetSource.init(std.testing.allocator);
    defer a.deinit();
    try a.add("manifest.json", "{}");
    try a.add("art/title.png", "png");
    var b = memory.MemoryAssetSource.init(std.testing.allocator);
    defer b.deinit();
    try b.add("art/title.png", "png");
    try b.add("manifest.json", "{}");
    const ia = try ofTree(a.assetSource(), 1 << 20);
    try std.testing.expectEqualSlices(u8, &ia, &(try ofTree(b.assetSource(), 1 << 20)));
    // One byte changed, or a file renamed, is other data.
    try b.add("manifest.json", "{ }");
    try std.testing.expect(!std.mem.eql(u8, &ia, &(try ofTree(b.assetSource(), 1 << 20))));
    // The names' case is not the data's: a page that adds the files in lower case has the
    // identity of a tree whose names are in upper case.
    var c = memory.MemoryAssetSource.init(std.testing.allocator);
    defer c.deinit();
    try c.add("ART/TITLE.PNG", "png");
    try c.add("Manifest.json", "{}");
    try std.testing.expectEqualSlices(u8, &ia, &(try ofTree(c.assetSource(), 1 << 20)));
    var abc: protocol.DataId = undefined;
    Sha256.hash("abc", &abc, .{});
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &hex(&abc));
}

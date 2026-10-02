//! The agent host's pictures (`--shot`): a frame as a PNG file, 8-bit RGBA, each row unfiltered and
//! the image data in stored deflate blocks. It needs no compression: a debugging picture is
//! written to be looked at, not kept small. The game's own pictures are content, which the
//! content's readers and the extractor handle.
const std = @import("std");

const signature = "\x89PNG\r\n\x1a\n";
/// The longest stored deflate block.
const max_block = 65535;

/// The PNG of `rgba` (`width` x `height` pixels, four bytes each, rows from the top).
pub fn encode(gpa: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) error{OutOfMemory}![]u8 {
    // PNG has no empty picture, and the rows' loop below needs a row's bytes.
    std.debug.assert(width > 0 and height > 0);
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);
    const row = @as(usize, width) * 4;
    const raw_len = (row + 1) * height;
    const blocks = @max(1, (raw_len + max_block - 1) / max_block);
    const idat_len = 2 + blocks * 5 + raw_len + 4;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, signature.len + (12 + 13) + (12 + idat_len) + 12);
    out.appendSliceAssumeCapacity(signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8 bits, RGBA, deflate, no filter method, no interlace
    chunk(&out, "IHDR", &ihdr);

    // The image data: a zlib stream (deflate, no preset dictionary) of stored blocks, each row
    // with its filter byte (none), then the Adler-32 of the rows.
    const start = out.items.len;
    out.appendNTimesAssumeCapacity(0, 8); // the chunk's length and type, written below
    out.appendSliceAssumeCapacity(&.{ 0x78, 0x01 });
    var adler: std.hash.Adler32 = .{};
    var left = raw_len;
    var y: usize = 0;
    var x: usize = 0; // the next byte of row `y`, the filter byte being byte 0
    while (true) {
        const n = @min(left, max_block);
        out.appendAssumeCapacity(if (n == left) 1 else 0);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u16, len[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, len[2..4], ~@as(u16, @intCast(n)), .little);
        out.appendSliceAssumeCapacity(&len);
        var k: usize = 0;
        while (k < n) {
            if (x == 0) {
                out.appendAssumeCapacity(0);
                adler.update(&.{0});
                x = 1;
                k += 1;
                continue;
            }
            const take = @min(n - k, row + 1 - x);
            const bytes = rgba[y * row + x - 1 ..][0..take];
            out.appendSliceAssumeCapacity(bytes);
            adler.update(bytes);
            x += take;
            k += take;
            if (x == row + 1) {
                x = 0;
                y += 1;
            }
        }
        left -= n;
        if (left == 0) break;
    }
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, adler.adler, .big);
    out.appendSliceAssumeCapacity(&sum);
    const data_len = out.items.len - start - 8;
    std.mem.writeInt(u32, out.items[start..][0..4], @intCast(data_len), .big);
    out.items[start + 4 ..][0..4].* = "IDAT".*;
    var crc = std.hash.Crc32.init();
    crc.update(out.items[start + 4 .. out.items.len]);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    out.appendSliceAssumeCapacity(&crc_bytes);

    chunk(&out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    out.appendSliceAssumeCapacity(&len);
    out.appendSliceAssumeCapacity(kind);
    out.appendSliceAssumeCapacity(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    out.appendSliceAssumeCapacity(&crc_bytes);
}

test "a picture's PNG: its chunks, and its rows in stored blocks" {
    const gpa = std.testing.allocator;
    // Wide enough that the rows span several blocks.
    const width = 9000;
    const height = 3;
    const rgba = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(rgba);
    for (rgba, 0..) |*b, i| b.* = @truncate(i *% 7);
    const png = try encode(gpa, width, height, rgba);
    defer gpa.free(png);
    try std.testing.expectEqualStrings(signature, png[0..8]);
    try std.testing.expectEqualStrings("IHDR", png[12..16]);
    try std.testing.expectEqual(@as(u32, width), std.mem.readInt(u32, png[16..20], .big));
    try std.testing.expectEqualSlices(u8, &.{ 8, 6, 0, 0, 0 }, png[24..29]);
    // The image data: the rows back from the stored blocks, and the stream's checksum.
    const idat_len = std.mem.readInt(u32, png[33..37], .big);
    try std.testing.expectEqualStrings("IDAT", png[37..41]);
    const zlib = png[41..][0..idat_len];
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x01 }, zlib[0..2]);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var at: usize = 2;
    while (true) {
        const final = zlib[at] == 1;
        const n = std.mem.readInt(u16, zlib[at + 1 ..][0..2], .little);
        try std.testing.expectEqual(~n, std.mem.readInt(u16, zlib[at + 3 ..][0..2], .little));
        try raw.appendSlice(gpa, zlib[at + 5 ..][0..n]);
        at += 5 + @as(usize, n);
        if (final) break;
    }
    try std.testing.expectEqual(std.hash.Adler32.hash(raw.items), std.mem.readInt(u32, zlib[at..][0..4], .big));
    try std.testing.expectEqual(idat_len, at + 4);
    for (0..height) |y| {
        const line = raw.items[y * (width * 4 + 1) ..][0 .. width * 4 + 1];
        try std.testing.expectEqual(@as(u8, 0), line[0]);
        try std.testing.expectEqualSlices(u8, rgba[y * width * 4 ..][0 .. width * 4], line[1..]);
    }
    // IEND, with its well-known checksum.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82 }, png[png.len - 12 ..]);
}

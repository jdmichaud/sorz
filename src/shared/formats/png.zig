//! Indexed PNG images: the content tree's pictures (docs/content.md). A picture is palette
//! indices, with index 0 transparent, and the palette that shows it; the game reads the indices
//! and draws them with its own palettes.
//!
//! The encoder writes 4 bits per pixel (8 when an index is above 15), no filter, and the image
//! data as stored (uncompressed) deflate blocks: the same picture gives the same bytes with any
//! version of the toolchain, which the extractor's check of two identical extractions needs. The
//! decoder reads what editors write: colour type 3 at 1, 2, 4 or 8 bits, every filter, compressed
//! data, and refuses anything else with the reason.
//!
//! Carried over from sor-remaster after review: the decoder's chunk arithmetic is checked (a
//! 32-bit target could overflow it), a second palette chunk is refused (it leaked the first), and
//! the encoder reports a wrong pixel count instead of asserting.
const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    /// One palette index per pixel, row by row.
    pixels: []u8,
    /// The palette the file carries, RGB, up to 256 entries.
    palette: [][3]u8,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        gpa.free(self.palette);
    }
};

pub const DecodeError = error{
    NotPng,
    Truncated,
    BadChunk,
    BadCrc,
    NotIndexed,
    Interlaced,
    BadData,
    TooLarge,
    NoPalette,
    IndexOutOfPalette,
} || std.mem.Allocator.Error;

pub const EncodeError = error{ BadImage, IndexOutOfPalette } || std.mem.Allocator.Error;

const signature = "\x89PNG\r\n\x1a\n";
pub const max_side = 8192;

/// Encodes `pixels` (width * height indices) with `palette` (RGB, 1 to 256 colours); index 0 is
/// transparent.
pub fn encode(gpa: std.mem.Allocator, width: u32, height: u32, pixels: []const u8, palette: []const [3]u8) EncodeError![]u8 {
    if (width == 0 or height == 0 or width > max_side or height > max_side) return error.BadImage;
    if (pixels.len != @as(usize, width) * height) return error.BadImage;
    if (palette.len < 1 or palette.len > 256) return error.BadImage;
    var depth: u8 = 4;
    for (pixels) |p| {
        if (p >= palette.len) return error.IndexOutOfPalette;
        if (p > 15) depth = 8;
    }
    if (palette.len > 16) depth = 8;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = depth;
    ihdr[9] = 3; // indexed colour
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(gpa, &out, "IHDR", &ihdr);

    var plte: std.ArrayList(u8) = .empty;
    defer plte.deinit(gpa);
    for (palette) |c| try plte.appendSlice(gpa, &c);
    try chunk(gpa, &out, "PLTE", plte.items);
    try chunk(gpa, &out, "tRNS", &.{0});

    // The raw scanlines: a filter byte (0) then the packed indices.
    const row_bytes: usize = if (depth == 4) (width + 1) / 2 else width;
    var raw = try gpa.alloc(u8, (row_bytes + 1) * height);
    defer gpa.free(raw);
    @memset(raw, 0);
    for (0..height) |y| {
        const row = raw[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        for (0..width) |x| {
            const p = pixels[y * width + x];
            if (depth == 8) {
                row[1 + x] = p;
            } else if (x % 2 == 0) {
                row[1 + x / 2] = p << 4;
            } else {
                row[1 + x / 2] |= p;
            }
        }
    }
    // zlib: header, stored blocks of up to 65535 bytes, Adler-32.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var at: usize = 0;
    while (true) {
        const n = @min(raw.len - at, 0xFFFF);
        const last = at + n == raw.len;
        try z.append(gpa, @intFromBool(last));
        var len: [4]u8 = undefined;
        std.mem.writeInt(u16, len[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, len[2..4], ~@as(u16, @intCast(n)), .little);
        try z.appendSlice(gpa, &len);
        try z.appendSlice(gpa, raw[at .. at + n]);
        at += n;
        if (last) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(gpa, &adler);
    try chunk(gpa, &out, "IDAT", z.items);
    try chunk(gpa, &out, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(gpa, &sum);
}

/// Decodes an indexed PNG.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Image {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], signature)) return error.NotPng;
    var pos: usize = signature.len;
    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var seen_header = false;
    var palette: ?[][3]u8 = null;
    errdefer if (palette) |p| gpa.free(p);
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (true) {
        if (bytes.len - pos < 12) return error.Truncated;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (len > bytes.len - pos - 12) return error.Truncated;
        const data = bytes[pos + 8 ..][0..len];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        if (crc.final() != std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big)) return error.BadCrc;
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13 or seen_header) return error.BadChunk;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            depth = data[8];
            if (data[9] != 3) return error.NotIndexed;
            if (depth != 1 and depth != 2 and depth != 4 and depth != 8) return error.BadChunk;
            if (data[12] != 0) return error.Interlaced;
            if (width == 0 or height == 0 or width > max_side or height > max_side) return error.TooLarge;
            seen_header = true;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len == 0 or len > 768 or palette != null) return error.BadChunk;
            const p = try gpa.alloc([3]u8, len / 3);
            for (p, 0..) |*c, i| c.* = data[i * 3 ..][0..3].*;
            palette = p;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
    }
    if (!seen_header) return error.BadChunk;
    const pal = palette orelse return error.NoPalette;
    // Inflate.
    const bits_per_row = @as(usize, width) * depth;
    const row_bytes = (bits_per_row + 7) / 8;
    const expected = (row_bytes + 1) * height;
    var in: std.Io.Reader = .fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    const raw = inflate.reader.allocRemaining(gpa, .limited(expected + 1)) catch return error.BadData;
    defer gpa.free(raw);
    if (raw.len != expected) return error.BadData;
    // Unfilter in place.
    const bpp: usize = @max(1, depth / 8);
    var prev: ?[]const u8 = null;
    for (0..height) |y| {
        const line = raw[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        const filter = line[0];
        const cur = line[1..];
        for (cur, 0..) |*b, i| {
            const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
            const up: u8 = if (prev) |p| p[i] else 0;
            const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
            b.* = switch (filter) {
                0 => b.*,
                1 => b.* +% a,
                2 => b.* +% up,
                3 => b.* +% @as(u8, @intCast((@as(u16, a) + up) / 2)),
                4 => b.* +% paeth(a, up, c),
                else => return error.BadData,
            };
        }
        prev = cur;
    }
    const pixels = try gpa.alloc(u8, @as(usize, width) * height);
    errdefer gpa.free(pixels);
    for (0..height) |y| {
        const cur = raw[y * (row_bytes + 1) + 1 ..][0..row_bytes];
        for (0..width) |x| {
            const bit = x * depth;
            const byte = cur[bit / 8];
            const shift: u3 = @intCast(8 - depth - (bit % 8));
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            const p = (byte >> shift) & mask;
            if (p >= pal.len) return error.IndexOutOfPalette;
            pixels[y * width + x] = p;
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels, .palette = pal };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "encode then decode gives the same indices and palette" {
    const gpa = std.testing.allocator;
    const pal = [_][3]u8{ .{ 0, 0, 0 }, .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 } };
    var px: [7 * 3]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i % 4);
    const bytes = try encode(gpa, 7, 3, &px, &pal);
    defer gpa.free(bytes);
    var img = try decode(gpa, bytes);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 7), img.width);
    try std.testing.expectEqualSlices(u8, &px, img.pixels);
    try std.testing.expectEqual(pal.len, img.palette.len);
    // The same picture encodes to the same bytes.
    const again = try encode(gpa, 7, 3, &px, &pal);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    // A wrong count of pixels, or an index past the palette, is refused.
    try std.testing.expectError(error.BadImage, encode(gpa, 7, 4, &px, &pal));
    try std.testing.expectError(error.IndexOutOfPalette, encode(gpa, 7, 3, &px, pal[0..2]));
}

test "a picture larger than a stored block encodes in several" {
    const gpa = std.testing.allocator;
    var grey: [256][3]u8 = undefined;
    for (&grey, 0..) |*c, i| c.* = .{ @intCast(i), @intCast(i), @intCast(i) };
    const px = try gpa.alloc(u8, 300 * 300);
    defer gpa.free(px);
    for (px, 0..) |*p, i| p.* = @truncate(i *% 7);
    const bytes = try encode(gpa, 300, 300, px, &grey);
    defer gpa.free(bytes);
    var img = try decode(gpa, bytes);
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, px, img.pixels);
}

test "a compressed, filtered PNG from an editor decodes" {
    // 2x2, 8-bit indexed, rows filtered with Sub and Up, compressed by a zlib encoder.
    const gpa = std.testing.allocator;
    const raw = [_]u8{ 1, 1, 1, 2, 0, 0 }; // row 0: Sub [1, +1]; row 1: Up [+0, +0]
    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer z.deinit();
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&z.writer, &buf, .zlib, .default);
    try c.writer.writeAll(&raw);
    try c.finish();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, signature);
    var ihdr: [13]u8 = .{ 0, 0, 0, 2, 0, 0, 0, 2, 8, 3, 0, 0, 0 };
    try chunk(gpa, &out, "IHDR", &ihdr);
    try chunk(gpa, &out, "PLTE", &.{ 0, 0, 0, 1, 1, 1, 2, 2, 2 });
    try chunk(gpa, &out, "IDAT", z.written());
    try chunk(gpa, &out, "IEND", &.{});
    var img = try decode(gpa, out.items);
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 1, 2 }, img.pixels);
}

test "malformed and true-colour files are refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotPng, decode(gpa, "GIF89a"));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, signature);
    var ihdr: [13]u8 = .{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0 };
    try chunk(gpa, &out, "IHDR", &ihdr);
    try std.testing.expectError(error.NotIndexed, decode(gpa, out.items));
    out.items[out.items.len - 1] ^= 1;
    try std.testing.expectError(error.BadCrc, decode(gpa, out.items));
    // A chunk whose length runs past the file.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    try long.appendSlice(gpa, signature);
    try long.appendSlice(gpa, &.{ 0xFF, 0xFF, 0xFF, 0xF0, 'I', 'H', 'D', 'R', 0, 0, 0, 0 });
    try std.testing.expectError(error.Truncated, decode(gpa, long.items));
    // Two palettes.
    const pal = [_][3]u8{ .{ 0, 0, 0 }, .{ 1, 1, 1 } };
    const good = try encode(gpa, 1, 1, &.{1}, &pal);
    defer gpa.free(good);
    var two: std.ArrayList(u8) = .empty;
    defer two.deinit(gpa);
    try two.appendSlice(gpa, good[0 .. signature.len + 25]); // the signature and IHDR
    try chunk(gpa, &two, "PLTE", &.{ 0, 0, 0 });
    try two.appendSlice(gpa, good[signature.len + 25 ..]);
    try std.testing.expectError(error.BadChunk, decode(gpa, two.items));
}

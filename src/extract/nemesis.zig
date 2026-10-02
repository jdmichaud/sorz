//! Nemesis decompression, as the original's routines at 0x8192 (to the VDP) and 0x81A4 (to RAM)
//! do it (graphics port map 1.1). A header word (bit 15: each row is XORed with the previous one;
//! bits 14-0: the number of tiles), a code table (per value: runs of (count, code length, code)
//! entries), then an MSB-first bit stream of codes, each giving a nibble value and a repeat count;
//! the code 111111 is followed by an inline 7-bit count and value. Rows of 8 nibbles form the
//! 32-byte tiles.
//!
//! Carried over from sor-remaster's exporter after review: the decoder only (sorz keeps no
//! coding to rebuild the ROM's streams), and a code of length 0 is refused (it indexed past the
//! code table).
const std = @import("std");

pub const Error = error{ Truncated, BadCode } || std.mem.Allocator.Error;

pub const Result = struct {
    bytes: []u8,
    /// The offset just past the stream (the bit reader's position rounded up to a byte).
    end: usize,
};

const Entry = struct { length: u8 = 0, value: u8 = 0, count: u8 = 0, set: bool = false };

pub fn decompress(gpa: std.mem.Allocator, data: []const u8, start: usize) Error!Result {
    var pos = start;
    if (pos + 2 > data.len) return error.Truncated;
    const header = @as(u16, data[pos]) << 8 | data[pos + 1];
    pos += 2;
    const xor = header & 0x8000 != 0;
    const rows: usize = @as(usize, header & 0x7FFF) * 8;

    var table: [256]Entry = @splat(.{});
    if (pos >= data.len) return error.Truncated;
    var b = data[pos];
    pos += 1;
    while (b != 0xFF) {
        const value = b & 0x0F;
        while (true) {
            if (pos >= data.len) return error.Truncated;
            b = data[pos];
            pos += 1;
            if (b & 0x80 != 0) break;
            const count = ((b >> 4) & 7) + 1;
            const length = b & 0x0F;
            if (length == 0 or length > 8) return error.BadCode;
            if (pos >= data.len) return error.Truncated;
            const code = data[pos];
            pos += 1;
            const shift: u4 = @intCast(8 - length);
            const first: usize = @as(u8, @truncate(@as(u16, code) << shift));
            const n = @as(usize, 1) << shift;
            for (table[first..][0..n]) |*e| e.* = .{ .length = length, .value = value, .count = count, .set = true };
        }
    }

    const out = try gpa.alloc(u8, rows * 4);
    errdefer gpa.free(out);
    var bits: Bits = .{ .data = data, .pos = pos * 8 };
    var row: u32 = 0;
    var nybbles: u8 = 0;
    var prev: u32 = 0;
    var done: usize = 0;
    while (done < rows) {
        const v = try bits.peek(8);
        var count: u8 = undefined;
        var value: u8 = undefined;
        if (v >= 0xFC) {
            bits.pos += 6;
            const inline_bits = try bits.peek(7);
            bits.pos += 7;
            count = @intCast((inline_bits >> 4) + 1);
            value = @intCast(inline_bits & 0x0F);
        } else {
            const e = table[v];
            if (!e.set) return error.BadCode;
            bits.pos += e.length;
            count = e.count;
            value = e.value;
        }
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            row = (row << 4) | value;
            nybbles += 1;
            if (nybbles == 8) {
                if (xor) {
                    row ^= prev;
                    prev = row;
                }
                std.mem.writeInt(u32, out[done * 4 ..][0..4], row, .big);
                row = 0;
                nybbles = 0;
                done += 1;
                if (done == rows) break;
            }
        }
    }
    return .{ .bytes = out, .end = (bits.pos + 7) / 8 };
}

/// The XOR bit, the code table (in the table's order) and the trailer of the stream at `start`.
const Bits = struct {
    data: []const u8,
    pos: usize,

    /// The next `n` bits, MSB first, without consuming them. Bits past the data read as 0, as
    /// the original reads whatever follows; a peek wholly past the end is refused.
    fn peek(self: *const Bits, n: u4) Error!u32 {
        if (self.pos / 8 >= self.data.len) return error.Truncated;
        var v: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = self.pos + i;
            const byte = if (p / 8 < self.data.len) self.data[p / 8] else 0;
            v = (v << 1) | ((byte >> @intCast(7 - (p & 7))) & 1);
        }
        return v;
    }
};

test "a table of two codes decodes a tile" {
    // One tile (8 rows). Value 0: code 0 (1 bit), count 8 -> a whole row of zeros. Value 5: code 1
    // (1 bit), count 8 -> a row of 5s. Bits: 0 1 0 1 0 1 0 1 -> rows alternate.
    const stream = [_]u8{
        0x00, 0x01, // one tile, no XOR
        0x80, 0x71, 0x00, // value 0 (bit 7 marks a value): count 8 (7 << 4), length 1, code 0
        0x85, 0x71, 0x01, // value 5: count 8, length 1, code 1
        0xFF, // end of the table
        0b0101_0101,
    };
    const r = try decompress(std.testing.allocator, &stream, 0);
    defer std.testing.allocator.free(r.bytes);
    try std.testing.expectEqual(@as(usize, 32), r.bytes.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0x55, 0x55, 0x55, 0x55 }, r.bytes[0..8]);
    try std.testing.expectEqual(stream.len, r.end);
}

test "the XOR variant and an inline code" {
    // One tile, XOR mode. Code 111111 then 7 bits: count 8 (0b111 << 4) and value 1: a row of 1s;
    // the next rows are inline zeros, so XOR repeats the first row.
    // Build the bit stream: 8 inline codes, the first with value 1, the rest value 0.
    var bits: [16]u8 = @splat(0);
    var at: usize = 0;
    const put = struct {
        fn f(buf: []u8, p: *usize, v: u32, n: u5) void {
            var i: u5 = n;
            while (i > 0) {
                i -= 1;
                if ((v >> i) & 1 != 0) buf[p.* / 8] |= @as(u8, 0x80) >> @intCast(p.* & 7);
                p.* += 1;
            }
        }
    }.f;
    for (0..8) |k| {
        put(&bits, &at, 0b111111, 6);
        put(&bits, &at, if (k == 0) 0b1110001 else 0b1110000, 7);
    }
    var stream: [3 + 16]u8 = undefined;
    stream[0] = 0x80;
    stream[1] = 0x01;
    stream[2] = 0xFF;
    @memcpy(stream[3..], &bits);
    const r = try decompress(std.testing.allocator, &stream, 0);
    defer std.testing.allocator.free(r.bytes);
    for (0..8) |row| try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x11, 0x11, 0x11 }, r.bytes[row * 4 ..][0..4]);
}

test "a truncated stream is refused" {
    try std.testing.expectError(error.Truncated, decompress(std.testing.allocator, &.{ 0x00, 0x01, 0xFF }, 0));
}

test "a code of length 0 is refused" {
    const stream = [_]u8{ 0x00, 0x01, 0x80, 0x70, 0x01, 0xFF, 0x00 };
    try std.testing.expectError(error.BadCode, decompress(std.testing.allocator, &stream, 0));
}

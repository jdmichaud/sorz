//! Kosinski decompression, as the original's routine at 0x85A2 does it (graphics port map). Sega's
//! LZ77 variant: a 16-bit little-endian descriptor of flags, read low bit first and reloaded when
//! its sixteenth flag is taken; a set flag copies a literal byte, a clear one starts a back
//! reference, short (two more flags: a length of 2 to 5, a one-byte offset) or long (a 13-bit
//! offset and a 3-bit length, or a length byte when those 3 bits are zero: 0 ends the stream, 1
//! continues).
//!
//! Carried over from sor-remaster's exporter after review, unchanged.
const std = @import("std");

pub const Error = error{ Truncated, BadReference } || std.mem.Allocator.Error;

pub const Result = struct {
    bytes: []u8,
    /// The offset just past the stream, where the original's source pointer stops.
    end: usize,
};

pub fn decompress(gpa: std.mem.Allocator, data: []const u8, start: usize) Error!Result {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var r: Reader = .{ .data = data, .pos = start };
    try r.loadDescriptor();
    while (true) {
        if (try r.bit()) {
            try out.append(gpa, try r.byte());
            continue;
        }
        var count: usize = undefined;
        var offset: isize = undefined;
        if (try r.bit()) {
            const lo = try r.byte();
            const hi = try r.byte();
            offset = @as(isize, @as(i16, @bitCast(@as(u16, 0xE000) | (@as(u16, hi & 0xF8) << 5) | lo)));
            count = hi & 7;
            if (count != 0) {
                count += 2;
            } else {
                const n = try r.byte();
                if (n == 0) break;
                if (n == 1) continue;
                count = @as(usize, n) + 1;
            }
        } else {
            const high: usize = @intFromBool(try r.bit());
            const low: usize = @intFromBool(try r.bit());
            count = (high << 1 | low) + 2;
            offset = @as(isize, try r.byte()) - 0x100;
        }
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const from = @as(isize, @intCast(out.items.len)) + offset;
            if (from < 0) return error.BadReference;
            try out.append(gpa, out.items[@intCast(from)]);
        }
    }
    return .{ .bytes = try out.toOwnedSlice(gpa), .end = r.pos };
}

const Reader = struct {
    data: []const u8,
    pos: usize,
    bits: u16 = 0,
    left: u8 = 0,

    fn byte(self: *Reader) Error!u8 {
        if (self.pos >= self.data.len) return error.Truncated;
        defer self.pos += 1;
        return self.data[self.pos];
    }

    fn loadDescriptor(self: *Reader) Error!void {
        const lo = try self.byte();
        const hi = try self.byte();
        self.bits = @as(u16, hi) << 8 | lo;
        self.left = 16;
    }

    /// The next flag. The original reloads the descriptor as soon as the sixteenth flag is
    /// taken, before that flag is used (0x85AE), so a stream's reload points are part of it.
    fn bit(self: *Reader) Error!bool {
        const b = self.bits & 1 != 0;
        self.bits >>= 1;
        self.left -= 1;
        if (self.left == 0) try self.loadDescriptor();
        return b;
    }
};

test "literals, a short and a long reference, the end" {
    // Descriptor bits, low first: 1 (literal 'a'), 1 ('b'), 0 0 1 0 (short: length 2+2, offset
    // -2), 0 1 (long, offset -4 length 3+2), 0 1 (long with a length byte of 0: the end).
    // bits: 1,1,0,0,1,0,0,1,0,1 -> 0b10_1001_0011 read low first.
    const flags: u16 = 0b0000_0010_1001_0011;
    const stream = [_]u8{
        @truncate(flags), @truncate(flags >> 8),
        'a', 'b', // literals
        0xFE, // short offset -2
        0xFC, 0xF8 | 3, // long: offset -4, length 3+2
        0x00, 0xF0, 0x00, // long with a zero length field, then the end byte
    };
    const r = try decompress(std.testing.allocator, &stream, 0);
    defer std.testing.allocator.free(r.bytes);
    try std.testing.expectEqualStrings("abababababa", r.bytes);
    try std.testing.expectEqual(stream.len, r.end);
}

test "a reference before the start is refused" {
    const flags: u16 = 0b0000_0000_0000_0000; // short reference first
    const stream = [_]u8{ @truncate(flags), @truncate(flags >> 8), 0xFF };
    try std.testing.expectError(error.BadReference, decompress(std.testing.allocator, &stream, 0));
}

test "a truncated stream is refused" {
    try std.testing.expectError(error.Truncated, decompress(std.testing.allocator, &[_]u8{0xFF}, 0));
}

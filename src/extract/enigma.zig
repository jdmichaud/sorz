//! Enigma tile-map decompression, as the original's routine at 0x82D6 does it (graphics port map
//! 2.4), quirks included. The header: the bit count of an inline tile number, a mask of the flag
//! bits that inline values carry (priority, palette high, palette low, V flip, H flip), the
//! incrementing start word and the common word (both plus the base in d0). Then MSB-first groups:
//! `00cccc` c + 1 incrementing words, `01cccc` c + 1 common words, `100cccc` one inline word c + 1
//! times, `101cccc` / `110cccc` an inline word counting up / down, `111cccc` c + 1 inline words,
//! `1111111` the end.
//!
//! The bit reader follows the original's registers (d5 a 16-bit window, d6 its unread bits):
//! the mask table the inline numbers are anded with starts on the word of a `bra.s` (0x60D8 at
//! 0x8422), so a stream with 0-bit inline numbers adds stale window bits masked with 0x60D8 to its
//! values, and the end offset depends on the window.
//!
//! Carried over from sor-remaster's exporter after review, unchanged.
const std = @import("std");

pub const Error = error{Truncated} || std.mem.Allocator.Error;

pub const Result = struct {
    words: []u16,
    /// Where the original's source pointer stops (0x837C): past the bytes it used, even.
    end: usize,
};

/// The masks of 0x8422, indexed by a bit count; entry 0 is the `bra.s` word.
fn mask(n: u32) u16 {
    if (n == 0) return 0x60D8;
    if (n >= 16) return 0xFFFF;
    return @intCast((@as(u32, 1) << @intCast(n)) - 1);
}

const Reader = struct {
    data: []const u8,
    pos: usize,
    d5: u16 = 0,
    d6: i32 = 16,

    fn byte(self: *Reader) Error!u8 {
        if (self.pos >= self.data.len) return error.Truncated;
        return self.data[self.pos];
    }

    fn word(self: *Reader) Error!u16 {
        if (self.pos + 2 > self.data.len) return error.Truncated;
        defer self.pos += 2;
        return @as(u16, self.data[self.pos]) << 8 | self.data[self.pos + 1];
    }

    /// 0x8444: drop `n` bits; refill a byte when fewer than 9 are left.
    fn consume(self: *Reader, n: i32) Error!void {
        self.d6 -= n;
        if (self.d6 < 9) {
            self.d6 += 8;
            self.d5 = (self.d5 << 8) | try self.byte();
            self.pos += 1;
        }
    }
};

pub fn decompress(gpa: std.mem.Allocator, data: []const u8, start: usize, base: u16) Error!Result {
    if (start + 8 > data.len) return error.Truncated;
    const nbits: u32 = data[start];
    const flag_mask: u16 = @as(u16, data[start + 1]) << 3;
    var inc: u16 = (@as(u16, data[start + 2]) << 8 | data[start + 3]) +% base;
    const common: u16 = (@as(u16, data[start + 4]) << 8 | data[start + 5]) +% base;
    var r: Reader = .{ .data = data, .pos = start + 6 };
    r.d5 = try r.word();

    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        const d1: u16 = (r.d5 >> @intCast(r.d6 - 7)) & 0x7F;
        var count: usize = undefined;
        if (d1 < 0x40) {
            try r.consume(6);
            count = ((d1 >> 1) & 15) + 1;
        } else {
            try r.consume(7);
            count = (d1 & 15) + 1;
        }
        switch (d1 >> 4) {
            0, 1 => for (0..count) |_| {
                try out.append(gpa, inc);
                inc +%= 1;
            },
            2, 3 => try out.appendNTimes(gpa, common, count),
            4 => try out.appendNTimes(gpa, try inlineValue(&r, nbits, flag_mask, base), count),
            5, 6 => {
                var v = try inlineValue(&r, nbits, flag_mask, base);
                for (0..count) |_| {
                    try out.append(gpa, v);
                    v = if (d1 >> 4 == 5) v +% 1 else v -% 1;
                }
            },
            else => {
                if (count == 16) break;
                for (0..count) |_| try out.append(gpa, try inlineValue(&r, nbits, flag_mask, base));
            },
        }
    }
    var end = r.pos - 1;
    if (r.d6 == 16) end -= 1;
    end += end & 1;
    return .{ .words = try out.toOwnedSlice(gpa), .end = end };
}

/// 0x8394: an inline word: the flag bits the mask selects, then an `nbits` tile number. The
/// palette's two bits are added to the base (`addi.w`), so they carry into the priority bit; the
/// priority and the flips are or-ed in (`ori.w`).
fn inlineValue(r: *Reader, nbits: u32, flag_mask: u16, base: u16) Error!u16 {
    var v: u16 = base;
    var m: u16 = flag_mask;
    for ([_]u16{ 0x8000, 0x4000, 0x2000, 0x1000, 0x800 }) |flag| {
        m = (m << 1) & 0x1FF;
        if (m & 0x100 != 0) {
            r.d6 -= 1;
            if ((r.d5 >> @intCast(r.d6)) & 1 != 0) v = if (flag == 0x4000 or flag == 0x2000) v +% flag else v | flag;
        }
    }
    var d1: u16 = r.d5;
    var d7: i32 = r.d6 - @as(i32, @intCast(nbits));
    if (d7 < 0) {
        r.d6 = d7 + 16;
        d7 = -d7;
        const sh: u5 = @intCast(d7);
        d1 = @truncate(@as(u32, d1) << sh);
        var b = try r.byte();
        if (@rem(d7, 8) != 0) b = std.math.rotl(u8, b, @as(u3, @intCast(@rem(d7, 8))));
        d1 +%= b & mask(@intCast(d7));
        d1 = (d1 & mask(nbits)) +% v;
        r.d5 = try r.word();
    } else if (d7 == 0) {
        r.d6 = 16;
        d1 = (d1 & mask(nbits)) +% v;
        r.d5 = try r.word();
    } else {
        d1 = ((d1 >> @intCast(d7)) & mask(nbits)) +% v;
        try r.consume(@intCast(nbits));
    }
    return d1;
}

test "incrementing, common and inline groups, then the end" {
    // nbits 8, no flags, inc 0x0010, common 0x0100. Groups: 00 0001 (2 incrementing), 01 0000
    // (1 common), 100 0000 + inline byte 0x42 (one inline word), 1111111 (end).
    // Bits: 000001 010000 1000000 01000010 1111111, padded.
    const gpa = std.testing.allocator;
    var bits: [8]u8 = @splat(0);
    var at: usize = 0;
    for ([_]struct { v: u32, n: u5 }{
        .{ .v = 0b000001, .n = 6 }, .{ .v = 0b010000, .n = 6 },  .{ .v = 0b1000000, .n = 7 },
        .{ .v = 0x42, .n = 8 },     .{ .v = 0b1111111, .n = 7 },
    }) |g| {
        var i: u5 = g.n;
        while (i > 0) {
            i -= 1;
            if ((g.v >> i) & 1 != 0) bits[at / 8] |= @as(u8, 0x80) >> @intCast(at & 7);
            at += 1;
        }
    }
    var stream: [6 + 8]u8 = .{ 8, 0, 0x00, 0x10, 0x01, 0x00 } ++ @as([8]u8, @splat(0));
    @memcpy(stream[6..], &bits);
    const r = try decompress(gpa, &stream, 0, 0);
    defer gpa.free(r.words);
    try std.testing.expectEqualSlices(u16, &.{ 0x10, 0x11, 0x100, 0x42 }, r.words);
    // The same stream with a base: every kind of word gets it.
    const b = try decompress(gpa, &stream, 0, 0x2000);
    defer gpa.free(b.words);
    try std.testing.expectEqualSlices(u16, &.{ 0x2010, 0x2011, 0x2100, 0x2042 }, b.words);
}

test "an inline word's flips are or-ed into the base, its palette added" {
    // nbits 8, one flag bit (`mask` 0x01: the horizontal flip, or 0x08: the palette's high bit).
    // Groups: 100 0000 + the flag bit 1 + byte 0x42 (one inline word), 1111111 (end).
    const gpa = std.testing.allocator;
    var bits: [6]u8 = @splat(0);
    var at: usize = 0;
    for ([_]struct { v: u32, n: u5 }{
        .{ .v = 0b1000000, .n = 7 }, .{ .v = 1, .n = 1 }, .{ .v = 0x42, .n = 8 }, .{ .v = 0b1111111, .n = 7 },
    }) |g| {
        var i: u5 = g.n;
        while (i > 0) {
            i -= 1;
            if ((g.v >> i) & 1 != 0) bits[at / 8] |= @as(u8, 0x80) >> @intCast(at & 7);
            at += 1;
        }
    }
    var stream: [6 + 6]u8 = .{ 8, 0x01, 0, 0, 0, 0 } ++ @as([6]u8, @splat(0));
    @memcpy(stream[6..], &bits);
    // ori.w #$800: a base with the flip already set keeps it.
    const flip = try decompress(gpa, &stream, 0, 0x0800);
    defer gpa.free(flip.words);
    try std.testing.expectEqualSlices(u16, &.{0x0842}, flip.words);
    // addi.w #$4000: the palette's high bit carries out of a base that has it.
    stream[1] = 0x08;
    const palette = try decompress(gpa, &stream, 0, 0xC000);
    defer gpa.free(palette.words);
    try std.testing.expectEqualSlices(u16, &.{0x0042}, palette.words);
}

test "a truncated stream is refused" {
    try std.testing.expectError(error.Truncated, decompress(std.testing.allocator, &.{ 8, 0, 0, 0 }, 0, 0));
}

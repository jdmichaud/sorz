//! The world's numbers (DESIGN.md P3, section 6): integer fixed-point at the original's
//! precision, never floating point. A place and a speed are 16.16: whole pixels and 1/65536 of a
//! pixel, in 32 bits, as the original keeps them; a speed is per logic tick. The arithmetic wraps
//! at 32 bits as the original's does, so that no value of the game stops the program.
//!
//! The axes of the world (`Vec3`):
//! - `x` across the round, growing to the right;
//! - `depth` on the ground, growing toward the player (lower on the screen);
//! - `height`, measured downward as the screen's lines are: a jump makes it smaller.
//!
//! An entity's place on the screen is `x` - the camera's x across, and `depth` / 2 + `height` -
//! the camera's y down, in whole pixels (`Vec3.screenY`).
const std = @import("std");

/// A 16.16 fixed-point number: `raw` / 65536.
pub const Fixed = packed struct(i32) {
    raw: i32,

    pub const frac_bits = 16;
    /// The units in a pixel.
    pub const unit: i32 = 1 << frac_bits;

    pub const zero: Fixed = .{ .raw = 0 };
    pub const one: Fixed = .{ .raw = unit };

    /// `n` whole pixels.
    pub fn pixels(n: i32) Fixed {
        return .{ .raw = n *% unit };
    }

    /// `units` / 65536 pixel: a value as the content and the traces write it.
    pub fn of(units: i32) Fixed {
        return .{ .raw = units };
    }

    /// `whole_pixels` pixels and `fraction` / 65536 more.
    pub fn parts(whole_pixels: i16, fraction: u16) Fixed {
        return .{ .raw = @as(i32, whole_pixels) * unit + fraction };
    }

    /// The whole pixels, rounded toward minus infinity: the original's whole word.
    pub fn whole(a: Fixed) i32 {
        return a.raw >> frac_bits;
    }

    /// The fraction of a pixel, in 1/65536.
    pub fn frac(a: Fixed) u16 {
        return @truncate(@as(u32, @bitCast(a.raw)));
    }

    pub fn add(a: Fixed, b: Fixed) Fixed {
        return .{ .raw = a.raw +% b.raw };
    }

    pub fn sub(a: Fixed, b: Fixed) Fixed {
        return .{ .raw = a.raw -% b.raw };
    }

    pub fn neg(a: Fixed) Fixed {
        return .{ .raw = 0 -% a.raw };
    }

    /// `a` times a whole number.
    pub fn times(a: Fixed, n: i32) Fixed {
        return .{ .raw = a.raw *% n };
    }

    /// `a` shifted right by `n` bits: halves, quarters, rounded toward minus infinity as the
    /// original's arithmetic shifts are.
    pub fn shr(a: Fixed, n: u5) Fixed {
        return .{ .raw = a.raw >> n };
    }

    /// `a` times `b`, the product's fraction cut toward minus infinity (64 bits inside, so that
    /// no part of the product is lost before the cut).
    pub fn mul(a: Fixed, b: Fixed) Fixed {
        const p = @as(i64, a.raw) * b.raw;
        return .{ .raw = @truncate(p >> frac_bits) };
    }

    pub fn abs(a: Fixed) Fixed {
        return if (a.raw < 0) a.neg() else a;
    }

    pub fn order(a: Fixed, b: Fixed) std.math.Order {
        return std.math.order(a.raw, b.raw);
    }

    pub fn lessThan(a: Fixed, b: Fixed) bool {
        return a.raw < b.raw;
    }

    pub fn eql(a: Fixed, b: Fixed) bool {
        return a.raw == b.raw;
    }

    pub fn min(a: Fixed, b: Fixed) Fixed {
        return if (b.raw < a.raw) b else a;
    }

    pub fn max(a: Fixed, b: Fixed) Fixed {
        return if (b.raw > a.raw) b else a;
    }

    /// `a` within `lo` to `hi`, both included.
    pub fn clamp(a: Fixed, lo: Fixed, hi: Fixed) Fixed {
        return a.max(lo).min(hi);
    }

    /// The sign of `a`: -1, 0 or 1.
    pub fn sign(a: Fixed) i32 {
        return std.math.sign(a.raw);
    }

    /// Writes the value in pixels with its fraction in 1/65536 (`-3+32768/65536`), exactly.
    pub fn format(a: Fixed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}", .{a.whole()});
        if (a.frac() != 0) try w.print("+{d}/65536", .{a.frac()});
    }
};

/// A place or a speed in the world: across, on the ground's depth, and in height.
pub const Vec3 = struct {
    x: Fixed = .zero,
    depth: Fixed = .zero,
    height: Fixed = .zero,

    pub const zero: Vec3 = .{};

    /// Whole pixels.
    pub fn pixels(x: i32, depth: i32, height: i32) Vec3 {
        return .{ .x = .pixels(x), .depth = .pixels(depth), .height = .pixels(height) };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x.add(b.x), .depth = a.depth.add(b.depth), .height = a.height.add(b.height) };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x.sub(b.x), .depth = a.depth.sub(b.depth), .height = a.height.sub(b.height) };
    }

    pub fn eql(a: Vec3, b: Vec3) bool {
        return a.x.eql(b.x) and a.depth.eql(b.depth) and a.height.eql(b.height);
    }

    /// The line of the round's picture the place is drawn on, before the camera: half the depth
    /// plus the height, in whole pixels (the halving rounds toward minus infinity).
    pub fn screenY(a: Vec3) i32 {
        return (a.depth.whole() >> 1) + a.height.whole();
    }
};

const testing = std.testing;

test "whole pixels and fractions" {
    const a = Fixed.parts(3, 0x8000);
    try testing.expectEqual(@as(i32, 3), a.whole());
    try testing.expectEqual(@as(u16, 0x8000), a.frac());
    try testing.expectEqual(@as(i32, 3 * 65536 + 32768), a.raw);
    // Negative values: the whole part rounds down, the fraction counts up from it.
    const b = Fixed.of(-1);
    try testing.expectEqual(@as(i32, -1), b.whole());
    try testing.expectEqual(@as(u16, 0xFFFF), b.frac());
    try testing.expectEqual(@as(i32, -2), Fixed.parts(-2, 0x4000).whole());
    try testing.expectEqual(Fixed.pixels(-5), Fixed.pixels(5).neg());
}

test "the arithmetic: sums, products and shifts, wrapping at 32 bits" {
    const speed = Fixed.of(0x18000); // 1.5 pixels a tick
    var x = Fixed.pixels(100);
    for (0..4) |_| x = x.add(speed);
    try testing.expectEqual(Fixed.pixels(106), x);
    try testing.expectEqual(Fixed.pixels(100), x.sub(speed.times(4)));
    try testing.expectEqual(Fixed.of(0xC000), speed.shr(1));
    // A shift rounds toward minus infinity, as an arithmetic shift does.
    try testing.expectEqual(@as(i32, -1), Fixed.of(-1).shr(4).raw);
    try testing.expectEqual(Fixed.of(0x24000), speed.mul(speed)); // 2.25
    try testing.expectEqual(Fixed.of(-0x24000), speed.mul(speed.neg()));
    try testing.expectEqual(Fixed.of(0x8000), Fixed.of(0x10000).mul(Fixed.of(0x8000)));
    // The original's 32 bits wrap; nothing traps.
    const top = Fixed.of(std.math.maxInt(i32));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), top.add(Fixed.of(1)).raw);
    try testing.expectEqual(Fixed.pixels(7), Fixed.pixels(9).clamp(.zero, .pixels(7)));
    try testing.expectEqual(Fixed.zero, Fixed.pixels(-9).clamp(.zero, .pixels(7)));
    try testing.expect(Fixed.pixels(-1).lessThan(.zero) and Fixed.pixels(3).abs().eql(Fixed.pixels(-3).abs()));
    try testing.expectEqual(@as(i32, -1), Fixed.of(-5).sign());
}

test "a place on the screen: half the depth plus the height" {
    const p: Vec3 = .{ .x = .pixels(40), .depth = .parts(81, 0xFFFF), .height = .pixels(-30) };
    try testing.expectEqual(@as(i32, 40 - 30), p.screenY());
    try testing.expectEqual(@as(i32, -1 + 10), (Vec3{ .depth = .pixels(-1), .height = .pixels(10) }).screenY());
    try testing.expect(p.add(Vec3.pixels(1, 0, 0)).sub(Vec3.pixels(1, 0, 0)).eql(p));
}

test "the format: whole pixels and the fraction, exactly" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("-3+32768/65536", try std.fmt.bufPrint(&buf, "{f}", .{Fixed.parts(-3, 0x8000)}));
    try testing.expectEqualStrings("12", try std.fmt.bufPrint(&buf, "{f}", .{Fixed.pixels(12)}));
}

/// A speed across and in depth, a logic tick.
pub const Heading = struct { x: Fixed, depth: Fixed };

/// The speed, `speed` pixels a tick along the direction from a place to another `dx` and
/// `ddepth` whole pixels away, as the original's objects head for a point: the longer of the two
/// ways takes the speed times the direction's cosine, the shorter times its sine, the slope (the
/// shorter over the longer) cut to 64ths and the speed to 1/256 pixel.
pub fn heading(dx: i32, ddepth: i32, speed: Fixed) Heading {
    const across: u32 = @abs(dx);
    const deep: u32 = @abs(ddepth);
    const depth_longer = across <= deep;
    const longer = if (depth_longer) deep else across;
    const shorter = if (depth_longer) across else deep;
    const slope: u32 = if (longer == 0) 0 else @min((shorter << 6) / longer, 63);
    const s: u32 = @as(u32, @bitCast(speed.raw)) >> 8 & std.math.maxInt(u16);
    var along_longer: u32 = s;
    var along_shorter: u32 = 0;
    if (slope != 0) {
        along_shorter = (slopes[slope].sine * s) >> 16;
        along_longer = (slopes[slope].cosine * s) >> 16;
    }
    var x: i32 = @intCast((if (depth_longer) along_shorter else along_longer) << 8);
    var d: i32 = @intCast((if (depth_longer) along_longer else along_shorter) << 8);
    if (dx < 0) x = -x;
    if (ddepth < 0) d = -d;
    return .{ .x = .of(x), .depth = .of(d) };
}

/// The speed a heading takes at the options' LEVEL `level` (0, the easiest, to 3), as the
/// original's enemies head for a point: at the easiest, `easy_least` pixels a tick or
/// more go `easy_less` slower (the extractor checks both against the ROM's).
pub fn levelSpeed(level: u2, speed: Fixed) Fixed {
    const s = @as(u32, @bitCast(speed.raw)) >> 8 & std.math.maxInt(u16);
    if (level != 0 or s < easy_least.raw >> 8) return speed;
    return speed.sub(easy_less);
}

pub const easy_least: Fixed = .pixels(3);
pub const easy_less: Fixed = .pixels(1);

test "a heading at the easiest level goes a pixel slower from 3 pixels a tick" {
    try std.testing.expectEqual(Fixed.of(229376), levelSpeed(0, .of(294912)));
    try std.testing.expectEqual(Fixed.of(196608 - 65536), levelSpeed(0, .of(196608)));
    try std.testing.expectEqual(Fixed.of(196607), levelSpeed(0, .of(196607)));
    try std.testing.expectEqual(Fixed.of(294912), levelSpeed(1, .of(294912)));
}

/// The sine and the cosine of each slope of 64ths, in 1/65536 and rounded: the original's table
/// (the extractor checks it against the ROM's).
pub const slopes = blk: {
    var out: [64]struct { sine: u32, cosine: u32 } = undefined;
    for (&out, 0..) |*o, k| o.* = .{ .sine = slopeComponent(@intCast(k), @intCast(k)), .cosine = slopeComponent(@intCast(k), 64) };
    break :blk out;
};

/// 65536 times `along` over the hypotenuse of the slope `k`/64, rounded: the integer `r` with
/// (2r - 1)^2 n <= 4 * 65536^2 * along^2 < (2r + 1)^2 n, n = k^2 + 64^2.
fn slopeComponent(comptime k: u64, comptime along: u64) u32 {
    @setEvalBranchQuota(100_000);
    const n: u64 = k * k + 64 * 64;
    const t: u64 = 4 * 65536 * 65536 * along * along;
    var r: u64 = (std.math.sqrt(t / n) + 1) / 2;
    while ((2 * r + 1) * (2 * r + 1) * n <= t) r += 1;
    while (r > 0 and (2 * r - 1) * (2 * r - 1) * n > t) r -= 1;
    return @intCast(r);
}

test "a heading: along an axis the whole speed; slanted, the original's components" {
    const three = Fixed.pixels(3);
    try testing.expectEqual(Heading{ .x = .pixels(-3), .depth = .zero }, heading(-40, 0, three));
    try testing.expectEqual(Heading{ .x = .zero, .depth = .pixels(3) }, heading(0, 12, three));
    // The original's table at slope 1: 1024 and 65528 in 1/65536.
    try testing.expectEqual(@as(u32, 1024), slopes[1].sine);
    try testing.expectEqual(@as(u32, 65528), slopes[1].cosine);
    try testing.expectEqual(@as(u32, 45975), slopes[63].sine);
    // Slope 32 (twice as far across): 3 * 58617 / 65536 and 3 * 29309 / 65536, in 1/256.
    const h = heading(64, -32, three);
    try testing.expectEqual(@as(i32, (58617 * 0x300 >> 16) << 8), h.x.raw);
    try testing.expectEqual(@as(i32, -((29309 * 0x300 >> 16) << 8)), h.depth.raw);
}

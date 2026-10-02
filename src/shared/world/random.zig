//! The random generator (DESIGN.md P3, section 6): the original's algorithm, one value for the
//! whole game, advanced only when the game draws from it.
//!
//! The state is a 32-bit number. A draw multiplies it by 41 (wrapping at 32 bits); the new state
//! keeps the product's low half, with the sum of the product's two halves (wrapping at 16 bits)
//! above it, and that sum is the number drawn. A state of zero, which is what the game has at
//! power-on, stands for the original's starting state (`power_on_state`); no draw ever gives zero
//! back, since 41 is odd.
//!
//! Each draw is named for what it decides (`rng.draw(.galsia_attack_choice, log)`), so that the
//! order of the draws can be read, traced (the `rng` event of the semantic traces) and, for exact,
//! made the original's.
const std = @import("std");

/// The type of a draw's name: an enum literal (`.galsia_attack_choice`).
pub const Purpose = @TypeOf(.purpose);

/// The draws of a logic tick, for the trace: how many, and the first `kept` values with their
/// names. It is the tick's output, not the game's state.
pub const Draws = struct {
    pub const kept = 16;

    count: u32 = 0,
    values: [kept]u16 = undefined,
    purposes: [kept][]const u8 = undefined,
    /// The state was set rather than drawn (a scenario's start) at this tick.
    reseeded: bool = false,

    pub fn note(self: *Draws, purpose: []const u8, value: u16) void {
        if (self.count < kept) {
            self.values[self.count] = value;
            self.purposes[self.count] = purpose;
        }
        self.count +|= 1;
    }

    pub fn clear(self: *Draws) void {
        self.* = .{};
    }
};

pub const Random = struct {
    /// The state; zero at power-on.
    state: u32 = 0,

    /// The state the first draw starts from when the state is zero: the original's.
    pub const power_on_state: u32 = 711800410;

    /// The next number, unnamed: for the generator's own tests and tools. The game draws with
    /// `draw`.
    pub fn next(self: *Random) u16 {
        const s = if (self.state != 0) self.state else power_on_state;
        const product = s *% 41;
        const low: u16 = @truncate(product);
        const high: u16 = @truncate(product >> 16);
        const sum = low +% high;
        self.state = @as(u32, sum) << 16 | low;
        return sum;
    }

    /// A number drawn for `purpose`, noted in `log` (the tick's draws) when there is one.
    pub fn draw(self: *Random, comptime purpose: Purpose, log: ?*Draws) u16 {
        const v = self.next();
        if (log) |l| l.note(@tagName(purpose), v);
        return v;
    }

    /// One of `n` values, 0 to `n` - 1, for `purpose`: the low bits of a draw, as the original
    /// takes them (`n` is a power of two).
    pub fn pick(self: *Random, comptime purpose: Purpose, comptime n: u16, log: ?*Draws) u16 {
        comptime std.debug.assert(std.math.isPowerOfTwo(n));
        return self.draw(purpose, log) & (n - 1);
    }

    /// Sets the state (a scenario that starts from a recorded state), noted in `log`.
    pub fn reseed(self: *Random, state: u32, log: ?*Draws) void {
        self.state = state;
        if (log) |l| l.reseeded = true;
    }
};

const testing = std.testing;

test "the sequence from power-on is the original's" {
    // The original's routine run from power-on, each draw on the state the last one left
    // (sor-remaster's tests/vectors/random.vec, chain s00, recorded on the original's ROM): the
    // number drawn is the low half of the routine's result, the state its stored long.
    const drawn = [_]u16{
        0x7FE7, 0x6115, 0x388B, 0x9BF8, 0xA878, 0xCB8D, 0xF300, 0x37E8, 0x431E, 0x6354, 0x1718,
        0x26F9, 0xD61D, 0xA977, 0x4FE8, 0xCF89, 0xC65B, 0xC6A3, 0x2125, 0x4993, 0xEB5D, 0x3F24,
        0xBB24, 0x52B7, 0xA347, 0x26E9, 0x4EDB, 0xC230, 0x66DF,
    };
    const states = [_]u32{ 0x7FE7B46A, 0x6115E4FA, 0x388BAC0A, 0x9BF88D9A };
    var r: Random = .{};
    for (drawn, 0..) |want, i| {
        try testing.expectEqual(want, r.next());
        if (i < states.len) try testing.expectEqual(states[i], r.state);
    }
    try testing.expectEqual(@as(u32, 0x2A6D365A), Random.power_on_state);
}

test "the original's edge cases: odd states and their sums" {
    // Chains s02 to s09 of the same vectors: the state before, the number drawn, the state after.
    const cases = [_]struct { before: u32, drawn: u16, after: u32 }{
        .{ .before = 0x2A6D365A, .drawn = 0x7FE7, .after = 0x7FE7B46A },
        .{ .before = 0x00000001, .drawn = 0x0029, .after = 0x00290029 },
        .{ .before = 0xFFFFFFFF, .drawn = 0xFFD6, .after = 0xFFD6FFD7 },
        .{ .before = 0x80000000, .drawn = 0x8000, .after = 0x80000000 },
        .{ .before = 0x7FFFFFFF, .drawn = 0x7FD6, .after = 0x7FD6FFD7 },
        .{ .before = 0x0000FFFF, .drawn = 0xFFFF, .after = 0xFFFFFFD7 },
        .{ .before = 0xFFFF0000, .drawn = 0xFFD7, .after = 0xFFD70000 },
        .{ .before = 0x00010000, .drawn = 0x0029, .after = 0x00290000 },
        .{ .before = 0xFFFF0001, .drawn = 0x0000, .after = 0x00000029 },
    };
    for (cases) |c| {
        var r: Random = .{ .state = c.before };
        try testing.expectEqual(c.drawn, r.next());
        try testing.expectEqual(c.after, r.state);
    }
}

test "named draws are noted for the trace, in order" {
    var r: Random = .{};
    var log: Draws = .{};
    try testing.expectEqual(@as(u16, 0x7FE7), r.draw(.test_first, &log));
    try testing.expectEqual(@as(u16, 0x6115 & 7), r.pick(.test_second, 8, &log));
    _ = r.draw(.unlogged, null);
    try testing.expectEqual(@as(u32, 2), log.count);
    try testing.expectEqualStrings("test_first", log.purposes[0]);
    try testing.expectEqualStrings("test_second", log.purposes[1]);
    try testing.expectEqual(@as(u16, 0x6115), log.values[1]);
    for (0..40) |_| _ = r.draw(.many, &log);
    try testing.expectEqual(@as(u32, 42), log.count);
    r.reseed(0, &log);
    try testing.expect(log.reseeded);
    try testing.expectEqual(@as(u16, 0x7FE7), r.next());
    log.clear();
    try testing.expectEqual(@as(u32, 0), log.count);
}

//! The canonical form of a state (DESIGN.md 6): what the game is, and nothing else, as a stream of
//! bits. Two states are the same exactly when their forms are: `hash` identifies a state for the
//! tests and for network play (DESIGN.md 9), `read` gives back the state a form was written from
//! (network play's join carries a game this way), and `firstDifference` names the first field
//! whose values differ, as the two peers of a session do when their states part.
//!
//! Each named field is written in the order of its declaration, with as many bits as its values
//! need, the low bit first, packed one after the other; the last byte is padded with zeros:
//! - a boolean is a bit; an integer its bits (its two's complement, signed); an enum the number of
//!   its value among its values, in the bits their count needs (a non-exhaustive one: its
//!   integer); a packed struct its fields;
//! - a struct and an array, their parts in order;
//! - an optional, a bit (1 with a value), then the value when there is one;
//! - a tagged union, its tag, then its active payload only.
//!
//! A **pool** is an array whose places hold things or are free (the world's entities): its
//! element type says so with a namespace `canonical_pool` (`inUse`, and what a free place keeps:
//! `Kept`, `kept`, `free`). Each place is a bit, 1 in use: then its thing; else a bit, 1 when what
//! the free place keeps is not the default (an entity's place: its generation), then that. So the
//! form carries the things there are, at their places (which keep the order the world updates
//! them in), and not the room for them.
//!
//! The form's length follows the state: `maxSize` bounds it. A form has one state and a state one
//! form; `read` refuses bytes that no state writes (an enum's number past its values, a free place
//! that keeps its default, bits past the end), so that a game read from its form goes on exactly
//! as the one it was written from.
const std = @import("std");

// --- the sizes ------------------------------------------------------------------------------------

/// The most bits of `T`'s form.
pub fn maxBits(comptime T: type) usize {
    @setEvalBranchQuota(1_000_000);
    return comptime switch (@typeInfo(T)) {
        .void => 0,
        .bool => 1,
        .int => |i| i.bits,
        .@"enum" => enumBits(T),
        .@"struct" => |s| blk: {
            var n: usize = 0;
            for (s.field_types) |F| n += maxBits(F);
            break :blk n;
        },
        .array => |a| if (isPool(a.child))
            a.len * (1 + @as(usize, @max(maxBits(a.child), 1 + maxBits(a.child.canonical_pool.Kept))))
        else
            a.len * maxBits(a.child),
        .optional => |o| 1 + maxBits(o.child),
        .@"union" => |u| blk: {
            const Tag = u.tag_type orelse @compileError("an untagged union has no canonical form: " ++ @typeName(T));
            var largest: usize = 0;
            for (u.field_types) |F| largest = @as(usize, @max(largest, maxBits(F)));
            break :blk enumBits(Tag) + largest;
        },
        else => @compileError("no canonical form for " ++ @typeName(T)),
    };
}

/// The most bytes of `T`'s form: room for any.
pub fn maxSize(comptime T: type) usize {
    return (maxBits(T) + 7) / 8;
}

/// The bits of an enum: the number of its value among its values (exhaustive), or its integer.
fn enumBits(comptime E: type) usize {
    const e = @typeInfo(E).@"enum";
    if (e.mode == .nonexhaustive) return @typeInfo(e.tag_type).int.bits;
    if (e.field_names.len <= 1) return 0;
    return std.math.log2_int_ceil(usize, e.field_names.len);
}

/// Whether an enum's values are its numbers 0, 1, 2...: its value is then its number.
fn dense(comptime E: type) bool {
    const e = @typeInfo(E).@"enum";
    for (e.field_values, 0..) |v, i| if (v != i) return false;
    return true;
}

fn isPool(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "canonical_pool"),
        else => false,
    };
}

/// The bits a value's number takes in an enum's form.
fn enumNumber(comptime E: type, value: E) u64 {
    const e = @typeInfo(E).@"enum";
    const Bits = @Int(.unsigned, @typeInfo(e.tag_type).int.bits);
    if (e.mode == .nonexhaustive or comptime dense(E)) return @as(Bits, @bitCast(@backingInt(value)));
    inline for (e.field_names, 0..) |name, i| if (value == @field(E, name)) return i;
    unreachable;
}

/// The value of an enum's number in its form, or null for a number past its values.
fn enumValue(comptime E: type, number: u64) ?E {
    const e = @typeInfo(E).@"enum";
    const Tag = e.tag_type;
    const Bits = @Int(.unsigned, @typeInfo(Tag).int.bits);
    if (e.mode == .nonexhaustive) return @fromBackingInt(@as(Tag, @bitCast(@as(Bits, @intCast(number)))));
    if (number >= e.field_names.len) return null;
    if (comptime dense(E)) return @fromBackingInt(@as(Tag, @intCast(number)));
    return std.enums.values(E)[@intCast(number)];
}

// --- writing --------------------------------------------------------------------------------------

/// Bits, the low first, into bytes (`out`, when there is one) and into the form's hash.
const BitWriter = struct {
    out: ?[]u8,
    hasher: std.hash.Fnv1a_64 = .init(),
    byte: u8 = 0,
    fill: u4 = 0,
    len: usize = 0,

    fn put(w: *BitWriter, value: u64, bits: usize) void {
        var v = value;
        var n = bits;
        while (n > 0) {
            const room: usize = 8 - @as(usize, w.fill);
            const k = @min(room, n);
            const part: u8 = @truncate(v & ((@as(u64, 1) << @intCast(k)) - 1));
            w.byte |= part << @intCast(w.fill);
            w.fill += @intCast(k);
            n -= k;
            v >>= @intCast(k);
            if (w.fill == 8) w.emit();
        }
    }

    fn emit(w: *BitWriter) void {
        if (w.out) |o| o[w.len] = w.byte;
        w.hasher.update(&.{w.byte});
        w.len += 1;
        w.byte = 0;
        w.fill = 0;
    }

    fn finish(w: *BitWriter) void {
        if (w.fill != 0) w.emit();
    }
};

/// Writes the form of `value` at the start of `out` (at least `maxSize(T)` bytes), and returns it.
pub fn write(comptime T: type, value: *const T, out: []u8) []u8 {
    std.debug.assert(out.len >= maxSize(T));
    var w: BitWriter = .{ .out = out };
    put(T, value, &w);
    w.finish();
    return out[0..w.len];
}

/// The hash of `value`'s form (FNV-1a, 64 bits), made without the form.
pub fn hash(comptime T: type, value: *const T) u64 {
    var w: BitWriter = .{ .out = null };
    put(T, value, &w);
    w.finish();
    return w.hasher.final();
}

/// The bytes of `value`'s form.
pub fn sizeOf(comptime T: type, value: *const T) usize {
    var w: BitWriter = .{ .out = null };
    put(T, value, &w);
    w.finish();
    return w.len;
}

fn put(comptime T: type, value: *const T, w: *BitWriter) void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => w.put(@intFromBool(value.*), 1),
        .int => |i| w.put(@as(@Int(.unsigned, i.bits), @bitCast(value.*)), i.bits),
        .@"enum" => w.put(enumNumber(T, value.*), enumBits(T)),
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, F| {
            // A packed struct's fields have no address of their own: each by its value.
            const field = if (s.layout == .@"packed") &@as(F, @field(value.*, name)) else &@field(value.*, name);
            put(F, field, w);
        },
        .array => |a| if (comptime isPool(a.child)) {
            const P = a.child.canonical_pool;
            for (value) |*place| {
                if (P.inUse(place)) {
                    w.put(1, 1);
                    put(a.child, place, w);
                    continue;
                }
                w.put(0, 1);
                const kept = P.kept(place);
                if (std.meta.eql(kept, @as(P.Kept, .{}))) {
                    w.put(0, 1);
                } else {
                    w.put(1, 1);
                    put(P.Kept, &kept, w);
                }
            }
        } else for (value) |*item| put(a.child, item, w),
        .optional => |o| if (value.*) |*v| {
            w.put(1, 1);
            put(o.child, v, w);
        } else w.put(0, 1),
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            w.put(enumNumber(Tag, std.meta.activeTag(value.*)), enumBits(Tag));
            switch (value.*) {
                inline else => |*payload| put(@TypeOf(payload.*), payload, w),
            }
        },
        else => comptime unreachable,
    }
}

// --- reading --------------------------------------------------------------------------------------

pub const ReadError = error{Malformed};

/// Bits from a form, the low first.
const BitReader = struct {
    form: []const u8,
    /// The bit to read next.
    at: usize = 0,

    fn get(r: *BitReader, bits: usize) ReadError!u64 {
        if (bits == 0) return 0;
        if (r.at + bits > r.form.len * 8) return error.Malformed;
        var v: u64 = 0;
        var got: usize = 0;
        while (got < bits) {
            const byte = r.form[r.at / 8];
            const shift: u3 = @intCast(r.at % 8);
            const k = @min(8 - @as(usize, shift), bits - got);
            const part: u64 = (byte >> shift) & ((@as(u16, 1) << @intCast(k)) - 1);
            v |= part << @intCast(got);
            got += k;
            r.at += k;
        }
        return v;
    }

    /// The form ends here: the last byte's padding is zeros, and nothing follows it.
    fn end(r: *const BitReader) ReadError!void {
        if ((r.at + 7) / 8 != r.form.len) return error.Malformed;
        if (r.at % 8 != 0 and r.form[r.at / 8] >> @intCast(r.at % 8) != 0) return error.Malformed;
    }
};

/// Reads into `out` the state whose form is `form`; a form that no state writes is `Malformed`
/// (`out` then holds part of it).
pub fn read(comptime T: type, form: []const u8, out: *T) ReadError!void {
    var r: BitReader = .{ .form = form };
    try get(T, &r, out);
    try r.end();
}

fn get(comptime T: type, r: *BitReader, out: *T) ReadError!void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => out.* = try r.get(1) == 1,
        .int => |i| out.* = @bitCast(@as(@Int(.unsigned, i.bits), @intCast(try r.get(i.bits)))),
        .@"enum" => out.* = enumValue(T, try r.get(enumBits(T))) orelse return error.Malformed,
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, F| {
            if (s.layout == .@"packed") {
                var field: F = undefined;
                try get(F, r, &field);
                @field(out.*, name) = field;
            } else try get(F, r, &@field(out.*, name));
        },
        .array => |a| if (comptime isPool(a.child)) {
            const P = a.child.canonical_pool;
            for (out) |*place| {
                if (try r.get(1) == 1) {
                    try get(a.child, r, place);
                    if (!P.inUse(place)) return error.Malformed;
                    continue;
                }
                var kept: P.Kept = .{};
                if (try r.get(1) == 1) {
                    try get(P.Kept, r, &kept);
                    // A free place that keeps its default is written without it.
                    if (std.meta.eql(kept, @as(P.Kept, .{}))) return error.Malformed;
                }
                place.* = P.free(kept);
            }
        } else for (out) |*item| try get(a.child, r, item),
        .optional => |o| if (try r.get(1) == 1) {
            out.* = @as(o.child, undefined);
            try get(o.child, r, &out.*.?);
        } else {
            out.* = null;
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            const tag = enumValue(Tag, try r.get(enumBits(Tag))) orelse return error.Malformed;
            switch (tag) {
                inline else => |t| {
                    const name = @tagName(t);
                    out.* = @unionInit(T, name, undefined);
                    try get(@FieldType(T, name), r, &@field(out.*, name));
                },
            }
        },
        else => comptime unreachable,
    }
}

// --- the first difference -------------------------------------------------------------------------

/// The first field whose values differ between two forms of one type.
pub const Difference = struct {
    name_buf: [96]u8 = undefined,
    name_len: u8 = 0,
    /// The field's place in our form, in bits, and its width in bits.
    offset: u32,
    width: u32,
    /// The field's value in each form (its first 64 bits).
    ours: u64,
    theirs: u64,

    pub fn name(d: *const Difference) []const u8 {
        return d.name_buf[0..d.name_len];
    }

    pub fn format(d: Difference, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} (bit {d}, {d} bit{s}): ours {d}, theirs {d}", .{
            d.name(), d.offset, d.width, if (d.width == 1) "" else "s", d.ours, d.theirs,
        });
    }
};

/// Names the first difference between two forms of `T`; null when they are the same.
pub const DiffFn = *const fn (ours: []const u8, theirs: []const u8) ?Difference;

pub fn diffFn(comptime T: type) DiffFn {
    return struct {
        fn diff(ours: []const u8, theirs: []const u8) ?Difference {
            return firstDifference(T, ours, theirs);
        }
    }.diff;
}

/// The first field of `T` whose values differ between `ours` and `theirs`, two forms of `T`, by
/// its path (`scenes.base.round.play.world.entities[5].position.x`): the two forms are read side
/// by side, field by field, so a field is found wherever the things before it put it. A union's
/// tag or a pool's place that differs is named by the union's or the place's path; an optional's
/// presence by the optional's. Null when the forms are the same. Forms that end before the
/// field, or are not `T`'s, are named `(the end)` at the bit where they part.
pub fn firstDifference(comptime T: type, ours: []const u8, theirs: []const u8) ?Difference {
    if (std.mem.eql(u8, ours, theirs)) return null;
    var walk: Walk = .{ .ours = .{ .form = ours }, .theirs = .{ .form = theirs } };
    if (walk.visit(T)) |found| {
        if (found) return walk.found;
    } else |_| return walk.ended();
    // The same fields: one form goes on past the other's end.
    return walk.ended();
}

const Walk = struct {
    ours: BitReader,
    theirs: BitReader,
    path: [96]u8 = undefined,
    len: usize = 0,
    found: ?Difference = null,

    /// Appends `text` to the path (cut at its end when it is too long); returns the length before.
    fn push(w: *Walk, text: []const u8) usize {
        const before = w.len;
        const n = @min(text.len, w.path.len - w.len);
        @memcpy(w.path[w.len..][0..n], text[0..n]);
        w.len += n;
        return before;
    }

    fn named(w: *const Walk, d: *Difference) void {
        @memcpy(d.name_buf[0..w.len], w.path[0..w.len]);
        d.name_len = @intCast(w.len);
    }

    /// The next `bits` of both forms: true when they differ (then `found`); the value read in
    /// each goes to `value`.
    fn leaf(w: *Walk, bits: usize, value: *[2]u64) ReadError!bool {
        const at = w.ours.at;
        value[0] = try w.ours.get(bits);
        value[1] = try w.theirs.get(bits);
        if (value[0] == value[1]) return false;
        var d: Difference = .{ .offset = @intCast(at), .width = @intCast(bits), .ours = value[0], .theirs = value[1] };
        w.named(&d);
        w.found = d;
        return true;
    }

    /// The forms part where one ends or is not `T`'s: named by the place.
    fn ended(w: *Walk) Difference {
        var d: Difference = .{ .offset = @intCast(@min(w.ours.at, w.theirs.at)), .width = 0, .ours = w.ours.form.len, .theirs = w.theirs.form.len };
        const text = "(the end)";
        const before = w.len;
        _ = w.push(if (w.len == 0) text else " " ++ text);
        w.named(&d);
        w.len = before;
        return d;
    }

    fn visit(w: *Walk, comptime T: type) ReadError!bool {
        var v: [2]u64 = undefined;
        switch (@typeInfo(T)) {
            .void => return false,
            .bool => return w.leaf(1, &v),
            .int => |i| return w.leaf(i.bits, &v),
            .@"enum" => return w.leaf(enumBits(T), &v),
            .@"struct" => |s| {
                // A packed struct of one field (a fixed-point number) is named as a whole.
                if (s.layout == .@"packed" and s.field_names.len == 1) return w.visit(s.field_types[0]);
                inline for (s.field_names, s.field_types) |name, F| {
                    const before = w.push(if (w.len == 0) name else "." ++ name);
                    if (try w.visit(F)) return true;
                    w.len = before;
                }
                return false;
            },
            .array => |a| {
                for (0..a.len) |i| {
                    var buf: [24]u8 = undefined;
                    const before = w.push(std.fmt.bufPrint(&buf, "[{d}]", .{i}) catch unreachable);
                    if (comptime isPool(a.child)) {
                        // The place: in use or free, then its thing or what it keeps.
                        if (try w.leaf(1, &v)) return true;
                        if (v[0] == 1) {
                            if (try w.visit(a.child)) return true;
                        } else {
                            if (try w.leaf(1, &v)) return true;
                            if (v[0] == 1) {
                                const kept = w.push(".(free)");
                                if (try w.visit(a.child.canonical_pool.Kept)) return true;
                                w.len = kept;
                            }
                        }
                    } else if (try w.visit(a.child)) return true;
                    w.len = before;
                }
                return false;
            },
            .optional => |o| {
                // The flag is the optional's own name; its value follows it.
                if (try w.leaf(1, &v)) return true;
                if (v[0] == 0) return false;
                const before = w.push(".?");
                if (try w.visit(o.child)) return true;
                w.len = before;
                return false;
            },
            .@"union" => |u| {
                // The tag is the union's own name; the payload follows it, named by the tag, which
                // is the same in both forms once the tag did not differ.
                const Tag = u.tag_type.?;
                if (try w.leaf(enumBits(Tag), &v)) return true;
                const tag = enumValue(Tag, v[0]) orelse return error.Malformed;
                switch (tag) {
                    inline else => |t| {
                        const name = @tagName(t);
                        const before = w.push(if (w.len == 0) name else "." ++ name);
                        if (try w.visit(@FieldType(T, name))) return true;
                        w.len = before;
                    },
                }
                return false;
            },
            else => comptime unreachable,
        }
    }
};

// --- tests ----------------------------------------------------------------------------------------

const testing = std.testing;

const Kind = enum(u8) { none, walker, runner };
const Flags = packed struct(u8) { a: bool = false, b: bool = false, rest: u6 = 0 };
const Item = union(enum) { empty, count: u16, place: struct { x: i16, y: i16 } };
const Sample = struct {
    tick: u32 = 1 << 24 | 2 << 16 | 3 << 8 | 4,
    on: bool = true,
    kind: Kind = .runner,
    flags: Flags = .{ .b = true },
    small: u3 = 5,
    signed: i16 = -2,
    points: [2]struct { x: u16 = 0, y: u16 = 0 } = .{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } },
    maybe: ?u16 = null,
    items: [2]Item = .{ .{ .count = 7 }, .empty },
};

/// A thing of a pool: free when its kind is none; a free place keeps its generation.
const Thing = struct {
    generation: u8 = 0,
    kind: Kind = .none,
    x: i16 = 0,

    pub const canonical_pool = struct {
        pub fn inUse(t: *const Thing) bool {
            return t.kind != .none;
        }
        pub const Kept = struct { generation: u8 = 0 };
        pub fn kept(t: *const Thing) Kept {
            return .{ .generation = t.generation };
        }
        pub fn free(k: Kept) Thing {
            return .{ .generation = k.generation };
        }
    };
};

const Pooled = struct {
    count: u8 = 0,
    things: [4]Thing = @splat(.{}),
};

fn roundTrip(comptime T: type, value: *const T) !void {
    var buf: [maxSize(T)]u8 = undefined;
    const form = write(T, value, &buf);
    var back: T = undefined;
    try read(T, form, &back);
    try testing.expect(std.meta.eql(value.*, back));
    var again: [maxSize(T)]u8 = undefined;
    try testing.expectEqualSlices(u8, form, write(T, &back, &again));
    try testing.expectEqual(hash(T, value), std.hash.Fnv1a_64.hash(form));
    try testing.expectEqual(form.len, sizeOf(T, value));
}

test "a state's form: its fields in order, in the bits their values need, packed" {
    // 32 + 1 + 2 (three kinds) + 8 + 3 + 16 + 64 + 17 (the flag and the value) + 2 * (2 + the
    // largest payload).
    try testing.expectEqual(@as(usize, 32 + 1 + 2 + 8 + 3 + 16 + 64 + 17 + 2 * (2 + 32)), maxBits(Sample));
    var buf: [maxSize(Sample)]u8 = undefined;
    const s: Sample = .{};
    const bytes = write(Sample, &s, &buf);
    // The tick's four bytes; then, bit by bit from the low: on 1, kind 2 (10), flags 0b00000010,
    // small 101, signed -2 (16 bits)...
    try testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, bytes[0..4]);
    try testing.expectEqual(@as(u8, 0b0_00010_10_1), bytes[4]);
    // The empty item is its tag alone: 147 bits, 19 bytes.
    try testing.expectEqual(@as(usize, (32 + 1 + 2 + 8 + 3 + 16 + 64 + 1 + 2 + 16 + 2 + 7) / 8), bytes.len);
    try roundTrip(Sample, &s);
    var other = s;
    other.maybe = 9;
    other.items[1] = .{ .place = .{ .x = -1, .y = 2 } };
    try roundTrip(Sample, &other);
    try testing.expect(hash(Sample, &s) != hash(Sample, &other));
    try testing.expectEqual(hash(Sample, &s), hash(Sample, &Sample{}));
}

test "a pool carries its things at their places, and of its free places what they keep" {
    var p: Pooled = .{ .count = 2 };
    try testing.expectEqual(@as(usize, 8 + 4 * (1 + @max(8 + 2 + 16, 1 + 8))), maxBits(Pooled));
    // Four free places at their default: a bit each and a bit for nothing kept.
    try testing.expectEqual(@as(usize, 2), sizeOf(Pooled, &p));
    try roundTrip(Pooled, &p);
    p.things[2] = .{ .generation = 3, .kind = .walker, .x = -5 };
    p.things[1] = Thing.canonical_pool.free(.{ .generation = 9 });
    try roundTrip(Pooled, &p);
    // A form whose free place keeps its default, or whose place in use reads free, is no state's.
    var buf: [maxSize(Pooled)]u8 = undefined;
    var back: Pooled = undefined;
    const empty = write(Pooled, &Pooled{}, &buf);
    const kept_default = [_]u8{ empty[0], 0b0000_0010, 0 };
    try testing.expectError(error.Malformed, read(Pooled, &kept_default, &back));
    const in_use_free = [_]u8{ empty[0], 0b0000_0001, 0, 0, 0 };
    try testing.expectError(error.Malformed, read(Pooled, &in_use_free, &back));
}

test "a form that no state writes is refused" {
    var buf: [maxSize(Sample)]u8 = undefined;
    const form = write(Sample, &Sample{}, &buf);
    var back: Sample = undefined;
    // Cut short, one byte too many, padding that is not zero.
    try testing.expectError(error.Malformed, read(Sample, form[0 .. form.len - 1], &back));
    var longer: [maxSize(Sample) + 1]u8 = undefined;
    @memcpy(longer[0..form.len], form);
    longer[form.len] = 0;
    try testing.expectError(error.Malformed, read(Sample, longer[0 .. form.len + 1], &back));
    var padded = buf;
    padded[form.len - 1] |= 0x80;
    try testing.expectError(error.Malformed, read(Sample, padded[0..form.len], &back));
    // The kind's number past its three values.
    var odd = buf;
    odd[4] |= 0b0000_0110;
    try testing.expectError(error.Malformed, read(Sample, odd[0..form.len], &back));
}

test "the first differing field is named by its path, wherever the fields before put it" {
    var a_buf: [maxSize(Sample)]u8 = undefined;
    var b_buf: [maxSize(Sample)]u8 = undefined;
    const a: Sample = .{};
    var b = a;
    const ours = write(Sample, &a, &a_buf);
    try testing.expectEqual(@as(?Difference, null), firstDifference(Sample, ours, write(Sample, &b, &b_buf)));

    b.points[1].y = 40;
    b.maybe = 3;
    var d = firstDifference(Sample, ours, write(Sample, &b, &b_buf)).?;
    try testing.expectEqualStrings("points[1].y", d.name());
    try testing.expectEqual(@as(u32, 32 + 1 + 2 + 8 + 3 + 16 + 48), d.offset);
    try testing.expectEqual(@as(u64, 4), d.ours);
    try testing.expectEqual(@as(u64, 40), d.theirs);
    var text: [96]u8 = undefined;
    try testing.expectEqualStrings("points[1].y (bit 110, 16 bits): ours 4, theirs 40", try std.fmt.bufPrint(&text, "{f}", .{d}));

    b = a;
    b.maybe = 3;
    try testing.expectEqualStrings("maybe", firstDifference(Sample, ours, write(Sample, &b, &b_buf)).?.name());
    // A field after a field of another length: found all the same.
    b.items[1] = .{ .count = 1 };
    var c = a;
    c.maybe = 3;
    const theirs_c = write(Sample, &c, &a_buf);
    try testing.expectEqualStrings("items[1]", firstDifference(Sample, theirs_c, write(Sample, &b, &b_buf)).?.name());
    b = a;
    b.items[0] = .{ .count = 8 };
    const ours_again = write(Sample, &a, &a_buf);
    try testing.expectEqualStrings("items[0].count", firstDifference(Sample, ours_again, write(Sample, &b, &b_buf)).?.name());
    b.items[0] = .empty;
    try testing.expectEqualStrings("items[0]", firstDifference(Sample, ours_again, write(Sample, &b, &b_buf)).?.name());
    b = a;
    b.flags.a = true;
    d = diffFn(Sample)(ours_again, write(Sample, &b, &b_buf)).?;
    try testing.expectEqualStrings("flags.a", d.name());
    try testing.expectEqual(@as(u64, 1), d.theirs);
    // A form cut short: named where it ends.
    try testing.expectEqualStrings("tick (the end)", firstDifference(Sample, ours_again, ours_again[0..2]).?.name());
}

test "the places of a pool are named, in use or free, and their things' fields" {
    var a_buf: [maxSize(Pooled)]u8 = undefined;
    var b_buf: [maxSize(Pooled)]u8 = undefined;
    var a: Pooled = .{};
    a.things[1] = .{ .generation = 1, .kind = .walker, .x = 3 };
    var b = a;
    b.things[1].x = 4;
    const ours = write(Pooled, &a, &a_buf);
    try testing.expectEqualStrings("things[1].x", firstDifference(Pooled, ours, write(Pooled, &b, &b_buf)).?.name());
    b = a;
    b.things[0] = .{ .kind = .runner };
    try testing.expectEqualStrings("things[0]", firstDifference(Pooled, ours, write(Pooled, &b, &b_buf)).?.name());
    b = a;
    b.things[3] = Thing.canonical_pool.free(.{ .generation = 2 });
    try testing.expectEqualStrings("things[3]", firstDifference(Pooled, ours, write(Pooled, &b, &b_buf)).?.name());
    a.things[3] = Thing.canonical_pool.free(.{ .generation = 5 });
    const kept = write(Pooled, &a, &a_buf);
    try testing.expectEqualStrings("things[3].(free).generation", firstDifference(Pooled, kept, write(Pooled, &b, &b_buf)).?.name());
}

test "a union with a signed tag and an enum of sparse values: their numbers among their values" {
    const Tag = enum(i8) { low = -2, high = 3 };
    const U = union(Tag) { low: u8, high: u16 };
    try testing.expectEqual(@as(usize, 1 + 16), maxBits(U));
    var a_buf: [maxSize(U)]u8 = undefined;
    var b_buf: [maxSize(U)]u8 = undefined;
    const ours = write(U, &U{ .low = 1 }, &a_buf);
    try testing.expectEqualStrings("low", firstDifference(U, ours, write(U, &U{ .low = 2 }, &b_buf)).?.name());
    try roundTrip(U, &U{ .high = 700 });
    const Open = enum(u8) { a = 1, _ };
    try testing.expectEqual(@as(usize, 8), maxBits(Open));
    try roundTrip(Open, &@as(Open, @fromBackingInt(200)));
}

//! The canonical form of a state (DESIGN.md 6): its named fields in the order of their
//! declarations, each in little-endian byte order, with no padding and no pointer. Two states are
//! the same exactly when their canonical bytes are: `hash` identifies a state for the tests and for
//! network play (DESIGN.md 9), and `firstDifference` names the first field whose bytes differ, as
//! the two peers of a session do when their states part.
//!
//! The types it takes: booleans (a byte), integers (their whole bytes), enums (their integer),
//! packed structs (their backing integer), structs and arrays (their parts in order), optionals (a
//! byte, 1 when there is a value, then the value or zeros) and tagged unions (the tag, then the
//! active payload, then zeros up to the largest payload). The form of a type has a fixed size, so
//! a field is at the same place in every state of its type.
const std = @import("std");

/// The bytes of `T`'s canonical form.
pub fn size(comptime T: type) usize {
    // The game's state has many fields: room for them all.
    @setEvalBranchQuota(100_000);
    return comptime switch (@typeInfo(T)) {
        .void => 0,
        .bool => 1,
        .int => |i| (i.bits + 7) / 8,
        .@"enum" => |e| size(e.tag_type),
        .@"struct" => |s| if (s.layout == .@"packed") size(s.backing_integer.?) else blk: {
            var n: usize = 0;
            for (s.field_types) |F| n += size(F);
            break :blk n;
        },
        .array => |a| a.len * size(a.child),
        .optional => |o| 1 + size(o.child),
        .@"union" => |u| blk: {
            const Tag = u.tag_type orelse @compileError("an untagged union has no canonical form: " ++ @typeName(T));
            var largest: usize = 0;
            for (u.field_types) |F| largest = @max(largest, size(F));
            break :blk size(Tag) + largest;
        },
        else => @compileError("no canonical form for " ++ @typeName(T)),
    };
}

/// Writes the canonical form of `value`, `size(T)` bytes, at the start of `out`, and returns them.
pub fn write(comptime T: type, value: *const T, out: []u8) []u8 {
    const n = size(T);
    std.debug.assert(out.len >= n);
    var at: usize = 0;
    put(T, value, out, &at);
    std.debug.assert(at == n);
    return out[0..n];
}

fn put(comptime T: type, value: *const T, out: []u8, at: *usize) void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => putInt(u1, @intFromBool(value.*), out, at),
        .int => putInt(T, value.*, out, at),
        .@"enum" => |e| putInt(e.tag_type, @backingInt(value.*), out, at),
        .@"struct" => |s| if (s.layout == .@"packed") {
            putInt(s.backing_integer.?, @bitCast(value.*), out, at);
        } else inline for (s.field_names, s.field_types) |name, F| put(F, &@field(value.*, name), out, at),
        .array => |a| for (value) |*item| put(a.child, item, out, at),
        .optional => |o| if (value.*) |*v| {
            putInt(u1, 1, out, at);
            put(o.child, v, out, at);
        } else {
            putInt(u1, 0, out, at);
            zeros(size(o.child), out, at);
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            putInt(@typeInfo(Tag).@"enum".tag_type, @backingInt(std.meta.activeTag(value.*)), out, at);
            const end = at.* + size(T) - size(Tag);
            switch (value.*) {
                inline else => |*payload| put(@TypeOf(payload.*), payload, out, at),
            }
            zeros(end - at.*, out, at);
        },
        else => comptime unreachable,
    }
}

fn putInt(comptime I: type, v: I, out: []u8, at: *usize) void {
    const n = comptime size(I);
    if (n == 0) return;
    const Bits = @Int(.unsigned, @bitSizeOf(I));
    const Wide = @Int(.unsigned, n * 8);
    std.mem.writeInt(Wide, out[at.*..][0..n], @as(Bits, @bitCast(v)), .little);
    at.* += n;
}

fn zeros(n: usize, out: []u8, at: *usize) void {
    @memset(out[at.*..][0..n], 0);
    at.* += n;
}

/// The hash of `value`'s canonical form (FNV-1a, 64 bits).
pub fn hash(comptime T: type, value: *const T) u64 {
    var buf: [size(T)]u8 = undefined;
    return std.hash.Fnv1a_64.hash(write(T, value, &buf));
}

/// The first field whose bytes differ between two canonical forms of one type.
pub const Difference = struct {
    name_buf: [96]u8 = undefined,
    name_len: u8 = 0,
    /// The field's place in the canonical form, and its bytes.
    offset: u32,
    width: u32,
    /// The field's value in each form: its bytes as a little-endian number (the first eight).
    ours: u64,
    theirs: u64,

    pub fn name(d: *const Difference) []const u8 {
        return d.name_buf[0..d.name_len];
    }

    pub fn format(d: Difference, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} (byte {d}, {d} byte{s}): ours {d}, theirs {d}", .{
            d.name(), d.offset, d.width, if (d.width == 1) "" else "s", d.ours, d.theirs,
        });
    }
};

/// Names the first difference between two canonical forms of `T`; null when they are the same.
pub const DiffFn = *const fn (ours: []const u8, theirs: []const u8) ?Difference;

pub fn diffFn(comptime T: type) DiffFn {
    return struct {
        fn diff(ours: []const u8, theirs: []const u8) ?Difference {
            return firstDifference(T, ours, theirs);
        }
    }.diff;
}

/// The first field of `T` whose bytes differ between `ours` and `theirs`, two canonical forms of
/// `T`, by its path (`scenes.base.test_pattern.markers[1].x`); null when they are the same.
/// Forms of different lengths differ at the shorter one's end, named `(the length)`; bytes that no
/// field names (a union's padding, a tag of no field: a form that is not `T`'s) by their place,
/// `(byte N)`.
pub fn firstDifference(comptime T: type, ours: []const u8, theirs: []const u8) ?Difference {
    if (ours.len != size(T) or theirs.len != size(T)) {
        if (ours.len == theirs.len and std.mem.eql(u8, ours, theirs)) return null;
        var d: Difference = .{ .offset = @intCast(@min(ours.len, theirs.len)), .width = 0, .ours = ours.len, .theirs = theirs.len };
        const text = "(the length)";
        @memcpy(d.name_buf[0..text.len], text);
        d.name_len = text.len;
        return d;
    }
    if (std.mem.eql(u8, ours, theirs)) return null;
    var walk: Walk = .{ .ours = ours, .theirs = theirs };
    if (walk.visit(T, 0)) return walk.found;
    const at = std.mem.findDiff(u8, ours, theirs).?;
    var d: Difference = .{ .offset = @intCast(at), .width = 1, .ours = ours[at], .theirs = theirs[at] };
    const text = std.fmt.bufPrint(&d.name_buf, "(byte {d})", .{at}) catch unreachable;
    d.name_len = @intCast(text.len);
    return d;
}

const Walk = struct {
    ours: []const u8,
    theirs: []const u8,
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

    /// Whether the field of `n` bytes at `at` differs; the first that does is `found`.
    fn leaf(w: *Walk, at: usize, n: usize) bool {
        const a = w.ours[at..][0..n];
        const b = w.theirs[at..][0..n];
        if (std.mem.eql(u8, a, b)) return false;
        var d: Difference = .{ .offset = @intCast(at), .width = @intCast(n), .ours = number(a), .theirs = number(b) };
        @memcpy(d.name_buf[0..w.len], w.path[0..w.len]);
        d.name_len = @intCast(w.len);
        w.found = d;
        return true;
    }

    fn number(bytes: []const u8) u64 {
        var v: u64 = 0;
        for (bytes[0..@min(bytes.len, 8)], 0..) |b, i| v |= @as(u64, b) << @intCast(8 * i);
        return v;
    }

    fn visit(w: *Walk, comptime T: type, at: usize) bool {
        switch (@typeInfo(T)) {
            .void => return false,
            .bool, .int, .@"enum" => return w.leaf(at, size(T)),
            .@"struct" => |s| {
                if (s.layout == .@"packed") return w.leaf(at, size(T));
                var place = at;
                inline for (s.field_names, s.field_types) |name, F| {
                    const before = w.push(if (w.len == 0) name else "." ++ name);
                    if (w.visit(F, place)) return true;
                    w.len = before;
                    place += size(F);
                }
                return false;
            },
            .array => |a| {
                for (0..a.len) |i| {
                    var buf: [24]u8 = undefined;
                    const before = w.push(std.fmt.bufPrint(&buf, "[{d}]", .{i}) catch unreachable);
                    if (w.visit(a.child, at + i * size(a.child))) return true;
                    w.len = before;
                }
                return false;
            },
            .optional => |o| {
                // The flag is the optional's own name; its value follows it.
                if (w.leaf(at, 1)) return true;
                const before = w.push(".?");
                if (w.visit(o.child, at + 1)) return true;
                w.len = before;
                return false;
            },
            .@"union" => |u| {
                // The tag is the union's own name; the payload follows it, named by the tag, which
                // is the same in both forms once the tag did not differ.
                const Tag = u.tag_type.?;
                const TagInt = @typeInfo(Tag).@"enum".tag_type;
                const tag_size = size(Tag);
                if (w.leaf(at, tag_size)) return true;
                // The tag's bits as `put` wrote them, a signed tag's included.
                const tag = number(w.ours[at..][0..tag_size]);
                inline for (u.field_names, u.field_types) |name, F| {
                    const bits: @Int(.unsigned, @bitSizeOf(TagInt)) = @bitCast(@as(TagInt, @backingInt(@field(Tag, name))));
                    if (tag == bits) {
                        const before = w.push(if (w.len == 0) name else "." ++ name);
                        if (w.visit(F, at + tag_size)) return true;
                        w.len = before;
                    }
                }
                return false;
            },
            else => comptime unreachable,
        }
    }
};

// --- tests -------------------------------------------------------------------------------------

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

test "a state's form: its fields in order, little-endian, without padding" {
    try testing.expectEqual(@as(usize, 4 + 1 + 1 + 1 + 1 + 2 + 8 + 3 + 2 * 5), size(Sample));
    var buf: [size(Sample)]u8 = undefined;
    const s: Sample = .{};
    const bytes = write(Sample, &s, &buf);
    try testing.expectEqualSlices(u8, &.{
        4, 3, 2, 1, // tick
        1, // on
        2, // kind
        2, // flags: b
        5, // small
        254, 255, // signed
        1, 0, 2, 0, 3, 0, 4, 0, // points
        0, 0, 0, // maybe: none, zeros
        1, 7, 0, 0, 0, // items[0]: count 7, then zeros to the largest payload
        0, 0, 0, 0, 0, // items[1]: empty
    }, bytes);
    var other = s;
    other.maybe = 9;
    other.items[1] = .{ .place = .{ .x = -1, .y = 2 } };
    try testing.expectEqualSlices(u8, &.{ 1, 9, 0, 1, 7, 0, 0, 0, 2, 255, 255, 2, 0 }, write(Sample, &other, &buf)[18..]);
    try testing.expect(hash(Sample, &s) != hash(Sample, &other));
    try testing.expectEqual(hash(Sample, &s), hash(Sample, &Sample{}));
}

test "the first differing field is named by its path" {
    var a_buf: [size(Sample)]u8 = undefined;
    var b_buf: [size(Sample)]u8 = undefined;
    const a: Sample = .{};
    var b = a;
    const ours = write(Sample, &a, &a_buf);
    try testing.expectEqual(@as(?Difference, null), firstDifference(Sample, ours, write(Sample, &b, &b_buf)));

    b.points[1].y = 40;
    b.maybe = 3;
    var d = firstDifference(Sample, ours, write(Sample, &b, &b_buf)).?;
    try testing.expectEqualStrings("points[1].y", d.name());
    try testing.expectEqual(@as(u32, 16), d.offset);
    try testing.expectEqual(@as(u64, 4), d.ours);
    try testing.expectEqual(@as(u64, 40), d.theirs);
    var text: [96]u8 = undefined;
    try testing.expectEqualStrings("points[1].y (byte 16, 2 bytes): ours 4, theirs 40", try std.fmt.bufPrint(&text, "{f}", .{d}));

    b = a;
    b.maybe = 3;
    try testing.expectEqualStrings("maybe", firstDifference(Sample, ours, write(Sample, &b, &b_buf)).?.name());
    b = a;
    b.items[0] = .{ .count = 8 };
    try testing.expectEqualStrings("items[0].count", firstDifference(Sample, ours, write(Sample, &b, &b_buf)).?.name());
    b.items[0] = .empty;
    try testing.expectEqualStrings("items[0]", firstDifference(Sample, ours, write(Sample, &b, &b_buf)).?.name());
    b = a;
    b.flags.a = true;
    d = diffFn(Sample)(ours, write(Sample, &b, &b_buf)).?;
    try testing.expectEqualStrings("flags", d.name());
    try testing.expectEqual(@as(u64, 3), d.theirs);
    // Forms of another length: another build's state.
    try testing.expectEqualStrings("(the length)", firstDifference(Sample, ours, ours[0..10]).?.name());
    // Bytes no field names: a union's padding, which a form of `Sample` never has.
    var odd = a_buf;
    odd[27] = 1; // items[1]'s payload, which `.empty` pads with zeros
    d = firstDifference(Sample, ours, &odd).?;
    try testing.expectEqualStrings("(byte 27)", d.name());
    try testing.expectEqual(@as(u64, 1), d.theirs);
}

test "a union with a signed tag names its payload" {
    const Tag = enum(i8) { low = -2, high = 3 };
    const U = union(Tag) { low: u8, high: u16 };
    var a_buf: [size(U)]u8 = undefined;
    var b_buf: [size(U)]u8 = undefined;
    const ours = write(U, &U{ .low = 1 }, &a_buf);
    try testing.expectEqualStrings("low", firstDifference(U, ours, write(U, &U{ .low = 2 }, &b_buf)).?.name());
}

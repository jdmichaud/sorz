//! JSON for the content tree and the records: a small value type written with sorted keys,
//! integers only and a fixed layout (two-space indentation; an array of scalars on one line), so
//! that the same data always gives the same bytes; and the reading side, over `std.json`, whose
//! accessors name the file and the field of a refused value (DESIGN.md C2).
//!
//! Carried over from sor-remaster after review: the writer refuses text that is not UTF-8
//! (the old one escaped each byte above 0x7F as a code point), an out-of-memory error is
//! reported instead of losing the field's path, and a reader can refuse the fields an object
//! should not have (`Node.only`).
const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    str: []const u8,
    array: []const Value,
    object: []const Field,

    pub fn num(v: anytype) Value {
        return .{ .int = @intCast(v) };
    }

    /// `v` as a string "0x1F" (upper-case digits).
    pub fn hex(arena: std.mem.Allocator, v: u64) error{OutOfMemory}!Value {
        return .{ .str = try std.fmt.allocPrint(arena, "0x{X}", .{v}) };
    }
};

pub const Field = struct { key: []const u8, value: Value };

fn fieldLess(_: void, a: Field, b: Field) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn scalar(v: Value) bool {
    return switch (v) {
        .array, .object => false,
        else => true,
    };
}

pub const WriteError = error{ OutOfMemory, InvalidUtf8, DuplicateKey };

/// The text of `v` with a final newline. An object's keys are sorted; two equal keys are an
/// error, as is a string that is not UTF-8.
pub fn write(gpa: std.mem.Allocator, v: Value) WriteError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    writeValue(gpa, &out.writer, v, 0) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => |x| x,
    };
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn indent(w: *std.Io.Writer, depth: usize) !void {
    try w.writeByte('\n');
    try w.splatByteAll(' ', depth * 2);
}

fn writeValue(gpa: std.mem.Allocator, w: *std.Io.Writer, v: Value, depth: usize) (WriteError || std.Io.Writer.Error)!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .str => |s| try writeString(w, s),
        .array => |items| {
            if (items.len == 0) return w.writeAll("[]");
            var flat = true;
            for (items) |it| flat = flat and scalar(it);
            try w.writeByte('[');
            for (items, 0..) |it, i| {
                if (i != 0) try w.writeByte(',');
                if (flat) {
                    if (i != 0) try w.writeByte(' ');
                } else try indent(w, depth + 1);
                try writeValue(gpa, w, it, depth + 1);
            }
            if (!flat) try indent(w, depth);
            try w.writeByte(']');
        },
        .object => |fields| {
            if (fields.len == 0) return w.writeAll("{}");
            const sorted = try gpa.dupe(Field, fields);
            defer gpa.free(sorted);
            std.mem.sort(Field, sorted, {}, fieldLess);
            try w.writeByte('{');
            for (sorted, 0..) |f, i| {
                if (i != 0) {
                    if (std.mem.eql(u8, sorted[i - 1].key, f.key)) return error.DuplicateKey;
                    try w.writeByte(',');
                }
                try indent(w, depth + 1);
                try writeString(w, f.key);
                try w.writeAll(": ");
                try writeValue(gpa, w, f.value, depth + 1);
            }
            try indent(w, depth);
            try w.writeByte('}');
        },
    }
}

fn writeString(w: *std.Io.Writer, s: []const u8) (WriteError || std.Io.Writer.Error)!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        0...0x09, 0x0B...0x1F, 0x7F => try w.print("\\u{X:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// --- Reading ---------------------------------------------------------------------------------

/// Where a refused value is: the file and the field path, and why.
pub const Diagnostic = struct {
    file: []const u8 = "",
    field: [256]u8 = undefined,
    field_len: usize = 0,
    message: []const u8 = "",

    pub fn fieldName(self: *const Diagnostic) []const u8 {
        return self.field[0..self.field_len];
    }

    /// The place of a refusal in a file that is not JSON: a line, or another place.
    pub fn setPlace(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.field, fmt, args) catch self.field[0..];
        self.field_len = s.len;
    }

    pub fn format(self: *const Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}", .{self.file});
        // A text file's place is a line; a JSON file's a field.
        if (self.field_len != 0) {
            const name = self.fieldName();
            try w.print("{s}{s}", .{ if (std.mem.startsWith(u8, name, "line ") or std.mem.startsWith(u8, name, "pixel ")) ": " else ": field ", name });
        }
        if (self.message.len != 0) try w.print(": {s}", .{self.message});
    }
};

pub const Error = error{ BadAsset, OutOfMemory };

/// A cursor on a parsed value: the value, and the path that reached it (for the diagnostic).
pub const Node = struct {
    value: std.json.Value,
    diag: *Diagnostic,
    path: []const u8,
    arena: std.mem.Allocator,

    /// Records the refusal of this value, with `message`, and returns `error.BadAsset`.
    pub fn fail(self: Node, message: []const u8) Error {
        const n = @min(self.path.len, self.diag.field.len);
        @memcpy(self.diag.field[0..n], self.path[0..n]);
        self.diag.field_len = n;
        self.diag.message = message;
        return error.BadAsset;
    }

    fn child(self: Node, value: std.json.Value, comptime fmt: []const u8, args: anytype) Error!Node {
        const path = try std.fmt.allocPrint(self.arena, fmt, args);
        return .{ .value = value, .diag = self.diag, .path = path, .arena = self.arena };
    }

    fn object(self: Node) Error!std.json.ObjectMap {
        return switch (self.value) {
            .object => |o| o,
            else => self.fail("not an object"),
        };
    }

    fn keyPath(self: Node, key: []const u8) Error!Node {
        const sep: []const u8 = if (self.path.len == 0) "" else ".";
        return self.child(.null, "{s}{s}{s}", .{ self.path, sep, key });
    }

    /// The field `key` of an object; a missing field is refused.
    pub fn get(self: Node, key: []const u8) Error!Node {
        const o = try self.object();
        const v = o.get(key) orelse return (try self.keyPath(key)).fail("missing");
        var n = try self.keyPath(key);
        n.value = v;
        return n;
    }

    /// The field `key` of an object, or null when it is absent or null.
    pub fn opt(self: Node, key: []const u8) Error!?Node {
        const o = try self.object();
        const v = o.get(key) orelse return null;
        if (v == .null) return null;
        var n = try self.keyPath(key);
        n.value = v;
        return n;
    }

    /// Refuses an object with a field not in `allowed` (a misspelt field would else be ignored).
    pub fn only(self: Node, allowed: []const []const u8) Error!void {
        const o = try self.object();
        for (o.keys()) |k| {
            for (allowed) |a| {
                if (std.mem.eql(u8, a, k)) break;
            } else return (try self.keyPath(k)).fail("not a field of this record");
        }
    }

    /// The fields of an object, in the file's order.
    pub fn fields(self: Node) Error!Fields {
        return .{ .node = self, .map = try self.object() };
    }

    pub const Fields = struct {
        node: Node,
        map: std.json.ObjectMap,
        index: usize = 0,

        pub fn count(self: *const Fields) usize {
            return self.map.count();
        }

        /// The next field's key and value.
        pub fn next(self: *Fields) Error!?struct { key: []const u8, value: Node } {
            if (self.index >= self.map.count()) return null;
            const k = self.map.keys()[self.index];
            var n = try self.node.keyPath(k);
            n.value = self.map.values()[self.index];
            self.index += 1;
            return .{ .key = k, .value = n };
        }
    };

    pub fn items(self: Node) Error![]std.json.Value {
        return switch (self.value) {
            .array => |a| a.items,
            else => self.fail("not an array"),
        };
    }

    pub fn at(self: Node, i: usize) Error!Node {
        const a = try self.items();
        if (i >= a.len) return self.fail("too short");
        return self.child(a[i], "{s}[{d}]", .{ self.path, i });
    }

    pub fn len(self: Node) Error!usize {
        return (try self.items()).len;
    }

    /// An integer, written as a number or as a string "0x1F".
    pub fn int(self: Node, comptime T: type) Error!T {
        const v: i64 = switch (self.value) {
            .integer => |i| i,
            .string => |s| parseHex(s) orelse return self.fail("not a number"),
            else => return self.fail("not a number"),
        };
        return std.math.cast(T, v) orelse self.fail("out of range");
    }

    pub fn boolean(self: Node) Error!bool {
        return switch (self.value) {
            .bool => |b| b,
            else => self.fail("not a boolean"),
        };
    }

    pub fn string(self: Node) Error![]const u8 {
        return switch (self.value) {
            .string => |s| s,
            else => self.fail("not a string"),
        };
    }

    pub fn isNull(self: Node) bool {
        return self.value == .null;
    }
};

/// "0x1F" or "-0x1F" as a number.
pub fn parseHex(s: []const u8) ?i64 {
    var t = s;
    var neg = false;
    if (t.len > 0 and t[0] == '-') {
        neg = true;
        t = t[1..];
    }
    if (t.len < 3 or t[0] != '0' or (t[1] != 'x' and t[1] != 'X')) return null;
    const v = std.fmt.parseInt(i64, t[2..], 16) catch return null;
    return if (neg) -v else v;
}

/// Parses `text` of the file `file`; the values live in `arena`.
pub fn parse(arena: std.mem.Allocator, file: []const u8, text: []const u8, diag: *Diagnostic) Error!Node {
    diag.* = .{ .file = file };
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |e| {
        diag.message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateField => "a field appears twice",
            else => "not valid JSON",
        };
        return error.BadAsset;
    };
    return .{ .value = v, .diag = diag, .path = "", .arena = arena };
}

test "sorted keys, one-line scalar arrays, the same bytes twice" {
    const gpa = std.testing.allocator;
    const v: Value = .{ .object = &.{
        .{ .key = "zeta", .value = .{ .array = &.{ Value.num(1), Value.num(-2) } } },
        .{ .key = "alpha", .value = .{ .str = "a\"b é" } },
        .{ .key = "mid", .value = .{ .array = &.{.{ .object = &.{.{ .key = "k", .value = .null }} }} } },
    } };
    const a = try write(gpa, v);
    defer gpa.free(a);
    try std.testing.expectEqualStrings(
        \\{
        \\  "alpha": "a\"b é",
        \\  "mid": [
        \\    {
        \\      "k": null
        \\    }
        \\  ],
        \\  "zeta": [1, -2]
        \\}
        \\
    , a);
    const b = try write(gpa, v);
    defer gpa.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "the writer refuses text that is not UTF-8 and keys that repeat" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidUtf8, write(gpa, .{ .str = "\xff" }));
    try std.testing.expectError(error.DuplicateKey, write(gpa, .{ .object = &.{
        .{ .key = "a", .value = .null },
        .{ .key = "a", .value = .null },
    } }));
}

test "the reader names the file and the field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const root = try parse(arena, "round1/art.json", "{\"planes\": [{\"width\": \"0x150\"}, {\"width\": true}]}", &diag);
    const planes = try root.get("planes");
    try std.testing.expectEqual(@as(u16, 0x150), try (try (try planes.at(0)).get("width")).int(u16));
    try std.testing.expectError(error.BadAsset, (try (try planes.at(1)).get("width")).int(u16));
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{&diag});
    try std.testing.expectEqualStrings("round1/art.json: field planes[1].width: not a number", text);
    try std.testing.expectError(error.BadAsset, root.get("palette"));
    try std.testing.expectEqualStrings("palette", diag.fieldName());
    try std.testing.expectEqual(@as(?Node, null), try root.opt("palette"));
    try std.testing.expectError(error.BadAsset, parse(arena, "x.json", "{", &diag));
    try std.testing.expectError(error.BadAsset, parse(arena, "x.json", "{\"a\": 1, \"a\": 2}", &diag));
    try std.testing.expectEqualStrings("a field appears twice", diag.message);
}

test "a record's unknown field is refused, and its fields are listed in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const root = try parse(arena, "a.json", "{\"b\": 1, \"a\": {\"x\": 2, \"widht\": 3}}", &diag);
    try root.only(&.{ "a", "b" });
    const a = try root.get("a");
    try std.testing.expectError(error.BadAsset, a.only(&.{"x"}));
    try std.testing.expectEqualStrings("a.widht", diag.fieldName());
    var it = try root.fields();
    try std.testing.expectEqual(@as(usize, 2), it.count());
    try std.testing.expectEqualStrings("b", (try it.next()).?.key);
    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("a", second.key);
    try std.testing.expectEqualStrings("a", second.value.path);
    try std.testing.expect(try it.next() == null);
}

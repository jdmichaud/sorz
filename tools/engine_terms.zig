//! The engine's rule against the console's terms (DESIGN.md P1, PLAN item 03). The engine's
//! sources (src/shared) are written in the game's terms: the original's places belong to the
//! extractor (src/extract), the content's provenance and sor-re's port maps. So in a source of the
//! engine, outside its `test` blocks, these are errors:
//! - a hexadecimal number of four digits or more (`0xFF0000`, or `$FF0000` in a comment or a
//!   string): an address, a RAM offset, a register's value;
//! - the console's words anywhere: VDP, VRAM, CRAM, VSRAM, and its processor (68000, 68K);
//! - VBlank in an identifier (a display tick is a tick), and d0 to d7 and a0 to a7, the
//!   processor's registers, as identifiers.
//!
//! The few legitimate cases (a colour constant, a chip's register in the sound's chip models) are
//! listed in the allow-list (`tools/engine_terms.allow`): a path (a file, or a directory ending in
//! `/`), the term (the text as it is written, or a class of terms: `hex`, `vblank`, `register`,
//! `vdp`, `vram`, `cram`, `vsram`, `cpu`), and why. An entry that allows nothing is an error too, so
//! that the list stays the list of what is there.
//!
//!     zig run tools/engine_terms.zig -- SOURCES ALLOW_LIST
//!
//! `zig build test` runs it on src/shared, from the repository's root.
const std = @import("std");

pub const Class = enum {
    /// A hexadecimal number of four digits or more.
    hex,
    /// VBlank in an identifier.
    vblank,
    /// d0 to d7 or a0 to a7 as an identifier.
    register,
    vdp,
    vram,
    cram,
    vsram,
    /// The console's processor: 68000, 68K.
    cpu,

    pub fn what(c: Class) []const u8 {
        return switch (c) {
            .hex => "a hexadecimal number of four digits or more (an address?)",
            .vblank => "VBlank in an identifier (the game counts display ticks)",
            .register => "a register of the console's processor as an identifier",
            .vdp, .vram, .cram, .vsram => "a term of the console's video chip",
            .cpu => "the console's processor",
        };
    }
};

pub const Finding = struct {
    /// The byte where the term starts, and the term as it is written.
    offset: usize,
    class: Class,
    text: []const u8,
};

/// The findings of one source, in order. Their texts point into `source`.
pub fn scan(gpa: std.mem.Allocator, source: [:0]const u8, out: *std.ArrayList(Finding)) error{OutOfMemory}!void {
    var tokenizer = std.zig.Tokenizer.init(source);
    // The end of the last token: the text from there to the next token is blanks and comments.
    var gap: usize = 0;
    while (true) {
        const token = tokenizer.next();
        try comments(gpa, source, gap, token.loc.start, out);
        if (token.tag == .eof) return;
        gap = token.loc.end;
        const text = source[token.loc.start..token.loc.end];
        switch (token.tag) {
            // A test block: its tokens and comments are the tests', which the rule exempts.
            .keyword_test => {
                var depth: usize = 0;
                while (true) {
                    const t = tokenizer.next();
                    if (t.tag == .eof) return;
                    gap = t.loc.end;
                    if (t.tag == .l_brace) depth += 1;
                    if (t.tag == .r_brace and depth > 0) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
            },
            .number_literal => if (hexDigits(text) >= 4) try out.append(gpa, .{ .offset = token.loc.start, .class = .hex, .text = text }),
            .identifier => if (identifierClass(text)) |class| try out.append(gpa, .{ .offset = token.loc.start, .class = class, .text = text }),
            .string_literal, .multiline_string_literal_line, .char_literal, .doc_comment, .container_doc_comment => try words(gpa, source, token.loc.start, token.loc.end, out),
            else => {},
        }
    }
}

/// The comments between two tokens.
fn comments(gpa: std.mem.Allocator, source: []const u8, start: usize, end: usize, out: *std.ArrayList(Finding)) error{OutOfMemory}!void {
    var at = start;
    while (std.mem.findPos(u8, source[0..end], at, "//")) |slash| {
        const line_end = std.mem.findScalarPos(u8, source[0..end], slash, '\n') orelse end;
        try words(gpa, source, slash, line_end, out);
        at = line_end;
    }
}

/// The terms in a text (a comment or a string): hexadecimal numbers and the console's words.
fn words(gpa: std.mem.Allocator, source: []const u8, start: usize, end: usize, out: *std.ArrayList(Finding)) error{OutOfMemory}!void {
    var i = start;
    while (i < end) {
        const ch = source[i];
        if (!std.ascii.isAlphanumeric(ch) and ch != '$') {
            i += 1;
            continue;
        }
        // A hexadecimal number in a text: `0x...` or the assembler's `$...`.
        const prefix: usize = if (ch == '$') 1 else if (ch == '0' and i + 1 < end and (source[i + 1] == 'x' or source[i + 1] == 'X')) 2 else 0;
        if (prefix != 0) {
            var j = i + prefix;
            var digits: usize = 0;
            while (j < end and (std.ascii.isHex(source[j]) or source[j] == '_')) : (j += 1) {
                if (source[j] != '_') digits += 1;
            }
            if (digits >= 4) try out.append(gpa, .{ .offset = i, .class = .hex, .text = source[i..j] });
            i = @max(j, i + 1);
            continue;
        }
        var j = i;
        while (j < end and (std.ascii.isAlphanumeric(source[j]) or source[j] == '_')) j += 1;
        // A word is read as an identifier's parts are (`vramAddr`, `MC68000`); VBlank and the
        // registers' names may be said in a text.
        if (partsClass(source[i..j])) |class| try out.append(gpa, .{ .offset = i, .class = class, .text = source[i..j] });
        i = j;
    }
}

/// The digits of a hexadecimal literal (0 for another number).
fn hexDigits(literal: []const u8) usize {
    if (literal.len < 2 or literal[0] != '0' or (literal[1] != 'x' and literal[1] != 'X')) return 0;
    var n: usize = 0;
    for (literal[2..]) |ch| {
        if (ch == '_') continue;
        if (!std.ascii.isHex(ch)) break;
        n += 1;
    }
    return n;
}

/// The class of a part of a name: a word of the console's video chip.
fn wordClass(word: []const u8) ?Class {
    const terms = [_]struct { []const u8, Class }{
        .{ "vdp", .vdp }, .{ "vram", .vram }, .{ "cram", .cram }, .{ "vsram", .vsram },
    };
    for (terms) |t| if (std.ascii.eqlIgnoreCase(word, t[0])) return t[1];
    return null;
}

/// Whether a name says the console's processor: 68000 or 68K, not inside a longer number
/// (`MC68000`, `cpu_68k`, `is68k`; not `268000` or `1680`).
fn saysCpu(name: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findPos(u8, name, i, "68")) |at| : (i = at + 1) {
        if (at > 0 and std.ascii.isDigit(name[at - 1])) continue;
        const rest = name[at + 2 ..];
        if (std.mem.startsWith(u8, rest, "000") and (rest.len == 3 or !std.ascii.isDigit(rest[3]))) return true;
        if (rest.len != 0 and (rest[0] == 'k' or rest[0] == 'K') and (rest.len == 1 or !(std.ascii.isLower(rest[1]) or std.ascii.isDigit(rest[1])))) return true;
    }
    return false;
}

/// The class of an identifier: a register's name, VBlank in it, or what its parts say.
fn identifierClass(name: []const u8) ?Class {
    if (name.len == 2 and std.mem.findScalar(u8, "dDaA", name[0]) != null and name[1] >= '0' and name[1] <= '7') return .register;
    if (std.ascii.findIgnoreCase(name, "vblank") != null) return .vblank;
    return partsClass(name);
}

/// The class of a name by its parts: the processor, or a part that is a word of the console's
/// video chip (`vramAddress`, `cram_colour`, `VDPStatus`; not `scramble`).
fn partsClass(name: []const u8) ?Class {
    if (saysCpu(name)) return .cpu;
    // Its parts: split at underscores, between a lower-case letter or a digit and a capital,
    // between letters and digits, and before the last capital of a run of capitals that a
    // lower-case letter follows.
    var start: usize = 0;
    var i: usize = 1;
    while (i <= name.len) : (i += 1) {
        const boundary = i == name.len or name[i] == '_' or name[i - 1] == '_' or
            (std.ascii.isUpper(name[i]) and !std.ascii.isUpper(name[i - 1])) or
            (std.ascii.isDigit(name[i]) != std.ascii.isDigit(name[i - 1])) or
            (std.ascii.isUpper(name[i - 1]) and std.ascii.isUpper(name[i]) and i + 1 < name.len and std.ascii.isLower(name[i + 1]));
        if (!boundary) continue;
        const part = std.mem.trim(u8, name[start..i], "_");
        if (wordClass(part)) |class| return class;
        start = i;
    }
    return null;
}

pub const Allowance = struct {
    path: []const u8,
    term: []const u8,
    used: bool = false,

    fn covers(a: *const Allowance, path: []const u8, f: Finding) bool {
        const place = if (std.mem.endsWith(u8, a.path, "/")) std.mem.startsWith(u8, path, a.path) else std.mem.eql(u8, path, a.path);
        return place and (std.mem.eql(u8, a.term, f.text) or std.mem.eql(u8, a.term, @tagName(f.class)));
    }
};

/// The allow-list's entries: `PATH TERM -- WHY` a line; `#` starts a comment line. Their texts
/// point into `text`.
pub fn parseAllowList(gpa: std.mem.Allocator, text: []const u8) error{ OutOfMemory, BadAllowList }![]Allowance {
    var list: std.ArrayList(Allowance) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const dashes = std.mem.find(u8, line, " -- ") orelse return error.BadAllowList;
        if (std.mem.trim(u8, line[dashes + 4 ..], " ").len == 0) return error.BadAllowList;
        var fields = std.mem.tokenizeAny(u8, line[0..dashes], " \t");
        const path = fields.next() orelse return error.BadAllowList;
        const term = fields.next() orelse return error.BadAllowList;
        if (fields.next() != null) return error.BadAllowList;
        try list.append(gpa, .{ .path = path, .term = term });
    }
    return list.toOwnedSlice(gpa);
}

fn lineAndColumn(source: []const u8, offset: usize) struct { usize, usize } {
    const line = std.mem.count(u8, source[0..offset], "\n") + 1;
    const start = if (std.mem.findScalarLast(u8, source[0..offset], '\n')) |nl| nl + 1 else 0;
    return .{ line, offset - start + 1 };
}

/// Checks every `.zig` file under `root` (a path as the allow-list writes it), and writes what
/// breaks the rule to `report`. Returns the number of errors.
pub fn check(gpa: std.mem.Allocator, io: std.Io, root: []const u8, allowances: []Allowance, report: *std.Io.Writer) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    // A file system may not say an entry's kind (DT_UNKNOWN): the walk then asks it, and enters
    // the directories itself.
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const kind = if (entry.kind != .unknown) entry.kind else (entry.dir.statFile(io, entry.basename, .{}) catch continue).kind;
        switch (kind) {
            .directory => {
                var dir_entry = entry;
                dir_entry.kind = .directory;
                try walker.enter(io, dir_entry);
            },
            .file => if (std.mem.endsWith(u8, entry.path, ".zig")) {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), entry.path });
                std.mem.replaceScalar(u8, path, '\\', '/');
                try paths.append(gpa, path);
            },
            else => {},
        }
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var errors: usize = 0;
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);
    for (paths.items) |path| {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(16 << 20), .of(u8), 0);
        defer gpa.free(source);
        findings.clearRetainingCapacity();
        try scan(gpa, source, &findings);
        for (findings.items) |f| {
            var allowed = false;
            for (allowances) |*a| if (a.covers(path, f)) {
                a.used = true;
                allowed = true;
            };
            if (allowed) continue;
            const line, const column = lineAndColumn(source, f.offset);
            try report.print("{s}:{d}:{d}: {s}: {s}\n", .{ path, line, column, f.text, f.class.what() });
            errors += 1;
        }
    }
    for (allowances) |a| if (!a.used) {
        try report.print("engine_terms.allow: {s} {s} allows nothing: the entry goes\n", .{ a.path, a.term });
        errors += 1;
    };
    if (errors != 0) try report.print("the engine's sources ({s}) name the console's places or terms ({d}): write them in the game's terms (DESIGN.md P1), or allow a legitimate one in the allow-list\n", .{ root, errors });
    return errors;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const root = args.next() orelse return usage(io);
    const allow_path = args.next() orelse return usage(io);
    if (args.next() != null) return usage(io);
    const allow_text = try std.Io.Dir.cwd().readFileAlloc(io, allow_path, gpa, .limited(1 << 20));
    defer gpa.free(allow_text);
    const allowances = parseAllowList(gpa, allow_text) catch |err| {
        std.log.err("{s}: a line is not PATH TERM -- WHY ({s})", .{ allow_path, @errorName(err) });
        std.process.exit(2);
    };
    defer gpa.free(allowances);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    const errors = try check(gpa, io, root, allowances, &w.interface);
    try w.interface.flush();
    if (errors != 0) std.process.exit(1);
}

fn usage(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll("usage: engine_terms SOURCES ALLOW_LIST\n");
    try w.interface.flush();
    std.process.exit(2);
}

// --- tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn findingsOf(source: [:0]const u8) ![]Finding {
    var list: std.ArrayList(Finding) = .empty;
    errdefer list.deinit(testing.allocator);
    try scan(testing.allocator, source, &list);
    return list.toOwnedSlice(testing.allocator);
}

test "a planted address is found, in code, in a comment and in a string" {
    const found = try findingsOf(
        \\const player_x = 0xFFB80A; // the player's x
        \\// was at $FFB80A in RAM
        \\const text = "0x0000_1234";
        \\const small = 0xFF;
        \\const mask = 0x3FF;
        \\const big = 1_000_000;
    );
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("0xFFB80A", found[0].text);
    try testing.expectEqualStrings("$FFB80A", found[1].text);
    try testing.expectEqualStrings("0x0000_1234", found[2].text);
    for (found) |f| try testing.expectEqual(Class.hex, f.class);
}

test "the console's words and identifiers are found; the game's are not" {
    const found = try findingsOf(
        \\//! Writes to the VDP, as the 68000 does.
        \\const vblank_count = 0;
        \\fn onVBlank() void {}
        \\var vramAddress: u16 = 0;
        \\const cram_colour = 1;
        \\const VSRAMScroll = 2;
        \\const d0 = 3;
        \\const a7 = 4;
        \\const scramble = 5;
        \\const d8 = 6;
        \\const tick_count = 7;
        \\/// Each display tick, as the original's VBlank.
        \\const m68k = 8;
        \\const cpu_68k = 9;
        \\const is68k = 10;
        \\// Its vramAddr, as the MC68000 has it; 268000 and 1680 are numbers.
    );
    defer testing.allocator.free(found);
    const want = [_]struct { []const u8, Class }{
        .{ "VDP", .vdp },           .{ "68000", .cpu },        .{ "vblank_count", .vblank },
        .{ "onVBlank", .vblank },   .{ "vramAddress", .vram }, .{ "cram_colour", .cram },
        .{ "VSRAMScroll", .vsram }, .{ "d0", .register },      .{ "a7", .register },
        .{ "m68k", .cpu },          .{ "cpu_68k", .cpu },      .{ "is68k", .cpu },
        .{ "vramAddr", .vram },     .{ "MC68000", .cpu },
    };
    try testing.expectEqual(want.len, found.len);
    for (want, found) |w, f| {
        try testing.expectEqualStrings(w[0], f.text);
        try testing.expectEqual(w[1], f.class);
    }
}

test "test blocks are exempt" {
    const found = try findingsOf(
        \\const ok = 1;
        \\test "the original's address" {
        \\    const at = 0xFFB80A; // $FFB80A
        \\    { const vdp = at; _ = vdp; }
        \\}
        \\const after = 0x1234;
    );
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("0x1234", found[0].text);
}

test "the allow-list: a path or a directory, a term or a class, and why" {
    const list = try parseAllowList(testing.allocator,
        \\# The exceptions.
        \\src/shared/audio/chips/ hex -- the chip's registers
        \\src/shared/x.zig 0xFFFF -- a colour
    );
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 2), list.len);
    const f: Finding = .{ .offset = 0, .class = .hex, .text = "0x1234" };
    try testing.expect(list[0].covers("src/shared/audio/chips/ym2612.zig", f));
    try testing.expect(!list[0].covers("src/shared/audio/driver.zig", f));
    try testing.expect(!list[1].covers("src/shared/x.zig", f));
    try testing.expect(list[1].covers("src/shared/x.zig", .{ .offset = 0, .class = .hex, .text = "0xFFFF" }));
    try testing.expectError(error.BadAllowList, parseAllowList(testing.allocator, "src/shared/x.zig 0xFFFF"));
    try testing.expectError(error.BadAllowList, parseAllowList(testing.allocator, "src/shared/x.zig -- why"));
    try testing.expectError(error.BadAllowList, parseAllowList(testing.allocator, "src/shared/x.zig 0xFFFF --  "));
}

test "a tree with a planted address fails, the same tree without it passes, and a stale entry fails" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "shared/net");
    try tmp.dir.writeFile(io, .{ .sub_path = "shared/game.zig", .data = "const tick: u32 = 0;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "shared/net/session.zig", .data = "const seed: u64 = 0x9E37_79B9;\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const root = try std.fmt.allocPrint(testing.allocator, "{s}/shared", .{base});
    defer testing.allocator.free(root);

    var out: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try testing.expectEqual(@as(usize, 1), try check(testing.allocator, io, root, &.{}, &w));
    try testing.expect(std.mem.find(u8, w.buffered(), "net/session.zig:1:19: 0x9E37_79B9: a hexadecimal number") != null);

    // Allowed, it passes; an entry that allows nothing fails.
    const entry = try std.fmt.allocPrint(testing.allocator, "{s}/net/session.zig 0x9E37_79B9 -- a hash's constant\n{s}/game.zig vblank -- none", .{ root, root });
    defer testing.allocator.free(entry);
    const allowances = try parseAllowList(testing.allocator, entry);
    defer testing.allocator.free(allowances);
    w = .fixed(&out);
    try testing.expectEqual(@as(usize, 1), try check(testing.allocator, io, root, allowances, &w));
    try testing.expect(std.mem.find(u8, w.buffered(), "game.zig vblank allows nothing") != null);
    w = .fixed(&out);
    for (allowances) |*a| a.used = false;
    try testing.expectEqual(@as(usize, 0), try check(testing.allocator, io, root, allowances[0..1], &w));
}

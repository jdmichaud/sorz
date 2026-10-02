//! The sound notation: a song or an effect as text, in the spirit of MML (docs/content-sound.md).
//! One file per item: its name and provenance, its instruments by named operator parameters, then
//! its tracks as sequences of words, one per event. Writing then reading gives the same item.
//!
//! ```
//! song round_1
//! provenance "request $81, ..."
//! instrument 0 algorithm 4 feedback 7
//!   op1 detune 3 multiple 1 level 33 key_scale 0 attack 31 am 0 decay 0 sustain_rate 0 ...
//! track fm1 volume_offset 4
//!   @0 v15 q3 [ o2 a:29 a:25 | a:36 ]4 r:111 :L1 c+:12 & c+:30 jump L1
//! ```
//!
//! Events: `o4` sets the octave of the notes after it; `c:12` a note (keys c c+ d d+ e f f+ g g+ a
//! a+ b, and n12-n15 for the four FM pitches past b), `hit:12` a drum hit, `r:12` a rest; `&`
//! ties the next note; `@3` instrument 3, `drum 3` the drums' sample; `v15` the volume, `v+1` and
//! `v-1` relative; `q3` the gate; `D=-10` and `D+=5` the detune set or added; `M=delay,period,
//! step,count`, `Moff`, `Mon`, `Mdelay=n`, `Mperiod=n`, `Mstep=n`, `Mcount=n` the vibrato; `[`,
//! `|` (leave on the last pass) and `]8` a loop; `stray_loop_end L` a loop end with no start;
//! `:L` a label and `jump L`; `fm3 a,b,c,d` FM3's special mode; `noise`; `pan left`; `pause`;
//! `env 3`; `set op2 sustain_rate 1` a tweak of an operator; `timer_b 198`; `lfo rate,fms,ams`;
//! `end`. A `;` starts a comment.
const std = @import("std");
const content = @import("content.zig");
const Event = content.Event;

pub const Error = error{ BadNotation, OutOfMemory };

/// Where a text was refused: its file, its line and why.
pub const Diagnostic = struct {
    file: []const u8 = "",
    line: u32 = 0,
    why: []const u8 = "",

    pub fn format(d: *const Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}:{d}: {s}", .{ d.file, d.line, d.why });
    }
};

const keys = [16][]const u8{ "c", "c+", "d", "d+", "e", "f", "f+", "g", "g+", "a", "a+", "b", "n12", "n13", "n14", "n15" };

const Kind = enum { fm, drums, psg };

// --- writing --------------------------------------------------------------------------------

const Writer = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    column: usize = 0,

    fn line(w: *Writer, comptime fmt: []const u8, args: anytype) !void {
        if (w.column != 0) try w.newline();
        try w.out.print(w.gpa, fmt, args);
        try w.newline();
    }

    fn newline(w: *Writer) !void {
        try w.out.append(w.gpa, '\n');
        w.column = 0;
    }

    /// A word of a track, wrapped at 100 columns.
    fn word(w: *Writer, comptime fmt: []const u8, args: anytype) !void {
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
        if (w.column != 0 and w.column + 1 + text.len > 100) try w.newline();
        if (w.column == 0) {
            try w.out.appendSlice(w.gpa, "  ");
            w.column = 2;
        } else {
            try w.out.append(w.gpa, ' ');
            w.column += 1;
        }
        try w.out.appendSlice(w.gpa, text);
        w.column += text.len;
    }
};

pub fn writeSong(gpa: std.mem.Allocator, s: *const content.Song) Error![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    try w.line("song {s}", .{s.name});
    try w.line("provenance \"{s}\"", .{s.provenance});
    for (s.instruments) |*i| try writeInstrument(&w, i);
    for (s.fm, 1..) |t, k| {
        try w.line("track fm{d} volume_offset {d}", .{ k, t.volume_offset });
        try writeEvents(&w, t.events, .fm);
    }
    try w.line("track drums volume_offset {d}", .{s.drums.volume_offset});
    try writeEvents(&w, s.drums.events, .drums);
    for (s.psg, 0..) |t, k| {
        try w.line("track tone{d} volume_offset {d} envelope {d}", .{ 2 - k, t.volume_offset, t.envelope });
        try writeEvents(&w, t.events, .psg);
    }
    return w.out.toOwnedSlice(gpa);
}

pub fn writeEffect(gpa: std.mem.Allocator, e: *const content.Effect) Error![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    try w.line("effect {s}", .{e.name});
    try w.line("provenance \"{s}\"", .{e.provenance});
    try w.line("channel {s} volume_offset {d}", .{ @tagName(e.channel), e.volume_offset });
    for (e.instruments) |*i| try writeInstrument(&w, i);
    try w.line("track", .{});
    try writeEvents(&w, e.events, .fm);
    return w.out.toOwnedSlice(gpa);
}

/// A list of instruments alone (the driver's songless list).
pub fn writeInstruments(gpa: std.mem.Allocator, list: []const content.Instrument) Error![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    for (list) |*i| try writeInstrument(&w, i);
    return w.out.toOwnedSlice(gpa);
}

fn writeInstrument(w: *Writer, i: *const content.Instrument) !void {
    try w.out.print(w.gpa, "instrument {d} algorithm {d} feedback {d}", .{ i.number, i.algorithm, i.feedback });
    if (i.borrowed) try w.out.appendSlice(w.gpa, " borrowed");
    if (i.ignored != 0) try w.out.print(w.gpa, " ignored {d}", .{i.ignored});
    try w.newline();
    for (i.operators, 1..) |o, k| {
        try w.out.print(w.gpa, "  op{d} detune {d} multiple {d} level {d} key_scale {d} attack {d} am {d} decay {d} sustain_rate {d} sustain_level {d} release {d}", .{ k, o.detune, o.multiple, o.level, o.key_scale, o.attack, @intFromBool(o.am), o.decay, o.sustain_rate, o.sustain_level, o.release });
        if (!std.mem.allEqual(u8, &o.ignored, 0)) {
            try w.out.print(w.gpa, " ignored {d},{d},{d},{d},{d},{d}", .{ o.ignored[0], o.ignored[1], o.ignored[2], o.ignored[3], o.ignored[4], o.ignored[5] });
        }
        try w.newline();
    }
}

fn writeEvents(w: *Writer, events: []const Event, kind: Kind) !void {
    // The labels: the targets of jumps and stray loop ends, named in their order.
    var labels: std.AutoArrayHashMapUnmanaged(u16, u16) = .empty;
    defer labels.deinit(w.gpa);
    for (events) |e| switch (e) {
        .jump => |to| try labels.put(w.gpa, to, 0),
        .loop_end => |l| if (!l.matched) try labels.put(w.gpa, l.to, 0),
        else => {},
    };
    labels.sort(struct {
        keys: []const u16,
        pub fn lessThan(c: @This(), a: usize, b: usize) bool {
            return c.keys[a] < c.keys[b];
        }
    }{ .keys = labels.keys() });
    for (labels.values(), 1..) |*v, n| v.* = @intCast(n);
    // The counts of the open loops, written at their ends.
    var counts: std.ArrayList(u8) = .empty;
    defer counts.deinit(w.gpa);
    var octave: ?u8 = null;
    for (events, 0..) |e, i| {
        if (labels.get(@intCast(i))) |n| try w.word(":L{d}", .{n});
        switch (e) {
            .note => |n| switch (kind) {
                .drums => try w.word("hit:{d}", .{n.duration}),
                .fm, .psg => {
                    const o: u8 = if (kind == .fm) n.octave else n.step / 12;
                    const key: u8 = if (kind == .fm) n.key else n.step % 12;
                    if (octave != o) try w.word("o{d}", .{o});
                    octave = o;
                    try w.word("{s}:{d}", .{ keys[key], n.duration });
                },
            },
            .rest => |n| try w.word("r:{d}", .{n}),
            .end => try w.word("end", .{}),
            .instrument => |n| try w.word("@{d}", .{n}),
            .drum => |n| try w.word("drum {d}", .{n}),
            .volume => |n| try w.word("v{d}", .{n}),
            .volume_add => |n| {
                const v: i8 = @bitCast(n);
                if (v < 0) try w.word("v-{d}", .{-@as(i16, v)}) else try w.word("v+{d}", .{v});
            },
            .detune => |d| try w.word("D{s}={d}", .{ if (d.add) "+" else "", d.value }),
            .gate => |n| try w.word("q{d}", .{n}),
            .vibrato => |v| switch (v) {
                .set => |p| try w.word("M={d},{d},{d},{d}", .{ p.delay, p.period, p.step, p.count }),
                .off => try w.word("Moff", .{}),
                .on => try w.word("Mon", .{}),
                .delay => |n| try w.word("Mdelay={d}", .{n}),
                .period => |n| try w.word("Mperiod={d}", .{n}),
                .step => |n| try w.word("Mstep={d}", .{n}),
                .count => |n| try w.word("Mcount={d}", .{n}),
            },
            .loop_start => |n| {
                try counts.append(w.gpa, n);
                try w.word("[", .{});
            },
            .loop_end => |l| if (l.matched) {
                try w.word("]{d}", .{counts.pop() orelse return error.BadNotation});
            } else try w.word("stray_loop_end L{d}", .{labels.get(l.to).?}),
            .loop_break => try w.word("|", .{}),
            .fm3 => |o| try w.word("fm3 {d},{d},{d},{d}", .{ o[0], o[1], o[2], o[3] }),
            .noise => try w.word("noise", .{}),
            .pan => |p| try w.word("pan {s}", .{@tagName(p)}),
            .pause => try w.word("pause", .{}),
            .envelope => |n| try w.word("env {d}", .{n}),
            .tweak => |t| switch (t) {
                .timer_b => |v| try w.word("timer_b {d}", .{v}),
                .operator => |o| {
                    const v = o.value;
                    const op = @tagName(o.operator);
                    switch (o.parameter) {
                        .detune_multiple => try w.word("set {s} detune {d} multiple {d}", .{ op, v >> 4 & 7, v & 15 }),
                        .level => try w.word("set {s} level {d}", .{ op, v }),
                        .key_scale_attack => try w.word("set {s} key_scale {d} attack {d}", .{ op, v >> 6, v & 31 }),
                        .am_decay => try w.word("set {s} am {d} decay {d}", .{ op, v >> 7, v & 31 }),
                        .sustain_rate => try w.word("set {s} sustain_rate {d}", .{ op, v }),
                        .sustain_level_release => try w.word("set {s} sustain_level {d} release {d}", .{ op, v >> 4, v & 15 }),
                    }
                },
            },
            .lfo => |l| try w.word("lfo {d},{d},{d}", .{ l.rate, l.fms, l.ams }),
            .tie => try w.word("&", .{}),
            .jump => |to| try w.word("jump L{d}", .{labels.get(to).?}),
        }
    }
    if (w.column != 0) try w.newline();
}

// --- reading --------------------------------------------------------------------------------

const Reader = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    diag: *Diagnostic,

    fn fail(r: *Reader, why: []const u8) Error {
        r.diag.line = r.line;
        r.diag.why = why;
        return error.BadNotation;
    }

    /// The next word, or null at the end; a quoted string is one word (quotes kept).
    fn next(r: *Reader) ?[]const u8 {
        while (r.pos < r.text.len) {
            const c = r.text[r.pos];
            if (c == ';') {
                while (r.pos < r.text.len and r.text[r.pos] != '\n') r.pos += 1;
            } else if (c == '\n') {
                r.line += 1;
                r.pos += 1;
            } else if (c == ' ' or c == '\t' or c == '\r') {
                r.pos += 1;
            } else break;
        }
        if (r.pos >= r.text.len) return null;
        const start = r.pos;
        if (r.text[r.pos] == '"') {
            r.pos += 1;
            while (r.pos < r.text.len and r.text[r.pos] != '"' and r.text[r.pos] != '\n') r.pos += 1;
            if (r.pos < r.text.len and r.text[r.pos] == '"') r.pos += 1;
            return r.text[start..r.pos];
        }
        while (r.pos < r.text.len and !std.ascii.isWhitespace(r.text[r.pos]) and r.text[r.pos] != ';') r.pos += 1;
        return r.text[start..r.pos];
    }

    fn peek(r: *Reader) ?[]const u8 {
        const saved = .{ r.pos, r.line };
        defer {
            r.pos = saved[0];
            r.line = saved[1];
        }
        return r.next();
    }

    fn word(r: *Reader) Error![]const u8 {
        return r.next() orelse r.fail("the text ends too early");
    }

    fn expect(r: *Reader, w: []const u8) Error!void {
        const got = try r.word();
        if (!std.mem.eql(u8, got, w)) {
            r.diag.line = r.line;
            r.diag.why = try std.fmt.allocPrint(r.arena, "expected '{s}', found '{s}'", .{ w, got });
            return error.BadNotation;
        }
    }

    fn int(r: *Reader, comptime T: type, text: []const u8) Error!T {
        return std.fmt.parseInt(T, text, 10) catch {
            r.diag.line = r.line;
            r.diag.why = try std.fmt.allocPrint(r.arena, "'{s}' is not a number of the field's range", .{text});
            return error.BadNotation;
        };
    }

    fn field(r: *Reader, comptime T: type, name: []const u8) Error!T {
        try r.expect(name);
        return r.int(T, try r.word());
    }

    fn list(r: *Reader, comptime T: type, comptime n: usize, text: []const u8) Error![n]T {
        var out: [n]T = undefined;
        var it = std.mem.splitScalar(u8, text, ',');
        for (&out) |*v| v.* = try r.int(T, it.next() orelse return r.fail("a list too short"));
        if (it.next() != null) return r.fail("a list too long");
        return out;
    }

    fn string(r: *Reader) Error![]const u8 {
        const w = try r.word();
        if (w.len < 2 or w[0] != '"' or w[w.len - 1] != '"') return r.fail("expected a quoted text");
        return w[1 .. w.len - 1];
    }
};

pub fn parseSong(arena: std.mem.Allocator, file: []const u8, text: []const u8, diag: *Diagnostic) Error!content.Song {
    diag.file = file;
    var r: Reader = .{ .arena = arena, .text = text, .diag = diag };
    try r.expect("song");
    var s: content.Song = .{ .name = try r.word(), .instruments = &.{}, .fm = undefined, .drums = undefined, .psg = &.{} };
    try r.expect("provenance");
    s.provenance = try r.string();
    s.instruments = try parseInstrumentList(&r);
    for (&s.fm, 1..) |*t, k| {
        try r.expect("track");
        try r.expect(try std.fmt.allocPrint(arena, "fm{d}", .{k}));
        t.* = .{ .volume_offset = try r.field(u8, "volume_offset"), .events = try parseEvents(&r, .fm) };
    }
    try r.expect("track");
    try r.expect("drums");
    s.drums = .{ .volume_offset = try r.field(u8, "volume_offset"), .events = try parseEvents(&r, .drums) };
    var psg: std.ArrayList(content.Track) = .empty;
    while (r.next()) |w| {
        if (!std.mem.eql(u8, w, "track")) return r.fail("expected a PSG track");
        try r.expect(([_][]const u8{ "tone2", "tone1", "tone0" })[@min(psg.items.len, 2)]);
        if (psg.items.len == 3) return r.fail("more than three PSG tracks");
        const volume_offset = try r.field(u8, "volume_offset");
        const envelope = try r.field(u8, "envelope");
        try psg.append(arena, .{ .volume_offset = volume_offset, .envelope = envelope, .events = try parseEvents(&r, .psg) });
    }
    s.psg = psg.items;
    return s;
}

pub fn parseEffect(arena: std.mem.Allocator, file: []const u8, text: []const u8, diag: *Diagnostic) Error!content.Effect {
    diag.file = file;
    var r: Reader = .{ .arena = arena, .text = text, .diag = diag };
    try r.expect("effect");
    const name = try r.word();
    try r.expect("provenance");
    const provenance = try r.string();
    try r.expect("channel");
    const channel = std.meta.stringToEnum(content.EffectChannel, try r.word()) orelse return r.fail("an effect's channel is fm3 or fm4");
    const volume_offset = try r.field(u8, "volume_offset");
    const instruments = try parseInstrumentList(&r);
    try r.expect("track");
    const events = try parseEvents(&r, .fm);
    if (r.next() != null) return r.fail("an effect has one track");
    return .{ .name = name, .provenance = provenance, .channel = channel, .volume_offset = volume_offset, .instruments = instruments, .events = events };
}

pub fn parseInstruments(arena: std.mem.Allocator, file: []const u8, text: []const u8, diag: *Diagnostic) Error![]const content.Instrument {
    diag.file = file;
    var r: Reader = .{ .arena = arena, .text = text, .diag = diag };
    const list = try parseInstrumentList(&r);
    if (r.next() != null) return r.fail("expected an instrument");
    return list;
}

fn parseInstrumentList(r: *Reader) Error![]const content.Instrument {
    var list: std.ArrayList(content.Instrument) = .empty;
    while (r.peek()) |w| {
        if (!std.mem.eql(u8, w, "instrument")) break;
        _ = r.next();
        var i: content.Instrument = .{
            .number = try r.int(u8, try r.word()),
            .algorithm = try r.field(u3, "algorithm"),
            .feedback = try r.field(u3, "feedback"),
            .operators = undefined,
        };
        if (r.peek()) |p| if (std.mem.eql(u8, p, "borrowed")) {
            _ = r.next();
            i.borrowed = true;
        };
        if (r.peek()) |p| if (std.mem.eql(u8, p, "ignored")) {
            _ = r.next();
            i.ignored = try r.int(u8, try r.word());
        };
        for (&i.operators, 1..) |*o, k| {
            try r.expect(([_][]const u8{ "", "op1", "op2", "op3", "op4" })[k]);
            o.* = .{
                .detune = try r.field(u3, "detune"),
                .multiple = try r.field(u4, "multiple"),
                .level = try r.field(u7, "level"),
                .key_scale = try r.field(u2, "key_scale"),
                .attack = try r.field(u5, "attack"),
                .am = try r.field(u1, "am") != 0,
                .decay = try r.field(u5, "decay"),
                .sustain_rate = try r.field(u5, "sustain_rate"),
                .sustain_level = try r.field(u4, "sustain_level"),
                .release = try r.field(u4, "release"),
            };
            if (r.peek()) |p| if (std.mem.eql(u8, p, "ignored")) {
                _ = r.next();
                o.ignored = try r.list(u8, 6, try r.word());
            };
        }
        for (list.items) |other| if (other.number == i.number) return r.fail("an instrument's number given twice");
        try list.append(r.arena, i);
    }
    return list.items;
}

/// A track's events, up to the next `track` or the end of the text.
fn parseEvents(r: *Reader, kind: Kind) Error![]const Event {
    var events: std.ArrayList(Event) = .empty;
    var labels: std.StringHashMapUnmanaged(u16) = .empty;
    // Jumps and stray loop ends waiting for their label.
    const Pending = struct { event: usize, label: []const u8, line: u32 };
    var pending: std.ArrayList(Pending) = .empty;
    // The open loops: their start's index, and their breaks.
    var open: std.ArrayList(usize) = .empty;
    var breaks: std.ArrayList([2]usize) = .empty;
    var octave: ?u8 = null;
    while (r.peek()) |w| {
        if (std.mem.eql(u8, w, "track")) break;
        _ = r.next();
        if (events.items.len >= std.math.maxInt(u16)) return r.fail("a track too long");
        const here: u16 = @intCast(events.items.len);
        if (w[0] == ':') {
            const gop = try labels.getOrPut(r.arena, w[1..]);
            if (gop.found_existing) return r.fail("a label defined twice");
            gop.value_ptr.* = here;
            continue;
        }
        const e: Event = blk: {
            if (w[0] == 'o' and w.len > 1 and std.ascii.isDigit(w[1])) {
                octave = try r.int(u8, w[1..]);
                if (octave.? > (if (kind == .fm) @as(u8, 7) else 10)) return r.fail("an octave out of range");
                continue;
            }
            if (std.mem.indexOfScalar(u8, w, ':')) |colon| {
                const name = w[0..colon];
                const n = try r.int(u16, w[colon + 1 ..]);
                if (std.mem.eql(u8, name, "r")) {
                    if (n < 1 or n > 256) return r.fail("a rest of 1 to 256 updates");
                    break :blk .{ .rest = n };
                }
                if (n < 1 or n > 127) return r.fail("a note of 1 to 127 updates");
                const duration: u8 = @intCast(n);
                if (kind == .drums) {
                    if (!std.mem.eql(u8, name, "hit")) return r.fail("a drum track's notes are hits");
                    break :blk .{ .note = .{ .duration = duration } };
                }
                const key = for (keys, 0..) |k, i| {
                    if (std.mem.eql(u8, k, name)) break i;
                } else return r.fail("an unknown note");
                const o = octave orelse return r.fail("a note before its octave");
                if (kind == .fm) break :blk .{ .note = .{ .duration = duration, .octave = @intCast(o), .key = @intCast(key) } };
                if (key > 11) return r.fail("the PSG's notes are c to b");
                const step = @as(u16, o) * 12 + key;
                if (step > 120) return r.fail("a PSG note past the table");
                break :blk .{ .note = .{ .duration = duration, .step = @intCast(step) } };
            }
            if (std.mem.eql(u8, w, "&")) break :blk .tie;
            if (std.mem.eql(u8, w, "end")) break :blk .end;
            if (std.mem.eql(u8, w, "noise")) break :blk .noise;
            if (std.mem.eql(u8, w, "pause")) break :blk .pause;
            if (std.mem.eql(u8, w, "Moff")) break :blk .{ .vibrato = .off };
            if (std.mem.eql(u8, w, "Mon")) break :blk .{ .vibrato = .on };
            if (std.mem.eql(u8, w, "[")) {
                try open.append(r.arena, here);
                break :blk .{ .loop_start = 0 };
            }
            if (std.mem.eql(u8, w, "|")) {
                if (open.items.len == 0) return r.fail("a loop break outside a loop");
                try breaks.append(r.arena, .{ here, open.items[open.items.len - 1] });
                break :blk .{ .loop_break = 0 };
            }
            if (w[0] == ']') {
                const start = open.pop() orelse return r.fail("a loop end without its start");
                events.items[start].loop_start = try r.int(u8, w[1..]);
                while (breaks.items.len != 0 and breaks.items[breaks.items.len - 1][1] == start) {
                    events.items[breaks.pop().?[0]].loop_break = here + 1;
                }
                break :blk .{ .loop_end = .{ .to = @intCast(start + 1) } };
            }
            if (w[0] == '@') break :blk .{ .instrument = try r.int(u8, w[1..]) };
            if (std.mem.startsWith(u8, w, "v+")) break :blk .{ .volume_add = @bitCast(try r.int(i8, w[2..])) };
            if (std.mem.startsWith(u8, w, "v-")) break :blk .{ .volume_add = @bitCast(-try r.int(i8, w[2..])) };
            if (w[0] == 'v') break :blk .{ .volume = try r.int(u8, w[1..]) };
            if (w[0] == 'q') break :blk .{ .gate = try r.int(u8, w[1..]) };
            if (std.mem.startsWith(u8, w, "D+=")) break :blk .{ .detune = .{ .value = try r.int(i16, w[3..]), .add = true } };
            if (std.mem.startsWith(u8, w, "D=")) break :blk .{ .detune = .{ .value = try r.int(i16, w[2..]), .add = false } };
            if (std.mem.startsWith(u8, w, "M=")) {
                var it = std.mem.splitScalar(u8, w[2..], ',');
                const delay = try r.int(u8, it.next() orelse "");
                const period = try r.int(u8, it.next() orelse "");
                const step = try r.int(i16, it.next() orelse "");
                const count = try r.int(u8, it.next() orelse "");
                if (it.next() != null) return r.fail("a vibrato of four values");
                break :blk .{ .vibrato = .{ .set = .{ .delay = delay, .period = period, .step = step, .count = count } } };
            }
            if (std.mem.startsWith(u8, w, "Mdelay=")) break :blk .{ .vibrato = .{ .delay = try r.int(u8, w[7..]) } };
            if (std.mem.startsWith(u8, w, "Mperiod=")) break :blk .{ .vibrato = .{ .period = try r.int(u8, w[8..]) } };
            if (std.mem.startsWith(u8, w, "Mstep=")) break :blk .{ .vibrato = .{ .step = try r.int(i16, w[6..]) } };
            if (std.mem.startsWith(u8, w, "Mcount=")) break :blk .{ .vibrato = .{ .count = try r.int(u8, w[7..]) } };
            if (std.mem.eql(u8, w, "drum")) break :blk .{ .drum = try r.int(u8, try r.word()) };
            if (std.mem.eql(u8, w, "env")) break :blk .{ .envelope = try r.int(u8, try r.word()) };
            if (std.mem.eql(u8, w, "timer_b")) break :blk .{ .tweak = .{ .timer_b = try r.int(u8, try r.word()) } };
            if (std.mem.eql(u8, w, "pan")) break :blk .{ .pan = std.meta.stringToEnum(content.Speakers, try r.word()) orelse return r.fail("a pan is both, left, right or none") };
            if (std.mem.eql(u8, w, "fm3")) break :blk .{ .fm3 = try r.list(u8, 4, try r.word()) };
            if (std.mem.eql(u8, w, "lfo")) {
                const l = try r.list(u8, 3, try r.word());
                break :blk .{ .lfo = .{ .rate = l[0], .fms = l[1], .ams = l[2] } };
            }
            if (std.mem.eql(u8, w, "set")) break :blk .{ .tweak = try parseTweak(r) };
            if (std.mem.eql(u8, w, "jump") or std.mem.eql(u8, w, "stray_loop_end")) {
                try pending.append(r.arena, .{ .event = here, .label = try r.word(), .line = r.line });
                break :blk if (w[0] == 'j') .{ .jump = 0 } else .{ .loop_end = .{ .to = 0, .matched = false } };
            }
            r.diag.line = r.line;
            r.diag.why = try std.fmt.allocPrint(r.arena, "an unknown word '{s}'", .{w});
            return error.BadNotation;
        };
        try events.append(r.arena, e);
    }
    if (open.items.len != 0) return r.fail("a loop start without its end");
    for (pending.items) |p| {
        const to = labels.get(p.label) orelse {
            r.line = p.line;
            return r.fail("a jump to a label the track does not have");
        };
        switch (events.items[p.event]) {
            .jump => events.items[p.event].jump = to,
            else => events.items[p.event].loop_end.to = to,
        }
    }
    return events.items;
}

fn parseTweak(r: *Reader) Error!content.Tweak {
    const op = std.meta.stringToEnum(content.OperatorName, try r.word()) orelse return r.fail("an operator is op1 to op4");
    const first = try r.word();
    const two = struct {
        fn pair(rd: *Reader, a: u8, comptime second: []const u8, comptime shift: u3, comptime max_a: u8, comptime max_b: u8) Error!u8 {
            const b = try rd.field(u8, second);
            if (a > max_a or b > max_b) return rd.fail("a parameter out of its range");
            return a << shift | b;
        }
    };
    const a = try r.int(u8, try r.word());
    const p: content.Parameter, const v: u8 = if (std.mem.eql(u8, first, "detune"))
        .{ .detune_multiple, try two.pair(r, a, "multiple", 4, 7, 15) }
    else if (std.mem.eql(u8, first, "level"))
        .{ .level, if (a > 127) return r.fail("a level of 0 to 127") else a }
    else if (std.mem.eql(u8, first, "key_scale"))
        .{ .key_scale_attack, try two.pair(r, a, "attack", 6, 3, 31) }
    else if (std.mem.eql(u8, first, "am"))
        .{ .am_decay, try two.pair(r, a, "decay", 7, 1, 31) }
    else if (std.mem.eql(u8, first, "sustain_rate"))
        .{ .sustain_rate, if (a > 31) return r.fail("a sustain rate of 0 to 31") else a }
    else if (std.mem.eql(u8, first, "sustain_level"))
        .{ .sustain_level_release, try two.pair(r, a, "release", 4, 15, 15) }
    else
        return r.fail("an unknown operator parameter");
    return .{ .operator = .{ .operator = op, .parameter = p, .value = v } };
}

// --- tests: made-up items ---------------------------------------------------------------------

const testing = std.testing;

fn expectSameEvents(a: []const Event, b: []const Event) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expectEqual(x, y);
}

test "a song written then read gives the same song" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fm1 = [_]Event{
        .{ .instrument = 0 },                                     .{ .tweak = .{ .operator = .{ .operator = .op2, .parameter = .sustain_rate, .value = 1 } } },
        .{ .volume = 15 },                                        .{ .gate = 3 },
        .{ .loop_start = 8 },                                     .{ .rest = 111 },
        .{ .loop_break = 9 },                                     .{ .note = .{ .duration = 29, .octave = 2, .key = 9 } },
        .{ .loop_end = .{ .to = 5 } },                            .tie,
        .{ .note = .{ .duration = 12, .octave = 3, .key = 13 } }, .{ .volume_add = @bitCast(@as(i8, -2)) },
        .{ .detune = .{ .value = -10, .add = true } },            .{ .vibrato = .{ .set = .{ .delay = 20, .period = 1, .step = -12, .count = 6 } } },
        .{ .vibrato = .off },                                     .{ .fm3 = .{ 100, 0, 250, 0 } },
        .{ .pan = .left },                                        .{ .lfo = .{ .rate = 3, .fms = 4, .ams = 0 } },
        .{ .tweak = .{ .timer_b = 198 } },                        .{ .tweak = .{ .operator = .{ .operator = .op4, .parameter = .am_decay, .value = 0x84 } } },
        .pause,                                                   .{ .jump = 5 },
    };
    const drums = [_]Event{ .{ .drum = 1 }, .{ .volume = 54 }, .{ .note = .{ .duration = 20 } }, .{ .rest = 256 }, .end };
    const stray = [_]Event{ .noise, .{ .envelope = 3 }, .{ .note = .{ .duration = 53, .step = 120 } }, .{ .loop_end = .{ .to = 1, .matched = false } }, .{ .jump = 0 } };
    var instrument: content.Instrument = .{ .number = 0, .algorithm = 6, .feedback = 3, .operators = .{ .{ .level = 23, .attack = 31 }, .{ .detune = 7, .multiple = 15, .am = true }, .{ .sustain_level = 15, .release = 8 }, .{ .decay = 10, .sustain_rate = 14 } } };
    instrument.operators[2].ignored = .{ 128, 0, 32, 0, 0, 0 };
    var borrowed = instrument;
    borrowed.number = 9;
    borrowed.borrowed = true;
    borrowed.ignored = 192;
    const resting = [_]Event{ .{ .rest = 1 }, .end };
    const song: content.Song = .{
        .name = "test_song",
        .provenance = "made up",
        .instruments = &.{ instrument, borrowed },
        .fm = .{ .{ .volume_offset = 4, .events = &fm1 }, .{ .events = &resting }, .{ .events = &resting }, .{ .events = &resting }, .{ .volume_offset = 255, .events = &resting } },
        .drums = .{ .events = &drums },
        .psg = &.{ .{ .volume_offset = 15, .envelope = 3, .events = &stray }, .{ .events = &resting } },
    };
    const text = try writeSong(arena, &song);
    var diag: Diagnostic = .{};
    const back = parseSong(arena, "test.txt", text, &diag) catch |err| {
        std.debug.print("{f}\n{s}\n", .{ diag, text });
        return err;
    };
    try testing.expectEqualStrings(song.name, back.name);
    try testing.expectEqualStrings(song.provenance, back.provenance);
    try testing.expectEqual(song.instruments.len, back.instruments.len);
    for (song.instruments, back.instruments) |a, b| try testing.expectEqual(a, b);
    for (song.fm, back.fm) |a, b| {
        try testing.expectEqual(a.volume_offset, b.volume_offset);
        try expectSameEvents(a.events, b.events);
    }
    try expectSameEvents(song.drums.events, back.drums.events);
    try testing.expectEqual(@as(usize, 2), back.psg.len);
    try testing.expectEqual(@as(u8, 3), back.psg[0].envelope);
    try expectSameEvents(&stray, back.psg[0].events);
    // The text reads as music.
    try testing.expect(std.mem.indexOf(u8, text, "[ :L1 r:111 | o2 a:29 ]8 & o3 n13:12 v-2 D+=-10") != null);
    try testing.expect(std.mem.indexOf(u8, text, "stray_loop_end L") != null);
}

test "an effect written then read; refusals name the line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const events = [_]Event{ .{ .instrument = 3 }, .{ .note = .{ .duration = 1, .octave = 7, .key = 0 } }, .end };
    const i: content.Instrument = .{ .number = 3, .algorithm = 7, .feedback = 0, .operators = @splat(.{}) };
    const effect: content.Effect = .{ .name = "beep", .provenance = "made up", .channel = .fm4, .volume_offset = 2, .instruments = &.{i}, .events = &events };
    const text = try writeEffect(arena, &effect);
    var diag: Diagnostic = .{};
    const back = try parseEffect(arena, "beep.txt", text, &diag);
    try testing.expectEqual(content.EffectChannel.fm4, back.channel);
    try expectSameEvents(&events, back.events);
    try testing.expectError(error.BadNotation, parseEffect(arena, "bad.txt", "effect x\nprovenance \"p\"\nchannel fm3 volume_offset 0\ntrack\n  o8 c:1\n", &diag));
    try testing.expectEqual(@as(u32, 5), diag.line);
    try testing.expectError(error.BadNotation, parseEffect(arena, "bad.txt", "effect x\nprovenance \"p\"\nchannel fm3 volume_offset 0\ntrack\n  jump nowhere\n", &diag));
    try testing.expectError(error.BadNotation, parseEffect(arena, "bad.txt", "effect x\nprovenance \"p\"\nchannel fm3 volume_offset 0\ntrack\n  [ c:1\n", &diag));
}

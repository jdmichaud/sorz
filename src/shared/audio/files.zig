//! The sound content's files in the content tree (docs/content-sound.md), written and loaded:
//!
//! - `sound/sounds.json`: the names the game asks for, each with what it plays and its priority;
//! - `sound/songs/NAME.txt`, `sound/effects/NAME.txt`: the songs and effects (notation.zig);
//! - `sound/driver.json`: the driver's tables; `sound/songless_instruments.txt`;
//! - `sound/samples.json` and `sound/samples/NAME.wav`: the samples, their pace and timing.
const std = @import("std");
const content = @import("content.zig");
const notation = @import("notation.zig");
const wav = @import("wav.zig");
const json = @import("../formats/json.zig");
const platform = @import("../platform.zig");
const Value = json.Value;

pub const File = struct { path: []const u8, bytes: []const u8 };

pub const Error = error{ BadAsset, BadNotation, OutOfMemory };

const pace_letters = "HLRrSs";

/// A sample's nominal rate, for listening to its file: the Z80 clock over the cycles of a byte of
/// two nonzero codes (432 and 26 per unit of delay, 12 more through the bank), two values each.
pub fn nominalRate(delay: u8, banked: bool) u32 {
    const per_byte: u64 = 432 + 26 * @as(u64, delay) + @as(u64, if (banked) 12 else 0);
    const num: u64 = 2 * 53_693_175;
    const den: u64 = 15 * per_byte;
    return @intCast((num + den / 2) / den);
}

// --- writing --------------------------------------------------------------------------------

pub fn write(arena: std.mem.Allocator, c: *const content.Content) Error![]const File {
    var files: std.ArrayList(File) = .empty;
    const add = struct {
        fn json_(a: std.mem.Allocator, list: *std.ArrayList(File), path: []const u8, v: Value) Error!void {
            const bytes = json.write(a, v) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.BadAsset,
            };
            try list.append(a, .{ .path = path, .bytes = bytes });
        }
    };

    var sounds: std.ArrayList(Value) = .empty;
    for (c.sounds) |s| {
        const plays: Value = switch (s.plays) {
            .song => |n| try object(arena, &.{.{ .key = "song", .value = .{ .str = c.songs[n].name } }}),
            .effect => |n| try object(arena, &.{.{ .key = "effect", .value = .{ .str = c.effects[n].name } }}),
            .sample => |n| try object(arena, &.{.{ .key = "sample", .value = .num(n) }}),
            .fade_out, .stop, .stop_effects => try object(arena, &.{.{ .key = "command", .value = .{ .str = @tagName(s.plays) } }}),
        };
        var fields: std.ArrayList(json.Field) = .empty;
        try fields.appendSlice(arena, &.{
            .{ .key = "name", .value = .{ .str = s.name } },
            .{ .key = "priority", .value = .num(s.priority) },
            .{ .key = "plays", .value = plays },
            .{ .key = "provenance", .value = .{ .str = s.provenance } },
        });
        if (s.request) |r| try fields.append(arena, .{ .key = "request", .value = .num(r) });
        try sounds.append(arena, try object(arena, fields.items));
    }
    try add.json_(arena, &files, "sound/sounds.json", try object(arena, &.{.{ .key = "sounds", .value = .{ .array = sounds.items } }}));

    for (c.songs) |*s| try files.append(arena, .{
        .path = try std.fmt.allocPrint(arena, "sound/songs/{s}.txt", .{s.name}),
        .bytes = try notation.writeSong(arena, s),
    });
    for (c.effects) |*e| try files.append(arena, .{
        .path = try std.fmt.allocPrint(arena, "sound/effects/{s}.txt", .{e.name}),
        .bytes = try notation.writeEffect(arena, e),
    });

    const d = &c.driver;
    var carriers: std.ArrayList(Value) = .empty;
    for (d.carriers) |algorithm| {
        var ops: std.ArrayList(Value) = .empty;
        for (algorithm, 0..) |is, k| if (is) try ops.append(arena, .{ .str = @tagName(@as(content.OperatorName, @fromBackingInt(@intCast(k)))) });
        try carriers.append(arena, .{ .array = ops.items });
    }
    var fm3: [4]Value = undefined;
    for (&fm3, d.fm3_operators) |*v, op| v.* = .{ .str = @tagName(op) };
    var envelopes: std.ArrayList(Value) = .empty;
    for (d.envelopes) |env| {
        var reads: [256]Value = undefined;
        for (&reads, env.reads) |*v, r| v.* = switch (r.kind) {
            .step => .num(r.value),
            else => .{ .str = @tagName(r.kind) },
        };
        try envelopes.append(arena, try object(arena, &.{
            .{ .key = "length", .value = .num(env.length) },
            .{ .key = "reads", .value = .{ .array = try arena.dupe(Value, &reads) } },
        }));
    }
    try add.json_(arena, &files, "sound/driver.json", try object(arena, &.{
        .{ .key = "fm_keys", .value = try numbers(arena, &d.fm_keys) },
        .{ .key = "psg_steps", .value = try numbers(arena, &d.psg_steps) },
        .{ .key = "volume_levels", .value = try numbers(arena, &d.volume_levels) },
        .{ .key = "carriers", .value = .{ .array = carriers.items } },
        .{ .key = "fm3_operators", .value = .{ .array = try arena.dupe(Value, &fm3) } },
        .{ .key = "envelopes", .value = .{ .array = envelopes.items } },
        .{ .key = "provenance", .value = .{ .str = d.provenance } },
    }));
    try files.append(arena, .{ .path = "sound/songless_instruments.txt", .bytes = try notation.writeInstruments(arena, d.songless_instruments) });

    var samples: std.ArrayList(Value) = .empty;
    for (c.samples) |s| {
        const pace = try arena.alloc(u8, s.pace.len);
        for (pace, s.pace) |*l, p| l.* = pace_letters[@backingInt(p)];
        var file: Value = .null;
        if (s.values.len != 0) {
            const path = try std.fmt.allocPrint(arena, "samples/{s}.wav", .{s.name});
            try files.append(arena, .{
                .path = try std.fmt.allocPrint(arena, "sound/{s}", .{path}),
                .bytes = try wav.write(arena, s.values, nominalRate(s.delay, s.banked)),
            });
            file = .{ .str = path };
        }
        try samples.append(arena, try object(arena, &.{
            .{ .key = "number", .value = .num(s.number) },
            .{ .key = "name", .value = .{ .str = s.name } },
            .{ .key = "wav", .value = file },
            .{ .key = "delay", .value = .num(s.delay) },
            .{ .key = "banked", .value = .{ .bool = s.banked } },
            .{ .key = "voice", .value = .{ .bool = s.voice } },
            .{ .key = "pace", .value = .{ .str = pace } },
            .{ .key = "provenance", .value = .{ .str = s.provenance } },
        }));
    }
    try add.json_(arena, &files, "sound/samples.json", try object(arena, &.{.{ .key = "samples", .value = .{ .array = samples.items } }}));
    return files.items;
}

fn object(arena: std.mem.Allocator, fields: []const json.Field) Error!Value {
    return .{ .object = try arena.dupe(json.Field, fields) };
}

fn numbers(arena: std.mem.Allocator, list: anytype) Error!Value {
    const out = try arena.alloc(Value, list.len);
    for (out, list) |*v, n| v.* = .num(n);
    return .{ .array = out };
}

// --- loading --------------------------------------------------------------------------------

/// The sound content from its files: `source.read(path)` gives a file's bytes (they must outlive
/// the content). A refusal names the file and the field or line in `diag`.
pub fn load(arena: std.mem.Allocator, source: anytype, diag: *json.Diagnostic) Error!content.Content {
    var c: content.Content = .{ .driver = .{} };
    const sounds = try parseJson(arena, source, "sound/sounds.json", diag);
    try sounds.only(&.{"sounds"});
    const list = try sounds.get("sounds");
    var song_names: std.ArrayList([]const u8) = .empty;
    var effect_names: std.ArrayList([]const u8) = .empty;
    const out = try arena.alloc(content.Sound, try list.len());
    for (out, 0..) |*s, i| {
        const n = try list.at(i);
        try n.only(&.{ "name", "priority", "plays", "request", "provenance" });
        const plays = try n.get("plays");
        try plays.only(&.{ "song", "effect", "sample", "command" });
        s.* = .{
            .name = try (try n.get("name")).string(),
            .priority = try (try n.get("priority")).int(u8),
            .request = if (try n.opt("request")) |r| try r.int(u8) else null,
            .provenance = if (try n.opt("provenance")) |p| try p.string() else "",
            .plays = if (try plays.opt("song")) |song|
                .{ .song = try indexOf(arena, &song_names, try song.string()) }
            else if (try plays.opt("effect")) |effect|
                .{ .effect = try indexOf(arena, &effect_names, try effect.string()) }
            else if (try plays.opt("sample")) |sample|
                .{ .sample = try sample.int(u8) }
            else if (try plays.opt("command")) |command| blk: {
                const k = std.meta.stringToEnum(Command, try command.string()) orelse return command.fail("not a command");
                break :blk commandOf(k);
            } else return plays.fail("plays nothing"),
        };
        for (out[0..i]) |other| if (std.mem.eql(u8, other.name, s.name)) return (try n.get("name")).fail("a name given twice");
    }
    c.sounds = out;

    const songs = try arena.alloc(content.Song, song_names.items.len);
    for (songs, song_names.items) |*s, name| {
        const path = try std.fmt.allocPrint(arena, "sound/songs/{s}.txt", .{name});
        var d: notation.Diagnostic = .{};
        s.* = notation.parseSong(arena, path, try readFile(source, path, diag), &d) catch |e| return textError(e, &d, diag);
        if (!std.mem.eql(u8, s.name, name)) return textError(error.BadNotation, &.{ .file = path, .line = 1, .why = "the song's name is not its file's" }, diag);
    }
    c.songs = songs;
    const effects = try arena.alloc(content.Effect, effect_names.items.len);
    for (effects, effect_names.items) |*e, name| {
        const path = try std.fmt.allocPrint(arena, "sound/effects/{s}.txt", .{name});
        var d: notation.Diagnostic = .{};
        e.* = notation.parseEffect(arena, path, try readFile(source, path, diag), &d) catch |err| return textError(err, &d, diag);
        if (!std.mem.eql(u8, e.name, name)) return textError(error.BadNotation, &.{ .file = path, .line = 1, .why = "the effect's name is not its file's" }, diag);
    }
    c.effects = effects;

    c.driver = try loadDriver(arena, source, diag);
    c.samples = try loadSamples(arena, source, diag);
    return c;
}

const Command = enum { fade_out, stop, stop_effects };

/// The sound content from the game's asset source (the content tree).
pub fn loadAssets(arena: std.mem.Allocator, assets: platform.AssetSource, diag: *json.Diagnostic) Error!content.Content {
    return load(arena, AssetReader{ .arena = arena, .assets = assets }, diag);
}

/// The files of an asset source, copied into the arena.
const AssetReader = struct {
    arena: std.mem.Allocator,
    assets: platform.AssetSource,

    pub fn read(r: AssetReader, path: []const u8) platform.AssetError![]const u8 {
        var owned = try r.assets.readAll(path, 16 << 20);
        defer owned.deinit();
        return r.arena.dupe(u8, owned.bytes);
    }
};

fn commandOf(k: Command) content.Plays {
    return switch (k) {
        .fade_out => .fade_out,
        .stop => .stop,
        .stop_effects => .stop_effects,
    };
}

fn indexOf(arena: std.mem.Allocator, names: *std.ArrayList([]const u8), name: []const u8) Error!u16 {
    for (names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
    try names.append(arena, name);
    return @intCast(names.items.len - 1);
}

/// A file of `source` (its `read` fails with the asset sources' errors), told apart when it
/// cannot be read: missing, its name refused, too large; out of memory is no fault of the file.
fn readFile(source: anytype, path: []const u8, diag: *json.Diagnostic) Error![]const u8 {
    return source.read(path) catch |e| {
        diag.* = .{ .file = path, .message = switch (@as(platform.AssetError, e)) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotFound => "missing",
            error.InvalidName => "not a valid file name",
            error.TooLarge => "too large",
            else => "cannot be read",
        } };
        return error.BadAsset;
    };
}

fn parseJson(arena: std.mem.Allocator, source: anytype, path: []const u8, diag: *json.Diagnostic) Error!json.Node {
    return json.parse(arena, path, try readFile(source, path, diag), diag);
}

fn textError(err: notation.Error, d: *const notation.Diagnostic, diag: *json.Diagnostic) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    diag.* = .{ .file = d.file, .message = d.why };
    diag.setPlace("line {d}", .{d.line});
    return error.BadAsset;
}

fn loadDriver(arena: std.mem.Allocator, source: anytype, diag: *json.Diagnostic) Error!content.Driver {
    var d: content.Driver = .{};
    const n = try parseJson(arena, source, "sound/driver.json", diag);
    try n.only(&.{ "fm_keys", "psg_steps", "volume_levels", "carriers", "fm3_operators", "envelopes", "provenance" });
    try intList(u16, &d.fm_keys, try n.get("fm_keys"));
    try intList(u16, &d.psg_steps, try n.get("psg_steps"));
    try intList(u8, &d.volume_levels, try n.get("volume_levels"));
    const carriers = try n.get("carriers");
    if (try carriers.len() != 8) return carriers.fail("eight algorithms");
    for (&d.carriers, 0..) |*c, alg| {
        const ops = try carriers.at(alg);
        for (0..try ops.len()) |k| {
            const op = try ops.at(k);
            c[@backingInt(try operator(op))] = true;
        }
    }
    const fm3 = try n.get("fm3_operators");
    if (try fm3.len() != 4) return fm3.fail("four operators");
    for (&d.fm3_operators, 0..) |*o, k| o.* = try operator(try fm3.at(k));
    const envelopes = try n.get("envelopes");
    if (try envelopes.len() != 5) return envelopes.fail("five envelopes");
    for (&d.envelopes, 0..) |*env, k| {
        const e = try envelopes.at(k);
        try e.only(&.{ "length", "reads" });
        env.length = try (try e.get("length")).int(u16);
        const reads = try e.get("reads");
        if (try reads.len() != 256) return reads.fail("256 reads");
        for (&env.reads, 0..) |*r, i| {
            const v = try reads.at(i);
            r.* = switch (v.value) {
                .string => .{ .kind = std.meta.stringToEnum(content.Read.Kind, try v.string()) orelse return v.fail("not a read") },
                else => .{ .kind = .step, .value = try v.int(u8) },
            };
        }
    }
    d.provenance = if (try n.opt("provenance")) |p| try p.string() else "";
    var td: notation.Diagnostic = .{};
    const path = "sound/songless_instruments.txt";
    d.songless_instruments = notation.parseInstruments(arena, path, try readFile(source, path, diag), &td) catch |e| return textError(e, &td, diag);
    return d;
}

fn operator(n: json.Node) Error!content.OperatorName {
    return std.meta.stringToEnum(content.OperatorName, try n.string()) orelse n.fail("not an operator");
}

fn intList(comptime T: type, out: []T, n: json.Node) Error!void {
    if (try n.len() != out.len) return n.fail("not of the table's length");
    for (out, 0..) |*v, i| v.* = try (try n.at(i)).int(T);
}

fn loadSamples(arena: std.mem.Allocator, source: anytype, diag: *json.Diagnostic) Error![]const content.Sample {
    const n = try parseJson(arena, source, "sound/samples.json", diag);
    try n.only(&.{"samples"});
    const list = try n.get("samples");
    const out = try arena.alloc(content.Sample, try list.len());
    for (out, 0..) |*s, i| {
        const e = try list.at(i);
        try e.only(&.{ "number", "name", "wav", "delay", "banked", "voice", "pace", "provenance" });
        s.* = .{
            .number = try (try e.get("number")).int(u8),
            .name = try (try e.get("name")).string(),
            .delay = try (try e.get("delay")).int(u8),
            .banked = try (try e.get("banked")).boolean(),
            .voice = try (try e.get("voice")).boolean(),
            .provenance = if (try e.opt("provenance")) |p| try p.string() else "",
        };
        if (s.number >= 32) return (try e.get("number")).fail("a sample's number is below 32");
        for (out[0..i]) |other| if (other.number == s.number) return (try e.get("number")).fail("a number given twice");
        if (try e.opt("wav")) |file| {
            const path = try std.fmt.allocPrint(arena, "sound/{s}", .{try file.string()});
            s.values = (wav.read(try readFile(source, path, diag)) catch return file.fail("not an 8-bit mono PCM file")).values;
        }
        const letters = try (try e.get("pace")).string();
        const pace = try arena.alloc(content.Pace, letters.len);
        for (pace, letters) |*p, l| p.* = @fromBackingInt(@intCast(std.mem.indexOfScalar(u8, pace_letters, l) orelse return (try e.get("pace")).fail("a pace is letters of HLRrSs")));
        if (pace.len != s.values.len) return (try e.get("pace")).fail("not one letter per value");
        s.pace = pace;
    }
    return out;
}

// --- tests -----------------------------------------------------------------------------------

const testing = std.testing;

const MemorySource = struct {
    files: []const File,
    pub fn read(m: MemorySource, path: []const u8) platform.AssetError![]const u8 {
        for (m.files) |f| if (std.mem.eql(u8, f.path, path)) return f.bytes;
        return error.NotFound;
    }
};

test "the content written to its files and loaded gives the same files" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const events = [_]content.Event{ .{ .instrument = 0 }, .{ .note = .{ .duration = 4, .octave = 3, .key = 2 } }, .end };
    const resting = [_]content.Event{ .{ .rest = 9 }, .end };
    const instrument: content.Instrument = .{ .number = 0, .algorithm = 7, .feedback = 1, .operators = @splat(.{ .attack = 31 }) };
    var driver: content.Driver = .{ .provenance = "made up", .songless_instruments = &.{instrument} };
    driver.fm_keys[3] = 644;
    driver.carriers[7] = .{ true, true, true, true };
    driver.envelopes[1].reads[0] = .{ .kind = .step, .value = 3 };
    const c: content.Content = .{
        .driver = driver,
        .songs = &.{.{ .name = "tune", .instruments = &.{instrument}, .fm = @splat(.{ .events = &resting }), .drums = .{ .events = &resting }, .psg = &.{} }},
        .effects = &.{.{ .name = "beep", .channel = .fm3, .volume_offset = 1, .instruments = &.{instrument}, .events = &events }},
        .samples = &.{
            .{ .number = 1, .name = "drum", .values = &.{ 129, 131 }, .pace = &.{ .first, .second }, .delay = 2 },
            .{ .number = 4, .name = "empty" },
        },
        .sounds = &.{
            .{ .name = "tune", .priority = 128, .plays = .{ .song = 0 } },
            .{ .name = "beep", .priority = 63, .plays = .{ .effect = 0 } },
            .{ .name = "drum", .priority = 114, .plays = .{ .sample = 1 } },
            .{ .name = "fade", .priority = 0, .plays = .fade_out },
        },
    };
    const files = try write(arena, &c);
    var diag: json.Diagnostic = .{};
    const back = load(arena, MemorySource{ .files = files }, &diag) catch |e| {
        std.debug.print("{f}\n", .{diag});
        return e;
    };
    try testing.expectEqual(@as(usize, 4), back.sounds.len);
    try testing.expectEqual(content.Plays.fade_out, back.sounds[3].plays);
    try testing.expectEqual(@as(u16, 644), back.driver.fm_keys[3]);
    try testing.expectEqualSlices(u8, &.{ 129, 131 }, back.samples[0].values);
    const again = try write(arena, &back);
    try testing.expectEqual(files.len, again.len);
    for (files, again) |a, b| {
        try testing.expectEqualStrings(a.path, b.path);
        try testing.expectEqualSlices(u8, a.bytes, b.bytes);
    }
    // A missing file and a misspelt field are refused, by name.
    try testing.expectError(error.BadAsset, load(arena, MemorySource{ .files = files[1..] }, &diag));
    try testing.expectEqualStrings("sound/sounds.json", diag.file);
}

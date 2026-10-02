//! The port's settings record (DESIGN.md 7, decision D2). The cartridge has no saves, so the port
//! stores only its own settings: the keys of both pads and of the settings screen, the
//! controllers' buttons and which pad the first one plays, the sound's volume, and the window's
//! scale and full screen (the SDL host's). The game's own options (the level, the controls, the
//! sound test, and the hidden lives and round) are the original's: they reset at power-on, as on
//! the console, so the game from power-on never depends on the record.
//!
//! The record is one JSON object, `settings.json` in the platform's `Storage`, with a version
//! (DESIGN.md 7: a record of another version is refused, not converted). The game writes it with
//! every field, in a fixed order, so that a player can read and edit it:
//!
//!     {
//!       "version": 1,
//!       "keys": {
//!         "pad1": { "up": "up", "down": "down", ..., "start": "enter" },
//!         "pad2": { "up": "w", ..., "start": "tab" },
//!         "settings": "f1"
//!       },
//!       "controllers": { "first_pad": 1, "buttons": { "a": "x", "b": "a", "c": "b", "start": "start" } },
//!       "sound": { "volume": 100, "mute": false },
//!       "window": { "scale": 3, "fullscreen": false }
//!     }
//!
//! Keys are named as `platform.Key` names them (the agent host's `--key` names), controller
//! buttons as `platform.ControllerButton` does.
//!
//! Damaged data has a defined behaviour (`parse`, `load`): a record that does not read as a JSON
//! object, or that is of another version, gives the defaults; a field that does not read gives
//! its default, and the rest is kept. The keys are one group and the controller buttons another:
//! one key for two buttons would press both, so a key used twice gives the group's defaults. A
//! field missing or unknown counts as damaged too, since the game writes every field and no
//! other. `load` never fails: it reports what it replaced, the game tells the player once, and
//! the record is written again repaired, with the damaged bytes kept as `settings-damaged.json`.
const std = @import("std");
const platform = @import("../platform.zig");
const input = @import("../input.zig");

/// The record's version: a record of another version is refused.
pub const version: i64 = 1;
/// The record's name in the storage, and the name a damaged record is kept under.
pub const name = "settings.json";
pub const damaged_name = "settings-damaged.json";
/// The longest record that is read; a longer one is damaged.
pub const max_len = 64 * 1024;

/// The volume's range, in percent, and the window scales the record keeps.
pub const max_volume: u8 = 100;
pub const max_scale: u8 = 12;

pub const Settings = struct {
    layout: input.Layout = .{},
    /// The key that opens and closes the settings screen.
    settings_key: platform.Key = .f1,
    sound: Sound = .{},
    window: Window = .{},

    pub const Sound = struct {
        /// 0 to 100, in percent of the game's own level.
        volume: u8 = max_volume,
        mute: bool = false,
    };

    /// The SDL host's window: the game's picture `scale` times, or the whole screen.
    pub const Window = struct {
        scale: u8 = 3,
        fullscreen: bool = false,
    };

    /// The key of every key setting: the pads' buttons, then the settings screen's.
    pub const KeySlot = union(enum) { pad: input.Layout.Place, settings };

    pub fn key(self: *const Settings, slot: KeySlot) platform.Key {
        return switch (slot) {
            .pad => |p| self.layout.keys[p.pad][@backingInt(p.button)],
            .settings => self.settings_key,
        };
    }

    pub fn setKey(self: *Settings, slot: KeySlot, k: platform.Key) void {
        switch (slot) {
            .pad => |p| self.layout.keys[p.pad][@backingInt(p.button)] = k,
            .settings => self.settings_key = k,
        }
    }

    /// The setting that holds `k`, if any.
    pub fn slotOf(self: *const Settings, k: platform.Key) ?KeySlot {
        if (self.settings_key == k) return .settings;
        if (self.layout.find(k)) |p| return .{ .pad = p };
        return null;
    }

    /// Gives `slot` the key `k`. The setting that had `k` takes `slot`'s old key, so that no
    /// key presses two things. False for a key that cannot be bound (`bindable`).
    pub fn bindKey(self: *Settings, slot: KeySlot, k: platform.Key) bool {
        if (!bindable(k)) return false;
        const old = self.key(slot);
        if (self.slotOf(k)) |other| self.setKey(other, old);
        self.setKey(slot, k);
        return true;
    }

    /// Gives the controllers' `face` button the controller button `b`; the face button that had
    /// it takes the old one. False for a button that cannot be bound (`bindableButton`).
    pub fn bindButton(self: *Settings, face: usize, b: platform.ControllerButton) bool {
        if (!bindableButton(b)) return false;
        const buttons = &self.layout.buttons;
        const old = buttons[face];
        for (buttons) |*x| if (x.* == b) {
            x.* = old;
        };
        buttons[face] = b;
        return true;
    }
};

/// Escape quits the game (native hosts) or belongs to the browser, so no setting takes it.
pub fn bindable(k: platform.Key) bool {
    return k != .unknown and k != .escape and std.enums.tagName(platform.Key, k) != null;
}

/// The d-pad is the pads' directions, and the guide button belongs to the system.
pub fn bindableButton(b: platform.ControllerButton) bool {
    return switch (b) {
        .dpad_up, .dpad_down, .dpad_left, .dpad_right, .guide => false,
        else => std.enums.tagName(platform.ControllerButton, b) != null,
    };
}

/// What the reading of a record found wrong.
pub const Report = struct {
    /// The whole record was refused: the defaults stand for all of it.
    refused: ?Refusal = null,
    /// The fields that gave their defaults, by their path (`keys.pad1.up`), and what was wrong.
    fields: [max_fields]Field = undefined,
    field_count: usize = 0,
    /// More fields than `fields` holds were wrong.
    more: bool = false,

    pub const max_fields = 8;
    pub const Refusal = enum { not_json, not_an_object, too_long, other_version };
    pub const Field = struct { path: []const u8, why: []const u8 };

    pub fn ok(self: *const Report) bool {
        return self.refused == null and self.field_count == 0;
    }

    fn add(self: *Report, path: []const u8, why: []const u8) void {
        if (self.field_count == max_fields) {
            self.more = true;
            return;
        }
        self.fields[self.field_count] = .{ .path = path, .why = why };
        self.field_count += 1;
    }

    /// One line for the log: what was refused, or each field and why.
    pub fn format(self: *const Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.refused) |r| return w.writeAll(switch (r) {
            .not_json => "the record is not JSON",
            .not_an_object => "the record is not a JSON object",
            .too_long => "the record is too long",
            .other_version => "the record is of another version",
        });
        for (self.fields[0..self.field_count], 0..) |f, i| {
            try w.print("{s}{s}: {s}", .{ if (i == 0) "" else "; ", f.path, f.why });
        }
        if (self.more) try w.writeAll("; and more");
    }
};

const Value = std.json.Value;

/// Reads a record: the settings it holds, each field that does not read replaced by its default
/// (`Report`). `gpa` holds the parse only while it runs.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, report: *Report) Settings {
    report.* = .{};
    const defaults: Settings = .{};
    if (bytes.len > max_len) {
        report.refused = .too_long;
        return defaults;
    }
    const parsed = std.json.parseFromSlice(Value, gpa, bytes, .{}) catch {
        report.refused = .not_json;
        return defaults;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            report.refused = .not_an_object;
            return defaults;
        },
    };
    const v = root.get("version") orelse Value.null;
    if (v != .integer or v.integer != version) {
        report.refused = .other_version;
        return defaults;
    }
    var s: Settings = .{};
    const r: Reader = .{ .report = report };
    r.unknown(root, &.{ "version", "keys", "controllers", "sound", "window" }, "");

    // The keys: all of them, then one key for one setting.
    if (r.object(root, "keys", "keys")) |keys| {
        r.unknown(keys, &.{ "pad1", "pad2", "settings" }, "keys.");
        inline for (.{ "pad1", "pad2" }, 0..) |pad_name, pad| {
            if (r.object(keys, pad_name, "keys." ++ pad_name)) |o| {
                r.unknown(o, &button_names, "keys." ++ pad_name ++ ".");
                inline for (button_names, 0..) |b, i| {
                    if (r.keyField(o, b, "keys." ++ pad_name ++ "." ++ b)) |k| s.layout.keys[pad][i] = k;
                }
            }
        }
        if (r.keyField(keys, "settings", "keys.settings")) |k| s.settings_key = k;
        if (!keysDistinct(&s)) {
            report.add("keys", "a key is used twice");
            s.layout.keys = defaults.layout.keys;
            s.settings_key = defaults.settings_key;
        }
    }
    if (r.object(root, "controllers", "controllers")) |c| {
        r.unknown(c, &.{ "first_pad", "buttons" }, "controllers.");
        if (r.integer(c, "first_pad", "controllers.first_pad", 1, 2)) |n| s.layout.first_pad = @intCast(n - 1);
        if (r.object(c, "buttons", "controllers.buttons")) |o| {
            r.unknown(o, &face_names, "controllers.buttons.");
            inline for (face_names, 0..) |f, i| {
                if (r.buttonField(o, f, "controllers.buttons." ++ f)) |b| s.layout.buttons[i] = b;
            }
            if (!buttonsDistinct(&s)) {
                report.add("controllers.buttons", "a button is used twice");
                s.layout.buttons = defaults.layout.buttons;
            }
        }
    }
    if (r.object(root, "sound", "sound")) |o| {
        r.unknown(o, &.{ "volume", "mute" }, "sound.");
        if (r.integer(o, "volume", "sound.volume", 0, max_volume)) |n| s.sound.volume = @intCast(n);
        if (r.boolean(o, "mute", "sound.mute")) |b| s.sound.mute = b;
    }
    if (r.object(root, "window", "window")) |o| {
        r.unknown(o, &.{ "scale", "fullscreen" }, "window.");
        if (r.integer(o, "scale", "window.scale", 1, max_scale)) |n| s.window.scale = @intCast(n);
        if (r.boolean(o, "fullscreen", "window.fullscreen")) |b| s.window.fullscreen = b;
    }
    return s;
}

const button_names = [_][]const u8{ "up", "down", "left", "right", "a", "b", "c", "start" };
const face_names = [_][]const u8{ "a", "b", "c", "start" };

comptime {
    for (button_names, 0..) |n, i| std.debug.assert(std.mem.eql(u8, n, @tagName(@as(input.Button, @fromBackingInt(i)))));
    for (face_names, input.face_buttons) |n, f| std.debug.assert(std.mem.eql(u8, n, @tagName(f)));
}

/// The fields of one object: each read, or reported and left to its default.
const Reader = struct {
    report: *Report,

    fn object(r: Reader, o: std.json.ObjectMap, field: []const u8, comptime path: []const u8) ?std.json.ObjectMap {
        const v = r.get(o, field, path) orelse return null;
        if (v == .object) return v.object;
        r.report.add(path, "not an object");
        return null;
    }

    fn get(r: Reader, o: std.json.ObjectMap, field: []const u8, comptime path: []const u8) ?Value {
        return o.get(field) orelse {
            r.report.add(path, "missing");
            return null;
        };
    }

    fn integer(r: Reader, o: std.json.ObjectMap, field: []const u8, comptime path: []const u8, comptime min: i64, comptime max: i64) ?i64 {
        const v = r.get(o, field, path) orelse return null;
        if (v == .integer and v.integer >= min and v.integer <= max) return v.integer;
        r.report.add(path, std.fmt.comptimePrint("not a whole number from {d} to {d}", .{ min, max }));
        return null;
    }

    fn boolean(r: Reader, o: std.json.ObjectMap, field: []const u8, comptime path: []const u8) ?bool {
        const v = r.get(o, field, path) orelse return null;
        if (v == .bool) return v.bool;
        r.report.add(path, "not true or false");
        return null;
    }

    fn keyField(r: Reader, o: std.json.ObjectMap, field: []const u8, comptime path: []const u8) ?platform.Key {
        const v = r.get(o, field, path) orelse return null;
        if (v == .string) if (std.meta.stringToEnum(platform.Key, v.string)) |k| if (bindable(k)) return k;
        r.report.add(path, "not the name of a key (escape is the game's)");
        return null;
    }

    fn buttonField(r: Reader, o: std.json.ObjectMap, field: []const u8, comptime path: []const u8) ?platform.ControllerButton {
        const v = r.get(o, field, path) orelse return null;
        if (v == .string) if (std.meta.stringToEnum(platform.ControllerButton, v.string)) |b| if (bindableButton(b)) return b;
        r.report.add(path, "not the name of a controller button (not the d-pad or guide)");
        return null;
    }

    /// Reports the fields of `o` that are not in `known`. The path is the field's own, so that
    /// it outlives the parse: only the first unknown field of an object is named.
    fn unknown(r: Reader, o: std.json.ObjectMap, known: []const []const u8, comptime prefix: []const u8) void {
        for (o.keys()) |k| {
            for (known) |n| {
                if (std.mem.eql(u8, n, k)) break;
            } else {
                r.report.add(if (prefix.len == 0) "(the record)" else prefix[0 .. prefix.len - 1], "a field the game does not know");
                return;
            }
        }
    }
};

fn keysDistinct(s: *const Settings) bool {
    const all: [17]platform.Key = s.layout.keys[0] ++ s.layout.keys[1] ++ [1]platform.Key{s.settings_key};
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| if (a == b) return false;
    return true;
}

fn buttonsDistinct(s: *const Settings) bool {
    for (s.layout.buttons, 0..) |a, i| for (s.layout.buttons[i + 1 ..]) |b| if (a == b) return false;
    return true;
}

/// The record's text: every field, in a fixed order, so that the same settings give the same
/// bytes.
pub fn write(s: *const Settings, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{{\n  \"version\": {d},\n  \"keys\": {{\n", .{version});
    for (s.layout.keys, 0..) |pad, p| {
        try w.print("    \"pad{d}\": {{ ", .{p + 1});
        for (pad, button_names, 0..) |k, b, i| try w.print("{s}\"{s}\": \"{s}\"", .{ if (i == 0) "" else ", ", b, @tagName(k) });
        try w.writeAll(" },\n");
    }
    try w.print("    \"settings\": \"{s}\"\n  }},\n", .{@tagName(s.settings_key)});
    try w.print("  \"controllers\": {{ \"first_pad\": {d}, \"buttons\": {{ ", .{@as(u8, s.layout.first_pad) + 1});
    for (s.layout.buttons, face_names, 0..) |b, f, i| try w.print("{s}\"{s}\": \"{s}\"", .{ if (i == 0) "" else ", ", f, @tagName(b) });
    try w.writeAll(" } },\n");
    try w.print("  \"sound\": {{ \"volume\": {d}, \"mute\": {} }},\n", .{ s.sound.volume, s.sound.mute });
    try w.print("  \"window\": {{ \"scale\": {d}, \"fullscreen\": {} }}\n}}\n", .{ s.window.scale, s.window.fullscreen });
}

/// The longest record `write` makes: every key name at its longest.
pub const max_written = 1024;

/// The record's bytes in `buf`.
pub fn encode(s: *const Settings, buf: *[max_written]u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(s, &w) catch unreachable;
    return w.buffered();
}

/// A hash of the record's bytes, which identifies the settings (the agent host prints it).
pub fn hash(s: *const Settings) u64 {
    var buf: [max_written]u8 = undefined;
    return std.hash.Fnv1a_64.hash(encode(s, &buf));
}

/// Writes the record. The storage keeps the previous one when it fails.
pub fn save(storage: platform.Storage, s: *const Settings) platform.StorageError!void {
    var buf: [max_written]u8 = undefined;
    return storage.save(name, encode(s, &buf));
}

/// What `load` found.
pub const Loaded = struct {
    settings: Settings = .{},
    /// A record was there (and read, wholly or in part).
    found: bool = false,
    report: Report = .{},
    /// The storage did not give the record (an I/O failure): the defaults stand, and nothing is
    /// written over the record.
    unreadable: bool = false,
    /// The repaired record could not be written: the player is told again at the next start.
    repair_failed: bool = false,

    /// Whether the player is told: a damaged record, or one the storage would not give.
    pub fn damaged(self: *const Loaded) bool {
        return self.unreadable or !self.report.ok();
    }
};

/// The settings in `storage`, or the defaults. A damaged record is replaced by the settings read
/// from it (each damaged field at its default), and its bytes are kept as `damaged_name`, so the
/// player is told once and a hand-edited record is not lost. Never fails.
pub fn load(gpa: std.mem.Allocator, storage: platform.Storage) Loaded {
    var out: Loaded = .{};
    var owned = storage.load(name) catch |err| {
        if (err != error.NotFound) out.unreadable = true;
        return out;
    };
    defer owned.deinit();
    out.found = true;
    out.settings = parse(gpa, owned.bytes, &out.report);
    if (out.report.ok()) return out;
    storage.save(damaged_name, owned.bytes) catch {};
    save(storage, &out.settings) catch {
        out.repair_failed = true;
    };
    return out;
}

const testing = std.testing;
const MemoryStorage = @import("../memory.zig").MemoryStorage;

fn reread(text: []const u8, report: *Report) Settings {
    return parse(testing.allocator, text, report);
}

test "the record round-trips, and the defaults are the input's" {
    var report: Report = .{};
    var s: Settings = .{};
    var buf: [max_written]u8 = undefined;
    try testing.expectEqual(input.Layout{}, reread(encode(&s, &buf), &report).layout);
    try testing.expect(report.ok());

    _ = s.bindKey(.{ .pad = .{ .pad = 1, .button = .start } }, .space);
    _ = s.bindKey(.settings, .keypad_minus);
    _ = s.bindButton(3, .back);
    s.layout.first_pad = 1;
    s.sound = .{ .volume = 40, .mute = true };
    s.window = .{ .scale = 5, .fullscreen = true };
    const text = encode(&s, &buf);
    const back = reread(text, &report);
    try testing.expect(report.ok());
    try testing.expectEqual(s, back);
    try testing.expectEqual(hash(&s), hash(&back));
    try testing.expect(hash(&s) != hash(&Settings{}));
    try testing.expect(std.mem.indexOf(u8, text, "\"start\": \"space\" }") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"settings\": \"keypad_minus\"") != null);

    // The longest names fit the buffer.
    const long: Settings = .{
        .layout = .{
            .keys = .{
                .{ .right_bracket, .left_bracket, .keypad_minus, .right_shift, .keypad_plus, .page_down, .left_shift, .apostrophe },
                .{ .right_ctrl, .left_ctrl, .backslash, .semicolon, .backspace, .right_alt, .page_up, .left_alt },
            },
            .buttons = .{ .right_shoulder, .left_shoulder, .right_stick, .left_stick },
        },
        .settings_key = .digit_0,
    };
    try testing.expectEqual(long, reread(encode(&long, &buf), &report));
    try testing.expect(report.ok());
}

test "a damaged field gives its default and the rest is kept" {
    var report: Report = .{};
    const s = reread(
        \\{ "version": 1,
        \\  "keys": { "pad1": { "up": "i", "down": "k", "left": "j", "right": "l", "a": "q", "b": "e", "c": "r", "start": 7 },
        \\            "pad2": { "up": "w", "down": "s", "left": "a", "right": "d", "a": "f", "b": "g", "c": "h", "start": "tab" },
        \\            "settings": "f2" },
        \\  "controllers": { "first_pad": 3, "buttons": { "a": "y", "b": "a", "c": "b", "start": "start" } },
        \\  "sound": { "volume": "loud", "mute": true },
        \\  "window": { "scale": 2, "fullscreen": "yes", "colour": 1 },
        \\  "extra": [] }
    , &report);
    try testing.expectEqual(platform.Key.i, s.layout.keys[0][0]);
    try testing.expectEqual(platform.Key.enter, s.layout.keys[0][7]);
    try testing.expectEqual(platform.Key.f2, s.settings_key);
    try testing.expectEqual(platform.ControllerButton.y, s.layout.buttons[0]);
    try testing.expectEqual(@as(u1, 0), s.layout.first_pad);
    try testing.expectEqual(Settings.Sound{ .volume = 100, .mute = true }, s.sound);
    try testing.expectEqual(Settings.Window{ .scale = 2, .fullscreen = false }, s.window);
    try testing.expect(!report.ok());
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try report.format(&w);
    try testing.expectEqualStrings("(the record): a field the game does not know; keys.pad1.start: not the name of a key (escape is the game's); " ++
        "controllers.first_pad: not a whole number from 1 to 2; sound.volume: not a whole number from 0 to 100; " ++
        "window: a field the game does not know; window.fullscreen: not true or false", w.buffered());
}

test "damaged records give the defaults" {
    var report: Report = .{};
    const defaults: Settings = .{};
    for ([_]struct { []const u8, Report.Refusal }{
        .{ "", .not_json },
        .{ "{\"version\": 1, \"keys\": ", .not_json },
        .{ "\x00\xff garbage", .not_json },
        .{ "{\"version\": 1, \"version\": 1}", .not_json },
        .{ "[1, 2]", .not_an_object },
        .{ "{}", .other_version },
        .{ "{\"version\": 2}", .other_version },
        .{ "{\"version\": \"1\"}", .other_version },
    }) |case| {
        try testing.expectEqual(defaults, reread(case[0], &report));
        try testing.expectEqual(case[1], report.refused.?);
    }
    const huge = try testing.allocator.alloc(u8, max_len + 1);
    defer testing.allocator.free(huge);
    @memset(huge, ' ');
    try testing.expectEqual(defaults, reread(huge, &report));
    try testing.expectEqual(Report.Refusal.too_long, report.refused.?);

    // A version alone: every group is missing, and named.
    try testing.expectEqual(defaults, reread("{\"version\": 1}", &report));
    try testing.expectEqual(@as(usize, 4), report.field_count);
    try testing.expectEqualStrings("keys", report.fields[0].path);
    try testing.expectEqualStrings("missing", report.fields[0].why);
}

test "a key used twice gives the keys' defaults; a button used twice the buttons'" {
    var report: Report = .{};
    var s: Settings = .{};
    s.layout.keys[1][0] = .up; // pad 1's up too
    s.layout.buttons[2] = .x; // A's too
    s.sound.volume = 30;
    var buf: [max_written]u8 = undefined;
    const back = reread(encode(&s, &buf), &report);
    try testing.expectEqual(input.Layout{}, back.layout);
    try testing.expectEqual(@as(u8, 30), back.sound.volume);
    try testing.expectEqualStrings("keys", report.fields[0].path);
    try testing.expectEqualStrings("controllers.buttons", report.fields[1].path);

    // The settings key is one of the keys.
    s = .{};
    s.settings_key = .z;
    _ = reread(encode(&s, &buf), &report);
    try testing.expectEqualStrings("keys", report.fields[0].path);
}

test "rebinding swaps: no key and no button does two things" {
    var s: Settings = .{};
    const a1: Settings.KeySlot = .{ .pad = .{ .pad = 0, .button = .a } };
    const up2: Settings.KeySlot = .{ .pad = .{ .pad = 1, .button = .up } };
    // Pad 1's A takes W, pad 2's up's key: pad 2's up takes Z, A's old key.
    try testing.expect(s.bindKey(a1, .w));
    try testing.expectEqual(platform.Key.w, s.key(a1));
    try testing.expectEqual(platform.Key.z, s.key(up2));
    // A key no setting had: nothing else changes.
    try testing.expect(s.bindKey(a1, .space));
    try testing.expectEqual(platform.Key.z, s.key(up2));
    // The settings key swaps as the others do.
    try testing.expect(s.bindKey(.settings, .space));
    try testing.expectEqual(platform.Key.f1, s.key(a1));
    try testing.expectEqual(platform.Key.space, s.settings_key);
    // Its own key changes nothing; Escape and unknown keys are refused.
    try testing.expect(s.bindKey(.settings, .space));
    try testing.expect(!s.bindKey(a1, .escape));
    try testing.expect(!s.bindKey(a1, .unknown));
    try testing.expect(!s.bindKey(a1, @fromBackingInt(999)));
    try testing.expect(keysDistinct(&s));

    try testing.expect(s.bindButton(0, .a)); // A takes B's button
    try testing.expectEqual([4]platform.ControllerButton{ .a, .x, .b, .start }, s.layout.buttons);
    try testing.expect(s.bindButton(3, .right_shoulder));
    try testing.expect(!s.bindButton(3, .dpad_up));
    try testing.expect(!s.bindButton(3, .guide));
    try testing.expect(buttonsDistinct(&s));
}

test "load: nothing kept, a record kept, a damaged one repaired once and kept aside" {
    var mem = MemoryStorage.init(testing.allocator);
    defer mem.deinit();
    const storage = mem.storage();
    var got = load(testing.allocator, storage);
    try testing.expect(!got.found and !got.damaged());

    var s: Settings = .{};
    s.sound.volume = 70;
    try save(storage, &s);
    got = load(testing.allocator, storage);
    try testing.expect(got.found and !got.damaged());
    try testing.expectEqual(s, got.settings);

    const damaged = "{\"version\": 1, \"keys\": 3, \"controllers\": {}, \"sound\": {\"volume\": 20, \"mute\": false}, \"window\": {\"scale\": 0, \"fullscreen\": true}}";
    try storage.save(name, damaged);
    got = load(testing.allocator, storage);
    try testing.expect(got.damaged() and !got.repair_failed);
    try testing.expectEqual(@as(u8, 20), got.settings.sound.volume);
    try testing.expectEqual(Settings.Window{ .scale = 3, .fullscreen = true }, got.settings.window);
    var kept = try storage.load(damaged_name);
    defer kept.deinit();
    try testing.expectEqualStrings(damaged, kept.bytes);
    // The next start finds the repaired record: nothing to tell.
    const again = load(testing.allocator, storage);
    try testing.expect(!again.damaged());
    try testing.expectEqual(got.settings, again.settings);
}

/// A storage that fails as a broken disk does.
const BrokenStorage = struct {
    fn storage() platform.Storage {
        return .{ .context = undefined, .vtable = &.{ .save = saveFails, .load = loadFails, .list_saves = list, .delete_save = delete } };
    }
    fn saveFails(_: *anyopaque, _: []const u8, _: []const u8) platform.StorageError!void {
        return error.Io;
    }
    fn loadFails(_: *anyopaque, _: []const u8) platform.StorageError!platform.OwnedBytes {
        return error.Io;
    }
    fn list(_: *anyopaque) platform.StorageError!platform.OwnedSaveNames {
        return error.Io;
    }
    fn delete(_: *anyopaque, _: []const u8) platform.StorageError!void {
        return error.Io;
    }
};

test "a storage that fails gives the defaults and is told" {
    const got = load(testing.allocator, BrokenStorage.storage());
    try testing.expect(got.unreadable and got.damaged());
    try testing.expectEqual(Settings{}, got.settings);
    try testing.expectError(error.Io, save(BrokenStorage.storage(), &got.settings));
}

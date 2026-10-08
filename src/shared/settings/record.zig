//! The port's settings record (DESIGN.md 7, decision D2). The cartridge has no saves, so the port
//! stores only its own settings: each player's input (the keyboard or a gamepad, its keys, its
//! gamepad's buttons, its autofire) and the settings screen's key, the sound's volume, the window's
//! scale and full screen (the SDL host's), and the game's rules outside the original (the lives, the
//! continues, the friendly hits: setup.zig). The game's own options (the level, the controls, the
//! sound test, and the hidden lives and round) are the original's: they reset at power-on, as on
//! the console.
//!
//! The record is one JSON object, `settings.json` in the platform's `Storage`, with a version
//! (DESIGN.md 7: a record of another version is refused, not converted). The game writes it with
//! every field, in a fixed order, so that a player can read and edit it:
//!
//!     {
//!       "version": 2,
//!       "players": {
//!         "player1": { "input": "keyboard", "keys": { "up": "up", ..., "start": "enter" },
//!                      "buttons": { "a": "x", "b": "a", "c": "b", "start": "start" }, "autofire": false },
//!         "player2": { "input": "gamepad 1", "keys": { "up": "w", ... }, ... },
//!         "player3": { "input": "keyboard", "keys": { "up": "none", ... }, ... },
//!         "player4": { ... }
//!       },
//!       "settings_key": "f1",
//!       "sound": { "volume": 100, "mute": false },
//!       "window": { "scale": 3, "fullscreen": false },
//!       "rules": { "lives": 3, "continues": 3, "friendly_hit": true }
//!     }
//!
//! Keys are named as `platform.Key` names them (the agent host's `--key` names), "none" for no key,
//! gamepad buttons as `platform.ControllerButton` does.
//!
//! A record of another version (an older game's) is not read: `load` writes the defaults over it,
//! and nothing is told (the user, 2026-10-08).
//!
//! Damaged data has a defined behaviour (`parse`, `load`): a record that does not read as a JSON
//! object gives the defaults; a field that does not read gives its default, and the rest is
//! kept. The keys are one group and each player's buttons another:
//! one key for two buttons would press both, so a key used twice gives the keys' defaults. A
//! field missing or unknown counts as damaged too, since the game writes every field and no
//! other. `load` never fails: it reports what it replaced, the game tells the player once, and
//! the record is written again repaired, with the damaged bytes kept as `settings-damaged.json`.
const std = @import("std");
const platform = @import("../platform.zig");
const input = @import("../input.zig");
const Rules = @import("../setup.zig").Rules;

/// The record's version: a record of another version is refused.
pub const version: i64 = 2;
/// The record's name in the storage, and the name a damaged record is kept under.
pub const name = "settings.json";
pub const damaged_name = "settings-damaged.json";
/// The longest record that is read; a longer one is damaged.
pub const max_len = 64 * 1024;

/// The volume's range, in percent, and the window scales the record keeps.
pub const max_volume: u8 = 100;
pub const max_scale: u8 = 12;
/// The rules' ranges.
pub const max_lives: u8 = 9;
pub const max_continues: u8 = 9;

pub const Settings = struct {
    layout: input.Layout = .{},
    /// The key that opens and closes the settings screen.
    settings_key: platform.Key = .f1,
    sound: Sound = .{},
    window: Window = .{},
    /// The game's rules outside the original.
    rules: Rules = .{},

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

    /// The key of every key setting: the players' buttons, then the settings screen's.
    pub const KeySlot = union(enum) { player: input.Layout.Place, settings };

    pub fn key(self: *const Settings, slot: KeySlot) platform.Key {
        return switch (slot) {
            .player => |p| self.layout.players[p.player].keys[@backingInt(p.button)],
            .settings => self.settings_key,
        };
    }

    pub fn setKey(self: *Settings, slot: KeySlot, k: platform.Key) void {
        switch (slot) {
            .player => |p| self.layout.players[p.player].keys[@backingInt(p.button)] = k,
            .settings => self.settings_key = k,
        }
    }

    /// The setting that holds `k`, if any.
    pub fn slotOf(self: *const Settings, k: platform.Key) ?KeySlot {
        if (self.settings_key == k) return .settings;
        if (self.layout.find(k)) |p| return .{ .player = p };
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

    /// Gives player `p`'s gamepad `face` button the gamepad button `b`; the face button that had
    /// it takes the old one. False for a button that cannot be bound (`bindableButton`).
    pub fn bindButton(self: *Settings, p: usize, face: usize, b: platform.ControllerButton) bool {
        if (!bindableButton(b)) return false;
        const buttons = &self.layout.players[p].buttons;
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
    r.unknown(root, &.{ "version", "players", "settings_key", "sound", "window", "rules" }, "");

    // The players, then one key for one setting.
    if (r.object(root, "players", "players")) |players| {
        r.unknown(players, &player_names, "players.");
        inline for (player_names, 0..) |player_name, i| {
            const path = "players." ++ player_name;
            const pi = &s.layout.players[i];
            if (r.object(players, player_name, path)) |o| {
                r.unknown(o, &.{ "input", "keys", "buttons", "autofire" }, path ++ ".");
                if (r.inputField(o, "input", path ++ ".input")) |g| pi.gamepad = g;
                if (r.object(o, "keys", path ++ ".keys")) |keys| {
                    r.unknown(keys, &button_names, path ++ ".keys.");
                    inline for (button_names, 0..) |b, k| {
                        if (r.keyField(keys, b, path ++ ".keys." ++ b)) |key| pi.keys[k] = key;
                    }
                }
                if (r.object(o, "buttons", path ++ ".buttons")) |buttons| {
                    r.unknown(buttons, &face_names, path ++ ".buttons.");
                    inline for (face_names, 0..) |f, k| {
                        if (r.buttonField(buttons, f, path ++ ".buttons." ++ f)) |b| pi.buttons[k] = b;
                    }
                    if (!buttonsDistinct(pi)) {
                        report.add(path ++ ".buttons", "a button is used twice");
                        pi.buttons = defaults.layout.players[i].buttons;
                    }
                }
                if (r.boolean(o, "autofire", path ++ ".autofire")) |b| pi.autofire = b;
            }
        }
        // A gamepad for one player alone.
        for (s.layout.players, 0..) |a, i| for (s.layout.players[i + 1 ..]) |*b| if (a.gamepad != null and a.gamepad == b.gamepad) {
            report.add("players", "a gamepad is two players'");
            b.gamepad = null;
        };
    }
    if (r.keyField(root, "settings_key", "settings_key")) |k| s.settings_key = k;
    if (!keysDistinct(&s)) {
        report.add("keys", "a key is used twice");
        for (&s.layout.players, defaults.layout.players) |*p, d| p.keys = d.keys;
        s.settings_key = defaults.settings_key;
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
    if (r.object(root, "rules", "rules")) |o| {
        r.unknown(o, &.{ "lives", "continues", "friendly_hit" }, "rules.");
        if (r.integer(o, "lives", "rules.lives", 1, max_lives)) |n| s.rules.lives = @intCast(n);
        if (r.integer(o, "continues", "rules.continues", 0, max_continues)) |n| s.rules.continues = @intCast(n);
        if (r.boolean(o, "friendly_hit", "rules.friendly_hit")) |b| s.rules.friendly_hit = b;
    }
    return s;
}

const player_names = [_][]const u8{ "player1", "player2", "player3", "player4" };
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
        if (v == .string) {
            if (std.mem.eql(u8, v.string, "none")) return input.no_key;
            if (std.meta.stringToEnum(platform.Key, v.string)) |k| if (bindable(k)) return k;
        }
        r.report.add(path, "not the name of a key, or none (escape is the game's)");
        return null;
    }

    /// "keyboard", or "gamepad N" (N from 1): the gamepad's place, or null for the keyboard.
    fn inputField(r: Reader, o: std.json.ObjectMap, field: []const u8, comptime path: []const u8) ??u2 {
        const v = r.get(o, field, path) orelse return null;
        if (v == .string) if (inputOf(v.string)) |g| return g;
        r.report.add(path, "not keyboard or gamepad 1 to gamepad 4");
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

/// An input method's name: "keyboard", "gamepad 1"...
fn inputOf(text: []const u8) ??u2 {
    if (std.mem.eql(u8, text, "keyboard")) return @as(?u2, null);
    for (0..input.Controls.max_controllers) |g| {
        var buf: [16]u8 = undefined;
        if (std.mem.eql(u8, text, inputName(@intCast(g), &buf))) return @as(?u2, @intCast(g));
    }
    return null;
}

fn inputName(g: ?u2, buf: *[16]u8) []const u8 {
    const n = g orelse return "keyboard";
    return std.fmt.bufPrint(buf, "gamepad {d}", .{@as(u8, n) + 1}) catch unreachable;
}

fn keysDistinct(s: *const Settings) bool {
    var all: [input.max_players * 8 + 1]platform.Key = undefined;
    for (s.layout.players, 0..) |p, i| all[i * 8 ..][0..8].* = p.keys;
    all[all.len - 1] = s.settings_key;
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| if (a == b and a != input.no_key) return false;
    return true;
}

fn buttonsDistinct(p: *const input.PlayerInput) bool {
    for (p.buttons, 0..) |a, i| for (p.buttons[i + 1 ..]) |b| if (a == b) return false;
    return true;
}

/// The record's text: every field, in a fixed order, so that the same settings give the same
/// bytes.
pub fn write(s: *const Settings, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{{\n  \"version\": {d},\n  \"players\": {{\n", .{version});
    for (s.layout.players, player_names, 0..) |p, name_, i| {
        var buf: [16]u8 = undefined;
        try w.print("    \"{s}\": {{ \"input\": \"{s}\", \"keys\": {{ ", .{ name_, inputName(p.gamepad, &buf) });
        for (p.keys, button_names, 0..) |k, b, j| try w.print("{s}\"{s}\": \"{s}\"", .{ if (j == 0) "" else ", ", b, keyName(k) });
        try w.writeAll(" }, \"buttons\": { ");
        for (p.buttons, face_names, 0..) |b, f, j| try w.print("{s}\"{s}\": \"{s}\"", .{ if (j == 0) "" else ", ", f, @tagName(b) });
        try w.print(" }}, \"autofire\": {} }}{s}\n", .{ p.autofire, if (i + 1 < player_names.len) "," else "" });
    }
    try w.print("  }},\n  \"settings_key\": \"{s}\",\n", .{keyName(s.settings_key)});
    try w.print("  \"sound\": {{ \"volume\": {d}, \"mute\": {} }},\n", .{ s.sound.volume, s.sound.mute });
    try w.print("  \"window\": {{ \"scale\": {d}, \"fullscreen\": {} }},\n", .{ s.window.scale, s.window.fullscreen });
    try w.print("  \"rules\": {{ \"lives\": {d}, \"continues\": {d}, \"friendly_hit\": {} }}\n}}\n", .{ s.rules.lives, s.rules.continues, s.rules.friendly_hit });
}

fn keyName(k: platform.Key) []const u8 {
    return if (k == input.no_key) "none" else @tagName(k);
}

/// The longest record `write` makes: every key name at its longest.
pub const max_written = 4096;

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

/// The settings in `storage`, or the defaults. A record of another version gives the defaults,
/// written over it, untold. A damaged record is replaced by the settings read from it (each
/// damaged field at its default), and its bytes are kept as `damaged_name`, so the player is told
/// once and a hand-edited record is not lost. Never fails.
pub fn load(gpa: std.mem.Allocator, storage: platform.Storage) Loaded {
    var out: Loaded = .{};
    var owned = storage.load(name) catch |err| {
        if (err != error.NotFound) out.unreadable = true;
        return out;
    };
    defer owned.deinit();
    out.found = true;
    out.settings = parse(gpa, owned.bytes, &out.report);
    if (out.report.refused == .other_version) {
        out.report = .{};
        save(storage, &out.settings) catch {};
        return out;
    }
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

    _ = s.bindKey(.{ .player = .{ .player = 1, .button = .start } }, .space);
    _ = s.bindKey(.{ .player = .{ .player = 3, .button = .a } }, .y);
    _ = s.bindKey(.settings, .keypad_minus);
    _ = s.bindButton(1, 3, .back);
    s.layout.assign(1, 2);
    s.layout.players[0].autofire = true;
    s.sound = .{ .volume = 40, .mute = true };
    s.window = .{ .scale = 5, .fullscreen = true };
    s.rules = .{ .lives = 9, .continues = 0, .friendly_hit = false };
    const text = encode(&s, &buf);
    const back = reread(text, &report);
    try testing.expect(report.ok());
    try testing.expectEqual(s, back);
    try testing.expectEqual(hash(&s), hash(&back));
    try testing.expect(hash(&s) != hash(&Settings{}));
    try testing.expect(std.mem.indexOf(u8, text, "\"start\": \"space\" }") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"input\": \"gamepad 3\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"settings_key\": \"keypad_minus\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"up\": \"none\"") != null);

    // The longest names fit the buffer.
    var longest: platform.Key = .a;
    for (std.enums.values(platform.Key)) |k| if (@tagName(k).len > @tagName(longest).len) {
        longest = k;
    };
    var long: Settings = .{ .settings_key = longest };
    for (&long.layout.players) |*p| {
        p.keys = @splat(longest);
        p.buttons = @splat(.right_shoulder);
        p.gamepad = 3;
    }
    try testing.expect(encode(&long, &buf).len < max_written);
}

test "a damaged field gives its default and the rest is kept" {
    var report: Report = .{};
    const s = reread(
        \\{ "version": 2,
        \\  "players": {
        \\    "player1": { "input": "gamepad 7", "keys": { "up": "i", "down": "k", "left": "j", "right": "l", "a": "q", "b": "e", "c": "r", "start": 7 },
        \\                 "buttons": { "a": "y", "b": "a", "c": "b", "start": "start" }, "autofire": true },
        \\    "player2": { "input": "gamepad 2", "keys": { "up": "w", "down": "s", "left": "a", "right": "d", "a": "f", "b": "g", "c": "h", "start": "tab" },
        \\                 "buttons": { "a": "x", "b": "a", "c": "b", "start": "start" }, "autofire": false },
        \\    "player3": { "input": "keyboard", "keys": { "up": "none", "down": "none", "left": "none", "right": "none", "a": "none", "b": "none", "c": "none", "start": "none" },
        \\                 "buttons": { "a": "x", "b": "a", "c": "b", "start": "start" }, "autofire": false },
        \\    "player4": { "input": "keyboard", "keys": { "up": "none", "down": "none", "left": "none", "right": "none", "a": "none", "b": "none", "c": "none", "start": "none" },
        \\                 "buttons": { "a": "x", "b": "a", "c": "b", "start": "start" }, "autofire": false } },
        \\  "settings_key": "f2",
        \\  "sound": { "volume": "loud", "mute": true },
        \\  "window": { "scale": 2, "fullscreen": "yes", "colour": 1 },
        \\  "rules": { "lives": 0, "continues": 5, "friendly_hit": false },
        \\  "extra": [] }
    , &report);
    const p1 = s.layout.players[0];
    try testing.expectEqual(platform.Key.i, p1.keys[0]);
    try testing.expectEqual(platform.Key.enter, p1.keys[7]);
    try testing.expect(p1.gamepad == null and p1.autofire);
    try testing.expectEqual(@as(?u2, 1), s.layout.players[1].gamepad);
    try testing.expectEqual(platform.ControllerButton.y, p1.buttons[0]);
    try testing.expectEqual(platform.Key.f2, s.settings_key);
    try testing.expectEqual(Settings.Sound{ .volume = 100, .mute = true }, s.sound);
    try testing.expectEqual(Settings.Window{ .scale = 2, .fullscreen = false }, s.window);
    try testing.expectEqual(Rules{ .lives = 3, .continues = 5, .friendly_hit = false }, s.rules);
    try testing.expect(!report.ok());
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try report.format(&w);
    try testing.expectEqualStrings("(the record): a field the game does not know; players.player1.input: not keyboard or gamepad 1 to gamepad 4; " ++
        "players.player1.keys.start: not the name of a key, or none (escape is the game's); sound.volume: not a whole number from 0 to 100; " ++
        "window: a field the game does not know; window.fullscreen: not true or false; rules.lives: not a whole number from 1 to 9", w.buffered());
}

test "damaged records give the defaults" {
    var report: Report = .{};
    const defaults: Settings = .{};
    for ([_]struct { []const u8, Report.Refusal }{
        .{ "", .not_json },
        .{ "{\"version\": 2, \"players\": ", .not_json },
        .{ "\x00\xff garbage", .not_json },
        .{ "{\"version\": 2, \"version\": 2}", .not_json },
        .{ "[1, 2]", .not_an_object },
        .{ "{}", .other_version },
        .{ "{\"version\": 1}", .other_version },
        .{ "{\"version\": \"2\"}", .other_version },
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
    try testing.expectEqual(defaults, reread("{\"version\": 2}", &report));
    try testing.expectEqual(@as(usize, 5), report.field_count);
    try testing.expectEqualStrings("players", report.fields[0].path);
    try testing.expectEqualStrings("missing", report.fields[0].why);
}

test "a key used twice gives the keys' defaults; a button or a gamepad used twice the player's" {
    var report: Report = .{};
    var s: Settings = .{};
    s.layout.players[1].keys[0] = .up; // player 1's up too
    s.layout.players[0].buttons[2] = .x; // A's too
    s.layout.players[0].gamepad = 0;
    s.layout.players[2].gamepad = 0;
    s.sound.volume = 30;
    var buf: [max_written]u8 = undefined;
    const back = reread(encode(&s, &buf), &report);
    const defaults: input.Layout = .{};
    try testing.expectEqual(defaults.players[1].keys, back.layout.players[1].keys);
    try testing.expectEqual(defaults.players[0].buttons, back.layout.players[0].buttons);
    try testing.expect(back.layout.players[0].gamepad == 0 and back.layout.players[2].gamepad == null);
    try testing.expectEqual(@as(u8, 30), back.sound.volume);
    try testing.expectEqualStrings("players.player1.buttons", report.fields[0].path);
    try testing.expectEqualStrings("players", report.fields[1].path);
    try testing.expectEqualStrings("keys", report.fields[2].path);

    // The settings key is one of the keys; no key at all, many times, is no key twice.
    s = .{};
    s.settings_key = .z;
    _ = reread(encode(&s, &buf), &report);
    try testing.expectEqualStrings("keys", report.fields[0].path);
}

test "rebinding swaps: no key and no button does two things" {
    var s: Settings = .{};
    const a1: Settings.KeySlot = .{ .player = .{ .player = 0, .button = .a } };
    const up2: Settings.KeySlot = .{ .player = .{ .player = 1, .button = .up } };
    const up3: Settings.KeySlot = .{ .player = .{ .player = 2, .button = .up } };
    // Player 1's A takes W, player 2's up's key: player 2's up takes Z, A's old key.
    try testing.expect(s.bindKey(a1, .w));
    try testing.expectEqual(platform.Key.w, s.key(a1));
    try testing.expectEqual(platform.Key.z, s.key(up2));
    // A key no setting had: nothing else changes.
    try testing.expect(s.bindKey(a1, .space));
    try testing.expectEqual(platform.Key.z, s.key(up2));
    // Player 3, without keys, takes Z: player 2's up has none.
    try testing.expect(s.bindKey(up3, .z));
    try testing.expectEqual(input.no_key, s.key(up2));
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

    try testing.expect(s.bindButton(0, 0, .a)); // A takes B's button
    try testing.expectEqual([4]platform.ControllerButton{ .a, .x, .b, .start }, s.layout.players[0].buttons);
    try testing.expectEqual([4]platform.ControllerButton{ .x, .a, .b, .start }, s.layout.players[1].buttons);
    try testing.expect(s.bindButton(0, 3, .right_shoulder));
    try testing.expect(!s.bindButton(0, 3, .dpad_up));
    try testing.expect(!s.bindButton(0, 3, .guide));
    try testing.expect(buttonsDistinct(&s.layout.players[0]));
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

    const damaged = "{\"version\": 2, \"players\": 3, \"settings_key\": \"f1\", \"sound\": {\"volume\": 20, \"mute\": false}, \"window\": {\"scale\": 0, \"fullscreen\": true}, \"rules\": {}}";
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

    // Another version's record: the defaults, written over it, untold, nothing kept aside.
    try storage.deleteSave(damaged_name);
    try storage.save(name, "{\"version\": 1, \"keys\": {}}");
    got = load(testing.allocator, storage);
    try testing.expect(!got.damaged());
    try testing.expectEqual(Settings{}, got.settings);
    try testing.expectError(error.NotFound, storage.load(damaged_name));
    var rewritten = try storage.load(name);
    defer rewritten.deinit();
    var buf: [max_written]u8 = undefined;
    try testing.expectEqualStrings(encode(&Settings{}, &buf), rewritten.bytes);
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

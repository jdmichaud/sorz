//! Network play's screens of this machine (DESIGN.md 9), overlays over the game in the settings
//! screen's style (screen.zig): the host's network options, opened by its menu's NETWORK PLAY, and
//! a client's name entry.
//!
//! - **The network options**: PLAYERS (2, the only number today), OBSERVERS (whether the session
//!   takes them), SAME CHARACTER (whether the two players may choose one character), START (the
//!   session opens) and EXIT (it does not). Up and down move, left, right, A, B or C change a
//!   value, A, B or C on START or EXIT act; START opens the session from any line; Escape, the
//!   settings key's place, and a gamepad's BACK leave as EXIT does.
//! - **The name entry**: ENTER YOUR NAME, three letters (A to Z, then 0 to 9): up and down change
//!   the letter under the cursor, left and right move it; A, B, C or START keeps the name, Escape
//!   or BACK leaves it as it was.
//!
//! The pads' keys of this machine's players work them as they work the menus, and the arrows and
//! Escape whatever those keys are.
const std = @import("std");
const platform = @import("../platform.zig");
const input = @import("../input.zig");
const panel_mod = @import("../panel.zig");
const record = @import("record.zig");

const Panel = panel_mod.Panel;
const Settings = record.Settings;

/// What a press did on a screen: stay, or leave (with the screen's answer kept).
pub const Result = enum { stay, done, cancel };

/// A press, as the screens take it.
const Nav = enum { up, down, left, right, choose, start, back };

/// The press `e` is on this machine: a player's key (pad 1 or 2's) or a gamepad's button, by the
/// players' layout, or the arrows, Enter and Escape whatever the keys are; null for another.
fn navOf(settings: *const Settings, players: usize, e: platform.Event) ?Nav {
    switch (e.payload) {
        .key_down => |k| {
            if (k.repeat) return switch (k.key) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                else => null,
            };
            if (settings.layout.find(k.key)) |place| if (place.player < players) return navOfButton(place.button);
            return switch (k.key) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                .enter => .start,
                .escape => .back,
                else => null,
            };
        },
        .controller_button_down => |b| return switch (b.button) {
            .dpad_up => .up,
            .dpad_down => .down,
            .dpad_left => .left,
            .dpad_right => .right,
            .back => .back,
            else => for (input.default_buttons, input.face_buttons) |x, face| {
                if (x == b.button) break navOfButton(face);
            } else null,
        },
        else => return null,
    }
}

fn navOfButton(b: input.Button) Nav {
    return switch (b) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        .a, .b, .c => .choose,
        .start => .start,
    };
}

const box_col = 1;
const box_row = 1;
const label_col = 3;
const value_col = 24;
const title_row = 2;
const first_row = 5;

/// The host's network options.
pub const NetOptions = struct {
    row: Row = .observers,
    observers: bool = true,
    same_character: bool = false,
    /// The players of this machine, whose keys work the screen.
    players: usize = 1,

    pub const Row = enum(u8) { players, observers, same_character, start, exit };

    /// Takes one event.
    pub fn handle(self: *NetOptions, settings: *const Settings, e: platform.Event) Result {
        const nav = navOf(settings, self.players, e) orelse return .stay;
        switch (nav) {
            .up => self.row = if (self.row == .observers) .exit else @fromBackingInt(@backingInt(self.row) - 1),
            .down => self.row = if (self.row == .exit) .observers else @fromBackingInt(@backingInt(self.row) + 1),
            .left, .right => self.change(),
            .choose => switch (self.row) {
                .start => return .done,
                .exit => return .cancel,
                else => self.change(),
            },
            .start => return .done,
            .back => return .cancel,
        }
        return .stay;
    }

    fn change(self: *NetOptions) void {
        switch (self.row) {
            .observers => self.observers = !self.observers,
            .same_character => self.same_character = !self.same_character,
            else => {},
        }
    }

    fn rowOf(r: Row) usize {
        return switch (r) {
            .players, .observers, .same_character => first_row + @backingInt(r),
            .start, .exit => first_row + @backingInt(r) + 1,
        };
    }

    pub fn draw(self: *const NetOptions, p: *Panel, arrow: bool) Panel.Error!void {
        try p.box(box_col, box_row, panel_mod.columns - 2 * box_col, panel_mod.rows - 2 * box_row);
        try p.text(label_col, title_row, "NETWORK PLAY", .bright);
        const rows = [_]struct { Row, []const u8, ?[]const u8 }{
            .{ .players, "PLAYERS", "2" },
            .{ .observers, "OBSERVERS", if (self.observers) "YES" else "NO" },
            .{ .same_character, "SAME CHARACTER", if (self.same_character) "YES" else "NO" },
            .{ .start, "START", null },
            .{ .exit, "EXIT", null },
        };
        for (rows) |r| {
            // PLAYERS is two today: dim, never chosen.
            const tone: panel_mod.Tone = if (r[0] == self.row) .bright else .dim;
            try p.text(label_col, rowOf(r[0]), r[1], tone);
            if (r[2]) |v| try p.text(value_col, rowOf(r[0]), v, tone);
        }
        if (arrow) p.arrowAt(if (self.row == .start or self.row == .exit) label_col - 1 else value_col - 1, @intCast(rowOf(self.row)));
    }
};

/// The letters a name takes, in their order.
const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// A client's name entry.
pub const NameEntry = struct {
    name: [3]u8 = "AAA".*,
    at: u2 = 0,
    players: usize = 1,

    pub fn open(name: [3]u8, players: usize) NameEntry {
        var e: NameEntry = .{ .players = players };
        for (name, 0..) |ch, i| e.name[i] = if (std.mem.indexOfScalar(u8, letters, ch) != null) ch else 'A';
        return e;
    }

    pub fn handle(self: *NameEntry, settings: *const Settings, e: platform.Event) Result {
        const nav = navOf(settings, self.players, e) orelse return .stay;
        switch (nav) {
            .up, .down => {
                const i = std.mem.indexOfScalar(u8, letters, self.name[self.at]) orelse 0;
                const n = letters.len;
                self.name[self.at] = letters[if (nav == .down) (i + 1) % n else (i + n - 1) % n];
            },
            .left => self.at = if (self.at == 0) 2 else self.at - 1,
            .right => self.at = if (self.at == 2) 0 else self.at + 1,
            .choose, .start => return .done,
            .back => return .cancel,
        }
        return .stay;
    }

    pub fn draw(self: *const NameEntry, p: *Panel, arrow: bool) Panel.Error!void {
        try p.box(box_col, box_row, panel_mod.columns - 2 * box_col, panel_mod.rows - 2 * box_row);
        try p.text(label_col, title_row, "ENTER YOUR NAME", .bright);
        const col = (panel_mod.columns - 5) / 2;
        for (self.name, 0..) |ch, i| try p.text(col + 2 * i, 12, &.{ch}, if (i == self.at) .bright else .dim);
        if (arrow) p.arrowAt(@intCast(col + 2 * @as(usize, self.at) - 1), 12);
        try p.text(label_col, panel_mod.rows - 3, "UP, DOWN: THE LETTER. A, B, C: DONE.", .dim);
    }
};

const testing = std.testing;

fn key(k: platform.Key) platform.Event {
    return .{ .time_ns = 0, .payload = .{ .key_down = .{ .key = k } } };
}

test "the network options: values changed, START opens, EXIT or Escape do not" {
    const s: Settings = .{};
    var o: NetOptions = .{};
    try testing.expectEqual(Result.stay, o.handle(&s, key(.z)));
    try testing.expect(!o.observers);
    _ = o.handle(&s, key(.down));
    _ = o.handle(&s, key(.right));
    try testing.expect(o.same_character);
    _ = o.handle(&s, key(.down));
    try testing.expectEqual(Result.done, o.handle(&s, key(.x)));
    _ = o.handle(&s, key(.down));
    try testing.expectEqual(Result.cancel, o.handle(&s, key(.c)));
    try testing.expectEqual(Result.cancel, o.handle(&s, key(.escape)));
    try testing.expectEqual(Result.done, o.handle(&s, key(.enter)));
    // PLAYERS is not a line the cursor takes.
    o.row = .observers;
    _ = o.handle(&s, key(.up));
    try testing.expectEqual(NetOptions.Row.exit, o.row);
}

test "the name entry: letters up and down, the cursor round, A keeps it" {
    const s: Settings = .{};
    var e: NameEntry = .open(.{ ' ', 'B', '?' }, 1);
    try testing.expectEqualSlices(u8, "ABA", &e.name);
    _ = e.handle(&s, key(.up));
    try testing.expectEqual(@as(u8, '9'), e.name[0]);
    _ = e.handle(&s, key(.left));
    _ = e.handle(&s, key(.down));
    try testing.expectEqualSlices(u8, "9BB", &e.name);
    try testing.expectEqual(Result.done, e.handle(&s, key(.z)));
    try testing.expectEqual(Result.cancel, e.handle(&s, key(.escape)));
}

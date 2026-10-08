//! Network play's screens of this machine (DESIGN.md 9), overlays over the game in the settings
//! screen's style (screen.zig): the host's network options, opened by its menu's NETWORK PLAY, and
//! a client's name entry.
//!
//! - **The network options**: PLAYERS (2, the only number today), PORT (the native host's, which
//!   it listens at once its server starts: fixed from then on; none on a page), OBSERVERS (whether
//!   the session takes them), SAME CHARACTER (whether the two players may choose one character),
//!   JOIN IN PROGRESS (whether a player may join a game under way, past its select: the host's own
//!   player coming back too); then START SERVER (the session opens: the screen stays, the host's
//!   lobby, listing who is connected while clients come), or STOP SERVER while it runs (its
//!   clients go; the screen stays), START GAME (the session opens if it is not, and the host's
//!   player goes to the character select) and EXIT (back to the menu, the server as it is). Over
//!   a game the host's player left for its clients to play on (`in_game`), START GAME is RETURN
//!   TO GAME (player 1 drops back in, when JOIN IN PROGRESS allows it), and EXIT shows the game
//!   (the host's player watching it). Up and down move, left,
//!   right, A, B or C change a value, A, B, C or START on an action act; START on a value is START
//!   GAME; Escape, the settings key's place, and a gamepad's BACK leave as EXIT does. A, B or C
//!   on PORT edits it, a digit at a time: left and right move between the digits, up and down
//!   change the one there, A, B, C or START keep the port (1 to 65535), Escape or BACK leave it as
//!   it was.
//! - **The name entry**: ENTER YOUR NAME, three letters (A to Z, then 0 to 9): up and down change
//!   the letter under the cursor, left and right move it; A, B, C or START keeps the name, Escape
//!   or BACK leaves it as it was.
//!
//! The pads' keys of this machine's players work them as they work the menus, and the arrows and
//! Escape whatever those keys are.
const std = @import("std");
const platform = @import("../platform.zig");
const netplay = @import("../net/netplay.zig");
const input = @import("../input.zig");
const panel_mod = @import("../panel.zig");
const record = @import("record.zig");

const Panel = panel_mod.Panel;
const Settings = record.Settings;

/// What a press did on a screen: stay, act and stay (the network options' server), or leave
/// (with the screen's answer kept).
pub const Result = enum { stay, acted, done, cancel };

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
    join_in_progress: bool = true,
    /// Over a game the host's player left for its clients (the game runs on under the screen),
    /// and whether player 1 can come back to it now.
    in_game: bool = false,
    can_return: bool = false,
    /// The port the host listens at (null: none, a page's), and whether it is fixed (it listens).
    port: ?u16 = null,
    port_fixed: bool = false,
    /// The digit of the port edited (0 the first of five), and the port before the edit.
    editing: ?u3 = null,
    port_before: u16 = 0,
    /// The host's server runs (its line is STOP SERVER), and the action last taken.
    serving: bool = false,
    action: Action = .start_game,
    /// Who is connected, while the server runs (the game keeps it up to date).
    clients: [max_clients]netplay.Entry = undefined,
    client_count: u8 = 0,
    /// The players of this machine, whose keys work the screen.
    players: usize = 1,

    pub const Row = enum(u8) { players, port, observers, same_character, join_in_progress, server, game, exit };
    pub const Action = enum { start_server, stop_server, start_game, return_to_game };
    /// The clients the screen lists.
    pub const max_clients = 8;

    const digits = 5;

    /// What the options choose of the session.
    pub const Choice = struct { observers: bool = true, same_character: bool = false, join_in_progress: bool = true };

    pub fn choice(self: *const NetOptions) Choice {
        return .{ .observers = self.observers, .same_character = self.same_character, .join_in_progress = self.join_in_progress };
    }

    /// The options as they open: the cursor on the first line it takes.
    pub fn open(self: NetOptions) NetOptions {
        var o = self;
        o.row = if (o.takes(.port)) .port else .observers;
        return o;
    }

    /// Takes one event.
    pub fn handle(self: *NetOptions, settings: *const Settings, e: platform.Event) Result {
        const nav = navOf(settings, self.players, e) orelse return .stay;
        if (self.editing) |*at| {
            const port = self.port.?;
            switch (nav) {
                .left => at.* = if (at.* == 0) digits - 1 else at.* - 1,
                .right => at.* = if (at.* == digits - 1) 0 else at.* + 1,
                .up, .down => self.port = turnDigit(port, at.*, nav == .up),
                .choose, .start => {
                    if (port == 0) self.port = self.port_before;
                    self.editing = null;
                },
                .back => {
                    self.port = self.port_before;
                    self.editing = null;
                },
            }
            return .stay;
        }
        switch (nav) {
            .up => self.move(-1),
            .down => self.move(1),
            .left, .right => self.change(),
            .choose => switch (self.row) {
                .server, .game, .exit => return self.act(self.row),
                .port => {
                    self.port_before = self.port.?;
                    self.editing = 0;
                },
                else => self.change(),
            },
            // On an action, START is A there; on a value, START GAME.
            .start => return self.act(switch (self.row) {
                .server, .exit => self.row,
                else => .game,
            }),
            .back => return .cancel,
        }
        return .stay;
    }

    /// The action of line `r`: START SERVER or STOP SERVER (the screen stays), START GAME, EXIT.
    fn act(self: *NetOptions, r: Row) Result {
        switch (r) {
            .server => {
                self.action = if (self.serving) .stop_server else .start_server;
                return .acted;
            },
            .game => {
                if (!self.takes(.game)) return .stay;
                self.action = if (self.in_game) .return_to_game else .start_game;
                return .done;
            },
            else => return .cancel,
        }
    }

    /// The server as the game left it after an action: running or not, its port fixed or not;
    /// started, the cursor goes to START GAME.
    pub fn served(self: *NetOptions, serving: bool, port_fixed: bool) void {
        if (serving and !self.serving) self.row = .game;
        self.serving = serving;
        self.port_fixed = port_fixed;
        if (!serving) self.client_count = 0;
    }

    /// Whether the cursor takes line `r`: not PLAYERS (two today), PORT when there is one to
    /// change.
    fn takes(self: *const NetOptions, r: Row) bool {
        return switch (r) {
            .players => false,
            .port => self.port != null and !self.port_fixed,
            .game => !self.in_game or self.can_return,
            else => true,
        };
    }

    /// The cursor to the next line it takes up (`step` -1) or down, round the ends.
    fn move(self: *NetOptions, step: i8) void {
        const n = std.enums.values(Row).len;
        var i: usize = @backingInt(self.row);
        for (0..n) |_| {
            i = if (step < 0) (i + n - 1) % n else (i + 1) % n;
            if (self.takes(@fromBackingInt(@intCast(i)))) break;
        }
        self.row = @fromBackingInt(@intCast(i));
    }

    fn change(self: *NetOptions) void {
        switch (self.row) {
            .observers => self.observers = !self.observers,
            .same_character => self.same_character = !self.same_character,
            .join_in_progress => self.join_in_progress = !self.join_in_progress,
            else => {},
        }
    }

    /// The port with its digit `at` (of five, from the first) one up or down, round from 9 to 0;
    /// past 65535, 65535.
    fn turnDigit(port: u16, at: u3, up: bool) u16 {
        var weight: u32 = 1;
        for (0..digits - 1 - @as(usize, at)) |_| weight *= 10;
        const d = (port / weight) % 10;
        const turned: u32 = if (up) (d + 1) % 10 else (d + 9) % 10;
        const v = @as(u32, port) - d * weight + turned * weight;
        return @intCast(@min(v, std.math.maxInt(u16)));
    }

    /// The panel's row of line `r` (PORT's none without a port; the actions after a blank).
    fn rowOf(self: *const NetOptions, r: Row) usize {
        var row: usize = first_row;
        for (std.enums.values(Row)) |x| {
            if (x == .port and self.port == null) continue;
            if (x == .server) row += 1;
            if (x == r) return row;
            row += 1;
        }
        unreachable;
    }

    pub fn draw(self: *const NetOptions, p: *Panel, arrow: bool) Panel.Error!void {
        try p.box(box_col, box_row, panel_mod.columns - 2 * box_col, panel_mod.rows - 2 * box_row);
        try p.text(label_col, title_row, "NETWORK PLAY", .bright);
        var port_buf: [8]u8 = undefined;
        const port_text: ?[]const u8 = if (self.port) |v| std.fmt.bufPrint(&port_buf, "{d}", .{v}) catch unreachable else null;
        const rows = [_]struct { Row, []const u8, ?[]const u8 }{
            .{ .players, "PLAYERS", "2" },
            .{ .port, "PORT", port_text },
            .{ .observers, "OBSERVERS", if (self.observers) "YES" else "NO" },
            .{ .same_character, "SAME CHARACTER", if (self.same_character) "YES" else "NO" },
            .{ .join_in_progress, "JOIN IN PROGRESS", if (self.join_in_progress) "YES" else "NO" },
            .{ .server, if (self.serving) "STOP SERVER" else "START SERVER", null },
            .{ .game, if (self.in_game) "RETURN TO GAME" else "START GAME", null },
            .{ .exit, "EXIT", null },
        };
        for (rows) |r| {
            if (r[0] == .port and self.port == null) continue;
            // PLAYERS is two today, a fixed port the one listened at: dim, never chosen.
            const tone: panel_mod.Tone = if (r[0] == self.row) .bright else .dim;
            const row = self.rowOf(r[0]);
            try p.text(label_col, row, r[1], tone);
            if (r[0] == .port) if (self.editing) |at| {
                // Its five digits apart, the one edited bright, the arrow before it.
                var buf: [digits]u8 = undefined;
                _ = std.fmt.bufPrint(&buf, "{d:0>5}", .{self.port.?}) catch unreachable;
                for (buf, 0..) |ch, i| try p.text(value_col + 2 * i, row, &.{ch}, if (i == at) .bright else .dim);
                if (arrow) p.arrowAt(@intCast(value_col + 2 * @as(usize, at) - 1), @intCast(row));
                continue;
            };
            if (r[2]) |v| try p.text(value_col, row, v, tone);
        }
        // The lobby: who is connected, while the server runs.
        if (self.serving) {
            const top = self.rowOf(.exit) + 2;
            try p.text(label_col, top, "CONNECTED", .bright);
            // The host's player out of the game its clients play on: in its lobby.
            try p.text(label_col, top + 1, if (self.in_game) "LOCAL - LOBBY" else netplay.local_line, .dim);
            for (self.clients[0..self.client_count], 0..) |*c, i| {
                var buf: [24]u8 = undefined;
                try p.text(label_col, top + 2 + i, c.line(&buf), .dim);
            }
        }
        if (self.editing != null) return;
        const action = self.row == .server or self.row == .game or self.row == .exit;
        if (arrow) p.arrowAt(if (action) label_col - 1 else value_col - 1, @intCast(self.rowOf(self.row)));
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

test "the network options: values changed, START SERVER or GAME, STOP SERVER; EXIT or Escape leave" {
    const s: Settings = .{};
    var o: NetOptions = .{};
    try testing.expectEqual(Result.stay, o.handle(&s, key(.z)));
    try testing.expect(!o.observers);
    _ = o.handle(&s, key(.down));
    _ = o.handle(&s, key(.right));
    try testing.expect(o.same_character);
    _ = o.handle(&s, key(.down));
    _ = o.handle(&s, key(.z));
    try testing.expect(!o.join_in_progress);
    _ = o.handle(&s, key(.down));
    try testing.expectEqual(Result.acted, o.handle(&s, key(.x)));
    try testing.expectEqual(NetOptions.Action.start_server, o.action);
    // Started: STOP SERVER, the cursor on START GAME.
    o.served(true, true);
    try testing.expectEqual(NetOptions.Row.game, o.row);
    o.row = .server;
    try testing.expectEqual(Result.acted, o.handle(&s, key(.x)));
    try testing.expectEqual(NetOptions.Action.stop_server, o.action);
    _ = o.handle(&s, key(.down));
    try testing.expectEqual(Result.done, o.handle(&s, key(.x)));
    try testing.expectEqual(NetOptions.Action.start_game, o.action);
    _ = o.handle(&s, key(.down));
    try testing.expectEqual(Result.cancel, o.handle(&s, key(.c)));
    try testing.expectEqual(Result.cancel, o.handle(&s, key(.escape)));
    o.row = .observers;
    o.action = .stop_server;
    try testing.expectEqual(Result.done, o.handle(&s, key(.enter)));
    try testing.expectEqual(NetOptions.Action.start_game, o.action);
    // START on an action is A there.
    o.row = .server;
    o.serving = false;
    try testing.expectEqual(Result.acted, o.handle(&s, key(.enter)));
    try testing.expectEqual(NetOptions.Action.start_server, o.action);
    o.row = .exit;
    try testing.expectEqual(Result.cancel, o.handle(&s, key(.enter)));
    // PLAYERS is not a line the cursor takes, nor PORT without one.
    o.row = .observers;
    _ = o.handle(&s, key(.up));
    try testing.expectEqual(NetOptions.Row.exit, o.row);
}

test "over a game in progress: RETURN TO GAME when player 1 can come back, else skipped; EXIT" {
    const s: Settings = .{};
    var o: NetOptions = .{ .in_game = true, .serving = true, .row = .server };
    _ = o.handle(&s, key(.down));
    try testing.expectEqual(NetOptions.Row.exit, o.row);
    // START on a value would be RETURN TO GAME: not now.
    o.row = .observers;
    try testing.expectEqual(Result.stay, o.handle(&s, key(.enter)));
    o.can_return = true;
    o.row = .server;
    _ = o.handle(&s, key(.down));
    try testing.expectEqual(NetOptions.Row.game, o.row);
    try testing.expectEqual(Result.done, o.handle(&s, key(.z)));
    try testing.expectEqual(NetOptions.Action.return_to_game, o.action);
    o.row = .exit;
    try testing.expectEqual(Result.cancel, o.handle(&s, key(.z)));
}

test "the network options' PORT: edited a digit at a time, kept or left; fixed, not taken" {
    const s: Settings = .{};
    var o = (NetOptions{ .port = 8000 }).open();
    try testing.expectEqual(NetOptions.Row.port, o.row);
    _ = o.handle(&s, key(.z));
    try testing.expectEqual(@as(?u3, 0), o.editing);
    // 08000: the first digit up twice, the second down once, kept.
    _ = o.handle(&s, key(.up));
    _ = o.handle(&s, key(.up));
    _ = o.handle(&s, key(.right));
    _ = o.handle(&s, key(.down));
    try testing.expectEqual(@as(?u16, 27000), o.port);
    try testing.expectEqual(Result.stay, o.handle(&s, key(.enter)));
    try testing.expect(o.editing == null and o.port.? == 27000);
    // Past 65535: 65535. Escape leaves the port as it was.
    _ = o.handle(&s, key(.z));
    for (0..4) |_| _ = o.handle(&s, key(.up));
    try testing.expectEqual(@as(?u16, 65535), o.port);
    _ = o.handle(&s, key(.escape));
    try testing.expectEqual(@as(?u16, 27000), o.port);
    // Up from PORT goes round to EXIT; fixed, the cursor does not take it.
    _ = o.handle(&s, key(.up));
    try testing.expectEqual(NetOptions.Row.exit, o.row);
    var fixed = (NetOptions{ .port = 8000, .port_fixed = true }).open();
    try testing.expectEqual(NetOptions.Row.observers, fixed.row);
    _ = fixed.handle(&s, key(.up));
    try testing.expectEqual(NetOptions.Row.exit, fixed.row);
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

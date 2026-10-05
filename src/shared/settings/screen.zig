//! The settings screen (DESIGN.md 7, 10.4 S3): the player changes this machine's settings record
//! in the game, on a scene over the game's picture that holds the game while it is open
//! (game.zig: the overlays). It is reached from OPTIONS' ADVANCED SETTINGS and from START during
//! play (the extended and network variants, variant.zig), and in the original with the settings
//! key (F1 by default), in any scene.
//!
//! Its rows, in the cartridge's options' style (the chosen row bright, the others dim, the menu's
//! arrow at the choice): each pad button's key, for player 1 and player 2, and, for A, B, C and
//! START, the gamepads' button (every gamepad: its directions are always its d-pad and left stick);
//! the settings key, where the variant has it; which player the first gamepad plays (the second
//! plays the other); the volume and the sound; the window's scale and full screen; the defaults;
//! and the two ways out, SAVE AND EXIT and EXIT WITHOUT SAVING. They are this machine's players'
//! alone: a machine with one player (network play, a browser) shows its keys alone (YOUR KEYS:
//! pad 1's, which network play sends) and the gamepads' buttons; every gamepad plays that player,
//! so there is no FIRST GAMEPAD row.
//!
//! The arrows move, Enter changes (a key or a button: the next one pressed is the new one; one
//! that another setting has is swapped with it, so that no key does two things), left and right
//! change a value. Escape saves and leaves, as SAVE AND EXIT does; EXIT WITHOUT SAVING, the
//! settings key (where the variant has it) and a gamepad's B or BACK leave without saving, giving
//! back the settings the screen opened with. A gamepad's d-pad and A or START do what the arrows and Enter do. The
//! arrows, Enter and Escape keep their meaning here whatever the pads' keys are, so the screen is
//! always usable. The changes apply at once (the keys when the screen closes).
const std = @import("std");
const platform = @import("../platform.zig");
const input = @import("../input.zig");
const record = @import("record.zig");
const panel_mod = @import("../panel.zig");

const Settings = record.Settings;
const Panel = panel_mod.Panel;

pub const Row = enum(u8) {
    up,
    down,
    left,
    right,
    a,
    b,
    c,
    start,
    settings_key,
    first_pad,
    volume,
    sound,
    scale,
    fullscreen,
    defaults,
    save_and_exit,
    exit_without_saving,

    /// The pad button of a key row.
    fn button(row: Row) ?input.Button {
        return if (@backingInt(row) < 8) @fromBackingInt(@as(u3, @intCast(@backingInt(row)))) else null;
    }

    /// The index in `input.face_buttons` of a row whose button a gamepad's button presses.
    fn face(row: Row) ?usize {
        const b = row.button() orelse return null;
        return std.mem.indexOfScalar(input.Button, &input.face_buttons, b);
    }

    /// The columns of the row: pad 1's key, pad 2's and the gamepads' button for A, B, C and
    /// START; the two pads' keys for the directions; one value for the others.
    fn columns(row: Row) u2 {
        if (row.face() != null) return 3;
        if (row.button() != null) return 2;
        return 1;
    }
};

const row_count = std.enums.values(Row).len;

/// The volume's step.
const volume_step = 10;

/// What the screen shows on this machine.
pub const Facts = struct {
    /// One player on the machine: its keys alone, and no FIRST GAMEPAD.
    one_player: bool = false,
    /// The settings key opens the settings (the original): its row, and it leaves them.
    settings_key: bool = true,
};

/// What an event did: the screen stays open, or it closed, its settings to be written, or given
/// back as they were when it opened.
pub const Result = enum { stay, save_and_exit, exit_without_saving };

pub const Screen = struct {
    facts: Facts = .{},
    row: Row = .up,
    /// In a key row: 0 pad 1, 1 pad 2, 2 the gamepads' button.
    column: u2 = 0,
    /// Waiting for the new key (or gamepad button) of the chosen setting.
    waiting: bool = false,
    /// The settings when the screen opened, which leaving it without saving gives back.
    before: Settings = .{},

    pub fn open(settings: *const Settings, facts: Facts) Screen {
        return .{ .facts = facts, .before = settings.* };
    }

    /// Whether the screen has the row here.
    fn shows(self: *const Screen, row: Row) bool {
        return switch (row) {
            .first_pad => !self.facts.one_player,
            .settings_key => self.facts.settings_key,
            else => true,
        };
    }

    /// Whether the row has the column here: not player 2's keys with one player.
    fn hasColumn(self: *const Screen, row: Row, column: u2) bool {
        return column < row.columns() and !(self.facts.one_player and column == 1);
    }

    /// Takes one event; `settings` change as the player chooses. When it closes without saving,
    /// they are already given back.
    pub fn handle(self: *Screen, settings: *Settings, e: platform.Event) Result {
        switch (e.payload) {
            .key_down => |k| {
                if (self.waiting) {
                    self.takeKey(settings, k);
                    return .stay;
                }
                const nav: Nav = switch (k.key) {
                    .up => .up,
                    .down => .down,
                    .left => .left,
                    .right => .right,
                    .enter, .space => if (k.repeat) return .stay else .choose,
                    .escape => .back,
                    else => if (self.facts.settings_key and k.key == settings.settings_key and !k.repeat) .leave else return .stay,
                };
                return self.navigate(settings, nav);
            },
            .controller_button_down => |b| {
                if (self.waiting) {
                    self.takeButton(settings, b.button);
                    return .stay;
                }
                const nav: Nav = switch (b.button) {
                    .dpad_up => .up,
                    .dpad_down => .down,
                    .dpad_left => .left,
                    .dpad_right => .right,
                    .a, .start => .choose,
                    .b, .back => .leave,
                    else => return .stay,
                };
                return self.navigate(settings, nav);
            },
            else => return .stay,
        }
    }

    /// `back` saves and leaves (Escape), `leave` leaves without saving.
    const Nav = enum { up, down, left, right, choose, back, leave };

    fn navigate(self: *Screen, settings: *Settings, nav: Nav) Result {
        switch (nav) {
            .up, .down => {
                var next: usize = @backingInt(self.row);
                while (true) {
                    next = if (nav == .up) (next + row_count - 1) % row_count else (next + 1) % row_count;
                    if (self.shows(@fromBackingInt(@as(u8, @intCast(next))))) break;
                }
                self.row = @fromBackingInt(@as(u8, @intCast(next)));
                while (!self.hasColumn(self.row, self.column)) self.column -= 1;
            },
            .left, .right => {
                const up = nav == .right;
                if (self.row.columns() > 1) {
                    // To the next column the row has here, if any.
                    var c = self.column;
                    while (if (up) c < 2 else c > 0) {
                        c = if (up) c + 1 else c - 1;
                        if (self.hasColumn(self.row, c)) {
                            self.column = c;
                            break;
                        }
                    }
                } else change(self.row, settings, up);
            },
            .choose => switch (self.row) {
                .volume => {},
                .scale => settings.window.scale = if (settings.window.scale >= record.max_scale) 1 else settings.window.scale + 1,
                .defaults => settings.* = .{},
                .save_and_exit => return .save_and_exit,
                .exit_without_saving => return self.leave(settings),
                else => if (self.row.button() != null or self.row == .settings_key) {
                    self.waiting = true;
                } else change(self.row, settings, true),
            },
            .back => return .save_and_exit,
            .leave => return self.leave(settings),
        }
        return .stay;
    }

    fn leave(self: *Screen, settings: *Settings) Result {
        settings.* = self.before;
        self.waiting = false;
        return .exit_without_saving;
    }

    /// Left and right on a value; Enter on a choice of two.
    fn change(row: Row, settings: *Settings, up: bool) void {
        switch (row) {
            .first_pad => settings.layout.first_pad ^= 1,
            .volume => {
                // By tens; a hand-edited volume goes to the nearest ten in the direction.
                const v = settings.sound.volume;
                settings.sound.volume = if (up)
                    @min((v / volume_step + 1) * volume_step, record.max_volume)
                else if (v % volume_step != 0) v / volume_step * volume_step else v -| volume_step;
            },
            .sound => settings.sound.mute = !settings.sound.mute,
            .scale => settings.window.scale = if (up) @min(settings.window.scale + 1, record.max_scale) else @max(settings.window.scale - 1, 1),
            .fullscreen => settings.window.fullscreen = !settings.window.fullscreen,
            else => {},
        }
    }

    fn keySlot(self: *const Screen) Settings.KeySlot {
        if (self.row == .settings_key) return .settings;
        return .{ .pad = .{ .pad = @intCast(self.column), .button = self.row.button().? } };
    }

    /// The key pressed while waiting: Escape keeps the old one; a key no setting can take is
    /// ignored. A key pressed while waiting for a gamepad's button keeps the old button.
    fn takeKey(self: *Screen, settings: *Settings, k: platform.Event.KeyEvent) void {
        if (k.repeat) return;
        if (self.column == 2) {
            self.waiting = false;
            return;
        }
        if (k.key == .escape or settings.bindKey(self.keySlot(), k.key)) self.waiting = false;
    }

    /// The gamepad's button pressed while waiting: the new button of the gamepads' A, B, C or
    /// START. While waiting for a key, a button keeps the old key.
    fn takeButton(self: *Screen, settings: *Settings, b: platform.ControllerButton) void {
        if (self.column != 2) {
            self.waiting = false;
            return;
        }
        if (settings.bindButton(self.row.face().?, b)) self.waiting = false;
    }

    // --- the picture ---------------------------------------------------------------------------

    /// Where the screen's parts are, in cells: the box, the title, the key columns' headers on the
    /// two rows above the key rows, the other rows below these, and the prompt while it waits.
    const box_col = 1;
    const box_row = 1;
    const title_row = 2;
    const header_row = 4;
    const label_col = 3;
    const value_cols = [3]u16{ 10, 20, 30 };
    const single_col = 23;
    const first_key_row = 6;
    const prompt_row = panel_mod.rows - 3;

    /// The key columns' headers, two rows each: each player's keys, and the gamepads' buttons for
    /// A, B, C and START. With one player: its keys and the gamepads', the gamepads' column under
    /// the other rows' values, apart from YOUR KEYS so that the two headers do not read as one.
    const headers = [3][2][]const u8{ .{ "PLAYER 1", "KEYS" }, .{ "PLAYER 2", "KEYS" }, .{ "", "GAMEPADS" } };
    const one_player_headers = [3][2][]const u8{ .{ "", "YOUR KEYS" }, .{ "", "" }, .{ "", "GAMEPADS" } };
    const one_player_cols = [3]u16{ 10, single_col, single_col };

    /// The cell column of a key row's column.
    fn columnX(self: *const Screen, c: usize) u16 {
        return if (self.facts.one_player) one_player_cols[c] else value_cols[c];
    }

    /// The screen's row of `row`: the rows it does not show leave no gap.
    fn screenRow(self: *const Screen, row: Row) u16 {
        var n: u16 = 0;
        for (std.enums.values(Row)[0..@backingInt(row)]) |r| n += @intFromBool(self.shows(r));
        return switch (row) {
            .up, .down, .left, .right, .a, .b, .c, .start => first_key_row + n,
            .defaults, .save_and_exit, .exit_without_saving => first_key_row + n + 2,
            else => first_key_row + n + 1,
        };
    }

    /// Draws the screen on `p` (its picture begun): a black box over the game's picture, which
    /// the panel dims. `arrow`: the arrow shows (it blinks while the screen waits for a key).
    pub fn draw(self: *const Screen, settings: *const Settings, p: *Panel, arrow: bool) Panel.Error!void {
        try p.box(box_col, box_row, panel_mod.columns - 2 * box_col, panel_mod.rows - 2 * box_row);
        try p.text(label_col, title_row, "SETTINGS", .bright);
        for (if (self.facts.one_player) one_player_headers else headers, 0..) |lines, c| {
            for (lines, header_row..) |line, y| try p.text(self.columnX(c), y, line, .dim);
        }
        var buf: [16]u8 = undefined;
        for (std.enums.values(Row)) |row| {
            if (!self.shows(row)) continue;
            const y = self.screenRow(row);
            const chosen = row == self.row;
            const tone: panel_mod.Tone = if (chosen) .bright else .dim;
            try p.text(label_col, y, label(row), tone);
            if (row.button()) |b| {
                for (0..row.columns()) |c| {
                    if (!self.hasColumn(row, @intCast(c))) continue;
                    const here = chosen and c == self.column;
                    const name = if (c == 2)
                        buttonName(settings.layout.buttons[row.face().?])
                    else
                        keyName(settings.layout.keys[c][@backingInt(b)]);
                    try p.text(self.columnX(c), y, if (here and self.waiting) "" else name, if (here) .bright else .dim);
                }
            } else if (value(row, settings, &buf)) |v| try p.text(single_col, y, v, tone);
        }
        if (arrow) {
            const y = self.screenRow(self.row);
            const x: u16 = if (self.row.columns() > 1) self.columnX(self.column) - 1 else if (value(self.row, settings, &buf) != null) single_col - 1 else label_col - 1;
            p.arrowAt(x, y);
        }
        if (self.waiting) try p.text(label_col, prompt_row, if (self.column == 2) "PRESS THE NEW GAMEPAD BUTTON." else "PRESS THE NEW KEY.", .dim);
    }

    fn label(row: Row) []const u8 {
        return switch (row) {
            .up => "UP",
            .down => "DOWN",
            .left => "LEFT",
            .right => "RIGHT",
            .a => "A",
            .b => "B",
            .c => "C",
            .start => "START",
            .settings_key => "SETTINGS KEY",
            .first_pad => "FIRST GAMEPAD PLAYS",
            .volume => "VOLUME",
            .sound => "SOUND",
            .scale => "WINDOW SCALE",
            .fullscreen => "FULL SCREEN",
            .defaults => "DEFAULTS",
            .save_and_exit => "SAVE AND EXIT",
            .exit_without_saving => "EXIT WITHOUT SAVING",
        };
    }

    fn value(row: Row, settings: *const Settings, buf: *[16]u8) ?[]const u8 {
        return switch (row) {
            .settings_key => keyName(settings.settings_key),
            .first_pad => if (settings.layout.first_pad == 0) "PLAYER 1" else "PLAYER 2",
            .volume => std.fmt.bufPrint(buf, "{d}", .{settings.sound.volume}) catch unreachable,
            .sound => if (settings.sound.mute) "OFF" else "ON",
            .scale => std.fmt.bufPrint(buf, "{d}", .{settings.window.scale}) catch unreachable,
            .fullscreen => if (settings.window.fullscreen) "ON" else "OFF",
            else => null,
        };
    }
};

/// A key's name on the screen, in the game's font (at most 9 characters).
pub fn keyName(k: platform.Key) []const u8 {
    return switch (k) {
        .escape => "ESCAPE",
        .enter => "ENTER",
        .space => "SPACE",
        .tab => "TAB",
        .backspace => "BACKSPACE",
        .left => "LEFT",
        .right => "RIGHT",
        .up => "UP",
        .down => "DOWN",
        .home => "HOME",
        .end => "END",
        .page_up => "PAGE UP",
        .page_down => "PAGE DOWN",
        .insert => "INSERT",
        .delete => "DELETE",
        .left_shift => "L SHIFT",
        .right_shift => "R SHIFT",
        .left_ctrl => "L CTRL",
        .right_ctrl => "R CTRL",
        .left_alt => "L ALT",
        .right_alt => "R ALT",
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => @tagName(k),
        .digit_0, .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9 => @tagName(k)["digit_".len..],
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => @tagName(k),
        .minus => "-",
        .equals => "EQUALS",
        .comma => ",",
        .period => ".",
        .slash => "SLASH",
        .semicolon => ";",
        .apostrophe => "'",
        .grave => "GRAVE",
        .left_bracket => "L BRACKET",
        .right_bracket => "R BRACKET",
        .backslash => "BACKSLASH",
        .keypad_plus => "KP PLUS",
        .keypad_minus => "KP MINUS",
        .unknown => "?",
        _ => "?",
    };
}

/// A gamepad button's name on the screen (at most 5 characters).
pub fn buttonName(b: platform.ControllerButton) []const u8 {
    return switch (b) {
        .a => "A",
        .b => "B",
        .x => "X",
        .y => "Y",
        .back => "BACK",
        .guide => "GUIDE",
        .start => "START",
        .left_stick => "LS",
        .right_stick => "RS",
        .left_shoulder => "LB",
        .right_shoulder => "RB",
        .dpad_up => "UP",
        .dpad_down => "DOWN",
        .dpad_left => "LEFT",
        .dpad_right => "RIGHT",
        _ => "?",
    };
}

// --- tests -----------------------------------------------------------------------------------------

const testing = std.testing;

fn press(screen: *Screen, settings: *Settings, k: platform.Key) Result {
    return screen.handle(settings, .{ .time_ns = 0, .payload = .{ .key_down = .{ .key = k } } });
}

fn pressButton(screen: *Screen, settings: *Settings, b: platform.ControllerButton) Result {
    const id: platform.ControllerId = @fromBackingInt(1);
    return screen.handle(settings, .{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = id, .button = b } } });
}

test "rebinding a key swaps it with the setting that had it; Escape saves and leaves" {
    var s: Settings = .{};
    var screen: Screen = .open(&s, .{});
    // Pad 2's A (row a, column 1): Enter, then X, pad 1's B.
    for ([_]platform.Key{ .down, .down, .down, .down, .right, .enter }) |k| try testing.expectEqual(Result.stay, press(&screen, &s, k));
    try testing.expect(screen.waiting);
    // Arrows and Enter are keys too while it waits; a repeat is not a press.
    _ = screen.handle(&s, .{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x, .repeat = true } } });
    try testing.expect(screen.waiting);
    const pad1_b = s.layout.keys[0][@backingInt(input.Button.b)];
    try testing.expectEqual(platform.Key.x, pad1_b);
    const pad2_a = s.layout.keys[1][@backingInt(input.Button.a)];
    _ = press(&screen, &s, .x);
    try testing.expect(!screen.waiting);
    try testing.expectEqual(platform.Key.x, s.layout.keys[1][@backingInt(input.Button.a)]);
    try testing.expectEqual(pad2_a, s.layout.keys[0][@backingInt(input.Button.b)]);
    // Escape while waiting keeps the key; Escape then goes back, saving: the keys stay.
    _ = press(&screen, &s, .enter);
    _ = press(&screen, &s, .escape);
    try testing.expectEqual(platform.Key.x, s.layout.keys[1][@backingInt(input.Button.a)]);
    try testing.expectEqual(Result.save_and_exit, press(&screen, &s, .escape));
    try testing.expectEqual(platform.Key.x, s.layout.keys[1][@backingInt(input.Button.a)]);
}

test "EXIT WITHOUT SAVING, the settings key and a gamepad's B give back what the screen opened with" {
    var s: Settings = .{};
    s.sound.volume = 70;
    const opened = s;
    var screen: Screen = .open(&s, .{});
    // Up from the first row: the last, EXIT WITHOUT SAVING; up to the volume, changed.
    _ = press(&screen, &s, .up);
    try testing.expectEqual(Row.exit_without_saving, screen.row);
    for (0..6) |_| _ = press(&screen, &s, .up);
    try testing.expectEqual(Row.volume, screen.row);
    _ = press(&screen, &s, .right);
    try testing.expectEqual(@as(u8, 80), s.sound.volume);
    try testing.expectEqual(Result.stay, press(&screen, &s, .f2));
    try testing.expectEqual(Result.exit_without_saving, press(&screen, &s, .f1));
    try testing.expectEqual(opened, s);
    // Without the settings key (outside the original), F1 is a key like the others.
    screen = .open(&s, .{ .settings_key = false });
    try testing.expectEqual(Result.stay, press(&screen, &s, .f1));

    screen = .open(&s, .{});
    _ = pressButton(&screen, &s, .dpad_up);
    _ = pressButton(&screen, &s, .dpad_up);
    try testing.expectEqual(Row.save_and_exit, screen.row);
    _ = pressButton(&screen, &s, .dpad_up);
    _ = pressButton(&screen, &s, .a);
    try testing.expectEqual(Settings{}, s);
    try testing.expectEqual(Result.exit_without_saving, pressButton(&screen, &s, .b));
    try testing.expectEqual(opened, s);

    // SAVE AND EXIT keeps them.
    screen = .open(&s, .{});
    _ = press(&screen, &s, .up);
    _ = press(&screen, &s, .up);
    try testing.expectEqual(Result.save_and_exit, press(&screen, &s, .enter));
}

test "one player: its keys alone, no FIRST GAMEPAD; without the settings key, no row of it" {
    var s: Settings = .{};
    var screen: Screen = .open(&s, .{ .one_player = true, .settings_key = false });
    // The rows: the eight keys, the volume, the sound...
    for (0..9) |_| _ = press(&screen, &s, .down);
    try testing.expectEqual(Row.sound, screen.row);
    try testing.expectEqual(@as(u16, 6 + 9 + 1), screen.screenRow(.sound));
    // A: pad 1's key, then the gamepads' button (no pad 2 column).
    screen.row = .a;
    _ = press(&screen, &s, .right);
    try testing.expectEqual(@as(u2, 2), screen.column);
    _ = press(&screen, &s, .enter);
    _ = pressButton(&screen, &s, .y);
    try testing.expectEqual(platform.ControllerButton.y, s.layout.buttons[0]);
    _ = press(&screen, &s, .left);
    try testing.expectEqual(@as(u2, 0), screen.column);
}

test "the screen draws on a panel: the title, the rows, the arrow" {
    var p: Panel = undefined;
    try p.init(testing.allocator, &panel_mod.Fixture.font, &panel_mod.Fixture.sheet, &panel_mod.Fixture.colours);
    defer p.deinit();
    var s: Settings = .{};
    const screen: Screen = .open(&s, .{});
    p.begin();
    try screen.draw(&s, &p, true);
    const rgba = try p.finish(null, false);
    // Row A's label (the fixture's font has no other letter), dim, at column 3 of row 10...
    try testing.expectEqualSlices(u8, &.{ 49, 49, 49 }, rgba[(10 * 8 * panel_mod.width + 3 * 8) * 4 ..][0..3]);
    // ...and the arrow is left of the first row's first key.
    try testing.expect(p.screen.sprites.len == 1 and p.screen.sprites[0].x == 9 * 8 and p.screen.sprites[0].y == 6 * 8);
}

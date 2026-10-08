//! The settings screen (DESIGN.md 7, 10.4 S3): the player changes this machine's settings record
//! in the game, on a scene over the game's picture that holds the game while it is open
//! (game.zig: the overlays). It is reached from OPTIONS' ADVANCED SETTINGS and from START during
//! play (the extended and network variants, variant.zig), and in the original with the settings
//! key (F1 by default), in any scene.
//!
//! Two pages, in the cartridge's options' style (the chosen row bright, the others dim, the menu's
//! arrow at the choice). The first: INPUT CONFIGURATION..., the sound and its volume, the window's
//! scale and full screen; the game's rules where the settings give them (the lives, the
//! continues, the friendly hits: setup.zig `Rules`); the defaults; and the two ways out, SAVE AND
//! EXIT and EXIT WITHOUT SAVING. INPUT CONFIGURATION has a column for each player of this machine
//! (one with network play or a browser): its input method (the keyboard, or a gamepad connected:
//! a gamepad one player takes goes from the other, who goes back to the keyboard), its keys, or
//! its gamepad's A, B, C and START (its model's: the directions are the gamepad's d-pad and stick),
//! and its autofire; the settings key where the variant has it; GAMEPAD LIST...; and EXIT, back to
//! the first page. GAMEPAD LIST shows every gamepad the machine knows (input.zig), by its label,
//! with its name, the connected ones bright, the others dim, scrolling past the screen's rows; an
//! unconnected one is forgotten with DEL, or with A, B or C and a yes (A, B or C again; START:
//! no).
//!
//! The pads' keys work it as they work the options: the directions move (left and right between
//! the players' columns, or change a value), A, B or C acts (a key or a button: the next one
//! pressed is the new one; one that another setting has is swapped with it, so that no key does
//! two things), and START leaves the page: INPUT CONFIGURATION for the first page, the first page
//! saving, as SAVE AND EXIT does; so do the gamepads' d-pad and buttons. Escape does what START
//! does, and the arrows move, whatever the pads' keys are, so the screen is always usable. EXIT
//! WITHOUT SAVING, the settings key (where the variant has it) and a gamepad's BACK leave without
//! saving, giving back the settings the screen opened with. The changes apply at once (the input
//! when the screen closes).
//!
//! The screen turns its page once the game has faded it out (`pending`, `turnPage`: game.zig fades
//! the panel out, then in on the next page), and takes no event until then.
const std = @import("std");
const platform = @import("../platform.zig");
const input = @import("../input.zig");
const record = @import("record.zig");
const panel_mod = @import("../panel.zig");

const Settings = record.Settings;
const Panel = panel_mod.Panel;

pub const Page = enum(u8) { main, input, gamepads };

/// The first page's rows.
pub const Row = enum(u8) {
    input_configuration,
    sound,
    volume,
    scale,
    fullscreen,
    lives,
    continues,
    friendly_hit,
    defaults,
    save_and_exit,
    exit_without_saving,

    fn rule(row: Row) bool {
        return row == .lives or row == .continues or row == .friendly_hit;
    }
};

/// INPUT CONFIGURATION's rows: the input method, a row for each pad button, autofire, the
/// settings key, EXIT.
pub const InputRow = enum(u8) {
    method,
    up,
    down,
    left,
    right,
    a,
    b,
    c,
    start,
    autofire,
    settings_key,
    gamepad_list,
    exit,

    /// The pad button of a button row.
    fn button(row: InputRow) ?input.Button {
        const i = @backingInt(row);
        return if (i >= 1 and i <= 8) @fromBackingInt(@as(u3, @intCast(i - 1))) else null;
    }

    /// The index in `input.face_buttons` of a row whose button a gamepad's button presses.
    fn face(row: InputRow) ?usize {
        const b = row.button() orelse return null;
        return std.mem.indexOfScalar(input.Button, &input.face_buttons, b);
    }

    /// A row of the players' columns.
    fn perPlayer(row: InputRow) bool {
        return row != .settings_key and row != .gamepad_list and row != .exit;
    }
};

/// The volume's step.
const volume_step = 10;

/// What the screen shows on this machine.
pub const Facts = struct {
    /// The players of this machine: their columns in INPUT CONFIGURATION.
    players: u3 = 2,
    /// The settings key opens the settings (the original): its row, and it leaves them.
    settings_key: bool = true,
    /// The game's rules are the settings' here (variant.zig): their rows.
    rules: bool = false,
    /// The labels of the gamepads connected, the lowest first (input.zig `Controls.connected`):
    /// the input methods a player may take.
    gamepads: [input.Controls.max_controllers]?u16 = @splat(null),

    pub fn connected(self: *const Facts, label: u16) bool {
        return std.mem.indexOfScalar(?u16, &self.gamepads, label) != null;
    }
};

/// What an event did: the screen stays open, or it closed, its settings to be written, or given
/// back as they were when it opened.
pub const Result = enum { stay, save_and_exit, exit_without_saving };

pub const Screen = struct {
    facts: Facts = .{},
    page: Page = .main,
    /// The page it turns to once faded out; it takes no events until then.
    pending: ?Page = null,
    row: Row = .input_configuration,
    input_row: InputRow = .method,
    /// INPUT CONFIGURATION's player column.
    column: u2 = 0,
    /// Waiting for the new key (or gamepad button) of the chosen setting.
    waiting: bool = false,
    /// GAMEPAD LIST's cursor (an index in the labels' order, EXIT past them), the first row
    /// shown, and the question whether to forget the chosen gamepad.
    list_cursor: usize = 0,
    list_top: usize = 0,
    confirming: bool = false,
    /// The settings when the screen opened, which leaving it without saving gives back.
    before: Settings = .{},

    pub fn open(settings: *const Settings, facts: Facts) Screen {
        return .{ .facts = facts, .before = settings.* };
    }

    /// Whether the first page has the row here.
    fn shows(self: *const Screen, row: Row) bool {
        return !row.rule() or self.facts.rules;
    }

    fn showsInput(self: *const Screen, row: InputRow) bool {
        return row != .settings_key or self.facts.settings_key;
    }

    /// Takes one event; `settings` change as the player chooses. When it closes without saving,
    /// they are already given back.
    pub fn handle(self: *Screen, settings: *Settings, e: platform.Event) Result {
        if (self.pending != null) return .stay;
        switch (e.payload) {
            .key_down => |k| {
                if (self.waiting) {
                    self.takeKey(settings, k);
                    return .stay;
                }
                if (self.page == .gamepads and k.key == .delete and !k.repeat) {
                    self.forgetChosen(settings);
                    return .stay;
                }
                const nav: Nav = if (self.padButton(settings, k.key)) |b| navOf(b) else switch (k.key) {
                    .up => .up,
                    .down => .down,
                    .left => .left,
                    .right => .right,
                    .escape => .back,
                    else => if (self.facts.settings_key and k.key == settings.settings_key) .leave else return .stay,
                };
                if (k.repeat and (nav == .choose or nav == .back or nav == .leave)) return .stay;
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
                    .back => .leave,
                    else => navOf(self.faceOf(settings, b.button) orelse return .stay),
                };
                return self.navigate(settings, nav);
            },
            else => return .stay,
        }
    }

    /// `back` leaves the page (START, Escape), the first saving; `leave` leaves without saving.
    const Nav = enum { up, down, left, right, choose, back, leave };

    /// What a pad's button does here.
    fn navOf(b: input.Button) Nav {
        return switch (b) {
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
            .a, .b, .c => .choose,
            .start => .back,
        };
    }

    /// The pad button that `key` presses for a player of this machine.
    fn padButton(self: *const Screen, settings: *const Settings, key: platform.Key) ?input.Button {
        const place = settings.layout.find(key) orelse return null;
        return if (place.player < self.facts.players) place.button else null;
    }

    /// The pad button a gamepad's button presses for a player of this machine (its gamepad's
    /// model's), or by the first buttons.
    fn faceOf(self: *const Screen, settings: *const Settings, b: platform.ControllerButton) ?input.Button {
        for (settings.layout.players[0..self.facts.players]) |p| {
            const pad = settings.layout.pad(p.gamepad orelse continue) orelse continue;
            if (std.mem.indexOfScalar(platform.ControllerButton, &pad.buttons, b)) |i| return input.face_buttons[i];
        }
        if (std.mem.indexOfScalar(platform.ControllerButton, &input.default_buttons, b)) |i| return input.face_buttons[i];
        return null;
    }

    fn navigate(self: *Screen, settings: *Settings, nav: Nav) Result {
        if (nav == .leave) return self.leave(settings);
        return switch (self.page) {
            .main => self.navigateMain(settings, nav),
            .input => self.navigateInput(settings, nav),
            .gamepads => self.navigateList(settings, nav),
        };
    }

    fn navigateMain(self: *Screen, settings: *Settings, nav: Nav) Result {
        switch (nav) {
            .up, .down => self.row = step(Row, self.row, nav == .down, self, shows),
            .left, .right => change(self.row, settings, nav == .right),
            .choose => switch (self.row) {
                .input_configuration => {
                    self.pending = .input;
                    self.input_row = .method;
                    self.column = 0;
                },
                .volume => {},
                .scale => settings.window.scale = if (settings.window.scale >= record.max_scale) 1 else settings.window.scale + 1,
                .lives => settings.rules.lives = if (settings.rules.lives >= record.max_lives) 1 else settings.rules.lives + 1,
                .continues => settings.rules.continues = if (settings.rules.continues >= record.max_continues) 0 else settings.rules.continues + 1,
                .defaults => settings.defaults(),
                .save_and_exit => return .save_and_exit,
                .exit_without_saving => return self.leave(settings),
                else => change(self.row, settings, true),
            },
            .back => return .save_and_exit,
            .leave => unreachable,
        }
        return .stay;
    }

    fn navigateInput(self: *Screen, settings: *Settings, nav: Nav) Result {
        const p = &settings.layout.players[self.column];
        switch (nav) {
            .up, .down => self.input_row = step(InputRow, self.input_row, nav == .down, self, showsInput),
            .left => if (self.input_row.perPlayer() and self.column > 0) {
                self.column -= 1;
            },
            .right => if (self.input_row.perPlayer() and @as(usize, self.column) + 1 < self.facts.players) {
                self.column += 1;
            },
            .choose => switch (self.input_row) {
                .method => settings.layout.assign(self.column, self.nextMethod(p.gamepad)),
                .autofire => p.autofire = !p.autofire,
                .settings_key => self.waiting = true,
                .gamepad_list => {
                    self.pending = .gamepads;
                    self.list_cursor = 0;
                    self.list_top = 0;
                    self.confirming = false;
                },
                .exit => self.pending = .main,
                else => if (p.gamepad == null or self.input_row.face() != null) {
                    self.waiting = true;
                },
            },
            .back => self.pending = .main,
            .leave => unreachable,
        }
        return .stay;
    }

    /// GAMEPAD LIST: up and down move (EXIT past the gamepads), A, B or C on an unconnected one
    /// asks whether to forget it (A, B or C again: yes; START: no), on EXIT goes back, as START
    /// does.
    fn navigateList(self: *Screen, settings: *Settings, nav: Nav) Result {
        var buf: [input.max_known]u16 = undefined;
        const labels = settings.layout.labels(&buf);
        if (self.confirming) {
            if (nav == .choose) self.forgetChosen(settings);
            if (nav == .choose or nav == .back) self.confirming = false;
            return .stay;
        }
        switch (nav) {
            .up => self.list_cursor = if (self.list_cursor == 0) labels.len else self.list_cursor - 1,
            .down => self.list_cursor = if (self.list_cursor >= labels.len) 0 else self.list_cursor + 1,
            .left, .right => {},
            .choose => if (self.list_cursor >= labels.len) {
                self.pending = .input;
            } else if (!self.facts.connected(labels[self.list_cursor])) {
                self.confirming = true;
            },
            .back => self.pending = .input,
            .leave => unreachable,
        }
        self.scroll(labels.len);
        return .stay;
    }

    /// Forgets the chosen gamepad, when it is not connected.
    fn forgetChosen(self: *Screen, settings: *Settings) void {
        var buf: [input.max_known]u16 = undefined;
        const labels = settings.layout.labels(&buf);
        if (self.list_cursor >= labels.len or self.facts.connected(labels[self.list_cursor])) return;
        settings.layout.forget(labels[self.list_cursor]);
        self.confirming = false;
        self.scroll(labels.len - 1);
    }

    /// The rows of gamepads GAMEPAD LIST shows at once.
    const list_rows = 16;

    /// Keeps the cursor (within the `count` gamepads and EXIT) among the rows shown.
    fn scroll(self: *Screen, count: usize) void {
        self.list_cursor = @min(self.list_cursor, count);
        if (self.list_cursor >= count) return;
        if (self.list_cursor < self.list_top) self.list_top = self.list_cursor;
        if (self.list_cursor >= self.list_top + list_rows) self.list_top = self.list_cursor + 1 - list_rows;
        self.list_top = @min(self.list_top, count -| list_rows);
    }

    /// Turns to the page it waits to turn to, if any.
    pub fn turnPage(self: *Screen) void {
        const p = self.pending orelse return;
        self.page = p;
        self.pending = null;
    }

    /// The input method after `now`: the keyboard, then each gamepad connected, in their labels'
    /// order.
    fn nextMethod(self: *const Screen, now: ?u16) ?u16 {
        for (self.facts.gamepads) |g| if (g) |l| {
            if (now == null or l > now.?) return l;
        };
        return null;
    }

    /// The row after `row`, down or up, round the ends, that the page has here.
    fn step(comptime R: type, row: R, down: bool, self: *const Screen, comptime has: fn (*const Screen, R) bool) R {
        const count = std.enums.values(R).len;
        var next: usize = @backingInt(row);
        while (true) {
            next = if (down) (next + 1) % count else (next + count - 1) % count;
            const r: R = @fromBackingInt(@as(u8, @intCast(next)));
            if (has(self, r)) return r;
        }
    }

    fn leave(self: *Screen, settings: *Settings) Result {
        settings.* = self.before;
        self.waiting = false;
        return .exit_without_saving;
    }

    /// Left and right on a value; A, B or C on a choice of two.
    fn change(row: Row, settings: *Settings, up: bool) void {
        switch (row) {
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
            .lives => settings.rules.lives = if (up) @min(settings.rules.lives + 1, record.max_lives) else @max(settings.rules.lives - 1, 1),
            .continues => settings.rules.continues = if (up) @min(settings.rules.continues + 1, record.max_continues) else settings.rules.continues -| 1,
            .friendly_hit => settings.rules.friendly_hit = !settings.rules.friendly_hit,
            else => {},
        }
    }

    /// The key setting waited for.
    fn keySlot(self: *const Screen) Settings.KeySlot {
        if (self.input_row == .settings_key) return .settings;
        return .{ .player = .{ .player = self.column, .button = self.input_row.button().? } };
    }

    /// Whether the setting waited for is a gamepad's button (else a key).
    fn waitsForButton(self: *const Screen, settings: *const Settings) bool {
        return self.input_row.perPlayer() and settings.layout.players[self.column].gamepad != null;
    }

    /// The key pressed while waiting: Escape keeps the old one; a key no setting can take is
    /// ignored. A key pressed while waiting for a gamepad's button keeps the old button.
    fn takeKey(self: *Screen, settings: *Settings, k: platform.Event.KeyEvent) void {
        if (k.repeat) return;
        if (self.waitsForButton(settings)) {
            self.waiting = false;
            return;
        }
        if (k.key == .escape or settings.bindKey(self.keySlot(), k.key)) self.waiting = false;
    }

    /// The gamepad's button pressed while waiting: the player's new button for A, B, C or START.
    /// While waiting for a key, a button keeps the old key.
    fn takeButton(self: *Screen, settings: *Settings, b: platform.ControllerButton) void {
        if (!self.waitsForButton(settings)) {
            self.waiting = false;
            return;
        }
        const which = settings.layout.players[self.column].gamepad.?;
        if (settings.bindButton(which, self.input_row.face().?, b)) self.waiting = false;
    }

    // --- the picture ---------------------------------------------------------------------------

    /// Where the screen's parts are, in cells: the box, the title, the rows, the players' columns
    /// and their headers, and the prompt at the bottom.
    const box_col = 1;
    const box_row = 1;
    const title_row = 2;
    const first_row = 5;
    const label_col = 3;
    const button_col = 5;
    const value_col = 24;
    const player_cols = [2]u16{ 18, 29 };
    const header_row = 4;
    const method_row = 6;
    const configuration_row = 8;
    const prompt_row = panel_mod.rows - 3;

    /// The first page's screen row of `row`: a blank row after INPUT CONFIGURATION..., before the
    /// rules and before DEFAULTS.
    fn screenRow(self: *const Screen, row: Row) u16 {
        var n: u16 = 0;
        for (std.enums.values(Row)[0..@backingInt(row)]) |r| n += @intFromBool(self.shows(r));
        if (row != .input_configuration) n += 1;
        if (@backingInt(row) >= @backingInt(Row.lives)) n += 1;
        if (@backingInt(row) >= @backingInt(Row.defaults) and self.facts.rules) n += 1;
        return first_row + n;
    }

    /// INPUT CONFIGURATION's screen row of `row`: the input method, CONFIGURATION's title and its
    /// buttons, then a blank row before AUTOFIRE and before EXIT.
    fn inputScreenRow(self: *const Screen, row: InputRow) u16 {
        return switch (row) {
            .method => method_row,
            .autofire => configuration_row + 10,
            .settings_key => configuration_row + 11,
            .gamepad_list => configuration_row + 12 + @as(u16, @intFromBool(self.facts.settings_key)),
            .exit => configuration_row + 13 + @as(u16, @intFromBool(self.facts.settings_key)),
            else => configuration_row + @backingInt(row),
        };
    }

    /// Draws the screen on `p` (its picture begun): a black box over the game's picture, which
    /// the panel dims. `arrow`: the arrow shows (it blinks while the screen waits for a key).
    pub fn draw(self: *const Screen, settings: *const Settings, p: *Panel, arrow: bool) Panel.Error!void {
        try p.box(box_col, box_row, panel_mod.columns - 2 * box_col, panel_mod.rows - 2 * box_row);
        switch (self.page) {
            .main => try self.drawMain(settings, p, arrow),
            .input => try self.drawInput(settings, p, arrow),
            .gamepads => try self.drawList(settings, p, arrow),
        }
    }

    /// GAMEPAD LIST: each gamepad's label and name on a row (cut to the box), bright when it is
    /// connected, from the first row shown; EXIT under them; the bottom line says what A, B or C
    /// or DEL would do.
    fn drawList(self: *const Screen, settings: *const Settings, p: *Panel, arrow: bool) Panel.Error!void {
        try p.text(label_col, title_row, "GAMEPAD LIST", .bright);
        var buf: [input.max_known]u16 = undefined;
        const labels = settings.layout.labels(&buf);
        if (labels.len == 0) try p.text(label_col, first_row, "NO GAMEPAD YET.", .dim);
        const shown = labels[@min(self.list_top, labels.len)..][0..@min(labels.len -| self.list_top, list_rows)];
        for (shown, 0..) |l, i| {
            var line: [panel_mod.columns]u8 = undefined;
            const pad = settings.layout.pad(l).?;
            const text = std.fmt.bufPrint(&line, "GAMEPAD {d} {s}", .{ l, pad.name.slice() }) catch line[0..];
            const width = panel_mod.columns - label_col - box_col - 1;
            try p.text(label_col, first_row + i, text[0..@min(text.len, width)], if (self.facts.connected(l)) .bright else .dim);
        }
        const exit_row = first_row + list_rows + 1;
        try p.text(label_col, exit_row, "EXIT", if (self.list_cursor >= labels.len) .bright else .dim);
        if (arrow) p.arrowAt(label_col - 1, if (self.list_cursor >= labels.len) exit_row else @intCast(first_row + self.list_cursor - self.list_top));
        const prompt_text: []const u8 = if (self.confirming)
            "FORGET IT? A, B, C: YES. START: NO."
        else if (self.list_cursor < labels.len and !self.facts.connected(labels[self.list_cursor]))
            "DEL, OR A, B, C: FORGET IT."
        else
            "";
        try p.text(label_col, prompt_row, prompt_text, .dim);
    }

    fn drawMain(self: *const Screen, settings: *const Settings, p: *Panel, arrow: bool) Panel.Error!void {
        try p.text(label_col, title_row, "SETTINGS", .bright);
        var buf: [16]u8 = undefined;
        for (std.enums.values(Row)) |row| {
            if (!self.shows(row)) continue;
            const tone: panel_mod.Tone = if (row == self.row) .bright else .dim;
            const y = self.screenRow(row);
            try p.text(label_col, y, label(row), tone);
            if (value(row, settings, &buf)) |v| try p.text(value_col, y, v, tone);
        }
        if (arrow) {
            const x: i32 = if (value(self.row, settings, &buf) != null) value_col - 1 else label_col - 1;
            p.arrowAt(x, self.screenRow(self.row));
        }
    }

    fn drawInput(self: *const Screen, settings: *const Settings, p: *Panel, arrow: bool) Panel.Error!void {
        try p.text(label_col, title_row, "INPUT CONFIGURATION", .bright);
        for (0..self.facts.players) |c| {
            var buf: [16]u8 = undefined;
            const header = std.fmt.bufPrint(&buf, "PLAYER {d}", .{c + 1}) catch unreachable;
            try p.text(player_cols[c], header_row, header, .dim);
        }
        try p.text(label_col, configuration_row, "CONFIGURATION", .dim);
        for (std.enums.values(InputRow)) |row| {
            if (!self.showsInput(row)) continue;
            const chosen = row == self.input_row;
            const y = self.inputScreenRow(row);
            try p.text(if (row.button() != null) button_col else label_col, y, inputLabel(row), if (chosen) .bright else .dim);
            if (row == .settings_key) {
                try p.text(player_cols[0], y, if (chosen and self.waiting) "" else keyName(settings.settings_key), if (chosen) .bright else .dim);
                continue;
            }
            if (!row.perPlayer()) continue;
            for (0..self.facts.players) |c| {
                const here = chosen and c == self.column;
                var buf: [16]u8 = undefined;
                const text = if (here and self.waiting) "" else cell(settings, row, c, &buf);
                try p.text(player_cols[c], y, text, if (here) .bright else .dim);
            }
        }
        if (arrow) {
            const y = self.inputScreenRow(self.input_row);
            const x: i32 = if (self.input_row.perPlayer()) player_cols[self.column] - 1 else if (self.input_row == .settings_key) player_cols[0] - 1 else label_col - 1;
            p.arrowAt(x, y);
        }
        var buf: [panel_mod.columns]u8 = undefined;
        try p.text(label_col, prompt_row, self.prompt(settings, &buf), .dim);
    }

    /// Player `c`'s cell of `row`: its input method, its key or its gamepad's button (its model's),
    /// its autofire.
    fn cell(settings: *const Settings, row: InputRow, c: usize, buf: *[16]u8) []const u8 {
        const pi = &settings.layout.players[c];
        return switch (row) {
            .method => methodName(pi.gamepad, buf),
            .autofire => if (pi.autofire) "ON" else "OFF",
            else => if (pi.gamepad) |l| blk: {
                const f = row.face() orelse break :blk "";
                const pad = settings.layout.pad(l) orelse break :blk "";
                break :blk buttonName(pad.buttons[f]);
            } else keyName(pi.keys[@backingInt(row.button().?)]),
        };
    }

    /// The bottom line: what the screen waits for, or that the chosen player's gamepad is away.
    fn prompt(self: *const Screen, settings: *const Settings, buf: []u8) []const u8 {
        if (self.waiting) return if (self.waitsForButton(settings)) "PRESS THE NEW GAMEPAD BUTTON." else "PRESS THE NEW KEY.";
        if (!self.input_row.perPlayer()) return "";
        const g = settings.layout.players[self.column].gamepad orelse return "";
        if (self.facts.connected(g)) return "";
        return std.fmt.bufPrint(buf, "GAMEPAD {d} IS AWAY: THE KEYS PLAY.", .{g}) catch "";
    }

    fn label(row: Row) []const u8 {
        return switch (row) {
            .input_configuration => "INPUT CONFIGURATION...",
            .sound => "SOUND",
            .volume => "VOLUME",
            .scale => "WINDOW SCALE",
            .fullscreen => "FULL SCREEN",
            .lives => "LIVES",
            .continues => "CONTINUES",
            .friendly_hit => "FRIENDLY HIT",
            .defaults => "DEFAULTS",
            .save_and_exit => "SAVE AND EXIT",
            .exit_without_saving => "EXIT WITHOUT SAVING",
        };
    }

    fn inputLabel(row: InputRow) []const u8 {
        return switch (row) {
            .method => "INPUT METHOD",
            .up => "UP",
            .down => "DOWN",
            .left => "LEFT",
            .right => "RIGHT",
            .a => "A",
            .b => "B",
            .c => "C",
            .start => "START",
            .autofire => "AUTOFIRE",
            .settings_key => "SETTINGS KEY",
            .gamepad_list => "GAMEPAD LIST...",
            .exit => "EXIT",
        };
    }

    fn value(row: Row, settings: *const Settings, buf: *[16]u8) ?[]const u8 {
        return switch (row) {
            .sound => if (settings.sound.mute) "OFF" else "ON",
            .volume => std.fmt.bufPrint(buf, "{d}", .{settings.sound.volume}) catch unreachable,
            .scale => std.fmt.bufPrint(buf, "{d}", .{settings.window.scale}) catch unreachable,
            .fullscreen => if (settings.window.fullscreen) "ON" else "OFF",
            .lives => std.fmt.bufPrint(buf, "{d}", .{settings.rules.lives}) catch unreachable,
            .continues => std.fmt.bufPrint(buf, "{d}", .{settings.rules.continues}) catch unreachable,
            .friendly_hit => if (settings.rules.friendly_hit) "ON" else "OFF",
            else => null,
        };
    }
};

/// An input method's name on the screen.
pub fn methodName(g: ?u16, buf: *[16]u8) []const u8 {
    const n = g orelse return "KEYB.";
    return std.fmt.bufPrint(buf, "GAMEPAD {d}", .{n}) catch unreachable;
}

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
        .unknown => "-",
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

/// `press`, the page turned at once (the game turns it once it has faded it out).
fn pressTurning(screen: *Screen, settings: *Settings, k: platform.Key) Result {
    const r = press(screen, settings, k);
    screen.turnPage();
    return r;
}

fn pressButton(screen: *Screen, settings: *Settings, b: platform.ControllerButton) Result {
    const id: platform.ControllerId = @fromBackingInt(1);
    return screen.handle(settings, .{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = id, .button = b } } });
}

test "INPUT CONFIGURATION: a key rebound swaps with the setting that had it; START goes back, then saves" {
    var s: Settings = .{};
    var screen: Screen = .open(&s, .{});
    // INPUT CONFIGURATION (A), then player 2's A (row a, column 1): A, then X, player 1's B.
    // The page turns once faded out: no event until then.
    try testing.expectEqual(Result.stay, press(&screen, &s, .z));
    try testing.expect(screen.page == .main and screen.pending == .input);
    try testing.expectEqual(Result.stay, press(&screen, &s, .down));
    screen.turnPage();
    try testing.expect(screen.page == .input and screen.input_row == .method);
    for ([_]platform.Key{ .down, .down, .down, .down, .down, .right, .z }) |k| try testing.expectEqual(Result.stay, press(&screen, &s, k));
    try testing.expect(screen.waiting and screen.input_row == .a and screen.column == 1);
    // A repeat is not a press.
    _ = screen.handle(&s, .{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x, .repeat = true } } });
    try testing.expect(screen.waiting);
    const pad2_a = s.layout.players[1].keys[@backingInt(input.Button.a)];
    _ = press(&screen, &s, .x);
    try testing.expect(!screen.waiting);
    try testing.expectEqual(platform.Key.x, s.layout.players[1].keys[@backingInt(input.Button.a)]);
    try testing.expectEqual(pad2_a, s.layout.players[0].keys[@backingInt(input.Button.b)]);
    // Escape while waiting keeps the key.
    _ = press(&screen, &s, .c);
    _ = press(&screen, &s, .escape);
    try testing.expectEqual(platform.Key.x, s.layout.players[1].keys[@backingInt(input.Button.a)]);
    // START (Enter, player 1's) goes back to the first page; there, START saves and leaves, as
    // player 2's (Tab) and Escape do.
    try testing.expectEqual(Result.stay, pressTurning(&screen, &s, .enter));
    try testing.expectEqual(Page.main, screen.page);
    try testing.expectEqual(Result.save_and_exit, press(&screen, &s, .enter));
    try testing.expectEqual(Result.save_and_exit, press(&screen, &s, .tab));
    try testing.expectEqual(Result.save_and_exit, press(&screen, &s, .escape));
    // With one player, player 2's keys are not its.
    screen = .open(&s, .{ .players = 1 });
    try testing.expectEqual(Result.stay, press(&screen, &s, .tab));
}

fn knownPads(s: *Settings, models: []const []const u8) void {
    for (models, 0..) |m, i| s.layout.gamepads[i] = .{ .label = @intCast(i + 1), .model = .of(m), .name = .of(m) };
}

test "the input method: the keyboard, then the gamepads connected; a gamepad taken goes from the other" {
    var s: Settings = .{};
    knownPads(&s, &.{ "6B", "6B", "8BitDo" });
    var screen: Screen = .open(&s, .{ .gamepads = .{ 1, 3, null, null } });
    screen.page = .input;
    _ = press(&screen, &s, .z);
    try testing.expectEqual(@as(?u16, 1), s.layout.players[0].gamepad);
    _ = press(&screen, &s, .z);
    try testing.expectEqual(@as(?u16, 3), s.layout.players[0].gamepad);
    _ = press(&screen, &s, .z);
    try testing.expectEqual(@as(?u16, null), s.layout.players[0].gamepad);
    _ = press(&screen, &s, .z);
    // Player 2 takes GAMEPAD 1: player 1 goes back to the keyboard.
    _ = press(&screen, &s, .right);
    _ = press(&screen, &s, .f);
    try testing.expect(s.layout.players[1].gamepad == 1 and s.layout.players[0].gamepad == null);
    // A gamepad player's buttons: A rebinds its gamepad's model's A; its directions are the
    // d-pad's.
    for (0..5) |_| _ = press(&screen, &s, .down);
    try testing.expectEqual(InputRow.a, screen.input_row);
    _ = press(&screen, &s, .z);
    try testing.expect(screen.waiting);
    _ = pressButton(&screen, &s, .y);
    try testing.expectEqual(platform.ControllerButton.y, s.layout.pad(1).?.buttons[0]);
    try testing.expectEqual(platform.ControllerButton.y, s.layout.pad(2).?.buttons[0]);
    try testing.expectEqual(platform.ControllerButton.x, s.layout.pad(3).?.buttons[0]);
    _ = press(&screen, &s, .up);
    _ = press(&screen, &s, .z);
    try testing.expect(!screen.waiting);
    // Autofire, then EXIT back to the first page.
    for (0..5) |_| _ = press(&screen, &s, .down);
    try testing.expectEqual(InputRow.autofire, screen.input_row);
    _ = press(&screen, &s, .z);
    try testing.expect(s.layout.players[1].autofire and !s.layout.players[0].autofire);
    _ = press(&screen, &s, .down);
    try testing.expectEqual(InputRow.settings_key, screen.input_row);
    _ = press(&screen, &s, .down);
    try testing.expectEqual(InputRow.gamepad_list, screen.input_row);
    _ = press(&screen, &s, .down);
    _ = pressTurning(&screen, &s, .z);
    try testing.expectEqual(Page.main, screen.page);
}

test "GAMEPAD LIST: every gamepad known, an unconnected one forgotten (DEL, or A and a yes), scrolling" {
    var s: Settings = .{};
    knownPads(&s, &.{ "a", "b", "c" });
    s.layout.players[1].gamepad = 2;
    var screen: Screen = .open(&s, .{ .gamepads = .{ 1, null, null, null } });
    screen.page = .input;
    screen.input_row = .gamepad_list;
    _ = pressTurning(&screen, &s, .z);
    try testing.expectEqual(Page.gamepads, screen.page);
    // GAMEPAD 1 is connected: A does nothing, nor DEL.
    _ = press(&screen, &s, .z);
    _ = press(&screen, &s, .delete);
    try testing.expect(!screen.confirming and s.layout.pad(1) != null);
    // GAMEPAD 2: A asks, START says no; A asks again, A says yes: player 2 to the keyboard.
    _ = press(&screen, &s, .down);
    _ = press(&screen, &s, .z);
    try testing.expect(screen.confirming);
    _ = press(&screen, &s, .enter);
    try testing.expect(!screen.confirming and s.layout.pad(2) != null);
    _ = press(&screen, &s, .z);
    _ = press(&screen, &s, .x);
    try testing.expect(s.layout.pad(2) == null and s.layout.players[1].gamepad == null);
    // GAMEPAD 3, now second: DEL forgets it at once; the cursor on EXIT.
    _ = press(&screen, &s, .delete);
    try testing.expect(s.layout.pad(3) == null);
    try testing.expectEqual(@as(usize, 1), screen.list_cursor);
    _ = pressTurning(&screen, &s, .z);
    try testing.expectEqual(Page.input, screen.page);

    // Many gamepads: the rows shown follow the cursor.
    s = .{};
    for (0..30) |i| s.layout.gamepads[i] = .{ .label = @intCast(i + 1) };
    screen = .open(&s, .{});
    screen.page = .gamepads;
    for (0..20) |_| _ = press(&screen, &s, .down);
    try testing.expectEqual(@as(usize, 20), screen.list_cursor);
    try testing.expectEqual(@as(usize, 20 + 1 - Screen.list_rows), screen.list_top);
    _ = press(&screen, &s, .up);
    for (0..20) |_| _ = press(&screen, &s, .up);
    try testing.expectEqual(@as(usize, 30), screen.list_cursor);
}

test "EXIT WITHOUT SAVING, the settings key and a gamepad's BACK give back what the screen opened with" {
    var s: Settings = .{};
    s.sound.volume = 70;
    const opened = s;
    var screen: Screen = .open(&s, .{});
    // Up from the first row: the last, EXIT WITHOUT SAVING; up to the volume, changed.
    _ = press(&screen, &s, .up);
    try testing.expectEqual(Row.exit_without_saving, screen.row);
    for (0..5) |_| _ = press(&screen, &s, .up);
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
    // The gamepads' A, B or C button (X, A, B by default) acts: DEFAULTS.
    _ = pressButton(&screen, &s, .a);
    try testing.expectEqual(Settings{}, s);
    try testing.expectEqual(Result.exit_without_saving, pressButton(&screen, &s, .back));
    try testing.expectEqual(opened, s);

    // SAVE AND EXIT keeps them; so does the gamepads' START.
    screen = .open(&s, .{});
    _ = press(&screen, &s, .up);
    _ = press(&screen, &s, .up);
    try testing.expectEqual(Result.save_and_exit, press(&screen, &s, .x));
    screen = .open(&s, .{});
    try testing.expectEqual(Result.save_and_exit, pressButton(&screen, &s, .start));
}

test "the rules' rows where the settings give the rules: lives 1 to 9, continues 0 to 9, friendly hits" {
    var s: Settings = .{};
    var screen: Screen = .open(&s, .{ .settings_key = false });
    for (0..5) |_| _ = press(&screen, &s, .down);
    try testing.expectEqual(Row.defaults, screen.row);
    screen = .open(&s, .{ .rules = true });
    for (0..5) |_| _ = press(&screen, &s, .down);
    try testing.expectEqual(Row.lives, screen.row);
    for (0..9) |_| _ = press(&screen, &s, .right);
    try testing.expectEqual(@as(u8, 9), s.rules.lives);
    _ = press(&screen, &s, .z);
    try testing.expectEqual(@as(u8, 1), s.rules.lives);
    _ = press(&screen, &s, .left);
    try testing.expectEqual(@as(u8, 1), s.rules.lives);
    _ = press(&screen, &s, .down);
    for (0..5) |_| _ = press(&screen, &s, .left);
    try testing.expectEqual(@as(u8, 0), s.rules.continues);
    _ = press(&screen, &s, .down);
    _ = press(&screen, &s, .z);
    try testing.expect(!s.rules.friendly_hit);
    // A blank row after INPUT CONFIGURATION... and before the rules: FRIENDLY HIT on the tenth.
    try testing.expectEqual(@as(u16, Screen.first_row + 9), screen.screenRow(.friendly_hit));
}

test "the screen draws on a panel: the title, the rows, the arrow" {
    var p: Panel = undefined;
    try p.init(testing.allocator, &panel_mod.Fixture.font, &panel_mod.Fixture.sheet, &panel_mod.Fixture.colours);
    defer p.deinit();
    var s: Settings = .{};
    var screen: Screen = .open(&s, .{});
    p.begin();
    try screen.draw(&s, &p, true);
    // The arrow is left of the first row's label.
    try testing.expect(p.screen.sprites.len == 1 and p.screen.sprites[0].x == 2 * 8 and p.screen.sprites[0].y == 5 * 8);
    // INPUT CONFIGURATION: row A's label (the fixture's font has no other letter), dim, at column 5
    // of row 13; the arrow left of player 1's input method.
    screen.page = .input;
    p.begin();
    try screen.draw(&s, &p, true);
    const rgba = try p.finish(null, false, 255);
    try testing.expectEqualSlices(u8, &.{ 49, 49, 49 }, rgba[(13 * 8 * panel_mod.width + 5 * 8) * 4 ..][0..3]);
    try testing.expect(p.screen.sprites[0].x == 17 * 8 and p.screen.sprites[0].y == 6 * 8);
}

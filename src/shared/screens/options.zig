//! The options screen: SOUND TEST, LEVEL, CONTROL, EXIT, and the hidden PLAYERS (the lives) and
//! ROUND NO. (the first round) that the code on pad 2 opens at the game menu. The line the cursor
//! is on is bright, the others dim. Up and down move between the lines ("menu move"; leaving the
//! sound test stops its sound); the line the cursor arrives on is drawn bright at the next tick,
//! which reads no input but START. Left and right change a value (the sound test's change stops
//! the sound); A, B or C on the sound test plays its entry, on EXIT leaves. START leaves from any
//! line (stopping the sound), a tick sooner than EXIT. Leaving fades out to the game menu.
//!
//! The port's VOLUME line (the extended and network variants, on the machine of player 1 when it
//! sounds the game itself: variant.zig) comes between CONTROL's table and EXIT, which moves a row
//! down: its name and its value as the other lines', left and right change it by 10 (0 to 100),
//! and the game's sound follows it (game.zig).
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const art = @import("../content/art.zig");
const records = @import("../content/screens.zig");
const setup_mod = @import("../setup.zig");
const Setup = setup_mod.Setup;
const Colours = @import("colours.zig").Colours;

/// The column where the lines' values are drawn, right of their names.
const value_column = 18;
/// The cells each value takes, padded with blanks so that it covers the one before.
const sound_test_cells = 11;
const level_cells = 7;
const control_cells = 16;
const control_rows = 5;
/// The VOLUME line's value: right-aligned in three cells; its step, and its most.
const volume_cells = 3;
const volume_step = 10;
const volume_most = 100;

pub const Line = enum(u8) {
    sound_test,
    level,
    control,
    lives,
    first_round,
    /// The port's.
    volume,
    exit,

    fn hidden(l: Line) bool {
        return l == .lives or l == .first_round;
    }
};

/// The values the screen shows.
pub const Values = struct {
    sound_test: u8 = 0,
    level: u8 = 0,
    control: u8 = 0,
    lives: u8 = 0,
    first_round: u8 = 0,
    /// Null without the VOLUME line.
    volume: ?u8 = null,

    fn of(s: *const Setup) Values {
        return .{ .sound_test = s.sound_test, .level = s.level, .control = s.control, .lives = s.lives, .first_round = s.first_round, .volume = s.volume };
    }

    fn store(v: Values, s: *Setup) void {
        s.sound_test = v.sound_test;
        s.level = v.level;
        s.control = v.control;
        s.lives = v.lives;
        s.first_round = v.first_round;
        s.volume = v.volume;
    }
};

pub const Options = struct {
    ticks: u16 = 0,
    phase: Phase = .setup,
    colours: Colours = .{},
    line: Line = .sound_test,
    /// The line drawn bright; none between a move and the tick it arrives.
    bright: ?Line = .sound_test,
    /// The cursor arrived at the last tick: the line is drawn bright at this one.
    arriving: bool = false,
    hidden_lines: bool = false,
    values: Values = .{},

    pub const Phase = enum(u8) { setup, aim, fade_in, first_line, lines, leave, fade_out, leaving };

    pub const Assets = struct {
        title: *const art.TileMap,
        sound_test: *const art.TileMap,
        sound_test_dim: *const art.TileMap,
        level: *const art.TileMap,
        level_dim: *const art.TileMap,
        control: *const art.TileMap,
        control_dim: *const art.TileMap,
        lives: *const art.TileMap,
        lives_dim: *const art.TileMap,
        first_round: *const art.TileMap,
        first_round_dim: *const art.TileMap,
        exit: *const art.TileMap,
        exit_dim: *const art.TileMap,
        colours: *const art.Palette,
        text: library.Text,
        data: *const records.Options,
        sound_test_sounds: library.SoundTest,
        move: library.Sound,
        stop: library.Sound,
        // The content's `*_chosen` maps are the dim lines (palette 1), shown when the cursor is
        // not on them.
        pub const names = .{
            .title = "options/title",
            .sound_test = "options/sound_test",
            .sound_test_dim = "options/sound_test_chosen",
            .level = "options/level",
            .level_dim = "options/level_chosen",
            .control = "options/control",
            .control_dim = "options/control_chosen",
            .lives = "options/players",
            .lives_dim = "options/players_chosen",
            .first_round = "options/round",
            .first_round_dim = "options/round_chosen",
            .exit = "options/exit",
            .exit_dim = "options/exit_chosen",
            .colours = "menu/one_pad",
            .text = "fonts/main",
            .data = "screens/options",
            .sound_test_sounds = "screens/options",
            .move = "menu move",
            .stop = "stop",
        };

        /// The cartridge's art of a line's name (the port's VOLUME is written in the font).
        fn name(a: *const Assets, l: Line, bright: bool) *const art.TileMap {
            return switch (l) {
                .volume => unreachable,
                .sound_test => if (bright) a.sound_test else a.sound_test_dim,
                .level => if (bright) a.level else a.level_dim,
                .control => if (bright) a.control else a.control_dim,
                .lives => if (bright) a.lives else a.lives_dim,
                .first_round => if (bright) a.first_round else a.first_round_dim,
                .exit => if (bright) a.exit else a.exit_dim,
            };
        }
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn start(_: *const Setup) Options {
        return .{};
    }

    pub fn tick(self: *Options, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        self.colours.latch();
        defer turn.frame = .{ .colours = self.colours.copy, .first_line = true };
        const reads_start = self.phase == .first_line or self.phase == .lines;
        if (reads_start and turn.pressed.pad1.start) {
            // START leaves from any line, its fade at once.
            turn.play(a.stop);
            self.colours.startFade(.black);
            self.phase = .fade_out;
            return null;
        }
        switch (self.phase) {
            .setup => {
                self.values = .of(turn.setup);
                self.hidden_lines = turn.setup.hidden_lines;
                self.phase = .aim;
            },
            .aim => {
                self.colours.aim(a.colours);
                self.colours.startFade(.target);
                self.phase = .fade_in;
            },
            .fade_in => if (self.colours.stepFade()) {
                self.phase = .first_line;
            },
            .first_line => {
                self.bright = .sound_test;
                self.phase = .lines;
            },
            .lines => if (self.arriving) {
                self.bright = self.line;
                self.arriving = false;
            } else self.lineInput(turn, a),
            .leave => {
                self.colours.startFade(.black);
                self.phase = .fade_out;
            },
            .fade_out => if (self.colours.stepFade()) {
                self.phase = .leaving;
            },
            .leaving => return .done,
        }
        return null;
    }

    /// The line's input: a move, or its own.
    fn lineInput(self: *Options, turn: *scene.Turn, a: *const Assets) void {
        const p = turn.pressed.pad1;
        if (p.up or p.down) {
            turn.play(a.move);
            if (self.line == .sound_test) turn.play(a.stop);
            self.line = self.next(p.down);
            self.bright = null;
            self.arriving = true;
            return;
        }
        const step: ?bool = if (p.right) true else if (p.left) false else null;
        const v = &self.values;
        switch (self.line) {
            .sound_test => if (step) |up| {
                turn.play(a.stop);
                v.sound_test = wrap(v.sound_test, @intCast(a.data.sound_test.len), up);
            } else if (p.a or p.b or p.c) {
                turn.play(a.sound_test_sounds.ids[v.sound_test]);
            },
            .level => if (step) |up| {
                v.level = wrap(v.level, @intCast(a.data.levels.len), up);
            },
            .control => if (step) |up| {
                v.control = wrap(v.control, @intCast(a.data.controls.len), up);
            },
            .lives => if (step) |up| {
                v.lives = wrap(v.lives, 4, up);
            },
            .first_round => if (step) |up| {
                v.first_round = wrap(v.first_round, 8, up);
            },
            .volume => if (step) |up| {
                const was = v.volume.?;
                v.volume = if (up) @min(volume_most, was + volume_step) else was -| volume_step;
            },
            .exit => if (p.a or p.b or p.c) {
                self.phase = .leave;
            },
        }
        v.store(turn.setup);
    }

    /// The line after the cursor's, down or up, round the ends; the hidden lines, when they are
    /// open, come before EXIT though they are below it on the screen (quirk O2), and the VOLUME
    /// line, when there is one, right before EXIT.
    fn next(self: *const Options, down: bool) Line {
        const order = [_]Line{ .sound_test, .level, .control, .lives, .first_round, .volume, .exit };
        var i = std.mem.indexOfScalar(Line, &order, self.line).?;
        while (true) {
            i = if (down) (i + 1) % order.len else (i + order.len - 1) % order.len;
            if (self.has(order[i])) return order[i];
        }
    }

    /// Whether the screen has the line now.
    fn has(self: *const Options, l: Line) bool {
        if (l == .volume) return self.values.volume != null;
        return self.hidden_lines or !l.hidden();
    }

    fn wrap(v: u8, count: u8, up: bool) u8 {
        return if (up) (if (v + 1 >= count) 0 else v + 1) else (if (v == 0) count - 1 else v - 1);
    }

    pub fn draw(self: *const Options, prev: ?*const Options, v: *view.View, a: *const Assets) !void {
        if (prev == null) try v.board(.a).drawMapAtPlace(a.title);
        for (std.enums.values(Line)) |l| {
            if (!self.has(l)) continue;
            if (prev) |p| if (p.bright == self.bright and std.meta.eql(p.values, self.values)) continue;
            try self.drawLine(l, v, a);
        }
        v.screen.colours = self.colours.shown;
    }

    /// A line: its name and its value, bright or dim.
    fn drawLine(self: *const Options, l: Line, v: *view.View, a: *const Assets) !void {
        const bright = self.bright == l;
        const look: render.Look = .{ .palette = if (bright) 0 else 1 };
        if (l == .volume) return self.drawVolume(v, a, look);
        const name = a.name(l, bright);
        const at = name.place orelse return;
        // With the VOLUME line, EXIT a row lower.
        const below: i32 = if (l == .exit and self.values.volume != null) 1 else 0;
        try v.board(.a).drawMap(name, at.x, at.y + below);
        const row: i32 = at.y;
        const d = a.data;
        var buf: [control_cells]u8 = undefined;
        switch (l) {
            .sound_test => try v.write(.a, a.text, value_column, row, pad(&buf, d.sound_test[self.values.sound_test].name, sound_test_cells), look),
            .level => try v.write(.a, a.text, value_column, row, pad(&buf, d.levels[self.values.level], level_cells), look),
            .control => {
                const lines = d.controls[self.values.control];
                for (0..control_rows) |i| {
                    const text = if (i < lines.len) lines[i] else "";
                    try v.write(.a, a.text, value_column, row + @as(i32, @intCast(i)), pad(&buf, text, control_cells), look);
                }
            },
            .lives => try v.write(.a, a.text, value_column, row, &[_]u8{'1' + 2 * self.values.lives}, look),
            .first_round => try v.write(.a, a.text, value_column, row, &[_]u8{'1' + self.values.first_round}, look),
            .volume, .exit => {},
        }
    }

    /// The VOLUME line, on the row above EXIT's place (EXIT then a row lower): its name in the
    /// column of the others', its value right-aligned in the values' column.
    fn drawVolume(self: *const Options, v: *view.View, a: *const Assets, look: render.Look) !void {
        const at = a.exit.place orelse return;
        const row: i32 = at.y - 1;
        try v.write(.a, a.text, at.x, row, "VOLUME", look);
        var digits: [volume_cells]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "{d: >3}", .{self.values.volume.?}) catch unreachable;
        try v.write(.a, a.text, value_column, row, text, look);
    }

    /// `text` padded with blanks to `cells`, in `buf`.
    fn pad(buf: []u8, text: []const u8, cells: usize) []const u8 {
        const n = @min(text.len, cells);
        @memcpy(buf[0..n], text[0..n]);
        @memset(buf[n..cells], ' ');
        return buf[0..cells];
    }
};

test "the cursor's order: the hidden lines before EXIT when open, round the ends" {
    var o: Options = .{};
    o.line = .control;
    try std.testing.expectEqual(Line.exit, o.next(true));
    o.hidden_lines = true;
    try std.testing.expectEqual(Line.lives, o.next(true));
    o.line = .exit;
    try std.testing.expectEqual(Line.first_round, o.next(false));
    try std.testing.expectEqual(Line.sound_test, o.next(true));
    o.line = .sound_test;
    try std.testing.expectEqual(Line.exit, o.next(false));
    try std.testing.expectEqual(@as(u8, 72), Options.wrap(0, 73, false));
    try std.testing.expectEqual(@as(u8, 0), Options.wrap(72, 73, true));
}

test "the VOLUME line: right before EXIT when there is one, by tens from 0 to 100" {
    var o: Options = .{ .values = .{ .volume = 90 } };
    o.line = .control;
    try std.testing.expectEqual(Line.volume, o.next(true));
    o.hidden_lines = true;
    o.line = .first_round;
    try std.testing.expectEqual(Line.volume, o.next(true));
    o.line = .exit;
    try std.testing.expectEqual(Line.volume, o.next(false));
    o.line = .volume;
    try std.testing.expectEqual(Line.first_round, o.next(false));
    try std.testing.expectEqual(Line.exit, o.next(true));

    // Right twice: 100 at most; left: by ten; the setup keeps it.
    var setup: Setup = .{ .volume = 90 };
    var turn: scene.Turn = .{ .setup = &setup, .pressed = .{ .pad1 = .{ .right = true } } };
    const a: Options.Assets = undefined;
    o.lineInput(&turn, &a);
    o.lineInput(&turn, &a);
    try std.testing.expectEqual(@as(?u8, 100), setup.volume);
    turn.pressed = .{ .pad1 = .{ .left = true } };
    o.lineInput(&turn, &a);
    try std.testing.expectEqual(@as(?u8, 90), setup.volume);
    o.values.volume = 5;
    o.lineInput(&turn, &a);
    try std.testing.expectEqual(@as(?u8, 0), setup.volume);
}

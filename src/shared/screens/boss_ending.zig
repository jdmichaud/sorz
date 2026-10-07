//! The ending in the boss's chair, when a player kept Mr. X's offer to the last
//! (`screens/boss_ending`): the room fades in with the character in the chair (player 1's, or
//! player 2's when player 1 is out); its two lines are typed a letter at a time, each letter
//! lit in a grey that rises before it takes the font's own colours, held, then erased so, the
//! grey falling; the credits roll up the plane, written a row below the view as their rows come;
//! the character turns in the chair; the colours darken in steps to the light on it; BAD END is
//! typed; START fades the scene out, and the game starts again from the Sega logo.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const art = @import("../content/art.zig");
const records = @import("../content/screens.zig");
const setup_mod = @import("../setup.zig");
const Colours = @import("colours.zig").Colours;
const Setup = setup_mod.Setup;

/// The plane's rows the credits cycle through (16 pixels each), and the pixels a credit's row
/// is written below the view's top.
const slots = 16;
const below = 240;

/// The scene's steps, each a tick at least.
const Step = enum {
    fade_in,
    type_first,
    type_second,
    hold,
    holding,
    erase_from,
    erase_first,
    erase_second,
    credits_from,
    credits,
    turn,
    turning,
    after_turn,
    waiting,
    darken_from,
    darken,
    type_last,
    start_from,
    wait_start,
    fade_out,
};

/// What the plane shows of a line: its codes typed (in the font's colours), its codes erased,
/// and the code lit in the rising or falling grey.
const Line = struct { typed: u8 = 0, erased: u8 = 0, lit: ?u8 = null };

pub const BossEnding = struct {
    ticks: u16 = 0,
    /// A tick is two display ticks: the second shows nothing new; START pressed then counts at
    /// the next.
    second: bool = false,
    kept: bool = false,
    who: setup_mod.Character = .axel,
    pad2: bool = false,
    step: Step = .fade_in,
    /// The line's code under way, and whether it is lit (else the next is to come); the lit
    /// letter's level; the ticks a step counts down; the colours' steps taken.
    code: u8 = 0,
    lit: bool = false,
    ramp: u8 = 0,
    count: u16 = 0,
    darkened: u8 = 0,
    colours: Colours = .{},
    colours_before: render.palettes.Colours = render.palettes.black,
    lines: [3]Line = @splat(.{}),
    /// Plane A's scroll down (in 1/65536 of a pixel), and the credits' rows written.
    y: u32 = 0,
    rows: u16 = 0,
    /// The character turning: the ticks since it began.
    turned: ?u16 = null,
    /// What the picture shows: the tick before's.
    shown: Shown = .{},
    before: Shown = .{},

    const Shown = struct {
        lines: [3]Line = @splat(.{}),
        y: u16 = 0,
        rows: u16 = 0,
        turned: ?u16 = null,
    };

    pub const Assets = struct {
        data: *const records.BossEnding,
        italic: library.Text,
        art: *const art.Art,
        music: library.Sound,
        leave: library.Sound,
        pub const names = .{
            .data = "screens/boss_ending",
            .italic = "fonts/italic",
            .art = "art",
            .music = "bad ending music",
            .leave = "fade out",
        };
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 }, .b = .{ .width = 64, .height = 32 } };

    pub fn start(setup: *const Setup) BossEnding {
        const p = setup.progress.players;
        const k: usize = if (p[0].in_play or !p[1].in_play) 0 else 1;
        return .{ .who = setup.characters[k] orelse .axel, .pad2 = k == 1 };
    }

    fn chair(self: *const BossEnding, d: *const records.BossEnding) *const records.Chair {
        for (d.chairs) |*c| if (std.mem.eql(u8, c.character, @tagName(self.who))) return c;
        return &d.chairs[0];
    }

    pub fn tick(self: *BossEnding, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        const pressed = if (self.pad2) turn.pressed.pad2 else turn.pressed.pad1;
        if (self.second) {
            self.second = false;
            self.kept = pressed.start;
            turn.frame = null;
            return null;
        }
        self.second = true;
        const start_pressed = self.kept or pressed.start;
        self.kept = false;
        defer self.ticks +|= 1;
        // The colours show a tick later still than a screen's (measured against the original).
        self.colours.latch();
        std.mem.swap(render.palettes.Colours, &self.colours.shown, &self.colours_before);
        defer turn.frame = .{ .colours = self.colours.copy };
        self.shown = self.before;
        self.before = .{ .lines = self.lines, .y = @intCast(self.y >> 16), .rows = self.rows, .turned = self.turned };
        const d = a.data;
        if (self.ticks == 0) {
            turn.releasePads();
            turn.play(a.music);
            for ([_][]const u8{ d.room_colours, self.chair(d).colours }) |name| if (a.art.palette(name)) |p| self.colours.aim(p);
            self.colours.startFade(.target);
        }
        if (self.turned) |*t| t.* += 1;
        switch (self.step) {
            .fade_in => if (self.colours.stepFade()) self.next(),
            .type_first, .type_second, .type_last => self.typeTick(d),
            .hold, .after_turn => {
                self.count = d.wait;
                self.next();
            },
            .holding, .waiting => {
                self.count -= 1;
                if (self.count == 0) self.next();
            },
            .erase_from => {
                self.code = 0;
                self.next();
            },
            .erase_first, .erase_second => self.eraseTick(d),
            .credits_from => {
                if (a.art.palette(d.credits_colours)) |p| self.colours.show(p);
                self.next();
                self.creditsTick(d);
            },
            .credits => self.creditsTick(d),
            .turn => {
                self.turned = 0;
                self.count = d.turn;
                self.next();
            },
            .turning => {
                self.count -= 1;
                if (self.count == 0) {
                    self.turned = null;
                    self.next();
                }
            },
            .darken_from => {
                self.count = d.step_period;
                self.next();
            },
            .darken => {
                self.count -= 1;
                if (self.count != 0) return null;
                if (self.darkened == d.room_steps.len) {
                    self.setColour(0, d.white_colour, 7);
                    self.next();
                    return null;
                }
                for ([_][]const u8{ d.room_steps[self.darkened], self.chair(d).steps[self.darkened] }) |name| if (a.art.palette(name)) |p| self.colours.show(p);
                self.darkened += 1;
                self.count = d.step_period;
            },
            .start_from, .wait_start => {
                if (self.step == .start_from) self.next();
                if (start_pressed) {
                    self.step = .fade_out;
                    self.colours.startFade(.black);
                    turn.play(a.leave);
                }
            },
            .fade_out => if (self.colours.stepFade()) return .done,
        }
        return null;
    }

    fn next(self: *BossEnding) void {
        self.step = @fromBackingInt(@intCast(@backingInt(self.step) + 1));
    }

    fn lineOf(self: *const BossEnding) u2 {
        return switch (self.step) {
            .type_first, .erase_first => 0,
            .type_second, .erase_second => 1,
            else => 2,
        };
    }

    fn setColour(self: *BossEnding, line: u8, colour: u8, level: u3) void {
        self.colours.palettes.shown[line][colour] = .{ .r = level, .g = level, .b = level };
        self.colours.copy = true;
    }

    /// The line's next code to light: its blanks pass at once; at its end, the next step.
    fn nextCode(self: *BossEnding, d: *const records.BossEnding) bool {
        const text = d.lines[self.lineOf()].text;
        while (self.code < text.len and text[self.code] == ' ') self.code += 1;
        if (self.code < text.len) return true;
        self.code = 0;
        self.next();
        return false;
    }

    /// A letter: lit, its grey rising a level a tick, then in the font's colours.
    fn typeTick(self: *BossEnding, d: *const records.BossEnding) void {
        const l = &self.lines[self.lineOf()];
        if (!self.lit) {
            if (!self.nextCode(d)) return;
            l.lit = self.code;
            self.lit = true;
            self.ramp = 0;
            return;
        }
        var level = self.ramp;
        if (level == d.letter_levels) {
            self.code += 1;
            l.typed = self.code;
            l.lit = null;
            self.lit = false;
            level = 0;
        }
        self.setColour(d.letter_line, d.letter_colour, @intCast(level));
        self.ramp += 1;
    }

    /// A letter: lit white, its grey falling a level a tick, then erased.
    fn eraseTick(self: *BossEnding, d: *const records.BossEnding) void {
        const l = &self.lines[self.lineOf()];
        if (!self.lit) {
            self.setColour(d.letter_line, d.letter_colour, 7);
            if (!self.nextCode(d)) return;
            l.lit = self.code;
            self.lit = true;
            return;
        }
        var level: u8 = self.colours.palettes.shown[d.letter_line][d.letter_colour].r - 1;
        if (level == 0) {
            self.code += 1;
            l.erased = self.code;
            l.lit = null;
            self.lit = false;
            level = 7;
        }
        self.setColour(d.letter_line, d.letter_colour, @intCast(level));
    }

    /// The credits: the plane scrolls up; at each of its rows, the next one written below the
    /// view (a credit's when its row has come, else blank); the last ends them.
    fn creditsTick(self: *BossEnding, d: *const records.BossEnding) void {
        if (@as(u16, @truncate(self.y)) == 0 and (self.y >> 16) % 16 == 0) {
            const row: u16 = @intCast(self.y >> 20);
            if (row == d.credits[d.credits.len - 1].row) {
                self.next();
                return;
            }
            self.rows = row + 1;
        }
        self.y += @intCast(d.scroll);
    }

    // --- the picture -----------------------------------------------------------------------------

    pub fn draw(self: *const BossEnding, prev: ?*const BossEnding, v: *view.View, a: *const Assets) !void {
        const d = a.data;
        const s = &self.shown;
        if (prev == null) if (a.art.map(d.room_colours)) |m| try v.board(.b).drawMapAtPlace(m);
        const was: ?*const Shown = if (prev) |p| &p.shown else null;
        for (0..2) |k| if (was == null or !std.meta.eql(was.?.lines[k], s.lines[k])) try drawLine(v, a, k, s.lines[k]);
        // The credits' rows written since (all those still on the plane, drawn whole).
        const from: u16 = if (was) |w| w.rows else s.rows -| slots;
        for (from..s.rows) |row| try drawRow(v, a, @intCast(row));
        if (was == null or !std.meta.eql(was.?.lines[2], s.lines[2])) try drawLine(v, a, 2, s.lines[2]);
        v.screen.plane_a.y = s.y;
        v.screen.colours = self.colours.shown;
        const c = self.chair(d);
        const frames = if (s.turned == null) c.sit else c.turn;
        var at: usize = 0;
        if (s.turned) |t| {
            var left = t % ticksOf(frames);
            while (left >= frames[at].ticks) : (at += 1) left -= frames[at].ticks;
        }
        const frame = a.art.frame(frames[at].frame) orelse return;
        try v.sprites.append(v.gpa, .{ .frame = frame, .x = c.x, .y = c.y, .palette = c.palette });
    }

    fn ticksOf(frames: []const records.ChairFrame) u16 {
        var n: u16 = 0;
        for (frames) |f| n += f.ticks;
        return n;
    }

    fn drawLine(v: *view.View, a: *const Assets, k: usize, l: Line) !void {
        const line = a.data.lines[k];
        for (line.text, 0..) |ch, i| {
            if (ch == ' ') continue;
            const x = @as(i32, line.x) + @as(i32, @intCast(i));
            if (i < l.erased) {
                try v.write(.a, a.italic, x, line.y, " ", .{});
            } else if (l.lit != null and l.lit.? == i) {
                try v.write(.a, a.italic, x, line.y, &.{ch}, .{ .palette = a.data.letter_line });
            } else if (i < l.typed) {
                try v.write(.a, a.italic, x, line.y, &.{ch}, .{});
            }
        }
    }

    /// The credits' row written at the plane's `row`th 16 pixels: below the view, a credit's or
    /// blank.
    fn drawRow(v: *view.View, a: *const Assets, row: u16) !void {
        const d = a.data;
        const y: i32 = @intCast(((@as(u32, row) * 16 + below) & 0xFF) / 8);
        var cells: [64]u8 = @splat(' ');
        for (d.credits) |c| if (c.row == row) {
            @memcpy(cells[0..@min(c.text.len, d.credit_cells)], c.text[0..@min(c.text.len, d.credit_cells)]);
        };
        try v.write(.a, a.italic, d.credit_column, y, cells[0..d.credit_cells], .{ .priority = true });
    }
};

//! The game menu, after the title: the cartridge's 1 PLAYER, 2 PLAYERS, OPTIONS, or the lines of
//! another variant for this machine's part in network play (variant.zig, DESIGN.md 9: the host's
//! NETWORK PLAY; a client's NAME, JOIN and OBSERVE), one under the other from the cartridge's
//! first line, the port's lines written in the font. It fades in; the arrow (the font's `->`)
//! blinks left of the chosen line, up and down move it ("menu move") from the fade's start; once
//! the fade is done, A, B, C or START chooses ("menu choose"), and after a tick the menu fades
//! out, then leaves for the character select or the options. Without a second pad, 2 PLAYERS is
//! dimmed (the colours `menu/one_pad`) and the arrow skips it (network play's second player is the
//! network's: it is never dimmed there); so are a client's JOIN and OBSERVE while the host takes
//! no player or no observer. Choosing OPTIONS with pad 2 holding exactly A, B, C and right at the
//! end of the fade opens the options' hidden lines. Pad 1 drives it: each machine's menu is its
//! own.
//!
//! NETWORK PLAY fades out and asks this machine for its network options (an overlay, game.zig): if
//! they opened the session, the menu leaves for the character select, the host's player alone;
//! else it fades in again. NAME asks for the name entry (a client without a name is asked at
//! once); OBSERVE asks to watch the host's game, which this machine then loads in its place.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const input = @import("../input.zig");
const art = @import("../content/art.zig");
const variant = @import("../variant.zig");
const Setup = @import("../setup.zig").Setup;
const Colours = @import("colours.zig").Colours;

/// The arrow blinks: shown for 16 ticks, hidden for 16.
const blink_ticks = 16;
/// The arrow's place: two cells left of its line.
const arrow_cells = 2;

pub const Line = variant.MenuLine;

/// The most lines a menu has.
const most_lines = std.enums.values(Line).len;

pub const Menu = struct {
    /// Ticks since the scene began (its set-up is tick 1).
    ticks: u16 = 0,
    phase: Phase = .setup,
    colours: Colours = .{},
    /// The lines, from the top (the variant's, taken at the set-up), and how many.
    lines: [most_lines]Line = @splat(.one_player),
    line_count: u8 = 0,
    choice: Line = .one_player,
    /// The choice before the arrow's last move (without a second pad, the arrow skips 2 PLAYERS
    /// in its direction).
    previous: Line = .one_player,
    /// The lines the arrow can be on: all of them, or not 2 PLAYERS without a second pad.
    all_lines: bool = true,
    blink_left: u8 = 0,
    hidden: bool = false,
    /// The arrow as the picture shows it at this tick: the tick before's (null: hidden).
    shown_arrow: ?Line = null,
    /// The lines dimmed (a bit each, by their place), and the name shown on NAME.
    dimmed: u8 = 0,
    name: [3]u8 = .{ ' ', ' ', ' ' },
    /// The player moved the arrow (a client's arrow, until then, goes back to JOIN as it lights).
    moved: bool = false,

    pub const Phase = enum(u8) { setup, fade_in, choosing, chosen, fade_out, leaving, network, observing };

    pub const Assets = struct {
        one_player: *const art.TileMap,
        two_players: *const art.TileMap,
        options: *const art.TileMap,
        two_pads: *const art.Palette,
        one_pad: *const art.Palette,
        text: library.Text,
        move: library.Sound,
        choose: library.Sound,
        pub const names = .{
            .one_player = "menu/one_player",
            .two_players = "menu/two_players",
            .options = "menu/options",
            .two_pads = "menu/two_pads",
            .one_pad = "menu/one_pad",
            .text = "fonts/main",
            .move = "menu move",
            .choose = "menu choose",
        };

        /// The cartridge's art of a line (none for the port's, written in the font).
        pub fn map(a: *const Assets, l: Line) ?*const art.TileMap {
            return switch (l) {
                .one_player => a.one_player,
                .two_players => a.two_players,
                .options => a.options,
                else => null,
            };
        }

        /// The cell of the menu's `i`th line: the cartridge's first line's, and as many of its
        /// lines' steps down (each cartridge line at its own place).
        pub fn cellOf(a: *const Assets, i: usize) struct { x: i32, y: i32 } {
            const first = a.one_player.place orelse art.Place{ .layer = .plane_a, .x = 0, .y = 0 };
            const second = a.two_players.place orelse first;
            const step = @as(i32, second.y) - first.y;
            return .{ .x = first.x, .y = first.y + step * @as(i32, @intCast(i)) };
        }
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn start(_: *const Setup) Menu {
        return .{};
    }

    fn slice(self: *const Menu) []const Line {
        return self.lines[0..self.line_count];
    }

    fn indexOf(self: *const Menu, l: Line) usize {
        return std.mem.indexOfScalar(Line, self.slice(), l) orelse 0;
    }

    /// The arrow's top-left on the screen for line `l`: two cells left of the line's place.
    pub fn arrowAt(self: *const Menu, a: *const Assets, l: Line) struct { x: i32, y: i32 } {
        const c = a.cellOf(self.indexOf(l));
        return .{ .x = (c.x - arrow_cells) * 8, .y = c.y * 8 };
    }

    pub fn tick(self: *Menu, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        self.colours.latch();
        defer turn.frame = .{ .colours = self.colours.copy, .first_line = true };
        self.shown_arrow = if (self.hidden) null else self.choice;
        switch (self.phase) {
            .setup => {
                turn.releasePads();
                turn.setup.hidden_lines = false;
                const lines = turn.policies.menuLines(turn.net.role);
                @memcpy(self.lines[0..lines.len], lines);
                self.line_count = @intCast(lines.len);
                self.choice = lines[0];
                self.previous = lines[0];
                self.all_lines = turn.second_pad;
                self.name = turn.net.name;
                // A client's lines dim (palette 1): the colours of one pad.
                self.colours.aim(if (turn.second_pad and turn.net.role != .client) a.two_pads else a.one_pad);
                self.dim(turn);
                if (turn.net.role == .client) {
                    self.choice = .join;
                    self.previous = .join;
                    if (!turn.net.named) turn.net_request = .name;
                }
                self.blink_left = blink_ticks;
                // The host back from a game with its server running: its lobby at once, the menu
                // dark under it (it fades in once the lobby closes).
                if (turn.net.lobby or (turn.net.start_game and turn.net.hosting)) {
                    self.choice = .network_play;
                    self.previous = .network_play;
                    // Its START GAME chosen already (a lobby over a game that ended): on to the
                    // select.
                    if (turn.net.lobby) turn.net_request = .network_options;
                    self.phase = .network;
                    return null;
                }
                self.colours.startFade(.target);
                // The menu's first step in the same tick: the arrow, the fade's first step.
                self.cursor(turn, turn.pressed.pad1, a);
                _ = self.colours.stepFade();
                self.phase = .fade_in;
            },
            .fade_in => {
                self.dim(turn);
                self.cursor(turn, turn.pressed.pad1, a);
                if (self.colours.stepFade()) self.phase = .choosing;
            },
            .choosing => {
                self.dim(turn);
                self.name = turn.net.name;
                const p = turn.pressed.pad1;
                if ((p.a or p.b or p.c or p.start) and self.available(self.choice)) {
                    turn.play(a.choose);
                    switch (self.choice) {
                        .name => turn.net_request = .name,
                        .observe => {
                            turn.net_request = .observe;
                            self.phase = .observing;
                        },
                        else => self.phase = .chosen,
                    }
                } else {
                    // The lines follow the second pad as it comes and goes (`dim`).
                    self.cursor(turn, p, a);
                }
            },
            // A tick to start the fade, which the arrow does not follow (it stays as it was).
            .chosen => {
                self.colours.startFade(.black);
                self.phase = .fade_out;
            },
            .fade_out => if (self.colours.stepFade()) {
                self.phase = .leaving;
            },
            // The network options closed (no tick runs while they are open): with START GAME, the
            // session open, the host's player goes to the character select alone; else (the
            // server started or stopped, or nothing) back to the menu.
            .network => if (turn.net.start_game and turn.net.hosting) {
                turn.setup.players = .one;
                turn.setup.rules = if (turn.policies.settings_rules) turn.rules else null;
                turn.setup.same_character = turn.net.same_character;
                return .network_play;
            } else {
                self.colours.startFade(.target);
                self.phase = .fade_in;
            },
            // Waiting for the host's game, which this machine loads in the menu's place; back to
            // choosing when the host takes no observer any more.
            .observing => if (!turn.net.can_observe) {
                self.phase = .choosing;
            },
            // A game: its players, and its rules, this machine's settings' where the variant takes
            // them.
            .leaving => switch (self.choice) {
                .one_player => {
                    turn.setup.players = .one;
                    turn.setup.rules = if (turn.policies.settings_rules) turn.rules else null;
                    turn.setup.same_character = null;
                    return .one_player;
                },
                // Both players here, or this machine's alone: the other machine's joins later (a
                // client's JOIN: the host's game).
                .two_players, .join => {
                    turn.setup.players = if (turn.policies.two_players_here) .two else .one;
                    turn.setup.rules = if (turn.policies.settings_rules) turn.rules else null;
                    turn.setup.same_character = null;
                    return .two_players;
                },
                .network_play => {
                    turn.net_request = .network_options;
                    self.phase = .network;
                },
                .name, .observe => unreachable,
                .options => {
                    const p2 = turn.pads.pad2;
                    const code: input.Pad = .{ .a = true, .b = true, .c = true, .right = true };
                    turn.setup.hidden_lines = std.meta.eql(p2, code);
                    return .options;
                },
            },
        }
        return null;
    }

    /// The arrow: up and down move it, round the ends, with a sound; it blinks; it does not stay
    /// on a dimmed line (2 PLAYERS without a second pad, a client's JOIN or OBSERVE the host does
    /// not take), but goes on in its direction. A client's arrow starts on JOIN, and goes back to
    /// it as it lights until the player moves the arrow.
    fn cursor(self: *Menu, turn: *scene.Turn, p: input.Pad, a: *const Assets) void {
        const lines = self.slice();
        const n = lines.len;
        if (!self.moved and turn.net.role == .client and self.available(.join)) self.choice = .join;
        if (p.up or p.down) {
            self.moved = true;
            turn.play(a.move);
            self.previous = self.choice;
            const i = self.indexOf(self.choice);
            self.choice = lines[if (p.up) (i + n - 1) % n else (i + 1) % n];
        }
        self.blink_left -= 1;
        if (self.blink_left == 0) {
            self.blink_left = blink_ticks;
            self.hidden = !self.hidden;
        }
        var tries: usize = 0;
        while (!self.available(self.choice) and tries < n) : (tries += 1) {
            const i = self.indexOf(self.choice);
            const up = self.previous == lines[(i + 1) % n];
            self.previous = self.choice;
            self.choice = lines[if (up) (i + n - 1) % n else (i + 1) % n];
        }
    }

    /// Whether a line can be chosen now.
    fn available(self: *const Menu, l: Line) bool {
        return self.dimmed & (@as(u8, 1) << @intCast(self.indexOf(l))) == 0;
    }

    /// The lines dimmed now: 2 PLAYERS without a second pad, a client's JOIN and OBSERVE by what
    /// the host takes.
    fn dim(self: *Menu, turn: *const scene.Turn) void {
        if (!self.all_lines and turn.second_pad) self.all_lines = true;
        if (self.all_lines and !turn.second_pad) self.all_lines = false;
        var bits: u8 = 0;
        for (self.slice(), 0..) |l, i| {
            const off = switch (l) {
                .two_players => !self.all_lines,
                .join => !turn.net.can_join,
                .observe => !turn.net.can_observe,
                else => false,
            };
            if (off) bits |= @as(u8, 1) << @intCast(i);
        }
        self.dimmed = bits;
    }

    pub fn draw(self: *const Menu, prev: ?*const Menu, v: *view.View, a: *const Assets) !void {
        for (self.slice(), 0..) |l, i| {
            const c = a.cellOf(i);
            if (a.map(l)) |m| {
                if (prev == null) try v.board(.a).drawMap(m, c.x, c.y);
                continue;
            }
            // The port's lines, in the font: again when their dimming or the name changed.
            if (prev) |p| if (p.dimmed == self.dimmed and std.mem.eql(u8, &p.name, &self.name)) continue;
            const look: render.Look = .{ .palette = if (self.available(l)) 0 else 1 };
            var buf: [16]u8 = undefined;
            const text: []const u8 = switch (l) {
                .network_play => "NETWORK PLAY",
                .join => "JOIN",
                .observe => "OBSERVE",
                .name => std.fmt.bufPrint(&buf, "NAME  {s}", .{&self.name}) catch unreachable,
                else => unreachable,
            };
            try v.write(.a, a.text, c.x, c.y, text, look);
        }
        v.screen.colours = self.colours.shown;
        if (self.shown_arrow) |l| {
            const at = self.arrowAt(a, l);
            try v.sprites.append(v.gpa, render.Sprite.of(try v.glyphFrame(a.text, "->"), at.x, at.y));
        }
    }
};

const Fixture = struct {
    const cells = [_]art.Cell{.{ .tile = 0 }};
    const tiles = [_]art.Tile{@splat(1)};
    const glyphs = [_]art.Glyph{.{ .text = "->", .tile = 0 }};
    const font: art.Font = .{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs };
    const sheet: art.TileSheet = .{ .name = "main", .file = "main.png", .tiles = &tiles };
    const maps = blk: {
        var m: [3]art.TileMap = undefined;
        for (&m, 0..) |*x, i| x.* = .{ .name = "line", .file = "line.tmj", .width = 1, .height = 1, .sheets = &.{}, .tiles = &tiles, .cells = &cells, .place = .{ .layer = .plane_a, .x = 16, .y = 11 + 2 * i } };
        break :blk m;
    };
    const one_pad = blk: {
        var p: art.Palette = .{ .name = "one_pad" };
        p.colours[1][1] = .{ .r = 1, .g = 1, .b = 1 };
        break :blk p;
    };
    const assets: Menu.Assets = .{
        .one_player = &maps[0],
        .two_players = &maps[1],
        .options = &maps[2],
        .two_pads = &.{ .name = "two_pads" },
        .one_pad = &one_pad,
        .text = .{ .font = &font, .sheet = &sheet },
        .move = 1,
        .choose = 2,
    };
};

/// A tick of `m` with `pressed`, in variant `v`.
fn press(m: *Menu, setup: *Setup, v: variant.Variant, second_pad: bool, pressed: input.Pads) struct { exit: ?flow.Exit, turn: scene.Turn } {
    var turn: scene.Turn = .{ .setup = setup, .second_pad = second_pad, .pressed = pressed, .policies = &v.config().policies };
    const exit = m.tick(&turn, &Fixture.assets);
    return .{ .exit = exit, .turn = turn };
}

test "without a second pad, 2 PLAYERS is dimmed and the arrow skips it; A chooses after the fade" {
    const a = &Fixture.assets;
    var setup: Setup = .{};
    var m: Menu = .{};
    _ = press(&m, &setup, .original, false, .{});
    try std.testing.expect(m.colours.palettes.target[1][1].eql(.{ .r = 1, .g = 1, .b = 1 }));
    // Down from 1 PLAYER lands on OPTIONS; down again on 1 PLAYER; up from it on OPTIONS.
    const down = press(&m, &setup, .original, false, .{ .pad1 = .{ .down = true } });
    try std.testing.expectEqual(Line.options, m.choice);
    try std.testing.expectEqual(@as(library.Sound, 1), down.turn.requests.slice()[0]);
    _ = press(&m, &setup, .original, false, .{ .pad1 = .{ .down = true } });
    try std.testing.expectEqual(Line.one_player, m.choice);
    _ = press(&m, &setup, .original, false, .{ .pad1 = .{ .up = true } });
    try std.testing.expectEqual(Line.options, m.choice);
    // The cartridge's lines at their own places.
    try std.testing.expectEqual(@as(i32, 15 * 8), m.arrowAt(a, .options).y);
    // A during the fade does nothing; after it, it chooses, and the fade out leads to OPTIONS.
    var exit: ?flow.Exit = null;
    while (exit == null) {
        exit = press(&m, &setup, .original, false, .{ .pad1 = .{ .a = true } }).exit;
        if (m.ticks < 64) try std.testing.expect(m.phase == .fade_in);
    }
    // Chosen at the 65th tick (after the 64 steps of the fade in), left 66 ticks later.
    try std.testing.expectEqual(flow.Exit.options, exit.?);
    try std.testing.expectEqual(@as(u16, 65 + 66), m.ticks);
}

test "the extended menu is the cartridge's; 2 PLAYERS puts both players in the game" {
    var setup: Setup = .{};
    var m: Menu = .{};
    _ = press(&m, &setup, .extended, true, .{});
    try std.testing.expectEqualSlices(Line, &.{ .one_player, .two_players, .options }, m.slice());
    while (m.phase != .choosing) _ = press(&m, &setup, .extended, true, .{});
    _ = press(&m, &setup, .extended, true, .{ .pad1 = .{ .down = true } });
    var exit: ?flow.Exit = press(&m, &setup, .extended, true, .{ .pad1 = .{ .start = true } }).exit;
    while (exit == null) exit = press(&m, &setup, .extended, true, .{}).exit;
    try std.testing.expectEqual(flow.Exit.two_players, exit.?);
    try std.testing.expectEqual(@import("../setup.zig").Players.two, setup.players);
}

test "the network menu: 2 PLAYERS and OPTIONS, pad 1's alone; 2 PLAYERS puts this machine's player in" {
    const a = &Fixture.assets;
    var setup: Setup = .{ .players = .two };
    var m: Menu = .{};
    _ = press(&m, &setup, .network, true, .{});
    try std.testing.expectEqualSlices(Line, &.{ .two_players, .options }, m.slice());
    // From the cartridge's first line's place down.
    try std.testing.expectEqual(@as(i32, 11 * 8), m.arrowAt(a, .two_players).y);
    try std.testing.expectEqual(@as(i32, 13 * 8), m.arrowAt(a, .options).y);
    while (m.phase != .choosing) _ = press(&m, &setup, .network, true, .{});
    // Pad 2 is not this menu's: the arrow stays.
    _ = press(&m, &setup, .network, true, .{ .pad2 = .{ .down = true } });
    try std.testing.expectEqual(Line.two_players, m.choice);
    _ = press(&m, &setup, .network, true, .{ .pad1 = .{ .down = true } });
    _ = press(&m, &setup, .network, true, .{ .pad1 = .{ .down = true } });
    try std.testing.expectEqual(Line.two_players, m.choice);
    var exit: ?flow.Exit = press(&m, &setup, .network, true, .{ .pad1 = .{ .b = true } }).exit;
    while (exit == null) exit = press(&m, &setup, .network, true, .{}).exit;
    try std.testing.expectEqual(flow.Exit.two_players, exit.?);
    try std.testing.expectEqual(@import("../setup.zig").Players.one, setup.players);
}

test "a client's arrow: on JOIN, off it while it is dimmed, back as it lights until the player moves it" {
    var setup: Setup = .{};
    var m: Menu = .{};
    const tick = struct {
        fn f(menu: *Menu, s: *Setup, open: bool, pressed: input.Pads) void {
            var turn: scene.Turn = .{
                .setup = s,
                .second_pad = false,
                .pressed = pressed,
                .policies = &variant.Variant.network.config().policies,
                .net = .{ .role = .client, .named = true, .can_join = open, .can_observe = open },
            };
            _ = menu.tick(&turn, &Fixture.assets);
        }
    }.f;
    tick(&m, &setup, false, .{});
    try std.testing.expectEqualSlices(Line, &.{ .name, .join, .observe, .options }, m.slice());
    try std.testing.expectEqual(Line.options, m.choice);
    tick(&m, &setup, true, .{});
    try std.testing.expectEqual(Line.join, m.choice);
    // Moved, it stays where the player put it.
    tick(&m, &setup, true, .{ .pad1 = .{ .down = true } });
    tick(&m, &setup, false, .{});
    tick(&m, &setup, true, .{});
    try std.testing.expectEqual(Line.options, m.choice);
}

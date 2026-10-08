//! The players' controls: the platform's keys and gamepads turned into the two 3-button pads the
//! game reads (`Pad`). The pads are sampled once per display tick, as the original reads its pads
//! once a frame. A lost focus releases every held control.
//!
//! Each player has its input method, the keyboard or a gamepad (GAMEPAD 1 the first to come),
//! its keys, its gamepad's buttons and its autofire, which the player changes in the settings'
//! INPUT CONFIGURATION (`settings/`). By default player 1 is on the arrows, Z (A: the special
//! attack), X (B: attack), C (C: jump) and Enter (start), player 2 on W, A, S, D, F, G, H and Tab,
//! and a gamepad's buttons are X (A), A (B), B (C) and start, its d-pad or left stick the
//! directions. A gamepad that comes goes to player 1 when player 1 is on the keyboard and no
//! player has it; a player whose gamepad is not connected plays with its keys. A gamepad one
//! player takes goes from the player that had it, who goes back to the keyboard. Autofire holds
//! and lets go the attack button in turn while the player holds it.
//!
//! A machine with one player (network play, where each machine has its player, and the browser
//! page always) has player 1 alone: network play sends its pad. The other players' keys and
//! gamepads do nothing there.
const std = @import("std");
const platform = @import("platform.zig");

/// A pad's buttons, in the order of `Pad`'s bits.
pub const Button = enum(u3) { up, down, left, right, a, b, c, start };

/// A 3-button pad as the game reads it at a display tick: a bit for each button held. Its byte is
/// what network play sends for a tick (net/protocol.zig).
pub const Pad = packed struct(u8) {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    a: bool = false,
    b: bool = false,
    c: bool = false,
    start: bool = false,

    pub fn held(pad: Pad, button: Button) bool {
        return @as(u8, @bitCast(pad)) & (@as(u8, 1) << @backingInt(button)) != 0;
    }
};

/// The two pads of a display tick.
pub const Pads = struct {
    pad1: Pad = .{},
    pad2: Pad = .{},
};

comptime {
    for (std.enums.values(Button)) |b| std.debug.assert(@bitOffsetOf(Pad, @tagName(b)) == @backingInt(b));
}

/// The buttons a controller's buttons are chosen for; the directions are its d-pad and left stick.
pub const face_buttons = [_]Button{ .a, .b, .c, .start };

/// The players a machine's controls keep a layout for: the game has two, but network play may
/// bring more.
pub const max_players = 4;

/// A key setting without a key (players 3 and 4 have none at first).
pub const no_key: platform.Key = .unknown;

const KeyBinding = struct { key: platform.Key, player: u2, button: Button };

pub const default_keys = [_]KeyBinding{
    .{ .key = .up, .player = 0, .button = .up },
    .{ .key = .down, .player = 0, .button = .down },
    .{ .key = .left, .player = 0, .button = .left },
    .{ .key = .right, .player = 0, .button = .right },
    .{ .key = .z, .player = 0, .button = .a },
    .{ .key = .x, .player = 0, .button = .b },
    .{ .key = .c, .player = 0, .button = .c },
    .{ .key = .enter, .player = 0, .button = .start },
    .{ .key = .w, .player = 1, .button = .up },
    .{ .key = .s, .player = 1, .button = .down },
    .{ .key = .a, .player = 1, .button = .left },
    .{ .key = .d, .player = 1, .button = .right },
    .{ .key = .f, .player = 1, .button = .a },
    .{ .key = .g, .player = 1, .button = .b },
    .{ .key = .h, .player = 1, .button = .c },
    .{ .key = .tab, .player = 1, .button = .start },
};

/// A player's controls: its input method (the keyboard or a gamepad), its keys, its gamepad's
/// buttons, and autofire.
pub const PlayerInput = struct {
    /// The gamepad it plays with, by the order the gamepads came (0: the first), or null: the
    /// keyboard. While that gamepad is not connected, the player plays with its keys.
    gamepad: ?u2 = null,
    /// Its key for each button, by `Button` (`no_key`: none).
    keys: [8]platform.Key = @splat(no_key),
    /// Its gamepad's buttons for A, B, C and start (`face_buttons`).
    buttons: [face_buttons.len]platform.ControllerButton = .{ .x, .a, .b, .start },
    /// Holding the attack button (the options' CONTROL says which) attacks again and again.
    autofire: bool = false,
};

/// Which keys and gamepad buttons press which player's pad buttons.
pub const Layout = struct {
    players: [max_players]PlayerInput = blk: {
        var players: [max_players]PlayerInput = @splat(.{});
        for (default_keys) |b| players[b.player].keys[@backingInt(b.button)] = b.key;
        break :blk players;
    },

    pub const Place = struct { player: u2, button: Button };

    /// The player's button `key` is set for, if any.
    pub fn find(self: *const Layout, key: platform.Key) ?Place {
        if (key == no_key) return null;
        for (self.players, 0..) |p, i| for (p.keys, 0..) |k, b| if (k == key) {
            return .{ .player = @intCast(i), .button = @fromBackingInt(@as(u3, @intCast(b))) };
        };
        return null;
    }

    /// The pad button a gamepad's button presses for player `p`, if any.
    pub fn buttonOf(self: *const Layout, p: usize, button: platform.ControllerButton) ?Button {
        return switch (button) {
            .dpad_up => .up,
            .dpad_down => .down,
            .dpad_left => .left,
            .dpad_right => .right,
            else => for (self.players[p].buttons, face_buttons) |b, face| {
                if (b == button) break face;
            } else null,
        };
    }

    /// Gamepad `g` came: player 1 takes it when it plays on the keyboard and no player has it.
    /// Returns whether it did.
    pub fn came(self: *Layout, g: u2) bool {
        for (self.players) |p| if (p.gamepad == g) return false;
        if (self.players[0].gamepad != null) return false;
        self.players[0].gamepad = g;
        return true;
    }

    /// Player `p` takes gamepad `g` (null: the keyboard); a player that had it goes to the
    /// keyboard.
    pub fn assign(self: *Layout, p: usize, g: ?u2) void {
        if (g != null) for (&self.players) |*other| if (other.gamepad == g) {
            other.gamepad = null;
        };
        self.players[p].gamepad = g;
    }
};

/// The left stick's dead zone: beyond it, the stick is a direction.
const stick_threshold: i16 = 16384;

/// Autofire's pace: the attack button held for this many display ticks, then released as long.
const autofire_half = 4;

pub const Controls = struct {
    layout: Layout = .{},
    /// One player on this machine (network play, the browser's page): player 1 alone plays.
    one_player: bool = false,
    /// The buttons held through each player's keys.
    keys: [max_players]u8 = @splat(0),
    /// The buttons held through each gamepad, by its place in `controllers`: the d-pad and
    /// buttons, and the stick. Each gamepad keeps its own, so that one's release or removal does
    /// not let go of what another holds.
    pad_buttons: [max_controllers]u8 = @splat(0),
    stick: [max_controllers]u8 = @splat(0),
    /// The gamepads in the order they came, each in the first free place: GAMEPAD 1 is the
    /// first place's.
    controllers: [max_controllers]?platform.ControllerId = @splat(null),
    /// The display tick each player's attack button has been held since, for autofire.
    autofire_since: [max_players]?u32 = @splat(null),

    pub const max_controllers = 4;

    /// The players on this machine.
    pub fn players(self: *const Controls) usize {
        return if (self.one_player) 1 else 2;
    }

    /// Takes one platform event; returns whether it concerned the controls. A gamepad that comes
    /// goes to player 1 when player 1 plays on the keyboard and no player has it.
    pub fn handle(self: *Controls, e: platform.Event) bool {
        switch (e.payload) {
            .key_down => |k| return self.key(k.key, true),
            .key_up => |k| return self.key(k.key, false),
            .controller_added => |id| {
                for (&self.controllers, 0..) |*c, slot| if (c.* == null) {
                    c.* = id;
                    if (self.layout.came(@intCast(slot))) self.keys[0] = 0;
                    return true;
                };
                return false;
            },
            .controller_removed => |id| {
                const slot = self.slotOf(id) orelse return false;
                self.controllers[slot] = null;
                self.pad_buttons[slot] = 0;
                self.stick[slot] = 0;
                return true;
            },
            .controller_button_down => |b| return self.controllerButton(b, true),
            .controller_button_up => |b| return self.controllerButton(b, false),
            .controller_axis => |a| return self.axis(a),
            .focus_lost => {
                self.release();
                return true;
            },
            else => return false,
        }
    }

    /// Releases every held control, as a lost focus does.
    pub fn release(self: *Controls) void {
        self.keys = @splat(0);
        self.pad_buttons = @splat(0);
        self.stick = @splat(0);
    }

    /// The pads as the players hold them: each player's keys (while they play it) and its
    /// gamepad's buttons and stick.
    pub fn pads(self: *const Controls) Pads {
        var bits: [max_players]u8 = @splat(0);
        for (0..self.players()) |p| if (self.keysPlay(p)) {
            bits[p] = self.keys[p];
        };
        for (0..max_controllers) |slot| {
            if (self.playerOfSlot(slot)) |p| bits[p] |= self.pad_buttons[slot] | self.stick[slot];
        }
        return .{ .pad1 = @bitCast(bits[0]), .pad2 = @bitCast(bits[1]) };
    }

    /// The pads as the game reads them at display tick `tick`: `pads`, the attack button
    /// (`attack`, by the options' CONTROL) of a player with autofire held and released in turn
    /// while it is held.
    pub fn read(self: *Controls, tick: u32, attack: Button) Pads {
        var out = self.pads();
        for ([_]*Pad{ &out.pad1, &out.pad2 }, 0..) |pad, p| {
            const bits: *u8 = @ptrCast(pad);
            const mask: u8 = @as(u8, 1) << @backingInt(attack);
            if (!self.layout.players[p].autofire or bits.* & mask == 0) {
                self.autofire_since[p] = null;
                continue;
            }
            const since = self.autofire_since[p] orelse tick;
            self.autofire_since[p] = since;
            if ((tick -% since) / autofire_half % 2 == 1) bits.* &= ~mask;
        }
        return out;
    }

    /// Whether player `p`'s keys play it now: it is on the keyboard, or its gamepad is not
    /// connected.
    pub fn keysPlay(self: *const Controls, p: usize) bool {
        const g = self.layout.players[p].gamepad orelse return true;
        return self.controllers[g] == null;
    }

    /// Whether `key` presses a button of a player of this machine now.
    pub fn uses(self: *const Controls, k: platform.Key) bool {
        const place = self.layout.find(k) orelse return false;
        return place.player < self.players() and self.keysPlay(place.player);
    }

    fn key(self: *Controls, k: platform.Key, down: bool) bool {
        if (!self.uses(k)) return false;
        const place = self.layout.find(k).?;
        set(&self.keys[place.player], place.button, down);
        return true;
    }

    /// The place of a gamepad in `controllers` (GAMEPAD 1 the first's).
    pub fn slotOf(self: *const Controls, id: platform.ControllerId) ?usize {
        for (self.controllers, 0..) |c, i| if (c == id) return i;
        return null;
    }

    /// The gamepads connected, a bit each by their place.
    pub fn connected(self: *const Controls) u4 {
        var bits: u4 = 0;
        for (self.controllers, 0..) |c, i| if (c != null) {
            bits |= @as(u4, 1) << @intCast(i);
        };
        return bits;
    }

    /// The player of this machine the gamepad at `slot` plays, if any.
    pub fn playerOfSlot(self: *const Controls, slot: usize) ?usize {
        if (self.controllers[slot] == null) return null;
        for (0..self.players()) |p| if (self.layout.players[p].gamepad) |g| if (g == slot) return p;
        return null;
    }

    fn controllerButton(self: *Controls, e: platform.Event.ControllerButtonEvent, down: bool) bool {
        const slot = self.slotOf(e.controller) orelse return false;
        const p = self.playerOfSlot(slot) orelse return false;
        const button = self.layout.buttonOf(p, e.button) orelse return false;
        set(&self.pad_buttons[slot], button, down);
        return true;
    }

    fn axis(self: *Controls, e: platform.Event.ControllerAxisEvent) bool {
        const slot = self.slotOf(e.controller) orelse return false;
        _ = self.playerOfSlot(slot) orelse return false;
        switch (e.axis) {
            .left_x => {
                set(&self.stick[slot], .left, e.value < -stick_threshold);
                set(&self.stick[slot], .right, e.value > stick_threshold);
            },
            .left_y => {
                set(&self.stick[slot], .up, e.value < -stick_threshold);
                set(&self.stick[slot], .down, e.value > stick_threshold);
            },
            else => return false,
        }
        return true;
    }

    fn set(bits: *u8, button: Button, down: bool) void {
        const mask: u8 = @as(u8, 1) << @backingInt(button);
        if (down) bits.* |= mask else bits.* &= ~mask;
    }
};

test "keys, a gamepad and the stick make the pads; a gamepad that comes goes to player 1" {
    var c: Controls = .{};
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .right } } });
    try std.testing.expect(c.pads().pad1.b and c.pads().pad1.right and !c.pads().pad1.a);
    try std.testing.expect(c.pads().pad1.held(.b) and !c.pads().pad1.held(.a));
    try std.testing.expectEqual(@as(u8, 0b0010_1000), @as(u8, @bitCast(c.pads().pad1)));
    // The gamepad goes to player 1, whose keys stop playing it (and are let go).
    const id: platform.ControllerId = @fromBackingInt(@intCast(7));
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = id } });
    try std.testing.expectEqual(@as(?u2, 0), c.layout.players[0].gamepad);
    try std.testing.expect(!c.pads().pad1.b and !c.uses(.x));
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = id, .button = .b } } });
    try std.testing.expect(c.pads().pad1.c);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_axis = .{ .controller = id, .axis = .left_y, .value = -30000 } } });
    try std.testing.expect(c.pads().pad1.up);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .tab } } });
    try std.testing.expect(c.pads().pad2.start);
    _ = c.handle(.{ .time_ns = 0, .payload = .focus_lost });
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad1)));
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad2)));
    // Removed, the gamepad gives player 1 its keys back.
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_removed = id } });
    try std.testing.expect(c.uses(.x) and c.layout.players[0].gamepad == 0);
}

test "each player its gamepad and its buttons; a gamepad taken goes from the other player" {
    var c: Controls = .{};
    c.layout.players[0].keys[@backingInt(Button.b)] = .space;
    c.layout.players[1].buttons = .{ .y, .x, .a, .back };
    const first: platform.ControllerId = @fromBackingInt(@intCast(3));
    const second: platform.ControllerId = @fromBackingInt(@intCast(4));
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = first } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = second } });
    // The second gamepad, no player's, plays nothing until player 2 takes it.
    try std.testing.expect(!c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = second, .button = .y } } }));
    c.layout.assign(1, 1);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = second, .button = .back } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = first, .button = .x } } });
    try std.testing.expect(c.pads().pad2.start and c.pads().pad1.a);
    // Player 2's keys do nothing while its gamepad plays; player 1 is on the first gamepad.
    try std.testing.expect(!c.uses(.tab) and !c.uses(.space));
    // Player 2 takes the first gamepad: player 1 goes to the keyboard.
    c.layout.assign(1, 0);
    try std.testing.expect(c.layout.players[0].gamepad == null and c.uses(.space));
    try std.testing.expectEqual(@as(?usize, 1), c.playerOfSlot(0));
    try std.testing.expectEqual(@as(u4, 0b11), c.connected());
    c.release();
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad1)) | @as(u8, @bitCast(c.pads().pad2)));
}

test "two gamepads of one player: one's release or removal keeps what the other holds" {
    var c: Controls = .{};
    const first: platform.ControllerId = @fromBackingInt(@intCast(3));
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = first } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = first, .button = .a } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_axis = .{ .controller = first, .axis = .left_x, .value = 30000 } } });
    // Player 1's keys press the same button and let it go.
    c.layout.players[0].gamepad = null;
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_up = .{ .key = .x } } });
    c.layout.players[0].gamepad = 0;
    try std.testing.expect(c.pads().pad1.b and c.pads().pad1.right);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_removed = first } });
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad1)));
}

test "one player: player 1 alone, its keys or its gamepad" {
    var c: Controls = .{ .one_player = true };
    const first: platform.ControllerId = @fromBackingInt(@intCast(3));
    const second: platform.ControllerId = @fromBackingInt(@intCast(4));
    c.layout.players[1].gamepad = 1;
    for ([_]platform.ControllerId{ first, second }) |id| _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = id } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = first, .button = .start } } });
    try std.testing.expect(c.pads().pad1.start);
    // Player 2's gamepad and keys do nothing here.
    try std.testing.expect(!c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = second, .button = .start } } }));
    try std.testing.expect(!c.uses(.tab) and !c.uses(.w) and !c.uses(.enter));
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad2)));
}

test "autofire: the attack button held is held and let go in turn" {
    var c: Controls = .{};
    c.layout.players[0].autofire = true;
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .z } } });
    var b: [10]bool = undefined;
    for (&b, 0..) |*x, t| {
        const pads_ = c.read(@intCast(100 + t), .b);
        x.* = pads_.pad1.b;
        try std.testing.expect(pads_.pad1.a);
    }
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true, false, false, false, false, true, true }, &b);
    // Player 2 has no autofire: its attack stays held.
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .g } } });
    for (0..8) |t| try std.testing.expect(c.read(@intCast(t), .b).pad2.b);
}

//! The players' controls: the platform's keys and gamepads turned into the two 3-button pads the
//! game reads (`Pad`). The pads are sampled once per display tick, as the original reads its pads
//! once a frame. A lost focus releases every held control.
//!
//! Each player has its input method, the keyboard or a gamepad, its keys and its autofire, which
//! the player changes in the settings' INPUT CONFIGURATION (`settings/`). By default player 1 is
//! on the arrows, Z (A: the special attack), X (B: attack), C (C: jump) and Enter (start), player 2
//! on W, A, S, D, F, G, H and Tab.
//!
//! The gamepads are known by their model, as the platform names them (DESIGN.md 3.3): every gamepad
//! seen keeps a label of its own for good (GAMEPAD 1, 2...), identical ones numbered in the order
//! they come, and its buttons for A, B, C and start are its model's (X, A, B and start at first;
//! the d-pad or left stick its directions); a player keeps the label of its gamepad. A gamepad that
//! comes goes to player 1 when player 1 is on the keyboard and no player has it; a player whose
//! gamepad is not connected plays with its keys. A gamepad one player takes goes from the player
//! that had it, who goes back to the keyboard. Autofire holds and lets go the attack button in
//! turn while the player holds it.
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

/// A gamepad's buttons for A, B, C and start (`face_buttons`) at first.
pub const default_buttons: [face_buttons.len]platform.ControllerButton = .{ .x, .a, .b, .start };

/// The gamepads a machine keeps (its settings' GAMEPAD LIST); past them, the unconnected one of
/// the lowest label is forgotten to make room. A model's key and a name are kept up to their
/// sizes.
pub const max_known = 64;
pub const max_model = 128;
pub const max_name = 48;

/// A short text kept in place, in printable ASCII (another byte kept as '?'); the bytes past it are
/// zeros, so that equal texts are equal.
pub fn Text(comptime n: usize) type {
    return struct {
        bytes: [n]u8 = @splat(0),
        len: u8 = 0,

        pub fn of(s: []const u8) @This() {
            var t: @This() = .{};
            t.len = @intCast(@min(s.len, n));
            for (t.bytes[0..t.len], s[0..t.len]) |*b, ch| b.* = if (ch >= 0x20 and ch < 0x7f) ch else '?';
            return t;
        }

        pub fn slice(t: *const @This()) []const u8 {
            return t.bytes[0..t.len];
        }
    };
}

/// A gamepad the machine has seen (DESIGN.md 3.3): its label (GAMEPAD 1, 2...), its own for good;
/// its model's key and its name, as the platform gives them; its buttons for A, B, C and start,
/// the same for every gamepad of its model.
pub const Gamepad = struct {
    label: u16,
    model: Text(max_model) = .{},
    name: Text(max_name) = .{},
    buttons: [face_buttons.len]platform.ControllerButton = default_buttons,
};

/// A player's controls: its input method (the keyboard or a gamepad), its keys, and autofire.
pub const PlayerInput = struct {
    /// The label of the gamepad it plays with, or null: the keyboard. While that gamepad is not
    /// connected, the player plays with its keys.
    gamepad: ?u16 = null,
    /// Its key for each button, by `Button` (`no_key`: none).
    keys: [8]platform.Key = @splat(no_key),
    /// Holding the attack button (the options' CONTROL says which) attacks again and again.
    autofire: bool = false,
};

/// Which keys and gamepads press which player's pad buttons, and the gamepads known.
pub const Layout = struct {
    players: [max_players]PlayerInput = blk: {
        var players: [max_players]PlayerInput = @splat(.{});
        for (default_keys) |b| players[b.player].keys[@backingInt(b.button)] = b.key;
        break :blk players;
    },
    /// The gamepads seen, in no order (the labels say theirs).
    gamepads: [max_known]?Gamepad = @splat(null),

    pub const Place = struct { player: u2, button: Button };

    /// The player's button `key` is set for, if any.
    pub fn find(self: *const Layout, key: platform.Key) ?Place {
        if (key == no_key) return null;
        for (self.players, 0..) |p, i| for (p.keys, 0..) |k, b| if (k == key) {
            return .{ .player = @intCast(i), .button = @fromBackingInt(@as(u3, @intCast(b))) };
        };
        return null;
    }

    /// The gamepad of label `label`, if known.
    pub fn pad(self: *const Layout, label: u16) ?*const Gamepad {
        for (&self.gamepads) |*g| if (g.*) |*x| if (x.label == label) return x;
        return null;
    }

    fn padMut(self: *Layout, label: u16) ?*Gamepad {
        for (&self.gamepads) |*g| if (g.*) |*x| if (x.label == label) return x;
        return null;
    }

    /// The pad button the button `button` of the gamepad labelled `label` presses, if any.
    pub fn buttonOf(self: *const Layout, label: u16, button: platform.ControllerButton) ?Button {
        return switch (button) {
            .dpad_up => .up,
            .dpad_down => .down,
            .dpad_left => .left,
            .dpad_right => .right,
            else => {
                const g = self.pad(label) orelse return null;
                for (g.buttons, face_buttons) |b, face| if (b == button) return face;
                return null;
            },
        };
    }

    /// The gamepad of `model` (named `name`) that came, the gamepads of `connected` labels
    /// already there: the known one of that model of the lowest label not connected (identical
    /// gamepads in the order they come); else a new one, of the lowest label free, with the
    /// buttons of its model's others. `new`: it was not known.
    pub fn identify(self: *Layout, model: []const u8, name: []const u8, connected: []const ?u16) struct { label: u16, new: bool } {
        const key: Text(max_model) = .of(model);
        var best: ?u16 = null;
        for (self.gamepads) |g| if (g) |x| if (std.mem.eql(u8, x.model.slice(), key.slice())) {
            if (std.mem.indexOfScalar(?u16, connected, x.label) != null) continue;
            if (best == null or x.label < best.?) best = x.label;
        };
        if (best) |l| return .{ .label = l, .new = false };
        var label: u16 = 1;
        while (self.pad(label) != null) label += 1;
        var g: Gamepad = .{ .label = label, .model = key, .name = .of(name) };
        for (self.gamepads) |o| if (o) |x| if (std.mem.eql(u8, x.model.slice(), key.slice())) {
            g.buttons = x.buttons;
            break;
        };
        self.adopt(g, connected);
        return .{ .label = label, .new = true };
    }

    /// Keeps `g` among the gamepads known (in place of one of its label); with no room, the
    /// unconnected one (not of `connected`) of the lowest label is forgotten first.
    pub fn adopt(self: *Layout, g: Gamepad, connected: []const ?u16) void {
        if (self.padMut(g.label)) |x| {
            x.* = g;
            return;
        }
        for (&self.gamepads) |*slot| if (slot.* == null) {
            slot.* = g;
            return;
        };
        var oldest: ?u16 = null;
        for (self.gamepads) |o| if (o) |x| {
            if (std.mem.indexOfScalar(?u16, connected, x.label) != null) continue;
            if (oldest == null or x.label < oldest.?) oldest = x.label;
        };
        self.forget(oldest orelse return);
        self.adopt(g, connected);
    }

    /// Forgets the gamepad of label `label`: a player that had it goes to the keyboard.
    pub fn forget(self: *Layout, label: u16) void {
        for (&self.gamepads) |*g| if (g.*) |x| if (x.label == label) {
            g.* = null;
        };
        for (&self.players) |*p| if (p.gamepad == label) {
            p.gamepad = null;
        };
    }

    /// The labels of the gamepads known, in their order, in `out`.
    pub fn labels(self: *const Layout, out: *[max_known]u16) []u16 {
        var n: usize = 0;
        for (self.gamepads) |g| if (g) |x| {
            out[n] = x.label;
            n += 1;
        };
        std.mem.sort(u16, out[0..n], {}, std.sort.asc(u16));
        return out[0..n];
    }

    /// Gamepad `label` came: player 1 takes it when it plays on the keyboard and no player has
    /// it. Returns whether it did.
    pub fn came(self: *Layout, label: u16) bool {
        for (self.players) |p| if (p.gamepad == label) return false;
        if (self.players[0].gamepad != null) return false;
        self.players[0].gamepad = label;
        return true;
    }

    /// Player `p` takes the gamepad labelled `g` (null: the keyboard); a player that had it goes
    /// to the keyboard.
    pub fn assign(self: *Layout, p: usize, g: ?u16) void {
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
    /// The gamepads connected, each in the first free place, and their labels.
    controllers: [max_controllers]?platform.ControllerId = @splat(null),
    labels: [max_controllers]?u16 = @splat(null),
    /// The display tick each player's attack button has been held since, for autofire.
    autofire_since: [max_players]?u32 = @splat(null),

    pub const max_controllers = 4;

    /// The players on this machine.
    pub fn players(self: *const Controls) usize {
        return if (self.one_player) 1 else 2;
    }

    /// Takes one platform event; returns whether it concerned the controls. A gamepad that comes
    /// unnamed is of no model (`add` names it).
    pub fn handle(self: *Controls, e: platform.Event) bool {
        switch (e.payload) {
            .key_down => |k| return self.key(k.key, true),
            .key_up => |k| return self.key(k.key, false),
            .controller_added => |id| return self.add(id, .{}) != null,
            .controller_removed => |id| {
                const slot = self.slotOf(id) orelse return false;
                self.controllers[slot] = null;
                self.labels[slot] = null;
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

    /// What `add` did: the gamepad's label, and whether it was not known before.
    pub const Added = struct { label: u16, new: bool };

    /// Gamepad `id` came, as the platform names it (`info`): it takes the first free place and
    /// the label of the gamepad of its model known (`Layout.identify`); player 1 takes it when it
    /// plays on the keyboard and no player has it. Null without a free place.
    pub fn add(self: *Controls, id: platform.ControllerId, info: platform.ControllerInfo) ?Added {
        if (self.slotOf(id)) |slot| return .{ .label = self.labels[slot].?, .new = false };
        const slot = std.mem.indexOfScalar(?platform.ControllerId, &self.controllers, null) orelse return null;
        const got = self.layout.identify(info.model, info.name, &self.labels);
        self.controllers[slot] = id;
        self.labels[slot] = got.label;
        if (self.layout.came(got.label)) self.keys[0] = 0;
        return .{ .label = got.label, .new = got.new };
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
        for ([_]*Pad{ &out.pad1, &out.pad2 }, 0..) |pad_, p| {
            const bits: *u8 = @ptrCast(pad_);
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

    /// Whether gamepad `label` is connected.
    pub fn isConnected(self: *const Controls, label: u16) bool {
        return std.mem.indexOfScalar(?u16, &self.labels, label) != null;
    }

    /// Whether player `p`'s keys play it now: it is on the keyboard, or its gamepad is not
    /// connected.
    pub fn keysPlay(self: *const Controls, p: usize) bool {
        const g = self.layout.players[p].gamepad orelse return true;
        return !self.isConnected(g);
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

    /// The place of a gamepad in `controllers`.
    pub fn slotOf(self: *const Controls, id: platform.ControllerId) ?usize {
        for (self.controllers, 0..) |c, i| if (c == id) return i;
        return null;
    }

    /// The labels of the gamepads connected, the lowest first (nulls last).
    pub fn connected(self: *const Controls) [max_controllers]?u16 {
        var out = self.labels;
        std.mem.sort(?u16, &out, {}, struct {
            fn lt(_: void, a: ?u16, b: ?u16) bool {
                const x = a orelse return false;
                const y = b orelse return true;
                return x < y;
            }
        }.lt);
        return out;
    }

    /// The player of this machine the gamepad at `slot` plays, if any.
    pub fn playerOfSlot(self: *const Controls, slot: usize) ?usize {
        const label = self.labels[slot] orelse return null;
        for (0..self.players()) |p| if (self.layout.players[p].gamepad == label) return p;
        return null;
    }

    fn controllerButton(self: *Controls, e: platform.Event.ControllerButtonEvent, down: bool) bool {
        const slot = self.slotOf(e.controller) orelse return false;
        _ = self.playerOfSlot(slot) orelse return false;
        const button = self.layout.buttonOf(self.labels[slot].?, e.button) orelse return false;
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

fn named(model: []const u8) platform.ControllerInfo {
    return .{ .model = model, .name = model };
}

test "keys, a gamepad and the stick make the pads; a gamepad that comes goes to player 1" {
    var c: Controls = .{};
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .right } } });
    try std.testing.expect(c.pads().pad1.b and c.pads().pad1.right and !c.pads().pad1.a);
    try std.testing.expect(c.pads().pad1.held(.b) and !c.pads().pad1.held(.a));
    try std.testing.expectEqual(@as(u8, 0b0010_1000), @as(u8, @bitCast(c.pads().pad1)));
    // The gamepad, new, is GAMEPAD 1, and goes to player 1, whose keys stop playing it.
    const id: platform.ControllerId = @fromBackingInt(@intCast(7));
    try std.testing.expectEqual(Controls.Added{ .label = 1, .new = true }, c.add(id, named("pad")).?);
    try std.testing.expectEqual(@as(?u16, 1), c.layout.players[0].gamepad);
    try std.testing.expect(!c.pads().pad1.b and !c.uses(.x));
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = id, .button = .b } } });
    try std.testing.expect(c.pads().pad1.c);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_axis = .{ .controller = id, .axis = .left_y, .value = -30000 } } });
    try std.testing.expect(c.pads().pad1.up);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .tab } } });
    try std.testing.expect(c.pads().pad2.start);
    _ = c.handle(.{ .time_ns = 0, .payload = .focus_lost });
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad1)) | @as(u8, @bitCast(c.pads().pad2)));
    // Removed, the gamepad gives player 1 its keys back; player 1 keeps it, for its return.
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_removed = id } });
    try std.testing.expect(c.uses(.x) and c.layout.players[0].gamepad == 1);
}

test "gamepads known by their model: back after a restart, identical ones in order, the buttons by model" {
    var c: Controls = .{};
    const a: platform.ControllerId = @fromBackingInt(@intCast(3));
    const b: platform.ControllerId = @fromBackingInt(@intCast(4));
    const d: platform.ControllerId = @fromBackingInt(@intCast(5));
    try std.testing.expectEqual(@as(u16, 1), c.add(a, named("6B")).?.label);
    try std.testing.expectEqual(@as(u16, 2), c.add(b, named("8BitDo")).?.label);
    // Twice the same: one place.
    try std.testing.expectEqual(Controls.Added{ .label = 2, .new = false }, c.add(b, named("8BitDo")).?);
    // Player 2 takes GAMEPAD 2, its buttons rebound: every 8BitDo's.
    c.layout.assign(1, 2);
    c.layout.padMut(2).?.buttons = .{ .y, .x, .a, .back };
    // A second 6B: GAMEPAD 3, with the buttons of its model.
    c.layout.padMut(1).?.buttons = .{ .b, .a, .x, .start };
    try std.testing.expectEqual(@as(u16, 3), c.add(d, named("6B")).?.label);
    try std.testing.expectEqual([4]platform.ControllerButton{ .b, .a, .x, .start }, c.layout.pad(3).?.buttons);

    // A restart: the same layout, the gamepads coming in another order.
    var r: Controls = .{ .layout = c.layout };
    try std.testing.expectEqual(Controls.Added{ .label = 2, .new = false }, r.add(d, named("8BitDo")).?);
    try std.testing.expectEqual(@as(u16, 1), r.add(a, named("6B")).?.label);
    _ = r.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = d, .button = .back } } });
    try std.testing.expect(r.pads().pad2.start);
    // Player 2 takes GAMEPAD 1: player 1 goes to the keyboard.
    r.layout.assign(1, 1);
    try std.testing.expect(r.layout.players[0].gamepad == null and r.uses(.x));
    var buf: [max_known]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, r.layout.labels(&buf));
    try std.testing.expectEqual([4]?u16{ 1, 2, null, null }, r.connected());
    // GAMEPAD 3 forgotten: its label free for the next new one.
    r.layout.forget(3);
    try std.testing.expectEqual(@as(u16, 3), r.add(b, named("other")).?.label);
}

test "a full list makes room: the unconnected gamepad of the lowest label goes" {
    var l: Layout = .{};
    for (0..max_known) |i| _ = l.identify(&[_]u8{ 'A' + @as(u8, @intCast(i % 26)), 'a' + @as(u8, @intCast(i / 26)) }, "", &.{});
    const got = l.identify("one more", "", &.{ 1, null });
    try std.testing.expect(got.new and l.pad(1) != null and l.pad(2) == null and l.pad(got.label) != null);
}

test "one player: player 1 alone, its keys or its gamepad" {
    var c: Controls = .{ .one_player = true };
    const first: platform.ControllerId = @fromBackingInt(@intCast(3));
    const second: platform.ControllerId = @fromBackingInt(@intCast(4));
    for ([_]platform.ControllerId{ first, second }) |id| _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = id } });
    c.layout.players[1].gamepad = 2;
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

//! The players' controls: the platform's keys and gamepads turned into the 3-button pads the game
//! reads (`Pad`). The pads are sampled once per display tick, as the original reads its pads
//! once a frame. A lost focus releases every held control.
//!
//! Each player has its input method, the keyboard or a gamepad, its keys and its autofire, which
//! the player changes in the settings' INPUT CONFIGURATION (`settings/`). By default player 1 is
//! on the arrows, Z (A: the special attack), X (B: attack), C (C: jump) and Enter (start), player 2
//! on W, A, S, D, F, G, H and Tab; players 3 and 4 (DESIGN.md 10.7, E4) have no keys until the
//! settings give them some. A machine has as many players as input methods (`Controls.players`):
//! the keyboard's, and a gamepad each.
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

/// The players a game may have: the cartridge's two, and the port's third and fourth (DESIGN.md
/// 10.7, E4). A machine's controls keep a layout for each.
pub const max_players = 4;

/// A player's number in the game, from 0 (player 1) to `max_players - 1`.
pub const Player = std.math.IntFittingRange(0, max_players - 1);

/// The pads of a display tick, a pad for each player (a player not in the game: none held).
pub const Pads = struct {
    pad1: Pad = .{},
    pad2: Pad = .{},
    pad3: Pad = .{},
    pad4: Pad = .{},

    /// Player `k`'s pad.
    pub fn of(self: Pads, k: usize) Pad {
        return switch (k) {
            0 => self.pad1,
            1 => self.pad2,
            2 => self.pad3,
            3 => self.pad4,
            else => unreachable,
        };
    }

    pub fn at(self: *Pads, k: usize) *Pad {
        return switch (k) {
            0 => &self.pad1,
            1 => &self.pad2,
            2 => &self.pad3,
            3 => &self.pad4,
            else => unreachable,
        };
    }
};

comptime {
    for (std.enums.values(Button)) |b| std.debug.assert(@bitOffsetOf(Pad, @tagName(b)) == @backingInt(b));
}

/// The buttons a controller's buttons are chosen for; the directions are its d-pad and left stick.
pub const face_buttons = [_]Button{ .a, .b, .c, .start };

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

    /// Whether a key of its is set (players 3 and 4 have none at first).
    pub fn hasKey(self: *const PlayerInput) bool {
        for (self.keys) |k| if (k != no_key) return true;
        return false;
    }
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

    /// The pad button the gamepad button `b` presses on the screens over the game (the settings,
    /// network play's): by the buttons of the gamepad of one of the first `players` players (its
    /// model's), else by the first buttons. Not the d-pad's.
    pub fn faceOf(self: *const Layout, players: usize, b: platform.ControllerButton) ?Button {
        for (self.players[0..players]) |p| {
            const g = self.pad(p.gamepad orelse continue) orelse continue;
            if (std.mem.indexOfScalar(platform.ControllerButton, &g.buttons, b)) |i| return face_buttons[i];
        }
        if (std.mem.indexOfScalar(platform.ControllerButton, &default_buttons, b)) |i| return face_buttons[i];
        return null;
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
    /// No press missed (PLAN item 54): each player's pad as the events last left it (`pads`), the
    /// presses (a button newly down) each of its buttons had since the last read, and the pad the
    /// last read gave (`read`).
    seen: [max_players]u8 = @splat(0),
    presses: [max_players][8]u8 = @splat(@splat(0)),
    reported: [max_players]u8 = @splat(0),

    /// The most presses a button keeps counted between two reads.
    const most_presses = 4;

    pub const max_controllers = 4;

    /// The players this machine's input methods can play (DESIGN.md 10.7, E4): one on a machine
    /// of one player; else the keyboard's (players 1 and 2, and players 3 and 4 once the settings
    /// give them a key) and one more for each gamepad connected, four at most. Which player plays
    /// with which is the settings' (`Layout.assign`: a gamepad given to player 3 sends player 1
    /// back to its keys).
    pub fn players(self: *const Controls) usize {
        if (self.one_player) return 1;
        var n: usize = 2;
        for (self.layout.players[2..]) |p| n += @intFromBool(p.hasKey());
        for (self.labels) |l| n += @intFromBool(l != null);
        return @min(n, max_players);
    }

    /// The players whose keys and gamepads this machine reads: player 1 alone on a machine of one
    /// player, else every one (a player past the game's players presses a pad no one plays).
    fn local(self: *const Controls) usize {
        return if (self.one_player) 1 else max_players;
    }

    /// Takes one platform event; returns whether it concerned the controls. A gamepad that comes
    /// unnamed is of no model (`add` names it).
    pub fn handle(self: *Controls, e: platform.Event) bool {
        const concerned = self.take(e);
        if (concerned) self.notePresses();
        return concerned;
    }

    /// Counts the presses the last changes made: a button of a player's pad newly down, whatever
    /// pressed it (a key, a gamepad's button, its stick).
    fn notePresses(self: *Controls) void {
        const now = self.pads();
        for (0..max_players) |p| {
            const bits: u8 = @bitCast(now.of(p));
            const new = bits & ~self.seen[p];
            for (0..8) |b| if (new & (@as(u8, 1) << @intCast(b)) != 0) {
                self.presses[p][b] = @min(self.presses[p][b] + 1, most_presses);
            };
            self.seen[p] = bits;
        }
    }

    fn take(self: *Controls, e: platform.Event) bool {
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

    /// Releases every held control, as a lost focus does, and forgets the presses not read yet.
    pub fn release(self: *Controls) void {
        self.keys = @splat(0);
        self.pad_buttons = @splat(0);
        self.stick = @splat(0);
        self.seen = @splat(0);
        self.presses = @splat(@splat(0));
    }

    /// The pads as the players hold them: each player's keys (while they play it) and its
    /// gamepad's buttons and stick.
    pub fn pads(self: *const Controls) Pads {
        var bits: [max_players]u8 = @splat(0);
        for (0..self.local()) |p| if (self.keysPlay(p)) {
            bits[p] = self.keys[p];
        };
        for (0..max_controllers) |slot| {
            if (self.playerOfSlot(slot)) |p| bits[p] |= self.pad_buttons[slot] | self.stick[slot];
        }
        var out: Pads = .{};
        for (bits, 0..) |b, p| out.at(p).* = @bitCast(b);
        return out;
    }

    /// The pads as the game reads them at display tick `tick`, no press missed (PLAN item 54): a
    /// button with a press counted since the last read shows down (the press read), unless the
    /// last read showed it down, when it shows up first, so that the press is a new one at the
    /// read after (a button let go and pressed again between two reads); without one, the button
    /// as it is held. A press whose button was let go before the read is so read once, then up;
    /// several between two reads come one after another; a press that spans reads reads as the
    /// pads hold it. Then the attack button (`attack`, by the options' CONTROL) of a player with
    /// autofire held and released in turn while it is held.
    pub fn read(self: *Controls, tick: u32, attack: Button) Pads {
        // A change no event brought (the layout changed by the settings) counts as one.
        self.notePresses();
        var out: Pads = .{};
        for (0..max_players) |p| {
            var bits: u8 = 0;
            for (0..8) |b| {
                const mask = @as(u8, 1) << @intCast(b);
                if (self.presses[p][b] > 0) {
                    if (self.reported[p] & mask == 0) {
                        bits |= mask;
                        self.presses[p][b] -= 1;
                    }
                } else bits |= self.seen[p] & mask;
            }
            self.reported[p] = bits;
            out.at(p).* = @bitCast(bits);
        }
        for (0..max_players) |p| {
            const bits: *u8 = @ptrCast(out.at(p));
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
        return place.player < self.local() and self.keysPlay(place.player);
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
        for (0..self.local()) |p| if (self.layout.players[p].gamepad == label) return p;
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
        return self.moveStick(slot, e);
    }

    /// Gamepad `e`'s stick moved, any gamepad connected (a player's or not): the d-pad button of
    /// the direction it holds now and did not, if any. The screens over the game take the stick
    /// as the d-pad (a pad's d-pad may come as a stick: SDL's generic mapping, a browser's pad
    /// without the standard mapping).
    pub fn stickPress(self: *Controls, e: platform.Event.ControllerAxisEvent) ?platform.ControllerButton {
        const slot = self.slotOf(e.controller) orelse return null;
        const before = self.stick[slot];
        if (!self.moveStick(slot, e)) return null;
        const pressed = self.stick[slot] & ~before;
        const directions = [_]Button{ .up, .down, .left, .right };
        const dpad = [_]platform.ControllerButton{ .dpad_up, .dpad_down, .dpad_left, .dpad_right };
        for (directions, dpad) |d, b| if (pressed & @as(u8, 1) << @backingInt(d) != 0) return b;
        return null;
    }

    /// The left stick of the gamepad at `slot` moved to `e`: the directions it holds. False for
    /// another axis.
    fn moveStick(self: *Controls, slot: usize, e: platform.Event.ControllerAxisEvent) bool {
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

test "the machine's players: the keyboard's two, a gamepad each, players 3 and 4 by their keys" {
    var c: Controls = .{};
    try std.testing.expectEqual(@as(usize, 2), c.players());
    const first: platform.ControllerId = @fromBackingInt(@intCast(3));
    const second: platform.ControllerId = @fromBackingInt(@intCast(4));
    // The first gamepad goes to player 1, as ever; it counts for a third player all the same.
    _ = c.add(first, named("6B"));
    try std.testing.expect(c.players() == 3 and c.layout.players[0].gamepad == 1);
    _ = c.add(second, named("6B"));
    try std.testing.expectEqual(@as(usize, 4), c.players());
    // Given to players 3 and 4, the gamepads fill their pads; player 1 is back on its keys.
    c.layout.assign(2, 1);
    c.layout.assign(3, 2);
    try std.testing.expect(c.layout.players[0].gamepad == null and c.uses(.x));
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = first, .button = .start } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = second, .button = .x } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x } } });
    const pads_ = c.pads();
    try std.testing.expect(pads_.pad3.start and pads_.pad4.a and pads_.pad1.b);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(pads_.pad2)));
    // Gone, the gamepads leave two players, but player 3 with a key of its own.
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_removed = first } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_removed = second } });
    try std.testing.expectEqual(@as(usize, 2), c.players());
    c.layout.players[2].keys[@backingInt(Button.start)] = .i;
    try std.testing.expectEqual(@as(usize, 3), c.players());
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .i } } });
    try std.testing.expect(c.pads().pad3.start);
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

test "the screens over the game: any gamepad's stick as its d-pad" {
    var c: Controls = .{};
    const id: platform.ControllerId = @fromBackingInt(@intCast(3));
    _ = c.add(id, named("6B"));
    // Its pad's d-pad as a stick (SDL's generic mapping): a press as it goes past the dead zone,
    // none while it stays, another once let go and pushed again; the other axes none.
    const at = struct {
        fn f(x: platform.ControllerId, a: platform.ControllerAxis, v: i16) platform.Event.ControllerAxisEvent {
            return .{ .controller = x, .axis = a, .value = v };
        }
    }.f;
    try std.testing.expectEqual(@as(?platform.ControllerButton, .dpad_down), c.stickPress(at(id, .left_y, 32767)));
    try std.testing.expectEqual(@as(?platform.ControllerButton, null), c.stickPress(at(id, .left_y, 32000)));
    try std.testing.expectEqual(@as(?platform.ControllerButton, null), c.stickPress(at(id, .left_y, 0)));
    try std.testing.expectEqual(@as(?platform.ControllerButton, .dpad_left), c.stickPress(at(id, .left_x, -32768)));
    try std.testing.expectEqual(@as(?platform.ControllerButton, null), c.stickPress(at(id, .right_x, 32767)));
    // A gamepad no player has: its stick too.
    c.layout.assign(0, null);
    try std.testing.expectEqual(@as(?platform.ControllerButton, .dpad_up), c.stickPress(at(id, .left_y, -32768)));
}

test "the screens over the game: a gamepad's buttons, the first ones or its player's" {
    var l: Layout = .{};
    _ = l.identify("6B", "6B", &.{});
    try std.testing.expectEqual(@as(?Button, .a), l.faceOf(2, .x));
    // Player 1 has it, its buttons rebound: its model's.
    l.assign(0, 1);
    l.padMut(1).?.buttons = .{ .y, .x, .a, .back };
    try std.testing.expectEqual(@as(?Button, .a), l.faceOf(2, .y));
    try std.testing.expectEqual(@as(?Button, .start), l.faceOf(2, .back));
    try std.testing.expectEqual(@as(?Button, .b), l.faceOf(2, .x));
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

/// The controls' event `payload` at time 0.
fn ev(payload: platform.Event.Payload) platform.Event {
    return .{ .time_ns = 0, .payload = payload };
}

/// Player 1's B (key X) at the next `n` reads.
fn bReads(c: *Controls, comptime n: usize) [n]bool {
    var out: [n]bool = undefined;
    for (&out, 0..) |*x, t| x.* = c.read(@intCast(t), .b).pad1.b;
    return out;
}

test "no press missed: a tap between two reads is read once, then let go" {
    var c: Controls = .{};
    _ = c.handle(ev(.{ .key_down = .{ .key = .x } }));
    _ = c.handle(ev(.{ .key_up = .{ .key = .x } }));
    try std.testing.expectEqualSlices(bool, &.{ true, false, false }, &bReads(&c, 3));
}

test "no press missed: let go and pressed again between two reads, it is let go at one, then down" {
    var c: Controls = .{};
    _ = c.handle(ev(.{ .key_down = .{ .key = .x } }));
    try std.testing.expectEqualSlices(bool, &.{ true, true }, &bReads(&c, 2));
    _ = c.handle(ev(.{ .key_up = .{ .key = .x } }));
    _ = c.handle(ev(.{ .key_down = .{ .key = .x } }));
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, &bReads(&c, 3));
}

test "no press missed: several taps between two reads come one after another" {
    var c: Controls = .{};
    for (0..3) |_| {
        _ = c.handle(ev(.{ .key_down = .{ .key = .x } }));
        _ = c.handle(ev(.{ .key_up = .{ .key = .x } }));
    }
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, false, true, false, false }, &bReads(&c, 7));
}

test "no press missed: a held button and a press spanning reads read as the pads hold them" {
    var c: Controls = .{};
    _ = c.handle(ev(.{ .key_down = .{ .key = .x } }));
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &bReads(&c, 3));
    _ = c.handle(ev(.{ .key_up = .{ .key = .x } }));
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &bReads(&c, 2));
    // Each read as `pads` holds them, but for the presses not read yet.
    _ = c.handle(ev(.{ .key_down = .{ .key = .right } }));
    for (0..3) |t| try std.testing.expectEqual(@as(u8, @bitCast(c.pads().pad1)), @as(u8, @bitCast(c.read(@intCast(t), .b).pad1)));
}

test "no press missed: a gamepad's button and its stick, a tap each between two reads" {
    var c: Controls = .{};
    const id: platform.ControllerId = @fromBackingInt(@intCast(7));
    _ = c.add(id, named("pad")).?;
    _ = c.handle(ev(.{ .controller_button_down = .{ .controller = id, .button = .b } }));
    _ = c.handle(ev(.{ .controller_button_up = .{ .controller = id, .button = .b } }));
    _ = c.handle(ev(.{ .controller_axis = .{ .controller = id, .axis = .left_y, .value = -30000 } }));
    _ = c.handle(ev(.{ .controller_axis = .{ .controller = id, .axis = .left_y, .value = 0 } }));
    const first = c.read(0, .b).pad1;
    try std.testing.expect(first.c and first.up);
    const next = c.read(1, .b).pad1;
    try std.testing.expect(!next.c and !next.up);
    // A lost focus forgets the presses not read yet.
    _ = c.handle(ev(.{ .key_down = .{ .key = .tab } }));
    _ = c.handle(ev(.{ .key_up = .{ .key = .tab } }));
    _ = c.handle(ev(.focus_lost));
    try std.testing.expect(!c.read(2, .b).pad2.start);
}

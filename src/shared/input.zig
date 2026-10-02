//! The players' controls: the platform's keys and controllers turned into the two 3-button pads
//! the game reads (`Pad`). The pads are sampled once per display tick, as the original reads its
//! pads once a frame. A lost focus releases every held control.
//!
//! The default layout: pad 1 on the arrows, Z (A: the special attack), X (B: attack), C (C:
//! jump) and Enter (start); pad 2 on W, A, S, D, F, G, H and Tab. The first two controllers are
//! pads 1 and 2: the d-pad or the left stick, X (A), A (B), B (C), start. The player changes the
//! layout in the settings (`settings/`, PLAN item 13): each pad button's key, the controllers'
//! buttons for A, B, C and start, and which pad the first controller plays.
//!
//! A machine with one player (network play, where each machine has its player, and the browser
//! page always) plays pad 1 with pad 1's keys and every controller, whatever pad the first
//! controller would play: network play sends pad 1 alone. Pad 2's keys do nothing there.
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

const KeyBinding = struct { key: platform.Key, pad: u1, button: Button };

pub const default_keys = [_]KeyBinding{
    .{ .key = .up, .pad = 0, .button = .up },
    .{ .key = .down, .pad = 0, .button = .down },
    .{ .key = .left, .pad = 0, .button = .left },
    .{ .key = .right, .pad = 0, .button = .right },
    .{ .key = .z, .pad = 0, .button = .a },
    .{ .key = .x, .pad = 0, .button = .b },
    .{ .key = .c, .pad = 0, .button = .c },
    .{ .key = .enter, .pad = 0, .button = .start },
    .{ .key = .w, .pad = 1, .button = .up },
    .{ .key = .s, .pad = 1, .button = .down },
    .{ .key = .a, .pad = 1, .button = .left },
    .{ .key = .d, .pad = 1, .button = .right },
    .{ .key = .f, .pad = 1, .button = .a },
    .{ .key = .g, .pad = 1, .button = .b },
    .{ .key = .h, .pad = 1, .button = .c },
    .{ .key = .tab, .pad = 1, .button = .start },
};

/// Which keys and controller buttons press which pad's buttons.
pub const Layout = struct {
    /// Each pad's key for each button, by `Button`.
    keys: [2][8]platform.Key = blk: {
        var keys: [2][8]platform.Key = undefined;
        for (default_keys) |b| keys[b.pad][@backingInt(b.button)] = b.key;
        break :blk keys;
    },
    /// The controller buttons of A, B, C and start (`face_buttons`), the same on both controllers.
    buttons: [face_buttons.len]platform.ControllerButton = .{ .x, .a, .b, .start },
    /// The pad the first controller plays; the second controller plays the other.
    first_pad: u1 = 0,

    pub const Place = struct { pad: u1, button: Button };

    /// The pad button `key` presses, if any.
    pub fn find(self: *const Layout, key: platform.Key) ?Place {
        for (self.keys, 0..) |pad, p| for (pad, 0..) |k, b| if (k == key) {
            return .{ .pad = @intCast(p), .button = @fromBackingInt(@as(u3, @intCast(b))) };
        };
        return null;
    }

    /// The pad button a controller button presses (of either controller), if any.
    pub fn buttonOf(self: *const Layout, button: platform.ControllerButton) ?Button {
        return switch (button) {
            .dpad_up => .up,
            .dpad_down => .down,
            .dpad_left => .left,
            .dpad_right => .right,
            else => for (self.buttons, face_buttons) |b, face| {
                if (b == button) break face;
            } else null,
        };
    }
};

/// The left stick's dead zone: beyond it, the stick is a direction.
const stick_threshold: i16 = 16384;

pub const Controls = struct {
    layout: Layout = .{},
    /// One player on this machine: pad 1's keys and every controller play pad 1.
    one_player: bool = false,
    /// The buttons held through the keyboard, per pad.
    keys: [2]u8 = .{ 0, 0 },
    /// The buttons held through each controller, by its place in `controllers`: the d-pad and
    /// buttons, and the stick. Each controller keeps its own, so that one's release or removal
    /// does not let go of what another holds on the same pad.
    pad_buttons: [max_controllers]u8 = @splat(0),
    stick: [max_controllers]u8 = @splat(0),
    /// The controllers in the order they came: the first two are the two pads' (`padOf`); with
    /// one player, all play pad 1.
    controllers: [max_controllers]?platform.ControllerId = @splat(null),

    pub const max_controllers = 4;

    /// Takes one platform event; returns whether it concerned the controls.
    pub fn handle(self: *Controls, e: platform.Event) bool {
        switch (e.payload) {
            .key_down => |k| return self.key(k.key, true),
            .key_up => |k| return self.key(k.key, false),
            .controller_added => |id| {
                for (&self.controllers) |*c| if (c.* == null) {
                    c.* = id;
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
        self.keys = .{ 0, 0 };
        self.pad_buttons = @splat(0);
        self.stick = @splat(0);
    }

    /// The pads as the game reads them at this display tick: the keys, and each controller's
    /// buttons on the pad it plays.
    pub fn pads(self: *const Controls) Pads {
        var bits = self.keys;
        for (0..max_controllers) |slot| {
            if (self.padOfSlot(slot)) |pad| bits[pad] |= self.pad_buttons[slot] | self.stick[slot];
        }
        return .{ .pad1 = @bitCast(bits[0]), .pad2 = @bitCast(bits[1]) };
    }

    /// Whether `key` presses a pad's button here (with one player, pad 1's only).
    pub fn uses(self: *const Controls, k: platform.Key) bool {
        const place = self.layout.find(k) orelse return false;
        return !self.one_player or place.pad == 0;
    }

    fn key(self: *Controls, k: platform.Key, down: bool) bool {
        if (!self.uses(k)) return false;
        const place = self.layout.find(k).?;
        set(&self.keys[place.pad], place.button, down);
        return true;
    }

    /// The place of a controller in `controllers`.
    fn slotOf(self: *const Controls, id: platform.ControllerId) ?usize {
        for (self.controllers, 0..) |c, i| if (c == id) return i;
        return null;
    }

    /// The pad the controller at `slot` plays: the first added plays `layout.first_pad`, the
    /// second the other, and the others none; with one player, every controller plays pad 1.
    fn padOfSlot(self: *const Controls, slot: usize) ?usize {
        if (self.controllers[slot] == null) return null;
        if (self.one_player) return 0;
        return if (slot < 2) slot ^ self.layout.first_pad else null;
    }

    /// The place of a controller that plays a pad.
    fn playingSlot(self: *const Controls, id: platform.ControllerId) ?usize {
        const slot = self.slotOf(id) orelse return null;
        _ = self.padOfSlot(slot) orelse return null;
        return slot;
    }

    fn controllerButton(self: *Controls, e: platform.Event.ControllerButtonEvent, down: bool) bool {
        const slot = self.playingSlot(e.controller) orelse return false;
        const button = self.layout.buttonOf(e.button) orelse return false;
        set(&self.pad_buttons[slot], button, down);
        return true;
    }

    fn axis(self: *Controls, e: platform.Event.ControllerAxisEvent) bool {
        const slot = self.playingSlot(e.controller) orelse return false;
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

test "keys, controllers and the stick make the pads" {
    var c: Controls = .{};
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .right } } });
    try std.testing.expect(c.pads().pad1.b and c.pads().pad1.right and !c.pads().pad1.a);
    try std.testing.expect(c.pads().pad1.held(.b) and !c.pads().pad1.held(.a));
    try std.testing.expectEqual(@as(u8, 0b0010_1000), @as(u8, @bitCast(c.pads().pad1)));
    const id: platform.ControllerId = @fromBackingInt(@intCast(7));
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = id } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = id, .button = .b } } });
    try std.testing.expect(c.pads().pad1.c);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_axis = .{ .controller = id, .axis = .left_y, .value = -30000 } } });
    try std.testing.expect(c.pads().pad1.up);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .tab } } });
    try std.testing.expect(c.pads().pad2.start);
    _ = c.handle(.{ .time_ns = 0, .payload = .focus_lost });
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad1)));
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad2)));
}

test "a layout of other keys, other buttons and the controllers swapped" {
    var c: Controls = .{};
    c.layout.keys[0][@backingInt(Button.b)] = .space;
    c.layout.keys[1][@backingInt(Button.start)] = .enter;
    c.layout.keys[0][@backingInt(Button.start)] = .tab;
    c.layout.buttons = .{ .y, .x, .a, .back };
    c.layout.first_pad = 1;
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .space } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .enter } } });
    try std.testing.expect(c.pads().pad1.b and c.pads().pad2.start and !c.pads().pad1.start);
    try std.testing.expect(!c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x } } }));
    const first: platform.ControllerId = @fromBackingInt(@intCast(3));
    const second: platform.ControllerId = @fromBackingInt(@intCast(4));
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = first } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = second } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = first, .button = .back } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = second, .button = .y } } });
    try std.testing.expect(c.pads().pad2.start and c.pads().pad1.a);
    try std.testing.expect(!c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = second, .button = .b } } }));
    // The first controller, removed, releases its pad (pad 2), not the second's.
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_removed = first } });
    try std.testing.expect(c.pads().pad1.a);
    c.release();
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad1)) | @as(u8, @bitCast(c.pads().pad2)));
}

test "two controllers on one pad: one's release or removal keeps what the other holds" {
    var c: Controls = .{ .one_player = true };
    const first: platform.ControllerId = @fromBackingInt(@intCast(3));
    const second: platform.ControllerId = @fromBackingInt(@intCast(4));
    for ([_]platform.ControllerId{ first, second }) |id| _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = id } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = first, .button = .a } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_axis = .{ .controller = first, .axis = .left_x, .value = 30000 } } });
    // The second controller presses and lets go of the same button, and its stick rests.
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = second, .button = .a } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_up = .{ .controller = second, .button = .a } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_axis = .{ .controller = second, .axis = .left_x, .value = 0 } } });
    try std.testing.expect(c.pads().pad1.b and c.pads().pad1.right);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_removed = second } });
    try std.testing.expect(c.pads().pad1.b and c.pads().pad1.right);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_removed = first } });
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad1)));
}

test "one player: every controller and pad 1's keys play pad 1, whatever the first controller's pad" {
    var c: Controls = .{ .one_player = true };
    c.layout.first_pad = 1;
    const first: platform.ControllerId = @fromBackingInt(@intCast(3));
    const second: platform.ControllerId = @fromBackingInt(@intCast(4));
    const third: platform.ControllerId = @fromBackingInt(@intCast(5));
    for ([_]platform.ControllerId{ first, second, third }) |id| _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = id } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = first, .button = .start } } });
    try std.testing.expect(c.pads().pad1.start);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = third, .button = .dpad_left } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_axis = .{ .controller = second, .axis = .left_y, .value = -30000 } } });
    try std.testing.expect(c.pads().pad1.left and c.pads().pad1.up);
    // Pad 2's keys do nothing; pad 1's do.
    try std.testing.expect(!c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .tab } } }));
    try std.testing.expect(c.uses(.enter) and !c.uses(.tab) and !c.uses(.w));
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .x } } });
    try std.testing.expect(c.pads().pad1.b);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(c.pads().pad2)));
    // Two players: the first controller plays pad 2 as the layout says, the third none.
    c.one_player = false;
    c.release();
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = first, .button = .start } } });
    try std.testing.expect(c.pads().pad2.start and !c.pads().pad1.start);
    try std.testing.expect(!c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = third, .button = .start } } }));
    // A controller past the first two, removed, frees its place.
    try std.testing.expect(c.handle(.{ .time_ns = 0, .payload = .{ .controller_removed = third } }));
    try std.testing.expect(c.pads().pad2.start);
}

//! The browser's gamepads (the Gamepad API) as the platform's controllers. The page polls
//! `navigator.getGamepads()` at each animation frame and reports each change by the gamepad's
//! index and the numbers of the W3C "standard" mapping; this table is the one place that turns
//! them into project buttons and axes, so a browser pad drives the game as SDL's game controller
//! does natively (the bottom face button is `a`, the d-pad the `dpad_*` buttons).
const std = @import("std");
const sorz = @import("sorz");
const platform = sorz.platform;

/// The buttons of the standard mapping, by index: the four face buttons (bottom, right, left,
/// top), the shoulders, the triggers (6 and 7, which are axes here), back, start, the sticks'
/// clicks, the d-pad (up, down, left, right) and the guide button.
pub fn button(index: u32) ?platform.ControllerButton {
    return switch (index) {
        0 => .a,
        1 => .b,
        2 => .x,
        3 => .y,
        4 => .left_shoulder,
        5 => .right_shoulder,
        8 => .back,
        9 => .start,
        10 => .left_stick,
        11 => .right_stick,
        12 => .dpad_up,
        13 => .dpad_down,
        14 => .dpad_left,
        15 => .dpad_right,
        16 => .guide,
        else => null,
    };
}

/// The standard mapping's triggers, which it reports as analog buttons.
pub fn trigger(index: u32) ?platform.ControllerAxis {
    return switch (index) {
        6 => .trigger_left,
        7 => .trigger_right,
        else => null,
    };
}

/// The axes of the standard mapping: the left stick (x, y), then the right one.
pub fn axis(index: u32) ?platform.ControllerAxis {
    return switch (index) {
        0 => .left_x,
        1 => .left_y,
        2 => .right_x,
        3 => .right_y,
        else => null,
    };
}

/// The controller of the gamepad at `index` of `navigator.getGamepads()`. The index stays the
/// gamepad's while it is connected, as an SDL instance id does.
pub fn controller(index: u32) platform.ControllerId {
    return @fromBackingInt(index);
}

/// A stick's position, -1 to 1 in the browser, in SDL's units (-32768 to 32767). The page passes
/// the value times 32767, rounded.
pub fn stickValue(scaled: i32) i16 {
    return @intCast(std.math.clamp(scaled, -32768, 32767));
}

/// A trigger's pressure, 0 to 1 in the browser, in SDL's units (0 to 32767).
pub fn triggerValue(scaled: i32) i16 {
    return @intCast(std.math.clamp(scaled, 0, 32767));
}

test "the standard mapping gives SDL's buttons: the bottom face button is a, the d-pad its own" {
    try std.testing.expectEqual(platform.ControllerButton.a, button(0).?);
    try std.testing.expectEqual(platform.ControllerButton.x, button(2).?);
    try std.testing.expectEqual(platform.ControllerButton.start, button(9).?);
    try std.testing.expectEqual(platform.ControllerButton.dpad_left, button(14).?);
    try std.testing.expectEqual(platform.ControllerButton.guide, button(16).?);
    try std.testing.expect(button(6) == null and button(17) == null);
    try std.testing.expectEqual(platform.ControllerAxis.trigger_right, trigger(7).?);
    try std.testing.expect(trigger(5) == null);
    try std.testing.expectEqual(platform.ControllerAxis.left_y, axis(1).?);
    try std.testing.expect(axis(4) == null);
    try std.testing.expectEqual(@as(i16, -32768), stickValue(-40000));
    try std.testing.expectEqual(@as(i16, 0), triggerValue(-5));
}

test "a browser pad drives the game's pad as a native controller does" {
    var c: sorz.input.Controls = .{};
    const id = controller(0);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_added = id } });
    // The bottom face button attacks (B), the left one is the special (A), the right one jumps.
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = id, .button = button(0).? } } });
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_button_down = .{ .controller = id, .button = button(15).? } } });
    try std.testing.expect(c.pads().pad1.b and c.pads().pad1.right and !c.pads().pad1.a);
    _ = c.handle(.{ .time_ns = 0, .payload = .{ .controller_axis = .{ .controller = id, .axis = axis(0).?, .value = stickValue(-32767) } } });
    try std.testing.expect(c.pads().pad1.left);
}

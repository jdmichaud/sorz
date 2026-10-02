//! The native binaries' log lines, on standard error, one form for all: the program's name, the
//! scope when there is one, the level when it is not news, then the message:
//!
//!     sorz-sdl: settings: kept, window scale 3, settings key f1
//!     sorz-sdl: netplay: hosting at 0.0.0.0:8080; waiting for the guest
//!     sorz-sdl: warning: the settings cannot be saved: AccessDenied
//!
//! Each binary makes `logFn` its `std_options.logFn` and sets `program` first thing. The hosts'
//! own lines and the shared code's (`std.log`, scoped or not) then read alike. The browser's
//! module has its own, to the console (src/web/main.zig).
const std = @import("std");

/// The name the lines start with.
pub var program: []const u8 = "sorz";

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    write(level, scope, format, args, stderr) catch {};
}

fn write(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
    t: std.Io.Terminal,
) std.Io.Writer.Error!void {
    try t.writer.print("{s}: ", .{program});
    if (scope != .default) try t.writer.writeAll(@tagName(scope) ++ ": ");
    const word: ?[]const u8 = switch (level) {
        .err => "error",
        .warn => "warning",
        .info => null,
        .debug => "debug",
    };
    if (word) |w| {
        t.setColor(if (level == .err) .red else if (level == .warn) .yellow else .dim) catch {};
        t.setColor(.bold) catch {};
        try t.writer.print("{s}: ", .{w});
        t.setColor(.reset) catch {};
    }
    try t.writer.print(format ++ "\n", args);
}

test "a line: the program, the scope, the level when it is not news" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const t: std.Io.Terminal = .{ .writer = &w, .mode = .no_color };
    program = "sorz-test";
    defer program = "sorz";
    try write(.info, .default, "settings: kept, scale {d}", .{3}, t);
    try write(.info, .netplay, "hosting at {s}", .{"0.0.0.0:8080"}, t);
    try write(.warn, .default, "cannot save: {s}", .{"AccessDenied"}, t);
    try write(.err, .relay, "a page broke the protocol", .{}, t);
    try std.testing.expectEqualStrings(
        \\sorz-test: settings: kept, scale 3
        \\sorz-test: netplay: hosting at 0.0.0.0:8080
        \\sorz-test: warning: cannot save: AccessDenied
        \\sorz-test: relay: error: a page broke the protocol
        \\
    , w.buffered());
}

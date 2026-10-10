//! A picture the game presents without its scenes (DESIGN.md 3.2): the console's 320 x 224
//! pixels, four bytes each (R, G, B, A). The test pattern (screens/test_pattern.zig) draws its
//! rectangles here, and the overlays go over it, black, when no scene's picture is under them;
//! the scenes' pictures are the renderer's own (view.zig, render/compose.zig). Only what changed
//! is drawn again (DESIGN.md 10.5 R4), and the picture's hash is worked out when asked, not with
//! each frame.
const std = @import("std");
const platform = @import("platform.zig");

pub const width: u32 = 320;
pub const height: u32 = 224;

pub const Rgb = [3]u8;

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Picture = struct {
    /// R, G, B, A bytes per pixel, rows from the top; A is 255.
    pixels: []u8,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Picture {
        const pixels = try allocator.alloc(u8, width * height * platform.RgbaFrame.bytes_per_pixel);
        @memset(pixels, 255);
        return .{ .pixels = pixels };
    }

    pub fn deinit(self: *Picture, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }

    /// Fills `r` (cut at the picture's edges) with `colour`.
    pub fn fill(self: *Picture, r: Rect, colour: Rgb) void {
        const x_end = @min(r.x + r.w, width);
        const y_end = @min(r.y + r.h, height);
        if (r.x >= x_end) return;
        var y = r.y;
        while (y < y_end) : (y += 1) {
            const row = self.pixels[(y * width + r.x) * 4 .. (y * width + x_end) * 4];
            var i: usize = 0;
            while (i < row.len) : (i += 4) row[i..][0..3].* = colour;
        }
    }

    /// The colour of the pixel at (x, y).
    pub fn at(self: *const Picture, x: u32, y: u32) Rgb {
        return self.pixels[(y * width + x) * 4 ..][0..3].*;
    }

    pub fn frame(self: *const Picture) platform.RgbaFrame {
        return .{ .width = width, .height = height, .stride = width * 4, .pixels = self.pixels };
    }

    /// The hash of the pixels (FNV-1a, 64 bits), which the hosts and the checks compare.
    pub fn hash(self: *const Picture) u64 {
        return std.hash.Fnv1a_64.hash(self.pixels);
    }
};

test "a rectangle is filled within the picture, and the alpha stays" {
    var pic = try Picture.init(std.testing.allocator);
    defer pic.deinit(std.testing.allocator);
    const before = pic.hash();
    pic.fill(.{ .x = 316, .y = 220, .w = 10, .h = 10 }, .{ 1, 2, 3 });
    try std.testing.expectEqual(Rgb{ 1, 2, 3 }, pic.at(319, 223));
    try std.testing.expectEqual(Rgb{ 255, 255, 255 }, pic.at(315, 223));
    try std.testing.expectEqual(@as(u8, 255), pic.pixels[pic.pixels.len - 1]);
    try std.testing.expect(pic.hash() != before);
    pic.fill(.{ .x = 400, .y = 0, .w = 5, .h = 5 }, .{ 0, 0, 0 });
}

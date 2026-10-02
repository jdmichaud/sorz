//! The samples' files: WAV, PCM, 8-bit unsigned, mono, the DAC's values as they are.
const std = @import("std");

pub const Error = error{ BadWav, OutOfMemory };

/// The file of `values` at `rate` frames a second.
pub fn write(gpa: std.mem.Allocator, values: []const u8, rate: u32) error{OutOfMemory}![]u8 {
    const out = try gpa.alloc(u8, 44 + values.len + values.len % 2);
    const le = struct {
        fn u32_(b: []u8, at: usize, v: u32) void {
            std.mem.writeInt(u32, b[at..][0..4], v, .little);
        }
        fn u16_(b: []u8, at: usize, v: u16) void {
            std.mem.writeInt(u16, b[at..][0..2], v, .little);
        }
    };
    @memcpy(out[0..4], "RIFF");
    le.u32_(out, 4, @intCast(out.len - 8));
    @memcpy(out[8..16], "WAVEfmt ");
    le.u32_(out, 16, 16);
    le.u16_(out, 20, 1); // PCM
    le.u16_(out, 22, 1); // mono
    le.u32_(out, 24, rate);
    le.u32_(out, 28, rate); // bytes a second
    le.u16_(out, 32, 1); // bytes a frame
    le.u16_(out, 34, 8); // bits a sample
    @memcpy(out[36..40], "data");
    le.u32_(out, 40, @intCast(values.len));
    @memcpy(out[44..][0..values.len], values);
    if (values.len % 2 != 0) out[out.len - 1] = 0;
    return out;
}

/// The values of an 8-bit mono PCM file (borrowed from `bytes`), and its rate.
pub fn read(bytes: []const u8) Error!struct { values: []const u8, rate: u32 } {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.BadWav;
    var at: usize = 12;
    var rate: ?u32 = null;
    while (at + 8 <= bytes.len) {
        const id = bytes[at..][0..4];
        const size = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        const body = at + 8;
        if (size > bytes.len - body) return error.BadWav;
        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16) return error.BadWav;
            const f = bytes[body..][0..16];
            if (std.mem.readInt(u16, f[0..2], .little) != 1 or std.mem.readInt(u16, f[2..4], .little) != 1 or std.mem.readInt(u16, f[14..16], .little) != 8) return error.BadWav;
            rate = std.mem.readInt(u32, f[4..8], .little);
        } else if (std.mem.eql(u8, id, "data")) {
            return .{ .values = bytes[body..][0..size], .rate = rate orelse return error.BadWav };
        }
        at = body + size + size % 2;
    }
    return error.BadWav;
}

test "a sample's values written and read back" {
    const values = [_]u8{ 0x80, 0x81, 0x7F };
    const file = try write(std.testing.allocator, &values, 8000);
    defer std.testing.allocator.free(file);
    const back = try read(file);
    try std.testing.expectEqualSlices(u8, &values, back.values);
    try std.testing.expectEqual(@as(u32, 8000), back.rate);
    try std.testing.expectError(error.BadWav, read(file[0..30]));
}

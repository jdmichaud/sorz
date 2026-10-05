//! The sound a run played, as a 16-bit PCM WAV file (`--wav`).
const std = @import("std");

/// `pcm`, interleaved frames of `channels` samples at `rate`, as a WAV file's bytes (owned by
/// the caller).
pub fn encode(gpa: std.mem.Allocator, pcm: []const i16, channels: u16, rate: u32) ![]u8 {
    const data_bytes: u32 = @intCast(pcm.len * 2);
    const bytes = try gpa.alloc(u8, 44 + data_bytes);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_bytes, .little);
    @memcpy(bytes[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], channels, .little);
    std.mem.writeInt(u32, bytes[24..28], rate, .little);
    std.mem.writeInt(u32, bytes[28..32], rate * channels * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], channels * 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);
    for (pcm, 0..) |v, i| std.mem.writeInt(i16, bytes[44 + 2 * i ..][0..2], v, .little);
    return bytes;
}

/// `encode`, written to `path`.
pub fn write(gpa: std.mem.Allocator, io: std.Io, path: []const u8, pcm: []const i16, channels: u16, rate: u32) !void {
    const bytes = try encode(gpa, pcm, channels, rate);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

test "a WAV file's header and its samples" {
    const b = try encode(std.testing.allocator, &.{ 1, -2 }, 2, 48000);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("RIFF", b[0..4]);
    try std.testing.expectEqual(@as(u32, 48000 * 4), std.mem.readInt(u32, b[28..32], .little));
    try std.testing.expectEqual(@as(i16, -2), std.mem.readInt(i16, b[46..48], .little));
}

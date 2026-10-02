//! The ROM the extractor reads: the one version sorz follows (graphics port map: SHA-256
//! `dd44f120…95c0`), checked by its size and digest before anything is read, and the big-endian
//! readers of its tables.
const std = @import("std");

pub const size = 0x80000;
pub const sha256 = "dd44f120446654bb91c448762f3e0cd0d9b034f35d0e3266a4dc34402ada95c0";

pub const Error = error{WrongRom};

/// Checks the ROM's size and digest: another dump or version is refused, not guessed at.
pub fn check(rom: []const u8) Error!void {
    if (rom.len != size) return error.WrongRom;
    if (!std.mem.eql(u8, &digest(rom), sha256)) return error.WrongRom;
}

/// The SHA-256 of `bytes` in lower-case hex.
pub fn digest(bytes: []const u8) [64]u8 {
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    return std.fmt.bytesToHex(sum, .lower);
}

pub fn u16be(rom: []const u8, a: u32) u16 {
    return std.mem.readInt(u16, rom[a..][0..2], .big);
}

pub fn u32be(rom: []const u8, a: u32) u32 {
    return std.mem.readInt(u32, rom[a..][0..4], .big);
}

pub fn s16be(rom: []const u8, a: u32) i16 {
    return @bitCast(u16be(rom, a));
}

test "a ROM of another size or digest is refused" {
    const gpa = std.testing.allocator;
    const fake = try gpa.alloc(u8, size);
    defer gpa.free(fake);
    @memset(fake, 0);
    try std.testing.expectError(error.WrongRom, check(fake));
    try std.testing.expectError(error.WrongRom, check(fake[0..100]));
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &digest(""));
}

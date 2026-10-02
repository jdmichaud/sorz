//! A track of the sound driver's data turned into events (sound port map 2.5, 3.4): the bytes
//! the track can reach from its start, followed as the driver follows them (its jumps and loops),
//! decoded in address order, with every address replaced by an event's index. The loops are
//! checked to be the regular ones (a loop start that counts with its own loop end's count, a loop
//! end that goes back to just after its start, a break that leaves past its end); the one loop end
//! of the ROM with no start keeps its target and is marked unmatched.
const std = @import("std");
const content = @import("sorz").audio.content;
const Event = content.Event;

pub const Kind = enum { fm, drums, psg };

pub const Error = error{ BadTrack, OutOfMemory };

/// Why the data was refused, and where.
pub const Refusal = struct {
    why: []const u8 = "",
    at: u32 = 0,

    pub fn refuse(r: *Refusal, why: []const u8, at: u32) Error {
        r.* = .{ .why = why, .at = at };
        return error.BadTrack;
    }
};

/// An instruction of a track: its length and where it may go on.
const Step = struct {
    len: u32,
    falls_through: bool,
    target: ?u32 = null,
};

const Reader = struct {
    rom: []const u8,
    kind: Kind,
    refusal: *Refusal,

    fn byte(r: Reader, a: u32) Error!u8 {
        if (a >= r.rom.len) return r.refusal.refuse("a track runs past the ROM's end", a);
        return r.rom[a];
    }

    fn leWord(r: Reader, a: u32) Error!u16 {
        return @as(u16, try r.byte(a)) | @as(u16, try r.byte(a + 1)) << 8;
    }

    fn beWord(r: Reader, a: u32) Error!u16 {
        return @as(u16, try r.byte(a)) << 8 | try r.byte(a + 1);
    }

    fn step(r: Reader, a: u32) Error!Step {
        const b = try r.byte(a);
        if (b == 0) return .{ .len = 1, .falls_through = false };
        if (b < 0x80) return .{ .len = 2, .falls_through = true };
        if (b < 0xF0) return .{ .len = 1, .falls_through = true };
        const psg = r.kind == .psg;
        return switch (b) {
            0xF0, 0xF1, 0xF3, 0xF8, 0xFB => .{ .len = 2, .falls_through = true },
            0xF2 => .{ .len = 4, .falls_through = true },
            0xF4 => .{ .len = switch (try r.byte(a + 1)) {
                0 => 7,
                1, 2 => 2,
                3, 4, 6 => 3,
                5 => 4,
                else => return r.refusal.refuse("a vibrato command outside the driver's table", a),
            }, .falls_through = true },
            0xF5 => .{ .len = 3, .falls_through = true },
            // F6 x n lo hi: back by the little-endian word, counted from its third argument byte.
            0xF6 => .{ .len = 5, .falls_through = true, .target = a + 3 -% signed(try r.leWord(a + 3)) },
            0xF7 => .{ .len = if (psg) 2 else 5, .falls_through = true },
            0xF9 => .{ .len = if (psg) 2 else 1, .falls_through = true },
            0xFA => .{ .len = if (psg) 2 else 3, .falls_through = true },
            0xFC => if (psg) r.refusal.refuse("a PSG command that hangs the driver", a) else .{ .len = 4, .falls_through = true },
            0xFD => .{ .len = 1, .falls_through = true },
            // FE lo hi: forward by the (unsigned) word, counted from 5 bytes after the FE.
            0xFE => .{ .len = 3, .falls_through = true, .target = a + 5 + try r.leWord(a + 1) },
            // FF hi lo: by the signed big-endian word, counted from its second byte.
            0xFF => .{ .len = 3, .falls_through = false, .target = a + 2 +% signed(try r.beWord(a + 1)) },
            else => unreachable,
        };
    }
};

fn signed(w: u16) u32 {
    return @bitCast(@as(i32, @as(i16, @bitCast(w))));
}

/// The events of the track that starts at `start`. `channel` is the chip's channel code of an FM
/// or drum track (0-2, 4-6), which its register tweaks name.
pub fn decode(arena: std.mem.Allocator, rom: []const u8, start: u32, kind: Kind, channel: u8, refusal: *Refusal) Error![]const Event {
    const r: Reader = .{ .rom = rom, .kind = kind, .refusal = refusal };
    // The reachable instructions, by address.
    var seen: std.AutoArrayHashMapUnmanaged(u32, Step) = .empty;
    var work: std.ArrayList(u32) = .empty;
    try work.append(arena, start);
    while (work.pop()) |a| {
        if (seen.contains(a)) continue;
        const s = try r.step(a);
        try seen.put(arena, a, s);
        if (seen.count() > 100_000) return refusal.refuse("a track too long to be one", start);
        if (s.falls_through) try work.append(arena, a + s.len);
        if (s.target) |t| try work.append(arena, t);
    }
    const addresses = try arena.dupe(u32, seen.keys());
    std.mem.sort(u32, addresses, {}, std.sort.asc(u32));
    for (addresses[0 .. addresses.len - 1], addresses[1..]) |a, next| {
        if (a + seen.get(a).?.len > next) return refusal.refuse("two instructions of a track overlap", next);
    }
    const events = try arena.alloc(Event, addresses.len);
    // The open loops, by the index of their start, for the checks of their ends and breaks.
    var open: std.ArrayList(usize) = .empty;
    // Breaks waiting for their loop's end: the break's index and the loop's start.
    var breaks: std.ArrayList([2]usize) = .empty;
    for (addresses, events, 0..) |a, *e, i| {
        const b = rom[a];
        const s = seen.get(a).?;
        e.* = if (b == 0) .end else if (b < 0x80) note(rom[a + 1], b, kind) else if (b < 0xF0)
            .{ .rest = if (b == 0x80) 256 else b - 0x80 }
        else switch (b) {
            0xF0 => if (kind != .drums) .{ .instrument = rom[a + 1] } else switch (rom[a + 1]) {
                // The drums ask for sample n - 1 with request $80 + n.
                1...17 => |n| .{ .drum = n - 1 },
                else => return refusal.refuse("a drum track's instrument that asks for no sample", a),
            },
            0xF1 => .{ .volume = rom[a + 1] },
            0xF2 => .{ .detune = .{ .value = @bitCast(@as(u16, rom[a + 2]) << 8 | rom[a + 1]), .add = rom[a + 3] != 0 } },
            0xF3 => .{ .gate = rom[a + 1] },
            0xF4 => .{ .vibrato = vibrato(rom[a + 1 ..][0..6]) },
            0xF5 => blk: {
                try open.append(arena, i);
                // The count is the byte its offset points at: checked against its end's below.
                break :blk .{ .loop_start = try r.byte(a + 1 + try r.leWord(a + 1)) };
            },
            0xF6 => blk: {
                const to = try indexOf(addresses, s.target.?, refusal);
                const start_index = open.pop() orelse break :blk .{ .loop_end = .{ .to = to, .matched = false } };
                const start_at = addresses[start_index];
                if (start_at + 1 + try r.leWord(start_at + 1) != a + 2)
                    return refusal.refuse("a loop start that counts with another byte than its end's", start_at);
                if (to != start_index + 1) return refusal.refuse("a loop end that goes back elsewhere than its start", a);
                while (breaks.items.len != 0 and breaks.items[breaks.items.len - 1][1] == start_index) {
                    const brk = breaks.pop().?;
                    if (events[brk[0]].loop_break != i + 1)
                        return refusal.refuse("a loop break that leaves elsewhere than past its end", addresses[brk[0]]);
                }
                break :blk .{ .loop_end = .{ .to = to } };
            },
            0xF7 => if (kind == .psg) .noise else .{ .fm3 = rom[a + 1 ..][0..4].* },
            0xF8 => .{ .pan = try speakers(rom, rom[a + 1], kind, refusal) },
            0xF9 => if (kind == .psg) .{ .envelope = rom[a + 1] } else .pause,
            0xFA => if (kind == .psg) .{ .envelope = rom[a + 1] } else .{ .tweak = try tweak(rom[a + 1], rom[a + 2], channel, refusal) },
            0xFB => .{ .volume_add = rom[a + 1] },
            0xFC => .{ .lfo = .{ .rate = rom[a + 1], .fms = rom[a + 2], .ams = rom[a + 3] } },
            0xFD => .tie,
            0xFE => blk: {
                if (open.items.len == 0) return refusal.refuse("a loop break outside a loop", a);
                try breaks.append(arena, .{ i, open.items[open.items.len - 1] });
                break :blk .{ .loop_break = try indexOf(addresses, s.target.?, refusal) };
            },
            0xFF => .{ .jump = try indexOf(addresses, s.target.?, refusal) },
            else => unreachable,
        };
    }
    if (open.items.len != 0) return refusal.refuse("a loop start without its end", addresses[open.items[0]]);
    if (breaks.items.len != 0) return refusal.refuse("a loop break without its loop's end", addresses[breaks.items[0][0]]);
    return events;
}

/// The driver's pan table: the output bits of pans 0-3.
pub const pan_table = 0x7353A;

/// The speakers of pan `n` (the PSG ignores its pans, whatever their number).
fn speakers(rom: []const u8, n: u8, kind: Kind, refusal: *Refusal) Error!content.Speakers {
    if (n > 3) return if (kind == .psg) .none else refusal.refuse("a pan past the table", pan_table);
    return switch (rom[pan_table + @as(u32, n)]) {
        0xC0 => .both,
        0x80 => .left,
        0x40 => .right,
        0x00 => .none,
        else => refusal.refuse("a pan table entry with other bits than the speakers'", pan_table),
    };
}

fn indexOf(list: []const u32, a: u32, refusal: *Refusal) Error!u16 {
    const i = std.sort.binarySearch(u32, list, a, struct {
        fn cmp(x: u32, y: u32) std.math.Order {
            return std.math.order(x, y);
        }
    }.cmp) orelse return refusal.refuse("a jump into the middle of an instruction", a);
    return @intCast(i);
}

fn note(byte: u8, duration: u8, kind: Kind) Event {
    return .{ .note = switch (kind) {
        .fm => .{ .duration = duration, .octave = @intCast(byte >> 4 & 7), .key = @intCast(byte & 15) },
        .psg => .{ .duration = duration, .step = (byte >> 4) * 12 + (byte & 15) },
        .drums => .{ .duration = duration },
    } };
}

fn vibrato(a: *const [6]u8) content.Vibrato {
    return switch (a[0]) {
        0 => .{ .set = .{ .delay = a[1], .period = a[2], .step = @bitCast(@as(u16, a[4]) << 8 | a[3]), .count = a[5] } },
        1 => .off,
        2 => .on,
        3 => .{ .delay = a[1] },
        4 => .{ .period = a[1] },
        5 => .{ .step = @bitCast(@as(u16, a[2]) << 8 | a[1]) },
        6 => .{ .count = a[1] },
        else => unreachable,
    };
}

/// The FM command FA r v of a track on `channel` (the chip's channel code, 0-2 and 4-6), by
/// meaning: an operator's parameter group, or timer B (sound port map 3.4). The driver writes
/// register r of the channel's part of the chip.
pub fn tweak(r: u8, v: u8, channel: u8, refusal: *Refusal) Error!content.Tweak {
    if (r == 0x26) return .{ .timer_b = v };
    const low = channel & 3;
    if (r & 3 != low) return refusal.refuse("a register tweak of another channel than the track's", r);
    const base = r - low;
    const parameter: content.Parameter = switch (base & 0xF0) {
        0x30 => .detune_multiple,
        0x40 => .level,
        0x50 => .key_scale_attack,
        0x60 => .am_decay,
        0x70 => .sustain_rate,
        0x80 => .sustain_level_release,
        else => return refusal.refuse("a register tweak outside the operators' parameters", r),
    };
    if (v & @import("sorz").audio.chips.registers.ignoredBits(parameter) != 0) return refusal.refuse("a register tweak with bits the chip does not use", r);
    return .{ .operator = .{ .operator = operatorOfSlot(@intCast(base >> 2 & 3)), .parameter = parameter, .value = v } };
}

/// The operator of a register slot ($x0, $x4, $x8, $xC): op1, op3, op2, op4.
pub fn operatorOfSlot(slot: u2) content.OperatorName {
    return switch (slot) {
        0 => .op1,
        1 => .op3,
        2 => .op2,
        3 => .op4,
    };
}

const testing = std.testing;

fn testRom(bytes: []const u8) ![]u8 {
    const rom = try testing.allocator.alloc(u8, 0x100);
    @memset(rom, 0);
    @memcpy(rom[0x10..][0..bytes.len], bytes);
    return rom;
}

test "a track's notes, rests, loops and jump become events with indexes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Offsets from the track's start (0x10); each offset's arithmetic is relative.
    const bytes = [_]u8{
        0xF0, 0x01, // 0: instrument 1
        0xF5, 0x0A, 0x00, // 2: loop start, its count at 3 + 10 = 13 (its end's second byte)
        0x0C, 0x25, // 5: a note of 12 updates, octave 2, key 5
        0xFE, 0x04, 0x00, // 7: break, to 7 + 5 + 4 = 16
        0x85, // 10: rest 5
        0xF6, 0x00, 0x03, 0x09, 0x00, // 11: loop end, three times, back to 11 + 3 - 9 = 5
        0xFF, 0xFF, 0xF0, // 16: jump to 16 + 2 - 16 = 2
    };
    const rom = try testRom(&bytes);
    defer testing.allocator.free(rom);
    var why: Refusal = .{};
    const events = try decode(arena.allocator(), rom, 0x10, .fm, 0, &why);
    try testing.expectEqual(@as(usize, 7), events.len);
    try testing.expectEqual(@as(u8, 1), events[0].instrument);
    try testing.expectEqual(@as(u8, 3), events[1].loop_start);
    try testing.expectEqual(Event{ .note = .{ .duration = 12, .octave = 2, .key = 5 } }, events[2]);
    try testing.expectEqual(@as(u16, 6), events[3].loop_break);
    try testing.expectEqual(@as(u16, 5), events[4].rest);
    try testing.expectEqual(@as(u16, 2), events[5].loop_end.to);
    try testing.expect(events[5].loop_end.matched);
    try testing.expectEqual(@as(u16, 1), events[6].jump);
}

test "a loop end with no start keeps its target; a loop start counting elsewhere is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var why: Refusal = .{};
    // 0: note; 2: loop end back to 0 (2 + 3 - 5); 7: end.
    const stray = [_]u8{ 0x05, 0x10, 0xF6, 0x00, 0x02, 0x05, 0x00, 0x00 };
    const rom = try testRom(&stray);
    defer testing.allocator.free(rom);
    const events = try decode(arena.allocator(), rom, 0x10, .psg, 0, &why);
    try testing.expectEqual(Event{ .loop_end = .{ .to = 0, .matched = false } }, events[1]);
    try testing.expectEqual(@as(u8, 12), events[0].note.step);
    // A loop start whose count is not its end's second byte (3 + 5 = 8, the end's is at 7).
    const wrong = [_]u8{ 0xF5, 0x05, 0x00, 0x05, 0x10, 0xF6, 0x00, 0x02, 0x05, 0x00, 0x00 };
    const rom2 = try testRom(&wrong);
    defer testing.allocator.free(rom2);
    try testing.expectError(error.BadTrack, decode(arena.allocator(), rom2, 0x10, .fm, 0, &why));
    try testing.expectEqualStrings("a loop start that counts with another byte than its end's", why.why);
}

test "register tweaks by meaning" {
    var why: Refusal = .{};
    try testing.expectEqual(content.Tweak{ .operator = .{ .operator = .op2, .parameter = .sustain_rate, .value = 1 } }, try tweak(0x78, 1, 0, &why));
    try testing.expectEqual(content.Tweak{ .operator = .{ .operator = .op4, .parameter = .am_decay, .value = 0x10 } }, try tweak(0x6D, 0x10, 1, &why));
    try testing.expectEqual(content.Tweak{ .timer_b = 0xC6 }, try tweak(0x26, 0xC6, 2, &why));
    try testing.expectEqual(content.Tweak{ .timer_b = 0xC6 }, try tweak(0x26, 0xC6, 6, &why));
    try testing.expectEqual(content.Tweak{ .timer_b = 0xC6 }, try tweak(0x26, 0xC6, 1, &why));
    try testing.expectError(error.BadTrack, tweak(0x79, 1, 0, &why));
    try testing.expectError(error.BadTrack, tweak(0x70, 0x20, 0, &why));
}

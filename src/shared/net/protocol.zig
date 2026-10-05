//! The messages of the netplay session (DESIGN.md 9), version 2: one message per transport message,
//! its first byte its kind, then fixed fields in little-endian order. Decoding is strict: an
//! unknown kind, a wrong length or a field out of its range is `Malformed`, and nothing is
//! half-read.
//!
//! | kind          | fields                                                       | bytes        |
//! |---------------|--------------------------------------------------------------|--------------|
//! | 1 hello       | magic "SZNP", protocol u16, build [32], data [32], session    | 83           |
//! |               | u64 (0: a new one), resume_from u32 (host pads needed from)  |              |
//! | 2 welcome     | session u64, delay u8 (2-6), fresh u8 (0/1), resume_from u32, | 18           |
//! |               | start: variant u8 (0-2), players u8 (0/1), volume u8 (0-100, |              |
//! |               | 255 none)                                                    |              |
//! | 3 reject      | reason u8                                                    | 2            |
//! | 4 ping        | seq u32, time_ns u64 (the sender's clock, echoed)            | 13           |
//! | 5 pong        | seq u32, time_ns u64                                         | 13           |
//! | 6 pads        | first u32, ack u32, slack i16, count u8 (1-64), pads [count] | 12 + count   |
//! | 7 hash        | tick u32, hash u64                                           | 13           |
//! | 8 state       | tick u32, length u32, offset u32, chunk of the state's form  | 13 + chunk   |
//! | 9 bye         | reason u8                                                    | 2            |
//! | 10 settings   | open u8 (0/1): the sender's player is on the settings screen | 2            |
//!
//! The guest opens with `hello`; the host answers `welcome` (after pings that measure the round
//! trip, for a new session) or `reject`. The welcome's `start` is what the host's game starts with
//! (its variant, the players, OPTIONS' VOLUME line: variant.zig): the guest's game starts with it
//! too, so that both run the same game (version 2 on). `pads` carries the sender's pads (input.Pad's byte) from
//! tick `first`, with `ack`, the first of the receiver's pads the sender does not have, and
//! `slack`, the sender's measure of how early the receiver's pads reach it (session.zig, the clock
//! balancing). `hash` is the hash of the game's state before tick `tick`, in its canonical form
//! (canonical.zig); after a mismatch, `state` carries that form, `length` bytes in chunks of
//! `chunk_size` (the last one shorter), so that the peers name the first differing field.
//! `settings` says that the sender's player opened the settings screen, which holds both games,
//! or closed it.
const std = @import("std");

pub const version: u16 = 2;
pub const magic = "SZNP";

/// The longest run of pads in one message.
pub const max_pads = 64;
/// The longest canonical state a session compares (at most seven chunks: the session notes the
/// chunks come in a byte's bits), and the chunk of it a `state` message carries.
pub const max_state_len = 64 * 1024;
pub const chunk_size = 16 * 1024;
/// The longest message of the protocol.
pub const max_len = 13 + chunk_size;

pub const Kind = enum(u8) {
    hello = 1,
    welcome = 2,
    reject = 3,
    ping = 4,
    pong = 5,
    pads = 6,
    hash = 7,
    state = 8,
    bye = 9,
    settings = 10,
    _,
};

pub const RejectReason = enum(u8) {
    /// Another protocol version.
    protocol = 1,
    /// Another build of the game.
    build = 2,
    /// Other game data (another ROM, another content tree).
    data = 3,
    /// The host already has a guest.
    busy = 4,
    /// A message that is not of the protocol, or out of place.
    malformed = 5,
    _,
};

pub const ByeReason = enum(u8) {
    /// The player quit.
    quit = 1,
    /// The session stopped at a state mismatch.
    desync = 2,
    _,
};

/// A build's identity, as text padded with zeros.
pub const Build = [32]u8;
/// The game data's identity (identity.zig).
pub const DataId = [32]u8;

pub const Hello = struct {
    protocol: u16 = version,
    build: Build,
    data: DataId,
    session: u64,
    resume_from: u32,
};

pub const Welcome = struct {
    session: u64,
    delay: u8,
    fresh: bool,
    resume_from: u32,
    start: Start = .{},
};

/// What the host's game starts with (variant.zig's `Start`, as bytes): the variant's number (0 to
/// `max_variant`), the players (0 one, 1 two), the VOLUME line's value (`no_volume`: none).
pub const Start = struct {
    variant: u8 = 0,
    players: u8 = 0,
    volume: u8 = no_volume,

    pub const max_variant = 2;
    pub const no_volume = 255;
};

pub const Ping = struct { seq: u32, time_ns: u64 };

pub const Pads = struct {
    first: u32,
    ack: u32,
    slack: i16,
    pads: []const u8,
};

pub const Hash = struct { tick: u32, hash: u64 };

pub const State = struct { tick: u32, length: u32, offset: u32, bytes: []const u8 };

pub const Message = union(Kind) {
    hello: Hello,
    welcome: Welcome,
    reject: RejectReason,
    ping: Ping,
    pong: Ping,
    pads: Pads,
    hash: Hash,
    state: State,
    bye: ByeReason,
    settings: bool,
};

pub const DecodeError = error{Malformed};

/// The chunks of a state's form of `length` bytes.
pub fn chunks(length: u32) u32 {
    return (length + chunk_size - 1) / chunk_size;
}

/// The bytes of the chunk at `offset` of a state's form of `length` bytes.
pub fn chunkLen(length: u32, offset: u32) u32 {
    return @min(chunk_size, length - offset);
}

const Writer = struct {
    buf: []u8,
    at: usize = 0,

    fn byte(w: *Writer, v: u8) void {
        w.buf[w.at] = v;
        w.at += 1;
    }
    fn int(w: *Writer, comptime T: type, v: T) void {
        std.mem.writeInt(T, w.buf[w.at..][0..@sizeOf(T)], v, .little);
        w.at += @sizeOf(T);
    }
    fn bytes(w: *Writer, b: []const u8) void {
        @memcpy(w.buf[w.at..][0..b.len], b);
        w.at += b.len;
    }
};

const Reader = struct {
    buf: []const u8,
    at: usize = 0,

    fn byte(r: *Reader) DecodeError!u8 {
        if (r.at >= r.buf.len) return error.Malformed;
        r.at += 1;
        return r.buf[r.at - 1];
    }
    fn int(r: *Reader, comptime T: type) DecodeError!T {
        if (r.buf.len - r.at < @sizeOf(T)) return error.Malformed;
        defer r.at += @sizeOf(T);
        return std.mem.readInt(T, r.buf[r.at..][0..@sizeOf(T)], .little);
    }
    fn bytes(r: *Reader, n: usize) DecodeError![]const u8 {
        if (r.buf.len - r.at < n) return error.Malformed;
        defer r.at += n;
        return r.buf[r.at..][0..n];
    }
    fn end(r: *const Reader) DecodeError!void {
        if (r.at != r.buf.len) return error.Malformed;
    }
};

/// Writes `m` into `out` (at least `max_len` bytes) and returns the message.
pub fn encode(m: Message, out: []u8) []u8 {
    std.debug.assert(out.len >= max_len);
    var w: Writer = .{ .buf = out };
    w.byte(@backingInt(std.meta.activeTag(m)));
    switch (m) {
        .hello => |h| {
            w.bytes(magic);
            w.int(u16, h.protocol);
            w.bytes(&h.build);
            w.bytes(&h.data);
            w.int(u64, h.session);
            w.int(u32, h.resume_from);
        },
        .welcome => |h| {
            w.int(u64, h.session);
            w.byte(h.delay);
            w.byte(@intFromBool(h.fresh));
            w.int(u32, h.resume_from);
            w.byte(h.start.variant);
            w.byte(h.start.players);
            w.byte(h.start.volume);
        },
        .reject => |r| w.byte(@backingInt(r)),
        .bye => |r| w.byte(@backingInt(r)),
        .settings => |open| w.byte(@intFromBool(open)),
        .ping, .pong => |p| {
            w.int(u32, p.seq);
            w.int(u64, p.time_ns);
        },
        .pads => |p| {
            std.debug.assert(p.pads.len >= 1 and p.pads.len <= max_pads);
            w.int(u32, p.first);
            w.int(u32, p.ack);
            w.int(i16, p.slack);
            w.byte(@intCast(p.pads.len));
            w.bytes(p.pads);
        },
        .hash => |h| {
            w.int(u32, h.tick);
            w.int(u64, h.hash);
        },
        .state => |s| {
            std.debug.assert(s.length <= max_state_len and s.offset < s.length and s.bytes.len == chunkLen(s.length, s.offset));
            w.int(u32, s.tick);
            w.int(u32, s.length);
            w.int(u32, s.offset);
            w.bytes(s.bytes);
        },
    }
    return out[0..w.at];
}

/// Reads one message. Its slices point into `bytes`.
pub fn decode(bytes: []const u8) DecodeError!Message {
    var r: Reader = .{ .buf = bytes };
    const kind: Kind = @fromBackingInt(@intCast(try r.byte()));
    const m: Message = switch (kind) {
        .hello => blk: {
            if (!std.mem.eql(u8, try r.bytes(magic.len), magic)) return error.Malformed;
            const protocol = try r.int(u16);
            break :blk .{ .hello = .{
                .protocol = protocol,
                .build = (try r.bytes(32))[0..32].*,
                .data = (try r.bytes(32))[0..32].*,
                .session = try r.int(u64),
                .resume_from = try r.int(u32),
            } };
        },
        .welcome => blk: {
            const session = try r.int(u64);
            const delay = try r.byte();
            const fresh = try r.byte();
            if (delay < min_delay or delay > max_delay or fresh > 1 or session == 0) return error.Malformed;
            const resume_from = try r.int(u32);
            const start: Start = .{ .variant = try r.byte(), .players = try r.byte(), .volume = try r.byte() };
            if (start.variant > Start.max_variant or start.players > 1 or (start.volume > 100 and start.volume != Start.no_volume)) return error.Malformed;
            break :blk .{ .welcome = .{ .session = session, .delay = delay, .fresh = fresh == 1, .resume_from = resume_from, .start = start } };
        },
        .reject => blk: {
            const reason: RejectReason = @fromBackingInt(@intCast(try r.byte()));
            if (std.enums.tagName(RejectReason, reason) == null) return error.Malformed;
            break :blk .{ .reject = reason };
        },
        .bye => blk: {
            const reason: ByeReason = @fromBackingInt(@intCast(try r.byte()));
            if (std.enums.tagName(ByeReason, reason) == null) return error.Malformed;
            break :blk .{ .bye = reason };
        },
        .settings => blk: {
            const open = try r.byte();
            if (open > 1) return error.Malformed;
            break :blk .{ .settings = open == 1 };
        },
        .ping => .{ .ping = .{ .seq = try r.int(u32), .time_ns = try r.int(u64) } },
        .pong => .{ .pong = .{ .seq = try r.int(u32), .time_ns = try r.int(u64) } },
        .pads => blk: {
            const first = try r.int(u32);
            const ack = try r.int(u32);
            const slack = try r.int(i16);
            const count = try r.byte();
            if (count == 0 or count > max_pads) return error.Malformed;
            if (@as(u64, first) + count > std.math.maxInt(u32)) return error.Malformed;
            break :blk .{ .pads = .{ .first = first, .ack = ack, .slack = slack, .pads = try r.bytes(count) } };
        },
        .hash => .{ .hash = .{ .tick = try r.int(u32), .hash = try r.int(u64) } },
        .state => blk: {
            const tick = try r.int(u32);
            const length = try r.int(u32);
            const offset = try r.int(u32);
            if (length == 0 or length > max_state_len or offset >= length or offset % chunk_size != 0) return error.Malformed;
            break :blk .{ .state = .{ .tick = tick, .length = length, .offset = offset, .bytes = try r.bytes(chunkLen(length, offset)) } };
        },
        _ => return error.Malformed,
    };
    try r.end();
    return m;
}

/// The input delay's range, in display ticks.
pub const min_delay = 2;
pub const max_delay = 6;

/// A build identity from its text: at most 32 bytes, padded with zeros.
pub fn buildId(text: []const u8) Build {
    var b: Build = @splat(0);
    const n = @min(text.len, b.len);
    @memcpy(b[0..n], text[0..n]);
    return b;
}

/// The text of a build identity.
pub fn buildText(b: *const Build) []const u8 {
    return b[0 .. std.mem.findScalar(u8, b, 0) orelse b.len];
}

// --- tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(m: Message) !void {
    var buf: [max_len]u8 = undefined;
    const bytes = encode(m, &buf);
    const back = try decode(bytes);
    var buf2: [max_len]u8 = undefined;
    try testing.expectEqualSlices(u8, bytes, encode(back, &buf2));
    // Every shorter prefix and a longer message are malformed.
    for (0..bytes.len) |n| try testing.expectError(error.Malformed, decode(bytes[0..n]));
    var longer: [max_len + 1]u8 = undefined;
    @memcpy(longer[0..bytes.len], bytes);
    longer[bytes.len] = 0;
    try testing.expectError(error.Malformed, decode(longer[0 .. bytes.len + 1]));
}

test "every message round trips, and its truncations are malformed" {
    const data: DataId = @splat(171);
    try roundTrip(.{ .hello = .{ .build = buildId("0.1.0 abc"), .data = data, .session = 1234567890123, .resume_from = 77 } });
    try roundTrip(.{ .welcome = .{ .session = 9, .delay = 3, .fresh = true, .resume_from = 0 } });
    try roundTrip(.{ .welcome = .{ .session = 9, .delay = 3, .fresh = true, .resume_from = 0, .start = .{ .variant = 2, .players = 1, .volume = 70 } } });
    try roundTrip(.{ .reject = .data });
    try roundTrip(.{ .bye = .quit });
    try roundTrip(.{ .settings = true });
    try roundTrip(.{ .settings = false });
    try roundTrip(.{ .ping = .{ .seq = 5, .time_ns = 123456789 } });
    try roundTrip(.{ .pong = .{ .seq = 5, .time_ns = 1 } });
    try roundTrip(.{ .pads = .{ .first = 1000, .ack = 998, .slack = -300, .pads = &.{ 1, 2, 128 } } });
    try roundTrip(.{ .hash = .{ .tick = 60, .hash = 3735928559 } });
    var chunk: [chunk_size]u8 = undefined;
    for (&chunk, 0..) |*b, i| b.* = @truncate(i);
    try roundTrip(.{ .state = .{ .tick = 60, .length = 3 * chunk_size + 10, .offset = 2 * chunk_size, .bytes = &chunk } });
    try roundTrip(.{ .state = .{ .tick = 60, .length = 3 * chunk_size + 10, .offset = 3 * chunk_size, .bytes = chunk[0..10] } });
    try testing.expectEqualStrings("0.1.0 abc", buildText(&buildId("0.1.0 abc")));
    try testing.expectEqual(@as(u32, 4), chunks(3 * chunk_size + 10));
    try testing.expectEqual(@as(u32, 1), chunks(1));
}

test "fields out of range are malformed" {
    var buf: [max_len]u8 = undefined;
    // An unknown kind, the wrong magic, a reason without a name.
    try testing.expectError(error.Malformed, decode(&.{0}));
    try testing.expectError(error.Malformed, decode(&.{ 200, 1 }));
    const hello = encode(.{ .hello = .{ .build = @splat(0), .data = @splat(0), .session = 0, .resume_from = 0 } }, &buf);
    hello[1] = 'X';
    try testing.expectError(error.Malformed, decode(hello));
    try testing.expectError(error.Malformed, decode(&.{ 3, 99 }));
    try testing.expectError(error.Malformed, decode(&.{ 9, 0 }));
    try testing.expectError(error.Malformed, decode(&.{ 10, 2 }));
    // A delay out of 2 to 6, a flag that is not 0 or 1, session 0.
    for ([_][3]u8{ .{ 1, 0, 1 }, .{ 7, 0, 1 }, .{ 3, 2, 1 }, .{ 3, 0, 0 } }) |v| {
        const w = encode(.{ .welcome = .{ .session = v[2], .delay = 3, .fresh = false, .resume_from = 0 } }, &buf);
        w[9] = v[0];
        w[10] = v[1];
        try testing.expectError(error.Malformed, decode(w));
    }
    // A start out of range: an unknown variant, three players, a volume past 100.
    for ([_][3]u8{ .{ 3, 0, 255 }, .{ 0, 2, 255 }, .{ 0, 0, 101 } }) |v| {
        const w = encode(.{ .welcome = .{ .session = 1, .delay = 3, .fresh = true, .resume_from = 0 } }, &buf);
        @memcpy(w[15..18], &v);
        try testing.expectError(error.Malformed, decode(w));
    }
    // No pads, or more than a message may carry, or a count that disagrees with the bytes.
    const pads = encode(.{ .pads = .{ .first = 0, .ack = 0, .slack = 0, .pads = &.{7} } }, &buf);
    pads[11] = 0;
    try testing.expectError(error.Malformed, decode(pads));
    pads[11] = max_pads + 1;
    try testing.expectError(error.Malformed, decode(pads));
    pads[11] = 2;
    try testing.expectError(error.Malformed, decode(pads));
    // A chunk off the grid, past the form's end, of the wrong length, or of a form too long.
    const chunk: [chunk_size]u8 = @splat(1);
    const s = encode(.{ .state = .{ .tick = 1, .length = 2 * chunk_size, .offset = 0, .bytes = &chunk } }, &buf);
    std.mem.writeInt(u32, s[9..13], 5, .little);
    try testing.expectError(error.Malformed, decode(s));
    std.mem.writeInt(u32, s[9..13], 2 * chunk_size, .little);
    try testing.expectError(error.Malformed, decode(s));
    std.mem.writeInt(u32, s[9..13], 0, .little);
    try testing.expectError(error.Malformed, decode(s[0 .. s.len - 1]));
    std.mem.writeInt(u32, s[5..9], max_state_len + 1, .little);
    try testing.expectError(error.Malformed, decode(s));
    std.mem.writeInt(u32, s[5..9], 0, .little);
    try testing.expectError(error.Malformed, decode(s));
}

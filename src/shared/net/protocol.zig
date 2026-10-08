//! The messages of the netplay session (DESIGN.md 9), version 4: one message per transport message,
//! its first byte its kind, then fixed fields in little-endian order. Decoding is strict: an
//! unknown kind, a wrong length or a field out of its range is `Malformed`, and nothing is
//! half-read.
//!
//! | kind          | fields                                                       | bytes        |
//! |---------------|--------------------------------------------------------------|--------------|
//! | 1 hello       | magic "SZNP", protocol u16, build [32], data [32], session    | 86           |
//! |               | u64 (0: none), resume_from u32 (host pads needed from), name |              |
//! |               | [3] (the client's player's, letters)                         |              |
//! | 2 welcome     | session u64 (0: none to resume), delay u8 (2-6),             | 14           |
//! |               | resume_from u32                                              |              |
//! | 3 reject      | reason u8                                                    | 2            |
//! | 4 ping        | seq u32, time_ns u64 (the sender's clock, echoed)            | 13           |
//! | 5 pong        | seq u32, time_ns u64                                         | 13           |
//! | 6 pads        | first u32, ack u32, slack i16, count u8 (1-64), pads [count] | 12 + count   |
//! | 7 hash        | tick u32, hash u64                                           | 13           |
//! | 8 state       | tick u32, length u32, offset u32, chunk of the state's form  | 13 + chunk   |
//! | 9 bye         | reason u8                                                    | 2            |
//! | 10 settings   | open u8 (0/1): the sender's player is on the settings screen | 2            |
//! | 11 status     | game u8 (0 none, 1 select, 2 play), character u8 (player 1's,| 4            |
//! |               | 0-2, 255 none), flags u8 (1 open, 2 a place free, 4          |              |
//! |               | observers taken, 8 the same character, 16 joins in progress) |              |
//! | 12 join       | character u8 (0-2, 255 none)                                 | 2            |
//! | 13 game       | session u64, delay u8, observe u8 (0/1), length u32, offset  | 23 + chunk   |
//! |               | u32, chunk of the game's form                                |              |
//! | 14 observe    | yes u8 (0/1): the client's player watches, or no longer      | 2            |
//! | 15 ticks      | first u32, count u8 (1-64), pads [2 count] (player 1's then  | 6 + 2 count  |
//! |               | player 2's, each tick's)                                     |              |
//! | 16 away       | seconds u8: a player's connection is down, the seconds left  | 2            |
//! |               | before it leaves the game (0: it is back, or it left)        |              |
//! | 17 name       | name [3]: the client's player's, given again                 | 4            |
//! | 18 where      | at u8: the client's player in its own menu (0) or at its     | 3            |
//! |               | character select, to join (1); cursor u8 (its cursor's       |              |
//! |               | character there, 0-2, 255 none)                              |              |
//! | 19 event      | tick u32, what u8 (1 player 1 leaves, 2 player 1 comes       | 10           |
//! |               | back, 3 the rules change), character u8 (0-2 for a coming    |              |
//! |               | back, else 255), lives u8, continues u8, friendly hit u8     |              |
//! |               | (0/1; the rules', 0 for the others)                          |              |
//!
//! The guest opens with `hello`; the host answers `welcome` (after pings that measure the round
//! trip and give the input delay) or `reject`. Welcomed, the two machines play their own games:
//! the host says what its game is (`status`: its front end, the character select, play, and
//! player 1's character there), and the guest asks to join it (`join`, with the character its
//! player chose, or none at the select). The host answers with its game (`game`: the session's
//! id and delay, then its join, in chunks of `chunk_size`: the game's canonical form,
//! canonical.zig, and the host's sound as it plays beside it, game.zig `joinForm`); the guest
//! loads it, and from that tick on both run the same game in lockstep. A hello with a session the
//! host still plays resumes it (`welcome` with that session). `pads` carries the sender's pads
//! (input.Pad's byte) from tick `first`, with `ack`, the first of the receiver's pads the sender
//! does not have, and `slack`, the sender's measure of how early the receiver's pads reach it
//! (session.zig, the clock balancing). `hash` is the hash of the game's state before tick `tick`;
//! after a mismatch, `state` carries that form so that the peers name the first differing field.
//! `settings` says that the sender's player opened the settings screen, which holds both games,
//! or closed it. Characters are numbered as the game's: Adam, Axel, Blaze.
//!
//! The host keeps a session for each client (its name in its `hello`, and in `name` when its player
//! gives it again; where its player is in its own game, `where`, for the host's lists). `status` also says whether
//! the host's session is open, whether a player's place is free in it, whether the host takes
//! observers and whether two players may choose one character. A client that asks to watch
//! (`observe`) gets the host's game (`game` with `observe`), then each tick's pads (`ticks`) as
//! the host's game runs them, and the game again whenever it changes otherwise; `away` counts a
//! player's dropped connection down for those who wait for it. The host that stops its server
//! says `bye` (`stopped`) to its clients, and turns away those that come (`reject`, `stopped`)
//! until it starts it again. A player who leaves the game but not the program says `bye` (`ended`):
//! the session ends, the connection stays. `event` changes the game in a session at a tick the
//! host chooses, ahead of its pads for that tick: its player leaving the game (Escape, the game
//! going on for its client) or coming back, or the game's rules (its settings).
const std = @import("std");

pub const version: u16 = 4;
pub const magic = "SZNP";

/// The longest run of pads in one message.
pub const max_pads = 64;
/// The longest canonical state a session compares (at most seven chunks: the session notes the
/// chunks come in a byte's bits), and the chunk of it a `state` message carries.
pub const max_state_len = 64 * 1024;
pub const chunk_size = 16 * 1024;
/// The longest message of the protocol.
pub const max_len = 22 + chunk_size;

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
    status = 11,
    join = 12,
    game = 13,
    observe = 14,
    ticks = 15,
    away = 16,
    name = 17,
    where = 18,
    event = 19,
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
    /// The host stopped its server: no client until it starts it again (the client tries again).
    stopped = 6,
    _,
};

pub const ByeReason = enum(u8) {
    /// The player quit.
    quit = 1,
    /// The session stopped at a state mismatch.
    desync = 2,
    /// The host stopped its server: its clients go back to their menus.
    stopped = 3,
    /// The sender's player left the game (Escape) and goes back to its menu: the session ends, the
    /// connection stays (the client in the host's lobby).
    ended = 4,
    _,
};

/// A build's identity, as text padded with zeros.
pub const Build = [32]u8;
/// The game data's identity (identity.zig).
pub const DataId = [32]u8;

/// A player's name: three letters.
pub const Name = [3]u8;

/// Where a client's player is in its own game: its menu, or its character select, to join, its
/// cursor on `cursor` there (a join at the host's select keeps it).
pub const Where = struct {
    at: At = .menu,
    cursor: u8 = no_character,

    pub const At = enum(u8) { menu = 0, select = 1 };
};

pub const Hello = struct {
    protocol: u16 = version,
    build: Build,
    data: DataId,
    session: u64,
    resume_from: u32,
    name: Name = .{ ' ', ' ', ' ' },
};

pub const Welcome = struct {
    /// The session that resumes; 0: none, the guest is welcomed to the host's games.
    session: u64,
    delay: u8,
    resume_from: u32,
};

/// A character's number (the game's: 0 Adam, 1 Axel, 2 Blaze), or none.
pub const no_character = 255;
pub const characters = 3;

/// What the host's game is: its front end (`none`), the character select a second player can
/// join (`select`), or play (`play`), with player 1's character there.
pub const Status = struct {
    game: Game = .none,
    character: u8 = no_character,
    /// The host's session is open (its server started), a player's place is free in it, it
    /// takes observers, two players may choose one character.
    open: bool = false,
    place: bool = false,
    observers: bool = false,
    same_character: bool = false,
    /// Players may join the game in progress (past its select).
    join_in_progress: bool = false,

    pub const Game = enum(u8) { none = 0, select = 1, play = 2 };

    fn flags(s: Status) u8 {
        return @as(u8, @intFromBool(s.open)) | @as(u8, @intFromBool(s.place)) << 1 | @as(u8, @intFromBool(s.observers)) << 2 | @as(u8, @intFromBool(s.same_character)) << 3 | @as(u8, @intFromBool(s.join_in_progress)) << 4;
    }
};

/// A chunk of the join's game: the session it starts, with its input delay, and the chunk at
/// `offset` of the game's form of `length` bytes.
/// `observe`: for an observer, whose game runs the host's ticks (`ticks`) rather than lockstep.
pub const GameChunk = struct { session: u64, delay: u8, observe: bool = false, length: u32, offset: u32, bytes: []const u8 };

/// The pads of the ticks from `first` as the host's game ran them: a pair (player 1's, player
/// 2's) a tick.
pub const Ticks = struct { first: u32, pads: []const u8 };

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
    status: Status,
    /// The guest's player asks to join, as this character (`no_character`: none yet).
    join: u8,
    game: GameChunk,
    /// The client's player watches the host's game (true), or no longer does.
    observe: bool,
    ticks: Ticks,
    /// The seconds before a player whose connection dropped leaves the game (0: back, or gone).
    away: u8,
    /// The client's player's name, given again.
    name: Name,
    /// Where the client's player is in its own game.
    where: Where,
    event: Event,
};

/// A change of the game in a session, before tick `tick` on both machines.
pub const Event = struct {
    tick: u32,
    what: What,
    /// The character player 1 comes back as (`no_character` for the others).
    character: u8 = no_character,
    /// The rules' (`rules`; 0 for the others): the lives (1 to 9), the continues (0 to 9), the
    /// friendly hits.
    lives: u8 = 0,
    continues: u8 = 0,
    friendly_hit: bool = false,

    pub const What = enum(u8) { leave = 1, back = 2, rules = 3 };
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
            w.bytes(&h.name);
        },
        .welcome => |h| {
            w.int(u64, h.session);
            w.byte(h.delay);
            w.int(u32, h.resume_from);
        },
        .status => |s| {
            w.byte(@backingInt(s.game));
            w.byte(s.character);
            w.byte(s.flags());
        },
        .join => |c| w.byte(c),
        .game => |g| {
            std.debug.assert(g.length <= max_state_len and g.offset < g.length and g.bytes.len == chunkLen(g.length, g.offset));
            w.int(u64, g.session);
            w.byte(g.delay);
            w.byte(@intFromBool(g.observe));
            w.int(u32, g.length);
            w.int(u32, g.offset);
            w.bytes(g.bytes);
        },
        .reject => |r| w.byte(@backingInt(r)),
        .bye => |r| w.byte(@backingInt(r)),
        .settings, .observe => |yes| w.byte(@intFromBool(yes)),
        .away => |seconds| w.byte(seconds),
        .name => |n| w.bytes(&n),
        .where => |x| {
            w.byte(@backingInt(x.at));
            w.byte(x.cursor);
        },
        .event => |e| {
            w.int(u32, e.tick);
            w.byte(@backingInt(e.what));
            w.byte(e.character);
            w.byte(e.lives);
            w.byte(e.continues);
            w.byte(@intFromBool(e.friendly_hit));
        },
        .ticks => |t| {
            std.debug.assert(t.pads.len >= 2 and t.pads.len <= 2 * max_pads and t.pads.len % 2 == 0);
            w.int(u32, t.first);
            w.byte(@intCast(t.pads.len / 2));
            w.bytes(t.pads);
        },
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
                .name = (try r.bytes(3))[0..3].*,
            } };
        },
        .welcome => blk: {
            const session = try r.int(u64);
            const delay = try r.byte();
            if (delay < min_delay or delay > max_delay) return error.Malformed;
            break :blk .{ .welcome = .{ .session = session, .delay = delay, .resume_from = try r.int(u32) } };
        },
        .status => blk: {
            const game = try r.byte();
            const character = try r.byte();
            const flags = try r.byte();
            if (game > 2 or !isCharacter(character) or (game == 2) == (character == no_character) or flags > 31) return error.Malformed;
            break :blk .{ .status = .{
                .game = @fromBackingInt(game),
                .character = character,
                .open = flags & 1 != 0,
                .place = flags & 2 != 0,
                .observers = flags & 4 != 0,
                .same_character = flags & 8 != 0,
                .join_in_progress = flags & 16 != 0,
            } };
        },
        .join => blk: {
            const character = try r.byte();
            if (!isCharacter(character)) return error.Malformed;
            break :blk .{ .join = character };
        },
        .game => blk: {
            const session = try r.int(u64);
            const delay = try r.byte();
            const observe = try r.byte();
            const length = try r.int(u32);
            const offset = try r.int(u32);
            if (session == 0 or delay < min_delay or delay > max_delay or observe > 1 or length == 0 or length > max_state_len or offset >= length or offset % chunk_size != 0) return error.Malformed;
            break :blk .{ .game = .{ .session = session, .delay = delay, .observe = observe == 1, .length = length, .offset = offset, .bytes = try r.bytes(chunkLen(length, offset)) } };
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
        .settings, .observe => blk: {
            const yes = try r.byte();
            if (yes > 1) return error.Malformed;
            break :blk if (kind == .settings) .{ .settings = yes == 1 } else .{ .observe = yes == 1 };
        },
        .away => .{ .away = try r.byte() },
        .name => .{ .name = (try r.bytes(3))[0..3].* },
        .where => blk: {
            const at = try r.byte();
            const cursor = try r.byte();
            if (at > @backingInt(Where.At.select) or !isCharacter(cursor)) return error.Malformed;
            break :blk .{ .where = .{ .at = @fromBackingInt(at), .cursor = cursor } };
        },
        .event => blk: {
            const tick = try r.int(u32);
            const what = try r.byte();
            const character = try r.byte();
            const lives = try r.byte();
            const continues = try r.byte();
            const friendly = try r.byte();
            if (what < 1 or what > 3 or !isCharacter(character) or (what == 2) == (character == no_character) or friendly > 1) return error.Malformed;
            // The rules within their bounds; the others carry none.
            const rules_ok = if (what == 3) lives >= 1 and lives <= 9 and continues <= 9 else lives == 0 and continues == 0 and friendly == 0;
            if (!rules_ok) return error.Malformed;
            break :blk .{ .event = .{ .tick = tick, .what = @fromBackingInt(what), .character = character, .lives = lives, .continues = continues, .friendly_hit = friendly == 1 } };
        },
        .ticks => blk: {
            const first = try r.int(u32);
            const count = try r.byte();
            if (count == 0 or count > max_pads) return error.Malformed;
            if (@as(u64, first) + count > std.math.maxInt(u32)) return error.Malformed;
            break :blk .{ .ticks = .{ .first = first, .pads = try r.bytes(2 * @as(usize, count)) } };
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

/// A character's number, or none.
fn isCharacter(c: u8) bool {
    return c < characters or c == no_character;
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
    try roundTrip(.{ .hello = .{ .build = buildId("0.1.0 abc"), .data = data, .session = 1234567890123, .resume_from = 77, .name = "BOB".* } });
    try roundTrip(.{ .welcome = .{ .session = 9, .delay = 3, .resume_from = 40 } });
    try roundTrip(.{ .welcome = .{ .session = 0, .delay = 2, .resume_from = 0 } });
    try roundTrip(.{ .status = .{} });
    try roundTrip(.{ .status = .{ .game = .select } });
    try roundTrip(.{ .status = .{ .game = .play, .character = 1 } });
    try roundTrip(.{ .status = .{ .game = .select, .open = true, .place = true, .observers = true, .same_character = true } });
    try roundTrip(.{ .observe = true });
    try roundTrip(.{ .observe = false });
    try roundTrip(.{ .away = 5 });
    try roundTrip(.{ .name = "ZED".* });
    try roundTrip(.{ .where = .{ .at = .select, .cursor = 2 } });
    try roundTrip(.{ .where = .{} });
    try roundTrip(.{ .event = .{ .tick = 900, .what = .leave } });
    try roundTrip(.{ .event = .{ .tick = 1200, .what = .back, .character = 1 } });
    try roundTrip(.{ .event = .{ .tick = 1300, .what = .rules, .lives = 5, .continues = 0, .friendly_hit = true } });
    try roundTrip(.{ .status = .{ .game = .play, .character = 0, .open = true, .join_in_progress = true } });
    try roundTrip(.{ .ticks = .{ .first = 300, .pads = &.{ 1, 2, 3, 4 } } });
    try roundTrip(.{ .join = no_character });
    try roundTrip(.{ .join = 2 });
    try roundTrip(.{ .reject = .data });
    try roundTrip(.{ .reject = .stopped });
    try roundTrip(.{ .bye = .quit });
    try roundTrip(.{ .bye = .stopped });
    try roundTrip(.{ .bye = .ended });
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
    try roundTrip(.{ .game = .{ .session = 77, .delay = 4, .length = chunk_size + 5, .offset = 0, .bytes = &chunk } });
    try roundTrip(.{ .game = .{ .session = 77, .delay = 4, .length = chunk_size + 5, .offset = chunk_size, .bytes = chunk[0..5] } });
    try roundTrip(.{ .game = .{ .session = 78, .delay = 2, .observe = true, .length = 5, .offset = 0, .bytes = chunk[0..5] } });
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
    // A delay out of 2 to 6.
    for ([_]u8{ 1, 7 }) |d| {
        const w = encode(.{ .welcome = .{ .session = 1, .delay = 3, .resume_from = 0 } }, &buf);
        w[9] = d;
        try testing.expectError(error.Malformed, decode(w));
    }
    // A status of no game with a character, of play without one, an unknown game or character;
    // a join as no character the game has.
    for ([_][2]u8{ .{ 0, 1 }, .{ 2, no_character }, .{ 3, no_character }, .{ 1, 3 } }) |v| {
        try testing.expectError(error.Malformed, decode(&.{ 11, v[0], v[1], 0 }));
    }
    try testing.expectError(error.Malformed, decode(&.{ 11, 0, no_character, 32 }));
    // An event of no kind, a leave with a character, a coming back without one.
    try testing.expectError(error.Malformed, decode(&.{ 19, 0, 0, 0, 0, 4, no_character, 0, 0, 0 }));
    try testing.expectError(error.Malformed, decode(&.{ 19, 0, 0, 0, 0, 1, 1, 0, 0, 0 }));
    try testing.expectError(error.Malformed, decode(&.{ 19, 0, 0, 0, 0, 2, no_character, 0, 0, 0 }));
    // Rules out of their bounds, or carried by another change.
    try testing.expectError(error.Malformed, decode(&.{ 19, 0, 0, 0, 0, 3, no_character, 0, 3, 1 }));
    try testing.expectError(error.Malformed, decode(&.{ 19, 0, 0, 0, 0, 1, no_character, 3, 0, 0 }));
    try testing.expectError(error.Malformed, decode(&.{ 14, 2 }));
    try testing.expectError(error.Malformed, decode(&.{ 18, 2, 0 }));
    try testing.expectError(error.Malformed, decode(&.{ 18, 1, 3 }));
    // Ticks: none, or more than a message may carry, or an odd byte.
    try testing.expectError(error.Malformed, decode(&.{ 15, 0, 0, 0, 0, 0 }));
    try testing.expectError(error.Malformed, decode(&.{ 15, 0, 0, 0, 0, 1, 7 }));
    try testing.expectError(error.Malformed, decode(&.{ 12, 3 }));
    // A game's chunk of session 0, or off the grid.
    const g = encode(.{ .game = .{ .session = 1, .delay = 2, .length = 1, .offset = 0, .bytes = &.{0} } }, &buf);
    @memset(g[1..9], 0);
    try testing.expectError(error.Malformed, decode(g));
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

//! Replays (DESIGN.md 10.8): the rolling recording of a local game, the replay file that F5 writes
//! from it, and the file read back to be played (`--replay`).
//!
//! The recording (`Recording`) keeps the last 20 seconds of display ticks in memory, bounded: the
//! game's state every 5 seconds, as network play's join carries a game (game.zig `joinForm`: its
//! canonical form, DESIGN.md 6, and this machine's sound as it plays), and each display tick's
//! pads as the game read them, the buttons the controller overlay showed (`Game.shown`) and this
//! machine's facts given to the tick (`State.Machine`). The oldest state kept and the ticks after
//! it play the last 20 seconds at least. A state changed between two ticks (a game left for the
//! menu, the settings' rules taken during a game) is a cut: that state is kept too, at its tick,
//! and the replay loads it there.
//!
//! The file (`version` 1), each number little-endian:
//! - the header (`Header`): `magic`; the format's version (u16); the build's identity and the
//!   game data's (32 bytes each), as network play's handshake knows them (net/protocol.zig
//!   `buildId`, net/identity.zig); the variant the game played (u8, its number); the display
//!   ticks (u32); the game's display tick at the first (u32); when it was saved (i64, seconds
//!   since 1970 in UTC, 0 when the platform gives no date);
//! - then records, each a byte of its kind (`Kind`) and its body: `state`, a u32 length and a
//!   join form, loaded before the next tick; `machine`, a u32 length and the canonical form of the
//!   facts given to the ticks from here; `tick`, the four pads read (players 1 to 4, a byte each:
//!   input.zig `Pad`) and the four pads shown; `end`, the last.
//! A state and the facts come before the first tick; a file of other bytes is refused.
const std = @import("std");
const canonical = @import("canonical.zig");
const input = @import("input.zig");
const protocol = @import("net/protocol.zig");
const variant = @import("variant.zig");
const game_mod = @import("game.zig");

const Machine = game_mod.State.Machine;

pub const magic = "SORZRPLY";
pub const version: u16 = 1;

/// The display ticks the recording keeps at least: 20 seconds at 59.92 a second.
pub const ticks_kept = 1199;
/// A state kept every 5 seconds' display ticks.
pub const state_every = 300;
/// The ticks it has room for: those kept, and those since the oldest state kept.
pub const tick_room = ticks_kept + state_every;
/// The states it has room for: those of the periodic ones that the ticks kept need, and cuts.
pub const state_room = tick_room / state_every + 3;

/// What a display tick took: its pads, the buttons shown, and the machine's facts.
pub const Tick = struct {
    pads: input.Pads,
    shown: input.Pads,
    machine: Machine,
};

/// What a replay file says of itself.
pub const Header = struct {
    build: protocol.Build,
    data: protocol.DataId,
    variant: variant.Variant,
    ticks: u32,
    first_tick: u32,
    /// Seconds since 1970 in UTC; 0 unknown.
    saved_s: i64 = 0,

    pub const size = magic.len + 2 + 32 + 32 + 1 + 4 + 4 + 8;

    fn write(h: *const Header, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(magic);
        try w.writeInt(u16, version, .little);
        try w.writeAll(&h.build);
        try w.writeAll(&h.data);
        try w.writeByte(@backingInt(h.variant));
        try w.writeInt(u32, h.ticks, .little);
        try w.writeInt(u32, h.first_tick, .little);
        try w.writeInt(i64, h.saved_s, .little);
    }

    /// The header of `bytes`: refused when they are no replay (`NotAReplay`) or one of another
    /// version of the format (`OtherVersion`).
    pub fn read(bytes: []const u8) ReadError!Header {
        if (bytes.len < magic.len + 2 or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.NotAReplay;
        if (std.mem.readInt(u16, bytes[magic.len..][0..2], .little) != version) return error.OtherVersion;
        if (bytes.len < size) return error.Malformed;
        var at: usize = magic.len + 2;
        var h: Header = undefined;
        @memcpy(&h.build, bytes[at..][0..32]);
        at += 32;
        @memcpy(&h.data, bytes[at..][0..32]);
        at += 32;
        h.variant = std.enums.fromInt(variant.Variant, bytes[at]) orelse return error.Malformed;
        at += 1;
        h.ticks = std.mem.readInt(u32, bytes[at..][0..4], .little);
        h.first_tick = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        h.saved_s = std.mem.readInt(i64, bytes[at + 8 ..][0..8], .little);
        return h;
    }
};

pub const Kind = enum(u8) { end = 0, state = 1, machine = 2, tick = 3 };

pub const ReadError = error{
    /// Not a replay file: its first bytes are not `magic`.
    NotAReplay,
    /// A replay of another version of the format.
    OtherVersion,
    /// A replay of another build: its states' forms may be another's.
    OtherBuild,
    /// A replay of other game data: its game is another's.
    OtherData,
    /// A replay whose records are not whole or not in order.
    Malformed,
    OutOfMemory,
};

/// Why a replay is refused, for the player.
pub fn refusal(err: ReadError) []const u8 {
    return switch (err) {
        error.NotAReplay => "it is not a replay file",
        error.OtherVersion => "it is a replay of another version of the format",
        error.OtherBuild => "it was recorded by another build of the game",
        error.OtherData => "it was recorded with other game data",
        error.Malformed => "it is damaged",
        error.OutOfMemory => "there is not enough memory",
    };
}

/// The identities a replay must have to be played here.
pub const Identity = struct { build: protocol.Build, data: protocol.DataId };

/// A state kept by the recording: before the tick `at` (the count of ticks recorded before it),
/// its form's bytes in `bytes` (`Recording`'s), the game's display tick then, and whether it was a
/// cut.
const Kept = struct { at: u64, len: u32, tick: u32, cut: bool };

/// The rolling recording: a ring of ticks and a ring of states, made at the first tick kept.
pub const Recording = struct {
    allocator: std.mem.Allocator,
    /// The forms' room: `form_room` bytes for each state.
    form_room: usize,
    ticks: []Tick = &.{},
    forms: []u8 = &.{},
    /// The ticks recorded since the recording began: tick `i` is at `ticks[i % tick_room]`.
    count: u64 = 0,
    states: [state_room]Kept = undefined,
    first: usize = 0,
    len: usize = 0,
    /// The ticks recorded since the last state kept.
    since_state: u32 = 0,
    /// The state changed between two ticks: the next tick keeps it.
    cut_due: bool = false,
    /// The memory was refused: nothing is recorded.
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, form_room: usize) Recording {
        return .{ .allocator = allocator, .form_room = form_room };
    }

    pub fn deinit(self: *Recording) void {
        self.allocator.free(self.ticks);
        self.allocator.free(self.forms);
        self.* = undefined;
    }

    /// Forgets what it kept (a session of network play: nothing of it is recorded); the next tick
    /// begins again.
    pub fn reset(self: *Recording) void {
        self.count = 0;
        self.len = 0;
        self.first = 0;
        self.since_state = 0;
        self.cut_due = false;
    }

    /// The game's state changed between two ticks: the next tick keeps it.
    pub fn cut(self: *Recording) void {
        if (self.len != 0) self.cut_due = true;
    }

    /// Whether the tick to come keeps the state before it (`keep`): the first, a cut, or the
    /// periodic one.
    pub fn stateDue(self: *const Recording) bool {
        return !self.failed and (self.len == 0 or self.cut_due or self.since_state >= state_every);
    }

    /// The room for the state to keep (`form_room` bytes), null when the memory is refused.
    pub fn room(self: *Recording) ?[]u8 {
        if (!self.made()) return null;
        // Full: the oldest goes.
        if (self.len == state_room) self.dropOldest();
        return self.formAt(self.len);
    }

    /// The state written in `room` (`len` bytes, the game at display tick `tick`) is kept before
    /// the tick to come.
    pub fn keep(self: *Recording, len: usize, tick: u32) void {
        std.debug.assert(len <= self.form_room and self.len < state_room);
        self.states[(self.first + self.len) % state_room] = .{ .at = self.count, .len = @intCast(len), .tick = tick, .cut = self.cut_due and self.len != 0 };
        self.len += 1;
        self.since_state = 0;
        self.cut_due = false;
    }

    /// A display tick, after the state before it was kept when it was due. A state whose ticks
    /// are no longer all kept goes.
    pub fn add(self: *Recording, t: Tick) void {
        if (self.len == 0 or !self.made()) return;
        self.ticks[@intCast(self.count % tick_room)] = t;
        self.count += 1;
        self.since_state += 1;
        while (self.len > 1 and self.count - self.oldest().at > tick_room) self.dropOldest();
    }

    /// The display ticks a replay of it would play.
    pub fn kept(self: *const Recording) u64 {
        if (self.len == 0) return 0;
        return self.count - self.oldest().at;
    }

    fn made(self: *Recording) bool {
        if (self.failed) return false;
        if (self.ticks.len != 0) return true;
        self.ticks = self.allocator.alloc(Tick, tick_room) catch return self.refused();
        self.forms = self.allocator.alloc(u8, self.form_room * state_room) catch return self.refused();
        return true;
    }

    fn refused(self: *Recording) bool {
        std.log.warn("no room to record the last seconds: F5 saves no replay", .{});
        self.allocator.free(self.ticks);
        self.ticks = &.{};
        self.failed = true;
        return false;
    }

    fn oldest(self: *const Recording) *const Kept {
        return &self.states[self.first];
    }

    fn dropOldest(self: *Recording) void {
        // The forms' room follows the states' places in the ring.
        self.first = (self.first + 1) % state_room;
        self.len -= 1;
    }

    /// The room of the `k`-th state from the oldest.
    fn formAt(self: *Recording, k: usize) []u8 {
        const slot = (self.first + k) % state_room;
        return self.forms[slot * self.form_room ..][0..self.form_room];
    }

    fn stateAt(self: *const Recording, k: usize) *const Kept {
        return &self.states[(self.first + k) % state_room];
    }

    /// Writes the replay file of what it kept: from its oldest state, the ticks since, the cuts'
    /// states at their ticks. `header`'s ticks and first tick are its own.
    pub fn write(self: *Recording, header: Header, w: *std.Io.Writer) std.Io.Writer.Error!void {
        std.debug.assert(self.len != 0);
        var h = header;
        h.ticks = @intCast(self.kept());
        h.first_tick = self.oldest().tick;
        try h.write(w);
        var next_state: usize = 0;
        var machine: ?Machine = null;
        var i = self.oldest().at;
        while (i < self.count) : (i += 1) {
            // The oldest state, and each cut's at its tick (the periodic ones follow from the
            // ticks).
            while (next_state < self.len and self.stateAt(next_state).at == i) : (next_state += 1) {
                const s = self.stateAt(next_state);
                if (next_state != 0 and !s.cut) continue;
                try w.writeByte(@backingInt(Kind.state));
                try w.writeInt(u32, s.len, .little);
                try w.writeAll(self.formAt(next_state)[0..s.len]);
            }
            const t = &self.ticks[@intCast(i % tick_room)];
            if (machine == null or !std.meta.eql(machine.?, t.machine)) {
                var buf: [canonical.maxSize(Machine)]u8 = undefined;
                const form = canonical.write(Machine, &t.machine, &buf);
                try w.writeByte(@backingInt(Kind.machine));
                try w.writeInt(u32, @intCast(form.len), .little);
                try w.writeAll(form);
                machine = t.machine;
            }
            try w.writeByte(@backingInt(Kind.tick));
            try w.writeAll(&padBytes(t.pads));
            try w.writeAll(&padBytes(t.shown));
        }
        try w.writeByte(@backingInt(Kind.end));
    }
};

fn padBytes(pads: input.Pads) [input.max_players]u8 {
    var out: [input.max_players]u8 = undefined;
    for (&out, 0..) |*b, k| b.* = @bitCast(pads.of(k));
    return out;
}

fn padsOf(bytes: *const [input.max_players]u8) input.Pads {
    var out: input.Pads = .{};
    for (bytes, 0..) |b, k| out.at(k).* = @bitCast(b);
    return out;
}

/// What comes before a display tick of a replay: a state to load, the facts from here, or the
/// tick's pads.
pub const Step = union(Kind) {
    end,
    state: []const u8,
    machine: Machine,
    tick: struct { pads: input.Pads, shown: input.Pads },
};

/// A replay file read: its header and its records in order.
pub const Replay = struct {
    allocator: std.mem.Allocator,
    header: Header,
    /// The file's bytes (the states' forms are in them).
    bytes: []u8,
    steps: []Step,

    /// Reads `bytes` (copied), refused unless it is a whole replay of this format, of `expect`'s
    /// build and data.
    pub fn read(allocator: std.mem.Allocator, bytes: []const u8, expect: Identity) ReadError!Replay {
        const header = try Header.read(bytes);
        if (!std.mem.eql(u8, &header.build, &expect.build)) return error.OtherBuild;
        if (!std.mem.eql(u8, &header.data, &expect.data)) return error.OtherData;
        const own = try allocator.dupe(u8, bytes);
        errdefer allocator.free(own);
        var steps: std.ArrayList(Step) = .empty;
        errdefer steps.deinit(allocator);
        var at: usize = Header.size;
        var ticks: u32 = 0;
        var has_state = false;
        var has_machine = false;
        while (true) {
            if (at >= own.len) return error.Malformed;
            const kind = std.enums.fromInt(Kind, own[at]) orelse return error.Malformed;
            at += 1;
            switch (kind) {
                .end => break,
                .state, .machine => {
                    if (own.len - at < 4) return error.Malformed;
                    const n = std.mem.readInt(u32, own[at..][0..4], .little);
                    at += 4;
                    if (n > own.len - at) return error.Malformed;
                    const body = own[at..][0..n];
                    at += n;
                    if (kind == .state) {
                        has_state = true;
                        try steps.append(allocator, .{ .state = body });
                    } else {
                        var m: Machine = .{};
                        canonical.read(Machine, body, &m) catch return error.Malformed;
                        has_machine = true;
                        try steps.append(allocator, .{ .machine = m });
                    }
                },
                .tick => {
                    if (!has_state or !has_machine) return error.Malformed;
                    if (own.len - at < 2 * input.max_players) return error.Malformed;
                    try steps.append(allocator, .{ .tick = .{
                        .pads = padsOf(own[at..][0..input.max_players]),
                        .shown = padsOf(own[at + input.max_players ..][0..input.max_players]),
                    } });
                    at += 2 * input.max_players;
                    ticks += 1;
                },
            }
        }
        if (at != own.len or ticks != header.ticks or ticks == 0) return error.Malformed;
        return .{ .allocator = allocator, .header = header, .bytes = own, .steps = try steps.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *Replay) void {
        self.allocator.free(self.steps);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// The replay's name in the storage: by the date and time it was saved (UTC), when the platform
/// gives them (`saved_s`), else by a counter past those there (`names`); `-2`, `-3` and on past a
/// name taken.
pub fn fileName(buf: *[64]u8, saved_s: ?i64, names: []const []const u8) []const u8 {
    var base_buf: [40]u8 = undefined;
    const base = if (saved_s) |s| blk: {
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(s, 0)) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        break :blk std.fmt.bufPrint(&base_buf, "replay-{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
            yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        }) catch unreachable;
    } else blk: {
        var most: u32 = 0;
        for (names) |n| if (counterOf(n)) |c| {
            most = @max(most, c);
        };
        break :blk std.fmt.bufPrint(&base_buf, "replay-{d:0>4}", .{most +| 1}) catch unreachable;
    };
    var k: u32 = 1;
    while (true) : (k += 1) {
        const name = if (k == 1)
            std.fmt.bufPrint(buf, "{s}" ++ extension, .{base}) catch unreachable
        else
            std.fmt.bufPrint(buf, "{s}-{d}" ++ extension, .{ base, k }) catch unreachable;
        if (!taken(names, name)) return name;
    }
}

/// The replays' files' extension.
pub const extension = ".sorzreplay";

fn taken(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// The counter of a name `replay-NNNN.sorzreplay`.
fn counterOf(name: []const u8) ?u32 {
    const prefix = "replay-";
    if (name.len < prefix.len + extension.len) return null;
    if (!std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) return null;
    if (!std.ascii.eqlIgnoreCase(name[name.len - extension.len ..], extension)) return null;
    return std.fmt.parseInt(u32, name[prefix.len .. name.len - extension.len], 10) catch null;
}

// --- tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn testTick(i: u64) Tick {
    return .{
        .pads = .{ .pad1 = .{ .right = i % 3 == 0, .b = i % 7 == 0 }, .pad2 = .{ .left = i % 5 == 0 } },
        .shown = .{ .pad1 = .{ .b = i % 7 == 0 } },
        .machine = .{ .second_pad = i < 400, .players_here = 2 },
    };
}

const test_identity: Identity = .{ .build = protocol.buildId("test"), .data = @splat(7) };

fn testHeader() Header {
    return .{ .build = test_identity.build, .data = test_identity.data, .variant = .extended, .ticks = 0, .first_tick = 0 };
}

/// Records `n` ticks, a state of 3 bytes (the tick's number) whenever due, a cut at `cut_at`.
fn record(r: *Recording, n: u64, cut_at: ?u64) void {
    for (0..n) |i| {
        if (cut_at == i) r.cut();
        if (r.stateDue()) {
            const room_ = r.room().?;
            std.mem.writeInt(u24, room_[0..3], @intCast(i), .little);
            r.keep(3, @intCast(i));
        }
        r.add(testTick(i));
    }
}

test "the recording keeps the last 20 seconds at least, in bounded memory" {
    var r: Recording = .init(testing.allocator, 16);
    defer r.deinit();
    try testing.expectEqual(@as(u64, 0), r.kept());
    record(&r, 100, null);
    try testing.expectEqual(@as(u64, 100), r.kept());
    record(&r, 10_000 - 100, null);
    // The oldest state is the one that covers the last 20 seconds; no more than its ticks.
    try testing.expect(r.kept() >= ticks_kept and r.kept() <= tick_room);
    try testing.expect(r.len <= state_room);
    const room_before = r.ticks.len + r.forms.len;
    record(&r, 5_000, null);
    try testing.expect(r.kept() >= ticks_kept and r.kept() <= tick_room);
    try testing.expectEqual(room_before, r.ticks.len + r.forms.len);
    try testing.expectEqual(@as(usize, tick_room), r.ticks.len);
    // 20 seconds at 59.92 display ticks a second.
    try testing.expect(ticks_kept * 100 >= 20 * 5992);
}

test "a replay file is read back as it was written: its states, facts and ticks" {
    var r: Recording = .init(testing.allocator, 16);
    defer r.deinit();
    record(&r, 2000, 1900);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var h = testHeader();
    h.saved_s = 1_762_600_000;
    try r.write(h, &out.writer);
    var replay = try Replay.read(testing.allocator, out.written(), test_identity);
    defer replay.deinit();
    try testing.expectEqual(@as(u32, @intCast(r.kept())), replay.header.ticks);
    try testing.expectEqual(variant.Variant.extended, replay.header.variant);
    try testing.expectEqual(@as(i64, 1_762_600_000), replay.header.saved_s);
    const first: u64 = 2000 - r.kept();
    try testing.expectEqual(@as(u32, @intCast(first)), replay.header.first_tick);
    // The first state, then the ticks from it in order, the cut's state before tick 1900, the
    // facts as they change.
    var i: u64 = first;
    var states: u32 = 0;
    var machine: ?Machine = null;
    for (replay.steps) |s| switch (s) {
        .state => |form| {
            try testing.expectEqual(@as(u24, @intCast(i)), std.mem.readInt(u24, form[0..3], .little));
            try testing.expect(states == 0 or i == 1900);
            states += 1;
        },
        .machine => |m| machine = m,
        .tick => |t| {
            const want = testTick(i);
            try testing.expectEqual(want.pads, t.pads);
            try testing.expectEqual(want.shown, t.shown);
            try testing.expectEqual(want.machine, machine.?);
            i += 1;
        },
        .end => unreachable,
    };
    try testing.expectEqual(@as(u64, 2000), i);
    try testing.expectEqual(@as(u32, 2), states);
}

test "a replay of another build, of other data, of another version or damaged is refused" {
    var r: Recording = .init(testing.allocator, 16);
    defer r.deinit();
    record(&r, 50, null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try r.write(testHeader(), &out.writer);
    const bytes = out.written();
    try testing.expectError(error.OtherBuild, Replay.read(testing.allocator, bytes, .{ .build = protocol.buildId("other"), .data = test_identity.data }));
    try testing.expectError(error.OtherData, Replay.read(testing.allocator, bytes, .{ .build = test_identity.build, .data = @splat(8) }));
    try testing.expectError(error.NotAReplay, Replay.read(testing.allocator, "{ \"version\": 5 }", test_identity));
    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    copy[magic.len] = 9;
    try testing.expectError(error.OtherVersion, Replay.read(testing.allocator, copy, test_identity));
    // Cut short, or with a byte past its end.
    try testing.expectError(error.Malformed, Replay.read(testing.allocator, bytes[0 .. bytes.len - 3], test_identity));
    const longer = try std.mem.concat(testing.allocator, u8, &.{ bytes, "x" });
    defer testing.allocator.free(longer);
    try testing.expectError(error.Malformed, Replay.read(testing.allocator, longer, test_identity));
    try testing.expectEqualStrings("it was recorded by another build of the game", refusal(error.OtherBuild));
}

test "the replays' names: by date and time, else by a counter, never one taken" {
    var buf: [64]u8 = undefined;
    // 2026-11-08 14:30:05 UTC.
    try testing.expectEqualStrings("replay-2026-11-08-143005.sorzreplay", fileName(&buf, 1_794_148_205, &.{}));
    try testing.expectEqualStrings("replay-2026-11-08-143005-2.sorzreplay", fileName(&buf, 1_794_148_205, &.{"replay-2026-11-08-143005.sorzreplay"}));
    try testing.expectEqualStrings("replay-0001.sorzreplay", fileName(&buf, null, &.{"settings.json"}));
    try testing.expectEqualStrings("replay-0013.sorzreplay", fileName(&buf, null, &.{ "replay-0004.sorzreplay", "REPLAY-0012.SORZREPLAY" }));
    try std.testing.expect(fileName(&buf, null, &.{}).len <= 64);
}

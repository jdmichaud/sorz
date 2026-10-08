//! sorz-netplay-check: network play's flows on the real game (DESIGN.md 9, PLAN items 18 and 26),
//! several games in one process over the in-memory network, each in its own agent backend with its
//! own clock and keys, on the content extracted from the user's ROM, as the hosts run them. The
//! host is the native game (the extended variant, its menu's NETWORK PLAY); its clients play the
//! network variant (a page's, `--join`'s).
//!
//!   sorz-netplay-check ROM [--pictures DIR] [FLOW...]
//!
//! - own_menus: each machine at its own menu; the client's name entry first, its menu NAME, JOIN,
//!   OBSERVE and OPTIONS, JOIN and OBSERVE dimmed until the host's NETWORK PLAY opens its session
//!   (its network options' START, the host at its select alone); the host lists the client; the
//!   client's OPTIONS (its own lines alone) and ADVANCED SETTINGS (one player's), the host not
//!   held.
//! - select: the client's JOIN joins the host at its select: both selects with two players, each
//!   player's cursor its own; both choose, round 1 with two players; the two games the same at the
//!   same ticks (state and picture), the client's sound the host's from the join on, the session's
//!   checks finding no difference; player 1's START in play opens its settings in place of the
//!   pause: both games hold, the client says why, and both go on once player 1 leaves them.
//! - round: the host plays round 1 alone a while; the client's player chooses a character on its
//!   own select (the host's taken), joins mid-round as it, and drops in; the same state, picture
//!   and sound after the join and on; a second client watches (OBSERVE): the same game, behind;
//!   the player quits: the host plays on, player 2 out of the game, its observer with it; the
//!   observer leaves with START, back to its menu; a new client joins; the host quits: its client
//!   goes back to its own menu, told why.
//! - away: the connection drops in the round: both hold, the host counting the seconds down; the
//!   client back in time, the same session goes on; the connection drops again and the client is
//!   not back in time: the host plays on without player 2, and the client, back, goes to its own
//!   menu.
//! - difference: a bit of the client's state flipped in a session: both games stop at the next
//!   check and name the first field that differs.
//!
//! Prints a JSON line per flow, and exits with 1 when a step fails; with `--pictures`, two pictures
//! that differ are written there (host.png, guest.png).
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const extract = @import("extract");

const platform = sorz.platform;
const net = sorz.net;
const Key = platform.Key;
const frame_ns = agent.netplay_cmd.frame_ns;

/// A machine: a game in its own agent backend, one tick per update, on the in-memory network.
const Machine = struct {
    backend: agent.AgentBackend,
    storage: sorz.memory.MemoryStorage,
    game: sorz.Game,
    /// Frozen: no update (a machine whose player walked away, its connection with it).
    frozen: bool = false,
    /// The sound's frames since the session began (none outside one).
    pcm: *std.ArrayList(i16) = undefined,

    fn create(gpa: std.mem.Allocator, assets: platform.AssetSource, network: *net.memory.Network, role: net.netplay.Role, name: ?[3]u8) !*Machine {
        const m = try gpa.create(Machine);
        errdefer gpa.destroy(m);
        m.backend = agent.AgentBackend.init(gpa, .{});
        m.storage = sorz.memory.MemoryStorage.init(gpa);
        m.game = try sorz.Game.init(gpa, assets, m.storage.storage());
        m.frozen = false;
        m.backend.audio.record = true;
        m.pcm = &m.backend.audio.pcm;
        m.game.pacing = .per_update;
        // The host the native game, its clients a page's or `--join`'s.
        m.game.variant = if (role == .host) .extended else .network;
        if (name) |n| m.game.settings.name = n;
        m.backend.transport = (try network.endpoint()).transport();
        try m.game.startNetplay(.{
            .role = role,
            .address = if (role == .host) "7000" else "ws://localhost:7000",
            .build = net.protocol.buildId(sorz.version.build),
            .data = @splat(1),
            .delay = if (role == .host) 3 else null,
            .log = false,
        });
        return m;
    }

    fn destroy(m: *Machine, gpa: std.mem.Allocator) void {
        m.game.deinit();
        m.storage.deinit();
        m.backend.deinit();
        gpa.destroy(m);
    }

    fn update(m: *Machine) !void {
        if (m.frozen) return;
        var p = m.backend.asPlatform();
        const was = m.inSession();
        const before = m.pcm.items.len;
        _ = try m.game.update(&p);
        m.backend.advance(frame_ns);
        // The sound's frames from the session's first tick (an update starts it before its tick).
        if (!m.inSession()) {
            m.pcm.clearRetainingCapacity();
        } else if (!was) {
            const n = m.pcm.items.len - before;
            std.mem.copyForwards(i16, m.pcm.items[0..n], m.pcm.items[before..]);
            m.pcm.shrinkRetainingCapacity(n);
        }
    }

    fn key(m: *Machine, k: Key, down: bool) !void {
        try m.backend.inject(.{ .time_ns = m.backend.clock_ns, .payload = if (down) .{ .key_down = .{ .key = k } } else .{ .key_up = .{ .key = k } } });
    }

    fn scene(m: *const Machine) sorz.flow.Kind {
        return std.meta.activeTag(m.game.state.scenes.base);
    }

    fn np(m: *const Machine) *net.Netplay {
        return m.game.netplay.?;
    }

    fn inSession(m: *const Machine) bool {
        const n = m.game.netplay orelse return false;
        return n.inSession();
    }

    fn message(m: *Machine) ?sorz.overlay.Message {
        const o = m.game.overlays.find(.network) orelse return null;
        return o.network.what;
    }

    fn seconds(m: *Machine) u8 {
        const o = m.game.overlays.find(.network) orelse return 0;
        return o.network.seconds;
    }
};

/// The machines of a flow, updated in turn.
const Room = struct {
    gpa: std.mem.Allocator,
    assets: platform.AssetSource,
    network: net.memory.Network,
    machines: std.ArrayList(*Machine) = .empty,

    fn init(gpa: std.mem.Allocator, assets: platform.AssetSource) Room {
        return .{ .gpa = gpa, .assets = assets, .network = .init(gpa) };
    }

    fn deinit(r: *Room) void {
        for (r.machines.items) |m| m.destroy(r.gpa);
        r.machines.deinit(r.gpa);
        r.network.deinit();
    }

    /// A machine of `role`; a client already named, unless `name` is null.
    fn add(r: *Room, role: net.netplay.Role) !*Machine {
        return r.addNamed(role, if (role == .guest) "CLI".* else null);
    }

    fn addNamed(r: *Room, role: net.netplay.Role, name: ?[3]u8) !*Machine {
        const m = try Machine.create(r.gpa, r.assets, &r.network, role, name);
        errdefer m.destroy(r.gpa);
        try r.machines.append(r.gpa, m);
        return m;
    }

    /// Takes a machine out (its game quit): it is gone.
    fn remove(r: *Room, m: *Machine) void {
        for (r.machines.items, 0..) |x, i| if (x == m) {
            _ = r.machines.orderedRemove(i);
            break;
        };
        m.destroy(r.gpa);
    }

    fn step(r: *Room, n: usize) !void {
        for (0..n) |_| for (r.machines.items) |m| try m.update();
    }

    /// `k` on machine `m`: pressed for an update of the room, then released for one.
    fn press(r: *Room, m: *Machine, k: Key) !void {
        try m.key(k, true);
        try r.step(1);
        try m.key(k, false);
        try r.step(1);
    }
};

const Failure = error{StepFailed};

const Flow = struct {
    out: *std.Io.Writer,
    name: []const u8,
    steps: u32 = 0,
    failed: ?[]const u8 = null,
    /// What the flow measured, for its line.
    notes: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn check(f: *Flow, ok: bool, what: []const u8) Failure!void {
        f.steps += 1;
        if (ok) return;
        f.failed = what;
        return error.StepFailed;
    }

    /// Steps the room until `cond` holds, `limit` updates at most.
    fn until(f: *Flow, r: *Room, ctx: anytype, cond: *const fn (@TypeOf(ctx)) bool, limit: u32, what: []const u8) !void {
        var n: u32 = 0;
        while (!cond(ctx)) : (n += 1) {
            if (n == limit) return f.check(false, what);
            try r.step(1);
        }
        try f.check(true, what);
    }

    fn note(f: *Flow, comptime fmt: []const u8, args: anytype) void {
        if (f.notes.items.len != 0) f.notes.append(f.gpa, ',') catch {};
        f.notes.print(f.gpa, fmt, args) catch {};
    }

    fn report(f: *Flow) !void {
        try f.out.print("{{\"flow\":\"{s}\",\"pass\":{},\"steps\":{d}", .{ f.name, f.failed == null, f.steps });
        if (f.failed) |w| try f.out.print(",\"failed\":\"{s}\"", .{w});
        if (f.notes.items.len != 0) try f.out.print(",{s}", .{f.notes.items});
        try f.out.writeAll("}\n");
        try f.out.flush();
    }
};

fn choosing(m: *Machine) bool {
    const menu = switch (m.game.state.scenes.base) {
        .menu => |*x| x,
        else => return false,
    };
    return menu.phase == .choosing and !m.game.overlays.holds();
}

fn menuChoice(m: *const Machine) ?sorz.variant.MenuLine {
    return switch (m.game.state.scenes.base) {
        .menu => |*x| x.choice,
        else => null,
    };
}

fn selectOf(m: *const Machine) ?*const sorz.scene.Select {
    return switch (m.game.state.scenes.base) {
        .select => |*s| s,
        else => null,
    };
}

fn inSelect(m: *Machine) bool {
    const s = selectOf(m) orelse return false;
    return (s.phase == .first_half or s.phase == .second_half) and m.game.state.scenes.overlay_count == 0;
}

fn roundOf(m: *const Machine) ?*const sorz.scene.Round {
    return switch (m.game.state.scenes.base) {
        .round => |*x| x,
        else => null,
    };
}

fn playing(m: *Machine) bool {
    const x = roundOf(m) orelse return false;
    return x.phase == .play and m.game.state.scenes.overlay_count == 0;
}

fn settingsOpen(m: *Machine) bool {
    return m.game.settingsOpen();
}

fn settingsClosed(m: *Machine) bool {
    return !m.game.settingsOpen();
}

fn inOptions(m: *Machine) bool {
    return switch (m.game.state.scenes.base) {
        .options => |*o| o.phase == .lines and m.game.state.scenes.overlay_count == 0,
        else => false,
    };
}

fn inSession(m: *Machine) bool {
    return m.inSession();
}

/// To the game menu, from wherever the machine's front end is: START every 40 updates of the room
/// (the others run on), until the menu chooses.
fn toMenu(f: *Flow, r: *Room, m: *Machine) !void {
    var n: u32 = 0;
    while (!choosing(m)) : (n += 1) {
        if (n == 4000) return f.check(false, "the game menu");
        if (n % 40 == 39) try r.press(m, .enter) else try r.step(1);
    }
    try f.check(true, "the game menu");
}

/// Both machines run until they are at the same tick (one of them may have run ahead of a hold).
fn level(r: *Room, a: *Machine, b: *Machine) !void {
    var n: usize = 0;
    while (a.game.state.tick != b.game.state.tick and n < 64) : (n += 1) {
        if (a.game.state.tick < b.game.state.tick) try a.update() else try b.update();
    }
    _ = r;
}

/// Where two pictures that differ are written (`--pictures`).
var pictures: ?[]const u8 = null;
var tool_io: std.Io = undefined;

/// The two games are the same: at the same tick, the same state, the same picture.
fn same(f: *Flow, r: *Room, a: *Machine, b: *Machine, what: []const u8) !void {
    try level(r, a, b);
    try f.check(a.game.state.tick == b.game.state.tick and a.game.stateHash() == b.game.stateHash(), what);
    // The games' pictures, without each machine's own overlays (the host's list of who is
    // connected, a message).
    const ha = std.hash.Fnv1a_64.hash(a.game.scenesFrame().pixels);
    const hb = std.hash.Fnv1a_64.hash(b.game.scenesFrame().pixels);
    if (ha != hb) if (pictures) |dir| {
        for ([_]*Machine{ a, b }, [_][]const u8{ "host.png", "guest.png" }) |m, name| {
            const frame = m.game.scenesFrame();
            const bytes = try agent.png.encode(r.gpa, frame.width, frame.height, frame.pixels[0 .. frame.stride * frame.height]);
            defer r.gpa.free(bytes);
            const path = try std.fs.path.join(r.gpa, &.{ dir, name });
            defer r.gpa.free(path);
            try std.Io.Dir.cwd().writeFile(tool_io, .{ .sub_path = path, .data = bytes });
        }
    };
    try f.check(ha == hb, "the same picture");
}

/// With `--pictures`, the picture `m` presented last (its overlays with it) as `name`.
fn shot(r: *Room, m: *Machine, name: []const u8) !void {
    const dir = pictures orelse return;
    const frame = m.backend.captureFrame() orelse return;
    const bytes = try agent.png.encode(r.gpa, frame.width, frame.height, frame.pixels[0 .. frame.stride * frame.height]);
    defer r.gpa.free(bytes);
    const path = try std.fs.path.join(r.gpa, &.{ dir, name });
    defer r.gpa.free(path);
    try std.Io.Dir.cwd().writeFile(tool_io, .{ .sub_path = path, .data = bytes });
}

/// Runs `n` updates of the room, the two games compared every 60.
fn sameFor(f: *Flow, r: *Room, a: *Machine, b: *Machine, n: usize) !void {
    var done: usize = 0;
    while (done < n) : (done += 60) {
        try r.step(60);
        try same(f, r, a, b, "the same state, tick by tick");
    }
    try f.check(a.np().difference == null and b.np().difference == null and a.np().phase() == .playing, "the session's checks agree");
}

/// The two machines' sound since the session began: the same frames, as far as both played,
/// not silence.
fn sameSound(f: *Flow, a: *Machine, b: *Machine) !void {
    const n = @min(a.pcm.items.len, b.pcm.items.len);
    var peak: u32 = 0;
    for (a.pcm.items[0..n]) |v| peak = @max(peak, @abs(v));
    const first = std.mem.indexOfDiff(i16, a.pcm.items[0..n], b.pcm.items[0..n]);
    if (first) |i| f.note("\"sound_differs_at_frame\":{d}", .{i / 2});
    try f.check(n >= 2 * 800 * 300 and peak > 1000 and first == null, "the same sound since the join, frame by frame");
}

/// The song the game's sound plays (its sequencer's), if any.
fn song(m: *const Machine) ?u16 {
    const s = m.game.sound orelse return null;
    const x = s.sound orelse return null;
    return x.sequencer.song;
}

fn lines(m: *const Machine) []const sorz.variant.MenuLine {
    const menu = &m.game.state.scenes.base.menu;
    return menu.lines[0..menu.line_count];
}

/// The host's NETWORK PLAY: its menu to the network options (START), and to its select alone.
fn hostNetworkPlay(f: *Flow, r: *Room, host: *Machine) !void {
    try toMenu(f, r, host);
    while (menuChoice(host) != .network_play) try r.press(host, .down);
    try r.press(host, .z);
    try f.until(r, host, struct {
        fn open(m: *Machine) bool {
            return m.game.overlays.find(.net_options) != null;
        }
    }.open, 200, "the network options");
    try r.press(host, .enter);
    try f.until(r, host, inSelect, 600, "the host's select");
    try f.check(host.np().open and selectOf(host).?.players == .one, "the session open, the host alone at its select");
}

/// A client's JOIN, once the host takes a player.
fn clientJoins(f: *Flow, r: *Room, c: *Machine) !void {
    try toMenu(f, r, c);
    try f.until(r, c, struct {
        fn can(m: *Machine) bool {
            const menu = switch (m.game.state.scenes.base) {
                .menu => |*x| x,
                else => return false,
            };
            return m.np().welcomed() and m.np().hostStatus().place and menu.dimmed & 2 == 0;
        }
    }.can, 300, "the client's JOIN can be chosen");
    while (menuChoice(c) != .join) try r.press(c, .down);
    try r.press(c, .z);
}

fn ownMenus(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const client = try r.addNamed(.guest, null);
    try toMenu(f, r, host);
    try f.check(std.mem.eql(sorz.variant.MenuLine, lines(host), &.{ .one_player, .two_players, .network_play, .options }), "the host's menu: 1 PLAYER, 2 PLAYERS, NETWORK PLAY, OPTIONS");
    // The client's name first: the entry opens at its menu (START on its intro and title to get
    // there); down on the first letter, then START.
    var n: u32 = 0;
    while (client.game.overlays.find(.name_entry) == null) : (n += 1) {
        if (n == 4000) return f.check(false, "the client's name entry");
        if (n % 40 == 39) try r.press(client, .enter) else try r.step(1);
    }
    try f.check(true, "the client's name entry");
    try r.press(client, .down);
    try r.press(client, .enter);
    try f.check(std.mem.eql(u8, &client.game.settings.name, "BAA") and client.game.overlays.find(.name_entry) == null, "the name kept");
    try toMenu(f, r, client);
    try f.check(std.mem.eql(sorz.variant.MenuLine, lines(client), &.{ .name, .join, .observe, .options }), "the client's menu: NAME, JOIN, OBSERVE, OPTIONS");
    try r.step(30);
    try f.check(client.game.state.scenes.base.menu.dimmed == 0b0110, "JOIN and OBSERVE dimmed: no session yet");
    // The host's NETWORK PLAY: the client's JOIN and OBSERVE lit; the host lists it.
    try hostNetworkPlay(f, r, host);
    try r.step(30);
    try f.check(client.game.state.scenes.base.menu.dimmed == 0, "JOIN and OBSERVE lit once the session is open");
    const roster = host.game.overlays.find(.roster);
    try f.check(roster != null and roster.?.roster.len == 1 and std.mem.eql(u8, &roster.?.roster.entries[0].name, "BAA") and roster.?.roster.entries[0].doing == .menu, "the host lists BAA (MENU)");
    // The client's OPTIONS: its own lines alone; ADVANCED SETTINGS, one player's; the host not
    // held.
    while (menuChoice(client) != .options) try r.press(client, .down);
    try r.press(client, .enter);
    try f.until(r, client, inOptions, 400, "the client's OPTIONS");
    const o = &client.game.state.scenes.base.options;
    try f.check(o.own_only and o.advanced_settings, "the client's OPTIONS show its own lines alone");
    try r.press(client, .up);
    try r.press(client, .up);
    try f.check(client.game.state.scenes.base.options.line == .advanced_settings, "ADVANCED SETTINGS");
    try r.press(client, .z);
    try f.until(r, client, settingsOpen, 80, "the client's settings open");
    const screen = client.game.overlays.find(.settings);
    try f.check(screen != null and screen.?.settings.facts.players == 1, "the client's settings open, one player's");
    const ticks = host.game.state.tick;
    try r.step(30);
    try f.check(host.game.state.tick >= ticks + 30 and host.game.overlays.find(.peer_settings) == null, "the host not held");
    try r.press(client, .escape);
    try f.until(r, client, settingsClosed, 80, "Escape leaves them");
    try f.check(!host.inSession() and !client.inSession(), "no session");
    f.note("\"host\":\"{s}\",\"client\":\"{s}\"", .{ @tagName(host.scene()), @tagName(client.scene()) });
}

fn atSelect(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try hostNetworkPlay(f, r, host);
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSession, 600, "the client joins at the select");
    try f.until(r, guest, inSelect, 100, "the client at the host's select");
    try same(f, r, host, guest, "the same select on both");
    try f.check(selectOf(host).?.players == .two and selectOf(guest).?.players == .two, "two players at the select");
    // Each player's cursor its own: the host's right, the client's left.
    const before = selectOf(host).?.cursors;
    try r.press(host, .right);
    try r.step(6);
    try r.press(guest, .left);
    try r.step(10);
    try same(f, r, host, guest, "the same select after the cursors' moves");
    const after = selectOf(host).?.cursors;
    try f.check(after[0].place != before[0].place and after[1].place != before[1].place, "each player moved its own cursor");
    try r.press(host, .z);
    try r.press(guest, .z);
    try f.until(r, host, playing, 2400, "round 1");
    try f.until(r, guest, playing, 100, "round 1 on the client");
    try same(f, r, host, guest, "the same round");
    const w = &roundOf(host).?.play.world;
    try f.check(w.players[0].entity != null and w.players[1].entity != null and host.game.state.setup.players == .two, "two players in the round");
    try f.check(song(host) != null and song(host) == song(guest), "the client's sound plays the round's music");
    try sameFor(f, r, host, guest, 600);
    try sameSound(f, host, guest);
    // Player 1's START in play: its settings, in place of the pause; both games hold, the client
    // says why; Escape (save and leave), and both go on.
    try r.press(host, .enter);
    try r.step(12);
    try f.check(host.game.settingsOpen() and !guest.game.settingsOpen() and roundOf(host).?.phase == .play, "player 1's START opens its settings, the round not paused");
    try f.check(guest.game.overlays.find(.peer_settings) != null, "the client says player 1 is in the settings");
    const held = .{ host.game.state.tick, guest.game.state.tick };
    try r.step(60);
    try f.check(host.game.state.tick == held[0] and guest.game.state.tick == held[1], "both games hold");
    try r.press(host, .escape);
    try r.step(12);
    try f.check(!host.game.settingsOpen() and guest.game.overlays.find(.peer_settings) == null and guest.game.state.tick > held[1], "both go on");
    try sameFor(f, r, host, guest, 120);
    f.note("\"session_tick\":{d},\"state_hash\":\"{x:0>16}\",\"song\":{?d}", .{ host.np().tick(), host.game.stateHash(), song(guest) });
}

/// A client from power-on to its select by JOIN, its character chosen there: `right` moves of its
/// cursor, then A.
fn guestChooses(f: *Flow, r: *Room, g: *Machine, rights: usize) !void {
    try clientJoins(f, r, g);
    try f.until(r, g, inSelect, 600, "the client's own select");
    for (0..rights) |_| {
        try r.press(g, .right);
        try r.step(4);
    }
    try r.press(g, .z);
}

fn observing(m: *Machine) bool {
    const n = m.game.netplay orelse return false;
    return n.observing() and m.scene() == .round;
}

fn inRound(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    try hostNetworkPlay(f, r, host);
    try r.press(host, .right);
    try r.step(4);
    try f.check(selectOf(host).?.cursors[0].place == .axel, "the host's cursor on Axel");
    try r.press(host, .z);
    try f.until(r, host, playing, 2400, "the host plays round 1 alone");
    const first = host.game.state.setup.characters[0].?;
    // It plays alone a while: walking, striking.
    try host.key(.right, true);
    try r.step(120);
    try host.key(.right, false);
    try r.press(host, .x);
    try r.step(200);
    try f.check(roundOf(host).?.play.world.players[1].entity == null, "player 2 not in the game");

    // The client's own select: the host's character is taken (its cursor passes it).
    const guest = try r.add(.guest);
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSelect, 600, "the client's own select");
    try r.step(30);
    for (0..3) |_| {
        try r.press(guest, .right);
        try r.step(4);
        try f.check(selectOf(guest).?.cursors[0].place != first, "the host's character is taken");
    }
    const chosen = selectOf(guest).?.cursors[0].place;
    try r.press(guest, .z);
    try f.until(r, guest, inSession, 600, "the client joins the round");
    try f.until(r, host, struct {
        fn in(m: *Machine) bool {
            const x = roundOf(m) orelse return false;
            return x.play.world.players[1].entity != null;
        }
    }.in, 200, "player 2 drops in");
    try same(f, r, host, guest, "the same round after the join");
    try f.check(host.game.state.setup.characters[1] == chosen, "player 2 as the client chose");
    try f.check(song(guest) != null and song(guest) == song(host), "the client's sound plays the round's music");
    try sameFor(f, r, host, guest, 600);
    try sameSound(f, host, guest);
    f.note("\"joined_at\":{d},\"character\":\"{s}\"", .{ host.game.state.tick, @tagName(chosen) });

    // A second client: no place (JOIN dimmed); it watches: the same game, behind.
    const watcher = try r.addNamed(.guest, "OBS".*);
    try toMenu(f, r, watcher);
    try r.step(10);
    try f.check(watcher.game.state.scenes.base.menu.dimmed == 0b0010, "no place: JOIN dimmed, OBSERVE lit");
    while (menuChoice(watcher) != .observe) try r.press(watcher, .down);
    try r.press(watcher, .z);
    try f.until(r, watcher, observing, 600, "the second client watches");
    try r.step(30);
    try same(f, r, host, watcher, "the observer's game the host's");
    const roster = host.game.overlays.find(.roster);
    try f.check(roster == null, "no list over the round");
    try sameFor(f, r, host, guest, 120);
    try same(f, r, host, watcher, "the observer's game the host's, on");

    // The player quits: the host plays on, player 2's fighter dies and it is out of the game; the
    // observer gets the game again.
    try guest.key(.escape, true);
    try guest.update();
    r.remove(guest);
    try r.step(30);
    try f.check(!host.inSession() and roundOf(host).?.play.world.players[1].gone, "player 2 gone from the game");
    try f.check(host.message() == .player_2_left, "the host is told");
    try f.until(r, host, struct {
        fn out(m: *Machine) bool {
            const pl = &roundOf(m).?.play.world.players[1];
            return pl.entity == null and pl.out;
        }
    }.out, 600, "player 2's fighter dead, out of the game");
    const ticks = host.game.state.tick;
    try r.step(60);
    try f.check(host.game.state.tick >= ticks + 60, "the host plays on");
    try same(f, r, host, watcher, "the observer's game the host's without player 2");

    // The observer leaves with START: back at its own menu.
    try r.press(watcher, .enter);
    try f.until(r, watcher, choosing, 600, "the observer back at its menu");
    try f.check(!watcher.inSession(), "it watches no more");
    r.remove(watcher);

    // A new client joins later.
    const next = try r.add(.guest);
    try guestChooses(f, r, next, 1);
    try f.until(r, next, inSession, 600, "the new client joins");
    try r.step(30);
    try same(f, r, host, next, "the same round with the new client");
    try f.check(roundOf(host).?.play.world.players[1].entity != null, "the new player 2 in the game");
    try sameFor(f, r, host, next, 300);
    f.note("\"sessions\":{d}", .{host.np().sessions});

    // The host quits: its client goes back to its own menu, told why.
    try host.key(.escape, true);
    try host.update();
    r.remove(host);
    try f.until(r, next, choosing, 900, "the client back at its menu");
    try f.check(!next.inSession() and next.message() == .player_1_left, "the client is told player 1 left");
}

fn away(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try hostNetworkPlay(f, r, host);
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSession, 900, "the client joins");
    try f.until(r, guest, inSelect, 200, "the select on the client");
    // Player 1 Axel (the content's fighter), player 2 where its cursor starts.
    try r.press(host, .right);
    try r.step(6);
    try r.press(host, .z);
    try r.press(guest, .z);
    try f.until(r, host, playing, 2400, "round 1");
    try r.step(60);
    // The cable is pulled: both hold, and the host counts the seconds down.
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(host.backend.transport.?.context));
    r.network.breakLink(endpoint, host.np().player.?.connection.?);
    const at = host.game.state.tick;
    try r.step(30);
    try f.check(host.game.state.tick <= at + 4 and host.message() == .player_2_away and host.seconds() >= 4 and host.seconds() <= 5, "the host holds and counts the seconds down");
    try f.check(guest.message() == .player_1_away, "the client holds and says it waits");
    // The client is back after a second: the same session goes on.
    try f.until(r, host, struct {
        fn back(m: *Machine) bool {
            return m.game.netplay.?.connected() and m.message() == null;
        }
    }.back, 300, "the client back in time");
    try r.step(60);
    try same(f, r, host, guest, "the same session goes on");
    try f.check(host.np().sessions == 1, "the same session");
    // Pulled again, and the client's machine away longer than the host waits.
    r.network.breakLink(endpoint, host.np().player.?.connection.?);
    guest.frozen = true;
    const wait: usize = @intCast(net.session.rejoin_ns / frame_ns + 30);
    try r.step(wait);
    const w = &roundOf(host).?.play.world;
    const fighter = w.getConst(w.players[1].entity.?).?;
    try f.check(!host.inSession() and w.players[1].gone and fighter.health == 0, "the host gave player 2 up: its fighter's health gone");
    // It dies, as at the time over, and is out of the game; no invitation over its part.
    try f.until(r, host, struct {
        fn out(m: *Machine) bool {
            const pl = &roundOf(m).?.play.world.players[1];
            return pl.entity == null and pl.out;
        }
    }.out, 600, "player 2's fighter dead, out of the game");
    try r.step(40);
    try shot(r, host, "dropped_out.png");
    try f.check(!roundOf(host).?.join.shown, "no invitation over player 2's part");
    try f.check(host.game.state.tick > at + 60, "the host plays on alone");
    // The client's machine back: its session is over; its own menu again.
    guest.frozen = false;
    try f.until(r, guest, choosing, 900, "the client back at its own menu");
    try f.check(!guest.inSession(), "no session for the client");
    f.note("\"held_at\":{d}", .{at});
}

fn difference(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try hostNetworkPlay(f, r, host);
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSession, 900, "the client joins");
    try f.until(r, guest, inSelect, 200, "the select on the client");
    // Player 1 Axel (the content's fighter), player 2 where its cursor starts.
    try r.press(host, .right);
    try r.step(6);
    try r.press(host, .z);
    try r.press(guest, .z);
    try f.until(r, host, playing, 2400, "round 1");
    try r.step(30);
    // A bit of the client's random generator.
    guest.game.state.random.state ^= 1;
    try f.until(r, host, struct {
        fn found(m: *Machine) bool {
            return m.game.netplay.?.difference != null;
        }
    }.found, 200, "the host names the difference");
    try f.until(r, guest, struct {
        fn found(m: *Machine) bool {
            return m.game.netplay.?.difference != null;
        }
    }.found, 200, "the client names the difference");
    const d = host.np().difference.?;
    try f.check(std.mem.eql(u8, d.name(), "random.state") and std.mem.eql(u8, guest.np().difference.?.name(), "random.state"), "both name the field");
    try f.check(host.message() == .desynced and guest.message() == .desynced, "both stop and say why");
    f.note("\"difference\":\"{f}\"", .{d});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const rom_path = args.next() orelse {
        try std.Io.File.stderr().writeStreamingAll(io, "usage: sorz-netplay-check ROM [FLOW...]\n");
        std.process.exit(2);
    };
    var only: std.ArrayList([]const u8) = .empty;
    tool_io = io;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--pictures")) {
            pictures = args.next();
            continue;
        }
        try only.append(arena, a);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(extract.rom.size + 1));
    defer gpa.free(rom);
    var tree = try extract.extract(gpa, rom);
    defer tree.deinit();
    var source = sorz.memory.MemoryAssetSource.init(gpa);
    defer source.deinit();
    try tree.addTo(&source);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var all = true;
    const Entry = struct { name: []const u8, run: *const fn (*Flow, *Room) anyerror!void };
    for ([_]Entry{
        .{ .name = "own_menus", .run = ownMenus },
        .{ .name = "select", .run = atSelect },
        .{ .name = "round", .run = inRound },
        .{ .name = "away", .run = away },
        .{ .name = "difference", .run = difference },
    }) |e| {
        if (only.items.len != 0) {
            var wanted = false;
            for (only.items) |o| wanted = wanted or std.mem.eql(u8, o, e.name);
            if (!wanted) continue;
        }
        var f: Flow = .{ .out = &out.interface, .name = e.name, .gpa = gpa };
        defer f.notes.deinit(gpa);
        var room = Room.init(gpa, source.assetSource());
        defer room.deinit();
        e.run(&f, &room) catch |err| if (err != error.StepFailed) return err;
        try f.report();
        all = all and f.failed == null;
    }
    if (!all) std.process.exit(1);
}

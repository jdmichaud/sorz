//! sorz-netplay-check: network play's flows on the real game (DESIGN.md 9, PLAN item 18), several
//! games in one process over the in-memory network, each in its own agent backend with its own
//! clock and keys, on the content extracted from the user's ROM, as the hosts run them.
//!
//!   sorz-netplay-check ROM [--pictures DIR] [FLOW...]
//!
//! - own_menus: the host and the guest each at their own game menu; a move of the host's arrow
//!   leaves the guest's where it was; the guest's OPTIONS (its own lines alone) leaves the host's
//!   menu as it was; its ADVANCED SETTINGS open its settings (one player's), the host not held.
//! - select: the host's 2 PLAYERS, its select alone; the guest's 2 PLAYERS joins it there: both
//!   selects with two players, each player's cursor its own; both choose, round 1 with two
//!   players; the two games the same at the same ticks (state and picture), the guest's sound the
//!   round's music, the session's checks finding no difference; player 1's START in play opens its
//!   settings in place of the pause: both games hold, the guest says why, and both go on once
//!   player 1 leaves them.
//! - round: the host plays round 1 alone a while; the guest's player chooses a character on its
//!   own select (the host's taken), joins mid-round as it, and drops in; the same state and
//!   picture after the join and on; the guest quits: the host plays on, player 2 out of the game;
//!   a new guest joins later, the same again; a third game is turned away and plays alone; the
//!   host quits: the guest plays on alone, as player 2, player 1 out of the game.
//! - away: the connection drops in the round: both hold, the host says it waits; the guest back in
//!   time, the same session goes on; the connection drops again and the guest is not back in
//!   time: the host plays on without player 2, and the guest, back, goes to its own menu.
//! - difference: a bit of the guest's state flipped in a session: both games stop at the next
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

    fn create(gpa: std.mem.Allocator, assets: platform.AssetSource, network: *net.memory.Network, role: net.netplay.Role) !*Machine {
        const m = try gpa.create(Machine);
        errdefer gpa.destroy(m);
        m.backend = agent.AgentBackend.init(gpa, .{});
        m.storage = sorz.memory.MemoryStorage.init(gpa);
        m.game = try sorz.Game.init(gpa, assets, m.storage.storage());
        m.frozen = false;
        m.game.pacing = .per_update;
        m.game.variant = .network;
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
        _ = try m.game.update(&p);
        m.backend.advance(frame_ns);
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

    fn add(r: *Room, role: net.netplay.Role) !*Machine {
        const m = try Machine.create(r.gpa, r.assets, &r.network, role);
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
    if (a.game.lastFrameHash() != b.game.lastFrameHash()) if (pictures) |dir| {
        for ([_]*Machine{ a, b }, [_][]const u8{ "host.png", "guest.png" }) |m, name| {
            const frame = m.game.frame();
            const bytes = try agent.png.encode(r.gpa, frame.width, frame.height, frame.pixels[0 .. frame.stride * frame.height]);
            defer r.gpa.free(bytes);
            const path = try std.fs.path.join(r.gpa, &.{ dir, name });
            defer r.gpa.free(path);
            try std.Io.Dir.cwd().writeFile(tool_io, .{ .sub_path = path, .data = bytes });
        }
    };
    try f.check(a.game.lastFrameHash() == b.game.lastFrameHash(), "the same picture");
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

/// The song the game's sound plays (its sequencer's), if any.
fn song(m: *const Machine) ?u16 {
    const s = m.game.sound orelse return null;
    const x = s.sound orelse return null;
    return x.sequencer.song;
}

fn ownMenus(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try toMenu(f, r, host);
    try toMenu(f, r, guest);
    try f.check(std.mem.eql(sorz.variant.MenuLine, host.game.state.scenes.base.menu.lines[0..2], &.{ .two_players, .options }), "the network menu: 2 PLAYERS, OPTIONS");
    // A move of the host's arrow: the guest's stays.
    try r.press(host, .down);
    try r.step(4);
    try f.check(menuChoice(host) == .options and menuChoice(guest) == .two_players, "the host's arrow moved, the guest's did not");
    // The guest's OPTIONS: its own lines alone; the host's menu as it was.
    try r.press(guest, .down);
    try r.press(guest, .enter);
    try f.until(r, guest, inOptions, 400, "the guest's OPTIONS");
    const o = &guest.game.state.scenes.base.options;
    try f.check(o.own_only and o.advanced_settings, "the guest's OPTIONS show its own lines alone");
    try f.check(host.scene() == .menu and menuChoice(host) == .options, "the host's menu as it was");
    // Its ADVANCED SETTINGS (above EXIT, up from SOUND TEST): its own settings, one player's; the
    // host not held.
    try r.press(guest, .up);
    try r.press(guest, .up);
    try f.check(guest.game.state.scenes.base.options.line == .advanced_settings, "ADVANCED SETTINGS");
    try r.press(guest, .z);
    try r.step(4);
    const screen = guest.game.overlays.find(.settings);
    try f.check(screen != null and screen.?.settings.facts.one_player, "the guest's settings open, one player's");
    const ticks = host.game.state.tick;
    try r.step(30);
    try f.check(host.game.state.tick >= ticks + 30 and host.game.overlays.find(.peer_settings) == null, "the host not held");
    try r.press(guest, .escape);
    try f.check(!guest.game.settingsOpen(), "Escape leaves them");
    try f.check(!host.inSession() and !guest.inSession(), "no session");
    f.note("\"host\":\"{s}\",\"guest\":\"{s}\"", .{ @tagName(host.scene()), @tagName(guest.scene()) });
}

/// The two machines' players choose 2 PLAYERS from their menus.
fn twoPlayers(f: *Flow, r: *Room, m: *Machine) !void {
    try f.check(menuChoice(m) == .two_players, "the arrow on 2 PLAYERS");
    try r.press(m, .enter);
}

fn atSelect(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try toMenu(f, r, host);
    try toMenu(f, r, guest);
    try twoPlayers(f, r, host);
    try f.until(r, host, inSelect, 600, "the host's select");
    try f.check(selectOf(host).?.players == .one, "the host alone at its select");
    try twoPlayers(f, r, guest);
    try f.until(r, guest, inSession, 600, "the guest joins at the select");
    try f.until(r, guest, inSelect, 100, "the guest at the host's select");
    try same(f, r, host, guest, "the same select on both");
    try f.check(selectOf(host).?.players == .two and selectOf(guest).?.players == .two, "two players at the select");
    // Each player's cursor its own: the host's right, the guest's left.
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
    try f.until(r, guest, playing, 100, "round 1 on the guest");
    try same(f, r, host, guest, "the same round");
    const w = &roundOf(host).?.play.world;
    try f.check(w.players[0].entity != null and host.game.state.setup.players == .two, "two players in the round");
    try f.check(song(host) != null and song(host) == song(guest), "the guest's sound plays the round's music");
    try sameFor(f, r, host, guest, 600);
    // Player 1's START in play (player 2 sits out until the content has Adam): its settings, in
    // place of the pause; both games hold, the guest says why; Escape (save and leave), and both
    // go on.
    try r.press(host, .enter);
    try r.step(12);
    try f.check(host.game.settingsOpen() and !guest.game.settingsOpen() and roundOf(host).?.phase == .play, "player 1's START opens its settings, the round not paused");
    try f.check(guest.game.overlays.find(.peer_settings) != null, "the guest says player 1 is in the settings");
    const held = .{ host.game.state.tick, guest.game.state.tick };
    try r.step(60);
    try f.check(host.game.state.tick == held[0] and guest.game.state.tick == held[1], "both games hold");
    try r.press(host, .escape);
    try r.step(12);
    try f.check(!host.game.settingsOpen() and guest.game.overlays.find(.peer_settings) == null and guest.game.state.tick > held[1], "both go on");
    try sameFor(f, r, host, guest, 120);
    f.note("\"session_tick\":{d},\"state_hash\":\"{x:0>16}\",\"song\":{?d}", .{ host.np().tick(), host.game.stateHash(), song(guest) });
}

/// A guest from power-on to its select by 2 PLAYERS, its character chosen there: `right` moves of
/// its cursor, then A.
fn guestChooses(f: *Flow, r: *Room, g: *Machine, rights: usize) !void {
    try toMenu(f, r, g);
    try twoPlayers(f, r, g);
    try f.until(r, g, inSelect, 600, "the guest's own select");
    for (0..rights) |_| {
        try r.press(g, .right);
        try r.step(4);
    }
    try r.press(g, .z);
}

fn inRound(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    try toMenu(f, r, host);
    try twoPlayers(f, r, host);
    try f.until(r, host, inSelect, 600, "the host's select");
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

    // The guest's own select: the host's character is taken (its cursor passes it).
    const guest = try r.add(.guest);
    try toMenu(f, r, guest);
    try twoPlayers(f, r, guest);
    try f.until(r, guest, inSelect, 600, "the guest's own select");
    try r.step(30);
    for (0..3) |_| {
        try r.press(guest, .right);
        try r.step(4);
        try f.check(selectOf(guest).?.cursors[0].place != first, "the host's character is taken");
    }
    const chosen = selectOf(guest).?.cursors[0].place;
    try r.press(guest, .z);
    try f.until(r, guest, inSession, 600, "the guest joins the round");
    try f.until(r, host, struct {
        fn in(m: *Machine) bool {
            const x = roundOf(m) orelse return false;
            return x.play.world.players[1].entity != null;
        }
    }.in, 200, "player 2 drops in");
    try same(f, r, host, guest, "the same round after the join");
    try f.check(host.game.state.setup.characters[1] == chosen, "player 2 as the guest chose");
    try f.check(song(guest) != null and song(guest) == song(host), "the guest's sound plays the round's music");
    try sameFor(f, r, host, guest, 600);
    f.note("\"joined_at\":{d},\"character\":\"{s}\"", .{ host.game.state.tick, @tagName(chosen) });

    // A third game asks to join while the two play: turned away, it plays alone.
    const third = try r.add(.guest);
    try toMenu(f, r, third);
    try twoPlayers(f, r, third);
    try f.until(r, third, struct {
        fn alone(m: *Machine) bool {
            return m.game.netplay == null and m.game.alone;
        }
    }.alone, 600, "the third is turned away");
    try f.check(third.message() == .busy, "the third is told two play there");
    try f.until(r, third, inSelect, 600, "the third's select, alone");
    try f.check(selectOf(third).?.players == .one and !third.game.overlays.holds(), "the third chooses alone, not held");
    try r.press(third, .right);
    try r.step(4);
    try r.press(third, .z);
    try f.until(r, third, playing, 2400, "the third plays alone");
    r.remove(third);
    try same(f, r, host, guest, "the two play on");

    // The guest quits: the host plays on, player 2 out of the game.
    try guest.key(.escape, true);
    try guest.update();
    r.remove(guest);
    try r.step(30);
    const w = &roundOf(host).?.play.world;
    try f.check(!host.inSession() and w.players[1].entity == null and w.players[1].out, "player 2 out of the game");
    try f.check(host.message() == .player_2_left, "the host is told");
    const ticks = host.game.state.tick;
    try r.step(60);
    try f.check(host.game.state.tick >= ticks + 60, "the host plays on");

    // A new guest joins later.
    const next = try r.add(.guest);
    try guestChooses(f, r, next, 1);
    try f.until(r, next, inSession, 600, "the new guest joins");
    try r.step(30);
    try same(f, r, host, next, "the same round with the new guest");
    try f.check(roundOf(host).?.play.world.players[1].entity != null, "the new player 2 in the game");
    try sameFor(f, r, host, next, 300);
    f.note("\"sessions\":{d}", .{host.np().sessions});

    // The host quits: the guest plays on alone, as player 2, player 1 out of the game; its pad
    // moves player 2.
    try host.key(.escape, true);
    try host.update();
    r.remove(host);
    try r.step(30);
    const left = &roundOf(next).?.play.world;
    try f.check(!next.inSession() and left.players[0].entity == null and left.players[0].out and left.players[1].entity != null, "player 1 out of the game, player 2 in it");
    try f.check(next.message() == .player_1_left and next.game.seat == 1, "the guest is told, and plays player 2");
    const second = left.players[1].entity.?;
    const x = left.getConst(second).?.position.x;
    try next.key(.right, true);
    try r.step(60);
    try next.key(.right, false);
    try f.check(playing(next) and left.getConst(second).?.position.x.raw > x.raw, "the guest's pad moves player 2");
}

fn away(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try toMenu(f, r, host);
    try toMenu(f, r, guest);
    try twoPlayers(f, r, host);
    try twoPlayers(f, r, guest);
    try f.until(r, guest, inSession, 900, "the guest joins");
    try f.until(r, guest, inSelect, 200, "the select on the guest");
    try f.until(r, host, inSelect, 200, "the select on the host");
    // Player 1 Axel (the content's fighter), player 2 where its cursor starts.
    try r.press(host, .right);
    try r.step(6);
    try r.press(host, .z);
    try r.press(guest, .z);
    try f.until(r, host, playing, 2400, "round 1");
    try r.step(60);
    // The cable is pulled: both hold, and the host says it waits.
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(host.backend.transport.?.context));
    r.network.breakLink(endpoint, host.np().peer.?);
    const at = host.game.state.tick;
    try r.step(30);
    try f.check(host.game.state.tick <= at + 4 and host.message() == .player_2_away, "the host holds and says it waits");
    try f.check(guest.message() == .player_1_away, "the guest holds and says it waits");
    // The guest is back after a second: the same session goes on.
    try f.until(r, host, struct {
        fn back(m: *Machine) bool {
            return m.game.netplay.?.peer != null and m.message() == null;
        }
    }.back, 300, "the guest back in time");
    try r.step(60);
    try same(f, r, host, guest, "the same session goes on");
    try f.check(host.np().sessions == 1, "the same session");
    // Pulled again, and the guest's machine away longer than the host waits.
    r.network.breakLink(endpoint, host.np().peer.?);
    guest.frozen = true;
    const wait: usize = @intCast(net.session.rejoin_ns / frame_ns + 30);
    try r.step(wait);
    const w = &roundOf(host).?.play.world;
    try f.check(!host.inSession() and w.players[1].entity == null and w.players[1].out, "the host gave player 2 up");
    try f.check(host.game.state.tick > at + 60, "the host plays on alone");
    // The guest's machine back: its session is over; its own menu again.
    guest.frozen = false;
    try f.until(r, guest, choosing, 900, "the guest back at its own menu");
    try f.check(!guest.inSession(), "no session for the guest");
    f.note("\"held_at\":{d}", .{at});
}

fn difference(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try toMenu(f, r, host);
    try toMenu(f, r, guest);
    try twoPlayers(f, r, host);
    try twoPlayers(f, r, guest);
    try f.until(r, guest, inSession, 900, "the guest joins");
    try f.until(r, guest, inSelect, 200, "the select on the guest");
    try f.until(r, host, inSelect, 200, "the select on the host");
    // Player 1 Axel (the content's fighter), player 2 where its cursor starts.
    try r.press(host, .right);
    try r.step(6);
    try r.press(host, .z);
    try r.press(guest, .z);
    try f.until(r, host, playing, 2400, "round 1");
    try r.step(30);
    // A bit of the guest's random generator.
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
    }.found, 200, "the guest names the difference");
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

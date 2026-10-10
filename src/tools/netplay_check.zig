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
//!   the player quits: the host plays on, player 2's fighter dies and it is out of the game, its
//!   observer with it; the observer leaves with START, back to its menu; a new client joins; the
//!   host quits: its client goes back to its own menu (its own variant's lines), told why for a
//!   while.
//! - away: the connection drops in the round: both hold, the host counting the seconds down; the
//!   client back in time, the same session goes on; the connection drops again and the client is
//!   not back in time: the host plays on, player 2's fighter dies and it is out of the game (no
//!   invitation over its part), and the client, back, goes to its own menu.
//! - difference: a bit of the client's state flipped in a session: both games stop at the next
//!   check and name the first field that differs.
//! - server: the host's START SERVER: its screen stays, its lobby, which lists the client; the
//!   client's JOIN lit, OBSERVE dimmed (no game to watch); the client's JOIN and character wait
//!   for the host's game, its own select naming it player 2; START GAME: once the host's select
//!   shows, the client joins it, its cursor and choice kept, not faded; Escape on the host: its
//!   lobby again, the client keeping the select, its own again; STOP SERVER: the client back at
//!   its menu, told, and turned away; START GAME: the server again, the client back in joins the
//!   host's select; Escape: the client keeps the select; EXIT: the menu, the server running;
//!   Escape in 1 PLAYER's game, the server running: the lobby; with it stopped, a local game:
//!   the menu.
//! - rejoin: the server started, the client waiting at its select; START GAME, the join; the
//!   host back to its lobby, the client keeping its select; START GAME again: each join lands on
//!   a select that shows (no fade on the client).
//! - select_escape: the client waiting at its select, Escape: its menu, its ask withdrawn; the
//!   host's next select does not take it.
//! - observer_select: the host's Escape at the shared select: the player keeps it, the observer
//!   goes back to its menu.
//! - observer_lobby: the host leaves the round, the client quits: the observer back at its menu,
//!   no difference found.
//! - observe_start: OBSERVE chosen with START held: the watch goes on.
//! - desync_host, desync_client: the games differ; the host's Escape: its lobby, the client its
//!   menu; the client's Escape: its menu, the host's player 2 place free again.
//! - select_link_down: the link down at the shared select, the host's Escape, the client back
//!   within 5 s: welcomed to the lobby, no session resumed.
//! - client_gives_up: the host's machine gone in a round: the client holds, then goes back to its
//!   menu.
//! - event_reconnect: the host's leave sent as the link breaks; back, the leave is made at its
//!   tick on both: the same game.
//! - stop_left: STOP SERVER with the client playing the game the host left and an observer: both
//!   back at their menus, told; the host's lobby over its menu.
//! - local_two: the server open, the host's 2 PLAYERS: both pads play, the client's JOIN dimmed,
//!   OBSERVE lit.
//! - cpu: the server open, the host's 1 PLAYER - 1 CPU (PLAN item 30): not a local game of two;
//!   player 1 chooses for itself, then for the CPU at the select's second time; round 1 with the
//!   CPU as player 2; a client joins mid-round in the CPU's place, as the character it chose, the
//!   CPU's fighter gone; the same game on both; the client quits: the CPU takes player 2 back,
//!   its fighter playing on.
//! - cpu_select: the same at the host's select: the client joins it in the CPU's place, both
//!   cursors there; the client quits: player 1 alone again, and once it has chosen, the select
//!   again for the CPU's character.
//! - lobby_silence: the host's lobby over the game its client plays: its sound is silence.
//! - rules: in round 1 with a client, the host's settings change FRIENDLY HIT: both games take it
//!   at one tick, and stay the same.
//! - observer_rules: the host alone in round 1, an observer watching: the host's settings change
//!   FRIENDLY HIT with no client in its game; the observer gets the game again, its rules too,
//!   and watches on with no difference found.
//! - friendly: in round 1 with a client, player 1's punches hurt player 2; the host's settings,
//!   by their keys, turn FRIENDLY HIT off; the punches no longer hurt, on both machines.
//! - left: in round 1 with a client, Escape on the host: its lobby over the game, which runs on
//!   for the client; player 1 dies out of it at one tick on both machines (the same game); RETURN
//!   TO GAME: player 1 drops back in on both; JOIN IN PROGRESS off: no way back; EXIT shows the
//!   game, which runs on; the client quits: the game the host left is over, its lobby again.
//!
//! Prints a JSON line per flow, and exits with 1 when a step fails; with `--pictures`, two pictures
//! that differ are written there (host.png, guest.png), and the host's at a few steps, its own
//! screens over them (network_options.png, roster.png, lobby.png, dropped_out.png), and the
//! client's OPTIONS (client_options.png).
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

    /// The program quits (its window closed): the game says farewell.
    fn quit(m: *Machine) !void {
        try m.backend.inject(.{ .time_ns = m.backend.clock_ns, .payload = .quit });
        try m.update();
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

    /// Network play's wait over the picture, if any.
    fn message(m: *Machine) ?sorz.overlay.Message {
        const o = m.game.overlays.find(.network) orelse return null;
        return o.network.what;
    }

    /// Network play's notice over the picture, if any.
    fn notice(m: *Machine) ?sorz.overlay.Message {
        const o = m.game.overlays.find(.net_notice) orelse return null;
        return o.net_notice.what;
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
    try r.step(90);
    try shot(r, host, "network_options.png");
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

/// A client's JOIN can be chosen: welcomed, a place free, the line lit.
fn joinLit(m: *Machine) bool {
    const menu = switch (m.game.state.scenes.base) {
        .menu => |*x| x,
        else => return false,
    };
    return m.np().welcomed() and m.np().hostStatus().place and menu.dimmed & 2 == 0;
}

/// The host's network options opened from its menu.
fn openOptions(f: *Flow, r: *Room, host: *Machine) !void {
    try f.until(r, host, choosing, 600, "the host at its menu");
    while (menuChoice(host) != .network_play) try r.press(host, .down);
    try r.press(host, .z);
    try f.until(r, host, struct {
        fn open(m: *Machine) bool {
            return m.game.overlays.find(.net_options) != null;
        }
    }.open, 200, "the network options");
}

/// The host's network options, open: `key` (A, or Enter: START) on `row`.
fn pressOption(r: *Room, host: *Machine, row: sorz.settings.net_screens.NetOptions.Row, key: platform.Key) !void {
    while (lobby(host).?.row != row) try r.press(host, .down);
    try r.press(host, key);
}

fn lobby(m: *Machine) ?*sorz.settings.net_screens.NetOptions {
    const o = m.game.overlays.find(.net_options) orelse return null;
    return &o.net_options;
}

fn server(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const client = try r.add(.guest);
    try toMenu(f, r, host);
    // START SERVER (with START, Enter): the session open; the screen stays, the host's lobby, its
    // cursor on START GAME.
    try openOptions(f, r, host);
    try pressOption(r, host, .server, .enter);
    try r.step(10);
    try f.check(host.np().open and lobby(host) != null and lobby(host).?.serving and lobby(host).?.row == .game, "the server started, the host's lobby stays, on START GAME");
    try toMenu(f, r, client);
    try f.until(r, client, joinLit, 300, "the client's JOIN lit");
    try f.check(client.game.state.scenes.base.menu.dimmed == 0b0100, "OBSERVE dimmed: the host has no game to watch");
    try f.until(r, host, struct {
        fn listed(m: *Machine) bool {
            const l = lobby(m) orelse return false;
            return l.client_count == 1 and std.mem.eql(u8, &l.clients[0].name, "CLI");
        }
    }.listed, 300, "the lobby lists the client");
    // JOIN, a character on its own select: it waits for the host's game.
    while (menuChoice(client) != .join) try r.press(client, .down);
    try r.press(client, .z);
    try f.until(r, client, inSelect, 600, "the client's own select");
    try f.check(selectOf(client).?.seat == 1, "the client's own select names its player 2");
    try f.until(r, host, struct {
        fn listed(m: *Machine) bool {
            const l = lobby(m) orelse return false;
            return l.client_count == 1 and l.clients[0].doing == .select;
        }
    }.listed, 300, "the lobby lists the client at its select (SELECT)");
    try r.press(client, .z);
    try f.until(r, client, struct {
        fn waits(m: *Machine) bool {
            return m.message() == .waiting_for_player_1;
        }
    }.waits, 300, "the client waits for the host's game");
    try shot(r, host, "lobby.png");
    try shot(r, client, "client_waiting.png");
    const waited = selectOf(client).?.cursors[0].place;
    // START GAME: the host's select; once it shows, the waiting client joins it there, its cursor
    // and its choice as they were, its screen not faded.
    try pressOption(r, host, .game, .z);
    try f.until(r, client, inSession, 900, "the waiting client joins at the host's select");
    try f.check(selectOf(client).?.settled() and selectOf(client).?.players == .two, "the client's select shows, two players: no fade");
    try f.check(selectOf(host).?.cursors[1].place == waited and selectOf(host).?.cursors[1].chosen, "the client's cursor and choice kept");
    try r.step(60);
    try shot(r, host, "host_joined.png");
    try shot(r, client, "client_joined.png");
    // Escape on the host: its lobby again, its server running; the client keeps the select, its
    // own again (its cursor player 2's, chosen: it waits for player 1), still in the host's lobby.
    try r.press(host, .escape);
    try f.until(r, host, struct {
        fn back(m: *Machine) bool {
            const l = lobby(m) orelse return false;
            return l.serving and l.client_count == 1 and l.clients[0].doing == .select;
        }
    }.back, 300, "the host back in its lobby, the client listed at its select");
    try f.until(r, client, struct {
        fn kept(m: *Machine) bool {
            const sel = selectOf(m) orelse return false;
            return !m.inSession() and sel.players == .one and sel.seat == 1 and m.message() == .waiting_for_player_1;
        }
    }.kept, 600, "the client keeps the select, its choice made: it waits for player 1");
    try f.check(selectOf(client).?.cursors[0].place == waited and selectOf(client).?.cursors[0].chosen and client.np().welcomed(), "its cursor and choice as they were, still connected");
    try f.check(client.notice() == .player_1_left, "PLAYER 1 LEFT shown with the wait");
    // STOP SERVER, in the lobby: the client back at its menu, told; turned away while the server
    // is stopped; the lobby stays, empty.
    try pressOption(r, host, .server, .z);
    try f.until(r, client, struct {
        fn back(m: *Machine) bool {
            return choosing(m) and m.notice() == .host_stopped;
        }
    }.back, 600, "the client back at its menu, told the host stopped");
    try f.check(host.np().peers.items.len == 0 and !host.np().open and lobby(host) != null and !lobby(host).?.serving and lobby(host).?.client_count == 0, "the host let its client go, its screen still there");
    try r.step(150);
    try f.check(!client.np().welcomed() and client.game.state.scenes.base.menu.dimmed & 0b0110 == 0b0110, "the client turned away: JOIN and OBSERVE dimmed");
    // START GAME: the server again, the host at its select; the client back in joins it there.
    try pressOption(r, host, .game, .z);
    try f.until(r, host, inSelect, 600, "the host's select");
    try f.until(r, client, joinLit, 300, "the client's JOIN lit again");
    while (menuChoice(client) != .join) try r.press(client, .down);
    try r.press(client, .z);
    try f.until(r, client, inSession, 900, "the client joins at the host's select");
    try f.check(selectOf(host).?.players == .two, "two players at the host's select");
    // Escape on the host: its lobby again; the client keeps the select.
    try r.press(host, .escape);
    try f.until(r, client, struct {
        fn kept(m: *Machine) bool {
            const sel = selectOf(m) orelse return false;
            return !m.inSession() and sel.seat == 1;
        }
    }.kept, 600, "the client keeps the select");
    try f.check(lobby(host) != null and !host.inSession(), "the host in its lobby, no session");
    // EXIT: the host's menu, its server running, the client still in its lobby.
    try pressOption(r, host, .exit, .z);
    try f.until(r, host, choosing, 600, "the host's menu");
    try f.check(host.np().open and client.np().welcomed(), "the server still running, the client in its lobby");
    // Escape in 1 PLAYER's game, the server running: the lobby again. STOP SERVER, EXIT, and
    // Escape in a local game: back to the menu, the program running.
    while (menuChoice(host) != .one_player) try r.press(host, .down);
    try r.press(host, .z);
    try f.until(r, host, inSelect, 600, "the host's select, its server running");
    try r.press(host, .escape);
    try f.until(r, host, struct {
        fn in(m: *Machine) bool {
            return lobby(m) != null;
        }
    }.in, 300, "the host's lobby again");
    try pressOption(r, host, .server, .z);
    try pressOption(r, host, .exit, .z);
    try f.until(r, host, choosing, 600, "the host's menu, its server stopped");
    while (menuChoice(host) != .one_player) try r.press(host, .down);
    try r.press(host, .z);
    try f.until(r, host, inSelect, 600, "the host's local select");
    try r.press(host, .escape);
    try f.until(r, host, choosing, 600, "the host back at its menu");
    try f.check(!host.game.finished and lobby(host) == null, "the menu, not the lobby: the game goes on");
}

/// The client at its own select, its choice made, waiting for the host's game.
fn waitsAtOwnSelect(m: *Machine) bool {
    const sel = selectOf(m) orelse return false;
    return !m.inSession() and sel.seat == 1 and sel.cursors[0].chosen and m.message() == .waiting_for_player_1;
}

/// The user's sequence (2026-10-08): the server started, the client waiting at its select; the
/// host's START GAME, the join at its select; the host back to its lobby; START GAME again: each
/// join lands on a select that shows (no fade on the client).
fn rejoin(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const client = try r.add(.guest);
    try toMenu(f, r, host);
    try openOptions(f, r, host);
    try pressOption(r, host, .server, .z);
    try toMenu(f, r, client);
    try f.until(r, client, joinLit, 300, "the client's JOIN lit");
    while (menuChoice(client) != .join) try r.press(client, .down);
    try r.press(client, .z);
    try f.until(r, client, inSelect, 600, "the client's own select");
    try r.press(client, .z);
    try f.until(r, client, waitsAtOwnSelect, 300, "the client waits at its select");
    for (0..2) |round_trip| {
        try pressOption(r, host, .game, .z);
        try f.until(r, client, inSession, 900, "the client joins the host's select");
        try f.check(selectOf(client).?.settled() and selectOf(host).?.settled(), if (round_trip == 0) "the first join: the select shows, no fade" else "the join again: the select shows, no fade");
        try r.step(30);
        try r.press(host, .escape);
        try f.until(r, client, waitsAtOwnSelect, 600, "the client keeps its select, waiting");
        try f.until(r, host, struct {
            fn in(m: *Machine) bool {
                return lobby(m) != null;
            }
        }.in, 300, "the host back in its lobby");
        // No stale offer: the client hears the host has no game, and the host keeps no ask.
        try r.step(30);
        try f.check(client.np().hostStatus().game == .none and host.np().joinAsked() == null and client.game.net.client == .own_select, "no stale status, no ask held");
    }
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
    try shot(r, host, "roster.png");
    const roster = host.game.overlays.find(.roster);
    try f.check(roster != null and roster.?.roster.len == 1 and std.mem.eql(u8, &roster.?.roster.entries[0].name, "BAA") and roster.?.roster.entries[0].doing == .menu, "the host lists BAA - MENU");
    // The client's OPTIONS: its own lines alone; ADVANCED SETTINGS, one player's; the host not
    // held.
    while (menuChoice(client) != .options) try r.press(client, .down);
    try r.press(client, .enter);
    try f.until(r, client, inOptions, 400, "the client's OPTIONS");
    const o = &client.game.state.scenes.base.options;
    try f.check(o.own_only and o.advanced_settings, "the client's OPTIONS show its own lines alone");
    try r.step(90);
    try shot(r, client, "client_options.png");
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
    try guest.quit();
    r.remove(guest);
    try r.step(30);
    try f.check(!host.inSession() and roundOf(host).?.play.world.players[1].gone, "player 2 gone from the game");
    try f.check(host.notice() == .player_2_left, "the host is told");
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
    try host.quit();
    r.remove(host);
    try f.until(r, next, choosing, 900, "the client back at its menu");
    try f.check(!next.inSession() and next.notice() == .player_1_left, "the client is told player 1 left");
    try f.check(next.game.state.start.variant == .network and std.mem.eql(sorz.variant.MenuLine, lines(next), &.{ .name, .join, .observe, .options }), "the client's own menu again: NAME, JOIN, OBSERVE, OPTIONS");
    try r.step(@intCast(sorz.overlay.notice_ns / frame_ns + 30));
    try f.check(next.notice() == null, "the notice gone after a while");
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

/// Whether player `k` plays a fighter in the round.
fn fighting(m: *const Machine, k: u1) bool {
    const x = roundOf(m) orelse return false;
    return x.play.world.players[k].entity != null;
}

fn left(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try hostNetworkPlay(f, r, host);
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSession, 900, "the client joins");
    try f.until(r, guest, inSelect, 200, "the select on the client");
    try r.press(host, .right);
    try r.step(6);
    try r.press(host, .z);
    try r.press(guest, .z);
    try f.until(r, host, playing, 2400, "round 1");
    try r.step(60);
    // Escape on the host: its lobby over the game, which runs on for the client; player 1 dies
    // out of it on both machines, at one tick.
    try r.press(host, .escape);
    try f.check(lobby(host) != null and lobby(host).?.in_game and host.game.net.host == .left, "the host's lobby over the game");
    const at = guest.game.state.tick;
    try f.until(r, host, struct {
        fn out(m: *Machine) bool {
            const x = roundOf(m) orelse return false;
            return x.play.world.players[0].entity == null and x.play.world.players[0].out;
        }
    }.out, 900, "player 1 dead, out of the game");
    try f.check(host.inSession() and guest.inSession() and guest.game.state.tick > at + 60 and fighting(guest, 1), "the client plays on");
    try f.check(guest.notice() == .player_1_left, "the client is told player 1 left");
    try same(f, r, host, guest, "the same game without player 1");
    try shot(r, host, "left_lobby.png");
    // RETURN TO GAME: player 1 drops back in, on both.
    try f.until(r, host, struct {
        fn can(m: *Machine) bool {
            return lobby(m).?.can_return;
        }
    }.can, 60, "RETURN TO GAME offered");
    try pressOption(r, host, .game, .z);
    try f.until(r, host, struct {
        fn back(m: *Machine) bool {
            return lobby(m) == null and fighting(m, 0);
        }
    }.back, 300, "player 1 back in the game");
    try r.step(30);
    try f.check(fighting(guest, 0) and host.game.net.host == .game, "player 1 back on the client too");
    try same(f, r, host, guest, "the same game with player 1 back");
    // JOIN IN PROGRESS off: no way back, nor in for another client; EXIT shows the game.
    try r.press(host, .escape);
    try f.until(r, host, struct {
        fn out(m: *Machine) bool {
            return !fighting(m, 0) and lobby(m) != null;
        }
    }.out, 900, "player 1 out again");
    try pressOption(r, host, .join_in_progress, .z);
    try r.step(30);
    try f.check(!lobby(host).?.join_in_progress and !lobby(host).?.can_return and !host.np().join_in_progress, "JOIN IN PROGRESS off: no RETURN TO GAME, the session takes no join");
    try pressOption(r, host, .exit, .z);
    try f.check(lobby(host) == null and host.game.net.host == .watching, "EXIT: the game shown, player 1 still out");
    const shown = host.game.state.tick;
    try r.step(60);
    try f.check(host.game.state.tick > shown + 30, "the game runs on, shown");
    try same(f, r, host, guest, "the same game, watched");
    // The client quits: no player left in the game the host's player watched: its lobby again,
    // its menu under it.
    try guest.quit();
    r.remove(guest);
    try f.until(r, host, struct {
        fn over(m: *Machine) bool {
            return m.game.net.host == .lobby and lobby(m) != null and !m.inSession();
        }
    }.over, 900, "the game the host left over: its lobby");
}

// --- the review's scenarios (2026-10-08): each state's ways out, on both machines -------------

const Pair = struct { host: *Machine, guest: *Machine };

/// A host and a client in round 1 together: the host's NETWORK PLAY and START, the client's
/// JOIN at its select, player 1 Axel, player 2 where its cursor starts.
fn inRoundTogether(f: *Flow, r: *Room) !Pair {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try hostNetworkPlay(f, r, host);
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSession, 900, "the client joins");
    try f.until(r, guest, inSelect, 200, "the select on the client");
    try r.press(host, .right);
    try r.step(6);
    try r.press(host, .z);
    try r.press(guest, .z);
    try f.until(r, host, playing, 2400, "round 1");
    try r.step(60);
    return .{ .host = host, .guest = guest };
}

/// A client named OBS that chooses OBSERVE, and watches the host's game.
fn observerWatches(f: *Flow, r: *Room) !*Machine {
    const watcher = try r.addNamed(.guest, "OBS".*);
    try toMenu(f, r, watcher);
    try f.until(r, watcher, struct {
        fn lit(m: *Machine) bool {
            const menu = switch (m.game.state.scenes.base) {
                .menu => |*x| x,
                else => return false,
            };
            return menu.dimmed & 0b0100 == 0;
        }
    }.lit, 300, "OBSERVE lit");
    while (menuChoice(watcher) != .observe) try r.press(watcher, .down);
    try r.press(watcher, .z);
    try f.until(r, watcher, struct {
        fn in(m: *Machine) bool {
            return m.game.net.client == .observing;
        }
    }.in, 600, "the observer watches");
    return watcher;
}

fn atClientMenu(m: *Machine) bool {
    return choosing(m) and m.game.net.client == .menu;
}

fn inLobby(m: *Machine) bool {
    return lobby(m) != null and m.game.net.host == .lobby;
}

/// The client waits at its own select, Escape: its menu, its ask withdrawn; the host's next
/// game does not take it.
fn selectEscape(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const client = try r.add(.guest);
    try toMenu(f, r, host);
    try openOptions(f, r, host);
    try pressOption(r, host, .server, .z);
    try toMenu(f, r, client);
    try f.until(r, client, joinLit, 300, "the client's JOIN lit");
    while (menuChoice(client) != .join) try r.press(client, .down);
    try r.press(client, .z);
    try f.until(r, client, inSelect, 600, "the client's own select");
    try r.press(client, .z);
    try f.until(r, client, waitsAtOwnSelect, 300, "the client waits at its select");
    try r.press(client, .escape);
    try f.until(r, client, atClientMenu, 600, "Escape: the client's menu, no wait over it");
    try f.check(client.message() == null and host.np().joinAsked() == null, "no wait, no ask left with the host");
    try f.until(r, host, struct {
        fn listed(m: *Machine) bool {
            const l = lobby(m) orelse return false;
            return l.client_count == 1 and l.clients[0].doing == .menu;
        }
    }.listed, 120, "the host lists the client at its menu");
    try pressOption(r, host, .game, .z);
    try f.until(r, host, inSelect, 600, "the host's select");
    try r.step(300);
    try f.check(!client.inSession() and atClientMenu(client), "the host's game does not take the client");
}

/// Host, client and an observer at the shared select; the host's Escape: the player keeps its
/// select, the observer goes back to its menu.
fn observerSelect(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try hostNetworkPlay(f, r, host);
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSession, 900, "the client joins at the select");
    const watcher = try r.addNamed(.guest, "OBS".*);
    try toMenu(f, r, watcher);
    try r.step(10);
    while (menuChoice(watcher) != .observe) try r.press(watcher, .down);
    try r.press(watcher, .z);
    try f.until(r, watcher, struct {
        fn in(m: *Machine) bool {
            return m.game.net.client == .observing;
        }
    }.in, 600, "the observer watches the select");
    try r.press(host, .escape);
    try f.until(r, watcher, atClientMenu, 600, "the observer back at its menu");
    try f.until(r, guest, struct {
        fn kept(m: *Machine) bool {
            const sel = selectOf(m) orelse return false;
            return !m.inSession() and sel.seat == 1 and m.game.net.client == .own_select;
        }
    }.kept, 600, "the player keeps its select");
    try f.check(selectOf(watcher) == null, "the observer at no select of its own");
}

/// In round 1, an observer; the host leaves the round (its lobby over the game); the client
/// quits: the game is over, the observer back at its menu, with no difference found.
fn observerLobby(f: *Flow, r: *Room) !void {
    const pair = try inRoundTogether(f, r);
    const host = pair.host;
    const watcher = try observerWatches(f, r);
    try r.press(host, .escape);
    try f.check(host.game.net.host == .left, "the host's lobby over the game");
    try r.step(120);
    try f.check(watcher.game.net.client == .observing, "the observer watches on");
    try pair.guest.quit();
    r.remove(pair.guest);
    try f.until(r, host, inLobby, 900, "the host's lobby, its menu under it");
    try f.until(r, watcher, atClientMenu, 900, "the observer back at its menu");
    try f.check(watcher.np().phase() != .desynced and watcher.message() != .desynced, "no difference found");
}

/// OBSERVE chosen with START held: the watch goes on.
fn observeStart(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    try hostNetworkPlay(f, r, host);
    const watcher = try r.addNamed(.guest, "OBS".*);
    try toMenu(f, r, watcher);
    try r.step(10);
    while (menuChoice(watcher) != .observe) try r.press(watcher, .down);
    try watcher.key(.enter, true);
    try f.until(r, watcher, struct {
        fn in(m: *Machine) bool {
            return m.game.net.client == .observing;
        }
    }.in, 600, "the observer watches");
    try r.step(60);
    try watcher.key(.enter, false);
    try r.step(30);
    try f.check(watcher.game.net.client == .observing, "START held as OBSERVE was chosen does not end the watch");
}

/// The games differ: the host's Escape takes it to its lobby, the client to its menu.
fn desyncHost(f: *Flow, r: *Room) !void {
    const pair = try inRoundTogether(f, r);
    pair.guest.game.state.random.state ^= 1;
    try f.until(r, pair.host, struct {
        fn stopped(m: *Machine) bool {
            return m.np().phase() == .desynced;
        }
    }.stopped, 300, "the games differ: stopped");
    try r.press(pair.host, .escape);
    try f.until(r, pair.host, inLobby, 600, "the host's Escape: its lobby");
    try f.until(r, pair.guest, atClientMenu, 900, "the client back at its menu");
}

/// The games differ: the client's Escape takes it to its menu; the host plays on, player 2's
/// place free.
fn desyncClient(f: *Flow, r: *Room) !void {
    const pair = try inRoundTogether(f, r);
    pair.guest.game.state.random.state ^= 1;
    try f.until(r, pair.guest, struct {
        fn stopped(m: *Machine) bool {
            return m.np().phase() == .desynced;
        }
    }.stopped, 300, "the games differ: stopped");
    try r.press(pair.guest, .escape);
    try f.until(r, pair.guest, atClientMenu, 900, "the client's Escape: its menu");
    try f.until(r, pair.host, struct {
        fn free(m: *Machine) bool {
            return m.np().player == null and m.np().phase() != .desynced and m.message() == null;
        }
    }.free, 600, "the host plays on, player 2's place free");
    try f.until(r, pair.host, struct {
        fn room(m: *Machine) bool {
            return statusOfHost(m).place;
        }
    }.room, 900, "a client may join again");
}

fn statusOfHost(m: *Machine) net.protocol.Status {
    return sorz.network_play.statusOf(&m.game.state, m.game.net.local_two);
}

/// At the shared select, the link breaks; the host's Escape; the client back within 5 s: the
/// host's lobby welcomes it, no session resumed, no difference.
fn selectLinkDown(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try hostNetworkPlay(f, r, host);
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSession, 900, "the client joins at the select");
    try r.step(30);
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(host.backend.transport.?.context));
    r.network.breakLink(endpoint, host.np().player.?.connection.?);
    try r.step(5);
    try r.press(host, .escape);
    try f.until(r, host, inLobby, 600, "the host's lobby");
    try f.check(!host.inSession() and host.np().player == null, "the session ended, the link down");
    try f.until(r, guest, struct {
        fn back(m: *Machine) bool {
            return m.np().welcomed() and !m.inSession();
        }
    }.back, 600, "the client back, in the host's lobby, no session");
    try r.step(60);
    try f.check(guest.np().phase() != .desynced and host.np().phase() != .desynced, "no difference");
}

/// The host's machine gone in round 1: the client holds, then gives up, back at its menu.
fn clientGivesUp(f: *Flow, r: *Room) !void {
    const pair = try inRoundTogether(f, r);
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(pair.host.backend.transport.?.context));
    r.network.breakLink(endpoint, pair.host.np().player.?.connection.?);
    pair.host.frozen = true;
    try r.step(60);
    try f.check(pair.guest.message() == .player_1_away, "the client holds and waits");
    const wait: u32 = @intCast((net.session.rejoin_ns + 2 * std.time.ns_per_s) / frame_ns + 600);
    try f.until(r, pair.guest, atClientMenu, wait, "the client gives up: its menu");
    try f.check(!pair.guest.inSession(), "no session");
}

/// The host's leave sent, the link breaks before the client has it, and comes back: the leave
/// crosses again, made at its tick on both.
fn eventReconnect(f: *Flow, r: *Room) !void {
    const pair = try inRoundTogether(f, r);
    try pair.host.key(.escape, true);
    try pair.host.update();
    try pair.host.key(.escape, false);
    try f.check(pair.host.game.net.host == .left and pair.host.np().eventDue(), "the leave scheduled");
    const endpoint: *net.memory.Endpoint = @ptrCast(@alignCast(pair.host.backend.transport.?.context));
    r.network.breakLink(endpoint, pair.host.np().player.?.connection.?);
    try f.until(r, pair.guest, struct {
        fn back(m: *Machine) bool {
            return m.np().connected() and m.inSession() and m.message() == null;
        }
    }.back, 600, "the client back in its session");
    try f.until(r, pair.host, struct {
        fn out(m: *Machine) bool {
            const x = roundOf(m) orelse return false;
            return x.play.world.players[0].out;
        }
    }.out, 900, "player 1 out");
    try r.step(30);
    try same(f, r, pair.host, pair.guest, "the same game on both");
}

/// STOP SERVER with the client playing the game the host left and an observer: both back at
/// their menus, told; the host's lobby over its menu.
fn stopLeft(f: *Flow, r: *Room) !void {
    const pair = try inRoundTogether(f, r);
    const watcher = try observerWatches(f, r);
    try r.press(pair.host, .escape);
    try f.until(r, pair.host, struct {
        fn out(m: *Machine) bool {
            const l = lobby(m) orelse return false;
            return l.in_game and !fighting(m, 0);
        }
    }.out, 900, "the host's lobby over the game, player 1 out");
    try pressOption(r, pair.host, .server, .z);
    for ([_]*Machine{ pair.guest, watcher }) |m| try f.until(r, m, struct {
        fn told(x: *Machine) bool {
            return atClientMenu(x) and x.notice() == .host_stopped;
        }
    }.told, 900, "a client back at its menu, told the host stopped");
    try f.check(pair.host.game.net.host == .lobby and lobby(pair.host) != null and !lobby(pair.host).?.in_game and !pair.host.game.state.inGame(), "the host's lobby over its menu");
}

/// The host's server open, its local 2 PLAYERS: both pads play, the client's JOIN dimmed, its
/// OBSERVE lit.
fn localTwo(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const client = try r.add(.guest);
    try toMenu(f, r, host);
    try openOptions(f, r, host);
    try pressOption(r, host, .server, .z);
    try pressOption(r, host, .exit, .z);
    try f.until(r, host, choosing, 600, "the host's menu");
    while (menuChoice(host) != .two_players) try r.press(host, .down);
    try r.press(host, .z);
    try f.until(r, host, inSelect, 600, "the host's local select");
    try f.check(selectOf(host).?.players == .two and host.game.net.local_two, "a local game of two");
    try toMenu(f, r, client);
    try r.step(30);
    try f.check(client.game.state.scenes.base.menu.dimmed & 0b0110 == 0b0010, "the client's JOIN dimmed, OBSERVE lit");
    // Player 2's pad moves its cursor (its right: D, the second player's key).
    const before = selectOf(host).?.cursors[1].place;
    for (0..4) |_| {
        try r.press(host, .d);
        try r.step(4);
    }
    try f.check(selectOf(host).?.cursors[1].place != before, "player 2's local pad plays");
}

/// The CPU's player 2 is a client's place, and the CPU's again when the client quits.
fn cpuPlace(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    try toMenu(f, r, host);
    try openOptions(f, r, host);
    try pressOption(r, host, .server, .z);
    try pressOption(r, host, .exit, .z);
    try f.until(r, host, choosing, 600, "the host's menu");
    while (menuChoice(host) != .two_players) try r.press(host, .down);
    try r.press(host, .right);
    try f.check(host.game.state.scenes.base.menu.cpus == 1, "1 PLAYER - 1 CPU");
    try r.press(host, .z);
    try f.until(r, host, inSelect, 600, "the host's select");
    try f.check(!host.game.net.local_two and selectOf(host).?.players == .one, "player 1 alone at its select, not a local game of two");
    try r.press(host, .z);
    try f.until(r, host, struct {
        fn again(m: *Machine) bool {
            return inSelect(m) and selectOf(m).?.cpu_pass;
        }
    }.again, 600, "the select again, for the CPU");
    try r.press(host, .right);
    try r.step(4);
    try r.press(host, .z);
    try f.until(r, host, playing, 2400, "round 1 with the CPU");
    const setup = &host.game.state.setup;
    try f.check(setup.cpu[1] and setup.characters[1] == .axel and roundOf(host).?.play.world.players[1].entity != null, "the CPU plays player 2, as Axel");
    try r.step(120);

    // A client's own select, and its join in the CPU's place.
    const guest = try r.add(.guest);
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSelect, 600, "the client's own select");
    try r.step(30);
    try r.press(guest, .right);
    try r.step(4);
    const chosen = selectOf(guest).?.cursors[0].place;
    try r.press(guest, .z);
    try f.until(r, guest, inSession, 600, "the client joins the round");
    try f.check(!setup.cpu[1], "player 2 the client's");
    // The CPU's fighter goes at the next logic tick, as the client's drops in.
    try r.step(4);
    try f.check(setup.characters[1] == chosen and roundOf(host).?.play.world.players[1].entity != null, "the client's player drops in, as the character it chose");
    try same(f, r, host, guest, "the same round after the join");
    try sameFor(f, r, host, guest, 300);
    f.note("\"joined_at\":{d},\"character\":\"{s}\"", .{ host.game.state.tick, @tagName(chosen) });

    // The client quits: player 2 is the CPU's again, its fighter playing on.
    try guest.quit();
    r.remove(guest);
    try r.step(30);
    try f.check(!host.inSession() and setup.cpu[1], "player 2 the CPU's again");
    const p2 = &roundOf(host).?.play.world.players[1];
    try f.check(p2.entity != null and !p2.gone and !p2.out, "its fighter plays on");
    try r.step(300);
    try f.check(roundOf(host).?.play.world.players[1].entity != null and setup.cpu[1], "and on");
}

/// The CPU's player 2 is a client's place at the select, and the CPU's again as it quits there.
fn cpuSelect(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    const guest = try r.add(.guest);
    try toMenu(f, r, host);
    try openOptions(f, r, host);
    try pressOption(r, host, .server, .z);
    try pressOption(r, host, .exit, .z);
    try f.until(r, host, choosing, 600, "the host's menu");
    while (menuChoice(host) != .two_players) try r.press(host, .down);
    try r.press(host, .right);
    try r.press(host, .z);
    try f.until(r, host, inSelect, 600, "the host's select");
    try clientJoins(f, r, guest);
    try f.until(r, guest, inSession, 900, "the client joins the select");
    try f.until(r, guest, inSelect, 200, "the select on the client");
    const setup = &host.game.state.setup;
    try f.check(!setup.cpu[1] and selectOf(host).?.players == .two, "both players' cursors, no CPU");
    try same(f, r, host, guest, "the same select");
    try guest.quit();
    r.remove(guest);
    try r.step(30);
    try f.check(!host.inSession() and setup.cpu[1] and selectOf(host).?.players == .one, "player 1 alone, player 2 the CPU's again");
    try r.press(host, .z);
    try f.until(r, host, struct {
        fn again(m: *Machine) bool {
            return inSelect(m) and selectOf(m).?.cpu_pass;
        }
    }.again, 600, "the select again, for the CPU");
    try r.press(host, .z);
    try f.until(r, host, playing, 2400, "round 1 with the CPU");
    try f.check(setup.cpu[1] and roundOf(host).?.play.world.players[1].entity != null, "the CPU plays player 2");
}

/// The host's lobby over the game its client plays: the host's sound is silence.
fn lobbySilence(f: *Flow, r: *Room) !void {
    const pair = try inRoundTogether(f, r);
    try r.press(pair.host, .escape);
    try r.step(30);
    pair.host.backend.audio.pcm.clearRetainingCapacity();
    try r.step(120);
    var loud: usize = 0;
    for (pair.host.backend.audio.pcm.items) |x| loud += @intFromBool(x != 0);
    try f.check(pair.host.game.net.host == .left and pair.host.backend.audio.pcm.items.len != 0 and loud == 0, "the host's lobby over the game: silence");
}

/// In round 1 with a client, the host's settings change FRIENDLY HIT: both games take it at one
/// tick, and stay the same.
fn rulesChange(f: *Flow, r: *Room) !void {
    const pair = try inRoundTogether(f, r);
    const host = pair.host;
    const was = host.game.state.setup.rules.?.friendly_hit;
    try r.press(host, .enter);
    try f.until(r, host, settingsOpen, 80, "the host's settings open");
    host.game.overlays.find(.settings).?.settings.row = .friendly_hit;
    try r.press(host, .z);
    try r.press(host, .escape);
    try f.until(r, host, settingsClosed, 80, "the host's settings close, saving");
    try f.until(r, host, struct {
        fn taken(m: *Machine) bool {
            return m.game.net.pending_rules == null and !m.np().eventDue();
        }
    }.taken, 300, "the change made on both");
    try f.check(host.game.state.setup.rules.?.friendly_hit != was and pair.guest.game.state.setup.rules.?.friendly_hit != was, "FRIENDLY HIT changed in both games");
    try sameFor(f, r, host, pair.guest, 120);
}

/// The host alone in round 1 (its server open, 1 PLAYER), an observer watching: the host's
/// settings change FRIENDLY HIT with no client in its game; the observer gets the game again.
fn observerRules(f: *Flow, r: *Room) !void {
    const host = try r.add(.host);
    try toMenu(f, r, host);
    try openOptions(f, r, host);
    try pressOption(r, host, .server, .z);
    try pressOption(r, host, .exit, .z);
    try f.until(r, host, choosing, 600, "the host's menu");
    while (menuChoice(host) != .one_player) try r.press(host, .up);
    try r.press(host, .z);
    try f.until(r, host, inSelect, 600, "the host's select");
    try r.press(host, .z);
    try f.until(r, host, playing, 2400, "round 1, player 1 alone");
    const watcher = try observerWatches(f, r);
    try r.step(120);
    const was = host.game.state.setup.rules.?.friendly_hit;
    try r.press(host, .enter);
    try f.until(r, host, settingsOpen, 80, "the host's settings open");
    host.game.overlays.find(.settings).?.settings.row = .friendly_hit;
    try r.press(host, .z);
    try r.press(host, .escape);
    try f.until(r, host, settingsClosed, 80, "the host's settings close, saving");
    try r.step(240);
    try f.check(host.game.state.setup.rules.?.friendly_hit != was and watcher.game.state.setup.rules.?.friendly_hit != was, "FRIENDLY HIT changed for the observer too");
    try f.check(watcher.game.net.client == .observing and watcher.np().phase() != .desynced and watcher.message() != .desynced, "the observer watches on, no difference found");
}

/// Player `k`'s fighter's health on machine `m`.
fn healthOf(m: *Machine, k: u1) i32 {
    const w = &roundOf(m).?.play.world;
    return w.getConst(w.players[k].entity orelse return -1).?.health;
}

/// Player 2 put just in front of player 1, facing it, on both machines at one tick (the same
/// change to both games).
fn faceOff(r: *Room, pair: Pair) !void {
    try level(r, pair.host, pair.guest);
    for ([_]*Machine{ pair.host, pair.guest }) |m| {
        const w = &m.game.state.scenes.base.round.play.world;
        const one = w.get(w.players[0].entity.?).?;
        const two = w.get(w.players[1].entity.?).?;
        two.position = one.position.add(.pixels(28, 0, 0));
        one.facing = .right;
        two.facing = .left;
    }
}

/// Player 1's punches at player 2 (its attack button, X), a few.
fn punches(r: *Room, host: *Machine) !void {
    for (0..4) |_| {
        try r.press(host, .x);
        try r.step(12);
    }
    try r.step(30);
}

/// In round 1 with a client: player 1's punches hurt player 2 (FRIENDLY HIT on); the host's
/// settings, by their keys, turn FRIENDLY HIT off; its punches no longer do; the same game on
/// both.
fn friendly(f: *Flow, r: *Room) !void {
    const pair = try inRoundTogether(f, r);
    try f.check(pair.host.game.state.setup.rules.?.friendly_hit, "FRIENDLY HIT on");
    try faceOff(r, pair);
    const before = healthOf(pair.guest, 1);
    try punches(r, pair.host);
    try level(r, pair.host, pair.guest);
    f.note("\"health_on\":[{d},{d}]", .{ before, healthOf(pair.guest, 1) });
    try f.check(healthOf(pair.host, 1) < before and healthOf(pair.guest, 1) < before, "player 1's punches hurt player 2");
    // The host's settings by their keys: START, down to FRIENDLY HIT, A, Escape (saving).
    try r.press(pair.host, .enter);
    try f.until(r, pair.host, settingsOpen, 80, "the host's settings open");
    var n: usize = 0;
    while (pair.host.game.overlays.find(.settings).?.settings.row != .friendly_hit and n < 20) : (n += 1) try r.press(pair.host, .down);
    try f.check(pair.host.game.overlays.find(.settings).?.settings.row == .friendly_hit, "FRIENDLY HIT's line reached");
    try r.press(pair.host, .z);
    try r.press(pair.host, .escape);
    try f.until(r, pair.host, settingsClosed, 120, "the host's settings close");
    try f.until(r, pair.guest, struct {
        fn off(m: *Machine) bool {
            return !m.game.state.setup.rules.?.friendly_hit;
        }
    }.off, 300, "the client's game: FRIENDLY HIT off");
    try f.check(!pair.host.game.state.setup.rules.?.friendly_hit, "the host's game: FRIENDLY HIT off");
    try r.step(90);
    try faceOff(r, pair);
    const after = healthOf(pair.guest, 1);
    try punches(r, pair.host);
    try level(r, pair.host, pair.guest);
    f.note("\"health_off\":[{d},{d}]", .{ after, healthOf(pair.guest, 1) });
    try f.check(healthOf(pair.host, 1) == after and healthOf(pair.guest, 1) == after, "FRIENDLY HIT off: player 1's punches do not hurt player 2");
    try same(f, r, pair.host, pair.guest, "the same game on both");
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
        .{ .name = "server", .run = server },
        .{ .name = "left", .run = left },
        .{ .name = "rejoin", .run = rejoin },
        .{ .name = "select_escape", .run = selectEscape },
        .{ .name = "observer_select", .run = observerSelect },
        .{ .name = "observer_lobby", .run = observerLobby },
        .{ .name = "observe_start", .run = observeStart },
        .{ .name = "desync_host", .run = desyncHost },
        .{ .name = "desync_client", .run = desyncClient },
        .{ .name = "select_link_down", .run = selectLinkDown },
        .{ .name = "client_gives_up", .run = clientGivesUp },
        .{ .name = "event_reconnect", .run = eventReconnect },
        .{ .name = "stop_left", .run = stopLeft },
        .{ .name = "local_two", .run = localTwo },
        .{ .name = "cpu", .run = cpuPlace },
        .{ .name = "cpu_select", .run = cpuSelect },
        .{ .name = "lobby_silence", .run = lobbySilence },
        .{ .name = "rules", .run = rulesChange },
        .{ .name = "observer_rules", .run = observerRules },
        .{ .name = "friendly", .run = friendly },
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

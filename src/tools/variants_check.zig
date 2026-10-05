//! sorz-variants-check: the gate of the variants (PLAN item 19): each variant's flow played from
//! power-on on the content extracted from the user's ROM, as the hosts run it (the game in the
//! agent backend, its keys injected), its steps checked on the game's state and its overlays.
//!
//!   sorz-variants-check ROM
//!
//! - original: the cartridge's game menu (1 PLAYER, 2 PLAYERS, OPTIONS); OPTIONS without VOLUME;
//!   the settings key opens the settings over the options, the game held; Escape saves and leaves.
//! - extended: SETTINGS after 2 PLAYERS opens the settings over the menu (the game held, the
//!   volume's row not there: it is OPTIONS'), EXIT WITHOUT SAVING gives the menu back as it was;
//!   OPTIONS has VOLUME before EXIT, and the record's volume follows it; 1 PLAYER, the select, the
//!   round.
//! - network, a browser's page alone (one player, the page's own volume): START, SETTINGS,
//!   OPTIONS; no VOLUME; START to the select with one player, then the round.
//! - network, two games in a session (the in-memory network): the host's start is both games';
//!   player 2 opens their settings from the menu: the host holds and says why, both hear the
//!   game's hold; then START, the select (each player's pad), the round; the two states the same
//!   and the session's checks without a difference.
//!
//! Prints a JSON line per flow, and exits with 1 when a step fails.
const std = @import("std");
const sorz = @import("sorz");
const agent = @import("agent");
const extract = @import("extract");

const platform = sorz.platform;
const Key = platform.Key;
const frame_ns = agent.netplay_cmd.frame_ns;

/// A game in the agent backend, one tick per update.
const Run = struct {
    backend: agent.AgentBackend,
    storage: sorz.memory.MemoryStorage,
    game: sorz.Game,
    updates: u32 = 0,

    fn create(gpa: std.mem.Allocator, assets: platform.AssetSource, variant: sorz.variant.Variant) !*Run {
        const r = try gpa.create(Run);
        errdefer gpa.destroy(r);
        r.backend = agent.AgentBackend.init(gpa, .{});
        r.storage = sorz.memory.MemoryStorage.init(gpa);
        r.game = try sorz.Game.init(gpa, assets, r.storage.storage());
        r.game.pacing = .per_update;
        r.game.variant = variant;
        r.updates = 0;
        return r;
    }

    fn destroy(r: *Run, gpa: std.mem.Allocator) void {
        r.game.deinit();
        r.storage.deinit();
        r.backend.deinit();
        gpa.destroy(r);
    }

    fn update(r: *Run) !void {
        var p = r.backend.asPlatform();
        _ = try r.game.update(&p);
        r.backend.advance(frame_ns);
        r.updates += 1;
    }

    fn key(r: *Run, k: Key, pressed: bool) !void {
        try r.backend.inject(.{ .time_ns = r.backend.clock_ns, .payload = if (pressed) .{ .key_down = .{ .key = k } } else .{ .key_up = .{ .key = k } } });
    }

    /// `k` pressed for an update, then released for one.
    fn press(r: *Run, k: Key) !void {
        try r.key(k, true);
        try r.update();
        try r.key(k, false);
        try r.update();
    }

    fn scene(r: *const Run) sorz.flow.Kind {
        return std.meta.activeTag(r.game.state.scenes.base);
    }

    fn menu(r: *const Run) ?*const sorz.screens.menu.Menu {
        return switch (r.game.state.scenes.base) {
            .menu => |*m| m,
            else => null,
        };
    }
};

/// A step of a flow that did not hold.
const Failure = error{StepFailed};

const Flow = struct {
    out: *std.Io.Writer,
    name: []const u8,
    steps: u32 = 0,
    failed: ?[]const u8 = null,

    fn check(f: *Flow, ok: bool, what: []const u8) Failure!void {
        f.steps += 1;
        if (ok) return;
        f.failed = what;
        return error.StepFailed;
    }

    /// Updates `r` until `cond` holds, `limit` updates at most.
    fn until(f: *Flow, r: *Run, cond: *const fn (*const Run) bool, limit: u32, what: []const u8) !void {
        var n: u32 = 0;
        while (!cond(r)) : (n += 1) {
            if (n == limit) return f.check(false, what);
            try r.update();
        }
        try f.check(true, what);
    }

    fn report(f: *Flow, r: ?*const Run) !void {
        try f.out.print("{{\"flow\":\"{s}\",\"pass\":{},\"steps\":{d}", .{ f.name, f.failed == null, f.steps });
        if (f.failed) |w| try f.out.print(",\"failed\":\"{s}\"", .{w});
        if (r) |x| try f.out.print(",\"ticks\":{d},\"scene\":\"{s}\"", .{ x.game.state.tick, @tagName(x.scene()) });
        try f.out.writeAll("}\n");
        try f.out.flush();
    }
};

fn choosing(r: *const Run) bool {
    const m = r.menu() orelse return false;
    return m.phase == .choosing and !r.game.overlays.holds();
}

fn inOptions(r: *const Run) bool {
    return switch (r.game.state.scenes.base) {
        .options => |*o| o.phase == .lines and r.game.state.scenes.overlay_count == 0,
        else => false,
    };
}

fn inSelect(r: *const Run) bool {
    return switch (r.game.state.scenes.base) {
        .select => |*s| s.phase == .first_half or s.phase == .second_half,
        else => false,
    };
}

fn inRound(r: *const Run) bool {
    return r.scene() == .round and r.game.state.scenes.overlay_count == 0;
}

fn settingsOpen(r: *const Run) bool {
    return r.game.settingsOpen();
}

/// From power-on to the game menu: START on the intro, then on the title.
fn toMenu(f: *Flow, r: *Run) !void {
    while (r.updates < 500) try r.update();
    try r.press(.enter);
    while (r.updates < 560) try r.update();
    try r.press(.enter);
    try f.until(r, choosing, 400, "the game menu");
}

/// The arrow down `n` lines.
fn down(r: *Run, n: usize) !void {
    for (0..n) |_| try r.press(.down);
}

fn lines(r: *const Run) []const sorz.variant.MenuLine {
    const m = r.menu().?;
    return m.lines[0..m.line_count];
}

fn original(f: *Flow, r: *Run) !void {
    try toMenu(f, r);
    try f.check(std.mem.eql(sorz.variant.MenuLine, lines(r), &.{ .one_player, .two_players, .options }), "the cartridge's menu");
    try down(r, 2);
    try r.press(.enter);
    try f.until(r, inOptions, 400, "OPTIONS");
    try f.check(r.game.state.setup.volume == null, "OPTIONS without VOLUME");
    // The settings key: the settings over OPTIONS, the game held.
    try r.press(.f1);
    try f.check(settingsOpen(r), "the settings key opens the settings");
    const tick = r.game.state.tick;
    for (0..30) |_| try r.update();
    try f.check(r.game.state.tick == tick, "the settings hold the game");
    const saves = r.game.saves_written;
    try r.press(.escape);
    try f.check(!settingsOpen(r) and r.game.saves_written == saves + 1, "Escape saves and leaves");
    try r.update();
    try f.check(r.game.state.tick > tick and !r.game.finished, "the game goes on");
}

fn extended(f: *Flow, r: *Run) !void {
    try toMenu(f, r);
    try f.check(std.mem.eql(sorz.variant.MenuLine, lines(r), &.{ .one_player, .two_players, .settings, .options }), "SETTINGS after 2 PLAYERS");
    try down(r, 2);
    const tick = r.game.state.tick;
    try r.press(.enter);
    try f.check(settingsOpen(r), "SETTINGS opens the settings");
    const screen = &r.game.overlays.find(.settings).?.settings;
    try f.check(!screen.facts.volume, "the volume is OPTIONS', not the settings'");
    for (0..30) |_| try r.update();
    try f.check(r.game.state.tick <= tick + 2, "the settings hold the game");
    // A change, then EXIT WITHOUT SAVING (up from the first row: the last): given back.
    const before = r.game.settings;
    try r.press(.down);
    try r.press(.enter);
    try r.press(.q);
    try f.check(!std.meta.eql(before, r.game.settings), "a key changed");
    try r.press(.up);
    try r.press(.up);
    const saves = r.game.saves_written;
    try r.press(.enter);
    try f.check(!settingsOpen(r) and std.meta.eql(before, r.game.settings) and r.game.saves_written == saves, "EXIT WITHOUT SAVING gives the settings back");
    try f.until(r, choosing, 10, "the menu goes on");
    try f.check(r.menu().?.choice == .settings, "the arrow on SETTINGS");
    try down(r, 1);
    try r.press(.enter);
    try f.until(r, inOptions, 400, "OPTIONS");
    try f.check(r.game.state.setup.volume.? == 100, "OPTIONS with VOLUME, the record's");
    // Down to VOLUME (SOUND TEST, LEVEL, CONTROL, VOLUME): a tick after each move, as the cursor
    // arrives.
    for (0..3) |_| {
        try r.press(.down);
        try r.update();
    }
    try r.press(.left);
    try f.check(r.game.state.setup.volume.? == 90 and r.game.settings.sound.volume == 90, "VOLUME sets the record's volume");
    try r.press(.enter);
    try f.until(r, choosing, 400, "back to the menu");
    try r.press(.enter);
    try f.until(r, inSelect, 600, "the select");
    try f.check(r.game.state.setup.players == .one, "1 PLAYER");
    try r.press(.right);
    try r.press(.z);
    try f.until(r, inRound, 1200, "the round");
}

fn page(f: *Flow, r: *Run) !void {
    try toMenu(f, r);
    try f.check(std.mem.eql(sorz.variant.MenuLine, lines(r), &.{ .start, .settings, .options }), "START, SETTINGS, OPTIONS");
    try f.check(r.game.state.setup.volume == null, "no VOLUME line (the page's own volume)");
    try down(r, 1);
    try r.press(.enter);
    try f.check(settingsOpen(r) and r.game.overlays.find(.settings).?.settings.facts.volume and r.game.overlays.find(.settings).?.settings.facts.one_player, "the settings: one player's keys, the volume");
    try r.press(.escape);
    try f.check(!settingsOpen(r), "Escape leaves");
    try r.press(.up);
    try r.press(.enter);
    try f.until(r, inSelect, 600, "the select");
    try f.check(r.game.state.setup.players == .one, "one player");
    try r.press(.right);
    try r.press(.z);
    try f.until(r, inRound, 1200, "the round");
}

/// Two games of a session over the in-memory network, updated in turn.
const Pair = struct {
    network: sorz.net.memory.Network,
    host: *Run,
    guest: *Run,

    fn update(p: *Pair) !void {
        try p.host.update();
        try p.guest.update();
    }

    fn press(p: *Pair, r: *Run, k: Key) !void {
        try r.key(k, true);
        try p.update();
        try r.key(k, false);
        try p.update();
    }
};

fn pairUntil(f: *Flow, p: *Pair, cond: *const fn (*const Run) bool, limit: u32, what: []const u8) !void {
    var n: u32 = 0;
    while (!(cond(p.host) and cond(p.guest))) : (n += 1) {
        if (n == limit) return f.check(false, what);
        try p.update();
    }
    try f.check(true, what);
}

fn pairStep(p: *Pair, n: usize) !void {
    for (0..n) |_| try p.update();
}

fn session(f: *Flow, gpa: std.mem.Allocator, assets: platform.AssetSource) !void {
    var p: Pair = .{ .network = sorz.net.memory.Network.init(gpa), .host = try Run.create(gpa, assets, .network), .guest = try Run.create(gpa, assets, .original) };
    defer {
        p.host.destroy(gpa);
        p.guest.destroy(gpa);
        p.network.deinit();
    }
    for ([_]*Run{ p.host, p.guest }, [_]sorz.net.netplay.Role{ .host, .guest }) |r, role| {
        r.backend.transport = (try p.network.endpoint()).transport();
        try r.game.startNetplay(.{
            .role = role,
            .address = if (role == .host) "7000" else "ws://localhost:7000",
            .build = sorz.net.protocol.buildId(sorz.version.build),
            .data = @splat(1),
            .delay = if (role == .host) 3 else null,
            .log = false,
        });
    }
    const started = struct {
        fn on(r: *const Run) bool {
            return r.game.net_epoch == 1;
        }
    }.on;
    try pairUntil(f, &p, started, 100, "the session starts");
    try f.check(p.guest.game.state.start.variant == .network and p.host.game.state.start.players == .two, "the host's start is both games'");
    // The front end, the host's START.
    for (0..500) |_| try p.update();
    try p.press(p.host, .enter);
    for (0..60) |_| try p.update();
    try p.press(p.host, .enter);
    try pairUntil(f, &p, choosing, 400, "the game menu on both");
    // Player 2 opens their settings from the menu: down, then Enter, on the guest's pad.
    try p.press(p.guest, .down);
    try pairStep(&p, 6);
    try p.press(p.guest, .enter);
    try pairStep(&p, 8);
    try f.check(settingsOpen(p.guest) and !settingsOpen(p.host), "player 2's settings, on player 2's machine");
    try f.check(p.host.game.overlays.find(.peer_settings) != null, "player 1's machine says why it holds");
    const ticks = .{ p.host.game.state.tick, p.guest.game.state.tick };
    try pairStep(&p, 60);
    try f.check(p.host.game.state.tick == ticks[0] and p.guest.game.state.tick == ticks[1], "both games hold");
    try p.press(p.guest, .escape);
    try pairStep(&p, 8);
    try f.check(!settingsOpen(p.guest) and p.host.game.overlays.find(.peer_settings) == null and p.host.game.state.tick > ticks[0], "both go on");
    // START (up to it), the select with each player's pad, the round.
    try p.press(p.host, .up);
    try pairStep(&p, 6);
    try p.press(p.host, .enter);
    try pairUntil(f, &p, inSelect, 600, "the select on both");
    try f.check(p.host.game.state.setup.players == .two, "two players");
    try p.press(p.host, .right);
    try p.press(p.host, .z);
    try p.press(p.guest, .z);
    try pairUntil(f, &p, inRound, 1200, "the round on both");
    for (0..600) |_| try p.update();
    try f.check(p.host.game.state.hash() == p.guest.game.state.hash() and p.host.game.state.tick == p.guest.game.state.tick, "the same state");
    try f.check(p.host.game.netplay.?.difference == null and p.host.game.netplay.?.phase() == .playing, "the session's checks agree");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const rom_path = args.next() orelse {
        try std.Io.File.stderr().writeStreamingAll(io, "usage: sorz-variants-check ROM\n");
        std.process.exit(2);
    };
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(extract.rom.size + 1));
    defer gpa.free(rom);
    var tree = try extract.extract(gpa, rom);
    defer tree.deinit();
    var source = sorz.memory.MemoryAssetSource.init(gpa);
    defer source.deinit();
    try tree.addTo(&source);
    const assets = source.assetSource();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var all = true;
    const Single = struct { name: []const u8, variant: sorz.variant.Variant, page: bool, run: *const fn (*Flow, *Run) anyerror!void };
    for ([_]Single{
        .{ .name = "original", .variant = .original, .page = false, .run = original },
        .{ .name = "extended", .variant = .extended, .page = false, .run = extended },
        .{ .name = "network_page", .variant = .network, .page = true, .run = page },
    }) |s| {
        var f: Flow = .{ .out = &out.interface, .name = s.name };
        const r = try Run.create(gpa, assets, s.variant);
        defer r.destroy(gpa);
        if (s.page) {
            r.game.setOnePlayer();
            r.game.host_volume = true;
        }
        s.run(&f, r) catch |e| if (e != error.StepFailed) return e;
        try f.report(r);
        all = all and f.failed == null;
    }
    var f: Flow = .{ .out = &out.interface, .name = "network_session" };
    session(&f, gpa, assets) catch |e| if (e != error.StepFailed) return e;
    try f.report(null);
    all = all and f.failed == null;
    if (!all) std.process.exit(1);
}

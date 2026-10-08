//! sorz-variants-check: the gate of the variants (PLAN item 19): each variant's flow played from
//! power-on on the content extracted from the user's ROM, as the hosts run it (the game in the
//! agent backend, its keys injected), its steps checked on the game's state and its overlays.
//!
//!   sorz-variants-check ROM
//!
//! - original: the cartridge's game menu (1 PLAYER, 2 PLAYERS, OPTIONS) and options (no ADVANCED
//!   SETTINGS); the settings key opens the settings over the options (its row there), the game
//!   held; Escape saves and leaves; 1 PLAYER to the round, where START pauses (no settings).
//! - extended: the cartridge's menu; OPTIONS has ADVANCED SETTINGS right before EXIT, which opens
//!   the settings (the game held, both players' keys and the volume, no settings key: F1 is no
//!   key of the game); EXIT WITHOUT SAVING gives the settings back and OPTIONS goes on; 1 PLAYER,
//!   the select, the round, where START opens the settings in place of the pause (the round not
//!   paused, the game held, the pause's jingle), and Escape goes back to play.
//! - network, as a browser's page plays it alone (one player): 2 PLAYERS and OPTIONS; ADVANCED
//!   SETTINGS opens one player's settings; 2 PLAYERS to the select with this machine's player
//!   alone, then the round, where START opens the settings.
//! - network, a guest's OPTIONS: SOUND TEST, ADVANCED SETTINGS and EXIT alone.
//!
//! The network's sessions (the join, the two games in lockstep) are netplay-check's. Prints a JSON
//! line per flow, and exits with 1 when a step fails.
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

fn settingsClosed(r: *const Run) bool {
    return !r.game.settingsOpen();
}

fn onPage(r: *const Run, which: sorz.settings.screen.Page) bool {
    const o = @constCast(&r.game.overlays).find(.settings) orelse return false;
    return o.settings.page == which;
}

fn onInputPage(r: *const Run) bool {
    return onPage(r, .input);
}

fn onFirstPage(r: *const Run) bool {
    return onPage(r, .main);
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

fn optionsOf(r: *const Run) ?*const sorz.screens.options.Options {
    return switch (r.game.state.scenes.base) {
        .options => |*o| o,
        else => null,
    };
}

fn roundOf(r: *const Run) ?*const sorz.scene.Round {
    return switch (r.game.state.scenes.base) {
        .round => |*x| x,
        else => null,
    };
}

fn playing(r: *const Run) bool {
    const x = roundOf(r) orelse return false;
    return x.phase == .play and r.game.state.scenes.overlay_count == 0 and !r.game.overlays.holds();
}

/// The options' cursor up `n` lines, a tick after each move, as the cursor arrives.
fn optionsUp(r: *Run, n: usize) !void {
    for (0..n) |_| {
        try r.press(.up);
        try r.update();
    }
}

/// From the menu's first line, the line `line` chosen, to the round with one player: the select's
/// cursor right, a choice, the round's play.
fn toRound(f: *Flow, r: *Run, line: usize) !void {
    try f.until(r, choosing, 400, "the menu");
    try down(r, line);
    try r.press(.enter);
    try f.until(r, inSelect, 600, "the select");
    try f.check(r.game.state.setup.players == .one, "one player in the select");
    try r.press(.right);
    try r.press(.z);
    try f.until(r, playing, 2400, "the round's play");
}

fn original(f: *Flow, r: *Run) !void {
    try toMenu(f, r);
    try f.check(std.mem.eql(sorz.variant.MenuLine, lines(r), &.{ .one_player, .two_players, .options }), "the cartridge's menu");
    try down(r, 2);
    try r.press(.enter);
    try f.until(r, inOptions, 400, "OPTIONS");
    try f.check(!optionsOf(r).?.advanced_settings, "OPTIONS without ADVANCED SETTINGS");
    // Up from SOUND TEST: EXIT, then CONTROL.
    try optionsUp(r, 2);
    try f.check(optionsOf(r).?.line == .control, "CONTROL right before EXIT");
    // The settings key: the settings over OPTIONS, the game held.
    try r.press(.f1);
    try f.check(settingsOpen(r), "the settings key opens the settings");
    try f.check(r.game.overlays.find(.settings).?.settings.facts.settings_key, "the settings key's row");
    const tick = r.game.state.tick;
    for (0..30) |_| try r.update();
    try f.check(r.game.state.tick == tick, "the settings hold the game");
    const saves = r.game.saves_written;
    try r.press(.escape);
    try f.check(!settingsOpen(r) and r.game.saves_written == saves + 1, "Escape saves and leaves");
    try r.update();
    try f.check(r.game.state.tick > tick and !r.game.finished, "the game goes on");
    // EXIT (down from CONTROL), the menu, 1 PLAYER, the round: START pauses.
    try r.press(.down);
    try r.update();
    try r.press(.enter);
    try toRound(f, r, 0);
    try r.press(.enter);
    for (0..4) |_| try r.update();
    try f.check(roundOf(r).?.phase == .paused and !settingsOpen(r), "START pauses the round");
    try r.press(.enter);
    for (0..4) |_| try r.update();
    try f.check(roundOf(r).?.phase == .play, "START ends the pause");
}

fn extended(f: *Flow, r: *Run) !void {
    try toMenu(f, r);
    try f.check(std.mem.eql(sorz.variant.MenuLine, lines(r), &.{ .one_player, .two_players, .options }), "the cartridge's menu");
    try down(r, 2);
    try r.press(.enter);
    try f.until(r, inOptions, 400, "OPTIONS");
    try f.check(optionsOf(r).?.advanced_settings, "OPTIONS with ADVANCED SETTINGS");
    try optionsUp(r, 2);
    try f.check(optionsOf(r).?.line == .advanced_settings, "ADVANCED SETTINGS right before EXIT");
    // F1 is no key of the extended game.
    try r.press(.f1);
    try f.check(!settingsOpen(r), "no settings key");
    // The options fade out, then the settings fade in, without the pause's jingle.
    try r.press(.z);
    try f.until(r, settingsOpen, 80, "ADVANCED SETTINGS opens the settings");
    try f.check(r.game.jingle_at == null, "no pause's jingle from the options");
    const screen = &r.game.overlays.find(.settings).?.settings;
    try f.check(screen.facts.players == 2 and !screen.facts.settings_key and screen.facts.rules, "both players' columns, no settings key, the rules");
    const tick = r.game.state.tick;
    for (0..30) |_| try r.update();
    try f.check(r.game.state.tick == tick, "the settings hold the game");
    // INPUT CONFIGURATION, a key changed (player 1's up), START back; then EXIT WITHOUT SAVING
    // (up from the first row: the last): given back, as the settings fade out.
    // The page turns once the panel has faded out, and fades in on the next.
    const before = r.game.settings;
    try r.press(.z);
    try f.until(r, onInputPage, 80, "INPUT CONFIGURATION, faded out to it");
    try r.press(.down);
    try r.press(.z);
    try r.press(.q);
    try f.check(!std.meta.eql(before, r.game.settings), "a key changed");
    try r.press(.enter);
    try f.until(r, onFirstPage, 80, "back on the first page");
    try r.press(.up);
    const saves = r.game.saves_written;
    try r.press(.z);
    try f.until(r, settingsClosed, 80, "the settings fade out");
    try f.check(std.meta.eql(before, r.game.settings) and r.game.saves_written == saves, "EXIT WITHOUT SAVING gives the settings back");
    try f.until(r, inOptions, 80, "OPTIONS go on");
    try f.check(optionsOf(r).?.line == .advanced_settings, "the cursor on ADVANCED SETTINGS");
    // EXIT, the menu, 1 PLAYER, the round: START opens the settings in place of the pause.
    try r.press(.down);
    try r.update();
    try r.press(.enter);
    try toRound(f, r, 0);
    try startOpensSettings(f, r);
}

/// START in play: the settings open in place of the pause, the game held with the pause's
/// jingle; Escape (save and leave) and play goes on.
fn startOpensSettings(f: *Flow, r: *Run) !void {
    try r.press(.enter);
    for (0..4) |_| try r.update();
    try f.check(settingsOpen(r) and roundOf(r).?.phase == .play, "START opens the settings, the round not paused");
    try f.check(r.game.jingle.len == 0 or r.game.jingle_at != null, "the pause's jingle");
    const tick = r.game.state.tick;
    for (0..30) |_| try r.update();
    try f.check(r.game.state.tick == tick, "the settings hold the game");
    try r.press(.escape);
    for (0..4) |_| try r.update();
    try f.check(!settingsOpen(r) and roundOf(r).?.phase == .play and r.game.state.tick > tick, "play goes on");
}

fn page(f: *Flow, r: *Run) !void {
    try toMenu(f, r);
    try f.check(std.mem.eql(sorz.variant.MenuLine, lines(r), &.{ .two_players, .options }), "2 PLAYERS and OPTIONS");
    try f.check(r.menu().?.all_lines, "2 PLAYERS offered (the other player is the network's)");
    try down(r, 1);
    try r.press(.enter);
    try f.until(r, inOptions, 400, "OPTIONS");
    try optionsUp(r, 2);
    try r.press(.z);
    try f.until(r, settingsOpen, 80, "ADVANCED SETTINGS opens the settings");
    const screen = &r.game.overlays.find(.settings);
    try f.check(screen.* != null and screen.*.?.settings.facts.players == 1, "the settings: one player's");
    try r.press(.escape);
    try f.until(r, settingsClosed, 80, "Escape leaves");
    try f.until(r, inOptions, 80, "OPTIONS go on");
    try r.press(.down);
    try r.update();
    try r.press(.enter);
    try toRound(f, r, 0);
    try startOpensSettings(f, r);
}

fn guestOptions(f: *Flow, r: *Run) !void {
    try toMenu(f, r);
    try down(r, 1);
    try r.press(.enter);
    try f.until(r, inOptions, 400, "OPTIONS");
    const o = optionsOf(r).?;
    try f.check(o.own_only and o.advanced_settings, "the guest's own lines");
    try optionsUp(r, 1);
    try f.check(optionsOf(r).?.line == .exit, "EXIT");
    try optionsUp(r, 1);
    try f.check(optionsOf(r).?.line == .advanced_settings, "ADVANCED SETTINGS");
    try optionsUp(r, 1);
    try f.check(optionsOf(r).?.line == .control, "CONTROL, its player's buttons");
    try optionsUp(r, 1);
    try f.check(optionsOf(r).?.line == .sound_test, "SOUND TEST, no LEVEL");
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
    const Single = struct { name: []const u8, variant: sorz.variant.Variant, page: bool = false, guest: bool = false, run: *const fn (*Flow, *Run) anyerror!void };
    for ([_]Single{
        .{ .name = "original", .variant = .original, .run = original },
        .{ .name = "extended", .variant = .extended, .run = extended },
        .{ .name = "network_page", .variant = .network, .page = true, .run = page },
        .{ .name = "network_guest_options", .variant = .network, .page = true, .guest = true, .run = guestOptions },
    }) |sg| {
        var f: Flow = .{ .out = &out.interface, .name = sg.name };
        const r = try Run.create(gpa, assets, sg.variant);
        defer r.destroy(gpa);
        if (sg.page) {
            r.game.setOnePlayer();
            r.game.host_volume = true;
        }
        r.game.guest = sg.guest;
        sg.run(&f, r) catch |e| if (e != error.StepFailed) return e;
        try f.report(r);
        all = all and f.failed == null;
    }
    if (!all) std.process.exit(1);
}

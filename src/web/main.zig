//! The browser build: the shared game in a WebAssembly module (DESIGN.md 5.3). The page's script,
//! `sorz.js`, gives the module the game's files that the page's server sends (the native game's own
//! copy: the player never gives any), starts the game and calls `gp_frame` once for each animation
//! frame. The module draws, plays sound and reads input through `WebBackend`, which calls the
//! functions that the script imports. Every file is in memory before the game starts, so no read
//! waits and the module needs no suspension of its stack (no Asyncify). The module links no libc,
//! and the script gives it its memory.
//!
//! The page has no menu of its own: once its files are in, the game runs its own front end, the
//! network variant's (DESIGN.md 5.3, 9), and draws network play's messages itself. The page's own
//! screens (the loading screen, the messages of errors) are the module's to draw in the game's
//! style (`screens.zig`), from the first files the page fetches, the content's font and menu
//! (`gp_screen_*`); without them (a tree without that art), `gp_screen_open` refuses and the page's
//! own text stands in, in the menu's colours.
//!
//! Network play: a native host's page is its client (`gp_start_netplay`, at once: the game connects
//! as it starts). On a relay, the page joins the relay as it loads, and gives the game the role the
//! relay gives it (`gp_start_netplay`): the first page hosts, every other is its client.
//!
//! The game's settings record is the page's only settings (`settings.zig`): the module tells the
//! page the record's sound and window when the game starts and whenever they change
//! (`js_settings`), and the page applies them as a browser does.
const std = @import("std");
const sorz = @import("sorz");
const Host = @import("host.zig").Host;
const WebBackend = @import("backend.zig").WebBackend;
const PageStorage = @import("storage.zig").PageStorage;
const keys = @import("keys.zig");
const gamepad = @import("gamepad.zig");
const page_settings = @import("settings.zig");
const screens_mod = @import("screens.zig");
const record = sorz.settings.record;

// --- the functions of the page ---------------------------------------------------------------

const page = struct {
    extern "env" fn js_now() f64;
    extern "env" fn js_set_resolution(width: u32, height: u32) void;
    extern "env" fn js_present(pixels: [*]const u8, width: u32, height: u32, stride: u32) void;
    extern "env" fn js_audio_open(rate: u32, channels: u32) u32;
    extern "env" fn js_audio_queue(samples: [*]const i16, frames: u32, channels: u32) u32;
    extern "env" fn js_audio_queued() f64;
    extern "env" fn js_audio_state() u32;
    extern "env" fn js_audio_clear() void;
    extern "env" fn js_audio_close() void;
    extern "env" fn js_set_relative_mouse(enabled: u32) u32;
    extern "env" fn js_log(level: u32, text: [*]const u8, len: u32) void;
    extern "env" fn js_storage_save(name: [*]const u8, name_len: u32, bytes: [*]const u8, len: u32) u32;
    extern "env" fn js_storage_delete(name: [*]const u8, name_len: u32) u32;
    extern "env" fn js_net_connect(url: [*]const u8, url_len: u32) u32;
    extern "env" fn js_net_send(id: u32, bytes: [*]const u8, len: u32) u32;
    extern "env" fn js_net_close(id: u32) void;
    /// The settings' sound and window, as the page applies them (`settings.View`): the output's
    /// gain, the picture's scale and full screen (0 or 1).
    extern "env" fn js_settings(gain: f64, scale: u32, fullscreen: u32) void;
};

/// The imported functions use the C calling convention. The backend's table holds Zig functions,
/// so each import has a small Zig function here.
const imports = struct {
    fn nowMs() f64 {
        return page.js_now();
    }
    fn setResolution(width: u32, height: u32) void {
        page.js_set_resolution(width, height);
    }
    fn present(pixels: [*]const u8, width: u32, height: u32, stride: u32) void {
        page.js_present(pixels, width, height, stride);
    }
    fn audioOpen(rate: u32, channels: u32) u32 {
        return page.js_audio_open(rate, channels);
    }
    fn audioQueue(samples: [*]const i16, frames: u32, channels: u32) u32 {
        return page.js_audio_queue(samples, frames, channels);
    }
    fn audioQueued() f64 {
        return page.js_audio_queued();
    }
    fn audioState() u32 {
        return page.js_audio_state();
    }
    fn audioClear() void {
        page.js_audio_clear();
    }
    fn audioClose() void {
        page.js_audio_close();
    }
    fn setRelativeMouse(enabled: u32) u32 {
        return page.js_set_relative_mouse(enabled);
    }
    fn log(level: u32, text: [*]const u8, len: u32) void {
        page.js_log(level, text, len);
    }
    fn storageSave(name: [*]const u8, name_len: u32, bytes: [*]const u8, len: u32) u32 {
        return page.js_storage_save(name, name_len, bytes, len);
    }
    fn storageDelete(name: [*]const u8, name_len: u32) u32 {
        return page.js_storage_delete(name, name_len);
    }
    fn netConnect(url: [*]const u8, url_len: u32) u32 {
        return page.js_net_connect(url, url_len);
    }
    fn netSend(id: u32, bytes: [*]const u8, len: u32) u32 {
        return page.js_net_send(id, bytes, len);
    }
    fn netClose(id: u32) void {
        page.js_net_close(id);
    }
};

const host = Host{
    .now_ms = imports.nowMs,
    .set_resolution = imports.setResolution,
    .present = imports.present,
    .audio_open = imports.audioOpen,
    .audio_queue = imports.audioQueue,
    .audio_queued = imports.audioQueued,
    .audio_state = imports.audioState,
    .audio_clear = imports.audioClear,
    .audio_close = imports.audioClose,
    .set_relative_mouse = imports.setRelativeMouse,
    .log = imports.log,
    .storage_save = imports.storageSave,
    .storage_delete = imports.storageDelete,
    .net_connect = imports.netConnect,
    .net_send = imports.netSend,
    .net_close = imports.netClose,
};

// --- logs and panics go to the browser's console -----------------------------------------------

pub const std_options: std.Options = .{ .logFn = logToConsole };

fn logToConsole(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [512]u8 = undefined;
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const text = std.fmt.bufPrint(&buf, prefix ++ format, args) catch buf[0..];
    page.js_log(@backingInt(level), text.ptr, @intCast(text.len));
}

pub const panic = std.debug.FullPanic(panicToConsole);

fn panicToConsole(message: []const u8, _: ?usize) noreturn {
    const lead = "panic: ";
    page.js_log(0, lead.ptr, lead.len);
    page.js_log(0, message.ptr, @intCast(message.len));
    @trap();
}

// --- the state of the module -------------------------------------------------------------------

const gpa = std.heap.wasm_allocator;

/// The game's files the page's server sent, file by file.
var assets: sorz.memory.MemoryAssetSource = undefined;
var file_count: u32 = 0;
/// The game's records, kept by the page in the browser's storage.
var storage: PageStorage = undefined;
var backend: WebBackend = undefined;
var ready = false;
var game: ?*sorz.Game = null;
/// The view of the settings the page was last told (`js_settings`).
var told: ?page_settings.View = null;
/// The page's screens, once the module has their files (`gp_screen_open`).
var screens: ?*screens_mod.Screens = null;
/// Why the last call failed, for `gp_error`.
var error_text: [512]u8 = undefined;
var error_len: usize = 0;

/// The bytes that the script writes before a call that takes text (a key code, typed text), and
/// where calls that answer with text write it.
var scratch: [4096]u8 = undefined;

fn setError(comptime format: []const u8, args: anytype) void {
    // A text too long for the buffer is cut at its end.
    error_len = if (std.fmt.bufPrint(&error_text, format, args)) |text| text.len else |_| error_text.len;
}

// --- exports -----------------------------------------------------------------------------------

/// Makes the providers and the backend. The script calls it once, first.
export fn gp_init() i32 {
    if (ready) return 0;
    assets = sorz.memory.MemoryAssetSource.init(gpa);
    storage = PageStorage.init(gpa, &host);
    backend = WebBackend.init(gpa, &host);
    ready = true;
    return 0;
}

export fn gp_scratch() [*]u8 {
    return &scratch;
}

export fn gp_scratch_len() u32 {
    return scratch.len;
}

/// The address that `gp_alloc` gives for an empty buffer. It is never written or freed.
var empty_buffer: [1]u8 = .{0};

/// Memory for the script to fill: a game file and its name, or a kept record. Null when the memory
/// cannot grow.
export fn gp_alloc(len: u32) ?[*]u8 {
    if (len == 0) return &empty_buffer;
    const bytes = gpa.alloc(u8, len) catch return null;
    return bytes.ptr;
}

export fn gp_free(ptr: [*]u8, len: u32) void {
    if (len == 0) return;
    gpa.free(ptr[0..len]);
}

/// Adds one of the game's files. The module keeps the name and the bytes, which `gp_alloc` made,
/// for as long as it runs. Returns 0, or -1 for an invalid name (the page frees both).
export fn gp_add_asset(name: [*]u8, name_len: u32, bytes: [*]u8, len: u32) i32 {
    if (!ready) return -1;
    if (game != null) {
        setError("the game has started: it takes no more files", .{});
        return -1;
    }
    assets.add(name[0..name_len], bytes[0..len]) catch |err| {
        setError("{s}: {s}", .{ name[0..@min(name_len, 256)], @errorName(err) });
        return -1;
    };
    file_count += 1;
    return 0;
}

/// Gives back one record that the page kept from an earlier load, before `gp_start`. The module
/// frees the name and the bytes. Returns 0, or -1 when the record cannot be kept.
export fn gp_add_record(name: [*]u8, name_len: u32, bytes: [*]u8, len: u32) i32 {
    defer gp_free(name, name_len);
    defer gp_free(bytes, len);
    if (!ready) return -1;
    storage.add(name[0..name_len], bytes[0..len]) catch return -1;
    return 0;
}

/// Starts the game on the files the page gave. Returns 0, or -1 with the reason in `gp_error`.
export fn gp_start() i32 {
    if (!ready) return -1;
    if (game != null) return 0;
    error_len = 0;
    startGame() catch |err| {
        if (error_len == 0) setError("{s}", .{@errorName(err)});
        return -1;
    };
    return 0;
}

fn startGame() !void {
    // The page runs no game without its files (DESIGN.md 5.3).
    if (file_count == 0) {
        setError("no game data: the page gave no file of the game", .{});
        return error.NoData;
    }
    const g = try gpa.create(sorz.Game);
    errdefer gpa.destroy(g);
    g.* = try sorz.Game.init(gpa, assets.assetSource(), storage.storage());
    // The page's gain is the volume: the game's sound stays at its own level. A page has one
    // player: the network variant (DESIGN.md 10.7), whose game menu's 2 PLAYERS plays with
    // another machine's player.
    g.host_volume = true;
    g.setOnePlayer();
    g.variant = .network;
    game = g;
    tellSettings(g);
}

/// Tells the page the settings' sound and window when they differ from what it was last told.
fn tellSettings(g: *const sorz.Game) void {
    const view = page_settings.View.of(&g.settings);
    if (told) |t| if (std.meta.eql(t, view)) return;
    told = view;
    page.js_settings(view.gain, view.scale, @intFromBool(view.fullscreen));
}

/// The page left its full screen without the game asking (the player pressed Escape, which is the
/// browser's): the setting goes off, as the player chose, and the record keeps it
/// (`Game.fullscreenLeft`).
export fn gp_fullscreen_left() void {
    const g = game orelse return;
    g.fullscreenLeft();
    tellSettings(g);
}

/// Network play (DESIGN.md 9): the game plays with another machine's player. The page calls it
/// after `gp_start`, with the role (0 a client; 1 the host, player 1) and the address (`url_len`
/// bytes in the scratch buffer): a native host's `ws://ADDRESS:PORT/` (the game connects at once),
/// or nothing when the page brings the connections itself (a relay's, once the relay gave the page
/// its role: on a client's page, the first connection the page reports is the host; on the host's,
/// each is a client). A network play the game had goes. The session's identity is this build's and the data's:
/// the digest of the game's files. Returns 0, or -1 with the reason in `gp_error`.
export fn gp_start_netplay(role: u32, url_len: u32) i32 {
    const g = game orelse {
        setError("the game has not started", .{});
        return -1;
    };
    const identity = sorz.net.identity.ofTree(assets.assetSource(), sorz.net.identity.max_file_bytes) catch |err| {
        setError("the game files' identity: {s}", .{@errorName(err)});
        return -1;
    };
    g.startNetplay(.{
        .role = if (role == 1) .host else .guest,
        .address = scratch[0..@min(url_len, scratch.len)],
        .build = sorz.net.protocol.buildId(sorz.version.build),
        .data = identity,
    }) catch |err| {
        setError("{s}", .{@errorName(err)});
        return -1;
    };
    return 0;
}

/// A connection of network play opened: one the game asked for (`incoming` 0), or a relay's client
/// on the host's page (1).
export fn gp_net_connected(id: u32, incoming: u32) void {
    backend.netConnected(id, incoming != 0);
}

/// A whole message on a connection, in memory from `gp_alloc` that the module takes (an empty
/// one's shared address is never freed: freeing nothing is a no-op).
export fn gp_net_received(id: u32, bytes: [*]u8, len: u32) void {
    backend.netReceived(id, bytes[0..len]);
}

/// A connection ended: `reason` as `platform.DisconnectReason` numbers them (0 closed, 1 lost,
/// 2 refused, 3 protocol, 4 too large).
export fn gp_net_disconnected(id: u32, reason: u32) void {
    backend.netDisconnected(id, reason);
}

// --- the page's screens, in the game's style ---------------------------------------------------

// The module draws the page's screens (DESIGN.md 5.3) from the files it needs first, the content's
// font and menu (`screens.zig`), which `gp_screen_files` names for the page to fetch before the
// others: the loading screen and its count, and the messages of errors.

/// The files the screens are drawn from, which the page fetches before the others: the
/// directories of the tree that hold them, each with its `/`, one a line, in the scratch buffer.
/// Returns the length.
export fn gp_screen_files() u32 {
    var w: std.Io.Writer = .fixed(&scratch);
    for (screens_mod.sets, 0..) |set, i| w.print("{s}{s}/", .{ if (i == 0) "" else "\n", set }) catch return 0;
    return @intCast(w.end);
}

/// Makes the screens from the files the page gave so far. Returns 0, or -1 with the reason in
/// `gp_error` while the module cannot draw them: the page's own text then stands in.
export fn gp_screen_open() i32 {
    if (screens != null) return 0;
    if (!ready) return -1;
    const s = gpa.create(screens_mod.Screens) catch {
        setError("no memory for the page's screens", .{});
        return -1;
    };
    var reason: std.Io.Writer = .fixed(&error_text);
    reason.writeAll("the page's screens: ") catch {};
    s.open(gpa, assets.assetSource(), &reason) catch |err| {
        gpa.destroy(s);
        error_len = reason.end;
        if (err != error.BadContent) setError("the page's screens: {s}", .{@errorName(err)});
        return -1;
    };
    screens = s;
    return 0;
}

fn presentScreen(rgba: []const u8) void {
    page.js_present(rgba.ptr, screens_mod.width, screens_mod.height, screens_mod.width * 4);
}

/// The loading screen: `done` of `total` files.
export fn gp_screen_loading(done: u32, total: u32) void {
    const s = screens orelse return;
    presentScreen(s.loading(done, total) catch return);
}

/// A message (`len` bytes in the scratch buffer, lines split at '\n'): on black, or, with `over`,
/// over the game's last picture once it has one. Returns 0, or -1 when the module cannot draw it.
export fn gp_screen_message(len: u32, over: u32) i32 {
    const s = screens orelse return -1;
    var under: ?sorz.platform.RgbaFrame = null;
    if (over != 0) if (game) |g| if (g.frames_presented != 0) {
        under = g.frame();
    };
    presentScreen(s.show(scratch[0..@min(len, scratch.len)], under) catch return -1);
    return 0;
}

// --- the game ------------------------------------------------------------------------------------

/// One update of the game. Returns 0 while the game runs, 1 when it has finished, -1 before
/// `gp_start` and -2 when the update failed (the reason is in `gp_error`).
export fn gp_frame() i32 {
    const g = game orelse return -1;
    var p = backend.asPlatform();
    const result = g.update(&p) catch |err| {
        setError("{s}", .{@errorName(err)});
        return -2;
    };
    tellSettings(g);
    return if (result == .finished) 1 else 0;
}

/// How the game's updates run ticks: 0 as the sound queue or the clock make them due (the game as
/// the player runs it), 1 one tick per update (the agent host's pacing, for the page's checks
/// against `sorz-agent`).
export fn gp_set_pacing(per_update: u32) void {
    const g = game orelse return;
    g.pacing = if (per_update != 0) .per_update else .clock;
}

/// Writes the reason of the last failure into the scratch buffer and returns its length.
export fn gp_error() u32 {
    const len = @min(error_len, scratch.len);
    @memcpy(scratch[0..len], error_text[0..len]);
    return @intCast(len);
}

/// A key: its `KeyboardEvent.code` (`code_len` bytes in the scratch buffer), down or up. Returns 1
/// when the game takes the key (the player's controls, pad 1's), so that the page keeps the browser
/// from acting on it (the arrows do not scroll); the browser keeps its other keys. Escape is the
/// browser's (it leaves the full screen, and the game quits on it natively), but the game's
/// settings screen's while it is open: it saves and leaves.
export fn gp_key(code_len: u32, down: u32, repeat: u32) u32 {
    const key = keys.fromCode(scratch[0..@min(code_len, scratch.len)]);
    if (key == .unknown) return 0;
    if (key == .escape) if (game) |g| if (g.settingsOpen()) {
        backend.keyEvent(key, down != 0, repeat != 0);
        return 1;
    };
    if (key == .escape) return 0;
    backend.keyEvent(key, down != 0, repeat != 0);
    if (game) |g| return @intFromBool(g.usesKey(key));
    for (sorz.input.default_keys) |binding| {
        if (binding.key == key and binding.player == 0) return 1;
    }
    return 0;
}

/// Text that a key typed: `len` UTF-8 bytes in the scratch buffer.
export fn gp_text(len: u32) void {
    backend.textEvent(scratch[0..@min(len, scratch.len)]);
}

export fn gp_motion(dx: i32, dy: i32, x: i32, y: i32) void {
    backend.motionEvent(dx, dy, x, y);
}

/// A button, numbered as `MouseEvent.button` numbers them: 0 left, 1 middle, 2 right.
export fn gp_button(button: u32, down: u32, x: i32, y: i32) void {
    backend.buttonEvent(@fromBackingInt(@as(u8, @intCast(@min(button, 255)))), down != 0, x, y);
}

export fn gp_wheel(dx: i32, dy: i32) void {
    backend.wheelEvent(dx, dy);
}

export fn gp_focus(gained: u32) void {
    backend.focusEvent(gained != 0);
}

/// The page reports whether it has the pointer lock.
export fn gp_capture(captured: u32) void {
    backend.captureEvent(captured != 0);
}

export fn gp_resized(width: u32, height: u32) void {
    backend.resizedEvent(width, height);
}

/// A gamepad appeared at `index` of `navigator.getGamepads()`, its id (the browser's text) the
/// first `id_len` bytes of the scratch buffer, or went away.
export fn gp_pad(index: u32, connected: u32, id_len: u32) void {
    const id = gamepad.controller(index);
    if (connected != 0) backend.controllerAdded(id, scratch[0..@min(id_len, scratch.len)]) else backend.controllerRemoved(id);
}

/// A button of the standard mapping changed. The triggers (6 and 7) are axes, and `value` is
/// their pressure times 32767. Returns 0 for a button the mapping does not have.
export fn gp_pad_button(index: u32, button: u32, down: u32, value: i32) u32 {
    const id = gamepad.controller(index);
    if (gamepad.button(button)) |b| {
        backend.controllerButton(id, b, down != 0);
        return 1;
    }
    if (gamepad.trigger(button)) |a| {
        backend.controllerAxis(id, a, gamepad.triggerValue(value));
        return 1;
    }
    return 0;
}

/// An axis of the standard mapping moved: `value` is its position times 32767. Returns 0 for an
/// axis the mapping does not have.
export fn gp_pad_axis(index: u32, axis: u32, value: i32) u32 {
    const a = gamepad.axis(axis) orelse return 0;
    backend.controllerAxis(gamepad.controller(index), a, gamepad.stickValue(value));
    return 1;
}

/// The settings in `gp_inspect`: the players a page has, and the record's values that the page
/// applies or that the checks change.
const SettingsState = struct {
    players: u8,
    /// The record's hash, as the agent host prints it.
    hash: []const u8,
    volume: u8,
    mute: bool,
    scale: u8,
    fullscreen: bool,
    settings_key: []const u8,
    /// Pad 1's start key.
    start_key: []const u8,
};

/// Network play's state in `gp_inspect`.
const NetState = struct {
    role: []const u8,
    phase: []const u8,
    tick: u32,
    delay: u8,
    /// The sessions started so far.
    sessions: u32,
    /// The connection to the peer is up (a session in play without it holds).
    connected: bool,
    /// The states differed, and the peers named the first differing field (in the console).
    difference: bool,
    /// The other player is on the settings screen (both games hold).
    peer_in_settings: bool,
};

/// The state of the game as one JSON object in the scratch buffer, for the page's checks and for
/// debugging. The hashes are hexadecimal text, since a JavaScript number holds 53 bits. Returns
/// its length, or 0 when it does not fit.
export fn gp_inspect() u32 {
    const g = game orelse return 0;
    var p = backend.asPlatform();
    const audio = p.audioStatus();
    var frame_hash: [16]u8 = undefined;
    var state_hash: [16]u8 = undefined;
    var settings_hash: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&frame_hash, "{x:0>16}", .{g.lastFrameHash()}) catch unreachable;
    _ = std.fmt.bufPrint(&state_hash, "{x:0>16}", .{g.stateHash()}) catch unreachable;
    _ = std.fmt.bufPrint(&settings_hash, "{x:0>16}", .{record.hash(&g.settings)}) catch unreachable;
    const s = &g.settings;
    var w: std.Io.Writer = .fixed(&scratch);
    // The game menu's lines, when it shows: their names, comma-separated.
    var lines_buf: [64]u8 = undefined;
    var lines: std.Io.Writer = .fixed(&lines_buf);
    var menu_at: []const u8 = "";
    switch (g.state.scenes.base) {
        .menu => |*m| {
            for (m.lines[0..m.line_count], 0..) |l, i| lines.print("{s}{s}", .{ if (i == 0) "" else ",", @tagName(l) }) catch {};
            menu_at = @tagName(m.choice);
        },
        else => {},
    }
    std.json.Stringify.value(.{
        .phase = if (g.finished) "finished" else "playing",
        .update_count = g.update_count,
        .ticks = g.state.tick,
        .variant = @tagName(g.state.start.variant),
        .scene = @tagName(std.meta.activeTag(g.state.scenes.base)),
        .menu = lines.buffered(),
        // The line the menu's arrow is on.
        .menu_at = menu_at,
        .settings_open = g.settingsOpen(),
        // Network play's screen of this machine open over the game, if any.
        .modal = if (g.overlays.find(.net_options) != null) "net_options" else if (g.overlays.find(.name_entry) != null) "name_entry" else "",
        // Network play's message over the picture, if any.
        .message = if (g.overlays.find(.network)) |o| o.network.what.text() else "",
        // Network play's notice over the picture, if any (it goes after a while).
        .notice_text = if (g.overlays.find(.net_notice)) |o| o.net_notice.what.text() else "",
        .players = @tagName(g.state.setup.players),
        .frames_presented = g.frames_presented,
        .frame_hash = &frame_hash,
        .state_hash = &state_hash,
        .events_consumed = g.events_consumed,
        .pacing = @tagName(g.pacing),
        .sound = g.sound != null,
        .saves_written = g.saves_written,
        .loads_done = g.loads_done,
        .notice = @tagName(g.notice),
        .audio_running = audio.running,
        .audio_queued = audio.queued_frames,
        .audio_played = audio.played_frames,
        .settings = SettingsState{
            .players = if (g.controls.one_player) 1 else 2,
            .hash = &settings_hash,
            .volume = s.sound.volume,
            .mute = s.sound.mute,
            .scale = s.window.scale,
            .fullscreen = s.window.fullscreen,
            .settings_key = @tagName(s.settings_key),
            .start_key = @tagName(s.key(.{ .player = .{ .player = 0, .button = .start } })),
        },
        .net = if (g.netplay) |np| NetState{
            .role = @tagName(np.role),
            .phase = @tagName(np.phase()),
            .tick = np.tick(),
            .delay = np.delay(),
            .sessions = np.sessions,
            .connected = np.connected(),
            .difference = np.difference != null,
            .peer_in_settings = np.peerInSettings(),
        } else null,
    }, .{}, &w) catch return 0;
    return @intCast(w.end);
}

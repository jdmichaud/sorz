//! The command-line options that the native hosts take and open for the game: the positional game
//! path and `--saves DIR` (DESIGN.md 5.2, D8), the variant (`--original`, DESIGN.md 10.7), network
//! play's `--netplay [ADDRESS:]PORT` or `--join ws://ADDRESS:PORT`, with `--delay N`, and server
//! mode's `--server [ADDRESS:]PORT` (DESIGN.md 9). Both serve the browser build built into the executable, never files beside it
//! (DESIGN.md 1), and the game's files from the game path (`served.zig`): the page never asks the
//! player for them (DESIGN.md 5.3).
//!
//! The game path is a game directory, the content tree on disk (a previous extraction, or a mod of
//! one), or the user's ROM, whose content is extracted into memory (`Providers.openRom`, the one
//! place where the extraction plugs in). Both are `AssetSource`s, so the game does not know which
//! it has. `--saves` defaults to the per-user application data directory, which is created on
//! first use.
const std = @import("std");
const builtin = @import("builtin");
const sorz = @import("sorz");
const extract = @import("extract");
const platform = sorz.platform;
const DirectoryAssetSource = @import("directory.zig").DirectoryAssetSource;
const DirectoryStorage = @import("storage.zig").DirectoryStorage;
const net = @import("net.zig");
const served = @import("served.zig");
const WebSocketTransport = net.WebSocketTransport;

pub const usage =
    \\  DIR|ROM              the game directory (its content tree), or the user's ROM, whose
    \\                       content is extracted in memory
    \\  --saves DIR          where saves are kept (default: the per-user application data
    \\                       directory)
    \\  --original           the cartridge exactly: its game menu, its options and its pause on
    \\                       START, without the port's additions (ADVANCED SETTINGS in
    \\                       OPTIONS, START opening the settings during play); the settings
    \\                       key (F1) opens the settings. Not with network play, which is
    \\                       the network variant's
    \\  --netplay [ADDRESS:]PORT  play with a second player over the network, as the host
    \\                       (player 1): listen at PORT (all interfaces without ADDRESS), where
    \\                       the browser build's page is served too, with the game's files;
    \\                       the guest's 2 PLAYERS joins your game, at the character select or
    \\                       in the round
    \\  --join ws://ADDRESS:PORT  play with the host at that address, as player 2: your 2 PLAYERS
    \\                       joins its game
    \\  --delay N            the host's input delay in display ticks, 2 to 6 (default: from the
    \\                       round trip)
    \\  --server [ADDRESS:]PORT  server mode, with no game: serve the page and the game's files
    \\                       of DIR|ROM at PORT, and relay network play between the browsers
    \\
;

pub const TakeError = error{ MissingValue, DuplicateAssets, BadValue };

pub const Options = struct {
    assets: ?[]const u8 = null,
    saves: ?[]const u8 = null,
    /// Network play (DESIGN.md 9): the address to host at, or the URL to join; server mode's
    /// address.
    netplay: ?[]const u8 = null,
    join: ?[]const u8 = null,
    server: ?[]const u8 = null,
    delay: ?u8 = null,
    /// `--original`: the cartridge's variant rather than the default (variant.zig).
    original: bool = false,

    /// Consumes `--saves`, the network's options and the single positional game path. Returns
    /// false for any other argument. After `--`, a game path can start with a dash.
    pub fn take(self: *Options, arg: []const u8, args: anytype) TakeError!bool {
        if (std.mem.eql(u8, arg, "--original")) {
            self.original = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "--saves")) {
            const value = args.next() orelse return error.MissingValue;
            if (value.len == 0) return error.MissingValue;
            self.saves = value;
            return true;
        }
        // One of `--netplay`, `--join` and `--server`, once.
        const hosting = std.mem.eql(u8, arg, "--netplay");
        if (hosting or std.mem.eql(u8, arg, "--server")) {
            const value = args.next() orelse return error.MissingValue;
            _ = platform.parseListenAddress(value) catch return error.BadValue;
            if (self.netplay != null or self.join != null or self.server != null) return error.BadValue;
            if (hosting) self.netplay = value else self.server = value;
            return true;
        }
        if (std.mem.eql(u8, arg, "--join")) {
            const value = args.next() orelse return error.MissingValue;
            _ = platform.WsUrl.parse(value) catch return error.BadValue;
            if (self.netplay != null or self.join != null or self.server != null) return error.BadValue;
            self.join = value;
            return true;
        }
        if (std.mem.eql(u8, arg, "--delay")) {
            const value = args.next() orelse return error.MissingValue;
            const d = std.fmt.parseInt(u8, value, 10) catch return error.BadValue;
            if (d < sorz.net.protocol.min_delay or d > sorz.net.protocol.max_delay) return error.BadValue;
            self.delay = d;
            return true;
        }
        if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |path| try self.setAsset(path);
            return true;
        }
        if (arg.len == 0 or arg[0] != '-') {
            try self.setAsset(arg);
            return true;
        }
        return false;
    }

    fn setAsset(self: *Options, path: []const u8) error{ MissingValue, DuplicateAssets }!void {
        if (path.len == 0) return error.MissingValue;
        if (self.assets != null) return error.DuplicateAssets;
        self.assets = path;
    }

    pub const Network = enum { none, netplay, server };

    /// What the options ask of the network: network play (`--netplay` or `--join`), server mode
    /// (`--server`, which runs no game and serves the game's data to its pages: the game path is
    /// required, and it keeps no saves), or nothing. `--delay` needs `--netplay`. Network play is
    /// the network variant's (each machine its own menus, one player a machine): `--original`,
    /// the cartridge's game on one machine, does not go with it.
    pub fn network(self: Options) TakeError!Network {
        if (self.delay != null and self.netplay == null) return error.BadValue;
        if (self.original and (self.netplay != null or self.join != null)) return error.BadValue;
        if (self.server != null) {
            if (self.saves != null) return error.BadValue;
            if (self.assets == null) return error.MissingValue;
            return .server;
        }
        return if (self.netplay != null or self.join != null) .netplay else .none;
    }

    /// The variant the game plays: the cartridge's with `--original`, network play's with
    /// `--netplay` or `--join`, else the default, extended.
    pub fn variant(self: Options) sorz.variant.Variant {
        return .of(.{ .original = self.original, .network = self.netplay != null or self.join != null });
    }

    /// The session's options for the game, given the data's identity.
    pub fn netplayOptions(self: Options, data: sorz.net.protocol.DataId) sorz.net.netplay.Options {
        return .{
            .role = if (self.netplay != null) .host else .guest,
            .address = self.netplay orelse self.join.?,
            .build = sorz.net.protocol.buildId(sorz.version.build),
            .data = data,
            .delay = self.delay,
        };
    }
};

/// The native side of network play for a host: the WebSocket transport, which serves the browser
/// build, `/netplay.json` (the page's cue that a native game hosts here) and the game's files on
/// the host's port. It outlives the backend that holds its transport.
pub const Netplay = struct {
    transport: WebSocketTransport,
    manifest: []u8,
    /// The game's files the guest's page loads: the host's own (DESIGN.md 9).
    assets: ?served.Assets,
    allocator: std.mem.Allocator,

    /// Initialises in place (the transport holds the address of `assets`). `page` is the browser
    /// build built into the executable; `source`, the game's data, whose files are read here.
    /// Without data, the host serves no files and its page says so.
    pub fn init(self: *Netplay, allocator: std.mem.Allocator, io: std.Io, page: net.Page, source: ?platform.AssetSource) served.Assets.ReadError!void {
        const manifest = try std.fmt.allocPrint(allocator, "{{\"protocol\":{d},\"mode\":\"native\",\"websocket\":\"/\",\"build\":\"{s}\"}}\n", .{ sorz.net.protocol.version, sorz.version.build });
        errdefer allocator.free(manifest);
        self.* = .{
            .transport = undefined,
            .manifest = manifest,
            .assets = if (source) |s| try served.Assets.read(allocator, s) else null,
            .allocator = allocator,
        };
        self.transport = WebSocketTransport.init(allocator, io, .{ .page = page, .manifest = manifest, .assets = if (self.assets) |*a| a else null });
    }

    pub fn deinit(self: *Netplay) void {
        self.transport.deinit();
        if (self.assets) |*a| a.deinit();
        self.allocator.free(self.manifest);
        self.* = undefined;
    }
};

/// The kind of asset source, for the host's start-up line and the agent's diagnostics.
pub const AssetKind = enum { none, rom, directory };

pub const OpenError = error{
    NotFound,
    NotADirectory,
    AccessDenied,
    NoApplicationDirectory,
    /// The game path is a file, but not the ROM that sorz follows (its size or digest differ).
    WrongRom,
    /// The ROM is the one, but its content could not be extracted.
    BadRom,
    Io,
    Canceled,
    OutOfMemory,
};

/// What a host says when the providers do not open.
pub fn openErrorText(err: OpenError) []const u8 {
    return switch (err) {
        error.NotFound => "it is not there",
        error.NotADirectory => "it is not a directory",
        error.AccessDenied => "access is denied",
        error.NoApplicationDirectory => "there is no per-user application data directory: give --saves DIR",
        error.WrongRom => "it is a file, but not the ROM sorz follows (Streets of Rage, the cartridge's version of 1991: its size or SHA-256 differs)",
        error.BadRom => "its content could not be extracted",
        error.Io => "it could not be read",
        error.Canceled => "it was canceled",
        error.OutOfMemory => "there is not enough memory",
    };
}

/// The providers that a host owns while the game runs.
pub const Providers = struct {
    allocator: std.mem.Allocator = undefined,
    kind: AssetKind = .none,
    /// The save directory in use (owned).
    saves_path: []u8 = &.{},
    assets_directory: ?DirectoryAssetSource = null,
    /// The content extracted from a ROM, in memory: the tree's files, and the source over them.
    rom_tree: ?extract.Tree = null,
    assets_memory: ?sorz.memory.MemoryAssetSource = null,
    saves: ?DirectoryStorage = null,

    pub const empty: Providers = .{};

    /// Opens the save directory, and creates it if it does not exist. If the options give a game
    /// path, also opens the asset source at that path.
    pub fn open(
        self: *Providers,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        options: Options,
    ) OpenError!void {
        self.allocator = allocator;
        errdefer self.deinit();
        self.saves_path = if (options.saves) |path|
            try allocator.dupe(u8, path)
        else
            try defaultSaveDirectory(allocator, environ);
        self.saves = try mapOpen(DirectoryStorage.open(allocator, io, self.saves_path, true));
        const path = options.assets orelse return;
        try self.openPath(io, path);
    }

    /// Opens only the asset source at `path`, and no save directory: a server's, which runs no
    /// game and serves the data to its pages.
    pub fn openAssets(self: *Providers, allocator: std.mem.Allocator, io: std.Io, path: []const u8) OpenError!void {
        self.allocator = allocator;
        errdefer self.deinit();
        try self.openPath(io, path);
    }

    /// The asset source at `path`: a directory as it is, a ROM through its content in memory.
    fn openPath(self: *Providers, io: std.Io, path: []const u8) OpenError!void {
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.Canceled => error.Canceled,
            else => error.Io,
        };
        if (st.kind == .directory) {
            self.assets_directory = try mapOpen(DirectoryAssetSource.open(self.allocator, io, path));
            self.kind = .directory;
            return;
        }
        try self.openRom(io, path);
    }

    /// The ROM at `path`, its content extracted into memory: the one place where the extraction
    /// plugs in. The file is checked to be the ROM the game follows (its size and digest) before
    /// anything of it is read; the tree's files stay in `rom_tree`, which `assets_memory` lists.
    fn openRom(self: *Providers, io: std.Io, path: []const u8) OpenError!void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(extract.rom.size + 1)) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.StreamTooLong => error.WrongRom,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.Io,
        };
        defer self.allocator.free(bytes);
        self.rom_tree = extract.extract(self.allocator, bytes) catch |err| return switch (err) {
            error.WrongRom => error.WrongRom,
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadRom,
        };
        self.assets_memory = sorz.memory.MemoryAssetSource.init(self.allocator);
        self.rom_tree.?.addTo(&self.assets_memory.?) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadRom,
        };
        self.kind = .rom;
    }

    fn mapOpen(result: anytype) OpenError!@typeInfo(@TypeOf(result)).error_union.payload {
        return result catch |err| switch (err) {
            error.NotFound => error.NotFound,
            error.NotADirectory => error.NotADirectory,
            error.AccessDenied => error.AccessDenied,
            error.Canceled => error.Canceled,
            error.Io => error.Io,
        };
    }

    pub fn deinit(self: *Providers) void {
        if (self.assets_directory) |*d| d.deinit();
        if (self.assets_memory) |*m| m.deinit();
        if (self.rom_tree) |*t| t.deinit();
        if (self.saves) |*s| s.deinit();
        self.allocator.free(self.saves_path);
        self.* = .empty;
    }

    /// The bound asset source. Null when the host has no game path.
    pub fn assetSource(self: *Providers) ?platform.AssetSource {
        return switch (self.kind) {
            .none => null,
            .rom => self.assets_memory.?.assetSource(),
            .directory => self.assets_directory.?.assetSource(),
        };
    }

    pub fn storage(self: *Providers) platform.Storage {
        return self.saves.?.storage();
    }

    /// The game data's identity, which network play's handshake compares (DESIGN.md 9): the
    /// content tree's digest (every file read once), as a page computes it from the files it was
    /// served; zeros without data.
    pub fn dataIdentity(self: *Providers) platform.AssetError!sorz.net.protocol.DataId {
        const source = self.assetSource() orelse return @splat(0);
        return sorz.net.identity.ofTree(source, sorz.net.identity.max_file_bytes);
    }
};

/// The per-user application data directory for the sorz saves:
/// `$XDG_DATA_HOME/sorz/saves`, else `$HOME/.local/share/sorz/saves`, and
/// `%APPDATA%\sorz\saves` on Windows. The caller owns the result.
pub fn defaultSaveDirectory(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) OpenError![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = environ.get("APPDATA") orelse return error.NoApplicationDirectory;
        if (appdata.len == 0) return error.NoApplicationDirectory;
        return std.fmt.allocPrint(allocator, "{s}\\sorz\\saves", .{appdata}) catch return error.OutOfMemory;
    }
    if (environ.get("XDG_DATA_HOME")) |data_home| {
        if (data_home.len != 0) {
            return std.fmt.allocPrint(allocator, "{s}/sorz/saves", .{data_home}) catch return error.OutOfMemory;
        }
    }
    const home = environ.get("HOME") orelse return error.NoApplicationDirectory;
    if (home.len == 0) return error.NoApplicationDirectory;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/sorz/saves", .{home}) catch return error.OutOfMemory;
}

const contract = @import("contract.zig");

fn testEnviron(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "the save directory follows the platform's application data convention" {
    const allocator = std.testing.allocator;
    {
        var env = try testEnviron(allocator, &.{.{ "XDG_DATA_HOME", "/data" }});
        defer env.deinit();
        if (builtin.os.tag == .windows) {
            // Windows reads %APPDATA% only.
            try std.testing.expectError(error.NoApplicationDirectory, defaultSaveDirectory(allocator, &env));
        } else {
            const path = try defaultSaveDirectory(allocator, &env);
            defer allocator.free(path);
            try std.testing.expectEqualStrings("/data/sorz/saves", path);
        }
    }
    {
        var env = try testEnviron(allocator, &.{ .{ "HOME", "/home/player" }, .{ "APPDATA", "C:\\Users\\player\\AppData\\Roaming" } });
        defer env.deinit();
        const path = try defaultSaveDirectory(allocator, &env);
        defer allocator.free(path);
        const want = if (builtin.os.tag == .windows)
            "C:\\Users\\player\\AppData\\Roaming\\sorz\\saves"
        else
            "/home/player/.local/share/sorz/saves";
        try std.testing.expectEqualStrings(want, path);
    }
    {
        var env = try testEnviron(allocator, &.{});
        defer env.deinit();
        try std.testing.expectError(error.NoApplicationDirectory, defaultSaveDirectory(allocator, &env));
    }
}

const TestArgs = struct {
    items: []const []const u8,
    i: usize = 0,
    pub fn next(self: *@This()) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
    fn all(items: []const []const u8) TakeError!Options {
        var o: Options = .{};
        var a: @This() = .{ .items = items };
        while (a.next()) |arg| if (!try o.take(arg, &a)) return error.BadValue;
        _ = try o.network();
        return o;
    }
};

test "the options take the game path and --saves" {
    var options: Options = .{};
    var args: TestArgs = .{ .items = &.{ "game", "--saves", "s" } };
    while (args.next()) |arg| try std.testing.expect(try options.take(arg, &args));
    try std.testing.expectEqualStrings("game", options.assets.?);
    try std.testing.expectEqualStrings("s", options.saves.?);
    var missing: TestArgs = .{ .items = &.{"--saves"} };
    try std.testing.expectError(error.MissingValue, options.take(missing.next().?, &missing));
    try std.testing.expectError(error.DuplicateAssets, TestArgs.all(&.{ "one", "two" }));
}

test "the variant: extended by default, network play's with --netplay or --join, --original's" {
    try std.testing.expectEqual(sorz.variant.Variant.extended, (try TestArgs.all(&.{"game"})).variant());
    try std.testing.expectEqual(sorz.variant.Variant.original, (try TestArgs.all(&.{ "game", "--original" })).variant());
    try std.testing.expectEqual(sorz.variant.Variant.network, (try TestArgs.all(&.{ "game", "--netplay", "7000" })).variant());
    try std.testing.expectEqual(sorz.variant.Variant.network, (try TestArgs.all(&.{ "--join", "ws://h:1" })).variant());
    // The cartridge's game is one machine's: not with network play.
    try std.testing.expectError(error.BadValue, TestArgs.all(&.{ "game", "--original", "--netplay", "7000" }));
    try std.testing.expectError(error.BadValue, TestArgs.all(&.{ "game", "--original", "--join", "ws://h:1" }));
}

test "the options of network play" {
    const host = try TestArgs.all(&.{ "game", "--netplay", "7000", "--delay", "3" });
    try std.testing.expectEqual(Options.Network.netplay, try host.network());
    try std.testing.expectEqual(@as(?u8, 3), host.delay);
    const hn = host.netplayOptions(@splat(1));
    try std.testing.expectEqual(sorz.net.netplay.Role.host, hn.role);
    try std.testing.expectEqualStrings("7000", hn.address);
    try std.testing.expectEqual(@as(?u8, 3), hn.delay);
    const guest = try TestArgs.all(&.{ "--join", "ws://192.168.1.2:7000", "tree" });
    const gn = guest.netplayOptions(@splat(1));
    try std.testing.expectEqual(sorz.net.netplay.Role.guest, gn.role);
    try std.testing.expectEqualStrings("ws://192.168.1.2:7000", gn.address);
    try std.testing.expectEqual(Options.Network.none, try (try TestArgs.all(&.{"game"})).network());
    // Server mode serves the game's data to its pages: it needs it, and keeps no saves.
    const server = try TestArgs.all(&.{ "game", "--server", "0.0.0.0:7000" });
    try std.testing.expectEqual(Options.Network.server, try server.network());
    try std.testing.expectEqualStrings("0.0.0.0:7000", server.server.?);
    try std.testing.expectEqualStrings("game", server.assets.?);
    for ([_][]const []const u8{
        &.{ "--netplay", "x:y" },
        &.{ "--join", "http://h:1" },
        &.{ "--netplay", "7000", "--delay", "7" },
        &.{ "--netplay", "7000", "--join", "ws://h:1" },
        &.{ "--netplay", "7000", "--netplay", "7001" },
        &.{ "--join", "ws://h:1", "--delay", "3" },
        &.{ "tree", "--server", "nowhere:x" },
        &.{ "tree", "--server", "7000", "--netplay", "7001" },
        &.{ "tree", "--join", "ws://h:1", "--server", "7000" },
        &.{ "tree", "--server", "7000", "--delay", "3" },
        &.{ "game", "--server", "7000", "--saves", "s" },
        // No option points a server at files beside the executable (DESIGN.md 1).
        &.{ "--netplay", "7000", "--web", "w" },
    }) |items| try std.testing.expectError(error.BadValue, TestArgs.all(items));
    try std.testing.expectError(error.MissingValue, TestArgs.all(&.{"--join"}));
    try std.testing.expectError(error.MissingValue, TestArgs.all(&.{ "game", "--server" }));
    try std.testing.expectError(error.MissingValue, TestArgs.all(&.{ "--server", "7000" }));
}

test "the options open a game directory, or none; a file that is not the ROM is refused" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try tmp.dir.createDirPath(io, "game");
    var game_dir = try tmp.dir.openDir(io, "game", .{ .iterate = true });
    defer game_dir.close(io);
    try @import("directory.zig").writeFixture(io, game_dir);

    var env = try testEnviron(allocator, &.{.{ "XDG_DATA_HOME", "/unused" }});
    defer env.deinit();
    var paths: [2][]u8 = undefined;
    inline for (.{ "game", "saves" }, 0..) |sub, i| {
        paths[i] = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, sub });
    }
    defer for (paths) |p| allocator.free(p);

    // A game directory: the asset source passes the contract, and the storage keeps a record.
    {
        var providers: Providers = .empty;
        try providers.open(allocator, io, &env, .{ .assets = paths[0], .saves = paths[1] });
        defer providers.deinit();
        try std.testing.expectEqual(AssetKind.directory, providers.kind);
        try contract.assetContract(providers.assetSource().?);
        const s = providers.storage();
        try s.save("CLI.PT", "position");
        var loaded = try s.load("CLI.PT");
        defer loaded.deinit();
        try std.testing.expectEqualStrings("position", loaded.bytes);
        try s.deleteSave("CLI.PT");
    }

    // Without a game path, only the save directory opens, and `open` creates it.
    {
        var providers: Providers = .empty;
        try providers.open(allocator, io, &env, .{ .saves = paths[1] });
        defer providers.deinit();
        try std.testing.expectEqual(AssetKind.none, providers.kind);
        try std.testing.expect(providers.assetSource() == null);
        var names = try providers.storage().listSaves();
        names.deinit();
        try std.testing.expectEqualStrings(paths[1], providers.saves_path);
        try std.testing.expectEqualSlices(u8, &@as(sorz.net.protocol.DataId, @splat(0)), &(try providers.dataIdentity()));
    }

    // A server's: the asset source alone, no save directory; its identity is the tree's.
    {
        var providers: Providers = .empty;
        try providers.openAssets(allocator, io, paths[0]);
        defer providers.deinit();
        try std.testing.expectEqual(AssetKind.directory, providers.kind);
        try std.testing.expect(providers.saves == null);
        const id = try providers.dataIdentity();
        try std.testing.expectEqualSlices(u8, &(try sorz.net.identity.ofTree(providers.assetSource().?, 1 << 20)), &id);
    }

    // A path that is missing; a file is a ROM, refused when it is not the one sorz follows, of
    // another size or of the same size and another digest (the tests have no ROM of the game).
    {
        var providers: Providers = .empty;
        const missing = try std.fmt.allocPrint(allocator, "{s}/absent", .{base});
        defer allocator.free(missing);
        try std.testing.expectError(error.NotFound, providers.open(allocator, io, &env, .{ .assets = missing, .saves = paths[1] }));
        const a_file = try std.fmt.allocPrint(allocator, "{s}/game/game.cfg", .{base});
        defer allocator.free(a_file);
        try std.testing.expectError(error.WrongRom, providers.open(allocator, io, &env, .{ .assets = a_file, .saves = paths[1] }));
        const zeros = try allocator.alloc(u8, extract.rom.size);
        defer allocator.free(zeros);
        @memset(zeros, 0);
        try tmp.dir.writeFile(io, .{ .sub_path = "zeros.md", .data = zeros });
        const rom_sized = try std.fmt.allocPrint(allocator, "{s}/zeros.md", .{base});
        defer allocator.free(rom_sized);
        try std.testing.expectError(error.WrongRom, providers.openAssets(allocator, io, rom_sized));
        try std.testing.expectEqual(AssetKind.none, providers.kind);
        try std.testing.expect(std.mem.find(u8, openErrorText(error.WrongRom), "not the ROM") != null);
    }
}

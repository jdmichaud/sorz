//! Server mode (DESIGN.md 9): the relay between two browsers. `DATA --server
//! [ADDRESS:]PORT` (`sorz-server`, or a game binary given it) serves the browser build built into
//! the executable, `/netplay.json` (`"mode": "relay"`) and the game's files of DATA (a game
//! directory, or a ROM once its extractor exists: `served.zig`) on one port, as the native host
//! does, and pairs the pages'
//! WebSockets: the first page to connect hosts, the next is its guest, and the session's binary
//! messages go from one to the other as they are, never parsed. It runs no game: the pages load
//! the files it serves, and a page whose player chooses 1 PLAYER plays alone on them without
//! joining the relay (only 2 PLAYERS joins it).
//!
//! Text messages tell a page what happens:
//! - `host` or `guest`: its role, as soon as its connection opens;
//! - `peer`: to the host, its guest has come; the guest's messages follow;
//! - `left`: to the host, its guest has gone (the next page to connect is its new guest); to the
//!   guest, its host has gone, and the relay then ends the guest's connection: the next page to
//!   connect hosts;
//! - `busy`: to a third page while two play, whose connection then ends. A third page is refused,
//!   not kept waiting: it would join a game that starts again from power-on when it does, which
//!   a reload once a place is free does as well, and the relay keeps no idle connections.
//!
//! The host's page answers each `left` with a text message `left`. What the host sent before
//! that answer was for the guest that left, and the relay drops it: without the answer, a
//! message on its way to a guest that has just left (a welcome, pads) would reach the next guest
//! when that one joins at once. Any other text from a page is ignored.
//!
//! Limits, as the transport's contract has them: a message is at most `platform.max_message_len`
//! (a longer one ends its page's connection, close code 1009); a page that sends a malformed
//! frame is ended (1002); each connection's outgoing queue is bounded
//! (`net.Options.send_queue_bytes`), and a page that does not take what its partner sends is
//! dropped at once when its queue is full, so that it never holds its partner back. The relay
//! pings every page (`keepalive_ms`) and drops one silent through three pings: a host whose
//! machine went to sleep must not keep the next players waiting.
const std = @import("std");
const sorz = @import("sorz");
const platform = sorz.platform;
const net = @import("net.zig");
const ws = @import("websocket.zig");
const served = @import("served.zig");
const cli = @import("cli.zig");
const Io = std.Io;
const ConnectionId = platform.ConnectionId;

const log = std.log.scoped(.relay);

/// The relay's words to the pages (text messages).
pub const words = struct {
    pub const host = "host";
    pub const guest = "guest";
    pub const peer = "peer";
    pub const left = "left";
    pub const busy = "busy";
};

/// The transport's options for the relay: room for the two players and a few pages being turned
/// away at once, and pings every five seconds (a silent page is dropped after fifteen). The
/// server takes text from the pages whatever the options say.
pub const transport_options: net.Options = .{
    .max_connections = 8,
    .keepalive_ms = 5000,
};

/// The rules, over the transport's events.
pub const Relay = struct {
    transport: *net.WebSocketTransport,
    host: ?ConnectionId = null,
    guest: ?ConnectionId = null,
    /// The `left` that the host's page has not answered yet: until it has, what the host sends is
    /// for a guest that left, and is dropped.
    host_answers_due: u32 = 0,
    log_enabled: bool = true,

    /// Takes the transport's events until the task is canceled.
    pub fn run(self: *Relay) Io.Cancelable!void {
        var events: [64]platform.Event = undefined;
        var text: [64]bool = undefined;
        while (true) {
            try self.transport.wait(.none);
            const n = self.transport.pollText(&events, &text);
            for (events[0..n], text[0..n]) |e, is_text| self.handle(e, is_text);
        }
    }

    /// One event of the transport; `text` tells a text message from a binary one.
    pub fn handle(self: *Relay, e: platform.Event, text: bool) void {
        switch (e.payload) {
            .net_connected => |c| self.joined(c.connection),
            .net_disconnected => |d| self.gone(d.connection, @tagName(d.reason)),
            .net_received => |m| if (text) self.heard(m.connection, m.bytes) else self.pass(m.connection, m.bytes),
            else => {},
        }
    }

    fn joined(self: *Relay, id: ConnectionId) void {
        if (self.host == null) {
            self.host = id;
            self.host_answers_due = 0;
            if (self.log_enabled) log.info("connection {d} hosts", .{@backingInt(id)});
            self.say(id, words.host);
        } else if (self.guest == null) {
            self.guest = id;
            if (self.log_enabled) log.info("connection {d} joins the host as its guest", .{@backingInt(id)});
            self.say(id, words.guest);
            if (self.host) |h| self.say(h, words.peer);
        } else {
            if (self.log_enabled) log.info("connection {d} is turned away: two players are playing", .{@backingInt(id)});
            self.say(id, words.busy);
            self.transport.transport().close(id);
        }
    }

    /// A connection ended (its event, or the relay dropped it): the rules for its role.
    fn gone(self: *Relay, id: ConnectionId, why: []const u8) void {
        if (self.host == id) {
            self.host = null;
            const guest = self.guest orelse {
                if (self.log_enabled) log.info("the host left ({s})", .{why});
                return;
            };
            self.guest = null;
            if (self.log_enabled) log.info("the host left ({s}); its guest's connection ends", .{why});
            self.say(guest, words.left);
            self.transport.transport().close(guest);
        } else if (self.guest == id) {
            self.guest = null;
            if (self.log_enabled) log.info("the guest left ({s})", .{why});
            if (self.host) |h| {
                self.host_answers_due += 1;
                self.say(h, words.left);
            }
        }
    }

    /// A text message from a page: the host's answer to `left`; any other is ignored.
    fn heard(self: *Relay, from: ConnectionId, text: []const u8) void {
        if (self.host == from and std.mem.eql(u8, text, words.left) and self.host_answers_due > 0) {
            self.host_answers_due -= 1;
        }
    }

    /// A message goes to the sender's partner as it is. A host's message is dropped when it has no
    /// guest, or when it was sent for a guest that left (before the page answered `left`).
    fn pass(self: *Relay, from: ConnectionId, bytes: []const u8) void {
        const to = if (self.host == from)
            (if (self.host_answers_due == 0) self.guest else null)
        else if (self.guest == from)
            self.host
        else
            null;
        const id = to orelse return;
        self.transport.transport().send(id, bytes) catch |err| switch (err) {
            // Its connection is ending: its event follows.
            error.NotConnected => {},
            else => self.drop(id),
        };
    }

    fn say(self: *Relay, id: ConnectionId, word: []const u8) void {
        self.transport.sendText(id, word) catch |err| switch (err) {
            error.NotConnected => {},
            else => self.drop(id),
        };
    }

    /// A page that does not take its messages (its queue is full) is dropped at once, without an
    /// event: the rules for its role apply now.
    fn drop(self: *Relay, id: ConnectionId) void {
        if (self.log_enabled) log.warn("connection {d} does not take its messages: dropped", .{@backingInt(id)});
        self.transport.abort(id);
        self.gone(id, "dropped");
    }
};

/// The server: the relay, its transport, and the page's files and manifest.
pub const Server = struct {
    allocator: std.mem.Allocator,
    transport: net.WebSocketTransport,
    relay: Relay,
    manifest: []u8,

    pub const InitOptions = struct {
        /// The browser build built into the executable; null serves none (the tests').
        page: ?net.Page = null,
        /// The game's files the pages load, which outlive the server; null serves none.
        assets: ?*const served.Assets = null,
        transport: net.Options = transport_options,
        log: bool = true,
    };

    /// Initialises in place: the relay holds the transport's address.
    pub fn init(self: *Server, allocator: std.mem.Allocator, io: Io, options: InitOptions) error{OutOfMemory}!void {
        const manifest = try std.fmt.allocPrint(allocator, "{{\"protocol\":{d},\"mode\":\"relay\",\"websocket\":\"/\",\"build\":\"{s}\"}}\n", .{ sorz.net.protocol.version, sorz.version.build });
        var transport_opts = options.transport;
        transport_opts.page = options.page;
        transport_opts.assets = options.assets;
        transport_opts.manifest = manifest;
        transport_opts.accept_text = true;
        self.* = .{
            .allocator = allocator,
            .transport = .init(allocator, io, transport_opts),
            .relay = undefined,
            .manifest = manifest,
        };
        self.relay = .{ .transport = &self.transport, .log_enabled = options.log };
    }

    /// Closes every connection (going away) and frees everything. The task that runs `run` is
    /// canceled first.
    pub fn deinit(self: *Server) void {
        self.transport.deinit();
        self.allocator.free(self.manifest);
        self.* = undefined;
    }

    pub fn listen(self: *Server, address: []const u8) platform.NetError!void {
        return self.transport.transport().listen(address);
    }

    /// The port it listens at.
    pub fn port(self: *const Server) u16 {
        return self.transport.port;
    }

    pub fn run(self: *Server) Io.Cancelable!void {
        return self.relay.run();
    }
};

/// Server mode as a program runs it: reads the game's files from `data` (a game directory, or a
/// ROM through its content extracted in memory) to serve them, listens at
/// `address`, says so on `err`
/// under the program's `name`, and relays until it is stopped. Returns the exit status: 2 when the
/// data cannot be read, 1 when it cannot listen.
pub fn serve(gpa: std.mem.Allocator, io: Io, data: []const u8, address: []const u8, page: net.Page) !u8 {
    var kind: cli.AssetKind = .none;
    var assets = read: {
        var providers: cli.Providers = .empty;
        defer providers.deinit();
        providers.openAssets(gpa, io, data) catch |e| {
            std.log.err("cannot open the game data {s}: {s}", .{ data, cli.openErrorText(e) });
            return 2;
        };
        kind = providers.kind;
        break :read served.Assets.read(gpa, providers.assetSource().?) catch |e| {
            std.log.err("cannot read the game data {s}: {s}", .{ data, @errorName(e) });
            return 2;
        };
    };
    defer assets.deinit();
    var server: Server = undefined;
    try server.init(gpa, io, .{ .page = page, .assets = &assets });
    defer server.deinit();
    server.listen(address) catch |e| {
        std.log.err("cannot listen at {s}: {s}", .{ address, @errorName(e) });
        return 1;
    };
    std.log.info("relaying network play at {s} (port {d}), serving its page and the game's files ({s}, {d} files, {d} bytes); build {s}, protocol {d}", .{
        address, server.port(), @tagName(kind), assets.files.len, assets.totalBytes(), sorz.version.build, sorz.net.protocol.version,
    });
    server.run() catch {};
    return 0;
}

pub const usage =
    \\usage: sorz-server DIR|ROM --server [ADDRESS:]PORT
    \\  DIR|ROM              the game's data, whose files the pages load: the game directory, or
    \\                       the user's ROM, its content extracted in memory; no game runs here
    \\  --server [ADDRESS:]PORT  serve the browser build's page and the game's files at PORT
    \\                       (all interfaces without ADDRESS), where a page plays alone (1
    \\                       PLAYER) or joins the relay of network play (2 PLAYERS): the first
    \\                       page to join hosts (player 1), the next is player 2, and a third is
    \\                       turned away while they play
    \\  --help, -h           show this help
    \\
;

pub const Options = struct {
    help: bool = false,
    address: ?[]const u8 = null,
    /// The game's data, which the pages load.
    data: ?[]const u8 = null,

    /// Parses the command line from an iterator shaped like `std.process.Args.iterate()`, whose
    /// first item is the program name.
    pub fn parse(iter: anytype) error{BadArguments}!Options {
        var args = iter;
        var o: Options = .{};
        _ = args.skip();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                o.help = true;
            } else if (std.mem.eql(u8, arg, "--server")) {
                const value = args.next() orelse return error.BadArguments;
                _ = platform.parseListenAddress(value) catch return error.BadArguments;
                if (o.address != null) return error.BadArguments;
                o.address = value;
            } else if (arg.len != 0 and arg[0] != '-') {
                if (o.data != null) return error.BadArguments;
                o.data = arg;
            } else return error.BadArguments;
        }
        if (!o.help and (o.address == null or o.data == null)) return error.BadArguments;
        return o;
    }
};

// --- tests ---------------------------------------------------------------------------------------

const testing = std.testing;
const Raw = net.Raw;

/// A server on 127.0.0.1 with its relay running in a task of its own.
const Harness = struct {
    server: Server,
    group: Io.Group = .init,

    fn start(h: *Harness, options: net.Options) !void {
        try h.server.init(testing.allocator, testing.io, .{ .transport = options, .log = false });
        errdefer h.server.deinit();
        // A test environment without a loopback socket fails here, with the error named: no
        // test is skipped (docs/testing.md).
        try h.server.listen("127.0.0.1:0");
        h.group = .init;
        try h.group.concurrent(testing.io, Server.run, .{&h.server});
    }

    fn stop(h: *Harness) void {
        h.group.cancel(testing.io);
        h.server.deinit();
    }

    /// A page's connection, open.
    fn page(h: *Harness) !*Raw {
        const r = try Raw.open(h.server.port());
        errdefer r.close();
        try r.handshake();
        return r;
    }
};

fn expectText(r: *Raw, word: []const u8) !void {
    const f = try r.next();
    try testing.expectEqual(ws.Opcode.text, f.opcode);
    try testing.expectEqualStrings(word, f.payload);
}

fn expectBinary(r: *Raw, bytes: []const u8) !void {
    const f = try r.next();
    try testing.expectEqual(ws.Opcode.binary, f.opcode);
    try testing.expectEqualSlices(u8, bytes, f.payload);
}

/// A page leaves as a browser does: a close frame, answered.
fn leave(r: *Raw) !void {
    try r.message(.close, &ws.closePayload(ws.CloseCode.going_away));
    try testing.expectEqual(ws.CloseCode.going_away, try r.closeCode());
    r.close();
}

test "the relay pairs two pages: roles, their messages both ways, a third page, the guest and the host leaving" {
    var h: Harness = undefined;
    try h.start(.{});
    defer h.stop();

    // The page's cue: a relay here.
    {
        const raw = try Raw.open(h.server.port());
        defer raw.close();
        try raw.write("GET /netplay.json HTTP/1.1\r\nHost: x\r\n\r\n");
        const head = try raw.head();
        try testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200"));
        const len = try std.fmt.parseInt(usize, ws.headerValue(head, "Content-Length").?, 10);
        const body = try raw.reader.interface.take(len);
        try testing.expect(std.mem.indexOf(u8, body, "\"mode\":\"relay\"") != null);
    }

    // The first page hosts; the second is its guest, which the host hears of.
    const a = try h.page();
    try expectText(a, words.host);
    const b = try h.page();
    try expectText(b, words.guest);
    try expectText(a, words.peer);

    // Their messages both ways, whole and as they are: a large one, an empty one, one in
    // fragments.
    try b.message(.binary, "hello");
    try expectBinary(a, "hello");
    const big = try testing.allocator.alloc(u8, platform.max_message_len);
    defer testing.allocator.free(big);
    for (big, 0..) |*x, i| x.* = @truncate(i * 13);
    try a.message(.binary, big);
    try expectBinary(b, big);
    try a.message(.binary, "");
    try expectBinary(b, "");
    try a.frame(.binary, false, 2, "ab");
    try a.frame(.continuation, true, 1, "c");
    try expectBinary(b, "abc");

    // A third page is turned away, and the two play on.
    {
        const c = try h.page();
        defer c.close();
        try expectText(c, words.busy);
        try testing.expectEqual(ws.CloseCode.normal, try c.closeCode());
    }
    try b.message(.binary, "still");
    try expectBinary(a, "still");

    // The guest leaves: the host hears it. What the host sends until it answers `left` was for
    // that guest, and goes nowhere, even once the next page has joined as its new guest.
    try leave(b);
    try expectText(a, words.left);
    try a.message(.binary, "nobody");
    const d = try h.page();
    try expectText(d, words.guest);
    try expectText(a, words.peer);
    try a.message(.binary, "stale");
    try d.message(.binary, "hello again");
    try expectBinary(a, "hello again");
    try a.message(.text, words.left);
    try a.message(.binary, "welcome");
    try expectBinary(d, "welcome");

    // The host goes, without a close frame: its guest hears it and its connection ends. The next
    // page hosts, and the one after is its guest.
    a.close();
    try expectText(d, words.left);
    try testing.expectEqual(ws.CloseCode.normal, try d.closeCode());
    d.close();
    const e = try h.page();
    defer e.close();
    try expectText(e, words.host);
    const f = try h.page();
    defer f.close();
    try expectText(f, words.guest);
    try expectText(e, words.peer);
    try f.message(.binary, "again");
    try expectBinary(e, "again");
}

test "a page that breaks the protocol is ended, and the rules for its role follow" {
    var h: Harness = undefined;
    try h.start(.{});
    defer h.stop();
    const a = try h.page();
    try expectText(a, words.host);

    // A guest that sends a frame of an unknown kind, one that sends an oversized message: each is
    // ended with its close code, and its host hears that it left. Text other than the host's
    // answer is ignored.
    var oversized: [14]u8 = undefined;
    const oversized_len = ws.writeHeader(&oversized, true, .binary, platform.max_message_len + 1, .{ 0, 0, 0, 0 });
    for ([_]struct { header: []const u8, code: u16 }{
        .{ .header = &.{ 0x83, 0x80, 0, 0, 0, 0 }, .code = ws.CloseCode.protocol_error },
        .{ .header = oversized[0..oversized_len], .code = ws.CloseCode.too_big },
    }) |case| {
        const g = try h.page();
        defer g.close();
        try expectText(g, words.guest);
        try expectText(a, words.peer);
        try g.message(.text, "hello");
        try g.message(.binary, "pad");
        try expectBinary(a, "pad");
        try g.write(case.header);
        try testing.expectEqual(case.code, try g.closeCode());
        try expectText(a, words.left);
        try a.message(.text, words.left);
    }

    // A host that sends an unmasked frame: ended (1002); its guest hears it and is ended too.
    const g = try h.page();
    defer g.close();
    try expectText(g, words.guest);
    try expectText(a, words.peer);
    var header: [14]u8 = undefined;
    const n = ws.writeHeader(&header, true, .binary, 3, null);
    try a.write(header[0..n]);
    try a.write("abc");
    try testing.expectEqual(ws.CloseCode.protocol_error, try a.closeCode());
    a.close();
    try expectText(g, words.left);
    try testing.expectEqual(ws.CloseCode.normal, try g.closeCode());
    const next = try h.page();
    defer next.close();
    try expectText(next, words.host);
}

/// Reads a page's frames until one comes: `left` (1) or another (2).
fn awaitLeft(r: *Raw, state: *std.atomic.Value(u8)) Io.Cancelable!void {
    const f = r.next() catch return state.store(2, .release);
    const left = f.opcode == .text and std.mem.eql(u8, f.payload, words.left);
    state.store(if (left) 1 else 2, .release);
}

test "a page that does not take its messages is dropped, and its partner goes on" {
    var h: Harness = undefined;
    try h.start(.{ .send_queue_bytes = 64 * 1024 });
    defer h.stop();
    const a = try h.page();
    defer a.close();
    try expectText(a, words.host);
    // The guest reads nothing more.
    const b = try h.page();
    defer b.close();
    try expectText(b, words.guest);
    try expectText(a, words.peer);

    // The host sends and sends; the relay drops its guest when the guest's queue is full, and the
    // host hears that it left. The host is never held back.
    var state: std.atomic.Value(u8) = .init(0);
    var reader: Io.Group = .init;
    defer reader.cancel(testing.io);
    try reader.concurrent(testing.io, awaitLeft, .{ a, &state });
    const chunk = try testing.allocator.alloc(u8, platform.max_message_len);
    defer testing.allocator.free(chunk);
    @memset(chunk, 0x5A);
    var sent: usize = 0;
    while (state.load(.acquire) == 0) : (sent += 1) {
        // 1 GiB at most: far beyond what the sockets' buffers and the queue hold.
        if (sent == 16 * 1024) return error.TestUnexpectedResult;
        try a.message(.binary, chunk);
    }
    try reader.await(testing.io);
    try testing.expectEqual(@as(u8, 1), state.load(.acquire));
    try a.message(.text, words.left);

    // The next page is the host's guest, and their messages flow: the first it gets is the first
    // the host sent after its answer.
    const c = try h.page();
    defer c.close();
    try expectText(c, words.guest);
    try expectText(a, words.peer);
    try a.message(.binary, "after");
    try expectBinary(c, "after");
}

test "a host gone without a word is dropped after three pings, and its guest's connection ends" {
    var h: Harness = undefined;
    try h.start(.{ .keepalive_ms = 50 });
    defer h.stop();
    // The host reads nothing after it hears of its guest: no pong answers the pings.
    const a = try h.page();
    defer a.close();
    try expectText(a, words.host);
    const b = try h.page();
    defer b.close();
    try expectText(b, words.guest);
    try expectText(a, words.peer);
    // The guest answers the pings (`next` does) until it hears that its host left.
    try expectText(b, words.left);
    try testing.expectEqual(ws.CloseCode.normal, try b.closeCode());
    const c = try h.page();
    defer c.close();
    try expectText(c, words.host);
}

test "the relay serves the game's files it is given" {
    var source = sorz.memory.MemoryAssetSource.init(testing.allocator);
    defer source.deinit();
    try source.add("manifest.json", "{}");
    var assets = try served.Assets.read(testing.allocator, source.assetSource());
    defer assets.deinit();
    var server: Server = undefined;
    try server.init(testing.allocator, testing.io, .{ .assets = &assets, .log = false });
    defer server.deinit();
    try server.listen("127.0.0.1:0");
    for ([_][2][]const u8{
        .{ "GET /assets/manifest.json HTTP/1.1\r\n\r\n", assets.listing },
        .{ "GET /assets/tree/manifest.json HTTP/1.1\r\n\r\n", "{}" },
    }) |case| {
        const raw = try Raw.open(server.port());
        defer raw.close();
        try raw.write(case[0]);
        const head = try raw.head();
        try testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200"));
        const len = try std.fmt.parseInt(usize, ws.headerValue(head, "Content-Length").?, 10);
        try testing.expectEqualStrings(case[1], try raw.reader.interface.take(len));
    }
}

test "the server's options" {
    const Args = struct {
        items: []const []const u8,
        i: usize = 0,
        pub fn skip(self: *@This()) bool {
            if (self.i >= self.items.len) return false;
            self.i += 1;
            return true;
        }
        pub fn next(self: *@This()) ?[]const u8 {
            if (self.i >= self.items.len) return null;
            defer self.i += 1;
            return self.items[self.i];
        }
    };
    const o = try Options.parse(Args{ .items = &.{ "sorz-server", "sor.md", "--server", "0.0.0.0:7000" } });
    try testing.expectEqualStrings("0.0.0.0:7000", o.address.?);
    try testing.expectEqualStrings("sor.md", o.data.?);
    const tree = try Options.parse(Args{ .items = &.{ "sorz-server", "--server", "7000", "tree" } });
    try testing.expectEqualStrings("7000", tree.address.?);
    try testing.expectEqualStrings("tree", tree.data.?);
    try testing.expect((try Options.parse(Args{ .items = &.{ "sorz-server", "-h" } })).help);
    for ([_][]const []const u8{
        &.{"sorz-server"},
        &.{ "sorz-server", "sor.md", "--server" },
        &.{ "sorz-server", "--server", "7000" },
        &.{ "sorz-server", "sor.md", "--server", "nowhere:x" },
        &.{ "sorz-server", "sor.md", "--server", "7000", "--server", "7001" },
        // No option points a server at files beside the executable (DESIGN.md 1).
        &.{ "sorz-server", "sor.md", "--server", "7000", "--web", "w" },
        &.{ "sorz-server", "sor.md", "tree", "--server", "7000" },
    }) |items| try testing.expectError(error.BadArguments, Options.parse(Args{ .items = items }));
}

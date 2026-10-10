//! Server mode (DESIGN.md 9): the hub of network play between pages. `DATA --server
//! [ADDRESS:]PORT` (`sorz-server`, or a game binary given it) serves the browser build built into
//! the executable, `/netplay.json` (`"mode": "relay"`) and the game's files of DATA (a game
//! directory, or a ROM through its content extracted in memory: `served.zig`) on one port, as the
//! native host does, and joins the pages' WebSockets. It runs no game: each page loads the files
//! it serves and runs its own, and connects as it loads. The first page to connect is the host;
//! every other page is a client, given a number (from 1) that is not used again while the relay
//! runs. The session's binary messages go between the host and each client, never parsed.
//!
//! Text messages tell a page what happens:
//! - `host` or `client`: its role, as soon as its connection opens;
//! - `peer N`: to the host, client N has come; its messages follow;
//! - `left N`: to the host, client N has gone;
//! - `left`: to a client, its host has gone; the relay then ends the client's connection. The
//!   next page to connect hosts (a client connects again and may be the one).
//! Text from a page is ignored.
//!
//! Binary messages carry a client's number, two bytes, little-endian, before the game's message:
//! a client's message reaches the host after the client's number; the host's begin with the number
//! of the client they are for, which the relay takes off. A host's message for a number that is
//! not connected (gone, or not given yet) is dropped: since a number is never given again, a
//! message on its way to a client that has just left never reaches another. Should the numbers
//! run out (65535 clients), the next client is turned away until a new page hosts: the numbers
//! then start again, none of the previous host's being connected.
//!
//! Limits, as the transport's contract has them: a message of the game's is at most
//! `platform.max_message_len`, a client's number before it on the host's side (a longer one ends
//! its page's connection, close code 1009); a page that sends a malformed frame is ended (1002);
//! each connection's outgoing queue is bounded (`net.Options.send_queue_bytes`), and a page that
//! does not take what is sent to it is dropped at once when its queue is full, so that it never
//! holds another back. A client sends its host at most `client_rate` bytes a second (a burst of
//! `client_burst`), far above a game's needs: one that floods its host is ended (close code
//! 1008) before the host's queue fills with its messages, which would end the host and the
//! others' game. The relay pings every page (`keepalive_ms`) and drops one silent through
//! three pings: a host whose machine went to sleep must not keep its clients waiting.
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

/// The relay's words to the pages (text messages); `peer` and `left` to the host are followed by a
/// space and the client's number.
pub const words = struct {
    pub const host = "host";
    pub const client = "client";
    pub const peer = "peer";
    pub const left = "left";
};

/// The bytes of a client's number before a binary message (little-endian).
pub const number_len = 2;

/// The longest message a page sends: a message of the game's, a client's number before it.
pub const framed_max_len = platform.max_message_len + number_len;

/// What a client may send its host: its bytes a second, and at once. A game's client sends its
/// pads (some 600 bytes a second) and its words; the burst is well below a host's queue
/// (`net.Options.send_queue_bytes`).
pub const client_rate = 32 * 1024;
pub const client_burst = 128 * 1024;

/// The transport's options for the relay: room for a host and its clients, and pings every five
/// seconds (a silent page is dropped after fifteen). The server takes text from the pages and the
/// host's framed messages whatever the options say.
pub const transport_options: net.Options = .{
    .max_connections = 32,
    .keepalive_ms = 5000,
};

/// The rules, over the transport's events.
pub const Relay = struct {
    transport: *net.WebSocketTransport,
    gpa: std.mem.Allocator,
    host: ?ConnectionId = null,
    /// The host's clients, in the order they came.
    clients: std.ArrayList(Client) = .empty,
    /// The number the next client gets; past `maxInt(u16)`, they have all been given.
    next_number: u32 = 1,
    /// A client's message with its number before it, on its way to the host.
    framed: [framed_max_len]u8 = undefined,
    log_enabled: bool = true,

    /// A client, and the bytes it may still send its host (`spend`).
    pub const Client = struct {
        id: ConnectionId,
        number: u16,
        budget: u32 = client_burst,
        refilled_ns: ?u64 = null,

        /// Whether the client may send its host `n` bytes more at `now_ns`: its budget refills
        /// at `client_rate` a second, up to `client_burst`.
        fn spend(c: *Client, n: usize, now_ns: u64) bool {
            const since: u64 = @min(now_ns -| (c.refilled_ns orelse now_ns), std.time.ns_per_s * 8);
            c.refilled_ns = now_ns;
            c.budget = @intCast(@min(client_burst, c.budget + since * client_rate / std.time.ns_per_s));
            if (n > c.budget) return false;
            c.budget -= @intCast(n);
            return true;
        }
    };

    pub fn deinit(self: *Relay) void {
        self.clients.deinit(self.gpa);
    }

    /// Takes the transport's events until the task is canceled.
    pub fn run(self: *Relay) Io.Cancelable!void {
        var events: [64]platform.Event = undefined;
        var text: [64]bool = undefined;
        while (true) {
            // Bounded: a cancel that lands as the wait begins is seen at the next one.
            try self.transport.wait(.{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } });
            const n = self.transport.pollText(&events, &text);
            for (events[0..n], text[0..n]) |e, is_text| self.handle(e, is_text);
        }
    }

    /// One event of the transport; `text` tells a text message (ignored) from a binary one.
    pub fn handle(self: *Relay, e: platform.Event, text: bool) void {
        switch (e.payload) {
            .net_connected => |c| self.joined(c.connection),
            .net_disconnected => |d| self.gone(d.connection, @tagName(d.reason)),
            .net_received => |m| if (!text) self.pass(m.connection, m.bytes),
            else => {},
        }
    }

    fn joined(self: *Relay, id: ConnectionId) void {
        if (self.host == null) {
            self.host = id;
            // No client is connected and the last host is gone: no number can be mistaken.
            if (self.next_number > std.math.maxInt(u16)) self.next_number = 1;
            if (self.log_enabled) log.info("connection {d} hosts", .{@backingInt(id)});
            self.say(id, words.host);
            return;
        }
        if (self.next_number > std.math.maxInt(u16)) {
            if (self.log_enabled) log.warn("connection {d} is turned away: every client number was given", .{@backingInt(id)});
            self.transport.transport().close(id);
            return;
        }
        const number: u16 = @intCast(self.next_number);
        self.clients.append(self.gpa, .{ .id = id, .number = number }) catch {
            self.transport.transport().close(id);
            return;
        };
        self.next_number += 1;
        if (self.log_enabled) log.info("connection {d} is client {d}", .{ @backingInt(id), number });
        // Its role first, so that it has it before any message of the host's; then the host hears
        // of it, unless it was dropped meanwhile.
        self.say(id, words.client);
        if (self.find(id) == null) return;
        if (self.host) |h| self.sayNumber(h, words.peer, number);
    }

    /// A connection ended (its event, or the relay ended it): the rules for its role.
    fn gone(self: *Relay, id: ConnectionId, why: []const u8) void {
        if (self.host == id) {
            self.host = null;
            if (self.log_enabled) log.info("the host left ({s}); its clients' connections end ({d})", .{ why, self.clients.items.len });
            for (self.clients.items) |c| {
                if (self.transport.sendText(c.id, words.left)) |_| {
                    self.transport.transport().close(c.id);
                } else |_| self.transport.abort(c.id);
            }
            self.clients.clearRetainingCapacity();
        } else if (self.find(id)) |i| {
            const number = self.clients.items[i].number;
            _ = self.clients.orderedRemove(i);
            if (self.log_enabled) log.info("client {d} left ({s})", .{ number, why });
            if (self.host) |h| self.sayNumber(h, words.left, number);
        }
    }

    /// A binary message: a client's goes to the host after the client's number; the host's goes
    /// to the client whose number it starts with, without it. The host's message for no client
    /// connected is dropped.
    fn pass(self: *Relay, from: ConnectionId, bytes: []const u8) void {
        if (self.host == from) {
            if (bytes.len < number_len) return;
            const number = std.mem.readInt(u16, bytes[0..number_len], .little);
            for (self.clients.items) |c| {
                if (c.number == number) return self.forward(c.id, bytes[number_len..]);
            }
        } else if (self.find(from)) |i| {
            const number = self.clients.items[i].number;
            if (bytes.len > platform.max_message_len) {
                // Longer than a message of the game's: ended as the transport ends one.
                if (self.log_enabled) log.warn("client {d} sent a message too long: ended", .{number});
                self.transport.closeWith(from, ws.CloseCode.too_big);
                return self.gone(from, "too_large");
            }
            if (!self.clients.items[i].spend(bytes.len, @intCast(Io.Clock.awake.now(self.transport.io).toNanoseconds()))) {
                if (self.log_enabled) log.warn("client {d} floods its host: ended", .{number});
                self.transport.closeWith(from, ws.CloseCode.policy_violation);
                return self.gone(from, "flooding");
            }
            const host = self.host orelse return;
            std.mem.writeInt(u16, self.framed[0..number_len], number, .little);
            @memcpy(self.framed[number_len..][0..bytes.len], bytes);
            self.forward(host, self.framed[0 .. number_len + bytes.len]);
        }
    }

    fn forward(self: *Relay, to: ConnectionId, bytes: []const u8) void {
        self.transport.sendLong(to, bytes) catch |err| switch (err) {
            // Its connection is ending: its event follows.
            error.NotConnected => {},
            else => self.drop(to),
        };
    }

    fn say(self: *Relay, id: ConnectionId, word: []const u8) void {
        self.transport.sendText(id, word) catch |err| switch (err) {
            error.NotConnected => {},
            else => self.drop(id),
        };
    }

    /// `word` and a client's number: `peer N`, `left N`.
    fn sayNumber(self: *Relay, id: ConnectionId, word: []const u8, number: u16) void {
        var buf: [16]u8 = undefined;
        self.say(id, std.fmt.bufPrint(&buf, "{s} {d}", .{ word, number }) catch unreachable);
    }

    /// Where a client is among `clients`.
    fn find(self: *const Relay, id: ConnectionId) ?usize {
        for (self.clients.items, 0..) |c, i| {
            if (c.id == id) return i;
        }
        return null;
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
        transport_opts.max_message_len = framed_max_len;
        self.* = .{
            .allocator = allocator,
            .transport = .init(allocator, io, transport_opts),
            .relay = undefined,
            .manifest = manifest,
        };
        self.relay = .{ .transport = &self.transport, .gpa = allocator, .log_enabled = options.log };
    }

    /// Closes every connection (going away) and frees everything. The task that runs `run` is
    /// canceled first.
    pub fn deinit(self: *Server) void {
        self.transport.deinit();
        self.relay.deinit();
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
    \\                       (all interfaces without ADDRESS), and relay network play between
    \\                       the pages: the first page to connect hosts (player 1), every other
    \\                       page is its client
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

/// The host's message for client `number`: the number, then the bytes.
fn toClient(r: *Raw, number: u16, bytes: []const u8) !void {
    const m = try testing.allocator.alloc(u8, number_len + bytes.len);
    defer testing.allocator.free(m);
    std.mem.writeInt(u16, m[0..number_len], number, .little);
    @memcpy(m[number_len..], bytes);
    try r.message(.binary, m);
}

/// A client's message as the host gets it: the client's number, then the bytes.
fn expectFrom(r: *Raw, number: u16, bytes: []const u8) !void {
    const f = try r.next();
    try testing.expectEqual(ws.Opcode.binary, f.opcode);
    try testing.expect(f.payload.len >= number_len);
    try testing.expectEqual(number, std.mem.readInt(u16, f.payload[0..number_len], .little));
    try testing.expectEqualSlices(u8, bytes, f.payload[number_len..]);
}

/// A word and a client's number, as the host hears them.
fn expectSaid(r: *Raw, word: []const u8, number: u16) !void {
    var buf: [16]u8 = undefined;
    try expectText(r, try std.fmt.bufPrint(&buf, "{s} {d}", .{ word, number }));
}

/// A client hears that its host left, and its connection ends.
fn expectHostLeft(r: *Raw) !void {
    try expectText(r, words.left);
    try testing.expectEqual(ws.CloseCode.normal, try r.closeCode());
}

test "the hub: roles, client numbers, and the messages between the host and each client" {
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

    // The first page hosts; every other is a client, numbered from 1, which the host hears of.
    const a = try h.page();
    try expectText(a, words.host);
    const b = try h.page();
    try expectText(b, words.client);
    try expectSaid(a, words.peer, 1);
    const c = try h.page();
    try expectText(c, words.client);
    try expectSaid(a, words.peer, 2);

    // A client's messages reach the host after its number, whole and as they are: an empty one,
    // one in fragments, one as long as the game's messages are.
    try b.message(.binary, "hello");
    try expectFrom(a, 1, "hello");
    try c.message(.binary, "");
    try expectFrom(a, 2, "");
    try c.frame(.binary, false, 2, "ab");
    try c.frame(.continuation, true, 1, "c");
    try expectFrom(a, 2, "abc");
    const big = try testing.allocator.alloc(u8, platform.max_message_len);
    defer testing.allocator.free(big);
    for (big, 0..) |*x, i| x.* = @truncate(i * 13);
    try b.message(.binary, big);
    try expectFrom(a, 1, big);

    // The host's reach the client whose number they start with, without it.
    try toClient(a, 2, "to c");
    try expectBinary(c, "to c");
    try toClient(a, 1, big);
    try expectBinary(b, big);
    try toClient(a, 1, "");
    try expectBinary(b, "");

    // Text from a page is ignored, and so is a host's message for no client: a number not given,
    // a message too short to hold one.
    try b.message(.text, "hello");
    try a.message(.text, "hello");
    try toClient(a, 7, "nobody");
    try a.message(.binary, "x");
    try toClient(a, 1, "after");
    try expectBinary(b, "after");
    try b.message(.binary, "after");
    try expectFrom(a, 1, "after");

    // A client leaves: the host hears it. Its number is not given again, and what the host sends
    // for it goes nowhere, even once another client has come.
    try leave(b);
    try expectSaid(a, words.left, 1);
    try toClient(a, 1, "gone");
    const d = try h.page();
    try expectText(d, words.client);
    try expectSaid(a, words.peer, 3);
    try toClient(a, 1, "stale");
    try toClient(a, 3, "welcome");
    try expectBinary(d, "welcome");
    try toClient(a, 2, "still");
    try expectBinary(c, "still");

    // The host goes, without a close frame: each client hears it, and its connection ends. The
    // next page hosts, and the numbers go on.
    a.close();
    try expectHostLeft(c);
    c.close();
    try expectHostLeft(d);
    d.close();
    const e = try h.page();
    defer e.close();
    try expectText(e, words.host);
    const f = try h.page();
    defer f.close();
    try expectText(f, words.client);
    try expectSaid(e, words.peer, 4);
    try f.message(.binary, "again");
    try expectFrom(e, 4, "again");
}

test "a page that breaks the protocol is ended, and the rules for its role follow" {
    var h: Harness = undefined;
    try h.start(.{});
    defer h.stop();
    const a = try h.page();
    try expectText(a, words.host);

    // A client that sends a frame of an unknown kind, one longer than any page may send, one
    // longer than a message of the game's (its number would not fit before it): each is ended
    // with its close code, and the host hears that it left.
    var oversized: [14]u8 = undefined;
    const oversized_len = ws.writeHeader(&oversized, true, .binary, framed_max_len + 1, .{ 0, 0, 0, 0 });
    var too_long: [14]u8 = undefined;
    const too_long_len = ws.writeHeader(&too_long, true, .binary, platform.max_message_len + 1, .{ 0, 0, 0, 0 });
    const payload = try testing.allocator.alloc(u8, platform.max_message_len + 1);
    defer testing.allocator.free(payload);
    @memset(payload, 0);
    var number: u16 = 1;
    for ([_]struct { header: []const u8, payload: []const u8 = "", code: u16 }{
        .{ .header = &.{ 0x83, 0x80, 0, 0, 0, 0 }, .code = ws.CloseCode.protocol_error },
        .{ .header = oversized[0..oversized_len], .code = ws.CloseCode.too_big },
        .{ .header = too_long[0..too_long_len], .payload = payload, .code = ws.CloseCode.too_big },
    }) |case| {
        const g = try h.page();
        defer g.close();
        try expectText(g, words.client);
        try expectSaid(a, words.peer, number);
        try g.message(.binary, "pad");
        try expectFrom(a, number, "pad");
        try g.write(case.header);
        if (case.payload.len != 0) try g.write(case.payload);
        try testing.expectEqual(case.code, try g.closeCode());
        try expectSaid(a, words.left, number);
        number += 1;
    }

    // A host that sends an unmasked frame: ended (1002); its client hears it and is ended too.
    const g = try h.page();
    defer g.close();
    try expectText(g, words.client);
    try expectSaid(a, words.peer, number);
    var header: [14]u8 = undefined;
    const n = ws.writeHeader(&header, true, .binary, 3, null);
    try a.write(header[0..n]);
    try a.write("abc");
    try testing.expectEqual(ws.CloseCode.protocol_error, try a.closeCode());
    a.close();
    try expectHostLeft(g);
    const next = try h.page();
    defer next.close();
    try expectText(next, words.host);
}

/// Reads a page's frames until one comes: the text `word` (1) or another (2).
fn awaitWord(r: *Raw, word: []const u8, state: *std.atomic.Value(u8)) Io.Cancelable!void {
    const f = r.next() catch return state.store(2, .release);
    const heard = f.opcode == .text and std.mem.eql(u8, f.payload, word);
    state.store(if (heard) 1 else 2, .release);
}

/// Reads `r`'s messages until the relay says `word`: 1 when it does, 2 when the connection ends.
fn awaitWordPast(r: *Raw, word: []const u8, state: *std.atomic.Value(u8)) Io.Cancelable!void {
    while (true) {
        const f = r.next() catch return state.store(2, .release);
        if (f.opcode == .binary) continue;
        return state.store(if (f.opcode == .text and std.mem.eql(u8, f.payload, word)) 1 else 2, .release);
    }
}

test "a client that floods its host is ended, and the host plays on" {
    var h: Harness = undefined;
    try h.start(.{});
    defer h.stop();
    const chunk = try testing.allocator.alloc(u8, platform.max_message_len);
    defer testing.allocator.free(chunk);
    @memset(chunk, 0x5A);
    const a = try h.page();
    defer a.close();
    try expectText(a, words.host);
    const c = try h.page();
    defer c.close();
    try expectText(c, words.client);
    try expectSaid(a, words.peer, 1);
    // The host reads all along; the client sends and sends, past its budget: it is ended, and
    // the host hears that it left (its queue had room for the word).
    var state: std.atomic.Value(u8) = .init(0);
    var reader: Io.Group = .init;
    defer reader.cancel(testing.io);
    try reader.concurrent(testing.io, awaitWordPast, .{ a, "left 1", &state });
    var sent: usize = 0;
    while (sent < 64) : (sent += 1) c.message(.binary, chunk) catch break;
    try reader.await(testing.io);
    try testing.expectEqual(@as(u8, 1), state.load(.acquire));
    try testing.expectEqual(ws.CloseCode.policy_violation, try c.closeCode());
    // The host is the host still: the next client is its.
    const d = try h.page();
    defer d.close();
    try expectText(d, words.client);
    try expectSaid(a, words.peer, 2);
}

test "a page that does not take its messages is dropped, and the others go on" {
    var h: Harness = undefined;
    try h.start(.{ .send_queue_bytes = 64 * 1024 });
    defer h.stop();
    const chunk = try testing.allocator.alloc(u8, platform.max_message_len);
    defer testing.allocator.free(chunk);
    @memset(chunk, 0x5A);
    const a = try h.page();
    try expectText(a, words.host);
    // The client reads nothing more.
    const b = try h.page();
    defer b.close();
    try expectText(b, words.client);
    try expectSaid(a, words.peer, 1);

    // The host sends and sends to it; the relay drops it when its queue is full, and the host
    // hears that it left. The host is never held back.
    {
        var state: std.atomic.Value(u8) = .init(0);
        var reader: Io.Group = .init;
        defer reader.cancel(testing.io);
        try reader.concurrent(testing.io, awaitWord, .{ a, "left 1", &state });
        var sent: usize = 0;
        while (state.load(.acquire) == 0) : (sent += 1) {
            // 1 GiB at most: far beyond what the sockets' buffers and the queue hold.
            if (sent == 16 * 1024) return error.TestUnexpectedResult;
            try toClient(a, 1, chunk[number_len..]);
        }
        try reader.await(testing.io);
        try testing.expectEqual(@as(u8, 1), state.load(.acquire));
    }

    // The next client's messages flow both ways.
    const c = try h.page();
    try expectText(c, words.client);
    try expectSaid(a, words.peer, 2);
    try toClient(a, 2, "after");
    try expectBinary(c, "after");

    // A host that reads nothing more is dropped the same way when a client sends and sends: each
    // client hears that its host left.
    {
        var state: std.atomic.Value(u8) = .init(0);
        var reader: Io.Group = .init;
        defer reader.cancel(testing.io);
        try reader.concurrent(testing.io, awaitWord, .{ c, words.left, &state });
        var sent: usize = 0;
        while (state.load(.acquire) == 0) : (sent += 1) {
            if (sent == 16 * 1024) return error.TestUnexpectedResult;
            // Its connection ends once it has heard: a write may fail then.
            c.message(.binary, chunk) catch break;
        }
        try reader.await(testing.io);
        try testing.expectEqual(@as(u8, 1), state.load(.acquire));
    }
    c.close();
    a.close();
    const d = try h.page();
    defer d.close();
    try expectText(d, words.host);
}

test "a host gone without a word is dropped after three pings, and its clients' connections end" {
    var h: Harness = undefined;
    try h.start(.{ .keepalive_ms = 50 });
    defer h.stop();
    // The host reads nothing after it hears of its client: no pong answers the pings.
    const a = try h.page();
    defer a.close();
    try expectText(a, words.host);
    const b = try h.page();
    defer b.close();
    try expectText(b, words.client);
    try expectSaid(a, words.peer, 1);
    // The client answers the pings (`next` does) until it hears that its host left.
    try expectHostLeft(b);
    const c = try h.page();
    defer c.close();
    try expectText(c, words.host);
}

test "the numbers are never given again: once they have run out, a client is turned away until another page hosts" {
    var h: Harness = undefined;
    try h.start(.{});
    defer h.stop();
    // As after 65534 clients; no page has connected yet.
    h.server.relay.next_number = std.math.maxInt(u16);
    const a = try h.page();
    try expectText(a, words.host);
    const b = try h.page();
    try expectText(b, words.client);
    try expectSaid(a, words.peer, std.math.maxInt(u16));
    {
        const c = try h.page();
        defer c.close();
        try testing.expectEqual(ws.CloseCode.normal, try c.closeCode());
    }
    try b.message(.binary, "on");
    try expectFrom(a, std.math.maxInt(u16), "on");
    // The host goes: the next page hosts, and its clients are numbered from 1 again.
    a.close();
    try expectHostLeft(b);
    b.close();
    const d = try h.page();
    defer d.close();
    try expectText(d, words.host);
    const e = try h.page();
    defer e.close();
    try expectText(e, words.client);
    try expectSaid(d, words.peer, 1);
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

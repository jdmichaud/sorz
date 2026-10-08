//! The native transport of network play (DESIGN.md 9): WebSocket (RFC 6455) connections on
//! `std.Io.net`, as a `platform.Transport` that the SDL and agent backends take. `listen` serves
//! one port: a GET with `Upgrade: websocket` becomes a connection of the game, any other GET gets
//! a file of the browser build (`index.html`, `sorz.js`, `sorz.wasm`: `Options.page`, the files
//! built into the executable, never files beside it), so that a browser opens the page and joins
//! at the same address. `/netplay.json` (`Options.manifest`) tells the page that a game hosts
//! there, and `/assets/manifest.json` and `/assets/NAME` give it the game's files
//! (`Options.assets`, `served.zig`). `connect` opens a client connection to
//! `ws://ADDRESS:PORT[/PATH]`.
//!
//! The sockets block, so each connection runs two tasks of the `Io` (a reader and a writer), the
//! listener one more, and each file request its own; the game's thread never waits for the
//! network. The tasks and the game meet in bounded queues under one mutex:
//! - a connection's outgoing messages (`Options.send_queue_bytes`): `send` fails with `QueueFull`
//!   and queues nothing when the message does not fit;
//! - the events for the game (`Options.receive_queue_bytes` of messages): a reader that finds it
//!   full waits for the game's next poll, and TCP then holds the peer back.
//! A message is at most `platform.max_message_len`; a longer one from a peer ends the connection
//! with close code 1009 (`too_large`). `deinit` cancels every task and closes every socket.
//!
//! The relay (server mode, `relay.zig`) uses it too, with what the game does not need: text
//! messages with the pages (`sendText`, `Options.accept_text` and `pollText`), a wait for the
//! next event (`wait`), a connection dropped at once (`abort`) or ended with a close code of its
//! choice (`closeWith`), messages longer than the game's (`Options.max_message_len`,
//! `sendLong`), and pings that find a peer gone without a word (`Options.keepalive_ms`).
const std = @import("std");
const sorz = @import("sorz");
const platform = sorz.platform;
const ws = @import("websocket.zig");
const served = @import("served.zig");
const Io = std.Io;

/// The browser build's files in memory: those built into a binary (`web_page`, from build.zig).
pub const Page = struct {
    index_html: []const u8,
    script_js: []const u8,
    module_wasm: []const u8,

    /// The file a request names (`websocket.staticName`), or null.
    pub fn file(self: Page, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "index.html")) return self.index_html;
        if (std.mem.eql(u8, name, "sorz.js")) return self.script_js;
        if (std.mem.eql(u8, name, "sorz.wasm")) return self.module_wasm;
        return null;
    }
};

pub const Options = struct {
    /// The browser build's files, built into the executable; null answers 404.
    page: ?Page = null,
    /// The text of `/netplay.json`, which tells the page that a game hosts at this port (the
    /// native host's, or the relay's); null answers 404.
    manifest: ?[]const u8 = null,
    /// The game's files that the page loads (`/assets/manifest.json`, `/assets/NAME`), read
    /// before the transport listens; null answers 404, and the page says it has no files.
    assets: ?*const served.Assets = null,
    /// The open WebSocket connections at most; a handshake beyond gets 503.
    max_connections: usize = 4,
    /// The HTTP requests being read or served at once at most (at most `max_waiting`). When all are
    /// taken, the oldest connection still waiting for its request gives its place up; with none
    /// waiting, a new connection is closed at once.
    max_requests: usize = 16,
    /// The bytes of a connection's messages waiting to be sent.
    send_queue_bytes: usize = 1024 * 1024,
    /// The bytes of received messages the game has not polled, for all connections.
    receive_queue_bytes: usize = 1024 * 1024,
    /// When not 0, each open connection is pinged this often, and one whose peer sent nothing
    /// (no frame at all, a pong included) for three of these periods is lost: its peer went away
    /// without closing (a machine asleep, a network gone). The game's session has its own pings
    /// and leaves it at 0.
    keepalive_ms: u32 = 0,
    /// Whether a peer may send text messages (the relay ignores a page's), which `pollText`
    /// tells apart. Without it, a text message ends its connection (close code 1003), since the
    /// game's peers send binary messages only.
    accept_text: bool = false,
    /// The longest message a peer may send: the game's, or more for the relay, whose host's page
    /// puts a client's number before each of the game's messages. A longer one ends its
    /// connection (close code 1009).
    max_message_len: usize = platform.max_message_len,
};

pub const WebSocketTransport = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: Options,
    /// Every task of the transport, so that `deinit` cancels and waits for them all.
    group: Io.Group = .init,
    mutex: Io.Mutex = .init,
    /// Signalled when the game polls: a reader waiting for room in `events` tries again.
    room: Io.Condition = .init,
    /// Signalled when an event arrives, for `wait`.
    arrived: Io.Condition = .init,
    events: std.ArrayList(Pending) = .empty,
    /// The bytes of the messages in `events`.
    event_bytes: usize = 0,
    /// The messages that the last poll gave out; freed at the next.
    delivered: std.ArrayList([]u8) = .empty,
    conns: std.ArrayList(*Conn) = .empty,
    next_id: u32 = 1,
    requests: usize = 0,
    /// The accepted connections still waiting for their request, by the order they came in. A
    /// browser opens connections ahead that may send nothing for long (Firefox's speculative
    /// ones); when every request's place is taken, the oldest of them gives its place up, so
    /// that they never keep the page's files from being served.
    waiting: [max_waiting]?Waiting = @splat(null),
    next_waiting: u64 = 0,
    listening: bool = false,
    /// The port the listener got (the one asked for, or the system's choice for port 0).
    port: u16 = 0,
    /// `deinit` has begun: the connections close as going away.
    shutting_down: bool = false,

    /// How long `deinit` waits for the peers to answer the close frames.
    pub const shutdown_grace_ms = 250;

    /// The connections waiting for their request that can give their place up, at most.
    pub const max_waiting = 64;

    const Waiting = struct { stream: Io.net.Stream, order: u64 };
    const Place = struct { index: usize, order: u64 };

    /// Notes an accepted connection as waiting for its request; its place among `waiting`, or
    /// null when they are all taken (it then cannot be asked to give its place up).
    fn startWaiting(self: *WebSocketTransport, stream: Io.net.Stream) ?Place {
        self.lock();
        defer self.unlock();
        for (&self.waiting, 0..) |*w, i| if (w.* == null) {
            const order = self.next_waiting;
            self.next_waiting += 1;
            w.* = .{ .stream = stream, .order = order };
            return .{ .index = i, .order = order };
        };
        return null;
    }

    /// The connection at `place` has its request (or has failed): it no longer waits. Before its
    /// stream is closed, so that `giveUpOldest` never shuts a closed one down.
    fn stopWaiting(self: *WebSocketTransport, place: ?Place) void {
        const p = place orelse return;
        self.lock();
        defer self.unlock();
        if (self.waiting[p.index]) |w| if (w.order == p.order) {
            self.waiting[p.index] = null;
        };
    }

    /// The oldest connection still waiting for its request gives its place up: its stream is
    /// shut down, so that its reader ends and its task frees the place. Under the mutex. False
    /// when none waits.
    fn giveUpOldest(self: *WebSocketTransport) bool {
        var oldest: ?usize = null;
        for (self.waiting, 0..) |w, i| if (w) |x| {
            if (oldest == null or x.order < self.waiting[oldest.?].?.order) oldest = i;
        };
        const i = oldest orelse return false;
        self.waiting[i].?.stream.shutdown(self.io, .both) catch {};
        self.waiting[i] = null;
        return true;
    }

    pub fn init(gpa: std.mem.Allocator, io: Io, options: Options) WebSocketTransport {
        return .{ .gpa = gpa, .io = io, .options = options };
    }

    /// Closes the connections (their queues are sent, then a close frame, going away), gives
    /// their peers `shutdown_grace_ms` to answer, then cancels every task, waits for them, and
    /// frees everything.
    pub fn deinit(self: *WebSocketTransport) void {
        self.lock();
        self.shutting_down = true;
        for (self.conns.items) |c| {
            c.game_closed = true;
            c.wake.signal(self.io);
        }
        self.room.broadcast(self.io);
        self.unlock();
        var waited: u32 = 0;
        while (waited < shutdown_grace_ms) : (waited += 5) {
            self.lock();
            const left = self.conns.items.len;
            self.unlock();
            if (left == 0) break;
            self.io.sleep(.fromMilliseconds(5), .awake) catch break;
        }
        self.group.cancel(self.io);
        for (self.events.items) |e| e.free(self.gpa);
        self.events.deinit(self.gpa);
        for (self.delivered.items) |b| self.gpa.free(b);
        self.delivered.deinit(self.gpa);
        std.debug.assert(self.conns.items.len == 0);
        self.conns.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn transport(self: *WebSocketTransport) platform.Transport {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = platform.Transport.VTable{
        .listen = listen,
        .connect = connect,
        .send = send,
        .close = close,
        .poll = poll,
    };

    fn cast(ctx: *anyopaque) *WebSocketTransport {
        return @ptrCast(@alignCast(ctx));
    }

    fn lock(self: *WebSocketTransport) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *WebSocketTransport) void {
        self.mutex.unlock(self.io);
    }

    fn find(self: *WebSocketTransport, id: platform.ConnectionId) ?*Conn {
        for (self.conns.items) |c| if (c.id == id) return c;
        return null;
    }

    fn newConn(self: *WebSocketTransport, client: bool) error{OutOfMemory}!*Conn {
        const c = try self.gpa.create(Conn);
        errdefer self.gpa.destroy(c);
        c.* = .{ .t = self, .id = @fromBackingInt(@intCast(self.next_id)), .client = client };
        try self.conns.append(self.gpa, c);
        self.next_id += 1;
        return c;
    }

    /// Queues an event for the game. Under the mutex.
    fn push(self: *WebSocketTransport, p: Pending) void {
        self.events.append(self.gpa, p) catch return p.free(self.gpa);
        self.arrived.broadcast(self.io);
    }

    // --- the relay's calls ---------------------------------------------------------------------

    /// Waits until `poll` has an event to give, or the timeout passes.
    pub fn wait(self: *WebSocketTransport, timeout: Io.Timeout) Io.Cancelable!void {
        const deadline = timeout.toDeadline(self.io);
        self.lock();
        defer self.unlock();
        while (self.events.items.len == 0) {
            self.arrived.waitTimeout(self.io, &self.mutex, deadline) catch |err| switch (err) {
                error.Timeout => return,
                error.Canceled => return error.Canceled,
            };
        }
    }

    /// Queues a text message, as `send` queues a binary one: the relay's word to a page (the
    /// game's peers send and take binary messages only).
    pub fn sendText(self: *WebSocketTransport, id: platform.ConnectionId, text: []const u8) platform.NetError!void {
        if (text.len > platform.max_message_len) return error.MessageTooLarge;
        return self.queueMessage(id, .text, text);
    }

    /// Queues a binary message as `send` does, of up to `Options.max_message_len` bytes rather
    /// than the game's limit: the relay's, a client's number before a message of the game's.
    pub fn sendLong(self: *WebSocketTransport, id: platform.ConnectionId, bytes: []const u8) platform.NetError!void {
        if (bytes.len > self.options.max_message_len) return error.MessageTooLarge;
        return self.queueMessage(id, .binary, bytes);
    }

    /// Ends a connection at once: what it had to send is dropped, its socket is shut down (no
    /// close frame), and no event follows. The relay's answer to a peer that does not take its
    /// messages, whose writer can be stuck in a write that its close would wait for.
    pub fn abort(self: *WebSocketTransport, id: platform.ConnectionId) void {
        self.lock();
        defer self.unlock();
        const c = self.find(id) orelse return;
        self.dropEvents(id);
        c.game_closed = true;
        for (c.out.items) |f| self.gpa.free(f.bytes);
        c.out.clearRetainingCapacity();
        c.out_bytes = 0;
        c.endLocked(.lost, null);
        if (c.stream) |s| s.shutdown(self.io, .both) catch {};
    }

    /// Ends a connection as the transport ends a peer that breaks its rules: what it had to send
    /// goes first, then a close frame of `code`, and no event follows. The relay's answer to a
    /// page's message that is too long for its role.
    pub fn closeWith(self: *WebSocketTransport, id: platform.ConnectionId, code: u16) void {
        self.lock();
        defer self.unlock();
        const c = self.find(id) orelse return;
        if (c.reason == null and c.close_code == null) c.close_code = code;
        c.game_closed = true;
        self.dropEvents(id);
        c.wake.signal(self.io);
        self.room.broadcast(self.io);
    }

    /// Drops the undelivered events of a connection. Under the mutex.
    fn dropEvents(self: *WebSocketTransport, id: platform.ConnectionId) void {
        var kept: usize = 0;
        for (self.events.items) |e| {
            if (e.id == id) {
                if (e.kind == .received) self.event_bytes -= e.kind.received.len;
                e.free(self.gpa);
                continue;
            }
            self.events.items[kept] = e;
            kept += 1;
        }
        self.events.shrinkRetainingCapacity(kept);
    }

    // --- the game's calls ----------------------------------------------------------------------

    fn listen(ctx: *anyopaque, address: []const u8) platform.NetError!void {
        const self = cast(ctx);
        const a = try platform.parseListenAddress(address);
        const ip: Io.net.IpAddress = if (a.host.len == 0)
            .{ .ip4 = .unspecified(a.port) }
        else if (std.ascii.eqlIgnoreCase(a.host, "localhost"))
            .{ .ip4 = .loopback(a.port) }
        else
            Io.net.IpAddress.parse(a.host, a.port) catch return error.InvalidAddress;
        self.lock();
        defer self.unlock();
        if (self.listening) return error.Busy;
        var server = ip.listen(self.io, .{ .reuse_address = true }) catch |err| return switch (err) {
            error.AddressInUse => error.AddressInUse,
            error.AddressUnavailable, error.AddressFamilyUnsupported => error.InvalidAddress,
            else => error.DeviceFailure,
        };
        self.port = server.socket.address.getPort();
        self.group.concurrent(self.io, acceptLoop, .{ self, server }) catch {
            server.deinit(self.io);
            return error.DeviceFailure;
        };
        self.listening = true;
    }

    fn connect(ctx: *anyopaque, url: []const u8) platform.NetError!platform.ConnectionId {
        const self = cast(ctx);
        const u = try platform.WsUrl.parse(url);
        self.lock();
        defer self.unlock();
        if (self.openCount() >= self.options.max_connections) return error.Busy;
        const c = try self.newConn(true);
        errdefer self.discard(c);
        c.url_host = try self.gpa.dupe(u8, u.host);
        c.url_path = try self.gpa.dupe(u8, u.path);
        c.url_port = u.port;
        c.refs = 1;
        self.group.concurrent(self.io, runClient, .{c}) catch return error.DeviceFailure;
        return c.id;
    }

    fn send(ctx: *anyopaque, id: platform.ConnectionId, bytes: []const u8) platform.NetError!void {
        return cast(ctx).queueMessage(id, .binary, bytes);
    }

    fn queueMessage(self: *WebSocketTransport, id: platform.ConnectionId, opcode: ws.Opcode, bytes: []const u8) platform.NetError!void {
        self.lock();
        defer self.unlock();
        const c = self.find(id) orelse return error.NotConnected;
        if (c.state != .open or c.game_closed) return error.NotConnected;
        if (c.out_bytes + bytes.len > self.options.send_queue_bytes) return error.QueueFull;
        const copy = try self.gpa.dupe(u8, bytes);
        c.out.append(self.gpa, .{ .opcode = opcode, .bytes = copy }) catch {
            self.gpa.free(copy);
            return error.OutOfMemory;
        };
        c.out_bytes += bytes.len;
        c.wake.signal(self.io);
    }

    fn close(ctx: *anyopaque, id: platform.ConnectionId) void {
        const self = cast(ctx);
        self.lock();
        defer self.unlock();
        const c = self.find(id) orelse return;
        c.game_closed = true;
        // Its undelivered events are dropped; none follows.
        self.dropEvents(id);
        c.wake.signal(self.io);
        self.room.broadcast(self.io);
    }

    fn poll(ctx: *anyopaque, dst: []platform.Event, time_ns: u64) usize {
        return cast(ctx).pollEvents(dst, null, time_ns);
    }

    /// `poll` for the relay, with `Options.accept_text`: `text[i]` tells whether the message of
    /// `dst[i]` was a text message.
    pub fn pollText(self: *WebSocketTransport, dst: []platform.Event, text: []bool) usize {
        std.debug.assert(text.len >= dst.len);
        return self.pollEvents(dst, text, 0);
    }

    fn pollEvents(self: *WebSocketTransport, dst: []platform.Event, text: ?[]bool, time_ns: u64) usize {
        self.lock();
        defer self.unlock();
        for (self.delivered.items) |b| self.gpa.free(b);
        self.delivered.clearRetainingCapacity();
        var n: usize = 0;
        for (self.events.items) |e| {
            if (n == dst.len) break;
            if (e.kind == .received) self.delivered.ensureUnusedCapacity(self.gpa, 1) catch break;
            dst[n] = .{ .time_ns = time_ns, .payload = switch (e.kind) {
                .connected => |incoming| .{ .net_connected = .{ .connection = e.id, .incoming = incoming } },
                .disconnected => |reason| .{ .net_disconnected = .{ .connection = e.id, .reason = reason } },
                .received => |bytes| blk: {
                    self.delivered.appendAssumeCapacity(bytes);
                    self.event_bytes -= bytes.len;
                    break :blk .{ .net_received = .{ .connection = e.id, .bytes = bytes } };
                },
            } };
            if (text) |t| t[n] = e.text;
            n += 1;
        }
        const rest = self.events.items.len - n;
        std.mem.copyForwards(Pending, self.events.items[0..rest], self.events.items[n..]);
        self.events.shrinkRetainingCapacity(rest);
        if (n != 0) self.room.broadcast(self.io);
        return n;
    }

    /// The connections that count against `max_connections`. Under the mutex.
    fn openCount(self: *const WebSocketTransport) usize {
        var n: usize = 0;
        for (self.conns.items) |c| {
            if (!c.game_closed) n += 1;
        }
        return n;
    }

    /// Removes a connection that no task holds. Under the mutex.
    fn discard(self: *WebSocketTransport, c: *Conn) void {
        for (self.conns.items, 0..) |x, i| if (x == c) {
            _ = self.conns.swapRemove(i);
            break;
        };
        c.deinit(self.gpa);
        self.gpa.destroy(c);
    }
};

const Pending = struct {
    id: platform.ConnectionId,
    kind: union(enum) {
        connected: bool,
        disconnected: platform.DisconnectReason,
        received: []u8,
    },
    /// A text message (`Options.accept_text`).
    text: bool = false,

    fn free(p: Pending, gpa: std.mem.Allocator) void {
        switch (p.kind) {
            .received => |b| gpa.free(b),
            else => {},
        }
    }
};

const Frame = struct { opcode: ws.Opcode, bytes: []u8 };

/// The page's cue that a game hosts at this port (`Options.manifest`).
pub const manifest_name = "netplay.json";

/// A WebSocket connection, from its handshake to its end. Its fields are under the transport's
/// mutex, but for `stream`, which is set before the tasks that use it start.
const Conn = struct {
    t: *WebSocketTransport,
    id: platform.ConnectionId,
    /// A client masks its frames and expects the server's unmasked (RFC 6455 section 5.1).
    client: bool,
    url_host: []u8 = &.{},
    url_path: []u8 = &.{},
    url_port: u16 = 0,
    stream: ?Io.net.Stream = null,
    state: enum { connecting, open, ending } = .connecting,
    /// Whether the game has its `net_connected` event (else a failure is `refused`).
    announced: bool = false,
    /// The game closed it: its queue is sent, then a close frame; no event follows.
    game_closed: bool = false,
    /// The first reason that the connection ended for.
    reason: ?platform.DisconnectReason = null,
    /// The close frame to send as the writer ends (ours, or the answer to the peer's).
    close_code: ?u16 = null,
    out: std.ArrayList(Frame) = .empty,
    out_bytes: usize = 0,
    /// Wakes the writer: a message, a close, an end.
    wake: Io.Condition = .init,
    /// The tasks that hold the connection; the last one out closes it.
    refs: u8 = 0,
    /// When the reader last had a frame (`Options.keepalive_ms`), on the awake clock.
    last_read_ns: std.atomic.Value(u64) = .init(0),

    fn deinit(c: *Conn, gpa: std.mem.Allocator) void {
        for (c.out.items) |f| gpa.free(f.bytes);
        c.out.deinit(gpa);
        gpa.free(c.url_host);
        gpa.free(c.url_path);
    }

    /// The connection ends for `reason`, with a close frame of `code` if not null. The first
    /// reason stays. Takes the mutex.
    fn end(c: *Conn, reason: platform.DisconnectReason, code: ?u16) void {
        const t = c.t;
        t.lock();
        defer t.unlock();
        c.endLocked(reason, code);
    }

    fn endLocked(c: *Conn, reason: platform.DisconnectReason, code: ?u16) void {
        if (c.reason == null) {
            c.reason = reason;
            if (c.close_code == null) c.close_code = code;
        }
        c.state = .ending;
        c.wake.signal(c.t.io);
        c.t.room.broadcast(c.t.io);
    }

    /// The handshake is done: the game hears of the connection. Returns false when the game
    /// already closed it.
    fn opened(c: *Conn, incoming: bool) bool {
        const t = c.t;
        t.lock();
        defer t.unlock();
        if (c.game_closed or c.state == .ending) return false;
        c.state = .open;
        c.announced = true;
        c.last_read_ns.store(nowNs(t.io), .monotonic);
        t.push(.{ .id = c.id, .kind = .{ .connected = incoming } });
        return true;
    }

    /// A task lets go of the connection; the last one closes the socket, tells the game why the
    /// connection ended (unless it closed it) and frees it.
    fn release(c: *Conn) void {
        const t = c.t;
        t.lock();
        defer t.unlock();
        c.refs -= 1;
        if (c.refs != 0) {
            // The other task learns that this one ended.
            c.state = .ending;
            if (c.reason == null) c.reason = .lost;
            c.wake.signal(t.io);
            return;
        }
        if (c.stream) |s| s.close(t.io);
        if (!c.game_closed) {
            const reason: platform.DisconnectReason = if (!c.announced) .refused else c.reason orelse .lost;
            t.push(.{ .id = c.id, .kind = .{ .disconnected = reason } });
        }
        t.discard(c);
    }

    /// Gives a whole message to the game, waiting for room in the queue. Returns false when the
    /// connection must stop (closed by the game, canceled).
    fn deliver(c: *Conn, bytes: []u8, text: bool) bool {
        const t = c.t;
        t.lock();
        defer t.unlock();
        while (!c.game_closed and t.events.items.len != 0 and t.event_bytes + bytes.len > t.options.receive_queue_bytes) {
            t.room.wait(t.io, &t.mutex) catch break;
        }
        if (c.game_closed or (t.events.items.len != 0 and t.event_bytes + bytes.len > t.options.receive_queue_bytes)) {
            t.gpa.free(bytes);
            return false;
        }
        t.events.append(t.gpa, .{ .id = c.id, .kind = .{ .received = bytes }, .text = text }) catch {
            t.gpa.free(bytes);
            return false;
        };
        t.event_bytes += bytes.len;
        t.arrived.broadcast(t.io);
        return true;
    }

    /// Queues a control frame (a pong) for the writer. Takes the mutex.
    fn queueControl(c: *Conn, opcode: ws.Opcode, payload: []const u8) void {
        const t = c.t;
        t.lock();
        defer t.unlock();
        const copy = t.gpa.dupe(u8, payload) catch return;
        c.out.append(t.gpa, .{ .opcode = opcode, .bytes = copy }) catch {
            t.gpa.free(copy);
            return;
        };
        c.wake.signal(t.io);
    }

    /// Starts the writer task for an open connection. False if it cannot run.
    fn startWriter(c: *Conn) bool {
        const t = c.t;
        t.lock();
        c.refs += 1;
        t.unlock();
        t.group.concurrent(t.io, writeLoop, .{c}) catch {
            t.lock();
            c.refs -= 1;
            t.unlock();
            c.end(.lost, null);
            return false;
        };
        return true;
    }
};

// --- the tasks -----------------------------------------------------------------------------------

fn acceptLoop(t: *WebSocketTransport, server_value: Io.net.Server) Io.Cancelable!void {
    var server = server_value;
    defer server.deinit(t.io);
    while (true) {
        const stream = server.accept(t.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ConnectionAborted => continue,
            else => {
                // Out of descriptors or memory: wait a moment rather than spin.
                t.io.sleep(.fromMilliseconds(50), .awake) catch return error.Canceled;
                continue;
            },
        };
        t.lock();
        // A place freed by a connection that waited the longest for its request counts at once:
        // its task leaves soon, the count over its most until then.
        const room = t.requests < @min(t.options.max_requests, WebSocketTransport.max_waiting) or t.giveUpOldest();
        if (room) t.requests += 1;
        t.unlock();
        if (!room) {
            stream.close(t.io);
            continue;
        }
        t.group.concurrent(t.io, serveRequest, .{ t, stream }) catch {
            t.lock();
            t.requests -= 1;
            t.unlock();
            stream.close(t.io);
        };
    }
}

/// One accepted connection: its HTTP request, answered with a file, or upgraded to a WebSocket
/// connection of the game.
fn serveRequest(t: *WebSocketTransport, stream: Io.net.Stream) Io.Cancelable!void {
    const io = t.io;
    var counted = true;
    defer if (counted) {
        t.lock();
        t.requests -= 1;
        t.unlock();
    };
    var rbuf: [ws.max_head_len]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    const w = &writer.interface;
    const place = t.startWaiting(stream);
    const head_len = readHead(&reader.interface) catch {
        t.stopWaiting(place);
        stream.close(io);
        return;
    };
    t.stopWaiting(place);
    const head = reader.interface.buffered()[0..head_len];
    const req = ws.parseRequest(head) catch {
        ws.writeStatus(w, "400 Bad Request", "", "bad request\n") catch {};
        w.flush() catch {};
        stream.close(io);
        return;
    };
    if (!req.upgrade) {
        serveFile(t, w, req);
        w.flush() catch {};
        stream.close(io);
        return;
    }
    // The opening handshake (RFC 6455 section 4.2).
    const key = req.key orelse "";
    var decoded: [18]u8 = undefined;
    const key_ok = key.len == 24 and (std.base64.standard.Decoder.calcSizeForSlice(key) catch 0) == 16 and
        (if (std.base64.standard.Decoder.decode(&decoded, key)) true else |_| false);
    if (!std.mem.eql(u8, req.method, "GET") or !key_ok) {
        ws.writeStatus(w, "400 Bad Request", "", "bad WebSocket handshake\n") catch {};
        w.flush() catch {};
        stream.close(io);
        return;
    }
    if (!std.mem.eql(u8, req.version orelse "", "13")) {
        ws.writeStatus(w, "426 Upgrade Required", "Sec-WebSocket-Version: 13\r\n", "WebSocket version 13 only\n") catch {};
        w.flush() catch {};
        stream.close(io);
        return;
    }
    t.lock();
    const c = if (t.openCount() < t.options.max_connections) t.newConn(false) catch null else null;
    if (c) |conn| {
        conn.stream = stream;
        conn.refs = 1;
    }
    t.unlock();
    const conn = c orelse {
        ws.writeStatus(w, "503 Service Unavailable", "", "no room for another connection\n") catch {};
        w.flush() catch {};
        stream.close(io);
        return;
    };
    // From here the connection owns the stream, and it no longer counts as a request.
    t.lock();
    t.requests -= 1;
    counted = false;
    t.unlock();
    defer conn.release();
    ws.writeUpgradeResponse(w, key) catch return conn.end(.lost, null);
    w.flush() catch return conn.end(.lost, null);
    reader.interface.toss(head_len);
    if (!conn.opened(true)) return;
    if (!conn.startWriter()) return;
    readLoop(conn, &reader);
}

fn serveFile(t: *WebSocketTransport, w: *Io.Writer, req: ws.Request) void {
    const head_only = std.mem.eql(u8, req.method, "HEAD");
    if (!head_only and !std.mem.eql(u8, req.method, "GET")) {
        ws.writeStatus(w, "405 Method Not Allowed", "Allow: GET, HEAD\r\n", "GET or HEAD only\n") catch {};
        return;
    }
    if (std.mem.eql(u8, req.path, "/" ++ manifest_name)) {
        return writeFile(w, "application/json", t.options.manifest orelse return notFound(w), head_only);
    }
    if (std.mem.startsWith(u8, req.path, assets_path)) {
        const assets = t.options.assets orelse return notFound(w);
        // A name in a URL may be percent-encoded; it is only looked up among the listed files,
        // never opened as a path.
        var buf: [served.Assets.directory.len + platform.max_asset_name_len]u8 = undefined;
        const raw = req.path[assets_path.len..];
        if (raw.len > buf.len) return notFound(w);
        @memcpy(buf[0..raw.len], raw);
        const name = std.Uri.percentDecodeInPlace(buf[0..raw.len]);
        if (std.mem.eql(u8, name, served.Assets.listing_name)) return writeFile(w, "application/json", assets.listing, head_only);
        return writeFile(w, ws.contentType(name), assets.find(name) orelse return notFound(w), head_only);
    }
    const name = ws.staticName(req.path) orelse return notFound(w);
    const bytes = (t.options.page orelse return notFound(w)).file(name) orelse return notFound(w);
    writeFile(w, ws.contentType(name), bytes, head_only);
}

/// The directory of the game's files (`Options.assets`).
pub const assets_path = "/assets/";

fn writeFile(w: *Io.Writer, content_type: []const u8, bytes: []const u8, head_only: bool) void {
    w.print("HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-cache\r\n" ++
        "Connection: close\r\n\r\n", .{ content_type, bytes.len }) catch return;
    if (!head_only) w.writeAll(bytes) catch return;
}

fn notFound(w: *Io.Writer) void {
    ws.writeStatus(w, "404 Not Found", "", "not found\n") catch {};
}

/// Reads until the reader's buffer holds a whole HTTP head; returns its length.
pub fn readHead(r: *Io.Reader) !usize {
    while (true) {
        if (ws.headEnd(r.buffered())) |n| return n;
        if (r.bufferedLen() == r.buffer.len) return error.HeadTooLong;
        try r.fillMore();
    }
}

/// A client connection: the TCP connection, the opening handshake, then its messages.
fn runClient(c: *Conn) Io.Cancelable!void {
    const t = c.t;
    const io = t.io;
    defer c.release();
    const stream = connectTo(io, c.url_host, c.url_port) catch |err| {
        c.end(.refused, null);
        if (err == error.Canceled) return error.Canceled;
        return;
    };
    t.lock();
    c.stream = stream;
    const closed = c.game_closed;
    t.unlock();
    if (closed) return;
    var rbuf: [ws.max_head_len]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var wbuf: [1024]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    var random: [16]u8 = undefined;
    io.random(&random);
    const key = ws.clientKey(random);
    ws.writeUpgradeRequest(&writer.interface, c.url_host, c.url_port, c.url_path, &key) catch return c.end(.refused, null);
    writer.interface.flush() catch return c.end(.refused, null);
    const head_len = readHead(&reader.interface) catch return c.end(.refused, null);
    ws.checkUpgradeResponse(reader.interface.buffered()[0..head_len], &key) catch return c.end(.refused, null);
    reader.interface.toss(head_len);
    if (!c.opened(false)) return;
    if (!c.startWriter()) return;
    readLoop(c, &reader);
}

fn connectTo(io: Io, host: []const u8, port: u16) !Io.net.Stream {
    if (Io.net.IpAddress.parse(host, port)) |ip| {
        return ip.connect(io, .{ .mode = .stream });
    } else |_| {}
    const name = try Io.net.HostName.init(host);
    return name.connect(io, port, .{ .mode = .stream });
}

/// Reads frames until the connection ends: whole messages go to the game, pings are answered,
/// a close is answered by the writer.
fn readLoop(c: *Conn, sr: *Io.net.Stream.Reader) void {
    const t = c.t;
    const r = &sr.interface;
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(t.gpa);
    var in_message = false;
    var text = false;
    while (true) {
        const h = readHeader(r) catch |err| return switch (err) {
            error.Protocol => c.end(.protocol, ws.CloseCode.protocol_error),
            else => readFailed(c, sr),
        };
        c.last_read_ns.store(nowNs(t.io), .monotonic);
        // The client masks, the server does not (RFC 6455 section 5.1).
        if ((h.mask != null) == c.client) return c.end(.protocol, ws.CloseCode.protocol_error);
        if (h.opcode.isControl()) {
            var buf: [125]u8 = undefined;
            const payload = buf[0..@intCast(h.len)];
            r.readSliceAll(payload) catch return readFailed(c, sr);
            if (h.mask) |m| ws.applyMask(payload, m, 0);
            switch (h.opcode) {
                .ping => c.queueControl(.pong, payload),
                .pong => {},
                .close => {
                    // Answered with the peer's code, or a normal close.
                    const code: u16 = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else ws.CloseCode.normal;
                    return c.end(.closed, code);
                },
                else => unreachable,
            }
            continue;
        }
        switch (h.opcode) {
            .text, .binary => {
                if (in_message) return c.end(.protocol, ws.CloseCode.protocol_error);
                text = h.opcode == .text;
                if (text and !t.options.accept_text) return c.end(.protocol, ws.CloseCode.unsupported_data);
            },
            .continuation => if (!in_message) return c.end(.protocol, ws.CloseCode.protocol_error),
            else => unreachable,
        }
        if (message.items.len + h.len > t.options.max_message_len) return c.end(.too_large, ws.CloseCode.too_big);
        const len: usize = @intCast(h.len);
        message.ensureUnusedCapacity(t.gpa, len) catch return c.end(.lost, ws.CloseCode.going_away);
        const dst = message.unusedCapacitySlice()[0..len];
        r.readSliceAll(dst) catch return readFailed(c, sr);
        if (h.mask) |m| ws.applyMask(dst, m, 0);
        message.items.len += len;
        in_message = !h.fin;
        if (h.fin) {
            const bytes = message.toOwnedSlice(t.gpa) catch return c.end(.lost, ws.CloseCode.going_away);
            if (!c.deliver(bytes, text)) return c.end(.closed, ws.CloseCode.normal);
        }
    }
}

/// A read ended the connection: the transport shuts down (a close frame goes out), or the stream
/// ended or broke.
fn readFailed(c: *Conn, sr: *const Io.net.Stream.Reader) void {
    if (sr.err) |err| if (err == error.Canceled) return c.end(.closed, ws.CloseCode.going_away);
    c.end(.lost, null);
}

fn nowNs(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

pub fn readHeader(r: *Io.Reader) (Io.Reader.Error || ws.ProtocolError)!ws.Header {
    var hb: [14]u8 = undefined;
    hb[0..2].* = (try r.takeArray(2)).*;
    var need: usize = 2;
    const short = hb[1] & 0x7F;
    if (short == 126) need += 2 else if (short == 127) need += 8;
    if (hb[1] & 0x80 != 0) need += 4;
    if (need > 2) @memcpy(hb[2..need], try r.take(need - 2));
    return (try ws.parseHeader(hb[0..need])).?;
}

/// Sends the queued frames as they come; at the end, the close frame, then the end of the
/// stream's sending side.
fn writeLoop(c: *Conn) Io.Cancelable!void {
    const t = c.t;
    const io = t.io;
    defer c.release();
    const stream = c.stream.?;
    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    const w = &writer.interface;
    var batch: std.ArrayList(Frame) = .empty;
    defer {
        for (batch.items) |f| t.gpa.free(f.bytes);
        batch.deinit(t.gpa);
    }
    var keepalive: Keepalive = .init(c);
    while (true) {
        t.lock();
        var silent = keepalive.due(c);
        while (!silent and c.out.items.len == 0 and c.state == .open and !c.game_closed) {
            c.wake.waitTimeout(io, &t.mutex, keepalive.timeout()) catch |err| switch (err) {
                error.Timeout => silent = keepalive.due(c),
                error.Canceled => {
                    // The transport shuts down: the peer hears it as a close (going away).
                    c.endLocked(.closed, ws.CloseCode.going_away);
                    t.unlock();
                    var payload = ws.closePayload(ws.CloseCode.going_away);
                    writeFrame(c, w, .close, &payload) catch {};
                    w.flush() catch {};
                    stream.shutdown(io, .send) catch {};
                    return error.Canceled;
                },
            };
        }
        if (silent) {
            // The peer is gone: no close frame would reach it. The reader stops too.
            c.endLocked(.lost, null);
            stream.shutdown(io, .both) catch {};
        }
        std.mem.swap(std.ArrayList(Frame), &batch, &c.out);
        c.out_bytes = 0;
        const game_closed = c.game_closed;
        const ending = batch.items.len == 0 and (c.state == .ending or game_closed);
        const code: ?u16 = if (game_closed and c.reason == null)
            (if (t.shutting_down) ws.CloseCode.going_away else c.close_code orelse ws.CloseCode.normal)
        else
            c.close_code;
        t.unlock();
        var failed = false;
        for (batch.items) |f| {
            if (!failed) writeFrame(c, w, f.opcode, f.bytes) catch {
                failed = true;
            };
        }
        for (batch.items) |f| t.gpa.free(f.bytes);
        batch.clearRetainingCapacity();
        if (!failed) w.flush() catch {
            failed = true;
        };
        if (failed) return failWrite(c, stream);
        if (ending) {
            if (code) |k| {
                var payload = ws.closePayload(k);
                writeFrame(c, w, .close, &payload) catch {};
                w.flush() catch {};
            }
            if (game_closed) c.end(.closed, null);
            stream.shutdown(io, .send) catch {};
            return;
        }
    }
}

/// The writer's pings (`Options.keepalive_ms`): one every period, whatever else it sends, and the
/// verdict on a peer that sent nothing for three of them.
const Keepalive = struct {
    period_ns: u64,
    next_ns: u64,

    fn init(c: *const Conn) Keepalive {
        const period = @as(u64, c.t.options.keepalive_ms) * std.time.ns_per_ms;
        return .{ .period_ns = period, .next_ns = nowNs(c.t.io) + period };
    }

    /// Queues a ping when one is due, and returns whether the peer is silent. Under the mutex.
    fn due(k: *Keepalive, c: *Conn) bool {
        if (k.period_ns == 0) return false;
        const now = nowNs(c.t.io);
        if (now < k.next_ns) return false;
        k.next_ns = now + k.period_ns;
        if (now -| c.last_read_ns.load(.monotonic) >= 3 * k.period_ns) return true;
        c.out.append(c.t.gpa, .{ .opcode = .ping, .bytes = &.{} }) catch {};
        return false;
    }

    /// How long the writer may wait for something to send.
    fn timeout(k: *const Keepalive) Io.Timeout {
        if (k.period_ns == 0) return .none;
        return .{ .deadline = Io.Timestamp.fromNanoseconds(k.next_ns).withClock(.awake) };
    }
};

fn failWrite(c: *Conn, stream: Io.net.Stream) void {
    c.end(.lost, null);
    // The reader stops too.
    stream.shutdown(c.t.io, .both) catch {};
}

fn writeFrame(c: *Conn, w: *Io.Writer, opcode: ws.Opcode, bytes: []u8) Io.Writer.Error!void {
    var header: [14]u8 = undefined;
    var mask: ?[4]u8 = null;
    if (c.client) {
        var k: [4]u8 = undefined;
        c.t.io.random(&k);
        mask = k;
        ws.applyMask(bytes, k, 0);
    }
    const n = ws.writeHeader(&header, true, opcode, bytes.len, mask);
    try w.writeAll(header[0..n]);
    try w.writeAll(bytes);
}

// --- tests ---------------------------------------------------------------------------------------

const testing = std.testing;

/// Polls `t` until `n` events came or the time runs out (the tasks run on their own threads). A
/// poll releases the messages of the one before, so the messages are copied into `arena`.
fn waitEvents(arena: std.mem.Allocator, t: platform.Transport, dst: []platform.Event, n: usize) ![]platform.Event {
    var got: usize = 0;
    var tries: usize = 0;
    while (got < n) : (tries += 1) {
        if (tries > 2500) return error.Timeout;
        const k = t.poll(dst[got..], 0);
        for (dst[got..][0..k]) |*e| switch (e.payload) {
            .net_received => |*m| m.bytes = try arena.dupe(u8, m.bytes),
            else => {},
        };
        got += k;
        if (got < n) try testing.io.sleep(.fromMilliseconds(2), .awake);
    }
    return dst[0..got];
}

/// Polls until `t` has an event; its message is valid until the next poll.
fn nextEvent(t: platform.Transport) !platform.Event {
    var one: [1]platform.Event = undefined;
    var tries: usize = 0;
    while (t.poll(&one, 0) == 0) : (tries += 1) {
        if (tries > 2500) return error.Timeout;
        try testing.io.sleep(.fromMilliseconds(2), .awake);
    }
    return one[0];
}

fn loopbackUrl(buf: []u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf, "ws://127.0.0.1:{d}", .{port}) catch unreachable;
}

test "two transports on localhost: connect, messages both ways, close" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var server = WebSocketTransport.init(testing.allocator, testing.io, .{});
    defer server.deinit();
    var client = WebSocketTransport.init(testing.allocator, testing.io, .{});
    defer client.deinit();
    const st = server.transport();
    const ct = client.transport();
    // A test environment without a loopback socket fails here, with the error named: no test is
    // skipped (docs/testing.md).
    try st.listen("127.0.0.1:0");
    try testing.expectError(error.Busy, st.listen("127.0.0.1:0"));
    var url_buf: [64]u8 = undefined;
    const id = try ct.connect(loopbackUrl(&url_buf, server.port));
    try testing.expectError(error.NotConnected, ct.send(id, "early"));

    const sc = try nextEvent(st);
    const sid = sc.payload.net_connected.connection;
    try testing.expect(sc.payload.net_connected.incoming);
    const cc = try nextEvent(ct);
    try testing.expectEqual(id, cc.payload.net_connected.connection);
    try testing.expect(!cc.payload.net_connected.incoming);

    // Messages both ways, whole and in order, a large one included.
    const big = try testing.allocator.alloc(u8, platform.max_message_len);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i * 7);
    try ct.send(id, "hello");
    try ct.send(id, big);
    try ct.send(id, "");
    var evs: [4]platform.Event = undefined;
    const got = try waitEvents(arena.allocator(), st, &evs, 3);
    try testing.expectEqualStrings("hello", got[0].payload.net_received.bytes);
    try testing.expectEqualSlices(u8, big, got[1].payload.net_received.bytes);
    try testing.expectEqual(@as(usize, 0), got[2].payload.net_received.bytes.len);
    try testing.expectEqual(sid, got[2].payload.net_received.connection);
    try st.send(sid, "welcome");
    try testing.expectEqualStrings("welcome", (try nextEvent(ct)).payload.net_received.bytes);

    // The client closes: the server hears it after the messages sent before; no event for the
    // client.
    try ct.send(id, "last");
    ct.close(id);
    try testing.expectError(error.NotConnected, ct.send(id, "after"));
    const end = try waitEvents(arena.allocator(), st, &evs, 2);
    try testing.expectEqualStrings("last", end[0].payload.net_received.bytes);
    try testing.expectEqual(platform.DisconnectReason.closed, end[1].payload.net_disconnected.reason);
    try testing.expectError(error.NotConnected, st.send(sid, "gone"));
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectEqual(@as(usize, 0), ct.poll(&evs, 0));
}

test "a refused connection, a peer that leaves, a full queue" {
    var server = WebSocketTransport.init(testing.allocator, testing.io, .{ .send_queue_bytes = 100 });
    defer server.deinit();
    const st = server.transport();
    try st.listen("127.0.0.1:0");
    const port = server.port;
    var url_buf: [64]u8 = undefined;
    {
        // No listener at a port: refused.
        var lone = WebSocketTransport.init(testing.allocator, testing.io, .{});
        defer lone.deinit();
        var other = WebSocketTransport.init(testing.allocator, testing.io, .{});
        try other.transport().listen("127.0.0.1:0");
        const free_port = other.port;
        other.deinit();
        const id = try lone.transport().connect(loopbackUrl(&url_buf, free_port));
        const e = try nextEvent(lone.transport());
        try testing.expectEqual(id, e.payload.net_disconnected.connection);
        try testing.expectEqual(platform.DisconnectReason.refused, e.payload.net_disconnected.reason);
        try testing.expectError(error.InvalidAddress, lone.transport().connect("ws://h"));
    }
    {
        // The client's transport shuts down: the server hears `closed`.
        var client = WebSocketTransport.init(testing.allocator, testing.io, .{});
        const id = try client.transport().connect(loopbackUrl(&url_buf, port));
        const sid = (try nextEvent(st)).payload.net_connected.connection;
        _ = try nextEvent(client.transport());
        _ = id;
        // A full queue refuses a message whole and keeps the connection.
        const over_queue: [101]u8 = @splat(0);
        try testing.expectError(error.QueueFull, st.send(sid, &over_queue));
        const over_limit: [platform.max_message_len + 1]u8 = @splat(0);
        try testing.expectError(error.MessageTooLarge, st.send(sid, &over_limit));
        client.deinit();
        const e = try nextEvent(st);
        try testing.expectEqual(sid, e.payload.net_disconnected.connection);
        try testing.expectEqual(platform.DisconnectReason.closed, e.payload.net_disconnected.reason);
    }
}

/// A raw TCP client of the transport's port, to send what a correct client would not, and to read
/// what a page reads (the relay's tests, `relay.zig`).
pub const Raw = struct {
    stream: Io.net.Stream,
    rbuf: [4096]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    /// The payload of the frame that `next` read last: a message of the game's, or one of the
    /// relay's, a client's number before it.
    payload: [platform.max_message_len + 16]u8 = undefined,

    pub fn open(port: u16) !*Raw {
        const r = try testing.allocator.create(Raw);
        errdefer testing.allocator.destroy(r);
        const ip: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        r.* = .{ .stream = try ip.connect(testing.io, .{ .mode = .stream }) };
        r.reader = r.stream.reader(testing.io, &r.rbuf);
        return r;
    }

    pub fn close(r: *Raw) void {
        r.stream.close(testing.io);
        testing.allocator.destroy(r);
    }

    pub fn write(r: *Raw, bytes: []const u8) !void {
        var buf: [256]u8 = undefined;
        var w = r.stream.writer(testing.io, &buf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    /// Reads the answer's head (an HTTP status line and headers).
    pub fn head(r: *Raw) ![]const u8 {
        const n = try readHead(&r.reader.interface);
        const h = r.reader.interface.buffered()[0..n];
        r.reader.interface.toss(n);
        return h;
    }

    pub fn handshake(r: *Raw) !void {
        try r.write("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
        try ws.checkUpgradeResponse(try r.head(), "dGhlIHNhbXBsZSBub25jZQ==");
    }

    /// Sends a masked frame header announcing `len` bytes, then `payload`.
    pub fn frame(r: *Raw, opcode: ws.Opcode, fin: bool, len: u64, payload: []const u8) !void {
        var h: [14]u8 = undefined;
        const n = ws.writeHeader(&h, fin, opcode, len, .{ 0, 0, 0, 0 });
        try r.write(h[0..n]);
        if (payload.len != 0) try r.write(payload);
    }

    /// Sends a whole message in one frame.
    pub fn message(r: *Raw, opcode: ws.Opcode, payload: []const u8) !void {
        try r.frame(opcode, true, payload.len, payload);
    }

    pub const Received = struct { opcode: ws.Opcode, payload: []const u8 };

    /// The next frame from the server that is not a ping (a ping is answered); its payload is
    /// valid until the next read.
    pub fn next(r: *Raw) !Received {
        while (true) {
            const h = try readHeader(&r.reader.interface);
            const p = r.payload[0..@intCast(h.len)];
            try r.reader.interface.readSliceAll(p);
            if (h.opcode == .ping) {
                try r.message(.pong, p);
                continue;
            }
            return .{ .opcode = h.opcode, .payload = p };
        }
    }

    /// The close code of the next frame, which must be a close.
    pub fn closeCode(r: *Raw) !u16 {
        const f = try r.next();
        try testing.expectEqual(ws.Opcode.close, f.opcode);
        return std.mem.readInt(u16, f.payload[0..2], .big);
    }
};

test "oversized, unmasked and text frames end the connection with their close codes" {
    var server = WebSocketTransport.init(testing.allocator, testing.io, .{});
    defer server.deinit();
    const st = server.transport();
    try st.listen("127.0.0.1:0");
    const cases = [_]struct { opcode: ws.Opcode, len: u64, fin: bool, masked: bool, code: u16, reason: platform.DisconnectReason }{
        .{ .opcode = .binary, .len = platform.max_message_len + 1, .fin = true, .masked = true, .code = ws.CloseCode.too_big, .reason = .too_large },
        .{ .opcode = .binary, .len = 3, .fin = true, .masked = false, .code = ws.CloseCode.protocol_error, .reason = .protocol },
        .{ .opcode = .text, .len = 2, .fin = true, .masked = true, .code = ws.CloseCode.unsupported_data, .reason = .protocol },
        .{ .opcode = .continuation, .len = 1, .fin = true, .masked = true, .code = ws.CloseCode.protocol_error, .reason = .protocol },
    };
    for (cases) |case| {
        const raw = try Raw.open(server.port);
        defer raw.close();
        try raw.handshake();
        const sid = (try nextEvent(st)).payload.net_connected.connection;
        if (case.masked) {
            try raw.frame(case.opcode, case.fin, case.len, "");
        } else {
            var h: [14]u8 = undefined;
            const n = ws.writeHeader(&h, case.fin, case.opcode, case.len, null);
            try raw.write(h[0..n]);
            try raw.write("abc");
        }
        try testing.expectEqual(case.code, try raw.closeCode());
        const e = try nextEvent(st);
        try testing.expectEqual(sid, e.payload.net_disconnected.connection);
        try testing.expectEqual(case.reason, e.payload.net_disconnected.reason);
    }
    // A message in fragments, a ping answered with its payload, and an oversized total.
    const raw = try Raw.open(server.port);
    defer raw.close();
    try raw.handshake();
    _ = try nextEvent(st);
    try raw.frame(.binary, false, 2, "ab");
    try raw.frame(.ping, true, 1, "p");
    try raw.frame(.continuation, true, 1, "c");
    const h = try readHeader(&raw.reader.interface);
    try testing.expectEqual(ws.Opcode.pong, h.opcode);
    try testing.expectEqualStrings("p", try raw.reader.interface.take(1));
    try testing.expectEqualStrings("abc", (try nextEvent(st)).payload.net_received.bytes);
    try raw.frame(.binary, false, platform.max_message_len, "");
    var zeros: [4096]u8 = @splat(0);
    var left: usize = platform.max_message_len;
    while (left > 0) : (left -= @min(left, zeros.len)) try raw.write(zeros[0..@min(left, zeros.len)]);
    try raw.frame(.continuation, true, 1, "x");
    try testing.expectEqual(ws.CloseCode.too_big, try raw.closeCode());
    try testing.expectEqual(platform.DisconnectReason.too_large, (try nextEvent(st)).payload.net_disconnected.reason);
}

test "the same port serves the browser build's files, those built in, and the game's files" {
    const page: Page = .{ .index_html = "<!doctype html>", .script_js = "go();", .module_wasm = "\x00asm" };
    var source = sorz.memory.MemoryAssetSource.init(testing.allocator);
    defer source.deinit();
    try source.add("manifest.json", "{\"format\":1}");
    try source.add("art/sheet.png", "\x89PNG");
    var assets = try served.Assets.read(testing.allocator, source.assetSource());
    defer assets.deinit();
    var server = WebSocketTransport.init(testing.allocator, testing.io, .{ .page = page, .manifest = "{\"mode\":\"native\"}", .assets = &assets });
    defer server.deinit();
    try server.transport().listen("127.0.0.1:0");
    const listing = "{\"files\":[{\"name\":\"tree/art/sheet.png\",\"size\":4},{\"name\":\"tree/manifest.json\",\"size\":12}]}\n";
    const cases = [_]struct { request: []const u8, status: []const u8, body: []const u8, type: ?[]const u8 }{
        // The listing, and the tree's own manifest under tree/; a name percent-encoded or in
        // another case; nothing outside the listed files.
        .{ .request = "GET /assets/manifest.json HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 200", .body = listing, .type = "application/json" },
        .{ .request = "GET /assets/tree/manifest.json HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 200", .body = "{\"format\":1}", .type = "application/json" },
        .{ .request = "GET /assets/tree/art/sheet.png?v=1 HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 200", .body = "\x89PNG", .type = "image/png" },
        .{ .request = "GET /assets/tree%2Fart%2FSHEET.png HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 200", .body = "\x89PNG", .type = "image/png" },
        .{ .request = "GET /assets/tree/../manifest.json HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 404", .body = "not found\n", .type = null },
        .{ .request = "GET /assets/art/sheet.png HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 404", .body = "not found\n", .type = null },
        .{ .request = "GET /assets/ HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 404", .body = "not found\n", .type = null },
        .{ .request = "GET / HTTP/1.1\r\nHost: x\r\n\r\n", .status = "HTTP/1.1 200", .body = "<!doctype html>", .type = "text/html; charset=utf-8" },
        .{ .request = "GET /sorz.js HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 200", .body = "go();", .type = "text/javascript; charset=utf-8" },
        .{ .request = "GET /sorz.wasm HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 200", .body = "\x00asm", .type = "application/wasm" },
        .{ .request = "GET /netplay.json HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 200", .body = "{\"mode\":\"native\"}", .type = "application/json" },
        .{ .request = "GET /../secret HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 404", .body = "not found\n", .type = null },
        .{ .request = "GET /absent.js HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 404", .body = "not found\n", .type = null },
        .{ .request = "POST / HTTP/1.1\r\n\r\n", .status = "HTTP/1.1 405", .body = "GET or HEAD only\n", .type = null },
        .{ .request = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n\r\n", .status = "HTTP/1.1 426", .body = "WebSocket version 13 only\n", .type = null },
        .{ .request = "nonsense\r\n\r\n", .status = "HTTP/1.1 400", .body = "bad request\n", .type = null },
    };
    for (cases) |case| {
        const raw = try Raw.open(server.port);
        defer raw.close();
        try raw.write(case.request);
        const head = try raw.head();
        try testing.expect(std.mem.startsWith(u8, head, case.status));
        if (case.type) |ty| try testing.expectEqualStrings(ty, ws.headerValue(head, "Content-Type").?);
        const len = try std.fmt.parseInt(usize, ws.headerValue(head, "Content-Length").?, 10);
        try testing.expectEqualStrings(case.body, try raw.reader.interface.take(len));
    }
}

test "the relay's calls: text, a wait for events, pings, a connection dropped at once" {
    var server = WebSocketTransport.init(testing.allocator, testing.io, .{ .keepalive_ms = 40, .accept_text = true });
    defer server.deinit();
    const st = server.transport();
    try st.listen("127.0.0.1:0");
    var evs: [2]platform.Event = undefined;
    // No event yet: the wait ends with its timeout.
    try server.wait(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } });
    try testing.expectEqual(@as(usize, 0), st.poll(&evs, 0));

    // A peer that answers nothing is lost after three periods.
    const mute = try Raw.open(server.port);
    defer mute.close();
    try mute.handshake();
    try server.wait(.none);
    const mid = (try nextEvent(st)).payload.net_connected.connection;
    const gone = try nextEvent(st);
    try testing.expectEqual(mid, gone.payload.net_disconnected.connection);
    try testing.expectEqual(platform.DisconnectReason.lost, gone.payload.net_disconnected.reason);

    // A text message; then the pings, which a peer that answers them outlives.
    const live = try Raw.open(server.port);
    defer live.close();
    try live.handshake();
    const lid = (try nextEvent(st)).payload.net_connected.connection;
    try server.sendText(lid, "host");
    const text = try live.next();
    try testing.expectEqual(ws.Opcode.text, text.opcode);
    try testing.expectEqualStrings("host", text.payload);
    var pings: usize = 0;
    while (pings < 5) : (pings += 1) {
        const h = try readHeader(&live.reader.interface);
        try testing.expectEqual(ws.Opcode.ping, h.opcode);
        try testing.expectEqual(@as(u64, 0), h.len);
        try live.message(.pong, "");
    }
    try st.send(lid, "alive");
    try testing.expectEqualStrings("alive", (try live.next()).payload);

    // Text from the peer, told apart from binary messages, in order.
    try live.frame(.text, false, 2, "le");
    try live.frame(.continuation, true, 2, "ft");
    try live.message(.binary, "pad");
    for ([_]struct { bool, []const u8 }{ .{ true, "left" }, .{ false, "pad" } }) |want| {
        var flag: [1]bool = undefined;
        while (server.pollText(evs[0..1], &flag) == 0) try server.wait(.none);
        try testing.expectEqual(want[0], flag[0]);
        try testing.expectEqualStrings(want[1], evs[0].payload.net_received.bytes);
    }

    // Dropped at once: no close frame, the stream ends, and no event follows.
    server.abort(lid);
    try testing.expectError(error.NotConnected, server.sendText(lid, "after"));
    while (live.next()) |f| try testing.expect(f.opcode != .close) else |_| {}
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectEqual(@as(usize, 0), st.poll(&evs, 0));
}

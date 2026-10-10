//! The in-memory transport (DESIGN.md 9): endpoints of one network inside one process, each a
//! `platform.Transport`, so that two games (or two sessions of a test) can play without a socket.
//! It keeps the contract of the native transport: whole messages, in order, bounded queues, the
//! connection's events in order, and the messages of a poll valid until the next.
//!
//! Addresses are the native ones: an endpoint listens at `[ADDRESS:]PORT`, and `ws://ADDRESS:PORT`
//! reaches the endpoint listening at that port, whatever the address. The network's clock is the
//! latest time that any endpoint polled with (the endpoints' clocks may start apart, as a game
//! that restarts does): a message sent at network time t arrives at the first poll at t +
//! `latency_ns` or later. `breakLink` is the test's broken cable.
const std = @import("std");
const platform = @import("../platform.zig");

const ConnectionId = platform.ConnectionId;
const NetError = platform.NetError;

pub const Network = struct {
    allocator: std.mem.Allocator,
    endpoints: std.ArrayList(*Endpoint) = .empty,
    links: std.ArrayList(*Link) = .empty,
    next_id: u32 = 1,
    /// The time a message or a connection takes to reach the peer.
    latency_ns: u64 = 0,
    /// The network's clock: the latest time an endpoint polled with.
    now_ns: u64 = 0,
    /// The bounds of each direction of a connection: the messages sent and not yet polled.
    queue_messages: usize = 256,
    queue_bytes: usize = 1024 * 1024,

    pub fn init(allocator: std.mem.Allocator) Network {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Network) void {
        for (self.endpoints.items) |e| e.destroy();
        self.endpoints.deinit(self.allocator);
        for (self.links.items) |l| self.allocator.destroy(l);
        self.links.deinit(self.allocator);
        self.* = undefined;
    }

    /// A new endpoint of the network, which the network owns.
    pub fn endpoint(self: *Network) error{OutOfMemory}!*Endpoint {
        const e = try self.allocator.create(Endpoint);
        e.* = .{ .network = self };
        errdefer self.allocator.destroy(e);
        try self.endpoints.append(self.allocator, e);
        return e;
    }

    /// Breaks the connection `id` of endpoint `at`, as a cable pulled out: the messages in flight
    /// both ways are lost, and both ends get `net_disconnected` (`lost`) at their next poll.
    pub fn breakLink(self: *Network, at: *Endpoint, id: ConnectionId) void {
        const link, _ = at.find(id) orelse return;
        if (link.state == .closed) return;
        link.state = .closed;
        for (link.ends) |end| {
            end.endpoint.dropEventsOf(end.id);
            end.endpoint.queue(.{ .due_ns = self.now_ns, .id = end.id, .kind = .{ .disconnected = .lost } }) catch {};
        }
    }

    /// Breaks the link of `at`'s connection `id` on `at`'s side alone (its own network failing):
    /// `at`'s game hears the connection lost; the other end hears nothing, what it sends going
    /// nowhere, until its own silence ends it.
    pub fn breakOneSide(self: *Network, at: *Endpoint, id: ConnectionId) void {
        const link, const i = at.find(id) orelse return;
        if (link.state != .open) return;
        link.state = .half_open;
        link.broke_at = i;
        at.dropEventsOf(id);
        at.queue(.{ .due_ns = self.now_ns, .id = id, .kind = .{ .disconnected = .lost } }) catch {};
    }

    fn newId(self: *Network) ConnectionId {
        defer self.next_id += 1;
        return @fromBackingInt(@intCast(self.next_id));
    }
};

const Link = struct {
    ends: [2]End,
    state: enum { open, closed, half_open } = .open,
    /// Half open: the end that saw the link break; the other still takes it for open.
    broke_at: usize = 0,

    const End = struct {
        endpoint: *Endpoint,
        id: ConnectionId,
        /// Whether this end's game has its `net_connected` event: it may send from then on.
        opened: bool = false,
        /// The messages sent to this end and not yet polled, and their bytes.
        pending_messages: usize = 0,
        pending_bytes: usize = 0,
    };
};

const Pending = struct {
    due_ns: u64,
    id: ConnectionId,
    kind: union(enum) {
        connected: bool,
        disconnected: platform.DisconnectReason,
        /// Owned by the endpoint until delivered, then until the next poll.
        received: []u8,
    },
};

pub const Endpoint = struct {
    network: *Network,
    /// The port this endpoint listens at, once it does.
    port: ?u16 = null,
    /// The events for this endpoint, in the order they happened.
    events: std.ArrayList(Pending) = .empty,
    /// The messages given out by the last poll.
    delivered: std.ArrayList([]u8) = .empty,

    fn destroy(self: *Endpoint) void {
        const gpa = self.network.allocator;
        self.releaseDelivered();
        self.delivered.deinit(gpa);
        for (self.events.items) |e| switch (e.kind) {
            .received => |bytes| gpa.free(bytes),
            else => {},
        };
        self.events.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn transport(self: *Endpoint) platform.Transport {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = platform.Transport.VTable{
        .listen = listen,
        .connect = connect,
        .send = send,
        .close = close,
        .poll = poll,
    };

    fn cast(ctx: *anyopaque) *Endpoint {
        return @ptrCast(@alignCast(ctx));
    }

    /// The link and the index of this endpoint's end in it.
    fn find(self: *Endpoint, id: ConnectionId) ?struct { *Link, usize } {
        for (self.network.links.items) |l| {
            for (l.ends, 0..) |end, i| if (end.endpoint == self and end.id == id) return .{ l, i };
        }
        return null;
    }

    fn queue(self: *Endpoint, p: Pending) error{OutOfMemory}!void {
        try self.events.append(self.network.allocator, p);
    }

    fn dropEventsOf(self: *Endpoint, id: ConnectionId) void {
        const gpa = self.network.allocator;
        var kept: usize = 0;
        for (self.events.items) |e| {
            if (e.id == id) {
                switch (e.kind) {
                    .received => |bytes| gpa.free(bytes),
                    else => {},
                }
                continue;
            }
            self.events.items[kept] = e;
            kept += 1;
        }
        self.events.shrinkRetainingCapacity(kept);
        if (self.find(id)) |found| {
            const link, const i = found;
            link.ends[i].pending_messages = 0;
            link.ends[i].pending_bytes = 0;
        }
    }

    fn releaseDelivered(self: *Endpoint) void {
        for (self.delivered.items) |bytes| self.network.allocator.free(bytes);
        self.delivered.clearRetainingCapacity();
    }

    fn listen(ctx: *anyopaque, address: []const u8) NetError!void {
        const self = cast(ctx);
        const a = try platform.parseListenAddress(address);
        if (self.port != null) return error.Busy;
        for (self.network.endpoints.items) |e| if (e.port == a.port) return error.AddressInUse;
        self.port = a.port;
    }

    fn connect(ctx: *anyopaque, url: []const u8) NetError!ConnectionId {
        const self = cast(ctx);
        const net = self.network;
        const u = try platform.WsUrl.parse(url);
        const id = net.newId();
        const due = net.now_ns + net.latency_ns;
        const listener = for (net.endpoints.items) |e| {
            if (e.port == u.port) break e;
        } else {
            try self.queue(.{ .due_ns = due, .id = id, .kind = .{ .disconnected = .refused } });
            return id;
        };
        const link = try net.allocator.create(Link);
        errdefer net.allocator.destroy(link);
        const their_id = net.newId();
        link.* = .{ .ends = .{ .{ .endpoint = self, .id = id }, .{ .endpoint = listener, .id = their_id } } };
        try net.links.append(net.allocator, link);
        // Two ends; each learns of the connection after the latency.
        try self.queue(.{ .due_ns = due, .id = id, .kind = .{ .connected = false } });
        try listener.queue(.{ .due_ns = due, .id = their_id, .kind = .{ .connected = true } });
        return id;
    }

    fn send(ctx: *anyopaque, id: ConnectionId, bytes: []const u8) NetError!void {
        const self = cast(ctx);
        const net = self.network;
        const link, const i = self.find(id) orelse return error.NotConnected;
        // Half open, from the end that did not see it break: sent, and lost.
        if (link.state == .half_open and i != link.broke_at) return;
        if (link.state != .open or !link.ends[i].opened) return error.NotConnected;
        const peer = &link.ends[1 - i];
        if (peer.pending_messages >= net.queue_messages or peer.pending_bytes + bytes.len > net.queue_bytes) return error.QueueFull;
        const copy = try net.allocator.dupe(u8, bytes);
        errdefer net.allocator.free(copy);
        try peer.endpoint.queue(.{ .due_ns = net.now_ns + net.latency_ns, .id = peer.id, .kind = .{ .received = copy } });
        peer.pending_messages += 1;
        peer.pending_bytes += bytes.len;
    }

    fn close(ctx: *anyopaque, id: ConnectionId) void {
        const self = cast(ctx);
        const link, const i = self.find(id) orelse return;
        self.dropEventsOf(id);
        if (link.state != .open) return;
        link.state = .closed;
        // The peer gets what was sent before the close, then the close.
        const peer = link.ends[1 - i];
        peer.endpoint.queue(.{ .due_ns = self.network.now_ns + self.network.latency_ns, .id = peer.id, .kind = .{ .disconnected = .closed } }) catch {};
    }

    fn poll(ctx: *anyopaque, dst: []platform.Event, time_ns: u64) usize {
        const self = cast(ctx);
        const gpa = self.network.allocator;
        self.releaseDelivered();
        const net = self.network;
        net.now_ns = @max(net.now_ns, time_ns);
        var n: usize = 0;
        var taken: usize = 0;
        for (self.events.items) |e| {
            if (n == dst.len or e.due_ns > net.now_ns) break;
            // A message needs room in the delivered list before it is given out.
            if (e.kind == .received) self.delivered.ensureUnusedCapacity(gpa, 1) catch break;
            dst[n] = .{ .time_ns = time_ns, .payload = switch (e.kind) {
                .connected => |incoming| blk: {
                    if (self.find(e.id)) |found| found[0].ends[found[1]].opened = true;
                    break :blk .{ .net_connected = .{ .connection = e.id, .incoming = incoming } };
                },
                .disconnected => |reason| .{ .net_disconnected = .{ .connection = e.id, .reason = reason } },
                .received => |bytes| blk: {
                    self.delivered.appendAssumeCapacity(bytes);
                    if (self.find(e.id)) |found| {
                        const link, const i = found;
                        link.ends[i].pending_messages -= 1;
                        link.ends[i].pending_bytes -= bytes.len;
                    }
                    break :blk .{ .net_received = .{ .connection = e.id, .bytes = bytes } };
                },
            } };
            n += 1;
            taken += 1;
        }
        const rest = self.events.items.len - taken;
        std.mem.copyForwards(Pending, self.events.items[0..rest], self.events.items[taken..]);
        self.events.shrinkRetainingCapacity(rest);
        return n;
    }
};

// --- tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn pollAll(t: platform.Transport, buf: []platform.Event, time_ns: u64) []platform.Event {
    return buf[0..t.poll(buf, time_ns)];
}

test "a connection opens both ways, carries whole messages in order and closes" {
    var net = Network.init(testing.allocator);
    defer net.deinit();
    const host = (try net.endpoint()).transport();
    const guest = (try net.endpoint()).transport();
    try host.listen("7000");
    try testing.expectError(error.Busy, host.listen("7001"));
    const g = try guest.connect("ws://localhost:7000");
    var buf: [8]platform.Event = undefined;
    // Not open before its event.
    try testing.expectError(error.NotConnected, guest.send(g, "early"));
    var ev = pollAll(host, &buf, 0);
    try testing.expectEqual(@as(usize, 1), ev.len);
    const h = ev[0].payload.net_connected.connection;
    try testing.expect(ev[0].payload.net_connected.incoming);
    ev = pollAll(guest, &buf, 0);
    try testing.expectEqual(g, ev[0].payload.net_connected.connection);
    try testing.expect(!ev[0].payload.net_connected.incoming);

    try guest.send(g, "one");
    try guest.send(g, "two");
    var scratch: [3]u8 = "tri".*;
    try guest.send(g, &scratch);
    // The transport copied the message: the sender's buffer is free again.
    scratch[0] = 'X';
    ev = pollAll(host, &buf, 0);
    try testing.expectEqual(@as(usize, 3), ev.len);
    try testing.expectEqualStrings("one", ev[0].payload.net_received.bytes);
    try testing.expectEqualStrings("two", ev[1].payload.net_received.bytes);
    try testing.expectEqualStrings("tri", ev[2].payload.net_received.bytes);
    try testing.expectEqual(h, ev[2].payload.net_received.connection);

    // A close reaches the peer after the messages sent before it; the closer gets no event.
    try host.send(h, "bye");
    host.close(h);
    try testing.expectError(error.NotConnected, host.send(h, "late"));
    try testing.expectEqual(@as(usize, 0), pollAll(host, &buf, 0).len);
    ev = pollAll(guest, &buf, 0);
    try testing.expectEqual(@as(usize, 2), ev.len);
    try testing.expectEqualStrings("bye", ev[0].payload.net_received.bytes);
    try testing.expectEqual(platform.DisconnectReason.closed, ev[1].payload.net_disconnected.reason);
}

test "no listener refuses; the queue is bounded; a broken link loses what is in flight" {
    var net = Network.init(testing.allocator);
    defer net.deinit();
    net.queue_messages = 2;
    const a_end = try net.endpoint();
    const a = a_end.transport();
    const b = (try net.endpoint()).transport();
    var buf: [8]platform.Event = undefined;
    const refused = try b.connect("ws://h:9");
    var ev = pollAll(b, &buf, 0);
    try testing.expectEqual(refused, ev[0].payload.net_disconnected.connection);
    try testing.expectEqual(platform.DisconnectReason.refused, ev[0].payload.net_disconnected.reason);
    try testing.expectError(error.InvalidAddress, b.connect("h:9"));

    try a.listen("9");
    const bid = try b.connect("ws://h:9");
    const aid = pollAll(a, &buf, 0)[0].payload.net_connected.connection;
    _ = pollAll(b, &buf, 0);
    try b.send(bid, "1");
    try b.send(bid, "2");
    try testing.expectError(error.QueueFull, b.send(bid, "3"));
    var big: [platform.max_message_len + 1]u8 = undefined;
    try testing.expectError(error.MessageTooLarge, b.send(bid, &big));
    // A poll makes room.
    try testing.expectEqual(@as(usize, 2), pollAll(a, &buf, 0).len);
    try b.send(bid, "3");
    try a.send(aid, "x");
    net.breakLink(a_end, aid);
    ev = pollAll(a, &buf, 0);
    try testing.expectEqual(@as(usize, 1), ev.len);
    try testing.expectEqual(platform.DisconnectReason.lost, ev[0].payload.net_disconnected.reason);
    ev = pollAll(b, &buf, 0);
    try testing.expectEqual(@as(usize, 1), ev.len);
    try testing.expectEqual(platform.DisconnectReason.lost, ev[0].payload.net_disconnected.reason);
    try testing.expectError(error.NotConnected, b.send(bid, "4"));
}

test "latency delays connections and messages by the endpoints' clocks" {
    var net = Network.init(testing.allocator);
    defer net.deinit();
    net.latency_ns = 50;
    const a = (try net.endpoint()).transport();
    const b = (try net.endpoint()).transport();
    var buf: [4]platform.Event = undefined;
    try a.listen("1");
    _ = try b.connect("ws://x:1");
    try testing.expectEqual(@as(usize, 0), pollAll(a, &buf, 49).len);
    const aid = pollAll(a, &buf, 50)[0].payload.net_connected.connection;
    try a.send(aid, "m");
    try testing.expectEqual(@as(usize, 1), pollAll(b, &buf, 60).len); // the connection
    try testing.expectEqual(@as(usize, 0), pollAll(b, &buf, 99).len);
    try testing.expectEqualStrings("m", pollAll(b, &buf, 100)[0].payload.net_received.bytes);
}

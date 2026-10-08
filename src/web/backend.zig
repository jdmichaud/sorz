//! The browser backend: the platform contract (`platform.Platform`) over the functions of the
//! page (`host.zig`). The page reports each device event through the exports of the module;
//! `poll_events` gives these events to the game in order. The rules follow the native host where
//! a browser permits it: the game reads the mouse as relative counts, so the pointer is locked
//! while the game has it, and a capture change is an event.
const std = @import("std");
const sorz = @import("sorz");
const platform = sorz.platform;
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const gamepad = @import("gamepad.zig");

pub const WebBackend = struct {
    allocator: std.mem.Allocator,
    host: *const Host,
    started: bool = false,
    capabilities: platform.Capabilities = .{},
    resolution: ?platform.Size = null,
    frames_presented: u64 = 0,

    /// The device events that the page reported and the game has not polled yet.
    events: std.ArrayList(platform.Event) = .empty,
    next_event: usize = 0,
    last_event_ns: u64 = 0,
    /// The messages that the last poll gave the game, which it may read until the next poll
    /// (DESIGN.md 3.7). The backend owns them, and the messages still in `events`.
    delivered: std.ArrayList([]u8) = .empty,

    /// Whether the game asked for the relative mouse. While it did and the page has no pointer
    /// lock, motion is not given to the game: the desktop pointer is not the game's.
    relative_wanted: bool = false,
    /// Whether the page has the pointer lock.
    captured: bool = false,
    /// The browser's id of each gamepad, by its index.
    pads: [8]struct { text: [128]u8 = @splat(0), len: u8 = 0 } = @splat(.{}),

    audio: Audio = .{},

    pub const Audio = struct {
        open: bool = false,
        format: platform.AudioFormat = .{},
        /// All frames that `audio_queue` accepted. `played` is computed from this count and the
        /// frames that the page still holds.
        accepted_frames: u64 = 0,
        /// The frames that `audio_clear` discarded. They are never reported as played.
        discarded_frames: u64 = 0,
    };

    /// The largest render resolution that the backend accepts, in each dimension.
    pub const max_dimension: u32 = 16384;

    pub fn init(allocator: std.mem.Allocator, host: *const Host) WebBackend {
        return .{ .allocator = allocator, .host = host };
    }

    pub fn deinit(self: *WebBackend) void {
        if (self.audio.open) self.host.audio_close();
        self.freeDelivered();
        self.delivered.deinit(self.allocator);
        for (self.events.items[self.next_event..]) |e| switch (e.payload) {
            .net_received => |m| self.allocator.free(m.bytes),
            else => {},
        };
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn asPlatform(self: *WebBackend) platform.Platform {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = platform.Platform.VTable{
        .start = start,
        .set_resolution = setResolution,
        .present = present,
        .poll_events = pollEvents,
        .now_ns = nowNs,
        .audio_open = audioOpen,
        .audio_queue = audioQueue,
        .audio_status = audioStatus,
        .audio_clear = audioClear,
        .audio_close = audioClose,
        .set_relative_mouse = setRelativeMouse,
        .controller_info = controllerInfo,
        .net_listen = netListen,
        .net_connect = netConnect,
        .net_send = netSend,
        .net_close = netClose,
    };

    fn cast(ctx: *anyopaque) *WebBackend {
        return @ptrCast(@alignCast(ctx));
    }

    fn start(ctx: *anyopaque) platform.PlatformError!platform.Capabilities {
        const self = cast(ctx);
        if (!self.started) {
            self.started = true;
            // The page polls the Gamepad API and reports each pad's changes.
            self.capabilities = .{ .video = true, .audio = true, .controllers = true };
        }
        return self.capabilities;
    }

    // --- time --------------------------------------------------------------------------------

    fn nowNs(ctx: *anyopaque) u64 {
        return cast(ctx).elapsedNs();
    }

    fn elapsedNs(self: *const WebBackend) u64 {
        const ms = self.host.now_ms();
        return if (ms > 0) @intFromFloat(ms * std.time.ns_per_ms) else 0;
    }

    /// The time of a new event: now, but never earlier than the previous event, so the delivery
    /// order and the time stamps agree.
    fn eventTime(self: *WebBackend) u64 {
        const t = @max(self.elapsedNs(), self.last_event_ns);
        self.last_event_ns = t;
        return t;
    }

    // --- presentation ------------------------------------------------------------------------

    fn setResolution(ctx: *anyopaque, width: u32, height: u32) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.InvalidResolution;
        // An unchanged resolution is not a mode change. The page resizes nothing.
        if (self.resolution) |current| {
            if (current.width == width and current.height == height) return;
        }
        self.host.set_resolution(width, height);
        self.resolution = .{ .width = width, .height = height };
    }

    fn present(ctx: *anyopaque, frame: platform.RgbaFrame) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        frame.validate() catch return error.InvalidFrame;
        const res = self.resolution orelse return error.InvalidResolution;
        if (frame.width != res.width or frame.height != res.height) return error.InvalidFrame;
        const stride = std.math.cast(u32, frame.stride) orelse return error.InvalidFrame;
        // The page copies the pixels into its canvas during the call and keeps no reference.
        self.host.present(frame.pixels.ptr, frame.width, frame.height, stride);
        self.frames_presented += 1;
    }

    // --- events ------------------------------------------------------------------------------

    fn pollEvents(ctx: *anyopaque, dst: []platform.Event) usize {
        const self = cast(ctx);
        // The messages of the previous poll: the game is done with them.
        self.freeDelivered();
        var n: usize = 0;
        while (n < dst.len and self.next_event < self.events.items.len) : (self.next_event += 1) {
            const e = self.events.items[self.next_event];
            if (e.payload == .net_received) {
                // Room first: a message that cannot be kept for the game waits for the next poll.
                self.delivered.ensureUnusedCapacity(self.allocator, 1) catch break;
                self.delivered.appendAssumeCapacity(@constCast(e.payload.net_received.bytes));
            }
            dst[n] = e;
            n += 1;
        }
        if (self.next_event == self.events.items.len and self.next_event != 0) {
            self.events.clearRetainingCapacity();
            self.next_event = 0;
        }
        return n;
    }

    fn push(self: *WebBackend, payload: platform.Event.Payload) void {
        self.events.append(self.allocator, .{ .time_ns = self.eventTime(), .payload = payload }) catch {};
    }

    fn freeDelivered(self: *WebBackend) void {
        for (self.delivered.items) |bytes| self.allocator.free(bytes);
        self.delivered.clearRetainingCapacity();
    }

    pub fn keyEvent(self: *WebBackend, key: platform.Key, down: bool, repeat: bool) void {
        const event: platform.Event.KeyEvent = .{ .key = key, .repeat = repeat };
        self.push(if (down) .{ .key_down = event } else .{ .key_up = event });
    }

    /// Text that a key typed, as UTF-8. It is split into `TextInput` events of at most eight
    /// bytes, only between code points.
    pub fn textEvent(self: *WebBackend, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            var chunk: platform.Event.TextInput = .{};
            while (i < text.len) {
                const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const len = @min(@as(usize, seq), text.len - i);
                if (chunk.len + len > chunk.bytes.len) break;
                @memcpy(chunk.bytes[chunk.len..][0..len], text[i..][0..len]);
                chunk.len += @intCast(len);
                i += len;
            }
            self.push(.{ .text_input = chunk });
        }
    }

    /// One pointer motion: `dx` and `dy` are the relative counts, `x` and `y` the position in
    /// page pixels. The game does not get the motion of a pointer that it asked for and does not
    /// have.
    pub fn motionEvent(self: *WebBackend, dx: i32, dy: i32, x: i32, y: i32) void {
        if (self.relative_wanted and !self.captured) return;
        self.push(.{ .mouse_motion = .{ .dx = dx, .dy = dy, .x = x, .y = y } });
    }

    pub fn buttonEvent(self: *WebBackend, button: platform.MouseButton, down: bool, x: i32, y: i32) void {
        const event: platform.Event.MouseButtonEvent = .{ .button = button, .x = x, .y = y };
        self.push(if (down) .{ .mouse_button_down = event } else .{ .mouse_button_up = event });
    }

    pub fn wheelEvent(self: *WebBackend, dx: i32, dy: i32) void {
        self.push(.{ .mouse_wheel = .{ .dx = dx, .dy = dy } });
    }

    pub fn focusEvent(self: *WebBackend, gained: bool) void {
        self.push(if (gained) .focus_gained else .focus_lost);
    }

    /// The page reports a change of the pointer lock.
    pub fn captureEvent(self: *WebBackend, captured: bool) void {
        if (captured == self.captured) return;
        self.captured = captured;
        self.push(.{ .capture_changed = captured });
    }

    pub fn resizedEvent(self: *WebBackend, width: u32, height: u32) void {
        self.push(.{ .drawable_resized = .{ .width = width, .height = height } });
    }

    /// A gamepad came, `text` the browser's id of it: its model's key, and its name.
    pub fn controllerAdded(self: *WebBackend, id: platform.ControllerId, text: []const u8) void {
        const i = @backingInt(id);
        if (i < self.pads.len) {
            const p = &self.pads[i];
            p.len = @intCast(@min(text.len, p.text.len));
            @memcpy(p.text[0..p.len], text[0..p.len]);
        }
        self.push(.{ .controller_added = id });
    }

    pub fn controllerRemoved(self: *WebBackend, id: platform.ControllerId) void {
        self.push(.{ .controller_removed = id });
    }

    pub fn controllerButton(self: *WebBackend, id: platform.ControllerId, button: platform.ControllerButton, down: bool) void {
        const event: platform.Event.ControllerButtonEvent = .{ .controller = id, .button = button };
        self.push(if (down) .{ .controller_button_down = event } else .{ .controller_button_up = event });
    }

    pub fn controllerAxis(self: *WebBackend, id: platform.ControllerId, axis: platform.ControllerAxis, value: i16) void {
        self.push(.{ .controller_axis = .{ .controller = id, .axis = axis, .value = value } });
    }

    pub fn quitEvent(self: *WebBackend) void {
        self.push(.quit);
    }

    // --- audio -------------------------------------------------------------------------------

    fn audioOpen(ctx: *anyopaque, requested: platform.AudioFormat) platform.PlatformError!platform.AudioFormat {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        if (requested.channels == 0 or requested.channels > 2 or requested.sample_rate == 0) return error.Unsupported;
        if (self.audio.open) self.host.audio_close();
        self.audio = .{};
        const rate = self.host.audio_open(requested.sample_rate, requested.channels);
        if (rate == 0) return error.DeviceFailure;
        self.audio = .{ .open = true, .format = .{ .channels = requested.channels, .sample_rate = rate } };
        return self.audio.format;
    }

    fn queuedFrames(self: *const WebBackend) u64 {
        const queued = self.host.audio_queued();
        return if (queued > 0) @intFromFloat(queued) else 0;
    }

    fn audioQueue(ctx: *anyopaque, samples: []const i16) platform.PlatformError!usize {
        const self = cast(ctx);
        if (!self.audio.open) return error.DeviceFailure;
        const channels: usize = self.audio.format.channels;
        const offered = std.math.cast(u32, samples.len / channels) orelse std.math.maxInt(u32);
        if (offered == 0) return 0;
        const accepted = @min(self.host.audio_queue(samples.ptr, offered, @intCast(channels)), offered);
        self.audio.accepted_frames += accepted;
        return accepted;
    }

    fn audioStatus(ctx: *anyopaque) platform.AudioStatus {
        const self = cast(ctx);
        if (!self.audio.open) return .{};
        const queued = self.queuedFrames();
        const state: host_mod.AudioState = @fromBackingInt(self.host.audio_state());
        return .{
            .queued_frames = queued,
            .played_frames = self.audio.accepted_frames -| self.audio.discarded_frames -| queued,
            .running = state == .running,
            .suspended = state != .running,
        };
    }

    fn audioClear(ctx: *anyopaque) void {
        const self = cast(ctx);
        if (!self.audio.open) return;
        self.audio.discarded_frames += self.queuedFrames();
        self.host.audio_clear();
    }

    fn audioClose(ctx: *anyopaque) void {
        const self = cast(ctx);
        if (self.audio.open) self.host.audio_close();
        self.audio = .{};
    }

    // --- capture -----------------------------------------------------------------------------

    /// Requests the pointer lock. A `capture_changed` event reports the state that the page
    /// really has. A browser locks the pointer only after a click, so the lock often comes later,
    /// with its own event.
    /// A gamepad's id as the browser gave it: its model's key; its name taken from it
    /// (gamepad.zig `nameOf`).
    fn controllerInfo(ctx: *anyopaque, id: platform.ControllerId) ?platform.ControllerInfo {
        const self = cast(ctx);
        const i = @backingInt(id);
        if (i >= self.pads.len) return null;
        const text = self.pads[i].text[0..self.pads[i].len];
        return .{ .model = text, .name = gamepad.nameOf(text) };
    }

    fn setRelativeMouse(ctx: *anyopaque, enabled: bool) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        self.relative_wanted = enabled;
        self.captured = self.host.set_relative_mouse(@intFromBool(enabled)) != 0;
        self.push(.{ .capture_changed = self.captured });
    }

    // --- transport ---------------------------------------------------------------------------

    // Network play's transport (DESIGN.md 9, PLAN A1) over the page's WebSockets: the page opens
    // them, sends and closes, and reports each connection's opening, messages and end through
    // the module's `gp_net_*` exports, which call the functions below.

    /// A page cannot listen: a relay's client arrives on the host's page as a connection that the
    /// page reports (`netConnected` with `incoming`), for a session started without an address.
    fn netListen(_: *anyopaque, _: []const u8) platform.NetError!void {
        return error.Unsupported;
    }

    fn netConnect(ctx: *anyopaque, url: []const u8) platform.NetError!platform.ConnectionId {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        _ = platform.WsUrl.parse(url) catch return error.InvalidAddress;
        const id = self.host.net_connect(url.ptr, @intCast(url.len));
        if (id == 0) return error.Unsupported;
        return @fromBackingInt(id);
    }

    fn netSend(ctx: *anyopaque, connection: platform.ConnectionId, bytes: []const u8) platform.NetError!void {
        const self = cast(ctx);
        if (bytes.len > platform.max_message_len) return error.MessageTooLarge;
        const result: host_mod.SendResult = @fromBackingInt(self.host.net_send(@backingInt(connection), bytes.ptr, @intCast(bytes.len)));
        return switch (result) {
            .sent => {},
            .queue_full => error.QueueFull,
            .too_large => error.MessageTooLarge,
            else => error.NotConnected,
        };
    }

    fn netClose(ctx: *anyopaque, connection: platform.ConnectionId) void {
        const self = cast(ctx);
        self.host.net_close(@backingInt(connection));
    }

    /// The page opened a connection: one the game asked for, or (`incoming`) a relay's client.
    pub fn netConnected(self: *WebBackend, id: u32, incoming: bool) void {
        self.push(.{ .net_connected = .{ .connection = @fromBackingInt(id), .incoming = incoming } });
    }

    /// A connection ended, for a reason numbered as `platform.DisconnectReason` numbers them.
    pub fn netDisconnected(self: *WebBackend, id: u32, reason: u32) void {
        const r: platform.DisconnectReason = @fromBackingInt(@as(u8, @intCast(@min(reason, 255))));
        self.push(.{ .net_disconnected = .{ .connection = @fromBackingInt(id), .reason = r } });
    }

    /// A whole message: `bytes` (from the backend's allocator) become the backend's, and the game
    /// reads them from the poll that gives the event until the next one. A message that cannot be
    /// kept is freed, and the connection's order is then broken: the session's checks see it.
    pub fn netReceived(self: *WebBackend, id: u32, bytes: []u8) void {
        self.events.append(self.allocator, .{
            .time_ns = self.eventTime(),
            .payload = .{ .net_received = .{ .connection = @fromBackingInt(id), .bytes = bytes } },
        }) catch self.allocator.free(bytes);
    }
};

// --- tests -------------------------------------------------------------------------------------

const testing = std.testing;

/// A page for the tests: a clock, a canvas and an audio output that it counts.
const FakePage = struct {
    var clock_ms: f64 = 0;
    var canvas: platform.Size = .{ .width = 0, .height = 0 };
    var presented: u64 = 0;
    var first_byte: u8 = 0;
    var audio_rate: u32 = 44100;
    var queued: f64 = 0;
    var cleared: u32 = 0;
    var room: u32 = std.math.maxInt(u32);
    var lock_granted: bool = false;

    fn reset() void {
        clock_ms = 0;
        canvas = .{ .width = 0, .height = 0 };
        presented = 0;
        audio_rate = 44100;
        queued = 0;
        cleared = 0;
        room = std.math.maxInt(u32);
        lock_granted = false;
    }
    fn nowMs() f64 {
        return clock_ms;
    }
    fn setResolution(w: u32, h: u32) void {
        canvas = .{ .width = w, .height = h };
    }
    fn present(pixels: [*]const u8, _: u32, _: u32, _: u32) void {
        first_byte = pixels[0];
        presented += 1;
    }
    fn audioOpen(_: u32, _: u32) u32 {
        return audio_rate;
    }
    fn audioQueue(_: [*]const i16, frames: u32, _: u32) u32 {
        const n = @min(frames, room);
        queued += @floatFromInt(n);
        return n;
    }
    fn audioQueued() f64 {
        return queued;
    }
    fn audioState() u32 {
        return @backingInt(host_mod.AudioState.running);
    }
    fn audioClear() void {
        cleared += 1;
        queued = 0;
    }
    fn noop() void {}
    fn relative(enabled: u32) u32 {
        return @intFromBool(enabled != 0 and lock_granted);
    }
    fn log(_: u32, _: [*]const u8, _: u32) void {}

    const host = Host{
        .now_ms = nowMs,
        .set_resolution = setResolution,
        .present = present,
        .audio_open = audioOpen,
        .audio_queue = audioQueue,
        .audio_queued = audioQueued,
        .audio_state = audioState,
        .audio_clear = audioClear,
        .audio_close = noop,
        .set_relative_mouse = relative,
        .log = log,
        .storage_save = storageSave,
        .storage_delete = storageDelete,
        .net_connect = netConnect,
        .net_send = netSend,
        .net_close = netClose,
    };
    fn storageSave(_: [*]const u8, _: u32, _: [*]const u8, _: u32) u32 {
        return 1;
    }
    fn storageDelete(_: [*]const u8, _: u32) u32 {
        return 1;
    }

    // A page's WebSockets: the connections it opened, what it sent, and what it closed.
    var next_connection: u32 = 1;
    var sent_bytes: usize = 0;
    var send_result: host_mod.SendResult = .sent;
    var closed: u32 = 0;
    fn netConnect(_: [*]const u8, _: u32) u32 {
        next_connection += 1;
        return next_connection - 1;
    }
    fn netSend(_: u32, _: [*]const u8, len: u32) u32 {
        if (send_result == .sent) sent_bytes += len;
        return @backingInt(send_result);
    }
    fn netClose(id: u32) void {
        closed = id;
    }
};

test "events come in order with ordered time stamps, and motion needs the pointer" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();

    FakePage.clock_ms = 10;
    backend.keyEvent(.a, true, false);
    backend.textEvent("a");
    FakePage.clock_ms = 5; // A clock that goes back does not reorder the events.
    backend.keyEvent(.a, false, false);
    try p.setRelativeMouse(true);
    backend.motionEvent(3, 4, 10, 10); // Wanted, not captured: dropped.
    backend.captureEvent(true);
    backend.motionEvent(5, -6, 20, 30);
    backend.buttonEvent(.right, true, 20, 30);

    var events: [16]platform.Event = undefined;
    const n = p.pollEvents(&events);
    try testing.expectEqual(@as(usize, 7), n);
    try testing.expectEqual(platform.Key.a, events[0].payload.key_down.key);
    try testing.expectEqualStrings("a", events[1].payload.text_input.slice());
    try testing.expectEqual(platform.Key.a, events[2].payload.key_up.key);
    try testing.expect(events[2].time_ns >= events[1].time_ns);
    try testing.expect(!events[3].payload.capture_changed);
    try testing.expect(events[4].payload.capture_changed);
    try testing.expectEqual(@as(i32, 5), events[5].payload.mouse_motion.dx);
    try testing.expectEqual(platform.MouseButton.right, events[6].payload.mouse_button_down.button);
    try testing.expectEqual(@as(usize, 0), p.pollEvents(&events));
}

test "long text splits between code points" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    backend.textEvent("abcdefghé!");
    var events: [4]platform.Event = undefined;
    var p = backend.asPlatform();
    const n = p.pollEvents(&events);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("abcdefgh", events[0].payload.text_input.slice());
    try testing.expectEqualStrings("é!", events[1].payload.text_input.slice());
}

test "presentation checks the frame against the resolution" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    var p = backend.asPlatform();
    var pixels: [4 * 3 * 4]u8 = @splat(7);
    try testing.expectError(error.NotStarted, p.present(.{ .width = 4, .height = 3, .stride = 16, .pixels = &pixels }));
    _ = try p.start();
    try testing.expectError(error.InvalidResolution, p.present(.{ .width = 4, .height = 3, .stride = 16, .pixels = &pixels }));
    try p.setResolution(4, 3);
    try testing.expectEqual(@as(u32, 4), FakePage.canvas.width);
    try p.present(.{ .width = 4, .height = 3, .stride = 16, .pixels = &pixels });
    try testing.expectEqual(@as(u64, 1), FakePage.presented);
    try testing.expectEqual(@as(u8, 7), FakePage.first_byte);
    try testing.expectError(error.InvalidFrame, p.present(.{ .width = 2, .height = 3, .stride = 8, .pixels = &pixels }));
    try testing.expectError(error.InvalidResolution, p.setResolution(0, 3));
}

test "audio counts accepted, played and discarded frames as the native host does" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    const samples: [200]i16 = @splat(0);
    try testing.expectError(error.DeviceFailure, p.audioQueue(&samples));
    FakePage.audio_rate = 48000;
    const got = try p.audioOpen(.{ .channels = 2, .sample_rate = 44100 });
    try testing.expectEqual(@as(u32, 48000), got.sample_rate);
    try testing.expectEqual(@as(usize, 100), try p.audioQueue(&samples));
    FakePage.room = 30;
    try testing.expectEqual(@as(usize, 30), try p.audioQueue(&samples));
    // The page played 70 of the 130 frames.
    FakePage.queued = 60;
    var status = p.audioStatus();
    try testing.expectEqual(@as(u64, 60), status.queued_frames);
    try testing.expectEqual(@as(u64, 70), status.played_frames);
    try testing.expect(status.running);
    p.audioClear();
    status = p.audioStatus();
    try testing.expectEqual(@as(u64, 0), status.queued_frames);
    try testing.expectEqual(@as(u64, 70), status.played_frames);
    p.audioClose();
    try testing.expect(!p.audioStatus().running);
}

test "gamepads come as controller events, in order, and the game's pads follow them" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    var p = backend.asPlatform();
    try testing.expect((try p.start()).controllers);
    const id: platform.ControllerId = @fromBackingInt(1);
    backend.controllerAdded(id, "2dc8-3106-8BitDo Receiver");
    // The platform names it: the browser's id its model, its name from it.
    const info = p.controllerInfo(id).?;
    try testing.expectEqualStrings("2dc8-3106-8BitDo Receiver", info.model);
    try testing.expectEqualStrings("8BitDo Receiver", info.name);
    backend.controllerButton(id, .start, true);
    backend.controllerAxis(id, .left_x, 32767);
    backend.controllerButton(id, .start, false);
    backend.controllerRemoved(id);
    var events: [8]platform.Event = undefined;
    const n = p.pollEvents(&events);
    try testing.expectEqual(@as(usize, 5), n);
    var controls: sorz.input.Controls = .{};
    _ = controls.handle(events[0]);
    _ = controls.handle(events[1]);
    _ = controls.handle(events[2]);
    try testing.expect(controls.pads().pad1.start and controls.pads().pad1.right);
    _ = controls.handle(events[3]);
    try testing.expect(!controls.pads().pad1.start);
    _ = controls.handle(events[4]);
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(controls.pads().pad1)));
}

test "the transport: the page's connections, their messages until the next poll, their ends" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    var p = backend.asPlatform();
    try testing.expectError(error.NotStarted, p.netConnect("ws://127.0.0.1:7000/"));
    _ = try p.start();
    try testing.expectError(error.Unsupported, p.netListen("7000"));
    try testing.expectError(error.InvalidAddress, p.netConnect("http://127.0.0.1:7000/"));
    try testing.expectError(error.InvalidAddress, p.netConnect("ws://127.0.0.1/"));
    const id = try p.netConnect("ws://127.0.0.1:7000/");

    // Sending: the page's answers, and the length checked before the page sees it.
    FakePage.sent_bytes = 0;
    FakePage.send_result = .sent;
    try p.netSend(id, "abc");
    try testing.expectEqual(@as(usize, 3), FakePage.sent_bytes);
    const big = try testing.allocator.alloc(u8, platform.max_message_len + 1);
    defer testing.allocator.free(big);
    try testing.expectError(error.MessageTooLarge, p.netSend(id, big));
    FakePage.send_result = .queue_full;
    try testing.expectError(error.QueueFull, p.netSend(id, "abc"));
    FakePage.send_result = .not_connected;
    try testing.expectError(error.NotConnected, p.netSend(id, "abc"));
    FakePage.send_result = .sent;

    // The page's reports, in order; a message stays valid until the next poll, which frees it.
    const raw = @backingInt(id);
    backend.netConnected(raw, false);
    const message = try testing.allocator.dupe(u8, "hello");
    backend.netReceived(raw, message);
    backend.netDisconnected(raw, @backingInt(platform.DisconnectReason.lost));
    var events: [2]platform.Event = undefined;
    try testing.expectEqual(@as(usize, 2), p.pollEvents(&events));
    try testing.expect(!events[0].payload.net_connected.incoming);
    try testing.expectEqualStrings("hello", events[1].payload.net_received.bytes);
    try testing.expectEqual(@as(usize, 1), p.pollEvents(&events));
    try testing.expectEqual(platform.DisconnectReason.lost, events[0].payload.net_disconnected.reason);
    p.netClose(id);
    try testing.expectEqual(raw, FakePage.closed);

    // A message the game never polled is freed with the backend (the test's allocator checks).
    backend.netReceived(raw, try testing.allocator.dupe(u8, "left behind"));
}

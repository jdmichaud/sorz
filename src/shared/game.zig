//! The game as the hosts run it (DESIGN.md 3.1): its state from power-on (`State`, the scenes of
//! scene.zig), the players' controls (input.zig), the picture it presents and the sound it queues,
//! and the settings record read at the start. The hosts own the platform and the providers; the
//! game owns what happens next.
//!
//! Time: the game advances by display ticks, the console's frame, 59.92 a second (DESIGN.md
//! 10.2). While the platform plays sound, the game runs the ticks that keep the device's queue a
//! few ticks long, so the sound keeps the device's time and never breaks; otherwise it runs the
//! ticks that the platform's clock makes due. The agent host runs one tick per update
//! (`Pacing.per_update`), so that its frames are the ticks.
//!
//! For now the game is a test pattern and silence: what the hosts, network play and the checks run
//! on until the content (PLAN item 06), the renderer (07), the scenes (08) and the sound (09)
//! take their places. TODO(PLAN item 06): the content loads from `assets` at the start.
//!
//! Settings (DESIGN.md 7): the record, read from the storage at the start, gives the controls'
//! layout, the sound's volume and the SDL host's window. A damaged record is repaired and kept
//! aside (settings/record.zig), and `notice` says so for the host and, once the game draws text,
//! the player (TODO(PLAN item 19): the settings screen and its notices).
const std = @import("std");
const platform = @import("platform.zig");
const input = @import("input.zig");
const settings_mod = @import("settings/root.zig");
const canonical = @import("canonical.zig");
const scene = @import("scene.zig");
const picture = @import("picture.zig");
const sound_out = @import("sound_out.zig");

pub const page_width = picture.width;
pub const page_height = picture.height;

pub const UpdateResult = enum { running, finished };

/// How the updates run ticks: as the sound or the clock make them due (the game as the player
/// runs it), or one each (the agent host's).
pub const Pacing = enum { clock, per_update };

/// What the game has to tell about its settings record.
pub const Notice = enum {
    none,
    /// The record was damaged: the rest was kept, and the damaged one kept aside.
    damaged,
    /// The storage did not give the record: the defaults stand.
    unreadable,
    /// The record could not be written.
    not_saved,
};

/// Everything that decides what the game does next. Its canonical form (canonical.zig) is what
/// the tests and network play compare: the same pads from power-on give the same state on every
/// platform.
pub const State = struct {
    /// Display ticks since power-on.
    tick: u32 = 0,
    scenes: scene.Stack = .{},

    /// One display tick, with the pads of that tick.
    pub fn step(self: *State, pads: input.Pads) void {
        self.scenes.tick(pads);
        self.tick +%= 1;
    }

    pub fn hash(self: *const State) u64 {
        return canonical.hash(State, self);
    }
};

/// The sound queue's length that the game keeps, in ticks, and the most ticks an update runs (a
/// longer stall is dropped, not caught up).
const queue_ticks = 3;
const max_ticks_per_update = 4;

pub const Game = struct {
    allocator: std.mem.Allocator,
    /// The game's files, which the content will load from (PLAN item 06), and the saves.
    assets: ?platform.AssetSource,
    storage: ?platform.Storage,
    state: State = .{},
    controls: input.Controls = .{},
    settings: settings_mod.Settings = .{},
    notice: Notice = .none,
    pacing: Pacing = .clock,
    started: bool = false,
    finished: bool = false,
    /// The sound, while the platform has an audio device.
    sound: ?sound_out.SoundOut = null,
    /// The clock's origin and the ticks run since, while the clock paces the game.
    clock_base_ns: u64 = 0,
    clock_ticks: u64 = 0,
    /// The host applies the settings' volume itself (the browser's page, with its gain): the game
    /// then queues its sound at full volume.
    host_volume: bool = false,
    /// Room for a tick's frames at the settings' volume.
    volume_buffer: []i16 = &.{},
    pic: picture.Picture,
    drawn: scene.TestPattern.Drawn = .{},
    /// Whether the picture may have changed since it was last drawn (a tick ran).
    redraw: bool = true,

    update_count: u64 = 0,
    frames_presented: u64 = 0,
    events_consumed: u64 = 0,
    saves_written: u64 = 0,
    loads_done: u64 = 0,

    /// The settings are read from `storage` (the defaults without one).
    pub fn init(allocator: std.mem.Allocator, assets: ?platform.AssetSource, storage: ?platform.Storage) error{OutOfMemory}!Game {
        var game: Game = .{ .allocator = allocator, .assets = assets, .storage = storage, .pic = try .init(allocator) };
        if (storage) |s| game.loadSettings(s);
        return game;
    }

    pub fn deinit(self: *Game) void {
        if (self.sound) |*s| s.deinit(self.allocator);
        self.allocator.free(self.volume_buffer);
        self.pic.deinit(self.allocator);
        self.* = undefined;
    }

    /// The settings from the storage: a damaged record is told (settings/record.zig).
    fn loadSettings(self: *Game, storage: platform.Storage) void {
        const loaded = settings_mod.record.load(self.allocator, storage);
        self.settings = loaded.settings;
        self.controls.layout = self.settings.layout;
        if (loaded.found) self.loads_done += 1;
        if (!loaded.damaged()) return;
        if (loaded.unreadable) {
            std.log.warn("the settings record cannot be read; the defaults stand", .{});
            self.notice = .unreadable;
            return;
        }
        std.log.warn("the settings record was damaged ({f}); the rest is kept, the damaged record is kept as {s}{s}", .{
            &loaded.report,
            settings_mod.record.damaged_name,
            if (loaded.repair_failed) ", and the repaired one could not be written" else "",
        });
        self.notice = .damaged;
    }

    /// Writes `settings` as the record; a failure is told, and the settings stay for this run.
    fn writeSettings(self: *Game, settings: *const settings_mod.Settings) void {
        const storage = self.storage orelse return;
        settings_mod.record.save(storage, settings) catch |err| {
            std.log.warn("the settings cannot be saved: {s}", .{@errorName(err)});
            self.notice = .not_saved;
            return;
        };
        self.saves_written += 1;
    }

    /// The host left its full screen without the game asking (in a browser, Escape is the
    /// browser's): the setting goes off, as the player chose, and the record keeps it.
    pub fn fullscreenLeft(self: *Game) void {
        if (!self.settings.window.fullscreen) return;
        self.settings.window.fullscreen = false;
        self.writeSettings(&self.settings);
    }

    /// The machine has one player: in network play, and in the browser page always. Pad 1's keys
    /// and every controller play pad 1 (input.zig).
    pub fn setOnePlayer(self: *Game) void {
        self.controls.one_player = true;
    }

    /// Whether the game takes `key` now: a pad's key or the settings key (the browser's page keeps
    /// the other keys for itself).
    pub fn usesKey(self: *const Game, key: platform.Key) bool {
        if (key == .unknown) return false;
        return key == self.settings.settings_key or self.controls.uses(key);
    }

    /// The events, the ticks due, the picture.
    pub fn update(self: *Game, p: *platform.Platform) !UpdateResult {
        if (!self.started) {
            _ = try p.start();
            try p.setResolution(page_width, page_height);
            self.started = true;
            self.openSound(p);
            self.clock_base_ns = p.nowNs();
        }
        self.update_count += 1;
        var buf: [32]platform.Event = undefined;
        while (true) {
            const n = p.pollEvents(&buf);
            if (n == 0) break;
            for (buf[0..n]) |e| {
                self.events_consumed += 1;
                switch (e.payload) {
                    .quit => self.finished = true,
                    .key_down => |k| if (k.key == .escape) {
                        self.finished = true;
                    } else {
                        _ = self.controls.handle(e);
                    },
                    else => _ = self.controls.handle(e),
                }
            }
        }
        if (self.finished) return .finished;
        switch (self.pacing) {
            .per_update => _ = self.runTick(p),
            .clock => self.runDue(p),
        }
        try self.present(p);
        return .running;
    }

    /// The ticks due: while the platform plays sound, those that keep its queue full enough;
    /// otherwise those the clock makes due since its origin.
    fn runDue(self: *Game, p: *platform.Platform) void {
        const now = p.nowNs();
        var n: u32 = 0;
        if (self.sound) |*s| {
            const st = p.audioStatus();
            if (st.running and !st.suspended) {
                const target = queue_ticks * s.maxFrames();
                while (n < max_ticks_per_update and p.audioStatus().queued_frames < target) : (n += 1) {
                    if (!self.runTick(p)) break;
                }
                self.clock_base_ns = now;
                self.clock_ticks = 0;
                return;
            }
        }
        // In picoseconds, 64-bit (the browser's module has no 128-bit division): it lasts 213
        // days from the clock's origin.
        const due: u64 = (now -| self.clock_base_ns) * 1000 / sound_out.tick_ps;
        while (n < max_ticks_per_update and self.clock_ticks < due) : (n += 1) {
            if (!self.runTick(p)) {
                // A hold: the clock does not run ahead of it.
                self.clock_base_ns = now;
                self.clock_ticks = 0;
                return;
            }
            self.clock_ticks += 1;
        }
        if (self.clock_ticks < due) {
            // Too far behind (a stall): the lost time is dropped.
            self.clock_base_ns = now;
            self.clock_ticks = 0;
        }
    }

    /// One tick with the local pads, and its sound. False when the game holds and nothing ran.
    fn runTick(self: *Game, p: *platform.Platform) bool {
        self.state.step(self.controls.pads());
        self.redraw = true;
        if (self.sound) |*s| _ = p.audioQueue(self.atVolume(s.tick(0))) catch {};
        return true;
    }

    /// The sound device, stereo at 48 kHz (or the rate the platform gives).
    fn openSound(self: *Game, p: *platform.Platform) void {
        const fmt = p.audioOpen(.{ .channels = sound_out.channels, .sample_rate = sound_out.rate }) catch |err| {
            std.log.info("no sound: {s}", .{@errorName(err)});
            return;
        };
        if (fmt.channels != sound_out.channels or fmt.sample_rate == 0) {
            std.log.warn("no sound: the device offers {d} channels at {d} Hz", .{ fmt.channels, fmt.sample_rate });
            p.audioClose();
            return;
        }
        self.sound = sound_out.SoundOut.init(self.allocator, fmt.sample_rate) catch |err| {
            std.log.warn("no sound: {s}", .{@errorName(err)});
            p.audioClose();
            return;
        };
    }

    /// `frames` at the settings' volume: themselves at full volume, else scaled in the volume
    /// buffer. The gain is the square of the volume's fraction, so that its steps sound even; muted,
    /// the queue gets silence and still paces the game. A host that applies the volume itself
    /// (`host_volume`) gets the frames as they are.
    fn atVolume(self: *Game, frames: []const i16) []const i16 {
        const s = self.settings.sound;
        if (self.host_volume or (s.volume >= settings_mod.record.max_volume and !s.mute)) return frames;
        if (self.volume_buffer.len < frames.len) {
            self.allocator.free(self.volume_buffer);
            self.volume_buffer = self.allocator.alloc(i16, frames.len) catch {
                self.volume_buffer = &.{};
                return frames;
            };
        }
        const out = self.volume_buffer[0..frames.len];
        const gain: i32 = if (s.mute) 0 else @as(i32, s.volume) * s.volume;
        for (frames, out) |f, *o| o.* = @intCast(@divTrunc(@as(i32, f) * gain, 100 * 100));
        return out;
    }

    /// The frame, drawn again only where it may have changed: a host that updates more often than
    /// the ticks run (a display above 60 Hz) presents the same frame in between.
    fn present(self: *Game, p: *platform.Platform) !void {
        if (self.redraw) {
            self.redraw = false;
            switch (self.state.scenes.top().*) {
                .empty => {},
                .test_pattern => |*t| t.draw(self.state.tick, &self.pic, &self.drawn),
            }
        }
        try p.present(self.pic.frame());
        self.frames_presented += 1;
    }

    /// The hash of the last frame presented (0 before the first). It is worked out when asked.
    pub fn lastFrameHash(self: *const Game) u64 {
        if (self.frames_presented == 0) return 0;
        return self.pic.hash();
    }

    /// The hash of the state's canonical form.
    pub fn stateHash(self: *const Game) u64 {
        return self.state.hash();
    }
};

const testing = std.testing;
const memory = @import("memory.zig");

test "the same pads from power-on give the same state, and other pads another" {
    var a: State = .{};
    var b: State = .{};
    for (0..200) |i| {
        const pads: input.Pads = .{ .pad1 = .{ .right = i % 3 == 0 }, .pad2 = .{ .down = i > 100 } };
        a.step(pads);
        b.step(pads);
    }
    try testing.expectEqual(a.hash(), b.hash());
    try testing.expectEqual(@as(u32, 200), a.tick);
    b.step(.{ .pad2 = .{ .start = true } });
    a.step(.{});
    try testing.expect(a.hash() != b.hash());
}

test "the settings come from the storage: a whole record is kept, a damaged one told" {
    var store = memory.MemoryStorage.init(testing.allocator);
    defer store.deinit();
    var s: settings_mod.Settings = .{};
    _ = s.bindKey(.{ .pad = .{ .pad = 0, .button = .start } }, .p);
    try settings_mod.record.save(store.storage(), &s);
    var game = try Game.init(testing.allocator, null, store.storage());
    defer game.deinit();
    try testing.expectEqual(@as(u64, 1), game.loads_done);
    try testing.expectEqual(Notice.none, game.notice);
    try testing.expectEqual(platform.Key.p, game.controls.layout.keys[0][@backingInt(input.Button.start)]);
    try testing.expect(game.usesKey(.p) and game.usesKey(.f1) and !game.usesKey(.enter));

    try store.storage().save(settings_mod.record.name, "not JSON");
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var damaged = try Game.init(testing.allocator, null, store.storage());
    defer damaged.deinit();
    try testing.expectEqual(Notice.damaged, damaged.notice);
    try testing.expectEqual(settings_mod.Settings{}, damaged.settings);

    // Without a storage: the defaults, and nothing is written.
    var bare = try Game.init(testing.allocator, null, null);
    defer bare.deinit();
    bare.settings.window.fullscreen = true;
    bare.fullscreenLeft();
    try testing.expectEqual(@as(u64, 0), bare.saves_written);
}

test "the volume scales the sound unless the host applies it" {
    var game = try Game.init(testing.allocator, null, null);
    defer game.deinit();
    const frames = [_]i16{ 1000, -1000, 30000, -30000 };
    try testing.expectEqual(@as([*]const i16, &frames), game.atVolume(&frames).ptr);
    game.settings.sound.volume = 50;
    try testing.expectEqualSlices(i16, &.{ 250, -250, 7500, -7500 }, game.atVolume(&frames));
    game.settings.sound.mute = true;
    try testing.expectEqualSlices(i16, &.{ 0, 0, 0, 0 }, game.atVolume(&frames));
    game.host_volume = true;
    try testing.expectEqualSlices(i16, &frames, game.atVolume(&frames));
}

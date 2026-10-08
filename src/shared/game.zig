//! The game as the hosts run it (DESIGN.md 3.1): its content, read from the asset source at the
//! start (library.zig); its state from power-on (`State`: the scenes of scene.zig and their flow,
//! flow.zig); the players' controls (input.zig); the picture it presents (view.zig, through the
//! renderer) and the sound it queues (sound_out.zig, through the sequencer); and the settings
//! record read at the start. The hosts own the platform and the providers; the game owns what
//! happens next.
//!
//! Time: the game advances by display ticks, the console's frame, 59.92 a second (DESIGN.md
//! 10.2). While the platform plays sound, the game runs the ticks that keep the device's queue a
//! few ticks long, so the sound keeps the device's time and never breaks; otherwise it runs the
//! ticks that the platform's clock makes due. The agent host runs one tick per update
//! (`Pacing.per_update`), so that its frames are the ticks.
//!
//! Without a content tree (the repository's checks give the game none, DESIGN.md 1), the game shows
//! a test pattern and plays silence, on which the hosts, network play and the checks run.
//!
//! Network play (DESIGN.md 9, `startNetplay`, network_play.zig): each machine plays its own game
//! with its player's pad (pad 1's keys and every controller); the players meet in one game, which
//! the host's canonical form carries to the guest (`load`). In a session, each tick's pads come
//! from it instead of the local controls; a tick runs once both pads for it are in; until then
//! the game holds: no tick, the same picture. The peer that gets ahead stretches its sound (or its
//! clock) by up to 0.5 %. A state mismatch stops it. Without network play, nothing of this runs.
//!
//! Settings (DESIGN.md 7): the record, read from the storage at the start, gives the controls'
//! layout, the sound's volume and the SDL host's window: this machine's, never the game's state.
//! The settings screen changes it: an overlay of this machine over the game's scenes
//! (overlay.zig), opened on the machine of the player who asks: OPTIONS' ADVANCED SETTINGS, START
//! during play (the extended and network variants), the settings key in the original. While it is
//! open the game holds:
//! no tick, the picture dimmed under it, the game's sound faded out and the pause's jingle played;
//! opened from the options, it fades in and out as the menus' screens do, without the jingle.
//! In network play the other machine holds too, says why and plays the jingle. A damaged record is repaired and kept aside (settings/record.zig),
//! and a notice tells the player for a few seconds.
const std = @import("std");
const platform = @import("platform.zig");
const input = @import("input.zig");
const settings_mod = @import("settings/root.zig");
const content_screens = @import("content/screens.zig");
const canonical = @import("canonical.zig");
const scene = @import("scene.zig");
const flow = @import("flow.zig");
const library = @import("library.zig");
const json = @import("formats/json.zig");
const picture = @import("picture.zig");
const sound_out = @import("sound_out.zig");
const net = @import("net/root.zig");
const View = @import("view.zig").View;
const transfers = @import("screens/transfers.zig");
const setup_mod = @import("setup.zig");
const Setup = setup_mod.Setup;
const world = @import("world/root.zig");
const variant = @import("variant.zig");
const overlay = @import("overlay.zig");
const panel_mod = @import("panel.zig");
const render = @import("render/root.zig");
const network_play = @import("network_play.zig");
const sound_form = @import("sound_form.zig");

pub const page_width = picture.width;
pub const page_height = picture.height;

pub const UpdateResult = enum { running, finished };

/// The settings panel's fade, a step every tick's time from `since_ns` (render.Fade); once faded
/// out, the settings go or their screen turns to its next page.
const PanelFade = struct {
    to: render.Fade.To,
    since_ns: u64,
    then: enum { close, turn_page } = .close,

    const Shown = struct { to: render.Fade.To, steps: u8 };

    fn at(f: PanelFade, now_ns: u64) Shown {
        const steps = @min((now_ns -| f.since_ns) * 1000 / sound_out.tick_ps, render.Fade.steps);
        return .{ .to = f.to, .steps = @intCast(steps) };
    }

    /// Faded out.
    fn out(f: PanelFade, now_ns: u64) bool {
        return f.to == .black and f.at(now_ns).steps == render.Fade.steps;
    }
};

/// How the updates run ticks: as the sound or the clock make them due (the game as the player
/// runs it), or one each (the agent host's).
pub const Pacing = enum { clock, per_update };

/// What the game has to tell about its settings record.
pub const Notice = overlay.Notice;

/// What the frame that starts the next tick does before the sound's driver: the last tick's
/// picture's transfers (the cycles they hold the sound's processor) and its other work.
pub const Due = struct {
    held: u32 = 0,
    work: i32 = transfers.costs.split,
};

/// The frame that starts a tick, before the sound's driver: the last tick's picture's transfers
/// and the pads' reading hold the sound's processor, unless a load holds the frame's work and
/// the sound together; and its work. `due` keeps this tick's picture's for the next.
pub fn transfersOf(due: *Due, turn: *const scene.Turn) Due {
    // A tick that ends no frame of the logic (an interrupt a load left waiting, taken in the
    // logic's middle; a tick of a load that leaves the interrupts on): the driver alone, the
    // frame's for the next.
    if (turn.lag != .none) return .{ .held = 0, .work = transfers.costs.lag };
    var now: Due = .{ .held = 0, .work = due.work };
    if (turn.sound_driver) {
        now.held = due.held + @as(u32, if (turn.demo_pads) transfers.demo_pads else transfers.pads);
        due.held = 0;
    }
    // A load's ticks leave what the frame before it carries for the frame after it.
    if (turn.frame) |f| {
        due.held = transfers.hold(f);
        due.work = transfers.work(f) + transfers.streamWork(turn.streamed);
    } else if (turn.sound_driver) due.work = transfers.work(null) + transfers.streamWork(turn.streamed);
    return now;
}

/// A tick's sound: its frames from the sounds it asked for and the frame's holds and work
/// (`transfersOf`).
pub fn tickSound(sound: *sound_out.SoundOut, due: *Due, turn: *const scene.Turn, stretch_ppm: u32) []const i16 {
    const frame = transfersOf(due, turn);
    return sound.play(stretch_ppm, turn.requests_now.slice(), turn.requests.slice(), turn.sound_driver, turn.sound_restart, turn.lag == .middle, frame.held, frame.work);
}

/// Everything that decides what the game does next. Its canonical form (canonical.zig) is what
/// the tests and network play compare: the same pads from power-on give the same state on every
/// platform.
pub const State = struct {
    /// Display ticks since power-on.
    tick: u32 = 0,
    /// What the game started with: its variant (its flow and its rules), the machines' players.
    start: variant.Start = .{},
    /// The scenes; the test pattern alone without content.
    scenes: scene.Stack = .{},
    /// What the screens decide for play.
    setup: Setup = .{},
    /// The pads at the last reading: a button held now and not then is pressed.
    held: input.Pads = .{},
    /// The game's random generator, with the original's algorithm (world/random.zig).
    random: world.Random = .{},

    /// The state at power-on of a game with its content: the variant's flow's first scene, its
    /// set-up, and the original's wait after it.
    pub fn powerOn(start: variant.Start) State {
        var s: State = .{ .start = start };
        s.scenes = scene.powerOn(start.variant.config().graph, &s.setup);
        return s;
    }

    /// What this machine tells a tick: whether a second pad is there, whether its game takes the
    /// game's rules from another machine's (scene.Turn).
    pub const Machine = struct { second_pad: bool = true, guest: bool = false, taken: ?setup_mod.Character = null, rules: setup_mod.Rules = .{}, net: scene.Net = .{} };

    /// One display tick, with the pads of that tick and whether a second pad is there. Returns
    /// what the tick asks of the sound. Every scene but the test pattern needs `assets`.
    pub fn step(self: *State, pads: input.Pads, second_pad: bool, assets: ?*const scene.Assets) scene.Turn {
        return self.stepWith(pads, .{ .second_pad = second_pad }, assets, null);
    }

    /// `step`, with this machine's facts, a round's world giving out its tick into `world_out`
    /// (the picture's).
    pub fn stepWith(self: *State, pads: input.Pads, machine: Machine, assets: ?*const scene.Assets, world_out: ?*world.Output) scene.Turn {
        const config = self.start.variant.config();
        var turn: scene.Turn = .{
            .pads = pads,
            .pressed = .{ .pad1 = newly(pads.pad1, self.held.pad1), .pad2 = newly(pads.pad2, self.held.pad2) },
            .second_pad = machine.second_pad,
            .guest = machine.guest,
            .taken = machine.taken,
            .rules = machine.rules,
            .net = machine.net,
            .setup = &self.setup,
            .policies = &config.policies,
            .random = &self.random,
            .world_out = world_out,
        };
        scene.tick(&self.scenes, config.graph, &turn, assets);
        if (turn.release_pads) {
            self.held = .{ .pad1 = all_buttons, .pad2 = all_buttons };
        } else if (turn.read_pads) self.held = pads;
        self.tick +%= 1;
        return turn;
    }

    const all_buttons: input.Pad = @bitCast(@as(u8, 0xff));

    fn newly(now: input.Pad, before: input.Pad) input.Pad {
        return @bitCast(@as(u8, @bitCast(now)) & ~@as(u8, @bitCast(before)));
    }

    pub fn hash(self: *const State) u64 {
        return canonical.hash(State, self);
    }

    /// Whether a game is under way: from the character select to its end (the game over).
    /// Network play's session lasts as long (DESIGN.md 9).
    pub fn inGame(self: *const State) bool {
        const k = if (self.scenes.next) |n| n.kind else std.meta.activeTag(self.scenes.base);
        return switch (k) {
            .select, .round, .round_clear, .next_round => true,
            else => false,
        };
    }

    /// What a second player joining the game can do now.
    pub const Joining = enum {
        /// Join at once: the character select's second cursor, or the round's drop-in at its next
        /// logic tick.
        now,
        /// Not now: between two rounds, or no game yet.
        later,
        /// The game plays: the second player must have a character first.
        character,
    };

    pub fn joining(self: *const State, character: ?setup_mod.Character) Joining {
        return switch (self.scenes.base) {
            .select => |*s| if (self.scenes.next == null and s.joinable()) .now else if (character == null) .character else .later,
            .round => |*r| if (character == null) .character else if (r.play.world.players[1].entity == null) .now else .later,
            .round_clear, .next_round => if (character == null) .character else .later,
            else => .later,
        };
    }

    /// The second player joins (`joining` said `now`): at the character select (its cursor where
    /// it was at its own select, `cursor`, its choice kept), or in the round as `character`.
    pub fn join(self: *State, character: ?setup_mod.Character, cursor: ?setup_mod.Character, assets: *const scene.Assets) void {
        switch (self.scenes.base) {
            .select => |*s| s.join(&self.setup, &assets.select, cursor orelse character, character != null),
            .round => |*r| _ = r.dropIn(1, character.?),
            else => {},
        }
    }

    /// Player `who` comes back to the round under way as `character` (network play's host's
    /// player, back to the game its clients played on): its fighter drops in at the next logic
    /// tick.
    pub fn dropIn(self: *State, who: u1, character: setup_mod.Character) void {
        switch (self.scenes.base) {
            .round => |*r| _ = r.dropIn(who, character),
            else => {},
        }
    }

    /// Player `who` leaves the game (network play's player who quit or did not come back, or the
    /// host's who left it for its clients): in a round its fighter dies, and it is out of the
    /// game, as a player out of lives who does not continue; out of the next round between two;
    /// the second player gone from the character select.
    pub fn dropOut(self: *State, who: u1, assets: *const scene.Assets) void {
        switch (self.scenes.base) {
            .select => |*s| if (who == 1) s.leave(&self.setup, &assets.select),
            .round => |*r| r.dropOut(who),
            .round_clear, .next_round => self.setup.progress.players[who].in_play = false,
            else => {},
        }
    }

    /// Whether the game plays its rounds: in a round or between two (past its select).
    pub fn inRounds(self: *const State) bool {
        return self.inGame() and switch (self.scenes.base) {
            .round, .round_clear, .next_round => true,
            else => false,
        };
    }

    /// Back to the game menu, with `setup` (network play's guest whose game ended without it:
    /// its own front end again), after the options' wait back to it.
    pub fn backToMenu(self: *State, setup: Setup) void {
        self.setup = setup;
        self.setup.progress = .{};
        self.setup.characters = .{ null, null };
        const back = flow.original.next(.options, .done).?;
        self.scenes = scene.startAt(.menu, back.load, &self.setup);
        self.held = .{};
    }
};

/// The sound queue's length that the game keeps, in ticks, and the most ticks an update runs (a
/// longer stall is dropped, not caught up).
const queue_ticks = 3;
const max_ticks_per_update = 4;

pub const Game = struct {
    allocator: std.mem.Allocator,
    /// The game's files, which the content is read from, and the saves.
    assets: ?platform.AssetSource,
    storage: ?platform.Storage,
    /// The content tree, and the scenes' assets in it; null without a tree (the test pattern).
    content: ?*library.Content = null,
    scene_assets: ?scene.Assets = null,
    state: State = .{},
    controls: input.Controls = .{},
    settings: settings_mod.Settings = .{},
    notice: Notice = .none,
    pacing: Pacing = .clock,
    started: bool = false,
    finished: bool = false,
    /// The sound, while the platform has an audio device.
    sound: ?sound_out.SoundOut = null,
    /// The clock's origin and the ticks run since, while the clock paces the game, and the
    /// stretch of its ticks (network play's balancing).
    clock_base_ns: u64 = 0,
    clock_ticks: u64 = 0,
    clock_ppm: u32 = 0,
    /// Network play: the session each tick's pads come from (null: the local controls).
    netplay: ?*net.Netplay = null,
    /// Network play's state on this machine (network_play.zig): the host's or the client's.
    net: network_play.NetPlay = .{},
    /// The variant the game plays (variant.zig), which the host chooses before the first update:
    /// in network play, the host's is both games'.
    variant: variant.Variant = .extended,
    /// The start the game plays instead of its variant's on this machine: a check's game that
    /// plays alone what a session played (the session's start, two players on one machine).
    fixed_start: ?variant.Start = null,
    /// The host applies the settings' volume itself (the browser's page, with its gain): the game
    /// then queues its sound at full volume.
    host_volume: bool = false,
    /// Room for a tick's frames at the settings' volume.
    volume_buffer: []i16 = &.{},
    /// The scenes' picture, with the content.
    view: ?View = null,
    /// The top scene's state as it was last drawn: the next drawing draws what changed since.
    drawn: scene.Scene = .{ .load = .{} },
    /// The cycles the last frame's transfers stop the sound's processor at the next frame's start
    /// (screens/transfers.zig).
    transfers_due: Due = .{},
    /// The test pattern's picture, without content, and what it shows.
    pic: picture.Picture,
    pattern_drawn: scene.TestPattern.Drawn = .{},
    /// Whether the picture may have changed since it was last drawn (a tick ran).
    redraw: bool = true,
    /// This machine's scenes over the game's (overlay.zig): the settings, the other player's, a
    /// notice; and what they are drawn with (the content's font and menu colours).
    overlays: overlay.Stack = .{},
    panel: ?*panel_mod.Panel = null,
    /// The overlays were drawn over the last frame presented (the frame is the panel's), and
    /// whether they need drawing again (they changed, or the picture under them did).
    overlay_shown: bool = false,
    overlay_dirty: bool = true,
    /// The settings' arrow as last drawn (it blinks while they wait for a key), and the light of
    /// a fading gamepad's message.
    arrow_shown: bool = true,
    light_shown: u8 = 255,
    /// The settings' panel fades: in and out as the menus' screens do when the options open them
    /// (`settings_fade`), and out and in as their screen turns its page. The fade running (or the
    /// last, its colours kept), and its step as last drawn.
    panel_fade: ?PanelFade = null,
    panel_fade_shown: ?PanelFade.Shown = null,
    settings_fade: bool = false,
    /// The pause's jingle that the settings play over a held game (made with the sound, before it
    /// is wanted), and where its playing is.
    jingle: []i16 = &.{},
    jingle_at: ?usize = null,
    /// The game's sound faded out for a hold; the next tick's sound fades in.
    faded: bool = false,
    fade_buffer: []i16 = &.{},

    update_count: u64 = 0,
    frames_presented: u64 = 0,
    events_consumed: u64 = 0,
    saves_written: u64 = 0,
    loads_done: u64 = 0,

    pub const InitError = error{ OutOfMemory, BadContent };

    /// The content is read from `assets` when they hold a content tree (a refusal is logged with
    /// the file and the field, and is `BadContent`); without one, the game shows its test
    /// pattern. The settings are read from `storage` (the defaults without one).
    pub fn init(allocator: std.mem.Allocator, assets: ?platform.AssetSource, storage: ?platform.Storage) InitError!Game {
        var game: Game = .{ .allocator = allocator, .assets = assets, .storage = storage, .pic = try .init(allocator) };
        errdefer game.deinit();
        if (assets) |a| if (library.hasTree(allocator, a)) try game.loadContent(a);
        if (storage) |s| game.loadSettings(s);
        game.state = game.startState();
        return game;
    }

    pub fn deinit(self: *Game) void {
        if (self.netplay) |np| {
            np.deinit();
            self.allocator.destroy(np);
        }
        if (self.sound) |*s| s.deinit(self.allocator);
        self.allocator.free(self.volume_buffer);
        self.allocator.free(self.fade_buffer);
        self.allocator.free(self.jingle);
        if (self.panel) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        if (self.view) |*v| v.deinit();
        if (self.content) |c| {
            c.destroy();
            self.allocator.destroy(c);
        }
        self.pic.deinit(self.allocator);
        self.* = undefined;
    }

    /// The content tree, every file checked, the scenes' assets found in it, and the game at
    /// power-on with it.
    fn loadContent(self: *Game, assets: platform.AssetSource) InitError!void {
        var diag: json.Diagnostic = .{};
        const c = library.load(self.allocator, assets, &diag) catch |e| return self.refuse(e, &diag);
        self.content = c;
        self.scene_assets = scene.Assets.find(c, &diag) catch |e| return self.refuse(e, &diag);
        self.view = try View.init(self.allocator);
        // The overlays' look: the game's font and its menu's colours (the game menu's assets).
        const a = &self.scene_assets.?.menu;
        const p = try self.allocator.create(panel_mod.Panel);
        p.init(self.allocator, a.text.font, a.text.sheet, a.one_pad) catch |e| {
            self.allocator.destroy(p);
            if (e == error.OutOfMemory) return error.OutOfMemory;
            std.log.err("the game's content is refused: fonts/main has no arrow (->)", .{});
            return error.BadContent;
        };
        self.panel = p;
    }

    fn refuse(_: *Game, e: library.LoadError, diag: *const json.Diagnostic) InitError {
        if (e == error.BadContent) std.log.err("the game's content is refused: {f}", .{diag});
        return e;
    }

    /// The state from power-on: with the content, the variant's flow's first scene; without, the
    /// pattern.
    fn startState(self: *const Game) State {
        return if (self.content != null) .powerOn(self.start()) else .{};
    }

    /// What the game starts with (variant.zig): this machine's variant, or in network play the
    /// session's, which the host gives.
    pub fn start(self: *const Game) variant.Start {
        if (self.fixed_start) |s| return s;
        return .{ .variant = self.variant };
    }

    /// The rules of the variant the game plays: its state's (without content, the test pattern's
    /// has none: this machine's).
    fn policies(self: *const Game) *const variant.Policies {
        const v = if (self.content != null) self.state.start.variant else self.start().variant;
        return &v.config().policies;
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
            self.tell(.unreadable);
            return;
        }
        std.log.warn("the settings record was damaged ({f}); the rest is kept, the damaged record is kept as {s}{s}", .{
            &loaded.report,
            settings_mod.record.damaged_name,
            if (loaded.repair_failed) ", and the repaired one could not be written" else "",
        });
        self.tell(.damaged);
    }

    /// A notice about the record: for the host (`notice`) and over the picture for a few seconds.
    fn tell(self: *Game, n: Notice) void {
        self.notice = n;
        self.overlays.push(.{ .notice = .{ .what = n } });
        self.overlay_dirty = true;
    }

    /// Writes `settings` as the record; a failure is told, and the settings stay for this run.
    fn writeSettings(self: *Game, settings: *const settings_mod.Settings) void {
        const storage = self.storage orelse return;
        settings_mod.record.save(storage, settings) catch |err| {
            std.log.warn("the settings cannot be saved: {s}", .{@errorName(err)});
            self.tell(.not_saved);
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

    /// The machine has one player: in network play, and in the browser page always. Player 1
    /// alone plays here (input.zig).
    pub fn setOnePlayer(self: *Game) void {
        self.controls.one_player = true;
    }

    /// Plays with another player over the network (DESIGN.md 9): the host (player 1) listens at
    /// `options.address`, the guest (player 2) connects to it when its player wants to join (a
    /// relay's page: the page brings the connection). A network play the game had goes; the next
    /// update starts this one.
    pub fn startNetplay(self: *Game, options: net.netplay.Options) error{OutOfMemory}!void {
        const np = try self.allocator.create(net.Netplay);
        errdefer self.allocator.destroy(np);
        var o = options;
        o.name = self.settings.name;
        np.* = try net.Netplay.init(self.allocator, o, canonical.diffFn(State));
        self.endNetplay();
        self.netplay = np;
        self.net = .{};
        // A client has one player; a host keeps its machine's (its own games may have two).
        if (options.role == .guest) self.setOnePlayer();
    }

    /// Whether this machine is network play's client: its game takes the game's rules from the
    /// host's, and its OPTIONS show only what is its own (scene.Turn).
    pub fn isClient(self: *const Game) bool {
        const np = self.netplay orelse return false;
        return np.role == .guest;
    }

    /// What the game menu asked of this machine at this tick: network play's (network_play.zig),
    /// or its name entry.
    fn netRequest(self: *Game, p: *platform.Platform, r: scene.NetRequest) void {
        switch (r) {
            .name => self.openModal(.{ .name_entry = .open(self.settings.name, self.controls.players()) }, null),
            else => network_play.request(self, p, r),
        }
    }

    /// Whether the game holds: an overlay holds it, but the lobby over a game the host's player
    /// left (its client plays on).
    fn holding(self: *const Game) bool {
        return self.overlays.holds() and !self.net.lobbyOverGame();
    }

    fn endNetplay(self: *Game) void {
        const np = self.netplay orelse return;
        np.deinit();
        self.allocator.destroy(np);
        self.netplay = null;
        self.net = .{};
        self.overlays.remove(.peer_settings);
        self.showWait(null, 0);
    }

    /// A notice of network play over the picture, which goes after a while (a wait shown with it
    /// stays); null: none.
    pub fn notify(self: *Game, m: ?overlay.Message) void {
        if (m) |x| self.overlays.push(.{ .net_notice = .{ .what = x } }) else self.overlays.remove(.net_notice);
        self.overlay_dirty = true;
    }

    /// Network play's wait (`m`, which holds the game, with its count of `seconds` where it has
    /// one), or none: a wait shown goes.
    pub fn showWait(self: *Game, m: ?overlay.Message, seconds: u8) void {
        if (self.overlays.find(.network)) |o| {
            if (m != null and o.network.what == m.? and o.network.seconds == seconds) return;
            self.overlays.remove(.network);
            self.overlay_dirty = true;
        }
        if (m) |x| {
            self.overlays.push(.{ .network = .{ .what = x, .seconds = seconds } });
            self.overlay_dirty = true;
        }
    }

    /// The most bytes of a join (`joinForm`).
    pub const join_max = 4 + canonical.maxSize(State) + sound_form.max_size;

    /// What network play's join carries (DESIGN.md 9), into `out` (`join_max` bytes): the game's
    /// canonical form, its length first (four bytes, the low first), and beside it this machine's
    /// sound as it plays (sound_form.zig), none without one.
    pub fn joinForm(self: *const Game, out: []u8) []u8 {
        const form = canonical.write(State, &self.state, out[4..]);
        std.mem.writeInt(u32, out[0..4], @intCast(form.len), .little);
        var n = 4 + form.len;
        if (self.sound) |*so| if (sound_form.write(so, self.transfers_due, out[n..])) |sound| {
            n += sound.len;
        };
        return out[0..n];
    }

    /// The game this machine loads from another's join (`joinForm`, network play's guest joining
    /// the host's): from the next tick on, it goes on as that game. What is this machine's own is
    /// made again from it: the picture whole; the sound from the other machine's, at the same
    /// place (or, without it, the scenes' music from its start). (Network play keeps this
    /// machine's own set-up: network_play.zig.)
    pub fn load(self: *Game, p: *platform.Platform, join: []const u8) !void {
        if (join.len < 4) return error.Malformed;
        const n = std.mem.readInt(u32, join[0..4], .little);
        if (n > join.len - 4) return error.Malformed;
        const s = try self.allocator.create(State);
        defer self.allocator.destroy(s);
        try canonical.read(State, join[4..][0..n], s);
        self.state = s.*;
        self.rebuild(p);
        if (self.view) |*v| if (self.scene_assets) |*a| scene.redrawOutput(&self.state.scenes, &v.world_out, a);
        if (self.sound) |*so| {
            const sound = join[4 + n ..];
            const carried = sound.len != 0 and if (sound_form.load(so, &self.transfers_due, sound)) true else |err| blk: {
                std.log.warn("the other machine's sound does not load ({s}): the music starts again", .{@errorName(err)});
                break :blk false;
            };
            if (!carried) if (self.scene_assets) |*a| if (scene.music(&self.state.scenes, a)) |m| so.ask(m);
        }
        self.loads_done += 1;
    }

    /// Whether the other player of network play is on the settings screen.
    pub fn peerInSettings(self: *const Game) bool {
        const np = self.netplay orelse return false;
        return np.peerInSettings();
    }

    /// Whether the game takes `key` now: a pad's key or the settings key (where the variant has
    /// it), or any key while the settings are open (the browser's page keeps the other keys for
    /// itself).
    pub fn usesKey(self: *const Game, key: platform.Key) bool {
        if (key == .unknown) return false;
        if (self.settingsOpen() or self.modalOpen()) return true;
        return (self.policies().settings_key and key == self.settings.settings_key) or self.controls.uses(key);
    }

    /// Whether the settings screen is open (the hosts follow its window's settings).
    pub fn settingsOpen(self: *const Game) bool {
        for (self.overlays.items[0..self.overlays.len]) |o| if (o == .settings) return true;
        return false;
    }

    /// Whether this machine plays player `who` (0 or 1): both without network play; in a session,
    /// its role's; outside one, its own game's (the host's players, a client's player 1 there).
    fn plays(self: *const Game, who: u1) bool {
        const np = self.netplay orelse return true;
        if (np.observing()) return false;
        if (!np.inSession()) return np.role == .host or who == 0;
        return @intFromBool(np.role == .guest) == who;
    }

    /// Opens the settings screen over the game, which holds while it is open; the controls let go,
    /// and once the game runs, the pause's jingle plays, unless they fade in from the options (from
    /// `fade_ns`). A notice goes. The screen shows this machine's players alone (one in network
    /// play), and the settings key where the variant has it.
    fn showSettings(self: *Game, fade_ns: ?u64) void {
        if (self.settingsOpen() or self.panel == null) return;
        self.overlays.remove(.notice);
        self.overlays.remove(.gamepad);
        self.overlays.push(.{ .settings = .open(&self.settings, .{
            .players = @intCast(self.controls.players()),
            .settings_key = self.policies().settings_key,
            .rules = self.policies().settings_rules and !self.isClient(),
            .gamepads = self.controls.connected(),
        }) });
        self.overlay_dirty = true;
        self.controls.release();
        self.panel_fade = if (fade_ns) |t| .{ .to = .target, .since_ns = t } else null;
        self.settings_fade = fade_ns != null;
        if (self.started and fade_ns == null) self.jingle_at = 0;
    }

    /// The settings screen closed: the controls take the keys; SAVE AND EXIT writes the record
    /// (left without saving, the screen gave back the settings it opened with). A game under way
    /// with the settings' rules takes them as they are now (FRIENDLY HIT at once, the lives and the
    /// continues at the next continue); in the host's network session, at a tick both machines
    /// share (network_play.zig). Faded in, they fade out from `now_ns` before they go (null: at
    /// once).
    fn closeSettings(self: *Game, how: settings_mod.screen.Result, now_ns: ?u64) void {
        self.overlay_dirty = true;
        self.controls.layout = self.settings.layout;
        if (self.state.setup.rules) |rules| if (!std.meta.eql(rules, self.settings.rules)) {
            const session = if (self.netplay) |np| np.inSession() else false;
            if (!session) {
                self.state.setup.rules = self.settings.rules;
            } else if (!self.isClient()) self.net.pending_rules = self.settings.rules;
        };
        if (how == .save_and_exit) self.writeSettings(&self.settings);
        if (self.settings_fade) if (now_ns) |t| {
            self.panel_fade = .{ .to = .black, .since_ns = t };
            return;
        };
        self.panel_fade = null;
        self.settings_fade = false;
        self.overlays.remove(.settings);
    }

    /// The settings' panel fading out (they close, or turn their page): they take no presses.
    fn settingsFadingOut(self: *const Game) bool {
        const f = self.panel_fade orelse return false;
        return f.to == .black;
    }

    /// The settings fading out once closed.
    fn settingsClosing(self: *const Game) bool {
        const f = self.panel_fade orelse return false;
        return f.to == .black and f.then == .close;
    }

    /// An event while the settings are open: they take the presses; the controls still see the
    /// controllers come and go, and the focus.
    fn settingsEvent(self: *Game, e: platform.Event, p: *platform.Platform) void {
        const now_ns = p.nowNs();
        switch (e.payload) {
            .quit => self.finished = true,
            .key_down, .controller_button_down => {
                if (self.settingsFadingOut()) return;
                const screen = &self.overlays.find(.settings).?.settings;
                const result = screen.handle(&self.settings, e);
                self.overlay_dirty = true;
                if (result != .stay) return self.closeSettings(result, now_ns);
                // Its next page: the panel fades out, then in on it.
                if (screen.pending != null) self.panel_fade = .{ .to = .black, .since_ns = now_ns, .then = .turn_page };
            },
            else => self.controlEvent(e, p),
        }
    }

    /// Whether one of network play's screens (the network options, the name entry) is open.
    pub fn modalOpen(self: *const Game) bool {
        for (self.overlays.items[0..self.overlays.len]) |o| if (o == .net_options or o == .name_entry) return true;
        return false;
    }

    /// Opens one of network play's screens over the game, which holds while it is open, as the
    /// settings do; from a menu that faded out (`fade_ns`), it fades in and out.
    pub fn openModal(self: *Game, o: overlay.Overlay, fade_ns: ?u64) void {
        if (self.settingsOpen() or self.modalOpen() or self.panel == null) return;
        self.overlays.remove(.notice);
        self.overlays.remove(.gamepad);
        self.overlays.push(o);
        self.overlay_dirty = true;
        self.controls.release();
        self.panel_fade = if (fade_ns) |t| .{ .to = .target, .since_ns = t } else null;
        self.settings_fade = fade_ns != null;
    }

    /// Closes network play's screen open: at once, or fading out when it faded in.
    fn closeModal(self: *Game, now_ns: u64) void {
        self.overlay_dirty = true;
        if (self.settings_fade) {
            self.panel_fade = .{ .to = .black, .since_ns = now_ns };
            return;
        }
        self.panel_fade = null;
        self.overlays.remove(.net_options);
        self.overlays.remove(.name_entry);
    }

    /// An event while network play's screen is open: it takes the presses; a done network
    /// options open the session, a done name entry is kept (and the host hears it).
    fn modalEvent(self: *Game, e: platform.Event, p: *platform.Platform) void {
        switch (e.payload) {
            .quit => self.finished = true,
            .key_down, .controller_button_down => {
                if (self.settingsFadingOut()) return;
                self.overlay_dirty = true;
                if (self.overlays.find(.net_options)) |o| {
                    const x = &o.net_options;
                    if (!network_play.lobbyAction(self, p, x, x.handle(&self.settings, e))) return;
                } else if (self.overlays.find(.name_entry)) |o| {
                    switch (o.name_entry.handle(&self.settings, e)) {
                        .stay, .acted => return,
                        .done => {
                            self.settings.name = o.name_entry.name;
                            self.writeSettings(&self.settings);
                            if (self.netplay) |np| np.rename(p, self.settings.name);
                        },
                        .cancel => {},
                    }
                }
                self.closeModal(p.nowNs());
            },
            else => self.controlEvent(e, p),
        }
    }

    /// An event for the controls. A gamepad that comes is known by its model, as the platform
    /// names it (input.zig `Controls.add`); one seen for the first time is kept in the settings
    /// and their record. It is told (GAMEPAD N CONNECTED, and DISCONNECTED as it goes), and the
    /// settings follow player 1 taking it; while the settings are open, they offer it, and player
    /// 1 takes it there.
    fn controlEvent(self: *Game, e: platform.Event, p: *platform.Platform) void {
        var gone: ?u16 = null;
        const got: ?input.Controls.Added = switch (e.payload) {
            .controller_added => |id| self.controls.add(id, p.controllerInfo(id) orelse .{}),
            .controller_removed => |id| blk: {
                if (self.controls.slotOf(id)) |slot| gone = self.controls.labels[slot];
                _ = self.controls.handle(e);
                break :blk null;
            },
            else => {
                _ = self.controls.handle(e);
                return;
            },
        };
        if (self.overlays.find(.settings)) |o| {
            o.settings.facts.gamepads = self.controls.connected();
            if (got) |g| {
                if (g.new) self.knowGamepad(g.label, &o.settings);
                _ = self.settings.layout.came(g.label);
            }
            self.overlay_dirty = true;
            return;
        }
        self.settings.layout.players[0].gamepad = self.controls.layout.players[0].gamepad;
        if (got) |g| {
            if (g.new) self.knowGamepad(g.label, null);
            self.overlays.push(.{ .gamepad = .{ .label = g.label } });
            self.overlay_dirty = true;
        }
        if (gone) |label| {
            self.overlays.push(.{ .gamepad = .{ .label = label, .connected = false } });
            self.overlay_dirty = true;
        }
    }

    /// A gamepad seen for the first time: the settings know it, and their record keeps it (the
    /// settings the screen opened with while it is open, so that leaving it without saving keeps
    /// the gamepad too).
    fn knowGamepad(self: *Game, label: u16, screen: ?*settings_mod.screen.Screen) void {
        const g = self.controls.layout.pad(label).?.*;
        self.settings.layout.adopt(g, &self.controls.labels);
        if (screen) |s| {
            s.before.layout.adopt(g, &self.controls.labels);
            self.writeSettings(&s.before);
        } else self.writeSettings(&self.settings);
    }

    /// This machine's player's pad as the game's CONTROL reads it: its A, B and C pressed for
    /// their actions by its own CONTROL, and given to the game as the game's CONTROL has those
    /// actions (a client's pad in the host's game).
    fn toGameControl(self: *const Game, pad: input.Pad) input.Pad {
        const own = network_play.ownControl(self);
        const game = self.state.setup.control;
        if (own == game) return pad;
        const a = if (self.scene_assets) |*x| x else return pad;
        return relayout(pad, a.round.screen.buttons.of(own), a.round.screen.buttons.of(game));
    }

    /// The pad that does under layout `to` what `pad` does under `from`: each action's button.
    fn relayout(pad: input.Pad, from: content_screens.Layout, to: content_screens.Layout) input.Pad {
        var out = pad;
        out.a = false;
        out.b = false;
        out.c = false;
        for ([_][2]content_screens.Button{ .{ from.special, to.special }, .{ from.attack, to.attack }, .{ from.jump, to.jump } }) |m| {
            const held = switch (m[0]) {
                .a => pad.a,
                .b => pad.b,
                .c => pad.c,
            };
            switch (m[1]) {
                .a => out.a = out.a or held,
                .b => out.b = out.b or held,
                .c => out.c = out.c or held,
            }
        }
        return out;
    }

    /// The pad button that attacks by this machine's player's CONTROL, for autofire (B without
    /// the content).
    fn attackButton(self: *const Game) input.Button {
        const a = if (self.scene_assets) |*a| a else return .b;
        return switch (a.round.screen.buttons.of(network_play.ownControl(self)).attack) {
            .a => .a,
            .b => .b,
            .c => .c,
        };
    }

    /// The events, the ticks due, the picture.
    pub fn update(self: *Game, p: *platform.Platform) !UpdateResult {
        if (!self.started) {
            _ = try p.start();
            try p.setResolution(page_width, page_height);
            self.started = true;
            // Power-on, with what the host chose since the game was made (its variant, a browser's
            // page's volume).
            self.state = self.startState();
            self.openSound(p);
            self.clock_base_ns = p.nowNs();
        }
        if (self.netplay) |np| if (!np.started) np.start(p) catch |err| {
            std.log.err("network play cannot start at {s}: {s}", .{ np.address, @errorName(err) });
            return err;
        };
        self.update_count += 1;
        var buf: [32]platform.Event = undefined;
        while (true) {
            const n = p.pollEvents(&buf);
            if (n == 0) break;
            for (buf[0..n]) |e| {
                self.events_consumed += 1;
                if (self.netplay) |np| if (np.handle(p, e)) continue;
                if (self.settingsOpen()) {
                    self.settingsEvent(e, p);
                    continue;
                }
                if (self.modalOpen()) {
                    self.modalEvent(e, p);
                    continue;
                }
                switch (e.payload) {
                    .quit => self.finished = true,
                    // Escape leaves a game, back to the menu (network_play.zig), or quits.
                    .key_down => |k| if (k.key == .escape) {
                        if (!network_play.escape(self, p)) self.finished = true;
                    } else if (self.policies().settings_key and k.key == self.settings.settings_key and !k.repeat) {
                        self.showSettings(null);
                    } else {
                        _ = self.controls.handle(e);
                    },
                    else => self.controlEvent(e, p),
                }
            }
        }
        if (self.finished) {
            // Quitting with the settings open writes nothing, as leaving them without saving.
            if (self.overlays.find(.settings)) |o| {
                if (!self.settingsClosing()) self.settings = o.settings.before;
                self.closeSettings(.exit_without_saving, null);
            }
            if (self.netplay) |np| np.quit(p);
            return .finished;
        }
        if (self.netplay) |np| {
            np.inSettings(p, self.settingsOpen());
            np.update(p);
            network_play.update(self, p);
        }
        if (self.netplay) |np| self.peerOverlay(np);
        // The settings' panel faded out: closed, they go, and the game goes on; else their screen
        // turns its page, and the panel fades in on it.
        if (self.panel_fade) |f| if (f.out(p.nowNs())) {
            self.overlay_dirty = true;
            switch (f.then) {
                .close => {
                    self.panel_fade = null;
                    self.settings_fade = false;
                    self.overlays.remove(.settings);
                    self.overlays.remove(.net_options);
                    self.overlays.remove(.name_entry);
                },
                .turn_page => {
                    if (self.overlays.find(.settings)) |o| o.settings.turnPage();
                    self.panel_fade = .{ .to = .target, .since_ns = p.nowNs() };
                },
            }
        };
        network_play.lists(self, p);
        if (self.holding()) {
            self.hold(p);
        } else switch (self.pacing) {
            .per_update => _ = self.runTick(p),
            .clock => self.runDue(p),
        }
        self.playJingle(p);
        try self.present(p);
        return .running;
    }

    /// The other player's being in the settings, as the session says it: both games hold, and both
    /// hear the pause's jingle.
    fn peerOverlay(self: *Game, np: *const net.Netplay) void {
        const in = np.peerInSettings();
        const shown = self.overlays.find(.peer_settings) != null;
        if (in == shown) return;
        self.overlay_dirty = true;
        if (!in) return self.overlays.remove(.peer_settings);
        self.overlays.push(.{ .peer_settings = @intFromBool(np.role == .host) });
        self.jingle_at = 0;
    }

    /// The overlays hold the game: no tick runs, the clock does not run ahead, and the sound fades
    /// out, to fade in with the next tick.
    fn hold(self: *Game, p: *platform.Platform) void {
        self.clock_base_ns = p.nowNs();
        self.clock_ticks = 0;
        self.fadeOut(p);
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
                    if (!self.runTick(p)) {
                        // A hold: the sound fades out rather than breaks.
                        self.fadeOut(p);
                        break;
                    }
                }
                self.clock_base_ns = now;
                self.clock_ticks = 0;
                return;
            }
        }
        // In picoseconds, 64-bit (the browser's module has no 128-bit division): it lasts 213
        // days from the clock's origin. Network play's balancing stretches the tick; a change keeps
        // the time already in the tick under way.
        const ppm = self.stretchPpm();
        if (ppm != self.clock_ppm) {
            const period = stretched(self.clock_ppm);
            const into = ((now -| self.clock_base_ns) * 1000) -| self.clock_ticks * period;
            self.clock_base_ns = now -| into / 1000;
            self.clock_ticks = 0;
            self.clock_ppm = ppm;
        }
        const due: u64 = (now -| self.clock_base_ns) * 1000 / stretched(ppm);
        while (n < max_ticks_per_update and self.clock_ticks < due) : (n += 1) {
            if (!self.runTick(p)) {
                // A hold: the clock does not run ahead of it, and the sound fades out.
                self.hold(p);
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

    /// A tick's time in picoseconds, stretched by `ppm` millionths.
    fn stretched(ppm: u32) u64 {
        return sound_out.tick_ps + sound_out.tick_ps * ppm / 1_000_000;
    }

    /// The stretch of the ticks that network play's balancing asks for (0 without a session). A
    /// game paced a tick an update (the agent host's) is paced by its caller, not by its sound:
    /// a stretch would only change its frames, not its pace.
    fn stretchPpm(self: *const Game) u32 {
        if (self.pacing == .per_update) return 0;
        const np = self.netplay orelse return 0;
        return np.stretchPpm();
    }

    /// Whether this machine has a second pad for the game: two players on it, or network play's
    /// second player, another machine's (the variant whose 2 PLAYERS is this machine's player
    /// alone).
    fn secondPad(self: *const Game) bool {
        return !self.controls.one_player or self.netplay != null or !self.policies().two_players_here;
    }

    /// One tick, and its sound. In network play the pads are the session's; false when the game
    /// holds (an overlay, or the other player's pads not in), and nothing ran. A tick whose game
    /// menu chose SETTINGS opens them, on the machine of the player who chose.
    fn runTick(self: *Game, p: *platform.Platform) bool {
        if (self.holding()) return false;
        var pads = self.controls.read(self.state.tick, self.attackButton());
        // The host's player out of the game it left: its pad plays nothing (the lobby takes its
        // keys).
        if (self.net.lobbyOverGame()) pads.pad1 = .{};
        const session = if (self.netplay) |np| (if (np.inSession()) np else null) else null;
        if (session) |np| {
            // A client's pad goes by its own CONTROL into the host's game.
            const local = if (np.role == .guest) self.toGameControl(pads.pad1) else pads.pad1;
            pads = np.pads(p, local) orelse return false;
            if (np.eventAt()) |e| network_play.applyEvent(self, p, np, e);
        } else if (self.netplay) |np| if (np.role == .host and np.open and !self.net.local_two) {
            // The host's server open: its second player is the network's, not this machine's
            // (but in a local game of two).
            pads.pad2 = .{};
        };
        const machine: State.Machine = .{ .second_pad = self.secondPad(), .guest = self.isClient(), .taken = network_play.taken(self), .rules = self.settings.rules, .net = network_play.facts(self) };
        const turn = self.state.stepWith(pads, machine, if (self.scene_assets) |*a| a else null, if (self.view) |*v| &v.world_out else null);
        self.redraw = true;
        if (turn.settings) |who| if (self.plays(who)) self.showSettings(if (turn.settings_fade) p.nowNs() else null);
        if (turn.net_request) |r| self.netRequest(p, r);
        if (self.sound) |*s| {
            const frames = tickSound(s, &self.transfers_due, &turn, self.stretchPpm());
            // After a hold, the sound fades in, and the jingle of the hold stops.
            const shaped = if (self.faded) self.fade(frames, .in) else frames;
            if (self.faded) self.jingle_at = null;
            self.faded = false;
            // Under the lobby, the game the host's player left plays silent on its machine.
            _ = p.audioQueue(if (self.net.lobbyOverGame()) self.silence(shaped.len) else self.atVolume(shaped)) catch {};
        } else _ = transfersOf(&self.transfers_due, &turn);
        if (self.netplay) |np| {
            if (session != null) np.ran();
            // The host's observers get each tick's pads.
            if (np.role == .host) np.observed(p, pads);
            // The game ended: so does the session, on both machines at this tick.
            if (session != null and !self.state.inGame()) {
                np.end(p, .game_over);
                return true;
            }
            if (np.checkDue()) {
                // The state before the next tick (the session's, an observer's): its hash and its
                // form.
                var buf: [canonical.maxSize(State)]u8 = undefined;
                const form = canonical.write(State, &self.state, &buf);
                np.check(p, std.hash.Fnv1a_64.hash(form), form);
            }
        }
        return true;
    }

    /// What is this machine's own, made again for a state that did not come from its last tick (a
    /// game loaded, a game sent back to its menu): the picture whole, the sound from silence.
    pub fn rebuild(self: *Game, p: *platform.Platform) void {
        self.redraw = true;
        self.pattern_drawn = .{};
        self.transfers_due = .{};
        if (self.view) |*v| v.shows = null;
        self.clock_base_ns = p.nowNs();
        self.clock_ticks = 0;
        self.faded = false;
        if (self.sound) |*s| {
            s.reset(self.allocator) catch |err| {
                std.log.warn("no sound: {s}", .{@errorName(err)});
                s.deinit(self.allocator);
                self.sound = null;
            };
            p.audioClear();
        }
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
        const sounds = if (self.content) |c| &c.sounds else null;
        self.sound = sound_out.SoundOut.init(self.allocator, fmt.sample_rate, sounds) catch |err| {
            std.log.warn("no sound: {s}", .{@errorName(err)});
            p.audioClose();
            return;
        };
        // The settings' jingle, made now rather than when the player opens them.
        if (sounds) |c| if (sound_out.alone(self.allocator, c, "pause", fmt.sample_rate)) |frames| {
            self.jingle = frames orelse &.{};
        } else |err| std.log.warn("no jingle for the settings: {s}", .{@errorName(err)});
    }

    /// A hold: once the device's queue runs low, the chips sound on for one more tick, without the
    /// sequencer, fading to silence, so that the sound fades rather than breaks.
    fn fadeOut(self: *Game, p: *platform.Platform) void {
        if (self.faded) return;
        const s = if (self.sound) |*s| s else return;
        if (p.audioStatus().queued_frames > s.maxFrames()) return;
        const frames = self.fade(s.play(self.stretchPpm(), &.{}, &.{}, false, false, false, 0, transfers.costs.split), .out);
        // Under the lobby over a game the host's player left: silent.
        _ = p.audioQueue(if (self.net.lobbyOverGame()) self.silence(frames.len) else self.atVolume(frames)) catch {};
        self.faded = true;
    }

    /// The jingle's next frames, while a hold has faded the game's sound out: a tick's worth at a
    /// time, as the device's queue runs low. A hold that ends stops it.
    fn playJingle(self: *Game, p: *platform.Platform) void {
        var at = self.jingle_at orelse return;
        if (self.net.lobbyOverGame()) {
            self.jingle_at = null;
            return;
        }
        if (!self.faded) return;
        const s = if (self.sound) |*s| s else return;
        const tick_frames = 2 * @as(usize, s.maxFrames());
        while (at < self.jingle.len and p.audioStatus().queued_frames < s.maxFrames() * 2) {
            const n = @min(self.jingle.len - at, tick_frames);
            _ = p.audioQueue(self.atVolume(self.jingle[at..][0..n])) catch {};
            at += n;
        }
        self.jingle_at = if (at < self.jingle.len) at else null;
    }

    /// `frames` with a linear ramp, in the fade buffer.
    fn fade(self: *Game, frames: []const i16, direction: enum { in, out }) []const i16 {
        if (self.fade_buffer.len < frames.len) {
            self.allocator.free(self.fade_buffer);
            self.fade_buffer = self.allocator.alloc(i16, frames.len) catch {
                self.fade_buffer = &.{};
                return frames;
            };
        }
        const out = self.fade_buffer[0..frames.len];
        const n: i32 = @intCast(@max(frames.len / 2, 1));
        for (0..frames.len / 2) |i| {
            const k: i32 = @intCast(i);
            const gain = if (direction == .in) k else n - k;
            for (0..2) |c| out[2 * i + c] = @intCast(@divTrunc(@as(i32, frames[2 * i + c]) * gain, n));
        }
        return out;
    }

    /// `frames` at the settings' volume: themselves at full volume, else scaled in the volume
    /// buffer. The gain is the square of the volume's fraction, so that its steps sound even; muted,
    /// the queue gets silence and still paces the game. A host that applies the volume itself
    /// (`host_volume`) gets the frames as they are.
    /// `n` samples of silence.
    fn silence(self: *Game, n: usize) []const i16 {
        if (self.volume_buffer.len < n) {
            self.allocator.free(self.volume_buffer);
            self.volume_buffer = self.allocator.alloc(i16, n) catch {
                self.volume_buffer = &.{};
                return &.{};
            };
        }
        const out = self.volume_buffer[0..n];
        @memset(out, 0);
        return out;
    }

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
    /// the ticks run (a display above 60 Hz) presents the same frame in between. The overlays go
    /// over the scenes' picture, drawn again when they or the picture changed.
    fn present(self: *Game, p: *platform.Platform) !void {
        if (self.redraw) {
            self.redraw = false;
            self.overlay_dirty = true;
            if (self.state.scenes.topKind() == .test_pattern) {
                self.state.scenes.base.test_pattern.draw(self.state.tick, &self.pic, &self.pattern_drawn);
            } else {
                const v = &self.view.?;
                try scene.draw(&self.state.scenes, &self.drawn, v, &self.scene_assets.?);
                _ = try v.compose();
            }
        }
        const f = if (self.overlays.len != 0) try self.overlaid(p.nowNs(), self.scenesFrame()) else blk: {
            self.overlay_shown = false;
            break :blk self.scenesFrame();
        };
        try p.present(f);
        self.frames_presented += 1;
    }

    /// The settings' arrow blinks while they wait for a key: on and off every 16 ticks' time.
    const blink_ns: u64 = 16 * sound_out.tick_ps / 1000;

    /// The overlays over `under` (null: a black screen), drawn again when they changed; a notice
    /// (the settings', network play's) whose time is over goes. The frame is the panel's.
    fn overlaid(self: *Game, now_ns: u64, under: ?platform.RgbaFrame) !platform.RgbaFrame {
        const p = self.panel orelse return under orelse self.pic.frame();
        if (self.overlays.find(.notice)) |o| {
            const until = o.notice.until_ns orelse now_ns + overlay.notice_ns;
            o.notice.until_ns = until;
            if (now_ns >= until) {
                self.overlays.remove(.notice);
                self.notice = .none;
                self.overlay_dirty = true;
            }
        }
        if (self.overlays.find(.net_notice)) |o| {
            const until = o.net_notice.until_ns orelse now_ns + overlay.notice_ns;
            o.net_notice.until_ns = until;
            if (now_ns >= until) {
                self.overlays.remove(.net_notice);
                self.overlay_dirty = true;
            }
        }
        // A gamepad's message fades out over its last part, alone over the picture.
        var light: u8 = 255;
        if (self.overlays.find(.gamepad)) |o| {
            const until = o.gamepad.until_ns orelse now_ns + overlay.gamepad_ns;
            o.gamepad.until_ns = until;
            if (now_ns >= until) {
                self.overlays.remove(.gamepad);
                self.overlay_dirty = true;
            } else if (self.overlays.len == 1 and until - now_ns < overlay.gamepad_fade_ns) {
                light = @intCast((until - now_ns) * 255 / overlay.gamepad_fade_ns);
            }
        }
        if (light != self.light_shown) self.overlay_dirty = true;
        self.light_shown = light;
        var waiting = false;
        if (self.overlays.find(.settings)) |o| waiting = o.settings.waiting;
        const arrow = !waiting or (now_ns / blink_ns) % 2 == 0;
        if (arrow != self.arrow_shown) self.overlay_dirty = true;
        self.arrow_shown = arrow;
        const shade = if (self.panel_fade) |f| f.at(now_ns) else null;
        if (!std.meta.eql(shade, self.panel_fade_shown)) self.overlay_dirty = true;
        self.panel_fade_shown = shade;
        var drawn: usize = 0;
        for (self.overlays.slice()) |_| drawn += 1;
        if (drawn == 0) {
            self.overlay_shown = false;
            return under orelse self.pic.frame();
        }
        if (self.overlay_dirty or !self.overlay_shown) {
            self.overlay_dirty = false;
            p.begin();
            if (shade) |f| p.faded(f.to, f.steps) else p.faded(null, 0);
            for (self.overlays.slice()) |*o| {
                try o.draw(p, &self.settings, arrow);
            }
            _ = try p.finish(under, self.overlays.dims(), light);
        }
        self.overlay_shown = true;
        return self.frame();
    }

    /// The scenes' last picture, or the test pattern's.
    pub fn scenesFrame(self: *const Game) platform.RgbaFrame {
        if (self.view) |*v| if (v.shows != null) return v.frame();
        return self.pic.frame();
    }

    /// The last frame presented: the overlays', or the scenes'.
    pub fn frame(self: *const Game) platform.RgbaFrame {
        if (self.overlay_shown) return .{ .width = panel_mod.width, .height = panel_mod.height, .stride = panel_mod.width * 4, .pixels = self.panel.?.rgba };
        return self.scenesFrame();
    }

    /// The hash of the last frame presented (0 before the first). It is worked out when asked.
    pub fn lastFrameHash(self: *const Game) u64 {
        if (self.frames_presented == 0) return 0;
        return std.hash.Fnv1a_64.hash(self.frame().pixels);
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
        _ = a.step(pads, true, null);
        _ = b.step(pads, true, null);
    }
    try testing.expectEqual(a.hash(), b.hash());
    try testing.expectEqual(@as(u32, 200), a.tick);
    _ = b.step(.{ .pad2 = .{ .start = true } }, true, null);
    _ = a.step(.{}, true, null);
    try testing.expect(a.hash() != b.hash());
}

test "the settings come from the storage: a whole record is kept, a damaged one told" {
    var store = memory.MemoryStorage.init(testing.allocator);
    defer store.deinit();
    var s: settings_mod.Settings = .{};
    _ = s.bindKey(.{ .player = .{ .player = 0, .button = .start } }, .p);
    try settings_mod.record.save(store.storage(), &s);
    var game = try Game.init(testing.allocator, null, store.storage());
    defer game.deinit();
    try testing.expectEqual(@as(u64, 1), game.loads_done);
    try testing.expectEqual(Notice.none, game.notice);
    try testing.expectEqual(platform.Key.p, game.controls.layout.players[0].keys[@backingInt(input.Button.start)]);
    try testing.expect(game.usesKey(.p) and !game.usesKey(.enter));
    // The settings key is the original's alone.
    try testing.expect(!game.usesKey(.f1));
    game.variant = .original;
    try testing.expect(game.usesKey(.f1));

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

test "a hold's sound fades out, and the next tick's fades in" {
    var game = try Game.init(testing.allocator, null, null);
    defer game.deinit();
    // Four stereo frames: the ramp's gains are 4/4 to 1/4 out, 0/4 to 3/4 in.
    const frames = [_]i16{ 400, -400, 400, -400, 400, -400, 400, -400 };
    try testing.expectEqualSlices(i16, &.{ 400, -400, 300, -300, 200, -200, 100, -100 }, game.fade(&frames, .out));
    try testing.expectEqualSlices(i16, &.{ 0, 0, 100, -100, 200, -200, 300, -300 }, game.fade(&frames, .in));
}

test "without the content's look, no settings screen; without network play, both players here" {
    var game = try Game.init(testing.allocator, null, null);
    defer game.deinit();
    game.showSettings(null);
    try testing.expect(!game.settingsOpen());
    try testing.expect(game.plays(0) and game.plays(1));
}

test "a client's pad by its own CONTROL, carried into the game's: each action's button" {
    const own: content_screens.Layout = .{ .special = .c, .attack = .a, .jump = .b };
    const game: content_screens.Layout = .{};
    // Its A attacks: the game's attack button, B.
    try std.testing.expectEqual(input.Pad{ .b = true, .left = true }, Game.relayout(.{ .a = true, .left = true }, own, game));
    // Its C, the special attack: the game's A; its B, the jump: the game's C.
    try std.testing.expectEqual(input.Pad{ .a = true, .c = true, .start = true }, Game.relayout(.{ .c = true, .b = true, .start = true }, own, game));
    try std.testing.expectEqual(input.Pad{ .a = true }, Game.relayout(.{ .a = true }, game, game));
}

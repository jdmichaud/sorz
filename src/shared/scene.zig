//! The game's scenes (DESIGN.md 10.4): a stack whose top scene takes the pads at each display tick,
//! advances, and draws its state. A scene ends with an exit, and the flow graph (flow.zig) says
//! which scene follows, and the load after its set-up if the original waited there. A load is an
//! overlay, a scene pushed over the new one (S3): it holds it, dark, for the measured time.
//!
//! The stack holds one scene of the flow, its base, and the overlays over it, each of the overlays'
//! own kinds (`Overlay`): the canonical state then holds the largest scene, a round with its world,
//! once, and an overlay costs only its own state.
//!
//! Each scene is a struct with:
//! - its state, plain values, part of the game's canonical state (no pointer, no slice);
//! - `start(setup)`, its state when it begins; its first tick is its set-up;
//! - `Assets`, the content it draws and plays, found by name when the game starts (library.zig);
//! - `tick(turn, assets)`, one display tick: the pads, the sounds it asks for, its exit if it ends;
//! - `layout`, the boards its picture needs, and `draw(prev, view, assets)`, which draws its state
//!   on the view: whole when `prev` is null (a new picture), else what changed since `prev`, the
//!   state it last drew. Sprites and colours are given again at every draw.
//!
//! The screens run their logic every display tick, but the character select, which runs at
//! play's rate (a tick of two display ticks, as `world/schedule.zig` says of play). Two of the
//! original's rules hold for every screen, as measured against sor-remaster:
//! - **The picture's colours and sprites are a tick late**: the console takes them as a frame
//!   starts, so a tick's colours and sprites show at the next tick that runs (after a load, at the
//!   first tick after it); its tiles show at once. Each scene latches what it shows at the start of
//!   its tick (`Shown`).
//! - **A set-up releases the pads**: a scene's set-up counts every button as held, and a load reads
//!   no pad, so a button held across a screen's change is not a press until it is pressed again
//!   (`Turn.release_pads`).
const std = @import("std");
const input = @import("input.zig");
const flow = @import("flow.zig");
const library = @import("library.zig");
const json = @import("formats/json.zig");
const View = @import("view.zig").View;
const Setup = @import("setup.zig").Setup;
const transfers = @import("screens/transfers.zig");
const content_round = @import("content/round.zig");
const world = @import("world/root.zig");
const variant = @import("variant.zig");

pub const Kind = flow.Kind;
pub const Exit = flow.Exit;
pub const TestPattern = @import("screens/test_pattern.zig").TestPattern;
pub const Load = @import("screens/load.zig").Load;
pub const StandIn = @import("screens/stand_in.zig").StandIn;
pub const Round = @import("screens/round.zig").Round;
pub const RoundClear = @import("screens/round_clear.zig").RoundClear;
pub const SegaLogo = @import("screens/sega_logo.zig").SegaLogo;
pub const Menu = @import("screens/menu.zig").Menu;
pub const Options = @import("screens/options.zig").Options;
pub const HighScores = @import("screens/high_scores.zig").HighScores;
pub const Intro = @import("screens/intro.zig").Intro;
pub const Ending = @import("screens/ending.zig").Ending;
pub const BossEnding = @import("screens/boss_ending.zig").BossEnding;
pub const Title = @import("screens/title.zig").Title;
pub const Select = @import("screens/select.zig").Select;

/// The scenes' state, by kind.
pub const Scene = union(Kind) {
    test_pattern: TestPattern,
    load: Load,
    sega_logo: SegaLogo,
    intro: Intro,
    title: Title,
    menu: Menu,
    options: Options,
    select: Select,
    demo: Round,
    high_scores: HighScores,
    round: Round,
    round_clear: RoundClear,
    next_round: StandIn,
    ending: Ending,
    boss_ending: BossEnding,

    /// The scene of kind `k` as it begins (a load is pushed by the flow, with its length).
    pub fn start(k: Kind, setup: *const Setup) Scene {
        return switch (k) {
            .test_pattern => .{ .test_pattern = .{} },
            .load => unreachable,
            inline else => |tag| blk: {
                const T = @FieldType(Scene, @tagName(tag));
                // The attract demo is a round the game plays itself.
                if (tag == .demo) break :blk .{ .demo = Round.startDemo(setup) };
                break :blk @unionInit(Scene, @tagName(tag), if (T == StandIn) StandIn.of(tag, setup) else T.start(setup));
            },
        };
    }
};

/// The sounds a tick asks for, in order (the sequencer takes three a tick at most, and drops the
/// rest as the original's driver does).
pub const Requests = struct {
    items: [4]library.Sound = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Requests) []const library.Sound {
        return self.items[0..self.len];
    }
};

/// A display tick at which the sound's driver runs alone (`Turn.lag`).
pub const Lag = enum { none, middle, load };

/// What a scene's tick has: the pads and the setup the screens share; and what it gives: the sounds
/// it asks for, and what it asks of the pads and the sound's driver.
/// This machine's part in network play as its menus see it (game.zig gives it).
pub const Net = struct {
    role: variant.NetRole = .none,
    /// The host: its session is open (the network options' START), and whether the two players
    /// may choose one character there.
    hosting: bool = false,
    same_character: bool = false,
    /// A client: the host takes a player now (JOIN), or an observer (OBSERVE); its player's name
    /// is given.
    can_join: bool = false,
    can_observe: bool = false,
    named: bool = true,
    name: [3]u8 = .{ ' ', ' ', ' ' },
};

pub const NetRequest = enum { network_options, observe, name };

pub const Turn = struct {
    /// The buttons held at this tick, and those newly held (held now, not at the last reading).
    pads: input.Pads = .{},
    pressed: input.Pads = .{},
    /// Whether a second pad is there (the game menu dims 2 PLAYERS without it): a second player
    /// on this machine, or network play's, whose second player is another machine's.
    second_pad: bool = true,
    /// This machine's game takes the game's rules from another machine's (network play's guest):
    /// OPTIONS shows only what is this machine's own.
    guest: bool = false,
    /// A character another machine's player plays (network play: the host's player 1, while this
    /// machine's player chooses theirs to join its game): the character select's cursor passes
    /// it and cannot choose it.
    taken: ?@import("setup.zig").Character = null,
    /// This machine's settings' rules, which the game menu gives the game it starts where the
    /// variant takes them (`Policies.settings_rules`).
    rules: @import("setup.zig").Rules = .{},
    /// This machine's part in network play, for its own menus (DESIGN.md 9).
    net: Net = .{},
    /// What the game menu asks of this machine (game.zig): the network options (NETWORK PLAY),
    /// to watch the host's game (OBSERVE), the name entry (NAME).
    net_request: ?NetRequest = null,
    setup: *Setup,
    /// The variant's rules (variant.zig), which the scenes ask rather than the variant.
    policies: *const variant.Policies = &variant.original.policies,
    requests: Requests = .{},
    /// The player who asked for the settings at this tick (OPTIONS' ADVANCED SETTINGS, START
    /// during play where the variant says so): the game opens them over the scenes, on that
    /// player's machine (game.zig).
    settings: ?u1 = null,
    /// They were asked for from the options, which faded out first: they fade in and out as the
    /// menus' screens do, without the pause's jingle.
    settings_fade: bool = false,
    /// The sounds asked for in the first half of a logic tick of play (its players'), which the
    /// sound's driver takes at the frame in the logic tick's middle: this tick's update, before
    /// `requests`, which it takes at the next.
    requests_now: Requests = .{},
    /// Whether the sound's driver runs at this tick: a load holds it, as the original's do.
    sound_driver: bool = true,
    /// Whether the pads are read at this tick: a load reads none.
    read_pads: bool = true,
    /// The pads read at this tick are the attract demo's (its stream: the reading takes longer).
    demo_pads: bool = false,
    /// A display tick that ends no frame of the logic, at which the sound's driver runs alone,
    /// without a frame's work: `middle`, an interrupt a load left waiting, which the logic takes
    /// in its middle (the requests of the ticks before come after it); `load`, one of a load that
    /// leaves the interrupts on (the requests of the set-up before it come first).
    lag: Lag = .none,
    /// Set by a set-up: every button counts as held, so that none is pressed at the next reading.
    release_pads: bool = false,
    /// Set by the start-up: the sound's driver starts again from its first state (the original
    /// loads it again), which stops every sound at its next update.
    sound_restart: bool = false,
    /// What this tick's picture transfers as the next frame starts (screens/transfers.zig);
    /// null for a tick that ends no frame (a load's, a tick split in two).
    frame: ?transfers.Frame = null,
    /// The art the frame that follows decodes of what play streams in (the middle of a logic
    /// tick's frames too).
    streamed: content_round.Streamed = .{},
    /// The game's random generator (the canonical state's), which play draws from; null in the
    /// tests of scenes that draw none.
    random: ?*world.Random = null,
    /// Where a round's world gives out its tick (the presentation's, the view's), when there is
    /// a picture.
    world_out: ?*world.Output = null,

    /// A set-up's release of the pads: no button is pressed at this tick, and every button counts
    /// as held at the next reading.
    pub fn releasePads(self: *Turn) void {
        self.release_pads = true;
        self.pressed = .{};
    }

    pub fn play(self: *Turn, s: library.Sound) void {
        if (self.requests.len == self.requests.items.len) return;
        self.requests.items[self.requests.len] = s;
        self.requests.len += 1;
    }

    /// `play`, for a sound of a logic tick's first half (`requests_now`).
    pub fn playNow(self: *Turn, s: library.Sound) void {
        if (self.requests_now.len == self.requests_now.items.len) return;
        self.requests_now.items[self.requests_now.len] = s;
        self.requests_now.len += 1;
    }
};

/// Every scene's content, found by name when the game starts.
pub const Assets = struct {
    load: Load.Assets,
    stand_in: StandIn.Assets,
    round: Round.Assets,
    round_clear: RoundClear.Assets,
    sega_logo: SegaLogo.Assets,
    menu: Menu.Assets,
    options: Options.Assets,
    high_scores: HighScores.Assets,
    intro: Intro.Assets,
    ending: Ending.Assets,
    boss_ending: BossEnding.Assets,
    title: Title.Assets,
    select: Select.Assets,

    pub fn find(c: *const library.Content, diag: *json.Diagnostic) library.LoadError!Assets {
        var a: Assets = undefined;
        const info = @typeInfo(Assets).@"struct";
        inline for (info.field_names, info.field_types) |name, T| @field(a, name) = try library.find(T, c, diag);
        return a;
    }
};

/// The scenes of the game that go over another and hold it by their own rule (S3), by kind: the
/// flow's loads. An overlay ends by itself (a load when its ticks are over), and is taken off. The
/// overlays of one machine (the settings screen, network play's notice that the other player is in
/// theirs, a notice about the settings record) are not the game's: they are not in its canonical
/// state, which the two machines of network play share, but over it (overlay.zig, game.zig).
pub const Overlay = union(enum) {
    load: Load,

    /// Its kind of scene.
    pub fn kind(self: *const Overlay) Kind {
        return switch (self.*) {
            inline else => |_, tag| @field(Kind, @tagName(tag)),
        };
    }

    /// Its state as a scene's (for the picture's last drawn state).
    pub fn scene(self: *const Overlay) Scene {
        return switch (self.*) {
            inline else => |payload, tag| @unionInit(Scene, @tagName(tag), payload),
        };
    }
};

/// The stack of scenes: the flow's scene at its base, and the overlays over it. Each scene started
/// has a number (`serial`), so that a new scene of the same kind still begins a new picture.
pub const Stack = struct {
    /// The overlays over the base at most.
    pub const overlays_most = 3;

    /// The flow's scene (a load is never one).
    base: Scene = .{ .test_pattern = .{} },
    base_serial: u32 = 0,
    overlays: [overlays_most]Overlay = @splat(.{ .load = .{} }),
    overlay_serials: [overlays_most]u32 = @splat(0),
    /// The overlays over the base.
    overlay_count: u8 = 0,
    /// The scenes started since power-on.
    started: u32 = 1,
    /// The scene that follows at the next tick: the top scene ended, and its last picture stays
    /// until the next scene's set-up.
    next: ?Next = null,
    /// The load that follows the top scene's set-up (0: none), and the set-up's ticks to come.
    load_after_setup: Load = .{},
    setup_left: u8 = 0,

    pub const Next = struct { kind: Kind, load: u16, sound_held: bool, driver_once: bool = false, driver_reloaded: bool = false };

    /// The scene on top: the last overlay, or the base.
    pub const Top = union(enum) { scene: *Scene, overlay: *Overlay };

    pub fn top(self: *Stack) Top {
        if (self.overlay_count == 0) return .{ .scene = &self.base };
        return .{ .overlay = &self.overlays[self.overlay_count - 1] };
    }

    pub fn topKind(self: *const Stack) Kind {
        if (self.overlay_count == 0) return std.meta.activeTag(self.base);
        return self.overlays[self.overlay_count - 1].kind();
    }

    pub fn topSerial(self: *const Stack) u32 {
        if (self.overlay_count == 0) return self.base_serial;
        return self.overlay_serials[self.overlay_count - 1];
    }

    /// The base replaced by `s`, a new scene with its own picture.
    pub fn replace(self: *Stack, s: Scene) void {
        self.base = s;
        self.base_serial = self.serial();
    }

    /// `o` over the scenes, a new scene with its own picture.
    pub fn push(self: *Stack, o: Overlay) error{Full}!void {
        if (self.overlay_count == overlays_most) return error.Full;
        self.overlays[self.overlay_count] = o;
        self.overlay_serials[self.overlay_count] = self.serial();
        self.overlay_count += 1;
    }

    /// Takes the top overlay off; the scene below goes on. The base stays. A place that holds no
    /// overlay is reset, never left as it was (the canonical state covers it).
    pub fn pop(self: *Stack) void {
        if (self.overlay_count == 0) return;
        self.overlay_count -= 1;
        self.overlays[self.overlay_count] = .{ .load = .{} };
        self.overlay_serials[self.overlay_count] = 0;
    }

    fn serial(self: *Stack) u32 {
        defer self.started +%= 1;
        return self.started;
    }
};

/// One display tick of the top scene, and the flow that follows its exit. A load that is over
/// gives its tick to the scene it held. Every scene but the test pattern needs the content's
/// `assets`.
pub fn tick(stack: *Stack, graph: *const flow.Graph, turn: *Turn, assets: ?*const Assets) void {
    switch (stack.top()) {
        .overlay => |o| if (o.* == .load and o.load.left == 0) stack.pop(),
        .scene => {},
    }
    if (stack.next) |n| {
        stack.replace(.start(n.kind, turn.setup));
        const load = if (n.kind == .round and assets != null) roundLoad(assets.?, turn.setup) orelse n.load else n.load;
        stack.load_after_setup = .{ .left = load, .sound_held = n.sound_held, .driver_once = n.driver_once, .driver_reloaded = n.driver_reloaded };
        stack.setup_left = setupTicks(n.kind);
        stack.next = null;
    }
    const s = switch (stack.top()) {
        // An overlay holds the scenes under it, and ends by itself.
        .overlay => |o| {
            switch (o.*) {
                inline else => |*payload, tag| _ = payload.tick(turn, assetsOf(assets.?, @field(Kind, @tagName(tag)))),
            }
            return;
        },
        .scene => |s| s,
    };
    const exit = switch (s.*) {
        .test_pattern => |*t| {
            t.tick(turn.pads);
            return;
        },
        inline else => |*payload, tag| payload.tick(turn, assetsOf(assets.?, tag)),
    };
    // The load after a set-up holds the scene from the next tick.
    if (stack.load_after_setup.left != 0) {
        if (stack.setup_left > 1) {
            stack.setup_left -= 1;
        } else {
            stack.push(.{ .load = stack.load_after_setup }) catch unreachable;
            stack.load_after_setup = .{};
        }
    }
    const how = exit orelse return;
    const edge = graph.next(std.meta.activeTag(s.*), how) orelse {
        std.log.warn("the scene {s} ended by {s}, which the flow does not follow", .{ @tagName(s.*), @tagName(how) });
        return;
    };
    stack.next = .{ .kind = edge.to, .load = edge.load, .sound_held = edge.sound_held, .driver_once = edge.driver_once, .driver_reloaded = edge.driver_reloaded };
}

/// The load of the round about to start (the game's next, or the options' first round of a new
/// game), when its content gives one (each round's art takes the original its own time).
fn roundLoad(a: *const Assets, setup: *const Setup) ?u16 {
    const g = setup.progress;
    const number: u8 = if (g.round == 0) setup.first_round + 1 else g.round;
    const r = a.round.rounds.of(number) orelse return null;
    return r.script.load;
}

/// The scenes at power-on: the flow's first scene, its set-up at the first tick, and the original's
/// wait after it.
pub fn powerOn(graph: *const flow.Graph, setup: *const Setup) Stack {
    var s: Stack = .{};
    s.replace(.start(graph.first, setup));
    s.load_after_setup = .{ .left = graph.power_on };
    s.setup_left = setupTicks(graph.first);
    return s;
}

/// The scenes from scene `k`'s set-up, the load `load` (display ticks) after it: a game that goes
/// back to one of its scenes (network play's guest back to its own menu).
pub fn startAt(k: Kind, load: u16, setup: *const Setup) Stack {
    var s: Stack = .{};
    s.replace(.start(k, setup));
    s.load_after_setup = .{ .left = load };
    s.setup_left = setupTicks(k);
    return s;
}

/// What the presentation keeps of the scenes' last tick, made again from their state (a game loaded
/// from another's form: network play's join): a round's world's draw list.
pub fn redrawOutput(stack: *const Stack, out: *world.Output, assets: *const Assets) void {
    out.* = .{};
    switch (stack.base) {
        .round => |*r| r.redrawWorld(out, &assets.round),
        else => {},
    }
}

/// The music the scenes play now, which a game loaded from another's form starts (network play's
/// join): the character select's, a round's.
pub fn music(stack: *const Stack, assets: *const Assets) ?library.Sound {
    return switch (stack.base) {
        .select => |*s| s.music(&assets.select),
        .round => |*r| r.music(&assets.round),
        else => null,
    };
}

/// The ticks a scene's set-up takes before the load after it: one, unless it says otherwise.
fn setupTicks(k: Kind) u8 {
    return switch (k) {
        inline else => |tag| blk: {
            const T = @FieldType(Scene, @tagName(tag));
            break :blk if (@hasDecl(T, "setup_ticks")) T.setup_ticks else 1;
        },
    };
}

/// Draws the top scene on `v`: whole when the view shows another scene (or none), else what
/// changed since `prev`, the state last drawn, which it then holds.
pub fn draw(stack: *Stack, prev: *Scene, v: *View, assets: *const Assets) !void {
    const fresh = v.shows != stack.topSerial() or std.meta.activeTag(prev.*) != stack.topKind();
    switch (stack.top()) {
        .scene => |s| {
            switch (s.*) {
                .test_pattern => unreachable,
                inline else => |*payload, tag| try drawOne(tag, payload, prev, fresh, stack.topSerial(), v, assets),
            }
            prev.* = s.*;
        },
        .overlay => |o| {
            switch (o.*) {
                inline else => |*payload, tag| try drawOne(@field(Kind, @tagName(tag)), payload, prev, fresh, stack.topSerial(), v, assets),
            }
            prev.* = o.scene();
        },
    }
}

/// Draws the scene of kind `k` whose state is `payload`: a new picture when `fresh`.
fn drawOne(comptime k: Kind, payload: anytype, prev: *const Scene, fresh: bool, serial: u32, v: *View, assets: *const Assets) !void {
    const T = @FieldType(Scene, @tagName(k));
    if (fresh) try v.begin(serial, if (@hasDecl(T, "layoutOf")) payload.layoutOf() else T.layout);
    v.sprites.clearRetainingCapacity();
    try payload.draw(if (fresh) null else &@field(prev.*, @tagName(k)), v, assetsOf(assets, k));
}

fn assetsOf(assets: *const Assets, comptime k: Kind) *const @FieldType(Scene, @tagName(k)).Assets {
    const T = @FieldType(Scene, @tagName(k));
    const info = @typeInfo(Assets).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (F == T.Assets) return &@field(assets, name);
    }
    @compileError("no assets for " ++ @typeName(T));
}

const testing = std.testing;

test "the stack: an overlay pushed over the base and taken off; every scene its own number" {
    var s = powerOn(&flow.original, &.{});
    try testing.expect(s.topKind() == .sega_logo and s.load_after_setup.left == flow.original.power_on);
    const first = s.topSerial();
    try s.push(.{ .load = .{ .left = 5 } });
    try testing.expect(s.topSerial() != first and s.topKind() == .load and s.top().overlay.load.left == 5);
    s.pop();
    try testing.expectEqual(first, s.topSerial());
    try testing.expect(s.overlays[0].load.left == 0 and s.overlay_serials[0] == 0);
    s.pop();
    try testing.expect(s.overlay_count == 0 and s.topKind() == .sega_logo);
    for (0..Stack.overlays_most) |_| try s.push(.{ .load = .{} });
    try testing.expectError(error.Full, s.push(.{ .load = .{} }));
}

test "the canonical state's most fits a session's state" {
    const canonical = @import("canonical.zig");
    const protocol = @import("net/protocol.zig");
    try testing.expect(canonical.maxSize(Overlay) < 64);
    // Every place of the world taken, every scene at its largest: still under the most, and the
    // join's sound beside it too.
    try testing.expect(canonical.maxSize(@import("game.zig").State) <= protocol.max_state_len);
    try testing.expect(@import("game.zig").Game.join_max <= protocol.max_state_len);
}

test "the flow: a set-up, its load over the scene, the scene again" {
    var setup: Setup = .{};
    var turn: Turn = .{ .setup = &setup };
    const assets: Assets = undefined;
    // The stand-in needs no content.
    const graph: flow.Graph = .{ .first = .next_round, .power_on = 3, .edges = &.{} };
    var s = powerOn(&graph, &setup);
    // The set-up's tick, then three ticks of the load, then the scene's own ticks.
    tick(&s, &graph, &turn, &assets);
    for (0..3) |_| {
        try testing.expect(s.topKind() == .load);
        tick(&s, &graph, &turn, &assets);
    }
    try testing.expect(s.topKind() == .load and s.top().overlay.load.left == 0);
    tick(&s, &graph, &turn, &assets);
    try testing.expect(s.topKind() == .next_round and s.overlay_count == 0);
    tick(&s, &graph, &turn, &assets);
    try testing.expect(s.topKind() == .next_round and s.next == null);
}

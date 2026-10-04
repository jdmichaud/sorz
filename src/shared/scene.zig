//! The game's scenes (DESIGN.md 10.4): a stack whose top scene takes the pads at each display tick,
//! advances, and draws its state. A scene ends with an exit, and the flow graph (flow.zig) says
//! which scene follows, and the load after its set-up if the original waited there. A load is a
//! scene pushed over the new one (S3): it holds it, dark, for the measured time.
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
//! Two of the original's rules hold for every screen (`docs/screens.md`):
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

pub const Kind = flow.Kind;
pub const Exit = flow.Exit;
pub const TestPattern = @import("screens/test_pattern.zig").TestPattern;
pub const Load = @import("screens/load.zig").Load;
pub const StandIn = @import("screens/stand_in.zig").StandIn;
pub const SegaLogo = @import("screens/sega_logo.zig").SegaLogo;
pub const Menu = @import("screens/menu.zig").Menu;
pub const Options = @import("screens/options.zig").Options;
pub const Intro = @import("screens/intro.zig").Intro;
pub const Title = @import("screens/title.zig").Title;

/// The scenes' state, by kind.
pub const Scene = union(Kind) {
    test_pattern: TestPattern,
    load: Load,
    sega_logo: SegaLogo,
    intro: Intro,
    title: Title,
    menu: Menu,
    options: Options,
    select: StandIn,
    demo: StandIn,
    high_scores: StandIn,
    round: StandIn,

    /// The scene of kind `k` as it begins (a load is pushed by the flow, with its length).
    pub fn start(k: Kind, setup: *const Setup) Scene {
        return switch (k) {
            .test_pattern => .{ .test_pattern = .{} },
            .load => unreachable,
            inline else => |tag| blk: {
                const T = @FieldType(Scene, @tagName(tag));
                break :blk @unionInit(Scene, @tagName(tag), if (T == StandIn) StandIn.of(tag) else T.start(setup));
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

/// What a scene's tick has: the pads and the setup the screens share; and what it gives: the sounds
/// it asks for, and what it asks of the pads and the sound's driver.
pub const Turn = struct {
    /// The buttons held at this tick, and those newly held (held now, not at the last reading).
    pads: input.Pads = .{},
    pressed: input.Pads = .{},
    /// Whether a second pad is there (the game menu dims 2 PLAYERS without it).
    second_pad: bool = true,
    setup: *Setup,
    requests: Requests = .{},
    /// Whether the sound's driver runs at this tick: a load holds it, as the original's do.
    sound_driver: bool = true,
    /// Whether the pads are read at this tick: a load reads none.
    read_pads: bool = true,
    /// Set by a set-up: every button counts as held, so that none is pressed at the next reading.
    release_pads: bool = false,
    /// Set by the start-up: the sound's driver starts again from its first state (the original
    /// loads it again), which stops every sound at its next update.
    sound_restart: bool = false,

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
};

/// Every scene's content, found by name when the game starts.
pub const Assets = struct {
    load: Load.Assets,
    stand_in: StandIn.Assets,
    sega_logo: SegaLogo.Assets,
    menu: Menu.Assets,
    options: Options.Assets,
    intro: Intro.Assets,
    title: Title.Assets,

    pub fn find(c: *const library.Content, diag: *json.Diagnostic) library.LoadError!Assets {
        var a: Assets = undefined;
        const info = @typeInfo(Assets).@"struct";
        inline for (info.field_names, info.field_types) |name, T| @field(a, name) = try library.find(T, c, diag);
        return a;
    }
};

/// The stack of scenes. Each scene started has a number (`serial`), so that a new scene of the same
/// kind still begins a new picture.
pub const Stack = struct {
    pub const capacity = 4;

    items: [capacity]Scene = .{ .{ .test_pattern = .{} }, .{ .load = .{} }, .{ .load = .{} }, .{ .load = .{} } },
    serials: [capacity]u32 = @splat(0),
    len: u8 = 1,
    /// The scenes started since power-on.
    started: u32 = 1,
    /// The scene that follows at the next tick: the top scene ended, and its last picture stays
    /// until the next scene's set-up.
    next: ?Next = null,
    /// The load that follows the top scene's set-up (0: none), and the set-up's ticks to come.
    load_after_setup: Load = .{},
    setup_left: u8 = 0,

    pub const Next = struct { kind: Kind, load: u16, sound_held: bool };

    pub fn top(self: *Stack) *Scene {
        return &self.items[self.len - 1];
    }

    pub fn topSerial(self: *const Stack) u32 {
        return self.serials[self.len - 1];
    }

    /// The top scene replaced by `s`, a new scene with its own picture.
    pub fn replace(self: *Stack, s: Scene) void {
        self.items[self.len - 1] = s;
        self.serials[self.len - 1] = self.started;
        self.started +%= 1;
    }

    pub fn push(self: *Stack, s: Scene) error{Full}!void {
        if (self.len == capacity) return error.Full;
        self.len += 1;
        self.replace(s);
    }

    /// Takes the top scene off; the one below goes on. The bottom scene stays. A place that holds
    /// no scene is reset, never left as it was (the canonical state covers it).
    pub fn pop(self: *Stack) void {
        if (self.len == 1) return;
        self.len -= 1;
        self.items[self.len] = .{ .load = .{} };
        self.serials[self.len] = 0;
    }
};

/// One display tick of the top scene, and the flow that follows its exit. A load that is over
/// gives its tick to the scene it held. Every scene but the test pattern needs the content's
/// `assets`.
pub fn tick(stack: *Stack, graph: *const flow.Graph, turn: *Turn, assets: ?*const Assets) void {
    if (stack.top().* == .load and stack.top().load.left == 0) stack.pop();
    if (stack.next) |n| {
        stack.replace(.start(n.kind, turn.setup));
        stack.load_after_setup = .{ .left = n.load, .sound_held = n.sound_held };
        stack.setup_left = setupTicks(n.kind);
        stack.next = null;
    }
    const s = stack.top();
    const exit = switch (s.*) {
        .test_pattern => |*t| {
            t.tick(turn.pads);
            return;
        },
        inline else => |*payload, tag| payload.tick(turn, assetsOf(assets.?, tag)),
    };
    // The load after a set-up holds the scene from the next tick.
    if (stack.load_after_setup.left != 0 and s.* != .load) {
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
    stack.next = .{ .kind = edge.to, .load = edge.load, .sound_held = edge.sound_held };
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
    const s = stack.top();
    const fresh = v.shows != stack.topSerial() or std.meta.activeTag(prev.*) != std.meta.activeTag(s.*);
    if (fresh) {
        const layout = switch (s.*) {
            .test_pattern => unreachable,
            inline else => |*payload, tag| blk: {
                const T = @FieldType(Scene, @tagName(tag));
                break :blk if (@hasDecl(T, "layoutOf")) payload.layoutOf() else T.layout;
            },
        };
        try v.begin(stack.topSerial(), layout);
    }
    v.sprites.clearRetainingCapacity();
    switch (s.*) {
        .test_pattern => unreachable,
        inline else => |*payload, tag| {
            const a = assetsOf(assets, tag);
            try payload.draw(if (fresh) null else &@field(prev.*, @tagName(tag)), v, a);
        },
    }
    prev.* = s.*;
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

test "the stack: a scene pushed over another and taken off; every scene its own number" {
    var s = powerOn(&flow.original, &.{});
    try testing.expect(s.top().* == .sega_logo and s.load_after_setup.left == flow.original.power_on);
    const first = s.topSerial();
    try s.push(.{ .test_pattern = .{} });
    try testing.expect(s.topSerial() != first);
    s.pop();
    try testing.expectEqual(first, s.topSerial());
    try testing.expect(s.items[1] == .load);
    s.pop();
    try testing.expectEqual(@as(u8, 1), s.len);
    for (1..Stack.capacity) |_| try s.push(.{ .test_pattern = .{} });
    try testing.expectError(error.Full, s.push(.{ .test_pattern = .{} }));
}

test "the flow: a set-up, its load over the scene, the scene again; an exit, its edge" {
    var setup: Setup = .{};
    var turn: Turn = .{ .setup = &setup };
    const assets: Assets = undefined;
    // The stand-ins need no content.
    const graph: flow.Graph = .{ .first = .demo, .power_on = 3, .edges = &.{
        .{ .from = .demo, .exit = .done, .to = .round, .load = 2 },
    } };
    var s = powerOn(&graph, &setup);
    // The set-up's tick, then three ticks of the load, then the scene's own ticks.
    tick(&s, &graph, &turn, &assets);
    for (0..3) |_| {
        try testing.expect(s.top().* == .load);
        tick(&s, &graph, &turn, &assets);
    }
    try testing.expect(s.top().* == .load and s.top().load.left == 0);
    tick(&s, &graph, &turn, &assets);
    try testing.expect(s.top().* == .demo and s.len == 1);
    var ticks: usize = 0;
    while (s.next == null) : (ticks += 1) {
        try testing.expect(ticks < 10_000);
        tick(&s, &graph, &turn, &assets);
    }
    // The demo's last picture stays; the next scene's set-up at the next tick, then its load.
    try testing.expect(s.top().* == .demo and s.next.?.kind == .round);
    tick(&s, &graph, &turn, &assets);
    try testing.expect(s.top().* == .load and s.items[0] == .round);
}

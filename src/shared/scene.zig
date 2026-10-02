//! The game's scenes (DESIGN.md 10.4): a stack whose top scene takes the pads at each display tick,
//! advances, and draws its state. A scene ends with an exit, and the flow graph (flow.zig) says
//! which scene follows, after a load if the original waited there. An overlay (S3: the settings,
//! network play's messages, the pause) will be a scene pushed over another.
//!
//! Each scene is a struct with:
//! - its state, plain values, part of the game's canonical state (no pointer, no slice);
//! - `start(setup)`, its state when it begins;
//! - `Assets`, the content it draws and plays, found by name when the game starts (library.zig);
//! - `tick(turn, assets)`, one display tick: the pads, the sounds it asks for, its exit if it ends;
//! - `layout`, the boards its picture needs, and `draw(prev, view, assets)`, which draws its state
//!   on the view: whole when `prev` is null (a new picture), else what changed since `prev`, the
//!   state it last drew. Sprites and colours are given again at every draw.
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

/// The scenes' state, by kind.
pub const Scene = union(Kind) {
    test_pattern: TestPattern,
    load: Load,
    sega_logo: StandIn,
    intro: StandIn,
    title: StandIn,
    menu: StandIn,
    options: StandIn,
    select: StandIn,
    demo: StandIn,
    high_scores: StandIn,
    round: StandIn,

    /// The scene of kind `k` as it begins (a load is begun by the flow, with its length).
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
/// it asks for.
pub const Turn = struct {
    /// The buttons held at this tick, and those newly held (held now, not at the last tick).
    pads: input.Pads = .{},
    pressed: input.Pads = .{},
    /// Whether a second pad is there (the game menu dims 2 PLAYERS without it).
    second_pad: bool = true,
    setup: *Setup,
    requests: Requests = .{},
    /// Whether the sound's driver runs at this tick: a load holds it, as the original's do.
    sound_driver: bool = true,

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

/// One display tick of the top scene, and the flow that follows its exit. Every scene but the test
/// pattern needs the content's `assets`.
pub fn tick(stack: *Stack, graph: *const flow.Graph, turn: *Turn, assets: ?*const Assets) void {
    const s = stack.top();
    const exit = switch (s.*) {
        .test_pattern => |*t| {
            t.tick(turn.pads);
            return;
        },
        inline else => |*payload, tag| payload.tick(turn, assetsOf(assets.?, tag)),
    } orelse return;
    // A load ends into the scene it was for.
    if (s.* == .load) return stack.replace(.start(s.load.next, turn.setup));
    const edge = graph.next(std.meta.activeTag(s.*), exit) orelse {
        std.log.warn("the scene {s} ended by {s}, which the flow does not follow", .{ @tagName(s.*), @tagName(exit) });
        return;
    };
    if (edge.load != 0) {
        stack.replace(.{ .load = .{ .next = edge.to, .left = edge.load, .sound_held = edge.sound_held } });
    } else stack.replace(.start(edge.to, turn.setup));
}

/// The state of the scene before `stack`'s top scene at power-on: the flow's first scene after its
/// power-on load.
pub fn powerOn(graph: *const flow.Graph) Stack {
    var s: Stack = .{};
    s.replace(.{ .load = .{ .next = graph.first, .left = graph.power_on } });
    return s;
}

/// Draws the top scene on `v`: whole when the view shows another scene (or none), else what
/// changed since `prev`, the state last drawn, which it then holds.
pub fn draw(stack: *Stack, prev: *Scene, v: *View, assets: *const Assets) !void {
    const s = stack.top();
    const fresh = v.shows != stack.topSerial() or std.meta.activeTag(prev.*) != std.meta.activeTag(s.*);
    if (fresh) {
        const layout = switch (s.*) {
            .test_pattern => unreachable,
            inline else => |_, tag| @FieldType(Scene, @tagName(tag)).layout,
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
    var s = powerOn(&flow.original);
    try testing.expect(s.top().* == .load and s.top().load.next == .sega_logo);
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

test "the flow: a load, then the scene it was for; an exit, its edge, and its load" {
    var setup: Setup = .{};
    var turn: Turn = .{ .setup = &setup };
    const assets: Assets = undefined;
    var s = powerOn(&flow.original);
    for (0..flow.original.power_on) |_| {
        try testing.expect(s.top().* == .load);
        tick(&s, &flow.original, &turn, &assets);
    }
    try testing.expect(s.top().* == .sega_logo);
    const graph: flow.Graph = .{ .first = .sega_logo, .power_on = 1, .edges = &.{
        .{ .from = .sega_logo, .exit = .done, .to = .intro, .load = 2 },
    } };
    var ticks: usize = 0;
    while (s.top().* == .sega_logo) : (ticks += 1) {
        try testing.expect(ticks < 10_000);
        tick(&s, &graph, &turn, &assets);
    }
    try testing.expect(s.top().* == .load and s.top().load.next == .intro);
    tick(&s, &graph, &turn, &assets);
    try testing.expect(s.top().* == .load);
    tick(&s, &graph, &turn, &assets);
    try testing.expect(s.top().* == .intro);
}

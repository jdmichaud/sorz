//! The behaviours (DESIGN.md W3): the code of the kinds of entity, each a state machine with
//! named states. A definition names its behaviour (`"behaviour": "sparring"`); its states are
//! code, their numbers the definition's data. A new kind of enemy is a definition, and a module
//! here when no behaviour fits: the module, and one line in `Mind`.
//!
//! A behaviour module declares:
//! - `Mind`, a struct with defaults: the entity's memory, its field `state` an enum of the named
//!   states (the semantic traces' names), the first the state it starts in;
//! - what it reads of its definition, by name, each optional: `Animation` and `Move` (enums of
//!   the animations and moves it starts), `Numbers` (a struct of the numbers it reads: whole
//!   numbers, or `Fixed` for speeds in 1/65536 pixel), `Sound` (an enum of the sounds it asks
//!   for). Binding the kinds refuses a definition that lacks one (kinds.zig);
//! - its hooks, each optional, each taking its `Actor` first (tick.zig): `control(a, command)` for
//!   the entity a player plays, `think(a)` for the others, `struck(a, blow) bool` (whether it
//!   takes a blow that meets its body; by default it does), `landed(a)`, `grabbable(a, by) bool`,
//!   `holds(a, held)`, `heldBy(a, holder)`, `picks(a, item)`, `pickedUp(a, by) bool` (whether
//!   the item stays in the world; by default it goes).
//!
//! `sparring` and `pawn` are synthetic: the enemy and the player of the world's tests, and the
//! pattern of the original's characters and enemies (PLAN items 11 and 12).
const std = @import("std");

/// No behaviour: the entity does nothing of its own (a prop, an effect that only animates).
pub const none = struct {};
pub const sparring = @import("behaviours/sparring.zig");
pub const pawn = @import("behaviours/pawn.zig");

/// An entity's behaviour and its memory: one line a behaviour module.
pub const Mind = union(enum) {
    none,
    sparring: sparring.Mind,
    pawn: pawn.Mind,
};

pub const Behaviour = std.meta.Tag(Mind);

/// The module of behaviour `b`.
pub fn module(comptime b: Behaviour) type {
    return @field(@This(), @tagName(b));
}

/// The behaviour whose module is `M`.
pub fn tagOf(comptime M: type) Behaviour {
    inline for (comptime std.enums.values(Behaviour)) |b| {
        if (module(b) == M) return b;
    }
    @compileError("not a behaviour module");
}

/// The memory of a new entity of behaviour `b`: its first state.
pub fn initial(b: Behaviour) Mind {
    switch (b) {
        .none => return .none,
        inline else => |t| return @unionInit(Mind, @tagName(t), .{}),
    }
}

/// The name of the state the entity is in; null without a behaviour.
pub fn stateName(m: *const Mind) ?[]const u8 {
    switch (m.*) {
        .none => return null,
        inline else => |*x| return @tagName(x.state),
    }
}

comptime {
    for (std.enums.values(Behaviour)) |b| {
        if (b == .none) continue;
        const M = module(b);
        if (@FieldType(Mind, @tagName(b)) != M.Mind) @compileError("Mind." ++ @tagName(b) ++ " is not its module's Mind");
        if (@typeInfo(@FieldType(M.Mind, "state")) != .@"enum") @compileError(@tagName(b) ++ ".Mind.state is not an enum of states");
    }
}

test "a behaviour's first state and its name" {
    const m = initial(.sparring);
    try std.testing.expectEqualStrings("stand", stateName(&m).?);
    try std.testing.expectEqual(@as(?[]const u8, null), stateName(&initial(.none)));
    try std.testing.expectEqual(Behaviour.pawn, tagOf(pawn));
}

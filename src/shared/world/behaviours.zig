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
//! - its hooks, each optional, each taking its `Actor` first (tick.zig):
//!   - `control(a, command)` for the entity a player plays, `think(a)` for the others, and
//!     `begin(a)` for the others before the blows of the tick;
//!   - `struck(a, blow) bool`: whether it takes a blow that meets its body; with the hook, the
//!     behaviour takes the blow's damage itself, at once or later (`a.takeDamage`); without,
//!     the damage is taken at once;
//!   - `blowLanded(a, target)`: its blow was taken;
//!   - `takeUp(a)`: put in a state from a situation another program recorded, it starts that
//!     state's animation;
//!   - `landed(a)`; `fall(a)`, in the air after its move: whether it lands (`a.land`) and how
//!     it falls (by default it lands when it comes down to the ground, and its definition's
//!     gravity adds to its speed);
//!   - `grabbable(a, by) bool`, `holds(a, held)`, `heldBy(a, holder)`, `letGoBy(a, holder)`
//!     (the hold ended, its holder still at the frame that let go);
//!   - `picks(a, item)`, `pickedUp(a, by) bool` (whether the item stays in the world; by
//!     default it goes);
//!   - `specialCalled(a)`, `specialKnockedDown(a, by, how) bool`: a player called the special
//!     attack, on the screen (`Tick.callSpecial`); it knocks the entity down
//!     (`Tick.specialKnockDown`);
//!   - `leftBehind(a)`: an enemy left behind the camera was brought back to its edge by the
//!     round's script (script.zig);
//!   - `knockedBack(a)`: an enemy on the screen as a player's new life drops in (lives.zig);
//!   - `given(a, item)`: the round's script gave it an item to hold (a breakable's);
//! - `trace_states`, the names the semantic traces give its states when they are not theirs (the
//!   other program numbers some types' states): `traceName`;
//! - `drives_animation`, true when its behaviour advances its animation's frames itself, as the
//!   original's players do (`a.step()`), and keeps its boxes (`a.showBoxes()`): the animation
//!   system then only notes the frame it shows.
//!
//! `sparring` and `pawn` are synthetic: the enemy and the player of the world's tests. `player`
//! is the original's players' (PLAN item 11); `galsia` round 1's Galsias', on the enemies' common
//! body (behaviours/enemy.zig, not a behaviour of its own: the states every enemy shares);
//! `special_knockdown` the special attack's own, which brings its `police_car`, then player 1's
//! `special_blast` or player 2's `special_fire`; `go_arrow` the arrow a section's opening shows,
//! `player_waiting` a player out of lives (PLAN item 13); round 1's other enemies, `stalker`,
//! `signal`, `galsia_pipe`, `galsia_knife`, `acrobat`, `brawler`, their weapons (`weapon`,
//! `knife`, and the `bat` a breakable holds, with its `bat_splinter`s), the rolling `shutter`,
//! `breakable` and `item` the street's breakables and what they leave, round 1's boss `antonio`
//! and his `boomerang`, and the `hit_spark` a player's blow makes (PLAN item 12).
const std = @import("std");

/// No behaviour: the entity does nothing of its own (a prop, an effect that only animates).
pub const none = struct {};
pub const sparring = @import("behaviours/sparring.zig");
pub const pawn = @import("behaviours/pawn.zig");
pub const player = @import("behaviours/player.zig");
pub const galsia = @import("behaviours/galsia.zig");
pub const stalker = @import("behaviours/stalker.zig");
pub const signal = @import("behaviours/signal.zig");
pub const galsia_pipe = @import("behaviours/galsia_pipe.zig");
pub const galsia_knife = @import("behaviours/galsia_knife.zig");
pub const acrobat = @import("behaviours/acrobat.zig");
pub const brawler = @import("behaviours/brawler.zig");
pub const shutter = @import("behaviours/shutter.zig");
pub const weapon = @import("behaviours/weapon.zig");
pub const knife = @import("behaviours/knife.zig");
pub const bat = @import("behaviours/bat.zig");
pub const bat_splinter = @import("behaviours/bat_splinter.zig");
pub const hit_spark = @import("behaviours/hit_spark.zig");
pub const breakable = @import("behaviours/breakable.zig");
pub const item = @import("behaviours/item.zig");
pub const antonio = @import("behaviours/antonio.zig");
pub const boomerang = @import("behaviours/boomerang.zig");
pub const police_car = @import("behaviours/police_car.zig");
pub const special_knockdown = @import("behaviours/special_knockdown.zig");
pub const special_blast = @import("behaviours/special_blast.zig");
pub const special_fire = @import("behaviours/special_fire.zig");
pub const go_arrow = @import("behaviours/go_arrow.zig");
pub const player_waiting = @import("behaviours/player_waiting.zig");

/// An entity's behaviour and its memory: one line a behaviour module.
pub const Mind = union(enum) {
    none,
    sparring: sparring.Mind,
    pawn: pawn.Mind,
    player: player.Mind,
    galsia: galsia.Mind,
    stalker: stalker.Mind,
    signal: signal.Mind,
    galsia_pipe: galsia_pipe.Mind,
    galsia_knife: galsia_knife.Mind,
    acrobat: acrobat.Mind,
    brawler: brawler.Mind,
    shutter: shutter.Mind,
    weapon: weapon.Mind,
    knife: knife.Mind,
    bat: bat.Mind,
    bat_splinter: bat_splinter.Mind,
    hit_spark: hit_spark.Mind,
    breakable: breakable.Mind,
    item: item.Mind,
    antonio: antonio.Mind,
    boomerang: boomerang.Mind,
    police_car: police_car.Mind,
    special_knockdown: special_knockdown.Mind,
    special_blast: special_blast.Mind,
    special_fire: special_fire.Mind,
    go_arrow: go_arrow.Mind,
    player_waiting: player_waiting.Mind,
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

/// Whether the behaviour of `m` advances its entity's animation itself.
pub fn drivesAnimation(m: *const Mind) bool {
    switch (m.*) {
        .none => return false,
        inline else => |_, tag| {
            const M = module(tag);
            return @hasDecl(M, "drives_animation") and M.drives_animation;
        },
    }
}

/// Puts the behaviour of `m` in its state named `name` (a situation another program recorded,
/// converted; a module's `trace_states` names its states as the other program's traces do, when
/// they have no names there): false when it has no state of that name.
pub fn setState(m: *Mind, name: []const u8) bool {
    switch (m.*) {
        .none => return false,
        inline else => |*x, tag| {
            const M = module(tag);
            if (@hasDecl(M, "trace_states")) {
                for (M.trace_states) |p| if (std.mem.eql(u8, p.name, name)) {
                    x.state = p.state;
                    return true;
                };
            }
            const S = @TypeOf(x.state);
            x.state = std.meta.stringToEnum(S, name) orelse return false;
            return true;
        },
    }
}

/// The place of the state the entity is in among its behaviour's states (0, the first, without a
/// behaviour).
pub fn stateIndex(m: *const Mind) usize {
    switch (m.*) {
        .none => return 0,
        inline else => |*x| return @backingInt(x.state),
    }
}

/// The name of the state the entity is in; null without a behaviour.
pub fn stateName(m: *const Mind) ?[]const u8 {
    switch (m.*) {
        .none => return null,
        inline else => |*x| return @tagName(x.state),
    }
}

/// The way in of an enemy that has come in already (one that came out of a shutter or waited):
/// its module's `plain_entrance`, else closing in.
pub fn plainEntrance(m: *const Mind) @import("entity.zig").Entrance {
    switch (m.*) {
        inline else => |_, tag| {
            if (tag == .none) return .close_in;
            const M = module(tag);
            return if (@hasDecl(M, "plain_entrance")) M.plain_entrance else .close_in;
        },
    }
}

/// The name the semantic traces give the state the entity is in: its module's `trace_states`
/// name for it, else its own.
pub fn traceName(m: *const Mind) ?[]const u8 {
    switch (m.*) {
        .none => return null,
        inline else => |*x, tag| {
            const M = module(tag);
            if (@hasDecl(M, "trace_states")) {
                for (M.trace_states) |p| if (p.state == x.state) return p.name;
            }
            return @tagName(x.state);
        },
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

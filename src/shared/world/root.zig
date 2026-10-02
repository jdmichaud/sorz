//! The world of a round (DESIGN.md 10.3): entities in a fixed pool with stable handles, their
//! typed fields and their behaviours' state machines, the systems that run a logic tick in their
//! order, and the draw list that feeds the renderer.
//!
//! ```
//! const kinds = try world.Kinds.bind(arena, content.entities, &content.art, &diag);
//! var w: world.World = .{};
//! w.players[0].entity = try w.spawn(&kinds, kinds.find("axel").?, .pixels(80, 120, 0), .right);
//! // each logic tick:
//! world.systems.run(&w, &kinds, &game_random, .{ .pads = .{ first, last } }, &out);
//! screen.sprites = out.sprites.slice();
//! ```
pub const fixed = @import("fixed.zig");
pub const random = @import("random.zig");
pub const entity = @import("entity.zig");
pub const behaviours = @import("behaviours.zig");
pub const kinds = @import("kinds.zig");
pub const output = @import("output.zig");
pub const tick = @import("tick.zig");
pub const systems = @import("systems.zig");
pub const draw_list = @import("draw_list.zig");
const world = @import("world.zig");

pub const Fixed = fixed.Fixed;
pub const Vec3 = fixed.Vec3;
pub const Random = random.Random;
pub const Entity = entity.Entity;
pub const Handle = entity.Handle;
pub const Kinds = kinds.Kinds;
pub const Output = output.Output;
pub const World = world.World;
pub const Player = world.Player;
pub const Command = world.Command;
pub const Camera = world.Camera;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests.zig");
}

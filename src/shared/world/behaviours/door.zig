//! The door of Mr. X's room (round 8's: the players' walk in puts it there, world/room.zig). At
//! its second tick it breaks: its sound, its splinters flying (door_splinter.zig) in the weapons'
//! places, as many as are free (the shadows' places that their turns, before the door's, leave),
//! each a little higher than the last, from its next tick; its cells of the round's plane
//! cleared; the room's opening asked for; and it goes. The other program's traces number
//! its states (`trace_states`). Its numbers and its splinters' table are its definition's
//! (`entities/door.json`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const world_mod = @import("../world.zig");
const splinter_mod = @import("door_splinter.zig");
const shadows = @import("../shadows.zig");

const Actor = tick.Actor(@This());

pub const State = enum { start, shut };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .shut },
};

pub const Mind = struct {
    state: State = .start,
};

pub const Animation = enum { shut };
pub const Sound = enum { @"break" };

pub const Numbers = struct {
    splinter_x: i16,
    splinter_depth: i16,
    splinter_rise: i16,
};

pub const Tables = struct {
    splinter_speed_x: [16]i16,
    splinter_speed_up: [16]i16,
    splinter_frame: [16]u8,
    splinter_offset: [16]i16,
};

pub const splinter_kind = "door_splinter";

pub fn think(a: Actor) void {
    const m = a.mind;
    a.entity.flags.still = true;
    switch (m.state) {
        .start => {
            a.animate(.shut);
            a.pause(true);
            m.state = .shut;
        },
        .shut => breaks(a),
    }
}

/// It breaks: its sound; the room's opening asked for; its splinters; its cells cleared; it goes.
fn breaks(a: Actor) void {
    const n = a.numbers();
    const t = a.tables();
    const e = a.entity;
    const w = a.tick.world;
    a.sound(.@"break");
    w.room.opening = true;
    w.room.door_broken = true;
    const kind = a.tick.kinds.find(splinter_kind);
    const places = world_mod.World.weapon_places;
    shadows.turnBefore(a.tick, a.handle.index);
    var height = e.position.height.whole();
    for (0..t.splinter_speed_x.len) |k| {
        const sk = kind orelse break;
        height -= n.splinter_rise;
        const at: fixed.Vec3 = .{
            .x = .pixels(e.position.x.whole() + n.splinter_x + t.splinter_offset[k]),
            .depth = .pixels(e.position.depth.whole() + n.splinter_depth),
            .height = .pixels(height),
        };
        const h = w.spawnWithin(a.tick.kinds, sk, places.from, places.to, at, .right) catch break;
        const s = a.tick.actor(splinter_mod, h) orelse continue;
        // It flies from its next tick (its own turn moves it).
        s.entity.flags.still = true;
        s.entity.velocity = .{ .x = .of(@as(i32, t.splinter_speed_x[k]) << 8), .depth = .zero, .height = .of(@as(i32, t.splinter_speed_up[k]) << 8) };
        s.mind.frame = t.splinter_frame[k];
    }
    a.remove();
}

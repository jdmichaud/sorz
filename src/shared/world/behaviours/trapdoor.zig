//! Mr. X's trapdoors (round 8's room: the offer accepted, world/room.zig puts them in the
//! effects' places). At their first tick: their sound, the floor gone from under the players
//! (the room's `floor_gone`: they fall, and their fall ends the round), the trapdoors open in the
//! round's plane under the players in play (the round scene's picture of them), and they go.
const tick = @import("../tick.zig");

const Actor = tick.Actor(@This());

pub const State = enum { start };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
};

pub const Mind = struct {
    state: State = .start,
};

pub const Sound = enum { open };

pub fn think(a: Actor) void {
    const w = a.tick.world;
    a.entity.flags.hidden = true;
    a.sound(.open);
    w.room.floor_gone = true;
    var players: u2 = 0;
    for (w.players, 0..) |p, k| {
        if (p.entity != null) players |= @as(u2, 1) << @intCast(k);
    }
    w.room.trapdoors = players;
    a.remove();
}

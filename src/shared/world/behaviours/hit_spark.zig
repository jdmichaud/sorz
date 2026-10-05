//! A hit spark: the flash a player's blow makes where it lands (player.zig makes it, at its tick
//! after the blow landed), small, or big for a blow its frame marks so. It shows its one frame
//! for that frame's ticks, still, and goes. Its art is its definition's
//! (`entities/hit_spark.json`).
const tick = @import("../tick.zig");

const Actor = tick.Actor(@This());

pub const State = enum { start, shown };

pub const Mind = struct {
    state: State = .start,
    /// The big spark (a blow its frame marks so).
    big: bool = false,
    /// The ticks left of its frame.
    ticks: u8 = 0,
};

pub const Animation = enum { small, big };

pub fn think(a: Actor) void {
    a.entity.flags.still = true;
    switch (a.mind.state) {
        .start => show(a, 0),
        .shown => {
            a.mind.ticks -|= 1;
            if (a.mind.ticks == 0) a.remove();
        },
    }
}

/// It shows its frame, `ago` ticks of it gone.
fn show(a: Actor, ago: u32) void {
    a.animate(if (a.mind.big) .big else .small);
    a.pause(true);
    a.mind.ticks = @max(1, a.ticksLeft() -| @as(u8, @intCast(@min(ago, 255))));
    a.mind.state = .shown;
}

/// Taken up from a situation `elapsed` ticks after it came: its frame shown as long already
/// (small: the other program's trace does not tell its size).
pub fn takeUp(a: Actor, elapsed: u32) void {
    show(a, elapsed);
}

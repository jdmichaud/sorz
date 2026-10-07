//! A splinter of the door of Mr. X's room (door.zig makes it, its speeds and its frame): it shows
//! its frame and flies, falling, until it lands on the floor; then it goes. Its gravity and frames
//! are its definition's (`entities/door_splinter.json`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { start, flies };

pub const Mind = struct {
    state: State = .start,
    /// Its frame, its maker's.
    frame: u8 = 0,
};

pub const Animation = enum { fly };

pub const Numbers = struct {
    gravity: Fixed,
};

pub fn think(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    e.flags.still = true;
    switch (m.state) {
        .start => {
            a.animate(.fly);
            a.pause(true);
            a.setFrame(m.frame);
            m.state = .flies;
        },
        // It moves, then lands or falls faster.
        .flies => {
            e.position = e.position.add(e.velocity);
            if (a.atGround()) return a.remove();
            e.velocity.height = e.velocity.height.add(a.numbers().gravity);
        },
    }
}

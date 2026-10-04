//! The GO arrow, which shows when a section opens (the round's script, script.zig): fixed on the
//! screen, in front of the layers, it blinks a number of times with its sound; then it goes once
//! the camera has moved since it came, or else waits and blinks again. Its place, blinks and
//! times are its definition's numbers.
const tick = @import("../tick.zig");
const Fixed = @import("../fixed.zig").Fixed;

const Actor = tick.Actor(@This());

pub const State = enum {
    /// Its first tick: it takes its place, shown; it blinks from the next.
    start,
    ready,
    shown,
    hidden,
    /// Its blinks are over and the camera has not moved: it waits to blink again.
    waiting,
};

pub const Mind = struct {
    state: State = .start,
    /// The ticks left of its state, and its blinks left.
    ticks: u8 = 0,
    blinks: u8 = 0,
    /// The camera's place across when it came.
    camera_x: Fixed = .zero,
};

pub const Animation = enum { arrow };
pub const Sound = enum { blink };

pub const Numbers = struct {
    /// Its place on the screen: across, and the depth that puts it at its line.
    x: i16,
    depth: i16,
    /// The blinks in a row, the ticks each is shown and hidden, the wait before the next row.
    blinks: u8,
    shown: u8,
    hidden: u8,
    wait: u8,
};

pub fn think(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    switch (a.mind.state) {
        .start => {
            e.flags.on_screen = true;
            e.flags.in_front = true;
            e.flags.stays = true;
            e.position = .pixels(n.x, n.depth, 0);
            a.mind.camera_x = a.tick.world.camera.x;
            a.mind.state = .ready;
        },
        .ready => {
            a.mind.blinks = n.blinks;
            show(a);
        },
        .shown => {
            a.mind.ticks -|= 1;
            if (a.mind.ticks != 0) return;
            a.mind.state = .hidden;
            a.mind.ticks = n.hidden;
            e.flags.hidden = true;
        },
        .hidden => {
            a.mind.ticks -|= 1;
            if (a.mind.ticks != 0) return;
            if (a.mind.blinks != 0) return show(a);
            if (!a.tick.world.camera.x.eql(a.mind.camera_x)) return a.remove();
            a.mind.state = .waiting;
            a.mind.ticks = n.wait;
        },
        .waiting => {
            a.mind.ticks -|= 1;
            if (a.mind.ticks != 0) return;
            a.mind.blinks = n.blinks;
            show(a);
        },
    }
}

/// A blink: shown for its ticks, with its sound.
fn show(a: Actor) void {
    const n = a.numbers();
    a.mind.blinks -= 1;
    a.mind.state = .shown;
    a.mind.ticks = n.shown;
    a.entity.flags.hidden = false;
    a.sound(.blink);
}

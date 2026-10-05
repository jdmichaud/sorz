//! Round 3's boss's part (boss_r3.zig): what his frames leave out of him, an entity of its own
//! that he places at his place (by his offsets) and shows or hides. Its own states only choose
//! its looks: standing (its frames by its side: the two sides' frames differ), his charge's, its
//! end's (the slam), his hug's. Its animations are its definition's
//! (`entities/boss_r3_part.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const entity = @import("../entity.zig");

const Handle = entity.Handle;
const Actor = tick.Actor(@This());

/// Its states as the original numbers them (the traces name them so): its first, standing (he
/// moves it), the charge's two, the hug's.
pub const State = enum { s0, s1, s2, s3, s4 };

pub const Mind = struct {
    state: State = .s0,
    /// The boss it belongs to.
    boss: ?Handle = null,
    /// The charge goes right (its frames', 1); its slam is due (the charge's end).
    flag: u8 = 0,
    /// The hug's way (his).
    right: bool = false,
};

pub const Animation = enum { stand, stand_left, charge, charge_end, hug };

/// Its first tick: shown standing (he places it).
pub fn think(a: Actor) void {
    a.entity.flags.still = true;
    switch (a.mind.state) {
        .s0 => {
            a.entity.flags.hidden = false;
            a.mind.state = .s1;
            a.entity.facing = .left;
            a.animate(.stand_left);
        },
        .s1 => {},
        .s2 => {
            a.animate(.charge);
            a.entity.facing = if (a.mind.flag != 0) .right else .left;
            a.mind.flag = 0;
            a.mind.state = .s3;
        },
        .s3 => {
            if (a.mind.flag == 0) return;
            a.mind.flag = 0;
            // The slam's frames face the other way (the original's next animation by its own
            // way's bit).
            a.animate(.charge_end);
            a.entity.facing = if (a.entity.facingLeft()) .right else .left;
            a.mind.state = .s1;
        },
        .s4 => {
            a.animate(.hug);
            a.entity.facing = if (a.mind.right) .right else .left;
            a.pause(true);
            a.setFrame(0);
            a.mind.right = false;
            a.mind.state = .s1;
        },
    }
}

/// Its standing frames, by its side.
fn standLook(a: Actor) void {
    a.animate(if (a.entity.facingLeft()) .stand_left else .stand);
}

/// It faces `left` (the boss's way): standing, its frames go with its side, the frame and its
/// ticks kept.
pub fn face(a: Actor, left: bool) void {
    a.entity.facing = if (left) .left else .right;
    const now: Animation = if (left) .stand_left else .stand;
    if (a.plays(.stand) or a.plays(.stand_left)) {
        if (!a.plays(now)) a.retime(now, a.ticksLeft());
    }
}

/// Shown and animated, standing, facing left (the original starts its animation 2 so).
pub fn stand(a: Actor) void {
    a.entity.flags.hidden = false;
    a.entity.facing = .left;
    a.animate(.stand_left);
    a.pause(false);
    a.mind.state = .s1;
}

/// Shown, standing still, facing left (until the boss turns it).
pub fn show(a: Actor) void {
    a.entity.flags.hidden = false;
    a.entity.facing = .left;
    a.animate(.stand_left);
    a.pause(true);
}

/// His charge: the charge's frames from its next tick, its way's.
pub fn charge(a: Actor, right: bool) void {
    a.mind.state = .s2;
    a.mind.flag = @intFromBool(right);
}

/// His slam: the charge's end's frames.
pub fn slam(a: Actor) void {
    a.mind.flag = 1;
}

/// His hug: the hug's frames from its next tick, its way's; hidden until his hug's third stage.
pub fn hug(a: Actor, right: bool) void {
    a.entity.flags.hidden = true;
    a.pause(true);
    a.mind.state = .s4;
    a.mind.right = right;
}

/// The hug's next frame.
pub fn nextFrame(a: Actor) void {
    a.setFrame(a.frame() + 1);
}

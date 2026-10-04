//! The police car of the special attack, a stand-in (PLAN item 11): called by a player
//! (`Tick.callSpecial`), it sends the camera running back across the round (`Camera.run`); once
//! the camera has run back far enough the car comes, and from then its sounds, its blast and the
//! camera's run ahead come at their times; at its end it goes, and play's phase is `special`
//! until then. The original's car drives in and its officer leans out and fires, the shells fall
//! and explode; TODO(PLAN item 13): the car itself and its parts, drawn.
const tick = @import("../tick.zig");
const Fixed = @import("../fixed.zig").Fixed;

const Actor = tick.Actor(@This());

pub const State = enum {
    /// The camera runs back; the car is not there yet.
    coming,
    there,
};

pub const Mind = struct {
    state: State = .coming,
    /// Logic ticks since the car came (0 at the tick it came).
    ticks: u16 = 0,
};

pub const Animation = enum { car };
pub const Sound = enum { siren, brakes, bazooka, shell, explosion };

pub const Numbers = struct {
    /// The camera's run: its speed (back, then ahead), how far back it runs at most, and how far
    /// back it has run when the car comes.
    run: Fixed,
    run_most: Fixed,
    comes: Fixed,
    /// The ticks from the car's coming: the siren, the brakes, the officer's shot, the shell's
    /// fall, the explosion, the blast that knocks down the enemies, the camera's run ahead, and
    /// the attack's end.
    siren: u16,
    brakes: u16,
    bazooka: u16,
    shell: u16,
    explosion: u16,
    blast: u16,
    run_ahead: u16,
    ends: u16,
};

/// The call: the camera runs back from where it is, as far as its run goes but not past the
/// round's start.
pub fn specialCalled(a: Actor) void {
    const n = a.numbers();
    const c = &a.tick.world.camera;
    c.run = .{ .from = c.x, .speed = n.run, .limit = c.x.sub(n.run_most).max(.zero) };
}

pub fn think(a: Actor) void {
    const n = a.numbers();
    a.entity.flags.hidden = true;
    const c = &a.tick.world.camera;
    if (a.mind.state == .coming) {
        const run = c.run orelse return;
        if (c.x.whole() > run.from.sub(n.comes).whole()) return;
        a.mind.state = .there;
    }
    const now = a.mind.ticks;
    a.mind.ticks += 1;
    if (now == n.siren) a.sound(.siren);
    if (now == n.brakes) a.sound(.brakes);
    if (now == n.bazooka) a.sound(.bazooka);
    if (now == n.shell) a.sound(.shell);
    if (now == n.explosion) a.sound(.explosion);
    if (now == n.blast) a.tick.specialBlast();
    if (now == n.run_ahead) {
        if (c.run) |*r| r.state = .ahead;
    }
    if (now == n.ends) {
        a.tick.world.special = false;
        a.remove();
    }
}

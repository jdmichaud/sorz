//! The police car of the special attack, a stand-in (PLAN item 11): it comes when a player calls
//! it (`Tick.callSpecial`), stays the attack's time with its sounds at their times, sets off its
//! blast, and goes; play's phase is `special` while it is there. The original's car drives in,
//! its officer leans out and fires while the camera runs back and the shells fall; TODO(PLAN
//! item 13): the car itself, its parts and the camera's run back.
const tick = @import("../tick.zig");

const Actor = tick.Actor(@This());

pub const State = enum { calling };

pub const Mind = struct {
    state: State = .calling,
    /// Logic ticks since the call (0 at the call's tick).
    ticks: u16 = 0,
};

pub const Animation = enum { car };
pub const Sound = enum { siren, brakes, bazooka, shell, explosion };

pub const Numbers = struct {
    /// The ticks from the call: the siren, the brakes, the officer's shot, the shell's fall, the
    /// explosion, the blast that knocks down the enemies, and the attack's end.
    siren: u16,
    brakes: u16,
    bazooka: u16,
    shell: u16,
    explosion: u16,
    blast: u16,
    ends: u16,
};

pub fn think(a: Actor) void {
    const n = a.numbers();
    a.entity.flags.hidden = true;
    const now = a.mind.ticks;
    a.mind.ticks += 1;
    if (now == n.siren) a.sound(.siren);
    if (now == n.brakes) a.sound(.brakes);
    if (now == n.bazooka) a.sound(.bazooka);
    if (now == n.shell) a.sound(.shell);
    if (now == n.explosion) a.sound(.explosion);
    if (now == n.blast) a.tick.specialBlast();
    if (now == n.ends) {
        a.tick.world.special = false;
        a.remove();
    }
}

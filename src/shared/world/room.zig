//! Round 8's last room, Mr. X's: the players' walk in, his offer and its answers, the fight
//! (behaviours/mr_x.zig), as the original's room script runs them. While the offer's script
//! runs, play's phase is the traces' `script` (the original's offer machine keeps running through
//! the fight, in its last step).

/// The room's script, part of the world.
pub const State = struct {
    /// The offer's script, while it runs: its step (the original's numbers).
    offer: ?u8 = null,
};

/// The offer's last step: the fight goes on, to the round's end.
pub const fight: u8 = 0x41;

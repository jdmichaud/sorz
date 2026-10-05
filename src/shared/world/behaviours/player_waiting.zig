//! A player out of lives (the original's waiting player): hidden, it reads the
//! presses of its pad at the logic tick's first display tick. While it has continues left it asks
//! the continue's question on the status bar: up or down moves the cursor between YES and the
//! other answer (with its sound), the cursor blinks, A, B, C or START answers at the next tick.
//! YES spends a continue and its player plays again
//! (lives.zig); NO, or no continue left, puts it out of the game: while the other player is still
//! in the game it goes; else it counts the game over down (the game over's music; the round
//! shows its text), and the game is over.
//!
//! Its states, the semantic traces' names: `begin` (its first tick: the question, or out),
//! `continue_choose`, `continue_chosen`, `countdown`, `game_over`.
const tick = @import("../tick.zig");
const Command = @import("../world.zig").Command;
const lives = @import("../lives.zig");

const Actor = tick.Actor(@This());

pub const State = enum { begin, continue_choose, continue_chosen, countdown, game_over };

pub const Answer = enum { yes, no };

pub const Mind = struct {
    state: State = .begin,
    cursor: Answer = .yes,
    /// The cursor shows: drawn from the question's second tick, it blinks (`phase`); the ticks
    /// of the count or of the blink.
    shown: bool = false,
    phase: bool = false,
    ticks: u8 = 0,
    /// The continues the question shows.
    count: u8 = 0,
    /// It answered NO: its count is the longer, and the status bar shows no game over at first.
    answered_no: bool = false,
    /// The game over's music was asked for.
    music: bool = false,
};

pub const Sound = enum { cursor, game_over };

pub const Numbers = struct {
    /// The ticks the cursor shows, and hides.
    cursor_blink: u8,
    /// The game over's ticks when no continue is left (after a NO: 256, its count cleared).
    out_wait: u8,
};

pub fn control(a: Actor, c: Command) void {
    const n = a.numbers();
    a.entity.flags.hidden = true;
    a.entity.flags.stays = true;
    switch (a.mind.state) {
        .begin => begin(a),
        .continue_choose => {
            const p = c.first;
            if (p.up or p.down) {
                a.mind.cursor = if (a.mind.cursor == .yes) .no else .yes;
                a.sound(.cursor);
            }
            a.mind.ticks -%= 1;
            if (a.mind.ticks == 0) {
                a.mind.ticks = n.cursor_blink;
                a.mind.phase = !a.mind.phase;
            }
            a.mind.shown = !a.mind.phase;
            if (p.a or p.b or p.c or p.start) a.mind.state = .continue_chosen;
        },
        .continue_chosen => {
            const k = a.tick.world.playerOf(a.handle) orelse return;
            if (a.mind.cursor == .yes) return lives.continueGame(a.tick, k);
            a.tick.world.players[k].continues = 0;
            a.tick.world.players[k].out = true;
            a.mind.answered_no = true;
            a.mind.state = .begin;
        },
        .countdown => {
            if (!a.mind.music) {
                a.mind.music = true;
                a.sound(.game_over);
            }
            a.mind.ticks -%= 1;
            if (a.mind.ticks == 0) a.mind.state = .game_over;
        },
        .game_over => {},
    }
}

/// Its first tick: the question while continues are left; else out of the game, and the game
/// over's count when no other player is in the game.
fn begin(a: Actor) void {
    const n = a.numbers();
    const w = a.tick.world;
    const k = w.playerOf(a.handle) orelse return a.remove();
    const p = &w.players[k];
    if (p.continues != 0) {
        a.mind.state = .continue_choose;
        a.mind.count = p.continues;
        a.mind.cursor = .yes;
        a.mind.shown = false;
        a.mind.phase = false;
        a.mind.ticks = n.cursor_blink;
        return;
    }
    p.out = true;
    const other = &w.players[1 - @as(u2, k)];
    if (other.entity != null and !other.out) {
        p.entity = null;
        return a.remove();
    }
    a.mind.state = .countdown;
    a.mind.ticks = if (a.mind.answered_no) 0 else n.out_wait;
}

/// Whether the game is over: no player is left in the game, the last one's count running or
/// done.
pub fn counting(state: State) bool {
    return state == .countdown or state == .game_over;
}

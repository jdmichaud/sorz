//! A player out of lives (the original's waiting player): hidden, it reads the
//! presses of its pad's last read (schedule.zig). When its score entered the high-score table at
//! its last life's end (lives.zig), it first enters its name on its part of the status bar:
//! left or right change the letter at the cursor's place (held, they repeat as the letter's
//! blink ends a showing), A or C takes it and goes to the next place, B goes back a place
//! (the letters keep what they show); START, the end mark taken or the last place's letter taken
//! ends the entry, and the round enters it in the table. While it has continues left it asks
//! the continue's question on the status bar: up or down moves the cursor between YES and the
//! other answer (with its sound), the cursor blinks, A, B, C or START answers at the next tick.
//! YES spends a continue and its player plays again
//! (lives.zig); NO, or no continue left, puts it out of the game: while the other player is still
//! in the game it goes; else it counts the game over down (the game over's music; the round
//! shows its text), and the game is over.
//!
//! Its states, the semantic traces' names: `begin` (its first tick: the name entry, the
//! question, or out; and the tick its name is entered), `name_entry`, `continue_choose`,
//! `continue_chosen`, `countdown`, `game_over`.
//!
//! As it is made it takes a shadow's place (its definition's `shadow_place`: the original's
//! record cleared, with no mark against a shadow, world/shadows.zig); from its first tick (the
//! name entry's start, or the wait's) it takes none, and that shadow goes at its next turn.
const tick = @import("../tick.zig");
const Command = @import("../world.zig").Command;
const lives = @import("../lives.zig");

const Actor = tick.Actor(@This());

pub const State = enum { begin, name_entry, continue_choose, continue_chosen, countdown, game_over };

/// The letters of a name (the high-score table's).
pub const places = 3;

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
    /// Its score entered the high-score table at its last life's end: its name is entered first.
    entering: bool = false,
    /// The name entry: the cursor's place (`places`: past the last), the letter there (a number
    /// of the letters, the last the end mark), the letter each place keeps, the furthest place
    /// the cursor reached, and the name's letters taken (null: none at that place). The letter
    /// at the cursor blinks (`shown`, `phase`, `ticks`).
    place: u8 = 0,
    letter: u8 = 0,
    letters: [places]u8 = @splat(0),
    reached: u8 = 0,
    name: [places]?u8 = @splat(null),
    /// Its name was entered: the status bar shows it until the question.
    named: bool = false,
};

pub const Sound = enum { cursor, game_over };

pub const Numbers = struct {
    /// The ticks the cursor shows, and hides.
    cursor_blink: u8,
    /// The game over's ticks when no continue is left (after a NO: 256, its count cleared).
    out_wait: u8,
    /// The ticks the name entry's letter shows, and hides.
    name_blink: u8,
    /// The letters a place goes through, the last the end mark.
    letters: u8,
};

pub fn control(a: Actor, c: Command) void {
    const n = a.numbers();
    a.entity.flags.hidden = true;
    a.entity.flags.stays = true;
    switch (a.mind.state) {
        .begin => begin(a),
        .name_entry => entry(a, c),
        .continue_choose => {
            const p = c.last;
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
            if (p.special or p.attack or p.jump or p.start) a.mind.state = .continue_chosen;
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

/// Its first tick: the name entry when its score entered the table; else the question while
/// continues are left; else out of the game, and the game over's count when no other player is in
/// the game.
fn begin(a: Actor) void {
    const n = a.numbers();
    a.entity.flags.shadowless = true;
    if (a.mind.entering) return startEntry(a);
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

/// The name entry's start: the cursor at the first place on the first letter, every place's
/// letter the first, no letter taken; the letter shows, its blink starts.
fn startEntry(a: Actor) void {
    const m = a.mind;
    m.state = .name_entry;
    m.place = 0;
    m.letter = 0;
    m.letters = @splat(0);
    m.reached = 0;
    m.name = @splat(null);
    m.shown = true;
    m.phase = false;
    m.ticks = a.numbers().name_blink;
}

/// A tick of the name entry, on the pad's presses: START ends it; B goes back a place (the
/// letter left there kept), then A or C takes the letter (the end mark, or the last place's,
/// ends it); left or right change the letter, wrapping round (held, they repeat at the blink's
/// last tick of a showing); the letter blinks.
fn entry(a: Actor, c: Command) void {
    const n = a.numbers();
    const m = a.mind;
    const p = c.last;
    if (p.start) return endEntry(a);
    const end = n.letters -| 1;
    if (p.attack and m.place != 0) {
        m.letters[m.place] = m.letter;
        m.place -= 1;
        m.letter = m.letters[m.place];
    }
    if (p.special or p.jump) {
        // Taken, it shows.
        m.letters[m.place] = m.letter;
        m.name[m.place] = m.letter;
        m.shown = true;
        if (m.letter == end) return endEntry(a);
        m.place += 1;
        m.reached = @max(m.reached, m.place);
        if (m.place == places) return endEntry(a);
        m.letter = m.letters[m.place];
    }
    var left = p.left;
    var right = p.right;
    if (!left and !right and m.ticks == 1 and m.phase) {
        left = c.held.left;
        right = c.held.right;
    }
    if (left) {
        m.letter = if (m.letter == 0) end else m.letter - 1;
    } else if (right) {
        m.letter = if (m.letter >= end) 0 else m.letter + 1;
    }
    m.ticks -%= 1;
    if (m.ticks == 0) {
        m.ticks = n.name_blink;
        m.phase = !m.phase;
    }
    m.shown = m.phase;
}

/// The name is entered: the round enters it in the high-score table; the next tick asks the
/// continue's question as a first tick does. (At round 8's end the original's entry ends the game
/// instead: PLAN item 16.)
fn endEntry(a: Actor) void {
    const k = a.tick.world.playerOf(a.handle) orelse return;
    a.tick.out.rankings.append(.{ .player = k, .name = a.mind.name });
    a.mind.entering = false;
    a.mind.named = true;
    a.mind.state = .begin;
}

/// What the name entry's place `q` shows: the cursor's letter while it shows, a letter the
/// cursor left there, or nothing (null: the bar's own cell).
pub fn shownAt(m: *const Mind, q: usize) ?u8 {
    if (q == m.place) return if (m.shown) m.letter else null;
    if (q <= m.reached) return m.letters[q];
    return null;
}

/// Whether the game is over: no player is left in the game, the last one's count running or
/// done.
pub fn counting(state: State) bool {
    return state == .countdown or state == .game_over;
}

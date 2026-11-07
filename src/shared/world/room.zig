//! Round 8's last room, Mr. X's (its content, content/round.zig's `Room`): the players' walk in,
//! his offer and its answers, the fight (behaviours/mr_x.zig), as the original's room script
//! runs them. The room's own steps of the round's script (its art, its fight's waves, its last
//! art) are script.zig's.
//!
//! As the room's script starts (script.zig) the players walk in by themselves (`walkIn`): to the
//! door's depths, where the first to get there puts up the room's door and strikes it
//! (behaviours/door.zig: it breaks, which opens the room), then each to its place in the room;
//! meanwhile the camera scrolls by itself (`scrolls`). Once all are in, the offer's script begins
//! (`offer`): while it runs, play's phase is the traces' `script` (the original's offer machine
//! keeps running through the fight, in its last step).
//!
//! The offer is the cartridge's two players' (DESIGN.md 10.7, E4): players 1 and 2, or players 3
//! and 4 (the port's) when neither of them is in the room (`first`, the offer's first player; the
//! offer's seats, `seatOf`). As the room's script starts and the offer's players walk in, the
//! others walk away, back the way the round came, and step out of the game's picture once off the
//! screen (`stepOut`: their fighters go, their records stay; at the walk in's end at the latest).
//! The room plays as a game of two until Mr. X rises from his chair; then they drop into the room
//! as a new life does, blinking, their lives, specials and scores as they were (`comeIn`). They
//! come in sooner when neither of the offer's players fights any more (both out of lives), so that
//! the game goes on with them.
//!
//! The offer's script (`offerTick`, before the players' turns) is the original's machine of steps,
//! by their numbers: Mr. X's window opens a row a tick, his texts are typed in it a letter every
//! few ticks (each letter's sound, but a blank's), waits between them; the players are held in
//! the choice (their pads taken, `choice`) and answer yes or no, each its mark moved by up and
//! down, its answer a button. One player's yes, or both, brings the reward and the trapdoors
//! (back to round 6); a no, or both, Mr. X's threat and the fight; two different answers, the
//! duel between the players, after which the one left is asked again (a yes the reward, a no
//! the traitor's threat, then the fight). The fight's step is the machine's last.
//!
//! Mr. X seated (behaviours/mr_x_seated.zig) talks as the offer asks: the offer asks for his
//! line (`talk`: the line's number, and a new line asked), and he says it (`talk_said`) once he
//! has played it out. The room's progress (`progress`) is the original's flags of its fight: Mr.
//! X's laughs, the waves' clears, his standing up, the music and the last art.
const std = @import("std");
const tick_mod = @import("tick.zig");
const entity = @import("entity.zig");
const world_mod = @import("world.zig");
const content_round = @import("../content/round.zig");
const lives = @import("lives.zig");

const Tick = tick_mod.Tick;
const Handle = entity.Handle;
const Offer = content_round.Offer;

/// The room's script, part of the world.
pub const State = struct {
    /// The offer's script, while it runs: its step (the original's numbers).
    offer: ?u8 = null,
    /// The line the offer asks Mr. X for (its number, from 1; 0: none), a new line asked, and
    /// his line said.
    talk: u8 = 0,
    talk_asked: bool = false,
    talk_said: bool = false,
    /// The fight's progress: `Progress`'s bits.
    progress: u8 = 0,
    /// The players walk in, the camera scrolling by itself.
    walking: bool = false,
    /// Each player: at the door's depths (its first stop), at its place; the players at their
    /// places.
    at_door: [world_mod.max_players]bool = @splat(false),
    in_place: [world_mod.max_players]bool = @splat(false),
    arrived: u8 = 0,
    /// The door was put up; it broke (its cells of the plane cleared); the room's opening is due.
    door_made: bool = false,
    door_broken: bool = false,
    opening: bool = false,
    /// The next of the fight's waves.
    wave: u8 = 0,
    /// A player out of the game left the room (as the fight began, or beaten in the duel).
    gone: [world_mod.max_players]bool = @splat(false),
    /// The offer's first player (its seats are this one and the next): player 1, or player 3 when
    /// neither player 1 nor player 2 is in the room as its script starts.
    first: world_mod.PlayerNumber = 0,
    /// The players walking away from the room, and those outside it, which the room keeps out
    /// (`held_out`) until Mr. X rises.
    leaving: [world_mod.max_players]bool = @splat(false),
    outside: [world_mod.max_players]bool = @splat(false),
    held_out: bool = false,
    /// The offer's window: its rows open (closing, `shutting`), the text in it (by its index in
    /// the offer's texts) and its letters typed, the ticks to the next letter; a wait's ticks.
    rows: u8 = 0,
    shutting: bool = false,
    text: ?u8 = null,
    typed: u8 = 0,
    type_ticks: u8 = 0,
    wait: u8 = 0,
    /// The offer's two players, by their seats: held in the choice, its mark on no, answered; its
    /// answers shown in the window, and its mark.
    choosing: [2]bool = .{ false, false },
    on_no: [2]bool = .{ false, false },
    answered: [2]bool = .{ false, false },
    answers_shown: [2]bool = .{ false, false },
    mark_shown: [2]bool = .{ false, false },
    /// The players fight each other (the duel); a yes kept for the round's end (the traitor's
    /// threat); the offer accepted (the trapdoors: back to round 6), and accepted before (a second
    /// coming skips it).
    duel: bool = false,
    yes_kept: bool = false,
    back: bool = false,
    accepted_before: bool = false,
    /// The trapdoors opened under the offer's players in the room then (a bit each, by their
    /// seats): the floor is gone.
    trapdoors: ?Trapdoors = null,
    floor_gone: bool = false,

    pub fn has(s: *const State, bit: Progress) bool {
        return s.progress & bit.mask() != 0;
    }

    /// Sets `bit`: whether it was set.
    pub fn set(s: *State, bit: Progress) bool {
        defer s.progress |= bit.mask();
        return s.has(bit);
    }
};

/// The offer's players a trapdoor opened under: a bit each seat (the room's places of players 1
/// and 2, where the offer's players stand).
pub const Trapdoors = u2;

/// The offer's seat of player `k` (0 or 1), when it is one of the offer's two players.
pub fn seatOf(r: *const State, k: world_mod.PlayerNumber) ?u1 {
    if (k < r.first) return null;
    return std.math.cast(u1, k - r.first);
}

/// The player in the offer's seat `seat`.
pub fn playerAt(r: *const State, seat: u1) world_mod.PlayerNumber {
    return r.first + seat;
}

/// The room's script starts (script.zig): the offer's players are players 1 and 2, or 3 and 4
/// when neither of the first two is in the room; the others walk away (`walkIn`), and the room
/// keeps them out.
pub fn begin(t: *Tick) void {
    const w = t.world;
    const r = &w.room;
    var in: [world_mod.max_players]bool = undefined;
    for (&in, w.players) |*x, p| x.* = p.entity != null;
    r.first = if (!in[0] and !in[1] and (in[2] or in[3])) 2 else 0;
    for (in, 0..) |fights, k| if (fights and seatOf(r, @intCast(k)) == null) {
        r.leaving[k] = true;
        r.held_out = true;
    };
}

/// The pixels past the screen's edge a player walking away steps out at (its sprite gone).
const away_past = 48;

/// At the logic tick's start, the players walking away step out once off the screen on the side
/// they walk to, or when the walk in has ended.
fn leaveTick(t: *Tick) void {
    const w = t.world;
    const r = &w.room;
    for (&r.leaving, 0..) |*l, k| {
        if (!l.*) continue;
        const e = w.getConst(w.players[k].entity orelse {
            l.* = false;
            continue;
        }) orelse continue;
        const left = w.camera.x.whole();
        const x = e.position.x.whole();
        const off = if (awayRight(t)) x > left + screen_width + away_past else x < left - away_past;
        if (!off and r.walking) continue;
        l.* = false;
        stepOut(t, @intCast(k));
    }
}

/// The screen's pixels across.
const screen_width = 320;

/// Whether the way back the round came is to the right (a round going left).
fn awayRight(t: *const Tick) bool {
    const p = t.plan orelse return true;
    return p.round.camera.leftward;
}

/// Player `k` joined the game under way (network play's): while the room keeps the others out,
/// it steps out at once, unless it is one of the offer's.
pub fn joined(t: *Tick, k: world_mod.PlayerNumber) void {
    if (t.world.room.held_out) stepOut(t, k);
}

/// Whether player `k` walks away from the room (the camera keeps it in view no more).
pub fn walksAway(r: *const State, k: usize) bool {
    return r.leaving[k];
}

/// Player `k`'s fighter steps out of the room, which keeps it out from then on: its record stays
/// as it is (its lives, specials, score), its fighter goes. One of the offer's, or one without a
/// fighter, stays as it is.
fn stepOut(t: *Tick, k: world_mod.PlayerNumber) void {
    const w = t.world;
    const r = &w.room;
    if (seatOf(r, k) != null) return;
    const p = &w.players[k];
    const h = p.entity orelse return;
    p.entity = null;
    w.remove(h);
    r.outside[k] = true;
    r.held_out = true;
}

/// Whether the room's players outside come in: once Mr. X has risen, or once neither of the
/// offer's players fights (out of lives, or out of the game).
fn comesIn(t: *const Tick) bool {
    const w = t.world;
    const r = &w.room;
    if (r.has(.stands)) return true;
    for (0..2) |seat| {
        const e = w.getConst(w.players[playerAt(r, @intCast(seat))].entity orelse continue) orelse continue;
        if (e.mind == .player) return false;
    }
    return true;
}

/// At the logic tick's start, when they come in (`comesIn`): the players outside drop in as a new
/// life does (lives.zig, `comeIn`), each in its turn, and the room keeps no one out any more.
fn letIn(t: *Tick) void {
    const r = &t.world.room;
    if (!r.held_out) return;
    leaveTick(t);
    if (!comesIn(t)) return;
    r.held_out = false;
    for (&r.outside, &r.leaving, 0..) |*o, *l, k| {
        // One still walking away turns back.
        l.* = false;
        if (!o.*) continue;
        o.* = false;
        _ = lives.comeIn(t, @intCast(k));
    }
}

/// The fight's progress, the original's bits by number: Mr. X's first laugh (the fight's first
/// wave due), the first wave cleared, his second laugh (the second wave due), his standing up,
/// the fight begun, its music on, the last art asked for, the last art loaded.
pub const Progress = enum(u3) {
    first_laugh,
    cleared,
    second_laugh,
    stands,
    begun,
    music,
    last_art,
    last_loaded,

    pub fn mask(p: Progress) u8 {
        return @as(u8, 1) << @backingInt(p);
    }
};

/// The offer's last step: the fight goes on, to the round's end.
pub const fight: u8 = 0x41;

/// The kind of the room's door.
pub const door_kind = "door";

/// The window's rows below the status bar's as the offer has them (0: none): opening, `open`
/// and the rows opened so far (to `rows`, less one); closing, `shut` and the rows left.
pub fn windowRows(r: *const State, o: *const Offer) u8 {
    if (r.offer == null or r.rows == 0 or r.rows > o.rows) return 0;
    if (r.shutting) return if (r.rows < o.rows) o.window.shut + r.rows else 0;
    return o.window.open + @min(r.rows, o.rows - 1);
}

/// Whether the camera scrolls by itself (the players walk in), and by how much a tick.
pub fn scrolls(t: *const Tick) ?i32 {
    if (!t.world.room.walking) return null;
    const p = t.plan orelse return null;
    const rm = p.round.room orelse return null;
    return rm.scroll;
}

/// The command player `k` (its fighter `h`) takes in the walk in, instead of its own: none outside
/// it, and none in the air (its own then). What it holds it lets go. One outside the offer walks
/// away, back the way the round came (`begin`). The offer's players: to the door's depths and
/// left of its place: the first there puts up the door and strikes it, facing left. Then to the
/// room's depths and its place (the offer's first seat's, or its second's): there, as the last
/// player arrives, the walk in ends and the offer begins (the timer stops); the first seat's
/// player turns right as it arrives.
pub fn walkIn(t: *Tick, k: world_mod.PlayerNumber, h: Handle) ?world_mod.Command {
    const r = &t.world.room;
    if (!r.walking) return null;
    const p = t.plan orelse return null;
    const rm = p.round.room orelse return null;
    const wk = rm.walk;
    const e = t.world.get(h) orelse return null;
    if (e.holding != null or e.holder != null) {
        if (e.holding) |held| if (t.isPlayer(held)) t.letGo(h);
    }
    if (!e.velocity.height.eql(.zero)) return null;
    const own = t.world.players[k].command;
    if (r.leaving[k]) {
        const away: world_mod.Actions = if (awayRight(t)) .{ .right = true } else .{ .left = true };
        return .{ .held = away, .pressed = away, .last = away };
    }
    const d = e.position.depth.whole();
    const x: u16 = @truncate(@as(u32, @bitCast(e.position.x.whole())));
    const way: world_mod.Actions = way: {
        if (!r.at_door[k]) {
            if (d < wk.door_depth[0]) break :way .{ .down = true };
            if (d >= wk.door_depth[1]) break :way .{ .up = true };
            if (x >= wk.door_x) break :way .{ .left = true };
            r.at_door[k] = true;
            if (!r.door_made) {
                r.door_made = true;
                putUpDoor(t, rm.door);
                e.facing = .left;
                break :way .{ .attack = true };
            }
        }
        if (d < wk.depth[0]) break :way .{ .down = true };
        if (d >= wk.depth[1]) break :way .{ .up = true };
        if (r.in_place[k]) break :way .{};
        const seat: u1 = seatOf(r, k) orelse @truncate(k);
        const place: u16 = @intCast(wk.places[seat]);
        if (place < x) break :way .{ .left = true };
        if (place -% @as(u16, @intCast(wk.near)) >= x) break :way .{ .right = true };
        r.arrived +%= 1;
        const needed: u8 = seatsInPlay(t) -| 1;
        if (r.arrived > needed) {
            r.walking = false;
            // The offer begins (back after the duel, it goes on).
            if (r.offer == null) r.offer = 0;
            t.world.timer.stopped = true;
        }
        r.in_place[k] = true;
        break :way if (seat == 0) .{ .right = true } else .{};
    };
    var held = way;
    held.start = own.held.start;
    var pressed = way;
    pressed.start = own.pressed.start;
    return .{ .held = held, .pressed = pressed, .last = pressed };
}

// The offer ------------------------------------------------------------------------------------

/// The offer's players in play (the players walking away not counted).
fn seatsInPlay(t: *const Tick) u8 {
    var n: u8 = 0;
    for (t.world.players, 0..) |p, k| {
        if (seatOf(&t.world.room, @intCast(k)) == null) continue;
        if (p.entity) |h| if (t.world.getConst(h) != null) {
            n += 1;
        };
    }
    return n;
}

/// The kind of the trapdoors the offer accepted opens.
pub const trapdoor_kind = "trapdoor";

/// The offer's script's tick (before the players' turns): the players outside let in when they
/// come in; the step's hold on the players, then the step.
pub fn offerTick(t: *Tick) void {
    letIn(t);
    const r = &t.world.room;
    const step = r.offer orelse return;
    const p = t.plan orelse return;
    const rm = &(p.round.room orelse return);
    const o = &rm.offer;
    const flag = if (step < o.steps.len) o.steps[step] else .free;
    const hold = flag == .hold or flag == .answer;
    r.choosing = .{ hold, hold };
    const two = playersIn(t) == 2;
    switch (step) {
        0 => {
            ask(r, 0);
            openText(r);
        },
        0x2A => openText(r),
        // The font's art: none is loaded outside Japan.
        1, 0x2B => next(r),
        2, 0x2C => {
            r.shutting = false;
            r.rows +%= 1;
            if (r.rows < o.rows) return;
            if (r.accepted_before) r.offer = 0x12;
            next(r);
        },
        3, 7, 0xE, 0x15, 0x1A, 0x24, 0x2F, 0x3E => {
            r.wait = o.wait;
            next(r);
            waitTick(r);
        },
        4, 8, 0xF, 0x16, 0x1B, 0x25, 0x30, 0x3F => waitTick(r),
        5 => {
            r.yes_kept = false;
            if (two) r.offer = 0x18;
            next(r);
            startText(r, o, "offer");
        },
        6, 0xD, 0x14, 0x19, 0x23, 0x2E, 0x3D => typeLetter(t, r, o),
        9, 0x31 => {
            next(r);
            const k = lone(t);
            r.choosing[k] = true;
            r.answers_shown[k] = true;
        },
        0xA, 0x1E, 0x1F, 0x33, 0x35...0x3A => {},
        0xB, 0x12, 0x20, 0x27, 0x3B => {
            r.text = null;
            next(r);
        },
        0xC => {
            ask(r, 2);
            next(r);
            startText(r, o, "reward");
        },
        0x10, 0x17 => if (closeRow(r, o)) {
            next(r);
            r.choosing[lone(t)] = false;
        },
        0x11 => if (r.talk_said) {
            r.talk_said = false;
            if (t.kinds.find(trapdoor_kind)) |k| {
                const places = world_mod.World.effect_places;
                _ = t.world.spawnWithin(t.kinds, k, places.from, places.to, .zero, .right) catch {};
            }
            r.back = true;
            r.accepted_before = true;
        },
        0x13 => {
            ask(r, 3);
            next(r);
            startText(r, o, "die");
        },
        0x18 => {
            r.offer = fight;
            t.world.timer.stopped = false;
        },
        0x1C => {
            next(r);
            r.choosing = .{ true, true };
            r.answers_shown[0] = true;
        },
        0x1D => {
            next(r);
            r.answers_shown[1] = true;
        },
        0x21 => {
            if (r.on_no[0] != r.on_no[1]) {
                next(r);
                ask(r, 1);
            } else r.offer = if (r.on_no[0]) 0x12 else 0xB;
        },
        0x22 => {
            ask(r, 5);
            next(r);
            r.duel = true;
            t.sound(o.duel_music, null);
            startText(r, o, "duel");
        },
        0x26 => if (closeRow(r, o)) {
            next(r);
            r.choosing = .{ false, false };
        },
        0x28 => {
            r.answers_shown = .{ false, false };
            r.mark_shown = .{ false, false };
            next(r);
            r.in_place = @splat(false);
        },
        // The duel's end: a player out of the game, the one left walks back to its place.
        0x29 => {
            const w = t.world;
            const seats = [2]usize{ playerAt(r, 0), playerAt(r, 1) };
            const out = [2]bool{ r.gone[seats[0]] or w.players[seats[0]].out, r.gone[seats[1]] or w.players[seats[1]].out };
            const left = if (out[0]) seats[1] else if (out[1]) seats[0] else return;
            if (!out[0]) r.duel = false;
            r.walking = true;
            if (!r.in_place[left]) return;
            r.in_place[left] = false;
            next(r);
        },
        0x2D => {
            ask(r, 4);
            next(r);
            startText(r, o, "join");
        },
        0x32 => {
            const k = lone(t);
            r.on_no[k] = false;
            r.answered[k] = false;
            next(r);
        },
        0x34 => r.offer = 0xB,
        0x3C => {
            ask(r, 6);
            r.yes_kept = true;
            next(r);
            startText(r, o, "traitor");
        },
        0x40 => r.offer = 0x12,
        else => {},
    }
}

/// The next step.
fn next(r: *State) void {
    r.offer.? +%= 1;
}

/// The offer asks Mr. X for line `n`.
fn ask(r: *State, n: u8) void {
    r.talk = n;
    r.talk_asked = true;
    r.talk_said = false;
}

/// The window's text is set up: the players stand where they are (out of their places), the
/// next step.
fn openText(r: *State) void {
    r.in_place = @splat(false);
    next(r);
}

/// A tick of a wait; at its end, the next step.
fn waitTick(r: *State) void {
    r.wait -%= 1;
    if (r.wait == 0) next(r);
}

/// The window closes a row: whether it is closed (it was).
fn closeRow(r: *State, o: *const Offer) bool {
    r.shutting = true;
    r.rows -%= 1;
    return r.rows >= o.rows;
}

/// The text `name` to type, from its first letter.
fn startText(r: *State, o: *const Offer, name: []const u8) void {
    r.typed = 0;
    r.type_ticks = o.type_period;
    for (o.texts, 0..) |x, i| if (std.mem.eql(u8, x.name, name)) {
        r.text = @intCast(i);
    };
}

/// The letters of a text: 4 rows of 25.
const text_cells = 25;
const text_letters = 4 * text_cells;

/// Every few ticks the text's next letter, with its sound unless it is blank; after the last,
/// the next step.
fn typeLetter(t: *Tick, r: *State, o: *const Offer) void {
    r.type_ticks -%= 1;
    if (r.type_ticks != 0) return;
    r.type_ticks = o.type_period;
    if (r.typed >= text_letters) return next(r);
    const text = o.texts[r.text orelse return];
    const bottom = text.lines[2 * (r.typed / text_cells) + 1][r.typed % text_cells];
    r.typed += 1;
    if (bottom != ' ') t.out.sounds.append(.{ .name = o.letter, .first = true });
}

/// Whether the offer's player in seat `seat` is in the game (not out of it, nor gone from the
/// room).
fn inGame(t: *const Tick, seat: u1) bool {
    const k = playerAt(&t.world.room, seat);
    const p = t.world.players[k];
    return p.entity != null and !p.out and !t.world.room.gone[k];
}

/// The players of the offer in the game: 1 or 2.
fn playersIn(t: *const Tick) u8 {
    return @as(u8, @intFromBool(inGame(t, 0))) + @intFromBool(inGame(t, 1));
}

/// The seat of the one player asked alone: the first's when it is the only one in the game, else
/// the second's.
fn lone(t: *const Tick) u1 {
    return if (inGame(t, 0) and !inGame(t, 1)) 0 else 1;
}

/// The command player `k` takes while held in the choice: none (its pads are taken). When the
/// step lets it answer and it has not, up and down move its mark (yes, no) with their sound, a
/// button answers (its sound): the next step, or, alone and saying no, seven steps on. Players
/// outside the offer are not held.
pub fn choice(t: *Tick, player: world_mod.PlayerNumber, h: Handle) ?world_mod.Command {
    const r = &t.world.room;
    const k = seatOf(r, player) orelse return null;
    if (!r.choosing[k]) return null;
    const step = r.offer orelse return null;
    const p = t.plan orelse return null;
    const o = &(p.round.room orelse return null).offer;
    if (step >= o.steps.len or o.steps[step] != .answer or r.answered[k]) return .{};
    const pressed = t.world.players[player].command.pressed;
    const was = r.on_no[k];
    if (pressed.up) r.on_no[k] = false else if (pressed.down) r.on_no[k] = true;
    if (r.on_no[k] != was) t.sound(o.move, h);
    if (pressed.special or pressed.attack or pressed.jump) {
        t.sound(o.answer, h);
        r.answered[k] = true;
        next(r);
        if (playersIn(t) != 2 and r.on_no[k]) r.offer.? +%= 7;
    }
    r.mark_shown[k] = true;
    return .{};
}

/// The door at its place, in the effects' first free place.
fn putUpDoor(t: *Tick, at: anytype) void {
    const kind = t.kinds.find(door_kind) orelse return;
    const places = world_mod.World.effect_places;
    _ = t.world.spawnWithin(t.kinds, kind, places.from, places.to, .pixels(at.x, at.depth, at.height), .right) catch {};
}

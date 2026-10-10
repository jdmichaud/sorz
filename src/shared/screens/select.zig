//! The character select: Adam, Axel and Blaze in their portraits' frames, their names and their
//! strengths, each player's label over the portrait they are on, its frame lit in the player's
//! colour. The characters stand, now and then move a little, and pose while a cursor is on them
//! (Blaze ends her pose with a jump); the eye of Blaze's portrait blinks.
//!
//! After its set-up and its load, the screen fades in over 64 ticks; then it runs a tick of its
//! own every two display ticks (as play does): the eye and the cursors in the first, the
//! portraits in the second, and the picture of both at the next (the original shows nothing new
//! between the two halves: the colours the cursors set in the first show with the rest). Each
//! player's presses of both display ticks count. Left, up and down move a cursor to the portrait
//! on its left, right to the one on its right, round the ends and past the other player's; A, B,
//! C or START chooses the character, once. The presses before the first such tick are lost.
//! When every player has chosen, the picture holds for 18 ticks, fades out, and the select ends
//! with "stop": round 1 follows (the options' first round; one the content does not have, its
//! stand-in).
//!
//! Network play (DESIGN.md 9): a second player may come to a select of one (`join`), its cursor
//! on the first portrait free from Blaze's, and go (`leave`); a character another machine's
//! player plays (`Turn.taken`) is passed and cannot be chosen.
//!
//! 1 PLAYER - 1 CPU (PLAN item 30, `Setup.cpu`): player 1 chooses alone; as the fade out ends,
//! the select comes again (`cpu_pass`), its music playing on, and player 1 chooses the CPU's
//! character there, its label CPU 1 in the font.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const input = @import("../input.zig");
const art = @import("../content/art.zig");
const setup_mod = @import("../setup.zig");
const transfers = @import("transfers.zig");
const Colours = @import("colours.zig").Colours;
const Setup = setup_mod.Setup;
const Character = setup_mod.Character;
const Pose = library.Poses.Pose;

/// The portraits, left to right: a place is its character.
const places = std.enums.values(Character);

/// Each label's top-left on the screen, by its place, and its row.
const label_x = std.EnumArray(Character, i16).init(.{ .adam = 32, .axel = 128, .blaze = 224 });
const label_y = 10;
/// Each character's place: the sprite's x, and its feet's y on the ground.
const portrait_x = std.EnumArray(Character, i16).init(.{ .adam = 48, .axel = 176, .blaze = 280 });
const feet_y = 16;

/// Heights in 1/65536 of a pixel, growing downward: Blaze's on the ground, her jump's first
/// speed, the pull while she rises and while she falls.
const one = 1 << 16;
const ground = 192 * one;
const jump_speed = -7 * one;
const rise_pull = 29 * one / 32;
const fall_pull = 17 * one / 32;

/// The step at which the idle ends (it is never shown), Adam's pose B ends, the pose A and the
/// others' pose B end; Adam's and Axel's pose C, and where Blaze's jump starts in hers.
const idle_end = std.EnumArray(Character, u8).init(.{ .adam = 11, .axel = 2, .blaze = 2 });
const pose_b_end = std.EnumArray(Character, u8).init(.{ .adam = 6, .axel = 3, .blaze = 3 });
const pose_a_end = 3;
const pose_c_end = std.EnumArray(Character, u8).init(.{ .adam = 4, .axel = 4, .blaze = 0 });
const jump_from = 3;

/// The wait after a pose, after the last choice; the eye's open and closed ticks.
const pose_wait = 18;
const chosen_wait = 18;
const eye_open_ticks = 300;
const eye_closed_ticks = 8;
/// The port's: the display ticks each of two players' labels on one portrait is in front.
const label_turn = 32;
/// The CPU's label, and its place in a label's 64 pixels (in the middle).
const cpu_label = "CPU 1";
const cpu_label_x: i16 = (64 - cpu_label.len * art.tile_side) / 2;

pub const Portrait = struct {
    state: State = .standing,
    pose: Pose = .stand,
    /// The pose's step shown, and the ticks left to it.
    step: u8 = 0,
    left: u8 = 0,
    /// The ticks left of a wait.
    wait: u8 = 0,
    /// A player's cursor is on it.
    cursor: bool = false,
    /// Blaze's height (in 1/65536 of a pixel, growing downward) and her speed.
    z: i32 = ground,
    vz: i32 = 0,
    /// Its frame changed: the next picture copies its art.
    copy: bool = false,

    pub const State = enum(u8) { standing, idle, pose_a_first, pose_a_second, pose_b, pose_c, wait, landing };

    fn start(self: *Portrait, pose: Pose, anim: *const library.Animation) void {
        self.pose = pose;
        self.step = 0;
        self.left = anim.steps[0].ticks;
        self.copy = true;
    }

    /// The next step when the ticks of this one are out (after the last, the first).
    fn advance(self: *Portrait, anim: *const library.Animation) void {
        self.left -%= 1;
        if (self.left != 0) return;
        self.copy = true;
        self.step += 1;
        if (self.step >= anim.len) self.step = 0;
        self.left = anim.steps[self.step].ticks;
    }

    /// One tick of the portrait of `who`: a cursor's arrival starts its pose, a departure stands
    /// it again (with a swing both), then its state's work.
    fn tick(self: *Portrait, who: Character, turn: *scene.Turn, a: *const Select.Assets) void {
        const posing = self.state != .standing and self.state != .idle;
        if (!posing and self.cursor) {
            self.state = .pose_a_first;
            self.start(.pose_a, a.poses.of(who, .pose_a));
            turn.play(a.swing);
        } else if (posing and !self.cursor) {
            // Back on the ground at once, the height's fraction kept.
            self.vz = 0;
            self.z = ground + @mod(self.z, one);
            self.state = .standing;
            self.start(.stand, a.poses.of(who, .stand));
            turn.play(a.swing);
        }
        const anim = a.poses.of(who, self.pose);
        switch (self.state) {
            .standing => {
                self.left -%= 1;
                if (self.left != 0) return;
                self.state = .idle;
                self.start(.idle, a.poses.of(who, .idle));
            },
            .idle => {
                self.advance(anim);
                if (self.step != idle_end.get(who)) return;
                self.state = .standing;
                self.start(.stand, a.poses.of(who, .stand));
            },
            .pose_a_first, .pose_a_second, .pose_b => {
                self.advance(anim);
                const last = if (self.state == .pose_b) pose_b_end.get(who) else pose_a_end;
                if (self.step != last) return;
                turn.play(a.swing);
                // Pose A twice, then B, then C.
                const next: struct { State, Pose } = switch (self.state) {
                    .pose_a_first => .{ .pose_a_second, .pose_a },
                    .pose_a_second => .{ .pose_b, .pose_b },
                    else => .{ .pose_c, .pose_c },
                };
                self.state = next[0];
                self.start(next[1], a.poses.of(who, next[1]));
            },
            .pose_c => {
                self.advance(anim);
                if (who == .blaze) {
                    if (self.step >= jump_from) self.jump(turn, a);
                    return;
                }
                if (self.step != pose_c_end.get(who)) return;
                self.wait = pose_wait;
                self.state = .wait;
                self.start(.stand, a.poses.of(who, .stand));
            },
            .wait => {
                self.wait -= 1;
                if (self.wait == 0) self.state = .standing;
            },
            .landing => {
                self.left -%= 1;
                if (self.left != 0) return;
                self.wait = pose_wait;
                self.state = .wait;
                self.start(.stand, a.poses.of(who, .stand));
            },
        }
    }

    /// Blaze's jump, a tick of it: up at 7 pixels a tick, pulled back down, and her landing on
    /// the ground, where her height keeps its fraction (so that her jumps differ by a pixel here
    /// and there).
    fn jump(self: *Portrait, turn: *scene.Turn, a: *const Select.Assets) void {
        if (self.vz == 0) self.vz = jump_speed;
        self.z += self.vz;
        if (@divFloor(self.z, one) < @divFloor(ground, one)) {
            self.vz += if (self.vz < 0) rise_pull else fall_pull;
            return;
        }
        self.vz = 0;
        self.z = ground + @mod(self.z, one);
        self.state = .landing;
        self.start(.landing, a.poses.of(.blaze, .landing));
        turn.play(a.landing);
    }

    /// The sprite's y: its feet's.
    fn y(self: *const Portrait) i16 {
        return @intCast(feet_y + @divFloor(self.z, one));
    }
};

pub const Cursor = struct {
    place: Character = .adam,
    chosen: bool = false,
};

/// The sprites a picture shows: each player's label at its place, each portrait's frame.
pub const Listing = struct {
    labels: [2]?Character = .{ null, null },
    portraits: [3]?Shown = .{ null, null, null },

    pub const Shown = struct { pose: Pose = .stand, step: u8 = 0, y: i16 = 0 };
};

pub const Select = struct {
    /// Ticks since the scene began (its set-up is tick 1).
    ticks: u16 = 0,
    phase: Phase = .setup,
    colours: Colours = .{},
    players: setup_mod.Players = .one,
    cursors: [2]Cursor = .{ .{ .place = .adam }, .{ .place = .blaze } },
    /// The player a lone cursor's label names: player 2 on a client of network play, whose
    /// player joins the host's game as player 2.
    seat: u1 = 0,
    /// The select's second time in a game of 1 PLAYER - 1 CPU: player 1 chooses the CPU's
    /// character (player 2's).
    cpu_pass: bool = false,
    /// By place: Adam's, Axel's, Blaze's.
    portraits: [3]Portrait = @splat(.{}),
    /// The eye: the ticks to its next blink or opening, and whether it is closed.
    eye_left: u16 = eye_open_ticks,
    eye_closed: bool = false,
    wait_left: u8 = 0,
    /// The presses of the last half tick's second display tick, which the next one's cursors see.
    kept: input.Pads = .{},
    /// The sprites the last tick listed, and what the picture shows (the sprites and the eye as
    /// the last frame shown took them).
    listed: Listing = .{},
    shown: Listing = .{},
    shown_eye_closed: bool = false,

    pub const Phase = enum(u8) { setup, placing, fade_in, first_half, second_half, wait, fade_out, leaving };

    pub const Assets = struct {
        frame: *const art.TileMap,
        eye_open: *const art.TileMap,
        eye_closed: *const art.TileMap,
        adam_name: *const art.TileMap,
        axel_name: *const art.TileMap,
        blaze_name: *const art.TileMap,
        adam_stats: *const art.TileMap,
        axel_stats: *const art.TileMap,
        blaze_stats: *const art.TileMap,
        colours: *const art.Palette,
        one_player: *const art.Palette,
        two_players: *const art.Palette,
        adam_dim: *const art.Palette,
        axel_dim: *const art.Palette,
        blaze_dim: *const art.Palette,
        adam_lit: *const art.Palette,
        axel_lit: *const art.Palette,
        blaze_lit: *const art.Palette,
        labels: [2]*const art.Frame,
        /// The CPU's label's letters.
        text: library.Text,
        poses: library.Poses,
        music: library.Sound,
        move: library.Sound,
        choose: library.Sound,
        swing: library.Sound,
        landing: library.Sound,
        stop: library.Sound,
        /// The rounds the content has, the game's first among them or not.
        rounds: library.Rounds,
        pub const names = .{
            .frame = "select/frame",
            .eye_open = "select/eye_open",
            .eye_closed = "select/eye_closed",
            .adam_name = "select/adam_name",
            .axel_name = "select/axel_name",
            .blaze_name = "select/blaze_name",
            .adam_stats = "select/adam_stats",
            .axel_stats = "select/axel_stats",
            .blaze_stats = "select/blaze_stats",
            .colours = "select/colours",
            // The frames lit at the start: Adam's, and Blaze's for player 2.
            .one_player = "select/cursors_one",
            .two_players = "select/cursors_two",
            .adam_dim = "select/frame_dim_1",
            .axel_dim = "select/frame_dim_2",
            .blaze_dim = "select/frame_dim_3",
            .adam_lit = "select/frame_lit_1",
            .axel_lit = "select/frame_lit_2",
            .blaze_lit = "select/frame_lit_3",
            .labels = "select/label",
            .text = "fonts/main",
            .poses = "screens/select",
            .music = "select music",
            .move = "menu move",
            .choose = "menu choose",
            .swing = "swing",
            .landing = "landing",
            .stop = "stop",
            .rounds = "rounds",
        };

        fn dim(a: *const Assets, c: Character) *const art.Palette {
            return switch (c) {
                .adam => a.adam_dim,
                .axel => a.axel_dim,
                .blaze => a.blaze_dim,
            };
        }

        fn lit(a: *const Assets, c: Character) *const art.Palette {
            return switch (c) {
                .adam => a.adam_lit,
                .axel => a.axel_lit,
                .blaze => a.blaze_lit,
            };
        }
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 }, .b = .{ .width = 64, .height = 32 } };

    pub fn start(_: *const Setup) Select {
        return .{};
    }

    pub fn tick(self: *Select, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        // The display tick between a tick's two halves shows nothing new, nor does the one after
        // the load (the set-up's tick is still running).
        if (self.phase != .placing and self.phase != .second_half) {
            self.colours.latch();
            self.shown = self.listed;
            self.shown_eye_closed = self.eye_closed;
        }
        switch (self.phase) {
            .setup => {
                turn.releasePads();
                // With the CPU, player 1 chooses alone, each time.
                self.players = if (turn.setup.cpu[1]) .one else turn.setup.players;
                self.seat = if (turn.net.role == .client and self.players == .one) 1 else 0;
                if (!self.cpu_pass) turn.setup.characters = .{ null, null };
                self.colours.aim(a.colours);
                self.colours.aim(if (self.players == .two) a.two_players else a.one_player);
                // Alone, the cursor starts on the first character no other machine's player has.
                if (turn.taken) |t| if (self.players == .one and self.cursors[0].place == t) {
                    self.cursors[0].place = next(t, true);
                    self.colours.aim(a.dim(t));
                    self.colours.aim(a.lit(self.cursors[0].place));
                };
                if (!self.cpu_pass) turn.play(a.music);
                self.phase = .placing;
                // The next display tick is the tick's second half.
                turn.frame = null;
                return null;
            },
            .placing => {
                self.kept = turn.pressed;
                for (&self.portraits, places) |*p, who| p.start(.stand, a.poses.of(who, .stand));
                self.list();
                self.colours.startFade(.target);
                self.phase = .fade_in;
            },
            .fade_in => if (self.colours.stepFade()) {
                for (self.cursors[0..self.count()]) |c| self.portraits[@backingInt(c.place)].cursor = true;
                self.phase = .first_half;
            },
            .first_half => {
                self.eye();
                const pressed: [2]input.Pad = .{ either(self.kept.pad1, turn.pressed.pad1), either(self.kept.pad2, turn.pressed.pad2) };
                for (0..self.count()) |i| self.cursor(@intCast(i), pressed[i], turn, a);
                self.phase = .second_half;
                turn.frame = null;
                return null;
            },
            .second_half => {
                self.kept = turn.pressed;
                for (&self.portraits, places) |*p, who| p.tick(who, turn, a);
                self.list();
                var chosen: usize = 0;
                for (self.cursors[0..self.count()]) |c| chosen += @intFromBool(c.chosen);
                if (chosen == self.count()) {
                    self.wait_left = chosen_wait;
                    self.phase = .wait;
                } else self.phase = .first_half;
            },
            .wait => {
                // A client's own select (network play's) leads to no round of its own: its player
                // chose, and waits there for the host's game.
                if (self.seat == 0) {
                    self.wait_left -= 1;
                    if (self.wait_left == 0) {
                        self.colours.startFade(.black);
                        self.phase = .fade_out;
                    }
                }
            },
            .fade_out => if (self.colours.stepFade()) {
                // The CPU's character next: the select again, from its set-up.
                if (turn.setup.cpu[1] and !self.cpu_pass) {
                    self.* = .{ .ticks = self.ticks, .cpu_pass = true };
                } else self.phase = .leaving;
            },
            .leaving => {
                turn.play(a.stop);
                turn.frame = .{ .colours = self.colours.copy, .first_line = true };
                return if (a.rounds.of(turn.setup.first_round + 1) != null) .chosen else .missing;
            },
        }
        turn.frame = .{ .colours = self.colours.copy, .tiles = self.copies(a), .first_line = true };
        return null;
    }

    fn count(self: *const Select) usize {
        return if (self.players == .two) 2 else 1;
    }

    fn either(x: input.Pad, y: input.Pad) input.Pad {
        return @bitCast(@as(u8, @bitCast(x)) | @as(u8, @bitCast(y)));
    }

    /// The eye's blink: open 300 ticks, closed 8.
    fn eye(self: *Select) void {
        self.eye_left -= 1;
        if (self.eye_left != 0) return;
        self.eye_closed = !self.eye_closed;
        self.eye_left = if (self.eye_closed) eye_closed_ticks else eye_open_ticks;
    }

    /// Player `i`'s cursor, with its presses: a choice, or a move to the next portrait that the
    /// other player is not on, its frame lit and the old one's dimmed.
    fn cursor(self: *Select, i: u1, pressed: input.Pad, turn: *scene.Turn, a: *const Assets) void {
        const c = &self.cursors[i];
        if (c.chosen or @as(u8, @bitCast(pressed)) == 0) return;
        if (pressed.a or pressed.b or pressed.c or pressed.start) {
            if (turn.taken == c.place) return;
            c.chosen = true;
            turn.setup.characters[if (self.cpu_pass) 1 else i] = c.place;
            turn.play(a.choose);
            return;
        }
        // Any direction but right is left.
        const from = c.place;
        var to = next(from, pressed.right);
        // A character the variant's rule says is taken (the other player's, in the cartridge), or
        // another machine's player's.
        if (self.players == .two and taken(turn, self.cursors[1 - i].place, to)) to = next(to, pressed.right);
        if (turn.taken == to) to = next(to, pressed.right);
        c.place = to;
        // A portrait the other player's cursor stays on stays lit (when the variant lets both
        // be on one).
        if (self.players != .two or self.cursors[1 - i].place != from) {
            self.portraits[@backingInt(from)].cursor = false;
            self.colours.show(a.dim(from));
        }
        self.portraits[@backingInt(to)].cursor = true;
        self.colours.show(a.lit(to));
        turn.play(a.move);
    }

    /// Whether a second player may come to this select: one plays it, and it has not ended.
    /// Whether `wanted` is taken for a player, the other's cursor on `other`: by the host's
    /// network options in a game of NETWORK PLAY, else by the variant's rule.
    fn taken(turn: *const scene.Turn, other: Character, wanted: Character) bool {
        if (turn.setup.same_character) |same| return !same and other == wanted;
        return turn.policies.characterTaken(other, wanted);
    }

    pub fn joinable(self: *const Select) bool {
        // Not where player 1 chooses for the CPU.
        return self.players == .one and !self.cpu_pass and switch (self.phase) {
            .setup, .placing, .fade_in, .first_half, .second_half => true,
            .wait, .fade_out, .leaving => false,
        };
    }

    /// Whether it shows, faded in: its players choose.
    pub fn settled(self: *const Select) bool {
        return self.phase == .first_half or self.phase == .second_half;
    }

    /// A second player comes to the select (`joinable`): its cursor where it was (`at`: network
    /// play's client's, at its own select, `chosen` there), else on the first portrait from
    /// Blaze's; not on player 1's unless both may choose one: a choice made keeps its portrait,
    /// player 1's cursor (its choice not made) moving on, else the newcomer's moves on; its frame
    /// lit; two players choose from now on.
    pub fn join(self: *Select, setup: *Setup, a: *const Assets, at: ?Character, chosen: bool) void {
        setup.players = .two;
        // Before its set-up, the set-up does it all.
        if (self.phase == .setup) return;
        self.players = .two;
        var place: Character = at orelse .blaze;
        var keep = at != null and chosen;
        const same = setup.same_character orelse false;
        if (!same and place == self.cursors[0].place) {
            if (keep and !self.cursors[0].chosen) {
                const to = next(place, true);
                self.cursors[0].place = to;
                switch (self.phase) {
                    .placing, .fade_in => self.colours.aim(a.lit(to)),
                    else => {
                        self.portraits[@backingInt(to)].cursor = true;
                        self.colours.show(a.lit(to));
                    },
                }
            } else {
                place = next(place, true);
                keep = false;
            }
        }
        self.cursors[1] = .{ .place = place, .chosen = keep };
        if (keep) setup.characters[1] = place;
        switch (self.phase) {
            // The fade in takes the frame lit, and lights its portrait at its end.
            .placing, .fade_in => self.colours.aim(a.lit(place)),
            else => {
                self.portraits[@backingInt(place)].cursor = true;
                self.colours.show(a.lit(place));
            },
        }
        self.list();
    }

    /// The second player goes: its cursor, its frame lit and its choice with it; one player
    /// chooses from now on.
    pub fn leave(self: *Select, setup: *Setup, a: *const Assets) void {
        setup.players = .one;
        setup.characters[1] = null;
        if (self.players == .one) return;
        self.players = .one;
        const place = self.cursors[1].place;
        if (self.cursors[0].place != place) {
            self.portraits[@backingInt(place)].cursor = false;
            switch (self.phase) {
                .setup, .placing, .fade_in => self.colours.aim(a.dim(place)),
                else => self.colours.show(a.dim(place)),
            }
        }
        self.cursors[1] = .{ .place = .blaze };
        self.list();
    }

    /// Player 1 goes and player 2 stays, alone (network play's client whose host's player left
    /// the select they shared): its cursor, as it was, the only one, named player 2's; chosen, it
    /// waits. False past the choice (the select fading out).
    pub fn keepSecond(self: *Select, a: *const Assets) bool {
        if (self.players != .two) return false;
        switch (self.phase) {
            .setup, .fade_out, .leaving => return false,
            else => {},
        }
        const first = self.cursors[0].place;
        if (first != self.cursors[1].place) {
            self.portraits[@backingInt(first)].cursor = false;
            switch (self.phase) {
                .placing, .fade_in => self.colours.aim(a.dim(first)),
                else => self.colours.show(a.dim(first)),
            }
        }
        self.cursors[0] = self.cursors[1];
        self.cursors[1] = .{ .place = .blaze };
        self.players = .one;
        self.seat = 1;
        self.list();
        return true;
    }

    /// The character the only player chose (a guest's own select, before it joins).
    pub fn chosenAlone(self: *const Select) ?Character {
        if (self.players != .one or !self.cursors[0].chosen) return null;
        return self.cursors[0].place;
    }

    /// The select's music, which plays from its set-up.
    pub fn music(self: *const Select, a: *const Assets) ?library.Sound {
        return if (self.phase == .setup) null else a.music;
    }

    fn next(c: Character, right: bool) Character {
        const n = places.len;
        const i = @backingInt(c);
        return @fromBackingInt(@intCast(if (right) (i + 1) % n else (i + n - 1) % n));
    }

    /// The sprites as the tick leaves them.
    fn list(self: *Select) void {
        var l: Listing = .{};
        for (self.cursors[0..self.count()], 0..) |c, i| l.labels[if (self.players == .one) self.seat else i] = c.place;
        for (self.portraits, 0..) |p, i| l.portraits[i] = .{ .pose = p.pose, .step = p.step, .y = p.y() };
        self.listed = l;
    }

    /// The portraits' frames copied at the next frame: each new frame's art.
    fn copies(self: *Select, a: *const Assets) transfers.Tiles {
        var t: transfers.Tiles = .{};
        for (&self.portraits, places) |*p, who| {
            if (!p.copy) continue;
            p.copy = false;
            for (a.poses.of(who, p.pose).steps[p.step].copied) |tiles| t.add(tiles * transfers.words_per_tile);
        }
        return t;
    }

    pub fn draw(self: *const Select, prev: ?*const Select, v: *view.View, a: *const Assets) !void {
        if (prev == null) {
            try v.board(.b).drawMapAtPlace(a.frame);
            for ([_]*const art.TileMap{ a.adam_name, a.axel_name, a.blaze_name, a.adam_stats, a.axel_stats, a.blaze_stats }) |m| {
                try v.board(.a).drawMapAtPlace(m);
            }
        }
        if (prev == null or prev.?.shown_eye_closed != self.shown_eye_closed) {
            try v.board(.b).drawMapAtPlace(if (self.shown_eye_closed) a.eye_closed else a.eye_open);
        }
        v.screen.colours = self.colours.shown;
        // Back to front: player 2's label, player 1's (on one portrait, when the variant lets
        // both players choose it, they take turns in front), Blaze, Axel, Adam.
        const one_place = self.shown.labels[0] != null and self.shown.labels[0] == self.shown.labels[1];
        const back_first: [2]usize = if (one_place and (self.ticks / label_turn) % 2 == 1) .{ 0, 1 } else .{ 1, 0 };
        for (back_first) |i| {
            const place = self.shown.labels[i] orelse continue;
            if (self.cpu_pass) {
                for (cpu_label, 0..) |ch, k| if (ch != ' ') {
                    const x = label_x.get(place) + cpu_label_x + @as(i16, @intCast(k * art.tile_side));
                    try v.sprites.append(v.gpa, .of(try v.glyphFrame(a.text, &.{ch}), x, label_y));
                };
            } else try v.sprites.append(v.gpa, .of(a.labels[i], label_x.get(place), label_y));
        }
        var k: usize = places.len;
        while (k > 0) {
            k -= 1;
            const s = self.shown.portraits[k] orelse continue;
            const who = places[k];
            const step = a.poses.of(who, s.pose).steps[s.step];
            var sprite: render.Sprite = .of(step.frame, portrait_x.get(who), s.y);
            sprite.flip_x = step.mirrored;
            try v.sprites.append(v.gpa, sprite);
        }
    }
};

const testing = std.testing;

/// Poses of one step each, but the idle's and the poses' four (their ends at 2 and 3), and
/// Blaze's pose C long enough for her jump.
const TestPoses = struct {
    frame: art.Frame = undefined,
    poses: library.Poses = .{},

    fn init(self: *TestPoses) void {
        self.frame = .{ .name = "f", .file = "f.png", .width = 1, .height = 1, .origin_x = 0, .origin_y = 0, .pixels = &.{1} };
        const step: library.Animation.Step = .{ .frame = &self.frame, .ticks = 1, .mirrored = false, .copied = .{ 34, 0 } };
        for (places) |who| for (std.enums.values(Pose)) |pose| {
            const n: u8 = switch (pose) {
                .stand, .landing => 1,
                .pose_c => 12,
                else => 7,
            };
            var anim: library.Animation = .{ .len = n };
            for (anim.steps[0..n]) |*s| s.* = step;
            if (pose == .stand) anim.steps[0].ticks = 100;
            self.poses.characters.getPtr(who).set(pose, anim);
        };
    }
};

const test_palette: art.Palette = .{ .name = "p" };
const test_map: art.TileMap = .{ .name = "m", .file = "m.tmj", .width = 1, .height = 1, .sheets = &.{}, .tiles = &.{}, .cells = &.{} };
const test_tiles = [_]art.Tile{@splat(1)};
const test_glyphs = [_]art.Glyph{ .{ .text = "C", .tile = 0 }, .{ .text = "P", .tile = 0 }, .{ .text = "U", .tile = 0 }, .{ .text = "1", .tile = 0 } };
const test_font: art.Font = .{ .name = "main", .sheet = "fonts/main", .glyphs = &test_glyphs };
const test_sheet: art.TileSheet = .{ .name = "main", .file = "main.png", .tiles = &test_tiles };

/// The select's assets of the tests: `tp`'s poses, one map and one palette for every picture.
fn testAssets(tp: *const TestPoses) Select.Assets {
    return .{
        .frame = &test_map,
        .eye_open = &test_map,
        .eye_closed = &test_map,
        .adam_name = &test_map,
        .axel_name = &test_map,
        .blaze_name = &test_map,
        .adam_stats = &test_map,
        .axel_stats = &test_map,
        .blaze_stats = &test_map,
        .colours = &test_palette,
        .one_player = &test_palette,
        .two_players = &test_palette,
        .adam_dim = &test_palette,
        .axel_dim = &test_palette,
        .blaze_dim = &test_palette,
        .adam_lit = &test_palette,
        .axel_lit = &test_palette,
        .blaze_lit = &test_palette,
        .labels = .{ &tp.frame, &tp.frame },
        .text = .{ .font = &test_font, .sheet = &test_sheet },
        .poses = tp.poses,
        .music = 1,
        .move = 2,
        .choose = 3,
        .swing = 4,
        .landing = 5,
        .stop = 6,
        .rounds = .{},
    };
}

test "the select: lost presses before its first tick, a move, a choice, the wait and the fade" {
    var tp: TestPoses = .{};
    tp.init();
    const a = testAssets(&tp);
    var setup: Setup = .{};
    var s: Select = .start(&setup);
    var turn: scene.Turn = .{ .setup = &setup };
    _ = s.tick(&turn, &a);
    try testing.expectEqualSlices(library.Sound, &.{1}, turn.requests.slice());
    try testing.expect(turn.frame == null);
    // The placing tick, then the fade's 64 ticks: right pressed during them is lost.
    for (0..65) |_| {
        turn = .{ .setup = &setup, .pressed = .{ .pad1 = .{ .right = true } } };
        _ = s.tick(&turn, &a);
    }
    try testing.expectEqual(Select.Phase.first_half, s.phase);
    // Right at the first half: Axel's, his frame lit, the move's sound; the portraits run in the
    // second half (Axel's pose with a swing).
    turn = .{ .setup = &setup, .pressed = .{ .pad1 = .{ .right = true } } };
    _ = s.tick(&turn, &a);
    try testing.expectEqual(Character.axel, s.cursors[0].place);
    try testing.expectEqualSlices(library.Sound, &.{2}, turn.requests.slice());
    try testing.expect(turn.frame == null);
    turn = .{ .setup = &setup };
    _ = s.tick(&turn, &a);
    try testing.expectEqual(Portrait.State.pose_a_first, s.portraits[1].state);
    try testing.expectEqual(Portrait.State.standing, s.portraits[0].state);
    try testing.expectEqualSlices(library.Sound, &.{4}, turn.requests.slice());
    // A at a second half counts at the next first half: Axel chosen.
    turn = .{ .setup = &setup };
    _ = s.tick(&turn, &a);
    turn = .{ .setup = &setup, .pressed = .{ .pad1 = .{ .a = true } } };
    _ = s.tick(&turn, &a);
    try testing.expectEqual(Select.Phase.first_half, s.phase);
    try testing.expectEqual(@as(?Character, null), setup.characters[0]);
    turn = .{ .setup = &setup };
    _ = s.tick(&turn, &a);
    try testing.expectEqual(@as(?Character, .axel), setup.characters[0]);
    // The second half sees every player chosen: 18 ticks of wait, 64 of fade, then the exit.
    turn = .{ .setup = &setup };
    _ = s.tick(&turn, &a);
    try testing.expectEqual(Select.Phase.wait, s.phase);
    var ticks: usize = 0;
    var exit: ?flow.Exit = null;
    while (exit == null) : (ticks += 1) {
        turn = .{ .setup = &setup };
        exit = s.tick(&turn, &a);
    }
    try testing.expectEqual(@as(usize, 18 + 64 + 1), ticks);
    // No round 1 in this content: the stand-in follows.
    try testing.expectEqual(flow.Exit.missing, exit.?);
    try testing.expectEqualSlices(library.Sound, &.{6}, turn.requests.slice());
}

test "two players: a move skips the other player's portrait; Blaze's jumps keep the fraction" {
    var tp: TestPoses = .{};
    tp.init();
    const a = testAssets(&tp);
    var setup: Setup = .{ .players = .two };
    var s: Select = .start(&setup);
    var turn: scene.Turn = .{ .setup = &setup };
    for (0..66) |_| _ = s.tick(&turn, &a);
    // Player 2 (on Blaze) left: Axel's; then player 1 (on Adam) right skips Axel to Blaze.
    turn = .{ .setup = &setup, .pressed = .{ .pad2 = .{ .left = true } } };
    _ = s.tick(&turn, &a);
    try testing.expectEqual(Character.axel, s.cursors[1].place);
    turn = .{ .setup = &setup };
    _ = s.tick(&turn, &a);
    turn = .{ .setup = &setup, .pressed = .{ .pad1 = .{ .right = true } } };
    _ = s.tick(&turn, &a);
    try testing.expectEqual(Character.blaze, s.cursors[0].place);
    // Blaze poses and jumps: her heights, and the landing.
    var p: Portrait = .{ .state = .pose_c, .pose = .pose_c, .step = jump_from, .left = 1, .cursor = true };
    var highest: i16 = 208;
    var landed = false;
    for (0..40) |_| {
        turn = .{ .setup = &setup };
        p.tick(.blaze, &turn, &a);
        highest = @min(highest, p.y());
        if (p.state == .landing) {
            landed = true;
            break;
        }
    }
    try testing.expect(landed);
    try testing.expectEqual(@as(i16, 208 - 31), highest);
    try testing.expectEqual(@as(i16, 208), p.y());
    try testing.expect(@mod(p.z, one) != 0);
}

test "1 PLAYER - 1 CPU: player 1 chooses, the select comes again, its music on, and chooses the CPU's" {
    var tp: TestPoses = .{};
    tp.init();
    const a = testAssets(&tp);
    var setup: Setup = .{ .players = .two, .cpu = .{ false, true } };
    var s: Select = .start(&setup);
    var turn: scene.Turn = .{ .setup = &setup };
    for (0..66) |_| _ = s.tick(&turn, &a);
    // One cursor, pad 1's: Adam chosen for player 1.
    try testing.expectEqual(setup_mod.Players.one, s.players);
    turn = .{ .setup = &setup, .pressed = .{ .pad1 = .{ .a = true } } };
    _ = s.tick(&turn, &a);
    for (0..1 + 18 + 64) |_| {
        turn = .{ .setup = &setup };
        _ = s.tick(&turn, &a);
    }
    try testing.expectEqual(@as(?Character, .adam), setup.characters[0]);
    try testing.expect(s.cpu_pass and s.phase == .setup);
    // Again from its set-up, the music not asked again: right to Axel, chosen, the CPU's.
    turn = .{ .setup = &setup };
    _ = s.tick(&turn, &a);
    try testing.expectEqual(@as(usize, 0), turn.requests.slice().len);
    for (0..65) |_| _ = s.tick(&turn, &a);
    for ([_]input.Pad{ .{ .right = true }, .{}, .{ .a = true }, .{}, .{}, .{} }) |p| {
        turn = .{ .setup = &setup, .pressed = .{ .pad1 = p } };
        _ = s.tick(&turn, &a);
    }
    try testing.expectEqual(@as(?Character, .adam), setup.characters[0]);
    try testing.expectEqual(@as(?Character, .axel), setup.characters[1]);
    var exit: ?flow.Exit = null;
    while (exit == null) {
        turn = .{ .setup = &setup };
        exit = s.tick(&turn, &a);
    }
    try testing.expectEqual(flow.Exit.missing, exit.?);
}

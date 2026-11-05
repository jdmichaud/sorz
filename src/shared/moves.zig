//! MOVES (DESIGN.md 10.4 S4, PLAN item 43): each character's blows and the damage each does,
//! shown on a screen of this machine's that the settings open (settings/screen.zig, game.zig).
//!
//! A black screen. Adam walks in from the bottom left, Axel from the top left, Blaze from the
//! right; each plays its moves in the middle, then walks out across, a spotlight on the floor
//! under it. The moves: the combo, the jump kick, the back attack, the hold's knees and last
//! knee, the throw over the shoulder, the slam from behind. There is no enemy and no world: the
//! character alone plays its definition's animations frame by frame at play's pace (a logic tick
//! every other display tick), each move ending at the frame the player's own ends it (its
//! numbers: `blow_ends`, `throw_ends`...), its walks, its jump and its leaps moved by its own
//! speeds and gravity, as the player behaviour moves them (world/behaviours/player.zig). Where
//! a move's blow strikes (the first frame of its blow, or a hold's the frame that lets the one
//! held go), the move's damage shows: a digit in the game's font where the enemy would be, which
//! rises and fades. The frames' and the moves' own sounds play (the swings, the shouts); a blow's
//! landing, no.
//!
//! It is this machine's, never the game's state: the game holds under it, as under the settings.
const std = @import("std");
const library = @import("library.zig");
const view_mod = @import("view.zig");
const render = @import("render/root.zig");
const art = @import("content/art.zig");
const content_entity = @import("content/entity.zig");
const world = @import("world/root.zig");
const audio = @import("audio/root.zig");
const platform = @import("platform.zig");
const json = @import("formats/json.zig");

const Fixed = world.Fixed;
const Facing = world.entity.Facing;
const Kind = world.kinds.Kind;
const player = world.behaviours.player;

pub const Assets = struct {
    text: library.Text,
    players_colours: *const art.Palette,
    sounds: *const library.Sounds,

    pub const names = .{
        .text = "fonts/main",
        .players_colours = "play/players",
        .sounds = "sound",
    };
};

/// A place on the floor: across, and in depth.
const Spot = struct { x: i32, depth: i32 };

/// The screen line of the floor at depth 0: a place's line is its depth's half below it.
const floor_line = 140;

/// Where each plays its moves.
const stage: Spot = .{ .x = 160, .depth = 60 };

/// Who comes, in their order: from where, to where it leaves, and the side it faces while it
/// plays.
const Entrance = struct { name: []const u8, from: Spot, to: Spot, facing: Facing };
const cast = [_]Entrance{
    .{ .name = "adam", .from = .{ .x = -40, .depth = 110 }, .to = .{ .x = 360, .depth = 16 }, .facing = .right },
    .{ .name = "axel", .from = .{ .x = -40, .depth = 16 }, .to = .{ .x = 360, .depth = 110 }, .facing = .right },
    .{ .name = "blaze", .from = .{ .x = 360, .depth = 60 }, .to = .{ .x = -40, .depth = 60 }, .facing = .left },
};

/// What it plays, in its order.
const Phase = enum { walk_in, combo, jump_kick, back_attack, knees, throw, slam, walk_out };

/// The logic ticks it stands ready between two moves, and holds a hold before its blows.
const ready_ticks = 18;
const hold_ticks = 10;
/// The logic ticks of the hold between two knees.
const knee_gap_ticks = 6;

/// A digit's life in display ticks: it rises a pixel each (the combo's next shows well below
/// it), and fades over its last `fade_ticks`, a step every `fade_ticks / fade_steps`.
const digit_ticks = 48;
const fade_ticks = 24;
const fade_steps = 4;
const most_digits = 8;

/// The palettes' lines: the characters' (the players' colours), the spotlight's, the digits'.
const spot_palette = 1;
const digit_palette = 2;

/// The font's colours: its letter, its shade, its ground (which outlines the digits).
const font_letter = 1;
const font_ground = 2;

/// The spotlight: an oval this wide and deep, in three shades.
const spot_width = 88;
const spot_height = 26;
const spot_shades = [_]art.Colour{ .{ .r = 1, .g = 1, .b = 1 }, .{ .r = 2, .g = 2, .b = 2 }, .{ .r = 3, .g = 3, .b = 3 } };

/// A move's damage shown: its digit, where it shows (screen pixels: the middle of its bottom),
/// and its display ticks so far.
const Digit = struct { value: u8, x: i32, y: i32, age: u16 = 0 };

/// The character playing: its kind and numbers, its place (height 0 on the floor, negative up)
/// and speeds, the side it faces, the frame it shows and the ticks left on it, the move it plays
/// and whether its damage showed; the hold's imaginary one, where the vault goes around it.
const Puppet = struct {
    kind: *const Kind,
    n: player.Numbers,
    x: Fixed,
    depth: Fixed,
    height: Fixed = .zero,
    vx: Fixed = .zero,
    vdepth: Fixed = .zero,
    vh: Fixed = .zero,
    airborne: bool = false,
    facing: Facing,
    animation: u8 = 0,
    frame: u8 = 0,
    left: u8 = 1,
    move: ?u8 = null,
    shown: bool = false,
    held_x: i32 = 0,
};

pub const Moves = struct {
    gpa: std.mem.Allocator,
    assets: Assets,
    kinds: *const world.Kinds,
    view: view_mod.View,
    sound: ?audio.Sound = null,
    spot: *art.Frame,
    /// Each digit's frames, by its fade's step.
    digit_frames: [10][fade_steps]*art.Frame,
    colours: render.palettes.Colours = render.palettes.black,
    who: u8 = 0,
    phase: Phase = .walk_in,
    /// The phase's step, and its count of ticks.
    sub: u8 = 0,
    timer: u16 = 0,
    /// Down from the air, the landing's crouch shows.
    crouching: bool = false,
    puppet: ?Puppet = null,
    digits: [most_digits]?Digit = @splat(null),
    /// The sounds the logic tick asked for.
    asked: [8]u16 = undefined,
    asked_len: u8 = 0,
    display_ticks: u32 = 0,
    /// All three played: MOVES ends.
    over: bool = false,

    pub const Error = error{ OutOfMemory, BadContent };

    /// MOVES from its start, on the content `c`, its sound at `rate` frames a second (none
    /// without the content's sound).
    pub fn create(gpa: std.mem.Allocator, c: *const library.Content, rate: ?u32) Error!*Moves {
        var diag: json.Diagnostic = .{};
        const assets = library.find(Assets, c, &diag) catch |e| {
            std.log.warn("MOVES: {f}", .{&diag});
            return e;
        };
        for (cast) |who| if (c.kinds.find(who.name) == null) return error.BadContent;
        const self = try gpa.create(Moves);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .assets = assets, .kinds = &c.kinds, .view = try .init(gpa), .spot = undefined, .digit_frames = undefined };
        errdefer self.view.deinit();
        self.spot = try spotFrame(gpa);
        errdefer freeFrame(gpa, self.spot);
        var made: usize = 0;
        errdefer for (0..made) |i| for (self.digit_frames[i]) |f| freeFrame(gpa, f);
        for (&self.digit_frames, 0..) |*steps, d| {
            steps.* = try digitFrames(gpa, assets.text, @intCast(d));
            made += 1;
        }
        if (rate) |r| self.sound = audio.Sound.init(gpa, assets.sounds, r) catch null;
        try self.view.begin(0, .{});
        self.colours = coloursOf(assets.players_colours);
        self.start();
        return self;
    }

    pub fn destroy(self: *Moves) void {
        const gpa = self.gpa;
        if (self.sound) |*s| s.deinit(gpa);
        for (self.digit_frames) |steps| for (steps) |f| freeFrame(gpa, f);
        freeFrame(gpa, self.spot);
        self.view.deinit();
        gpa.destroy(self);
    }

    /// One display tick: the character's logic tick every other one, the digits' rise and fade;
    /// the tick's sound frames (stereo, interleaved; empty without sound), valid until the next.
    pub fn tick(self: *Moves) []const i16 {
        defer self.display_ticks +%= 1;
        if (self.display_ticks % 2 == 0 and !self.over) self.logicTick();
        for (&self.digits) |*slot| if (slot.*) |*d| {
            d.age += 1;
            if (d.age >= digit_ticks) slot.* = null;
        };
        const s = if (self.sound) |*s| s else return &.{};
        for (self.asked[0..self.asked_len]) |id| s.play(id);
        self.asked_len = 0;
        return s.tick();
    }

    /// The picture as it stands: the spotlight under the character, its shadow, the character,
    /// the digits.
    pub fn draw(self: *Moves) error{OutOfMemory}!platform.RgbaFrame {
        const v = &self.view;
        v.sprites.clearRetainingCapacity();
        v.screen.colours = self.colours;
        if (self.puppet) |*p| {
            const x = p.x.whole();
            const floor = (p.depth.whole() >> 1) + floor_line;
            try v.sprites.append(v.gpa, .{ .frame = self.spot, .x = x, .y = floor, .palette = spot_palette });
            if (self.kinds.shadow) |shadow| try v.sprites.append(v.gpa, .{ .frame = shadow, .x = x, .y = floor, .palette = shadow.palette });
            const shown = p.kind.definition.animations[p.animation].frames[p.frame];
            const f = p.kind.frames[p.animation][p.frame];
            try v.sprites.append(v.gpa, .{ .frame = f, .x = x, .y = floor + p.height.whole(), .flip_x = (p.facing == .left) != shown.flip, .palette = f.palette });
        }
        for (self.digits) |slot| if (slot) |d| {
            const f = self.digit_frames[d.value][fadeStep(d.age)];
            try v.sprites.append(v.gpa, .{ .frame = f, .x = d.x, .y = d.y - @as(i32, d.age), .palette = digit_palette });
        };
        return v.compose();
    }

    // The script ----------------------------------------------------------------------------

    /// The next character walks in, from its entrance's place.
    fn start(self: *Moves) void {
        const who = cast[self.who];
        const id = self.kinds.find(who.name).?;
        const k = self.kinds.get(id);
        self.puppet = .{
            .kind = k,
            .n = world.kinds.numbersOf(player, k),
            .x = .pixels(who.from.x),
            .depth = .pixels(who.from.depth),
            .facing = if (who.from.x < stage.x) .right else .left,
        };
        self.enter(.walk_in);
        self.animate(.walk);
    }

    fn enter(self: *Moves, phase: Phase) void {
        self.phase = phase;
        self.sub = 0;
        self.timer = 0;
        self.crouching = false;
    }

    /// The phase after a move, once the character has stood ready a while.
    fn next(self: *Moves) void {
        const p = &self.puppet.?;
        if (self.sub == 0xFF) {
            self.timer += 1;
            if (self.timer < ready_ticks) return;
            self.enter(@fromBackingInt(@backingInt(self.phase) + 1));
            self.begin();
            return;
        }
        p.move = null;
        p.vx = .zero;
        p.vdepth = .zero;
        self.animate(.ready);
        self.sub = 0xFF;
        self.timer = 0;
    }

    /// A move's first tick.
    fn begin(self: *Moves) void {
        const p = &self.puppet.?;
        p.facing = cast[self.who].facing;
        switch (self.phase) {
            .walk_in, .walk_out => self.animate(.walk),
            .combo => self.startMove(.attack1),
            .jump_kick => {
                self.ownSound(.jump);
                self.animate(.jump_crouch);
            },
            .back_attack => self.animate(.jump_crouch),
            .knees, .throw, .slam => self.animate(.grab),
        }
        if (self.phase == .back_attack and p.n.back_attack_up == null) self.startMove(.back_attack);
    }

    fn logicTick(self: *Moves) void {
        const p = &self.puppet.?;
        if (self.sub == 0xFF and self.phase != .walk_out) return self.next();
        switch (self.phase) {
            .walk_in => if (self.walkTo(stage)) self.next(),
            .combo => self.combo(),
            .jump_kick => self.jumpKick(),
            .back_attack => self.backAttack(),
            .knees => self.knees(),
            .throw => self.throwOver(),
            .slam => self.slam(),
            .walk_out => if (self.walkTo(cast[self.who].to)) {
                self.who += 1;
                if (self.who == cast.len) {
                    self.over = true;
                    self.puppet = null;
                    return;
                }
                return self.start();
            },
        }
        self.move(p);
    }

    /// Walks toward `to`, as the player's walk goes by the pad (across and in depth, the
    /// diagonal's speeds when both); whether it is there.
    fn walkTo(self: *Moves, to: Spot) bool {
        const p = &self.puppet.?;
        const dx = to.x - p.x.whole();
        const dd = to.depth - p.depth.whole();
        const across: i32 = if (dx > 2) 1 else if (dx < -2) -1 else 0;
        const depth: i32 = if (dd > 1) 1 else if (dd < -1) -1 else 0;
        if (across == 0 and depth == 0) {
            p.vx = .zero;
            p.vdepth = .zero;
            return true;
        }
        if (across != 0) p.facing = if (across < 0) .left else .right;
        const diagonal = across != 0 and depth != 0;
        p.vx = (if (diagonal) p.n.diagonal_x else p.n.walk_x).times(across);
        p.vdepth = (if (diagonal) p.n.diagonal_depth else p.n.walk_depth).times(depth);
        _ = self.step();
        return false;
    }

    /// The combo: the four blows, each from the frame the one before ends at (its
    /// `blow_ends`, the third's `attack3_ends`); the last ends at `last_blow_ends`, or leaps
    /// from `last_blow_leap` (Blaze's) and lands.
    fn combo(self: *Moves) void {
        const p = &self.puppet.?;
        if (self.sub == 4) return self.leapLanding();
        _ = self.step();
        const n = p.n;
        switch (self.sub) {
            0, 1, 2 => if (p.frame == if (self.sub == 2) n.attack3_ends else n.blow_ends) {
                self.sub += 1;
                self.startMove(switch (self.sub) {
                    1 => .attack2,
                    2 => .attack3,
                    else => .attack4,
                });
            },
            else => {
                if (n.last_blow_leap) |from| if (p.frame >= from) {
                    self.leap();
                    if (p.airborne) self.sub = 4;
                    return;
                };
                if (p.frame == n.last_blow_ends) self.next();
            },
        }
    }

    /// The jump kick: the jump's crouch, the jump (where it stands), the kick as it nears the
    /// jump's top, held on its last frame down to the landing.
    fn jumpKick(self: *Moves) void {
        const p = &self.puppet.?;
        switch (self.sub) {
            0 => if (self.countDown()) {
                self.animate(.jump);
                p.vh = p.n.jump;
                p.airborne = true;
                self.sub = 1;
            },
            1 => {
                self.gravity();
                if (p.vh.raw >= @divTrunc(p.n.jump.raw, 3)) {
                    self.startMove(.jump_kick);
                    self.sub = 2;
                }
            },
            2 => {
                if (!p.airborne) {
                    self.sub = 3;
                    return self.landing();
                }
                self.kickGravity();
                self.toLastFrame();
            },
            else => self.landing(),
        }
    }

    /// The back attack where it stands; Adam's jumps (`back_attack_up`): its crouch, then up,
    /// to its last frame, down to the landing.
    fn backAttack(self: *Moves) void {
        const p = &self.puppet.?;
        const up = p.n.back_attack_up orelse {
            _ = self.step();
            if (p.frame == p.n.back_attack_ends) self.next();
            return;
        };
        switch (self.sub) {
            0 => if (self.countDown()) {
                self.startMove(.back_attack);
                p.vh = up;
                p.airborne = true;
                self.sub = 1;
            },
            1 => {
                if (!p.airborne) {
                    self.sub = 2;
                    return self.landing();
                }
                self.toLastFrame();
                self.gravity();
            },
            else => self.landing(),
        }
    }

    /// The hold's blows: a knee, the hold, a knee, the hold, the last knee (Blaze's leaps from
    /// `knee_last_leap`), to its `knee_last_ends`.
    fn knees(self: *Moves) void {
        const p = &self.puppet.?;
        switch (self.sub) {
            0, 2, 4 => {
                self.timer += 1;
                const wait: u16 = if (self.sub == 0) hold_ticks else knee_gap_ticks;
                if (self.timer < wait) return;
                self.timer = 0;
                self.sub += 1;
                self.startMove(if (self.sub == 5) .knee_last else .knee);
            },
            1, 3 => if (self.countDown()) {
                self.animate(.grab);
                self.sub += 1;
            },
            // A last knee that leaps does so from its frame, and has no end of its own before
            // it (as the player's).
            5 => {
                _ = self.step();
                if (p.n.knee_last_leap) |from| {
                    if (p.frame < from) return;
                    self.leap();
                    if (p.airborne) self.sub = 6;
                    return;
                }
                if (p.frame == p.n.knee_last_ends) self.next();
            },
            else => self.leapLanding(),
        }
    }

    /// The throw over the shoulder: the hold, then the throw (the character turned first where
    /// its throw turns it: `throw_turns`), to its `grab_blow_ends`.
    fn throwOver(self: *Moves) void {
        const p = &self.puppet.?;
        switch (self.sub) {
            0 => {
                self.timer += 1;
                if (self.timer < hold_ticks) return;
                if (p.n.throw_turns != 0) p.facing = p.facing.turned();
                self.startMove(.grab_blow);
                self.sub = 1;
            },
            else => {
                _ = self.step();
                if (p.frame == p.n.grab_blow_ends) self.next();
            },
        }
    }

    /// The slam from behind: the hold, the vault over the one held (going around it, by each
    /// frame's `place`) to its `throw_ends`, turned, the hold from behind, the slam to its
    /// `vault_ends`, and its landing's frames.
    fn slam(self: *Moves) void {
        const p = &self.puppet.?;
        switch (self.sub) {
            0 => {
                self.timer += 1;
                if (self.timer < hold_ticks) return;
                const held = p.kind.definition.animations[p.animation].frames[0].held;
                p.held_x = p.x.whole() + @as(i32, if (held) |h| h.x else 0) * p.facing.sign();
                self.ownSound(.jump);
                self.startMove(.throw);
                self.goAround();
                self.sub = 1;
            },
            1 => {
                if (self.step()) self.goAround();
                if (p.frame != p.n.throw_ends) return;
                self.ownSound(.land);
                p.facing = p.facing.turned();
                p.height = .zero;
                self.animate(.grab_behind);
                self.timer = 0;
                self.sub = 2;
            },
            2 => {
                self.timer += 1;
                if (self.timer < hold_ticks) return;
                self.startMove(.vault);
                self.sub = 3;
            },
            3 => {
                _ = self.step();
                if (p.frame != p.n.vault_ends) return;
                self.animate(.vault_land);
                self.sub = 4;
            },
            else => if (self.step() and p.frame == 0) self.next(),
        }
    }

    /// In the vault, the character goes where its frame puts it around the one held (as the
    /// player's `goAround`).
    fn goAround(self: *Moves) void {
        const p = &self.puppet.?;
        const at = p.kind.definition.animations[p.animation].frames[p.frame].place orelse return;
        p.x = .pixels(p.held_x + @as(i32, at.x) * p.facing.sign());
        p.height = .pixels(at.height);
    }

    /// A blow that leaps: once, up and back from the side it faces; then it falls as a jump kick.
    fn leap(self: *Moves) void {
        const p = &self.puppet.?;
        if (!p.airborne) {
            p.vh = p.n.leap_up;
            p.vx = p.n.leap_back.times(-p.facing.sign());
            p.airborne = true;
        }
        self.kickGravity();
    }

    /// A leaping blow in the air: its frames run on as it falls (as the player's), then it lands.
    fn leapLanding(self: *Moves) void {
        const p = &self.puppet.?;
        if (p.airborne) _ = self.step();
        self.landing();
    }

    /// Down from a leap, a jump or a jumping back attack: the frame it shows stays to the ground,
    /// then the landing's crouch, and it stands ready.
    fn landing(self: *Moves) void {
        const p = &self.puppet.?;
        if (p.airborne) {
            self.kickGravity();
            return;
        }
        if (!self.crouching) {
            self.ownSound(.land);
            self.animate(.jump_crouch);
            self.crouching = true;
            return;
        }
        if (!self.countDown()) return;
        self.crouching = false;
        self.next();
    }

    /// Its move: by its speeds; in the air, down to the floor, where it lands (its speeds gone).
    fn move(self: *Moves, p: *Puppet) void {
        _ = self;
        p.x = p.x.add(p.vx);
        p.depth = p.depth.add(p.vdepth);
        if (!p.airborne) return;
        p.height = p.height.add(p.vh);
        if (p.height.lessThan(.zero)) return;
        p.height = .zero;
        p.vh = .zero;
        p.vx = .zero;
        p.airborne = false;
    }

    fn gravity(self: *Moves) void {
        const p = &self.puppet.?;
        p.vh = p.vh.add(.of(p.kind.definition.gravity));
    }

    /// A jump kick's gravity, and a leap's: its own going up, a lighter one coming down.
    fn kickGravity(self: *Moves) void {
        const p = &self.puppet.?;
        if (p.vh.raw < 0) return self.gravity();
        p.vh = p.vh.add(p.n.kick_falling_gravity);
    }

    // The animation, as the player's (tick.zig's Actor) ----------------------------------------

    fn animate(self: *Moves, which: player.Animation) void {
        const p = &self.puppet.?;
        p.move = null;
        self.startAnimation(p.kind.animation_of[@backingInt(which)]);
    }

    fn startMove(self: *Moves, which: player.Move) void {
        const p = &self.puppet.?;
        const index = p.kind.move_of[@backingInt(which)];
        const m = p.kind.definition.moves[index];
        if (m.sound) |s| self.ask(s);
        p.move = index;
        p.shown = false;
        p.animation = m.animation;
        self.showFrame(0);
    }

    fn startAnimation(self: *Moves, index: u8) void {
        const p = &self.puppet.?;
        p.animation = index;
        self.showFrame(0);
    }

    fn showFrame(self: *Moves, index: u8) void {
        const p = &self.puppet.?;
        p.frame = index;
        const f = p.kind.definition.animations[p.animation].frames[index];
        p.left = f.ticks;
        if (f.sound) |s| self.ask(s);
        self.struck();
    }

    /// The frame's ticks count down: whether they ran out.
    fn countDown(self: *Moves) bool {
        const p = &self.puppet.?;
        p.left -%= 1;
        return p.left == 0;
    }

    /// A tick of the animation: its next frame (after the last, the first) once the frame's
    /// ticks ran out; whether the frame changed.
    fn step(self: *Moves) bool {
        const p = &self.puppet.?;
        if (!self.countDown()) return false;
        const frames = p.kind.definition.animations[p.animation].frames;
        self.showFrame(if (p.frame + 1 < frames.len) p.frame + 1 else 0);
        return true;
    }

    /// The animation runs on to its last frame, which then stays.
    fn toLastFrame(self: *Moves) void {
        const p = &self.puppet.?;
        if (p.frame + 1 < p.kind.definition.animations[p.animation].frames.len) _ = self.step();
    }

    /// At the frame its move's blow strikes, the move's damage shows, once a move: the first
    /// frame of its blow, or in a hold the frame that lets the one held go.
    fn struck(self: *Moves) void {
        const p = &self.puppet.?;
        const index = p.move orelse return;
        if (p.shown) return;
        const m = p.kind.definition.moves[index];
        const frames = p.kind.definition.animations[m.animation].frames;
        const f = frames[p.frame];
        const lets_go = for (frames) |x| {
            if (x.held) |h| if (h.lets_go) break true;
        } else false;
        const strikes = if (lets_go) (if (f.held) |h| h.lets_go else false) else f.blow;
        if (!strikes or m.damage == 0) return;
        p.shown = true;
        // Where the enemy would be: the blow's spark, or the one held's place (its middle).
        const at: struct { x: i32, height: i32 } = if (f.spark) |s|
            .{ .x = s.x, .height = s.height }
        else if (f.held) |h|
            .{ .x = h.x, .height = @as(i32, h.height) - held_middle }
        else
            .{ .x = default_reach, .height = -held_middle };
        self.show(@intCast(@min(m.damage, 9)), p.x.whole() + at.x * p.facing.sign(), (p.depth.whole() >> 1) + floor_line + p.height.whole() + at.height - digit_above);
    }

    fn show(self: *Moves, value: u8, x: i32, y: i32) void {
        for (&self.digits) |*slot| if (slot.* == null) {
            slot.* = .{ .value = value, .x = x, .y = y };
            return;
        };
    }

    /// The character's own sound `which` (its jump's, its landing's), as the player asks for it.
    fn ownSound(self: *Moves, which: player.Sound) void {
        const p = &self.puppet.?;
        self.ask(p.kind.sound_of[@backingInt(which)]);
    }

    fn ask(self: *Moves, name: []const u8) void {
        const id = self.assets.sounds.find(name) orelse return;
        if (self.asked_len == self.asked.len) return;
        self.asked[self.asked_len] = id;
        self.asked_len += 1;
    }
};

/// The middle of the one held, above its feet; the reach of a blow without a spark; how far
/// above the blow's place a digit's bottom shows.
const held_middle = 40;
const default_reach = 40;
const digit_above = 4;

/// The fade's step at a digit's `age`: 0, whole, to `fade_steps - 1`, nearly gone.
fn fadeStep(age: u16) usize {
    if (age + fade_ticks < digit_ticks) return 0;
    const into = age + fade_ticks - digit_ticks;
    return @min(fade_steps - 1, into * fade_steps / fade_ticks);
}

/// The colours: every line black, but the characters' (the players' colours), the spotlight's
/// shades, and the digits' (the font's letter and shade, its ground black, which outlines them).
fn coloursOf(players: *const art.Palette) render.palettes.Colours {
    var c = render.palettes.black;
    players.apply(&c);
    for (spot_shades, 1..) |s, i| c[spot_palette][i] = s;
    c[digit_palette] = c[0];
    c[digit_palette][font_ground] = .black;
    return c;
}

/// The spotlight's frame: an oval of three shades, the brightest in its middle, their edges
/// dithered; its origin at its middle.
fn spotFrame(gpa: std.mem.Allocator) error{OutOfMemory}!*art.Frame {
    const pixels = try gpa.alloc(u8, spot_width * spot_height);
    errdefer gpa.free(pixels);
    spotPixels(pixels);
    const f = try gpa.create(art.Frame);
    f.* = .{ .name = "spotlight", .file = "", .width = spot_width, .height = spot_height, .origin_x = spot_width / 2, .origin_y = spot_height / 2, .pixels = pixels };
    return f;
}

/// The oval's shades: by the distance from its middle (1 at its rim), a shade more every third
/// of it inward; an ordered dither's threshold mixes two shades over a band at each edge. In
/// whole numbers (the browser's module has no float helpers): shade `k` holds where the distance
/// `r` is at most `1 - (k - t) / 3`, `t` the threshold, compared squared.
fn spotPixels(out: []u8) void {
    const bayer = [4][4]u64{ .{ 0, 8, 2, 10 }, .{ 12, 4, 14, 6 }, .{ 3, 11, 1, 9 }, .{ 15, 7, 13, 5 } };
    const w: u64 = spot_width;
    const h: u64 = spot_height;
    // The rim, squared, in the half pixels the distances are counted in.
    const rim = w * w * h * h;
    for (0..spot_height) |y| for (0..spot_width) |x| {
        const dx: i64 = @as(i64, @intCast(2 * x + 1)) - spot_width;
        const dy: i64 = @as(i64, @intCast(2 * y + 1)) - spot_height;
        const r2: u64 = @as(u64, @intCast(dx * dx)) * h * h + @as(u64, @intCast(dy * dy)) * w * w;
        if (r2 >= rim) {
            out[y * spot_width + x] = 0;
            continue;
        }
        // The threshold in 32nds; the distance's bound for shade k in 96ths of the rim.
        const t = 2 * bayer[y % 4][x % 4] + 1;
        var shade: u8 = 1;
        for (2..spot_shades.len + 1) |k| {
            const bound = 96 + t -| 32 * k;
            if (r2 * 96 * 96 <= bound * bound * rim) shade = @intCast(k);
        }
        out[y * spot_width + x] = shade;
    };
}

/// Digit `d`'s frames, by the fade's step: the font's glyph, outlined in its ground colour (as
/// the cartridge's labels: view.zig `outlinedText`), then fewer of its pixels at each step, by
/// an ordered pattern; their origin at the middle of their bottom.
fn digitFrames(gpa: std.mem.Allocator, t: library.Text, d: u8) error{ OutOfMemory, BadContent }![fade_steps]*art.Frame {
    const g = t.font.glyphAt(&.{'0' + d}) orelse return error.BadContent;
    const side = art.tile_side;
    const w = side + 2;
    const h = side + 2;
    var whole: [w * h]u8 = @splat(0);
    for (0..side) |y| for (0..side) |x| {
        whole[(y + 1) * w + x + 1] = t.sheet.tiles[g.tile][y * side + x];
    };
    // The ground: none, but where it touches a letter's pixel, which it outlines.
    for (&whole) |*px| if (px.* == font_ground) {
        px.* = 0;
    };
    var outlined = whole;
    for (0..h) |y| for (0..w) |x| {
        if (whole[y * w + x] != 0) continue;
        const touches = (x > 0 and whole[y * w + x - 1] != 0) or (x + 1 < w and whole[y * w + x + 1] != 0) or
            (y > 0 and whole[(y - 1) * w + x] != 0) or (y + 1 < h and whole[(y + 1) * w + x] != 0);
        if (touches) outlined[y * w + x] = font_ground;
    };
    var out: [fade_steps]*art.Frame = undefined;
    var made: usize = 0;
    errdefer for (out[0..made]) |f| freeFrame(gpa, f);
    const pattern = [4][4]u8{ .{ 0, 2, 0, 2 }, .{ 3, 1, 3, 1 }, .{ 0, 2, 0, 2 }, .{ 3, 1, 3, 1 } };
    for (&out, 0..) |*f, step| {
        const pixels = try gpa.alloc(u8, w * h);
        errdefer gpa.free(pixels);
        for (0..h) |y| for (0..w) |x| {
            pixels[y * w + x] = if (pattern[y % 4][x % 4] < step) 0 else outlined[y * w + x];
        };
        f.* = try gpa.create(art.Frame);
        f.*.* = .{ .name = "digit", .file = "", .width = w, .height = h, .origin_x = w / 2, .origin_y = h, .pixels = pixels };
        made += 1;
    }
    return out;
}

fn freeFrame(gpa: std.mem.Allocator, f: *art.Frame) void {
    gpa.free(f.pixels);
    gpa.destroy(f);
}

// --- tests -----------------------------------------------------------------------------------------

const testing = std.testing;

test "the spotlight: an oval, brightest in its middle, nothing past its rim" {
    var px: [spot_width * spot_height]u8 = undefined;
    spotPixels(&px);
    try testing.expectEqual(@as(u8, 0), px[0]);
    try testing.expectEqual(@as(u8, 0), px[spot_width - 1]);
    try testing.expectEqual(@as(u8, 3), px[(spot_height / 2) * spot_width + spot_width / 2]);
    for (px) |p| try testing.expect(p <= spot_shades.len);
    // Left and right alike, but the dither.
    var lit: [2]usize = .{ 0, 0 };
    for (0..spot_height) |y| for (0..spot_width) |x| {
        if (px[y * spot_width + x] != 0) lit[@intFromBool(x >= spot_width / 2)] += 1;
    };
    try testing.expectEqual(lit[0], lit[1]);
}

test "a digit fades over its last ticks, in steps, whole until then" {
    try testing.expectEqual(@as(usize, 0), fadeStep(0));
    try testing.expectEqual(@as(usize, 0), fadeStep(digit_ticks - fade_ticks - 1));
    try testing.expectEqual(@as(usize, 0), fadeStep(digit_ticks - fade_ticks));
    try testing.expectEqual(@as(usize, fade_steps - 1), fadeStep(digit_ticks - 1));
    var last: usize = 0;
    for (0..digit_ticks) |a| {
        const s = fadeStep(@intCast(a));
        try testing.expect(s >= last);
        last = s;
    }
}

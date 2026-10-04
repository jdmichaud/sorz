//! The intro: the city at night and its story scrolling up, the three heroes' profiles typed
//! beside their pictures, the city again rushing past while Axel's picture forms, Adam and Blaze
//! arriving, the flash, and the title it ends on (title.zig has the parts it shares with the
//! title that START sets up). Its script (`screens/intro`, the original's) starts each part at its
//! tick; a part runs from then on each tick, in the order of its place in the original's list of
//! objects, which is also the order of their pictures (the first in front). A part the script
//! gives a life ends at its last tick.
//!
//! Time: the intro's own ticks, n, are display ticks but at its start (its set-up takes two
//! ticks, then the load) and at the flash of the city, one of whose ticks spans two display ticks
//! (quirk Q3: the city's flash waits for a frame in the middle of the tick). The script's
//! countdown runs on display ticks.
//!
//! START on pad 1 before PRESS START BUTTON is up stops the music and fades everything out, then
//! the title is set up with its pictures in place (title.zig); once it is up, START goes to the
//! game menu. The script's end starts the attract demo.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const art = @import("../content/art.zig");
const records = @import("../content/screens.zig");
const Setup = @import("../setup.zig").Setup;
const half = @import("half_colours.zig");
const HalfColours = half.HalfColours;
const title = @import("title.zig");
const transfers = @import("transfers.zig");

const lines = render.height;

/// The parts the script starts, by their names in the content's script.
pub const Part = enum(u8) {
    city_drift,
    city_fade_in,
    story_fade_out,
    city_lights,
    story_text,
    story_rise,
    profiles,
    pictures_out,
    city_again,
    city_rush,
    adam_arrives,
    blaze_arrives,
    hero,
    flash_adam,
    flash_blaze,
    flash_city,
    heroes_step,
    press_start,
    credit_sega,
    credit_music,
    credit_composer,
    title,
};

/// A running part's age (its ticks, 0 at its first) and the ticks it has left (its life; 0 for
/// one without).
const Run = struct {
    age: u16 = 0,
    left: u16 = 0,

    fn of(life: u16) Run {
        return .{ .left = life };
    }

    /// The part's tick: its age, or null when its life is out (it ends without running).
    fn next(r: *?Run) ?u16 {
        const x = &(r.* orelse return null);
        if (x.left != 0) {
            x.left -= 1;
            if (x.left == 0) {
                r.* = null;
                return null;
            }
        }
        defer x.age +|= 1;
        return x.age;
    }
};

/// A picture that slides, in 1/65536 pixel (the original's 16.16 places and speeds), until it
/// is past its stop. It does not move at its first tick.
const Slider = struct {
    x: i32,
    speed: i32,
    acceleration: i32,
    stop: i16,
    first: bool = true,
    stopped: bool = false,

    fn of(x: i16, speed: i16, acceleration: i32, stop: i16) Slider {
        return .{ .x = @as(i32, x) << 16, .speed = @as(i32, speed) << 16, .acceleration = acceleration, .stop = stop };
    }

    fn px(s: Slider) i16 {
        return @intCast(s.x >> 16);
    }

    /// One tick: past its stop (on the side its speed goes to), it stops there; else its speed
    /// changes and it moves.
    fn step(s: *Slider) void {
        if (s.first) {
            s.first = false;
            return;
        }
        if (s.stopped) return;
        const x = s.px();
        if ((s.speed > 0 and x > s.stop) or (s.speed < 0 and x < s.stop)) {
            s.x = @as(i32, s.stop) << 16;
            s.stopped = true;
            return;
        }
        s.speed += s.acceleration;
        s.x += s.speed;
    }
};

/// A pixel in the sliders' units, and how they slow down a tick: Adam from the right by 5/32 of
/// a pixel a tick, Blaze and the title's words from the left by 3/16.
const pixel: i32 = 65536;
const brakes_from_right = pixel * 5 / 32;
const brakes_from_left = pixel * 3 / 16;

/// A credit that moves in a few pixels a tick until its place. It does not move at its first
/// tick.
const Credit = struct {
    at: i16,
    first: bool = true,

    fn step(c: *Credit, to: i16, by: i16) void {
        if (c.first) {
            c.first = false;
            return;
        }
        if ((by > 0 and c.at < to) or (by < 0 and c.at > to)) c.at += by;
    }
};

/// The scroll of both planes: per screen line the board's pixel column at the screen's left, and
/// the board's pixel row at its top.
pub const Scroll = struct {
    a_left: [lines]i16 = @splat(0),
    b_left: [lines]i16 = @splat(0),
    a_top: i16 = 0,
    b_top: i16 = 0,

    /// Lines `first` to `last` move `by` pixels (left: their content moves right).
    fn add(left: *[lines]i16, first: usize, last: usize, by: i16) void {
        for (left[first..@min(last + 1, lines)]) |*l| l.* +%= by;
    }

    fn set(left: *[lines]i16, v: i16) void {
        @memset(left, v);
    }
};

/// What the boards hold: the story's (64 x 64 cells), the profiles' (128 x 32), the title's
/// (64 x 64).
pub const Boards = enum(u8) { story, profiles, title };

/// The profiles' text: after a wait of 40 ticks, a character a tick; a pause blinks the cursor
/// for 60 ticks; at the text's end the director is told, and the next profile waits for it.
const Typing = struct {
    profile: u8 = 0,
    /// The characters of its text typed.
    typed: u8 = 0,
    phase: enum(u8) { wait, ready, typing, paused, done } = .wait,
    count: u8 = 40,
    cursor: bool = false,
    /// The keys' sound: on the 1st, 5th, 9th... character typed, across the profiles.
    keys: u2 = 0,
};

/// The profiles' pictures: their places (null: not there).
const Pictures = struct {
    adam: ?[2]i16 = null,
    blaze: ?[2]i16 = null,
    axel: ?[2]i16 = null,
};

/// A palette line's flash: to white, then back down to its target.
const Flash = struct {
    run: Run,
    back: bool = false,
};

/// The profiles' director's phases: each band slides in, its border lit while its profile is
/// typed, then the band moves aside.
const Director = enum(u8) { adam_in, adam_typing, adam_up, blaze_wait, blaze_in, blaze_typing, blaze_down, axel_wait, axel_in, axel_typing };

const sprites_max = 12;
const Sprites = title.Sprites(sprites_max);

pub const Intro = struct {
    /// Display ticks since the scene began (0 at its first).
    ticks: u16 = 0,
    /// The intro's tick.
    n: u16 = 0,
    phase: Phase = .dark,
    /// The script's next entry, and its countdown in display ticks.
    entry: u8 = 0,
    countdown: u16 = 0,
    colours: HalfColours = .{},
    scroll: Scroll = .{},
    shown_scroll: Scroll = .{},
    boards: Boards = .story,
    sprites: Sprites = .{},
    shown_sprites: Sprites = .{},
    /// START's fade: its ticks so far.
    fading: u8 = 0,
    /// The city's flash took the frame in the middle of a tick: the rest of it is due.
    split: bool = false,

    // The story's parts.
    drift: ?Run = null,
    fade_in: ?Run = null,
    lights: ?Run = null,
    lights_step: u8 = 0,
    story: ?Run = null,
    /// The story's writes so far: its lines, each with a blank line under it, then blank lines.
    story_writes: u8 = 0,
    rise: ?Run = null,
    story_out: ?Run = null,
    bands: bool = false,
    city: bool = true,

    // The profiles.
    director: ?Director = null,
    director_count: u8 = 0,
    typing: ?Typing = null,
    /// The three profiles typed.
    all_typed: bool = false,
    /// A profile's end, which the director sees at its next tick.
    profile_end: bool = false,
    pictures: Pictures = .{},
    pictures_out: ?Run = null,

    // The city again, the hero, the flashes.
    city_again: ?Run = null,
    rush: ?Run = null,
    hero: ?Run = null,
    hero_drawn: bool = false,
    /// Its tiles copied to the picture at each frame while it forms.
    hero_copying: bool = false,
    passes: u8 = 0,
    shown_passes: u8 = 0,
    adam: ?Slider = null,
    blaze: ?Slider = null,
    flash_adam: ?Flash = null,
    flash_blaze: ?Flash = null,
    flash_city: ?Flash = null,
    step_right: ?Run = null,

    // The title.
    title_director: ?Run = null,
    streets: ?Slider = null,
    of: ?Slider = null,
    name_drawn: bool = false,
    title_flash: ?Run = null,
    music: ?Credit = null,
    composer: ?Credit = null,
    sega: ?Credit = null,
    trademark: enum(u8) { none, due, shown } = .none,
    title_steps: ?title.ColourSteps = null,
    press_start: ?title.Blink = null,
    press_start_first: bool = false,

    pub const Phase = enum(u8) { dark, running, fading };

    /// The set-up's ticks before the load: the screen goes dark, then the set-up.
    pub const setup_ticks = 2;

    pub const Assets = struct {
        data: *const records.Intro,
        script: library.Script(Part),
        italic: library.Text,
        profile_font: library.Text,
        story_frame: *const art.TileSheet,
        city_left: *const art.TileMap,
        city_right: *const art.TileMap,
        band_1: *const art.TileMap,
        band_2: *const art.TileMap,
        band_3: *const art.TileMap,
        band_4: *const art.TileMap,
        band_5: *const art.TileMap,
        band_6: *const art.TileMap,
        hero: *const art.TileMap,
        name_1: *const art.TileMap,
        name_2: *const art.TileMap,
        start: *const art.Palette,
        city: *const art.Palette,
        city_lights: *const art.Palette,
        lights: *const art.PaletteSteps,
        profile_colours: *const art.Palette,
        heroes_2: *const art.Palette,
        heroes_3: *const art.Palette,
        title_colours: *const art.Palette,
        name: *const art.Palette,
        flash: *const art.Palette,
        steps: *const art.PaletteSteps,
        pictures: [title.picture_count]*const art.Frame,
        music: library.Sound,
        stop: library.Sound,
        stab: library.Sound,
        landing: library.Sound,
        boomerang: library.Sound,
        title_flash: library.Sound,
        pub const names = .{
            .data = "screens/intro",
            .script = "screens/intro",
            .italic = "fonts/italic",
            .profile_font = "fonts/intro",
            .story_frame = "intro/story_frame",
            .city_left = "intro/city_left",
            .city_right = "intro/city_right",
            .band_1 = "intro/story_frame_1",
            .band_2 = "intro/story_frame_2",
            .band_3 = "intro/story_frame_3",
            .band_4 = "intro/story_frame_4",
            .band_5 = "intro/story_frame_5",
            .band_6 = "intro/story_frame_6",
            .hero = "title/hero",
            .name_1 = "title/name_1",
            .name_2 = "title/name_2",
            .start = "intro/start",
            .city = "intro/city",
            .city_lights = "intro/city_lights",
            .lights = "intro/lights",
            .profile_colours = "intro/profiles",
            .heroes_2 = "intro/story_colours_2",
            .heroes_3 = "intro/story_colours_3",
            .title_colours = "title/colours",
            .name = "title/name",
            .flash = "title/flash",
            .steps = "title/steps",
            .pictures = "intro/picture",
            .music = "title music",
            .stop = "stop",
            .stab = "stab",
            .landing = "landing",
            .boomerang = "boomerang",
            .title_flash = "title flash",
        };
    };

    pub fn layoutOf(self: *const Intro) view.Layout {
        return switch (self.boards) {
            .profiles => .{ .a = .{ .width = 128, .height = 32 }, .b = .{ .width = 128, .height = 32 } },
            else => .{ .a = .{ .width = 64, .height = 64 }, .b = .{ .width = 64, .height = 64 } },
        };
    }

    pub fn start(_: *const Setup) Intro {
        return .{};
    }

    // --- the tick ----------------------------------------------------------------------------

    pub fn tick(self: *Intro, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        defer self.ticks +|= 1;
        defer turn.frame = self.frame();
        self.colours.latch();
        self.shown_scroll = self.scroll;
        self.shown_sprites = self.sprites;
        self.shown_passes = self.passes;
        switch (self.phase) {
            .dark => {
                if (self.ticks == 0) {
                    // The screen dark, the state of a new game, the music.
                    turn.setup.first_round = 0;
                    if (turn.setup.high_scores) |*t| for (t) |*e| {
                        e.new = null;
                    };
                    turn.play(a.music);
                    return null;
                }
                // The set-up and the intro's first tick, the screen still dark.
                self.colours.show(a.start);
                self.phase = .running;
                if (self.scriptEnd(a)) return .done;
                self.run(turn, a);
                return null;
            },
            .fading => {
                self.fading += 1;
                if (self.fading == 1) self.sprites = .{};
                if (self.fading >= 2 and self.fading <= 16) self.colours.fadeAll();
                return if (self.fading == 17) .start else null;
            },
            .running => {},
        }
        if (self.countdown > 0) self.countdown -= 1;
        if (self.split) {
            // The second frame of the city's flash: the rest of its tick, then its pictures.
            self.split = false;
            self.runFrom(turn, a, .flash_city_back);
            self.listSprites();
            return null;
        }
        if (turn.pressed.pad1.start) {
            turn.play(a.stop);
            if (self.press_start != null) return .menu;
            self.phase = .fading;
            return null;
        }
        self.n += 1;
        if (self.scriptEnd(a)) return .done;
        self.run(turn, a);
        return null;
    }

    /// What this tick's picture transfers as the next frame starts: none after its first tick
    /// (its wait) or the first part of the city's flash; else the colours when touched, the line
    /// scroll, and Axel's picture's tiles while it forms.
    fn frame(self: *const Intro) ?transfers.Frame {
        if ((self.phase == .dark and self.ticks == 0) or self.split) return null;
        return .{ .colours = self.colours.copy, .line_scroll = true, .tile_words = if (self.hero_copying) title.hero_words else 0 };
    }

    /// The script's next entry when its countdown is out; true at its end.
    fn scriptEnd(self: *Intro, a: *const Assets) bool {
        if (self.countdown != 0) return false;
        if (self.entry >= a.script.len) return true;
        const e = a.script.entries[self.entry];
        self.entry += 1;
        self.countdown = e.wait;
        const r = Run.of(e.life);
        switch (e.part) {
            .city_drift => self.drift = r,
            .city_fade_in => self.fade_in = r,
            // Its life counts down to the clearing of the boards, not to its end.
            .story_fade_out => self.story_out = r,
            .city_lights => self.lights = r,
            .story_text => self.story = r,
            .story_rise => self.rise = r,
            // The parts that come below have no life of their own.
            .profiles => self.director = .adam_in,
            .pictures_out => self.pictures_out = r,
            .city_again => self.city_again = r,
            .city_rush => self.rush = r,
            .adam_arrives => self.adam = .of(320, -10, brakes_from_right, 120),
            .blaze_arrives => self.blaze = .of(0, 10, -brakes_from_left, 208),
            .hero => self.hero = .{},
            .flash_adam => self.flash_adam = .{ .run = r },
            .flash_blaze => self.flash_blaze = .{ .run = r },
            .flash_city => self.flash_city = .{ .run = r },
            .heroes_step => self.step_right = .{},
            .press_start => {
                self.press_start = .{};
                self.press_start_first = true;
            },
            .credit_sega => self.sega = .{ .at = 240 },
            .credit_music => self.music = .{ .at = 0 },
            .credit_composer => self.composer = .{ .at = 320 },
            // The title's starter makes its director, which runs this tick.
            .title => self.title_director = .{},
        }
        return false;
    }

    /// The parts' places in the order they run (the original's list of objects).
    const Place = enum { first, second, third, fourth, fifth, flash_city_back, sixth, seventh, eighth, adam, blaze };

    fn run(self: *Intro, turn: *scene.Turn, a: *const Assets) void {
        self.runFrom(turn, a, .first);
        if (!self.split) self.listSprites();
    }

    fn runFrom(self: *Intro, turn: *scene.Turn, a: *const Assets, from: Place) void {
        for (std.enums.values(Place)) |p| {
            if (@backingInt(p) < @backingInt(from)) continue;
            switch (p) {
                // The trademark, made by the title's director at its end, runs from the next.
                .first => if (self.trademark == .due) {
                    self.trademark = .shown;
                },
                .second => {
                    self.cityDrift();
                    self.profilesDirector(turn, a);
                    self.picturesOut(turn, a);
                    self.cityAgain(a);
                    self.heroForms();
                    self.flash(&self.flash_adam, 2, 4, a.heroes_2);
                    self.heroesStep();
                    if (self.of) |*s| s.step();
                },
                .third => {
                    self.cityLights(a);
                    self.storyOut();
                    self.cityRush();
                    if (self.streets) |*s| s.step();
                },
                .fourth => {
                    self.cityFadeIn(a);
                    self.typeProfile(turn, a);
                    self.flash(&self.flash_blaze, 3, 4, a.heroes_3);
                    self.titleDirector(a);
                    if (self.press_start) |*b| {
                        if (self.press_start_first) self.press_start_first = false else b.tick();
                    }
                },
                .fifth => {
                    self.storyText();
                    self.flashCity();
                    if (self.split) return;
                    self.titleFlash(turn, a);
                    if (self.title_steps) |*c| c.tick(&self.colours, a.steps);
                },
                // Only where the city's flash took the frame: the rest of its tick.
                .flash_city_back => if (from == .flash_city_back) self.flashCityBack(a),
                .sixth => {
                    self.storyRise();
                    if (self.music) |*c| c.step(128, 4);
                },
                .seventh => if (self.composer) |*c| c.step(200, -4),
                .eighth => if (self.sega) |*c| c.step(200, -2),
                .adam => if (self.adam) |*s| s.step(),
                .blaze => if (self.blaze) |*s| s.step(),
            }
        }
    }

    // --- the story ---------------------------------------------------------------------------

    /// The city drifts left a pixel every 4 ticks.
    fn cityDrift(self: *Intro) void {
        const t = Run.next(&self.drift) orelse return;
        if (t % 4 == 3) Scroll.add(&self.scroll.b_left, 0, lines - 1, 1);
    }

    /// The city's colours rise from black, a half-level every 6 ticks.
    fn cityFadeIn(self: *Intro, a: *const Assets) void {
        const t = Run.next(&self.fade_in) orelse return;
        if (t == 0) {
            self.colours.aim(a.city);
        } else if (t % 6 == 0) self.colours.step(.{ .line = 1 }, .rise);
    }

    /// The city's lights: after 96 ticks, every 16 the next of their steps (from the second,
    /// round to the first).
    fn cityLights(self: *Intro, a: *const Assets) void {
        // The lights ask for the colours' copy at every tick, the one they end at too.
        if (self.lights != null) self.colours.copy = true;
        const t = Run.next(&self.lights) orelse return;
        if (t < 96 or (t - 96) % 16 != 0) return;
        self.lights_step = (self.lights_step + 1) % @as(u8, @intCast(a.lights.steps.len));
        self.colours.showStep(a.lights, self.lights_step);
    }

    const story_column = 9;
    const story_first_row = 36;
    /// After the story, the blank lines go from this row on.
    const story_blank_row = 30;

    /// The story's lines: one every 64 ticks from its second tick, each with a blank line under
    /// it; then, after a pause of one, a blank line every 64 ticks (they erase the lines the
    /// plane brings round again).
    fn storyText(self: *Intro) void {
        const t = Run.next(&self.story) orelse return;
        if (t == 0 or (t - 1) % 64 != 0) return;
        if ((t - 1) / 64 != story_lines) self.story_writes += 1;
    }

    const story_lines = 28;

    /// The story scrolls up a pixel every 4 ticks.
    fn storyRise(self: *Intro) void {
        const t = Run.next(&self.rise) orelse return;
        if (t % 4 == 3) self.scroll.a_top +%= 1;
    }

    /// The story's end: the city sinks to black, a half-level every 2 ticks; at the end of its
    /// life palette 0 is cleared, the boards are cleared and made 128 cells wide with the line
    /// scroll back to 0; the profiles' bands are drawn at the tick after.
    fn storyOut(self: *Intro) void {
        const x = &(self.story_out orelse return);
        const t = x.age;
        x.age += 1;
        x.left -%= 1;
        if (x.left == 0) {
            for (0..half.size) |k| {
                self.colours.now[0][k] = .{ 0, 0, 0 };
                self.colours.target[0][k] = .{ 0, 0, 0 };
            }
            self.boards = .profiles;
            self.city = false;
            Scroll.set(&self.scroll.a_left, 0);
            Scroll.set(&self.scroll.b_left, 0);
            return;
        }
        if (self.boards == .profiles) {
            self.bands = true;
            self.story_out = null;
            return;
        }
        if (t >= 2 and t % 2 == 0) self.colours.step(.{ .line = 1 }, .sink);
    }

    // --- the profiles ------------------------------------------------------------------------

    /// The bands' borders: palette 0's colours 11 (Adam's), 13 (Blaze's), 12 (Axel's), lit while
    /// the band's text is typed.
    const borders = [3]u4{ 11, 13, 12 };
    const border_lit: half.Half = .{ 14, 12, 10 };
    const border_unlit: half.Half = .{ 6, 4, 4 };
    const picture_place: [2]i16 = .{ 72, 136 };

    fn border(self: *Intro, who: usize, lit: bool) void {
        self.colours.now[0][borders[who]] = if (lit) border_lit else border_unlit;
        self.colours.copy = true;
    }

    fn count(self: *Intro) bool {
        self.director_count -= 1;
        return self.director_count == 0;
    }

    fn startPhase(self: *Intro, phase: Director, ticks: u8) void {
        self.director = phase;
        self.director_count = ticks;
    }

    /// The profiles' director.
    fn profilesDirector(self: *Intro, turn: *scene.Turn, a: *const Assets) void {
        const d = self.director orelse return;
        const s = &self.scroll;
        switch (d) {
            .adam_in => {
                if (self.director_count == 0) {
                    // Its first tick: Adam's picture, the planes moved, the profiles' colours.
                    self.pictures.adam = picture_place;
                    s.a_top = -72;
                    s.b_top = -64;
                    Scroll.add(&s.a_left, 0, lines - 1, -320);
                    self.colours.show(a.profile_colours);
                    self.director_count = 21;
                    return;
                }
                if (self.count()) {
                    turn.play(a.stab);
                    self.typing = .{ .count = first_wait };
                    self.border(0, true);
                    self.director = .adam_typing;
                } else Scroll.add(&s.b_left, 0, 144, 16);
            },
            .adam_typing, .blaze_typing, .axel_typing => {
                if (!self.profile_end) return;
                self.profile_end = false;
                const who: usize = switch (d) {
                    .adam_typing => 0,
                    .blaze_typing => 1,
                    else => 2,
                };
                self.border(who, false);
                switch (d) {
                    .adam_typing => {
                        turn.play(a.landing);
                        self.startPhase(.adam_up, 10);
                    },
                    .blaze_typing => {
                        turn.play(a.landing);
                        self.startPhase(.blaze_down, 10);
                    },
                    else => {
                        self.goOn();
                        self.director = null;
                    },
                }
            },
            .adam_up => if (self.count()) {
                self.pictures.blaze = picture_place;
                Scroll.add(&s.b_left, 72, lines - 1, -320);
                Scroll.add(&s.a_left, 0, lines - 1, 320);
                self.startPhase(.blaze_wait, 40);
            } else {
                s.b_top +%= 8;
                self.pictures.adam.?[1] -= 8;
            },
            .blaze_wait => if (self.count()) self.startPhase(.blaze_in, 21),
            .blaze_in => if (self.count()) {
                turn.play(a.stab);
                self.goOn();
                self.border(1, true);
                self.director = .blaze_typing;
            } else Scroll.add(&s.a_left, 0, lines - 1, 16),
            .blaze_down => if (self.count()) {
                self.pictures.axel = picture_place;
                Scroll.add(&s.b_left, 72, lines - 1, 320);
                self.startPhase(.axel_wait, 40);
            } else {
                s.a_top -%= 8;
                self.pictures.blaze.?[1] += 8;
            },
            .axel_wait => if (self.count()) self.startPhase(.axel_in, 21),
            .axel_in => if (self.count()) {
                turn.play(a.stab);
                self.goOn();
                self.border(2, true);
                self.director = .axel_typing;
            } else Scroll.add(&s.b_left, 72, lines - 1, 16),
        }
    }

    /// The text's wait before it types: 40 ticks, the tick it starts at not counted.
    const first_wait = 41;

    /// The text goes on to the next profile (after the last, it ends).
    fn goOn(self: *Intro) void {
        const t = &(self.typing orelse return);
        if (t.phase != .done) return;
        t.profile += 1;
        if (t.profile >= 3) {
            self.typing = null;
            self.all_typed = true;
            return;
        }
        t.typed = 0;
        t.phase = .wait;
        t.count = first_wait;
    }

    /// The profile's text, a character a tick.
    fn typeProfile(self: *Intro, turn: *scene.Turn, a: *const Assets) void {
        const t = &(self.typing orelse return);
        switch (t.phase) {
            .wait => {
                t.count -= 1;
                if (t.count == 0) t.phase = .ready;
            },
            .ready => t.phase = .typing,
            .done => {},
            .typing, .paused => {},
        }
        if (t.phase == .paused) {
            t.count -= 1;
            if (t.count == 0) {
                t.cursor = false;
                t.phase = .ready;
            } else if (t.count & 15 == 8) t.cursor = !t.cursor;
            return;
        }
        if (t.phase != .typing) return;
        // A character typed (or the text's end): the keys' sound on every fourth.
        if (t.keys == 0) turn.play(a.landing);
        t.keys -%= 1;
        const text = a.data.profiles[t.profile].text;
        if (t.typed >= text.len) {
            t.phase = .done;
            self.profile_end = true;
            return;
        }
        const c = text[t.typed];
        t.typed += 1;
        if (c == '|') {
            t.phase = .paused;
            t.count = 60;
            t.cursor = false;
        }
    }

    // --- the city again, the hero, the flashes -------------------------------------------------

    /// The pictures slide out with their bands; then every colour goes black.
    fn picturesOut(self: *Intro, turn: *scene.Turn, a: *const Assets) void {
        const x = &(self.pictures_out orelse return);
        const t = x.age;
        x.age += 1;
        if (t == 0) {
            turn.play(a.boomerang);
            return;
        }
        if (t == 40) {
            self.pictures = .{};
            self.colours.clear();
            self.pictures_out = null;
            return;
        }
        const s = &self.scroll;
        if (self.pictures.adam) |*p| p[0] -= 8;
        if (self.pictures.axel) |*p| p[0] += 8;
        if (self.pictures.blaze) |*p| p[0] -= 8;
        Scroll.add(&s.b_left, 0, 72, 8);
        Scroll.add(&s.b_left, 72, lines - 1, -8);
        Scroll.add(&s.a_left, 0, lines - 1, 8);
    }

    /// The city again: the boards and colours cleared, then 64 x 64 cells, the city, the scroll
    /// back to 0, its colours rising every 4 ticks.
    fn cityAgain(self: *Intro, a: *const Assets) void {
        const t = Run.next(&self.city_again) orelse return;
        if (t == 0) {
            self.boards = .title;
            self.bands = false;
            self.city = false;
            self.colours.clear();
        } else if (t == 1) {
            self.city = true;
            const s = &self.scroll;
            s.a_top = 0;
            s.b_top = 0;
            Scroll.set(&s.a_left, 0);
            Scroll.set(&s.b_left, 0);
            self.colours.aim(a.city);
            self.colours.aim(a.city_lights);
        } else if ((t - 1) % 4 == 0) self.colours.step(.{ .line = 1 }, .rise);
    }

    /// The city rushes left 8 pixels a tick.
    fn cityRush(self: *Intro) void {
        _ = Run.next(&self.rush) orelse return;
        Scroll.add(&self.scroll.b_left, 0, lines - 1, 8);
    }

    /// Axel's picture forms: plane A moved, the picture drawn transparent, then every 6 ticks a
    /// pass reveals a byte in 17 of its tiles; 160 ticks.
    fn heroForms(self: *Intro) void {
        const t = Run.next(&self.hero) orelse return;
        if (t == 0) {
            Scroll.add(&self.scroll.a_left, 0, lines - 1, 160);
        } else if (t == 1) {
            self.hero_drawn = true;
        } else if (t == 2) {
            self.hero_copying = true;
        } else if (t == 2 + 160) {
            self.hero = null;
            self.hero_copying = false;
        } else if ((t - 2) % 6 == 0) self.passes += 1;
    }

    /// A palette line's flash: towards white every `period` ticks until its 64th tick, then back
    /// down to `back`'s colours.
    fn flash(self: *Intro, f: *?Flash, line: u2, comptime period: u16, back: *const art.Palette) void {
        const x = &(f.* orelse return);
        x.run.left -= 1;
        if (x.run.left == 0) {
            f.* = null;
            return;
        }
        const t = x.run.age;
        x.run.age += 1;
        if (t == 0) return;
        if (!x.back) {
            if (t == 64) {
                self.colours.aim(back);
                x.back = true;
            } else if (t % period == 0) self.colours.step(.{ .line = line }, .whiten);
        } else if ((t - 64) % period == 0) self.colours.step(.{ .line = line }, .unwhiten);
    }

    /// The city's flash: as the others, every 2 ticks; at its 64th tick the city's scroll comes
    /// back to 0 and the tick waits for the next frame (quirk Q3), where it aims at the city's
    /// colours.
    fn flashCity(self: *Intro) void {
        const x = &(self.flash_city orelse return);
        x.run.left -= 1;
        if (x.run.left == 0) {
            self.flash_city = null;
            return;
        }
        const t = x.run.age;
        x.run.age += 1;
        if (t == 0) return;
        if (!x.back) {
            if (t == 64) {
                Scroll.set(&self.scroll.b_left, 0);
                self.split = true;
            } else if (t % 2 == 0) self.colours.step(.{ .line = 1 }, .whiten);
        } else if ((t - 64) % 2 == 0) self.colours.step(.{ .line = 1 }, .unwhiten);
    }

    fn flashCityBack(self: *Intro, a: *const Assets) void {
        const x = &(self.flash_city orelse return);
        if (x.back) return;
        self.colours.aim(a.city);
        self.colours.aim(a.city_lights);
        x.back = true;
    }

    /// Adam and Blaze step right with plane A, 10 pixels a tick for 4 ticks.
    fn heroesStep(self: *Intro) void {
        const x = &(self.step_right orelse return);
        if (x.age == 4) {
            self.step_right = null;
            return;
        }
        x.age += 1;
        if (self.adam) |*s| s.x += 10 << 16;
        if (self.blaze) |*s| s.x += 10 << 16;
        Scroll.add(&self.scroll.a_left, 0, lines - 1, -10);
    }

    // --- the title -----------------------------------------------------------------------------

    /// The title's director: its colours and STREETS; 20 ticks later OF; 40 later RAGE, fading in
    /// every 2 ticks; 40 later the title's flash; 100 later the colour steps and the trademark.
    fn titleDirector(self: *Intro, a: *const Assets) void {
        const x = &(self.title_director orelse return);
        const t = x.age;
        x.age += 1;
        switch (t) {
            0 => {
                self.colours.show(a.title_colours);
                self.scroll.a_top = 0;
                self.scroll.b_top = 0;
                // Before the director in the list: it runs from the next tick.
                self.streets = .of(0, 10, -brakes_from_left, 88);
            },
            20 => self.of = .of(0, 10, -brakes_from_left, 88),
            60 => {
                self.name_drawn = true;
                self.colours.aim(a.name);
            },
            100 => self.title_flash = .{},
            200 => {
                self.title_steps = .{};
                self.trademark = .due;
                self.title_director = null;
            },
            else => if (t > 60 and t < 100 and t % 2 == 0) self.colours.step(.{ .line = 0, .first = 5 }, .rise),
        }
    }

    /// The title's flash: palette 0's colour 15 to white a step a tick for 15 ticks, then down
    /// to `title/flash`'s every 4 ticks; 80 ticks.
    fn titleFlash(self: *Intro, turn: *scene.Turn, a: *const Assets) void {
        const x = &(self.title_flash orelse return);
        const t = x.age;
        x.age += 1;
        const r: HalfColours.Range = .{ .line = 0, .first = 15, .last = 15 };
        if (t == 0) {
            turn.play(a.title_flash);
        } else if (t <= 15) {
            self.colours.step(r, .whiten);
        } else if (t == 16) {
            self.colours.aim(a.flash);
        } else if (t == 80) {
            self.title_flash = null;
        } else if ((t - 16) % 4 == 0) self.colours.step(r, .unwhiten);
    }

    /// The pictures of this tick, front to back.
    fn listSprites(self: *Intro) void {
        var l: Sprites = .{};
        if (self.trademark == .shown) l.add(.{ .picture = .trademark, .x = 180, .y = 10, .palette = 0, .priority = true });
        // A picture shows from its first tick (one made by a part after it in the list runs, and
        // shows, from the next).
        if (self.of) |s| if (!s.first) l.add(.{ .picture = .of, .x = s.px(), .y = 40 });
        if (self.pictures.adam) |p| l.add(.{ .picture = .adam_profile, .x = p[0], .y = p[1], .palette = 2 });
        if (self.streets) |s| if (!s.first) l.add(.{ .picture = .streets, .x = s.px(), .y = 24 });
        if (self.press_start) |b| if (b.shown) l.add(.{ .picture = .press_start, .x = 160, .y = 176, .palette = 2, .priority = true });
        if (self.pictures.blaze) |p| l.add(.{ .picture = .blaze_profile, .x = p[0], .y = p[1], .palette = 3 });
        if (self.pictures.axel) |p| l.add(.{ .picture = .axel_profile, .x = p[0], .y = p[1], .palette = 1 });
        if (self.music) |c| if (!c.first) l.add(.{ .picture = .music, .x = c.at, .y = 216, .palette = 2, .priority = true });
        if (self.composer) |c| if (!c.first) l.add(.{ .picture = .composer, .x = c.at, .y = 216, .palette = 2, .priority = true });
        if (self.sega) |c| if (!c.first) l.add(.{ .picture = .sega, .x = 160, .y = c.at, .palette = 2, .priority = true });
        if (self.adam) |s| if (!s.first) l.add(.{ .picture = .adam, .x = s.px(), .y = 144, .palette = 2 });
        if (self.blaze) |s| if (!s.first) l.add(.{ .picture = .blaze, .x = s.px(), .y = 144, .palette = 3 });
        self.sprites = l;
    }

    // --- the picture -----------------------------------------------------------------------------

    pub fn draw(self: *const Intro, prev: ?*const Intro, v: *view.View, a: *const Assets) !void {
        // A new picture, or new boards: everything of the boards drawn again.
        const was: ?*const Intro = if (prev) |p| if (p.boards == self.boards) p else null else null;
        if (prev != null and was == null) try v.begin(v.shows.?, self.layoutOf());
        const before: Intro = if (was) |p| p.* else .{ .boards = self.boards, .city = false, .story_writes = 0 };
        switch (self.boards) {
            .story => {
                if (self.city and !before.city) try self.drawCity(v, a);
                var w = before.story_writes;
                while (w < self.story_writes) : (w += 1) try storyWrite(w, v, a);
            },
            .profiles => {
                if (self.bands and !before.bands) for ([_]*const art.TileMap{ a.band_1, a.band_2, a.band_3, a.band_4, a.band_5, a.band_6 }) |m| {
                    try v.board(planeOf(m)).drawMapAtPlace(m);
                };
                try self.drawProfiles(if (was) |p| p else null, v, a);
            },
            .title => {
                if (self.city and !before.city) try self.drawCity(v, a);
                if (self.hero_drawn and (!before.hero_drawn or before.shown_passes != self.shown_passes)) try self.drawHero(v, a);
                if (self.name_drawn and !before.name_drawn) {
                    try v.board(.a).drawMapAtPlace(a.name_2);
                    try v.board(.a).drawMapAtPlace(a.name_1);
                }
            },
        }
        const s = &self.shown_scroll;
        v.lineScroll(.a, &s.a_left);
        v.lineScroll(.b, &s.b_left);
        v.screen.plane_a.y = s.a_top;
        v.screen.plane_b.y = s.b_top;
        v.screen.colours = self.colours.shown;
        try self.shown_sprites.draw(v, &a.pictures);
    }

    fn planeOf(m: *const art.TileMap) view.Plane {
        return if (m.place) |p| (if (p.layer == .plane_b) .b else .a) else .a;
    }

    fn drawCity(_: *const Intro, v: *view.View, a: *const Assets) !void {
        try v.board(.b).drawMapAtPlace(a.city_right);
        try v.board(.b).drawMapAtPlace(a.city_left);
    }

    /// The story's write `w`: a line and the blank line under it, or (after the lines) a blank
    /// line.
    fn storyWrite(w: u8, v: *view.View, a: *const Assets) !void {
        const blank: [22]u8 = @splat(' ');
        const story = a.data.story;
        if (w < story_lines and w < story.len) {
            const row: i32 = @intCast((story_first_row + 2 * @as(u32, w)) % 64);
            try v.write(.a, a.italic, story_column, row, story[w], .{});
            try v.write(.a, a.italic, story_column, @mod(row + 2, 64), &blank, .{});
        } else {
            const j: u32 = w - story_lines;
            try v.write(.a, a.italic, story_column, @intCast((story_blank_row + 2 * j) % 64), &blank, .{});
        }
    }

    /// The profiles' texts, from where `prev` had them typed.
    fn drawProfiles(self: *const Intro, prev: ?*const Intro, v: *view.View, a: *const Assets) !void {
        const now = self.typedOf();
        const then = if (prev) |p| p.typedOf() else Typed{};
        for (a.data.profiles, 0..) |p, i| {
            const upto: usize = if (i < now.profile) p.text.len else if (i == now.profile) now.typed else 0;
            const from: usize = if (i < then.profile) p.text.len else if (i == then.profile) then.typed else 0;
            if (upto <= from and !(i == now.profile and now.cursor != then.cursor)) continue;
            const plane: view.Plane = if (p.plane == .plane_b) .b else .a;
            var x: i32 = p.x;
            var y: i32 = p.y;
            for (p.text[0..upto], 0..) |c, k| {
                switch (c) {
                    '/' => {
                        y += 1;
                        x = p.x;
                        continue;
                    },
                    '|' => continue,
                    else => {},
                }
                if (k >= from) {
                    if (c == '_') {
                        try v.board(plane).put(x, y, &a.story_frame.tiles[0], .{});
                    } else {
                        const g = a.profile_font.font.glyphAt(&.{c}) orelse return error.NoGlyph;
                        try v.board(plane).put(x, y, &a.profile_font.sheet.tiles[g.tile], .{});
                    }
                }
                x += 1;
            }
            // The pause's cursor, where the next character goes.
            if (i == now.profile and (now.cursor != then.cursor or upto > from) and now.paused) {
                const tile = if (now.cursor) &a.profile_font.sheet.tiles[cursor_tile] else &a.story_frame.tiles[0];
                try v.board(plane).put(x, y, tile, .{});
            }
        }
    }

    /// The profiles' font's tile of the typing cursor.
    const cursor_tile = 28;

    const Typed = struct { profile: usize = 0, typed: usize = 0, cursor: bool = false, paused: bool = false };

    fn typedOf(self: *const Intro) Typed {
        if (self.typing) |x| return .{ .profile = x.profile, .typed = x.typed, .cursor = x.cursor, .paused = x.phase == .paused or x.phase == .ready };
        // Before the first profile, none; after the last, all three.
        return if (self.all_typed) .{ .profile = 3 } else .{};
    }

    /// Axel's picture, its bytes revealed by the passes shown.
    fn drawHero(self: *const Intro, v: *view.View, a: *const Assets) !void {
        const m = a.hero;
        const tiles = try v.tileBlock(m.tiles.len);
        const total = m.tiles.len * 32;
        @memset(tiles, @splat(0));
        // The passes: from byte `s`, every 17th; the next from where the last stopped, past the
        // data's end.
        var s: usize = 0;
        for (0..self.shown_passes) |_| {
            var b = s;
            while (b <= total) : (b += 17) {
                if (b == total) continue;
                const t = b / 32;
                const at = (b % 32) / 4 * 8 + (b % 4) * 2;
                tiles[t][at] = m.tiles[t][at];
                tiles[t][at + 1] = m.tiles[t][at + 1];
            }
            s = b - total;
        }
        var copy = m.*;
        copy.tiles = tiles;
        try v.board(.a).drawMapAtPlace(&copy);
    }
};

const testing = std.testing;

test "Adam and Blaze slide in, slowing, past their stop for a tick" {
    var adam: Slider = .of(320, -10, brakes_from_right, 120);
    var xs: [29]i16 = undefined;
    for (&xs) |*x| {
        adam.step();
        x.* = adam.px();
    }
    // Its first tick does not move it; then 310, 300, 290...; 114 for a tick, then 120.
    try testing.expectEqualSlices(i16, &.{ 320, 310, 300, 290, 281, 272, 263, 254, 245, 237, 228, 220, 212, 204, 196, 188, 181, 173, 166, 159, 152, 146, 139, 133, 126, 120, 114, 120, 120 }, &xs);
    var blaze: Slider = .of(0, 10, -brakes_from_left, 208);
    var last: i16 = 0;
    var past = false;
    for (0..40) |_| {
        blaze.step();
        past = past or blaze.px() > 208;
        last = blaze.px();
    }
    try testing.expect(past and last == 208);
}

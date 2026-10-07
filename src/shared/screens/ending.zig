//! The ending after round 8, when no player kept Mr. X's offer: its script (`screens/ending`)
//! starts its parts at their ticks; each part runs in its place among the parts, a place the
//! first free one as it starts, in their places' order, as the original's objects do (a part
//! started by another in a later place runs at once, in an earlier one from the next tick).
//! A part the script gives a life ends at its last tick. The parts:
//! - texts: the staff's texts typed a code every few ticks in the italic font, each kept a
//!   while and erased so, then the next; the last waits for the sun to set. The font shows only
//!   as the dissolves let it: a dissolve in brings its pixels in, a pass every few ticks (every
//!   61st of them from where the last pass stopped), a dissolve out takes them out so;
//! - pictures: the pictures drawn one after the other, their palette lines faded in and out
//!   (fades: a line a half-level a step towards its colours or black), the last with the
//!   scene's planes;
//! - the clouds crossing from the right, back at the right at a random height; the sun setting,
//!   which lets the last text be typed and the scene go on; the car's lines scrolling left;
//! - the scene: its palettes and its sky's colours in steps, the clouds sent off, the star's
//!   blink; THE END, its colour glowing in.
//! The script's end, or START once its last entry is near, leaves for the high scores.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const art = @import("../content/art.zig");
const records = @import("../content/screens.zig");
const setup_mod = @import("../setup.zig");
const transfers = @import("transfers.zig");
const HalfColours = @import("half_colours.zig").HalfColours;
const Setup = setup_mod.Setup;

/// The parts' places.
const places = 16;
const font_lag = 3;
const colour_lag = 2;
const scroll_lag = 3;
/// The font's tiles the dissolves show.
const font_tiles = 49;

const Part = union(enum) {
    texts: Texts,
    pictures: Pictures,
    dissolve: Dissolve,
    cloud: Cloud,
    sun: Sun,
    scene: Scene,
    glow: Glow,
    scroll: Scroll,
    fade: Fade,
};

const Slot = struct {
    part: Part,
    /// Its ticks left (none: it ends by itself).
    life: ?u16 = null,
    first: bool = true,
};

const TextState = enum { typing, kept, erasing, gap, waiting, last };

const Texts = struct {
    state: TextState = .typing,
    index: u8 = 0,
    /// The codes typed (or erased) of the text.
    codes: u16 = 0,
    count: u16 = 0,
    /// The sun began to set: the last text may come.
    sun: bool = false,
};

const Pictures = struct {
    moment: u8 = 0,
    count: u16 = 0,
};

const Dissolve = struct {
    in: bool,
    count: u8 = 0,
};

const Cloud = struct {
    which: u1,
    /// Across, in 1/65536 of a pixel; down, a pixel.
    x: i32,
    y: i16,
    off: bool = false,
};

const Sun = struct { y: i32 };

const Scene = struct {
    step: u8 = 0,
    sky: u8 = 0,
    count: u16 = 0,
    sun_set: bool = false,
    blink: u8 = 0,
    blinking: bool = false,
};

const Glow = struct { count: u8 = 0 };

const Scroll = struct { count: u16 = 0 };

const FontShown = struct { in: bool = false, passes: u16 = 0 };

const Fade = struct {
    line: u2,
    rise: bool,
    count: u8 = 0,
};

/// What the picture shows of the texts: each text's cells typed or erased, by text.
const Typed = struct {
    index: u8 = 0,
    codes: u16 = 0,
    erasing: bool = false,
    /// The texts erased whole (before `index`), and the last typed whole.
    done: u8 = 0,
};

pub const Ending = struct {
    ticks: u16 = 0,
    entry: u8 = 0,
    countdown: u16 = 0,
    slots: [places]?Slot = @splat(null),
    colours: HalfColours = .{},
    /// The font's dissolve: in or out, and the passes so far (the last's when none runs).
    font_in: bool = false,
    font_passes: u16 = 0,
    shown_font: FontShown = .{},
    font_before: [font_lag]FontShown = @splat(.{}),
    /// The pictures drawn, the texts' cells, the star's look, the car's scroll, the sprites.
    pictures: u8 = 0,
    shown_pictures: u8 = 0,
    typed: Typed = .{},
    typed_before: Typed = .{},
    shown_typed: Typed = .{},
    colours_before: [colour_lag]render.palettes.Colours = @splat(render.palettes.black),
    colours_held: render.palettes.Colours = render.palettes.black,
    star: ?u8 = null,
    shown_star: ?u8 = null,
    scrolled: u16 = 0,
    shown_scrolled: u16 = 0,
    sprites: Sprites = .{},
    shown_sprites: Sprites = .{},
    star_before: ?u8 = null,
    scrolled_before: [scroll_lag]u16 = @splat(0),
    sprites_before: Sprites = .{},
    /// The scene's palettes shown so far.
    scene_palettes: u8 = 0,

    pub const Assets = struct {
        data: *const records.Ending,
        text: *const art.Palette,
        italic: library.Text,
        art: *const art.Art,
        music: library.Sound,
        pub const names = .{
            .data = "screens/ending",
            .text = "ending/text",
            .italic = "fonts/italic",
            .art = "art",
            .music = "good ending music",
        };
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 64 }, .b = .{ .width = 64, .height = 64 } };

    pub fn start(_: *const Setup) Ending {
        return .{};
    }

    // --- the tick ----------------------------------------------------------------------------

    pub fn tick(self: *Ending, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        defer self.ticks +|= 1;
        defer turn.frame = .{ .colours = self.colours.copy, .line_scroll = true, .tiles = .one(font_tiles * 16) };
        // What the tick before left goes to the picture as the next frame starts, a frame later
        // than play's (the original's ending transfers it at the interrupt after its tick): the
        // colours, the cells typed, the font's tiles, the star.
        // Colours set without being copied (the sky's) show once a later change is.
        const copied = self.colours.copy;
        self.colours.latch();
        const colours = if (copied) self.colours.shown else self.colours_held;
        self.colours_held = colours;
        self.colours.shown = self.colours_before[colour_lag - 1];
        var c: usize = colour_lag - 1;
        while (c > 0) : (c -= 1) self.colours_before[c] = self.colours_before[c - 1];
        self.colours_before[0] = colours;
        // The font's tiles go to the picture a tick later still (copied as the next frame
        // starts, from what the tick before left).
        self.shown_font = self.font_before[font_lag - 1];
        var f: usize = font_lag - 1;
        while (f > 0) : (f -= 1) self.font_before[f] = self.font_before[f - 1];
        self.font_before[0] = .{ .in = self.font_in, .passes = self.font_passes };
        self.shown_pictures = self.pictures;
        self.shown_typed = self.typed_before;
        self.typed_before = self.typed;
        self.shown_star = self.star_before;
        self.star_before = self.star;
        self.shown_scrolled = self.scrolled_before[scroll_lag - 1];
        var sl: usize = scroll_lag - 1;
        while (sl > 0) : (sl -= 1) self.scrolled_before[sl] = self.scrolled_before[sl - 1];
        self.scrolled_before[0] = self.scrolled;
        self.shown_sprites = self.sprites_before;
        self.sprites_before = self.sprites;
        const d = a.data;
        if (self.ticks == 0) turn.play(a.music);
        if (self.ticks != 0) {
            // START near the script's end ends it.
            if (self.entry >= d.numbers.skip_from and self.countdown <= d.numbers.skip_within and turn.pressed.pad1.start) return .start;
        }
        if (self.countdown > 0) self.countdown -= 1;
        if (self.countdown == 0) {
            if (self.entry >= d.script.len) return .done;
            const e = d.script[self.entry];
            self.entry += 1;
            self.countdown = e.wait;
            self.begin(e.part, e.life, turn, a);
        }
        var k: usize = 0;
        while (k < places) : (k += 1) self.runSlot(k, turn, a);
        self.listSprites(a);
        return null;
    }

    /// A part begins in the first free place.
    fn begin(self: *Ending, name: []const u8, life: u16, turn: *scene.Turn, a: *const Assets) void {
        _ = turn;
        const d = a.data;
        const part: Part = if (std.mem.eql(u8, name, "texts")) .{ .texts = .{} } else if (std.mem.eql(u8, name, "pictures")) .{ .pictures = .{} } else if (std.mem.eql(u8, name, "dissolve_in")) .{ .dissolve = .{ .in = true } } else if (std.mem.eql(u8, name, "dissolve_out")) .{ .dissolve = .{ .in = false } } else if (std.mem.eql(u8, name, "cloud_1")) .{ .cloud = cloudOf(d, 0) } else if (std.mem.eql(u8, name, "cloud_2")) .{ .cloud = cloudOf(d, 1) } else if (std.mem.eql(u8, name, "sun")) .{ .sun = .{ .y = @as(i32, d.sun.y) << 16 } } else if (std.mem.eql(u8, name, "scene")) .{ .scene = .{} } else if (std.mem.eql(u8, name, "glow")) .{ .glow = .{} } else if (std.mem.eql(u8, name, "scroll")) .{ .scroll = .{} } else return;
        const lived = switch (part) {
            .texts, .pictures, .scene => false,
            else => true,
        };
        self.place(.{ .part = part, .life = if (lived) life else null });
    }

    fn cloudOf(d: *const records.Ending, which: u1) Cloud {
        const c = d.clouds[which];
        return .{ .which = which, .x = @as(i32, c.x) << 16, .y = c.y };
    }

    fn place(self: *Ending, s: Slot) void {
        for (&self.slots) |*o| if (o.* == null) {
            o.* = s;
            return;
        };
    }

    fn runSlot(self: *Ending, k: usize, turn: *scene.Turn, a: *const Assets) void {
        const slot = &(self.slots[k] orelse return);
        if (slot.life) |*l| {
            l.* -%= 1;
            if (l.* == 0) {
                self.slots[k] = null;
                return;
            }
        }
        const first = slot.first;
        slot.first = false;
        const d = a.data;
        const n = &d.numbers;
        switch (slot.part) {
            .texts => |*t| if (!self.texts(t, first, a)) {
                self.slots[k] = null;
            },
            .pictures => |*p| if (!self.picturesTick(p, first, a)) {
                self.slots[k] = null;
            },
            .dissolve => |*x| {
                if (first) {
                    x.count = n.dissolve_period;
                    self.font_in = x.in;
                    self.font_passes = 0;
                    return;
                }
                x.count -%= 1;
                if (x.count != 0) return;
                x.count = n.dissolve_period;
                self.font_passes +|= 1;
            },
            .cloud => |*c| {
                if (c.off) {
                    self.slots[k] = null;
                    return;
                }
                if (first) return;
                if ((c.x >> 16) > n.cloud_turn) {
                    c.x += d.clouds[c.which].speed;
                    return;
                }
                // Back at the right, its fraction of a pixel kept.
                c.x = @as(i32, n.cloud_back) << 16 | @as(i32, @as(u16, @truncate(@as(u32, @bitCast(c.x)))));
                c.y = n.cloud_height + @as(i16, @intCast(turn.random.?.next() & n.cloud_spread));
            },
            .sun => |*s| {
                if (first) {
                    for (&self.slots) |*o| if (o.*) |*x| switch (x.part) {
                        .texts => |*t| t.sun = true,
                        else => {},
                    };
                    return;
                }
                if ((s.y >> 16) <= d.numbers.sun_until) {
                    s.y += d.sun.speed;
                    return;
                }
                for (&self.slots) |*o| if (o.*) |*x| switch (x.part) {
                    .scene => |*sc| sc.sun_set = true,
                    else => {},
                };
                self.slots[k] = null;
            },
            .scene => |*sc| self.sceneTick(sc, first, a),
            .glow => |*g| {
                if (first) {
                    g.count = n.glow_period;
                    if (a.art.palette(n.glow_colours)) |p| self.colours.aim(p);
                    return;
                }
                g.count -%= 1;
                if (g.count != 0) return;
                g.count = n.glow_period;
                self.colours.step(.{ .line = @intCast(n.glow_line), .first = @intCast(n.glow_colour), .last = @intCast(n.glow_colour) }, .rise);
            },
            .scroll => |*s| {
                if (first) s.count = n.scroll_ticks;
                s.count -%= 1;
                if (s.count == 0) {
                    self.slots[k] = null;
                    return;
                }
                self.scrolled += 1;
            },
            .fade => |*f| {
                if (first) {
                    f.count = n.fade_period;
                    return;
                }
                f.count -%= 1;
                if (f.count != 0) return;
                f.count = n.fade_period;
                self.colours.step(.{ .line = f.line }, if (f.rise) .rise else .sink);
            },
        }
    }

    /// The texts' tick: whether they go on.
    fn texts(self: *Ending, t: *Texts, first: bool, a: *const Assets) bool {
        const d = a.data;
        const n = &d.numbers;
        if (first) {
            self.colours.show(a.text);
            t.state = .typing;
            t.count = n.type_period;
            t.codes = 0;
            self.typed = .{ .index = t.index, .codes = 0, .done = self.typed.done };
            return true;
        }
        switch (t.state) {
            .typing, .last => {
                t.count -%= 1;
                if (t.count != 0) return true;
                t.count = n.type_period;
                t.codes += 1;
                self.typed.codes = t.codes;
                if (t.codes < codesOf(&d.texts[t.index])) return true;
                if (t.state == .last) return false;
                t.state = .kept;
                t.count = d.texts[t.index].stays;
            },
            .kept => {
                t.count -%= 1;
                if (t.count != 0) return true;
                t.state = .erasing;
                t.count = n.type_period;
                t.codes = 0;
                self.typed.erasing = true;
                self.typed.codes = 0;
            },
            .erasing => {
                t.count -%= 1;
                if (t.count != 0) return true;
                t.count = n.type_period;
                t.codes += 1;
                self.typed.codes = t.codes;
                if (t.codes < codesOf(&d.texts[t.index])) return true;
                t.index += 1;
                self.typed = .{ .index = t.index, .codes = 0, .done = t.index };
                if (t.index + 1 >= d.texts.len) {
                    t.state = .waiting;
                    return true;
                }
                t.state = .gap;
                t.count = n.erase_gap;
            },
            .gap => {
                t.count -%= 1;
                if (t.count != 0) return true;
                t.state = .typing;
                t.count = n.type_period;
                t.codes = 0;
            },
            .waiting => if (t.sun) {
                t.state = .last;
                t.count = n.type_period;
                t.codes = 0;
            },
        }
        return true;
    }

    /// The pictures' tick: whether they go on.
    fn picturesTick(self: *Ending, p: *Pictures, first: bool, a: *const Assets) bool {
        const d = a.data;
        if (!first) {
            p.count -%= 1;
            if (p.moment + 1 == d.moments.len and p.count == d.numbers.black_before) {
                self.colours.now[d.numbers.black_line] = @splat(.{ 0, 0, 0 });
                self.colours.copy = true;
            }
            if (p.count != 0) return true;
        }
        const m = d.moments[p.moment];
        self.pictures += m.pictures;
        for (m.fade_in) |f| {
            if (a.art.palette(f.colours)) |pal| self.colours.aim(pal);
            self.place(.{ .part = .{ .fade = .{ .line = @intCast(f.line), .rise = true } }, .life = d.numbers.fade_life });
        }
        for (m.fade_out) |line| self.place(.{ .part = .{ .fade = .{ .line = @intCast(line), .rise = false } }, .life = d.numbers.fade_life });
        p.count = m.after;
        p.moment += 1;
        return p.moment < d.moments.len;
    }

    fn sceneTick(self: *Ending, sc: *Scene, first: bool, a: *const Assets) void {
        const d = a.data;
        if (sc.blinking) {
            sc.count -%= 1;
            if (sc.count == 0) self.blink(sc, d);
            return;
        }
        if (!first) {
            const step = d.scene[sc.step - 1];
            if (step.until_sun) {
                if (!sc.sun_set) return;
            } else {
                sc.count -%= 1;
                if (sc.count != 0) return;
            }
        }
        const step = d.scene[sc.step];
        sc.step += 1;
        sc.count = step.after;
        if (step.palette) {
            const k = self.scene_palettes;
            self.scene_palettes += 1;
            if (k < d.scene_colours.len) if (a.art.palette(d.scene_colours[k])) |p| self.colours.show(p);
        }
        // The sky's colours are set, not copied to the picture: they show with the next change
        // that is.
        if (step.sky) {
            const copy = self.colours.copy;
            if (a.art.steps(d.sky)) |s| self.colours.showStep(s, @min(sc.sky, s.steps.len - 1));
            self.colours.copy = copy;
            sc.sky += 1;
        }
        if (step.clouds_off) for (&self.slots) |*o| if (o.*) |*x| switch (x.part) {
            .cloud => |*c| c.off = true,
            else => {},
        };
        if (step.star) {
            sc.blinking = true;
            sc.blink = 0;
            self.blink(sc, d);
        }
    }

    fn blink(self: *Ending, sc: *Scene, d: *const records.Ending) void {
        const k = sc.blink;
        sc.blink = if (k + 1 < d.star.len) k + 1 else 0;
        sc.count = d.star[k].ticks;
        self.star = k;
    }

    fn listSprites(self: *Ending, a: *const Assets) void {
        const d = a.data;
        var l: Sprites = .{};
        for (self.slots) |o| if (o) |x| switch (x.part) {
            .cloud => |c| l.add(.{ .sprite = c.which, .x = @intCast(c.x >> 16), .y = c.y }),
            .sun => |s| l.add(.{ .sprite = 2, .x = d.sun.x, .y = @intCast(s.y >> 16) }),
            .glow => l.add(.{ .sprite = 3, .x = d.glow.x, .y = d.glow.y }),
            else => {},
        };
        self.sprites = l;
    }

    // --- the picture -----------------------------------------------------------------------------

    pub fn draw(self: *const Ending, prev: ?*const Ending, v: *view.View, a: *const Assets) !void {
        const d = a.data;
        const was: Ending = if (prev) |p| p.* else .{};
        // The pictures drawn since.
        var k = was.shown_pictures;
        while (k < self.shown_pictures and k < d.pictures.len) : (k += 1) {
            const m = a.art.map(d.pictures[k]) orelse continue;
            const p = m.place orelse continue;
            try v.board(if (p.layer == .plane_b) .b else .a).drawMap(m, p.x, p.y);
        }
        // The texts' cells, in the font as the dissolves show it.
        const font = try self.fontTiles(v, a);
        try self.drawTexts(v, a, font);
        if (self.shown_star) |s| if (prev == null or was.shown_star != self.shown_star) {
            if (a.art.map(d.star[s].map)) |m| try v.board(.b).drawMapAtPlace(m);
        };
        var left: [render.height]i16 = @splat(0);
        const n = &d.numbers;
        for (n.scroll_first..@min(render.height, n.scroll_first + n.scroll_lines)) |line| left[line] = @intCast(self.shown_scrolled);
        v.lineScroll(.b, &left);
        v.screen.colours = self.colours.shown;
        try self.shown_sprites.draw(v, a);
    }

    /// The font's tiles as the dissolves leave them.
    fn fontTiles(self: *const Ending, v: *view.View, a: *const Assets) ![]art.Tile {
        const n = &a.data.numbers;
        const src = a.italic.sheet.tiles;
        const tiles = try v.tileBlock(font_tiles);
        const f = self.shown_font;
        for (tiles, 0..) |*t, i| t.* = if (f.in or i >= src.len) @splat(0) else src[i];
        var at: u32 = n.dissolve_from;
        for (0..f.passes) |_| {
            while (at < n.dissolve_span) : (at += n.dissolve_step) {
                const byte = at / 2;
                const t = byte / 32;
                if (t >= src.len) continue;
                const px = (byte % 32) / 4 * 8 + (byte % 4) * 2 + at % 2;
                tiles[t][px] = if (f.in) src[t][px] else 0;
            }
            at -= n.dissolve_span;
        }
        return tiles;
    }

    fn drawTexts(self: *const Ending, v: *view.View, a: *const Assets, font: []art.Tile) !void {
        const d = a.data;
        const ty = self.shown_typed;
        if (ty.index >= d.texts.len) return;
        const t = &d.texts[ty.index];
        const board = v.board(if (t.plane == .plane_b) .b else .a);
        // Typing, its codes so far; erasing, every code (those erased blank).
        var codes: u16 = 0;
        for (t.rows, 0..) |row, r| {
            const y: i32 = @as(i32, t.y) + @as(i32, @intCast(r));
            for (row, 0..) |c, x| {
                if (!ty.erasing and codes >= ty.codes) return;
                const erased = ty.erasing and codes < ty.codes;
                codes += 1;
                const cell = if (erased or c == ' ') 0 else glyphTile(a, c);
                try board.put(@as(i32, t.x) + @as(i32, @intCast(x)), y, &font[cell], .{ .priority = true });
            }
            codes += 1;
        }
    }
};

/// A glyph's tile in the italic font.
fn glyphTile(a: *const Ending.Assets, c: u8) usize {
    const g = a.italic.font.glyphAt(&.{c}) orelse return 0;
    return g.tile;
}

/// The codes of a text: its glyphs and blanks, and a code a row's end.
fn codesOf(t: *const records.EndingText) u16 {
    var n: u16 = 0;
    for (t.rows) |row| n += @intCast(row.len + 1);
    return n;
}

const Sprite = struct { sprite: u2 = 0, x: i16 = 0, y: i16 = 0 };

const Sprites = struct {
    items: [4]Sprite = @splat(.{}),
    len: u8 = 0,

    fn add(self: *Sprites, s: Sprite) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = s;
        self.len += 1;
    }

    fn draw(self: *const Sprites, v: *view.View, a: *const Ending.Assets) !void {
        const d = a.data;
        var i = self.len;
        while (i > 0) {
            i -= 1;
            const s = self.items[i];
            const def = switch (s.sprite) {
                0 => d.clouds[0],
                1 => d.clouds[1],
                2 => d.sun,
                3 => d.glow,
            };
            const frame = a.art.frame(def.frame) orelse continue;
            try v.sprites.append(v.gpa, .{ .frame = frame, .x = s.x, .y = s.y, .palette = def.palette, .priority = def.priority });
        }
    }
};

//! The title: the city behind, Axel's picture and STREETS OF RAGE in front, Adam and Blaze, the
//! credits, PRESS START BUTTON blinking, the name's colours stepping. The intro ends on it (its
//! last part, intro.zig); START during the intro sets it up at once, its pictures in place (this
//! scene). It waits 300 ticks for START (the game menu), then the attract demo starts.
//!
//! The parts both share: the colour steps (`ColourSteps`), PRESS START's blink (`Blink`) and the
//! sprites' list (`Sprites`).
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const art = @import("../content/art.zig");
const Setup = @import("../setup.zig").Setup;
const HalfColours = @import("half_colours.zig").HalfColours;

/// The title's wait for START before the demo.
const wait_ticks = 300;
/// Plane A's place: the board's column 120 at the screen's left (the name and the hero).
pub const name_left = 120;

/// The title's colour steps (`title/steps`): every 5 ticks the next of steps 0, 1 and 2 replaces
/// palette 0's colours 1 to 12, then they hold 60 ticks, and again; the index's wrap comes before
/// the fourth step, which is never shown (quirk Q8).
pub const ColourSteps = struct {
    index: u8 = 0,
    count: u8 = 5,
    holding: bool = false,

    const period = 5;
    const hold = 60;
    const steps = 4;

    /// One tick (the first at its start).
    pub fn tick(self: *ColourSteps, c: *HalfColours, all: *const art.PaletteSteps) void {
        self.count -= 1;
        if (self.count != 0) return;
        if (self.holding) {
            self.holding = false;
            self.count = period;
            return;
        }
        self.count = period;
        const step = self.index;
        self.index += 1;
        if (self.index >= steps) {
            self.index = 0;
            self.count = hold;
            self.holding = true;
            return;
        }
        c.showStep(all, step);
    }
};

/// PRESS START BUTTON's blink: shown 20 ticks from its first, hidden 20, and again.
pub const Blink = struct {
    shown: bool = true,
    left: u8 = period,

    const period = 20;

    pub fn tick(self: *Blink) void {
        self.left -= 1;
        if (self.left != 0) return;
        self.left = period;
        self.shown = !self.shown;
    }
};

/// A sprite of the screens' pictures (`intro/picture_NN`), as the scene's state keeps it.
pub const Picture = enum(u8) {
    axel_profile,
    adam_profile,
    blaze_profile,
    adam,
    blaze,
    press_start,
    sega,
    music,
    composer,
    streets,
    of,
    japan_1,
    japan_2,
    trademark,
};

pub const picture_count = @typeInfo(Picture).@"enum".field_names.len;

pub const Sprite = struct {
    picture: Picture = .trademark,
    x: i16 = 0,
    y: i16 = 0,
    palette: u2 = 0,
    priority: bool = false,
};

/// The sprites a picture shows, front to back (the original's order: the first covers the
/// others).
pub fn Sprites(comptime max: usize) type {
    return struct {
        items: [max]Sprite = @splat(.{}),
        len: u8 = 0,

        const Self = @This();

        pub fn add(self: *Self, s: Sprite) void {
            if (self.len == max) return;
            self.items[self.len] = s;
            self.len += 1;
        }

        /// Given to the view back to front: the renderer's later sprites cover the earlier.
        pub fn draw(self: *const Self, v: *view.View, frames: *const [picture_count]*const art.Frame) !void {
            var i = self.len;
            while (i > 0) {
                i -= 1;
                const s = self.items[i];
                try v.sprites.append(v.gpa, .{ .frame = frames[@backingInt(s.picture)], .x = s.x, .y = s.y, .palette = s.palette, .priority = s.priority });
            }
        }
    };
}

/// The title's sprites in place, front to back.
pub const in_place = [_]Sprite{
    .{ .picture = .trademark, .x = 180, .y = 10, .palette = 0, .priority = true },
    .{ .picture = .press_start, .x = 160, .y = 176, .palette = 2, .priority = true },
    .{ .picture = .sega, .x = 160, .y = 200, .palette = 2, .priority = true },
    .{ .picture = .music, .x = 128, .y = 216, .palette = 2, .priority = true },
    .{ .picture = .composer, .x = 200, .y = 216, .palette = 2, .priority = true },
    .{ .picture = .streets, .x = 88, .y = 24, .palette = 0, .priority = false },
    .{ .picture = .of, .x = 88, .y = 40, .palette = 0, .priority = false },
    .{ .picture = .adam, .x = 160, .y = 144, .palette = 2, .priority = false },
    .{ .picture = .blaze, .x = 248, .y = 144, .palette = 3, .priority = false },
};

pub const Title = struct {
    ticks: u16 = 0,
    colours: HalfColours = .{},
    steps: ColourSteps = .{ .index = 1 },
    blink: Blink = .{},
    sprites: Sprites(in_place.len) = .{},
    /// What the picture shows of them: the tick before's.
    shown_sprites: Sprites(in_place.len) = .{},

    pub const Assets = struct {
        city_left: *const art.TileMap,
        city_right: *const art.TileMap,
        hero: *const art.TileMap,
        name_1: *const art.TileMap,
        name_2: *const art.TileMap,
        flash: *const art.Palette,
        name: *const art.Palette,
        colours: *const art.Palette,
        heroes_3: *const art.Palette,
        heroes_2: *const art.Palette,
        city_lights: *const art.Palette,
        city: *const art.Palette,
        steps: *const art.PaletteSteps,
        pictures: [picture_count]*const art.Frame,
        pub const names = .{
            .city_left = "intro/city_left",
            .city_right = "intro/city_right",
            .hero = "title/hero",
            .name_1 = "title/name_1",
            .name_2 = "title/name_2",
            .flash = "title/flash",
            .name = "title/name",
            .colours = "title/colours",
            .heroes_3 = "intro/story_colours_3",
            .heroes_2 = "intro/story_colours_2",
            .city_lights = "intro/city_lights",
            .city = "intro/city",
            .steps = "title/steps",
            .pictures = "intro/picture",
        };
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 64 }, .b = .{ .width = 64, .height = 64 } };

    pub fn start(_: *const Setup) Title {
        return .{};
    }

    pub fn tick(self: *Title, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.colours.latch();
        self.shown_sprites = self.sprites;
        defer self.ticks +|= 1;
        if (self.ticks == 0) {
            // Its colours over the black the intro faded to; its pictures in place, running from
            // this tick.
            for ([_]*const art.Palette{ a.flash, a.name, a.colours, a.heroes_3, a.heroes_2, a.city_lights, a.city }) |p| self.colours.show(p);
        } else {
            if (turn.pressed.pad1.start) return .start;
            if (self.ticks == wait_ticks) return .done;
        }
        self.steps.tick(&self.colours, a.steps);
        self.sprites = .{};
        for (in_place) |s| {
            if (s.picture == .press_start and !self.blink.shown) continue;
            self.sprites.add(s);
        }
        self.blink.tick();
        return null;
    }

    pub fn draw(self: *const Title, prev: ?*const Title, v: *view.View, a: *const Assets) !void {
        if (prev == null) {
            try v.board(.b).drawMapAtPlace(a.city_right);
            try v.board(.b).drawMapAtPlace(a.city_left);
            try v.board(.a).drawMapAtPlace(a.hero);
            try v.board(.a).drawMapAtPlace(a.name_1);
            try v.board(.a).drawMapAtPlace(a.name_2);
        }
        // The scroll as the picture shows it: from the set-up's tick on (the tick before is the
        // intro's dark one).
        if (self.ticks > 1) {
            v.screen.plane_a.x = name_left;
            v.screen.plane_b.x = 0;
        }
        v.screen.colours = self.colours.shown;
        try self.shown_sprites.draw(v, &a.pictures);
    }
};

test "the colour steps: 0, 1, 2 five ticks apart, then a hold, every 80 ticks; the blink 20 and 20" {
    var steps_list: [4][art.palette_count][art.palette_size]?art.Colour = @splat(@splat(@splat(null)));
    for (&steps_list, 0..) |*s, i| s[0][1] = .{ .r = @intCast(i + 1), .g = 0, .b = 0 };
    const all: art.PaletteSteps = .{ .name = "steps", .steps = &steps_list };
    var c: HalfColours = .{};
    var cs: ColourSteps = .{};
    var shown: [170]u4 = undefined;
    for (&shown) |*v| {
        cs.tick(&c, &all);
        v.* = c.now[0][1][0] / 2;
    }
    // Step 0 (red 1) at the 5th tick, 1 at the 10th, 2 at the 15th; the 4th never; 80 later again.
    try std.testing.expectEqual(@as(u4, 0), shown[3]);
    try std.testing.expectEqual(@as(u4, 1), shown[4]);
    try std.testing.expectEqual(@as(u4, 2), shown[9]);
    try std.testing.expectEqual(@as(u4, 3), shown[14]);
    try std.testing.expectEqual(@as(u4, 3), shown[83]);
    try std.testing.expectEqual(@as(u4, 1), shown[84]);
    try std.testing.expectEqual(@as(u4, 2), shown[89]);
    var b: Blink = .{};
    var seen: [45]bool = undefined;
    for (&seen) |*v| {
        v.* = b.shown;
        b.tick();
    }
    try std.testing.expect(seen[0] and seen[19] and !seen[20] and !seen[39] and seen[40]);
}

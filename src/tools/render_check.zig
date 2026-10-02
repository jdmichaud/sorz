//! sorz-render-check: the renderer's checks that need more than the unit tests (PLAN 07).
//!
//!   sorz-render-check --bench
//!       composes a frame of synthetic content (two full layers, the window over 32 lines, 40
//!       sprites of 56 x 72 pixels) many times and prints the time a frame takes: everything
//!       drawn again, the sprites alone, and nothing (an unchanged picture).
//!   sorz-render-check ROM DIR [REFERENCE_DIR]
//!       composes screens from the content of the user's ROM (extracted in memory) and writes
//!       them into DIR as PNG pictures: the title, the menu, and round 1's planes at a camera
//!       position with the status bar and a few of Axel's frames. With REFERENCE_DIR, compares
//!       each with sor-remaster's picture of the same name there (`title.png`, `menu.png`,
//!       `round1.png`, its agent's `--shot`; see `references` below) and writes the differences
//!       as `DIR/NAME_diff.png`: the reference's pixels dimmed where they are equal, red where not.
const std = @import("std");
const sorz = @import("sorz");
const extract = @import("extract");

const render = sorz.render;
const art = sorz.content.art;
const png = sorz.formats.png;

const usage =
    \\usage: sorz-render-check --bench
    \\       sorz-render-check ROM DIR [REFERENCE_DIR]
    \\
;

/// sor-remaster's pictures to compare with, and how its agent takes them (`sorz-agent ROM
/// --frames N --key ... --shot FRAME:PATH`): the frames are display ticks from power-on.
pub const references =
    \\title.png   --frames 601 --key 500:enter --shot 600:title.png (the title, its objects in place)
    \\menu.png    --frames 661 --key 500:enter --key 560:enter --shot 660:menu.png (the arrow on 1 PLAYER)
    \\round1.png  --frames 901 --key 500:enter --shot 900:round1.png (the demo in round 1, camera at 768)
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const first = args.next() orelse return fail(io, usage);
    if (std.mem.eql(u8, first, "--bench")) {
        if (args.next() != null) return fail(io, usage);
        return bench(gpa, io);
    }
    const dir_path = args.next() orelse return fail(io, usage);
    const reference_path = args.next();
    if (args.next() != null) return fail(io, usage);

    const rom = std.Io.Dir.cwd().readFileAlloc(io, first, gpa, .limited(extract.rom.size + 1)) catch |e| {
        return fail(io, try std.fmt.allocPrint(init.arena.allocator(), "cannot read the ROM {s}: {s}\n", .{ first, @errorName(e) }));
    };
    defer gpa.free(rom);
    var tree = extract.extract(gpa, rom) catch |e| switch (e) {
        error.WrongRom => return fail(io, "not the ROM sorz follows (its size or SHA-256 differs)\n"),
        else => return e,
    };
    defer tree.deinit();
    var source = sorz.memory.MemoryAssetSource.init(gpa);
    defer source.deinit();
    try tree.addTo(&source);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: sorz.content.Diagnostic = .{};
    const content = sorz.content.load(arena, source.assetSource(), &diag) catch |e| switch (e) {
        error.BadAsset => return fail(io, try std.fmt.allocPrint(arena, "the tree does not load: {f}\n", .{&diag})),
        else => return e,
    };

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);
    var reference_dir: ?std.Io.Dir = if (reference_path) |p| std.Io.Dir.cwd().openDir(io, p, .{}) catch |e| {
        return fail(io, try std.fmt.allocPrint(arena, "cannot open the references {s}: {s}\n", .{ p, @errorName(e) }));
    } else null;
    defer if (reference_dir) |*d| d.close(io);

    const composer = try render.Composer.create(gpa);
    defer composer.destroy();
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const screens = [_]struct { name: []const u8, make: *const fn (*Stage) anyerror!void }{
        .{ .name = "title", .make = title },
        .{ .name = "menu", .make = menu },
        .{ .name = "round1", .make = round1 },
    };
    for (screens) |s| {
        var stage: Stage = .{ .gpa = gpa, .art = &content.art };
        defer stage.deinit();
        s.make(&stage) catch |e| return fail(io, try std.fmt.allocPrint(arena, "{s}: {s}\n", .{ s.name, @errorName(e) }));
        const start = std.Io.Timestamp.now(io, .awake);
        _ = try composer.compose(&stage.screen);
        const ns = start.untilNow(io, .awake).toNanoseconds();
        try writePicture(gpa, io, dir, try std.fmt.allocPrint(arena, "{s}.png", .{s.name}), composer);
        try out.interface.print("{{\"picture\":\"{s}\",\"compose_us\":{d}", .{ s.name, @divTrunc(ns, 1000) });
        if (reference_dir) |rd| {
            const c = try compareWith(gpa, io, rd, dir, s.name, composer, stage.compare_from);
            try out.interface.print(",\"compared_lines\":[{d},{d}],\"pixels\":{d},\"differing\":{d}", .{ stage.compare_from, render.height, c.pixels, c.differing });
        }
        try out.interface.writeAll("}\n");
        try out.interface.flush();
    }
}

/// A screen being set: its boards, its sprites and its colours.
const Stage = struct {
    gpa: std.mem.Allocator,
    art: *const art.Art,
    screen: render.Screen = .{},
    palettes: render.Palettes = .{},
    boards: [3]?render.Board = @splat(null),
    sprites: std.ArrayList(render.Sprite) = .empty,
    /// Frames the screen makes from tiles (the menu's arrow).
    made: std.ArrayList(*art.Frame) = .empty,
    /// The first line compared with the reference (the status bar's texts are left out).
    compare_from: u16 = 0,

    fn deinit(self: *Stage) void {
        for (&self.boards) |*b| if (b.*) |*made| made.deinit();
        self.sprites.deinit(self.gpa);
        for (self.made.items) |f| self.gpa.destroy(f);
        self.made.deinit(self.gpa);
    }

    fn board(self: *Stage, k: usize, w: u16, h: u16) !*render.Board {
        self.boards[k] = try render.Board.init(self.gpa, w, h);
        return &self.boards[k].?;
    }

    fn map(self: *Stage, name: []const u8) !*const art.TileMap {
        return self.art.map(name) orelse missing(name);
    }

    fn frame(self: *Stage, name: []const u8) !*const art.Frame {
        return self.art.frame(name) orelse missing(name);
    }

    fn show(self: *Stage, name: []const u8) !void {
        self.palettes.show(self.art.palette(name) orelse return missing(name));
    }

    fn sprite(self: *Stage, s: render.Sprite) !void {
        try self.sprites.append(self.gpa, s);
    }

    fn finish(self: *Stage) void {
        self.screen.sprites = self.sprites.items;
        self.screen.colours = self.palettes.shown;
    }
};

fn missing(name: []const u8) error{MissingAsset} {
    std.log.err("no asset {s} in the content", .{name});
    return error.MissingAsset;
}

/// The title as its set-up leaves it (graphics port map 3.3): the city on plane B, the logo and
/// the title's name on plane A scrolled by 120 pixels, the screen's palettes, and the title's
/// pictures as sprites in their places.
fn title(s: *Stage) !void {
    const b = try s.board(0, 64, 64);
    try b.drawMapAtPlace(try s.map("intro/city_right"));
    try b.drawMapAtPlace(try s.map("intro/city_left"));
    const a = try s.board(1, 64, 64);
    try a.drawMapAtPlace(try s.map("title/hero"));
    try a.drawMapAtPlace(try s.map("title/name_1"));
    try a.drawMapAtPlace(try s.map("title/name_2"));
    s.screen.plane_b = .{ .board = b };
    s.screen.plane_a = .{ .board = a, .x = 120 };
    for ([_][]const u8{ "title/flash", "title/name", "title/colours", "intro/story_colours_3", "intro/story_colours_2", "intro/city_lights", "intro/city" }) |p| try s.show(p);
    // The title's objects, back to front: by their depth, the lowest on the screen in front.
    const pictures = [_]struct { frame: []const u8, x: i32, y: i32, palette: u2, priority: bool }{
        .{ .frame = "intro/picture_13", .x = 180, .y = 10, .palette = 0, .priority = true },
        .{ .frame = "intro/picture_09", .x = 88, .y = 24, .palette = 0, .priority = false },
        .{ .frame = "intro/picture_10", .x = 88, .y = 40, .palette = 0, .priority = false },
        .{ .frame = "intro/picture_04", .x = 248, .y = 144, .palette = 3, .priority = false },
        .{ .frame = "intro/picture_03", .x = 160, .y = 144, .palette = 2, .priority = false },
        .{ .frame = "intro/picture_05", .x = 160, .y = 176, .palette = 2, .priority = true },
        .{ .frame = "intro/picture_06", .x = 160, .y = 200, .palette = 2, .priority = true },
        .{ .frame = "intro/picture_07", .x = 128, .y = 216, .palette = 2, .priority = true },
        .{ .frame = "intro/picture_08", .x = 200, .y = 216, .palette = 2, .priority = true },
    };
    for (pictures) |p| try s.sprite(.{ .frame = try s.frame(p.frame), .x = p.x, .y = p.y, .palette = p.palette, .priority = p.priority });
    s.finish();
}

/// The game's menu (1 PLAYER, 2 PLAYERS, OPTIONS) with its colours for two pads, and the arrow
/// (the font's glyph "->" as a sprite) on the first line.
fn menu(s: *Stage) !void {
    const a = try s.board(1, 64, 32);
    for ([_][]const u8{ "menu/one_player", "menu/two_players", "menu/options" }) |m| try a.drawMapAtPlace(try s.map(m));
    s.screen.plane_a = .{ .board = a };
    try s.show("menu/two_pads");
    const font = s.art.font("fonts/main") orelse return missing("fonts/main");
    const sheet = s.art.sheet(font.sheet) orelse return missing(font.sheet);
    const arrow = font.glyphAt("->") orelse return missing("the arrow's glyph");
    const f = try s.gpa.create(art.Frame);
    errdefer s.gpa.destroy(f);
    f.* = .{ .name = "arrow", .file = "", .width = 8, .height = 8, .origin_x = 0, .origin_y = 0, .pixels = &sheet.tiles[arrow.tile] };
    try s.made.append(s.gpa, f);
    try s.sprite(.{ .frame = f, .x = 112, .y = 88 });
    s.finish();
}

/// Round 1 at the camera of the attract demo's start (768, 0): its two planes, the status bar
/// in the window over the top 32 lines (which hides the sprites there), round 1's and play's
/// colours, and a few of Axel's frames.
fn round1(s: *Stage) !void {
    const pa = try s.map("round1/plane_a");
    const pb = try s.map("round1/plane_b");
    const b = try s.board(0, pb.width, pb.height);
    try b.drawMap(pb, 0, 0);
    const a = try s.board(1, pa.width, pa.height);
    try a.drawMap(pa, 0, 0);
    const w = try s.board(2, 40, 28);
    try w.drawMapAtPlace(try s.map("play/status_bar"));
    s.screen.plane_b = .{ .board = b, .x = 768 };
    s.screen.plane_a = .{ .board = a, .x = 768 };
    s.screen.window = .{ .board = w, .lines = .{ .top = 0, .bottom = 32 } };
    s.screen.sprite_lines = .{ .top = 32, .bottom = render.height };
    for ([_][]const u8{ "round1/colours", "play/colours", "play/players" }) |p| try s.show(p);
    const axel = [_]struct { frame: []const u8, x: i32, y: i32, flip: bool }{
        .{ .frame = "axel/001", .x = 60, .y = 200, .flip = false },
        .{ .frame = "axel/004", .x = 130, .y = 190, .flip = true },
        .{ .frame = "axel/012", .x = 200, .y = 210, .flip = false },
        .{ .frame = "axel/020", .x = 270, .y = 60, .flip = true },
    };
    for (axel) |x| {
        var sp = render.Sprite.of(try s.frame(x.frame), x.x, x.y);
        sp.flip_x = x.flip;
        try s.sprite(sp);
    }
    s.compare_from = 32;
    s.finish();
}

/// The composed picture as an indexed PNG: index k + 1 is colour k of the palettes, so that no
/// pixel uses index 0, which the encoder makes transparent.
fn writePicture(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, c: *const render.Composer) !void {
    var pixels: [render.width * render.height]u8 = undefined;
    for (&pixels, c.indices) |*p, i| p.* = i + 1;
    var colours: [1 + render.palettes.count * render.palettes.size][3]u8 = undefined;
    colours[0] = .{ 255, 0, 255 };
    for (c.colours.?, 0..) |line, i| for (line, 0..) |col, k| {
        colours[1 + i * render.palettes.size + k] = render.palettes.rgba(col)[0..3].*;
    };
    const bytes = try png.encode(gpa, render.width, render.height, &pixels, &colours);
    defer gpa.free(bytes);
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}

const Comparison = struct { pixels: usize, differing: usize };

/// The composed picture against the reference's picture NAME.png from line `from` on; writes
/// NAME_diff.png.
fn compareWith(gpa: std.mem.Allocator, io: std.Io, rd: std.Io.Dir, dir: std.Io.Dir, name: []const u8, c: *const render.Composer, from: u16) !Comparison {
    var name_buf: [64]u8 = undefined;
    const file = try std.fmt.bufPrint(&name_buf, "{s}.png", .{name});
    const bytes = try rd.readFileAlloc(io, file, gpa, .limited(1 << 22));
    defer gpa.free(bytes);
    var ref = try png.decode(gpa, bytes);
    defer ref.deinit(gpa);
    if (ref.width != render.width or ref.height != render.height) return error.ReferenceSize;
    const frame = c.frame();
    var diff: [render.width * render.height]u8 = undefined;
    // The diff's colours: 0 unused, 1 red, then the reference's colours dimmed.
    var colours: std.ArrayList([3]u8) = .empty;
    defer colours.deinit(gpa);
    try colours.appendSlice(gpa, &.{ .{ 255, 0, 255 }, .{ 255, 0, 0 } });
    var result: Comparison = .{ .pixels = 0, .differing = 0 };
    for (0..render.height) |y| for (0..render.width) |x| {
        const want = ref.palette[ref.pixels[y * render.width + x]];
        const got = frame.row(@intCast(y))[x * 4 ..][0..3];
        const k = y * render.width + x;
        if (y < from) {
            diff[k] = try dimmed(gpa, &colours, want, 4);
            continue;
        }
        result.pixels += 1;
        if (std.mem.eql(u8, &want, got)) {
            diff[k] = try dimmed(gpa, &colours, want, 2);
        } else {
            result.differing += 1;
            diff[k] = 1;
        }
    };
    const out = try png.encode(gpa, render.width, render.height, &diff, colours.items);
    defer gpa.free(out);
    const diff_name = try std.fmt.bufPrint(&name_buf, "{s}_diff.png", .{name});
    try dir.writeFile(io, .{ .sub_path = diff_name, .data = out });
    return result;
}

fn dimmed(gpa: std.mem.Allocator, colours: *std.ArrayList([3]u8), c: [3]u8, by: u8) !u8 {
    const d: [3]u8 = .{ c[0] / by, c[1] / by, c[2] / by };
    for (colours.items[2..], 2..) |e, i| if (std.mem.eql(u8, &e, &d)) return @intCast(i);
    if (colours.items.len == 256) return error.TooManyColours;
    try colours.append(gpa, d);
    return @intCast(colours.items.len - 1);
}

// The timing -------------------------------------------------------------------------------------

fn bench(gpa: std.mem.Allocator, io: std.Io) !void {
    var prng = std.Random.DefaultPrng.init(31415926);
    const r = prng.random();
    // Synthetic art: 256 tiles of random colours, and a frame of a player's size.
    const tiles = try gpa.alloc(art.Tile, 256);
    defer gpa.free(tiles);
    for (tiles) |*t| for (t) |*v| {
        v.* = if (r.uintLessThan(u8, 4) == 0) 0 else r.uintLessThan(u8, 16);
    };
    var pixels: [56 * 72]u8 = undefined;
    for (&pixels, 0..) |*v, i| v.* = if ((i % 56) < 8 or (i % 56) > 50) 0 else r.uintLessThan(u8, 16);
    const fr: art.Frame = .{ .name = "f", .file = "f.png", .width = 56, .height = 72, .origin_x = 28, .origin_y = 71, .pixels = &pixels };
    var boards: [3]render.Board = undefined;
    const sizes = [3][2]u16{ .{ 64, 32 }, .{ 64, 32 }, .{ 40, 28 } };
    for (&boards, sizes) |*b, size| {
        b.* = try render.Board.init(gpa, size[0], size[1]);
        const cells = try gpa.alloc(art.Cell, @as(usize, size[0]) * size[1]);
        defer gpa.free(cells);
        for (cells) |*c| c.* = .{ .tile = r.uintLessThan(u16, 256), .palette = r.int(u2), .flip_x = r.boolean(), .flip_y = r.boolean(), .priority = r.uintLessThan(u8, 4) == 0 };
        const m: art.TileMap = .{ .name = "m", .file = "m.tmj", .width = size[0], .height = size[1], .sheets = &.{}, .tiles = tiles, .cells = cells };
        try b.drawMap(&m, 0, 0);
    }
    defer for (&boards) |*b| b.deinit();
    var sprites: [40]render.Sprite = undefined;
    for (&sprites) |*s| s.* = .{ .frame = &fr, .x = r.intRangeAtMost(i32, 0, 320), .y = r.intRangeAtMost(i32, 60, 260), .flip_x = r.boolean(), .palette = r.int(u2), .priority = r.uintLessThan(u8, 8) == 0 };
    var p: render.Screen = .{
        .plane_b = .{ .board = &boards[0], .x = 3 },
        .plane_a = .{ .board = &boards[1], .x = 5 },
        .window = .{ .board = &boards[2], .lines = .{ .top = 0, .bottom = 32 } },
        .sprites = &sprites,
        .sprite_lines = .{ .top = 32, .bottom = render.height },
    };
    for (&p.colours, 0..) |*line, i| for (line, 0..) |*c, k| {
        c.* = .{ .r = @intCast(i * 2), .g = @intCast(k % 8), .b = @intCast(k / 2) };
    };
    const composer = try render.Composer.create(gpa);
    defer composer.destroy();
    const frames = 400;
    var out_buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    try out.interface.print("{{\"mode\":\"{s}\"", .{@tagName(@import("builtin").mode)});
    const cases = [_][]const u8{ "everything", "sprites", "nothing" };
    for (cases) |case| {
        var best: i96 = std.math.maxInt(i96);
        var total: i96 = 0;
        for (0..frames) |k| {
            // Every frame moves what the case changes: the layers' scroll, the sprites.
            if (!std.mem.eql(u8, case, "nothing")) {
                for (&sprites) |*s| s.x +%= if (k % 2 == 0) 1 else -1;
            }
            if (std.mem.eql(u8, case, "everything")) {
                p.plane_b.x += 1;
                p.plane_a.x += 2;
            }
            const start = std.Io.Timestamp.now(io, .awake);
            _ = try composer.compose(&p);
            const ns = start.untilNow(io, .awake).toNanoseconds();
            best = @min(best, ns);
            total += ns;
        }
        try out.interface.print(",\"{s}_us\":{{\"mean\":{d},\"best\":{d}}}", .{ case, @divTrunc(@divTrunc(total, frames), 1000), @divTrunc(best, 1000) });
    }
    try out.interface.writeAll("}\n");
    try out.interface.flush();
}

fn fail(io: std.Io, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(message);
    try w.interface.flush();
    std.process.exit(2);
}

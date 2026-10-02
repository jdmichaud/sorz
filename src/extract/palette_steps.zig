//! The screens' palette steps (docs/content.md): colours the original's routines show one after
//! another from small tables of its own, the steps' times being the scenes':
//! - the Sega logo's colour sweep (0x8F98): a table of 31 colours (0x7224C), of which a window of
//!   11 is palette 0's colours 2 to 12, the window moving one colour back every 4 ticks from the
//!   table's colour 20 to its first: 21 steps;
//! - the title's colour steps (0xC58C, type $79): four lists of 12 colours (0x3F556), palette 0's
//!   colours 1 to 12.
const std = @import("std");
const sorz = @import("sorz");
const art = sorz.content.art;
const rom_mod = @import("rom.zig");
const builder_mod = @import("builder.zig");
const Builder = builder_mod.Builder;

const Step = [art.palette_count][art.palette_size]?art.Colour;

pub const sweep_table = 0x7224C;
const sweep_colours = 31;
const sweep_window = 11;
/// The window's first colour at the sweep's start: the table's 21st.
const sweep_from = 20;

pub const title_table = 0x3F556;
const title_steps = 4;
const title_colours = 12;

/// `count` colours of the ROM at `a`, one word each, into palette 0 from colour `first`.
fn colours(rom: []const u8, a: u32, first: usize, count: usize) Step {
    var s: Step = @splat(@splat(null));
    for (0..count) |k| s[0][first + k] = builder_mod.colourOf(rom_mod.u16be(rom, a + 2 * @as(u32, @intCast(k))));
    return s;
}

pub fn extract(b: *Builder) !void {
    const rom = b.rom;
    const sweep = try b.arena.alloc(Step, sweep_from + 1);
    for (sweep, 0..) |*s, i| {
        const window: u32 = @intCast(sweep_from - i);
        std.debug.assert(window + sweep_window <= sweep_colours);
        s.* = colours(rom, sweep_table + 2 * window, 2, sweep_window);
    }
    try b.paletteSteps("segalogo/sweep", .{
        .name = "",
        .provenance = try std.fmt.allocPrint(b.arena, "ROM 0x{X:0>5}: 31 colours, of which a window of 11 is shown as palette 0's colours 2 to 12, from the table's colour 20 back to its first, a colour a step (0x8F98, every 4 ticks)", .{sweep_table}),
        .steps = sweep,
    });
    const title = try b.arena.alloc(Step, title_steps);
    for (title, 0..) |*s, i| s.* = colours(rom, title_table + @as(u32, @intCast(i)) * 2 * title_colours, 1, title_colours);
    try b.paletteSteps("title/steps", .{
        .name = "",
        .provenance = try std.fmt.allocPrint(b.arena, "ROM 0x{X:0>5}: four lists of 12 colours, palette 0's colours 1 to 12, shown in turn by the title's colour steps (type $79, 0xC58C)", .{title_table}),
        .steps = title,
    });
}

test "the sweep's steps are windows of the table, one colour back a step" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // A synthetic image: the sweep's table colour k has red k % 8 and green k / 8; the title's
    // lists colour (i, k) blue i + 1.
    const rom = try arena.allocator().alloc(u8, 0x80000);
    @memset(rom, 0);
    for (0..sweep_colours) |k| std.mem.writeInt(u16, rom[sweep_table + 2 * k ..][0..2], @intCast(((k % 8) << 1) | ((k / 8) << 5)), .big);
    for (0..title_steps) |i| for (0..title_colours) |k| {
        std.mem.writeInt(u16, rom[title_table + 2 * (i * title_colours + k) ..][0..2], @intCast((i + 1) << 9), .big);
    };
    var b = Builder.init(arena.allocator(), rom);
    try extract(&b);
    const a = try b.finish();
    const sweep = a.steps("segalogo/sweep").?;
    try std.testing.expectEqual(@as(usize, 21), sweep.steps.len);
    // Step 0: the window from colour 20 (red 4, green 2) at colour 2; step 20 from colour 0.
    try std.testing.expect(sweep.steps[0][0][2].?.eql(.{ .r = 4, .g = 2, .b = 0 }));
    try std.testing.expect(sweep.steps[20][0][2].?.eql(.{ .r = 0, .g = 0, .b = 0 }));
    try std.testing.expect(sweep.steps[20][0][12].?.eql(.{ .r = 2, .g = 1, .b = 0 }));
    try std.testing.expect(sweep.steps[3][0][1] == null and sweep.steps[3][0][13] == null);
    const title = a.steps("title/steps").?;
    try std.testing.expect(title.steps[3][0][12].?.eql(.{ .r = 0, .g = 0, .b = 4 }) and title.steps[0][0][0] == null);
}

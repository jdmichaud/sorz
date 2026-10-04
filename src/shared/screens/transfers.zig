//! The picture's transfers and the sound (DESIGN.md A4, P4): in the original, as each frame
//! starts the game copies the parts of the picture that its last tick made (the sprites' list,
//! the colours when it touched them, a screen's own table of scroll or tiles) and reads the pads,
//! each time with the sound's processor stopped, so that the samples it plays (the drums, the
//! voices) come that much later. A deliberate model of that time, measured by sor-remaster on the
//! original: a transfer of n words stops the sound's processor for 64 + 456n / 205 of its cycles
//! (228n / 205 for the colours), the pads' reading for 235.
//!
//! A tick says what its frame transfers (`Frame`); the game gives the sound the time at the next
//! frame's start, when the original transfers it (game.zig). A load's frames transfer nothing:
//! the original's loads hold the frame's work and the sound's driver.
const std = @import("std");

/// What a tick's picture transfers as the next frame starts.
pub const Frame = struct {
    /// The colours, when the tick touched them (set, faded, stepped).
    colours: bool = false,
    /// A table of scroll a line, both planes' (the intro, the title).
    line_scroll: bool = false,
    /// The scroll by cells, both planes' (the Sega logo's frames: play's way, with nothing to
    /// scroll).
    cell_scroll: bool = false,
    /// Tiles the game makes, in words (Axel's picture revealed, the title's set-up).
    tile_words: u16 = 0,
};

/// The sprites' list: 320 words, every frame.
const sprite_list_words = 320;
const colour_words = 64;
const line_scroll_words = 512;
/// Two transfers of 32 words.
const cell_scroll_words = 32;

/// The cycles a transfer of `words` stops the sound's processor; `colours` at half the cost a
/// word.
fn transfer(words: u32, colours: bool) u32 {
    const per_word: u32 = if (colours) 228 else 456;
    return 64 + words * per_word / 205;
}

/// The cycles the pads' reading stops it, at each frame but a load's.
pub const pads = 235;

/// The cycles the transfers of `f` stop the sound's processor.
pub fn hold(f: Frame) u32 {
    var h = transfer(sprite_list_words, false);
    if (f.colours) h += transfer(colour_words, true);
    if (f.line_scroll) h += transfer(line_scroll_words, false);
    if (f.cell_scroll) h += 2 * transfer(cell_scroll_words, false);
    if (f.tile_words != 0) h += transfer(f.tile_words, false);
    return h;
}

test "the transfers' cycles, as sor-remaster measured them" {
    try std.testing.expectEqual(@as(u32, 775), hold(.{}));
    try std.testing.expectEqual(@as(u32, 775 + 135 + 1202), hold(.{ .colours = true, .line_scroll = true }));
    try std.testing.expectEqual(@as(u32, 775 + 270), hold(.{ .cell_scroll = true }));
    try std.testing.expectEqual(@as(u32, 775 + 6327), hold(.{ .tile_words = 2816 }));
}

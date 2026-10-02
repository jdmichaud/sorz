//! What a logic tick of the world gives out, besides its state: the sounds asked for, the blows
//! that landed, the pick-ups, the random draws (for the semantic traces), the frames the entities
//! showed and the draw list (for the renderer). It is not the game's state: nothing in it decides
//! what the world does next, and it holds the content's frames by reference, so it lives outside
//! the canonical state, with the presentation.
const std = @import("std");
const art = @import("../content/art.zig");
const render = @import("../render/root.zig");
const entity = @import("entity.zig");
const random = @import("random.zig");

const Handle = entity.Handle;
const capacity = entity.capacity;

/// A list of at most `n` items; an item past them is dropped and counted.
pub fn List(comptime T: type, comptime n: usize) type {
    return struct {
        const Self = @This();
        pub const max = n;

        items: [n]T = undefined,
        len: usize = 0,
        /// Items that did not fit.
        dropped: usize = 0,

        pub fn append(self: *Self, item: T) void {
            if (self.len == n) {
                self.dropped += 1;
                return;
            }
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.dropped = 0;
        }
    };
}

/// A sound asked for, by its name in the sound content (DESIGN.md A1), and who asked.
pub const SoundRequest = struct { name: []const u8, by: ?Handle = null };

/// A blow that landed: who struck (null: no entity, the special attack's), whom, and the health
/// it took.
pub const Hit = struct { attacker: ?Handle, target: Handle, damage: i16 };

/// A weapon or an item picked up, by whom.
pub const Pickup = struct { item: Handle, kind: entity.KindId, by: Handle };

/// The frame an entity showed at the tick, and whether mirrored.
pub const Shown = struct { frame: *const art.Frame, mirrored: bool };

pub const Output = struct {
    /// The random generator's draws.
    draws: random.Draws = .{},
    sounds: List(SoundRequest, 32) = .{},
    hits: List(Hit, 32) = .{},
    pickups: List(Pickup, 16) = .{},
    /// By the entities' places in the pool: the frame each showed (the animation system).
    shown: [capacity]?Shown = @splat(null),
    /// The draw list, back to front: what the renderer's `Screen.sprites` takes. It stays until
    /// the next logic tick, so the display ticks in between draw it again.
    sprites: List(render.Sprite, 2 * capacity) = .{},

    /// A new logic tick: its lists start empty (the draw list is rebuilt by its system).
    pub fn begin(self: *Output) void {
        self.draws.clear();
        self.sounds.clear();
        self.hits.clear();
        self.pickups.clear();
        @memset(&self.shown, null);
    }
};

test "a list drops and counts what does not fit" {
    var l: List(u8, 2) = .{};
    l.append(1);
    l.append(2);
    l.append(3);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, l.slice());
    try std.testing.expectEqual(@as(usize, 1), l.dropped);
    l.clear();
    try std.testing.expectEqual(@as(usize, 0), l.slice().len);
}

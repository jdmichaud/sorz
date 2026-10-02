//! The world of a round (DESIGN.md 10.3): its numbers and its random generator.
pub const fixed = @import("fixed.zig");
pub const random = @import("random.zig");

pub const Fixed = fixed.Fixed;
pub const Vec3 = fixed.Vec3;
pub const Random = random.Random;

test {
    @import("std").testing.refAllDecls(@This());
}

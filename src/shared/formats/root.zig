//! The file formats the game reads and writes, shared by the content's loader, the extractor and
//! the records: JSON with a deterministic writer and a reader that names the refused field, and
//! indexed PNG pictures.
pub const json = @import("json.zig");
pub const png = @import("png.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

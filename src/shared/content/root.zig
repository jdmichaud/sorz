//! The game's content as typed data, by name, and the tree it is read from (DESIGN.md P2, C2;
//! docs/content.md): the art (palettes, tile sheets, tile maps, sprite frames, fonts, each
//! screen's art set), the definitions of the kinds of entity, and the tree's manifest. The
//! extractor writes the tree from the user's ROM; a mod edits a copy of it.
pub const art = @import("art.zig");
pub const tiled = @import("tiled.zig");
pub const entity = @import("entity.zig");
pub const tree = @import("tree.zig");

pub const Art = art.Art;
pub const Content = tree.Content;
pub const File = tree.File;
pub const Diagnostic = tree.Diagnostic;
pub const load = tree.load;
pub const write = tree.write;

test {
    @import("std").testing.refAllDecls(@This());
}

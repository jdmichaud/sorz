//! sorz-server: server mode (DESIGN.md 9). It serves the browser build and the game's files of
//! the data it is given (a game directory) on one port, and relays network play between the
//! browsers (`native.relay`); it runs no game, links no library, and runs until it is stopped.
//!
//! `sorz-sdl --server` and `sorz-agent --server` run the same relay. This binary is the one for a
//! machine without the display and sound libraries (X11, Wayland, PulseAudio, ALSA) that
//! `sorz-sdl` needs to start: it is static.
const std = @import("std");
const native = @import("native");
const web_page = @import("web_page");
const relay = native.relay;

/// The browser build built into the binary: it serves no file beside it.
const page: native.net.Page = .{ .index_html = web_page.index_html, .script_js = web_page.script_js, .module_wasm = web_page.module_wasm };

/// Every log line as the binaries' (native/log.zig).
pub const std_options: std.Options = .{ .logFn = native.log.logFn };

pub fn main(init: std.process.Init) !void {
    native.log.program = "sorz-server";
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buf);
    const err = &stderr.interface;
    const options = relay.Options.parse(try init.minimal.args.iterateAllocator(init.arena.allocator())) catch {
        try err.writeAll("sorz-server: invalid arguments\n\n" ++ relay.usage);
        try err.flush();
        std.process.exit(2);
    };
    if (options.help) {
        try err.writeAll(relay.usage);
        try err.flush();
        return;
    }
    const status = try relay.serve(init.gpa, io, options.data.?, options.address.?, page);
    if (status != 0) std.process.exit(status);
}

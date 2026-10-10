//! sorz-sdl: the interactive SDL host. The entry point only creates the process resources and
//! gives them to `sdl.host.run`. That function owns the backend, the providers, the game and the
//! outer loop.
const std = @import("std");
const sdl = @import("sdl");
const native = @import("native");
const web_page = @import("web_page");
const built_in = @import("built_in");

/// The browser build built into the binary, which `--netplay` and `--server` serve.
const page: native.net.Page = .{ .index_html = web_page.index_html, .script_js = web_page.script_js, .module_wasm = web_page.module_wasm };

/// Every log line as the binaries' (native/log.zig).
pub const std_options: std.Options = .{ .logFn = native.log.logFn };

pub fn main(init: std.process.Init) !void {
    native.log.program = "sorz-sdl";
    // `iterateAllocator` is the form that Windows needs; the arena keeps the arguments for the
    // whole run.
    var options = sdl.host.parseArgs(try init.minimal.args.iterateAllocator(init.arena.allocator())) catch |err| {
        try showUsage(init.io, if (err == error.MissingAssets) "a game directory is required" else "invalid arguments");
        std.process.exit(2);
    };
    // The ROM built into sorz-sdl-standalone, played without a game path; sorz-sdl has none.
    options.providers.built_in_rom = built_in.rom;
    if (options.help) return showUsage(init.io, null);
    const status = try sdl.host.run(init.gpa, init.io, init.environ_map, options, page);
    if (status != 0) std.process.exit(status);
}

fn showUsage(io: std.Io, message: ?[]const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    if (message) |text| try w.interface.print("sorz-sdl: {s}\n\n", .{text});
    try w.interface.writeAll(sdl.host.usage);
    try w.interface.flush();
}

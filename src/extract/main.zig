//! sorz-extract: the extractor as a tool of the build (not one of the game's executables).
//!
//!   sorz-extract ROM DIR     writes ROM's content tree into DIR
//!   sorz-extract --check ROM extracts twice and checks that the trees are byte-identical, and
//!                            that every file of the tree loads (the content's loader)
const std = @import("std");
const sorz = @import("sorz");
const extract = @import("extract");

pub const std_options: std.Options = .{ .log_level = .info };

const usage =
    \\usage: sorz-extract ROM DIR
    \\       sorz-extract --check ROM
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const first = args.next() orelse return fail(io, usage);
    const check = std.mem.eql(u8, first, "--check");
    const rom_path = if (check) args.next() orelse return fail(io, usage) else first;
    const dir_path = if (check) null else args.next() orelse return fail(io, usage);
    if (args.next() != null) return fail(io, usage);

    const rom = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(extract.rom.size + 1)) catch |e| {
        return fail(io, try std.fmt.allocPrint(init.arena.allocator(), "cannot read the ROM {s}: {s}\n", .{ rom_path, @errorName(e) }));
    };
    defer gpa.free(rom);

    var tree = extract.extract(gpa, rom) catch |e| switch (e) {
        error.WrongRom => return fail(io, "not the ROM sorz follows (its size or SHA-256 differs)\n"),
        else => return e,
    };
    defer tree.deinit();

    var out_buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    if (dir_path) |path| {
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
        defer dir.close(io);
        try extract.writeDirectory(io, &tree, dir);
        var bytes: usize = 0;
        for (tree.files) |f| bytes += f.bytes.len;
        try out.interface.print("{{\"files\":{d},\"bytes\":{d},\"into\":\"{s}\"}}\n", .{ tree.files.len, bytes, path });
        try out.interface.flush();
        return;
    }

    // Two extractions are byte-identical.
    var again = try extract.extract(gpa, rom);
    defer again.deinit();
    if (again.files.len != tree.files.len) return fail(io, "two extractions differ in their count of files\n");
    for (tree.files, again.files) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.bytes, b.bytes)) {
            return fail(io, try std.fmt.allocPrint(init.arena.allocator(), "two extractions differ: {s}\n", .{a.path}));
        }
    }
    // Every file loads, and the loaded content writes the same files again.
    var source = sorz.memory.MemoryAssetSource.init(gpa);
    defer source.deinit();
    try tree.addTo(&source);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag: sorz.content.Diagnostic = .{};
    const loaded = sorz.content.load(arena.allocator(), source.assetSource(), &diag) catch |e| switch (e) {
        error.BadAsset => return fail(io, try std.fmt.allocPrint(init.arena.allocator(), "the tree does not load: {f}\n", .{&diag})),
        else => return e,
    };
    const rewritten = try sorz.content.write(arena.allocator(), &loaded);
    var read: usize = 0;
    for (tree.files) |f| {
        if (std.mem.startsWith(u8, f.path, "sound/")) continue; // the sound's own loader reads these
        read += 1;
    }
    if (rewritten.len != read) return fail(io, "the loaded tree writes another count of files\n");
    var k: usize = 0;
    for (tree.files) |f| {
        if (std.mem.startsWith(u8, f.path, "sound/")) continue;
        const r = rewritten[k];
        k += 1;
        if (!std.mem.eql(u8, f.path, r.path) or !std.mem.eql(u8, f.bytes, r.bytes)) {
            return fail(io, try std.fmt.allocPrint(init.arena.allocator(), "the loaded tree writes {s} differently\n", .{f.path}));
        }
    }
    var bytes: usize = 0;
    for (tree.files) |f| bytes += f.bytes.len;
    try out.interface.print("{{\"files\":{d},\"bytes\":{d},\"identical\":true,\"loaded_sets\":{d},\"rewritten_identical\":true}}\n", .{ tree.files.len, bytes, loaded.art.sets.len });
    try out.interface.flush();
}

fn fail(io: std.Io, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(message);
    try w.interface.flush();
    std.process.exit(2);
}

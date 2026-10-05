//! sorz build graph.
//!
//! Targets:
//!   sorz-agent  headless debugging host (shared game + AgentBackend), never links SDL
//!   sorz-sdl    SDL interactive host (Linux, Windows)
//!   sorz-server the relay of network play between two browsers (server mode), links nothing
//!   web/            the browser build: sorz.wasm, index.html, sorz.js
//! Steps: `zig build` installs the three binaries; `agent`, `sdl` and `server` install one; `web`
//! installs the browser build and checks its module's imports; `web-check` checks the page's
//! helper functions against compiler-rt (it needs Node.js); `test` runs the unit tests of every
//! module and the engine's rule against the console's terms (tools/engine_terms.zig); `smoke`
//! runs the agent host for a few frames and checks the settings record across starts
//! (tools/check_settings.sh); `verify` checks that the agent and server binaries have no SDL
//! dependency and that each executable, alone in a directory, serves its page
//! (tools/check_alone.sh); `all` installs every binary of the target and of Windows (under
//! <prefix>/windows) and the browser build. `browser-check` runs the browser build in Chromium
//! against the agent host, and two pages through the relay, and with `-Drom=ROM` the page's
//! screens drawn from the ROM's content (it needs Node.js and a Chromium);
//! `sound-check` compares the sound with sor-remaster's, from the user's ROM (`-Drom=ROM
//! -Dremaster=DIR`), `screens-check` the screens' pictures and sound, tick by tick from
//! power-on (the same options), `similar-check` Axel's moves in the catalogue's scenarios and
//! `round-check` round 1's scenes from power-on (`-Drom=ROM -Dremaster=DIR|AGENT`);
//! `variants-check` plays each variant's flow from power-on on the ROM's content (`-Drom=ROM`), and
//! `netplay-check` network play's flows on it (the joins, leaving, a dropped connection, a
//! difference named; two agent hosts over WebSockets).
const std = @import("std");

/// The SDL2 release that the Linux host is built and tested against.
pub const pinned_sdl_version = "2.32.4";

/// The SDL2 release that a Windows build links: the `sdl2` package of build.zig.zon,
/// allyourcodebase's SDL2 built from source by Zig. Keep it with the package's version.
pub const package_sdl_version = "2.32.10";

const SdlLinkage = enum { static, dynamic };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdl_linkage = b.option(SdlLinkage, "sdl-linkage", "Link the system SDL2 as a static archive or as a shared library (default: static). A Windows build always links its SDL2 statically") orelse .static;

    const versions = b.addOptions();
    // The build's identity, which network play's handshake compares (DESIGN.md 9): the source's
    // commit, as the native and the browser builds of one tree share it.
    versions.addOption([]const u8, "build", buildIdentity(b));

    // Shared code: the platform contract, in-memory providers, the game. No host library, no libc.
    const shared = b.addModule("sorz", .{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared.addOptions("build_versions", versions);

    // The extractor (src/extract): the one module that reads the user's ROM, into the content
    // tree. Native hosts and tools import it; the browser build never does.
    const extract = b.addModule("extract", .{
        .root_source_file = b.path("src/extract/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sorz", .module = shared }},
    });

    // Native I/O: the directory asset source and the directory storage over std.Io, a ROM's
    // content extracted in memory, and the WebSocket transport of network play. The executables
    // import it; `sorz` never does.
    const native = b.addModule("native", .{
        .root_source_file = b.path("src/native/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sorz", .module = shared },
            .{ .name = "extract", .module = extract },
        },
    });

    // Agent platform: injected events, controlled time, captured output. Its network play runs
    // over the native transport too (it links nothing either).
    const agent = b.addModule("agent", .{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sorz", .module = shared },
            .{ .name = "native", .module = native },
        },
    });

    // SDL platform: the only module that links SDL2, and thus libc. It imports `native` for the
    // asset and save providers of the host, which link nothing.
    const sdl = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sorz", .module = shared },
            .{ .name = "native", .module = native },
        },
    });
    if (target.result.os.tag == .windows)
        linkPackagedSdl(b, sdl, target, versions)
    else
        linkSdl(b, sdl, sdl_linkage, versions);

    const agent_exe = b.addExecutable(.{
        .name = "sorz-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sorz", .module = shared },
                .{ .name = "agent", .module = agent },
                .{ .name = "native", .module = native },
            },
        }),
    });

    const sdl_exe = b.addExecutable(.{
        .name = "sorz-sdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdl/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sorz", .module = shared },
                .{ .name = "sdl", .module = sdl },
                .{ .name = "native", .module = native },
            },
        }),
    });

    // Server mode (DESIGN.md 9): the relay between two browsers, with no game and no library, so
    // that it runs on a machine without a display or sound (src/server/main.zig).
    const server_exe = b.addExecutable(.{
        .name = "sorz-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sorz", .module = shared },
                .{ .name = "native", .module = native },
            },
        }),
    });

    b.installArtifact(agent_exe);
    b.installArtifact(sdl_exe);
    b.installArtifact(server_exe);

    b.step("agent", "Build and install only the headless agent host").dependOn(&b.addInstallArtifact(agent_exe, .{}).step);
    b.step("sdl", "Build and install only the SDL host").dependOn(&b.addInstallArtifact(sdl_exe, .{}).step);
    b.step("server", "Build and install only the relay server (server mode)").dependOn(&b.addInstallArtifact(server_exe, .{}).step);
    // The browser build (src/web): the shared game as a WebAssembly module for a page, with the
    // page and its script. The module links no libc, and the script gives it its memory. Every
    // game file is in memory before the game starts, so the module needs no Asyncify pass. The
    // module is built in the build's mode (-Doptimize), as the native binaries that embed it are.
    const web_step = b.step("web", "Build the browser build into <prefix>/web and check the module's imports");
    const web_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const web_shared = b.createModule(.{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = web_target,
        .optimize = optimize,
    });
    web_shared.addOptions("build_versions", versions);
    const web_module = b.addExecutable(.{
        .name = "sorz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web/main.zig"),
            .target = web_target,
            .optimize = optimize,
            // The module's debug info only in a debug build: the native binaries embed the module,
            // where `strip` cannot reach it.
            .strip = optimize != .debug,
            .imports = &.{.{ .name = "sorz", .module = web_shared }},
        }),
    });
    web_module.entry = .disabled;
    web_module.rdynamic = true;
    web_module.import_memory = true;
    // No compiler-rt (DESIGN.md 5.3): the functions of it that the game calls are imports, which
    // the script gives. The placeholder game calls one, `__multi3`, the 128-bit product in
    // `std.hash.Wyhash`. `web-check` checks the script's helpers against compiler-rt, and
    // `src/web/module_check.zig` checks the list of imports.
    web_module.bundle_compiler_rt = false;
    web_module.import_symbols = true;
    // The script reads these limits from the module's import. The stack is the size of a native
    // main thread's, because a game's values can be large.
    web_module.stack_size = 8 * 1024 * 1024;
    web_module.initial_memory = 16 * 1024 * 1024;
    web_module.max_memory = 1024 * 1024 * 1024;
    web_step.dependOn(&b.addInstallFileWithDir(web_module.getEmittedBin(), .prefix, "web/sorz.wasm").step);
    web_step.dependOn(&b.addInstallFileWithDir(b.path("src/web/index.html"), .prefix, "web/index.html").step);
    web_step.dependOn(&b.addInstallFileWithDir(b.path("src/web/sorz.js"), .prefix, "web/sorz.js").step);

    // The module's imports: its memory, the page's functions and the helpers, and nothing else.
    // The script and the module are copied next to a generated root, so `@embedFile` reaches
    // them.
    const web_files = b.addWriteFiles();
    _ = web_files.addCopyFile(b.path("src/web/sorz.js"), "sorz.js");
    _ = web_files.addCopyFile(web_module.getEmittedBin(), "sorz.wasm");
    const web_output = b.createModule(.{
        .root_source_file = web_files.add("web_output.zig",
            \\//! The browser build's script and module, for the check of the module's imports
            \\//! (generated by build.zig).
            \\pub const script_js: []const u8 = @embedFile("sorz.js");
            \\pub const module_wasm: []const u8 = @embedFile("sorz.wasm");
            \\
        ),
    });
    // The browser build built into the native binaries (`web_page`): `--netplay` and `--server`
    // serve it, with the game's files of their data, and nothing beside them.
    const page_files = b.addWriteFiles();
    _ = page_files.addCopyFile(b.path("src/web/index.html"), "index.html");
    _ = page_files.addCopyFile(b.path("src/web/sorz.js"), "sorz.js");
    _ = page_files.addCopyFile(web_module.getEmittedBin(), "sorz.wasm");
    const web_page = b.createModule(.{
        .root_source_file = page_files.add("web_page.zig",
            \\//! The browser build's page, script and module, built into the native binaries that
            \\//! serve them (generated by build.zig).
            \\pub const index_html: []const u8 = @embedFile("index.html");
            \\pub const script_js: []const u8 = @embedFile("sorz.js");
            \\pub const module_wasm: []const u8 = @embedFile("sorz.wasm");
            \\
        ),
    });
    for ([_]*std.Build.Step.Compile{ agent_exe, sdl_exe, server_exe }) |exe| exe.root_module.addImport("web_page", web_page);

    const module_check = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/web/module_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "web_output", .module = web_output }},
    }) });
    web_step.dependOn(&b.addRunArtifact(module_check).step);

    // `web-check`: the script's helpers against compiler-rt. A probe of the operations is built
    // with compiler-rt and without it, and Node runs both over the same inputs, the second with
    // the helpers of `sorz.js`.
    const web_check_step = b.step("web-check", "Check the browser build's helper functions against compiler-rt, and the page script's parts that need no browser (needs Node.js)");
    const helpers_check = b.addSystemCommand(&.{"node"});
    helpers_check.addFileArg(b.path("src/web/helpers_check.cjs"));
    helpers_check.addFileArg(b.path("src/web/sorz.js"));
    for ([_]bool{ true, false }) |with_compiler_rt| {
        const probe = b.addExecutable(.{
            .name = if (with_compiler_rt) "probe-compiler-rt" else "probe-helpers",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/web/helpers_probe.zig"),
                .target = web_target,
                .optimize = optimize,
            }),
        });
        probe.entry = .disabled;
        probe.rdynamic = true;
        probe.import_memory = true;
        probe.bundle_compiler_rt = with_compiler_rt;
        probe.import_symbols = !with_compiler_rt;
        probe.initial_memory = 2 * 1024 * 1024;
        probe.max_memory = 2 * 1024 * 1024;
        helpers_check.addFileArg(probe.getEmittedBin());
    }
    web_check_step.dependOn(&helpers_check.step);
    // And the parts of the page's script and of the module that need no browser and no game data:
    // the listing of the game's files its server sends, the transport of network play over a
    // stand-in WebSocket, the ownership of the data given to the module, its memory's growth, its
    // refusals, its screens without their files, and a game started on a file.
    const page_check = b.addSystemCommand(&.{"node"});
    page_check.addFileArg(b.path("src/web/page_check.cjs"));
    page_check.addFileArg(b.path("src/web/sorz.js"));
    page_check.addFileArg(web_module.getEmittedBin());
    web_check_step.dependOn(&page_check.step);

    // The parts of the browser build that run without a browser, for the unit tests.
    const web_parts = b.createModule(.{
        .root_source_file = b.path("src/web/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sorz", .module = shared }},
    });

    // The extractor as a tool (not installed): `extract` writes the content tree of the user's
    // ROM, `extract-check` extracts it twice and checks the two are byte-identical and load.
    // Both need `-Drom=PATH`; no build or test reads a ROM without it.
    const extract_exe = b.addExecutable(.{
        .name = "sorz-extract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/extract/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sorz", .module = shared },
                .{ .name = "extract", .module = extract },
            },
        }),
    });
    const rom_path = b.option([]const u8, "rom", "The user's ROM, for the extract and extract-check steps");
    const content_dir = b.option([]const u8, "content", "Where the extract step writes the content tree (default: <prefix>/content)");
    const extract_step = b.step("extract", "Write the content tree of the ROM -Drom=PATH into -Dcontent=DIR");
    const extract_check_step = b.step("extract-check", "Extract the ROM -Drom=PATH twice: the trees must be byte-identical and load");
    // The gate of PLAN 06: the art against sor-remaster's exported tree (its `--export-assets`).
    const remaster_tree = b.option([]const u8, "remaster-tree", "sor-remaster's exported asset tree, for the extract-compare step");
    const extract_compare_step = b.step("extract-compare", "Compare the art of -Drom=PATH with sor-remaster's exported tree -Dremaster-tree=DIR");
    if (rom_path != null and remaster_tree != null) {
        const compare_tree = b.addRunArtifact(extract_exe);
        compare_tree.addArgs(&.{ "--compare", rom_path.?, remaster_tree.? });
        compare_tree.has_side_effects = true;
        extract_compare_step.dependOn(&compare_tree.step);
    } else {
        extract_compare_step.dependOn(&b.addFail("the extract-compare step needs -Drom=PATH and -Dremaster-tree=DIR").step);
    }
    if (rom_path) |rom| {
        const write_tree = b.addRunArtifact(extract_exe);
        write_tree.addArg(rom);
        if (content_dir) |dir| {
            write_tree.addArg(dir);
        } else {
            write_tree.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "content" } }, .{ .make_absolute = true });
        }
        write_tree.has_side_effects = true;
        extract_step.dependOn(&write_tree.step);
        const check_tree = b.addRunArtifact(extract_exe);
        check_tree.addArgs(&.{ "--check", rom });
        check_tree.has_side_effects = true;
        extract_check_step.dependOn(&check_tree.step);
    } else {
        const missing = b.addFail("the extract steps need the user's ROM: -Drom=PATH");
        extract_step.dependOn(&missing.step);
        extract_check_step.dependOn(&missing.step);
    }

    // `variants-check`, the gate of the variants (PLAN item 19, src/tools/variants_check.zig): each
    // variant's flow from power-on on the ROM's content, as the hosts run it, its steps checked.
    const variants_check_step = b.step("variants-check", "Play each variant's flow from power-on on the content of -Drom=ROM, its steps checked");
    if (rom_path) |rom| {
        const variants_exe = b.addExecutable(.{
            .name = "sorz-variants-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/variants_check.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sorz", .module = shared },
                    .{ .name = "agent", .module = agent },
                    .{ .name = "extract", .module = extract },
                },
            }),
        });
        const check = b.addRunArtifact(variants_exe);
        check.addArg(rom);
        check.has_side_effects = true;
        variants_check_step.dependOn(&check.step);
    } else {
        variants_check_step.dependOn(&b.addFail("variants-check needs the user's ROM: -Drom=PATH").step);
    }

    // `sound-check`: the sound against sor-remaster's driver (PLAN 09), from the user's ROM and a
    // sor-remaster checkout, which is built as a library and never written to. Optimised, as it
    // plays every song for minutes.
    const sound_check_step = b.step("sound-check", "Compare the sound with sor-remaster's (needs -Drom=ROM -Dremaster=DIR)");
    const remaster = b.option([]const u8, "remaster", "A sor-remaster checkout, the reference of sound-check, screens-check and similar-check (for similar-check, its built agent will do)");
    const sound_only = b.option([]const u8, "sound-only", "One group of sound-check's scenarios: songs, round6, effects, pairs, changes, fades, pauses, stops, voices, quirks, pcm, random; or bench, the sequencer's cost");
    const sound_tree = b.option([]const u8, "sound-tree", "Where sound-check writes the sound content's files, for reading");
    const sound_optimize = b.option(std.builtin.OptimizeMode, "sound-check-optimize", "The build mode of sound-check (default: fast; debug to measure the bench in a debug build)") orelse .fast;
    if (rom_path != null and remaster != null) {
        const run = soundCheck(b, target, sound_optimize, versions, rom_path.?, remaster.?);
        if (sound_only) |o| run.addArgs(&.{ "--only", o });
        if (sound_tree) |t| run.addArgs(&.{ "--tree", t });
        sound_check_step.dependOn(&run.step);
    } else {
        sound_check_step.dependOn(&b.addFail("sound-check needs -Drom=ROM and -Dremaster=DIR").step);
    }

    // The renderer's checks (src/tools/render_check.zig, not installed): `render-bench` times the
    // composition of a synthetic frame; `render-check` composes screens from the content of the
    // ROM -Drom=PATH into PNG pictures in -Drender-out=DIR (default <prefix>/render), and compares
    // them with sor-remaster's pictures in -Dremaster-shots=DIR when given.
    const render_check_exe = b.addExecutable(.{
        .name = "sorz-render-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/render_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sorz", .module = shared },
                .{ .name = "extract", .module = extract },
            },
        }),
    });
    const render_bench = b.addRunArtifact(render_check_exe);
    render_bench.addArg("--bench");
    render_bench.has_side_effects = true;
    b.step("render-bench", "Time the composition of a synthetic frame").dependOn(&render_bench.step);
    const render_out = b.option([]const u8, "render-out", "Where render-check writes its pictures (default: <prefix>/render)");
    const remaster_shots = b.option([]const u8, "remaster-shots", "sor-remaster's pictures for render-check to compare with");
    const render_check_step = b.step("render-check", "Compose screens from the content of -Drom=PATH into pictures, compared with -Dremaster-shots=DIR");
    if (rom_path) |rom| {
        const pictures = b.addRunArtifact(render_check_exe);
        pictures.addArg(rom);
        if (render_out) |dir| {
            pictures.addArg(dir);
        } else {
            pictures.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "render" } }, .{ .make_absolute = true });
        }
        if (remaster_shots) |dir| pictures.addArg(dir);
        pictures.has_side_effects = true;
        render_check_step.dependOn(&pictures.step);
    } else {
        render_check_step.dependOn(&b.addFail("the render-check step needs the user's ROM: -Drom=PATH").step);
    }

    // `screens-check`, the gate of the screens (PLAN 08, src/tools/screens_check.zig): sorz's
    // pictures and sound against sor-remaster's at the same ticks from power-on with the same
    // keys. sor-remaster's agent is built from its checkout (-Dremaster=DIR, never written to:
    // its cache and its prefix are this build's), optimised.
    const screens_out = b.option([]const u8, "screens-out", "Where screens-check writes the pictures it compares (default: <prefix>/screens)");
    const screens_only = b.option([]const u8, "screens-only", "The scenarios screens-check runs, separated by commas (default: all)");
    const screens_check_step = b.step("screens-check", "Compare the screens' pictures and sound with sor-remaster's (needs -Drom=ROM -Dremaster=DIR)");
    if (rom_path != null and remaster != null) {
        const screens_exe = b.addExecutable(.{
            .name = "sorz-screens-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/screens_check.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sorz", .module = shared },
                    .{ .name = "agent", .module = agent },
                    .{ .name = "extract", .module = extract },
                },
            }),
        });
        const reference = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "agent", "-Doptimize=ReleaseFast", "--prefix" });
        const reference_prefix = reference.addOutputDirectoryArg("remaster");
        reference.addArg("--cache-dir");
        reference.addDirectoryArg2(.{ .relative = .{ .base = .local_cache } }, .{ .make_absolute = true });
        reference.setCwd(.{ .cwd_relative = remaster.? });
        reference.has_side_effects = true;
        const check = b.addRunArtifact(screens_exe);
        check.addArg(rom_path.?);
        check.addDirectoryArg(reference_prefix);
        if (screens_out) |dir| {
            check.addArg(dir);
        } else {
            check.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "screens" } }, .{ .make_absolute = true });
        }
        if (screens_only) |names| {
            var it = std.mem.tokenizeScalar(u8, names, ',');
            while (it.next()) |n| check.addArg(n);
        }
        check.has_side_effects = true;
        screens_check_step.dependOn(&check.step);
    } else {
        screens_check_step.dependOn(&b.addFail("screens-check needs -Drom=ROM and -Dremaster=DIR").step);
    }

    // `similar-check`, the gate of the players' moves (PLAN items 05, 11 and 14,
    // src/tools/similar_check.zig): the catalogue's scenarios of Axel, Adam and Blaze, and the two
    // players' (tests/scenarios/axel, adam, blaze, two), run in sor-remaster and in sorz, their
    // traces, probes and measurements compared move by move. -Dremaster is sor-remaster's
    // checkout (its agent built as screens-check builds it) or an agent already built.
    const similar_out = b.option([]const u8, "similar-out", "Where similar-check writes its runs and report (default: <prefix>/similar)");
    const similar_only = b.option([]const u8, "similar-only", "The scenarios similar-check runs, separated by commas (default: all)");
    // With the recorded play of round 1 (the catalogue's game.pads), similar-check compares the
    // enemies and the items too (PLAN item 12, src/tools/similar_enemies.zig).
    const similar_pads = b.option([]const u8, "pads", "The recorded play of round 1 (game.pads): similar-check then compares the enemies and the items in tests/scenarios/enemies");
    const similar_every = b.option(u32, "similar-every", "similar-check runs every N-th run of the enemies' families (default 1: all)");
    const similar_jobs = b.option(u32, "similar-jobs", "similar-check runs sor-remaster this many times at once for the enemies (default 4)");
    const similar_check_step = b.step("similar-check", "Compare the players' moves with sor-remaster's in the catalogue's scenarios (needs -Drom=ROM -Dremaster=DIR|AGENT)");
    const similar_module = b.createModule(.{
        .root_source_file = b.path("src/tools/similar_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sorz", .module = shared },
            .{ .name = "agent", .module = agent },
            .{ .name = "extract", .module = extract },
        },
    });
    if (rom_path != null and remaster != null) {
        const similar_exe = b.addExecutable(.{ .name = "sorz-similar-check", .root_module = similar_module });
        const check = b.addRunArtifact(similar_exe);
        check.addArg(rom_path.?);
        if (std.Io.Dir.cwd().openDir(b.graph.io, remaster.?, .{})) |dir| {
            dir.close(b.graph.io);
            const reference = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "agent", "-Doptimize=ReleaseFast", "--prefix" });
            const reference_prefix = reference.addOutputDirectoryArg("remaster");
            reference.addArg("--cache-dir");
            reference.addDirectoryArg2(.{ .relative = .{ .base = .local_cache } }, .{ .make_absolute = true });
            reference.setCwd(.{ .cwd_relative = remaster.? });
            reference.has_side_effects = true;
            check.addFileArg(reference_prefix.path(b, "bin/sorz-agent"));
        } else |_| check.addArg(remaster.?);
        check.addDirectoryArg(b.path("tests/scenarios"));
        if (similar_out) |dir| {
            check.addArg(dir);
        } else {
            check.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "similar" } }, .{ .make_absolute = true });
        }
        if (similar_pads) |pads| {
            check.addArg("--pads");
            check.addFileArg(.{ .cwd_relative = pads });
            check.addArg("--enemies");
            check.addDirectoryArg(b.path("tests/scenarios/enemies"));
            if (similar_every) |n| check.addArgs(&.{ "--every", b.fmt("{d}", .{n}) });
            if (similar_jobs) |n| check.addArgs(&.{ "--jobs", b.fmt("{d}", .{n}) });
        }
        if (similar_only) |names| {
            var it = std.mem.tokenizeScalar(u8, names, ',');
            while (it.next()) |n| check.addArg(n);
        }
        check.has_side_effects = true;
        similar_check_step.dependOn(&check.step);
    } else {
        similar_check_step.dependOn(&b.addFail("similar-check needs -Drom=ROM and -Dremaster=DIR|AGENT").step);
    }

    // `round-check`, the gate of round 1's scene (PLAN item 13, src/tools/round_check.zig): round
    // 1's scenarios (tests/scenarios/round1) run from power-on in sor-remaster and in sorz, their
    // round scenes' traces compared. -Dremaster as for similar-check.
    const round_out = b.option([]const u8, "round-out", "Where round-check writes its runs and report (default: <prefix>/round)");
    const round_only = b.option([]const u8, "round-only", "The scenarios round-check runs, separated by commas (default: all)");
    const round_reach = b.option([]const u8, "round-reach", "Scenario files round-check also runs to report how far they stay equal (a recorded play's), separated by commas");
    const round_reach_min = b.option([]const u8, "round-reach-min", "The floors of -Dround-reach's runs, TRACE,FRAMES,SOUND (round ticks, round ticks, display ticks; one left empty is none): a run below one fails");
    const round_check_step = b.step("round-check", "Compare round 1's scenes with sor-remaster's from power-on (needs -Drom=ROM -Dremaster=DIR|AGENT)");
    const round_module = b.createModule(.{
        .root_source_file = b.path("src/tools/round_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sorz", .module = shared },
            .{ .name = "agent", .module = agent },
            .{ .name = "extract", .module = extract },
        },
    });
    if (rom_path != null and remaster != null) {
        const round_exe = b.addExecutable(.{ .name = "sorz-round-check", .root_module = round_module });
        const check = b.addRunArtifact(round_exe);
        check.addArg(rom_path.?);
        if (std.Io.Dir.cwd().openDir(b.graph.io, remaster.?, .{})) |dir| {
            dir.close(b.graph.io);
            const reference = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "agent", "-Doptimize=ReleaseFast", "--prefix" });
            const reference_prefix = reference.addOutputDirectoryArg("remaster");
            reference.addArg("--cache-dir");
            reference.addDirectoryArg2(.{ .relative = .{ .base = .local_cache } }, .{ .make_absolute = true });
            reference.setCwd(.{ .cwd_relative = remaster.? });
            reference.has_side_effects = true;
            check.addFileArg(reference_prefix.path(b, "bin/sorz-agent"));
        } else |_| check.addArg(remaster.?);
        check.addDirectoryArg(b.path("tests/scenarios/round1"));
        if (round_out) |dir| {
            check.addArg(dir);
        } else {
            check.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "round" } }, .{ .make_absolute = true });
        }
        if (round_only) |names| {
            var it = std.mem.tokenizeScalar(u8, names, ',');
            while (it.next()) |n| check.addArg(n);
        }
        if (round_reach) |files| {
            var it = std.mem.tokenizeScalar(u8, files, ',');
            while (it.next()) |path| check.addArgs(&.{ "--reach", path });
            if (round_reach_min) |floors| check.addArgs(&.{ "--reach-min", floors });
        }
        check.has_side_effects = true;
        round_check_step.dependOn(&check.step);
    } else {
        round_check_step.dependOn(&b.addFail("round-check needs -Drom=ROM and -Dremaster=DIR|AGENT").step);
    }

    // Unit tests of every module. The tests of the SDL module link SDL2 as the host does.
    const test_step = b.step("test", "Run the unit tests of every module");
    const unit_modules = [_]*std.Build.Module{ shared, agent, native, sdl, web_parts, extract, similar_module, round_module };
    for (unit_modules) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // The engine's rule against the console's terms (DESIGN.md P1, PLAN item 03): the engine's
    // sources (src/shared) name no address and no term of the console, but those that the
    // allow-list gives (tools/engine_terms.zig). It reads the sources each time, so it always runs.
    const terms_tool = b.addExecutable(.{
        .name = "engine-terms",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/engine_terms.zig"), .target = b.graph.host, .optimize = .debug }),
    });
    const terms = b.addRunArtifact(terms_tool);
    terms.setCwd(b.path("."));
    terms.addArgs(&.{ "src/shared", "tools/engine_terms.allow" });
    terms.expectExitCode(0);
    terms.has_side_effects = true;
    test_step.dependOn(&terms.step);
    const terms_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tools/engine_terms.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(terms_tests).step);

    // The agent host for a few frames, its keys moving a marker of the test pattern; then the
    // settings record read at the start, and damaged records (tools/check_settings.sh). It needs
    // no game files and no display.
    const smoke_step = b.step("smoke", "Run the agent host for a few frames, and the settings record across starts");
    const smoke = b.addRunArtifact(agent_exe);
    smoke.addArgs(&.{ "--frames", "60", "--key", "10:right:20", "--key", "20:x:5" });
    smoke.expectExitCode(0);
    smoke_step.dependOn(&smoke.step);
    const settings_check = b.addSystemCommand(&.{ "sh", "tools/check_settings.sh" });
    settings_check.addArtifactArg(agent_exe);
    settings_check.expectExitCode(0);
    settings_check.has_side_effects = true;
    smoke_step.dependOn(&settings_check.step);

    // Network play on the real game (PLAN item 18), from the user's ROM: its flows with several
    // games in one process (src/tools/netplay_check.zig: each machine's own menus, the joins at the
    // select and mid-round, a guest leaving and another joining, a third turned away, a dropped
    // connection, a planted difference named), and two agent hosts over WebSockets
    // (tools/check_netplay.sh: the host alone into round 1, the guest joining mid-round, the same
    // state). `-Dnetplay-only=FLOW,...` runs some of the flows.
    const netplay_check_step = b.step("netplay-check", "Play network play's flows on the content of -Drom=ROM: own menus, joins at the select and mid-round, leaving, a dropped connection, a planted difference; two agent hosts over WebSockets");
    const netplay_only = b.option([]const u8, "netplay-only", "netplay-check: the flows to run (comma-separated: own_menus, select, round, away, difference)");
    if (rom_path) |rom| {
        const netplay_exe = b.addExecutable(.{
            .name = "sorz-netplay-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/netplay_check.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sorz", .module = shared },
                    .{ .name = "agent", .module = agent },
                    .{ .name = "extract", .module = extract },
                },
            }),
        });
        const flows = b.addRunArtifact(netplay_exe);
        flows.addArg(rom);
        if (netplay_only) |list| {
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |name| if (name.len != 0) flows.addArg(name);
        }
        flows.has_side_effects = true;
        netplay_check_step.dependOn(&flows.step);
        if (netplay_only == null) {
            const netplay_check = b.addSystemCommand(&.{ "sh", "tools/check_netplay.sh" });
            netplay_check.addArtifactArg(agent_exe);
            netplay_check.addArg(rom);
            netplay_check.expectExitCode(0);
            netplay_check.has_side_effects = true;
            netplay_check_step.dependOn(&netplay_check.step);
        }
    } else {
        netplay_check_step.dependOn(&b.addFail("netplay-check needs the user's ROM: -Drom=PATH").step);
    }

    // The browser build in Chromium against the agent host (src/web/browser_check.mjs), the pages
    // served by native programs with the game's files of a game directory that the check makes:
    // the page without files, its text from the loading to the menu, the game's frames and sound
    // compared tick by tick with the agent host's, a settings record applied, the game as the
    // player runs it, a hidden page, the keyboard, a gamepad, network play with the agent host as
    // the host, and two pages through the relay (`sorz-server DIR --server`) and its rules; with
    // -Drom=PATH, the page's screens drawn by the module from the ROM's content. It needs Node.js
    // and a Chromium, so it is not part of `test`; build it optimised (-Doptimize=ReleaseFast) for
    // its real-time parts.
    const chromium = b.option([]const u8, "chromium", "The Chromium that browser-check drives (default: $CHROME, else chromium or chrome on the PATH)");
    const browser_check_step = b.step("browser-check", "Run the browser build in Chromium against the agent host, and two pages through the relay (needs Node.js and a Chromium)");
    {
        // The page's three files, as `web` installs them.
        const page = b.addWriteFiles();
        _ = page.addCopyFile(web_module.getEmittedBin(), "sorz.wasm");
        _ = page.addCopyFile(b.path("src/web/index.html"), "index.html");
        _ = page.addCopyFile(b.path("src/web/sorz.js"), "sorz.js");
        const run = b.addSystemCommand(&.{"node"});
        run.addFileArg(b.path("src/web/browser_check.mjs"));
        run.addArg("--web");
        run.addDirectoryArg(page.getDirectory());
        run.addArg("--agent");
        run.addArtifactArg(agent_exe);
        run.addArg("--server");
        run.addArtifactArg(server_exe);
        if (chromium) |path| run.addArgs(&.{ "--chromium", path });
        // With the user's ROM, the page's screens too, drawn by the module from its content.
        if (rom_path) |rom| {
            const tree = b.addRunArtifact(extract_exe);
            tree.addArg(rom);
            const content = tree.addOutputDirectoryArg("content");
            run.addArg("--content");
            run.addDirectoryArg(content);
        }
        run.step.dependOn(web_step);
        run.has_side_effects = true;
        browser_check_step.dependOn(&run.step);
    }

    // The agent and server binaries must have no SDL dependency.
    const verify_step = b.step("verify", "Check that the agent host and the relay server link no SDL library, and that each executable alone serves its page");
    for ([_]*std.Build.Step.Compile{ agent_exe, server_exe }) |exe| {
        const no_sdl = b.addSystemCommand(&.{ "sh", "tools/check_no_sdl.sh" });
        no_sdl.addArtifactArg(exe);
        no_sdl.expectExitCode(0);
        verify_step.dependOn(&no_sdl.step);
    }
    // Each executable, copied alone into an empty directory, serves the browser build built into
    // it with `--server` (DESIGN.md 1, PLAN S1). A Windows build is not run here.
    if (target.result.os.tag != .windows) {
        for ([_]*std.Build.Step.Compile{ agent_exe, sdl_exe, server_exe }) |exe| {
            const alone = b.addSystemCommand(&.{ "sh", "tools/check_alone.sh" });
            alone.addDirectoryArg(page_files.getDirectory());
            alone.addArtifactArg(exe);
            alone.expectExitCode(0);
            alone.has_side_effects = true;
            verify_step.dependOn(&alone.step);
        }
    }

    // `all`: every binary of the target and of Windows, and the browser build. The Windows binaries come from a second build for the
    // Windows target, run by this step alone, into <prefix>/windows: a build of any other step
    // never asks for the SDL2 package, which only a Windows build fetches.
    const all_step = b.step("all", "Build and install every binary: the target's, Windows's under <prefix>/windows, and the browser build");
    all_step.dependOn(b.getInstallStep());
    all_step.dependOn(web_step);
    if (target.result.os.tag != .windows) {
        const windows = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "install", "-Dtarget=x86_64-windows-gnu" });
        windows.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
        // The paths of this build, which only the make phase knows: its prefix and its cache. The
        // global cache comes with the environment.
        const absolute: std.Build.Step.Run.PathArgOptions = .{ .make_absolute = true };
        windows.addArg("--prefix");
        windows.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "windows" } }, absolute);
        windows.addArg("--cache-dir");
        windows.addDirectoryArg2(.{ .relative = .{ .base = .local_cache } }, absolute);
        windows.setCwd(b.path("."));
        windows.has_side_effects = true;
        all_step.dependOn(&windows.step);
    }
}

/// The source's commit (`git describe`), or "unknown" out of a git checkout. Two builds of one
/// commit give the same text, whatever they build.
fn buildIdentity(b: *std.Build) []const u8 {
    // The configure phase is cached: it runs again when the checkout's HEAD moves, which its
    // reflog records (a commit, a checkout, a rebase). Local changes are not in the identity:
    // they would need every source file here, and the session's state checks catch a build
    // that plays differently.
    var code: u8 = 0;
    // The checkout's git directory: `.git`, or another for a worktree, whose `.git` is a file.
    if (b.runAllowFail(&.{ "git", "rev-parse", "--absolute-git-dir" }, &code, .ignore)) |dir| {
        const reflog = b.fmt("{s}/logs/HEAD", .{std.mem.trim(u8, dir, " \t\r\n")});
        if (std.Io.Dir.cwd().access(b.graph.io, reflog, .{})) |_| {
            // By contents: this Zig does not check a dependency by metadata yet.
            b.dependOnFileContents(.{ .cwd_relative = reflog });
        } else |_| {}
    } else |_| {}
    // The build runs in the source tree, so git finds its checkout.
    const out = b.runAllowFail(&.{ "git", "describe", "--always", "--abbrev=12", "--exclude=*" }, &code, .ignore) catch return "unknown";
    const text = std.mem.trim(u8, out, " \t\r\n");
    return if (text.len == 0 or text.len > 32) "unknown" else text;
}

/// The run of the sound check (tests/sound/check.zig): its own optimised copies of `sorz` and the
/// extractor, and sor-remaster's shared module as `remaster`.
fn soundCheck(b: *std.Build, target: std.Build.ResolvedTarget, fast: std.builtin.OptimizeMode, versions: *std.Build.Step.Options, rom: []const u8, remaster: []const u8) *std.Build.Step.Run {
    const shared = b.createModule(.{ .root_source_file = b.path("src/shared/root.zig"), .target = target, .optimize = fast });
    shared.addOptions("build_versions", versions);
    const extract = b.createModule(.{
        .root_source_file = b.path("src/extract/root.zig"),
        .target = target,
        .optimize = fast,
        .imports = &.{.{ .name = "sorz", .module = shared }},
    });
    const reference_versions = b.addOptions();
    reference_versions.addOption([]const u8, "build", "reference");
    reference_versions.addOption([]const u8, "sdl", "none");
    const reference = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ remaster, "src/shared/root.zig" }) },
        .target = target,
        .optimize = fast,
    });
    reference.addOptions("build_versions", reference_versions);
    reference.addImport("vector_files", b.createModule(.{ .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ remaster, "tests/vectors/files.zig" }) } }));
    const exe = b.addExecutable(.{
        .name = "sound-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sound/check.zig"),
            .target = target,
            .optimize = fast,
            .imports = &.{
                .{ .name = "sorz", .module = shared },
                .{ .name = "extract", .module = extract },
                .{ .name = "remaster", .module = reference },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    run.addArg(rom);
    run.has_side_effects = true;
    return run;
}

/// Links SDL2 into `m`, and records the SDL2 version that pkg-config reports as the `sdl` build
/// option. Static linkage uses the archive that pkg-config names and the system libraries of its
/// static link line. Those libraries stay dynamic, because static builds of X11, Wayland or
/// PulseAudio are not practical. Dynamic linkage uses the shared library.
fn linkSdl(b: *std.Build, m: *std.Build.Module, linkage: SdlLinkage, versions: *std.Build.Step.Options) void {
    var code: u8 = 0;
    if (b.runAllowFail(&.{ "pkg-config", "--modversion", "sdl2" }, &code, .ignore)) |out| {
        const found = std.mem.trim(u8, out, " \t\r\n");
        versions.addOption([]const u8, "sdl", found);
    } else |_| {
        std.log.warn("pkg-config could not report the SDL2 version; the pin ({s}) is checked at run time only", .{pinned_sdl_version});
        versions.addOption([]const u8, "sdl", "unknown");
    }

    switch (linkage) {
        .dynamic => m.linkSystemLibrary("SDL2", .{}),
        .static => {
            const libdir_out = b.runAllowFail(&.{ "pkg-config", "--variable=libdir", "sdl2" }, &code, .ignore) catch {
                std.log.err("static SDL2 linkage needs pkg-config to locate libSDL2.a; use -Dsdl-linkage=dynamic", .{});
                std.process.exit(1);
            };
            const libdir = std.mem.trim(u8, libdir_out, " \t\r\n");
            m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libSDL2.a", .{libdir}) });
            const libs_out = b.runAllowFail(&.{ "pkg-config", "--static", "--libs", "sdl2" }, &code, .ignore) catch {
                std.log.err("pkg-config --static --libs sdl2 failed; use -Dsdl-linkage=dynamic", .{});
                std.process.exit(1);
            };
            var it = std.mem.tokenizeAny(u8, libs_out, " \t\r\n");
            while (it.next()) |flag| {
                if (std.mem.eql(u8, flag, "-lSDL2")) continue;
                if (std.mem.eql(u8, flag, "-pthread")) continue;
                if (std.mem.startsWith(u8, flag, "-l")) {
                    m.linkSystemLibrary(flag[2..], .{ .use_pkg_config = .no });
                } else if (std.mem.startsWith(u8, flag, "-L")) {
                    m.addLibraryPath(.{ .cwd_relative = b.dupe(flag[2..]) });
                }
            }
        },
    }
}

/// A Windows build: SDL2 compiled from source by Zig for the target (the `sdl2` package), linked
/// statically with the Windows libraries that it needs. The package is fetched on the first Windows
/// build; Linux builds never fetch it. SDL is optimised whatever the game's mode, as the system
/// library of a Linux build is.
fn linkPackagedSdl(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget, versions: *std.Build.Step.Options) void {
    versions.addOption([]const u8, "sdl", package_sdl_version);
    const dep = b.lazyDependency("sdl2", .{ .target = target, .optimize = .ReleaseFast }) orelse return;
    m.linkLibrary(dep.artifact("SDL2"));
}

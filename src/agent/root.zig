//! The agent platform: a backend with scripted devices, a controlled clock and captured output. A
//! port drives its game through it to test and to debug without a window: the same input gives the
//! same frames on every machine. A port grows a driver on top of it for its tests (DESIGN.md).
pub const AgentBackend = @import("backend.zig").AgentBackend;
/// The pictures that `--shot` writes.
pub const png = @import("png.zig");
/// Network play in the agent host: a session over WebSockets, or two games in one process.
pub const netplay_cmd = @import("netplay_cmd.zig");
/// Scenarios: a converted start, then a script of pad events; their traces and probes.
pub const scenario = @import("scenario.zig");
pub const scenario_cmd = @import("scenario_cmd.zig");
/// The sound a run played, as a WAV file.
pub const wav = @import("wav.zig");
/// A scenario from power-on: the whole game, its start through the screens.
pub const game_run = @import("game_run.zig");
/// The comparison of two semantic traces, carried over from sor-remaster.
pub const trace_compare = @import("trace_compare.zig");

test {
    @import("std").testing.refAllDecls(@This());
    // Network play between agent hosts.
    _ = @import("netplay_test.zig");
}

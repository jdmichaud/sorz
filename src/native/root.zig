//! Native I/O: the `AssetSource` and `Storage` providers over the host file system, the contract
//! that every provider passes, and the command-line options of the native hosts. The agent and SDL
//! executables import this module. The shared `sorz` module never imports it, because the
//! shared module must stay free of host I/O.
pub const directory = @import("directory.zig");
pub const storage = @import("storage.zig");
pub const cli = @import("cli.zig");
pub const contract = @import("contract.zig");
/// The binaries' log lines on standard error.
pub const log = @import("log.zig");
/// The transport of network play: WebSocket (RFC 6455) on `std.Io.net`, and the page's files.
pub const websocket = @import("websocket.zig");
pub const net = @import("net.zig");
pub const WebSocketTransport = net.WebSocketTransport;
/// The game's files that a server gives its pages.
pub const served = @import("served.zig");
/// Server mode: the relay between two browsers (`sorz-server`).
pub const relay = @import("relay.zig");

pub const DirectoryAssetSource = directory.DirectoryAssetSource;
pub const DirectoryStorage = storage.DirectoryStorage;
pub const Providers = cli.Providers;

test {
    @import("std").testing.refAllDecls(@This());
}

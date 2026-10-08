//! The machine's own scenes over the game (DESIGN.md 10.4, S3): the settings screen, network play's
//! screens (the host's network options, a client's name entry) and the host's list of who is
//! connected, the notice that the other player of network play is in their settings, network
//! play's messages, a notice about the settings record, a gamepad's coming or going. Each is pushed over the game's scenes and holds them or
//! not by its own rule (`holds`): the settings hold the game, and so does the other player's (both
//! games of network play wait while either player is in the settings); network play's waits hold
//! it; a notice does not, nor does a gamepad's message, which fades out as it goes.
//!
//! They are this machine's, not the game's: the game's canonical state (game.zig), which both
//! machines of network play keep the same, has the scenes of the flow and their loads
//! (scene.zig); these overlays are not in it, since one machine shows the settings while the other
//! says why it waits. They take this machine's events (keys and gamepads' buttons, not the pads) and
//! are drawn over the game's last picture with the panel (panel.zig), in the game's font and the
//! colours of its menu.
const std = @import("std");
const settings_mod = @import("settings/root.zig");
const panel_mod = @import("panel.zig");

const Panel = panel_mod.Panel;
const Settings = settings_mod.Settings;
const net_screens = settings_mod.net_screens;
const netplay = @import("net/netplay.zig");

/// What the game has to tell about its settings record.
pub const Notice = enum {
    none,
    /// The record was damaged: the rest was kept, and the damaged one kept aside.
    damaged,
    /// The storage did not give the record: the defaults stand.
    unreadable,
    /// The record could not be written.
    not_saved,

    pub fn text(n: Notice) []const u8 {
        return switch (n) {
            .none => "",
            .damaged => "THE SETTINGS FILE WAS DAMAGED.",
            .unreadable => "THE SETTINGS FILE CANNOT BE READ.",
            .not_saved => "THE SETTINGS COULD NOT BE SAVED.",
        };
    }
};

/// How long a notice shows.
pub const notice_ns: u64 = 5 * std.time.ns_per_s;

/// How long a gamepad's message shows, and the fade out of its last part.
pub const gamepad_ns: u64 = 3 * std.time.ns_per_s;
pub const gamepad_fade_ns: u64 = std.time.ns_per_s;

/// What network play tells this machine's player (DESIGN.md 9), in the game's words.
pub const Message = enum {
    /// The guest's player chose and waits for the host's game.
    waiting_for_player_1,
    /// The client asked to join or to watch; the host's game is on its way.
    joining,
    /// The client's connection to its host is down: the game holds.
    player_1_away,
    /// Player 2's connection is down: the game holds, counting down the seconds before it leaves.
    player_2_away,
    /// The other player left: this one plays on, or goes back to its menu (notices).
    player_1_left,
    player_2_left,
    /// The host has as many clients as it takes (a notice).
    busy,
    /// The other machine plays another build or other game data (a notice).
    other_game,
    /// The two games differ: the session stopped, and the game with it.
    desynced,
    /// The host cannot listen at its port (a notice).
    cannot_host,

    pub fn text(m: Message) []const u8 {
        return switch (m) {
            .waiting_for_player_1 => "WAITING FOR PLAYER 1",
            .joining => "JOINING",
            .player_1_away => "PLAYER 1 CANNOT BE REACHED\nWAITING",
            .player_2_away => "PLAYER 2 DISCONNECTED",
            .player_1_left => "PLAYER 1 LEFT",
            .player_2_left => "PLAYER 2 LEFT",
            .busy => "THE HOST HAS NO ROOM FOR YOU",
            .other_game => "THE OTHER GAME IS NOT THIS ONE",
            .desynced => "THE TWO GAMES DIFFER\nTHE GAME STOPPED",
            .cannot_host => "THIS MACHINE CANNOT HOST\nITS PORT IS TAKEN",
        };
    }

    /// Its text with its count of `seconds` (player 2's dropped connection's), in `buf`.
    pub fn textWith(m: Message, seconds: u8, buf: *[64]u8) []const u8 {
        if (m != .player_2_away) return m.text();
        return std.fmt.bufPrint(buf, "{s}\nWAIT FOR {d} SEC", .{ m.text(), seconds }) catch m.text();
    }

    /// Whether the game waits under it; else it is a notice, which goes after `notice_ns`.
    pub fn holds(m: Message) bool {
        return switch (m) {
            .waiting_for_player_1, .joining, .player_1_away, .player_2_away, .desynced => true,
            .player_1_left, .player_2_left, .busy, .other_game, .cannot_host => false,
        };
    }
};

pub const Kind = enum { settings, net_options, name_entry, peer_settings, network, notice, gamepad, roster };

/// The host's list of who is connected: its own player, then its clients.
pub const Roster = struct {
    entries: [8]netplay.Entry = undefined,
    len: u8 = 0,

    pub fn eql(a: Roster, b: Roster) bool {
        if (a.len != b.len) return false;
        for (a.entries[0..a.len], b.entries[0..b.len]) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }
};

pub const Overlay = union(Kind) {
    settings: settings_mod.screen.Screen,
    net_options: net_screens.NetOptions,
    name_entry: net_screens.NameEntry,
    /// The other player (of network play) is in their settings: this player, `player` (0 or 1).
    peer_settings: u1,
    /// Network play's message, its count where it has one, and for a notice the time it goes
    /// (set when first shown).
    network: struct { what: Message, until_ns: ?u64 = null, seconds: u8 = 0 },
    /// A notice, until the time it goes (set when first shown).
    notice: struct { what: Notice, until_ns: ?u64 = null },
    /// A gamepad came, or went: its label (input.zig), until the time the message goes (set
    /// when first shown).
    gamepad: struct { label: u16, connected: bool = true, until_ns: ?u64 = null },
    /// The host's list of who is connected.
    roster: Roster,

    /// Whether it holds the game under it: no tick runs, the picture stays, the sound fades out.
    pub fn holds(o: *const Overlay) bool {
        return switch (o.*) {
            .notice, .gamepad, .roster => false,
            .network => |n| n.what.holds(),
            else => true,
        };
    }

    /// Whether the game's picture shows dimmed under it.
    pub fn dims(o: *const Overlay) bool {
        return o.* == .settings or o.* == .net_options or o.* == .name_entry;
    }

    /// Draws it on `p`. `arrow`: the settings' arrow shows (it blinks while they wait for a key).
    pub fn draw(o: *const Overlay, p: *Panel, settings: *const Settings, arrow: bool) Panel.Error!void {
        switch (o.*) {
            .settings => |*s| try s.draw(settings, p, arrow),
            .net_options => |*s| try s.draw(p, arrow),
            .name_entry => |*s| try s.draw(p, arrow),
            .peer_settings => |player| _ = try p.message(peerText(player), 11, true),
            .network => |n| {
                var buf: [64]u8 = undefined;
                _ = try p.message(n.what.textWith(n.seconds, &buf), 11, true);
            },
            .roster => |r| try drawRoster(&r, p),
            .notice => |n| {
                try p.box(1, panel_mod.rows - 5, panel_mod.columns - 2, 3);
                try p.text(3, panel_mod.rows - 4, n.what.text(), .bright);
            },
            .gamepad => |g| {
                var buf: [32]u8 = undefined;
                _ = try p.message(gamepadText(g.label, g.connected, &buf), panel_mod.rows - 4, true);
            },
        }
    }
};

/// The host's list at the bottom left: LOCAL (PLAYER 1), then each client by its name and what it
/// does.
fn drawRoster(r: *const Roster, p: *Panel) Panel.Error!void {
    const n = @as(usize, r.len) + 1;
    const top = panel_mod.rows - 1 - n;
    try p.box(0, top, 20, n);
    try p.text(1, top, "LOCAL (PLAYER 1)", .bright);
    for (r.entries[0..r.len], 1..) |e, i| {
        var buf: [24]u8 = undefined;
        const doing: []const u8 = switch (e.doing) {
            .menu => "MENU",
            .player => "PLAYER 2",
            .observing => "OBSERVING",
        };
        try p.text(1, top + i, std.fmt.bufPrint(&buf, "{s} ({s})", .{ &e.name, doing }) catch "", .dim);
    }
}

/// What a player sees while the other is in the settings, by the other player.
pub fn peerText(player: u1) []const u8 {
    return if (player == 1) "PLAYER 2 IS IN THE SETTINGS MENU" else "PLAYER 1 IS IN THE SETTINGS MENU";
}

/// A gamepad's message, by its label: it came, or went.
pub fn gamepadText(label: u16, connected: bool, buf: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "GAMEPAD {d} {s}", .{ label, if (connected) "CONNECTED" else "DISCONNECTED" }) catch unreachable;
}

/// The overlays over the game, from the bottom: one of each kind at most.
pub const Stack = struct {
    items: [std.enums.values(Kind).len]Overlay = undefined,
    len: u8 = 0,

    pub fn slice(self: *Stack) []Overlay {
        return self.items[0..self.len];
    }

    pub fn find(self: *Stack, k: Kind) ?*Overlay {
        for (self.slice()) |*o| if (o.* == k) return o;
        return null;
    }

    /// `o` on top; one already there of its kind is replaced, in its place.
    pub fn push(self: *Stack, o: Overlay) void {
        if (self.find(std.meta.activeTag(o))) |there| {
            there.* = o;
            return;
        }
        self.items[self.len] = o;
        self.len += 1;
    }

    pub fn remove(self: *Stack, k: Kind) void {
        for (self.slice(), 0..) |*o, i| if (o.* == k) {
            std.mem.copyForwards(Overlay, self.items[i .. self.len - 1], self.items[i + 1 .. self.len]);
            self.len -= 1;
            return;
        };
    }

    /// Whether any overlay holds the game.
    pub fn holds(self: *const Stack) bool {
        for (self.items[0..self.len]) |*o| if (o.holds()) return true;
        return false;
    }

    pub fn dims(self: *const Stack) bool {
        for (self.items[0..self.len]) |*o| if (o.dims()) return true;
        return false;
    }
};

test "the overlays: one of each kind, the settings hold and dim, a notice does neither" {
    var s: Stack = .{};
    s.push(.{ .notice = .{ .what = .damaged } });
    try std.testing.expect(!s.holds() and !s.dims());
    s.push(.{ .gamepad = .{ .label = 12 } });
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("GAMEPAD 12 DISCONNECTED", gamepadText(12, false, &buf));
    try std.testing.expect(!s.holds() and !s.dims());
    s.remove(.gamepad);
    s.push(.{ .peer_settings = 1 });
    try std.testing.expect(s.holds() and !s.dims());
    s.push(.{ .settings = .open(&.{}, .{}) });
    s.push(.{ .peer_settings = 0 });
    try std.testing.expectEqual(@as(u8, 3), s.len);
    try std.testing.expectEqual(@as(u1, 0), s.items[1].peer_settings);
    try std.testing.expect(s.holds() and s.dims());
    s.remove(.peer_settings);
    try std.testing.expect(s.items[1] == .settings and s.len == 2);
    s.remove(.settings);
    s.remove(.settings);
    try std.testing.expect(!s.holds() and s.len == 1);
    try std.testing.expectEqualStrings("PLAYER 2 IS IN THE SETTINGS MENU", peerText(1));
}

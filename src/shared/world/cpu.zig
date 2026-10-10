//! The CPU's play (PLAN item 30): a player's pad from what the round's world shows, the same on
//! every machine. Its presses follow the world's clock: a button pressed at a logic tick is
//! released at the next, the pad the same at both display ticks of one, as a player's read is.
//!
//! - The fight is sor-remaster's runner's bot (the agent host's `bot`): holding a foe, the knees;
//!   hurt, food lying goes first; else the nearest enemy or boss out of hiding, which it lines up
//!   with in depth, comes to the jab's reach of from across, faces, and jabs at every other tick;
//!   with none, it walks right, jabbing at a solid thing that stops it.
//! - Mr. X's offer: no.
//! - Out of lives: its name, CPU, when its score entered the high-score table; yes to the
//!   continue's question (asked only while it has continues).
//! - Never START, which would open the settings or the pause.
const std = @import("std");
const input = @import("../input.zig");
const content_screens = @import("../content/screens.zig");
const world_mod = @import("world.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const behaviours = @import("behaviours.zig");
const player_waiting = @import("behaviours/player_waiting.zig");

const World = world_mod.World;
const Actions = world_mod.Actions;
const Entity = entity.Entity;
const Kinds = kinds_mod.Kinds;
const Layout = content_screens.Layout;

/// The name the CPU enters in the high-score table.
pub const name = "CPU";

/// The rule's distances (sor-remaster's runner's): the depth within which it is level with its
/// foe, the reach it jabs from across (its jab's), the least across it keeps; the health under
/// which food comes first; how far ahead across and in depth a solid thing stops its walk.
const level = 3;
const reach = 34;
const close = 14;
const hungry = 40;
const blocked = 48;
const blocked_depth = 12;

/// Player `k`'s pad as the CPU plays it, from the world as its last logic tick left it: `letters`
/// are the name entry's (content), `layout` the buttons of the options' CONTROL.
pub fn pad(w: *const World, kinds: *const Kinds, letters: []const []const u8, layout: Layout, k: u1) input.Pad {
    const press = w.tick % 2 == 0;
    const r = &w.room;
    if (r.choosing[k] and !r.answered[k]) return padOf(if (r.on_no[k]) .{ .attack = press } else .{ .down = press }, layout);
    const e = w.getConst(w.players[k].entity orelse return .{}) orelse return .{};
    return switch (e.mind) {
        .player => if (fight(w, kinds, k, w.tick)) |p| padOf(.{ .up = p.up, .down = p.down, .left = p.left, .right = p.right, .attack = p.b }, layout) else .{},
        .player_waiting => |*m| switch (m.state) {
            .name_entry => entry(m, letters, layout, press),
            .continue_choose => padOf(if (m.cursor == .no) .{ .up = press } else .{ .attack = press }, layout),
            else => .{},
        },
        else => .{},
    };
}

/// The CPU's pad in name entry `m` (player_waiting.zig's rules), with a press if `press`: left or
/// right to its name's letter at the cursor's place, the nearer way round, then the letter taken;
/// a letter that `letters` lacks is taken as it is.
pub fn entry(m: *const player_waiting.Mind, letters: []const []const u8, layout: Layout, press: bool) input.Pad {
    const want = if (m.place < name.len) for (letters, 0..) |l, i| {
        if (l.len == 1 and l[0] == name[m.place]) break i;
    } else m.letter else m.letter;
    if (m.letter == want) return padOf(.{ .special = press }, layout);
    const n = letters.len;
    const ahead = (want + n - m.letter) % n;
    return padOf(if (ahead <= n / 2) .{ .right = press } else .{ .left = press }, layout);
}

/// The pad whose buttons give `a` by `layout`.
fn padOf(a: Actions, layout: Layout) input.Pad {
    var p: input.Pad = .{ .up = a.up, .down = a.down, .left = a.left, .right = a.right, .start = a.start };
    for ([_]struct { content_screens.Button, bool }{ .{ layout.special, a.special }, .{ layout.attack, a.attack }, .{ layout.jump, a.jump } }) |b| if (b[1]) switch (b[0]) {
        .a => p.a = true,
        .b => p.b = true,
        .c => p.c = true,
    };
    return p;
}

/// Player `k`'s pad at tick `now` by the fight's rule (the cartridge's buttons: B attacks), while
/// it is a fighter; null otherwise.
pub fn fight(w: *const World, kinds: *const Kinds, k: u1, now: u64) ?input.Pad {
    const p = w.getConst(w.players[k].entity orelse return null) orelse return null;
    if (p.mind != .player) return null;
    const px = p.position.x.whole();
    const pd = p.position.depth.whole();
    const left = p.facing == .left;
    const jab = now % 2 == 0;
    const state = behaviours.stateName(&p.mind) orelse "";
    if (std.mem.startsWith(u8, state, "grab")) return .{ .b = jab };
    var out: input.Pad = .{};
    if (p.health < hungry) if (nearest(w, kinds, px, pd, .food)) |e| {
        const dx = e.position.x.whole() - px;
        const dd = e.position.depth.whole() - pd;
        if (@abs(dd) > 2) {
            out.up = dd < 0;
            out.down = dd > 0;
        }
        if (@abs(dx) > 6) {
            out.left = dx < 0;
            out.right = dx > 0;
        }
        if (@as(u8, @bitCast(out)) == 0) out.b = jab;
        return out;
    };
    const foe = nearest(w, kinds, px, pd, .foe) orelse {
        // No foe: right, but a solid thing ahead at its depth stops the walk, and is jabbed.
        for (&w.entities) |*e| {
            if (!e.alive() or !e.flags.solid or e.flags.hidden) continue;
            const dx = e.position.x.whole() - px;
            if (dx >= 0 and dx <= blocked and @abs(e.position.depth.whole() - pd) <= blocked_depth and !left) return .{ .b = jab };
        }
        return .{ .right = true };
    };
    const dx = foe.position.x.whole() - px;
    const dd = foe.position.depth.whole() - pd;
    if (@abs(dd) > level) {
        out.up = dd < 0;
        out.down = dd > 0;
    }
    if (@abs(dx) > reach) {
        out.left = dx < 0;
        out.right = dx > 0;
    } else if (@abs(dx) < close) {
        out.right = dx < 0;
        out.left = dx >= 0;
    } else if ((dx < 0) != left) {
        out.left = dx < 0;
        out.right = dx >= 0;
    } else if (@as(u8, @bitCast(out)) == 0) out.b = jab;
    return out;
}

/// The nearest entity (across plus in depth) the rule looks for: an enemy or a boss out of
/// hiding with health left, or food lying.
fn nearest(w: *const World, kinds: *const Kinds, px: i32, pd: i32, what: enum { foe, food }) ?*const Entity {
    var best: ?*const Entity = null;
    var best_d: u32 = std.math.maxInt(u32);
    for (&w.entities) |*e| {
        if (!e.alive() or e.flags.hidden) continue;
        const k = kinds.get(e.kind.?);
        switch (what) {
            .foe => {
                const f = k.family();
                if (f != .enemy and f != .boss) continue;
                if (e.health < 0) continue;
                const now = behaviours.stateName(&e.mind) orelse "";
                if (std.mem.eql(u8, now, "appear") or std.mem.eql(u8, now, "knocked_out")) continue;
            },
            .food => if (!std.mem.eql(u8, k.name(), "apple") and !std.mem.eql(u8, k.name(), "beef")) continue,
        }
        const d = @abs(e.position.x.whole() - px) + @abs(e.position.depth.whole() - pd);
        if (d < best_d) {
            best_d = d;
            best = e;
        }
    }
    return best;
}

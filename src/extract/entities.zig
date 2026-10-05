//! The kinds of entity (docs/content.md, `entities/NAME.json`): each a definition read from the
//! ROM's tables and from the immediate values of the code that uses them, with the place of each
//! in its provenance. The players' animations are their animation sets' (graphics port map 2.7):
//! the frames with their durations (the players' lists at 0x3A30), their boxes (the players' box
//! table at 0x1ABA8, the depths at 0x1AB8E) and the power and kind of each frame's blow (the
//! table at 0x423C); the states and numbers are those of the players' code (0x1C44 to 0x5700,
//! sor-remaster's sim/player).
//!
//! A set holds each animation twice, facing right then facing left; the definition keeps the
//! first, and the box that the other uses as the box's `x_left` when it is not the mirror image.
const std = @import("std");
const sorz = @import("sorz");
const entity = sorz.content.entity;
const art = sorz.content.art;
const rom_mod = @import("rom.zig");
const sprites = @import("sprites.zig");
const sound_names = @import("sound_names.zig");
const enemies = @import("enemies.zig");
const weapons = @import("weapons.zig");
const items = @import("items.zig");

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const s16be = rom_mod.s16be;

pub const Error = error{ OutOfMemory, BadData };

pub fn s8(rom: []const u8, a: u32) i8 {
    return @bitCast(rom[a]);
}

// --- The players' tables ---------------------------------------------------------------------

/// A long per character: its animation set (0x1E0E reads it at a life's start).
const player_sets = 0x1F20;
/// A byte per player state: the state's animation, as a byte offset into the set (0x2C74).
const state_animations = 0x2F2C;
/// 36 word offsets to the lists of frame durations, a byte per frame (0x3A14).
const durations = 0x3A30;
/// By the animation pair, a word offset to the characters' first entries, then a byte per
/// frame: the power of its blow (low nibble) and its kind (high nibble; bit 0 knocks down).
const attack_table = 0x423C;
/// The players' boxes: 5 bytes each (X from, X width, a depth pair, Z from, Z height), and the
/// depth pairs (from, width).
const player_boxes = 0x1ABA8;
pub const depth_pairs = 0x1AB8E;
/// A long per character: two signed bytes per state pair, the speeds across and in depth in
/// sixteenths of a pixel a tick (0x3614).
const speed_tables = 0x3664;
/// A long per character: the jump's speed up (0x3832).
const jump_speeds = 0x3842;
/// By the state / 2, what the one held does when the holder is in that state (0x32D8).
const hold_requests = 0x32F2;
/// A byte per character: the frame at which the combo's last blow ends (0x20A6).
const last_blow_ends = 0x20E8;
/// A byte per character: the attack's shout, the death cry, the last knee's sound (0x106CA,
/// 0x106DA, 0x35E2).
const attack_voices = 0x106D6;
const death_cries = 0x106E6;
const knee_sounds = 0x3610;
/// The places of the one held by the frames of the holder's throws, by the holder's character
/// (0xA378): the throw over the shoulder (0xA240) and the back drop (0xA2EC): 3 bytes a frame,
/// X and height from the holder, the held one's pose; a pose of $99 ends the hold.
pub const throw_poses = 0xA3E8;
pub const slam_poses = 0xA416;
const counter_poses = 0xA400;
/// The places of a player holding an enemy by its animation from $70 (0x4A5A): a word offset per
/// animation pair (bit 15: present), a byte per character to its list, then 2 bytes a frame: X
/// toward the player's side and height from the one held.
pub const holder_places = 0x4C3E;
/// The other objects' box table (0xAB24).
pub const object_boxes = 0x1A68E;

/// The players' states (the trace's names), by the original's number (the table at $1CE2).
const State = struct {
    pub const ready = 0x02;
    pub const idle = 0x04;
    pub const walk = 0x06;
    pub const walk_up_side = 0x08;
    pub const walk_up = 0x0A;
    pub const jump_crouch = 0x10;
    pub const jump = 0x12;
    pub const jump_kick = 0x16;
    pub const attack1 = 0x18;
    pub const attack3 = 0x1C;
    pub const attack4 = 0x1E;
    pub const back_attack = 0x20;
    pub const pick_up = 0x28;
    pub const armed_stand = 0x30;
    pub const armed_walk = 0x32;
    pub const armed_attack = 0x44;
    pub const armed_stab = 0x46;
    pub const armed_swing = 0x48;
    pub const down = 0x54;
    pub const dying = 0x56;
    pub const lying_dead = 0x58;
    pub const hurt = 0x5A;
    pub const knocked_down = 0x5C;
    pub const getting_up = 0x5E;
    pub const grab = 0x60;
    pub const grab_blow = 0x62;
    pub const grab_behind = 0x66;
    pub const vault = 0x68;
    pub const knee = 0x6A;
    pub const knee_last = 0x6E;
    pub const vault_land = 0x70;
    pub const recover = 0x74;
    pub const throw = 0x76;
    pub const held = 0x78;
    pub const held_behind = 0x7A;
    pub const escape = 0x7C;
    pub const counter = 0x7E;
    pub const thrown = 0x82;
};

// --- Reading an animation ----------------------------------------------------------------------

/// A frame of an animation as the set holds it: the frame's address, drawn mirrored or not, and
/// the box indices it uses that way (the frame holds a pair for each way).
pub const RawFrame = struct { address: u32, mirrored: bool, attack: u8, body: u8 };

pub const RawAnimation = struct { timing: u8, frames: []RawFrame };

/// Entry `entry` of the set at `set`: a count, a timing, and the frames' word offsets from the
/// animation (bit 15: drawn mirrored); a frame's box pair is its bytes 1 and 2, or 3 and 4 drawn
/// mirrored (0x3B12).
pub fn readAnimation(arena: std.mem.Allocator, rom: []const u8, set: u32, entry: u32) Error!RawAnimation {
    const off = s16be(rom, set + 2 * entry);
    if (off <= 0) return error.BadData;
    const a = set + @as(u32, @intCast(off));
    const n = rom[a];
    if (n == 0) return error.BadData;
    const frames = try arena.alloc(RawFrame, n);
    for (frames, 0..) |*f, j| {
        const w = u16be(rom, a + 2 + 2 * @as(u32, @intCast(j)));
        const fa = a + (w & 0x7FFF);
        const m = w & 0x8000 != 0;
        f.* = .{ .address = fa, .mirrored = m, .attack = rom[fa + @as(u32, if (m) 3 else 1)], .body = rom[fa + @as(u32, if (m) 4 else 2)] };
    }
    return .{ .timing = rom[a + 1], .frames = frames };
}

/// The duration of frame `j` in the players' list `timing`, as the code reads it (0x3A14).
fn duration(rom: []const u8, timing: u8, j: usize) u8 {
    const list: u32 = @intCast(@as(i32, durations) + s16be(rom, durations + 2 * @as(u32, timing)));
    return rom[list + j];
}

/// The attack byte of frame `j` of the animation pair whose right-facing entry is `entry`, for
/// character `character` (0x41EA).
fn attackByte(rom: []const u8, entry: u32, character: u8, j: usize) u8 {
    const t: u32 = @intCast(@as(i32, attack_table) + s16be(rom, attack_table + (entry & 0xFFFE)));
    const i: u8 = rom[t + character] +% @as(u8, @intCast(j));
    return rom[t + 3 + @as(u32, i)];
}

/// A box of the players' table (0x4192): [from, to] on each axis, both included.
pub const Spans = struct { x: entity.Span, depth: entity.Span, height: entity.Span };

fn playerBox(rom: []const u8, n: u8) Spans {
    return tableBox(rom, player_boxes, n);
}

/// Box `n` of the box table at `table` (the players' or the other objects', 0xAB24).
pub fn tableBox(rom: []const u8, table: u32, n: u8) Spans {
    const e = table + 5 * @as(u32, n);
    const x0: i16 = s8(rom, e);
    const d = depth_pairs + 2 * @as(u32, rom[e + 2]);
    const d0: i16 = s8(rom, d);
    const z0: i16 = s8(rom, e + 3);
    return .{
        .x = .{ .from = x0, .to = x0 + s8(rom, e + 1) },
        .depth = .{ .from = d0, .to = d0 + s8(rom, d + 1) },
        .height = .{ .from = z0, .to = z0 + s8(rom, e + 4) },
    };
}

// --- Building a definition ---------------------------------------------------------------------

/// A definition as it is built: its lists, and the boxes by the pair of indices they come from.
pub const Def = struct {
    arena: std.mem.Allocator,
    rom: []const u8,
    /// The art set's directory, its animation set, and the set's frames in address order, which
    /// name the frames.
    dir: []const u8,
    /// The frames' names' prefix in a shared art set (`weapons/pipe_00`); none: the set's own.
    prefix: []const u8 = "",
    set: u32,
    frame_addresses: []const u32,
    /// The box table of its frames: the players' or the other objects'.
    box_table: u32 = player_boxes,
    numbers: std.ArrayList(entity.Number) = .empty,
    number_notes: std.ArrayList(u8) = .empty,
    tables: std.ArrayList(entity.Table) = .empty,
    choices: std.ArrayList(entity.Choice) = .empty,
    sounds: std.ArrayList(entity.Sound) = .empty,
    boxes: std.ArrayList(entity.Box) = .empty,
    box_keys: std.ArrayList([3]u8) = .empty,
    animations: std.ArrayList(entity.Animation) = .empty,
    moves: std.ArrayList(entity.Move) = .empty,

    pub fn frameName(d: *Def, address: u32) Error![]const u8 {
        const i = std.mem.indexOfScalar(u32, d.frame_addresses, address) orelse return error.BadData;
        if (d.prefix.len != 0) return std.fmt.allocPrint(d.arena, "{s}/{s}_{d:0>2}", .{ d.dir, d.prefix, i });
        return std.fmt.allocPrint(d.arena, "{s}/{d:0>3}", .{ d.dir, i });
    }

    /// The number `name`; its place goes in the definition's provenance.
    pub fn number(d: *Def, name: []const u8, value: i32, place: []const u8) Error!void {
        try d.numbers.append(d.arena, .{ .name = name, .value = value });
        try d.number_notes.print(d.arena, "; {s}: {s}", .{ name, place });
    }

    /// The table `name`; its place goes in the definition's provenance.
    pub fn table(d: *Def, name: []const u8, values: []const i32, place: []const u8) Error!void {
        try d.tables.append(d.arena, .{ .name = name, .values = try d.arena.dupe(i32, values) });
        try d.number_notes.print(d.arena, "; {s}: {s}", .{ name, place });
    }

    /// The choice of states `name`; its place goes in the definition's provenance.
    pub fn choice(d: *Def, name: []const u8, states: []const []const u8, place: []const u8) Error!void {
        try d.choices.append(d.arena, .{ .name = name, .states = try d.arena.dupe([]const u8, states) });
        try d.number_notes.print(d.arena, "; {s}: {s}", .{ name, place });
    }

    /// The box of the pair (`right`, `left`) of the players' table in role `role`, named the
    /// first time after the animation `animation` that uses it.
    pub fn box(d: *Def, role: u8, right: u8, left: u8, animation: []const u8, role_name: []const u8) Error!?u8 {
        if (right == 0 and left == 0) return null;
        if (right == 0 or left == 0) return error.BadData;
        const key: [3]u8 = .{ role, right, left };
        for (d.box_keys.items, 0..) |k, i| if (std.mem.eql(u8, &k, &key)) return @intCast(i);
        const r = tableBox(d.rom, d.box_table, right);
        const l = tableBox(d.rom, d.box_table, left);
        // Facing left, only the span across may differ from the mirror image.
        if (!std.meta.eql(r.depth, l.depth) or !std.meta.eql(r.height, l.height)) return error.BadData;
        var name = try std.fmt.allocPrint(d.arena, "{s}_{s}", .{ animation, role_name });
        var k: usize = 2;
        while (d.boxIndex(name) != null) : (k += 1) name = try std.fmt.allocPrint(d.arena, "{s}_{s}_{d}", .{ animation, role_name, k });
        try d.boxes.append(d.arena, .{
            .name = name,
            .x = r.x,
            .x_left = if (std.meta.eql(l.x, r.x.mirrored())) null else l.x,
            .depth = r.depth,
            .height = r.height,
        });
        try d.box_keys.append(d.arena, key);
        return @intCast(d.boxes.items.len - 1);
    }

    fn boxIndex(d: *const Def, name: []const u8) ?usize {
        for (d.boxes.items, 0..) |b, i| if (std.mem.eql(u8, b.name, name)) return i;
        return null;
    }

    pub fn animationIndex(d: *const Def, name: []const u8) ?u8 {
        for (d.animations.items, 0..) |a, i| if (std.mem.eql(u8, a.name, name)) return @intCast(i);
        return null;
    }

    pub fn sound(d: *Def, role: []const u8, request: u8) Error!void {
        try d.sounds.append(d.arena, .{ .name = role, .sound = try soundName(request) });
    }
};

/// The sound content's name of the original's request `request`.
pub fn soundName(request: u8) Error![]const u8 {
    for (sound_names.entries) |e| if (e.request == request) return e.name;
    return error.BadData;
}

/// `addq` or `subq` at `at`, whose opcode less its count is `base`: the count (0 is 8).
pub fn quick(rom: []const u8, at: u32, base: u16) Error!i32 {
    const op = u16be(rom, at);
    if (op & 0xF1FF != base) return error.BadData;
    const n: i32 = (op >> 9) & 7;
    return if (n == 0) 8 else n;
}

/// The immediate value of the instruction at `at`, checked: its first bytes must be `opcode`;
/// the value is the `width` bytes after them (1: the low byte of a word, a `moveq`'s byte), sign
/// extended.
pub fn immediate(rom: []const u8, at: u32, opcode: []const u8, width: u8) Error!i32 {
    if (!std.mem.eql(u8, rom[at..][0..opcode.len], opcode)) return error.BadData;
    const v = at + @as(u32, @intCast(opcode.len));
    return switch (width) {
        1 => s8(rom, v),
        2 => s16be(rom, v),
        4 => @bitCast(u32be(rom, v)),
        else => error.BadData,
    };
}

/// `move.b #N,(D,a0)`: the opcode, then the byte's word, then the displacement.
pub fn moveByte(rom: []const u8, at: u32, displacement: u8) Error!i32 {
    if (u16be(rom, at) != 0x117C or rom[at + 2] != 0 or u16be(rom, at + 4) != displacement) return error.BadData;
    return rom[at + 3];
}

/// `cmpi.b #N,(10,a0)`: a frame of the animation compared.
pub fn frameCompared(rom: []const u8, at: u32) Error!i32 {
    if (u16be(rom, at) != 0x0C28 or rom[at + 2] != 0 or u16be(rom, at + 4) != 10) return error.BadData;
    return rom[at + 3];
}

/// `moveq #N,dR`.
pub fn moveq(rom: []const u8, at: u32, register: u3) Error!i32 {
    if (rom[at] != 0x70 | (@as(u8, register) << 1)) return error.BadData;
    return s8(rom, at + 1);
}

// --- The player ----------------------------------------------------------------------------------

/// The animations a player definition holds, by the state that plays them (0x2F2C).
const PlayerAnimation = struct { name: []const u8, state: u8 };

const player_animations = [_]PlayerAnimation{
    .{ .name = "ready", .state = State.ready },
    .{ .name = "idle", .state = State.idle },
    .{ .name = "walk", .state = State.walk },
    // The crouch before a jump and after a landing.
    .{ .name = "jump_crouch", .state = State.jump_crouch },
    // In the air: a jump, and a fall.
    .{ .name = "jump", .state = State.jump },
    .{ .name = "jump_kick", .state = State.jump_kick },
    // The combo's first two blows play one animation.
    .{ .name = "attack1", .state = State.attack1 },
    .{ .name = "attack3", .state = State.attack3 },
    .{ .name = "attack4", .state = State.attack4 },
    .{ .name = "back_attack", .state = State.back_attack },
    .{ .name = "pick_up", .state = State.pick_up },
    .{ .name = "hurt", .state = State.hurt },
    .{ .name = "knocked_down", .state = State.knocked_down },
    // Lying down, and the knock-down's bounce.
    .{ .name = "down", .state = State.down },
    .{ .name = "getting_up", .state = State.getting_up },
    // Dead on the ground (dying plays the knock-down's animation).
    .{ .name = "lying_dead", .state = State.lying_dead },
    .{ .name = "recover", .state = State.recover },
    .{ .name = "grab", .state = State.grab },
    .{ .name = "grab_blow", .state = State.grab_blow },
    .{ .name = "grab_behind", .state = State.grab_behind },
    .{ .name = "vault", .state = State.vault },
    .{ .name = "knee", .state = State.knee },
    .{ .name = "knee_last", .state = State.knee_last },
    .{ .name = "throw", .state = State.throw },
    // Held by an enemy from the front, from behind; the jump out of a hold from behind; the
    // throw that answers it (traced as `grab_blow`); thrown over an enemy's head.
    .{ .name = "held", .state = State.held },
    .{ .name = "held_behind", .state = State.held_behind },
    .{ .name = "escape", .state = State.escape },
    .{ .name = "counter", .state = State.counter },
    .{ .name = "thrown", .state = State.thrown },
    // Armed: standing and walking, a weapon in hand; its blows: the plain one (in which a knife
    // is thrown), the stab, the swing (0x2F2C).
    .{ .name = "armed_stand", .state = State.armed_stand },
    .{ .name = "armed_walk", .state = State.armed_walk },
    .{ .name = "armed_attack", .state = State.armed_attack },
    .{ .name = "armed_stab", .state = State.armed_stab },
    .{ .name = "armed_swing", .state = State.armed_swing },
};

/// The set's entry of state `state`'s animation facing right (its byte offset / 2).
fn stateEntry(rom: []const u8, state: u8) Error!u32 {
    const offset = rom[state_animations + @as(u32, state)];
    if (offset & 3 != 0) return error.BadData;
    // Facing left, the state's next byte names the next entry.
    if (rom[state_animations + @as(u32, state) + 1] != offset + 2) return error.BadData;
    return offset / 2;
}

/// The frames of entry `entry` (facing right) with those of the next entry (facing left): the
/// same frames, mirrored the other way; their durations from list `timing`, and per frame the
/// blow's power and kind. `name` names the boxes it uses first.
fn playerFrames(d: *Def, name: []const u8, entry: u32, timing: u8, character: u8) Error![]entity.Frame {
    const right = try readAnimation(d.arena, d.rom, d.set, entry);
    const left = try readAnimation(d.arena, d.rom, d.set, entry + 1);
    if (right.frames.len != left.frames.len) return error.BadData;
    const out = try d.arena.alloc(entity.Frame, right.frames.len);
    for (out, right.frames, left.frames, 0..) |*f, r, l, j| {
        if (r.address != l.address or r.mirrored == l.mirrored) return error.BadData;
        const ticks = duration(d.rom, timing, j);
        if (ticks == 0) return error.BadData;
        const power = attackByte(d.rom, entry, character, j) & 0xF;
        f.* = .{
            .frame = try d.frameName(r.address),
            .ticks = ticks,
            .flip = r.mirrored,
            .body = try d.box(0, r.body, l.body, name, "body"),
            .attack = try d.box(1, r.attack, l.attack, name, if (power == 0) "reach" else "blow"),
            .blow = power != 0,
        };
    }
    return out;
}

/// What the one held does in state `state` (the table at 0x32F2), as the move's reaction.
fn holdReaction(rom: []const u8, state: u8) Error!entity.Reaction {
    return switch (rom[hold_requests + @as(u32, state) / 2]) {
        3 => .reel, // hit while held: it reels and stays held (0xA164)
        4 => .knock_down, // flipped over: knocked down (0xA1DC)
        5, 7, 8 => .thrown, // thrown over the holder (0xA240)
        6 => .slammed, // slammed down behind the holder (0xA2EC)
        else => error.BadData,
    };
}

/// The definition of the player `name`, character `character` (0 Axel, 1 Adam, 2 Blaze).
pub fn player(arena: std.mem.Allocator, rom: []const u8, name: []const u8, character: u8) Error!entity.Definition {
    const set = u32be(rom, player_sets + 4 * @as(u32, character));
    var d: Def = .{ .arena = arena, .rom = rom, .dir = name, .set = set, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };

    // The animations, by the states that play them, and the moves of the blows and the holds.
    for (player_animations) |pa| {
        const entry = try stateEntry(rom, pa.state);
        const raw = try readAnimation(arena, rom, set, entry);
        try d.animations.append(arena, .{ .name = pa.name, .loop = true, .frames = try playerFrames(&d, pa.name, entry, raw.timing, character) });
    }
    // A long weapon in hand (a pipe), the stand and the walk are the next entries (0x2E32:
    // animation +4).
    if (try quick(rom, 0x2E66, 0x5068) != 4) return error.BadData;
    for ([_]struct { name: []const u8, state: u8 }{
        .{ .name = "armed_stand_long", .state = State.armed_stand },
        .{ .name = "armed_walk_long", .state = State.armed_walk },
    }) |pa| {
        const entry = try stateEntry(rom, pa.state) + 2;
        const raw = try readAnimation(arena, rom, set, entry);
        try d.animations.append(arena, .{ .name = pa.name, .loop = true, .frames = try playerFrames(&d, pa.name, entry, raw.timing, character) });
    }
    // The weapon in hand, frame by frame (0x5FC8), by the armed animations in the original's
    // order.
    for ([_][]const u8{ "armed_stand", "armed_stand_long", "armed_walk", "armed_walk_long", "armed_attack", "armed_stab", "armed_swing" }, 0..) |armed, k| {
        try weapons.playerHands(&d, armed, @intCast(k), character);
    }
    // The armed blows: the stab and the swing sound at their second frame as the combo's
    // blows do (0x2242); the plain blow's sound is its behaviour's (a knife thrown sounds the
    // throw instead, 0x2226).
    const armed_swing = try soundName(@bitCast(@as(i8, @intCast(try moveq(rom, 0x2242, 7)))));
    for ([_][]const u8{ "armed_stab", "armed_swing" }) |n| {
        @constCast(d.animations.items[d.animationIndex(n).?].frames)[1].sound = armed_swing;
    }
    try d.sound("armed_blow", @bitCast(@as(i8, @intCast(try moveq(rom, 0x2242, 7)))));
    try d.sound("throw_weapon", @bitCast(@as(i8, @intCast(try moveq(rom, 0x2226, 7)))));
    try d.sound("swing_weapon", @bitCast(@as(i8, @intCast(try moveq(rom, 0x311C, 7)))));
    try d.number("armed_blow_ends", try moveq(rom, 0x21E6, 1), "ROM 0x021E6: moveq #N,d1 (the plain blow's and the stab's last frame)");
    try d.number("armed_swing_ends", try moveq(rom, 0x225C, 1), "ROM 0x0225C: moveq #N,d1 (the swing's)");
    try d.number("throw_frame", try frameCompared(rom, 0x2214), "ROM 0x02214: cmpi.b #N,(10,a0) (a knife leaves the hand)");
    try d.number("stab_reach", try immediate(rom, 0x3106, &.{ 0x0C, 0x44 }, 2), "ROM 0x03106: cmpi.w #N,d4 (a thing ahead within it, 0x30C4)");
    try d.number("stab_level", try immediate(rom, 0x30D2, &.{ 0x04, 0x42 }, 2), "ROM 0x030D2: subi.w #N,d2 (its depth within it either way, 0x030D8)");
    if (try immediate(rom, 0x30D8, &.{ 0x06, 0x43 }, 2) != 2 * try immediate(rom, 0x30D2, &.{ 0x04, 0x42 }, 2)) return error.BadData;

    // A blow of the combo's first pressed again while it runs hurries: the rest of its frames
    // take the durations of the list the code sets (0x205A).
    const attack1 = try stateEntry(rom, State.attack1);
    const hurried: u8 = @intCast(try moveByte(rom, 0x205A, 12));
    try d.animations.append(arena, .{ .name = "attack1_hurried", .loop = true, .frames = try playerFrames(&d, "attack1", attack1, hurried, character) });
    // The back drop's landing plays the vault's frames 3, 2 and 1 backward, each for the ticks
    // the code sets (0x23D6, 0x23F8).
    {
        const vault = d.animations.items[d.animationIndex("vault").?].frames;
        const ticks: u8 = @intCast(try moveByte(rom, 0x23E6, 13));
        if (ticks != try moveByte(rom, 0x240A, 13)) return error.BadData;
        const first: usize = @intCast(try frameCompared(rom, 0x23DA) - 1);
        const frames = try arena.alloc(entity.Frame, first);
        for (frames, 0..) |*f, k| {
            f.* = vault[first - k];
            f.ticks = ticks;
        }
        try d.animations.append(arena, .{ .name = "vault_land", .loop = true, .frames = frames });
    }
    // The vault over the one held and the jump back over it from behind: the holder's places
    // from the one held, frame by frame (0x4A5A; from behind, the list of animation $A0).
    {
        const throw: []entity.Frame = @constCast(d.animations.items[d.animationIndex("throw").?].frames);
        const back = try arena.dupe(entity.Frame, throw);
        try placeFrames(&d, throw, try stateEntry(rom, State.throw) * 2 - 0x70, character);
        try placeFrames(&d, back, 0xA0 - 0x70, character);
        try d.animations.append(arena, .{ .name = "throw_back", .loop = true, .frames = back });
    }
    // The one held, frame by frame, in the throw over the shoulder and in the back drop; and
    // where the enemies' hold puts it in the holds and the knees (0xA0B8, 0xA112, 0xA196: in
    // front, from behind, struck while held).
    try heldFrames(&d, "grab_blow", throw_poses, character);
    try heldFrames(&d, "vault", slam_poses, character);
    // The throw that answers a hold from behind places the enemy as the table for its request 8
    // does (0xA240 with 0xA400); thrown by an enemy, the player is placed from it frame by frame
    // (0x4A5A).
    try heldFrames(&d, "counter", counter_poses, character);
    try placeFrames(&d, @constCast(d.animations.items[d.animationIndex("thrown").?].frames), try stateEntry(rom, State.thrown) * 2 - 0x70, character);
    for ([_]struct { name: []const u8, at: u32 }{
        .{ .name = "grab", .at = 0xA0BC },
        .{ .name = "grab_behind", .at = 0xA116 },
        .{ .name = "knee", .at = 0xA19A },
    }) |h| {
        const x = -(try moveq(rom, h.at, 3));
        for (@constCast(d.animations.items[d.animationIndex(h.name).?].frames)) |*f| f.held = .{ .x = @intCast(x) };
        try d.number_notes.print(arena, "; {s}'s one held: ROM 0x{X:0>5}: moveq #-N,d3", .{ h.name, h.at });
    }
    try d.number_notes.print(arena, "; the poses of the one held: ROM 0x{X:0>5} (throw), 0x{X:0>5} (back drop); the holder's places: 0x{X:0>5}", .{ throw_poses, slam_poses, holder_places });

    // The swing of a blow at its frame 1 (0x4462), the last knee's sound at its hitting frame
    // (0x35E2).
    const swing = try soundName(@intCast(@as(u8, @bitCast(@as(i8, @intCast(try moveq(rom, 0x4470, 7)))))));
    for ([_][]const u8{ "attack1", "attack1_hurried", "attack3", "attack4", "back_attack" }) |n| {
        @constCast(d.animations.items[d.animationIndex(n).?].frames)[1].sound = swing;
    }
    @constCast(d.animations.items[d.animationIndex("knee_last").?].frames)[1].sound = try soundName(rom[knee_sounds + @as(u32, character)]);

    // The moves: their power and kind from their frames' blows.
    const shout = try soundName(rom[attack_voices + @as(u32, character)]);
    const Move = struct { name: []const u8, animation: []const u8, state: u8, sound: ?[]const u8 = null, hold: bool = false };
    const moves = [_]Move{
        .{ .name = "attack1", .animation = "attack1", .state = State.attack1 },
        .{ .name = "attack2", .animation = "attack1", .state = State.attack1 + 2 },
        .{ .name = "attack3", .animation = "attack3", .state = State.attack3 },
        .{ .name = "attack4", .animation = "attack4", .state = State.attack4 },
        .{ .name = "back_attack", .animation = "back_attack", .state = State.back_attack },
        // A jump kick and a throw's or a back drop's start shout (0x3914, 0x2BA8, 0x2332).
        .{ .name = "jump_kick", .animation = "jump_kick", .state = State.jump_kick, .sound = shout },
        .{ .name = "knee", .animation = "knee", .state = State.knee, .hold = true },
        .{ .name = "knee_last", .animation = "knee_last", .state = State.knee_last, .hold = true },
        .{ .name = "grab_blow", .animation = "grab_blow", .state = State.grab_blow, .sound = shout, .hold = true },
        .{ .name = "vault", .animation = "vault", .state = State.vault, .sound = shout, .hold = true },
        .{ .name = "throw", .animation = "throw", .state = State.throw },
        .{ .name = "throw_back", .animation = "throw_back", .state = State.throw },
        .{ .name = "counter", .animation = "counter", .state = State.counter, .hold = true },
    };
    for (moves) |m| {
        const index = d.animationIndex(m.animation).?;
        const entry = try stateEntry(rom, m.state);
        var power: u8 = 0;
        var kind: u8 = 0;
        for (d.animations.items[index].frames, 0..) |f, j| {
            if (!f.blow) continue;
            const b = attackByte(rom, entry, character, j);
            if (power != 0 and (b & 0xF != power or b >> 4 != kind)) return error.BadData;
            power = b & 0xF;
            kind = b >> 4;
        }
        const reaction: entity.Reaction = if (m.hold) try holdReaction(rom, m.state) else if (kind & 1 != 0) .knock_down else .reel;
        try d.moves.append(arena, .{
            .name = m.name,
            .provenance = try std.fmt.allocPrint(arena, "the player's state ${X:0>2}: the power and kind of its frames' blows (ROM 0x{X:0>5}){s}", .{
                m.state, attack_table, if (m.hold) try std.fmt.allocPrint(arena, ", the one held's reaction (0x{X:0>5})", .{hold_requests}) else "",
            }),
            .animation = index,
            .damage = power,
            .reaction = reaction,
            .sound = m.sound,
        });
    }

    // The numbers.
    const speeds = u32be(rom, speed_tables + 4 * @as(u32, character));
    const sixteenth: i32 = 0x1000;
    const sp = struct {
        fn x(r: []const u8, table: u32, state: u8) i32 {
            return s8(r, table + state);
        }
        fn y(r: []const u8, table: u32, state: u8) i32 {
            return s8(r, table + state + 1);
        }
    };
    const speed_place = try std.fmt.allocPrint(arena, "the speed table at ROM 0x{X:0>5}", .{speeds});
    try d.number("walk_x", sp.x(rom, speeds, State.walk) * sixteenth, speed_place);
    try d.number("walk_depth", -sp.y(rom, speeds, State.walk_up) * sixteenth, speed_place);
    try d.number("diagonal_x", sp.x(rom, speeds, State.walk_up_side) * sixteenth, speed_place);
    try d.number("diagonal_depth", -sp.y(rom, speeds, State.walk_up_side) * sixteenth, speed_place);
    try d.number("knocked_down_x", sp.x(rom, speeds, State.knocked_down) * sixteenth, speed_place);
    try d.number("dying_x", sp.x(rom, speeds, State.dying) * sixteenth, speed_place);
    try d.number("jump", @bitCast(u32be(rom, jump_speeds + 4 * @as(u32, character))), "ROM 0x03842, by character");
    try d.number("jump_x", try immediate(rom, 0x384E, &.{ 0x20, 0x3C }, 4), "ROM 0x0384E: move.l #N,d0");
    try d.number("steer", try immediate(rom, 0x38F0, &.{ 0x20, 0x3C }, 4), "ROM 0x038F0: move.l #N,d0");
    try d.number("steer_most", -(try immediate(rom, 0x38FA, &.{ 0x20, 0x3C }, 4)), "ROM 0x038FA: move.l #-N,d0");
    try d.number("kick_falling_gravity", try immediate(rom, 0x38B4, &.{ 0x20, 0x3C }, 4), "ROM 0x038B4: move.l #N,d0");
    try d.number("fall_most", try immediate(rom, 0x3886, &.{ 0x0C, 0xA8 }, 4), "ROM 0x03886: cmpi.l #N,(36,a0)");
    try d.number("drop", try immediate(rom, 0x3E20, &.{ 0x21, 0x7C }, 4), "ROM 0x03E20: move.l #N,(36,a0)");
    try d.number("knocked_down_up", try immediate(rom, 0x34DA, &.{ 0x21, 0x7C }, 4), "ROM 0x034DA: move.l #N,(36,a0)");
    try d.number("dying_up", try immediate(rom, 0x3440, &.{ 0x21, 0x7C }, 4), "ROM 0x03440: move.l #N,(36,a0)");
    try d.number("dead", try moveByte(rom, 0x3F18, 0x41), "ROM 0x03F18: move.b #N,($41,a0)");
    try d.number("hurt", try moveByte(rom, 0x348C, 0x41), "ROM 0x0348C: move.b #N,($41,a0)");
    try d.number("down", try moveByte(rom, 0x3F66, 0x41), "ROM 0x03F66: move.b #N,($41,a0)");
    try d.number("blink", try moveByte(rom, 0x4F6A, 0x49), "ROM 0x04F6A: move.b #N,($49,a0)");
    try d.number("combo_window", try moveByte(rom, 0x2034, 0x5C), "ROM 0x02034: move.b #N,($5C,a0)");
    try d.number("hit_pause", try moveByte(rom, 0x21D8, 0x4F), "ROM 0x021D8: move.b #N,($4F,a0)");
    try d.number("let_go", try moveByte(rom, 0x32CE, 0x63), "ROM 0x032CE: move.b #N,($63,a0)");
    try d.number("special_beyond", try immediate(rom, 0x40C2, &.{ 0x06, 0x41 }, 2), "ROM 0x040C2: addi.w #N,d1 (from the camera's place across, 0x40A6)");
    try d.number("hurry_first", try moveByte(rom, 0x2060, 13), "ROM 0x02060: move.b #N,(13,a0)");
    try d.number("hurry_later", try moveByte(rom, 0x206E, 13), "ROM 0x0206E: move.b #N,(13,a0)");
    try d.number("jab_walk_frame", try moveByte(rom, 0x3040, 0x5A), "ROM 0x03040: move.b #N,($5A,a0)");
    try d.number("jab_walk_ticks", try moveByte(rom, 0x3046, 0x5B), "ROM 0x03046: move.b #N,($5B,a0)");
    try d.number("idle_ends", try moveq(rom, 0x1F96, 0), "ROM 0x01F96: moveq #N,d0");
    try d.number("blow_ends", try moveq(rom, 0x2078, 0), "ROM 0x02078: moveq #N,d0");
    try d.number("last_blow_ends", rom[last_blow_ends + @as(u32, character)], "ROM 0x020E8, by character");
    try d.number("back_attack_ends", try frameCompared(rom, 0x20F4), "ROM 0x020F4: cmpi.b #N,(10,a0)");
    try d.number("getting_up_ends", try frameCompared(rom, 0x2B24), "ROM 0x02B24: cmpi.b #N,(10,a0)");
    try d.number("recover_ends", try frameCompared(rom, 0x242E), "ROM 0x0242E: cmpi.b #N,(10,a0)");
    try d.number("vault_ends", try frameCompared(rom, 0x23DA), "ROM 0x023DA: cmpi.b #N,(10,a0)");
    try d.number("knee_last_ends", try frameCompared(rom, 0x2474), "ROM 0x02474: cmpi.b #N,(10,a0)");
    try d.number("grab_blow_ends", try moveq(rom, 0x23B4, 5), "ROM 0x023B4: moveq #N,d5");
    try d.number("throw_ends", try frameCompared(rom, 0x2742), "ROM 0x02742: cmpi.b #N,(10,a0)");
    try d.number("pick_x", -(try immediate(rom, 0x314A, &.{ 0x06, 0x41 }, 2)), "ROM 0x0314A: addi.w #-N,d1");
    try d.number("pick_depth", -(try immediate(rom, 0x3158, &.{ 0x06, 0x43 }, 2)), "ROM 0x03158: addi.w #-N,d3");
    try d.number("pick_height", -(try immediate(rom, 0x3166, &.{ 0x06, 0x45 }, 2)), "ROM 0x03166: addi.w #-N,d5");
    // Held by an enemy (0x24C4, 0x25B8): the jump out of a hold from behind opens, at its frame,
    // a window in which B throws the holder (0x26B0); thrown over its head (0x284A, 0x286E): its
    // first frame's ticks, each next one's, the frame it falls at, how far ahead, and its speeds.
    try d.number("escape_frame", try frameCompared(rom, 0x26BC), "ROM 0x026BC: cmpi.b #N,(10,a0)");
    try d.number("escape_window", try moveByte(rom, 0x26CA, 0x62), "ROM 0x026CA: move.b #N,(98,a0)");
    try d.number("thrown_first", try moveByte(rom, 0x24F4, 0x4E), "ROM 0x024F4: move.b #N,(78,a0)");
    try d.number("thrown_pace", try moveByte(rom, 0x285C, 0x4E), "ROM 0x0285C: move.b #N,(78,a0)");
    try d.number("thrown_falls", try frameCompared(rom, 0x2854), "ROM 0x02854: cmpi.b #N,(10,a0)");
    try d.number("thrown_ahead", try moveq(rom, 0x286E, 0), "ROM 0x0286E: moveq #N,d0");
    try d.number("thrown_up", (try immediate(rom, 0x2882, &.{ 0x31, 0x7C }, 2)) << 16, "ROM 0x02882: move.w #N,(36,a0)");
    try d.number("thrown_x", try immediate(rom, 0x2888, &.{ 0x20, 0x3C }, 4), "ROM 0x02888: move.l #N,d0");
    // Held from behind by a stalker, it is kept this far ahead of it (0xDB18's table at 0xDBC8,
    // by character).
    try d.number("held_ahead", rom[0xDBC8 + @as(u32, character)], "ROM 0x0DBC8, by character");

    // The sounds by their role.
    try d.sound("jump", @bitCast(@as(i8, @intCast(try moveq(rom, 0x2FD4, 7)))));
    try d.sound("land", @bitCast(@as(i8, @intCast(try moveq(rom, 0x3EE6, 7)))));
    try d.sound("hurt", @bitCast(@as(i8, @intCast(try moveq(rom, 0x3476, 7)))));
    try d.sound("thud", @bitCast(@as(i8, @intCast(try moveq(rom, 0x3F58, 7)))));
    try d.sound("death", rom[death_cries + @as(u32, character)]);

    const health = try moveq(rom, 0x1F12, 7);
    return .{
        .name = name,
        .provenance = try std.fmt.allocPrint(arena, "player character {d}: the animation set at ROM 0x{X:0>5} (0x1F20), the states' animations (0x2F2C), the durations (0x3A30), the boxes (0x1ABA8, 0x1AB8E), the blows (0x423C); health ROM 0x01F12: moveq #N,d7; gravity ROM 0x0389A: move.l #N,d0{s}", .{ character, set, d.number_notes.items }),
        .family = .player,
        .team = .player,
        .behaviour = "player",
        .health = @intCast(health),
        .gravity = try immediate(rom, 0x389A, &.{ 0x20, 0x3C }, 4),
        .shadow = true,
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
        .moves = d.moves.items,
    };
}

/// Each frame of `frames` takes its place from the one held: the list of animation `which`
/// ($70 on) of the players' places (0x4A5A), X toward the holder's side and the height added
/// (downward). An entry of $0303 (two 3s) or past the list ends it.
fn placeFrames(d: *Def, frames: []entity.Frame, which: u32, character: u8) Error!void {
    const rom = d.rom;
    const w = u16be(rom, holder_places + which / 2);
    if (w & 0x8000 == 0) return error.BadData;
    const list = holder_places + (w & 0x7FFF);
    const t = list + rom[list + character];
    for (frames, 0..) |*f, k| {
        const at = t + 2 * @as(u32, @intCast(k));
        f.place = .{ .x = s8(rom, at), .height = s8(rom, at + 1) };
    }
}

/// The frames of animation `name` place the one held as `table` says (0xA378): X and height
/// from the holder, which faces the same way as the one held there (the holder turned for the
/// throw over the shoulder, or holds from behind for the back drop): its X ahead of the holder,
/// its height up; the entry whose pose is $99 lets it go.
fn heldFrames(d: *Def, name: []const u8, table: u32, character: u8) Error!void {
    const rom = d.rom;
    const frames: []entity.Frame = @constCast(d.animations.items[d.animationIndex(name).?].frames);
    const t = table + rom[table + character];
    for (frames, 0..) |*f, k| {
        const at = t + 3 * @as(u32, @intCast(k));
        const pose = rom[at + 2];
        f.held = .{ .x = s8(rom, at), .height = -@as(i16, s8(rom, at + 1)), .pose = if (pose == 0x99) null else pose, .lets_go = pose == 0x99 };
        if (pose == 0x99) return;
    }
    return error.BadData;
}

test "an immediate is read only from its instruction" {
    var rom: [16]u8 = @splat(0);
    @memcpy(rom[2..8], &[_]u8{ 0x20, 0x3C, 0x00, 0x00, 0xE8, 0x00 });
    try std.testing.expectEqual(@as(i32, 0xE800), try immediate(&rom, 2, &.{ 0x20, 0x3C }, 4));
    try std.testing.expectError(error.BadData, immediate(&rom, 4, &.{ 0x20, 0x3C }, 4));
    @memcpy(rom[8..14], &[_]u8{ 0x11, 0x7C, 0x00, 0x0A, 0x00, 0x41 });
    try std.testing.expectEqual(@as(i32, 10), try moveByte(&rom, 8, 0x41));
    try std.testing.expectError(error.BadData, moveByte(&rom, 8, 0x40));
}

// --- The special attack's police car --------------------------------------------------------------

/// The police car of the special attack, a stand-in (sorz's `police_car` behaviour): its frame
/// from its animation set (0x70A78), its sounds the requests its parts make (sor-remaster's
/// obj/police.zig, obj/special_blast.zig), and its times the ones sor-remaster measures from the
/// call to each (the catalogue's `player-special-axel.scn`), which the original's car, officer,
/// shells and camera make together (PLAN item 13 brings them).
pub fn policeCar(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set = 0x70A78;
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "police", .set = set, .box_table = object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    const car = try readAnimation(arena, rom, set, 0);
    const frames = try arena.alloc(entity.Frame, 1);
    frames[0] = .{ .frame = try d.frameName(car.frames[0].address), .ticks = 1 };
    try d.animations.append(arena, .{ .name = "car", .loop = true, .frames = frames });
    // The camera's run (its plane's special attack modes): back at 0x18CC4, ahead at 0x18DC2,
    // at the same speed; its limit at 0x192E4; the car comes at 0x18CDE.
    const back = try immediate(rom, 0x18CC4, &.{ 0x23, 0x7C }, 4);
    if (try immediate(rom, 0x18DC2, &.{ 0x23, 0x7C }, 4) != -back) return error.BadData;
    try d.number("run", -back, "ROM 0x18CC4 (move.l to the camera's speed; 0x18DC2 the same ahead)");
    try d.number("run_most", -(try immediate(rom, 0x192E4, &.{ 0x06, 0x80 }, 4)), "ROM 0x192E4 (addi.l to the camera's place)");
    try d.number("comes", (try immediate(rom, 0x18CDE, &.{ 0x04, 0x40 }, 2)) << 16, "ROM 0x18CDE (subi.w from the camera's place at the call)");
    const measured = "measured: the ticks from the car's coming in sor-remaster's special attack (catalogue player-special-axel.scn, player-special-enemies-axel.scn)";
    try d.number("siren", 29, measured);
    try d.number("brakes", 44, measured);
    try d.number("bazooka", 82, measured);
    try d.number("shell", 148, measured);
    try d.number("explosion", 201, measured);
    try d.number("blast", 245, measured);
    try d.number("run_ahead", 100, measured);
    try d.number("ends", 286, measured);
    try d.sound("siren", 0xCE);
    try d.sound("brakes", 0xAE);
    try d.sound("bazooka", 0xA9);
    try d.sound("shell", 0xAA);
    try d.sound("explosion", 0xAD);
    return .{
        .name = "police_car",
        .provenance = try std.fmt.allocPrint(arena, "the special attack's police car (type 5, 0x597C), a stand-in: its frame from the animation set at ROM 0x{X:0>5}{s}", .{ set, d.number_notes.items }),
        .family = .effect,
        .team = .neutral,
        .behaviour = "police_car",
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .animations = d.animations.items,
    };
}

/// The GO arrow (type $48, 0x67A4), which a section's opening shows (sorz's `go_arrow`
/// behaviour): its frame (animation 0 of the set at 0x6F06E, the effects' art), its place on the
/// screen, its blinks and their times, its sound, from the immediates of its code.
pub fn goArrow(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const set = 0x6F06E;
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "play", .set = set, .box_table = object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    const arrow = try readAnimation(arena, rom, set, 0);
    const index = std.mem.indexOfScalar(u32, d.frame_addresses, arrow.frames[0].address) orelse return error.BadData;
    const frames = try arena.alloc(entity.Frame, 1);
    frames[0] = .{ .frame = try std.fmt.allocPrint(arena, "play/arrow_{d:0>2}", .{index}), .ticks = 1 };
    try d.animations.append(arena, .{ .name = "arrow", .loop = true, .frames = frames });
    try d.number("x", try immediate(rom, 0x67CC, &.{ 0x34, 0x3C }, 2), "ROM 0x067CC (move.w #N,d2)");
    try d.number("depth", try immediate(rom, 0x67E2, &.{ 0x31, 0x7C }, 2), "ROM 0x067E2 (move.w #N,($14,a0))");
    try d.number("blinks", 1 + try immediate(rom, 0x67F2, &.{ 0x11, 0x7C }, 2), "ROM 0x067F2 (move.b #N,($50,a0): the blinks after the first)");
    try d.number("shown", try immediate(rom, 0x67FE, &.{ 0x11, 0x7C }, 2), "ROM 0x067FE (move.b #N,($0D,a0))");
    try d.number("hidden", try immediate(rom, 0x6820, &.{ 0x11, 0x7C }, 2), "ROM 0x06820 (move.b #N,($0D,a0))");
    try d.number("wait", try immediate(rom, 0x684E, &.{ 0x11, 0x7C }, 2), "ROM 0x0684E (move.b #N,($0D,a0))");
    if (rom[0x67F8] != 0x7E) return error.BadData;
    try d.sound("blink", rom[0x67F9]);
    return .{
        .name = "go_arrow",
        .provenance = try std.fmt.allocPrint(arena, "the GO arrow (type $48, 0x67A4): its frame from the animation set at ROM 0x{X:0>5}; its sound ROM 0x067F8 (moveq #N,d7){s}", .{ set, d.number_notes.items }),
        .family = .effect,
        .team = .neutral,
        .behaviour = "go_arrow",
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .animations = d.animations.items,
    };
}

/// A player out of lives (type $F, 0x5218): hidden, it asks the continue's question on the
/// status bar, or counts down the game over.
pub fn playerWaiting(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "play", .set = 0, .box_table = object_boxes, .frame_addresses = &.{} };
    const blink = try immediate(rom, 0x54B6, &.{ 0x31, 0x7C }, 2);
    if (blink >> 8 != blink & 0xFF) return error.BadData;
    try d.number("cursor_blink", blink & 0xFF, "ROM 0x054B6 (move.w #N,($60,a0): the cursor's ticks shown and hidden)");
    try d.number("out_wait", try immediate(rom, 0x5488, &.{ 0x11, 0x7C }, 2), "ROM 0x05488 (move.b #N,($60,a0): the game over's ticks when no continue is left)");
    if (rom[0x52CA] != 0x7E or rom[0x5288] != 0x7E) return error.BadData;
    try d.sound("cursor", rom[0x52CB]);
    try d.sound("game_over", rom[0x5289]);
    return .{
        .name = "player_waiting",
        .provenance = try std.fmt.allocPrint(arena, "the waiting player (type $F, 0x5218): the continue's question (0x52AE), the game over's count (0x5278); its sounds ROM 0x052CA and 0x05288 (moveq #N,d7); the count after a NO, 256 ticks (its timer cleared, 0x5256){s}", .{d.number_notes.items}),
        .family = .player,
        .team = .neutral,
        .behaviour = "player_waiting",
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
    };
}

/// The definitions the extractor writes, in the manifest's order.
pub fn all(arena: std.mem.Allocator, rom: []const u8) Error![]const entity.Definition {
    var out: std.ArrayList(entity.Definition) = .empty;
    try out.append(arena, try player(arena, rom, "axel", 0));
    try enemies.all(arena, rom, &out);
    try weapons.all(arena, rom, &out);
    try items.all(arena, rom, &out);
    try out.append(arena, try policeCar(arena, rom));
    try out.append(arena, try goArrow(arena, rom));
    try out.append(arena, try playerWaiting(arena, rom));
    return out.items;
}

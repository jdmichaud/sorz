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

const u16be = rom_mod.u16be;
const u32be = rom_mod.u32be;
const s16be = rom_mod.s16be;

pub const Error = error{ OutOfMemory, BadData };

fn s8(rom: []const u8, a: u32) i8 {
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
const depth_pairs = 0x1AB8E;
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
const throw_poses = 0xA3E8;
const slam_poses = 0xA416;
/// The places of a player holding an enemy by its animation from $70 (0x4A5A): a word offset per
/// animation pair (bit 15: present), a byte per character to its list, then 2 bytes a frame: X
/// toward the player's side and height from the one held.
const holder_places = 0x4C3E;

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
    pub const down = 0x54;
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
};

// --- Reading an animation ----------------------------------------------------------------------

/// A frame of an animation as the set holds it: the frame's address, drawn mirrored or not, and
/// the box indices it uses that way (the frame holds a pair for each way).
const RawFrame = struct { address: u32, mirrored: bool, attack: u8, body: u8 };

const RawAnimation = struct { timing: u8, frames: []RawFrame };

/// Entry `entry` of the set at `set`: a count, a timing, and the frames' word offsets from the
/// animation (bit 15: drawn mirrored); a frame's box pair is its bytes 1 and 2, or 3 and 4 drawn
/// mirrored (0x3B12).
fn readAnimation(arena: std.mem.Allocator, rom: []const u8, set: u32, entry: u32) Error!RawAnimation {
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
const Spans = struct { x: entity.Span, depth: entity.Span, height: entity.Span };

fn playerBox(rom: []const u8, n: u8) Spans {
    return tableBox(rom, player_boxes, n);
}

/// Box `n` of the box table at `table` (the players' or the other objects', 0xAB24).
fn tableBox(rom: []const u8, table: u32, n: u8) Spans {
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
const Def = struct {
    arena: std.mem.Allocator,
    rom: []const u8,
    /// The art set's directory, its animation set, and the set's frames in address order, which
    /// name the frames.
    dir: []const u8,
    set: u32,
    frame_addresses: []const u32,
    /// The box table of its frames: the players' or the other objects'.
    box_table: u32 = player_boxes,
    numbers: std.ArrayList(entity.Number) = .empty,
    number_notes: std.ArrayList(u8) = .empty,
    sounds: std.ArrayList(entity.Sound) = .empty,
    boxes: std.ArrayList(entity.Box) = .empty,
    box_keys: std.ArrayList([3]u8) = .empty,
    animations: std.ArrayList(entity.Animation) = .empty,
    moves: std.ArrayList(entity.Move) = .empty,

    fn frameName(d: *Def, address: u32) Error![]const u8 {
        const i = std.mem.indexOfScalar(u32, d.frame_addresses, address) orelse return error.BadData;
        return std.fmt.allocPrint(d.arena, "{s}/{d:0>3}", .{ d.dir, i });
    }

    /// The number `name`; its place goes in the definition's provenance.
    fn number(d: *Def, name: []const u8, value: i32, place: []const u8) Error!void {
        try d.numbers.append(d.arena, .{ .name = name, .value = value });
        try d.number_notes.print(d.arena, "; {s}: {s}", .{ name, place });
    }

    /// The box of the pair (`right`, `left`) of the players' table in role `role`, named the
    /// first time after the animation `animation` that uses it.
    fn box(d: *Def, role: u8, right: u8, left: u8, animation: []const u8, role_name: []const u8) Error!?u8 {
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

    fn animationIndex(d: *const Def, name: []const u8) ?u8 {
        for (d.animations.items, 0..) |a, i| if (std.mem.eql(u8, a.name, name)) return @intCast(i);
        return null;
    }

    fn sound(d: *Def, role: []const u8, request: u8) Error!void {
        try d.sounds.append(d.arena, .{ .name = role, .sound = try soundName(request) });
    }
};

/// The sound content's name of the original's request `request`.
fn soundName(request: u8) Error![]const u8 {
    for (sound_names.entries) |e| if (e.request == request) return e.name;
    return error.BadData;
}

/// The immediate value of the instruction at `at`, checked: its first bytes must be `opcode`;
/// the value is the `width` bytes after them (1: the low byte of a word, a `moveq`'s byte), sign
/// extended.
fn immediate(rom: []const u8, at: u32, opcode: []const u8, width: u8) Error!i32 {
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
fn moveByte(rom: []const u8, at: u32, displacement: u8) Error!i32 {
    if (u16be(rom, at) != 0x117C or rom[at + 2] != 0 or u16be(rom, at + 4) != displacement) return error.BadData;
    return rom[at + 3];
}

/// `cmpi.b #N,(10,a0)`: a frame of the animation compared.
fn frameCompared(rom: []const u8, at: u32) Error!i32 {
    if (u16be(rom, at) != 0x0C28 or rom[at + 2] != 0 or u16be(rom, at + 4) != 10) return error.BadData;
    return rom[at + 3];
}

/// `moveq #N,dR`.
fn moveq(rom: []const u8, at: u32, register: u3) Error!i32 {
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
    .{ .name = "recover", .state = State.recover },
    .{ .name = "grab", .state = State.grab },
    .{ .name = "grab_blow", .state = State.grab_blow },
    .{ .name = "grab_behind", .state = State.grab_behind },
    .{ .name = "vault", .state = State.vault },
    .{ .name = "knee", .state = State.knee },
    .{ .name = "knee_last", .state = State.knee_last },
    .{ .name = "throw", .state = State.throw },
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
    try d.number("jump", @bitCast(u32be(rom, jump_speeds + 4 * @as(u32, character))), "ROM 0x03842, by character");
    try d.number("jump_x", try immediate(rom, 0x384E, &.{ 0x20, 0x3C }, 4), "ROM 0x0384E: move.l #N,d0");
    try d.number("steer", try immediate(rom, 0x38F0, &.{ 0x20, 0x3C }, 4), "ROM 0x038F0: move.l #N,d0");
    try d.number("steer_most", -(try immediate(rom, 0x38FA, &.{ 0x20, 0x3C }, 4)), "ROM 0x038FA: move.l #-N,d0");
    try d.number("kick_falling_gravity", try immediate(rom, 0x38B4, &.{ 0x20, 0x3C }, 4), "ROM 0x038B4: move.l #N,d0");
    try d.number("fall_most", try immediate(rom, 0x3886, &.{ 0x0C, 0xA8 }, 4), "ROM 0x03886: cmpi.l #N,(36,a0)");
    try d.number("drop", try immediate(rom, 0x3E20, &.{ 0x21, 0x7C }, 4), "ROM 0x03E20: move.l #N,(36,a0)");
    try d.number("knocked_down_up", try immediate(rom, 0x34DA, &.{ 0x21, 0x7C }, 4), "ROM 0x034DA: move.l #N,(36,a0)");
    try d.number("hurt", try moveByte(rom, 0x348C, 0x41), "ROM 0x0348C: move.b #N,($41,a0)");
    try d.number("down", try moveByte(rom, 0x3F66, 0x41), "ROM 0x03F66: move.b #N,($41,a0)");
    try d.number("blink", try moveByte(rom, 0x4F6A, 0x49), "ROM 0x04F6A: move.b #N,($49,a0)");
    try d.number("combo_window", try moveByte(rom, 0x2034, 0x5C), "ROM 0x02034: move.b #N,($5C,a0)");
    try d.number("hit_pause", try moveByte(rom, 0x21D8, 0x4F), "ROM 0x021D8: move.b #N,($4F,a0)");
    try d.number("let_go", try moveByte(rom, 0x32CE, 0x63), "ROM 0x032CE: move.b #N,($63,a0)");
    try d.number("hurry_first", try moveByte(rom, 0x2060, 13), "ROM 0x02060: move.b #N,(13,a0)");
    try d.number("hurry_later", try moveByte(rom, 0x206E, 13), "ROM 0x0206E: move.b #N,(13,a0)");
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

// --- The enemies ---------------------------------------------------------------------------------

/// A long per enemy type from $20: its animation set (0x938C).
const enemy_sets = 0x27032;
/// The other objects' box table (0xAB24).
const object_boxes = 0x1A68E;
/// Per enemy type from $20, 6 bytes by palette variant: its health's low byte, then three bytes
/// on its power (0x93CE).
const enemy_numbers = 0x26FCE;
/// The sine and the cosine of each slope of 64ths (0x982C).
const slopes = 0x2705E;
/// The walk off's pacing (0xDD26): a stretch's ticks, and its speed (8.8) with its frames' ticks.
const pace_lengths = 0x1033A;
const pace_speeds = 0xDD68;

/// The frames of an enemy's entry `entry` (facing right) with the next one's (facing left), each
/// shown for the animation's timing byte, as the objects' animations run (0xB0B6).
fn enemyFrames(d: *Def, name: []const u8, entry: u32) Error![]entity.Frame {
    const right = try readAnimation(d.arena, d.rom, d.set, entry);
    const left = try readAnimation(d.arena, d.rom, d.set, entry + 1);
    if (right.frames.len != left.frames.len or right.timing == 0) return error.BadData;
    const out = try d.arena.alloc(entity.Frame, right.frames.len);
    for (out, right.frames, left.frames) |*f, r, l| {
        if (r.address != l.address or r.mirrored == l.mirrored) return error.BadData;
        f.* = .{
            .frame = try d.frameName(r.address),
            .ticks = right.timing,
            .flip = r.mirrored,
            .body = try d.box(0, r.body, l.body, name, "body"),
            .attack = try d.box(1, r.attack, l.attack, name, "attack"),
        };
    }
    return out;
}

/// The Galsias of round 1 (type $22, its handler 0xDD78, sor-remaster's obj/galsia.zig), as the
/// first wave's close in on a player and punch (the other ways to approach come with PLAN item
/// 12).
pub fn galsia(arena: std.mem.Allocator, rom: []const u8) Error!entity.Definition {
    const kind = 0x22 - 0x20;
    const set = u32be(rom, enemy_sets + 4 * kind);
    var d: Def = .{ .arena = arena, .rom = rom, .dir = "galsia", .set = set, .box_table = object_boxes, .frame_addresses = try sprites.frameAddresses(arena, rom, set) };
    // The animations by the entries the code starts (0x96C4 with the animation's offset).
    const anims = [_]struct { name: []const u8, entry: u32 }{
        .{ .name = "walk", .entry = 0 },
        // Knocked down: the flight, lying, getting up; frame 5 upside down in a back drop.
        .{ .name = "down", .entry = 2 },
        .{ .name = "reel", .entry = 4 },
        .{ .name = "stand", .entry = 6 },
        // Held in front, and thrown over a shoulder.
        .{ .name = "thrown", .entry = 8 },
        .{ .name = "punch", .entry = 10 },
    };
    for (anims) |an| try d.animations.append(arena, .{ .name = an.name, .loop = true, .frames = try enemyFrames(&d, an.name, an.entry) });
    // Slammed down in a back drop, it shows the poses of its knock-down's frames (0xA2EC).
    try d.animations.append(arena, .{ .name = "slammed", .loop = true, .frames = d.animations.items[d.animationIndex("down").?].frames });

    // The punch: a string of blows (its frames with an attack box); from its last punch's frame
    // on (0xE1FA), a blow that lands knocks down. The reach the Galsia punches from is its first
    // jab's box (0xE102); the last punch's box is tested once (0xE1D8).
    const punch: []entity.Frame = @constCast(d.animations.items[d.animationIndex("punch").?].frames);
    for (punch) |*f| f.blow = f.attack != null;
    const reach_box = try moveq(rom, 0xE102, 1);
    const last_box = try moveq(rom, 0xE1D8, 1);
    const reach_frame = for (punch, 0..) |f, j| {
        if (f.attack) |b| if (d.box_keys.items[b][1] == reach_box) break j;
    } else return error.BadData;
    const last_frame = for (punch, 0..) |f, j| {
        if (f.attack) |b| if (d.box_keys.items[b][1] == last_box) break j;
    } else return error.BadData;
    const knocks_from = try frameCompared(rom, 0xE1FA);
    if (knocks_from != last_frame) return error.BadData;
    const power = rom[enemy_numbers + 6 * kind + 3];
    try d.moves.append(arena, .{ .name = "punch", .provenance = "the punch (0xE190), its power ROM 0x26FDB (0x93CE)", .animation = d.animationIndex("punch").?, .damage = power });
    try d.moves.append(arena, .{ .name = "punch_last", .provenance = "the punch's last blow, from frame 7 on (0xE1FA): it knocks down", .animation = d.animationIndex("punch").?, .damage = power, .reaction = .knock_down });

    try d.number("reach_frame", @intCast(reach_frame), "the punch's frame with box 18 (ROM 0x0E102: moveq #18,d1)");
    try d.number("last_punch_frame", @intCast(last_frame), "the punch's frame with box 62 (ROM 0x0E1D8: moveq #62,d1)");
    try d.number("last_punch_test", try frameCompared(rom, 0xE1CA), "ROM 0x0E1CA: cmpi.b #N,(10,a0)");
    try d.number("punch_ends", try frameCompared(rom, 0xE1EA), "ROM 0x0E1EA: cmpi.b #N,(10,a0)");
    try d.number("appears_from", try immediate(rom, 0x97E8, &.{ 0x0C, 0x68 }, 2) - 0x80, "ROM 0x097E8: cmpi.w #N+$80,(40,a0)");
    try d.number("appears_to", try immediate(rom, 0x97F0, &.{ 0x0C, 0x68 }, 2) - 0x80 - 1, "ROM 0x097F0: cmpi.w #N+$81,(40,a0)");
    // The first wave's variant closes in at the slower speed (0xE158, variant bit 5).
    try d.number("close_in_speed", try immediate(rom, 0xE158, &.{ 0x31, 0x7C }, 2) * 0x100, "ROM 0x0E158: move.w #N,(100,a0) (8.8)");
    try d.number("close_in_ticks", try moveByte(rom, 0xE144, 80), "ROM 0x0E144: move.b #N,(80,a0)");
    try d.number("close_in_beside", try moveq(rom, 0xE16A, 1), "ROM 0x0E16A: moveq #N,d1");
    try d.number("close_in_pace", (try immediate(rom, 0xE138, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0E138: move.w #N*$100+1,(12,a0)");
    try d.number("reel", try moveByte(rom, 0x9B90, 80), "ROM 0x09B90: move.b #N,(80,a0)");
    try d.number("reel_nudge", try moveq(rom, 0x9BF2, 0), "ROM 0x09BF2: moveq #N,d0");
    try d.number("knocked_x", try immediate(rom, 0x992E, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x0992E: move.w #N,(28,a0)");
    try d.number("knocked_out_x", try immediate(rom, 0x9940, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x09940: move.w #N,(28,a0)");
    try d.number("knocked_up", try immediate(rom, 0x9934, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x09934: move.w #N,(36,a0)");
    try d.number("knocked_slowing", try immediate(rom, 0x99D2, &.{ 0x20, 0x3C }, 4), "ROM 0x099D2: move.l #N,d0");
    try d.number("bounce_most", (try immediate(rom, 0x9A72, &.{ 0x0C, 0x68 }, 2)) << 16, "ROM 0x09A72: cmpi.w #N,(36,a0)");
    try d.number("bounce_slowing", try immediate(rom, 0x9A92, &.{ 0x20, 0x3C }, 4), "ROM 0x09A92: move.l #N,d0");
    try d.number("lying", (try immediate(rom, 0x9A26, &.{ 0x31, 0x7C }, 2)) & 0xFF, "ROM 0x09A26: move.w #N*$101,(12,a0)");
    if (rom[0x9A4E] & 0xF1 != 0x50 or rom[0x9A4F] != 0) return error.BadData;
    try d.number("lying_least", @as(i32, rom[0x9A4E] >> 1) & 7, "ROM 0x09A4E: addq.b #N,d0 (the draw's low two bits, doubled)");
    try d.number("gets_up_frame", try frameCompared(rom, 0x9A5A), "ROM 0x09A5A: cmpi.b #N,(10,a0)");
    try d.number("fall_most", try immediate(rom, 0x974E, &.{ 0x0C, 0xA8 }, 4), "ROM 0x0974E: cmpi.l #N,(36,a0)");
    try d.number("blinks", (try immediate(rom, 0x9D36, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x09D36: move.w #N*$100+T,(70,a0)");
    try d.number("first_blink", (try immediate(rom, 0x9D36, &.{ 0x31, 0x7C }, 2)) & 0xFF, "ROM 0x09D36: move.w #B*$100+N,(70,a0)");
    try d.number("blink", try moveByte(rom, 0x9D84, 71), "ROM 0x09D84: move.b #N,(71,a0)");
    try d.number("struck_held", try moveByte(rom, 0xA180, 80), "ROM 0x0A180: move.b #N,(80,a0)");
    try d.number("flipped_x", try immediate(rom, 0xA218, &.{ 0x31, 0x7C }, 2) << 16, "ROM 0x0A218: move.w #N,(28,a0)");
    try d.number("flipped_up", try immediate(rom, 0xA21E, &.{ 0x21, 0x7C }, 4), "ROM 0x0A21E: move.l #N,(36,a0)");
    try d.number("thrown_x", try immediate(rom, 0xA26C, &.{ 0x20, 0x3C }, 4), "ROM 0x0A26C: move.l #N,d0");
    try d.number("thrown_up", try immediate(rom, 0xA272, &.{ 0x22, 0x3C }, 4), "ROM 0x0A272: move.l #N,d1");
    try d.number("thrown_slide", try moveByte(rom, 0xA2C4, 80), "ROM 0x0A2C4: move.b #N,(80,a0)");
    try d.number("slam_ticks", try moveByte(rom, 0xA300, 80), "ROM 0x0A300: move.b #N,(80,a0)");
    try d.number("slammed_x", try immediate(rom, 0xA358, &.{ 0x21, 0x7C }, 4), "ROM 0x0A358: move.l #N,(28,a0)");
    try d.number("slammed_up", try immediate(rom, 0xA360, &.{ 0x21, 0x7C }, 4), "ROM 0x0A360: move.l #N,(36,a0)");
    try d.number("grab_height", try immediate(rom, 0xAAF6, &.{ 0x0C, 0x42 }, 2), "ROM 0x0AAF6: cmpi.w #N,d2");
    // Its heading toward a point (0x982C) takes the sine and cosine of a slope from the table
    // at 0x2705E: the world computes the same table (world/fixed.zig), checked here.
    for (sorz.world.fixed.slopes[1..], 1..) |sl, k| {
        const at = slopes + 4 * @as(u32, @intCast(k));
        if (u16be(rom, at) != sl.sine or u16be(rom, at + 2) != sl.cosine) return error.BadData;
    }
    // Held still by the special attack (0xA496): a pose by its place across's low two bits.
    try d.number("special_spin_frame", try moveByte(rom, 0xA4FC, 10), "ROM 0x0A4FC: move.b #N,(10,a0)");
    try d.number("special_spin_turn", try moveByte(rom, 0xA502, 81), "ROM 0x0A502: move.b #N,(81,a0)");
    try d.number("special_down_frame", try moveByte(rom, 0xA530, 10), "ROM 0x0A530: move.b #N,(10,a0)");
    try d.number("special_shake_pace", (try immediate(rom, 0xA54C, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0A54C: move.w #N*$101,(12,a0)");
    try d.number("special_shake_turn", try moveByte(rom, 0xA552, 81), "ROM 0x0A552: move.b #N,(81,a0)");
    // The walk off (0xDBCC): away in depth, then pacing across near its target.
    try d.number("walk_off_pace", (try immediate(rom, 0xDBEC, &.{ 0x31, 0x7C }, 2)) >> 8, "ROM 0x0DBEC: move.w #N*$100+1,(12,a0)");
    try d.number("walk_off_depth", try immediate(rom, 0xDC1A, &.{ 0x20, 0x3C }, 4), "ROM 0x0DC1A: move.l #N,d0");
    try d.number("walk_off_faster", try immediate(rom, 0xDC28, &.{ 0x20, 0x3C }, 4), "ROM 0x0DC28: move.l #N,d0");
    try d.number("walk_off_fastest", try immediate(rom, 0xDC36, &.{ 0x20, 0x3C }, 4), "ROM 0x0DC36: move.l #N,d0");
    try d.number("walk_off_faster_after", try immediate(rom, 0xDC20, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x0DC20: cmpi.b #N,(110,a0)");
    try d.number("walk_off_fastest_after", try immediate(rom, 0xDC2E, &.{ 0x0C, 0x28, 0x00 }, 1), "ROM 0x0DC2E: cmpi.b #N,(110,a0)");
    try d.number("walk_off_up_from", try immediate(rom, 0xDC66, &.{ 0x0C, 0x69 }, 2), "ROM 0x0DC66: cmpi.w #N,(20,a1)");
    try d.number("walk_off_down_to", try immediate(rom, 0xDCCA, &.{ 0x0C, 0x68 }, 2), "ROM 0x0DCCA: cmpi.w #N,(20,a0)");
    try d.number("walk_off_up_to", try immediate(rom, 0xDCD6, &.{ 0x0C, 0x68 }, 2), "ROM 0x0DCD6: cmpi.w #N,(20,a0)");
    try d.number("walk_off_again", try immediate(rom, 0xDC7C, &.{ 0x0C, 0x40 }, 2), "ROM 0x0DC7C: cmpi.w #N,d0");
    try d.number("walk_off_near", try moveq(rom, 0xDD12, 0), "ROM 0x0DD12: moveq #N,d0");
    {
        if (u32be(rom, 0xDD2E + 2) != pace_lengths) return error.BadData;
        for (0..4) |k| {
            const kk: u32 = @intCast(k);
            try d.number(try std.fmt.allocPrint(arena, "pacing_{d}", .{k}), rom[pace_lengths + kk], "ROM 0x1033A: a stretch's ticks by a draw's low two bits (0xDD26)");
            try d.number(try std.fmt.allocPrint(arena, "pacing_speed_{d}", .{k}), @as(i32, u16be(rom, pace_speeds + 4 * kk)) << 8, "ROM 0x0DD68: its speed (8.8)");
            try d.number(try std.fmt.allocPrint(arena, "pacing_pace_{d}", .{k}), u16be(rom, pace_speeds + 4 * kk + 2) >> 8, "ROM 0x0DD6A: its frames' ticks");
        }
    }

    try d.sound("hurt", @bitCast(@as(i8, @intCast(try moveq(rom, 0x9BC6, 7)))));
    try d.sound("thud", @bitCast(@as(i8, @intCast(try moveq(rom, 0x9AB6, 7)))));
    // The knockout cry (0x997E): one for an even place across, another for an odd one.
    try d.sound("cry", @bitCast(@as(i8, @intCast(try moveq(rom, 0x9990, 7)))));
    try d.sound("cry_odd", @bitCast(@as(i8, @intCast(try moveq(rom, 0x999A, 7)))));

    return .{
        .name = "galsia",
        .provenance = try std.fmt.allocPrint(arena, "enemy type $22: the animation set at ROM 0x{X:0>5} (0x27032), the boxes (0x1A68E, 0x1AB8E); health ROM 0x26FDA (0x93CE); gravity ROM 0x0973E: addi.l #N,(36,a0){s}", .{ set, d.number_notes.items }),
        .family = .enemy,
        .team = .enemy,
        .behaviour = "galsia",
        .health = rom[enemy_numbers + 6 * kind],
        .gravity = try immediate(rom, 0x973E, &.{ 0x06, 0xA8 }, 4),
        .shadow = true,
        .numbers = d.numbers.items,
        .sounds = d.sounds.items,
        .boxes = d.boxes.items,
        .animations = d.animations.items,
        .moves = d.moves.items,
    };
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
    const measured = "measured: the ticks from the call in sor-remaster's special attack (catalogue player-special-axel.scn)";
    try d.number("siren", 61, measured);
    try d.number("brakes", 76, measured);
    try d.number("bazooka", 114, measured);
    try d.number("shell", 180, measured);
    try d.number("explosion", 233, measured);
    try d.number("blast", 278, measured);
    try d.number("ends", 318, measured);
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

/// The definitions the extractor writes, in the manifest's order.
pub fn all(arena: std.mem.Allocator, rom: []const u8) Error![]const entity.Definition {
    const out = try arena.alloc(entity.Definition, 3);
    out[0] = try player(arena, rom, "axel", 0);
    out[1] = try galsia(arena, rom);
    out[2] = try policeCar(arena, rom);
    return out;
}

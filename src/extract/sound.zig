//! The sound content from the ROM (docs/content-sound.md, sound port map): the 68000 driver's
//! songs and effects as sequences of events, their instruments, the driver's tables, the Z80
//! player's samples, and the names the game asks for. The one place that knows where they are.
const std = @import("std");
const sorz = @import("sorz");
const content = sorz.audio.content;
const tracks = @import("sound_tracks.zig");
const sound_samples = @import("sound_samples.zig");
const names = @import("sound_names.zig");
const rom_mod = @import("rom.zig");
const registers = sorz.audio.chips.registers;

pub const Refusal = tracks.Refusal;
pub const Error = tracks.Error;

// The driver's tables (sound port map 2.3).
const priority_table = 0x72824; // a byte per request $81-$E8
const music_table = 0x7288C; // 17 songs, $81-$91
const envelope_table = 0x728D0; // PSG envelopes 1-5
const fm3_registers = 0x72D04; // FM3's special-mode frequency registers, by offset
const music_channel_steps = 0x72F7C; // the channel codes of the music's six FM tracks, as steps
const fm_keys = 0x732D2; // F-numbers of C to B, then 4 words past B
const volume_table = 0x73600; // read with a signed index
const carrier_table = 0x73728;
const psg_steps = 0x73A64; // 120 dividers and a 0
const effect_table = 0x73B56; // 48 effects, $A0-$CF
const voice_size = 25;

/// The content, and for each sound (by its index in `content.sounds`) the request byte the
/// original's code sends for it: the comparison with the reference drives it by those.
pub const Extracted = struct {
    content: content.Content,
    requests: []const u8,
};

pub fn extract(arena: std.mem.Allocator, rom: []const u8, refusal: *Refusal) Error!Extracted {
    if (rom.len < rom_mod.size) return refusal.refuse("the ROM is too short", 0);
    var x: Extractor = .{ .arena = arena, .rom = rom, .refusal = refusal };
    return x.run();
}

/// The sound's files of the content tree (`sound/...`), for the extractor's core to add to the
/// tree.
pub fn files(arena: std.mem.Allocator, c: *const content.Content) ![]const sorz.audio.files.File {
    return sorz.audio.files.write(arena, c);
}

const Extractor = struct {
    arena: std.mem.Allocator,
    rom: []const u8,
    refusal: *Refusal,
    /// Where every song and effect starts: an item ends where the next one starts.
    starts: std.ArrayList(u32) = .empty,
    /// The instrument numbers any effect asks for. An effect's instruments are read from the
    /// list of the effect started last, so an effect playing on FM3 when one starts on FM4 reads
    /// its numbers in the other's list: each effect's file holds every one of these numbers its
    /// own list has.
    effect_numbers: std.StaticBitSet(256) = .empty,

    fn u16be(x: *Extractor, a: u32) u16 {
        return rom_mod.u16be(x.rom, a);
    }

    fn u32be(x: *Extractor, a: u32) u32 {
        return rom_mod.u32be(x.rom, a);
    }

    fn run(x: *Extractor) Error!Extracted {
        for (0..17) |i| try x.starts.append(x.arena, x.u32be(music_table + 4 * @as(u32, @intCast(i))));
        for (0..48) |i| try x.starts.append(x.arena, x.u32be(effect_table + 4 * @as(u32, @intCast(i))));
        for (x.starts.items) |a| if (a + 8 > x.rom.len) return x.refusal.refuse("a song or an effect past the ROM's end", a);
        std.mem.sort(u32, x.starts.items, {}, std.sort.asc(u32));
        for (0..48) |i| {
            const a = x.u32be(effect_table + 4 * @as(u32, @intCast(i)));
            const start = a +% @as(u32, @bitCast(@as(i32, rom_mod.s16be(x.rom, a + 4))));
            for (try tracks.decode(x.arena, x.rom, start, .fm, x.rom[a + 3], x.refusal)) |ev| {
                if (ev == .instrument) x.effect_numbers.set(ev.instrument);
            }
        }

        var song_list: std.ArrayList(content.Song) = .empty;
        var song_at: std.ArrayList(u32) = .empty;
        var effect_list: std.ArrayList(content.Effect) = .empty;
        var sound_list: std.ArrayList(content.Sound) = .empty;
        var requests: std.ArrayList(u8) = .empty;
        const all_samples = try x.sampleList();
        for (names.entries) |e| {
            const priority = x.rom[priority_table + @as(u32, e.request) - 0x81];
            const plays: content.Plays = switch (e.request) {
                0x81...0x91 => blk: {
                    const a = x.u32be(music_table + 4 * @as(u32, e.request - 0x81));
                    const index = std.mem.indexOfScalar(u32, song_at.items, a) orelse new: {
                        try song_list.append(x.arena, try x.song(a, e));
                        try song_at.append(x.arena, a);
                        break :new song_at.items.len - 1;
                    };
                    break :blk .{ .song = @intCast(index) };
                },
                0xA0...0xCF => blk: {
                    try effect_list.append(x.arena, try x.effect(x.u32be(effect_table + 4 * @as(u32, e.request - 0xA0)), e));
                    break :blk .{ .effect = @intCast(effect_list.items.len - 1) };
                },
                // $D0 + n asks the player for sample n + 5.
                0xD0...0xDB => .{ .sample = e.request - 0xD0 + sound_samples.first_voice },
                0xE0 => .fade_out,
                0xE1 => .stop,
                0xE2 => .stop_effects,
                else => return x.refusal.refuse("a named request the content has no kind for", e.request),
            };
            try sound_list.append(x.arena, .{
                .name = e.name,
                .priority = priority,
                .plays = plays,
                .request = e.request,
                .provenance = try std.fmt.allocPrint(x.arena, "request ${X:0>2}: {s}", .{ e.request, e.note }),
            });
            try requests.append(x.arena, e.request);
        }
        return .{
            .content = .{
                .driver = try x.driver(),
                .songs = song_list.items,
                .effects = effect_list.items,
                .samples = all_samples,
                .sounds = sound_list.items,
            },
            .requests = requests.items,
        };
    }

    /// Where the item that holds `a` ends: the next item's start, the samples' bank, or the
    /// ROM's end.
    fn itemEnd(x: *Extractor, a: u32) u32 {
        var end: u32 = @intCast(x.rom.len);
        if (a < sound_samples.bank) end = sound_samples.bank;
        for (x.starts.items) |s| if (s > a) return @min(s, end);
        return end;
    }

    fn song(x: *Extractor, a: u32, e: names.Entry) Error!content.Song {
        // The voice table's offset is unsigned; the FM tracks' are signed, the PSG tracks'
        // unsigned (sound port map 2.4).
        const voices = a + x.u16be(a);
        if (x.rom[a + 2] != 6) return x.refusal.refuse("a song without six FM tracks", a);
        const psg_count = x.rom[a + 3];
        if (psg_count > 3) return x.refusal.refuse("a song with more than three PSG tracks", a);
        // Every voice of the table, up to the item's end and before a voice of fill bytes.
        var instruments: std.ArrayList(content.Instrument) = .empty;
        const end = x.itemEnd(voices);
        var n: u32 = 0;
        while (voices + voice_size * (n + 1) <= end) : (n += 1) {
            const bytes = x.rom[voices + voice_size * n ..][0..voice_size];
            if (std.mem.allEqual(u8, bytes, 0xFF)) break;
            try instruments.append(x.arena, x.instrument(bytes, @intCast(n)));
        }
        const own = instruments.items.len;
        // The effects' numbers past the list, which an effect can load from it (`borrowed`).
        var numbers = x.effect_numbers.iterator(.{});
        while (numbers.next()) |k| if (k >= own and voices + voice_size * (k + 1) <= x.rom.len) {
            var i = x.instrument(x.rom[voices + voice_size * k ..][0..voice_size], @intCast(k));
            i.borrowed = true;
            try instruments.append(x.arena, i);
        };
        var s: content.Song = .{
            .name = e.file,
            .provenance = try std.fmt.allocPrint(x.arena, "request ${X:0>2}, header at ROM 0x{X}, instruments at 0x{X}", .{ e.request, a, voices }),
            .instruments = instruments.items,
            .fm = undefined,
            .drums = undefined,
            .psg = &.{},
        };
        var channel: u8 = 0;
        for (0..6) |k| {
            const at = a + 4 + 3 * @as(u32, @intCast(k));
            channel += x.rom[music_channel_steps + k];
            if (channel != ([_]u8{ 0, 1, 2, 4, 5, 6 })[k]) return x.refusal.refuse("the music's FM tracks on other channels than FM1-FM6", music_channel_steps);
            const start = a +% @as(u32, @bitCast(@as(i32, rom_mod.s16be(x.rom, at))));
            const kind: tracks.Kind = if (k == 5) .drums else .fm;
            const t: content.Track = .{
                .volume_offset = x.rom[at + 2],
                .events = try tracks.decode(x.arena, x.rom, start, kind, channel, x.refusal),
            };
            try x.check(t.events, kind, own, start);
            if (k == 5) s.drums = t else s.fm[k] = t;
        }
        const psg = try x.arena.alloc(content.Track, psg_count);
        for (psg, 0..) |*t, k| {
            const at = a + 4 + 18 + 4 * @as(u32, @intCast(k));
            const start = a + x.u16be(at);
            t.* = .{
                .volume_offset = x.rom[at + 2],
                .envelope = x.rom[at + 3],
                .events = try tracks.decode(x.arena, x.rom, start, .psg, 0, x.refusal),
            };
            if (t.envelope > 5) return x.refusal.refuse("a PSG track starting with an envelope past the table", at);
            try x.check(t.events, .psg, 0, start);
        }
        s.psg = psg;
        return s;
    }

    fn effect(x: *Extractor, a: u32, e: names.Entry) Error!content.Effect {
        const voices = a +% @as(u32, @bitCast(@as(i32, rom_mod.s16be(x.rom, a))));
        const channel = x.rom[a + 3];
        const start = a +% @as(u32, @bitCast(@as(i32, rom_mod.s16be(x.rom, a + 4))));
        const events = try tracks.decode(x.arena, x.rom, start, .fm, channel, x.refusal);
        try x.check(events, .fm, 0x80, start);
        // The instruments the effect uses, by number, and those any other effect uses that its
        // list holds (`effect_numbers`).
        var own: std.StaticBitSet(256) = .empty;
        for (events) |ev| if (ev == .instrument) own.set(ev.instrument);
        var instruments: std.ArrayList(content.Instrument) = .empty;
        var numbers = x.effect_numbers.iterator(.{});
        while (numbers.next()) |n| {
            const at = voices + voice_size * @as(u32, @intCast(n));
            const used = own.isSet(n);
            if (at + voice_size > x.rom.len) {
                if (used) return x.refusal.refuse("an effect's instrument past the ROM's end", at);
                continue;
            }
            var i = x.instrument(x.rom[at..][0..voice_size], @intCast(n));
            i.borrowed = !used;
            try instruments.append(x.arena, i);
        }
        return .{
            .name = e.file,
            .provenance = try std.fmt.allocPrint(x.arena, "request ${X:0>2}, header at ROM 0x{X}, instruments from 0x{X}", .{ e.request, a, voices }),
            .channel = switch (channel) {
                2 => .fm3,
                4 => .fm4,
                else => return x.refusal.refuse("an effect on another channel than FM3 or FM4", a),
            },
            .volume_offset = x.rom[a + 2],
            .instruments = instruments.items,
            .events = events,
        };
    }

    /// The checks of a track's events against the driver's tables: instruments in the list,
    /// notes and envelopes in their tables.
    fn check(x: *Extractor, events: []const content.Event, kind: tracks.Kind, instruments: usize, start: u32) Error!void {
        for (events) |ev| switch (ev) {
            .instrument => |n| if (kind == .fm and n >= instruments)
                return x.refusal.refuse("an instrument the song's or effect's list does not hold", start),
            .note => |nt| if (kind == .psg and nt.step > 120) return x.refusal.refuse("a PSG note past the table", start),
            .envelope => |n| if (n > 5) return x.refusal.refuse("an envelope past the table", start),
            else => {},
        };
    }

    /// An instrument from its 25 bytes: the operators' parameter groups ($30 to $80, each for the
    /// operators in register order), then the algorithm's byte. Bits the chip ignores are kept.
    fn instrument(_: *Extractor, bytes: *const [voice_size]u8, number: u8) content.Instrument {
        var i: content.Instrument = .{
            .number = number,
            .algorithm = @intCast(bytes[24] & 7),
            .feedback = @intCast(bytes[24] >> 3 & 7),
            .operators = undefined,
            .ignored = bytes[24] & 0xC0,
        };
        for (0..4) |slot| {
            var g: [6]u8 = undefined;
            for (&g, 0..) |*b, group| b.* = bytes[4 * group + slot];
            const o = &i.operators[@backingInt(tracks.operatorOfSlot(@intCast(slot)))];
            o.* = .{
                .detune = @intCast(g[0] >> 4 & 7),
                .multiple = @intCast(g[0] & 15),
                .level = @intCast(g[1] & 0x7F),
                .key_scale = @intCast(g[2] >> 6),
                .attack = @intCast(g[2] & 31),
                .am = g[3] & 0x80 != 0,
                .decay = @intCast(g[3] & 31),
                .sustain_rate = @intCast(g[4] & 31),
                .sustain_level = @intCast(g[5] >> 4),
                .release = @intCast(g[5] & 15),
            };
            for (&o.ignored, g, std.enums.values(content.Parameter)) |*ig, b, p| ig.* = b & registers.ignoredBits(p);
        }
        return i;
    }

    fn driver(x: *Extractor) Error!content.Driver {
        var d: content.Driver = .{};
        for (&d.fm_keys, 0..) |*k, i| k.* = x.u16be(fm_keys + 2 * @as(u32, @intCast(i)));
        for (&d.psg_steps, 0..) |*s, i| s.* = x.u16be(psg_steps + 2 * @as(u32, @intCast(i)));
        for (&d.volume_levels, 0..) |*v, i| {
            const signed: i32 = @as(i8, @bitCast(@as(u8, @intCast(i))));
            v.* = x.rom[@intCast(volume_table + signed)];
        }
        for (&d.carriers, 0..) |*c, alg| {
            const mask = x.rom[carrier_table + alg];
            if (mask & 0xF0 != 0) return x.refusal.refuse("a carrier table entry past the four operators", carrier_table);
            for (0..4) |slot| c[@backingInt(tracks.operatorOfSlot(@intCast(slot)))] = mask >> @intCast(slot) & 1 != 0;
        }
        for (&d.fm3_operators, 0..) |*o, i| o.* = switch (x.rom[fm3_registers + i]) {
            0xA6 => .op4,
            0xAC => .op3,
            0xAE => .op2,
            0xAD => .op1,
            else => return x.refusal.refuse("an FM3 frequency register the special mode does not have", fm3_registers),
        };
        for (&d.envelopes, 0..) |*env, k| {
            const a = x.u32be(envelope_table + 4 * @as(u32, @intCast(k)));
            if (a + 256 > x.rom.len) return x.refusal.refuse("an envelope past the ROM's end", a);
            var ended = false;
            for (&env.reads, 0..) |*r, p| {
                const b = x.rom[a + p];
                r.* = switch (b) {
                    0x80 => .{ .kind = .again },
                    0x81 => .{ .kind = .hold },
                    0x83 => .{ .kind = .silence },
                    else => .{ .kind = .step, .value = b },
                };
                if (!ended and r.kind != .step) {
                    env.length = @intCast(p + 1);
                    ended = true;
                }
            }
            if (!ended) return x.refusal.refuse("an envelope without its end", a);
        }
        // With no song, the song's list is at address 0: the cartridge's vectors.
        var songless: std.ArrayList(content.Instrument) = .empty;
        var numbers = x.effect_numbers.iterator(.{});
        while (numbers.next()) |n| {
            var i = x.instrument(x.rom[voice_size * n ..][0..voice_size], @intCast(n));
            i.borrowed = true;
            try songless.append(x.arena, i);
        }
        d.songless_instruments = songless.items;
        d.provenance = "the 68000 driver's tables: FM keys ROM 0x732D2, PSG steps 0x73A64, volume levels around 0x73600, carriers 0x73728, FM3's registers 0x72D04, envelopes by 0x728D0; the songless instruments from address 0";
        return d;
    }

    fn sampleList(x: *Extractor) Error![]const content.Sample {
        const raw = sound_samples.raw(x.arena, x.rom, x.refusal) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadTrack,
        };
        const out = try x.arena.alloc(content.Sample, sound_samples.count);
        for (out, raw, 0..) |*s, r, n| {
            const d = try sound_samples.decode(x.arena, r.bytes);
            s.* = .{
                .number = @intCast(n),
                .name = sample_names[n],
                .values = d.values,
                .pace = d.pace,
                .delay = r.delay,
                .banked = r.banked,
                .voice = n >= sound_samples.first_voice,
                .provenance = try std.fmt.allocPrint(x.arena, "sample {d}, {s} 0x{X}", .{ n, if (r.banked) "ROM" else "Z80 RAM", r.address }),
            };
        }
        return out;
    }
};

/// The samples' names: the drums by number (sample 4 is empty), the voices by their sounds'.
const sample_names = [sound_samples.count][]const u8{
    "drum_1",           "drum_2",          "drum_3",         "drum_4",      "empty",
    "adam_shout",       "adam_shout_fast", "blaze_shout",    "twins_shout", "blaze_death_cry",
    "female_enemy_cry", "axel_death_cry",  "adam_death_cry", "enemy_cry",   "enemy_cry_high",
    "boss_cry",         "axel_shout",
};

test {
    _ = tracks;
    _ = sound_samples;
}

const testing = std.testing;

/// A Kosinski stream of literal bytes (the decoder takes the next descriptor as soon as it has
/// taken the sixteenth flag of the last, before that flag's byte), then the end.
fn kosinskiLiterals(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const flags = bytes.len + 2; // the literals' set flags, then 0 and 1 (a long reference)
    var descriptors: std.ArrayList(u16) = .empty;
    defer descriptors.deinit(gpa);
    var i: usize = 0;
    while (i < flags + 16) : (i += 16) {
        var d: u16 = 0;
        for (0..16) |k| {
            const f = i + k;
            const set = f < bytes.len or f == bytes.len + 1;
            if (set) d |= @as(u16, 1) << @intCast(k);
        }
        try descriptors.append(gpa, d);
    }
    try out.appendSlice(gpa, &.{ @truncate(descriptors.items[0]), @truncate(descriptors.items[0] >> 8) });
    for (0..flags) |f| {
        if (f % 16 == 15) {
            const d = descriptors.items[f / 16 + 1];
            try out.appendSlice(gpa, &.{ @truncate(d), @truncate(d >> 8) });
        }
        if (f < bytes.len) try out.append(gpa, bytes[f]);
        // The end: a long reference with no length, then a length byte of 0.
        if (f == bytes.len + 1) try out.appendSlice(gpa, &.{ 0, 0, 0 });
    }
    return out.toOwnedSlice(gpa);
}

test "the sound content from a synthetic ROM: the tables, a song, the effects, the samples" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try arena.alloc(u8, rom_mod.size);
    @memset(rom, 0);
    const put = struct {
        fn bytes(r: []u8, at: usize, b: []const u8) void {
            @memcpy(r[at..][0..b.len], b);
        }
        fn word(r: []u8, at: usize, v: u16) void {
            std.mem.writeInt(u16, r[at..][0..2], v, .big);
        }
        fn long(r: []u8, at: usize, v: u32) void {
            std.mem.writeInt(u32, r[at..][0..4], v, .big);
        }
    };
    // The driver's tables, made up.
    for (0..0x68) |i| rom[priority_table + i] = @intCast(i);
    put.bytes(rom, fm3_registers, &.{ 0xA6, 0xAC, 0xAE, 0xAD });
    put.bytes(rom, music_channel_steps, &.{ 0, 1, 1, 2, 1, 1 });
    for (0..16) |i| put.word(rom, fm_keys + 2 * i, @intCast(0x280 + i));
    put.bytes(rom, tracks.pan_table, &.{ 0xC0, 0x80, 0x40, 0xC0 });
    for (0..20) |i| rom[volume_table + i] = @intCast(0x40 - 2 * i);
    put.bytes(rom, carrier_table, &.{ 8, 8, 8, 8, 0xC, 0xE, 0xE, 0xF });
    for (0..121) |i| put.word(rom, psg_steps + 2 * i, @intCast(0x3F0 - i));
    // Five envelopes at 0x75000: 0, 1, then hold.
    for (0..5) |k| put.long(rom, envelope_table + 4 * k, 0x75000);
    put.bytes(rom, 0x75000, &.{ 0, 1, 0x81, 0x83 });
    // A song at 0x74000: five FM tracks resting (one with an instrument and a note), the drums,
    // two PSG tracks; its two instruments after them.
    const song: u32 = 0x74000;
    for (0..17) |i| put.long(rom, music_table + 4 * i, song);
    put.word(rom, song, 0x80); // instruments at 0x74080
    put.bytes(rom, song + 2, &.{ 6, 2 });
    for (0..6) |k| {
        put.word(rom, song + 4 + 3 * k, if (k == 0) 0x40 else 0x50);
        rom[song + 4 + 3 * k + 2] = @intCast(k);
    }
    for (0..2) |k| {
        put.word(rom, song + 22 + 4 * k, 0x60);
        rom[song + 22 + 4 * k + 2] = 3;
        rom[song + 22 + 4 * k + 3] = 1;
    }
    put.bytes(rom, song + 0x40, &.{ 0xF0, 0x01, 0x10, 0x25, 0x00 }); // instrument 1, a note, the end
    put.bytes(rom, song + 0x50, &.{ 0x80, 0xFF, 0xFF, 0xFD }); // rest 256, back to it
    put.bytes(rom, song + 0x60, &.{ 0x08, 0x13, 0x00 }); // a PSG note (step 15), the end
    for (0..50) |i| rom[song + 0x80 + i] = @intCast(i % 16); // two instruments, then fill
    @memset(rom[song + 0x80 + 50 .. song + 0x200], 0xFF);
    // 48 effects at 0x74200, on FM3, their instrument list at 0x74300.
    const effect_at: u32 = 0x74200;
    for (0..48) |i| put.long(rom, effect_table + 4 * i, effect_at);
    put.word(rom, effect_at, 0x100);
    put.bytes(rom, effect_at + 2, &.{ 4, 2 });
    put.word(rom, effect_at + 4, 0x10);
    put.bytes(rom, effect_at + 0x10, &.{ 0xF0, 0x00, 0x05, 0x30, 0x00 });
    // The Z80 program: the samples' table at 0x19B, each sample at 0x200 + 0x20 n; the bank's.
    const program = try arena.alloc(u8, sound_samples.z80_copy);
    @memset(program, 0);
    for (0..9) |n| {
        const at = 0x200 + 0x20 * n;
        put.bytes(program, 0x19B + 5 * n, &.{ @truncate(at), @intCast(at >> 8), 18, 0, @intCast(n) });
        program[at] = 2; // a zero code repeats twice
        program[at + 1] = 1; // code 1 adds 1
        put.bytes(program, at + 16, &.{ 0x11, 0x10 });
    }
    put.bytes(rom, sound_samples.z80_program, try kosinskiLiterals(arena, program));
    for (0..8) |n| put.bytes(rom, sound_samples.bank + 5 * n, &.{ 0x00, 0x01, 17, 0, 20 });
    rom[sound_samples.bank + 0x100] = 2;
    rom[sound_samples.bank + 0x101] = 3;
    rom[sound_samples.bank + 0x110] = 0x10;

    var why: Refusal = .{};
    const x = extract(arena, rom, &why) catch |err| {
        std.debug.print("refused: {s} at 0x{X}\n", .{ why.why, why.at });
        return err;
    };
    const c = &x.content;
    try testing.expectEqual(@as(usize, 1), c.songs.len);
    try testing.expectEqual(@as(usize, 48), c.effects.len);
    try testing.expectEqual(names.entries.len, c.sounds.len);
    try testing.expectEqual(@as(u8, 0xA0), x.requests[17]);
    try testing.expectEqual(@as(u8, 0xA0 - 0x81), c.sounds[17].priority);
    try testing.expectEqual(@as(?u8, 0xA0), c.sounds[17].request);
    // The tables.
    try testing.expectEqual(@as(u16, 0x285), c.driver.fm_keys[5]);
    try testing.expectEqual(@as(u8, 0x40 - 6), c.driver.volume_levels[3]);
    try testing.expectEqual([4]bool{ false, true, false, true }, c.driver.carriers[4]);
    try testing.expectEqual(content.Read{ .kind = .hold }, c.driver.envelopes[2].reads[2]);
    try testing.expectEqual(@as(u16, 3), c.driver.envelopes[2].length);
    try testing.expectEqual(content.Read{ .kind = .silence }, c.driver.envelopes[2].reads[3]);
    // The song: its instruments (two, and none borrowed past them: the effects ask for 0 only),
    // its tracks and their offsets.
    const s = &c.songs[0];
    try testing.expectEqual(@as(usize, 2), s.instruments.len);
    // Instrument 1's first byte, 25 % 16: op1's multiple.
    try testing.expectEqual(@as(u4, 9), s.instruments[1].operators[0].multiple);
    try testing.expectEqual(content.Event{ .note = .{ .duration = 0x10, .octave = 2, .key = 5 } }, s.fm[0].events[1]);
    try testing.expectEqual(@as(u8, 5), s.drums.volume_offset);
    try testing.expectEqual(@as(usize, 2), s.psg.len);
    try testing.expectEqual(@as(u8, 15), s.psg[1].events[0].note.step);
    try testing.expectEqual(@as(u8, 1), s.psg[0].envelope);
    // The effects.
    try testing.expectEqual(content.EffectChannel.fm3, c.effects[0].channel);
    try testing.expectEqual(@as(u8, 4), c.effects[0].volume_offset);
    try testing.expectEqual(@as(usize, 1), c.effects[0].instruments.len);
    // The samples: from the Z80 program (0-8) and the bank (9-16).
    try testing.expectEqual(@as(usize, 17), c.samples.len);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x82, 0x83, 0x84 }, c.samples[3].values[0..4]);
    try testing.expectEqual(@as(u8, 3), c.samples[3].delay);
    try testing.expect(!c.samples[3].banked and c.samples[12].banked and c.samples[12].voice);
    try testing.expectEqualSlices(u8, &.{ 0x83, 0x86, 0x89 }, c.samples[12].values);
}

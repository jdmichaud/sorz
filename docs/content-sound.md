# The sound content

The sound part of the content tree (`docs/content.md`): the songs and effects as readable
sequences, their instruments, the samples, the driver's tables and the names the game asks for.
The extractor writes it from the ROM (`src/extract/sound.zig`); the game loads it
(`src/shared/audio/files.zig`) and plays it with the sequencer (`src/shared/audio/sequencer.zig`,
DESIGN.md 10.6). The files carry no ROM address; each item says where it comes from in its
`provenance`.

| File | What it holds |
| --- | --- |
| `sound/sounds.json` | The names the game asks for, what each plays, its priority |
| `sound/songs/NAME.txt` | A song: its instruments and its tracks, in the notation below |
| `sound/effects/NAME.txt` | An effect: its channel, its instruments and its track |
| `sound/driver.json` | The driver's tables: pitches, volume levels, carriers, envelopes |
| `sound/songless_instruments.txt` | The instruments an effect finds when no song plays (below) |
| `sound/samples.json` | The samples: their WAV file, their pace and the player's delay |
| `sound/samples/NAME.wav` | A sample's DAC values: PCM, 8-bit unsigned, mono |

## Sounds (`sounds.json`)

```json
{"sounds": [
  {"name": "menu move", "priority": 111, "plays": {"effect": "menu_move"}, "request": 185,
   "provenance": "request $B9: sound test SE 26"},
  {"name": "round 1 music", "priority": 128, "plays": {"song": "round_1"}, "provenance": "..."},
  {"name": "axel shout", "priority": 114, "plays": {"sample": 16}, "provenance": "..."},
  {"name": "fade out", "priority": 0, "plays": {"command": "fade_out"}, "provenance": "..."}
]}
```

`plays` is one of `song` (a file of `songs/`), `effect` (of `effects/`), `sample` (a number of
`samples.json`), or `command`: `fade_out` (the song fades over 79 updates, then everything
stops), `stop` (everything stops, and stops again at the next update), `stop_effects`.

The priority decides between requests: of the requests read at one update, the last whose
priority is at least the playing effect's wins; a priority of 128 or more (the songs') is never
kept, so songs never hold off effects, and an effect holds off lower ones only while it plays.

Two names may play the same item ("name entry music" and "round clear music" are one song).

`request` (optional) is the original's number for the request, 129 to 226: sor-remaster's
semantic traces name a sound by it (`sfx_b9` is 185), so the comparison of the two programs'
traces maps one name to the other with it. The game never reads it: it asks for sounds by name.

## Songs and effects (the notation)

One item per file, in the spirit of MML. Words are separated by spaces and line ends; `;` starts
a comment.

```
song title
provenance "request $83, header at ROM 0x7B508, instruments at 0x7BB8B"
instrument 0 algorithm 6 feedback 0
  op1 detune 0 multiple 0 level 23 key_scale 2 attack 31 am 1 decay 10 sustain_rate 14 sustain_level 15 release 8
  op2 ...
  op3 ...
  op4 ...
track fm1 volume_offset 4
  @0 set op2 sustain_rate 1 set op1 am 0 decay 4 v15 q3 [ r:111 r:33 ]8 [ [ o2 a:29 a:25 a:36 a:54
  ]4 ]2 v17 [ g:11 a:18 g:7 a:18 g:11 a:18 g:7 a:18 a:30 r:6 ]16 @1 v12 D=0 [ a:127 & a:17 & ]9 r:7
  end
track fm2 volume_offset 4
  ...
track drums volume_offset 4
  ...
track tone2 volume_offset 255 envelope 0
  ...
```

A song has the tracks `fm1` to `fm5`, `drums` (the sixth FM channel's track, which asks the
sample player for drum hits) and up to three PSG tracks, `tone2`, `tone1`, `tone0` in that order.
An effect has `channel fm3` or `channel fm4`, a `volume_offset`, and one `track`. A track's
`volume_offset` is added to its carriers' attenuation (FM) or its attenuation (PSG); a PSG track
starts with an `envelope` (0 for none).

### Instruments

An instrument is an FM patch: the algorithm, the feedback, and each operator's parameters, named
as the YM2612's documentation names them (op1 to op4): `detune` (0-7), `multiple` (0-15),
`level` (the attenuation, 0-127), `key_scale` (0-3), `attack` (0-31), `am` (0-1), `decay` (the
first decay rate, 0-31), `sustain_rate` (0-31), `sustain_level` (0-15), `release` (0-15). The
events name an instrument by its number.

- A song lists every instrument of its list, used or not: an effect that gives its channel back
  can load any of them (the PassQuirk, below).
- An effect lists the instruments it uses, and, marked `borrowed`, those that other effects use
  that its list holds: the effects share one list, the one of the effect started last.
- Some borrowed instruments are bytes that are no instrument. Their bits that the chip ignores are
  kept: `ignored N` after the algorithm, and `ignored a,b,c,d,e,f` after an operator (one per
  parameter group, in the order above). The instruments the items use have none.

### Events

| Words | Meaning |
| --- | --- |
| `o4` | The octave of the notes after it (FM: the block, 0-7; PSG: the row of the PSG table, 0-10) |
| `a:29` | A note of 29 updates; keys `c c+ d d+ e f f+ g g+ a a+ b`, and on FM `n12`-`n15`, the four pitches the driver's table gives past B |
| `hit:20` | A drum hit of 20 updates (the drums track's notes) |
| `r:111` | A rest of 1 to 256 updates |
| `&` | The next note continues this one: no key off, no key on, no restart of an equal pitch |
| `@3` | FM: instrument 3. PSG: kept, no effect |
| `drum 2` | Drums: the sample of the next hits |
| `v15`, `v+1`, `v-2` | FM: the volume level (an index of `volume_levels`, higher louder), or moved; drums: no effect. PSG: the attenuation (16 - v) mod 16 plus the offset, or lowered by n |
| `q3` | The gate: the note is released when 3 updates remain (0: never) |
| `D=-10`, `D+=5` | The detune, set or added (FM: F-number units; PSG: sixteenths of a divider step) |
| `M=20,1,-12,6` | Vibrato on: after 20 updates, every 1 update the pitch moves by -12, 6 / 2 times one way, then 6 + 1 times the other way, and so on |
| `Moff`, `Mon`, `Mdelay=5`, `Mperiod=1`, `Mstep=-12`, `Mcount=6` | Vibrato off, on, or one parameter |
| `[` ... `]8` | Repeat 8 times |
| `|` | Inside a repeat: leave it on its last pass |
| `:L1`, `jump L1` | A label, and a jump to it |
| `stray_loop_end L1` | A repeat's end with no start (round 6 music's first PSG track, see below) |
| `fm3 100,0,250,0` | FM3's special mode, with the pitch offsets of its four operators (in `fm3_operators` order); zero offsets leave the mode as it is |
| `noise` | PSG: the track plays the noise channel, white, at tone 2's rate |
| `pan left` | FM: the speakers (`both`, `left`, `right`, `none`). PSG: no effect |
| `pause` | The pause toggles (the pause jingle carries it): the song is silent until the next toggle; effects go on |
| `env 3` | PSG: envelope 3 (0 for none) |
| `set op2 sustain_rate 1` | FM: one parameter group of an operator set, and set again after each volume change while the instrument stays. The groups: `detune D multiple M`, `level L`, `key_scale K attack A`, `am X decay D`, `sustain_rate R`, `sustain_level S release R` |
| `timer_b 198` | The chip's timer B (no effect on the sound; on FM4-FM6 the chip ignores it) |
| `lfo 3,4,0` | The LFO at rate 3, and the channel's FM and AM sensitivities |
| `end` | The end of the track |

Durations are in updates (display ticks, 59.92 a second): the driver has no tempo.

## The driver's tables (`driver.json`)

| Field | What it is |
| --- | --- |
| `fm_keys` | 16 F-numbers: the keys C to B, then the four values the driver's code gives past B |
| `psg_steps` | 121 PSG dividers by octave x 12 + key; octaves 0-1 repeat octave 2's, 7-9 octave 6's; the last is 0 |
| `volume_levels` | 256 carrier attenuations by volume level, the level read as a signed byte: 0-19 are the table, the others what the driver reads around it |
| `carriers` | The carriers of each algorithm, 0 to 7 |
| `fm3_operators` | The operators that FM3's special-mode offsets apply to, in order |
| `envelopes` | The PSG envelopes 1 to 5: each a `length` and 256 `reads` |
| `provenance` | Where they come from |

An envelope's reads are what each position gives, one per update from a note's start: a number
(added to the track's attenuation), `hold` (the value stays until the next note), `silence` (the
channel goes silent) or `again` (back to the start). The first `length` reads are the envelope;
the rest are what the driver reads on past its end (the next envelopes, then its own code), which
the rests reach (below).

## Samples (`samples.json` and `samples/`)

```json
{"samples": [
  {"number": 5, "name": "adam_shout", "wav": "samples/adam_shout.wav", "delay": 32,
   "banked": false, "voice": true, "pace": "HLRrLHLHLHLHSsHL...", "provenance": "sample 5, Z80 RAM 0x1600"}
]}
```

Samples 0-3 are the drums, 4 is empty (it stops the playing sample), 5-16 the voices. The WAV
holds the DAC's values; its rate is the sample's mean rate, for listening. The player's timing is
`delay` (its loop's units between two values), `banked` (read through the window on the
cartridge, slower) and `pace`, one letter per value: `H` and `L` a value of the first or the second
half of a byte of codes, `R` and `S` the first of a run of repeats in either half, `r` and `s` the
next ones. A `voice` plays on both speakers, and the drums wait while it plays.

## The original's quirks the content carries

The sound is exact (DESIGN.md G1), so a few of the original driver's oddities are kept, each a
named rule of the sequencer:

- **The PassQuirk.** An effect that gives its channel back makes the effects stepped after it in
  that update act as the song's tracks: an FM4 effect then loads the song's instrument of its
  number. With no song playing the driver reads that instrument at address 0, the cartridge's
  vectors: `songless_instruments.txt` holds those bytes for the numbers the effects use.
- **The effects' shared list.** The effects use the list of the effect started last; hence the
  borrowed instruments.
- **The stray loop end** of round 6 music's first PSG track counts in the next track's state
  (its flags, then its channel's code...): that track stops after one pass.
- **Rests read on past an envelope's end**, and a `silence` there quiets the channel again.
- **The drum hold.** The drums send no hit while a voice plays; when a voice ends is a timing model
  of the original's two processors (`src/shared/audio/clock.zig`).
- A drum track that ends ends the rest of its update; a stop stops again at the next update.

## Checks

- `zig build extract-check -Drom=ROM`: two extractions of the whole tree are byte-identical, and
  the sound's files load and write the same files again.
- `zig build sound-check -Drom=ROM -Dremaster=DIR` extracts the sound twice, loads it back from
  its files, and plays it against sor-remaster's driver (the reference): every song and effect,
  alone and together, call by call, then their PCM byte by byte (`-Dsound-only=GROUP` runs one
  group, `-Dsound-tree=DIR` writes the files there).

# The content tree

The game's content is a tree of human-readable files (DESIGN.md P2, C1-C4, decision D8): JSON
records, indexed PNG pictures and Tiled maps. The extractor (`src/extract/`) writes it from the
user's ROM; the game reads it through its asset source, from a directory or from memory, with
the same loader (`src/shared/content/`). A mod is an edited copy of the tree. No file of the tree
is in the repository: the repository holds the extractor and the schema.

This document is the schema, format 1. The sound's part of the tree is described in
`docs/content-sound.md`.

## Principles

- **Named in the game's terms.** An asset's full name is its set's name, a slash and its own:
  `title/logo`, `round1/plane_a`, `axel/012`. Names are lower case letters, digits and `_`.
- **No ROM address in the model.** Each record may carry a `provenance`, a text for the reader
  saying where the extractor took it from (the ROM's places, the routine that uses it). No code
  interprets it.
- **Refused, not guessed.** The loader checks every file and every value. A refusal names the
  file, the field (or the place in a picture) and the reason, for example
  `title/art.json: field palettes.sky.colours.1[15][0]: not 0 to 7` or
  `round1/tiles.png: pixel (3, 5): a colour index above 15`. A field the schema does not have is
  refused too, so a misspelt field is not silently ignored.
- **Deterministic.** The same content gives the same bytes: JSON with sorted keys, two-space
  indentation, integers only, an array of scalars on one line, a final newline; PNG pictures
  4 bits a pixel with stored (uncompressed) image data; files in path order. Two extractions of
  one ROM are byte-identical, and loading a tree and writing it again gives the same files.
- **Versioned.** The manifest names the format and its version. A tree of another version is
  refused ("extract the tree again"), never converted.

## Layout

```
manifest.json          the format, its version, the extractor, the ROM, the art sets, the kinds
attributes.png         the attribute tiles the maps' second layer uses (palette, priority)
SET/art.json           an art set: its palettes, tile sheets, maps, frames, fonts
SET/NAME.png           a tile sheet or a sprite frame
SET/NAME.tmj           a tile map (Tiled)
entities/NAME.json     a kind of entity's definition: a character, an enemy, an item...
sound/...              the sound (docs/content-sound.md)
```

An art set is a directory: a screen's (`title`, `menu`), a round's (`round1`), a character's or
an enemy's (`axel`, `galsia`), or art several screens share (`fonts`, `play`).

## manifest.json

```json
{
  "format": "sorz-content",
  "version": 1,
  "extractor": "sorz-extract 1",
  "rom": {"sha256": "…", "size": 524288},
  "art": ["fonts", "segalogo", "title", "round1", "axel"],
  "entities": ["axel", "galsia"]
}
```

`art` lists the art sets the loader reads, in order; `entities`, which a tree without
definitions leaves out, the kinds of entity (`entities/NAME.json`). `rom` names the ROM the tree
was extracted from; it identifies the data (network play compares it).

## SET/art.json

Every field is optional. The kinds of asset are separate: a sheet and a map may share a name.

```json
{
  "provenance": "the title screen's set-up …",
  "uses": ["fonts", "intro"],
  "palettes": {
    "sky": {"provenance": "…", "colours": {"1": [null, [7, 7, 7], …16 entries]}}
  },
  "cycles": {
    "cycle_1": {"provenance": "…", "period": 4, "steps": [{"2": […16]}, {"2": […16]}]}
  },
  "steps": {
    "sweep": {"provenance": "…", "steps": [{"0": […16]}, {"0": […16]}]}
  },
  "tiles": {
    "city": {"provenance": "…", "file": "city.png", "count": 210}
  },
  "maps": {
    "plane_b": {"provenance": "…", "file": "plane_b.tmj", "at": {"layer": "plane_b", "x": 0, "y": 0}}
  },
  "frames": {
    "012": {"provenance": "…", "file": "012.png", "origin": [31, 63], "palette": 0,
            "priority": false, "pieces": [[-24, -63, 4, 4], …]}
  },
  "fonts": {
    "main": {"provenance": "…", "tiles": "fonts/main", "glyphs": {" ": 0, "A": 1, "->": 39}}
  }
}
```

- `uses`: the other art sets a screen draws with (the font, the status bar). A screen's art set
  is its own directory and the sets it uses.
- **Palettes.** The renderer holds four palettes of 16 colours (DESIGN.md 10.5); colour 0 of each
  is transparent. A palette asset gives colours to some of them: `colours` maps a palette's number
  (`"0"` to `"3"`) to its 16 colours, each `[red, green, blue]` with levels 0 to 7 (the console's
  512 colours), or `null` where the asset leaves the colour as it is. A screen applies several
  in turn; a later one's colours replace an earlier one's.
- **Cycles.** Colours that change in turn (a round's neon signs, its water): every `period` logic
  ticks (30 a second in play) the next of the `steps` replaces the colours it gives, the last step
  followed by the first. A step is a palette's `colours`.
- **Palette steps** (`steps`). Colours a screen shows one after another, at the times its scene
  decides (the Sega logo's colour sweep, the title's colour steps): each of the `steps` is a
  palette's `colours`, which replace those it gives when the scene shows it.
- **Tile sheets** (`tiles`). `file` is an indexed PNG of 8x8 tiles, read left to right and top to
  bottom (16 a row when the extractor writes it); `count` is the number of tiles, the rest of the
  last row being unused. A pixel is a colour index 0 to 15, 0 transparent; an index above 15 is
  refused. The picture's own palette is only for viewing: the game draws a tile with the palette
  its cell or sprite names.
- **Maps.** `file` is a Tiled map (below). `at`, when present, is where the original draws the
  map: the layer (`plane_a`, the front scrolling layer; `plane_b`, the back one; `window`, the
  fixed layer of the status bar) and the cell of the layer its top-left cell goes to.
- **Frames.** A sprite frame is one picture (`file`, indexed as a sheet's), drawn with one palette
  (`palette`, 0 to 3, to which an entity may add its own) and one priority (`priority`: drawn over
  the layers' high-priority cells or not). `origin` is the entity's position in the picture, in
  pixels from its top-left corner (it may lie outside the picture); a mirrored frame is drawn
  mirrored about it (column c to -1 - c). `pieces` are the hardware sprites the original drew the
  frame with, `[x, y, width, height]`: the top-left corner relative to the origin, in pixels, and
  the size in cells (1 to 4). The renderer draws the picture; the pieces are kept for the
  original's sprite limits, which are not reproduced (decision D4).
- **Fonts.** `tiles` is the full name of the font's sheet; `glyphs` maps each glyph's text to its
  tile. A glyph may be several characters (`"->"`, `"(c)"`); a text is read longest glyph first.

### Why a sprite frame is one picture

The renderer (DESIGN.md 10.5) draws sprites with a palette and a priority, and keeps its art by
name, with no tile slots. A frame as pieces would make it place several tiles a sprite, each
through a table, to draw what is in fact one picture. The original's frames allow the simpler
form: each of its frames uses one palette and one priority in all its pieces, and drawing a
frame's pieces mirrored equals mirroring the composed picture about the origin (graphics port
map 5, checked on all 635 frames). So a frame is one indexed picture with its origin: one blit,
mirrored or not, and an editor sees the frame as it appears. The pieces stay in the record, as
rectangles, for the day the original's per-line sprite limits matter.

## entities/NAME.json

A kind of entity: a character, an enemy, a boss, a weapon, an item, a piece of scenery, an
effect. NAME is the kind's name, which the semantic traces use (`galsia`, `galsia_knife`). The
definition holds what the world needs to make one, and the numbers its behaviour reads: the
behaviour's states are code (`src/shared/world/behaviours/`), their speeds, ranges, durations and
damage are here (DESIGN.md W3). A new kind of enemy is a definition, and a behaviour module when
none of the existing ones fits.

```json
{
  "provenance": "…",
  "family": "enemy",
  "team": "enemy",
  "behaviour": "galsia",
  "health": 32,
  "palette": 1,
  "gravity": 24576,
  "shadow": true,
  "numbers": {"walk_speed": 65536, "reach": 28},
  "sounds": {"hurt": "enemy hit"},
  "boxes": {
    "body": {"x": [-8, 8], "depth": [-3, 3], "height": [-56, 0]},
    "fist": {"x": [10, 30], "x_left": [-31, -11], "depth": [-3, 3], "height": [-48, -40]}
  },
  "animations": {
    "stand": {"loop": true, "frames": [{"frame": "galsia/000", "ticks": 8, "body": "body"}]},
    "punch": {"frames": [
      {"frame": "galsia/010", "ticks": 3, "body": "body"},
      {"frame": "galsia/011", "ticks": 4, "body": "body", "attack": "fist"}
    ]}
  },
  "moves": {
    "punch": {"animation": "punch", "damage": 4, "reaction": "reel", "push": {"x": 65536},
              "sound": "punch swing", "hit_sound": "punch hits"}
  }
}
```

The units are the world's: pixels for the boxes; 1/65536 pixel for the speeds, per logic tick (30
a second in play). The axes are `x` across, `depth` on the ground (toward the player) and
`height`, which grows downward as the screen's lines do (a jump makes it smaller).

- `family`: `player`, `enemy`, `boss`, `projectile`, `weapon`, `item`, `scenery`, `effect` or
  `screen`: what the semantic traces say of it. `team`: `player`, `enemy` or `neutral`: whose
  blows land on it.
- `behaviour`: the behaviour module that drives it, by name. The world refuses a kind whose
  behaviour does not exist, or that lacks a number, a sound, an animation or a move the behaviour
  reads, naming the file and what is missing.
- `health` (0 to 32767); `palette` (0 to 3), added to its frames' palettes; `gravity`, added to
  its height's speed every logic tick in the air; `shadow`, whether a shadow follows it on the
  ground. Each is optional: 0, or false.
- `numbers`: the behaviour's numbers by name, integers in the units the behaviour gives them.
  `sounds`: the sounds the behaviour asks for, by their role, each a name of the sound content
  (`docs/content-sound.md`).
- `boxes`: named boxes, each a span `[from, to]` (both included) on each axis from the entity's
  place, for the entity facing right. Facing left, the span across is `x_left` if given, else `x`
  mirrored (`[-to, -from]`). Two boxes meet when their spans overlap or touch on all three axes.
- `animations`: each a list of `frames`, at least one: `frame`, a sprite frame by its full name;
  `ticks`, how many logic ticks it shows (1 to 255); `flip`, drawn mirrored besides the entity's
  facing; `body`, the box blows strike it in, and `attack`, the box its blow strikes with, while
  the frame shows (a frame without them has none). With `loop` the first frame follows the last;
  without, the last stays.
- `moves`: a blow or an action: its `animation` (by name); the `damage` its blow does; the
  `reaction` of the one it strikes, `reel` or `knock_down`; the speed it gives that one, `push`
  (`x` away from the striker, `height` negative upward); the `sound` asked for when it starts and
  the `hit_sound` when its blow lands.

The optional fields are written only when they are not their defaults, so a file read and
written again keeps its bytes. The extractor writes the original's characters and enemies (PLAN
item 11 and on); until then a tree has no `entities`.

## Tile maps (`.tmj`)

A map is a Tiled map in JSON, orthogonal, 8x8 tiles, not infinite, with two tile layers of the
map's size (Tiled can open and edit it; save it with the layers' data as arrays, not encoded):

- `cells`: each cell's gid, its tile across the map's tilesets in Tiled's numbering (the tileset
  with the largest `firstgid` not above it, then the tile `gid - firstgid` of that tileset), 0 for
  an empty cell; bit 31 flips the tile across, bit 30 down. Tiled's diagonal flip (bit 29) is
  refused: the console has none.
- `attributes`: each cell's palette and priority, as a tile of the `attributes` tileset: palette
  p with priority q (1 for high) is that tileset's tile `p + 4q`; 0 is palette 0, low priority.

The tilesets are the sheets the map draws from, each named by the sheet's full name, with the
sheet's picture as its `image` (relative to the map's directory) and the sheet's `count` as its
`tilecount`; then `attributes`, 8 tiles, `image` the tree's `attributes.png`. A tileset that
names no sheet, a count or a picture that is not the sheet's, an external tileset, or a gid that
no tileset holds, is refused with its field.

In memory a map has its sheets' tiles one after the other, and a cell names a tile of them, its
palette, its flips and its priority (`content/art.zig`, `TileMap` and `Cell`).

## What the tree holds

The art (PLAN 06), by set:

| Set | Holds |
| --- | --- |
| `fonts` | the fonts' sheets (`main`, `italic`, `intro`, `big`) and the glyphs of `main`, `italic`, `intro` |
| `segalogo`, `intro`, `title`, `menu`, `options`, `select`, `highscores`, `round_end`, `ending`, `boss_ending` | each screen's sheets, maps (with where the original draws them) and palettes |
| `play` | the status bar's sheet and maps, play's colours, the arrow, sparks and shadow frames |
| `offer` | Mr. X's window in round 8 (and in Japan) |
| `round1` to `round8` | the round's two art sheets, its planes' whole maps (`plane_a`, `plane_b`), its colours and cycles, its props' frames; round 3's waves (four maps, five palettes) |
| `axel`, `adam`, `blaze` | the players' frames |
| `galsia`, `signal`, `acrobat`, `brawler`, `juggler` | the enemies' frames and colour variants (`variant_N_palette_P`: variant N for palette P) |
| `antonio`, `round2_boss`, `round3_boss`, `round4_boss`, `twins`, `mrx` | the bosses' frames and colour variants |
| `items`, `weapons`, `police`, `special`, `demo` | the items', weapons', police car's, special attack's and demo sign's frames |

A screen's art set is its directory and the sets its `uses` names. Only the sheets that maps and
fonts draw from are in the tree: a sheet that sprites alone are drawn from is composed into the
frames, which are the content. A frame's name is its set's prefix and its number in the set's
order (the order of the original's records): `axel/012`, `items/beef_00`; the animations, which
name the frames by move, come with the moves (PLAN 11). Where the original gives no meaning to
tell assets apart, the name numbers them (`ending/colours_03`), and the provenance says where
each comes from; the scenes' items may rename them when they give them a role.

Not in the tree yet, each with the item that needs it: the texts (the menus' option values, the
story, the profiles, the endings: PLAN 08); the screens' palette effects that are routines over
small tables but for the Sega logo's sweep and the title's colour steps (`segalogo/sweep`,
`title/steps`: PLAN 08); the
fixed sprite lists of the round's banner, the pause and the game over, drawn from tiles play
builds itself (PLAN 13); the rounds' cameras, bands and floors (PLAN 13); the moves (PLAN 11).

## Extracting and checking

- `zig build extract -Drom=PATH [-Dcontent=DIR]` writes the tree of the user's ROM into DIR
  (`<prefix>/content` by default). The ROM's size and SHA-256 are checked first.
- `zig build extract-check -Drom=PATH` extracts twice and checks that the two trees are
  byte-identical, that every file loads, and that the loaded content writes the same files.
- `zig build extract-compare -Drom=PATH -Dremaster-tree=DIR` compares the art with sor-remaster's
  exported tree (`sorz-agent ROM --export-assets DIR` of sor-remaster): every sheet's tiles, every
  map's cells, every frame's picture and origin, every palette's and cycle's colours, every font's
  glyphs, through the ROM record each asset was made from (`src/extract/compare.zig`).
- In memory, `extract.extract(gpa, rom)` gives the tree's files (`Tree.files`, or
  `Tree.addTo(source)` for a `MemoryAssetSource`), so a host can play from a ROM; `writeDirectory`
  writes them to disk.

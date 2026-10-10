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
screens/NAME.json      a screen's record: its texts and tables (the options, the high scores...)
rounds/NAME.json       a round's script: its sections, walls, waves and boss (round1...)
sound/...              the sound (docs/content-sound.md)
```

An art set is a directory: a screen's (`title`, `menu`), a round's (`round1`), a character's or
an enemy's (`axel`, `galsia`), or art several screens share (`fonts`, `play`).

## manifest.json

```json
{
  "format": "sorz-content",
  "version": 2,
  "extractor": "sorz-extract 1",
  "rom": {"sha256": "…", "size": 524288},
  "art": ["fonts", "segalogo", "title", "round1", "axel"],
  "entities": ["axel", "galsia"],
  "screens": ["high_scores", "intro", "options", "select"],
  "rounds": ["round1"]
}
```

`art` lists the art sets the loader reads, in order; `entities`, which a tree without
definitions leaves out, the kinds of entity (`entities/NAME.json`); `screens`, in name order and
left out by a tree without any, the screens' records (`screens/NAME.json`); `rounds`, left out by a
tree without any, the rounds' scripts (`rounds/NAME.json`). `rom` names the ROM the tree was
extracted from; it identifies the data (network play compares it).

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
  decides (the Sega logo's colour sweep, the title's colour steps, the city's lights in the
  intro): each of the `steps` is a palette's `colours`, which replace those it gives when the
  scene shows it.
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
  original's sprite limits, which are not reproduced (decision D4). `copied`, when there: the
  tiles the game copies to show the frame, a copy each (a player's frames: the parts of the
  players' art it has, 34 and 32 tiles), whose time holds the sound's processor (A4).
- **Fonts.** `tiles` is the full name of the font's sheet; `glyphs` maps each glyph's text to its
  tile. A glyph may be several characters (`"->"`, `"(ED)"`); a text is read longest glyph first.

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
  ground (it takes one of the shadows' places, world/shadows.zig); `shadow_place`, whether it
  takes a shadow's place though none of it is drawn (a piece of scenery the original gives no
  mark against a shadow: round 3's rain until it shows). Each is optional: 0, or false.
- `traced_as` (optional): the name sor-remaster's traces give the kind when it differs (the
  `pepper` shaker is their `bottle`). The traces use it, and a kind is found by it as by its name
  (a scenario's `near bottle`, a situation taken up).
- `numbers`: the behaviour's numbers by name, integers in the units the behaviour gives them.
  A behaviour may read a number only when the definition gives it (a character's move played
  its own way: Adam's back attack that jumps, `back_attack_up`; Blaze's blows that leap,
  `last_blow_leap`, `knee_last_leap`); left out, the behaviour does without. `sounds`: the
  sounds the behaviour asks for, by their role, each a name of the sound content
  (`docs/content-sound.md`). `colours`: the colours the behaviour shows by their role, each a
  palette's full name in the art (the rain's sky, `round3/flash_1`).
- `boxes`: named boxes, each a span `[from, to]` (both included) on each axis from the entity's
  place, for the entity facing right. Facing left, the span across is `x_left` if given, else `x`
  mirrored (`[-to, -from]`), and the span in height `height_left` if given, else `height` (Adam's
  back attack reaches less high facing left, as the original's table has it). Two boxes meet
  when their spans overlap or touch on all three axes.
  A box named `solid` stops the fighters' walks while its behaviour holds it solid (a
  breakable's): a fighter whose place comes within it across and in depth goes back.
- `animations`: each a list of `frames`, at least one: `frame`, a sprite frame by its full name;
  `ticks`, how many logic ticks it shows (1 to 255); `flip`, drawn mirrored besides the entity's
  facing; `body`, the box blows strike it in, and `attack`, the box its blow strikes with, while
  the frame shows (a frame without them has none); `blow`, the move's blow is under way in this
  frame: its damage counts (its `attack` box strikes, or the one it holds takes it). An `attack`
  box without `blow` is a reach: what it meets, the entity may grab. `sound`, a sound asked for
  when the frame starts showing. In a hold, `held` places the one held from the holder (`x`
  ahead, `height` downward), with the `pose` it shows (a frame of its own `thrown` animation) or
  `lets_go` (the hold ends there, the one held placed so); `place` puts the holder itself from
  the one held (`x` toward the side the holder faces, `height` downward), as it vaults around
  it. A player's `spark` is the spark its blow makes when it landed in that frame: `x` ahead and
  `height` downward from its place, `big`, and `either_side` (made whatever side the one struck
  is on); without, a small one at its place. With `loop` the first frame follows the last;
  without, the last stays.
- `moves`: a blow or an action: its `animation` (by name); the `damage` its blow does; the
  `reaction` of the one it strikes, `reel`, `knock_down` or `lift` (reeling, it is lifted: it
  rises and falls again, and reels on; a blow that knocks down while it is up knocks it off,
  flying across: Adam's third blow), and of one held, `thrown` (it flies off where the hold lets
  it go) or `slammed` (it is slammed down there, and knocked down a moment later); `sneeze` (it
  stops a while, unharmed) is the pepper's, which its behaviour gives its things thrown; the
  speed it gives that one, `push` (`x` away from the striker, `height` negative upward: a
  throw's, which Blaze's makes faster); the `sound` asked for when it starts and the `hit_sound`
  when its blow lands.
- `partners` (the players'): in a hold between the two players, where this kind goes from the
  other at each frame of what it does then, by the other's kind: under the behaviour's name of
  that role (`held`, `held_behind`, `slammed`, `thrown`, `lifted`, `lift_over`, `throw_back`,
  `vault_over`), `by` maps the other's kind to a place `[x, height]` per frame (`x` toward the
  side this one faces, `height` downward, from the other's place). With `moves_partner`, the
  other goes instead, to stand at that place from it (the one held puts its holder); with
  `depth`, it takes the other's depth too.

  ```json
  "partners": {"held": {"by": {"axel": [[-51, 0]], "blaze": [[-50, 0]]}, "depth": true,
                        "moves_partner": true}}
  ```
- `colour_maps`: other colours for its frames within their palette, each by the name of the rule
  that asks for it: 16 colour indices, index `i` of a frame's pixels drawn as the map's `i`th (0,
  transparent, kept so). The players' `duplicate`, which the extended variant gives a second
  player playing the first's character, is the port's choice (the ROM has none): Axel's jeans
  red and his hair grey, Adam's top blue, Blaze's clothes blue, in the players' palette.

The optional fields are written only when they are not their defaults, so a file read and
written again keeps its bytes. The extractor writes the players (`axel`, `adam`, `blaze`, each
of behaviour `player`, from the same code of the original, which tests the character where one
plays a move its own way: each definition holds its own numbers and frames then), round 1's
Galsia (`galsia`), a stand-in for the special attack's police car (`police_car`), the GO arrow
a section's opening shows (`go_arrow`) and a player out of lives (`player_waiting`: no art, the
name entry's and the continue's question's numbers and sounds), round 2's scenery (the oil drums,
`knockable`; the `drip`s; the `flight`s across the screen, with no art, their `flier`s, and the
posters' corners they stir, `flight_scenery`), round 3's (the `lamp`s, the `crate`s and their pieces, the `drifter`s, the `rain` and its
raindrops, its sky's flashes the round's art set's palettes `flash_N`), round 3's acrobats of a
trio (`acrobat_trio`) and its boss (`boss_r3`, his part `boss_r3_part`, which shows its own
frames by side, `stand` and `stand_left`, and the helper of a pair, `boss_r3_helper`, with no
art), round 8's corridor's gold statues (`statue`) and its trolleys (`trolley`), and its boss Mr. X
standing (`mr_x`: his struck pose its first frame alone, the second of its pair being none), with
his gun's shots (`mr_x_shot`) and their cartridges (`mr_x_cartridge`, which shows its own frames
whatever its way); the other characters and enemies come with PLAN
items 12 to 15. Their numbers are read from the ROM's
tables and from the immediate values of the code that uses them, each with its place in the
definition's provenance, but the car's times, which the original's car, camera and shells make
together: those are measured in sor-remaster and said so.

## screens/NAME.json

What a front-end screen shows and plays beyond its art, as the original's tables give it: texts
in the game's font (`fonts/main`'s glyphs: capitals, digits and signs), sounds by their names in
the sound content, frames by their full names. A list carries its `provenance`. The records:

- `options`: `sound_test.entries`, the sound test's entries, each the `name` it shows and the
  `sound` it plays; `levels.names`, the levels' names, the easiest first (the high scores show
  them too); `controls.choices`, for each control choice the lines that say what the buttons do.
- `high_scores`: `first.entries`, the table at power-on, the best first: each a `score` (0 to
  999999), the `round` reached, a `name` of three letters and a `level` (a number of the
  options' `levels`).
- `intro`: `story.lines`, the story's lines in `fonts/italic`, each as wide as it is on the
  screen; `profiles.entries`, the characters' profiles in the order they are typed, each a
  `text` in `fonts/intro` (`_` a blank cell, `/` a new line, `|` a pause, where the cursor
  blinks), the `plane` (`plane_a`, `plane_b`) and the cell `at` its first character goes;
  `script.entries`, the intro's script: each the `part` it starts (by its name in the intro's
  code), the ticks to `wait` before the next entry, and the part's `life` in ticks.
- `ending`: the ending after round 8: its `script` (the intro's entries: a part, the ticks to the
  next, a life); its `texts` (each its plane and first cell, its rows in `fonts/italic`, the
  ticks it stays typed); its `pictures` (maps, in order) and `moments` (the pictures drawn, the
  palette lines faded in towards a palette or out, the ticks to the next); the last `scene`'s
  steps (its next palette of `scene_colours`, the `sky`'s next step, the clouds sent off, the
  star's blink, the ticks to the next or until the sun has set); its `clouds`, `sun` and `glow`
  (a frame, a place, a speed in 1/65536 of a pixel a tick, a palette and a priority); the
  `star`'s looks (maps) and ticks; and its `numbers` (the typing's and the dissolves' periods,
  the dissolves' step and span, the fades', the clouds' turn, the car's scroll...).
- `boss_ending`: the ending in the boss's chair: its three `lines` (each its first cell `x`,
  `y` of plane A and its `text` in `fonts/italic`, a blank taking no time), typed a letter a
  tick after another in palette line `letter_line`'s colour `letter_colour`, rising to
  `letter_levels` before the letter takes the font's colours, and erased so; its `credits` (each
  the `row`, of 16 pixels, at which the rolling plane writes it below the view, and its `text`;
  the last's row ends them), from `credit_column`, `credit_cells` cells; its `chairs` by
  `character` (a place, a palette, the frames and ticks it `sit`s and `turn`s, its `colours` and
  their five `steps`); the room's colours and steps, the credits' colours; the colour made white
  at the end (`white_colour` of line 0); the ticks of a `wait`, of the `turn`, between the
  colours' steps (`step_period`); the credits' scroll a tick (`scroll`, in 1/65536 of a pixel);
  its `music` and the sound as it fades out (`leave`).
- `select`: `characters.adam`, `axel` and `blaze`, each character's poses on the character
  select, each an animation: `stand`, `idle`, `pose_a`, `pose_b`, `pose_c` and Blaze's `landing`.
  An animation is a list of steps, each a `frame`, the `ticks` it shows (1 or more), when it is
  drawn mirrored, `mirrored`, and the tiles the game `copied` to show it, a number a copy (the
  players' frames are copied whole as they come, in a part of 34 tiles and, for the larger
  frames, a second of 32: what the copies cost the sound's processor, DESIGN.md A4). (They are the players' animations in the original's sets; the
  characters' own definitions will hold them with their moves, PLAN 11.)
- `round`, play's screen: `banner`, the round's banner, three frames drawn at the screen's
  top-left (`left`, the round's number, `right`; `numbers`, a frame by round from round 1's, the
  eight rounds' all made from the status bar's art); the status bar's first `fade` colours fade in,
  then the parts slide in (the left part right, the number down, the right part left) by `in`
  pixels a tick for `in_ticks` ticks, stay `wait` ticks (the round's music at their start), slide
  back out by `out` for `out_ticks` ticks, and the round starts `after` ticks later; `pause.frame`,
  the pause's text; `time_over`, the time over: its `frame`, shown `ticks` ticks, then each player
  in play loses `health` and the timer shows `seconds`; `status_bar`, the cells of the fixed
  layer (`[x, y]`, 40 by 4) where each player's parts go (`players`: its `name`, a text of
  `fonts/main`, and `at` its `name`, `score`, `health` bar, `lives` and `specials` (a digit two
  cells high) and the `lives_mark` and `specials_mark` before them, and the special attack's
  `icon`) and the timer's (`time`), and `join`, player 2's invitation to join while it does not
  play: its `text` (`fonts/main`, its words only: a space leaves the bar's cell) `at` its cell,
  shown and hidden in turn every `blink` logic ticks of play; at a blink's tick with player 2's
  START held, player 2 joins with `lives` (the one it plays counted) as the character `next`
  names by player 1's (`{"adam": ..., "axel": ..., "blaze": ...}`), but in its `closed_round`
  (the last), which has neither; `score_most`, the most a score
  holds (points past it are lost), its digits the bar's score's; `extra_lives`, the scores that
  give a player a life more, by the lives its score gave it already (at the end of its turn, one
  a turn, with the sound `extra life`; a continue counts them from none again); `image`, the
  bar's rows and cells the game writes at every frame of play (their time comes before the sound's
  driver, A4);
  `bosses`, the bosses' bars, shown from the tick after a boss's first in its section (its
  record's `bar` their entry): the fixed layer a row taller, the bars' rectangle
  (`play/enemy_bar`, at its place, written whole at every frame) and on it each bar's ten cells
  from its cell of `bars` (the first bar its boss's, the second a twin's when the entry's
  `second` says so: `second` by entry), the label after the first bar (`play/enemy_bar_label`)
  at `label`; a bar shows its boss's health `points` pixels a point (none once the boss is
  gone), and from `over`'s first pixels its ten cells are all `play/enemy_bar_over`'s first
  cell, from its second the second.
  The status bar shows each tick
  what the tick before left (the original copies its image as a frame starts, as the sprites).
  `continue`, the continue's question that a player out of lives answers on the bar: the
  `question` with the continues left a digit `count` cells after its first, the second answer
  (`new_game` for player 1 while player 2 has not gone out of the game, else `game_over`), the
  `cursor` that blinks before the answer chosen, the cells `cleared` on each row of a player's
  part, and each player's places (`players`: the first cell `cleared` of each row, the
  `question`, the `answer`, the cursor's `yes` and `no`, and `out`, where a player out of the game
  has `game_over` blink); `frame`, the game over's text over the picture while the last player
  counts the game over down. `name_entry`, the name entry of a player out of lives whose score
  enters the high-score table, on its part of the bar (cleared; its name and score where play
  shows them): the `label` and, for each player (`players`), the label's cell (`label`), the
  first of the name's three places (`first`) and the end mark's cell after them (`mark`); the
  `letters` a place goes through, the last the end mark, which ends the entry (a high-score
  entry shows it as a space). `enemy_colours`, the enemies' colours the round loads as they
  come, by number (`sets`: each a kind's colours for the enemies' first palette line and their
  second, `first` and `second`, palettes of the art; or its `own`, over the first line), the
  `lines` an enemy shows on as it appears (its colours in the first, the second, the other: its
  own), and the police car's colours (`police`), over the enemies' from its siren until the
  special attack gives theirs back. `clear`, the round's clear: the `header` ("ROUND n CLEAR",
  a map of the `round_end` set) on plane A from `header_at`, the round's number a big digit at
  its cell `number`; the bonuses' `lines` (the clear's, the time's, the level's: each a `text` from its
  cell `at` of plane A), a bonus's digits over the line's zeros from its `digits`th letter, in the `normal`
  palette or the `counted` one while it is counted; the `wait` between the steps; the bonuses
  (`clear_bonus` for the round and each special attack left, `time_bonus` a second left,
  `level_bonus` a LEVEL), counted `count` points a tick; the `colours` faded in over the status
  bar's. `buttons`, the players' buttons by the options' CONTROL: for each choice in its order
  (`layouts`), the pad's button (`a`, `b` or `c`) that gives the `special` attack, the `attack`
  and the `jump`; left out, the cartridge's first alone. `levels`, what the options' LEVEL
  changes in play besides the records that come and the bosses' strengths, by level (four
  entries, the easiest first): a thing heading for a point (an enemy to its place, a knife sent
  off) at `slower_from` or faster goes `slower` less fast (1/65536 pixel a tick); the common
  enemies come with `enemy_health` more health, and their blows do `enemy_power` more damage (a
  weapon's do its own); the last round's clear gives `life_bonus` points a life left; left out,
  none. `demo`, the attract demo: round 1
  played by the game, both players in play, the characters `players` names (player 1's, player
  2's), each with `lives` and `specials` (the status bar shows those a new life gives until they
  change); its play lasts `ticks` ticks, then fades out; its `sign`, a kind of entity fixed on
  the screen (`press_start`), stays over it; `pads`, each pad's readings, one at each display
  tick of the demo but its load's from its set-up's, the buttons held (the engine's pad's bits,
  up, down, left, right, A, B, C, START from the lowest), two hexadecimal digits a reading, the
  readings before `first_reading` none; the pads as they are (the cartridge's first layout), and
  the real START pressed ends the demo.
  The parts' pictures are the `play` set's: `play/status_bar`
  under them, `play/time_digits` (the big digits, a column of two cells each), `play/health_1`
  and `_2` and `play/enemy_bar_1` and `_2` (a bar's full cells, its partial cell, its empty
  ones, as many: a bar of n full cells shows its cells from the (cells - n)th, a health point a
  pixel (a boss's `bosses.points`), and its partial cell is the tile of `play/fills` of its
  pixels, the players' from 0, the enemies' from 8; a player's health shows up to its kind's
  `health`), `play/police_icon`.

```json
{"first": {"provenance": "…", "entries": [{"score": 100000, "round": 1, "name": "AAA", "level": 1}]}}
```

## rounds/NAME.json

A round's script (DESIGN.md W6): who comes, where and when, as the original's level events run
the round. NAME is `round` and the round's number. A modder moves a wall, a wave or a boss by
editing it.

```json
{
  "provenance": "…",
  "round": 1,
  "art": "round1",
  "music": "round 1 music", "ground": 160,
  "camera": {"provenance": "…", "at": [768, 0], "x_min": 768, "y": [0, 0], "plane_b": [1, 1],
             "wall_within": 4, "edges": [-8, 328], "left_behind": [-32, 96],
             "follow": [144, 176], "follow_most": 3, "follow_cleared": -128, "kept_x": [32, 288],
             "kept_depth": [2, 112], "shake": [8, 3]},
  "players": {"provenance": "…", "x": 0, "depth": [64, 32], "height": 0},
  "timer": {"provenance": "…", "pace": 90},
  "sections": [
    {"provenance": "…", "wall": 1216, "timer": 40, "opens_after": 62,
     "streamed": [[0, 0, 0, 0], [0, 0, 0, 0], [5, 181, 3, 111], …],
     "placed": [{"kind": "galsia", "x": 1104, "depth": 64, "entrance": "close_in", "slow": true,
                 "offset": {"x": 64, "depth": -48}}],
     "wave": [{"kind": "galsia_stalker", "side": "left", "depth": 32, "after": 16,
               "entrance": "approach", "offset": {"x": 64, "depth": 0}}],
     "reserve": [{"kind": "galsia", "side": "left", "depth": 72, "arrives_after": 32,
                  "streamed": […]}]}
  ],
  "boss": {"provenance": "…", "fade": "fade out", "music": "boss music", "music_after": 86,
           "wave_after": 59, "streamed": […], "wave": [{"kind": "antonio", "side": "right", "depth": 16,
           "after": 16, "bar": 4}], "reserve": []}
}
```

The units are pixels of the level (x across, depth on the ground) and logic ticks (30 a second in
play).

- `art`: the art set of the round's planes (`plane_a`, `plane_b`), colours (`colours`) and
  cycles (8 at most); the round's scene draws and colours its round from them, its size the
  planes'. `music`: the round's music, a name of the sound content. `ground`: the ground's
  height, where the enemies stand and the players land (heights grow downward, as the screen's
  lines): the floor's, one kind of cell everywhere in round 1 (the extractor refuses a round
  whose floor's cells differ until the floor comes cell by cell, PLAN 15). `load`, optional: the
  display ticks the round's load holds the picture dark after its set-up, as the original's
  lasts (each round's art takes its own time; measured, sor-remaster's); else the flow's.
- `camera`: the view's top-left corner at the start (`at`), how far back it may go at the start
  (`x_min`; it never goes back after), its limits down (`y`), and plane B's scroll across,
  `leftward`, optional (round 8's): true when it goes left, each section's `wall` its limit on
  the left (the first section's at `x_min`), its limit on the right at the start `x_max` and
  following it after, the things it leaves behind (items, scenery) going once their place is
  right of its place plus `behind_right`, and at a wall the enemies at or right of its place
  plus `left_behind_right` coming back there;
  `plane_b` = [times, per] of the camera's; `plane_b_down`, optional: true when plane B moves
  down as plane A does (the camera's shake too), else it keeps its place down; `scroll`,
  optional: how each frame of play copies the planes' scroll, `cells` (a value a row of cells)
  or `lines` (a value a line), else none (the planes scroll whole); its time comes before the
  sound's driver (A4). It has reached a wall when it is less than
  `wall_within` pixels from it. A wave's records come in at `edges`, across from its left edge on
  the left and on the right; when it reaches a wall, the section's enemies at or behind
  `left_behind`'s first (across from its left edge) come back there, at its second's depth. In
  play it follows the players: one drawn before `follow`'s first pixel across the screen, or from
  its second on, moves it by as much, at most `follow_most` pixels a tick (one whose life ended
  at this tick is read at `follow_cleared`, the original's record cleared); the players are kept
  within `kept_x` across from its left edge (but in a hold) and on the depths `kept_depth`; a
  heavy fall shakes it `shake`'s first ticks, its second's pixels down and up in turn. `bands`,
  each plane's bands (plane A's, then B's): `[rows, times, per]`, a band `rows` blocks high whose
  place across is its plane's times `times` / `per` (a plane whose bands' ratios differ scrolls
  by lines, each band's at its place); as it crosses a column of blocks (16
  pixels) the game writes the column coming in (and a row as the camera crosses one): their time
  comes before the sound's driver (A4).
- `players`: where a life starts: `x` from the camera's left edge, each player's `depth`, and the
  `height` it drops in from; facing left when `left` (round 8's), with `specials` special attacks
  (round 8's none).
- `timer`: `pace`, the ticks a second of the round's timer lasts.
- `sections`, in order: each the stretch of the level up to its `wall`, the camera's right limit
  until the section is cleared. A section starts at the previous one's clear (the first: with
  the round, the tick before its first tick of play): its `placed` come then, each at its place,
  hidden until its place is on the screen. `opens_after` ticks later (the original's load of the section's art) the section
  opens: the wall moves to its own, the GO arrow shows and the timer is set to its `timer`
  seconds (the first section's wall and timer are the round's own). When the camera reaches the
  wall, the `wave` comes in, each record `after` ticks after the one before (the first, after the
  camera reached the wall) at the screen's edge on its `side`. Once the wave is in, each of the
  section's enemies that goes calls one of the `reserve`, which comes in `arrives_after` ticks
  later (two are called at once if none is left then): the first still to come whose art and
  colours can be had. A section's `art` is the art its slots hold as it begins (the enemies'
  three and the boss's, by number; a boss's section's too); a reserve record's art takes the
  slot that holds it, else one no enemy shows (from the round's `art_from`th, round 1's second;
  in the boss's fight the first only, none with the boss's art `boss_art_full`), its colours
  those that hold them, else ones no enemy shows on (in the boss's fight the second's, never a
  kind's own). The enemies each slot shows are tallied as the original does: those in the world
  as the reserve begins, one more as each arrives, one less as each is knocked out while it
  runs. The section is cleared when the last of its enemies goes.
- `boss`: after the last section's clear, the camera stops where it is and `fade` is asked for;
  `music_after` ticks after the clear, the boss's `music`; `wave_after` ticks after the music,
  its `wave` and `reserve` as a section's. A beaten boss ends the round.
- `own_sound`, optional: a sound the round plays by itself (round 3's waves): `sound`, `times`
  times, the first at play's `first`th tick, then every `every` ticks; counted again from each
  section's opening.
- `animation`, optional: a part of its planes the round animates by itself (round 3's waves):
  every `every` ticks of play, the next of its `steps` (after the last, the first again), each a
  `map` of the round's art set written at its place, repeated across its plane, and `colours` of
  the art set put in the colours shown; until the first step, the planes show their own.
- `lift`, optional: the round's lift (round 7's). The camera stays where it starts, its sections'
  walls the first's, and plane B rides by. Plane B starts `from` pixels down. Each section's
  opening starts the lift (the first section's, by a hidden piece of it), and plane B moves up
  `speed` pixels a tick to the section's entry of `heights`, where the lift stops. As it starts
  and as it stops, the camera jolts down by each of `jolts` in turn, one every `period` ticks. A
  section's wave waits `wait` ticks from its opening, then for the lift's next jolt.
  - `holds_special`: no special attack is called while the lift is called, jolts or rides.
  - The special attack runs plane B, and the camera follows its moves a tick late. Plane B drops
    to `special_drop`, runs back to the level's start, then ahead to where it was, and rises
    back. The camera is level again once within `special_settle` of its top. The police car
    comes at `special_car_x` across, as much lower as the camera dropped.
- `exit`, optional: how a round without a boss ends (round 7's, which has no `boss`). Once its
  last section is cleared, the timer stops, the enemies' `colours` are loaded (as a section's
  `colours`), and the players walk out by themselves: each goes left until it is before `x`, then
  into the depths `depth` (from the first, before the second), then left again. The round ends
  `ticks` turns of a player there later, as a boss's beating ends one.
- `depth_walls`, optional, true when absent: whether the floor's walls stop the players' moves in
  depth, as they stop those across (false in round 7's).
- `enemy_walk`, optional: how the enemies walk on the round's own floor (round 7's lift),
  whatever their kinds'.
  - They walk across past `x_least` and in depth short of `depth_most`.
  - Walking, a cell deeper than `deep` `ahead` pixels to their right stops them. Going left and
    up, so does the level's top `back` behind them.
  - Knocked away from `flight_low` down, they fly on across over a cell deeper than `deep`, else
    while the cell `flight_ahead` ahead of them is neither the level's top nor deeper.
- `knocked_back_left`, optional: a new life knocks the enemies on the screen back to the left,
  facing right (rounds 7 and 8); else to the right.
- `streamed` (a section's, the boss's, a reserve record's): the art the game decodes while it
  plays, a little each display tick, for what comes (the original streams it in, five tiles a
  display tick): a section's kinds' and the boss's, from the section's start (the first
  section's, from the round's start), the boss's from the last section's clear, an arriving
  enemy's kind's from its call. Each entry is a display tick, the first the one that ends that
  tick, then the next tick's middle, its end and so on: `[tiles, codes, long codes, bytes]`, the
  tiles it decodes and the decoder's reads (its codes, those written out in full among them, and
  its bytes); `[0, 0, 0, 0]` where it decodes nothing. Their time comes before the sound's
  driver (A4).
- `again` (a section's, the boss's): its enemies' art that the special attack's police car took
  the place of (the boss's, or the section's second art kind's), streamed in again as the camera
  runs back ahead, close to where it was at the call; as `streamed`, from the tick it is queued.
  The boss's `copies_art` (round 5's twins): none streamed; the twins' art is copied again from
  the players' art instead, as their first one's coming has it copied (a step a tick, each the
  transfer of the twins' definition's `copy_words` at the next frame; the twins wait meanwhile).
- `special.streamed`: the special attack's art, by its caller (player 1's, player 2's): the
  police car's and the caller's weapon's, queued as the car comes, once nothing else streams in;
  the car shows when it is all in.
- `colours` (a section's; the boss's `section_colours`): the enemies' colours it loads as it
  begins, by number (`screens/round`'s `enemy_colours`): its `first`, its `second` and, when
  given, its `other` (else the other keeps its own). The boss's `colours`: its own, a palette of
  the art, loaded over the first as its section opens. An enemy that
  appears shows on the line of the colours that hold its own (the other's for a kind's own; the
  first's when the first holds them; else the second's); one that arrives from the reserve takes
  the colours that hold its own, or ones no enemy has shown on since the reserve began.

A record of `placed`, `wave` or `reserve` is one entity:

- `kind`, a kind of entity (`entities/NAME.json`). A kind the tree does not define yet is kept:
  the game skips it with a warning.
- `x` (placed) or `side` (`right` or `left`, wave and reserve), `depth`; `after` (wave),
  `arrives_after` and `streamed` (reserve).
- `level`, the lowest LEVEL of the options it comes at (0, the easiest, when absent); in the
  original the depth's low two bits, which the depth keeps. `two_players`: it comes only with two
  players.
- An enemy's: `entrance`, its way in (`approach`, `close_in`, `edge`, `wait`, `shutter`,
  `square_up`, `jump_in`, `size_up`, `follow`, `enter`, `circle`); its traits, each a field
  `true` when it has it (`waits_for_camera`: it stays hidden until the camera has reached its
  place, not only until its place is on the screen; `slow`, `closes_in_after_lurking`, `pipe_b`,
  `slides`, `flips_away`, `drops_in`, `flips_at_close_range`, `unflinching`, `walks_off`,
  `twin`, a boss's: round 3's boss a variant; `goes_as_enemy`, a boss's whose beating is not the
  round's end: he goes as an enemy, round 5's round 3's bosses); `offset`, where it keeps from
  its target (`x` away from it, `depth`); `offset_nibbles`, the indices of that offset in its
  kind's `offsets` table (across in the high nibble, in depth in the low), for a kind that counts
  on from them (the acrobat trio's others: role 1 one on in depth); `strength`, its row of
  strength and colours (0 when absent): its health, its blows' damage and its points are
  its kind's tables' `strength_health`, `strength_power` and `strength_points` at it (round 3's
  boss: its palette's row, 2 round 8's, a variant with more health that takes the helper of a
  pair with him); `colours`,
  its colours by number (`enemy_colours`); `art`, its art by number (the art slots hold it).
- A breakable's (an oil drum's too): `holds`, the kind of the item it leaves. A boss's: `bar`,
  its entry in the status bar's names and bars (round 3's boss: a bar of its own, the second's,
  which also makes the helper of a pair).
- A reserve's boss's kind (round 5's round 3's bosses, round 8's every boss, among its
  enemies; a round's colours one palette a number): `reserve_boss`, its
  art and colours a boss's rather than an enemy's `art` and `colours`: its `art`, a load by
  number, takes the boss's art slot, once no enemy shows the second's, the third's or the boss's
  (none is streamed, and it comes the next tick, when that slot holds it already); its
  `colours`, a number apart from the enemies' (its record's palette byte), take the other's
  place and the first's, and its `palette`, a palette of the art, is loaded over the first line
  as it is called, once no enemy shows on the first or the other (unless the other holds them).
  While a boss's art is in its slot the later records take the first's art and the second's
  colours only; when the last such boss goes, the art of the slots from the second on is
  cleared.
- A piece of scenery's (placed): `height`, the height it takes as it starts (on a wall; placed
  on the ground, as the original places it); the trait `stirs`: it moves while a flight passes
  (round 2's posters' corners); `drift`, how a drifting piece moves (round 3's): `still`,
  `drifts` away, drifts and `stops` in turn, or rides the `waves`. A crate holds an item as a
  breakable does, and so does a trolley (round 8's), which `rolls` too: 0 (or none) it stands,
  1 or 2 it rolls to the right, 3 or 4 from behind to the left, at its kind's `roll_N` speed. The first section's placed end with the pieces the round's start places itself
  (round 3's first two lamps).

The extractor writes the scripts of rounds 1 to 3 (PLAN items 13 and 15; the other rounds, whose
last sections and set pieces differ, with item 15). The times between the events are the
original's loads of art: a section opens, and a reserve comes in, once its kinds' art is loaded,
which the original streams at five tiles a display tick; the extractor counts them from the art's
sizes and says so in each section's provenance.

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
| `play` | the status bar's sheet and maps, its parts' maps (`screens/round`), play's colours, the arrow, sparks and shadow frames, the banner's, the pause's, the time over's and the game over's texts as frames, and the bars' tiles the game makes (`bar_tiles`, `fills`) |
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

The screens' records (PLAN 08): `high_scores`, `intro`, `options`, `select` (above); the
screens' palette steps: `segalogo/sweep`, `intro/lights`, `title/steps`. The rounds' scripts
(PLAN 13): `round1`.

Not in the tree yet, each with the item that needs it: the endings' texts (PLAN 16); the
Japanese story and its kana (the game plays outside Japan, decision D5); the rounds' bands and
floors, the scripts of rounds 2 to 8 (PLAN 15).

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

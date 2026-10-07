# sorz implementation plan

- Design: `DESIGN.md`. Tests: `docs/testing.md`.
- Unchecked items are open work. Priorities set the delivery order; dependencies name the
  prerequisites.
- An item is a title, its dependencies, one line of scope and a gate. Complete it through small
  commits with its tests; tick it ([x]) when the gate is met. A partly done item may carry checked
  and unchecked sub-points. No commentary: evidence goes in commit messages and docs.
- A missing item is added here first, in its own commit, with the rationale in the commit message.
- Keep proprietary inputs and captures outside the repository, and personal paths out of committed
  files.
- The reference is sor-remaster (DESIGN.md section 12). Nothing is ported from it line by line:
  a mechanic is written in the game's terms and checked against it.

## F1 — Foundations

- [x] **01 — Build structure and toolchain** — Depends: none.
  - The template's skeleton (game-port-template 4a9a7c9), renamed sorz.
  - Gate: `zig build`, `test`, `smoke`, `verify` and `web` pass; the agent binary has no SDL.
- [x] **02 — Infrastructure carried over** — Depends: 01.
  - From sor-remaster, each piece reviewed against DESIGN.md before it lands: the platform
    contract's transport and the hosts' options; the SDL host's window and pacing; the agent
    host's commands (keys, shots, WAV, frames); the browser page (served files, its look, its
    checks); the native command line and providers; network play's protocol, session, transport
    and the relay; the settings record; the log lines; the build's checks (`verify`,
    `check_alone`, `web-check`, `browser-check`); the PNG and JSON readers.
  - Gate: a blank scene runs on Linux, Windows (cross build) and in Chromium; network play joins
    two agent hosts and a page through the relay; every check passes.
- [x] **03 — The engine's rule against the console's terms** — Depends: 01.
  - A build check that fails on hexadecimal addresses and console terms in the engine's sources
    (DESIGN.md P1), with the extractor and its tests exempt.
  - Gate: the check fails on a planted address and passes on the tree.
- [x] **04 — Semantic traces** — Depends: 01.
  - The event vocabulary (DESIGN.md V2); an observer in sor-remaster that derives it from its
    state each tick (outside its simulation); a trace format and a comparison tool that names the
    first difference and applies tolerances.
  - Gate: sor-remaster's traces of the attract demo and of round 1 are written, repeatable, and a
    planted difference is named.
  - [x] The vocabulary and the observer in sor-remaster (its `docs/traces.md`, `--trace-events`,
    e2d34a2); the comparison tool carried into sorz (`sorz-agent trace-compare`). Checked
    2026-10-05: the attract demo (7,600 display ticks, 1,969 events) and round 1 played from
    power-on (18,000, 26,311 events, 160 hits) traced twice, byte-identical; a hit's damage
    changed by one is named with its line, field and tick.
- [x] **05 — Scenarios** — Depends: 04.
  - Starting situations taken from sor-remaster (its state at a tick, converted for the players
    and the common enemies), and scripted scenarios from power-on for the rest (D14); the
    measurements of V3 (frame data, speeds, arcs, AI timings, spawns).
  - Gate: a scenario runs in both programs and its measurements are compared.

## F2 — Content and presentation

- [x] **06 — Content model and extractor (art)** — Depends: 02.
  - The content's schema, versioned and validated; the extractor from the ROM for palettes, art,
    fonts, tile maps and sprite frames (with their pieces), by name.
  - Gate: two extractions are byte-identical; every file loads; the art equals sor-remaster's
    decoded art.
- [x] **07 — Renderer** — Depends: 06.
  - Layers with per-line and per-column scroll, a fixed layer, sprites with priority and palette,
    four palettes, fades and cycles; drawn by cell and run; composed only when changed.
  - Gate: synthetic frames exact; a debug build draws a frame in under 1 ms.
- [x] **08 — Scenes and the flow graph** — Depends: 07.
  - The scene stack and the flow graph; the Sega logo, the intro, the title, the game menu,
    options and character select.
  - Gate: each screen's pictures equal sor-remaster's at the same moments, and its timings.

## F3 — Sound

- [x] **09 — Sound content and sequencer** — Depends: 06.
  - The music and effects as readable sequences (extractor); the sequencer with the driver's
    semantics and priorities; the chip models carried over (YM2612, PSG, DAC, model 1).
  - Gate: every song and effect gives sor-remaster's driver's register writes, then its PCM.

## F4 — Round 1

- [x] **10 — World and systems** — Depends: 08.
  - Entities with typed fields and handles; the systems in their order; fixed-point; the random
    generator; the logic tick (D13).
  - Gate: unit tests; a world of synthetic entities replays identically.
- [x] **11 — Axel** — Depends: 10, 05.
  - His moves as data (frames, boxes, damage, sounds), walking, jumping, attacks, grabs, throws,
    the special attack.
  - Gate: similar to sor-remaster in each move's measurements.
- [x] **12 — Round 1's enemies, items and boss** — Depends: 11.
  - Their definitions, behaviours and AI; weapons and food.
  - Gate: similar in their measurements and AI timings.
  - [x] Checked 2026-10-05: `similar-check -Dpads=...` on the catalogue's ai-* and item-*
    families, every 4th run, with sorz's item-knife and item-bat: 168 of 175 runs the same as
    sor-remaster's (ai-s2c's 8 again since the hold's fix). Per kind (the catalogue's m_ai measures), Signal, the knife Galsia, Antonio,
    the knife, the boomerang and the pipe are equal; the Galsia, the stalker, the pipe Galsia,
    the acrobat and the brawler are within tolerance; none differs. The items' families (apple,
    beef, pipe, knife, bat) are equal. The hit sparks are compared since then, in the recorded
    round's trace and pictures as well.
  - [ ] Open: the runs that still part come from the take-up, not from play: a pipe Galsia's
    offsets turned by waits before the situation, a brawler's follow, a knife Galsia's frame
    pace. The bat's splinters go at the ground, not by the floor's cells (item 15).
- [ ] **13 — Round 1's script and the round's screens** — Depends: 12, 09.
  - The map, the camera's stops, the waves, the status bar, the timer, pause, continue, game over,
    and the name entry of a score that enters the high-score table as its player's lives run out.
  - Gate: similar for round 1 end to end; the user plays it.
  - [x] Checked 2026-10-08: the attract demo equal to sor-remaster at every display tick in
    trace, sound and pictures (the accepted differences named in `src/tools/accepted.zig`); the
    recorded round 1 play equal to round tick 10956; round 1's bot runs with Axel, Adam, Blaze and
    two players equal. The user's play is pending.

## F5 — The whole game

- [x] **14 — Adam and Blaze, two players** — Depends: 13.
  - Adam's and Blaze's definitions from the ROM, played by the player's behaviour (each
    character's own ways as data); each player's choice at the select reaching the round; two
    players in the round: player 2's status bar, their blows on each other, the enemies' choice
    between them, each one's special attack, the script's two-player records.
  - Gate: similar to sor-remaster in each of Adam's and Blaze's catalogue moves, and in the two
    players' blows, the enemies' choice and the special attacks; a round from power-on with Blaze,
    and one with two players, equal in trace, frames and sound; the user plays them.
  - [x] Checked 2026-10-05: `similar-check` (Adam's 16 moves and Blaze's 16 equal, Axel's 18
    still, the two players' 6), `round-check` (`blaze`, `two`, and `join` as Adam), the SDL build
    under Xvfb with XTEST keys (Adam, Blaze, two players on one keyboard). The user's play is
    pending.
  - [x] The players' holds of each other (2026-10-05): a walk into the other holds it; the
    knees, the throw that lifts the other over into its spin and fall, C's lift over the one
    held, the back drop, the jump back over it, the jump out and the counter, each one placed
    from the other by its definition's `partners`. `similar-check`'s 12 scenarios of them equal
    (three pairs of characters, either player holding).
- [x] **15 — Rounds 2 to 8** — Depends: 13.
  - Their enemies, bosses and set pieces (the ship, the lift, the offer, Mr. X).
  - Checked 2026-10-08: each round's run by sor-remaster's bot (`bot TICKS`, its pads recorded
    and replayed in sorz) equal in trace end to end, rounds 2 to 8, with sound and pictures
    compared at every display tick (the accepted differences named); coverage runs with Blaze
    alone and with Adam and Blaze in rounds 2 to 7 equal end to end but two-player round 5 (a
    trace field of a time over) and round 6 (round 4's boss too heavy to throw, in progress); the
    offer's four ways (both refuse, both accept, one alone, the duel) against the original's own
    captures. The user's play is pending (item 17).
- [x] **16 — Endings, high scores and name entry** — Depends: 15.
  - The name entry at the endings (play's own is item 13's).
  - Checked 2026-10-08 against the original's captures: round 8's clear and its name entries;
    the good ending (660 of 771 sampled pictures equal, the rest a cloud's random height in a
    taken-up run and pixel crossings); the ending in the boss's chair (884 of 884 equal); the
    high scores after them.
- [ ] **17 — Whole-game acceptance** — Depends: 14, 15, 16.
  - Gate: similar for every mechanic; the user plays the game through, alone and with two
    players.

## F6 — Network play, settings and variants

- [x] **18 — Network play** — Depends: 02, 13.
  - Each machine its own front end; the players meet in the game: the second player's 2 PLAYERS
    joins the first's at the select or mid-round, the host's canonical form loaded by the guest
    (a loadable form), the host's sound beside it, then lockstep; leaving, a dropped connection, a
    third turned away; A1 and A2's checks (DESIGN.md section 9).
  - [x] Checked 2026-10-05 on round 1 as it is: `netplay-check -Drom` (own menus; joins at the
    select and mid-round, the states, pictures and sound equal on; a guest leaving and another
    joining; a third turned away; a dropped connection back in time and not; a planted difference
    named; two processes over WebSockets, the guest joining mid-round, the same sound since the
    join), `browser-check -Drom` (a page joining a native host's round; two pages through the
    relay, the first alone before the second joins; a third turned away; the guest leaving).
  - [ ] Open: two real machines under `netem`'s latency and loss (A1), and the user's play.
- [x] **19 — Settings and variants** — Depends: 08.
  - The settings scene, reached from OPTIONS' ADVANCED SETTINGS and from START during play (the
    settings key in the original), showing the machine's own players; the variants (original,
    extended, network: DESIGN.md 10.7) as flow graphs and policies; the network flow (each
    machine its own menus: 2 PLAYERS and OPTIONS).
  - Gate: each variant's flow tested; the original's screens equal sor-remaster's.
  - [x] Checked 2026-10-05: `variants-check -Drom` (the original's menu, options, pause and
    settings key; the extended ADVANCED SETTINGS and START opening the settings; the network
    page's menu, settings and START; a guest's OPTIONS), `screens-check` on the original,
    `browser-check -Drom` (part `flow`). The user's play is pending.
- [x] **20 — An extension** — Depends: 19, 14.
  - The same character twice in two players, its palette from data.
  - Gate: it plays, and nothing outside the policy and the content changed.
  - [x] Checked 2026-10-05: the extended variant's policies let both players choose a character
    (`characterTaken`) and draw the second with its definition's `duplicate` colour map
    (`duplicate_colours`); the colours are content, the port's choice. The four palettes are all
    in use in play, so the map recolours within the players' palette. Beside the policy and the
    content: a sprite's colour map (the renderer's, generic), a player's map carried to its
    sprites (the world's), and the rule's two readers (the round's players; the select, where
    two cursors may share a portrait). Played with the agent host (two Axels, the select's
    labels taking turns); variants-check and round-check's `two` equal.

## F7 — Platforms and exactness

- [ ] **21 — Windows acceptance** — Depends: 17. Tests and the game on Windows itself.
  - Checked 2026-10-08 on Linux: `zig build all` cross-builds the Windows executables. Under
    Wine, 419 of 430 unit tests pass: the 10 of the native transport fail on Wine's missing
    sockets device (`docs/lessons.md`), and the engine-terms check's own test fails (expected 1
    finding, found 3; likely its paths written with `/`); to look at on Windows itself.
- [ ] **22 — Browser acceptance** — Depends: 17. Chromium, a real sound device and gamepad.
- [ ] **23 — Exact** — Depends: 17.
  - Only if similar is not good enough (the user): traces equal tick by tick from power-on,
    pictures and sound equal.

## Standing rule

- [ ] **S1 — The repository stands alone** — Depends: none.
  - Building and testing use nothing outside the repository and no proprietary data of the game.
  - Gate, checked at each phase: in a fresh clone with an empty environment, `zig build`, `zig
    build test` (no test skipped), `smoke`, `verify` and `web` pass; each executable, copied alone
    into an empty directory, runs.

## Decisions

- [x] **D1 — Sound**: the YM2612 (a Zig port of ymfm), the PSG, the DAC and the model 1 output
  stage, carried over from sor-remaster.
- [x] **D2 — Saves**: the cartridge has none; the port stores only its settings.
- [x] **D3 — Slowdown**: the original's dropped display ticks (a sound handler outlasting its
  frame) are not reproduced in the game; the user left the choice to the lead (2026-10-05). A
  test-only option may model them if a comparison with the original's own play needs it; the
  comparisons with sor-remaster, which does not reproduce them either, do not.
- [x] **D4 — Sprite limits**: not reproduced.
- [x] **D5 — Region**: 60 Hz, English text by default.
- [x] **D8 — Content**: extracted from the user's ROM into a human-readable tree; `sorz ROM` or
  `sorz DIR`.
- [x] **D9 — Licence**: unlicensed for now; ymfm's BSD-3 notice kept with its port.
- [x] **D10 — Browsers**: Chromium.
- [x] **D11 — Network play**: netplay with a native host and a browser or native guest, a relay
  for two browsers; delay-based input lockstep over WebSocket (DESIGN.md section 9).
- [x] **D12 — Exactness**: similar first, then exact if similar is not good enough; sound exact
  from the start (2026-10-02).
- [x] **D13 — The logic tick**: the original's 30 Hz in play (2026-10-02, design Q1).
- [x] **D14 — Scenarios**: converted states for the players and common enemies, scripted
  scenarios for the rest (2026-10-02, design Q2).

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
- [ ] **04 — Semantic traces** — Depends: 01.
  - The event vocabulary (DESIGN.md V2); an observer in sor-remaster that derives it from its
    state each tick (outside its simulation); a trace format and a comparison tool that names the
    first difference and applies tolerances.
  - Gate: sor-remaster's traces of the attract demo and of round 1 are written, repeatable, and a
    planted difference is named.
- [ ] **05 — Scenarios** — Depends: 04.
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
- [ ] **11 — Axel** — Depends: 10, 05.
  - His moves as data (frames, boxes, damage, sounds), walking, jumping, attacks, grabs, throws,
    the special attack.
  - Gate: similar to sor-remaster in each move's measurements.
- [ ] **12 — Round 1's enemies, items and boss** — Depends: 11.
  - Their definitions, behaviours and AI; weapons and food.
  - Gate: similar in their measurements and AI timings.
- [ ] **13 — Round 1's script and the round's screens** — Depends: 12, 09.
  - The map, the camera's stops, the waves, the status bar, the timer, pause, continue, game over.
  - Gate: similar for round 1 end to end; the user plays it.

## F5 — The whole game

- [ ] **14 — Adam and Blaze, two players** — Depends: 13.
- [ ] **15 — Rounds 2 to 8** — Depends: 13.
  - Their enemies, bosses and set pieces (the ship, the lift, the offer, Mr. X).
- [ ] **16 — Endings, high scores and name entry** — Depends: 15.
- [ ] **17 — Whole-game acceptance** — Depends: 14, 15, 16.
  - Gate: similar for every mechanic; the user plays the game through, alone and with two
    players.

## F6 — Network play, settings and variants

- [ ] **18 — Network play** — Depends: 02, 13.
  - The session on the new canonical state; A1 and A2's checks (DESIGN.md section 9).
- [ ] **19 — Settings and variants** — Depends: 08.
  - The settings scene; the variants (original, extended, network: DESIGN.md 10.7) as flow
    graphs and policies; the extended OPTIONS lines; the network flow (one player a machine).
  - Gate: each variant's flow tested; the original's screens equal sor-remaster's.
- [ ] **20 — An extension** — Depends: 19, 14.
  - The same character twice in two players, its palette from data.
  - Gate: it plays, and nothing outside the policy and the content changed.

## F7 — Platforms and exactness

- [ ] **21 — Windows acceptance** — Depends: 17. Tests and the game on Windows itself.
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
- [ ] **D3 — Slowdown**: the original's dropped frames are not reproduced, pending the user.
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

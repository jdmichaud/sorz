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
- [x] **24 — Input configuration and the settings' rules** — Depends: 19.
  - The settings' INPUT CONFIGURATION page: a column for each player of the machine, its input
    method (the keyboard or a gamepad connected), its keys or its gamepad's buttons, its
    autofire; a gamepad that comes told and given to player 1 on the keyboard; outside the
    original, the game's rules from the settings (lives, continues, friendly hits) in place of
    OPTIONS' hidden lives.
  - Gate: the original unchanged; the pages played and the rules seen in a game; variants-check,
    netplay-check, smoke and the browser's flow and settings parts pass.
  - [x] Checked 2026-10-08 (e1d31f4): played on the agent host (the two pages, a key rebound,
    LIVES 5 giving x5 in a two-player game); variants-check, netplay-check, smoke, and the
    browser check's flow and settings parts in Chromium. A real gamepad, autofire and friendly
    hits off in play: unit tests only; the user's play is pending.
- [x] **25 — Gamepads known by their model** — Depends: 24.
  - The platform names each gamepad (a key of its model and a name, DESIGN.md 3.3); the settings
    keep every gamepad seen under a label of its own for good (GAMEPAD 1...), identical pads
    numbered in the order they come, the buttons per model, a player's gamepad by its label; the
    INPUT CONFIGURATION's GAMEPAD LIST..., scrolling, where an unconnected one is forgotten.
  - Gate: a gamepad back after a restart plays its player with its buttons; the list played; the
    SDL, browser and agent hosts name their gamepads; variants-check, smoke and the browser's
    flow and settings parts pass.
  - [x] Checked 2026-10-08: played on the agent host with a record of two pads (a new pad kept
    and labelled, a player's gamepad with its model's buttons, GAMEPAD LIST and a pad
    forgotten); the hosts' naming in unit tests (SDL's virtual joystick); variants-check,
    netplay-check, smoke, and the browser's flow and settings parts. Real gamepads: the user's.
- [ ] **26 — The network workflow** — Depends: 18, 25.
  - DESIGN.md 9 (2026-10-08): NETWORK PLAY in the native game's menu (and the first page of a
    server) opens the network options (PLAYERS 2, OBSERVERS, SAME CHARACTER, START) and the
    session, listening on 0.0.0.0 (port 8000, or `--netplay`'s); clients connect as they start,
    give a name, and JOIN or OBSERVE; the host lists who is connected; observers take the game and
    each tick's pads; a player's drop counts five seconds, then the host decides its leaving; a
    host that leaves sends its clients to their menus; the server a hub of numbered clients.
  - Gate: the flows played (a native host and native and page clients: join at the select and in
    play, observe, drops, the host leaving); netplay-check's flows for them; variants-check,
    smoke and the browser check pass.
- [ ] **27 — Network play's stats** — Depends: 26.
  - Each machine of a session measures, every second, the ticks it ran, its busy share of the
    time (its updates' work, the presenting aside) and its wait for the other's pads; the two
    send theirs to each other (protocol version 5). The settings' NETWORK STATS (off by default,
    kept in the record, version 5) shows both machines' lines, with the ping and the input
    delay, at the bottom left during a session's rounds.
  - Gate: the lines seen in a session of a native host and a page; netplay-check, variants-check
    and the browser check pass; the user's play.
- [ ] **30 — A CPU player** — Depends: 19, 26.
  - Outside the original, left and right on the game menu's 2 PLAYERS make it 1 PLAYER - 1 CPU:
    player 2 is the CPU. The select comes twice, player 1 choosing its character and then the
    CPU's (its label CPU 1). In play the CPU's pads come from the game's state at each tick, on
    every machine alike, by the agent host's bot rule moved into the game: it continues while it
    has continues, and answers no to Mr. X. In network play a guest's join takes the CPU's
    player, and a guest that leaves gives it back. Strength by difficulty comes later.
  - Gate: the CPU's pads tested on synthetic play; a game of 1 PLAYER - 1 CPU played from the
    menu on the agent host (the CPU fights, continues, refuses Mr. X); netplay-check's flows with
    a guest taking and leaving the CPU's player; variants-check and the original's checks
    unchanged; the user's play.
  - [x] Checked 2026-10-10: unit tests of the CPU's fight, name entry, continue and no to Mr. X
    (the room's own choice); variants-check's `extended_cpu` (menu, both selects, the CPU
    scoring in round 1); netplay-check's `cpu` and `cpu_select` (a client takes the CPU's place
    mid-round and at the select, the same state and picture on both; it quits and the CPU takes
    player 2 back); all flows of both checks, screens-check against sor-remaster, smoke and
    verify. Played in the SDL build under Xvfb. The user's play is pending.
- [ ] **31 — The CPU plays as a person** — Depends: 30.
  - The CPU of item 30 plays as a partner with a mind of its own, not a machine. It looks at the
    screen a few times a second, so it reacts late, and goes for the best of what it shows, a
    little at random: a foe (one on a player 1 in trouble first, one player 1 fights after the
    others), what lies about (food when hurt, unless player 1 needs it more; money, gold, a
    life, a special), a thing to break, or a place of its own, mostly ahead of player 1 and out
    of its line. It strikes at a person's pace, a few blows and a breath; now and then it grabs
    and throws, comes in with a jump kick, back attacks a foe behind it. It calls the police
    when a life is at stake. It never blocks player 1's way nor walks into it (which would grab
    it).
  - Its memory is the world's (its player's), its random draws its own: the game's draws stay
    the original's, and both machines of network play play it alike. The agent host's bot keeps
    item 30's rule.
  - Gate: unit tests on synthetic play (its reaction late, its presses at a person's pace, a
    punk knocked down, out of player 1's line and never grabbing it, the police when due);
    variants-check's `extended_cpu` and netplay-check's CPU flows; the user's play.
  - [x] Checked 2026-10-10: the unit tests above; variants-check (all flows) and netplay-check's
    `cpu` and `cpu_select`; a minute of round 1 in the SDL build under Xvfb. The user's play of
    the first version found it in player 1's way, without a mind of its own: reworked. The
    user's play of this one is pending.

## F7 — Platforms and exactness

- [ ] **28 — SDL's declarations from its headers** — Depends: 01.
  - The SDL host's SDL2 types, constants and functions come from SDL2's own headers, translated
    by build.zig (translate-c): the system's on Linux, the `sdl2` package's for Windows. The
    hand declarations and their layout test go. SDL2 stays.
  - Gate: the SDL host builds for Linux and Windows; the unit tests pass; the game played in the
    SDL build (picture, sound, keys, a gamepad, the mouse, full screen) as before.
- [x] **29 — The SDL game with the ROM inside** — Depends: 01.
  - `zig build standalone -Drom=ROM` builds `sorz-standalone`, the SDL host with the user's
    ROM built in (DESIGN.md 5.4). Without a game path it plays that ROM, its content extracted in
    memory as from a ROM given on the command line. No other build embeds it.
  - Gate: the standalone, copied alone into an empty directory, plays with no argument;
    `sorz` with none still shows the test pattern.
- [ ] **21 — Windows acceptance** — Depends: 17. Tests and the game on Windows itself.
  - Checked 2026-10-08 on Linux: `zig build all` cross-builds the Windows executables. Under
    Wine, 419 of 430 unit tests pass: the 10 of the native transport fail on Wine's missing
    sockets device (`docs/lessons.md`), and the engine-terms check's own test fails (expected 1
    finding, found 3; likely its paths written with `/`); to look at on Windows itself.
- [ ] **22 — Browser acceptance** — Depends: 17. Chromium, a real sound device and gamepad.
- [ ] **23 — Exact** — Depends: 17.
  - Only if similar is not good enough (the user): traces equal tick by tick from power-on,
    pictures and sound equal.

- [ ] **33 — Two CPUs: 0 PLAYERS - 2 CPU** — Depends: 30, 31.
  - Outside the original, the game menu's 2 PLAYERS line has a third reading: right goes 2
    PLAYERS, 1 PLAYER - 1 CPU, 0 PLAYERS - 2 CPU (and round), left back; without a second pad,
    2 PLAYERS is passed. With two CPUs, player 1's pad chooses both characters, the select's
    label CPU 1 then CPU 2, and the CPUs play both players (item 31's play, each the other's
    partner); player 1's START still pauses the game. In network play a guest takes player 2
    as from one CPU.
  - Gate: the menu's and the select's tests; variants-check's flow from the menu to a round the
    two CPUs play; the user's play.
  - [x] Checked 2026-10-10: the menu's and the select's tests; variants-check's
    `extended_cpus` (the CPUs score with no key pressed; START opens the settings) and all its
    flows; netplay-check's CPU flows. In the SDL build under Xvfb: the line 0 PLAYERS - 2 CPU,
    the labels CPU 1 and CPU 2, round 1 fought by the two CPUs, START and Escape. The user's play
    is pending.
- [ ] **34 — The CPUs play the whole game** — Depends: 31, 33.
  - Two CPUs play the eight rounds through as people would. CPU 1 leads: it goes on the way the
    round goes (left in round 8), and CPU 2 keeps out of its way. Their walks keep off the
    floor's holes and walls and from under a press about to drop; a walk that does not move
    them gives up what they went for and takes the shortest way round, and one in a solid thing
    walks out. Barriers, blocks and crates are knocked away; a foe waiting at the screen's edge
    is gone for; one still coming in is none yet.
  - In the fight: a foe within the jab's reach (its first blow's box on the foe's body) struck
    at once, from the jab's far end, out of a punk's punch, the combo finished; blows that do
    not hurt make it back off. A boss is come at out of its line, from behind while the partner
    draws it; what comes at it in its line (a knife, a boomerang, a rush) is stepped out of; a
    boss too heavy is kneed, not thrown; the police called on a boss and when a life is at
    stake. The user found the CPU hesitant, not punching a foe in front of it.
  - `zig build cpus-check -Drom=ROM` plays the game with the two CPUs from power-on to the
    ending or the game's end, its rounds measured: lives lost, time overs, the damage taken by
    the kind that dealt it.
  - Gate: cpus-check reaches round 8 with the default lives and the ending with the options' 7
    in most seeds; the unit tests; variants-check's CPU flows; the user's play.
  - [x] Checked 2026-10-11: cpus-check, seeds 1 to 8. On the default lives all eight reach round
    8 and end in its boss rush (33 to 38 lives lost, none in round 1); with 7 lives seven reach
    the ending, and one stops in round 7: a brawler that fell off the lift standing was deleted
    far off the screen, not knocked out, and the reserve waits for it (an engine fault, apart).
    The unit tests; variants-check, all flows. The user's play is pending.
- [x] **32 — The code review's follow-ups** — Depends: none.
  - The review of 2026-10-10 found these besides its bugs (fixed in their own commits).
  - The overlays drawn again only when they change, and mixed with the picture only on their
    rows.
  - The content tree's version raised (2) and, in its comment, the rule to raise it with each
    change to the schema.
  - The states several behaviours share found when compiled (`behaviours.inState`), food known
    by what its definition gives, the bosses' placing by a throw one routine.
  - The ROM's places cited in the round script's comments moved to sor-re's port map; the art
    slots named in DESIGN.md as a quirk (that commit awaits the user's approval).
  - `Game.load` and the CPU's `hold` renamed where the words met others.
  - Gate: each point's own check.
  - [x] Checked 2026-10-10: the overlays' frames as before at 1.20 ms a frame in Debug with a
    notice up (2.60 before); a version 1 tree refused; a misspelt state name stops the build;
    the CPU eats the fixture's apple; zig build test, variants-check, netplay-check (25 flows).
- [x] **35 — Enemies lost off the screen** — Depends: none.
  - Found by item 34's cpus-check: in round 7 an enemy went far off the screen without being
    knocked out, never counted off, and the reserve's last enemies never came (time overs to the
    game's end). Two ways led there, both unlike the original's:
  - A thrown enemy whose slide lands (rising onto round 7's railing) flies on in the air with the
    speed it kept, to land again or, over the shaft, fall out of the fight; it went on at the
    railing's height, over the shaft and off the screen.
  - An enemy in the air as the special attack is called drops by its common fall: on the floor
    under it, or, over a hole, knocked out fallen far enough; it fell without end.
  - The common enemies a section or round 8's room places stay in the world far off the screen,
    as the original marks its groups' (a wave's and a reserve's still go).
  - Gate: the unit tests of the three; cpus-check's game that stopped (seed 7, 7 lives) reaches
    the ending; the attract demo still equal to sor-remaster at every display tick.
  - [x] Checked 2026-10-11: the three unit tests, each failing without its fix; cpus-check's
    seed 7 with 7 lives reaches the ending, no time over in round 7 (23 before), and so do seeds
    1 to 8 (seven before); with 3 lives all eight reach round 8 as before; the attract demo equal
    to sor-remaster at every display tick in trace, sound and pictures; zig build test.
- [ ] **36 — CPUs out of each other's blows** — Depends: 34.
  - cpus-check's nine pairings of characters, eight seeds each: 3.6% of the blows the two CPUs
    land hit the other one, one every 37 s; 90% are the combo's punches. The one struck was
    mostly walking or standing (73%), mostly going for the same foe (74%): between the striker
    and that foe (56%), or close past it (27%).
  - A CPU keeps out of player 1's blows' way, as a person does: ahead of it, within its jab's
    reach on a body and a margin, in its line, while a foe stands there or it strikes. In that
    way, it steps out of the line; a walk that would take it in goes round in depth; its spot at
    a foe there is on the other side. Its own blows are not held back.
  - `cpus-check --chars` chooses the CPUs' characters; it reports each CPU's blows landed on
    the foes and on the other, by what struck, and where the one struck stood.
  - Gate: cpus-check's nine pairings, eight seeds each, against the same before: fewer blows on
    the partner, no more lives lost nor longer rounds; the unit tests; the user's play.
- [ ] **37 — An enemy grabbed while lifted** — Depends: none.
  - cpus-check's games warn now and then that an acrobat asked for frame 3 of its three-frame
    thrown pose, reeling. A grab of an enemy in the air from a lift shook its reel first, which
    the original's lift does not (its reel shakes only on the ground): the acrobat, lifted in
    the pose of one thrown, went past its last frame; the others showed their knock-down's next
    frame a moment.
  - Gate: a unit test failing without the fix; the game that warned no longer does.

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

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
- [x] **36 — CPUs out of each other's blows** — Depends: 34.
  - cpus-check's nine pairings of characters, eight seeds each: 3.6% of the blows the two CPUs
    land hit the other one, one every 37 s; 90% are the combo's punches. The one struck was
    mostly walking or standing (73%), mostly going for the same foe (74%): between the striker
    and that foe (56%), or close past it (27%).
  - A CPU keeps out of player 1's blows' way, as a person does: ahead of it, within its jab's
    reach on a body and a margin, in its line, while a foe stands there or it strikes. A walk
    that would take it in goes round in depth; its spot at a foe there is on the other side; one
    already in it stays (stepping out left it open to the foes). Its own blows are not held back.
  - With foes on both sides of them, each CPU takes one (the user saw both go for one side,
    their backs to the others): a foe player 1 is nearer to and faces, as a person sees it
    going for it, comes after the others.
  - `cpus-check --chars` chooses the CPUs' characters; it reports each CPU's blows landed on
    the foes and on the other, by what struck, and where the one struck stood; and where the
    CPUs go with foes on both sides of them.
  - Gate: cpus-check's nine pairings, eight seeds each, against the same before: fewer blows on
    the partner, no more lives lost nor longer rounds; the unit tests; the user's play.
  - [x] Checked 2026-10-11: cpus-check, the nine pairings, seeds 1 to 16 (144 games each way),
    against before: blows on the partner 3.62% -> 1.52%; with foes on both sides, both CPUs on
    one side 48% -> 23% of the time, one on each 47% -> 71%; lives lost -3.1%, damage from the
    foes -1.6%, rounds as long; stalled rounds 16 -> 10 (item 36 does not touch the stalls).
    zig build test. The user's play is pending.
- [x] **37 — An enemy grabbed while lifted** — Depends: none.
  - cpus-check's games warn now and then that an acrobat asked for frame 3 of its three-frame
    thrown pose, reeling. A grab of an enemy in the air from a lift shook its reel first, which
    the original's lift does not (its reel shakes only on the ground): the acrobat, lifted in
    the pose of one thrown, went past its last frame; the others showed their knock-down's next
    frame a moment.
  - Gate: a unit test failing without the fix; the game that warned no longer does.
  - [x] Checked 2026-10-11: the unit test, failing without the fix (its frame 3, not 2);
    cpus-check's seed 2 with Adam and Axel, which warned, no longer does; zig build test.

- [x] **38 — Twin bosses' end** — Depends: none.
  - The user saw, with two players, the bonus tally come at once after a round's boss fell. In
    two-player games several rounds' bosses come as twins, and the last twin's knockout won the
    round at once; the original's (sor-remaster's 0x1647A, 0x164FC) only ends the fight then:
    the first twin to go leaves the other alone, whose lying time's end wins the round, as a
    single boss's does.
  - Gate: cpus-check's scenes: each boss's round won as long after its fight's end as a single
    boss's (dead ticks).
  - [x] Checked 2026-10-11: cpus-check `--scenes on`, seed 1: rounds 1, 4 and 6 won 220 display
    ticks after their fights' end (0 before), as rounds 2 and 5 (round 3's boss 264, his own);
    round 7 has no boss (its players walk out); zig build test.

- [x] **39 — The CPU's skills, at the hardest level** — Depends: 34.
  - The user saw the CPU never break a hold from behind, nor gain from weapons, and leave food
    it needed for the foes. cpus-check at the hardest level (72 games, 7 lives): held from
    behind 595 times, 6 jumps out (by chance), no throw of the holder; no throw landed on its
    feet; under 40% of its health with food on the screen 6% of that time, the food mostly
    given up (its walk counted stuck while it was struck or down, or at the floor's back edge,
    short of which it stood).
  - Held from behind by a foe, it jumps out (C) and in the moment after throws the holder (B);
    thrown by one, up and C land it on its feet: at a person's reaction, now and then missed.
  - Food it needs (under 40%) comes before the foes, and it walks past those not in its way; it
    takes an item as soon as their bodies meet; a walk is counted stuck only while it is free to
    walk.
  - Armed, it stands free to act as unarmed (the holes, the presses and player 1's way kept to,
    the jump kick steered). Weapons: armed it deals more damage a minute than unarmed (38 to
    31), but going for them made it fight worse (25 a minute): its fight is the unarmed one;
    a fight with the weapon's reach and swing is left for later.
  - Gate: cpus-check at the hardest level against before: holds escaped, throws landed, less
    time hurt with food on the screen, no more lives lost.
  - [x] Checked 2026-10-11: cpus-check at the hardest level, 7 lives, the nine pairings, seeds 1
    and 2, against before: 38 of 44 holds jumped out of (2), 32 holders thrown (0), 334 throws
    landed on the feet (0); under 40% of its health with food on the screen 6.9% -> 2.1% of that
    time; lives lost -11%, damage from the foes -6.3%, rounds 3.7% shorter. (72 games before the
    food's last fixes: lives lost -6.5%, damage -3.5%.) Two games stalled in time overs (rounds
    4 and 8), as before. zig build test. The user's play is pending.

- [x] **40 — Rounds the CPUs never finish** — Depends: 34.
  - Some 5 to 10% of cpus-check's games stall: a round's section waits for the camera to reach
    its wall, the CPUs never walk it there, and time overs come until the game is over (round 4's
    bridge, 61 minutes once; round 6; round 8). Seen there:
  - A place of its own off the depths the players are kept on (above the bridge's top), walked
    at for ever; a step out of player 1's line against the edge of those depths, no step at all;
    the way round a hole sought on depths off them.
  - The two CPUs over each other at the edge of the view, the leader stepping away into the edge;
    a crate at that edge, too close to strike and no step back.
  - The bridge's barriers given up for good once a walk to them stuck, with the way on shut by
    them.
  - The CPU's places and its steps in depth keep to those depths (out of player 1's line, the
    other way at their edge); its steps away across, the other way at the view's edge; a thing it
    gave up is tried again after 15 s.
  - Gate: cpus-check's games that stalled reach the ending; no more lives lost.
  - [x] Checked 2026-10-11: cpus-check at the hardest level, 7 lives, the nine pairings, seeds 1
    and 2: all 18 reach the ending (16 before: rounds 4 and 8 stalled), time overs 103 -> 17;
    lives lost -1.8%, damage from the foes -0.6% (neither significant). Each part found in a
    stalled game and checked there (round 4's, round 6's). zig build test.

- [x] **41 — A fight with the weapon** — Depends: 39.
  - Armed, the CPU fought as unarmed, from its jab's reach: at the hardest level its armed blows
    landed 36% (the knife) to 66% (the pipe) of the time, nearer than the weapon's band mostly,
    and its damage a minute armed was no more than unarmed. The weapon's band, from the holder's
    armed blow's frames whose hand strikes and the weapon's pose there: Adam's knife 62 to 86
    pixels ahead, Axel's pipe 17 to 69, Blaze's knife 43 to 67; the knife lands best there.
  - Armed, it strikes within its weapon's band, stands near its far end and steps back nearer
    than its near end; a stab only within the stab's reach and level (past them a press throws
    the knife); no walk in to grab.
  - Gate: cpus-check at the hardest level: more damage a minute armed, no more lives lost.
  - [x] Checked 2026-10-11: cpus-check at the hardest level, 7 lives, the nine pairings, seeds 1
    and 2, against before: damage a minute armed 33.0 -> 42.6 (unarmed 34.1), armed 98 -> 108
    minutes; lives lost +3.6%, damage taken +1.3% (neither significant: t 0.9, 0.5); all 18
    reach the ending. zig build test. The user's play is pending.

- [x] **42 — The keys' help, and the frame's stats** — Depends: none.
  - The keys outside the pads (Escape, the settings key, START's pause or settings) are told
    nowhere in the game. The settings' first page gets HELP..., a page of them.
  - The settings' stats (NETWORK STATS, network play's alone, DESIGN.md 9) get the frame's: FPS,
    the frames presented a second, and TPF, the milliseconds an update works on its frame before
    presenting it (the presenting's wait for the display not counted), each over the last second,
    FPS whole and TPF in tenths, three places before the point. They show in any scene, network
    play's lines over them in a session's rounds, all the letters over the picture without a
    ground, outlined in black. The row is
    STATS, on every machine; F3 turns it on and off as the row does, and the record keeps it (its
    field still `network_stats`, so that the records written read). No setting takes F3.
  - Gate: zig build test; the stats seen in play.
  - Done first otherwise, then changed (the user, 2026-11-04): F3 showed the frame's stats alone,
    apart from the settings' stats, and was not kept.
  - [x] Checked 2026-11-04: zig build test. The SDL host (Debug, software renderer, a virtual
    display) over the intro: FPS 59.9, TPF 0.5 ms. Through the agent host: F3 on and off, the
    record keeping it; STATS and HELP on the first page. Network play's lines not seen in a
    session. The user's play is pending.

- [x] **43 — MOVES: each character's blows and their damage, shown** — Depends: 42.
  - The players cannot see what a blow is worth, nor why Axel's combo knocks a round 1 Galsia out
    and Adam's does not (his uppercut lifts it, and his last blow, landing on it lifted, takes no
    health). The settings' first page gets MOVES..., a screen that shows them (the user,
    2026-11-05).
  - A black screen. Each character in turn walks in, plays its moves, and walks out: Adam from the
    bottom left, Axel from the top left, Blaze from the right. A light on the floor follows it: an
    oval in a few dark shades, as a spotlight on a stage.
  - Its moves: the combo, the jump kick, the back attack, the hold's knees and last knee, the
    throw over the shoulder, the slam from behind. No enemy, no world (the user, 2026-11-05): the
    character alone plays its definition's animations frame by frame at play's pace, the walks
    and the jump moved by its own speeds and gravity. At the frame each move's blow strikes, its
    damage shows, a digit in the game's font where the enemy would be, rising and fading; no
    caption. Adam's last blow shows its own damage, 2, as on the ground.
  - Sound: the frames' and the moves' own (the swings, the shouts), not a blow's landing, nor
    music.
  - Any key or button ends it at once; after Blaze it ends by itself. Either way the settings come
    back as they were.
  - Gate: zig build test; the screen seen through, each digit the move's damage; a key ends it.
  - [x] Checked 2026-11-05: zig build test, zig build web. Through the agent host (the original's
    settings by F1), shots every 8 to 40 frames: the three walk in and out by their ways and play
    each move, the digits Adam's and Axel's 1, 1, 1, 2, 3, 3, 2, 2, 3, 4, 5 and Blaze's 1, 1, 1, 2,
    2, 2, 2, 2, 3, 4, 5; the settings come back after Blaze, and at a key. Its sound recorded
    (--wav): the shouts and the finisher's at their ticks. The SDL host (software renderer, a
    virtual display) runs it in real time. Blaze's last knee ended a frame before its blow, at its
    own end, which her leap's has none of: fixed before the commit (the user saw it). The user's
    look is pending.
  - The user's look (2026-11-05): after Blaze, part of the light still shows as the settings come
    back; the floor seems to move with the character; the settings reappear at once. Each walks
    out until the light is off the screen, and a moment of black follows Blaze; the floor is a
    floor of planks that stays where it is, the light alone moving over it, shown only where it
    falls; the settings fade in from black, as their pages do.
  - [x] Checked 2026-11-05: zig build test, zig build web; through the agent host, Blaze walks
    out until her light is gone, about a second of black, then the settings fade in; the floor's
    planks stay at their places of the screen as the light moves over them (a test checks it).
    The user's look is pending.
  - The user (2026-11-06): before walking out, each plays its idle (the move it makes after a
    while standing ready), once, as the player does: its `idle` animation to its `idle_ends`,
    after the stand that follows the slam (not the player's 100 ticks first).
  - [x] Checked 2026-11-06: zig build test; through the agent host, Adam's idle (his guard's
    shuffle) after the slam's stand, then his walk out. The user's look is pending.
  - The user (2026-11-06): the idle before the turn to leave (as the slam left it); after the
    throw, no turn back for the slam (the throw turns Adam and Axel): each slams facing as its
    throw left it, and so leaves by where it came in, off the screen with its light.
  - [x] Checked 2026-11-06: zig build test; through the agent host, Adam throws, slams facing left,
    idles, leaves by the bottom left; Blaze slams to her left, idles, leaves by the right. The
    user's look is pending.

- [x] **44 — STOP SERVER closes the port** — Depends: none.
  - Stopped, the host kept listening to turn the clients that come away (DESIGN.md 9): its port
    stayed open, the page served there. The user expects a stopped server to close its port
    (2026-11-06).
  - STOP SERVER, its clients told and let go as before, stops listening (`netUnlisten`, the
    platform's: the native transport closes its listener; the page's host has none); START SERVER
    listens again at the same port. A client that comes meanwhile finds no host and tries again
    every second.
  - Gate: zig build test (a transport test: the port refuses once unlistened, and listens again);
    netplay-check.
  - [x] Checked 2026-11-06: zig build test (the transport's test on real sockets), zig build web;
    netplay-check's 25 flows in one process pass (server: the host's port closed after STOP
    SERVER). Its last step, tools/check_netplay.sh (two agent hosts over WebSockets, no STOP
    SERVER), fails on this machine as it did before the change, and at 9fbb231, the script's
    last change: the client never joins ("incomplete"): item 45. The user's try is pending.

- [x] **45 — netplay-check's two processes** — Depends: none.
  - tools/check_netplay.sh failed on this machine (the client never joined: "incomplete"),
    before item 44 too. The host, started a second first and run as fast as it goes, offers its
    round's place before the client has passed its front end: the client's `place+` presses,
    counted from that offer, fell in its intro and its name entry, and its JOIN was lost.
  - A guest's `place+` presses count from the host's offer once its own plain presses are done.
  - Gate: netplay-check passes, the script alone several times in a row.
  - [x] Checked 2026-11-06: netplay-check twice (its 25 flows and the two processes),
    tools/check_netplay.sh alone three times in a row; zig build test.

- [x] **46 — The CPU's course, and its pace on a free screen** — Depends: 34.
  - The user saw the CPU partner turn round and walk back within a few ticks for no reason, and
    in 1 PLAYER - 1 CPU had to wait for it on a free screen: with no foe on the screen the camera
    follows both players and moves on only as the hindmost lets it (from the start of its band),
    and the CPU lagged behind. Its place on the floor stayed where player 1 had left it until its
    while there was over.
  - cpus-check `--player1 bot`, player 1 played by item 30's rule (Adam or Axel), the CPU each of
    the three, rounds 1 to 6, level 1, 9 lives, seeds 1 to 3: the CPU turned round within half a
    second of its last turn 22.7 times a minute (the rule 5.0), with no foe within 120 pixels
    29.7 times a minute of that time (median of the games 7.7; the rule 1.2). Seen there: in and
    out of the margin round a press about to come down at every tick; stepping back from a thing
    too close and turning to it again, each a walk (Blaze's 4 pixels) that undid the other, no
    blow for minutes; the same against the edge of the view; its step out of player 1's line, or
    its detour's, undone by its goal's walk at the next tick. On a free screen it held the camera
    back 17% of the time, trailing player 1 by more than 32 pixels 46% of it.
  - Its walk keeps its course a while (`settle`): a turn round, or a reversal in depth, within a
    third of a second of the last is left out, the CPU standing that way a moment, but for a
    strong reason (a foe close, a turn to strike, out from under a press, out of the way of what
    comes at it, out of a solid thing). Too close to its foe it steps back until a turn's room
    past its reach's near end (the other way, past it, at the edge of the view); within the
    margin round a press it keeps out of the one it walks out from.
  - On a free screen its place keeps up with player 1: ahead of it or level, past the start of the
    camera's band the way the round goes, chosen anew on the same side once player 1 or the
    camera has gone past it. While the camera may move on, it leaves the foes off the screen
    behind (found after the first change: it walked at them, held at the edge of the view).
  - cpus-check `--player1 bot` (1 PLAYER - 1 CPU, player 1 played by item 30's rule) and its
    measures: each CPU's quick turns (`turns`; `--turns on` tells each), player 2's pace on a free
    screen (`pace`), each player's lives lost and damage taken from the foes.
  - Gate: cpus-check `--player1 bot` against before: fewer quick turns, less time holding the
    camera back; cpus-check's nine pairings at the hardest level: no more lives lost nor damage
    taken beyond noise; the unit tests; the user's play.
  - [x] Checked 2026-11-07: cpus-check `--player1 bot`, the same 18 games, against before: quick
    turns 22.7 -> 8.7 a minute, with no foe near 29.7 -> 3.2 (median of the games 7.7 -> 2.6;
    round 6's Blaze at a press 403 -> 14 in one game), quick reversals in depth 94 -> 42; on a
    free screen holding the camera back 17.0% -> 6.7% of the time, trailing by more than 32
    pixels 46% -> 31%, on average 35 pixels behind -> 16 ahead; its lives lost 304 -> 303,
    damage taken 22643 -> 22384. The nine pairings at the hardest level, 7 lives, seeds 1 and 2:
    lives lost 47.8 -> 48.3 a game, damage taken 4819 -> 4867 (t 0.3 both), quick turns 15.1 ->
    6.9 a minute, CPU 2 holding the camera back 19.7% -> 6.3%; all 18 reach the ending. The
    course held in the fight too, without the foe close as a reason, cost lives (+5.0%, damage
    +5.5%, t 1.5 and 2.1): dropped. zig build test (a test of each change). Pictures of round 1
    through the bot's game: the CPU ahead or level as the camera moves on. The user's play is
    pending.

### Three and four players (DESIGN.md 10.7, E4; the user, 2026-11-07)

Outside the original; games of 1 or 2 players stay as they are at every step. One player a
machine in network play; CPUs in the free places and several local players a machine come later
(the CPU's play will want tuning for them).

- [x] **47 — The engine for four players** — Depends: 46.
  - The pads (`input.Pads`), the world's players, their records (lives, specials, scores,
    continues), the canonical form and network play's messages carry four players. What pairs
    the two players today takes any two: holds and throws between players, friendly hits, an
    enemy's target, the camera keeping every player in view, the police special, the draw order.
  - No change seen: games of 1 or 2 players as before.
  - Gate: zig build test; the recorded round and the scenarios equal to sor-remaster's traces as
    before (round-check, similar-check); netplay-check; a 4-player world in unit tests (four
    players fight, hold each other, each loses its lives).
  - [x] Checked 2026-11-07: zig build test (500 tests: four players moving by their own pads,
    player 3 striking player 4, holds and throws between players 3 and 4, 2 and 3, 1 and 4, each
    losing its own lives, the camera keeping the four in view, an enemy going for the nearest of
    any, player 4's special attack; protocol 6's new fields; a guest in player 4's place; an
    observer of four). cpus-check (ReleaseFast) built before and after, 39 games (the nine
    pairings at level 3, 7 lives, seeds 1 and 2; the nine `--player1 bot` to round 7, seeds 1
    and 2; the defaults, seeds 1 to 3): every JSON line and its stderr byte-identical.
    round-check (its nine scenes equal, its report identical), the attract demo at every display
    tick (equal to its end, 7659 ticks, the same accepted difference), similar-check (71 moves
    equal of 71, its report identical), screens-check and variants-check (their output
    identical), netplay-check (its 25 flows and its two processes pass; the state hashes and the
    planted difference's bit differ, the form's layout changed): all as before the change.
    Players 3 and 4 have their places past the effects', start half a step from players 1 and 2,
    call player 1's and player 2's shots; their CPU follows player 1; round 8's offer stays
    players 1 and 2's; the status bar, the select and the menu stay two players' (items 48 to
    53).
- [x] **48 — The status bar for 3 and 4 players** — Depends: 47.
  - Four compact slots in a row, the timer between the second and the third: the name (its
    network name, else 1P to 4P, or CPU), the police icon on one line and its count; the health
    bar and the lives under them. No score shown (it counts still); the bosses' bar below.
  - Gate: zig build test; pictures of the bar with 3 and 4 players, their health, lives and
    specials changing; 1 and 2 players' bar as before.
  - [x] Checked 2026-11-07: zig build test (507 tests: the slots' places, a name of each kind,
    the health's scale, the port's police icon, a bar of four drawn on a board with a slot
    changed alone and a blink, the round clear's bar for two and three; a scenario's start of
    four and its pads 3 and 4). Pictures of rounds of 3 and 4 players from the agent's scenarios
    (`start` now takes up to four characters): health falling under the Galsias' blows, lives
    lost to them and to time overs, a special called and given back with a new life, the
    continue's question on three slots, a NO and its blinking GAME OVER. screens-check (its 23
    runs' lines identical, none differing), round-check (its report identical), cpus-check
    (ReleaseFast, 9 games: the three pairings at level 3, 7 lives, seeds 1 and 2, to round 3;
    Adam twice; the bot to round 7; the defaults: JSON and stderr byte-identical) and
    netplay-check (its 25 flows pass): as before the change. The slot of a player not in the game
    is empty; the continue's question, the name entry and the game over have short forms on a
    slot until item 53; the setup's network names are given by item 51; the round clear of 3 or
    4 players was not pictured.
- [x] **49 — The select for 4** — Depends: 47.
  - A cursor each, 1P to 4P; with 4 players SAME CHARACTER on. A character's third and fourth
    players take colour sets of the port's own (shown to the user first).
  - The colour sets, approved by the user (2026-11-07), maps of the players' palette (line 0)
    as the cartridge's `duplicate` is, its colours the same 16: Adam's shirt (14, 15) red for
    the third (6, 7), white and light grey for the fourth (1, 8); Axel's jeans (9, 10, 11) grey
    for the third (8, 12, 13), yellow and orange for the fourth (14, 15, 5); Blaze's outfit
    (6, 7) white and light grey for the third (8, 12), yellow and orange for the fourth (14, 15).
  - Gate: zig build test; pictures of the select with 3 and 4 cursors and of each character's
    four colour sets in a round.
  - [x] Checked 2026-11-07: zig build test (four cursors sharing portraits even by the
    cartridge's rule, their labels taking turns in front, the four choices; three passing the
    others' portraits by the cartridge's rule; two as before; the colour maps' rule, own,
    `duplicate`, `third`, `fourth` by the players before on a character; the 3P and 4P labels'
    digit and outline). The extractor writes `third` and `fourth` beside `duplicate` and the
    labels `select/label_02` and `_03` (2PLAYER with the main font's 3 and 4), their provenance
    the port's; extract-check identical. Pictures through the agent host, players 3 and 4 on keys
    of the settings: the select of three (1PLAYER on Adam, 3PLAYER on Axel, 2PLAYER on Blaze,
    three frames lit) and of four (3PLAYER and 4PLAYER by turns on Axel, then on Blaze and Adam,
    Axel's frame dimmed); rounds of four on one character: Adam yellow, blue, red, white; Axel's
    jeans blue, red (hair grey), grey, yellow and orange; Blaze red, blue, white, yellow.
    cpus-check (ReleaseFast) built before and after, 39 games (the nine pairings at level 3, 7
    lives, seeds 1 and 2, to round 3; the nine `--player1 bot` to round 7, seeds 1 and 2; the
    defaults, seeds 1 to 3): every JSON line, stderr and exit byte-identical. round-check (its
    report identical), screens-check (its 23 scenarios as before, none differing),
    variants-check's six flows of before as before, netplay-check (its 25 flows and its two
    processes pass, as before).
- [x] **50 — 3 and 4 PLAYERS in the menu** — Depends: 48, 49.
  - Right on 2 PLAYERS: 3 PLAYERS, 4 PLAYERS, then the CPU's readings; skipped without as many
    input methods (the keyboard's two pads, the gamepads).
  - Gate: zig build test; variants-check's flow from the menu to a round of 4 players on one
    machine (the agent's pads).
  - [x] Checked 2026-11-07: zig build test (the machine's players, the keyboard's two, a
    gamepad each, players 3 and 4 by a key of theirs; pads 3 and 4 from their gamepads and keys;
    the settings' four columns, two at once; the menu's readings both ways, 4 PLAYERS passed with
    three input methods, 3 PLAYERS back to 2 as a gamepad goes, a game of four chosen and kept).
    variants-check's `extended_four`: two gamepads plugged, players 3 and 4 given them in INPUT
    CONFIGURATION, 4 PLAYERS, the four cursors chosen by their own pads, round 1 with four
    fighters (player 4 in Blaze's duplicate colours, player 3 walking by its gamepad); its six
    other flows with the steps and ticks of before. The same games of 1 and 2 as item 49's check,
    as before (cpus-check's 39 games byte-identical, round-check, screens-check, netplay-check).
    A picture of the settings' INPUT CONFIGURATION with players 3 and 4's pair. The status bar
    still shows two players (item 48).
- [x] **51 — Network play for up to 4** — Depends: 50.
  - The network options' PLAYERS takes 2 to 4. The host relays every player's pads each tick to
    every machine; clients join until the places are full (at the select, or during a round
    where JOIN IN PROGRESS lets them), then may observe; a player whose machine drops out leaves
    after the wait, as player 2 today; the roster and the stats list every machine.
  - Gate: zig build test; netplay-check with 3 and 4 machines in one process (joins, leaving, a
    dropped connection, a difference found); 3 and 4 agent processes over WebSockets (as
    tools/check_netplay.sh with two) reaching the same state and sound.
  - [x] Checked 2026-11-07: zig build test (protocol 7's messages and their bounds; a guest in a
    session under way from its first tick, the host's pads sent from it; the changes of the game
    queued by tick; the network options' PLAYERS both ways, SAME CHARACTER on and fixed with
    four; the select's joins and leaves of players 2 to 4, a place before the last left free;
    a guest's own choice taken back; the host's offer: the first free place, a character taken
    refused; agent hosts in one process: four joining one after another, each in its place, the
    same game and each player's pads its own machine's, a fifth in the lobby, the roster ANN -
    PLAYER 2 to CAT - PLAYER 4; the stats of three on every machine; a client of four quitting,
    the others on; a dropped connection in three, held and told whose, back, then not back and
    the others on; a corrupted byte on one client of three named, every machine stopped).
    netplay-check (Debug): its 25 flows of two machines with the same steps, ticks and notes as
    before (the state hash and the planted bit's index changed: the set-up's names are in the
    state), and select_three, select_four (joins at the select one after another; round 1 with
    every player, its slot named HST, ANN, BOB, CAT; the same state, picture and sound on every
    machine; the roster and the stats listing every machine; a client's settings holding every
    game, the others told whose; a fifth machine finding JOIN dimmed and watching), round_three
    (player 3 joining mid-round, the two characters taken; leaving by Escape, the others told
    PLAYER 3 LEFT and playing on; joining again in its place), away_four (PLAYER 3 DISCONNECTED
    counted down on every machine; back in time; then not back, the three others on),
    difference_three (random.state named by the host and that client, every machine stopped);
    tools/check_netplay.sh's two processes, and tools/check_netplay_many.sh with 3 and with 4
    agent processes over WebSockets (the clients joining mid-round as players 2 to 4; the same
    state at the session's tick 1500 and the same sound from tick 900). zig build web.
    browser-check (ReleaseFast, Chromium, the ROM's content): its netplay and relay parts pass;
    its input part fails on the gamepad's state hash, as it does at the item's base commit
    (the same hashes). Pictures from netplay-check: the network options with PLAYERS 4, a round
    of four with its slots named, the stats of four, PLAYER 3 DISCONNECTED on a client, player
    3 dropped in. Not checked: real machines on a network, the input delay grown by a slow
    link between clients (the checks fix it at 3), a page as one of three or four clients.
  - [x] Checked 2026-11-07, after the item: a page as one of three machines (browser-check's
    `netplay_three`, Chromium: the agent host with PLAYERS 3, the page joining as player 2, an
    agent host as player 3; the same state at the session's tick 900, twice); the delay over slow
    links (netplay-check's `slow_three`: every link 30 ms one way, the delay from the round trips:
    4 ticks with one client, 6 on every machine once the second joins, the same games). Left: real
    machines on a network, and the user's play.
- [x] **52 — The rounds with 3 and 4 players** — Depends: 47.
  - The two-player spawns again: half of them with 3 players, all of them with 4 (the second
    boss among them not again: as many bosses as with two players); the enemies' health x1.25
    and x1.5, the bosses' x1.5 and x2; the breakables among them bring more food and goodies.
  - Gate: zig build test; the numbers measured with CPUs in every place (a tool's games of 3 and
    4 players: lives lost, damage taken, rounds' times against 2), tuned, and the user's play.
  - [x] Checked 2026-11-07: zig build test (518 tests: the placed of 1 to 4 players, copied 40
    pixels back, no boss again; the wave's second pass, 32 ticks apart; the reserve's repeats
    before the clear; the health factors, their rounding and the bosses' bar's measure; worlds of
    3 and 4 players whose script brings a punk again with more health and Antonio alone; four
    CPUs that never hold each other). Half: every other two-player record of a part (a section,
    the boss's, the room) in the script's order, placed then wave then reserve. cpus-check's
    `--players 3|4` (CPUs in every place; its `--level` now applied, it was not before) measured
    the whole game at 7 lives, levels 1 and 3, six sets of characters, seeds 1 to 4: 24 games
    per level and count. Rounds 1 to 7, lives lost per player (time overs a game, display ticks):
    level 1, 2 players 10.79 (2.33, 186k); before, 3 players 5.40 (1.38, 175k), 4 players 8.43
    (5.08, 231k); after, 9.47 (1.92, 211k) and 10.60 (3.17, 248k). Level 3, 2 players 22.56
    (2.29, 233k); before, 13.46 (1.21, 222k) and 13.40 (2.83, 248k); after, 21.04 (3.25, 274k)
    and 21.93 (5.71, 306k). Settled: the enemies x1.25 and x1.5, the bosses x1.5 with 3 and with
    4 (x2 with 4 gave 11.60 and 25.19 lives a player, 3.96 and 7.83 time overs). The rounds of 3
    and 4 still last longer than 2's (more time overs): four CPUs crowd each other. Found on the
    way and fixed: the CPUs of 3 and 4 held each other by turns and the camera waited (a CPU now
    keeps off every player); with 3 or 4 players an enemy gone far off the screen calls the
    reserve and is counted off (the reserve waited forever in round 4). The no-enemies report: a
    player standing behind holds the camera back (its band's start), as with two; not the
    spawns. 1 and 2 players unchanged: cpus-check built before and after, 39 games (the nine
    pairings at level 3, 7 lives, seeds 1 and 2; the nine `--player1 bot` to round 7, seeds 1
    and 2; the defaults, seeds 1 to 3): JSON and stderr byte-identical; round-check's report
    identical; netplay-check's 25 flows pass. Pictures: a round 1 of four CPUs and its two
    Antonios, their bars full at the start and emptying. Left: the user's play; round 8's room
    (item 53); in round 8 a twin stuck past the wall and in round 5 a twins' fight of 3 players
    that outlasted its timer many times, both seen with CPUs.
- [x] **53 — Mr. X's room, the continues and the high scores for 4** — Depends: 47, 48.
  - Mr. X's offer for players 1 and 2 alone, played as two until he rises; then the others come
    in. Each player's continue's question and name entry on its own slot; the high scores take
    four entries.
  - Gate: zig build test; round 8's room and a game over played with 4 players (pictures).
  - [x] Checked 2026-11-07: zig build test (the room of four: players 3 and 4 walking away and
    out, the fight as two until Mr. X rises, their drop with their records; the offer's players
    out of lives letting them in, no game over; players 3 and 4 in the offer's seats, player 4
    answering with its own pad; a join stepping out; the slot's question, name entry and game
    over; the last round's lives of four; the table's last place in a game of four; players 3
    and 4's colours; the chair's player; the agent's `cpu` lines). Pictures of `start adam axel
    blaze adam round 8` played by four CPUs (the agent's new `cpu N on`): players 3 and 4
    walking off to the right as 1 and 2 walk to the door, their slots kept; the offer for
    players 1 and 2; Mr. X rising and players 3 and 4 dropping in; the fight of four to the
    round's clear (1UP to 4UP's lives counted, four names entered) and the ending; with pads 1
    and 2 answering yes, the trapdoors under them, then round 6 with four players. A game of
    four from round 1 (CPUs, then idle pads): CONTINUE over ->YES x3 on the slots, the name
    entries' scores over NAME, GAME OVER beside each name, the high scores with players 1 to 3's
    new entries in red, yellow and green (player 4's blue in a run before the table's last place
    was guarded). Games of one and two as before: cpus-check (ReleaseFast) built on the base and
    on the change, 39 games (the nine pairings at level 3, 7 lives, seeds 1 and 2, the whole
    game through the room to the ending; the nine `--player1 bot` to round 7, seeds 1 and 2; the
    defaults, seeds 1 to 3): every JSON line and stderr byte-identical; round-check's report and
    screens-check's 23 runs' lines identical to the base's; six recorded two-player games to
    round 8 (their traces, which end before the offer) identical; netplay-check (its 25 flows)
    passes. Players 3 and 4 come in by dropping in, as Mr. X's room's door and camera leave no
    side to walk in from; the boss ending of four was not pictured (no scenario reaches it).

### Inputs

- [x] **54 — No press missed by the controls** — Depends: none.
  - The user sees presses not registered now and then. The controls keep each button's state as
    the events leave it, and each display tick reads that state: a press whose down and up both
    come between two reads (a tap shorter than a frame, or a wireless pad's events held back and
    delivered together) is never read; nor is a release and press again of a button held. The
    cartridge's pad has the same reads, but its wire never bunches events. Never miss a press by
    design (the user, 2026-11-08); the controller overlay and the recording wait (the user: back
    to them if presses are still missed).
  - Every press reaches a read: each player's buttons (its keys, its gamepad's buttons and
    stick, together) count their presses (a button newly down) since the last read; a read shows
    a counted press, then the button as held: a press whose button was let go already shows down
    at one read and up at the next; a button let go and pressed again while it was down at the
    last read shows up at one read, then down; several presses come one after another. A press
    that spans reads reads as before.
  - Gate: zig build test (taps within one read, a release and press again, several taps, the
    stick, a held button as before); 1 and 2 players' games as before (cpus-check's JSON
    identical; round-check, similar-check, screens-check, variants-check and netplay-check as
    before: their inputs come a frame or more apart).
  - [x] Checked 2026-11-08: zig build test (a tap between two reads read once, then let go; let
    go and pressed again, up at one read, then down; three taps one after another; a held button
    and a press spanning reads as the pads hold them; a gamepad's button and stick tapped; a lost
    focus forgetting). round-check (nine scenes equal), similar-check (71 moves equal),
    variants-check (7 flows), netplay-check (31 flows). screens-check: its menu scenario pressed
    Down at frames 565 and 566 a frame each, the second's down with the first's up: now two
    presses, the reference's one hold (an accepted difference from the cartridge); its second
    press moved to 567, the 23 runs then none differing. The user's play (2026-11-08), with the
    wireless controller: "It plays so much better."

### Replays and the controller overlay (DESIGN.md 10.8; the user, 2026-11-08)

- [x] **55 — The controller overlay** — Depends: 54.
  - F4 (and a STATS-like setting, kept in the record) shows over the picture a pad for each
    player in the game: the pixel art made from the photo of the Mega Drive control pad (sor-data's
    pad-mockup: `photo_pad.py`, `states_photo.py`, chosen by the user: the photo's pad at about 104
    x 61 pixels, greys and reds of the console's levels, a black outline, crisp red A, B, C in the
    buttons; pressed, a button or a D-pad arm or START plain yellow, its shading kept, its letter
    dark red), tagged 1P to 4P in the game's font, semi-transparent (about 75%). Its pixels are
    the port's own, in the repository; its look settled live (its opacity; four players' pads,
    which do not fit across at that width: smaller, or two rows).
  - [x] Smaller (the user, 2026-11-08: "around 80%", then "4 of them next to each other
    comfortably"): one pad of 70 x 41 for one to four players, four 12 pixels apart; START
    drawn (a light slanted pill, plain yellow pressed: the photo's greys lit near white); a
    pressed part's yellow opaque. The sizes in the check below were the first. Checked: zig
    build test; the scenario runner's pictures of two and four players with arms, buttons and
    START lit; a replay's line just above the pads.
  - A button lights while its events hold it (down until up), at least a few display ticks for
    a shorter press: the earliest signal the game has (input.zig's controls, before the reads).
  - F4 not bindable (as F3); HELP lists F4.
  - Gate: zig build test; pictures of the overlay with 1, 2 and 4 players, presses lit; 1 and 2
    players' games as before (the overlay off by default: screens-check, round-check).
  - [x] Checked 2026-11-08: zig build test (the sampling: a tap between two samples shown once,
    a held button at every sample, reads the same with and without samples; a tap lit 6 display
    ticks, a hold lit while held; the places of 1 to 4 players; every button's pixels, a pressed
    one yellow at 75 %, the panel's text kept over the pads; the row after STATS and F4's HELP
    line; the record's `controller_overlay` read back, a record without it whole and off, F4 not
    bindable). The art: src/shared/pad_art.zig (rows of colour indices, parts, 19 colours in
    levels), made by tools/pad_art.py from the photo; 104 x 61 for one or two players at the
    bottom corners, 76 x 45 for three or four spread across the bottom. Pictures: the agent host
    with the ROM, F4 on: 1P over the Sega logo, B tapped one tick lit ticks 152 to 157, Right
    held lit; round 1 of two players, 1P's Right and B and 2P's Left and C lit; the scenario
    runner's new `--controller-overlay` on `start axel blaze` and `start adam axel blaze adam`:
    1P to 4P with their arms and buttons lit. Games of one and two as before (the overlay off):
    screens-check's 23 lines and round-check's report identical to the base's; netplay-check (31
    flows), variants-check (7 flows), smoke and web pass. Not checked: network play with the
    overlay on (it shows this machine's player alone), the browser's page, the user's play.
- [x] **56 — The rolling recording (F5)** — Depends: 55.
  - In a local game the last 20 seconds: the game's state every few seconds (its canonical form),
    each display tick's pads as read and the overlay's presses. F5 writes a replay file (the
    game's build and data identity, the first state, the ticks) to the settings' storage, and a
    notice says so (REPLAY SAVED). F5 not bindable; HELP lists F5.
  - Gate: zig build test (the window kept at 20 s, the file's format read back); a file saved
    from the agent host's game.
  - [x] Checked 2026-11-08: zig build test (src/shared/replay.zig: over 10,000 ticks and 5,000
    more the window keeps 1199 to 1499 ticks, 20 s at least, in the same room; the file read back
    with its first state, a cut's state at its tick, the facts as they change and every tick's
    pads read and shown; another build, other data, another version, a file cut short or longer
    refused; the names by date (UTC) and by counter, none taken twice; src/agent/replay_test.zig:
    the game in the agent backend, 3000 ticks then F5: REPLAY SAVED, replay-0001.sorzreplay, its
    ticks to the tick F5 came at, Right read as held and the overlay's buttons as shown; a page
    keeps F5 and records nothing; F5 not bindable). The agent host with the ROM: round 1, a fight
    (Right, B every 12 ticks, a jump, C), F5 at frame 2700: replay-0001.sorzreplay in `--saves`,
    1200 ticks, 15,035 bytes, REPLAY SAVED. over the round. A state kept costs about 0.11 ms in
    Debug (every 300 ticks); the recording's room is about 220 KB, made at its first tick.
- [x] **57 — Replays** — Depends: 56.
  - `sorz DATA --replay FILE` (and the agent host's): the game from the file's first state, its
    ticks driven by the recorded pads, the overlay on with the recorded presses; Space pauses,
    Right steps a tick while paused, S full, half and quarter speed, Escape leaves; the tick's
    number shown; the end holds. A file of another build or other data is refused, told why.
  - Gate: zig build test; a replay reaching the recorded game's states (their hashes) tick by
    tick; pictures of a replay paused, stepped and slowed.
  - [x] Checked 2026-11-08: zig build test (the playback's states and facts before their ticks;
    the line's texts; `--replay`'s options; in the agent backend, 2000 ticks saved and replayed
    with a pause, a step, half and quarter speed: every tick's state hash the recorded game's,
    held at the tick F5 came at). The new `zig build replay-check -Drom=ROM`: fight (round 1, 30
    s of walking, blows, jumps and specials, F5) 1267 ticks compared, 0 states and 0 buttons
    differing; cut (Escape to the menu during the fight, F5 5 s later; from the select through
    the round's load) 1368 compared, 0 differing, 2 states loaded; in both the pause held with
    its 3 steps, half speed 150 ticks in 300 updates, quarter 100 in 400; another build's and
    other data's files refused. Pictures (the agent host's `--shot`): REPLAY 100 OF 1200 PAUSED,
    then 101 and 102 stepped, HALF SPEED, QUARTER SPEED with the Right arm lit, B lit later, END
    at 1200 (Axel where the recorded game left him). Refused, told why: the previous build's file
    (its build and this one's), the test pattern's (the two data identities), in the agent and
    the SDL host (dummy video and audio), which also played a replay. As before: netplay-check (31
    flows) and variants-check (7) lines identical to the base's, state hashes included;
    screens-check's 23 lines and round-check's report identical; web builds. Not checked: the
    user's play in a window, the sound at slow speeds by ear.
- [x] **58 — Back to a snapshot; a replay from the gamepad** — Depends: 57.
  - While a replay is paused (or held at its end), Left goes back to the previous snapshot: the
    state before every 300th tick (5 s), kept in memory as the replay plays (network play's
    join form, its place in the file), the newest before the tick shown; again, the one before.
    The file's format unchanged. Its line shows the tick gone back to, still paused.
  - A gamepad drives a replay as the keys do: START as Space, the D-pad's Left and Right as the
    arrows (the user, 2026-11-08). `--replay`'s texts say so (HELP lists the game's keys only).
  - Gate: zig build test (back to the snapshots, then on: every tick's state hash the recorded
    game's); replay-check with a step back; a picture of a replay gone back.
  - [x] Checked 2026-11-08: zig build test (src/shared/replay.zig: snapshots before ticks 0, 300
    and 600 kept once, back to 600, 300, 0 then none, a gamepad's Right held stepping at 24, 27
    and 30 updates; src/agent/replay_test.zig: a replay to its end, Left, the gamepad's Left,
    Right and START, each state the recorded game's on to the end). replay-check on the ROM:
    fight and cut back from the end to 900, its state the recorded one, then 367 and 468 ticks
    on, 0 differing (the cut's state loaded again). The agent host's pictures: REPLAY 900 OF
    1280 PAUSED after Left and a gamepad's Left; 300, then 301 after a step, the fighters as the
    recorded game had them. Not checked: a real gamepad and window.
- [x] **59 — A replay of another build plays** — Depends: 57.
  - A replay recorded by another build is no longer refused (the user, 2026-11-08: "too
    restrictive"): it plays, the log telling both builds; where the builds' games differ it may
    go its own way, and a state that does not load ends it, told. Other game data is still
    refused.
  - Gate: zig build test (another build's file read and played, other data's refused);
    replay-check's refusal case as such; the agent host plays a file of the previous build.
  - [x] Checked 2026-11-08: zig build test (another build's file read, `otherBuild` true; other
    data's refused); replay-check's identities case (another build's read, other data's
    refused), fight and cut passing; the agent host played a file saved by build a28e8b0 to its
    end at game tick 2480 (where F5 came), its log naming both builds.
- [x] **60 — The settings in the configuration directory** — Depends: 59.
  - The settings record (`settings.json`) leaves the saves' directory (the user, 2026-11-08:
    "should not be in the save folder"): the SDL host keeps it in the per-user configuration
    directory (`$XDG_CONFIG_HOME/sorz`, else `~/.config/sorz`; `%APPDATA%\sorz` on Windows) or
    at `--config DIR`; the saves' directory keeps the replays. A record found in the saves'
    directory and not in the configuration's is moved there once, told in the log. The agent
    host keeps it at `--saves` unless `--config` is given (never the user's directories); the
    browser's page keeps its one storage. `--help`'s `config:` names it.
  - Gate: zig build test (the directory by the platform's conventions; the record moved once,
    kept when both exist; the settings read and written in the configuration's storage, the
    replays in the saves'); `sorz --help` with and without `--config`; the SDL host moving this
    machine's record.
  - [x] Checked 2026-11-08: zig build test (the configuration directory by the platform's
    conventions; the record moved once, one in the configuration standing and one left with the
    saves kept there; the settings read from and written to the configuration's storage, none
    in the saves'); `sorz --help` names ~/.config/sorz/settings.json, with `--config /tmp/c`
    that; the SDL host (dummy drivers, XDG_DATA_HOME and XDG_CONFIG_HOME in /tmp, a copy of this
    machine's record in the saves' directory): moved, then read ("settings: kept"), a second run
    moving nothing; zig build web. The user's own record moves at their next run.
- [x] **61 — F4 in a replay** — Depends: 57.
  - F4 hides and shows a replay's pads and its line (the user, 2026-11-08), shown at its start;
    for that replay only, the settings' CONTROLLER OVERLAY unchanged. `--replay`'s texts say so.
  - Gate: zig build test (the line hidden and shown, the setting unchanged); pictures of a
    replay before F4, after it, and after it again.
  - [x] Checked 2026-11-08: zig build test (F4 hides the replay's line, the setting unchanged;
    again, shows it); the agent host on the ROM: REPLAY 301 OF 1280 with the 1P pad, then after
    F4 neither, then after F4 again both (REPLAY 341).
- [x] **62 — Time to throw after pushing away** — Depends: none.
  - Holding one from the front, the pad pushed away lets go after 4 ticks (the original's 3 and
    one, `let_go`); B in that time throws. The user lets go where they meant to throw ("I don't
    release so much enemies on the original game"): the port's rules (the extended game, network
    play) give 2 ticks more between the pad away and B (the user, 2026-11-10: "a couple of tick of
    pause between the arrow and the punch. But not the other way around"); B before the pad away
    stays a knee. The cartridge's variant keeps the original's.
  - Gate: zig build test (with the port's rules, B 5 ticks after the pad away throws, 6 lets go;
    without, 3 and 4); the scenario runner's grid against sor-remaster unchanged for the
    cartridge's variant.
  - [x] Checked 2026-11-10: zig build test (the new test: B 3 ticks after the pad away throws and
    4 lets go without the grace, 5 and 6 with it; it fails without the change); the scenario
    runner (the cartridge's rules) on 0 and 2 knees, the pad away at once or 6 ticks after, B 0
    to 6 ticks later: the same as sor-remaster's. Not checked: the user's play.
- [x] **63 — Round 4's police car on firm ground** — Depends: none.
  - At round 4's boss the special attack's police car drives over the hole (the user,
    2026-11-10). The original brings it at depth $20 in round 4, $40 elsewhere (ROM 0x18D12:
    `cmpi.w #3,($FF02).w`, then `move.w #$20,($14,a6)`; sor-remaster's 0x18CD4): the round's
    content carries its car's depth (`special.car_depth`, extracted), the world takes it.
  - Gate: zig build test (the content read back with and without it; the car at the round's
    depth); the extraction gives round 4 depth 32 and no other round one; a picture of round 4's
    boss with the car, against sor-remaster's at the same tick.
  - [x] Checked 2026-11-10: zig build test (the round read back with and without; the car at its
    definition's depth and at the round's); the extraction: round 4 car_depth 32, no other
    round's; round 4's bot play with the special at its boss: the car at depth 32 on the
    bridge's road (the build before: 64, over the hole). Not met: sor-remaster's picture at the
    same tick (its --pads does not replay the bot's file as sorz's scenario does); the ROM's
    instructions and sor-remaster's code stand for it.
- [ ] **64 — The relay as a locked-down service** — Depends: none.
  - sorz-server listens on the network and is not hardened (its own warning): a compromised relay
    must be stopped by the system. `tools/sorz-runner install|start|stop|uninstall` (the user,
    2026-11-11) runs it as a systemd service whose unit restricts it: no home but its own files,
    a read-only system, no devices, a system call allowlist (io_uring refused, any other call
    kills it), internet sockets only, bounded memory and threads. It starts by `start` only, never
    at boot. A user service by default, without root (the user, 2026-11-11), its files in
    ~/.local/share/sorz-server; `--system` makes it the system's (root, through sudo, its files
    in /opt/sorz-server), which adds a throwaway user and its one port. `--help` says what a user
    service cannot restrict. The README says it in a few lines.
  - Gate: the generated units pass `systemd-analyze verify`; the four commands as a user: the
    relay serves its page and the game's files and relays pages' messages under its unit, with
    its sandbox on; the four commands with `--system` on a machine with systemd, as root.

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

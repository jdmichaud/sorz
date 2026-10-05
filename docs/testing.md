# Testing

What is tested, how, and what the tests may read. The skeleton has unit tests, the provider
contract cases (`src/native/contract.zig`) and a headless smoke run; the harness beyond them
depends on the game, and the port builds it as its checks need (below).

## Before every commit

- `zig build test`: the unit tests of every module, and the engine's rule against the console's
  terms (tools/engine_terms.zig). **No test is skipped**: the summary says "N pass (N total)".
- The port's own suites, once it has them.
- `zig build smoke` (the agent host for a few frames, and the settings record across starts) and
  `zig build verify` (the agent and server binaries link no SDL, and each executable alone serves
  its page).
- `zig build web`: the browser build, with the check of its module's imports. When the page or
  network play changes, `zig build web-check` (it needs Node.js) and `zig build browser-check
  -Doptimize=ReleaseFast` (Node.js and a Chromium; its real-time parts are sensitive to the
  machine's load, which its report gives).
- `zig fmt --check src tools build.zig`.

The steps are listed at the top of `build.zig`; agents build into a prefix and a cache under
`/tmp/<project>`, never into `zig-out`.

## Unit tests

- **Next to the code**, as `test` blocks in the file they test. A module's root refers to its
  files so that `zig build test` finds every test.
- **Synthetic inputs.** A test builds the data it needs. A test of code that reads the original's
  tables builds a synthetic image with the same layout (the table at its address, filled by the
  test), never a copy of the game's bytes.
- **A missing file fails.** A test that reads committed data fails when the file is missing. A
  test that skips on a missing file hides a lost fixture, and a run full of skips cannot tell a
  pass from nothing.
- **Degenerate inputs lie.** A test of random draws seeds the generator with a realistic seed (the
  original's own initial seed); a small seed such as 1 or 7 gives degenerate first draws in a
  multiplicative generator (`docs/lessons.md`).

## The harness a port builds

What to compare depends on the game, so the skeleton has no test runner. Build one when the first
reference data arrives, and keep what previous ports found necessary:

- **Two suites.** One of synthetic and redistributable fixtures, one whose expectations are
  recordings of the original's behaviour, committed as observation files with their provenance.
- **Exact, ordered comparison** that names the **first difference**: the step, the object, the
  field.
- **Bounded runs.** Each case runs under a wall-clock bound, in its own process when a driver can
  hang or crash, so a stall is a `timeout` and a death a `crash`, not a hung suite.
- **Inputs checked by digest** before and after, so a case cannot pass on edited data.
- **Negative controls**: cases that expect a wrong value, a missing observation, an extra one, a
  stall, a crash. They prove the harness catches each.
- **A status per case**: `verified` blocks a change; `provisional` and `disputed` are reported
  and never fail a run.
- **Drivers per subsystem**, such as the two that carried a previous port: **routine vectors** (a
  function of the port against the recorded inputs and outputs of the original's routine) and
  **trace replays** (the port's simulation stepped against a recorded trace of the original).

## The agent host in tests

The agent host runs the whole game without a window, with a virtual clock and injected input. The
skeleton's `smoke` step runs it for a few frames; a port grows it into the driver of scripted
end-to-end checks: a fixed script and its expected state and frame digests, long games, save and
load cycles, statistics ("Comparing behaviours with statistics", below).

It is not the game the user runs ("Gate the join", below).

## Reference data: what may be committed

**May be committed**: measurements of the original's behaviour. The inputs and outputs of its
routines, traces of its simulation, its decisions, counts, digests. Each file says where it comes
from: the tool and its revision, the digest of the executable, the capture profile.

**May not be committed**: the game's files or any part of them (code, tables copied as data,
pictures, sounds, text, films), screenshots and memory dumps of the running original, and the
tools that run it.

**Synthetic data instead**: a test that needs data in the original's format builds it.

## Oracles

The measurements come from oracles that live outside the repository
(`docs/reverse-engineering.md`):

- **Routine vectors.** An interpreter or emulator runs one of the original's routines, with its
  callees, on chosen inputs, and records the outputs.
- **Captures.** The original runs under an emulator, driven by scripted input, and its memory is
  read at checkpoints.
- **Traces.** A whole flow recorded from the original: the state before, the events, the state
  after. The port replays the flow and compares each step.

Only their outputs enter the repository, as reference data.

## Gate the join

A green suite is not the game working. Suites hold stills and injected events; the user runs the
SDL build with a mouse, in their own video mode. In a previous port, a placeholder renderer, a
dozen dead menu rows, an unplayable play screen and a video mode nobody had looked at all passed
green suites. So, before an item is done:

- **Run the build the user runs**, in the mode they play (their configuration decides it), under
  a real or virtual display, with real input (X events through XTEST, not injected events), and
  **look at screenshots of the presented window**.
- **Gate the moving picture**, not a still: during a move, assert what moves and what must not
  (a camera that chases, an object left behind). A still cannot see motion.
- **Ask what reaches the code**: a feature gated in a test but unreachable from the menus is not
  done.

## Verify before claiming, measure before fixing

- Reproduce a report in the real build before changing code, and verify the fix the same way.
- Never re-record a baseline to bless your own change. Without independent evidence, mark the case
  `disputed`.
- An anomaly in your own measurement is the lead, not noise.
- Do not tune the gate instead of the game: a harness knob can move a number without changing the
  behaviour.
- A report can be the reverse of the truth. In a previous port, "the computer plays too well"
  measured as "it pots less than the original"; later, measured properly, the two were equal.

## Scenarios and the similar-check

The mechanics are compared with sor-remaster's (DESIGN.md V3, D14) through scenarios, in
sor-remaster's format: a start (`start axel`, or `start axel blaze` for two players), then pad
events and conditions by logic tick. The catalogue's scenarios of each character are copied in
`tests/scenarios/axel`, `adam` and `blaze`, the two players' in `tests/scenarios/two`; a family
(its header says "{N} takes the values A to B") is a run per value.

- `sorz-agent DIR|ROM --scenario FILE [--trace-events OUT [--probe OUT]]` runs one in sorz from
  power-on, the whole game as the hosts run it (src/agent/game_run.zig): the start passes the
  screens as sor-remaster's runner does (START tapped, the menu's arrow, the select's cursor), or
  replays a recorded play's pads (`start pads FILE VBLANKS`); the script's tick 0 is play's first
  logic tick. The trace has the scenes, play's phases, the round's world at its ticks and the
  scenes' sounds; the probe, the fighters' frames, boxes and power as the trace sees the round.
- With `--situation TRACE [--game-tick N] [--probe OUT]`, the run takes up its start from
  sor-remaster's trace of the same scenario: the round scene's first `phase play`, its entities
  with their ids, states, places and health, the camera, the players' lives; it runs the round's
  world alone and writes the probe (each fighter's frame, boxes and power per tick) too, in
  sor-remaster's formats. A scenario that starts from a recorded play (`start pads FILE V`) is
  taken up mid-round, at the end of the logic tick that holds display tick V: every entity in its
  state, each enemy with the record the round's script placed it by (`rounds/round1.json`,
  matched by where it appeared), the random generator as the trace's draws left it, the
  round's clock as sor-remaster counts it (`--game-tick`, its `script_game_tick`), and the
  round's script where it was: replayed from the round's start over the trace's script
  entities, camera and phases (a stand-in brings what the trace brought should they part).
- With `--reload`, a run from power-on reads the game's state back from its canonical form
  (canonical.zig) at every display tick and goes on from the state read: the state read must be
  the one written, and the run's trace and sound must equal those of the run without it (a game
  loaded from its form goes on as the one it was taken from, DESIGN.md 6). `--form-sizes OUT`
  writes the form's size at each tick (with a situation: the round's world's, at each logic tick).
- `sorz-agent trace-compare FIRST SECOND` compares two traces (the first difference, the counts
  per kind of event), from a scene on (`--scene round --after TICK`), with kinds of entity,
  events and fields left out and sor-remaster's sound names translated (`--sounds`); with
  `--renumber`, the entities numbered by their order of appearance (two runs from power-on whose
  front ends make other objects).
- `zig build similar-check -Drom=ROM -Dremaster=DIR|AGENT` (src/tools/similar_check.zig), the
  gate of PLAN items 05, 11 and 14: each scenario runs in sor-remaster (its checkout, whose agent
  the build builds, or that agent) and in sorz; then the traces, the probes and the catalogue's
  measurements of each move (frame data, states and their ticks, damage, pushes, arcs, speeds,
  boxes, power, the special attack's times; with two players, their blows on each other, the
  enemies' choice between them, each one's special attack) are compared, all equal. It prints a
  verdict per move, equal, within tolerance or different, with the numbers, writes it with the
  runs into `<prefix>/similar` (`-Dsimilar-out=DIR`), and fails when a move differs.
  `-Dsimilar-only=NAME,...` runs some scenarios (or families, below).
- With `-Dpads=FILE`, round 1's recorded play (the catalogue's game.pads, which the repository
  does not hold), similar-check compares the enemies and the items too (PLAN item 12,
  src/tools/similar_enemies.zig): the catalogue's ai-* and item-* families (`tests/scenarios/
  enemies`: the recorded play to a wave, then the player stands, presses B every other tick, or
  goes for an item; with sorz's item-knife: the knife picked up, stabbed and thrown), sorz taken
  up from sor-remaster's situation. Run by run, the traces are
  compared (the first difference and the kind of entity it is about); per enemy and thing
  thrown, the catalogue's measures over every run (its m_ai: each state's ticks and the states
  that follow it, an attack's place from the player at its start, its blows' tick, damage and
  reaction, the health coming out of hiding, a thrown thing's flights and hits): equal, within
  tolerance (as many, a tenth at least one, medians and means within a tenth, shares within 0.1,
  the same values seen) or different. An item's family is equal when all its runs are the same.
  `-Dsimilar-every=N` runs every N-th run of each family; sor-remaster's runs go
  `-Dsimilar-jobs=N` at once and are kept in `<prefix>/similar/enemies` while its agent and the
  scenario stay the same.
- `zig build round-check -Drom=ROM -Dremaster=DIR|AGENT` (src/tools/round_check.zig), the gate of
  PLAN item 13: round 1's scenarios (`tests/scenarios/round1`: a walk to the first wall, standing
  through three time overs, the continue's YES and NO, two pauses, player 2's PRESS 2UP START
  mid-round as Adam, alone and with the first Galsias on the screen, Blaze chosen at the select,
  two players) run from power-on in both
  programs, and their round scenes' traces are compared event by event (the camera and its stops,
  the timer, play's phases, the players' places, states, health, lives and deaths, the continue,
  the game over, the placed enemies coming out, the sounds asked for), the hit sparks left out;
  all equal; the fighters' frames (the probes, agent/probe_compare.zig: each frame's start and
  index, entity by entity) equal; the game's clock as each script begins is the same; and the
  sound of the whole run, from power-on, sample by sample (both programs' 48 kHz output,
  `--wav`): equal at every display tick. It writes the runs and the report into `<prefix>/round`
  (`-Dround-out=DIR`); `-Dround-only=NAME,...`. `-Dround-reach=FILE,...` also runs scenario
  files kept outside the repository (a recorded play's, `start pads`), not as a gate: their
  lines say where the trace, the frames and the sound first differ.

## The variants

The game is played in three variants (DESIGN.md 10.7, src/shared/variant.zig): the original
(`--original`, the cartridge exactly), the extended game (the default) and the network variant
(network play and the browser). The checks against sor-remaster compare the original: its
scenarios (`--scenario`, game_run.zig) and `screens-check` run it, and sor-remaster's agent runs its
own default, which is the cartridge's too.

- `zig build variants-check -Drom=ROM` (src/tools/variants_check.zig), the gate of PLAN item 19:
  each variant's flow played from power-on on the ROM's content, as the hosts run it, its steps
  checked on the game's state and its overlays: the original's menu and options (no ADVANCED
  SETTINGS), the settings key, the round's pause on START; the extended game's ADVANCED SETTINGS
  right before EXIT (the settings held over OPTIONS, both players', no settings key; EXIT WITHOUT
  SAVING), and START in the round opening the settings in place of the pause; the network variant
  as a browser's page plays it alone (2 PLAYERS and OPTIONS, one player's settings, the select
  with this machine's player, the round's START); a network guest's OPTIONS (SOUND TEST,
  ADVANCED SETTINGS, EXIT).
- `browser-check` with `-Drom=ROM` adds the part `flow`: on a relay serving the whole content
  tree, the page's game runs its own front end (the page has no menu of its own): the network
  variant's game menu, 2 PLAYERS and OPTIONS; OPTIONS' ADVANCED SETTINGS opens one player's
  settings, the game held; Escape saves and leaves.
- `sorz-agent --page` runs the game as a browser's page does alone (the network variant, one
  player, the page's own volume), `--original` the original.

## Network play

Each machine runs its own front end; the players meet in one game, which the host's canonical
form carries to the guest (DESIGN.md 9, src/shared/network_play.zig). The session's protocol and
its lockstep have their unit tests (src/shared/net, the agent's netplay_test.zig, a stand-in state
that the guest joins); on the real game, from the user's ROM:

- `zig build netplay-check -Drom=ROM`, the gate of PLAN item 18:
  - src/tools/netplay_check.zig, several games in one process over the in-memory network, each with
    its own clock and keys: `own_menus` (a move of the host's arrow leaves the guest's; the guest's
    OPTIONS its own lines alone, its ADVANCED SETTINGS its own settings), `select` (the guest's 2
    PLAYERS joins the host's select: each player's cursor its own; round 1 with two players; the
    two games' states and pictures the same at the same ticks, their sound the same frame by frame
    since the join, the session's checks without a difference; player 1's START opening its
    settings, both games held, the guest told), `round` (the host plays alone; the guest chooses on
    its own select, the host's character taken, and drops in mid-round; the same games, and the
    same sound since the join: the round's music going on from the host's place, not again from its
    start; a third game turned away plays alone;
    the guest quits, player 2 out of the game, the host plays on; a new guest joins later; the
    host quits, player 1 out of the game, the guest plays on alone as player 2), `away`
    (a dropped connection: both hold and say so; back in time, the same session; not back in time,
    the host plays on without player 2 and the guest goes back to its own menu), `difference` (a
    bit of the guest's state flipped: both stop at the next check and name the field). With
    `-Dnetplay-only=FLOW,...` some flows alone; the tool's `--pictures DIR` writes two pictures that
    differ.
  - tools/check_netplay.sh: two agent hosts, two processes over WebSockets (`--netplay`, `--join`):
    the host plays round 1 alone, the guest's player chooses 2 PLAYERS and a character, and joins
    mid-round; at the session's tick 600 both are in the round with two players, in the same
    state, and both played the same sound since the join (the hash of its frames, their number).
- `browser-check` with `-Drom=ROM` adds the parts `netplay` (a Chromium page, the guest of the
  agent host on the whole content tree, joins its round mid-way; the same state at the session's
  tick 600), `relay` (two pages through the relay: the first plays round 1 alone, the second joins
  it mid-round; the same state) and `relay_rules` (a third page turned away plays alone, told why;
  the guest leaves and the host plays on without player 2, told so).
- Not checked here: two machines with `netem`'s latency and loss, and the user's play (PLAN A1).

## Comparing behaviours with statistics

When the outcome is random (a computer player, a shuffled deck, a random start), compare rates,
never single runs:

- **The same protocol on both sides**: the same mode, the same pairing, the same cut (for example,
  leaving out the same kind of opening move).
- **Read the original at the right moment.** A global can be published after the event it
  describes; read it when the original's own code has written it (`docs/lessons.md`).
- **Sample sizes and intervals.** Give each rate with its count and its 95% interval; compare
  with a two-proportion test per group and a chi-square over the groups.
- **Say what the test rules out.** Fifty samples rule out only large differences.

A previous port compared its computer players with the original's this way: about 500 shots of
the original's own demo under an emulator against 2,000 of the port's, over nine skill levels; no
level differed and the rates agreed as a whole (chi-square p = 0.93).

## Other targets

- **Windows under Wine.** `zig build test -Dtarget=x86_64-windows-gnu -fwine` runs most unit tests.
  Wine has known limits (`docs/lessons.md`); the Windows gate needs Windows itself.
- **Browsers.** Chromium and Firefox, headless for scripted checks, and with a real display for
  input and audio.

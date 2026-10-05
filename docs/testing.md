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
sor-remaster's format: a start (`start axel`), then pad events and conditions by logic tick. The
catalogue's scenarios of Axel are copied in `tests/scenarios/axel`; a family (its header says
"{N} takes the values A to B") is a run per value.

- `sorz-agent DIR|ROM --scenario FILE [--trace-events OUT]` runs one in sorz from power-on, the
  whole game as the hosts run it (src/agent/game_run.zig): the start passes the screens as
  sor-remaster's runner does (START tapped, the menu's arrow, the select's cursor), or replays a
  recorded play's pads (`start pads FILE VBLANKS`); the script's tick 0 is play's first logic
  tick. The trace has the scenes, play's phases, the round's world at its ticks and the scenes'
  sounds.
- With `--situation TRACE [--game-tick N] [--probe OUT]`, the run takes up its start from
  sor-remaster's trace of the same scenario: the round scene's first `phase play`, its entities
  with their ids, states, places and health, the camera, the players' lives; it runs the round's
  world alone and writes the probe (each fighter's frame, boxes and power per tick) too, in
  sor-remaster's formats. A scenario that starts from a recorded play (`start pads FILE V`) is
  taken up mid-round, at the end of the logic tick that holds display tick V: every entity in its
  state, each enemy with the record the round's script placed it by (`rounds/round1.json`,
  matched by where it appeared), the random generator as the trace's draws left it, and the
  round's clock as sor-remaster counts it (`--game-tick`, its `script_game_tick`).
- `sorz-agent trace-compare FIRST SECOND` compares two traces (the first difference, the counts
  per kind of event), from a scene on (`--scene round --after TICK`), with kinds of entity,
  events and fields left out and sor-remaster's sound names translated (`--sounds`); with
  `--renumber`, the entities numbered by their order of appearance (two runs from power-on whose
  front ends make other objects).
- `zig build similar-check -Drom=ROM -Dremaster=DIR|AGENT` (src/tools/similar_check.zig), the
  gate of PLAN items 05 and 11: each scenario runs in sor-remaster (its checkout, whose agent the
  build builds, or that agent) and in sorz; then the traces, the probes and the catalogue's
  measurements of each move (frame data, states and their ticks, damage, pushes, arcs, speeds,
  boxes, power) are compared, all equal but the special attack's times (its car a stand-in: 1
  tick). It prints a verdict per move, equal, within tolerance or different, with the numbers,
  writes it with the runs into `<prefix>/similar` (`-Dsimilar-out=DIR`), and fails when a move
  differs. `-Dsimilar-only=NAME,...` runs some scenarios.
- `zig build round-check -Drom=ROM -Dremaster=DIR|AGENT` (src/tools/round_check.zig), the gate of
  PLAN item 13: round 1's scenarios (`tests/scenarios/round1`: a walk to the first wall, standing
  through three time overs, the continue's YES and NO, two pauses) run from power-on in both
  programs, and their round scenes' traces are compared event by event (the camera and its stops,
  the timer, play's phases, the players' places, states, health, lives and deaths, the continue,
  the game over, the placed enemies coming out, the sounds asked for), the hit sparks left out;
  all equal; and the game's clock as each script begins is the same. Play's sound itself (its
  samples) is not compared yet: play's frames' transfers, which hold the sound's processor, are
  not modelled, and its drums' samples differ from sor-remaster's. It writes
  the runs and the report into `<prefix>/round` (`-Dround-out=DIR`); `-Dround-only=NAME,...`.

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

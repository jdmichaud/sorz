# sorz — design

Approved 2026-10-02 (the user: "Implement the proposal", sor-re/docs/sorz-design.md). This
document defines the architecture and its contracts. It changes only with the user's approval
(`AGENTS.md`).

sorz is a clean re-implementation of Streets of Rage (Sega Mega Drive, 1991). A first port, now
**sor-remaster**, translated the cartridge's program routine by routine and is verified against the
original field by field, write by write and pixel by pixel; it is sorz's **reference**. sorz is
written in the game's terms, with its own structure, and is checked against sor-remaster at the
level of meaning (section 12).

The game owns the rules, the simulation, the input interpretation, the drawing and the sound
generation. The platform supplies devices, storage, time and transport. The interfaces make
errors, memory ownership, asynchronous operations and the frame format explicit.

## 1. Goals and principles

- **G1 Plays as the original**, in two steps:
  - **similar** first: the mechanics measured equal (section 11);
  - then **exact** if similar is not good enough: the same pictures and the same events tick by
    tick.
  - **Sound is exact from the start.**
- **G2 A modern, readable program.** Code in the game's terms (a punch, a grab, a wave of
  enemies), not the console's (a RAM offset, a VDP command).
- **G3 Extensible.** New rules, moves, characters, rounds and screens are additions to data and to
  small systems, not forks of code (section 10.7).
- **G4 Efficient.** A few percent of a core, in a debug build too.
- **G5 The same platforms and features**:
  - Linux, Windows and the browser;
  - network play, with the native host, the native guest and the relay;
  - the settings.

- **P1 The game's terms, not the console's.** No ROM address, RAM offset, register name or VDP
  command in the engine's code. The original's knowledge lives in three places:
  - the **content** (data with names, made by the extractor);
  - the **extractor** (the one place that reads the ROM, by address, as a parser);
  - the **port maps** in sor-re.

  A check in the build fails on hexadecimal addresses in the engine's sources.
- **P2 Data-driven content.** Characters, moves, enemies, items, rounds, screens, music and sound
  effects are data in the asset tree: human-readable, named, validated when loaded. Code
  implements systems and behaviours, parametrised by data.
- **P3 Deterministic, exact-capable.** Determinism is what keeps the step to exact free of a
  redesign:
  - integer fixed-point at the original's precisions, never floating point, in the simulation;
  - a fixed tick, and a defined order of the systems within it;
  - one random generator with the original's algorithm, whose draws are explicit and named.

  The same properties make network play and replays work.
- **P4 Quirks are named behaviour.** Where exact needs one of the original's oddities (a sprite
  list that drops pieces, a sound held back while a sample plays), it becomes a named, documented
  rule in one place, never an accident of structure.
- **P5 Verified against sor-remaster, at the level of meaning** (section 11).
- **P6 One way to do a thing.** No parallel paths for "original" and "extended" spread through
  the code: variants are configurations of the same systems (section 10.7).
- **The repository stands alone.** No file of the original enters the repository, and no build or
  test needs one; a build that embeds the game's files takes a copy the user supplies.
- **Each executable is self-contained.** At run time it reads only the user's copy of the game's
  files, its settings and its saves. Nothing it needs is installed beside it, and no option points
  it at such files.
- **Few dependencies.** Zig and SDL2 for the native game; nothing beyond the browser for the
  browser build. **Static linking where practical** (section 8).
- **Linux/SDL first, the agent host alongside.** The headless agent host drives the same game
  without a window. Windows and the browser follow on the same shared code.

## 2. The platform boundary

The application composes three interfaces:

- `Platform`: the lifecycle, events, time, presentation, PCM output and mouse capture.
  Implemented by the SDL backend, the browser backend and the agent backend. A port adds the
  calls its game needs to all three: a transport for network play (section 9), I/O jobs that run
  beside the frame (section 4).
- `AssetSource`: named, read-only game files, listed and read. Implemented over a directory and
  memory; a port adds the sources its game needs (a CD image, files embedded in the executable,
  an overlay of mod files over the original's).
- `Storage`: persistent named byte records and their listing. Implemented over a directory, the
  browser's storage, and memory.

Each interface is a context pointer and a table of functions (`src/shared/platform.zig`), so
several backends and several games can exist in one process: the computer player's trials, the
agent host's resets and the network tests all need more than one game at a time.

**The simulation depends on none of these interfaces.** It receives explicit state and commands,
and produces state changes and events. The application coordinates I/O and presentation around
it. There are no globals: a game is a value.

The host implementation is chosen at build time and passed as explicit instances. The asset
source is chosen at run time (a game directory on the command line in the skeleton).

## 3. Platform contracts

### 3.1 The game and its host

```zig
const UpdateResult = enum { running, finished };

// Game operations:
fn init(allocator: std.mem.Allocator, assets: AssetSource, storage: Storage) !Game;
fn update(self: *Game, platform: *Platform) !UpdateResult;
fn deinit(self: *Game) void;
```

The host creates the allocator, the backend, the providers and the game, and owns the outer loop.
The game's first update calls `platform.start()`, which activates the services and returns the
backend's capabilities. Each later update processes events and completed I/O results, advances
bounded work and does the rendering and audio that are due. `finished` means the game has done
its orderly shutdown (required saves included); the host then releases the game, the providers
and the backend, in that order, and the allocator last. An error returns control to the host for
reporting and cleanup.

The native host calls `update` in a loop and paces it outside the game. The browser calls one
update per `requestAnimationFrame` callback. The agent host calls updates on command, with a
virtual clock.

### 3.2 Presentation

The renderer produces a finished RGBA8 frame; indexed pixels and palettes stay inside the
renderer, where they express the original's drawing and its palette effects.

```zig
const RgbaFrame = struct {
    width: u32,
    height: u32,
    stride: usize, // bytes between row starts, at least width * 4
    pixels: []const u8, // R, G, B, A bytes per pixel; A is 255
};
fn setResolution(width: u32, height: u32) !void;
fn present(frame: RgbaFrame) !void;
```

`present` borrows the frame for the duration of the call only. The render resolution, the window
size, the fullscreen state and the pixel aspect are separate: resizing a window keeps the game's
resolution, and a failed mode change keeps the previous mode usable.

### 3.3 Input

The platform delivers ordered, timestamped events in project-owned types, never SDL or DOS scan
codes: key down and up, text input, relative mouse motion and the pointer position, buttons,
wheel, controllers, focus, quit, and drawable-size changes. The game maps them to actions, with
the original's filters, sensitivities and key tables in shared code. Relative mouse capture is a
request, and an event reports whether it was granted; losing focus or capture releases held
controls without producing an action.

The platform names each controller it reports, for the game to know it again (the user,
2026-10-08): a key of its model, the same for every controller of that model on that platform
(SDL's GUID; the browser's gamepad id), and a name to show (`controllerInfo`, while it is
connected). The game keeps its players' gamepads by those alone; no library's identifiers or types
cross the boundary.

```zig
const ControllerInfo = struct { model: []const u8, name: []const u8 };
fn controllerInfo(id: ControllerId) ?ControllerInfo;
```

The mouse travels in the game's own units. A host that passes window pixels to a game drawn at a
scale moves the game's pointer too fast (`docs/lessons.md`).

### 3.4 Audio

Audio crosses the boundary as PCM. Sequencing, sample decoding, synthesis, mixing and the
original's priorities are shared code; the platform plays the finished samples.

```zig
fn audioOpen(requested: AudioFormat) !AudioFormat;
fn audioQueue(samples: []const i16) !usize; // sample frames accepted; partial is allowed
fn audioStatus() AudioStatus; // queued and played frames, running or suspended
fn audioClear() void;
fn audioClose() void;
```

The queue is bounded and copies what it accepts. Timing is counted in sample frames, so the
render rate never decides the music's tempo, and effects are scheduled against the frame that
shows their cause. Suspension is state: a browser starts audio only after a user gesture.

### 3.5 Assets

```zig
fn open(path: []const u8) !OpenedAsset; // a handle and a length
fn readAt(file: AssetHandle, offset: u64, dst: []u8) !usize; // short reads allowed
fn list(prefix: []const u8) !OwnedAssetEntries;
fn close(file: AssetHandle) void;
fn readAll(path: []const u8, max_bytes: usize) !OwnedBytes; // shared helper over the four
```

Asset names are validated ASCII logical names, matched the way the original's file system
matched them (DOS rules). Each source converts its own names: the directory source keeps the
host's encoding; an ISO 9660 reader, if the port reads the CD image directly, drops version
suffixes. Such a reader belongs in shared code over a byte source, so the same parser serves a
native file, memory and a browser blob. An overlay decides which source answers first (for
example, a user configuration file or a mod's files over the CD's).

### 3.6 Storage

```zig
fn save(name: []const u8, bytes: []const u8) !void; // atomic replacement
fn load(name: []const u8) !OwnedBytes;
fn listSaves() !OwnedSaveNames;
fn deleteSave(name: []const u8) !void;
```

A save's name is a validated ASCII key; an invalid key is an error, never silently rewritten.
`save` returns once the store confirms the write; a failure before that keeps the previous
record. Storage holds bytes; the formats are shared code (section 7).

### 3.7 Ownership

- Inputs (paths, names, bytes, destinations) are borrowed for the duration of a call. Providers
  keep no borrow after returning.
- Returned buffers and listings belong to the caller until their `deinit`.
- Received network messages, once a port has a transport, stay valid until the next
  `pollEvents`.
- A handle outlives every call that uses it; its owner closes it.

### 3.8 Text

- Player-entered names and descriptions follow the original's field filters and length limits.
- Save keys and asset names are validated ASCII; an invalid name is an error.
- The original's text and its rendering data keep the original's glyph and layout encoding as it
  is: spacing codes, kerning and border glyphs are part of the drawing.
- Host paths and host text keep the platform's encoding.

## 4. Execution: the host loop and I/O

The skeleton reads its files and writes its saves inside an update, through the providers. That
is enough while every read is small or the files are in memory (the browser build fetches them
all before the first update).

When a read would stall the frame (a large load, a film streamed from the CD), the port adds I/O
workflows to the platform contract. A workflow is a finite job: load and decode a file, prepare a
set of assets, write a save, fill one film buffer, with the decoding that produces its result.
Previous ports ran **one workflow at a time** from a bounded queue: the game submits workflows and
takes their completed results at update boundaries. Why one at a time: the order of completion is
then defined, which the agent host's reproducible runs need; the queue and the buffers are
bounded; and the same model runs in a browser, where a suspended task cannot overlap another
without extra stack management. A workflow never runs inside the frame: waiting for a disk must
not stall input or drawing. The agent host completes workflows inline, so a run replays exactly;
the native executor uses `std.Io`; the browser completes its reads through the page.

Loading, menus, films, computer players and shutdown are phases of the game, advanced by bounded
updates. A required save keeps the shutdown phase alive until it is written.

**Three clocks stay separate**: the original's simulation time, the local presentation time, and
transport deadlines. A shared conversion keeps the original's timing units and rounding where they
are observable. The simulation advances by its own scheduler; the host limits how much work one
update does, and that limit must not change the order or the result of any event.

## 5. The hosts

### 5.1 The agent host (`sorz-agent`)

A headless host for scripted runs and debugging. It links no SDL and needs no window, sound
device or input device; it implements the same platform contracts, so rendering, input
interpretation, audio scheduling and loading run through the same code as in the game.

- A virtual clock: time advances only when the host says so, never with the time an agent spends
  thinking.
- The skeleton's host runs a number of frames, presses the keys named on the command line at
  their frames, and prints one JSON line: counters, the state's hash and the last frame's hash.
  Diagnostics go to standard error.
- Saves go to an in-memory store or to a directory the caller names; never to the user's.

A port grows it with the game: previous ports gave it a JSON-lines protocol on standard input
and output, with commands to reset, inject timestamped events, step a number of updates or run
until a condition, inspect state, and capture the frame and the PCM, each run bounded by work,
virtual-time and wall-clock limits that the response names. Grow only what the checks use.

The agent host is how the port is driven end to end without a display, and how a test reproduces
a defect. It is not the game the user runs: gates also run the SDL build (`docs/testing.md`).

### 5.2 The SDL host (`sorz-sdl`)

The interactive game on Linux and Windows. The first positional argument names the game
directory. The window's scale and full screen are the settings' (section 7); options select the
window scale for a run, a software renderer, an event log on standard output
(JSON lines, so a played session can be replayed headlessly once the agent host reads them), a
run time, and the saves directory. Its updates are paced by the display when the renderer
presents in step with it, and by a fallback pacer otherwise: a loop that presents nothing must
not spin.

The host captures the pointer when the game reads relative motion, with a key chord that releases
it. On Windows it is a console program, so that its command-line options and messages stay
usable, and it declares itself DPI-aware (section 8).

### 5.3 The browser build

The shared game compiled for `wasm32-freestanding`: no libc, no compiler-rt and no entry point.
The page's hand-written JavaScript creates the memory, provides the host functions (canvas
presentation, input with pointer lock, Web Audio, storage) and the few helper
functions the compiler emits calls to (128-bit multiply and divide, and the math functions the
code uses), and calls one update per animation frame. The build checks the module's list of
imports: an unexpected import is an error, and each helper is tested against compiler-rt.

When every file the game needs is fetched before the first update, the module needs no
suspension mechanism. Only a game that must stream files during play needs one (Asyncify, with a
pinned `wasm-opt`, a sized continuation buffer and a larger module; or JSPI where browsers
support it), behind the I/O workflows of section 4.

The browser keeps the game's records in its own storage, per address, and gives them back before
the game starts.

**Where the game's files come from.** The server that sends the page serves them: the page reads
`assets/manifest.json` (`{"files": [{"name", "size"}]}`) and fetches each `assets/NAME` it lists,
and that server is the native game (`--netplay`, or the relay of `--server`), reading the user's
copy through its `AssetSource` (section 9): the content tree on disk, or the one extracted from
the ROM in memory. The tree has a `manifest.json` of its own at its root (`docs/content.md`), so
it is served under `assets/tree/`: the listing names `tree/manifest.json`, `tree/title/art.json`,
and so on, and the page gives each file to the module under its name in the tree. The page never
asks the player to pick or upload the original's files. A page without a manifest says so and
stops; it does not run a game without its files.

**The page looks like the game.** The player sees the game's style from the first frame. The page
fetches first the few files the module needs to draw a screen (the content's `fonts/` and `menu/`
sets: the fonts, the menu's art and palette, about 20 KB), and from then on the module draws the
loading screen and its count of files itself, with the look of the game's menu after the title: black, the play font, the menu's
colours. Then the game runs its own front end, as the native game does (the network variant's,
section 9): the page has no menu of its own. The messages of network play and of errors are drawn
the same way, over the game's picture once it has one.
Until then, and for an error the module cannot draw, the page's own text stands in, in the menu's
colours and the closest font (bold slanted capitals), never in a browser or framework style.
Messages reach the player in the game's words and look, not as browser dialogs.

### 5.4 A build with the game's files inside (optional)

A port may offer an SDL game with the gameplay files built in, for users who own the original:
a build option names the user's copy (a CD image or a directory), a packer that runs on the build
machine copies an explicit list of files into a generated module, and that module is one more
`AssetSource`. It is then the one build that reads the original's files, and its output is never
committed or distributed with the repository. Large optional content (films) may be left out;
the game then disables what needs it.

## 6. Determinism and state

- **Explicit state.** A game is a value; nothing is global. Several games in one process do not
  share state.
- **Integer fixed-point** at the original's precisions in the simulation, never floating point;
  central helpers do the arithmetic, with the original's widths and rounding where they are
  observable.
- **One explicit random generator**, with the original's algorithm. Each draw is a named call, so
  that their order can be made the original's (exact).
- **A fixed tick and a fixed order** of the systems within it (section 10).
- **Canonical state.** A hash and a serialisation over named fields in a defined order and byte
  order, never over padding or pointers, identify the state for tests, replays and the network.
  A game loads from its serialisation and goes on as the one it was taken from: network play's
  join carries the game this way (section 9).

## 7. Assets and saves

- **Assets.** The original's files are read at run time from the game directory (or whatever
  source the port adds: a CD image, files built in). The port never commits them.
- **Saves.** One versioned format per kind of record (settings, a game in progress, ...). A record
  of another version is refused, not converted: no readers for old versions.
- **Settings.** The cartridge has no saves (decision D2), so the port's one record is its own
  settings: `settings.json` in the platform's `Storage` (`src/shared/settings/`), with the pads'
  keys, the controllers' buttons, the volume and the SDL host's window. The game's own options
  stay the original's and reset at power-on, so no record changes the simulation. The player
  changes the settings on a screen of the game (the user, 2026-10-05): ADVANCED SETTINGS, the line
  before EXIT in OPTIONS, and START during the game, which opens them in place of the pause (the
  extended and network variants); in the original, whose OPTIONS and pause are the cartridge's,
  the settings key (F1). The volume is one of them. The screen shows only the settings of the
  machine's own players (one in network play), and it holds the game while it is open (in
  network play, both games, and the other player is told why). A
  damaged record never stops the game: a field that does not read gives its default and the rest
  is kept, the player is told once, and the damaged record is kept beside the repaired one. A
  host's command line wins over the record for its run.

### Content

- **C1 The extractor** (today's exporter, rewritten around the content model) reads the user's ROM
  and writes the content:
  - art and maps as images and tile maps;
  - characters and enemies with their moves (frames, boxes, damage, sounds);
  - rounds with their scripts;
  - music as sequences;
  - texts.

  It is the one place that knows ROM addresses, and it says where each value comes from in a
  comment of the data, for provenance.
- **C2 The content's schema** is part of the design: versioned, validated when loaded, with errors
  that name the file and the field.
- **C3 Overlays:** a mod is a directory of content over the extracted one, on the same paths.
- **C4 The repository holds no content of the game**: the extractor and the schema, never the
  data (as now).

## 8. Builds and linking

The toolchain is pinned (`build.zig.zon`, `build.zig`). The modules, and what each links:

- `sorz` (`src/shared`), nothing: the game, the platform contract and the in-memory
  providers.
- `agent`, nothing: the agent backend and host.
- `native`, nothing: host I/O: the directory source and storage, and the command line.
- `sdl`, libc and SDL2: the SDL backend and host.

- **Linux.** SDL2 is linked from its static archive; the system libraries it needs (X11, Wayland,
  PulseAudio, ALSA) stay dynamic because they have no practical static builds. A build option
  links the shared SDL2 instead.
- **The agent host** links nothing but the Zig standard library; built for a musl target it is a
  fully static binary. The `verify` step checks that it has no SDL dependency.
- **Windows.** `-Dtarget=x86_64-windows-gnu`, which needs nothing from Windows to build. SDL2 comes
  from a Zig package (a build of SDL2 by Zig, added with `zig fetch` as a lazy dependency), is
  compiled from source and linked statically: the executables import only Windows' own libraries
  and the Universal C runtime. The SDL host is a console program and declares per-monitor DPI
  awareness through SDL's hint.
- **The browser.** `wasm32-freestanding`, imported memory, no compiler-rt, imported symbols for the
  host functions, no entry point (section 5.3).

## 9. Networking

The original's two players share one console. Network play is an addition (plan items A1, A2 and
26): the players of several machines play the same game as if on one console, two players today
(more players are a later work), and others may watch.

**The ways to play** (the user, 2026-10-01 and 2026-10-08). Two players on one machine use the
native game; a browser always has one player.

| How it starts | The machine | Who is who |
| --- | --- | --- |
| `sorz DATA` | 1 or 2 players; or NETWORK PLAY, the host | as on the console; the host's player is player 1 |
| `sorz DATA --netplay PORT` | as `sorz DATA`, NETWORK PLAY at PORT (8000 without) | as above |
| `sorz DATA --join ws://ADDRESS:PORT` | a client of that host, 1 player | player 2 once it joins, or an observer |
| `sorz DATA --server PORT` | none on the server; 1 player a browser | the first page is the host, the others its clients |

A machine with one player shows that player's input alone in its settings; network play sends that
player's pad. A player who opens the settings during a network game pauses every game of it, and
the others are told why.

**Each machine its own menus; the players meet in the game** (the user, 2026-10-05 and
2026-10-08). Each machine runs its own front end: the Sega logo, the title, its menus and OPTIONS
are its own, driven by its player alone. The host and its clients:

- **The host** is the native game whose player chooses NETWORK PLAY in its menu (1 PLAYER, 2
  PLAYERS, NETWORK PLAY, OPTIONS), or the first page connected to a server (its menu: 1 PLAYER,
  NETWORK PLAY, OPTIONS). NETWORK PLAY opens the network options: PLAYERS (2, the only number
  today), PORT (the native host's), OBSERVERS (yes or no), SAME CHARACTER (whether two players may
  choose one character), JOIN IN PROGRESS (whether a player may join a game under way, past its
  select: so that no one leaves and comes back for new lives), then START SERVER, START GAME and
  EXIT. START SERVER opens the session:
  the native host listens on every interface (0.0.0.0) at its port, and serves there the page and
  the game's files (section 5.3); the network options stay, the host's lobby: they list who is
  connected while clients come. START GAME opens the session if it is not open, and the host's
  player goes to the character select as player 1, and plays alone until a player joins. The
  session stays open from game to game; while it is, STOP SERVER (in the lobby) closes it: its
  clients go back to their menus, told THE HOST STOPPED, and the clients that come are turned away
  (they try again every second) until the session opens again. The lobby (in a grey between the
  menu's bright and dim tones: legible, not a line to choose), and the host's front end screens at
  the bottom left in white over the picture, list who is connected: LOCAL - PLAYER 1, and each
  client by its name and what it does (MENU, SELECT: at its own character select to join, PLAYER
  2, OBSERVING).
- **A client** is a page of that host or server (not the first), or `--join`: it connects as it
  starts, and its player gives a name of three letters, kept in the settings. Its menu: JOIN, when
  the host's session is open and a player's place is free; OBSERVE, when it is open, the host
  takes observers and has a game; OPTIONS. A line it cannot take is dimmed. With the host at its
  menu, JOIN's player chooses a character and waits for the host's game; its own select names its
  cursor 2PLAYER, the player it joins as. The host's select takes it once it shows: the client
  sees player 1's cursor come, its own screen, cursor and choice as they were (a choice made keeps
  its portrait, player 1's cursor moving on).
- **JOIN** goes to the client's own character select, and joins the host's game as player 2: at
  the host's select, the two meet there and each sees the other's cursor; in play, the client's
  player chooses a character on its own machine while the host plays on, and drops in once chosen,
  as the original's second player joins a game (its PRESS 2UP START).
- **OBSERVE** shows the host's game on the client: it takes the host's game and then each tick's
  pads (below), and holds no one. START leaves it, back to the client's menu; at the game's end
  the client plays on to its own front end.
- The game's rules (LEVEL, the lives, whatever of OPTIONS or the settings the game reads, SAME
  CHARACTER) are the host's game's: a client's OPTIONS shows only what is its own (its CONTROL:
  its pad carried into the host's by the host's). The host's settings change the settings' rules
  during a game too (FRIENDLY HIT at once, the lives and continues at the next continue), at a
  tick both machines share.
- When the game ends, each machine plays on to its own front end (a client in its own variant
  again), and the session stays open for the next game. A player who leaves, or does not come back
  in time, dies in the game as at the time over, and is out of it.
- Escape in a game leaves it, not the program: the host's player goes back to its menu, or to its
  lobby while its server runs; a client's player to its menu. The other machines are told (the
  session ends, the connections stay); a client at the select they shared keeps it, its own
  again, and an observer goes back to its menu. A client whose host is gone (its connection not
  back a second after the host's five) goes back to its menu. At the front end, Escape quits.
- While the server runs, the host's 1 PLAYER game takes a client as START GAME's does (SAME
  CHARACTER the lobby's); its 2 PLAYERS game is a local game of two: both its pads play, and it
  offers clients no place (observers may watch).
- The host's player who leaves a round its client plays: the game runs on for the client, on the
  host's machine under its lobby (silent there). Player 1 leaves it at a tick both machines make
  the change at (the host sends it ahead of its pads for that tick): its fighter dies as at the
  time over, and it is out. The lobby's RETURN TO GAME drops player 1 back in the same way, when
  JOIN IN PROGRESS allows it; EXIT shows the game, its player watching. The game over, or no
  client left in it, the host's menu comes back under the lobby, whether its player had the lobby
  open or watched; the observers go back to their menus.

**The join.** The host's game holds for a moment while its state crosses (its canonical form,
section 6); the client loads it, and from that tick on both run the same game in lockstep.

**Delay-based input lockstep.** From the join, the host and its player run the same deterministic
game; what crosses the network in play is each player's pad. Every display tick, a player's
machine samples its pad and sends it for tick N + D, where the input delay D is chosen at the
session's start from the measured round trip (2 to 6 ticks); tick N runs when every player's pad
for N is in. The loads' waits are ticks like any other (section 10.2), so the machines stay in
step through them. Rollback (predicting a pad and re-running the ticks it changes) is not planned:
a co-operative beat-'em-up tolerates a few ticks of delay, and re-running ticks would replay the
sound. It is the upgrade if the delay is felt.

- **Observers.** The host sends an observer its game, then the pads of each tick as it runs
  (every player's); the observer runs them as they come, behind the players, and no game waits
  for it. When the host's game changes otherwise than by its pads (a player joins, a player
  leaves), the host sends its game again. An observer checks its states against the host's hashes,
  as a player does.
- **Canonical state.** The game's state is one value, with a canonical serialisation (section 6).
  Its hash is exchanged every 30 ticks; a mismatch stops the game, and the machines then compare
  their serialisations field by field to name the first differing field.
- **Time.** Each machine runs its ticks at its own sound device's rate (section 3.4), and the
  devices' clocks differ slightly. A player's machine that gets ahead stretches its sound by up to
  0.5 % (the synthesiser's output rate) until they are level again, so neither waits with an empty
  sound queue. A machine whose partner's input is late holds: no tick runs, the picture stays, and
  the sound fades rather than breaks.
- **Stats** (the user, 2026-10-09). Each machine of a session measures, every second, the ticks it
  ran, its busy share of the time (its updates' work, without the presenting, which may wait for
  the display) and its wait for the other's pads, and sends them to the other. With the settings'
  NETWORK STATS on (off by default), a machine shows during the session's rounds, at the bottom
  left over the picture, its own line (LOCAL) and the other's (the client's name on the host, HOST
  on the client), with the ping and the input delay. A machine busy near 100 % is the slow one;
  waits while neither is busy are the link's, its ping near or past what the delay covers.
- **Game data.** A page loads the game's files of the native game that serves it (section 5.3):
  the host's copy, or the server's. A native client uses its own. The handshake compares the
  data's identity, its content tree's digest (a ROM's is the digest of the tree extracted from it,
  so a ROM, an unedited extraction of it and a page's copy of either are the same data; an edited
  tree, a mod, is other data), and refuses a client of different data.

**Leaving.** A host that leaves ends the session: each client goes back to its own menu, told why.
A player's connection that drops holds the game on the host and on its observers, with a count of
five seconds (PLAYER 2 DISCONNECTED, the seconds left); a client that comes back in time resumes
it; otherwise the host decides the tick at which its player leaves the game (its character goes
and does not come back), and plays on. The client may join again later. A client in its menu or
observing leaves as it pleases.

The layers:

- The game (game.zig) takes the merged pads of each tick from the session instead of the local
  controls, and never runs a tick ahead of them.
- The session protocol, in shared code, encodes and decodes messages and keeps the handshake
  (protocol and build versions, data identity, the client's name, the input delay), the host's
  word on its session (open, a player's place free, observers taken), the inputs by tick, pings,
  state hashes, the hold, and reconnection. It is outside the simulation. The host keeps one
  session of the protocol for each client.
- The platform transport moves whole messages, reliably and in order, while a connection lives:
  `connect`, `listen`, `send` (accepted into a bounded queue) and `close`, and the events
  `connected`, `disconnected` and `received` through `pollEvents`. The transport is WebSocket
  (RFC 6455): the native build implements a server and a client on `std.Io.net`, the browser uses
  the page's WebSocket. The agent host has an in-memory transport, so that agent instances can
  play a session in one test.

**The native host** (NETWORK PLAY, at `--netplay`'s port, 8000 without): it serves the browser
build's files, the game's files of DATA (section 5.3) and a WebSocket on one port. A client joins
from a browser at that address, whose page loads the host's files and runs the game's own front
end, or from another native game with its own data (`sorz DATA --join ws://ADDRESS:PORT`). The
native game serves the browser build from inside itself: `build.zig` embeds the page, the script
and the module into each executable (the generated module `web_page`, with `@embedFile`), so there
is no `web` directory to serve and no option to serve one.

**Server mode** (`sorz DATA --server [ADDRESS:]PORT`): `sorz-sdl --server` and `sorz-agent
--server` run no game; `sorz-server`, a program of its own that links nothing, does the same on a
machine without the display and sound libraries that `sorz-sdl` needs to start. It serves the
page built into it and the game's files of DATA, and relays the session's binary messages between
the host's page and its clients' pages, never parsing them. The first page to connect is the
host; each other page is a client, given a number that is not used again. The server tells each
page its role in a text message (`host`, `client`), and tells the host when a client comes and
goes (`peer N`, `left N`). A client's binary messages reach the host after the client's number
(two bytes); the host's go to the client whose number they start with, which the server takes off.
The host's page shows each client to the module as a connection of its own, so the game's host
logic needs no listening socket; its manifest says it is a relay, so the page reports a
connection open only after its role. A host that leaves ends its clients' connections (each told
`left`): they go back to their menus, connect again, and the first to do so hosts. Each
connection's queue is bounded: a page that does not read is dropped when its queue is full, so
that it never holds another back; a page silent for 15 seconds is dropped.

## 10. The game

### 10.1 Architecture

```
 hosts (SDL, agent, browser)      platform contract: frames, input, audio, storage, transport
        |
 app: scenes (boot, title, menu, options, select, round, continue, ending, settings...)
        |
 engine: world (entities, systems), camera, rounds' scripts     <- content (asset tree)
        |                     |
 renderer (layers, sprites)   audio (sequencer -> chips -> PCM)
```

- **Hosts and platform:** carried over from sor-remaster after review (plan item F1). The contract
  stays: the game is a value; hosts give it time, input, storage and a transport, and take its
  frames and PCM.
- **The app** is a stack of **scenes**. Each scene owns its state, takes input, advances on the
  tick, and draws.
- **The engine** runs a round: a world of entities, the systems that move them, the round's
  script and the camera.
- **The renderer and the audio** are subsystems the scenes and the engine drive through plain
  descriptions: a frame's layers and sprites, sound events.

### 10.2 Time

- **T1 The display tick** is 59.92 Hz, the console's frame. Presentation, fades and the audio
  pacing count display ticks.
- **T2 The logic tick:** in play the original runs its logic every other display tick (30 Hz)
  and draws in between. The engine has a logic tick at that rate, and the round's systems run on
  it; screens that run at 60 Hz have their own rate. The scheduler says which ticks run what, in
  one place.
- **T3 Lag and slowdown** (the original's dropped frames, decision D3): not reproduced, unless
  decided otherwise; the scheduler is the one place where it would go.
- **T4 Loads** (the original's waits while a round loads) are scenes of their own with their
  measured length, so the timing of music and fades around them stays the original's.

### 10.3 The world

- **W1 Entities.** A fixed pool, enough for the original's 66 objects at once and room to spare.
  An entity has a stable handle (index and generation), so a stale reference is caught.
- **W2 Its data is typed fields, not a record of bytes:**
  - position: x, depth on the ground and height, fixed-point;
  - velocity;
  - facing;
  - team: player, enemy, neutral;
  - health and lives;
  - the current move and its frame;
  - the animation and its frame;
  - the collision boxes in use;
  - timers;
  - a reference to its definition in the content.
- **W3 Behaviour** is a state machine per kind of entity, with named states:
  - player: walk, attack, grab, thrown, knocked down...;
  - enemy: approach, wait, attack, flee...;
  - weapon: lying, held, thrown.

  The states are code; their numbers (speeds, durations, ranges, damage) are the definition's
  data. A kind of enemy is one definition plus, when its behaviour is its own (a boss), one
  behaviour module.
- **W4 Systems in a fixed order per logic tick** (the original's turn, as measured against
  sor-remaster):
  1. input to commands;
  2. player control;
  3. the players' movement;
  4. the camera;
  5. the other entities' tick begins (a state entered at the last tick sets itself up);
  6. hit and hurt boxes, hits and their reactions;
  7. grabs and throws;
  8. AI decisions;
  9. the others' movement and gravity;
  10. pick-ups;
  11. the round's script (spawns, events, walls of the camera);
  12. animation;
  13. sound events;
  14. the draw list.

  The order is part of the game's definition: exact may require reordering a step, and then it is
  done here.
- **W5 Depth and drawing order:** entities are drawn by depth, with the original's tie-breaking
  as a named rule.
- **W6 The round's script:** a round is data:
  - its map and layers;
  - the camera's limits and stops;
  - the triggers that bring waves of enemies;
  - the items in its scenery;
  - its special events: the police car, the lift, the boss's arrival;
  - its music.

  Special set pieces that are more than data (round 5's ship, round 7's lift, round 8's offer)
  are behaviour modules the script names.

### 10.4 Scenes and flow

- **S1 Scenes:**
  - boot, Sega logo, intro, title, game menu, options, character select;
  - round (intro, play, clear, tally), continue, game over, name entry, ending, high scores;
  - the port's settings screen.
- **S2 The flow between scenes is a graph described in one place** (a table of scenes and their
  exits). The ways to play (`docs/workflows.md` of sor-remaster: W1 to W6) are variants of that
  graph. The network flow, for example: each machine its own front end, a game menu of 2 PLAYERS
  and OPTIONS, the machines meeting at the character select or in the round (section 9).
- **S3 Overlays** (the settings screen, the network messages, the pause) are scenes pushed over
  another, which they hold or not by their own rule. The settings screen and network play's
  messages are each machine's own and stay out of the game's shared state. Outside the original,
  START during the game opens the settings in place of the pause, and they hold the game as the
  pause does.

### 10.5 Rendering

- **R1 A description, not a VDP.** A frame is:
  - two scrolling tile layers, with per-line or per-column scroll for the effects that need it
    (round 3's waves);
  - a fixed layer for the status bar and the window;
  - sprites with priority and palette;
  - 4 palettes of 16 colours, with fades and cycles.

  The renderer composes it into 320 × 224 indexed pixels, then RGBA.
- **R2 Art by name:** tiles, maps and sprite frames are assets with names; the renderer keeps them
  ready to draw. There is no VRAM to manage, and no tile slots.
- **R3 Exactness of pixels** is reachable because the layers' rules are the console's: priority,
  transparency, the 8-pixel cells. The sprite limits are not reproduced (decision D4).
- **R4 Efficiency:**
  - the layers are drawn by cell and by run;
  - unchanged layers are not drawn again;
  - a frame is composed only when the picture changed.

### 10.6 Sound

- **A1 The game asks for sounds by name** ("menu move", "punch hits", "round 1 music"), and the
  content maps each name to its music or effect.
- **A2 A sequencer plays them:**
  - tracks of notes, rests, instrument and volume changes, loops, vibrato;
  - channels assigned with the original's priorities: an effect takes a music channel and gives
    it back.

  It is a clean implementation of the original driver's semantics, its music data turned into
  readable sequences by the extractor.
- **A3 The chip models** (YM2612 from ymfm, the PSG, the DAC and its samples, the model 1 output
  stage) carry over from sor-remaster as they are. They model hardware, are bit-exact against
  ymfm, and are already efficient.
- **A4 Exact:** the sequencer's register writes are checked against sor-remaster's driver for
  every song and effect, then the PCM. The five known drum-hit cases depend on the 68000's and
  the Z80's timing: they get a deliberate, named model.

### 10.7 Extensibility and variants

- **E1 The extension points:**
  - new content: characters, moves, enemies, rounds, items, music;
  - rules as small, named policies, each a function with a default: may two players choose the
    same character; the player palettes for a duplicate; the number of lives; friendly fire;
  - scenes and the flow graph;
  - behaviour modules for special enemies and set pieces;
  - the settings.
- **E2 Variants** are configurations: a flow graph, a set of policies and content overlays.
  - **original**: the cartridge's flow and rules, the target of exact; its pause on START, the
    settings by the settings key (F1).
  - **extended**: the default; port additions such as ADVANCED SETTINGS in OPTIONS, START opening
    the settings during the game, or the same character twice.
  - **network**: one player a machine, a client of a host (section 9): each machine its own
    menus, the players meeting in the game; the extended variant's menu offers NETWORK PLAY, its
    host.

  A variant is chosen at start; in network play the host's is both games'.
- **E3 Example: the same character twice.** The select scene asks the policy whether a choice is
  taken. The world loads each player's palette from the character's definition and the
  "duplicate" palette rule. No other code knows about it.

## 11. Verification

- **V1 Unit tests** for each system, on synthetic content.
- **V2 Semantic traces.** Both programs emit the same vocabulary of events per tick:
  - "entity of kind K entered state S";
  - "hit: attacker, target, damage";
  - "spawn";
  - "sound requested";
  - "camera moved";
  - "scene changed".

  sor-remaster gets an observer that derives them from its state each tick, so its code does not
  change.
- **V3 Similar, mechanic by mechanic:** short scenarios run from the same starting state in both
  programs (sor-remaster can produce the state at any tick; a converter gives the new sorz the
  same situation in its terms). Then their traces and measurements are compared:
  - each move's start-up, active and recovery frames, hit boxes, damage, knock-back;
  - speeds, jumps and throws' arcs;
  - the AI's delays, ranges and choices, as distributions over many runs;
  - the rounds' spawns and the camera's stops;
  - the screens' timings.

  Each comparison has a stated tolerance. Long runs are not compared: two plausible games diverge
  at the first different decision.
- **V4 Exact:** the traces equal tick by tick from power-on with the same inputs; the pictures
  equal sor-remaster's (which equal the original's); the sound's writes and PCM equal.
- **V5 The user plays it:** feel is judged by hand once the numbers match.
- **Evidence.** Every mechanic has evidence: a measurement of sor-remaster or of the original
  running. A deliberate difference from the original is the user's decision, recorded where the
  code makes it, and as a variant's policy (section 10.7).
- **A report of a defect is a lead:** measure sor-remaster (or the original) before changing sorz.

## 12. The reference and the original

- **sor-remaster** (`/home/jd/sor/sor-remaster`, outside this repository) is the reference: a
  program that plays exactly as the original, deterministic, inspectable at every tick, with an
  observer that writes its semantic traces (section 11).
- **The original's description** lives in sor-re: the port maps (`sor-re/docs/*-port-map.md`), the
  disassembly and the tools. The extractor's comments name the ROM's places it reads.


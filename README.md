# Game port template

A starting point for porting an old game, typically a DOS game, to Linux, Windows and the browser
with Zig. It holds the way of working and the technical design that previous ports arrived at;
the examples in its documents come from them.

The template has two parts:

- **The way of working.** The rules for agents (`AGENTS.md`), the plan (`PLAN.md`), the design
  (`DESIGN.md`), and the notes in `docs/` on the process, the tests, the study of the original and
  the lessons learned.
- **A skeleton that builds and tests as it is.** The platform boundary, the three hosts (a
  headless agent host, an SDL host and a browser build) and a placeholder game in place of the
  real one. It holds what every port needs the same way; what depends on the game (a network
  link, background I/O, a test runner, a build with the game's files inside) is described in
  `DESIGN.md` and `docs/testing.md` and grown by the port when its game asks for it.

The placeholder name of the project is `sorz`.

## Starting a port

1. **Copy the folder and name the project.** The name becomes the Zig module, the binaries
   (`mygame-agent`, `mygame-sdl`) and the browser files, so it must be a lowercase
   Zig identifier that is not a keyword: letters, digits and underscores. Replace `sorz`
   everywhere, in the contents and in the file names, give the package its own fingerprint, and
   start the port's own history:

   ```sh
   cp -r game-port-template mygame && cd mygame
   rm -rf .git .zig-cache zig-out zig-pkg
   grep -rlI sorz . | xargs sed -i 's/sorz/mygame/g'
   find . -depth -name '*sorz*' \
       -execdir sh -c 'mv "$1" "$(echo "$1" | sed s/sorz/mygame/g)"' _ {} \;
   grep -rniI sorz . || echo "renamed everywhere"
   # A renamed package needs its own fingerprint; `zig build` rejects the old one and suggests one.
   fp=$(zig build --prefix /tmp/mygame/out 2>&1 |
       sed -n 's/.*use this value: \(0x[0-9a-f]*\).*/\1/p')
   sed -i "s/\.fingerprint = 0x[0-9a-f]*/.fingerprint = $fp/" build.zig.zon
   git init && git add -A && git commit -m "Start mygame from the game port template"
   ```

2. **Keep the original out of the repository.** The CD image, the installed game, captures of it
   and the tools that study it live outside the repository. Recorded measurements of the
   original's behaviour may be committed as test data (`docs/testing.md`).
3. **Write the game into `DESIGN.md`.** Its TODO sections describe the original: the executable,
   the video modes, the sound hardware, the input devices, the network, and the subsystems that
   the port maps will cover. The rest of the design applies as it is; change it only with the
   user's approval.
4. **Plan the first items.** `PLAN.md` holds the phases that previous ports went through, with
   placeholders where the game decides. Fill in the scope and the gate of the first items, and
   commit the plan before the work starts.
5. **Check the start.** The steps are listed at the top of `build.zig`: `zig build`, `zig build
   test` and `zig build smoke` pass on the skeleton before the first change. `zig build all`
   builds every binary at once: this machine's, Windows's under `zig-out/windows`, and the browser
   build.
6. **Replace the placeholder game.** `src/shared/game.zig` is where the real game grows, behind
   the same platform contracts that the hosts already drive.

## The folder

- `AGENTS.md`: the rules for agents working in the repository. Read it first.
- `PLAN.md`: the work, in phases and items, each with a scope and a gate.
- `DESIGN.md`: the technical design: the platform boundary, the hosts, determinism, the builds.
- `docs/process.md`: how a session and an item go, and how to work with the user and with
  subagents.
- `docs/testing.md`: what is tested, how, and what may be committed as reference data.
- `docs/reverse-engineering.md`: how to study the original: sources, oracles, emulators, port
  maps.
- `docs/port-map-template.md`: the outline of a subsystem's port map.
- `docs/lessons.md`: the lessons and traps of previous ports that apply to any port.
- `src/shared`: the `sorz` module, the game and everything the targets share. It links
  nothing. `platform.zig` holds the platform contract (with network play's transport),
  `memory.zig` the in-memory providers, `game.zig` the game as the hosts run it (its content,
  its picture and sound; a test pattern without content), `scene.zig`, `flow.zig` and `screens/`
  the scenes, the flow between them and the front-end screens, `library.zig` the scenes' content
  found by name, `content/` the content tree, `render/` the renderer, `audio/` the sound,
  `world/` play's world, `canonical.zig` the canonical form of its state, `input.zig` and
  `settings/` the controls and the settings record, and `net/` network play's protocol, session
  and driver.
- `src/agent`: `sorz-agent`, the headless host: the agent backend under a virtual clock of display
  ticks, keys at chosen ticks, frames as PNG files and the sound as a WAV file, one JSON line of
  counters and digests, and network play (`--netplay`, `--join`, `--pair`). It never links SDL.
- `src/native`: host I/O for the native targets: the directory asset source, the directory
  storage, their shared contract tests, the command line (a content tree, or a ROM whose content
  is extracted in memory), the WebSocket transport, the game's files a server gives its pages, the relay of
  server mode, and the binaries' log lines.
- `src/sdl`: `sorz-sdl`, the interactive host on SDL2, for Linux and Windows.
- `src/server`: `sorz-server`, the relay of network play between two browsers (server mode), with
  no game and no library.
- `src/web`: the browser build: the WebAssembly module, its backend, the page and its script, and
  their checks (`page_check.cjs` under Node, `browser_check.mjs` in Chromium).
- `tools`: build helpers only: the checks that the agent and server binaries link no SDL and that
  each executable alone serves its page, the settings across starts, and the engine's rule against
  the console's terms (`engine_terms.zig`, with its allow-list). Tools that study the original do
  not belong here.

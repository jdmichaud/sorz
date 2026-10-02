Purpose of this project:
Implement a modern re-implementation of Streets of Rage (Sega Mega Drive, 1991). The code is
portable, maintainable and extensible, with modern engineering practices, and written in the
game's terms: it is neither an emulator nor a translation of the original's program. Its content
comes from a human-readable tree that the game extracts from the ROM the user supplies.

The targeted platforms are Linux/SDL, Windows/SDL and the browser through WebAssembly.

The game plays as the original does: first similar (its mechanics measured equal), then exact if
needed; the sound is exact. The reference is sor-remaster, a translation of the original verified
against it, outside this repository (DESIGN.md section 12).

Rules:
- Create small self-contained commits on the main branch, each one building and passing the
  tests. The subject is `area: description`; the body says why and how it was verified, wrapped
  at 100 columns. Never push: the user decides what leaves the machine.
- Maintain PLAN.md: a missing item is first documented in PLAN.md, in its own commit, with the
  rationale in the commit message. When an item's gate is met, flag it ([x]). The plan holds
  items, scopes and gates, not commentary.
- DO NOT modify DESIGN.md without explicit approval.
- Use as few dependencies as possible.
- Link native binaries statically when practical. Depend on a dynamic library only when no other
  practical choice is possible.
- Build and test with the repository alone. No file of the original game and no capture of it is
  in the repository or needed by a build or a test (a build that embeds the game's files takes
  them from a copy the user supplies). Recorded measurements of the original's behaviour
  (traces, routine outputs, decisions) may be committed as test data; tests that need game data
  use synthetic data. No personal paths or identifiers in committed files.
- Verify before claiming. Reproduce a report in the build the user runs before changing code, and
  verify the fix the same way. Never re-record a baseline to bless your own change. Say what is
  not verified.
- The original's bytes decide. Measure the original before changing a behaviour; a recovered
  source, a curve fit or a report is a lead, not evidence.
- Log each problem found in a tool (decompiler, emulator, interpreter) in that tool's log,
  outside the repository, with a reproduction. If it blocks the work, stop and raise the flag.
- Put scratch output (builds, captures, screenshots, logs) under /tmp/<project>, never in the
  repository or in zig-out, and delete it when the check is done.
- Never write into the original's files: an emulator runs a copy of the ROM.
- Stop processes by PID. `pkill -f` and `pgrep -f` also match the caller's own command line.
- Remove an agent worktree and its branch once its work has landed.
- Never port sor-remaster's code line by line. A mechanic is written in the game's terms, with
  its numbers as content, and checked against sor-remaster at the level of meaning.
- No ROM address, RAM offset, register name or console term in the engine's code (DESIGN.md P1):
  the original's places belong to the extractor, the content's provenance and sor-re's port maps.

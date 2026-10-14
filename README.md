# sorz

sorz is Sega's Streets of Rage (Mega Drive, 1991) rewritten in Zig, for Linux, Windows and the
browser, played from your own copy of the ROM.

sorz add network play and AI co-op game.

## Starting the game

You need the ROM of the 1991 cartridge (512 KiB, SHA-256 `dd44f120…95c0`). Other versions are
refused.

```sh
sorz sor.md
```

`sorz --help` lists the options. To play with a second player over the network, choose
NETWORK PLAY in the menu. The other player then opens `http://YOUR-ADDRESS:8000` in a browser, or
runs `sorz sor.md --join ws://YOUR-ADDRESS:8000`.

## Building

You need Zig 0.17. On Linux you also need SDL2's development files and pkg-config (Debian:
`libsdl2-dev pkg-config`). A Windows build fetches its own SDL2.

```sh
zig build                          # sorz, sorz-agent and sorz-server, in zig-out/bin
zig build standalone -Drom=sor.md  # sorz-standalone: the ROM built in, no argument needed
zig build all                      # also the Windows programs and the browser build
zig build test
```

Do not share `sorz-standalone`: it contains your ROM. Every build step is listed at the top
of `build.zig`.

## License

None yet: all rights reserved. The YM2612 emulation (`src/shared/audio/chips/ym2612.zig`) is a
port of ymfm, under the BSD 3-Clause License; its notice is in that file. Streets of Rage belongs
to Sega, and none of its files are in this repository.

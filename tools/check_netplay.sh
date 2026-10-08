#!/bin/sh
# Network play on the real game over WebSockets (DESIGN.md 9, PLAN items 18 and 26), with the agent
# host and the user's ROM (its content extracted in memory by each process): two processes, the host
# (`--netplay`) and the client (`--join`), each running its own front end with its own keys. The
# host's player chooses NETWORK PLAY, opens the session (the network options' START), chooses Axel
# and plays round 1 alone; the client's player gives its name, chooses JOIN later, a character on
# its own select while the host plays (Axel taken), and joins mid-round: the host's game crosses,
# its sound beside it, and both run it. At the session's tick 600 both are in the round with two
# players, in the same state, one session, and both played the same sound since the join, frame by
# frame (the round's music going on from the host's place). The flows in one process (the joins at
# the select, observing, leaving, a dropped connection, a planted difference) are
# src/tools/netplay_check.zig's.
set -eu
bin="${1:?usage: check_netplay.sh AGENT ROM}"
rom="${2:?usage: check_netplay.sh AGENT ROM}"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
fail() { echo "check_netplay: $*" >&2; exit 1; }
# A field of a JSON line (its last of that name).
field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }

ticks=600
# Both to their game menus; the host's NETWORK PLAY at once (down to it, A, the network options'
# START), Axel and play; the client's name (START keeps the entry's) and its JOIN much later (its
# arrow back on JOIN once the host's session is open): the two run as fast as they can, and a
# client at its select while the host is still at its own would join it there. Its JOIN
# 2,100 updates after the host's NETWORK PLAY finds the host in its round unless the client runs
# three times as fast.
front="--key 500:enter:3 --key 560:enter:3"
host_keys="$front --key 620:down:3 --key 640:z:3 --key 800:enter:3 --key 1160:right:3 --key 1180:z:3 --key 1800:right:60 --key 2000:x:3"
guest_keys="$front --key 760:enter:3 --key 2940:z:3 --key 3240:z:3"

# A port of their own (another try on another port if it is taken).
for try in 1 2 3; do
  port=$((20000 + ($$ * 7 + try * 131) % 20000))
  # shellcheck disable=SC2086
  "$bin" "$rom" --netplay "127.0.0.1:$port" --delay 3 --frames 30000 --until-session $ticks $host_keys >"$dir/host.json" 2>"$dir/host.log" &
  host=$!
  sleep 1
  if kill -0 "$host" 2>/dev/null; then break; fi
  wait "$host" || true
  [ "$try" = 3 ] && fail "the host could not listen: $(tail -3 "$dir/host.log")"
done
# shellcheck disable=SC2086
"$bin" "$rom" --join "ws://127.0.0.1:$port" --frames 30000 --until-session $ticks $guest_keys >"$dir/guest.json" 2>"$dir/guest.log" || fail "the client failed: $(cat "$dir/guest.json") $(tail -3 "$dir/guest.log")"
wait "$host" || fail "the host failed: $(cat "$dir/host.json") $(tail -3 "$dir/host.log")"
h="$(cat "$dir/host.json")"
g="$(cat "$dir/guest.json")"
[ "$(field "$h" state_hash)" = "$(field "$g" state_hash)" ] || fail "the two processes' states differ: $h $g"
[ "$(field "$h" sound_frames)" -gt 0 ] && [ "$(field "$h" sound_peak)" -gt 1000 ] || fail "no sound in the session: $h"
[ "$(field "$h" sound_frames)" = "$(field "$g" sound_frames)" ] && [ "$(field "$h" sound_hash)" = "$(field "$g" sound_hash)" ] || fail "the two processes' sounds differ since the join: $h $g"
for line in "$h" "$g"; do
  [ "$(field "$line" session_tick)" = $ticks ] || fail "a game did not reach the session's tick $ticks: $line"
  [ "$(field "$line" scene)" = round ] || fail "a game is not in the round: $line"
  [ "$(field "$line" players)" = two ] || fail "a game has not two players: $line"
  [ "$(field "$line" variant)" = network ] || fail "a game is not the network variant: $line"
  [ "$(field "$line" phase)" = playing ] || fail "a session is not in play: $line"
  [ "$(field "$line" sessions)" = 1 ] || fail "not one session: $line"
  [ "$(field "$line" verdict)" = ok ] || fail "a game's verdict is not ok: $line"
done
# The guest joined mid-round: the host had played alone a while.
[ "$(field "$h" ticks)" -gt $((ticks + 1500)) ] || fail "the guest did not join mid-round: $h"
echo "check_netplay: two processes, the guest joined the host's round; the same state at the session's tick $ticks: $(field "$h" state_hash); the same sound since the join: $(field "$h" sound_frames) frames, $(field "$h" sound_hash)"

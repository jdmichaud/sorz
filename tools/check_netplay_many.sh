#!/bin/sh
# Network play of three and four machines on the real game over WebSockets (DESIGN.md 9, 10.7 E4,
# PLAN item 51), with the agent host and the user's ROM: N processes (3 or 4), the host
# (`--netplay`) and N - 1 clients (`--join`), each running its own front end with its own keys,
# as tools/check_netplay.sh does with two. The host's player chooses NETWORK PLAY, sets PLAYERS
# to N in the network options (up from PORT, then right), starts the game, chooses Axel and plays
# round 1 alone; each client's player gives its name, chooses JOIN once the host offers a place
# in its round, a character on its own select (the third client one to the right of the second's,
# so that with three players and SAME CHARACTER off each plays its own), and joins mid-round:
# the host's game crosses to each at a tick every machine shares, and all run it. At the
# session's tick 1500 every machine is in the round with N players, in the same state, one
# session, each client in its own place, and all played the same sound from the session's tick
# 900 on, frame by frame.
set -eu
bin="${1:?usage: check_netplay_many.sh AGENT ROM N}"
rom="${2:?usage: check_netplay_many.sh AGENT ROM N}"
n="${3:?usage: check_netplay_many.sh AGENT ROM N}"
case "$n" in 3) players=three ;; 4) players=four ;; *) echo "check_netplay_many: N is 3 or 4" >&2; exit 2 ;; esac
dir="$(mktemp -d)"
pids=""
cleanup() {
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  rm -rf "$dir"
}
trap cleanup EXIT
fail() { echo "check_netplay_many: $*" >&2; exit 1; }
# A field of a JSON line (its last of that name).
field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }

ticks=1500
sound_from=900
front="--key 500:enter:3 --key 560:enter:3"
# PLAYERS: up from PORT to it, then right once (3) or twice (4), then START GAME.
more="--key 770:right:3"
[ "$n" = 4 ] && more="$more --key 790:right:3"
host_keys="$front --key 620:down:3 --key 640:z:3 --key 740:up:3 $more --key 820:enter:3 --key 1160:right:3 --key 1180:z:3 --key 1800:right:60 --key 2000:x:3"
guest_keys="$front --key 760:enter:3 --key place+300:z:3"

for try in 1 2 3; do
  port=$((20000 + ($$ * 11 + try * 173) % 20000))
  # shellcheck disable=SC2086
  "$bin" "$rom" --netplay "127.0.0.1:$port" --delay 3 --frames 40000 --until-session $ticks --sound-from $sound_from $host_keys >"$dir/host.json" 2>"$dir/host.log" &
  host=$!
  sleep 1
  if kill -0 "$host" 2>/dev/null; then break; fi
  wait "$host" || true
  [ "$try" = 3 ] && fail "the host could not listen: $(tail -3 "$dir/host.log")"
done
pids="$host"
clients=""
i=1
while [ "$i" -lt "$n" ]; do
  # The client's character: as its cursor starts (the first free), the third's one to the right.
  choose="--key place+600:z:3"
  [ "$i" = 2 ] && choose="--key place+560:right:3 --key place+620:z:3"
  # shellcheck disable=SC2086
  "$bin" "$rom" --join "ws://127.0.0.1:$port" --frames 40000 --until-session $ticks --sound-from $sound_from $guest_keys $choose >"$dir/guest$i.json" 2>"$dir/guest$i.log" &
  clients="$clients $!"
  pids="$pids $!"
  i=$((i + 1))
done
i=1
for c in $clients; do
  wait "$c" || fail "client $i failed: $(cat "$dir/guest$i.json") $(tail -3 "$dir/guest$i.log")"
  i=$((i + 1))
done
wait "$host" || fail "the host failed: $(cat "$dir/host.json") $(tail -3 "$dir/host.log")"
pids=""
h="$(cat "$dir/host.json")"
[ "$(field "$h" sound_frames)" -gt 0 ] && [ "$(field "$h" sound_peak)" -gt 1000 ] || fail "no sound in the session: $h"
seen=""
i=1
while [ "$i" -lt "$n" ]; do
  g="$(cat "$dir/guest$i.json")"
  [ "$(field "$h" state_hash)" = "$(field "$g" state_hash)" ] || fail "the host's and client $i's states differ: $h $g"
  [ "$(field "$h" sound_frames)" = "$(field "$g" sound_frames)" ] && [ "$(field "$h" sound_hash)" = "$(field "$g" sound_hash)" ] || fail "the host's and client $i's sounds differ from tick $sound_from: $h $g"
  [ "$(field "$g" session_start)" -lt $sound_from ] || fail "client $i joined past tick $sound_from: $g"
  seen="$seen $(field "$g" player)"
  i=$((i + 1))
done
for file in "$dir"/host.json "$dir"/guest*.json; do
  line="$(cat "$file")"
  [ "$(field "$line" session_tick)" = $ticks ] || fail "a game did not reach the session's tick $ticks: $line"
  [ "$(field "$line" scene)" = round ] || fail "a game is not in the round: $line"
  [ "$(field "$line" players)" = $players ] || fail "a game has not $players players: $line"
  [ "$(field "$line" phase)" = playing ] || fail "a session is not in play: $line"
  [ "$(field "$line" sessions)" = 1 ] || fail "not one session: $line"
  [ "$(field "$line" verdict)" = ok ] || fail "a game's verdict is not ok: $line"
done
# Each client in its own place, players 2 to N.
for want in $(seq 2 "$n"); do
  case " $seen " in *" $want "*) ;; *) fail "no client is player $want:$seen" ;; esac
done
# The clients joined mid-round: the host's round had begun before the session's first tick.
[ "$(field "$h" ticks)" -gt $((ticks + 1300)) ] || fail "the clients did not join mid-round: $h"
echo "check_netplay_many: $n processes, the clients joined the host's round as players$seen; the same state at the session's tick $ticks: $(field "$h" state_hash); the same sound from tick $sound_from: $(field "$h" sound_frames) frames, $(field "$h" sound_hash)"

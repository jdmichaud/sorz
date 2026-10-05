#!/bin/sh
# Network play on the real game over WebSockets (DESIGN.md 9, PLAN item 18), with the agent host and
# the user's ROM (its content extracted in memory by each process): two processes, the host
# (`--netplay`) and the guest (`--join`), each running its own front end with its own keys. The
# host's player chooses 2 PLAYERS and Axel and plays round 1 alone; the guest's chooses 2 PLAYERS
# later, a character on its own select while the host plays (Axel taken), and joins mid-round: the
# host's game crosses, and both run it. At the session's tick 600 both are in the round with two
# players, in the same state, one session. The flows in one process (the joins at the select,
# leaving, a dropped connection, a planted difference) are src/tools/netplay_check.zig's.
set -eu
bin="${1:?usage: check_netplay.sh AGENT ROM}"
rom="${2:?usage: check_netplay.sh AGENT ROM}"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
fail() { echo "check_netplay: $*" >&2; exit 1; }
# A field of a JSON line (its last of that name).
field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }

ticks=600
front="--key 500:enter:3 --key 560:enter:3 --key 640:enter:3"
host_keys="$front --key 860:right:3 --key 880:z:3 --key 1500:right:60 --key 1700:x:3"
guest_keys="$front --key 3000:z:3"

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
"$bin" "$rom" --join "ws://127.0.0.1:$port" --frames 30000 --until-session $ticks $guest_keys >"$dir/guest.json" 2>"$dir/guest.log" || fail "the guest failed: $(cat "$dir/guest.json") $(tail -3 "$dir/guest.log")"
wait "$host" || fail "the host failed: $(cat "$dir/host.json") $(tail -3 "$dir/host.log")"
h="$(cat "$dir/host.json")"
g="$(cat "$dir/guest.json")"
[ "$(field "$h" state_hash)" = "$(field "$g" state_hash)" ] || fail "the two processes' states differ: $h $g"
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
echo "check_netplay: two processes, the guest joined the host's round; the same state at the session's tick $ticks: $(field "$h" state_hash)"

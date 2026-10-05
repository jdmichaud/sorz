#!/bin/sh
# Network play on the real game (DESIGN.md 9, PLAN item 18), with the agent host and the user's
# ROM (its content extracted in memory by each process):
#  1. two agent hosts, two processes over WebSockets (`--netplay` and `--join`), from power-on
#     through the network variant's front end (the host's START on the intro, the title and the
#     game menu; each player's character chosen) into round 1, the host walking and striking: both
#     reach the same state, in the round, the session in play;
#  2. the same keys with the two games in one process (`--pair`): the same state as one game alone
#     with their merged pads;
#  3. a planted difference: a bit of the guest's state flipped in the round (`--corrupt`): both
#     games stop at the next state check and name the first field that differs.
set -eu
bin="${1:?usage: check_netplay.sh AGENT ROM}"
rom="${2:?usage: check_netplay.sh AGENT ROM}"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
fail() { echo "check_netplay: $*" >&2; exit 1; }
# A field of a JSON line (its last of that name).
field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }

ticks=2400
host_keys="--key 500:enter:3 --key 560:enter:3 --key 640:enter:3 --key 860:right:3 --key 880:z:3 --key 1500:right:60 --key 1700:x:3"
guest_keys="900:z:3 1600:up:30"

# 1. Two processes, a port of their own (another try on another port if it is taken).
for try in 1 2 3; do
  port=$((20000 + ($$ * 7 + try * 131) % 20000))
  # shellcheck disable=SC2086
  "$bin" "$rom" --netplay "127.0.0.1:$port" --delay 3 --frames $ticks $host_keys >"$dir/host.json" 2>"$dir/host.log" &
  host=$!
  sleep 1
  if kill -0 "$host" 2>/dev/null; then break; fi
  wait "$host" || true
  [ "$try" = 3 ] && fail "the host could not listen: $(tail -3 "$dir/host.log")"
done
set -- --frames $ticks
for k in $guest_keys; do set -- "$@" --key "$k"; done
"$bin" "$rom" --join "ws://127.0.0.1:$port" "$@" >"$dir/guest.json" 2>"$dir/guest.log" || fail "the guest failed: $(tail -3 "$dir/guest.log")"
wait "$host" || fail "the host failed: $(tail -3 "$dir/host.log")"
h="$(cat "$dir/host.json")"
g="$(cat "$dir/guest.json")"
[ "$(field "$h" state_hash)" = "$(field "$g" state_hash)" ] || fail "the two processes' states differ: $h $g"
for line in "$h" "$g"; do
  [ "$(field "$line" ticks)" = $ticks ] || fail "a game did not reach tick $ticks: $line"
  [ "$(field "$line" scene)" = round ] || fail "a game is not in the round: $line"
  [ "$(field "$line" variant)" = network ] || fail "a game is not the network variant: $line"
  [ "$(field "$line" phase)" = playing ] || fail "a session is not in play: $line"
  [ "$(field "$line" verdict)" = ok ] || fail "a game's verdict is not ok: $line"
done
echo "check_netplay: two processes, the same state in the round at tick $ticks: $(field "$h" state_hash)"

# 2. The same in one process, against one game with the merged pads.
set -- --pair --frames $ticks $host_keys
for k in $guest_keys; do set -- "$@" --guest-key "$k"; done
p="$("$bin" "$rom" "$@" 2>"$dir/pair.log")" || fail "the pair differs: $p"
[ "$(field "$p" same)" = true ] || fail "the pair differs: $p"
[ "$(field "$p" scene)" = round ] || fail "the pair is not in the round: $p"
echo "check_netplay: the pair and one game with their pads, the same state: $(field "$p" state_hash)"

# 3. A planted difference in the round: named on both sides at the next check.
c="$("$bin" "$rom" "$@" --corrupt 1650 2>"$dir/corrupt.log")" || fail "the planted difference was not named: $c"
case "$c" in
*'"difference":"random.state'*'"difference":"random.state'*) ;;
*) fail "the planted difference is not named as the random generator's: $c" ;;
esac
echo "check_netplay: a bit flipped before tick 1650 in the round, found at tick $(printf '%s\n' "$c" | sed -n 's/.*"found_at":\([0-9]*\).*/\1/p') and named on both sides: $(printf '%s\n' "$c" | sed -n 's/.*"difference":"\([^"]*\)".*/\1/p')"

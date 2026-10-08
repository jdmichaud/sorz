#!/bin/sh
# The settings record (DESIGN.md 7) through the agent host, each run with a saves directory of its
# own (never the user's, DESIGN.md 5.1):
#  1. without a record, the game has the defaults and writes nothing;
#  2. a whole record, as the game writes it, is read at the start: its settings, and nothing to
#     tell; its keys play (pad 1's Start on P: the state is the one Enter gives with the defaults);
#  3. damaged records (a damaged field, not JSON, a field missing, another version) start the
#     game with the defaults where they are damaged; the player is told (the agent host's
#     `notice`: other_version for another version's), the damaged record is kept as
#     settings-damaged.json and written back repaired, so the next start has nothing to tell.
# The settings screen that changes them is checked by the unit tests and variants-check.
set -eu
bin="${1:?usage: check_settings.sh AGENT}"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
fail() { echo "check_settings: $*" >&2; exit 1; }
# A field of the agent host's JSON line.
field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }

# 1. No record.
out="$("$bin" --saves "$dir/none" --frames 20 --key 5:enter)"
defaults="$(field "$out" settings)"
enter_state="$(field "$out" state_hash)"
[ "$(field "$out" loads)" = 0 ] || fail "a record was read where there is none: $out"
[ "$(field "$out" notice)" = none ] || fail "no record is told as damaged: $out"
[ ! -e "$dir/none/settings.json" ] || fail "the game wrote a record it was not asked to"

# 2. A whole record.
mkdir -p "$dir/kept"
cat >"$dir/kept/settings.json" <<'EOF'
{
  "version": 2,
  "players": {
    "player1": { "input": "keyboard", "keys": { "up": "up", "down": "down", "left": "left", "right": "right", "a": "z", "b": "x", "c": "c", "start": "p" }, "buttons": { "a": "x", "b": "a", "c": "b", "start": "start" }, "autofire": false },
    "player2": { "input": "keyboard", "keys": { "up": "w", "down": "s", "left": "a", "right": "d", "a": "f", "b": "g", "c": "h", "start": "tab" }, "buttons": { "a": "x", "b": "a", "c": "b", "start": "start" }, "autofire": false },
    "player3": { "input": "keyboard", "keys": { "up": "none", "down": "none", "left": "none", "right": "none", "a": "none", "b": "none", "c": "none", "start": "none" }, "buttons": { "a": "x", "b": "a", "c": "b", "start": "start" }, "autofire": false },
    "player4": { "input": "keyboard", "keys": { "up": "none", "down": "none", "left": "none", "right": "none", "a": "none", "b": "none", "c": "none", "start": "none" }, "buttons": { "a": "x", "b": "a", "c": "b", "start": "start" }, "autofire": false }
  },
  "settings_key": "f1",
  "sound": { "volume": 70, "mute": false },
  "window": { "scale": 2, "fullscreen": false },
  "rules": { "lives": 3, "continues": 3, "friendly_hit": true }
}
EOF
out="$("$bin" --saves "$dir/kept" --frames 20 --key 5:p)"
[ "$(field "$out" loads)" = 1 ] || fail "the record was not read: $out"
[ "$(field "$out" notice)" = none ] || fail "a whole record is told as damaged: $out"
[ "$(field "$out" settings)" != "$defaults" ] || fail "the record's settings are the defaults: $out"
[ "$(field "$out" state_hash)" = "$enter_state" ] || fail "P is not pad 1's Start with the record: $out"
out="$("$bin" --saves "$dir/kept" --frames 20 --key 5:enter)"
[ "$(field "$out" state_hash)" != "$enter_state" ] || fail "Enter is still pad 1's Start with the record: $out"

# 3. Damaged records.
for record in '{"version": 2, "sound": {"volume": "loud", "mute": true}}' 'not JSON' '{"version": 2}' '{"version": 1}'; do
  rm -rf "$dir/damaged"
  mkdir "$dir/damaged"
  printf '%s' "$record" >"$dir/damaged/settings.json"
  out="$("$bin" --saves "$dir/damaged" --frames 2 2>"$dir/log")" || fail "a damaged record stopped the game: $record"
  told=damaged
  [ "$record" = '{"version": 1}' ] && told=other_version
  [ "$(field "$out" notice)" = "$told" ] || fail "the player is not told of a damaged record: $out"
  grep -q "the settings record was damaged" "$dir/log" || fail "the log does not tell of the damaged record"
  [ "$(cat "$dir/damaged/settings-damaged.json")" = "$record" ] || fail "the damaged record was not kept: $record"
  out="$("$bin" --saves "$dir/damaged" --frames 2 2>/dev/null)"
  [ "$(field "$out" notice)" = none ] || fail "the player is told twice: $record: $out"
  case "$record" in
    *mute*) grep -q '"mute": true' "$dir/damaged/settings.json" || fail "the record's whole field was lost" ;;
    *) [ "$(field "$out" settings)" = "$defaults" ] || fail "a refused record does not give the defaults: $out" ;;
  esac
done
echo "check_settings: a record was read at the start and its keys played; damaged records gave the defaults, were told once and kept aside"

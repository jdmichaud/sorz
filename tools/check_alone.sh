#!/bin/sh
# Copies an executable alone into an empty directory and runs it in server mode (`DATA --server`),
# DATA being a small content tree made here, outside that directory (the user's copy of the game's
# files: no build or test needs the ROM). It must serve the page, the script and the module built
# into it, byte for byte the build's, with nothing installed beside it (DESIGN.md 1, PLAN S1),
# and the game's files from DATA: the listing `assets/manifest.json`, and each listed file under
# `assets/tree/`, the tree's own `manifest.json` among them (DESIGN.md 5.3). Needs curl.
set -eu
page="${1:?usage: check_alone.sh <page-dir> <binary>}"
bin="${2:?usage: check_alone.sh <page-dir> <binary>}"
[ -f "$bin" ] || { echo "check_alone: no such file: $bin" >&2; exit 2; }
# The build may give relative paths; the check runs in another directory.
page="$(cd "$page" && pwd)"
bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"
name="$(basename "$bin")"
dir="$(mktemp -d)"
data="$(mktemp -d)"
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$dir" "$data"' EXIT

# The fixture: a manifest of its own at the tree's root, and a file in a directory.
mkdir -p "$data/art"
printf '{"format": 1}\n' >"$data/manifest.json"
printf 'not a picture\n' >"$data/art/sheet.png"

cp "$bin" "$dir/$name"
cd "$dir"
: >log
"./$name" "$data" --server 127.0.0.1:0 2>log &
pid=$!

# The port the system gave: the start-up line says "(port N)".
port=""
i=0
while [ -z "$port" ] && [ $i -lt 100 ]; do
  port="$(sed -n 's/.*(port \([0-9][0-9]*\)).*/\1/p' log)"
  [ -n "$port" ] || sleep 0.1
  i=$((i + 1))
done
[ -n "$port" ] || { echo "check_alone: $name did not listen:" >&2; cat log >&2; exit 1; }

# GET the path into the file `got`; any status but 200 fails.
get() {
  code="$(curl -s -o got -w '%{http_code}' "http://127.0.0.1:$port$1")"
  [ "$code" = 200 ] || { echo "check_alone: $name answers $code for $1" >&2; exit 1; }
}

for f in index.html sorz.js sorz.wasm; do
  path="/$f"
  [ "$f" = index.html ] && path="/"
  get "$path"
  cmp -s got "$page/$f" || { echo "check_alone: $name serves another $f than the build's" >&2; exit 1; }
done

get /assets/manifest.json
listing='{"files":[{"name":"tree/art/sheet.png","size":14},{"name":"tree/manifest.json","size":14}]}'
[ "$(cat got)" = "$listing" ] || { echo "check_alone: $name lists the game's files as $(cat got)" >&2; exit 1; }
for f in manifest.json art/sheet.png; do
  get "/assets/tree/$f"
  cmp -s got "$data/$f" || { echo "check_alone: $name serves another $f than the data's" >&2; exit 1; }
done

echo "check_alone: $name, alone in a directory, serves its page, script and module" \
  "($(wc -c <"$page/index.html"), $(wc -c <"$page/sorz.js") and $(wc -c <"$page/sorz.wasm") bytes)" \
  "and the game's files of the data it is given"

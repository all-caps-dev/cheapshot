#!/bin/sh
# The status line reads Claude Code's status JSON on stdin (ignored) and prints one line from the ledger.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../scripts/cheapshot-statusline.sh"
fake="$here/fake-bin"
fails=0
pass() { echo "ok  $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

out=$(printf '{"model":{"display_name":"Fable"}}' | PATH="$fake:$PATH" sh "$script" 2>/dev/null)
[ "$out" = "cheapshot: 41.2k saved" ] && pass "formats thousands with one decimal" || fail "formats thousands: got '$out'"

log=$(mktemp)
printf '{}' | PATH="$fake:$PATH" FAKE_LOG="$log" sh "$script" >/dev/null 2>&1
grep -q -- '--ledger --json --days 7' "$log" && pass "asks for a 7 day window" || fail "asks for a 7 day window: $(cat "$log")"
rm -f "$log"

nobin=$(mktemp -d); ln -s "$(command -v jq)" "$nobin/jq"
out=$(printf '{}' | PATH="$nobin:/usr/bin:/bin" sh "$script" 2>/dev/null); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "missing binary prints nothing" || fail "missing binary prints nothing (code=$code out='$out')"
rm -rf "$nobin"

out=$(printf '{}' | PATH="$fake:$PATH" FAKE_EXIT=1 sh "$script" 2>/dev/null); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "binary failure prints nothing" || fail "binary failure prints nothing"

# format helper: exact under 1000, k with one decimal to 999.9k, M above
for pair in "0:0" "999:999" "1000:1.0k" "41200:41.2k" "999949:999.9k" "1500000:1.5M"; do
  n=${pair%%:*}; want=${pair##*:}
  got=$(sh "$script" --format "$n" 2>/dev/null)
  [ "$got" = "$want" ] && pass "format $n" || fail "format $n: want $want got $got"
done

echo "$fails failure(s)"
[ "$fails" = 0 ]

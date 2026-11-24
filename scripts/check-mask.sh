#!/bin/sh
# End-to-end check for `cheapshot mask` (NOV-95), POSIX sh. Renders a fake settings page with a
# fake token and phone number in headless Chrome at 2x, masks the screenshot with the binary given,
# checks by pixel sampling (never by looking) that the secret lines are fully black and normal
# lines are untouched, then runs the plugin's Read hook against the real binary: the original is
# denied with a pointer to mask, the masked copy passes once, and a second Read is denied again.
#
# Usage: scripts/check-mask.sh <path to a cheapshot binary>   (default ./cheapshot)
# Needs: Google Chrome, jq, swift. Writes only to a temp dir it removes on exit.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin=$(cd "$(dirname "${1:-./cheapshot}")" && pwd)/$(basename "${1:-./cheapshot}")
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$bin" ] || { echo "no binary at $bin"; exit 2; }
[ -x "$chrome" ] || { echo "Google Chrome not found"; exit 2; }
W=$(mktemp -d)
trap 'rm -rf "${W:?}"' EXIT
fails=0
pass() { echo "ok  $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# The fake token is assembled in the page's script so no whole token sits in this file. It is not
# a real credential. Large monospace text, like a terminal or a settings pane.
cat > "$W/page.html" <<'HTML'
<!doctype html><meta charset="utf-8">
<style>body{font:28px Menlo,monospace;margin:40px;background:#fff;color:#222} p{margin:0 0 28px}</style>
<p>Account settings</p>
<p>Display name: Demo User</p>
<p id="t"></p>
<p>Phone: (212) 555-0147</p>
<p>Theme: Dark</p>
<script>document.getElementById('t').textContent = 'API token: ' + 'ghp_' + 'Fake1234Test5678' + 'Demo9012Abcd';</script>
HTML

# Burst run, no server: a throwaway profile, one screenshot, exit.
"$chrome" --headless=new --disable-gpu --no-first-run --user-data-dir="$W/profile" \
  --force-device-scale-factor=2 --window-size=1000,520 --screenshot="$W/page.png" "file://$W/page.html" >/dev/null 2>&1
[ -s "$W/page.png" ] || { echo "Chrome wrote no screenshot"; exit 1; }

export TMPDIR="$W"   # the allow file and the default mask folder land in the temp dir
orig=$("$bin" --json --no-ledger "$W/page.png") || { echo "OCR of the original failed"; exit 1; }
echo "original redactions: $(printf '%s' "$orig" | jq -c '.results[0].redactions')"

m=$("$bin" mask --json "$W/page.png") || { echo "mask failed"; exit 1; }
masked=$(printf '%s' "$m" | jq -r '.masked')
echo "mask: $(printf '%s' "$m" | jq -c '{box_count, redactions, width, height, rounds}')"
[ -s "$masked" ] && pass "masked copy written under \$TMPDIR/cheapshot-masked" || fail "no masked copy"
case "$masked" in "$W"/cheapshot-masked/*|/private"$W"/cheapshot-masked/*) ;; *) fail "masked path outside the scratch folder: $masked";; esac

sample() { swift "$here/mask-sample.swift" "$W/page.png" "$masked" "$@"; }

# Every redacted line in the original's OCR (its text holds a [RULE] marker) is fully black.
n=0
for box in $(printf '%s' "$orig" | jq -r '.results[0].lines[] | select(.text | test("\\[[A-Z_0-9]+\\]")) | .bbox | join(",")'); do
  n=$((n + 1))
  set -- $(printf '%s' "$box" | tr ',' ' ')
  f=$(sample black "$@")
  [ "$f" = "1.0000" ] && pass "redacted line at $box is fully black" || fail "redacted line at $box is $f black"
done
[ "$n" -ge 2 ] && pass "found $n redacted lines (token and phone)" || fail "expected 2+ redacted lines, found $n"

# Normal lines are pixel-identical to the original.
for word in "Account settings" "Theme"; do
  box=$(printf '%s' "$orig" | jq -r --arg w "$word" '[.results[0].lines[] | select(.text | contains($w))][0].bbox | join(" ")')
  [ -n "$box" ] && [ "$box" != null ] || { fail "no OCR line for $word"; continue; }
  c=$(sample changed $box)
  [ "$c" = 0 ] && pass "normal line \"$word\" untouched" || fail "normal line \"$word\": $c pixels changed"
done

# A plain OCR of the masked copy finds nothing to redact.
again=$("$bin" --json --no-ledger "$masked" | jq -c '.results[0].redactions')
[ "$again" = "{}" ] && pass "re-OCR of the masked copy finds no redactions" || fail "masked copy still redacts: $again"

# The real hook, with this binary first on PATH.
hook="$here/../plugin/hooks/cheapshot-read.sh"
read_json() { printf '{"session_id":"e2e","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s"}}' "$1"; }
run_hook() { read_json "$1" | PATH="$(dirname "$bin"):$PATH" sh "$hook" 2>/dev/null; }
r=$(run_hook "$W/page.png" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
case "$r" in *"cheapshot mask "*) pass "hook denies the original and points at cheapshot mask";; *) fail "hook reason: $r";; esac
o=$(run_hook "$masked")
[ -z "$o" ] && pass "hook lets the masked copy through once" || fail "hook on masked copy: $o"
d=$(run_hook "$masked" | jq -r '.hookSpecificOutput.permissionDecision // empty')
[ "$d" = deny ] && pass "second Read of the masked copy is denied (one-shot)" || fail "second Read: $d"

echo "$fails failure(s)"
echo "rerun: sh scripts/check-mask.sh $bin"
[ "$fails" = 0 ]

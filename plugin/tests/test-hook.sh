#!/bin/sh
# Runs the hook with canned Read tool inputs against the fake binary. No Vision, no real files.
set -u
here=$(cd "$(dirname "$0")" && pwd)
hook="$here/../hooks/cheapshot-read.sh"
fake="$here/fake-bin"
fails=0
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
pass() { echo "ok  $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

fresh() {
  # New TMPDIR per case so the allowlist and the session marker never leak between cases.
  T=$(mktemp -d "$ROOT/case.XXXXXX")
  export TMPDIR="$T"
  export FAKE_LOG="$T/argv.log"
  : > "$FAKE_LOG"
}
input() {
  # $1 file_path, $2 optional pages, $3 optional session id
  if [ -n "${2:-}" ]; then
    printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s","pages":"%s"}}' "${3:-s1}" "$1" "$2"
  else
    printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s"}}' "${3:-s1}" "$1"
  fi
}
run_hook() { PATH="$fake:$PATH" sh "$hook"; }
# A PATH that has jq but no cheapshot, whatever the machine has installed.
nobin=$(mktemp -d "$ROOT/nobin.XXXXXX"); ln -s "$(command -v jq)" "$nobin/jq"
NOBIN_PATH="$nobin:/usr/bin:/bin"

# 1. a source file is not ours
fresh
out=$(input /tmp/main.swift | run_hook 2>/dev/null); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "non-image passes through" || fail "non-image passes through (code=$code out=$out)"

# 2. a png is denied with the text and the savings line, on stdout and stderr
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
out=$(input /tmp/shot.png | run_hook 2>"$err"); code=$?
dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
[ "$code" = 0 ] && [ "$dec" = deny ] && pass "png is denied" || fail "png is denied (code=$code dec=$dec)"
case "$reason" in *"hello world"*"key [AWS_KEY]"*) pass "reason carries the redacted text";; *) fail "reason carries the redacted text";; esac
line='cheapshot: 1018 image tokens -> 37 text tokens. If you need the pixels for layout, run: cheapshot allow /tmp/shot.png, then Read again.'
case "$reason" in *"$line") pass "reason ends with the savings line";; *) fail "reason ends with the savings line: $reason";; esac
grep -qF "$line" "$err" && pass "savings line on stderr" || fail "savings line on stderr"
grep -q -- '--json --stats /tmp/shot.png' "$FAKE_LOG" && pass "binary called with --json --stats" || fail "binary called with --json --stats: $(cat "$FAKE_LOG")"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" = PreToolUse ] && pass "hookEventName set" || fail "hookEventName set"
# Ruling 1: the deny also carries a top-level systemMessage with the savings line (stderr on exit 0 is not shown).
[ "$(printf '%s' "$out" | jq -r '.systemMessage')" = "$line" ] && pass "deny carries systemMessage with the savings line" || fail "deny carries systemMessage: $(printf '%s' "$out" | jq -c '.systemMessage')"

# 3. every extension in the list is ours, case-insensitive
fresh
for e in jpg JPEG webp gif PNG; do
  dec=$(input "/tmp/x.$e" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
  [ "$dec" = deny ] && pass "extension $e" || fail "extension $e"
done

# 4. passthrough env
fresh
out=$(input /tmp/shot.png | CHEAPSHOT_PASSTHROUGH=1 run_hook 2>/dev/null); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "CHEAPSHOT_PASSTHROUGH=1 passes through" || fail "CHEAPSHOT_PASSTHROUGH=1 passes through"

# 5. binary missing: pass through (no decision), one hint per session on stdout (systemMessage) and stderr
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
out=$(input /tmp/shot.png | PATH="$NOBIN_PATH" sh "$hook" 2>"$err"); code=$?
dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput // empty')
[ "$code" = 0 ] && [ -z "$dec" ] && pass "missing binary passes through" || fail "missing binary passes through (code=$code out=$out)"
grep -q 'brew install all-caps-dev/tap/cheapshot' "$err" && pass "missing binary hint names brew" || fail "missing binary hint names brew"
# Ruling 2: the hint is also a systemMessage on stdout, exit 0, no decision.
msg=$(printf '%s' "$out" | jq -r '.systemMessage // empty')
case "$msg" in *"brew install all-caps-dev/tap/cheapshot"*) pass "missing binary emits systemMessage";; *) fail "missing binary emits systemMessage: $out";; esac
err2=$(mktemp "$ROOT/err.XXXXXX")
out2=$(input /tmp/shot.png | PATH="$NOBIN_PATH" sh "$hook" 2>"$err2")
[ ! -s "$err2" ] && [ -z "$out2" ] && pass "hint printed once per session" || fail "hint printed once per session"
err3=$(mktemp "$ROOT/err.XXXXXX")
out3=$(input /tmp/shot.png "" s2 | PATH="$NOBIN_PATH" sh "$hook" 2>"$err3")
[ -s "$err3" ] && [ -n "$out3" ] && pass "new session gets the hint again" || fail "new session gets the hint again"

# 6. allowlist: a live entry is consumed once, an expired entry is ignored
fresh
now=$(date +%s)
printf '%s\t/tmp/shot.png\n%s\t/tmp/other.png\n' "$((now + 200))" "$((now + 200))" > "$TMPDIR/cheapshot-allow"
out=$(input /tmp/shot.png | run_hook 2>/dev/null)
[ -z "$out" ] && pass "allowed path passes through" || fail "allowed path passes through"
grep -q '/tmp/shot.png' "$TMPDIR/cheapshot-allow" && fail "entry consumed" || pass "entry consumed"
grep -q '/tmp/other.png' "$TMPDIR/cheapshot-allow" && pass "other entries kept" || fail "other entries kept"
dec=$(input /tmp/shot.png | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "second Read is denied again" || fail "second Read is denied again"
printf '%s\t/tmp/shot.png\n' "$((now - 10))" > "$TMPDIR/cheapshot-allow"
dec=$(input /tmp/shot.png | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "expired entry is ignored" || fail "expired entry is ignored"
grep -q '/tmp/shot.png' "$TMPDIR/cheapshot-allow" && fail "expired entry dropped from the file" || pass "expired entry dropped from the file"

# 6b. allowlist last line without a trailing newline is honoured
fresh
now=$(date +%s)
printf '%s\t/tmp/other.png\n%s\t/tmp/shot.png' "$((now + 200))" "$((now + 200))" > "$TMPDIR/cheapshot-allow"
out=$(input /tmp/shot.png | run_hook 2>/dev/null)
[ -z "$out" ] && pass "allow entry without trailing newline passes through" || fail "allow entry without trailing newline passes through"
grep -q '/tmp/shot.png' "$TMPDIR/cheapshot-allow" && fail "unterminated entry consumed" || pass "unterminated entry consumed"
grep -q '/tmp/other.png' "$TMPDIR/cheapshot-allow" && pass "other entry kept alongside it" || fail "other entry kept alongside it"

# 6c. an entry standardised to /tmp/x matches a Read of /private/tmp/x (Task 3 strips /private)
fresh
now=$(date +%s)
printf '%s\t/tmp/x.png\n' "$((now + 200))" > "$TMPDIR/cheapshot-allow"
out=$(input /private/tmp/x.png | run_hook 2>/dev/null)
[ -z "$out" ] && pass "/private prefix: allowed /tmp path passes through" || fail "/private prefix: allowed /tmp path passes through"
grep -q '/tmp/x.png' "$TMPDIR/cheapshot-allow" && fail "/private prefix: entry consumed" || pass "/private prefix: entry consumed"
dec=$(input /private/tmp/x.png | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "/private prefix: second Read denied again" || fail "/private prefix: second Read denied again"

# 7. pdf with pages: passed as --pages, denied with text
fresh
dec=$(input /tmp/report.pdf 3-5 | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "pdf with pages is denied" || fail "pdf with pages is denied"
grep -q -- '--pages 3-5 /tmp/report.pdf' "$FAKE_LOG" && pass "pages forwarded as --pages" || fail "pages forwarded: $(cat "$FAKE_LOG")"

# 8. pdf without pages: small one is denied, big one passes through with a hint
fresh
dec=$(input /tmp/report.pdf | FAKE_PAGES=5 run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "5 page pdf is denied" || fail "5 page pdf is denied"
grep -q -- '--json --no-ledger --pages 1-1 /tmp/report.pdf' "$FAKE_LOG" && pass "page count probed with --pages 1-1" || fail "page count probed: $(cat "$FAKE_LOG")"
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
out=$(input /tmp/report.pdf | FAKE_PAGES=42 run_hook 2>"$err")
dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput // empty')
[ -z "$dec" ] && pass "42 page pdf passes through" || fail "42 page pdf passes through: $out"
grep -q 'pages' "$err" && grep -q '42' "$err" && pass "big pdf hint names the page count and pages" || fail "big pdf hint: $(cat "$err")"
grep -q -- '--json --stats' "$FAKE_LOG" && fail "big pdf never fully run" || pass "big pdf never fully run"
# Ruling 2: the hint is a systemMessage on stdout and names the Bash escape hatch.
msg=$(printf '%s' "$out" | jq -r '.systemMessage // empty')
case "$msg" in *"42"*"--pages 1-5 /tmp/report.pdf"*) pass "big pdf systemMessage names --pages 1-5";; *) fail "big pdf systemMessage: $out";; esac

# 9. binary failure passes through with a stderr line
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
out=$(input /tmp/shot.png | FAKE_EXIT=1 run_hook 2>"$err"); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "binary failure passes through" || fail "binary failure passes through"
grep -q 'cheapshot' "$err" && pass "failure reported on stderr" || fail "failure reported on stderr"

# 9b. binary exits 0 with output that is not the JSON shape: pass through with a stderr line
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
out=$(input /tmp/shot.png | FAKE_RAW='not json' run_hook 2>"$err"); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "non-JSON output passes through" || fail "non-JSON output passes through (code=$code out=$out)"
grep -q 'unreadable output' "$err" && pass "non-JSON output reported on stderr" || fail "non-JSON output reported on stderr: $(cat "$err")"
fresh
out=$(input /tmp/shot.png | FAKE_RAW='' run_hook 2>/dev/null); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "empty output passes through" || fail "empty output passes through (code=$code out=$out)"

# 9c. binary exits 0 with no recognised text: pass through, the pixels are the content
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
out=$(input /tmp/shot.png | FAKE_EMPTY_TEXT=1 run_hook 2>"$err"); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "empty text passes through" || fail "empty text passes through (code=$code out=$out)"
grep -qF 'cheapshot: no text in /tmp/shot.png, reading it as pixels.' "$err" && pass "empty text reported on stderr" || fail "empty text reported on stderr: $(cat "$err")"

# 10. no file_path at all
fresh
out=$(printf '{"session_id":"s1","tool_name":"Read","tool_input":{}}' | run_hook 2>/dev/null); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "missing file_path passes through" || fail "missing file_path passes through"

# 10b. session id with path characters is sanitised into the marker name
fresh
out=$(input /tmp/shot.png "" '../../evil id' | PATH="$NOBIN_PATH" sh "$hook" 2>/dev/null)
[ -n "$out" ] && [ -e "$TMPDIR/cheapshot-missing-.._.._evil_id" ] && pass "marker name sanitised" || fail "marker name sanitised: $(ls "$TMPDIR")"

# 11. Ruling 3: the hook runs as an executable (no leading sh) from a plugin root that has a space,
# invoked the way hooks.json may spell it: "${CLAUDE_PLUGIN_ROOT}"/hooks/cheapshot-read.sh and unquoted.
fresh
root=$(mktemp -d "$T/plugin root.XXXXXX")
mkdir -p "$root/hooks" && cp "$hook" "$root/hooks/cheapshot-read.sh" && chmod +x "$root/hooks/cheapshot-read.sh"
dec=$(input /tmp/shot.png | CLAUDE_PLUGIN_ROOT="$root" PATH="$fake:$PATH" sh -c '"${CLAUDE_PLUGIN_ROOT}"/hooks/cheapshot-read.sh' 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "executable via quoted CLAUDE_PLUGIN_ROOT with a space" || fail "executable via quoted CLAUDE_PLUGIN_ROOT with a space (dec=$dec)"
root2=$(mktemp -d "$T/pluginroot.XXXXXX")
mkdir -p "$root2/hooks" && cp "$hook" "$root2/hooks/cheapshot-read.sh" && chmod +x "$root2/hooks/cheapshot-read.sh"
dec=$(input /tmp/shot.png | CLAUDE_PLUGIN_ROOT="$root2" PATH="$fake:$PATH" sh -c '${CLAUDE_PLUGIN_ROOT}/hooks/cheapshot-read.sh' 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "executable via unquoted CLAUDE_PLUGIN_ROOT" || fail "executable via unquoted CLAUDE_PLUGIN_ROOT (dec=$dec)"

echo "$fails failure(s)"
[ "$fails" = 0 ]

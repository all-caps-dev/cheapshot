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
# Octal permission bits of a file, on GNU (CI runs on Linux) or BSD/macOS stat. BSD `stat -f`
# means "filesystem status" on Linux, so try GNU's `-c` first.
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
denied() {
  # $1 label; $o holds the hook output (captured by the caller, not piped in, so this runs in
  # the main shell and a failure is counted).
  [ "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // empty')" = deny ] && pass "$1 is denied" || fail "$1 is denied: $o"
}
# NOV-160 (Ryan, 2026-11-25: "Block in default too"): a failed OCR run on an image is denied in
# every mode. The user is told how to fix it; the model is told neither the fix nor the allow.
fail_closed() {
  # $1 label; $o holds the hook output; $2 a string the user message must contain
  denied "$1"
  r=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
  m=$(printf '%s' "$o" | jq -r '.systemMessage // empty')
  case "$m" in *"$2"*) pass "$1: user message says how to fix it";; *) fail "$1: user message lacks '$2': $m";; esac
  case "$r" in *"cheapshot allow"*|*"brew "*|*"CHEAPSHOT_PASSTHROUGH"*) fail "$1: model reason names a fix or bypass: $r";; *) pass "$1: model reason names no fix or bypass";; esac
  grep -q -- '--note-passthrough' "$FAKE_LOG" && fail "$1: a deny is not a pass-through" || pass "$1: not recorded as a pass-through"
}
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
line="cheapshot: 1018 image tokens -> 37 text tokens. If you need the layout, run in Bash: cheapshot mask '/tmp/shot.png', then Read the path it prints after \"masked: \" (a copy with redacted and low-confidence lines blacked out). The raw pixels still need the user's approval."
user_line="cheapshot: 1018 image tokens -> 37 text tokens. To show the agent the pixels, run in a terminal: cheapshot allow '/tmp/shot.png'"
case "$reason" in *"$line") pass "reason ends with the savings line";; *) fail "reason ends with the savings line: $reason";; esac
# Fleet #290 item 3: the model is never told how to approve its own raw access.
case "$reason" in *"cheapshot allow"*) fail "reason must not name cheapshot allow";; *) pass "reason does not name cheapshot allow";; esac
grep -qF "$user_line" "$err" && pass "user savings line on stderr" || fail "user savings line on stderr"
grep -q -- '--json --stats /tmp/shot.png' "$FAKE_LOG" && pass "binary called with --json --stats" || fail "binary called with --json --stats: $(cat "$FAKE_LOG")"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" = PreToolUse ] && pass "hookEventName set" || fail "hookEventName set"
# Ruling 1: the deny also carries a top-level systemMessage with the savings line (stderr on exit 0 is not shown).
[ "$(printf '%s' "$out" | jq -r '.systemMessage')" = "$user_line" ] && pass "deny carries systemMessage with the user's allow command" || fail "deny carries systemMessage: $(printf '%s' "$out" | jq -c '.systemMessage')"

# 3. every extension in the list is ours, case-insensitive
fresh
for e in jpg JPEG webp gif PNG heic HEIF tif tiff bmp; do
  dec=$(input "/tmp/x.$e" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
  [ "$dec" = deny ] && pass "extension $e" || fail "extension $e"
done

# 4. passthrough env
fresh
out=$(input /tmp/shot.png | CHEAPSHOT_PASSTHROUGH=1 run_hook 2>/dev/null); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "CHEAPSHOT_PASSTHROUGH=1 passes through" || fail "CHEAPSHOT_PASSTHROUGH=1 passes through"
grep -qx -- '--note-passthrough passthrough_env' "$FAKE_LOG" && pass "passthrough env recorded in the ledger" || fail "passthrough env recorded: $(cat "$FAKE_LOG")"

# 5. binary missing. An image is denied every time, in default mode too (NOV-160), and the user
# message names the brew install and CHEAPSHOT_PASSTHROUGH (an allow entry needs the binary).
fresh
o=$(input /tmp/shot.png | PATH="$NOBIN_PATH" sh "$hook" 2>/dev/null); fail_closed "missing binary, image" "brew install all-caps-dev/tap/cheapshot"
case "$(printf '%s' "$o" | jq -r '.systemMessage')" in *"CHEAPSHOT_PASSTHROUGH=1"*) pass "missing binary, image: names the session bypass";; *) fail "missing binary bypass: $o";; esac
o=$(input /tmp/shot.png | PATH="$NOBIN_PATH" sh "$hook" 2>/dev/null); denied "missing binary, second image Read"
# A PDF keeps the old default: pass through, one hint per session on stdout (systemMessage) and stderr.
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
out=$(input /tmp/report.pdf | PATH="$NOBIN_PATH" sh "$hook" 2>"$err"); code=$?
dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput // empty')
[ "$code" = 0 ] && [ -z "$dec" ] && pass "missing binary passes through" || fail "missing binary passes through (code=$code out=$out)"
grep -q 'brew install all-caps-dev/tap/cheapshot' "$err" && pass "missing binary hint names brew" || fail "missing binary hint names brew"
# Ruling 2: the hint is also a systemMessage on stdout, exit 0, no decision.
msg=$(printf '%s' "$out" | jq -r '.systemMessage // empty')
case "$msg" in *"brew install all-caps-dev/tap/cheapshot"*) pass "missing binary emits systemMessage";; *) fail "missing binary emits systemMessage: $out";; esac
err2=$(mktemp "$ROOT/err.XXXXXX")
out2=$(input /tmp/report.pdf | PATH="$NOBIN_PATH" sh "$hook" 2>"$err2")
[ ! -s "$err2" ] && [ -z "$out2" ] && pass "hint printed once per session" || fail "hint printed once per session"
err3=$(mktemp "$ROOT/err.XXXXXX")
out3=$(input /tmp/report.pdf "" s2 | PATH="$NOBIN_PATH" sh "$hook" 2>"$err3")
[ -s "$err3" ] && [ -n "$out3" ] && pass "new session gets the hint again" || fail "new session gets the hint again"

# 6. allowlist: a live entry is consumed once, an expired entry is ignored. A plain (hashless)
# entry is honoured for a PDF only (PR #19 review), so the plain-entry cases use a PDF.
fresh
now=$(date +%s)
printf '%s\t/tmp/shot.pdf\n%s\t/tmp/other.pdf\n' "$((now + 200))" "$((now + 200))" > "$TMPDIR/cheapshot-allow"
out=$(input /tmp/shot.pdf | run_hook 2>/dev/null)
[ -z "$out" ] && pass "allowed path passes through" || fail "allowed path passes through"
grep -qx -- '--note-passthrough allow' "$FAKE_LOG" && pass "allow recorded in the ledger" || fail "allow recorded: $(cat "$FAKE_LOG")"
grep -q '/tmp/shot.pdf' "$TMPDIR/cheapshot-allow" && fail "entry consumed" || pass "entry consumed"
grep -q '/tmp/other.pdf' "$TMPDIR/cheapshot-allow" && pass "other entries kept" || fail "other entries kept"
dec=$(input /tmp/shot.pdf | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "second Read is denied again" || fail "second Read is denied again"
printf '%s\t/tmp/shot.pdf\n' "$((now - 10))" > "$TMPDIR/cheapshot-allow"
dec=$(input /tmp/shot.pdf | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "expired entry is ignored" || fail "expired entry is ignored"
grep -q '/tmp/shot.pdf' "$TMPDIR/cheapshot-allow" && fail "expired entry dropped from the file" || pass "expired entry dropped from the file"

# 6m. NOV-95 / PR #18: a mask entry carries the SHA-256 of the masked copy. The exact copy
# passes; a file swapped in after mask, or a symlink, is denied and the entry is used up.
fresh
now=$(date +%s)
m="$TMPDIR/masked.png"; printf 'masked-bytes' > "$m"
sum=$(shasum -a 256 "$m" | cut -d' ' -f1)
printf '%s\t%s\t%s\n' "$((now + 200))" "$m" "$sum" > "$TMPDIR/cheapshot-allow"
out=$(input "$m" | run_hook 2>/dev/null)
# NOV-117: the Read is rewritten to a fresh copy whose hash was checked, not the path as named.
dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
f=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.file_path // empty')
[ "$dec" = allow ] && [ -n "$f" ] && [ "$f" != "$m" ] && pass "mask entry: the unchanged copy is allowed via a fresh copy" || fail "mask entry: unchanged copy: $out"
case "$f" in "$TMPDIR"/cheapshot-read.*/masked.png) pass "mask entry: fresh copy sits in a private cheapshot-read folder";; *) fail "mask entry: fresh copy path $f";; esac
[ "$(cat "$f" 2>/dev/null)" = masked-bytes ] && pass "mask entry: fresh copy holds the hashed bytes" || fail "mask entry: fresh copy bytes"
[ "$(mode "$(dirname "$f")")" = 700 ] && pass "mask entry: fresh folder is 0700" || fail "mask entry: fresh folder mode $(mode "$(dirname "$f")")"
# Swapping the source after the hook ran changes nothing the Read sees (the check-to-Read race).
printf 'swapped-later' > "$m"
[ "$(cat "$f")" = masked-bytes ] && pass "mask entry: a later swap of the source does not reach the Read" || fail "mask entry: later swap reached the fresh copy"
printf 'masked-bytes' > "$m"
printf '%s\t%s\t%s\n' "$((now + 200))" "$m" "$sum" > "$TMPDIR/cheapshot-allow"
printf 'raw-secret-bytes' > "$m"
dec=$(input "$m" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "mask entry: a file swapped in after mask is denied" || fail "mask entry: swapped file denied (dec=$dec)"
grep -q "$m" "$TMPDIR/cheapshot-allow" && fail "mask entry: tampered entry used up" || pass "mask entry: tampered entry used up"
printf 'masked-bytes' > "$TMPDIR/real.png"; ln -sf "$TMPDIR/real.png" "$TMPDIR/link.png"
printf '%s\t%s\t%s\n' "$((now + 200))" "$TMPDIR/link.png" "$sum" > "$TMPDIR/cheapshot-allow"
dec=$(input "$TMPDIR/link.png" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "mask entry: a symlink is denied even when its target hashes right" || fail "mask entry: symlink denied (dec=$dec)"

# 6s. NOV-117: `cheapshot allow` of an image writes a stripped copy and a four-field entry
# "<exp>\t<original>\t<sha256 of copy>\t<copy>". A Read of the original is rewritten to a fresh
# copy of the stripped copy; the original's bytes (and its EXIF) never reach the Read.
fresh
now=$(date +%s)
orig="$TMPDIR/IMG_0001.jpg"; printf 'original-with-gps-exif' > "$orig"
mkdir -p "$TMPDIR/cheapshot-allowed"; c="$TMPDIR/cheapshot-allowed/IMG_0001-allowed.png"; printf 'stripped-pixels' > "$c"
csum=$(shasum -a 256 "$c" | cut -d' ' -f1)
printf '%s\t%s\t%s\t%s\n%s\t/tmp/other.png\n' "$((now + 200))" "$orig" "$csum" "$c" "$((now + 200))" > "$TMPDIR/cheapshot-allow"
out=$(printf '{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"%s","offset":3,"limit":9}}' "$orig" | run_hook 2>/dev/null)
dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
f=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.file_path // empty')
[ "$dec" = allow ] && pass "image allow: Read of the original is allowed" || fail "image allow: decision $out"
[ "$(cat "$f" 2>/dev/null)" = stripped-pixels ] && pass "image allow: the Read is pointed at the stripped bytes" || fail "image allow: rewritten path $f"
case "$f" in "$orig"|"$c") fail "image allow: Read must not name the original or the reusable copy: $f";; *) pass "image allow: Read names a fresh copy, not the original";; esac
[ "$(printf '%s' "$out" | jq -c '.hookSpecificOutput.updatedInput | {offset, limit}')" = '{"offset":3,"limit":9}' ] && pass "image allow: other Read fields are kept" || fail "image allow: fields $out"
grep -qx -- '--note-passthrough allow' "$FAKE_LOG" && pass "image allow: recorded in the ledger" || fail "image allow: ledger $(cat "$FAKE_LOG")"
grep -q "$orig" "$TMPDIR/cheapshot-allow" && fail "image allow: entry consumed" || pass "image allow: entry consumed"
grep -q '/tmp/other.png' "$TMPDIR/cheapshot-allow" && pass "image allow: other entries kept" || fail "image allow: other entries kept"
[ ! -e "$c" ] && pass "image allow: the allow copy is deleted once its entry is used" || fail "image allow: allow copy left on disk"
[ "$(mode "$f")" = 600 ] && pass "image allow: the fresh copy is 0600" || fail "image allow: fresh copy mode $(mode "$f")"
dec=$(input "$orig" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "image allow: second Read is denied again" || fail "image allow: second Read ($dec)"
# A Read naming the copy itself matches the same entry.
printf 'stripped-pixels' > "$c"
printf '%s\t%s\t%s\t%s\n' "$((now + 200))" "$orig" "$csum" "$c" > "$TMPDIR/cheapshot-allow"
f=$(input "$c" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.updatedInput.file_path // empty')
[ "$(cat "$f" 2>/dev/null)" = stripped-pixels ] && pass "image allow: a Read of the copy path also matches" || fail "image allow: copy path read ($f)"
# A copy changed after allow is refused, the entry used up, and the Read denied as usual.
printf '%s\t%s\t%s\t%s\n' "$((now + 200))" "$orig" "$csum" "$c" > "$TMPDIR/cheapshot-allow"
printf 'tampered' > "$c"
dec=$(input "$orig" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "image allow: a changed copy is denied" || fail "image allow: changed copy ($dec)"
[ -s "$TMPDIR/cheapshot-allow" ] && fail "image allow: tampered entry used up" || pass "image allow: tampered entry used up"
[ ! -e "$c" ] && pass "image allow: a tampered copy is deleted" || fail "image allow: tampered copy left on disk"
ls -d "$TMPDIR"/cheapshot-read.* >/dev/null 2>&1 && [ "$(ls -d "$TMPDIR"/cheapshot-read.* | wc -l | tr -d ' ')" = 2 ] && pass "image allow: a refused copy leaves no fresh folder" || fail "image allow: fresh folders $(ls -d "$TMPDIR"/cheapshot-read.* 2>/dev/null)"
# A missing copy is refused too, never a fall-back to the original.
printf '%s\t%s\t%s\t%s\n' "$((now + 200))" "$orig" "$csum" "$TMPDIR/nope.png" > "$TMPDIR/cheapshot-allow"
dec=$(input "$orig" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "image allow: a missing copy is denied" || fail "image allow: missing copy ($dec)"
# An expired entry's copy is deleted; a forged entry cannot delete a file outside cheapshot-allowed.
printf 'stripped-pixels' > "$c"; printf 'keep-me' > "$TMPDIR/precious.png"
printf '%s\t%s\t%s\t%s\n%s\t%s\t%s\t%s\n' "$((now - 10))" "$orig" "$csum" "$c" "$((now - 10))" "$orig" "$csum" "$TMPDIR/precious.png" > "$TMPDIR/cheapshot-allow"
input /tmp/shot.png | run_hook >/dev/null 2>&1
[ ! -e "$c" ] && pass "image allow: an expired entry's copy is deleted" || fail "image allow: expired copy left on disk"
[ -e "$TMPDIR/precious.png" ] && pass "image allow: a forged copy path outside cheapshot-allowed is never deleted" || fail "image allow: forged entry deleted a file"
# Fresh folders are removed on any later run once over 2 minutes old; a new one is kept.
old=$(mktemp -d "$TMPDIR/cheapshot-read.XXXXXX"); touch -t 202601010000 "$old"
new=$(mktemp -d "$TMPDIR/cheapshot-read.XXXXXX")
rm -f "$TMPDIR/cheapshot-allow"
input /tmp/shot.png | run_hook >/dev/null 2>&1
[ ! -d "$old" ] && pass "image allow: fresh folders over 2 minutes old are removed, even with no allow file" || fail "image allow: old fresh folder kept"
[ -d "$new" ] && pass "image allow: a just-made fresh folder is kept for its Read" || fail "image allow: new fresh folder removed"

# 6t. macOS sets TMPDIR with a trailing slash; the binary writes the copy path without the double slash.
fresh
now=$(date +%s)
mkdir -p "$TMPDIR/cheapshot-allowed"; c="$TMPDIR/cheapshot-allowed/x-allowed.png"; printf 'p' > "$c"
printf '%s\t/tmp/x.png\tabc\t%s\n' "$((now - 10))" "$c" > "$TMPDIR/cheapshot-allow"
input /tmp/shot.png | TMPDIR="$TMPDIR/" run_hook >/dev/null 2>&1
[ ! -e "$c" ] && pass "trailing-slash TMPDIR: the expired copy is still deleted" || fail "trailing-slash TMPDIR: copy left"

# 6h. NOV-117 review: the hook intercepts every type `allow` strips, so an allowed HEIC Read is
# rewritten to its stripped copy instead of passing the original (and its GPS) through.
fresh
now=$(date +%s)
heic="$TMPDIR/IMG_0002.HEIC"; printf 'heic-with-gps' > "$heic"
mkdir -p "$TMPDIR/cheapshot-allowed"; hc="$TMPDIR/cheapshot-allowed/IMG_0002-allowed.png"; printf 'heic-stripped' > "$hc"
printf '%s\t%s\t%s\t%s\n' "$((now + 200))" "$heic" "$(shasum -a 256 "$hc" | cut -d' ' -f1)" "$hc" > "$TMPDIR/cheapshot-allow"
f=$(input "$heic" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.updatedInput.file_path // empty')
[ "$(cat "$f" 2>/dev/null)" = heic-stripped ] && pass "heic: an allowed HEIC Read is rewritten to the stripped copy" || fail "heic: rewritten path ($f)"
dec=$(input "$heic" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "heic: a HEIC Read with no allow is denied with text, not passed raw" || fail "heic: no-allow Read ($dec)"

# 6p. PR #19 review: a plain (hashless) entry for an image, as an older binary writes, is not
# honoured: the original would pass with its metadata. The Read gets the redacted deny, and the
# entry is used up.
fresh
now=$(date +%s)
printf '%s\t/tmp/shot.png\n' "$((now + 200))" > "$TMPDIR/cheapshot-allow"
out=$(input /tmp/shot.png | run_hook 2>/dev/null)
dec=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')
[ "$dec" = deny ] && pass "plain image entry: Read gets the redacted deny" || fail "plain image entry denied (dec=$dec)"
case "$(printf '%s' "$out" | jq -r '.systemMessage')" in *"older cheapshot binary"*) pass "plain image entry: user told the binary is old";; *) fail "plain image entry: old-binary notice: $out";; esac
grep -q '/tmp/shot.png' "$TMPDIR/cheapshot-allow" && fail "plain image entry used up" || pass "plain image entry used up"

# 6b. allowlist last line without a trailing newline is honoured
fresh
now=$(date +%s)
printf '%s\t/tmp/other.pdf\n%s\t/tmp/shot.pdf' "$((now + 200))" "$((now + 200))" > "$TMPDIR/cheapshot-allow"
out=$(input /tmp/shot.pdf | run_hook 2>/dev/null)
[ -z "$out" ] && pass "allow entry without trailing newline passes through" || fail "allow entry without trailing newline passes through"
grep -q '/tmp/shot.pdf' "$TMPDIR/cheapshot-allow" && fail "unterminated entry consumed" || pass "unterminated entry consumed"
grep -q '/tmp/other.pdf' "$TMPDIR/cheapshot-allow" && pass "other entry kept alongside it" || fail "other entry kept alongside it"

# 6c. an entry standardised to /tmp/x matches a Read of /private/tmp/x (Task 3 strips /private)
fresh
now=$(date +%s)
printf '%s\t/tmp/x.pdf\n' "$((now + 200))" > "$TMPDIR/cheapshot-allow"
out=$(input /private/tmp/x.pdf | run_hook 2>/dev/null)
[ -z "$out" ] && pass "/private prefix: allowed /tmp path passes through" || fail "/private prefix: allowed /tmp path passes through"
grep -q '/tmp/x.pdf' "$TMPDIR/cheapshot-allow" && fail "/private prefix: entry consumed" || pass "/private prefix: entry consumed"
dec=$(input /private/tmp/x.pdf | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
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

# 9. binary failure on an image: denied in default mode too (NOV-160), the reason and the fix on
# stderr and in the systemMessage, nothing recorded as a pass-through
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
o=$(input /tmp/shot.png | FAKE_EXIT=1 run_hook 2>"$err"); fail_closed "binary failure, image" "cheapshot allow '/tmp/shot.png'"
case "$(printf '%s' "$o" | jq -r '.systemMessage')" in *"could not read /tmp/shot.png (exit 1)"*"brew reinstall all-caps-dev/tap/cheapshot"*) pass "binary failure: user message names the exit code and the reinstall";; *) fail "binary failure user message: $o";; esac
grep -q 'could not read /tmp/shot.png (exit 1)' "$err" && pass "failure reported on stderr" || fail "failure reported on stderr: $(cat "$err")"
# A PDF keeps the old default: the failure passes through, visible and recorded.
fresh
out=$(input /tmp/report.pdf 1-2 | FAKE_EXIT=1 run_hook 2>/dev/null); code=$?
[ "$code" = 0 ] && [ -z "$(printf '%s' "$out" | jq -r '.hookSpecificOutput // empty')" ] && pass "binary failure on a PDF passes through" || fail "binary failure on a PDF: $out"
case "$(printf '%s' "$out" | jq -r '.systemMessage // empty')" in *"could not read /tmp/report.pdf (exit 1)"*) pass "PDF failure is a visible systemMessage";; *) fail "PDF failure systemMessage: $out";; esac
grep -qx -- '--note-passthrough error' "$FAKE_LOG" && pass "PDF failure recorded in the ledger" || fail "PDF failure recorded: $(cat "$FAKE_LOG")"

# 9b. binary exits 0 with output that is not the JSON shape: an image is denied in default mode
# too (NOV-160), with a stderr line
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
o=$(input /tmp/shot.png | FAKE_RAW='not json' run_hook 2>"$err"); fail_closed "non-JSON output" "cheapshot allow '/tmp/shot.png'"
grep -q 'unreadable output' "$err" && pass "non-JSON output reported on stderr" || fail "non-JSON output reported on stderr: $(cat "$err")"
fresh
o=$(input /tmp/shot.png | FAKE_RAW='' run_hook 2>/dev/null); fail_closed "empty output" "cheapshot allow '/tmp/shot.png'"
fresh
o=$(input /tmp/shot.png | FAKE_RAW='{"version":"0.6.0","results":[{"file":"/tmp/shot.png","text":"hel' run_hook 2>/dev/null); fail_closed "truncated JSON" "cheapshot allow '/tmp/shot.png'"
fresh
o=$(input /tmp/shot.png | FAKE_RAW='{"version":"0.6.0","results":{"text":"hello"}}' run_hook 2>/dev/null); fail_closed "results not an array" "cheapshot allow '/tmp/shot.png'"
# A PDF keeps the old default for unreadable output.
fresh
out=$(input /tmp/report.pdf 1-2 | FAKE_RAW='not json' run_hook 2>/dev/null)
[ -z "$(printf '%s' "$out" | jq -r '.hookSpecificOutput // empty')" ] && pass "non-JSON output on a PDF passes through" || fail "non-JSON PDF: $out"

# 9c. NOV-160: the binary says the image read empty without a retry (ocr_status "empty",
# retried false): a photo or a small image, so the pixels are the content. Pass through, recorded.
# (Before NOV-160 this case used FAKE_EMPTY_TEXT, which has no ocr_status: see 9d-b for that now.)
ocr_result() {
  # $1 ocr_status JSON value, $2 retried JSON value, $3 text (JSON-escaped), $4 screenshot_like
  printf '{"version":"0.6.0","results":[{"file":"/tmp/shot.png","text":"%s","redactions":{},"image_tokens":1018,"text_tokens":%s,"lines":[],"ocr_status":%s,"retried":%s,"screenshot_like":%s}],"image_tokens":1018,"text_tokens":%s}' \
    "$3" "${#3}" "$1" "$2" "${4:-true}" "${#3}"
}
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
out=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"empty"' false '' false)" run_hook 2>"$err"); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "empty text (photo, not retried) passes through" || fail "empty text passes through (code=$code out=$out)"
grep -qF 'cheapshot: no text in /tmp/shot.png, reading it as pixels.' "$err" && pass "empty text reported on stderr" || fail "empty text reported on stderr: $(cat "$err")"
grep -qx -- '--note-passthrough no_text' "$FAKE_LOG" && pass "empty text recorded in the ledger" || fail "empty text recorded: $(cat "$FAKE_LOG")"

# 9d. NOV-160: OCR that is still empty after the cold-start retry must never fall through to the
# pixel path. Deny in every mode, tell the user about `cheapshot allow` and `cheapshot mask`, and
# never tell the model how to approve its own raw access.
# 9d-a. empty + retried: a screenshot that still read blank
fresh
err=$(mktemp "$ROOT/err.XXXXXX")
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"empty"' true '')" run_hook 2>"$err"); denied "empty + retried"
reason=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
msg=$(printf '%s' "$o" | jq -r '.systemMessage // empty')
case "$reason" in *"no text"*"retry"*) pass "empty + retried: reason says OCR read nothing after a retry";; *) fail "empty + retried reason: $reason";; esac
case "$reason" in *"cheapshot allow"*|*"cheapshot mask"*) fail "empty + retried: reason must not name allow or mask";; *) pass "empty + retried: reason names neither allow nor mask";; esac
case "$reason" in *"Read it once more"*) fail "empty + retried: reason must not invite a re-Read: $reason";; *) pass "empty + retried: reason does not invite a re-Read";; esac
case "$msg" in *"cheapshot allow '/tmp/shot.png'"*) pass "empty + retried: user message names cheapshot allow, quoted";; *) fail "empty + retried user message lacks allow: $msg";; esac
case "$msg" in *"cheapshot mask '/tmp/shot.png'"*) pass "empty + retried: user message names cheapshot mask";; *) fail "empty + retried user message lacks mask: $msg";; esac
grep -qF "$msg" "$err" && pass "empty + retried: user message also on stderr" || fail "empty + retried stderr: $(cat "$err")"
grep -q -- '--note-passthrough' "$FAKE_LOG" && fail "empty + retried: a deny is not a pass-through" || pass "empty + retried: not recorded as a pass-through"
fresh
o=$(input /tmp/shot.png | CHEAPSHOT_STRICT=1 FAKE_RAW="$(ocr_result '"empty"' true '')" run_hook 2>/dev/null); denied "strict: empty + retried"
# 9d-b. an older binary (no ocr_status, no retried) with empty text: it cannot say whether OCR
# failed, so the hook keeps the pixels out and asks for an update or a person's allow.
fresh
o=$(input /tmp/shot.png | FAKE_EMPTY_TEXT=1 run_hook 2>/dev/null); denied "older binary, empty text"
msg=$(printf '%s' "$o" | jq -r '.systemMessage // empty')
case "$msg" in *"does not report ocr_status (added in v0.6.0)"*"cheapshot allow '/tmp/shot.png'"*) pass "older binary: user message says update or allow";; *) fail "older binary user message: $msg";; esac
# Dev builds that call themselves 0.6.0 lack the fields too, so the message makes no version claim.
case "$msg" in *"older than"*) fail "older binary: message must not claim a version: $msg";; *) pass "older binary: message makes no version claim";; esac
grep -q -- '--note-passthrough' "$FAKE_LOG" && fail "older binary: a deny is not a pass-through" || pass "older binary: not recorded as a pass-through"
# An older binary that found text is unchanged: the redacted text, no flag (test 2 covers the rest).
fresh
o=$(input /tmp/shot.png | run_hook 2>/dev/null)
case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in "hello world"*) pass "older binary with text is unchanged";; *) fail "older binary with text: $o";; esac
# 9d-c. short + retried. The binary keeps the longer pass and reports "ok"; the text is there and
# redacted, so the Read is still denied with it, plus a flag that lines may be missing.
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"ok"' true 'hello')" run_hook 2>/dev/null); denied "short + retried (ok)"
reason=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
msg=$(printf '%s' "$o" | jq -r '.systemMessage // empty')
case "$reason" in "hello"*"may be missing"*) pass "short + retried: text plus a may-be-missing flag for the model";; *) fail "short + retried reason: $reason";; esac
case "$msg" in *"may be missing"*) pass "short + retried: the user sees the flag too";; *) fail "short + retried user message: $msg";; esac
# A status this hook does not know (a future "short", say) with text: denied with the text, flagged.
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"short"' true 'hello')" run_hook 2>/dev/null); denied "unknown status with text"
case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in "hello"*"may be missing"*) pass "unknown status with text is flagged";; *) fail "unknown status flag: $o";; esac
# Unknown status with no text: denied, never pixels.
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"short"' true '')" run_hook 2>/dev/null); denied "unknown status, empty text"
# 9d-d. ok, not retried: exactly the old deny, no flag
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"ok"' false 'hello world')" run_hook 2>/dev/null)
reason=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')
[ "$reason" = "hello world

cheapshot: 1018 image tokens -> 11 text tokens. If you need the layout, run in Bash: cheapshot mask '/tmp/shot.png', then Read the path it prints after \"masked: \" (a copy with redacted and low-confidence lines blacked out). The raw pixels still need the user's approval." ] && pass "ok: deny reason is unchanged" || fail "ok reason: $reason"
[ "$(printf '%s' "$o" | jq -r '.systemMessage')" = "cheapshot: 1018 image tokens -> 11 text tokens. To show the agent the pixels, run in a terminal: cheapshot allow '/tmp/shot.png'" ] && pass "ok: user message is unchanged" || fail "ok user message: $o"
# "ok" with empty text contradicts itself: denied.
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"ok"' false '')" run_hook 2>/dev/null); denied "ok status with empty text"
# 9d-e. malformed: wrong types, non-object results, an empty results array. Each is denied when
# there is no text; none may reach the pixel path.
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result 5 '"yes"' '')" run_hook 2>/dev/null); denied "malformed field types, empty text"
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result 'null' true '')" run_hook 2>/dev/null); denied "null ocr_status, empty text"
fresh
o=$(input /tmp/shot.png | FAKE_RAW='{"version":"0.6.0","results":[1],"image_tokens":0,"text_tokens":0}' run_hook 2>/dev/null); denied "non-object result"
fresh
o=$(input /tmp/shot.png | FAKE_RAW='{"version":"0.6.0","results":[],"image_tokens":0,"text_tokens":0}' run_hook 2>/dev/null); denied "empty results array"
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result 5 '"yes"' 'hello')" run_hook 2>/dev/null); denied "malformed field types with text"
case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in "hello"*"may be missing"*) pass "malformed fields with text are flagged";; *) fail "malformed fields flag: $o";; esac
# Output that is not JSON at all is the failure path (test 9b): denied for an image in every mode.
# 9d-g. NOV-160 review: "blank" (a photo) needs text "" and, when the field is there,
# screenshot_like false. Anything else that reads empty is denied.
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"empty"' false '' true)" run_hook 2>/dev/null); denied "empty, not retried, but screenshot_like"
fresh
o=$(input /tmp/shot.png | FAKE_RAW='{"version":"0.6.0","results":[{"file":"/tmp/shot.png","redactions":{},"image_tokens":1018,"text_tokens":0,"lines":[],"ocr_status":"empty","retried":false,"screenshot_like":false}],"image_tokens":1018,"text_tokens":0}' run_hook 2>/dev/null); denied "photo result with no text field"
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"empty"' false '\n' false)" run_hook 2>/dev/null); denied "photo result whose text is only a newline"
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(ocr_result '"empty"' false '' null)" run_hook 2>/dev/null); denied "empty, not retried, screenshot_like null"
fresh
# No screenshot_like field at all (allowed absent): a photo still passes.
o=$(input /tmp/shot.png | FAKE_RAW='{"version":"0.6.0","results":[{"file":"/tmp/shot.png","text":"","redactions":{},"image_tokens":1018,"text_tokens":0,"lines":[],"ocr_status":"empty","retried":false}],"image_tokens":1018,"text_tokens":0}' run_hook 2>/dev/null)
[ -z "$o" ] && grep -qx -- '--note-passthrough no_text' "$FAKE_LOG" && pass "photo without screenshot_like still passes" || fail "photo without screenshot_like: $o"
# 9d-h. one field without the other: denied when empty
fresh
o=$(input /tmp/shot.png | FAKE_RAW='{"version":"0.6.0","results":[{"file":"/tmp/shot.png","text":"","image_tokens":1018,"text_tokens":0,"ocr_status":"empty"}],"image_tokens":1018,"text_tokens":0}' run_hook 2>/dev/null); denied "ocr_status without retried"
fresh
o=$(input /tmp/shot.png | FAKE_RAW='{"version":"0.6.0","results":[{"file":"/tmp/shot.png","text":"","image_tokens":1018,"text_tokens":0,"retried":false}],"image_tokens":1018,"text_tokens":0}' run_hook 2>/dev/null); denied "retried without ocr_status"
# 9d-i. several results: a photo passes only when every result is a photo
photo='{"file":"/tmp/a.png","text":"","image_tokens":1018,"text_tokens":0,"ocr_status":"empty","retried":false,"screenshot_like":false}'
blank='{"file":"/tmp/b.png","text":"","image_tokens":1018,"text_tokens":0,"ocr_status":"empty","retried":true,"screenshot_like":true}'
okr='{"file":"/tmp/c.png","text":"hello","image_tokens":1018,"text_tokens":5,"ocr_status":"ok","retried":false,"screenshot_like":true}'
fresh
o=$(input /tmp/shot.png | FAKE_RAW="{\"results\":[$photo,$photo],\"image_tokens\":2036,\"text_tokens\":0}" run_hook 2>/dev/null)
[ -z "$o" ] && pass "multi-result: all photos pass through" || fail "multi-result all photos: $o"
fresh
o=$(input /tmp/shot.png | FAKE_RAW="{\"results\":[$photo,$blank],\"image_tokens\":2036,\"text_tokens\":0}" run_hook 2>/dev/null); denied "multi-result: photo plus blank-after-retry"
fresh
o=$(input /tmp/shot.png | FAKE_RAW="{\"results\":[$okr,$blank],\"image_tokens\":2036,\"text_tokens\":5}" run_hook 2>/dev/null); denied "multi-result: text plus blank-after-retry"
case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in "hello"*"may be missing"*) pass "multi-result: text plus blank-after-retry is flagged";; *) fail "multi-result flag: $o";; esac
# 9d-j. a single quote in the path: the allow and mask commands in the user message stay pasteable
fresh
qshot="/tmp/it's here.png"
o=$(input "$qshot" | FAKE_RAW="$(ocr_result '"empty"' true '')" run_hook 2>/dev/null); denied "single-quote path, blank after retry"
msg=$(printf '%s' "$o" | jq -r '.systemMessage')
a=${msg#*cheapshot allow }; a=${a%% (or cheapshot mask*}
eval "set -- $a"
[ "$#" = 1 ] && [ "$1" = "$qshot" ] && pass "single-quote path: allow command is shell-quoted" || fail "single-quote allow quoting: $msg"
m=${msg#*cheapshot mask }; m=${m%% for a copy*}
eval "set -- $m"
[ "$#" = 1 ] && [ "$1" = "$qshot" ] && pass "single-quote path: mask command is shell-quoted" || fail "single-quote mask quoting: $msg"
# 9d-f. PDFs carry no ocr_status: an empty PDF result keeps the old pass-through.
fresh
o=$(input /tmp/report.pdf 1-2 | FAKE_RAW='{"version":"0.6.0","results":[{"file":"/tmp/report.pdf","text":"","redactions":{},"image_tokens":2200,"text_tokens":0,"source":{"path":"/tmp/report.pdf","sha256":"ab12","pages":2},"pages":[]}],"image_tokens":2200,"text_tokens":0}' run_hook 2>/dev/null)
[ -z "$o" ] && grep -qx -- '--note-passthrough no_text' "$FAKE_LOG" && pass "empty PDF text still passes through" || fail "empty PDF: $o $(cat "$FAKE_LOG")"
# A PDF with text is never flagged: it has no ocr_status by design.
fresh
o=$(input /tmp/report.pdf 3-5 | run_hook 2>/dev/null)
case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in *"may be missing"*) fail "PDF with text is flagged: $o";; *) pass "PDF with text is not flagged";; esac

# 10. no file_path at all
fresh
out=$(printf '{"session_id":"s1","tool_name":"Read","tool_input":{}}' | run_hook 2>/dev/null); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "missing file_path passes through" || fail "missing file_path passes through"

# 10b. session id with path characters is sanitised into the marker name
fresh
out=$(input /tmp/report.pdf "" '../../evil id' | PATH="$NOBIN_PATH" sh "$hook" 2>/dev/null)
[ -n "$out" ] && [ -e "$TMPDIR/cheapshot-missing-.._.._evil_id" ] && pass "marker name sanitised" || fail "marker name sanitised: $(ls "$TMPDIR")"

# 10c. Fleet #15 review: a model-supplied path that starts with "-" would parse as a flag.
# NOV-160 (Ryan: "fail closed everywhere"): it no longer passes as pixels. The hook hands it to
# the binary after "--" (end of options, cheapshot 0.6.0), so it is read and redacted like any
# other path, and is never recorded as a pass-through.
fresh
o=$(input "-dash.png" | run_hook 2>/dev/null); denied "dash path"
case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in "hello world"*) pass "dash path: the redacted text comes back";; *) fail "dash path text: $o";; esac
grep -qx -- "--json --stats -- $PWD/-dash.png" "$FAKE_LOG" && pass "dash path: binary called with -- before the path" || fail "dash path argv: $(cat "$FAKE_LOG")"
grep -q -- '--note-passthrough' "$FAKE_LOG" && fail "dash path: not a pass-through" || pass "dash path: not recorded as a pass-through"
# An older binary rejects "--" (exit 2, unknown option): that is a failed run, denied for an image.
fresh
o=$(input "-dash.png" | FAKE_EXIT=2 FAKE_STDERR='cheapshot: unknown option --' run_hook 2>/dev/null); denied "dash path, binary rejects --"
# PR #21 review: the user is told to update, not reinstall; the model is told neither.
case "$(printf '%s' "$o" | jq -r '.systemMessage')" in *"brew upgrade all-caps-dev/tap/cheapshot"*) pass "dash path, old binary: user told to update";; *) fail "dash path old binary message: $o";; esac
case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in *brew*|*"cheapshot allow"*) fail "dash path old binary: model reason names a fix: $o";; *) pass "dash path, old binary: model reason names no fix";; esac
# Pre-push review: the commands printed for the user spell a dash path absolute (from the
# working directory), since `allow` has no "--" form and refuses an argument that starts with "-".
case "$(printf '%s' "$o" | jq -r '.systemMessage')" in *"cheapshot allow '$PWD/-dash.png'"*) pass "dash path: user's allow command is absolute";; *) fail "dash path allow command: $o";; esac
# The absolute entry `cheapshot allow` writes for that command matches a Read of the relative path.
fresh
printf '%s\t%s\n' "$(($(date +%s) + 200))" "$PWD/-dash.pdf" > "$TMPDIR/cheapshot-allow"
out=$(input "-dash.pdf" | run_hook 2>/dev/null)
[ -z "$out" ] && grep -qx -- '--note-passthrough allow' "$FAKE_LOG" && pass "dash path: absolute allow entry matches" || fail "dash path allow entry: $out $(cat "$FAKE_LOG")"
fresh
o=$(input "-dash.png" | run_hook 2>/dev/null)
case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in *"cheapshot mask '$PWD/-dash.png'"*) pass "dash path: model's mask command is absolute";; *) fail "dash path mask command: $o";; esac
# Pre-push review: a missing image ("no such file", the real binary's message, and no file) is
# not a broken install. The Read runs and reports the missing file; one that exists but will not
# decode stays denied.
fresh
o=$(input "$T/missing.png" | FAKE_EXIT=1 FAKE_STDERR="cheapshot: no such file $T/missing.png" run_hook 2>/dev/null)
[ "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // empty')" = "" ] && pass "missing image: the Read runs" || fail "missing image: the Read runs: $o"
# PR #21 review: a relative path missing from the hook's $PWD but present in the session's .cwd
# (where Read resolves it) is a real image: denied, not passed as pixels.
fresh
mkdir "$T/sess"; : > "$T/sess/real.png"
o=$(printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"real.png"}}' "$T/sess" \
  | FAKE_EXIT=1 FAKE_STDERR="cheapshot: no such file real.png" run_hook 2>/dev/null); denied "relative image present only in .cwd"
# PR #21 second review: OCR reads the copy Read will open (.cwd), not the hook's $PWD copy.
fresh
o=$(printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"x.png"}}' "$T/sess" | run_hook 2>/dev/null)
grep -qx -- "--json --stats $T/sess/x.png" "$FAKE_LOG" && pass "relative path: binary reads the .cwd copy" || fail "relative path argv: $(cat "$FAKE_LOG")"
# The dash path's printed commands and allowlist match use .cwd too.
fresh
o=$(printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"-dash.png"}}' "$T" | run_hook 2>/dev/null)
case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in *"cheapshot mask '$T/-dash.png'"*) pass "dash path: mask command uses .cwd";; *) fail "dash path .cwd mask command: $o";; esac
fresh
: > "$T/corrupt.png"
o=$(input "$T/corrupt.png" | FAKE_EXIT=1 FAKE_STDERR="cheapshot: cannot read $T/corrupt.png" run_hook 2>/dev/null); denied "undecodable image that exists"
# A normal path is called exactly as before, with no "--", so older binaries keep working.
fresh
o=$(input /tmp/shot.png | run_hook 2>/dev/null)
grep -qx -- '--json --stats /tmp/shot.png' "$FAKE_LOG" && pass "normal path: argv unchanged, no --" || fail "normal path argv: $(cat "$FAKE_LOG")"
# PDFs: the page-count probe and the page-range run both put "--" before a dash path.
fresh
o=$(input "-r.pdf" | FAKE_PAGES=3 run_hook 2>/dev/null)
grep -qx -- "--json --no-ledger --pages 1-1 -- $PWD/-r.pdf" "$FAKE_LOG" && grep -qx -- "--json --stats -- $PWD/-r.pdf" "$FAKE_LOG" && pass "dash PDF: probe and run use --" || fail "dash PDF argv: $(cat "$FAKE_LOG")"
fresh
o=$(input "-r.pdf" 2-3 | run_hook 2>/dev/null)
grep -qx -- "--json --stats --pages 2-3 -- $PWD/-r.pdf" "$FAKE_LOG" && pass "dash PDF with pages: run uses --" || fail "dash PDF pages argv: $(cat "$FAKE_LOG")"

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

# 12. Fleet #290 item 4: CHEAPSHOT_STRICT=1 denies on every failure instead of passing pixels through.
strict_denies() {
  # $1 label; $o holds the hook output. The caller captures it first (o=$(...); strict_denies),
  # since piping into this function ran it in a subshell where a failure was never counted.
  [ "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // empty')" = deny ] && pass "strict: $1 is denied" || fail "strict: $1 is denied: $o"
}
fresh
o=$(input /tmp/shot.png | CHEAPSHOT_STRICT=1 FAKE_EXIT=1 run_hook 2>/dev/null); strict_denies "binary failure"
grep -q -- '--note-passthrough' "$FAKE_LOG" && fail "strict: a deny is not a pass-through" || pass "strict: a deny is not recorded as a pass-through"
fresh
o=$(input /tmp/shot.png | CHEAPSHOT_STRICT=1 FAKE_RAW='not json' run_hook 2>/dev/null); strict_denies "non-JSON output"
fresh
o=$(input /tmp/report.pdf | CHEAPSHOT_STRICT=1 FAKE_PAGES=42 run_hook 2>/dev/null); strict_denies "PDF over the page cap"
fresh
o=$(input /tmp/shot.png | CHEAPSHOT_STRICT=1 PATH="$NOBIN_PATH" sh "$hook" 2>/dev/null); strict_denies "missing binary"
fresh
# No jq on PATH (/bin has cat but no jq): strict still denies an image Read and leaves a source file alone.
# A PATH holding only symlinks to the tools the hook needs, so no jq is reachable even where /bin
# is /usr/bin (Ubuntu) and jq is installed there.
nojq=$(mktemp -d "$ROOT/nojq.XXXXXX")
for t in cat tr date mktemp mv rm cut; do ln -s "$(command -v "$t")" "$nojq/$t"; done
o=$(input /tmp/shot.PNG | CHEAPSHOT_STRICT=1 PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
case "$o" in *'"permissionDecision":"deny"'*) pass "strict: missing jq denies an image";; *) fail "strict: missing jq denies an image: $o";; esac
o=$(input /tmp/main.swift | CHEAPSHOT_STRICT=1 PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
[ -z "$o" ] && pass "strict: missing jq leaves a source file alone" || fail "strict: missing jq leaves a source file alone: $o"
# NOV-160: missing jq is a broken install, so an image is denied in default mode too. Without jq
# the image is told apart by the file_path extension in the raw hook JSON (pattern match).
o=$(input /tmp/shot.png | PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
case "$o" in *'"permissionDecision":"deny"'*) pass "default: missing jq denies an image";; *) fail "default: missing jq denies an image: $o";; esac
case "$o" in *'"systemMessage":"'*'brew install jq'*'CHEAPSHOT_PASSTHROUGH=1'*) pass "default: missing jq user message names brew install jq and the session bypass";; *) fail "missing jq user message: $o";; esac
r=${o#*permissionDecisionReason\":\"}; r=${r%%\"*}
case "$r" in *brew*|*CHEAPSHOT_PASSTHROUGH*|*"cheapshot allow"*) fail "missing jq: model reason names a fix or bypass: $r";; "$o") fail "missing jq: no reason found: $o";; *) pass "missing jq: model reason names no fix or bypass";; esac
o=$(printf '%s' '{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/tmp/a\"b.JPEG"}}' | PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
case "$o" in *'"permissionDecision":"deny"'*) pass "default: missing jq denies an image with a quote in its name";; *) fail "default missing jq, quoted name: $o";; esac
o=$(input /tmp/report.pdf | PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
[ -z "$o" ] && pass "default: missing jq still passes a PDF through" || fail "default: missing jq, PDF: $o"
o=$(input /tmp/report.pdf | CHEAPSHOT_STRICT=1 PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
case "$o" in *'"permissionDecision":"deny"'*) pass "strict: missing jq denies a PDF";; *) fail "strict: missing jq, PDF: $o";; esac
o=$(input /tmp/main.swift | PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
[ -z "$o" ] && pass "default: missing jq leaves a source file alone" || fail "default: missing jq, source file: $o"
o=$(input /tmp/shot.png | CHEAPSHOT_PASSTHROUGH=1 PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
[ -z "$o" ] && pass "default: missing jq still honours CHEAPSHOT_PASSTHROUGH=1" || fail "default: missing jq ignored passthrough: $o"
o=$(input /tmp/shot.png | CHEAPSHOT_STRICT=1 CHEAPSHOT_PASSTHROUGH=1 PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
[ -z "$o" ] && pass "strict: missing jq still honours CHEAPSHOT_PASSTHROUGH=1" || fail "strict: missing jq ignored passthrough: $o"
o=$(printf '%s' '{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/tmp/a\"b.png"}}' | CHEAPSHOT_STRICT=1 PATH="$nojq" /bin/sh "$hook" 2>/dev/null)
case "$o" in *'"permissionDecision":"deny"'*) pass "strict: missing jq denies a name with a quote";; *) fail "strict: missing jq, quoted name: $o";; esac
fresh
# The human overrides still work in strict mode.
o=$(input /tmp/shot.png | CHEAPSHOT_STRICT=1 CHEAPSHOT_PASSTHROUGH=1 run_hook 2>/dev/null)
[ -z "$o" ] && pass "strict: CHEAPSHOT_PASSTHROUGH=1 still passes through" || fail "strict: passthrough env: $o"
now=$(date +%s)
printf '%s\t/tmp/shot.pdf\n' "$((now + 200))" > "$TMPDIR/cheapshot-allow"
o=$(input /tmp/shot.pdf | CHEAPSHOT_STRICT=1 run_hook 2>/dev/null)
[ -z "$o" ] && pass "strict: an allow entry still passes through" || fail "strict: allow entry: $o"
fresh
# A path starting with "-" is denied in strict mode too, and reaches the binary only after "--".
o=$(input "-dash.png" | CHEAPSHOT_STRICT=1 run_hook 2>/dev/null)
[ "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // empty')" = deny ] && pass "strict: dash path is denied" || fail "strict: dash path is denied: $o"
grep -qx -- "--json --stats -- $PWD/-dash.png" "$FAKE_LOG" && pass "strict: dash path reaches the binary only after --" || fail "strict: dash path argv: $(cat "$FAKE_LOG")"
fresh
# A good read is unchanged by strict mode.
dec=$(input /tmp/shot.png | CHEAPSHOT_STRICT=1 run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$dec" in *"hello world"*) pass "strict: a good read still returns the text";; *) fail "strict: good read: $dec";; esac

# 13. The allow command in the user's message is shell-quoted: spaces and U+202F survive a paste.
fresh
shot="/tmp/Screenshot 2026-11-20 at 10.00.00$(printf '\342\200\257')AM.png"
msg=$(input "$shot" | run_hook 2>/dev/null | jq -r '.systemMessage')
q=${msg#*cheapshot allow }
eval "set -- $q"
[ "$#" = 1 ] && [ "$1" = "$shot" ] && pass "allow command is shell-quoted (space, U+202F)" || fail "allow command quoting: $msg"

# 13b. NOV-95: the model's copy names `cheapshot mask` with the same shell quoting, so the agent can
# run it from Bash; a PDF (mask does images only) keeps the ask-the-user line.
reason=$(input "$shot" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason')
q=${reason#*cheapshot mask }
q=${q%%, then Read*}
eval "set -- $q"
[ "$#" = 1 ] && [ "$1" = "$shot" ] && pass "mask command is shell-quoted (space, U+202F)" || fail "mask command quoting: $reason"
fresh
reason=$(input /tmp/report.pdf "1-2" | run_hook 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason" in *"cheapshot mask"*) fail "pdf reason must not offer mask: $reason";; *"ask the user to approve it."*) pass "pdf keeps the ask-the-user line";; *) fail "pdf line: $reason";; esac

# 14. A broken rules file named by CHEAPSHOT_RULES denies even in default mode.
fresh
o=$(input /tmp/shot.png | FAKE_EXIT=2 FAKE_STDERR='cheapshot: cannot read rules file /x.json: missing' run_hook 2>/dev/null)
[ "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // empty')" = deny ] && pass "broken named rules file denies in default mode" || fail "broken rules: $o"
o=$(input /tmp/shot.png | FAKE_EXIT=2 run_hook 2>/dev/null); denied "other exit 2 on an image, default mode"
o=$(input /tmp/report.pdf 1-2 | FAKE_EXIT=2 run_hook 2>/dev/null)
[ -z "$(printf '%s' "$o" | jq -r '.hookSpecificOutput // empty')" ] && pass "other exit 2 on a PDF still fails open in default mode" || fail "other exit 2 PDF: $o"

# 15. CS-03: the result shape, not the file name, decides PDF. A PDF result carries
# .source.pages; an image result does not. A x.pdf holding an image gets the NOV-160 checks;
# a .png holding a PDF result is handled as a PDF.
pdfshape() {
  # $1 text (JSON-escaped), $2 page count for .source.pages. A PDF result: source.pages, no
  # ocr_status, like the real binary writes.
  printf '{"version":"0.6.0","results":[{"file":"/tmp/doc","text":"%s","redactions":{},"image_tokens":2200,"text_tokens":%s,"source":{"path":"/tmp/doc","sha256":"ab12","pages":%s},"pages":[]}],"image_tokens":2200,"text_tokens":%s}' \
    "$1" "${#1}" "$2" "${#1}"
}
# 15a. a file named .pdf whose result is an image result: ocr_status "" (unknown) and
# retried true, no text. The NOV-160 empty-image deny applies; never the pixel path.
fresh
o=$(input /tmp/x.pdf | FAKE_RAW="$(ocr_result '""' true '')" run_hook 2>/dev/null); denied "x.pdf with an image result, unknown status, empty"
reason=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
case "$reason" in *"cheapshot allow"*|*"cheapshot mask"*) fail "x.pdf image result: deny reason names allow or mask: $reason";; *) pass "x.pdf image result: deny reason names neither allow nor mask";; esac
grep -q -- '--note-passthrough' "$FAKE_LOG" && fail "x.pdf image result: a deny is not a pass-through" || pass "x.pdf image result: not recorded as a pass-through"
# 15b. a real PDF result (has .source.pages) that read empty keeps the PDF pass-through, in
# default mode and in strict mode.
fresh
o=$(input /tmp/x.pdf | FAKE_RAW="$(pdfshape '' 3)" run_hook 2>/dev/null)
[ -z "$o" ] && grep -qx -- '--note-passthrough no_text' "$FAKE_LOG" && pass "empty PDF result passes through" || fail "empty PDF result: $o $(cat "$FAKE_LOG")"
fresh
o=$(input /tmp/x.pdf | CHEAPSHOT_STRICT=1 FAKE_RAW="$(pdfshape '' 3)" run_hook 2>/dev/null)
[ -z "$o" ] && grep -qx -- '--note-passthrough no_text' "$FAKE_LOG" && pass "strict: empty PDF result still passes through" || fail "strict empty PDF result: $o $(cat "$FAKE_LOG")"
# 15c. a .PNG whose result carries .source.pages is a PDF result: the shape decides. Empty
# passes as pixels; with text the deny carries the PDF ask-the-user line, never mask.
fresh
o=$(input /tmp/shot.PNG | FAKE_RAW="$(pdfshape '' 3)" run_hook 2>/dev/null)
[ -z "$o" ] && grep -qx -- '--note-passthrough no_text' "$FAKE_LOG" && pass ".PNG with a PDF result and no text passes through" || fail ".PNG with a PDF result, empty: $o $(cat "$FAKE_LOG")"
fresh
o=$(input /tmp/shot.png | FAKE_RAW="$(pdfshape 'hello' 3)" run_hook 2>/dev/null); denied ".PNG with a PDF result and text"
reason=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
case "$reason" in *"ask the user to approve it.") pass ".PNG with a PDF result: PDF ask-the-user line";; *) fail ".PNG with a PDF result line: $reason";; esac
case "$reason" in *"cheapshot mask"*) fail ".PNG with a PDF result: reason must not offer mask: $reason";; *) pass ".PNG with a PDF result: no mask in the reason";; esac

echo "$fails failure(s)"
[ "$fails" = 0 ]

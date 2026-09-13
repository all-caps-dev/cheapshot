#!/bin/sh
# cheapshot PreToolUse hook for Read. Input: the hook JSON on stdin. Output: nothing (let the
# Read proceed), a {"systemMessage": ...} hint with no decision (still proceeds), or a deny
# decision whose reason is the redacted text plus one savings line. The savings line also goes
# out as a top-level systemMessage, since stderr on exit 0 is not shown to the user.
# Every exit is 0: a hook failure must never block a Read. Needs jq.
set -u
input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$path" ] || exit 0
ext=$(printf '%s' "${path##*.}" | tr 'A-Z' 'a-z')
case "$ext" in png|jpg|jpeg|webp|gif|pdf) ;; *) exit 0 ;; esac

[ "${CHEAPSHOT_PASSTHROUGH:-0}" = "1" ] && exit 0

tmp="${TMPDIR:-/tmp}"
sid=$(printf '%s' "$input" | jq -r '.session_id // "nosession"' | tr -c 'A-Za-z0-9._-\n' '_')

# A hint that lets the Read proceed: one line on stderr, the same text as systemMessage on stdout.
hint() {
  echo "$1" >&2
  jq -n --arg m "$1" '{systemMessage: $m}'
}

if ! command -v cheapshot >/dev/null 2>&1; then
  marker="$tmp/cheapshot-missing-$sid"
  if [ ! -e "$marker" ]; then
    : > "$marker"
    hint "cheapshot: binary not found, reading $path as pixels. Install it: brew install all-caps-dev/tap/cheapshot"
  fi
  exit 0
fi

# One-shot allowlist written by `cheapshot allow <path>`: "<expiry epoch>\t<path>" per line.
# Expired lines are dropped; the first live match for this path is consumed. `cheapshot allow`
# standardises paths, which strips a leading /private, while Read may pass /private/tmp/...,
# so an entry also matches the path with that prefix removed.
allow="$tmp/cheapshot-allow"
if [ -f "$allow" ]; then
  alt="$path"
  case "$path" in /private/*) alt="${path#/private}" ;; esac
  now=$(date +%s)
  keep=$(mktemp "$tmp/cheapshot-allow.XXXXXX")
  hit=0
  tab=$(printf '\t')
  while IFS="$tab" read -r exp p || [ -n "$exp" ]; do
    [ "$exp" -ge "$now" ] 2>/dev/null || continue
    if [ "$hit" = 0 ] && { [ "$p" = "$path" ] || [ "$p" = "$alt" ]; }; then hit=1; continue; fi
    printf '%s\t%s\n' "$exp" "$p" >> "$keep"
  done < "$allow"
  mv "$keep" "$allow"
  [ "$hit" = 1 ] && exit 0
fi

pages=$(printf '%s' "$input" | jq -r '.tool_input.pages // empty')
if [ "$ext" = pdf ] && [ -z "$pages" ]; then
  # Cheap probe: one page, no ledger line, just to learn the page count.
  probe=$(cheapshot --json --no-ledger --pages 1-1 "$path" 2>/dev/null) || exit 0
  count=$(printf '%s' "$probe" | jq -r '.results[0].source.pages // 0')
  if [ "$count" -gt 20 ] 2>/dev/null; then
    hint "cheapshot: $path has $count pages, reading it as-is. For redacted text of a range, Read it with pages (for example pages: \"1-5\") or run from Bash: cheapshot --pages 1-5 $path"
    exit 0
  fi
fi

if [ -n "$pages" ]; then
  out=$(cheapshot --json --stats --pages "$pages" "$path" 2>/dev/null)
else
  out=$(cheapshot --json --stats "$path" 2>/dev/null)
fi
code=$?
if [ "$code" != 0 ]; then
  echo "cheapshot: could not read $path (exit $code), reading it as pixels instead." >&2
  exit 0
fi

printf '%s' "$out" | jq -e '.results | type == "array"' >/dev/null 2>&1 || {
  echo "cheapshot: unreadable output for $path, reading it as pixels instead." >&2
  exit 0
}

text=$(printf '%s' "$out" | jq -r '[.results[] | .text // empty] | join("\n")')
if [ -z "$text" ]; then
  # Nothing recognised: there are no tokens to save, the pixels are the content.
  echo "cheapshot: no text in $path, reading it as pixels." >&2
  exit 0
fi
it=$(printf '%s' "$out" | jq -r '.image_tokens // 0')
tt=$(printf '%s' "$out" | jq -r '.text_tokens // 0')
line="cheapshot: $it image tokens -> $tt text tokens. If you need the pixels for layout, run: cheapshot allow $path, then Read again."
echo "$line" >&2
jq -n --arg text "$text" --arg line "$line" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: ($text + "\n\n" + $line)}, systemMessage: $line}'
exit 0

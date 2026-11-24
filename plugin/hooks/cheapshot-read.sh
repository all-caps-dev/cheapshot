#!/bin/sh
# cheapshot PreToolUse hook for Read (POSIX sh). Input: the hook JSON on stdin. Output: nothing
# (let the Read proceed), a {"systemMessage": ...} hint with no decision (still proceeds), or a
# deny decision whose reason is the redacted text plus one savings line. The savings line also
# goes out as a top-level systemMessage, since stderr on exit 0 is not shown to the user.
#
# Every exit is 0. By default a failure lets the Read through (fail open) and says so in a
# systemMessage. With CHEAPSHOT_STRICT=1 a failure denies the Read instead (fail closed), so
# pixels never reach the model unless a person chose that (CHEAPSHOT_PASSTHROUGH=1 for the
# session, or `cheapshot allow <path>` from a terminal) or the image has no text to redact
# (Fleet #290 item 4). A broken rules file named by $CHEAPSHOT_RULES denies in both modes:
# passing the pixels would skip the built-in redaction as well as the custom rules. (A broken
# default rules.json never gets here: the binary warns and keeps its built-in rules.)
#
# Every pass-through of an image or PDF is recorded in the ledger as a zero-token line with a
# reason and no path (`cheapshot --note-passthrough <reason>`). Needs jq.
set -u
input=$(cat)
strict=0
[ "${CHEAPSHOT_STRICT:-0}" = "1" ] && strict=1

if ! command -v jq >/dev/null 2>&1; then
  # No jq means no JSON parsing. In strict mode, still refuse image and PDF Reads, found with a
  # plain pattern match, so a missing tool cannot become a silent bypass. Static JSON only.
  # CHEAPSHOT_PASSTHROUGH=1 is still honoured; a `cheapshot allow` entry is not, since matching
  # it needs the parsed path (the deny message says to install jq).
  [ "${CHEAPSHOT_PASSTHROUGH:-0}" = "1" ] && exit 0
  # The path pattern allows JSON escapes (\" and friends), so a quote in a file name cannot
  # end the match early and slip past the deny.
  if [ "$strict" = 1 ] && printf '%s' "$input" | /usr/bin/grep -Eiq '"file_path" *: *"([^"\\]|\\.)*\.(png|jpe?g|webp|gif|pdf)"'; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"cheapshot: jq is missing, so this image was not read (CHEAPSHOT_STRICT=1). Tell the user."},"systemMessage":"cheapshot: jq is missing; strict mode denied an image Read. Install it: brew install jq"}'
  fi
  exit 0
fi

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$path" ] || exit 0
ext=$(printf '%s' "${path##*.}" | tr 'A-Z' 'a-z')
case "$ext" in png|jpg|jpeg|webp|gif|pdf) ;; *) exit 0 ;; esac

tmp="${TMPDIR:-/tmp}"
sid=$(printf '%s' "$input" | jq -r '.session_id // "nosession"' | tr -c 'A-Za-z0-9._\n-' '_')

# A hint that lets the Read proceed: one line on stderr, the same text as systemMessage on stdout.
hint() {
  echo "$1" >&2
  jq -n --arg m "$1" '{systemMessage: $m}'
}

# A deny: $1 is what the model sees, $2 what the user sees.
deny() {
  echo "$2" >&2
  jq -n --arg r "$1" --arg m "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, systemMessage: $m}'
}

# Record a pass-through in the ledger. Best effort: an older binary rejects the flag (exit 2),
# and a missing binary cannot record anything.
note() {
  command -v cheapshot >/dev/null 2>&1 && cheapshot --note-passthrough "$1" >/dev/null 2>&1
  return 0
}

# The binary's stderr, kept so a failure can be told apart: a broken rules file must never fail open.
errf=$(mktemp "$tmp/cheapshot-err.XXXXXX") || errf=/dev/null
trap '[ "$errf" = /dev/null ] || rm -f "$errf"' EXIT

# A failure: deny in strict mode, otherwise let the Read through with a visible hint. A rules
# file error denies in every mode, since the pixels would also skip the built-in redaction.
failed() {
  if /usr/bin/grep -Eq '^cheapshot: (cannot read rules file|rules file|rule |duplicate rule|CHEAPSHOT_RULES)' "$errf" 2>/dev/null; then
    deny "cheapshot could not load its redaction rules, so $path was not read. Tell the user; do not retry another way." \
         "cheapshot: the rules file named by CHEAPSHOT_RULES is broken ($(/usr/bin/grep -m1 '^cheapshot: ' "$errf" | cut -c12-200)). Denied the Read of $path; fix the file or unset CHEAPSHOT_RULES."
  elif [ "$strict" = 1 ]; then
    deny "cheapshot could not read $path, and strict mode keeps the pixels out. Tell the user; do not retry another way." \
         "cheapshot: $1 Strict mode denied the Read of $path."
  else
    note error
    hint "cheapshot: $1 Reading $path as pixels instead."
  fi
  exit 0
}

if [ "${CHEAPSHOT_PASSTHROUGH:-0}" = "1" ]; then
  note passthrough_env
  exit 0
fi

# The model supplies file_path, so it can start with "-" and parse as a flag. The binary has no
# "--" marker to lean on (older builds reject it), so never hand such a path to it. By default
# the Read shows pixels; strict mode denies it like any other failure.
case "$path" in
  -*)
    if [ "$strict" = 1 ]; then
      deny "cheapshot will not read $path: it starts with \"-\" and would parse as a flag. Tell the user; do not retry another way." \
           "cheapshot: $path starts with \"-\"; strict mode denied the Read."
    else
      note error
      hint "cheapshot: $path starts with \"-\", so it would parse as a flag. Reading it as pixels."
    fi
    exit 0 ;;
esac

if ! command -v cheapshot >/dev/null 2>&1; then
  if [ "$strict" = 1 ]; then
    deny "cheapshot is not installed, and strict mode keeps the pixels out. Tell the user." \
         "cheapshot: binary not found; strict mode denied the Read of $path. Install it: brew install all-caps-dev/tap/cheapshot"
    exit 0
  fi
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
  if [ "$hit" = 1 ]; then
    note allow
    exit 0
  fi
fi

pages=$(printf '%s' "$input" | jq -r '.tool_input.pages // empty')
if [ "$ext" = pdf ] && [ -z "$pages" ]; then
  # Cheap probe: one page, no ledger line, just to learn the page count.
  probe=$(cheapshot --json --no-ledger --pages 1-1 "$path" 2>"$errf") || failed "could not probe the page count (exit $?)."
  count=$(printf '%s' "$probe" | jq -r '.results[0].source.pages // 0')
  if [ "$count" -gt 20 ] 2>/dev/null; then
    if [ "$strict" = 1 ]; then
      deny "$path has $count pages. Read it again with pages (for example pages: \"1-5\") to get redacted text of a range." \
           "cheapshot: $path has $count pages; strict mode asked the agent for a page range."
    else
      note over_cap
      hint "cheapshot: $path has $count pages, reading it as-is. For redacted text of a range, Read it with pages (for example pages: \"1-5\") or run from Bash: cheapshot --pages 1-5 $path"
    fi
    exit 0
  fi
fi

if [ -n "$pages" ]; then
  out=$(cheapshot --json --stats --pages "$pages" "$path" 2>"$errf")
else
  out=$(cheapshot --json --stats "$path" 2>"$errf")
fi
code=$?
[ "$code" = 0 ] || failed "could not read $path (exit $code)."

printf '%s' "$out" | jq -e '.results | type == "array"' >/dev/null 2>&1 || failed "unreadable output for $path."

text=$(printf '%s' "$out" | jq -r '[.results[] | .text // empty] | join("\n")')
if [ -z "$text" ]; then
  # Nothing recognised: there are no tokens to save, the pixels are the content. Not a failure,
  # so strict mode lets it through too (documented), but it is still a pass-through and is recorded.
  note no_text
  echo "cheapshot: no text in $path, reading it as pixels." >&2
  exit 0
fi
it=$(printf '%s' "$out" | jq -r '.image_tokens // 0')
tt=$(printf '%s' "$out" | jq -r '.text_tokens // 0')
# The model's copy does not name `cheapshot allow`: approving raw pixels is the user's call
# (Fleet #290 item 3). The user's copy, the systemMessage, carries the command.
# Shell-quoted so a person (or the agent's Bash tool) can paste it: macOS screenshot names
# carry spaces and U+202F.
qpath=$(jq -rn --arg p "$path" '$p | @sh')
if [ "$ext" = pdf ]; then
  model_line="cheapshot: $it image tokens -> $tt text tokens. If you need the pixels for layout, ask the user to approve it."
else
  # NOV-95: for an image, point the agent at the masked copy first. `cheapshot mask` paints every
  # redacted or low-confidence line black, writes the copy to a scratch folder and allows only
  # that copy, so the agent can see the layout without a person approving the raw pixels.
  model_line="cheapshot: $it image tokens -> $tt text tokens. If you need the layout, run in Bash: cheapshot mask $qpath, then Read the path it prints after \"masked: \" (a copy with redacted and low-confidence lines blacked out). The raw pixels still need the user's approval."
fi
user_line="cheapshot: $it image tokens -> $tt text tokens. To show the agent the pixels, run in a terminal: cheapshot allow $qpath"
echo "$user_line" >&2
jq -n --arg text "$text" --arg line "$model_line" --arg m "$user_line" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: ($text + "\n\n" + $line)}, systemMessage: $m}'
exit 0

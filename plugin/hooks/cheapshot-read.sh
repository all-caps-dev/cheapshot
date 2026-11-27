#!/bin/sh
# cheapshot PreToolUse hook for Read (POSIX sh). Input: the hook JSON on stdin. Output: nothing
# (let the Read proceed), a {"systemMessage": ...} hint with no decision (still proceeds), or a
# deny decision whose reason is the redacted text plus one savings line, or (for a one-shot allow
# entry with a hash) an allow decision with `updatedInput` pointing the Read at a checked copy.
# The savings line also goes out as a top-level systemMessage, since stderr on exit 0 is not
# shown to the user.
#
# Every exit is 0. A broken install or a failed OCR run on an image (missing jq, missing binary,
# non-zero exit, empty, truncated or non-JSON output, results that are not an array) denies the
# Read in every mode (NOV-160; Ryan, 2026-11-25: "Block in default too"). The user message says
# how to fix it, or names `cheapshot allow` or CHEAPSHOT_PASSTHROUGH=1; the model's reason names
# none of them. A path starting with "-" is read like any other, after "--". For a PDF, and for a
# PDF over 20 pages, the default still lets the Read through (fail open) and says so in a
# systemMessage. With CHEAPSHOT_STRICT=1 every failure denies (fail closed), so pixels never
# reach the model unless a person chose that (CHEAPSHOT_PASSTHROUGH=1 for the session, or
# `cheapshot allow <path>` from a terminal) or the image has no text to redact (Fleet #290 item
# 4). "No text" passes only when the binary says so for a photo (ocr_status
# "empty", retried false, text "", screenshot_like false or absent) or for a PDF. A screenshot
# still blank after the cold-start retry, an unknown or malformed status, and any empty image
# from a binary that does not report ocr_status (added in v0.6.0; it cannot tell a photo from a
# failed read) are denied in every mode (NOV-160). Known limit: the binary only retries an image
# that looks like a screenshot, so a photo or JPEG scan whose text Vision drops on a cold start
# reads as "empty", retried false, screenshot_like false, and passes as pixels in every mode. A broken rules file named by $CHEAPSHOT_RULES
# denies in both modes: passing the pixels would skip the built-in redaction as well as the
# custom rules. (A broken default rules.json never gets here: the binary warns and keeps its
# built-in rules.)
#
# Every pass-through of an image or PDF is recorded in the ledger as a zero-token line with a
# reason and no path (`cheapshot --note-passthrough <reason>`). Needs jq.
set -u
input=$(cat)
strict=0
[ "${CHEAPSHOT_STRICT:-0}" = "1" ] && strict=1

if ! command -v jq >/dev/null 2>&1; then
  # No jq means no JSON parsing, and is a broken install. An image Read is denied in every mode
  # (NOV-160); a PDF Read only in strict mode, as before. Without jq the file type comes from a
  # plain pattern match on the file_path extension in the raw hook JSON, not from the parsed
  # path: this is the one place the hook decides image versus PDF that way. Static JSON only.
  # CHEAPSHOT_PASSTHROUGH=1 is still honoured; a `cheapshot allow` entry is not, since matching
  # it needs the parsed path (the deny message says to install jq).
  [ "${CHEAPSHOT_PASSTHROUGH:-0}" = "1" ] && exit 0
  # The path pattern allows JSON escapes (\" and friends), so a quote in a file name cannot
  # end the match early and slip past the deny. The model's reason names neither the fix nor
  # the bypass; the user's systemMessage (and stderr) carries both.
  if printf '%s' "$input" | /usr/bin/grep -Eiq '"file_path" *: *"([^"\\]|\\.)*\.(png|jpe?g|webp|gif|heic|heif|tiff?|bmp)"'; then
    echo "cheapshot: jq is missing, so the image Read was denied. Install it: brew install jq (or set CHEAPSHOT_PASSTHROUGH=1 for the session to read images as pixels)." >&2
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"cheapshot: jq is missing, so this image was not read. Tell the user."},"systemMessage":"cheapshot: jq is missing, so the image Read was denied. Install it: brew install jq (or set CHEAPSHOT_PASSTHROUGH=1 for the session to read images as pixels)."}'
  elif [ "$strict" = 1 ] && printf '%s' "$input" | /usr/bin/grep -Eiq '"file_path" *: *"([^"\\]|\\.)*\.pdf"'; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"cheapshot: jq is missing, so this PDF was not read (CHEAPSHOT_STRICT=1). Tell the user."},"systemMessage":"cheapshot: jq is missing; strict mode denied a PDF Read. Install it: brew install jq"}'
  fi
  exit 0
fi

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$path" ] || exit 0
# Read resolves a relative file_path against the session's working directory, which the hook
# input carries as .cwd. Checks and printed commands use that base (the hook's own $PWD only when
# .cwd is absent), so they look at the file the Read will open (PR #21 review).
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
case "$path" in /*) rpath="$path" ;; *) rpath="${cwd:-$PWD}/$path" ;; esac
ext=$(printf '%s' "${path##*.}" | tr 'A-Z' 'a-z')
# The same image types `cheapshot allow` strips (NOV-117), so an allowed HEIC is rewritten too.
case "$ext" in png|jpg|jpeg|webp|gif|heic|heif|tif|tiff|bmp|pdf) ;; *) exit 0 ;; esac

tmp="${TMPDIR:-/tmp}"
# Fresh copies made for an earlier Read (below) are needed only until that Read ran, which is
# straight after the hook: every run removes ones over 2 minutes old. Only our own folder names.
find "$tmp" -maxdepth 1 -type d -name 'cheapshot-read.*' -mmin +2 -exec rm -rf {} + 2>/dev/null
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

# A failure: deny for an image in every mode (NOV-160), and in strict mode for a PDF too;
# otherwise let the Read through with a visible hint. A rules file error denies in every mode,
# since the pixels would also skip the built-in redaction.
failed() {
  if /usr/bin/grep -Eq '^cheapshot: (cannot read rules file|rules file|rule |duplicate rule|CHEAPSHOT_RULES)' "$errf" 2>/dev/null; then
    deny "cheapshot could not load its redaction rules, so $path was not read. Tell the user; do not retry another way." \
         "cheapshot: the rules file named by CHEAPSHOT_RULES is broken ($(/usr/bin/grep -m1 '^cheapshot: ' "$errf" | cut -c12-200)). Denied the Read of $path; fix the file or unset CHEAPSHOT_RULES."
  elif [ "$ext" != pdf ] && [ "$strict" != 1 ] && [ ! -e "$path" ] && [ ! -L "$path" ] \
       && [ ! -e "$rpath" ] && [ ! -L "$rpath" ] \
       && /usr/bin/grep -q '^cheapshot: no such file ' "$errf" 2>/dev/null; then
    # The binary said there is no such file, and there is none, neither where the binary looked
    # nor where the Read will look (.cwd): no pixels to keep out. Let the Read run and report the
    # missing file itself, instead of a deny that blames the install. A file that exists but will
    # not decode stays denied. Known limit: a file created between this check and the Read
    # passes unredacted (a small check-then-use window on a fail-open path).
    note error
    hint "cheapshot: $path does not exist; letting the Read report it."
  elif [ "$ext" != pdf ] && [ -n "${sep:-}" ] && /usr/bin/grep -q 'unknown option --' "$errf" 2>/dev/null; then
    # A dash path on a binary older than 0.6.0, which does not know "--": a reinstall of the
    # same version will not help, an update will (PR #21 review).
    qpath=$(jq -rn --arg p "$cpath" '$p | @sh')
    deny "cheapshot could not read $path, so the pixels were kept out. Tell the user; do not retry another way." \
         "cheapshot: this cheapshot binary is too old for a path that starts with \"-\" (it does not know \"--\"). Denied the Read of $path. Update it (brew upgrade all-caps-dev/tap/cheapshot), or look at the image and, to show the agent the pixels, run in a terminal: cheapshot allow $qpath"
  elif [ "$ext" != pdf ]; then
    # The user can fix the install, or look at the image and allow it once. `cheapshot allow`
    # needs the binary to start, which a crash during OCR does not rule out.
    qpath=$(jq -rn --arg p "$cpath" '$p | @sh')
    deny "cheapshot could not read $path, so the pixels were kept out. Tell the user; do not retry another way." \
         "cheapshot: $1 Denied the Read of $path. Fix the install (brew reinstall all-caps-dev/tap/cheapshot; run cheapshot $qpath in a terminal to see the error), or look at the image and, to show the agent the pixels, run in a terminal: cheapshot allow $qpath"
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

# The binary is called with $rpath, the path Read will open (resolved against .cwd), so OCR reads
# the same file the Read does (PR #21 second review). $rpath is absolute and cannot parse as a
# flag; "--" stays before a dash path as a backstop, which ends option parsing (cheapshot 0.6.0,
# #290), so it is read and redacted like any other (NOV-160: it used to pass as pixels). Only a
# dash path gets "--": an older binary rejects "--" as an unknown option, which is a failed run
# (denied for an image), while every normal path keeps working on older binaries.
sep=""
case "$path" in -*) sep="--" ;; esac
# The commands printed for a person (allow, mask, a plain run) take no "--" form for allow, so a
# dash path (always relative) is spelled absolute there, from the session's working directory
# (.cwd), which Read resolves it against. `cheapshot allow` stores that same absolute path, and
# the allowlist below matches a relative path by it too.
cpath="$path"
case "$path" in -*) cpath="$rpath" ;; esac

if ! command -v cheapshot >/dev/null 2>&1; then
  # An image is denied in every mode (NOV-160). `cheapshot allow` cannot help here (it needs the
  # binary, and the allowlist is only read once the binary is found), so the user message offers
  # the install and the session-wide CHEAPSHOT_PASSTHROUGH=1 instead.
  if [ "$ext" != pdf ]; then
    deny "cheapshot is not installed, so the pixels were kept out. Tell the user." \
         "cheapshot: binary not found; denied the Read of $path. Install it: brew install all-caps-dev/tap/cheapshot (or set CHEAPSHOT_PASSTHROUGH=1 for the session to read images as pixels)."
    exit 0
  fi
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

# One-shot allowlist written by `cheapshot allow <path>` and `cheapshot mask`, one entry per line:
#   "<expiry epoch>\t<path>"                    allow of a PDF (or an older binary): the file itself
#   "<expiry>\t<path>\t<sha256>"                 mask: <path> is the masked copy, <sha256> its hash
#   "<expiry>\t<path>\t<sha256>\t<copy>"         allow of an image (NOV-117): <copy> is a stripped
#                                               copy (pixels only, no GPS, camera or date metadata)
#                                               and <sha256> is the copy's hash
# Expired lines are dropped; the first live match for this path is consumed. `cheapshot allow`
# standardises paths, which strips a leading /private, while Read may pass /private/tmp/...,
# so an entry also matches the path with that prefix removed. A Read of the copy itself matches
# its entry too (a HEIC the hook does not intercept: the person can hand the agent the copy path).
#
# A hashed entry (mask or image allow) is never read in place. The hook copies the source to a
# fresh private folder, hashes that copy, and on a match rewrites the Read to it with
# `updatedInput` (Claude Code PreToolUse: it replaces the whole tool_input, so every other field
# is kept). The hashed bytes are then the bytes read, which closes the gap between check and Read
# that NOV-95's Known limits named, and an image allow shows the stripped copy, never the original.
allow="$tmp/cheapshot-allow"
if [ -f "$allow" ]; then
  alt="$rpath"
  case "$alt" in /private/*) alt="${alt#/private}" ;; esac
  now=$(date +%s)
  keep=$(mktemp "$tmp/cheapshot-allow.XXXXXX")
  hit=0
  fresh=""
  stale=0
  tab=$(printf '\t')
  # Delete an allow copy whose entry is used up or expired. Only a file inside our own
  # cheapshot-allowed folder, so a forged entry cannot point this at anything else.
  drop_copy() {
    case "$1" in "${tmp%/}"/cheapshot-allowed/*|/private"${tmp%/}"/cheapshot-allowed/*)
      case "$1" in */../*) ;; *) [ -f "$1" ] && [ ! -L "$1" ] && rm -f "$1" ;; esac ;;
    esac
  }
  while IFS="$tab" read -r exp p sum copy || [ -n "$exp" ]; do
    if ! [ "$exp" -ge "$now" ] 2>/dev/null; then
      [ -n "$copy" ] && drop_copy "$copy"
      continue
    fi
    if [ "$hit" = 0 ] && { [ "$p" = "$path" ] || [ "$p" = "$alt" ] || { [ -n "$copy" ] && { [ "$copy" = "$path" ] || [ "$copy" = "$alt" ]; }; }; }; then
      # Either way the entry is used up: a tampered entry falls through to normal handling.
      if [ -n "$sum" ]; then
        src="${copy:-$path}"
        # Only a regular file, not a symlink (PR #18 review). cp could still race a swap, but
        # the hash below is taken of the fresh copy, which is what the Read will see.
        if [ -f "$src" ] && [ ! -L "$src" ] && rd=$(mktemp -d "$tmp/cheapshot-read.XXXXXX"); then
          f="$rd/$(basename "$src")"
          if cp "$src" "$f" 2>/dev/null && chmod 600 "$f" && [ "$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1)" = "$sum" ]; then
            hit=1; fresh="$f"
          else
            rm -rf "${rd:?}"
          fi
        fi
        # The allow copy has done its job (or was tampered with): the fresh copy is what is read.
        [ -n "$copy" ] && drop_copy "$copy"
        continue
      fi
      # A plain (hashless) entry is honoured for a PDF only. The current binary always writes a
      # hashed entry for an image, so a plain image line is from an older binary or hand-made,
      # and would pass the original with its GPS and camera metadata (PR #19 review). Used up
      # either way; an image falls through to the normal redacted deny.
      if [ "$ext" = pdf ]; then hit=1; else stale=1; fi
      continue
    fi
    line="$exp$tab$p"
    [ -n "$sum" ] && line="$line$tab$sum"
    [ -n "$copy" ] && line="$line$tab$copy"
    printf '%s\n' "$line" >> "$keep"
  done < "$allow"
  mv "$keep" "$allow"
  if [ "$hit" = 1 ]; then
    [ -z "$fresh" ] && note allow
    if [ -n "$fresh" ]; then
      m="cheapshot: showing the agent a checked copy of $path (pixels only, no location or camera metadata)."
      # If jq fails here, an empty reply would send the Read to the original, unstripped path.
      # Deny instead, with a reply built without jq (PR #19 review).
      if ! printf '%s' "$input" | jq --arg f "$fresh" --arg m "$m" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
          permissionDecisionReason: "cheapshot: allowed once by the user or by cheapshot mask",
          updatedInput: (.tool_input | .file_path = $f)}, systemMessage: $m}'; then
        echo "cheapshot: could not hand over the checked copy; denied the Read instead of passing the original." >&2
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"cheapshot could not hand over the checked copy, so the Read was denied. Tell the user; do not retry another way."},"systemMessage":"cheapshot: could not hand over the checked copy, so the Read was denied instead of passing the original."}'
      else
        # Log and announce only once the allow reply was actually sent (PR #19 second review).
        echo "$m" >&2
        note allow
      fi
    fi
    exit 0
  fi
fi

pages=$(printf '%s' "$input" | jq -r '.tool_input.pages // empty')
if [ "$ext" = pdf ] && [ -z "$pages" ]; then
  # Cheap probe: one page, no ledger line, just to learn the page count.
  probe=$(cheapshot --json --no-ledger --pages 1-1 ${sep:+"$sep"} "$rpath" 2>"$errf") || failed "could not probe the page count (exit $?)."
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
  out=$(cheapshot --json --stats --pages "$pages" ${sep:+"$sep"} "$rpath" 2>"$errf")
else
  out=$(cheapshot --json --stats ${sep:+"$sep"} "$rpath" 2>"$errf")
fi
code=$?
[ "$code" = 0 ] || failed "could not read $path (exit $code)."

printf '%s' "$out" | jq -e '.results | type == "array"' >/dev/null 2>&1 || failed "unreadable output for $path."

text=$(printf '%s' "$out" | jq -r '[.results[] | .text // empty] | join("\n")' 2>/dev/null)

# NOV-160: how sure the binary is that OCR worked, from `ocr_status` and `retried` on each image
# result (cheapshot 0.6.0 and later). One word per distinct verdict, space separated:
#   ok             text found on the first pass
#   retried        text found, but a second pass ran (empty or short cold start): lines may be missing
#   blank          empty with no retry, text exactly "", and screenshot_like false or absent
#                  (null is not absent: it denies):
#                  a photo or small image, the pixels are the content
#   blank_retried  a screenshot-like image that still read empty after the retry: a likely OCR failure
#   legacy         neither field present: a binary without them (any build before v0.6.0's
#                  cold-start retry, including dev builds that call themselves 0.6.0), which
#                  cannot tell a photo from a failure
#   unknown        a status this hook does not know, fields of the wrong type, only one of the two
#                  fields, or an "empty" result that does not look like a photo
# Empty output (non-object results, an empty array, a jq error) counts as unknown below.
# PDF results carry neither field and keep the old handling.
ocr=""
if [ "$ext" != pdf ]; then
  ocr=$(printf '%s' "$out" | jq -r '
    [.results[] |
      if (has("ocr_status") or has("retried")) | not then "legacy"
      elif (.ocr_status | type) != "string" or (.retried | type) != "boolean" then "unknown"
      elif .ocr_status == "ok" then (if .retried then "retried" else "ok" end)
      elif .ocr_status == "empty" and .retried then "blank_retried"
      elif .ocr_status == "empty" and .text == "" and ((has("screenshot_like") | not) or .screenshot_like == false) then "blank"
      else "unknown" end
    ] | unique | join(" ")' 2>/dev/null)
fi

if [ -z "$text" ]; then
  # Nothing recognised. For a PDF, or an image the binary says read empty without a retry (a
  # photo), there are no tokens to save and the pixels are the content: not a failure, so strict
  # mode lets it through too (documented), but it is still a pass-through and is recorded.
  if [ "$ext" = pdf ] || [ "$ocr" = blank ]; then
    note no_text
    echo "cheapshot: no text in $path, reading it as pixels." >&2
    exit 0
  fi
  # Any other empty image result fails closed, in every mode: the pixels may hold a secret that
  # OCR missed, so they never reach the model unless a person looks first and allows them. The
  # model is not told about `cheapshot allow` or `cheapshot mask` (Fleet #290 item 3): mask runs
  # with no approval and, on an image it also reads as blank, would paint nothing.
  qpath=$(jq -rn --arg p "$cpath" '$p | @sh')
  extra=""
  case " $ocr " in
    *" blank_retried "*)
      why="OCR read no text from $path even after a retry, though it looks like a screenshot (a likely OCR failure)" ;;
    *" legacy "*)
      why="no text in $path; this cheapshot binary does not report ocr_status (added in v0.6.0), so it cannot say whether OCR failed"
      extra=" Or update to a cheapshot release that includes it (brew upgrade all-caps-dev/tap/cheapshot)." ;;
    *)
      why="no text in $path, and cheapshot did not report a usable OCR status" ;;
  esac
  deny "cheapshot: $why, so the pixels were kept out. Tell the user; do not read it another way." \
       "cheapshot: $why, so the Read was denied. Look at the image first. To show the agent the pixels, run in a terminal: cheapshot allow $qpath (or cheapshot mask $qpath for a copy with any text it finds blacked out).$extra"
  exit 0
fi

# Text was found but OCR was retried, or its status is unclear: the redacted text still goes to
# the model as usual, flagged so neither side mistakes it for the whole image. A legacy binary
# with text is left exactly as before.
flag=""
if [ "$ext" != pdf ]; then
  case " $ocr " in
    *" retried "*|*" blank_retried "*|*" unknown "*|"  ")
      flag="OCR on this image was retried or reported no clear status, so some lines may be missing." ;;
  esac
fi
it=$(printf '%s' "$out" | jq -r '.image_tokens // 0')
tt=$(printf '%s' "$out" | jq -r '.text_tokens // 0')
# The model's copy does not name `cheapshot allow`: approving raw pixels is the user's call
# (Fleet #290 item 3). The user's copy, the systemMessage, carries the command.
# Shell-quoted so a person (or the agent's Bash tool) can paste it: macOS screenshot names
# carry spaces and U+202F.
qpath=$(jq -rn --arg p "$cpath" '$p | @sh')
if [ "$ext" = pdf ]; then
  model_line="cheapshot: $it image tokens -> $tt text tokens. If you need the pixels for layout, ask the user to approve it."
else
  # NOV-95: for an image, point the agent at the masked copy first. `cheapshot mask` paints every
  # redacted or low-confidence line black, writes the copy to a scratch folder and allows only
  # that copy, so the agent can see the layout without a person approving the raw pixels.
  model_line="cheapshot: $it image tokens -> $tt text tokens. If you need the layout, run in Bash: cheapshot mask $qpath, then Read the path it prints after \"masked: \" (a copy with redacted and low-confidence lines blacked out). The raw pixels still need the user's approval."
fi
user_line="cheapshot: $it image tokens -> $tt text tokens. To show the agent the pixels, run in a terminal: cheapshot allow $qpath"
# A plain allow line for an image was refused above: it came from an older binary, so another
# `cheapshot allow` from that binary would loop. Say so (PR #19 second review).
[ "${stale:-0}" = 1 ] && user_line="$user_line (The allow entry for this file came from an older cheapshot binary and was not honoured; update cheapshot, then run allow again.)"
# NOV-160: the flag goes first on both lines, so the deny reason still ends with the savings line.
if [ -n "$flag" ]; then
  model_line="cheapshot: $flag ${model_line#cheapshot: }"
  user_line="cheapshot: $flag ${user_line#cheapshot: }"
fi
echo "$user_line" >&2
jq -n --arg text "$text" --arg line "$model_line" --arg m "$user_line" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: ($text + "\n\n" + $line)}, systemMessage: $m}'
exit 0

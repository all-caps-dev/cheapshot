#!/bin/sh
# Claude Code status line segment. Reads the status JSON on stdin (unused), prints one line:
#   cheapshot: 41.2k saved
# from `cheapshot --ledger --json --days 7`. Prints nothing when the binary is missing or fails, so
# the status line never shows an error. `--format N` prints the short form of N and exits, for tests.
set -u

short() {
  n=$1
  if [ "$n" -ge 1000000 ]; then
    awk -v n="$n" 'BEGIN { printf "%.1fM", n / 1000000 }'
  elif [ "$n" -ge 1000 ]; then
    awk -v n="$n" 'BEGIN { printf "%.1fk", n / 1000 }'
  else
    printf '%s' "$n"
  fi
}

if [ "${1:-}" = "--format" ]; then
  short "${2:-0}"; echo
  exit 0
fi

cat >/dev/null
command -v cheapshot >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
out=$(cheapshot --ledger --json --days 7 2>/dev/null) || exit 0
saved=$(printf '%s' "$out" | jq -r '.saved // 0')
case "$saved" in ''|*[!0-9]*) exit 0 ;; esac
echo "cheapshot: $(short "$saved") saved"
exit 0

#!/bin/sh
# Runs the redact engine's portable tests (decision table, blank check, image formats, defaults,
# and later the JPEG and PNG scrubbers and output naming) and fails unless they really ran:
# swift test exits 0 when a filter matches nothing, so the exit code alone proves nothing.
# A copy of check-redaction-tests.sh with a minimum count instead of an exact one, so each later
# suite can land without editing this file. Suites that have not landed yet match nothing.
# Runs in the windows-core job in ci.yml (not gating until one green run there) and on macOS.
#
# Usage: scripts/check-redact-portable-tests.sh [filter]
# The filter argument exists only to prove the guard: a filter that matches nothing must fail.
cd "$(dirname "$0")/.." || exit 1
filter="${1:-CheapshotPortableTests.(RedactOutcome|BlankCheck|ImageFormat|RedactDefaults|MetadataScrubJPEG|MetadataScrubPNG|OutputNaming)Tests}"
minimum=14   # P1: 7 RedactOutcome + 5 BlankCheck + 1 ImageFormat + 1 RedactDefaults; raise as suites land
log="${TMPDIR:-/tmp}/cheapshot-redact-portable-tests.$$.log"

swift test --filter "$filter" >"$log" 2>&1
status=$?
cat "$log"

# The largest "Executed N tests" line is the selected-tests total for the portable bundle
# (the Apple-only bundles, present on macOS, report 0).
executed=$(sed -n 's/.*Executed \([0-9][0-9]*\) tests\{0,1\},.*/\1/p' "$log" | sort -n | tail -n 1)
# The fail-closed property itself must be among the tests that passed, by name. XCTest names the
# case "-[Module.Suite test]" on macOS and "Suite.test" on Windows and Linux; accept both.
if grep -Eq "Test Case '.*RedactOutcomeTests[ .]testNoWritableOutcomeWithoutAllThreeGates\]?' passed" "$log"; then gate=yes; else gate=no; fi
rm -f "$log"

echo "== redact portable tests: exit $status, executed ${executed:-0} (want at least $minimum), testNoWritableOutcomeWithoutAllThreeGates passed: $gate"
[ "$status" -eq 0 ] || { echo "FAIL: swift test exited $status"; exit 1; }
[ "${executed:-0}" -ge "$minimum" ] || { echo "FAIL: executed ${executed:-0} tests, want at least $minimum"; exit 1; }
[ "$gate" = yes ] || { echo "FAIL: testNoWritableOutcomeWithoutAllThreeGates did not pass"; exit 1; }
echo "ok: ${executed} redact portable tests ran and passed, the three-gate test among them"

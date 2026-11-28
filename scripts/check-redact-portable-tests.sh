#!/bin/sh
# Runs the redact engine's portable tests (decision table, blank check, image formats, defaults,
# and later the JPEG and PNG scrubbers and output naming) and fails unless they really ran:
# swift test exits 0 when a filter matches nothing, so the exit code alone proves nothing.
# Each suite has its own floor, so a whole suite going missing fails even when the total looks
# fine. Suites that have not landed yet have floor 0; the PR that adds one raises its floor.
# Runs in the windows-core job in ci.yml (not gating until one green run there) and on macOS.
#
# Usage: scripts/check-redact-portable-tests.sh [filter]
# The filter argument exists only to prove the guard: a filter that matches nothing must fail.
cd "$(dirname "$0")/.." || exit 1
filter="${1:-CheapshotPortableTests.(RedactOutcome|BlankCheck|ImageFormat|RedactDefaults|MetadataScrubJPEG|MetadataScrubPNG|OutputNaming)Tests}"
# Suite:floor pairs. Raise a floor when tests are added to that suite.
floors="RedactOutcomeTests:7 BlankCheckTests:5 ImageFormatTests:1 RedactDefaultsTests:1
MetadataScrubJPEGTests:0 MetadataScrubPNGTests:0 OutputNamingTests:0"
log="${TMPDIR:-/tmp}/cheapshot-redact-portable-tests.$$.log"

swift test --filter "$filter" >"$log" 2>&1
status=$?
cat "$log"

# How many tests one suite ran: the "Executed N tests" line right after "Test Suite '<name>'
# passed|failed". 0 when the suite never ran. XCTest prints the same lines on macOS and Windows.
suite_count() {
  awk -v name="$1" '
    $0 ~ ("Test Suite .?" name "\047 (passed|failed)") { want = 1; next }
    want && /Executed [0-9]+ tests?,/ { match($0, /Executed [0-9]+/); n = substr($0, RSTART + 9, RLENGTH - 9) + 0
                                        if (n > best) best = n; want = 0 }
    END { print best + 0 }' "$log"
}

# The largest "Executed N tests" line is the selected-tests total for the portable bundle
# (the Apple-only bundles, present on macOS, report 0).
executed=$(sed -n 's/.*Executed \([0-9][0-9]*\) tests\{0,1\},.*/\1/p' "$log" | sort -n | tail -n 1)
# The fail-closed property itself must be among the tests that passed, by name. XCTest names the
# case "-[Module.Suite test]" on macOS and "Suite.test" on Windows and Linux; accept both.
if grep -Eq "Test Case '.*RedactOutcomeTests[ .]testNoWritableOutcomeWithoutAllThreeGates\]?' passed" "$log"; then gate=yes; else gate=no; fi

short=""
for pair in $floors; do
  suite="${pair%%:*}"; floor="${pair##*:}"
  ran=$(suite_count "$suite")
  echo "   $suite: ran $ran, floor $floor"
  [ "$ran" -ge "$floor" ] || short="$short $suite($ran<$floor)"
done
rm -f "$log"

echo "== redact portable tests: exit $status, executed ${executed:-0}, testNoWritableOutcomeWithoutAllThreeGates passed: $gate"
[ "$status" -eq 0 ] || { echo "FAIL: swift test exited $status"; exit 1; }
[ "${executed:-0}" -gt 0 ] || { echo "FAIL: no tests ran"; exit 1; }
[ -z "$short" ] || { echo "FAIL: suites under their floor:$short"; exit 1; }
[ "$gate" = yes ] || { echo "FAIL: testNoWritableOutcomeWithoutAllThreeGates did not pass"; exit 1; }
echo "ok: ${executed} redact portable tests ran and passed, every suite at its floor, the three-gate test among them"

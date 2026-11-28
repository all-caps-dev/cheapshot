#!/bin/sh
# CheapshotCore on iOS (native app plan, step 1): build Core and its tests for the iOS Simulator
# and for a device, then run the Core tests (the 62 golden redaction cases among them) on an
# iPhone Simulator. Since the Windows split the golden cases sit in CheapshotPortableTests,
# which the scheme runs too. NSRegularExpression comes from the OS, so redaction on iOS is
# measured here, not assumed.
#
# The Simulator is chosen on purpose and printed: the newest available iOS runtime that is 17 or
# later (Core's iOS floor), and the first iPhone on it. The test run must report at least
# MIN_TESTS executed tests, so a run that builds but runs nothing (a scheme or filter mistake)
# fails instead of passing quietly. All golden cases run inside one method,
# GoldenTests.testGoldenCases, which no count can see, so the log must also show it passed.
#
# CI (CI=true) fails when no iOS 17+ iPhone Simulator is available. Locally, with none
# installed, it builds everything and says the tests were not run, then exits 0.
#
# scripts/test-check-ios-core.sh tests this script with fake xcodebuild and xcrun.
set -e
cd "$(dirname "$0")/.."
dd="${DERIVED_DATA:-.build/xcode-ios}"
scheme=CheapshotCore-iOS
# The scheme runs two bundles: CheapshotCoreTests (90 tests on macOS, 11 of them macOS only:
# 9 ffmpeg, 2 that compare with AppKit's NSImage) and CheapshotPortableTests (99), so 178 run on
# iOS. 175 leaves room for a test removed on purpose, while still failing on 0 or on a run that
# skipped a whole bundle or any suite of 4 or more (PR #22 review: at 140, all of
# LayoutTests could go missing unnoticed).
min_tests="${MIN_TESTS:-175}"

echo "== build: CheapshotCore for an iOS device"
xcodebuild build -quiet -scheme "$scheme" -destination 'generic/platform=iOS' \
  -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO

echo "== build: CheapshotCore and CheapshotCoreTests for the iOS Simulator"
xcodebuild build-for-testing -quiet -scheme "$scheme" -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO

# Newest iOS runtime at 17 or later. simctl prints lines like
#   iOS 18.2 (18.2 - 22C150) - com.apple.CoreSimulator.SimRuntime.iOS-18-2
# The awk keeps the version with the highest major*1000+minor.
runtime="$(xcrun simctl list runtimes available 2>/dev/null | awk '
  /^iOS [0-9]+\.[0-9]+/ {
    split($2, v, "."); key = v[1] * 1000 + v[2]
    if (v[1] >= 17 && key > best) { best = key; ver = $2 }
  }
  END { if (ver != "") print ver }')"

not_available() {
  if [ "${CI:-}" = "true" ]; then echo "$1"; exit 1; fi
  echo "not run: $1 (builds above passed)"
  exit 0
}
[ -n "$runtime" ] || not_available "no iOS 17 or later Simulator runtime on this Mac"

# First iPhone listed under that runtime's "-- iOS x.y --" heading, by its 36-character UDID.
udid="$(xcrun simctl list devices available 2>/dev/null | awk -v head="-- iOS $runtime --" '
  $0 == head { inside = 1; next }
  /^-- / { inside = 0 }
  inside && /^ *iPhone/ { print; exit }' \
  | sed -En 's/.*\(([0-9A-F-]{36})\) \((Shutdown|Booted)\).*/\1/p')"
[ -n "$udid" ] || not_available "no iPhone Simulator on iOS $runtime"

echo "== test: CheapshotCoreTests on iOS $runtime, iPhone Simulator $udid (need at least $min_tests tests)"
log="$dd/ios-core-test.log"
mkdir -p "$dd"
# No pipe, so xcodebuild's own exit code is kept (POSIX sh has no pipefail).
set +e
xcodebuild test-without-building -scheme "$scheme" -destination "id=$udid" -derivedDataPath "$dd" > "$log" 2>&1
rc=$?
set -e
cat "$log"
[ "$rc" -eq 0 ] || { echo "xcodebuild test failed (exit $rc)"; exit 1; }

# XCTest prints "Executed N tests, ..." per suite, per bundle and sometimes once for the whole
# run. With two bundles there may be no whole-run line, so add up the line that follows each
# "Test Suite '<bundle>.xctest' passed|failed". With no bundle lines, fall back to the largest
# N. No Executed line at all counts as 0.
ran="$(awk '
  /Test Suite .*\.xctest. (passed|failed)/ { want = 1; next }
  want && /Executed [0-9]+ tests?,/ { match($0, /Executed [0-9]+/); sum += substr($0, RSTART + 9, RLENGTH - 9); seen = 1; want = 0 }
  END { if (seen) print sum }' "$log")"
[ -n "$ran" ] || ran="$(sed -En 's/.*Executed ([0-9]+) tests?,.*/\1/p' "$log" | sort -n | tail -n 1)"
ran="${ran:-0}"
[ "$ran" -ge "$min_tests" ] || { echo "ran $ran tests on iOS $runtime, expected at least $min_tests"; exit 1; }
# The golden redaction cases, by name: the whole point of this run (PR #22 review).
grep -q "GoldenTests testGoldenCases\]' passed" "$log" || { echo "golden redaction cases did not run on iOS $runtime"; exit 1; }
echo "ok: CheapshotCore builds for iOS and $ran Core tests pass on iOS $runtime"

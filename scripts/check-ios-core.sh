#!/bin/sh
# CheapshotCore on iOS (native app plan, step 1): build Core and its tests for the iOS Simulator
# and for a device, then run the Core tests (the 55 golden redaction cases among them) on the
# first available iPhone Simulator. NSRegularExpression comes from the OS, so redaction on iOS
# is measured here, not assumed.
#
# CI (CI=true) fails when no Simulator is available. Locally, with no Simulator runtime
# installed, it builds everything and says the tests were not run, then exits 0.
set -e
cd "$(dirname "$0")/.."
dd="${DERIVED_DATA:-.build/xcode-ios}"
scheme=CheapshotCore-iOS
quiet="-quiet"

echo "== build: CheapshotCore for an iOS device"
xcodebuild build $quiet -scheme "$scheme" -destination 'generic/platform=iOS' \
  -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO

echo "== build: CheapshotCore and CheapshotCoreTests for the iOS Simulator"
xcodebuild build-for-testing $quiet -scheme "$scheme" -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO

# First available iPhone Simulator, by UDID. simctl output is plain text; the UDID is the 36-character id in brackets.
udid="$(xcrun simctl list devices available 2>/dev/null \
  | sed -En 's/^ *iPhone.*\(([0-9A-F-]{36})\) \((Shutdown|Booted)\).*/\1/p' | head -n 1)"
if [ -z "$udid" ]; then
  if [ "${CI:-}" = "true" ]; then echo "no iPhone Simulator available"; exit 1; fi
  echo "not run: no iPhone Simulator runtime on this Mac (builds above passed)"
  exit 0
fi

echo "== test: CheapshotCoreTests on Simulator $udid"
xcodebuild test-without-building $quiet -scheme "$scheme" -destination "id=$udid" -derivedDataPath "$dd"
echo "ok: CheapshotCore builds for iOS and its tests pass on the iOS Simulator"

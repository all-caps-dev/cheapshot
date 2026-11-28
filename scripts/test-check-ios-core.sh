#!/bin/sh
# Tests for scripts/check-ios-core.sh, with fake `xcodebuild` and `xcrun` first on PATH, so it
# runs on any Mac (or Linux) with no Simulator runtime. Each case sets what the fakes print and
# checks the script's exit code and output. Proves, among other things, that a run where
# xcodebuild reports 0 tests fails.
set -u
cd "$(dirname "$0")/.."
root="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$work/bin"

# Fake xcrun: only `xcrun simctl list runtimes|devices available` is used by the script.
cat > "$work/bin/xcrun" <<'EOF'
#!/bin/sh
case "$*" in
  "simctl list runtimes available") cat "$FAKE_DIR/runtimes" ;;
  "simctl list devices available")  cat "$FAKE_DIR/devices" ;;
  *) echo "fake xcrun: unexpected: $*" >&2; exit 9 ;;
esac
EOF
# Fake xcodebuild: builds succeed; `test-without-building` prints $FAKE_DIR/test-out, exits
# with $FAKE_DIR/test-rc, and records its arguments so a case can check the destination.
cat > "$work/bin/xcodebuild" <<'EOF'
#!/bin/sh
case "$1" in
  build|build-for-testing) exit 0 ;;
  test-without-building)
    echo "$*" > "$FAKE_DIR/test-args"
    cat "$FAKE_DIR/test-out"
    exit "$(cat "$FAKE_DIR/test-rc")" ;;
  *) echo "fake xcodebuild: unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$work/bin/xcrun" "$work/bin/xcodebuild"

U17=11111111-1111-1111-1111-111111111111
U18=22222222-2222-2222-2222-222222222222
UPAD=33333333-3333-3333-3333-333333333333
U16=44444444-4444-4444-4444-444444444444
runtimes_17_18='== Runtimes ==
iOS 17.5 (17.5 - 21F79) - com.apple.CoreSimulator.SimRuntime.iOS-17-5
iOS 18.2 (18.2 - 22C150) - com.apple.CoreSimulator.SimRuntime.iOS-18-2
watchOS 11.2 (11.2 - 22S99) - com.apple.CoreSimulator.SimRuntime.watchOS-11-2'
devices_17_18="== Devices ==
-- iOS 17.5 --
    iPhone 15 ($U17) (Shutdown)
-- iOS 18.2 --
    iPad Air 13-inch (M2) ($UPAD) (Shutdown)
    iPhone 16 Pro ($U18) (Shutdown)
-- watchOS 11.2 --
    Apple Watch Series 10 (46mm) (55555555-5555-5555-5555-555555555555) (Shutdown) "
golden_line='Test Case '"'"'-[CheapshotPortableTests.GoldenTests testGoldenCases]'"'"' passed (0.412 seconds).'
ok_out="$golden_line"'
Test Suite '"'"'All tests'"'"' passed at 2026-11-25 16:00:00.000.
	 Executed 190 tests, with 0 failures (0 unexpected) in 3.1 (3.2) seconds
** TEST EXECUTE SUCCEEDED **'

two_bundles="$golden_line"'
Test Suite '"'"'CheapshotPortableTests.xctest'"'"' passed at 2026-11-27 16:00:00.000.
	 Executed 105 tests, with 0 failures (0 unexpected) in 2.0 (2.0) seconds
Test Suite '"'"'CheapshotCoreTests.xctest'"'"' passed at 2026-11-27 16:00:03.000.
	 Executed 85 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds
** TEST EXECUTE SUCCEEDED **'
one_bundle="$golden_line"'
Test Suite '"'"'CheapshotPortableTests.xctest'"'"' passed at 2026-11-27 16:00:00.000.
	 Executed 99 tests, with 0 failures (0 unexpected) in 2.0 (2.0) seconds
** TEST EXECUTE SUCCEEDED **'

pass=0; fail=0
# case <name> <want exit: 0 or nonzero> <CI value> <runtimes> <devices> <test-out> <test-rc> <grep for in output>
case_() {
  name=$1; want=$2; ci=$3
  d="$work/$pass-$fail"; mkdir -p "$d"
  printf '%s\n' "$4" > "$d/runtimes"; printf '%s\n' "$5" > "$d/devices"
  printf '%s\n' "$6" > "$d/test-out"; printf '%s\n' "$7" > "$d/test-rc"
  out="$(FAKE_DIR="$d" CI="$ci" PATH="$work/bin:$PATH" DERIVED_DATA="$d/dd" sh "$root/scripts/check-ios-core.sh" 2>&1)"
  code=$?
  okcode=0
  if [ "$want" = 0 ]; then [ "$code" -eq 0 ] || okcode=1; else [ "$code" -ne 0 ] || okcode=1; fi
  if [ "$okcode" -eq 0 ] && printf '%s' "$out" | grep -q -- "$8"; then
    pass=$((pass+1)); echo "ok    $name (exit $code)"
  else
    fail=$((fail+1)); echo "FAIL  $name (exit $code, wanted $want, looked for: $8)"; printf '%s\n' "$out" | sed 's/^/      /'
  fi
  LAST_DIR="$d"
}

case_ "190 tests on iOS 18.2 passes" 0 true "$runtimes_17_18" "$devices_17_18" "$ok_out" 0 "ok: CheapshotCore builds for iOS"
grep -q "id=$U18" "$LAST_DIR/test-args" && { pass=$((pass+1)); echo "ok    picks the iPhone under the newest iOS 17+ runtime"; } \
  || { fail=$((fail+1)); echo "FAIL  destination was: $(cat "$LAST_DIR/test-args")"; }
case_ "the chosen runtime and device are printed" 0 true "$runtimes_17_18" "$devices_17_18" "$ok_out" 0 "iOS 18.2.*$U18"
case_ "0 tests executed fails" 1 true "$runtimes_17_18" "$devices_17_18" \
  "	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
** TEST EXECUTE SUCCEEDED **" 0 "ran 0 tests"
case_ "no Executed line fails" 1 true "$runtimes_17_18" "$devices_17_18" "** TEST EXECUTE SUCCEEDED **" 0 "ran 0 tests"
case_ "too few tests fails" 1 true "$runtimes_17_18" "$devices_17_18" \
  "	 Executed 12 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds" 0 "ran 12 tests"
case_ "xcodebuild failure fails even with a big count" 1 true "$runtimes_17_18" "$devices_17_18" \
  "	 Executed 190 tests, with 2 failures (0 unexpected) in 3.1 (3.2) seconds
** TEST EXECUTE FAILED **" 65 "exit 65"
# PR #22 review: a high count is not enough; the golden cases must be seen passing by name.
case_ "high count but no golden line fails" 1 true "$runtimes_17_18" "$devices_17_18" \
  "	 Executed 190 tests, with 0 failures (0 unexpected) in 3.1 (3.2) seconds
** TEST EXECUTE SUCCEEDED **" 0 "golden redaction cases did not run"
case_ "the old floor of 140 now fails" 1 true "$runtimes_17_18" "$devices_17_18" \
  "$golden_line
	 Executed 143 tests, with 0 failures (0 unexpected) in 3.1 (3.2) seconds" 0 "ran 143 tests"
case_ "only iOS 16 on CI fails" 1 true "== Runtimes ==
iOS 16.4 (16.4 - 20E247) - com.apple.CoreSimulator.SimRuntime.iOS-16-4" "== Devices ==
-- iOS 16.4 --
    iPhone 14 ($U16) (Shutdown) " "$ok_out" 0 "no iOS 17 or later"
case_ "no runtime on CI fails" 1 true "== Runtimes ==" "== Devices ==" "$ok_out" 0 "no iOS 17 or later"
case_ "no runtime locally builds and says not run" 0 "" "== Runtimes ==" "== Devices ==" "$ok_out" 0 "not run"
case_ "runtime with no iPhone on CI fails" 1 true "$runtimes_17_18" "== Devices ==
-- iOS 18.2 --
    iPad Air 13-inch (M2) ($UPAD) (Shutdown) " "$ok_out" 0 "no iPhone Simulator"

case_ "two bundles with no whole-run line are added up" 0 true "$runtimes_17_18" "$devices_17_18" "$two_bundles" 0 "190 Core tests pass"
case_ "one bundle alone is too few" 1 true "$runtimes_17_18" "$devices_17_18" "$one_bundle" 0 "ran 99 tests"

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

#!/bin/sh
# Runs the redaction tests (golden cases, redactor, validators, rule files, rule catalog) and fails unless
# they really ran: swift test exits 0 when a filter matches nothing, so the exit code alone
# proves nothing. Used as the gating step of the windows-core job in ci.yml; runs on macOS too.
#
# Usage: scripts/check-redaction-tests.sh [filter]
# The filter argument exists only to prove the guard: a filter that matches nothing must fail.
cd "$(dirname "$0")/.." || exit 1
filter="${1:-CheapshotPortableTests.(GoldenTests|RedactorTests|ValidatorsTests|RuleFileTests|RuleFileV2Tests|RuleCatalogTests)}"
expected=61   # 2 Golden + 18 Redactor + 15 Validators + 6 RuleFile + 15 RuleFileV2 + 5 RuleCatalog; change when tests are added
log="${TMPDIR:-/tmp}/cheapshot-redaction-tests.$$.log"

swift test --filter "$filter" >"$log" 2>&1
status=$?
cat "$log"

# The largest "Executed N tests" line is the selected-tests total for the portable bundle
# (the Apple-only bundles, present on macOS, report 0).
executed=$(sed -n 's/.*Executed \([0-9][0-9]*\) tests\{0,1\},.*/\1/p' "$log" | sort -n | tail -n 1)
# XCTest names the case "-[Module.GoldenTests testGoldenCases]" on macOS and
# "GoldenTests.testGoldenCases" on Windows and Linux; accept both.
if grep -Eq "Test Case '.*GoldenTests[ .]testGoldenCases\]?' passed" "$log"; then golden=yes; else golden=no; fi
rm -f "$log"

echo "== redaction tests: exit $status, executed ${executed:-0} (want $expected), testGoldenCases passed: $golden"
[ "$status" -eq 0 ] || { echo "FAIL: swift test exited $status"; exit 1; }
[ "${executed:-0}" -eq "$expected" ] || { echo "FAIL: executed ${executed:-0} tests, want $expected"; exit 1; }
[ "$golden" = yes ] || { echo "FAIL: testGoldenCases did not pass"; exit 1; }
echo "ok: $expected redaction tests ran and passed, golden cases among them"

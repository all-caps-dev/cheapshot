#!/bin/sh
# Phase 3 acceptance sweep: every check script, the two fake binaries in step, the Swift suite,
# the allow usage line, and the runbook. Later phases re-run this.
set -e
cd "$(dirname "$0")/.."
scripts/check-plugin.sh
scripts/check-mcp.sh
scripts/check-readme.sh
scripts/check-workflows.sh
scripts/check-site.sh
cmp plugin/tests/fake-bin/cheapshot mcp/test/fake-bin/cheapshot || { echo "the two fake binaries drifted apart"; exit 1; }
swift test > /tmp/cheapshot-swift-test.log 2>&1 || { tail -20 /tmp/cheapshot-swift-test.log; exit 1; }
grep -E "Executed" /tmp/cheapshot-swift-test.log | tail -1
grep -q '^ *cheapshot allow <path>' Sources/CheapshotCLI/Output.swift || { echo "usage lacks allow"; exit 1; }
test -f docs/release-phase3.md || { echo "phase 3 runbook missing"; exit 1; }
grep -q 'npm publish' docs/release-phase3.md || { echo "runbook lacks npm publish"; exit 1; }
grep -q 'claude plugin marketplace add all-caps-dev/cheapshot' docs/release-phase3.md || { echo "runbook lacks the marketplace step"; exit 1; }
echo "ok: phase 3"

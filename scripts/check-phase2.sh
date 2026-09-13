#!/bin/sh
set -e
cd "$(dirname "$0")/.."
scripts/check-license.sh
scripts/check-workflows.sh
scripts/check-formula.sh
scripts/check-readme.sh
scripts/check-site.sh
swift test > /tmp/cheapshot-swift-test.log 2>&1 || { tail -20 /tmp/cheapshot-swift-test.log; exit 1; }
grep -E "Executed" /tmp/cheapshot-swift-test.log | tail -1
make build check
test -f docs/release.md || { echo "runbook missing"; exit 1; }
grep -qF 'git tag v0.5.0 && git push origin v0.5.0' docs/release.md || { echo "runbook lacks the tag step"; exit 1; }
echo "ok: phase 2"

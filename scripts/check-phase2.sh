#!/bin/sh
set -e
scripts/check-license.sh
scripts/check-workflows.sh
scripts/check-formula.sh
scripts/check-readme.sh
scripts/check-site.sh
swift test 2>&1 | grep -E "Executed|error" | tail -2
make build check
test -f docs/release.md || { echo "runbook missing"; exit 1; }
grep -q 'git tag v0.5.0' docs/release.md || { echo "runbook lacks the tag step"; exit 1; }
echo "ok: phase 2"

#!/bin/sh
# Fails if any tracked file outside the frozen spec/brief still names the old license.
set -e
head -1 LICENSE | grep -q '^MIT License$' || { echo "LICENSE is not MIT"; exit 1; }
hits=$(git ls-files -z | grep -zv -e '^docs/product-brief.md$' -e '^docs/superpowers/' -e '^scripts/check-license\.sh$' | xargs -0 grep -l -i -e 'Business Source' -e 'BUSL' 2>/dev/null || true)
test -z "$hits" || { echo "old license text in: $hits"; exit 1; }
test ! -e docs/licensing-animated.svg || { echo "licensing-animated.svg still present"; exit 1; }
test ! -e docs/licensing.png || { echo "licensing.png still present"; exit 1; }
echo "ok: MIT everywhere"

#!/bin/sh
# Assertions for the Pages deploy workflow. Written on the Task 6 branch because
# scripts/check-workflows.sh landed on main after this branch point; the controller merges
# these lines into check-workflows.sh when the branch lands.
set -e
cd "$(dirname "$0")/.."
p=.github/workflows/pages.yml
test -f $p || { echo "$p missing"; exit 1; }
ruby -ryaml -e "YAML.load_file('$p')" || { echo "$p is not valid YAML"; exit 1; }
grep -q 'withastro/action@v6' $p || { echo "pages.yml must use withastro/action@v6"; exit 1; }
grep -q 'actions/deploy-pages@v5' $p || { echo "pages.yml must use deploy-pages@v5"; exit 1; }
grep -q "path: ./site" $p || { echo "pages.yml must point withastro/action at ./site"; exit 1; }
grep -q "'site/\*\*'" $p || { echo "pages.yml must trigger on site/** only"; exit 1; }
echo "ok: pages.yml"

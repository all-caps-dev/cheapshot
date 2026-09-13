#!/bin/sh
# Parses every workflow and asserts the lines the plan depends on.
set -e
for f in .github/workflows/*.yml; do
  ruby -ryaml -e "YAML.load_file('$f')" || { echo "$f does not parse"; exit 1; }
done
grep -q 'swift test' .github/workflows/ci.yml || { echo "ci.yml lacks swift test"; exit 1; }
grep -q 'make build check' .github/workflows/ci.yml || { echo "ci.yml lacks make build check"; exit 1; }
echo "ok: workflows parse and carry the required steps"

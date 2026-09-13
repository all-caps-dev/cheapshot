#!/bin/sh
# Parses every workflow and asserts the lines the plan depends on.
set -e
for f in .github/workflows/*.yml; do
  ruby -ryaml -e "YAML.load_file('$f')" || { echo "$f does not parse"; exit 1; }
done
grep -q 'swift test' .github/workflows/ci.yml || { echo "ci.yml lacks swift test"; exit 1; }
grep -q 'make build check' .github/workflows/ci.yml || { echo "ci.yml lacks make build check"; exit 1; }
r=.github/workflows/release.yml
grep -q "tags: \['v\*'\]" $r || { echo "release.yml does not trigger on v* tags"; exit 1; }
grep -q 'make build check' $r || { echo "release.yml must build with make, not swiftc"; exit 1; }
grep -q 'mislav/bump-homebrew-formula-action@v4' $r || { echo "bump action not pinned to v4"; exit 1; }
grep -q 'create-pullrequest: false' $r || { echo "bump action must commit directly"; exit 1; }
grep -q 'xcrun notarytool submit' $r || { echo "release.yml does not notarize"; exit 1; }
grep -q 'softprops/action-gh-release@v2' $r || { echo "release action not pinned to v2"; exit 1; }
grep -q 'homebrew-tap: all-caps-dev/homebrew-tap' $r || { echo "wrong tap"; exit 1; }
echo "ok: workflows parse and carry the required steps"

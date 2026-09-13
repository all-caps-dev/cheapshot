#!/bin/sh
# Parses every workflow and asserts the lines the plan depends on.
set -e
cd "$(dirname "$0")/.."
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  test -e "$f" || continue
  # aliases: true so anchors parse under Psych 4 (Ruby 3); older Psych has no such keyword and allows them anyway
  ruby -ryaml -e "begin; YAML.load_file('$f', aliases: true); rescue ArgumentError; YAML.load_file('$f'); end" || { echo "$f does not parse"; exit 1; }
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
grep -q 'ditto -c -k --norsrc' $r || { echo "zip must place the binary at the archive root"; exit 1; }
grep -q 'cheapshot-.*-macos\.zip' $r || { echo "release asset name changed"; exit 1; }
grep -q 'notarization not Accepted' $r || { echo "release.yml must assert the notarization status"; exit 1; }
grep -qF '[[:space:]]*:[[:space:]]*"Accepted"' $r || { echo "notarization guard must tolerate notarytool's pretty-printed JSON spacing"; exit 1; }
p=.github/workflows/pages.yml
test -f $p || { echo "$p missing"; exit 1; }
grep -q 'withastro/action@v6' $p || { echo "pages.yml must use withastro/action@v6"; exit 1; }
grep -q 'actions/deploy-pages@v5' $p || { echo "pages.yml must use deploy-pages@v5"; exit 1; }
grep -q "path: ./site" $p || { echo "pages.yml must point withastro/action at ./site"; exit 1; }
grep -q "'site/\*\*'" $p || { echo "pages.yml must include site/** in its paths"; exit 1; }
grep -q 'check-site.sh' $p || { echo "pages.yml must gate the deploy on scripts/check-site.sh"; exit 1; }
grep -q 'scripts/check-formula.sh' .github/workflows/ci.yml || { echo "ci.yml lacks scripts/check-formula.sh"; exit 1; }
for s in check-license check-workflows check-readme; do
  grep -q "scripts/$s.sh" .github/workflows/ci.yml || { echo "ci.yml lacks scripts/$s.sh"; exit 1; }
done
echo "ok: workflows parse and carry the required steps"

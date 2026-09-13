#!/bin/sh
set -e
cd "$(dirname "$0")/.."
test -f site/package.json || { echo "site/package.json missing"; exit 1; }
cd site
grep -q "base: '/cheapshot/'" astro.config.mjs || { echo "astro base must be /cheapshot/"; exit 1; }
grep -q "site: 'https://all-caps-dev.github.io'" astro.config.mjs || { echo "astro site origin wrong"; exit 1; }
if [ -n "$CI" ] || [ ! -d node_modules ]; then npm ci --no-audit --no-fund; fi
npm run build
test -f dist/index.html || { echo "no dist/index.html"; exit 1; }
test -f dist/.nojekyll || { echo "no dist/.nojekyll"; exit 1; }
grep -q 'href="#_top"' dist/install/index.html || grep -qi 'skip to content' dist/install/index.html || { echo "no skip link in built HTML"; exit 1; }
for p in $(cd src/content/docs && find . -name '*.md' | sed 's|^\./||; s|\.md$||; s|/index$||'); do
  case "$p" in index) t=dist/index.html;; *) t="dist/$p/index.html";; esac
  test -f "$t" || { echo "page $p did not build"; exit 1; }
done
# every image in every page has alt text
if grep -rn '!\[\]' src/content/docs; then echo "image without alt text"; exit 1; fi
if grep -rn '<img' src/content/docs | grep -v 'alt="[^"]\+"'; then echo "img tag without alt"; exit 1; fi
# the theme's body text on its background passes AA in light and dark
cr=$HOME/.claude/skills/efficient-burn/scripts/contrast-ratio.sh
if [ -x "$cr" ]; then
  for pair in $(sed -n 's/^# contrast-pairs: *//p' ../docs/site-colors.txt); do
    fg=${pair%%/*}; bg=${pair##*/}
    "$cr" "$fg" "$bg" | grep -q 'AA.*pass' || { echo "contrast fails for $fg on $bg"; exit 1; }
  done
fi
echo "ok: site builds"

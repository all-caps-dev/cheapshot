#!/bin/sh
set -e
cd site
test -f package.json || { echo "site/package.json missing"; exit 1; }
grep -q "base: '/cheapshot/'" astro.config.mjs || { echo "astro base must be /cheapshot/"; exit 1; }
grep -q "site: 'https://all-caps-dev.github.io'" astro.config.mjs || { echo "astro site origin wrong"; exit 1; }
if [ ! -d node_modules ]; then npm ci --no-audit --no-fund; fi
npm run build
test -f dist/index.html || { echo "no dist/index.html"; exit 1; }
test -f dist/.nojekyll || { echo "no dist/.nojekyll"; exit 1; }
grep -q 'href="#_top"' dist/install/index.html || grep -qi 'skip to content' dist/install/index.html || { echo "no skip link in built HTML"; exit 1; }
for p in $(cd src/content/docs && find . -name '*.md' | sed 's|^\./||; s|\.md$||; s|/index$||'); do
  case "$p" in index) t=dist/index.html;; *) t="dist/$p/index.html";; esac
  test -f "$t" || { echo "page $p did not build"; exit 1; }
done
echo "ok: site builds"

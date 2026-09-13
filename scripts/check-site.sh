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
if grep -rn '!\[[[:space:]]*\]' src/content/docs; then echo "image without alt text"; exit 1; fi
if grep -rn '<img' src/content/docs | grep -v 'alt="[^"]\+"'; then echo "img tag without alt"; exit 1; fi
# the research pages are verbatim copies of the notes in docs/research, so they cannot drift:
# skip the 4-line frontmatter, the blank line, the "kept as written" line and its blank line on
# the page side, and the note's own h1 and its blank line on the source side.
for n in video-frames structured-output pdf-pipeline; do
  case "$n" in pdf-pipeline) src=../docs/research/2026-09-12-pdf-pipeline-notes.md;; *) src=../docs/research/2026-09-12-$n.md;; esac
  a=$(mktemp); b=$(mktemp)
  tail -n +8 "src/content/docs/research/$n.md" > "$a"; tail -n +3 "$src" > "$b"
  diff "$a" "$b" > /dev/null || { rm -f "$a" "$b"; echo "research page drifted: $n"; exit 1; }
  rm -f "$a" "$b"
done
# the theme's body text on its background passes AA in light and dark. The pairs are read out of
# the CSS the build just emitted, not out of a hand-typed file, so a theme upgrade that darkens
# the text fails here even if nobody re-measures. The ratio maths is vendored in scripts/, so
# this runs on a bare CI runner with no skills directory.
cr=../scripts/contrast-ratio.sh
test -x "$cr" || { echo "scripts/contrast-ratio.sh missing or not executable"; exit 1; }
live=
for t in light dark; do
  blk=$(cat dist/_astro/*.css | tr -d '\n' | grep -o "data-theme=$t\]{[^}]*}" | head -1)
  fg=$(printf '%s' "$blk" | grep -o -- '--foreground:oklch([^)]*)' | head -1 | sed 's/^--foreground://')
  bg=$(printf '%s' "$blk" | grep -o -- '--background:oklch([^)]*)' | head -1 | sed 's/^--background://')
  [ -n "$fg" ] && [ -n "$bg" ] || { echo "cannot read the $t theme --foreground/--background out of dist/_astro/*.css"; exit 1; }
  "$cr" "$fg" "$bg" || { echo "contrast fails for the $t theme body text on its background"; exit 1; }
  live="$live $t=$fg/$bg"
done
# the measured values on record still describe the theme that just built
base=$(sed -n 's/^# baseline-oklch: *//p' ../docs/site-colors.txt)
if [ "$(echo $live)" != "$(echo $base)" ]; then
  echo "theme colours changed, re-measure docs/site-colors.txt"
  echo "  built CSS: $(echo $live)"
  echo "  baseline:  $(echo $base)"
  exit 1
fi
# and the hex pairs written down in docs/site-colors.txt are still truthful
for pair in $(sed -n 's/^# contrast-pairs: *//p' ../docs/site-colors.txt); do
  "$cr" "${pair%%/*}" "${pair##*/}" || { echo "contrast fails for the recorded pair $pair"; exit 1; }
done
echo "ok: site builds"

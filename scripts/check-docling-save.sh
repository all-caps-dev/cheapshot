#!/bin/sh
# Checks scripts/docling-save without Docling installed: a fake `docling` writes the same three
# outputs the real one does (markdown with absolute picture links, JSON, an _artifacts folder),
# and the script must package them. Runs on a bare macOS or Linux runner with python3.
set -e
cd "$(dirname "$0")/.."
S=scripts/docling-save
test -x "$S" || { echo "$S missing or not executable"; exit 1; }
sh -n "$S" || { echo "$S has a syntax error"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# A fake docling: `docling convert <in.pdf> ... --output <dir>` writes <dir>/<stem>.md, .json, _artifacts/.
cat > "$T/docling" <<'EOF'
#!/bin/sh
in=$2; out=""
while [ $# -gt 0 ]; do [ "$1" = "--output" ] && out=$2; shift; done
stem=$(basename "$in" .pdf)
mkdir -p "$out/${stem}_artifacts"
printf 'png' > "$out/${stem}_artifacts/image_000000_aa.png"
printf '## Slide one\n\n![Image](%s/%s_artifacts/image_000000_aa.png)\n' "$out" "$stem" > "$out/$stem.md"
printf '{"pages": {"1": {}, "2": {}}}' > "$out/$stem.json"
EOF
chmod +x "$T/docling"
printf '%%PDF-1.4 fake\n' > "$T/My Deck & Notes.pdf"

# 1. Usage and errors exit with the documented codes.
DOCLING="$T/docling" "$S" --help > /dev/null 2>&1 && { echo "--help should exit 2"; exit 1; } || [ $? -eq 2 ] || { echo "--help should exit 2"; exit 1; }
DOCLING="$T/docling" "$S" "$T/nope.pdf" > /dev/null 2>&1 && { echo "a missing file should fail"; exit 1; } || true

# 2. A run makes the package, with a slug from the file name and relative picture links.
out=$(PATH="/usr/bin:/bin" DOCLING="$T/docling" DOCLING_PYTHON=python3 "$S" "$T/My Deck & Notes.pdf" --dest "$T/dest" 2>/dev/null)
d="$T/dest/my-deck-notes"
[ "$out" = "$d" ] || { echo "printed path $out, expected $d"; exit 1; }
for f in my-deck-notes.pdf my-deck-notes.docling.md my-deck-notes.docling.json manifest.json images/image_000000_aa.png; do
  test -f "$d/$f" || { echo "package lacks $f"; exit 1; }
done
grep -q '](images/image_000000_aa.png)' "$d/my-deck-notes.docling.md" || { echo "picture link is not relative"; exit 1; }
if grep -q "$T" "$d/my-deck-notes.docling.md"; then echo "markdown still holds a temp path"; exit 1; fi
cmp -s "$T/My Deck & Notes.pdf" "$d/my-deck-notes.pdf" || { echo "the saved PDF is not the original bytes"; exit 1; }
python3 - "$d/manifest.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["pages"] == 2 and m["picture_links"] == 1 and m["picture_files"] == 1, m
assert len(m["sha256"]) == 64 and m["source_file"] == "My Deck & Notes.pdf", m
assert m["page_text"] is None, m   # cheapshot is off PATH in this run
EOF

# 3. An existing folder is never replaced without --force.
PATH="/usr/bin:/bin" DOCLING="$T/docling" DOCLING_PYTHON=python3 "$S" "$T/My Deck & Notes.pdf" --dest "$T/dest" > /dev/null 2>&1 \
  && { echo "a second run without --force should fail"; exit 1; } || true
PATH="/usr/bin:/bin" DOCLING="$T/docling" DOCLING_PYTHON=python3 "$S" "$T/My Deck & Notes.pdf" --dest "$T/dest" --force > /dev/null 2>&1 \
  || { echo "--force should replace the folder"; exit 1; }

echo "ok: docling-save packages a PDF"

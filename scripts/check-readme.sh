#!/bin/sh
set -e
n=$(wc -l < README.md | tr -d "[:space:]")
test "$n" -le 100 || { echo "README is $n lines, limit 100"; exit 1; }
grep -q 'https://all-caps-dev.github.io/cheapshot/' README.md || { echo "README does not link the docs site"; exit 1; }
for h in '## Install' '## Use' '## Redaction' '## Video' '## PDF' '## Ledger' '## Claude Code' '## MCP' '## Docs' '## License'; do
  grep -q "^$h" README.md || { echo "README lacks section $h"; exit 1; }
done
grep -q 'brew install all-caps-dev/tap/cheapshot' README.md || { echo "README lacks the brew line"; exit 1; }
grep -q 'Exit codes: 0 ok, 1 an input failed' README.md || { echo "README lacks the exit-code line"; exit 1; }
if grep -n '!\[[[:space:]]*\]' README.md; then echo "image without alt text"; exit 1; fi
grep -q 'ignore previous instructions' README.md || { echo "README lacks the injection note"; exit 1; }
grep -q 'claude plugin install cheapshot@all-caps-dev' README.md || { echo "README lacks the plugin install line"; exit 1; }
echo "ok: README $n lines"

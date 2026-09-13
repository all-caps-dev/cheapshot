#!/bin/sh
set -e
f=packaging/homebrew/cheapshot.rb
test -f "$f" || { echo "formula missing"; exit 1; }
ruby -c "$f" >/dev/null || { echo "formula does not parse"; exit 1; }
grep -q 'license "MIT"' "$f" || { echo "formula license is not MIT"; exit 1; }
grep -q 'depends_on macos: :ventura' "$f" || { echo "formula must use depends_on macos: :ventura"; exit 1; }
grep -q 'releases/download/v0.5.0/cheapshot-v0.5.0-macos.zip' "$f" || { echo "formula url is wrong"; exit 1; }
grep -q -- '--version' "$f" || { echo "formula test block must run --version"; exit 1; }
if command -v brew >/dev/null; then brew style "$f" || { echo "brew style failed"; exit 1; }; fi
echo "ok: formula"

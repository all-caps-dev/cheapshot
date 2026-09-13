#!/bin/sh
# Builds and tests the MCP package and checks what npm would publish.
set -e
cd "$(dirname "$0")/../mcp"
test "$(node -p 'require("./package.json").name')" = "cheapshot-mcp" || { echo "package name must be cheapshot-mcp"; exit 1; }
test "$(node -p 'require("./package.json").bin["cheapshot-mcp"]')" = "./dist/src/index.js" || { echo "bin must be ./dist/src/index.js"; exit 1; }
if [ -n "$CI" ] || [ ! -d node_modules ]; then npm ci --no-audit --no-fund; fi
npm test
head -1 dist/src/index.js | grep -q '^#!/usr/bin/env node' || { echo "dist/src/index.js lacks the node shebang"; exit 1; }
npm pack --dry-run --json 2>/dev/null | node -e '
  const pkgs = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const files = pkgs[0].files.map(f => f.path);
  const must = ["dist/src/index.js", "dist/src/server.js", "dist/src/args.js", "dist/src/run.js", "README.md", "package.json"];
  for (const m of must) if (!files.includes(m)) { console.error("npm pack would omit " + m); process.exit(1); }
  for (const f of files) if (f.startsWith("dist/test") || f.startsWith("src/")) { console.error("npm pack would ship " + f); process.exit(1); }
'
echo "ok: mcp builds, tests pass, pack contents right"

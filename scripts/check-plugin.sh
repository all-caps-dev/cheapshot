#!/bin/sh
# Manifests parse, names match the spec, every hook path goes through CLAUDE_PLUGIN_ROOT.
set -e
cd "$(dirname "$0")/.."
command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }
for f in .claude-plugin/marketplace.json plugin/.claude-plugin/plugin.json plugin/hooks/hooks.json; do
  test -f "$f" || { echo "$f missing"; exit 1; }
  jq -e . "$f" >/dev/null || { echo "$f is not valid JSON"; exit 1; }
done
test "$(jq -r .name .claude-plugin/marketplace.json)" = "all-caps-dev" || { echo "marketplace name must be all-caps-dev"; exit 1; }
test "$(jq -r '.plugins[0].name' .claude-plugin/marketplace.json)" = "cheapshot" || { echo "marketplace plugin name must be cheapshot"; exit 1; }
test "$(jq -r '.plugins[0].source' .claude-plugin/marketplace.json)" = "./plugin" || { echo "marketplace source must be ./plugin"; exit 1; }
test "$(jq -r .name plugin/.claude-plugin/plugin.json)" = "cheapshot" || { echo "plugin name must be cheapshot"; exit 1; }
jq -e '.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' plugin/.claude-plugin/plugin.json >/dev/null || { echo "plugin.json needs a semver version"; exit 1; }
test "$(jq -r .hooks plugin/.claude-plugin/plugin.json)" = "./hooks/hooks.json" || { echo "plugin.json hooks pointer wrong"; exit 1; }
test "$(jq -r '.hooks.PreToolUse[0].matcher' plugin/hooks/hooks.json)" = "Read" || { echo "hook matcher must be Read"; exit 1; }
jq -e '.owner.name | type == "string" and length > 0' .claude-plugin/marketplace.json >/dev/null || { echo "marketplace.json needs a non-empty owner.name"; exit 1; }
jq -e '.hooks.PreToolUse[0].hooks[0].type == "command"' plugin/hooks/hooks.json >/dev/null || { echo "hook type must be command"; exit 1; }
jq -e '.hooks.PreToolUse[0].hooks[0].timeout | type == "number"' plugin/hooks/hooks.json >/dev/null || { echo "hook timeout must be a number"; exit 1; }
cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' plugin/hooks/hooks.json)
case "$cmd" in
  *'${CLAUDE_PLUGIN_ROOT}'*/hooks/cheapshot-read.sh) ;;
  *) echo "hook command must go through \${CLAUDE_PLUGIN_ROOT}/hooks/cheapshot-read.sh, got $cmd"; exit 1 ;;
esac
test -x plugin/hooks/cheapshot-read.sh || { echo "hook is not executable"; exit 1; }
test -x plugin/tests/fake-bin/cheapshot || { echo "fake binary is not executable"; exit 1; }
plugin/tests/test-hook.sh
echo "ok: plugin manifests"

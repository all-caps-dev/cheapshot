# Phase 3 runbook: plugin, MCP package, status line

Everything below is a hand step for Ryan unless marked AGENT. Do them in order, after the Phase 2 runbook has reached step 9 (v0.5.0 is tagged and `brew install all-caps-dev/tap/cheapshot` works), because the plugin and the MCP server both depend on the brew binary.

## 0. Preconditions (AGENT, done in Phase 3)
- `scripts/check-phase3.sh` prints `ok: phase 3` on a clean main.
- `plugin/.claude-plugin/plugin.json` and `mcp/package.json` are both at `0.1.0`.

## 1. Re-sign the unsigned commits, then push main (RYAN, 5 minutes)
1Password was locked for most of Phase 3, so every commit after `0dcbd03` on main is unsigned (`git log --format='%h %G? %s' 0dcbd03..HEAD` shows `N` on each). Re-sign them before anything leaves this machine:

```sh
git rebase --exec 'git commit --amend --no-edit -S' 0dcbd03
git log --format='%h %G? %s' 0dcbd03..HEAD   # every line must show G
```

Then `git push origin main`. Verify: https://github.com/all-caps-dev/cheapshot/actions shows the CI workflow green, including the `plugin-and-mcp` job.

## 2. npm account (RYAN, 10 minutes, once)
1. https://www.npmjs.com/signup with the all-caps-dev email. Turn on two-factor auth at https://www.npmjs.com/settings/~/tfa (npm requires it to publish).
2. In a terminal: `npm login` (opens the browser), then `npm whoami` prints the account.
3. Check the name is free: `npm view cheapshot-mcp` should print a 404. If it is taken, the fallback name is `@all-caps-dev/cheapshot-mcp`; that needs the org at https://www.npmjs.com/org/create, and `mcp/package.json` `name`, `plugin/.mcp.json`, `mcp/README.md`, `README.md`, and `site/src/content/docs/mcp.md` all change with it (AGENT, one commit).

## 3. Publish the MCP package (RYAN, 5 minutes)
```sh
cd mcp && npm ci && npm test && npm pack --dry-run
npm publish --access public
```
Verify: https://www.npmjs.com/package/cheapshot-mcp shows 0.1.0, and from a temp directory `printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}\n' | npx -y cheapshot-mcp | head -c 300` prints a JSON-RPC result with `"name":"cheapshot"`.

## 4. Install the plugin on this Mac (RYAN, 5 minutes)
```sh
claude plugin marketplace add all-caps-dev/cheapshot
claude plugin install cheapshot@all-caps-dev
```
Verify, in a new `claude` session in any folder that holds a png:
1. Ask it to read the png. Expected: the reply quotes the text, the terminal shows `cheapshot: N image tokens -> M text tokens ...` on stderr, and `cheapshot --ledger` grew by one run.
2. Ask it to describe the layout. Expected: it runs `cheapshot allow <path>` in Bash, then Reads the image and sees pixels.
3. `/mcp` lists `cheapshot` with three tools.
If the hook does not fire, `claude --debug` shows the hook registration; the common cause is a plugin cache from before an edit, fixed by `/plugin marketplace update` then `/reload-plugins`.

## 5. Status line (RYAN, 2 minutes, optional)
Follow the "Status line" section on https://all-caps-dev.github.io/cheapshot/claude-code/#status-line . The copy step in either form:

```sh
cp "$(claude plugin list --json | jq -r '.[] | select(.id=="cheapshot@all-caps-dev") | .installPath')/scripts/cheapshot-statusline.sh" ~/.claude/cheapshot-statusline.sh
# or, without jq (the version segment changes with each plugin release):
cp ~/.claude/plugins/cache/all-caps-dev/cheapshot/0.1.0/scripts/cheapshot-statusline.sh ~/.claude/cheapshot-statusline.sh
```

Then add `{ "statusLine": { "type": "command", "command": "~/.claude/cheapshot-statusline.sh" } }` to `~/.claude/settings.json`. Verify: the bottom of the Claude Code window shows `cheapshot: <n> saved`.

## 6. Announce the site pages (AGENT then RYAN)
AGENT: nothing; the pages deployed with step 1. RYAN: open https://all-caps-dev.github.io/cheapshot/claude-code/ and https://all-caps-dev.github.io/cheapshot/mcp/ and confirm both render and appear in the sidebar.

## Releasing later versions
Bump `plugin/.claude-plugin/plugin.json` `version` and `.claude-plugin/marketplace.json` `plugins[0].version` together (the marketplace version drives update checks). Bump `mcp/package.json` and `npm publish` from `mcp/`. Neither is tied to the binary's version; the binary is upgraded by brew.

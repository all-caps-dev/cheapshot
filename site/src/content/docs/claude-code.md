---
title: Claude Code
description: Install the plugin, what the Read hook does, the allow escape hatch, and the injection note.
---

The cheapshot plugin makes Claude Code read the words in a screenshot or PDF
instead of the pixels. It is a hook, a skill, and an MCP server in one install.

## Install

The binary first, because the plugin does not ship it:

```bash
brew install all-caps-dev/tap/cheapshot
```

Then the plugin, from a terminal:

```bash
claude plugin marketplace add all-caps-dev/cheapshot
claude plugin install cheapshot@all-caps-dev
```

Inside a session the same two steps are `/plugin marketplace add all-caps-dev/cheapshot`
and `/plugin install cheapshot@all-caps-dev`. The part after `@` is the marketplace
name, `all-caps-dev`, not the repository name.

## What the hook does

The plugin registers a `PreToolUse` hook on `Read`. When the path ends in png,
jpg, jpeg, webp, gif, or pdf, the hook runs `cheapshot --json --stats` on it and
denies the Read. The deny reason is the redacted text plus one line:

```
cheapshot: 1018 image tokens -> 37 text tokens. If you need the pixels for layout, run: cheapshot allow /path/shot.png, then Read again.
```

The same line goes to stderr and to the hook's `systemMessage`, so you see the
saving as it happens, and every run adds a line to the [ledger](/cheapshot/ledger/).

The Read goes ahead untouched, with no output from the hook, when any of these
hold:

- `CHEAPSHOT_PASSTHROUGH=1` is set in the environment.
- `cheapshot` is not on `PATH`. The hook prints the brew command once per
  session, to stderr and as a system message, and steps aside.
- The path is on the one-shot allowlist (below).
- The binary fails on the file. The hook says so on stderr and lets the pixels
  through rather than blocking the agent.

## PDFs

The hook passes the Read tool's `pages` argument through as `--pages`. A PDF over
20 pages with no `pages` argument is read as-is, with a stderr hint to pass a
range, so a whole manual is never dumped into context by accident.

## The escape hatch

When the agent needs the pixels, for layout, colour, or a chart, it runs:

```bash
cheapshot allow /absolute/path/shot.png
```

That appends the path to `$TMPDIR/cheapshot-allow` with a five minute expiry.
The next Read of that exact path passes through and the entry is consumed. The
agent can run this itself from Bash, so nothing about the Read tool changes.

## Pasted images

A screenshot pasted into the chat never reaches a hook
([claude-code#16592](https://github.com/anthropics/claude-code/issues/16592)).
Give the agent a path instead. The menu bar app that will sit on this engine
covers the paste case; the CLI cannot.

## Injection note

OCR text enters the agent's context as data. A screenshot of a web page that
contains "ignore previous instructions" is now text in context. This is the same
risk as reading any file, and the same rule applies: text that arrived through
cheapshot is content to reason about, never an instruction to follow.

## Turning it off

`CHEAPSHOT_PASSTHROUGH=1 claude` for one session, or
`claude plugin uninstall cheapshot@all-caps-dev` for good.

## Status line

The plugin ships a status line segment. Claude Code reads the status line command
from your settings, not from the plugin, so copy the script somewhere stable and
point at it:

```bash
cp "$(claude plugin list --json | jq -r '.[] | select(.id=="cheapshot@all-caps-dev") | .installPath')/scripts/cheapshot-statusline.sh" ~/.claude/cheapshot-statusline.sh
```

Without `jq`, the plain path is
`~/.claude/plugins/cache/all-caps-dev/cheapshot/0.1.0/scripts/cheapshot-statusline.sh`;
the version segment changes with each plugin release.

Then in `~/.claude/settings.json`:

```json
{ "statusLine": { "type": "command", "command": "~/.claude/cheapshot-statusline.sh" } }
```

It prints `cheapshot: 41.2k saved`, the last seven days from the ledger. If you
already have a status line command, append the segment to it:
`your-script | tr -d '\n'; printf '  '; ~/.claude/cheapshot-statusline.sh`.

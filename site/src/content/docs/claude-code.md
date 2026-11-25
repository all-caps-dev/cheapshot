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

```text wrap
cheapshot: 1018 image tokens -> 37 text tokens. If you need the pixels for layout, ask the user to approve it.
```

You get the same saving on stderr and in the hook's `systemMessage`, with the
command to approve the pixels yourself, and every run adds a line to the
[ledger](/cheapshot/ledger/):

```text wrap
cheapshot: 1018 image tokens -> 37 text tokens. To show the agent the pixels, run in a terminal: cheapshot allow '/path/shot.png'
```

The path is shell-quoted, so a macOS screenshot name with spaces pastes as one
argument.

The Read goes ahead with the pixels when any of these hold. Each one except a
missing binary or `jq` adds a zero-token `passthrough` line with its reason to
the ledger, and `cheapshot --ledger` counts them:

- `CHEAPSHOT_PASSTHROUGH=1` is set in the environment.
- `cheapshot` is not on `PATH`. The hook prints the brew command once per
  session, to stderr and as a system message, and steps aside.
- `jq` is not on `PATH`. The hook steps aside with no message, so install it
  with `brew install jq`.
- The path is on the one-shot allowlist (below).
- The binary fails on the file. The hook says so in a system message and lets
  the pixels through rather than blocking the agent.
- The path starts with `-`, so it would parse as a flag. The hook never hands
  it to the binary and says so in a system message.
- OCR finds no text in a photo or a small image (`ocr_status` `"empty"` with no
  retry), or in a PDF. There is nothing to redact, so the pixels are the content.

An image with no text that does not look like a photo is denied in every mode,
never passed as pixels: a screenshot that still read blank after the cold-start
retry (`"empty"` with `"retried": true`), a result with no usable `ocr_status`,
and any image read by a binary older than 0.6.0, which reports neither field and
so cannot tell a photo from a failed read. Look at the image yourself, then run
`cheapshot allow <path>` in a terminal, or `cheapshot mask <path>` for a copy with
any text it finds blacked out. When text was found but OCR was retried, the
redacted text is still returned, with a note that some lines may be missing.

## Strict mode

Set `CHEAPSHOT_STRICT=1` and every failure above (missing binary, missing `jq`,
a binary error, unreadable output, a PDF over 20 pages with no range, a path
that starts with `-`) denies the Read instead of passing the pixels through.
`CHEAPSHOT_PASSTHROUGH=1` and `cheapshot allow` still work, because those are
your decisions. Strict mode still lets a photo or a PDF with no recognised text
through: that is not a failure, and there is no text to redact. It is recorded in
the ledger as a `no_text` pass-through. A blank screenshot is denied in both modes
(above).

The plugin's MCP tools refuse `raw: true` unless `CHEAPSHOT_ALLOW_RAW=1` is set
in the environment that starts Claude Code; see the [MCP page](/cheapshot/mcp/#environment).

## Custom rules

The hook and the MCP server never pass `--rules`, so cheapshot looks for rules
itself: `$CHEAPSHOT_RULES` if set, else `rules.json` next to the ledger
(`~/Library/Application Support/cheapshot/rules.json`, or `$CHEAPSHOT_HOME`).
A file you name with `--rules` or `$CHEAPSHOT_RULES` that is missing or broken
stops the run, and the hook denies the Read in every mode, since passing the
pixels would skip the built-in redaction too. A broken default `rules.json` is
skipped with a warning and the built-in rules still run. Both lookups need
cheapshot 0.6.0 or later; older binaries read `--rules` only.

## PDFs

The hook passes the Read tool's `pages` argument through as `--pages`. A PDF over
20 pages with no `pages` argument is read as-is, with a stderr hint to pass a
range, so a whole manual is never dumped into context by accident.

## The escape hatch

When the agent needs the pixels, for layout, colour, or a chart, it asks you,
and you run this in a terminal:

```bash
cheapshot allow /absolute/path/shot.png
```

That appends the path to `$TMPDIR/cheapshot-allow` with a five minute expiry.
The next Read of that exact path passes through and the entry is consumed.
`allow` (0.6.0 or later) refuses to run unless stdin and stdout are a terminal
and it is in that terminal's foreground process group, so cheapshot stops
offering the agent the bypass. It is not a sandbox: a model with a free Bash
tool runs as you and can still fake a terminal (`script`) or write the file.

## Pasted images

A screenshot pasted into the chat never reaches a hook
([claude-code#16592](https://github.com/anthropics/claude-code/issues/16592)).
Give the agent a path instead. The menu bar app that will sit on this engine
covers the paste case, and we're working on handling pasted images automatically
in the plugin too.

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

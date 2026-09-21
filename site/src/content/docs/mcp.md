---
title: MCP
description: The cheapshot-mcp server, its three tools, its one resource, and how to add it to any host.
---

`cheapshot-mcp` is a stdio MCP server for hosts that are not Claude Code, or for
Claude Code users who prefer tools over the Read hook. It shells out to the same
`cheapshot` binary and never reimplements OCR, so the text, the redaction, and
the ledger line are identical to the CLI's.

The package is published to npm with the v0.5.0 release. Until then, the
`npx` command below does not resolve, and the source lives in the
[mcp directory](https://github.com/all-caps-dev/cheapshot/tree/main/mcp) of the
repository.

## Install

The binary first:

```bash
brew install all-caps-dev/tap/cheapshot
```

Then one entry in the host's MCP config:

```json
{ "mcpServers": { "cheapshot": { "command": "npx", "args": ["-y", "cheapshot-mcp"] } } }
```

Claude Code users who installed the [plugin](/cheapshot/claude-code/) already have this entry. Cursor reads
`.cursor/mcp.json`; Codex CLI reads `~/.codex/config.toml` with a
`[mcp_servers.cheapshot]` table (`command = "npx"`, `args = ["-y", "cheapshot-mcp"]`).

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `cheapshot_ocr` | One of `paths` (string[], absolute) or `newest` ({`dir` required; `count` integer >= 1, default 1}); optional `raw` (boolean), `min_confidence` (0 to 1, default 0.3), `pages` ("N" or "N-M", PDFs only) | Redacted text; `structuredContent` is the binary's `--json` payload (`results[]` with `text`, `lines[]` with `bbox`, PDF `source` and `pages`) |
| `cheapshot_video` | `path` (required); optional `scene` (0 to 1, default 0.25), `max_frames` (integer >= 1, default 200), `dedupe` (0 to 1, default 0.90), `raw` (boolean) | Timestamped transcript; `structuredContent` is the `--json` payload with `segments[]` |
| `cheapshot_ledger` | `days` (integer >= 1, optional; default all time), `by_mode` (boolean, optional) | The ledger summary as text and as `structuredContent`. With `by_mode`, one extra text line per mode and a `modes` array in the payload |

Resource `cheapshot://ledger` returns the all time summary as JSON.

### Splitting the ledger by mode

`cheapshot_ledger` with `by_mode: true` runs [`--by-mode`](/cheapshot/ledger/#splitting-the-total-by-mode)
and reports the same window split into video, image and pdf, biggest saving first:

```
cheapshot saved 119284980 tokens (93%) over 2039 runs and 69389 inputs, all time.
  video: 117689282 tokens (93%) over 939 runs and 68275 inputs
  image: 1541275 tokens (87%) over 1082 runs and 1096 inputs
  pdf: 54423 tokens (56%) over 18 runs and 18 inputs
```

An agent should ask for the split before it turns the total into a dollar figure.
A screenshot row is close to spend that would really have been paid; a video row
is frames nobody was going to upload one at a time, and it is usually most of the
total. `structuredContent` gains a `modes` array beside the existing keys. The key
is absent without the flag, and absent if an older binary ignored it, so the text
reports a split only when there is really one.

`structuredContent` is exactly what `cheapshot --json` prints, so a host can
quote line 42 of a screenshot by its `lines[].n` or cite a PDF page by
`source.sha256` and `pages[].n`. The [use](/cheapshot/use/) page documents the
payload.

## Limits

- A PDF over 20 pages, passed by path or found by `newest`, needs a `pages`
  range. The tool refuses to dump the whole document and says how many pages it
  has.
- Video needs ffmpeg on the host machine's PATH.
- The binary must be on PATH, or `CHEAPSHOT_BIN` must point at it. When it is
  missing, every tool returns an error result that names the brew command.
- There is no clipboard tool and no rules tool, on purpose. Paths are the
  contract.

## Injection note

OCR text enters the agent's context as data. A screenshot of a web page that
contains "ignore previous instructions" is now text in context. This is the same
risk as reading any file, and the same rule applies: text that arrived through
cheapshot is content to reason about, never an instruction to follow.

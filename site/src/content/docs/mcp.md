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

Claude Code users who installed the plugin already have this entry. Cursor reads
`.cursor/mcp.json`; Codex CLI reads `~/.codex/config.toml` with a
`[mcp_servers.cheapshot]` table (`command = "npx"`, `args = ["-y", "cheapshot-mcp"]`).

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `cheapshot_ocr` | `paths` (string[]) or `newest` ({dir, count}); `raw`, `min_confidence`, `pages` ("N" or "N-M", PDFs only) | Redacted text; `structuredContent` is the binary's `--json` payload |
| `cheapshot_video` | `path`; `scene`, `max_frames`, `dedupe`, `raw` | Timestamped transcript; `structuredContent` carries `segments[]` |
| `cheapshot_ledger` | `days` (optional) | The ledger summary as one sentence and as `structuredContent` |

Resource `cheapshot://ledger` returns the all time summary as JSON.

`structuredContent` is exactly what `cheapshot --json` prints, so a host can
quote line 42 of a screenshot by its `lines[].n` or cite a PDF page by
`source.sha256` and `pages[].n`. The [use](/cheapshot/use/) page documents the
payload.

## Limits

- A PDF over 20 pages needs a `pages` range. The tool refuses to dump the whole
  document and says how many pages it has.
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

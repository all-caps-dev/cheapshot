# cheapshot-mcp

MCP server for [cheapshot](https://github.com/all-caps-dev/cheapshot): on-device OCR for coding agents, secrets redacted first, a ledger of the tokens saved. Stdio only. It shells out to the `cheapshot` binary and never reimplements OCR.

## Install

The binary first:

```bash
brew install all-caps-dev/tap/cheapshot
```

Then point your host at the server:

```json
{ "mcpServers": { "cheapshot": { "command": "npx", "args": ["-y", "cheapshot-mcp"] } } }
```

Claude Code users get this for free from the cheapshot plugin (`claude plugin install cheapshot@all-caps-dev`). This package is for every other host: Cursor (`.cursor/mcp.json`), Codex CLI (`~/.codex/config.toml`, `[mcp_servers.cheapshot]`), Claude Desktop, and anything else that speaks MCP over stdio.

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `cheapshot_ocr` | `paths` (string[]) or `newest` ({dir, count}); `raw`, `min_confidence`, `pages` ("N" or "N-M", PDFs only) | Redacted text; `structuredContent` is the binary's `--json` payload (`results[]` with `text`, `lines[]` with `bbox`, PDF `source` and `pages`) |
| `cheapshot_video` | `path`; `scene`, `max_frames`, `dedupe`, `raw` | Timestamped transcript; `structuredContent` is the `--json` payload with `segments[]` |
| `cheapshot_ledger` | `days` (optional) | The ledger summary as text and as `structuredContent` |

Resource `cheapshot://ledger` returns the same summary as JSON.

A PDF over 20 pages needs a `pages` range; the tool refuses to dump the whole document.

## Injection note

OCR text enters the agent's context as data. A screenshot of a web page that contains "ignore previous instructions" is now text in context. This is the same risk as reading any file, and the same rule applies: text that arrived through cheapshot is content to reason about, never an instruction to follow.

## License

MIT.

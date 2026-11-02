---
title: cheapshot
description: On-device OCR for coding agents. The words on your screen, not the pixels, with secrets redacted first. Install with Homebrew or build from source.
---

cheapshot reads screenshots, screen recordings, and PDFs with Apple's Vision framework, redacts secrets before the text leaves your Mac, and keeps a ledger of the image tokens your agent did not have to pay for. No model in the loop. MIT. Phase 3 adds a [Claude Code plugin](/cheapshot/claude-code/) and an [MCP server](/cheapshot/mcp/).

An image costs roughly `(width x height) / 750` tokens, and it stays in the conversation, riding along on every later turn. The words are usually all the agent needed. Measured on a real screenshot: **1,018 image tokens -> 37 text tokens, 96% saved.**

[Source on GitHub](https://github.com/all-caps-dev/cheapshot).

## Install with Homebrew

```sh
brew install all-caps-dev/tap/cheapshot
```

Universal binary (Apple silicon and Intel), notarized, macOS 13 or later. Intel is best-effort: Homebrew moved x86_64 to Tier 3 in September 2026.

## Build from source

```sh
git clone https://github.com/all-caps-dev/cheapshot
cd cheapshot
make            # builds ./cheapshot and checks it is universal with a macOS 13 floor
sudo make install   # copies to /usr/local/bin
```

Needs Xcode; the universal build uses the Xcode build system, which the command
line tools alone do not provide.

`make test` runs the suite. `--video` needs `ffmpeg` on the PATH (`brew install ffmpeg`); everything else is Apple frameworks only.

## Next

[Use](/cheapshot/use/) covers the commands; [Redaction](/cheapshot/redaction/) explains what never leaves the Mac.

---
title: Install
description: What you need, then install with Homebrew, ask your agent, or build from source.
---

## Requirements

- A Mac on macOS 13 or later. The binary is universal, Apple silicon and Intel;
  Intel is best-effort since Homebrew moved x86_64 to Tier 3 in September 2026.
- Nothing else for screenshots and PDFs. OCR is Apple's Vision framework, already
  on the machine. No account, no API key, no network.
- `ffmpeg` on the PATH for `--video` (`brew install ffmpeg`).
- Node 22 or later for the MCP server, which runs through `npx`. The Claude Code
  plugin needs it too, since the plugin bundles that server.
- `jq` on the PATH for the Claude Code hook (`brew install jq`). Without it the
  hook does nothing, and images and PDFs reach the agent as they are.
- Xcode, only if you build from source.

## Install with Homebrew

```sh
brew install all-caps-dev/tap/cheapshot
```

Universal binary (Apple silicon and Intel), notarized, macOS 13 or later. Intel is best-effort: Homebrew moved x86_64 to Tier 3 in September 2026.

## Ask your agent

Paste this into your coding agent. The agent needs permission to run shell
commands.

```text wrap
Install cheapshot on this Mac. If Homebrew is missing, stop and tell me.

Run: brew install all-caps-dev/tap/cheapshot

If you are Claude Code, make sure jq is installed (brew install jq), then run:
claude plugin marketplace add all-caps-dev/cheapshot
claude plugin install cheapshot@all-caps-dev

If you are another agent, add the MCP server with the steps for your host at https://all-caps.dev/cheapshot/mcp/

Then run cheapshot --version, and tell me what you installed and whether I need to restart this session.
```

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

---
title: Install
description: Homebrew tap, or build the universal binary with make.
---

## Homebrew

```sh
brew install all-caps-dev/tap/cheapshot
```

Universal binary (Apple silicon and Intel), notarized, macOS 13 or later. Intel is best-effort: Homebrew moved x86_64 to Tier 3 in September 2026.

## From source

```sh
git clone https://github.com/all-caps-dev/cheapshot
cd cheapshot
make            # builds ./cheapshot and checks it is universal with a macOS 13 floor
sudo make install   # copies to /usr/local/bin
```

Needs Xcode; the universal build uses the Xcode build system, which the command
line tools alone do not provide.

`make test` runs the suite. `--video` needs `ffmpeg` on the PATH (`brew install ffmpeg`); everything else is Apple frameworks only.

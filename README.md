# ocra

On-device screenshot OCR for AI agents. Turns screenshots into **redacted text**
so agents read words instead of pixels.

Apple Vision framework. No network. No API cost. macOS only.

## Why

An image costs roughly `(width x height) / 750` tokens, and it stays in the
conversation, riding along on every later turn. The words are usually all the
agent needed. Measured on a real screenshot: **1,018 image tokens -> 37 text
tokens, 96% saved.**

Screenshots are also full of things you do not want in an agent's context.
`ocra` redacts by default.

## Install

```bash
swiftc -O ocra.swift -o ocra -framework Vision -framework AppKit
cp ocra ~/local-dev/bin/
```

## Use

```bash
ocra shot.png                 # OCR one file, redacted
ocra --cleanshot              # newest CleanShot capture
ocra --cleanshot 3            # newest three
ocra --newest ~/Desktop 2     # newest two in any folder
ocra --raw shot.png           # skip redaction
ocra --json shot.png          # structured output with redaction counts
ocra --stats shot.png         # token savings to stderr
```

## Redaction

On by default. Ordered most-specific first so a key is never eaten by a looser
rule.

| Rule | Catches |
|---|---|
| `AWS_KEY` | AKIA/ASIA/AGPA/AIDA/AROA/ANPA + 16 |
| `GITHUB_PAT` | ghp_ gho_ ghu_ ghs_ ghr_ github_pat_ |
| `OPENAI_KEY` | sk-, sk-proj-, sk-ant-, sk-live- |
| `SLACK_TOKEN` | xoxb/xoxp/xoxa/xoxo/xoxs/xoxr |
| `JWT` | three base64url segments |
| `PRIVATE_KEY` | PEM header |
| `BEARER` | Authorization: Bearer ... |
| `EMAIL` | addresses |
| `SSN` | US, with invalid-prefix exclusions |
| `CARD` | 13-19 digits, **Luhn-validated** |
| `PHONE` | US formats |
| `TOKEN` | opaque mixed-case runs 20+ chars |
| `IPV4` | dotted quads |

### Known limit

OCR garbles long random strings (`0` -> `Ø`, `l` -> `I`). A garbled secret can
break a specific rule and survive as a fragment; the `TOKEN` catch-all exists to
sweep those up. Redaction is best-effort on OCR output, not a guarantee. Do not
point this at something whose secrets must never leak, and use `--raw` only when
you know what is in the frame.

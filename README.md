# cheapshot

On-device screenshot OCR for AI agents. Turns screenshots into **redacted text**
so agents read words instead of pixels.

Apple Vision framework. No network. No API cost. macOS only.

## Why

An image costs roughly `(width x height) / 750` tokens, and it stays in the
conversation, riding along on every later turn. The words are usually all the
agent needed. Measured on a real screenshot: **1,018 image tokens -> 37 text
tokens, 96% saved.**

Screenshots are also full of things you do not want in an agent's context.
`cheapshot` redacts by default.

## Install

```bash
make            # universal binary at ./cheapshot, macOS 13 or newer
make install    # copies it to /usr/local/bin (PREFIX=... to change)
```

Needs the Xcode command line tools. `swift test` runs the test suite.

## Use

```bash
cheapshot shot.png                 # OCR one file, redacted
cheapshot report.pdf               # PDF, text layer or OCR per page
cheapshot --pages 3-5 report.pdf   # a page range
cheapshot --cleanshot              # newest CleanShot capture (falls back to ~/Desktop)
cheapshot --cleanshot 3            # newest three
cheapshot --newest ~/Desktop 2     # newest two in any folder
cheapshot --raw shot.png           # skip redaction
cheapshot --json shot.png          # structured output: text, lines with boxes, redaction counts
cheapshot --stats shot.png         # token savings to stderr
cheapshot --rules my-rules.json shot.png   # extra redaction rules
cat notes.txt | cheapshot --text - # redact text with no OCR at all

cheapshot --video screen.mp4       # screen recording to a timestamped transcript
cheapshot --ledger                 # cumulative savings across every run
```

Exit codes: 0 ok, 1 an input failed (its `--json` entry carries `"error"`), 2 usage error.

Screenshots of code keep their shape: lines in a fixed-width font are wrapped in a code fence
and their indentation is rebuilt from the bounding boxes, and those regions are recognized with
language correction off so hashes and tokens are not "corrected" into words.

Custom rules are a JSON array: `[{"name": "TICKET", "pattern": "\\bINT-\\d{6}\\b", "caseInsensitive": true}]`.
They run before the built-in rules.

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
| `EMAIL` | addresses; a scale suffix like `@2x.png` is not one |
| `SSN` | US, with invalid-prefix exclusions |
| `CARD` | 13-19 digits, **Luhn-validated** |
| `PHONE` | US formats |
| `ROUTING` | 9-digit ABA, **checksum-validated** |
| `BANK_ACCT` | 8 to 17 digits after an account cue (`acct`, `account`, `a/c`, `micr`) or a redacted routing number; bare digit runs survive |
| `TOKEN` | opaque mixed-case runs 20+ chars |
| `IPV4` | dotted quads |

### Known limit

OCR garbles long random strings (`0` -> `Ø`, `l` -> `I`). A garbled secret can
break a specific rule and survive as a fragment; the `TOKEN` catch-all exists to
sweep those up. Redaction is best-effort on OCR output, not a guarantee. Do not
point this at something whose secrets must never leak, and use `--raw` only when
you know what is in the frame.

## The other thing it is for

Cheapshot started as a way to spend fewer tokens. It turned out to also be the
only lawful way to hand an agent a page it is not allowed to fetch.

Bot protection fingerprints the TLS handshake and runs a JavaScript proof of
work. `curl` fails both, and every tool that defeats it is bot detection
evasion. So an agent asking for a retailer's live inventory, a bank statement,
an authenticated dashboard, an IPMI console, a native app with no API, or
anything behind a login is stuck, permanently, by design.

You are not stuck. You are allowed to see the page. You are looking at it.

```bash
cheapshot --cleanshot
```

The human is the credential. Cheapshot is the transport. Nothing is forged,
nothing is evaded, and no check is defeated. A person who is permitted to see
something reads it to their tools.

This is also why redaction is on by default. The pages worth doing this with
are the ones with account numbers on them.

## Video

`--video` is the same idea aimed at screen recordings. Agents normally read a
video by sampling frames and sending each one as an image, which costs thousands
of tokens per frame. Cheapshot instead asks ffmpeg for only the frames where the
screen actually changed, OCRs those locally, drops any screen nearly identical
to the one before it, and emits a timestamped transcript.

Measured on a 13 minute, 2.9 GB screen recording at 2560x1440: 12 scene frames,
**22,128 image tokens to 1,091 text tokens, 95% saved.**

Options: `--scene <f>` change threshold, default 0.25. `--max-frames <n>`,
default 200. `--dedupe <f>` drop a screen this similar to the last, default 0.90.

Requires ffmpeg on your PATH. Cheapshot uses whichever one you have.

Frames are sampled at 4 per second, static stretches are dropped before scene
scoring, and only changed frames are written (`-fps_mode vfr`), so `--max-frames`
counts kept frames, not input frames.

## PDF

`cheapshot report.pdf` and `cheapshot --pages 3-5 report.pdf`. Pages with a text layer are
read through PDFKit (the text lane, free, fonts kept so code is fenced); pages without one are
rendered at 2x and OCR'd like a screenshot (the scan lane). The plain output separates pages
with `--- page N ---`. `--json` adds `source.sha256` and `pages[].lane` so a downstream tool
can cite a page and route scanned pages for review. Redaction and the ledger apply as for
images; the ledger counts what an agent would pay to read each page as an image. In the text
lane a line's `bbox` is in PDF points in the page's own unrotated coordinate space, while the
page `width` and `height` in `--json` are the rendered pixel size after rotation.

## Ledger

Every run appends one JSON line to `~/Library/Application Support/cheapshot/ledger.jsonl`
(or `$CHEAPSHOT_HOME/ledger.jsonl` if that variable is set):

```
{"image_tokens":1550,"inputs":1,"mode":"image","redactions":10,"saved":1496,"text_tokens":54,"ts":"2026-09-08T01:05:35Z"}
```

`mode` is `image`, `pdf` or `video`, and a run that mixes PDFs and screenshots writes one line
per kind, because the PDF number is an estimate of what reading the pages as images would have
cost rather than a measured saving. `--ledger` totals it, `--ledger --json` prints the totals as
JSON, `--no-ledger` skips recording a run. Upgrading from 0.4.x:
`cheapshot --ledger --migrate` imports the old `~/.claude/cheapshot-ledger/*.tsv` files once and
leaves them in place.

## Why there is no LLM in the pipeline

macOS 26 ships Apple's on-device Foundation Models, and the obvious move is to
pipe OCR text through it to compress or to catch PII that regex misses. It was
built and cut in the same hour. Measured on real input:

- **compression fabricated.** Given a screenshot of a 1Password dialog, the model
  appended an invented paragraph about a password-sharing feature that appeared
  nowhere on screen.
- **semantic redaction silently deleted words.** `SSN 123-45-6789` came back as
  `[SSN]` with the label gone; `github ghp_...` lost `github`.

The entire value of this tool is that the text it hands an agent is what was
actually on the screen. A layer that invents and deletes is worse than the tokens
it saves. Vision OCR plus deterministic regex it is.

## License

MIT. See [LICENSE](LICENSE). The Mac App Store app that will sit on this engine is a separate, private repo; the engine and the CLI stay MIT.

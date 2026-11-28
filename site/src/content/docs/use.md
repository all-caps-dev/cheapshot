---
title: Use
description: The command list, the flag groups, and the exit codes.
---

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
cheapshot --ledger --days 7        # savings for the last week
```

`cheapshot allow <path>` lets the next Read of that image or PDF through the
[Claude Code](/cheapshot/claude-code/) plugin's hook for five minutes.

Exit codes: 0 ok, 1 an input failed (its `--json` entry carries `"error"`), 2 usage error.

Screenshots of code keep their shape: lines in a fixed-width font are wrapped in a code fence
and their indentation is rebuilt from the bounding boxes, and those regions are recognized with
language correction off so hashes and tokens are not "corrected" into words.

Custom rules are a JSON array: `[{"name": "TICKET", "pattern": "\\bINT-\\d{6}\\b", "caseInsensitive": true}]`.
They run before the built-in rules.

## Input modes

Every run starts by naming what to read. Pass one or more files directly
(`cheapshot <file.png|file.pdf> [more ...]`), or let cheapshot find them:
`cheapshot --newest [dir] [n]` takes the newest `n` files in a folder and
`cheapshot --cleanshot [n]` takes the newest `n` CleanShot captures. Two modes
skip image OCR entirely: `cheapshot --video <file.mp4>` walks a screen
recording, and `cheapshot --text <file|->` redacts text that is already text
(`-` reads stdin). `cheapshot --ledger [--json] [--migrate] [--days <n>]` reports instead of
reading anything.

## Redaction

Redaction is on by default. `--raw` turns it off and prints the OCR text as
recognized. `--rules <file>` adds your own patterns on top of the built-ins,
as JSON `[{name, pattern, caseInsensitive}]`.

## Output

`--json` emits JSON instead of plain text. `--stats` prints the token savings
to stderr, so it composes with either output form.

### JSON output

The payload is one object: `version`, `results[]`, and the run totals
`image_tokens` and `text_tokens`. Each `results[]` entry is one input:

| Field | Meaning |
|---|---|
| `file` | The input path. |
| `text` | The full text after redaction. Lines are joined by newlines, and a block read as code is wrapped in triple-backtick fence lines. |
| `image_tokens` | The estimated token cost of the image. |
| `text_tokens` | The estimated token cost of the text instead. |
| `redactions` | Map of redaction rule name to hit count. `{}` means nothing was redacted. |
| `lines[]` | Images only. One object per recognized line: `n` (1-based), `text`, `bbox`, `confidence`. |
| `error` | On a failed input, an error message. A failed entry carries only `file` and `error`. |

`bbox` is `[minX, minY, maxX, maxY]` in image pixels, top left origin.
`confidence` runs 0 to 1; lines under `--min-conf` (default `0.3`) are dropped,
from `lines[]` and from `text` alike.

Image results also carry three fields, 0.6.0 and later:

- `ocr_status`: `ok` when the pass found text, `empty` otherwise.
- `retried`: true when a second OCR pass ran (the cold start retry).
- `screenshot_like`: the image heuristic that gated that retry.

`empty` with `retried` true is a screenshot-like image that still read blank.
Treat it as a likely OCR failure, not as a photo with no text in it.

```json
{
  "version": "0.6.0",
  "results": [{
    "file": "shot.png",
    "text": "build ok\nkey [AWS_KEY]",
    "image_tokens": 1018,
    "text_tokens": 6,
    "redactions": { "AWS_KEY": 1 },
    "lines": [
      { "n": 1, "text": "build ok", "bbox": [22, 30, 350, 54], "confidence": 1 },
      { "n": 2, "text": "key [AWS_KEY]", "bbox": [22, 90, 482, 116], "confidence": 0.5 }
    ],
    "ocr_status": "ok",
    "retried": false,
    "screenshot_like": true
  }],
  "image_tokens": 1018,
  "text_tokens": 6
}
```

PDF results carry `source` and `pages[]` in place of `lines[]` and the three
0.6.0 fields. Each page has its own `lines[]`. See [PDF](/cheapshot/pdf/).

:::tip
Layout question, no pixels? Compare `lines[].bbox`: find the line you care
about, then the lines whose boxes sit next to it or under it. Arrows and shapes
are not text, so this is inference from word positions, not sight. Say so when
you answer.
:::

A `redactions` count above 0 means the image held a secret: use the `text`,
and never send that image's pixels to a model. The pixels carry the secret
the redaction hid.

## Recognition

`--min-conf <f>` sets the confidence floor for a recognized line; the default
is `0.3`. Lines below it are dropped.

## PDF

`--pages <N|N-M>` limits a PDF to one page or a range. The default is all
pages.

`--force-ocr` OCRs every PDF page and ignores its text layer. Without it, a
page keeps its text layer only when the layer agrees with an OCR of the page.
See [PDF](/cheapshot/pdf/).

## Video

`--scene <f>` is the scene-change threshold that decides when a new frame is
worth reading, default `0.25`. `--max-frames <n>` caps how many frames a
recording contributes, default `200`. `--dedupe <f>` drops a screen that is at
least this similar to the one before it, default `0.90`.

## Ledger

`--ledger` prints the cumulative savings across every run. `--no-ledger` runs
without recording this one. `--version` prints the version and exits.

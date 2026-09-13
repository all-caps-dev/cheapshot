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

## Recognition

`--min-conf <f>` sets the confidence floor for a recognized line; the default
is `0.3`. Lines below it are dropped.

## PDF

`--pages <N|N-M>` limits a PDF to one page or a range. The default is all
pages.

## Video

`--scene <f>` is the scene-change threshold that decides when a new frame is
worth reading, default `0.25`. `--max-frames <n>` caps how many frames a
recording contributes, default `200`. `--dedupe <f>` drops a screen that is at
least this similar to the one before it, default `0.90`.

## Ledger

`--ledger` prints the cumulative savings across every run. `--no-ledger` runs
without recording this one. `--version` prints the version and exits.

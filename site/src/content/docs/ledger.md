---
title: Ledger
description: Where the ledger lives, the shape of one line, and how to total, export, or migrate it.
---

Every run appends one JSON line to a ledger file, so the savings add up across
every screenshot, PDF and recording you ever read.

## Where it lives

If `$CHEAPSHOT_HOME` is set and not empty, the file is
`$CHEAPSHOT_HOME/ledger.jsonl`. Otherwise it is
`~/Library/Application Support/cheapshot/ledger.jsonl`.

## One line

```json
{"image_tokens":1550,"inputs":1,"mode":"image","redactions":10,"saved":1496,"text_tokens":54,"ts":"2026-09-08T01:05:35Z"}
```

`mode` is one of three values: `image`, `pdf`, or `video`. A run that mixes PDFs
and screenshots writes one line per kind. They are kept apart because the PDF
number is an estimate of what reading the pages as images would have cost, not a
measured saving, and mixing the two would quietly inflate the total.

## Reading it

```bash
cheapshot --ledger          # cumulative savings across every run
cheapshot --ledger --json   # the same totals as JSON
cheapshot --no-ledger shot.png   # read this one without recording it
```

## Migrating from 0.4.x

Version 0.4.x wrote daily TSV files under `~/.claude/cheapshot-ledger/`. One
command imports them:

```bash
cheapshot --ledger --migrate
```

The import happens once. It leaves the TSV files in place and writes a marker
file, `migrated-tsv.json`, next to the ledger so a later `--migrate` is a no-op.
Only a real import writes the marker, so running `--migrate` before the old
files exist does not lock out a later one.

## PDF savings are estimates

For a PDF, the ledger counts what an agent would have paid to read each page as
an image, based on the rendered pixel size of the page. Nobody actually sent
those images, so treat the PDF total as an estimate of avoided cost rather than
a measurement of tokens saved. Image and video totals come from real frames.

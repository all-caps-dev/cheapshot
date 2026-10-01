---
title: Save a PDF with Docling
description: docling-save, a companion script that keeps a PDF as Docling markdown, Docling JSON, the pictures and cheapshot's redacted page text, in one folder.
---

```bash
scripts/docling-save report.pdf --dest ~/papers
```

`docling-save` keeps one PDF as a folder that an agent can read later without
the PDF. It calls two tools. [Docling](https://github.com/docling-project/docling)
reads the structure of each page, and cheapshot reads the text on each page,
including the words inside screenshots.

Docling is not part of cheapshot. The cheapshot binary stays a single Swift
program with no Python, and `docling-save` is a shell script in `scripts/` that
you run beside it.

## Why Docling

cheapshot gives an agent the words on each page, in reading order, with a
marker between pages. Docling gives the agent the structure around those words,
so the agent knows where it is in the document:

- Headings. Docling marks the large titles on a page as markdown headings. An
  agent can see where a topic starts and go to one section instead of reading
  a whole document of flat lines. On a 114 page slide deck, Docling found 77
  headings.
- Tables. Docling rebuilds a table as a markdown table with rows and columns.
  On a 90 page deck, a slide with a grid of punch card codes came out as a 24
  row table instead of a column of loose characters.
- Pictures in place. Each picture sits in the markdown where it sat on the
  page, as a link into `images/`, so the agent knows which text belongs with
  which picture.
- Positions. The JSON records the page and the position of every heading,
  paragraph, table and picture, so a later tool can cite the page an answer
  came from.

Docling decides what a heading is from the size and the place of the text, and
it does not judge meaning. On slides, a large quote or a large number also
becomes a heading, e.g., a slide that shows only a dollar figure. Read the
headings as a map of the document, and do not treat them as an outline the
author wrote.

## What the folder holds

For `report.pdf`, the script writes `report/` with six things:

| File | What it is |
|---|---|
| `report.pdf` | The original file, byte for byte |
| `report.docling.md` | Docling's markdown: headings, text, tables, and links to the pictures |
| `report.docling.json` | Docling's full record, with the page and position of every item |
| `images/` | Every picture Docling cut out of the pages |
| `report.ocr-pages.txt` | cheapshot's page by page text, redacted, with `--- page N ---` markers |
| `manifest.json` | The source file name, its SHA-256, page and picture counts, tool versions, and the date |

The picture links in the markdown are relative (`images/...`), so the folder
still works after you move it.

## Why both tools

Docling keeps a screenshot as a picture, so the words inside a screenshot are
not in its markdown. cheapshot reads every page with Apple Vision, so its text
file has those words, and it redacts emails, phone numbers and keys first. On
a 90 page slide deck, Docling's markdown held about 3,900 words and cheapshot's
page text about 5,300.

When cheapshot is not on your `PATH`, the script skips the page text and says
so in the manifest.

## Install Docling

The script needs Docling 2 and, for OCR, its `rapidocr` engine with
`onnxruntime` in the same Python environment:

```bash
uv tool install docling --with onnxruntime
```

The script looks for Docling as `$DOCLING`, then `docling` on your `PATH`, then
`~/.local/share/docling-venv/bin/docling`. Pass `--no-ocr` to skip Docling's OCR
when `onnxruntime` is missing; cheapshot's page text still covers the words on
the pages.

## Options

- `--name <slug>` sets the folder name. The default is the file name in lower
  case, with every run of other characters turned into a hyphen, so
  `My Deck & Notes.pdf` becomes `my-deck-notes`.
- `--dest <folder>` sets where the folder goes. The default is `./docling-save`.
- `--no-ocr` turns off Docling's OCR.
- `--force` replaces a folder that already exists. Without it, the script stops
  rather than overwrite anything.

The script does all its work in a temporary folder and copies the finished
folder into place at the end, so a synced folder such as Dropbox never holds a
half-written copy.

## Exit codes

0 when the folder was written, 1 when the input or Docling failed, 2 for a usage
error.

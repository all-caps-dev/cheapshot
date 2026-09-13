---
title: PDF
description: The text lane and the scan lane, page ranges, the JSON additions, and the coordinate spaces.
---

```bash
cheapshot report.pdf
cheapshot --pages 3-5 report.pdf
```

Every page takes one of two lanes, chosen per page.

## Text lane

A page that already has a text layer is read through PDFKit. That is free, and
the fonts come with the text, so fixed-pitch runs are detected and fenced
without any measurement. Most PDFs are entirely this lane.

## Scan lane

A page whose text layer holds fewer than 20 non-whitespace characters is
rendered at 2x and run
through the same Vision OCR path as a screenshot. The lane is recorded per page,
so a downstream tool can route scanned pages for review instead of trusting them
like native text.

## Page ranges

`--pages <N|N-M>` limits the run to one page or a range. The default is every
page. Plain output separates pages with a marker line:

```
--- page 1 ---
Quarterly report
...

--- page 2 ---
...
```

## JSON

`--json` adds two things to the payload for a PDF. `source` carries the file
path, the page count, and `sha256`, so a citation can be pinned to the exact
bytes that were read. `pages` is an array, and each page object carries:

- `n`, the 1-based page number
- `lane`, either `text` or `scan`
- `width` and `height`, the rendered pixel size at 2x after rotation
- `lines`, one object per line with `n`, `text`, `bbox` and `confidence`

## The two coordinate spaces

A line's `bbox` is `[minX, minY, maxX, maxY]` with a top-left origin, but the
unit depends on the lane.

In the **text lane** the box is in PDF points, in the page's own unrotated
coordinate space. In the **scan lane** the box is in pixels of the rendered
image.

The page `width` and `height` are always the rendered pixel size after rotation,
so on a rotated page they do not describe the space the text-lane boxes live in.
Read the lane before you trust a box.

## Errors

A password-protected PDF is an error. Cheapshot does not prompt for a password
and does not read a partial document: the file fails, its `--json` entry carries
`"error"`, and the run exits 1.

## Redaction and the ledger

Both apply exactly as they do for images. The ledger records `mode: "pdf"` and
counts what an agent would have paid to read each page as an image, which makes
the PDF figure an estimate of avoided cost rather than a measured saving. See
[Ledger](/cheapshot/ledger/).

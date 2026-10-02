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

`cheapshot --ledger --json --days 7` limits the totals to the last seven days and adds
`"window_days": 7` to the JSON. The Claude Code [status line segment](/cheapshot/claude-code/#status-line)
uses exactly that call.

## Splitting the total by mode

One number for the whole ledger hides which kind of input earned it, and the kinds
are not comparable. `--by-mode` splits the same window, biggest saving first:

```bash
cheapshot --ledger --by-mode
```

```
cheapshot ledger  (10 days, by mode)
  mode        runs    inputs   image tokens   text tokens          saved     %  redactions
  video        939     68275      125892675       8203393      117689282    93        2923
  image       1082      1096        1769456        249533        1541275    87         323
  pdf           18        18          96626         42203          54423    56           3
  TOTAL       2039     69389      127758757       8495129      119284980    93        3249
```

Read that table before quoting the total as money saved. A screenshot row is close
to real avoided spend, because you would have pasted that image into a model. A
video row usually is not: the 68,275 frames above were never going to be uploaded
one by one at any price, so that saving is a capability you gained, not a bill you
dodged. The two live in one file and should not be added together in a sentence
about cost.

`--by-mode` combines with `--json` and `--days`. In JSON it adds a `modes` array
alongside the flat totals, one object per mode with the same keys plus `mode`. The
key is absent without the flag, so an existing parser sees no change. The rows
always reconcile with the flat totals in the same payload.

`--by-mode` without `--ledger` is a usage error (exit 2).

## Splitting the total by session, and by model

A ledger line records who asked for the run, when the caller says so:

```bash
cheapshot --session "$MY_SESSION_ID" shot.png
cheapshot --ledger --by-session
```

`--session` takes an opaque string. cheapshot never interprets it, never sanitises it, and
writes it verbatim as a `session` key. Without the flag the key is absent, so every line
written before this existed stays byte-identical and still decodes.

```
cheapshot ledger  (10 days, by session)
  session                                runs   inputs          saved     %  redactions
  578404de-9ecb-4e6d-8642-4718c9690212     42      812       1,204,556    91         37
  (untagged)                              870      884       1,320,890    87        323
  TOTAL                                   912    1,696       2,525,446    88        360
```

Runs with no id group under `(untagged)` rather than being dropped or folded into an arbitrary
caller. In JSON that group's `session` is `null`, not the display string.

### Why not a model name

cheapshot does not know what a model is, and should not: the same binary serves Claude Code,
Cursor, Codex CLI and a bare shell. A session id is neutral, so the harness that *does* know
can resolve it afterwards.

The Claude Code plugin passes its session id automatically, so nothing is needed from you. To
turn that into a per-model split, `commandcode/ledger/ledger.py --by-model` reads the session
id off each line, finds that session's transcript, and attributes the run to the model that
was actually answering:

```
=== CHEAPSHOT SAVINGS BY MODEL (attributed through the session id) ===
model                          runs   inputs          saved   at list in
claude-fable-5-1                342   26,111     45,417,501      $454.18
claude-opus-5                 1,095    9,036     15,243,338       $76.22
no-session                      495   33,070     56,565,660          n/a
```

The join is the session id, never the timestamp. A clock-only join tops out near 70% on a real
ledger and can attribute a run to a session that merely overlapped it. A run that cannot be
resolved is reported as `no-session` or `session-not-found`, never guessed.

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

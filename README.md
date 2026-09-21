# cheapshot

Give your coding agent the words on your screen, not the pixels: on-device OCR that redacts secrets first and shows you the tokens it saved.

Full writeup: [Everything to Save, Nothing to Trust](https://ilano.fyi/writing/nothing-to-trust/).

## Why

An image costs roughly `(width x height) / 750` tokens and it stays in the conversation, riding along on every later turn. The words are usually all the agent needed. Screenshots are also full of things you do not want in an agent's context, so cheapshot redacts by default.

Apple Vision framework. No network. No API cost. macOS only.

## Install

```bash
brew install all-caps-dev/tap/cheapshot
```

From source:

```bash
make                 # universal binary at ./cheapshot, macOS 13 or newer
sudo make install    # copies it to /usr/local/bin (PREFIX=... to change)
```

Needs Xcode; the universal build uses the Xcode build system, which the command line tools alone do not provide. Apple silicon is the tested target and Intel is best-effort. `--video` needs ffmpeg on your PATH.

## Use

```bash
cheapshot shot.png                 # OCR one file, redacted
cheapshot --json shot.png          # text, lines with boxes, redaction counts
cheapshot --cleanshot              # newest CleanShot capture (falls back to ~/Desktop)
cat notes.txt | cheapshot --text - # redact text, no OCR
```

Exit codes: 0 ok, 1 an input failed (its `--json` entry carries `"error"`), 2 usage error. An empty or unreadable `--newest` or `--cleanshot` folder is an input failure: exit 1, and the message names the folder.

## Redaction

```bash
cheapshot --rules my-rules.json shot.png
```

Fifteen built-in rules catch keys, tokens, cards, and contact details, ordered most specific first; your own rules run before them and are a JSON array: `[{"name": "TICKET", "pattern": "\\bINT-\\d{6}\\b", "caseInsensitive": true}]`.

## Video

```bash
cheapshot --video screen.mp4
```

ffmpeg hands over only the frames where the screen changed, cheapshot OCRs those locally, drops near-duplicate screens, and prints a timestamped transcript.

## PDF

```bash
cheapshot --pages 3-5 report.pdf
```

Pages with a text layer are read through PDFKit and pages without one are rendered and OCR'd like a screenshot, which `--json` reports per page. `--pages` on a non-PDF input is a usage error (exit 2).

## Ledger

```bash
cheapshot --ledger              # cumulative savings across every run
cheapshot --ledger --by-mode    # the same window split into video / image / pdf
```

Every run appends one JSON line to `~/Library/Application Support/cheapshot/ledger.jsonl`, or to `$CHEAPSHOT_HOME/ledger.jsonl` when that variable is set, tagged with the mode it ran in: `image`, `pdf`, or `video`.

`--by-mode` matters before you turn the total into money. Screenshots are close to real avoided spend, because you would have pasted them into a model. Video frames usually are not: nobody was ever going to upload a recording frame by frame, so that share of the total is a capability rather than a bill you dodged. It combines with `--json` (adds a `modes` array) and `--days`.

## Claude Code

```bash
claude plugin marketplace add all-caps-dev/cheapshot
claude plugin install cheapshot@all-caps-dev
```

The plugin's hook intercepts `Read` on images and PDFs and hands the agent redacted text plus one line saying what it saved. The agent gets the pixels back with `cheapshot allow <path>` when it needs layout. `CHEAPSHOT_PASSTHROUGH=1` turns the hook off for a session. The binary is not bundled; brew it first.

OCR text enters the agent's context as data. A screenshot of a web page containing "ignore previous instructions" is now text in context, the same risk as reading any file.

## MCP

```bash
npx cheapshot-mcp
```

Stdio server for any MCP host. Tools `cheapshot_ocr`, `cheapshot_video`, `cheapshot_ledger`; resource `cheapshot://ledger`. It shells out to the same binary.

## Docs

https://all-caps-dev.github.io/cheapshot/ has every flag, the rule table, the ledger format, and the research notes.

## License

MIT. See [LICENSE](LICENSE). The Mac App Store app that will sit on this engine is a separate, private repo; the engine and the CLI stay MIT.

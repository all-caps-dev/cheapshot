# Cheapshot design: two products, one engine

Written 2026-09-12 from docs/product-brief.md plus four decisions Ryan made in the brainstorm the same day. The brief holds the market research, the pricing, and the audit. This doc holds the architecture and the revised build order. When the two disagree, this doc wins.

## Decisions made in the brainstorm (2026-09-12)

1. **Two repos.** Public `all-caps-dev/cheapshot` holds `CheapshotCore`, the CLI, the Claude Code plugin, and the MCP server. Private `all-caps-dev/cheapshot-app` holds the Mac App Store app and depends on Core through a SwiftPM git URL pinned to a tag.
2. **MIT** for the public repo. Relicense from BSL 1.1 before the v0.5.0 tag. The Homebrew formula says `MIT`, not `BUSL-1.1` as the brief's Phase 2 drafts it.
3. **Both video frame sources.** ffmpeg stays for the CLI (scene detection). AVFoundation is added for the sandboxed app. Both sit behind one `FrameSource` protocol in Core. See "Video" below.
4. **Core split moves ahead of Phase 1, as a new Phase 0.** Every audit fix lands in the module the app will import, and `swift test` works from day one.

## Architecture

```
all-caps-dev/cheapshot (public, MIT)
  Package.swift
  Sources/CheapshotCore/     OCR, redaction, rules, ledger, tokens, video, pdf
  Sources/cheapshot/         thin CLI: arg parsing, output formatting, exit codes
  Tests/CheapshotCoreTests/  redaction golden files, ledger, arg parsing
  plugin/                    Claude Code plugin (hook, SKILL.md, MCP config)
  mcp/                       cheapshot-mcp, TypeScript, npm
  .github/workflows/         release.yml (from the brief), ci.yml
  docs/

all-caps-dev/cheapshot-app (private)
  Package dependency: cheapshot @ vX.Y.Z
  Cheapshot.app: menu bar app, folder watcher, clipboard guard, ledger window, StoreKit
```

### CheapshotCore public surface

Core knows nothing about licenses, tiers, or the App Store. Every feature is callable from the CLI for free. The app decides what to show behind a paywall. This keeps one code path, one test suite, and no "is this user paid" branches in the engine.

| Type or function | What it does | Notes |
|---|---|---|
| `Redactor(rules: [Rule])` and `redact(_:) -> (String, RedactionReport)` | Today's `redact()` with the rule list injected | Built-in rules stay in `Rule.builtin`. Custom rules append to the front so they win. |
| `Rule` | name, pattern, options, optional `validator` closure | Luhn, ABA, and `looksLikeSecret` become validators on the rule instead of string checks inside the loop. |
| `RuleFile.load(url) -> [Rule]` | Reads a JSON array of `{name, pattern, caseInsensitive}` | CLI: `--rules path`. App: the rules editor writes the same file. |
| `OCR.recognize(image: CGImage, minConfidence: Float, languageCorrection: Bool) -> OCRResult` | Wraps `VNRecognizeTextRequest` | Takes `CGImage`, not a path, so the app can pass clipboard images. `OCRResult` carries lines with confidence and bounding boxes. |
| `PDFSource.pages(of: URL, range: ClosedRange<Int>?) -> [PDFPageResult]` | PDFKit text lane, Vision scan lane per page | Returns lane, lines with bbox, and the rendered image size for the ledger. See "PDF input". |
| `Tokens.image(width:height:)` and `Tokens.text(_:)` | Today's estimators | Unchanged. |
| `Ledger(at: URL)` with `append(Entry)` and `summary(days:) -> Summary` | JSONL, one line per run, `O_APPEND` single write | Location rule below. |
| `FrameSource` protocol, `FFmpegFrameSource`, `AVFoundationFrameSource` | Yield `(timestamp, CGImage)` for a video | See "Video". |
| `VideoTranscriber(source: FrameSource, dedupe: Double)` | Frames to OCR to deduped transcript with timestamps | Today's loop in `--video`, minus the `exit(0)` leak. |

### Ledger location and sharing

The sales pitch is "you saved N tokens this week". Most of those savings will come from the CLI hook, not from the app. So the app must read the CLI's ledger.

Rule: Core resolves the ledger file in this order.

1. `$CHEAPSHOT_HOME/ledger.jsonl` if the variable is set.
2. `~/Library/Application Support/cheapshot/ledger.jsonl` otherwise.

Revised 2026-09-12 after Perplexity answer 2 (see Open questions): a CLI that is not an entitled member of the App Group gets a macOS 15 authorization prompt when it touches `~/Library/Group Containers/<TEAMID>.dev.all-caps.cheapshot/`, and the user can deny it. So the CLI never writes there. How the sandboxed app reads the CLI's ledger is decided in Phase 4, between two options: the app takes a security-scoped bookmark to `~/Library/Application Support/cheapshot/` on first launch (one more folder picker, no signing dependency), or the brew-distributed CLI is signed by the same team with the App Group entitlement and validated at runtime with `launchctl procinfo`. The bookmark is the default because it has no dependency on how the binary was installed.

Existing `~/.claude/cheapshot-ledger/*.tsv` files are imported once by `cheapshot --ledger --migrate` and left in place.

### Plugin layout

```
plugin/
  .claude-plugin/plugin.json      name: cheapshot
  hooks/hooks.json                PreToolUse, matcher: Read
  hooks/cheapshot-read.sh         the hook
  skills/cheapshot/SKILL.md       generic rewrite of ~/.claude/skills/screenshot-ocr
  .mcp.json                       npx cheapshot-mcp
.claude-plugin/marketplace.json   at repo root, one entry pointing at ./plugin
```

Install: `claude plugin marketplace add all-caps-dev/cheapshot` then `claude plugin install cheapshot@all-caps-dev`. The suffix after `@` is the `name` field of `marketplace.json`, which this spec fixes as `all-caps-dev`, not the repo name. Inside a session the same commands are `/plugin marketplace add ...` and `/plugin install ...`. `plugin.json` declares `"hooks": "./hooks/hooks.json"` and `"mcpServers": "./.mcp.json"`; every path inside those files uses `${CLAUDE_PLUGIN_ROOT}` so the install location does not matter (Perplexity answer 4 in Open questions).

Hook behaviour:

1. Fires on `Read` where `file_path` ends in png, jpg, jpeg, webp, gif, or pdf (PDF rules in the PDF input section).
2. If `CHEAPSHOT_PASSTHROUGH=1`, or `cheapshot` is not on PATH, or the path is on the one-shot allowlist, exit 0 with no output so the Read proceeds. When the binary is missing, print one stderr line with the brew command, once per session (marker file in `$TMPDIR`).
3. Otherwise run `cheapshot --json --stats <path>`, return `permissionDecision: deny` with `permissionDecisionReason` = redacted text plus one line: `cheapshot: 1018 image tokens -> 37 text tokens. If you need the pixels for layout, run: cheapshot allow <path>, then Read again.`
4. Print the same savings line to stderr so the user sees it.
5. `cheapshot allow <path>` appends the path to `$TMPDIR/cheapshot-allow` with a 5 minute expiry. The hook consumes the entry on the next Read of that path. The agent can call it from Bash, so the escape hatch needs no new Read parameter. The brief's `allow_image=true` does not exist on the Read tool.

The plugin does not bundle the binary. It depends on `brew install all-caps-dev/tap/cheapshot`. Reason: the binary is notarized and versioned through the tap; shipping a second copy inside a git-cloned plugin means two update channels and Gatekeeper on the plugin copy.

Injection note for SKILL.md and README: OCR text enters the agent's context as data. A screenshot of a web page containing "ignore previous instructions" is now text in context. Same risk as reading any file; say so plainly.

### MCP server

`mcp/` publishes `cheapshot-mcp` to npm. Stdio only. Shells out to the `cheapshot` binary, never reimplements OCR. Three tools, one resource, exactly as the brief lists. The plugin's `.mcp.json` points at it so Claude Code users who prefer MCP over the hook get it in the same install.

## The app

Menu bar only, no Dock icon, no main window until the user opens the ledger.

### First launch

1. Folder picker for the screenshots folder. Store a security-scoped bookmark. Default suggestion: read `com.apple.screencapture location`, fall back to `~/Desktop`.
2. Ask for notification permission.
3. Ask for a security-scoped bookmark to `~/Library/Application Support/cheapshot/` so the app can read the CLI's ledger (see "Ledger location and sharing").

### Free tier

1. Watch the folder with `FSEvents` through the bookmark. On a new image: OCR, redact, put the text on the clipboard, notify with the token count. One toggle: "copy text automatically" versus "notify only".
2. Ledger window shows the last 7 days: images processed, tokens saved, redactions by rule.
3. Redaction on by default, built-in rules only.

### Paid tier, $4.99 for two years

1. **Clipboard guard.** This is the feature that closes the gap the CLI cannot: claude-code#16592 means a pasted screenshot is never seen by a hook. The app watches `NSPasteboard.general` for image data. When one lands, it OCRs it in the background and offers a global hotkey (default Cmd-Shift-V) that replaces the image on the clipboard with the redacted text and pastes it. The image is never auto-replaced; the user chooses per paste. That keeps image pastes into Figma or Slack working.
2. **Video transcripts.** Drop a screen recording on the menu bar icon, or pick from the folder watcher when a `.mov` appears. Uses `AVFoundationFrameSource`.
3. **Ledger history.** All time, per day chart, export as CSV.
4. **Custom redaction rules.** Editor with a live test field. Writes the same `rules.json` the CLI reads with `--rules`, into the bookmarked `~/Library/Application Support/cheapshot/` directory, so the CLI picks them up too.

The paywall screen shows the user's own number first: "Cheapshot saved you 41,200 tokens this week." Then the price.

### StoreKit

Non-renewing subscription product, two-year duration, as the brief specifies. The app reads `Transaction.all`, takes the newest purchase date for the product, and treats `purchaseDate + 2 years` as the expiry. No server. `Transaction.all` covers restore across devices when the user is signed in to the same Apple ID. The brief's Phase 4 line says "one-time purchase"; the decision section's non-renewing subscription is the one that stands. Fallback if App Review rejects: one-year auto-renewing at $2.49.

### Sandbox entitlements

`com.apple.security.app-sandbox`, `com.apple.security.files.bookmarks.app-scope`, `com.apple.security.application-groups`. No network entitlement at all, so the privacy label "no data collected" is enforced by the OS, not just claimed.

## Video

### FrameSource protocol

```swift
public protocol FrameSource {
    /// Yields candidate frames in time order. The transcriber OCRs each and drops near-duplicates by text similarity.
    func frames(of video: URL, maxFrames: Int) throws -> AsyncThrowingStream<(time: TimeInterval, image: CGImage), Error>
}
```

Image-typed, not path-typed. Vision wants a `CGImage` in memory, and the app has no temp dir it wants to manage. The ffmpeg adapter writes to a temp directory it owns and deletes in a `defer` that actually runs (the CLI returns a status instead of calling `exit(0)` mid-function).

### FFmpegFrameSource (CLI only)

Verified on this Mac (ffmpeg 9.0.1) with a synthetic 4 second, 10 fps clip that has exactly three visual changes:

| Command | Frames printed by `metadata=print` | PNG files written |
|---|---|---|
| Today's filter, no `-fps_mode` | 3 | 41 |
| Same filter plus `-fps_mode vfr` | 3 | 3 |

**Bug in v0.4.1:** the image2 muxer runs at constant frame rate by default, so every input frame becomes a file even though `select` passed only three. The `-frames:v 200` cap then covers 200 input frames, which is under 7 seconds of a 30 fps screen recording. Timestamps after the third frame fall back to the file index. `--video` on anything longer than a few seconds is silently truncated. Fix is one flag: `-fps_mode vfr`. This goes in Phase 1 with a test that counts files.

The ffmpeg skill at `~/.claude/skills/ffmpeg` was checked. It wraps `fftools.py` (cut, merge, thumbnails at fixed count, `select=not(mod(n,30))`) and has no scene detection, `mpdecimate`, keyframe-only decode, or cropping. Cheapshot's filter is already ahead of it. Two items transfer: probe first with `ffprobe` for duration and size, and write JPEG at `-q:v 2` instead of PNG. The public repo `MastroMimmo/ffmpeg-skill` is the same skill.

Filter chain after Phase 1:

```
-an -sn -vf "fps=4,mpdecimate=hi=64*12:lo=64*5:frac=0.1,select=eq(n\,0)+gt(scene\,T),metadata=print:file=-" -fps_mode vfr -q:v 2 f_%05d.jpg
```

`fps=4` cuts filter work by about 15x on 60 fps captures. `mpdecimate` drops static stretches before the scene metric runs. The scene threshold `T` needs retuning after `fps=4` because neighbours are 250 ms apart instead of 16 ms; tune against three real agent recordings, not synthetic clips. `metadata=print` does emit frame 0 (verified above), so timestamps align. Optional later: `--region w:h:x:y` as a leading `crop=` filter for users who know which pane matters.

### AVFoundationFrameSource (Core, used by the app, available to the CLI as `--engine av`)

1. `AVAssetImageGenerator.images(for:)` at 2 to 4 Hz. macOS 13+. Set `requestedTimeToleranceBefore` and `After` to half the interval; with `.zero` the generator decodes exact frames and re-seeks, which is the main cost mistake.
2. `VNGenerateImageFeaturePrintRequest` on each frame, macOS 10.15+, and `computeDistance(to:)` against the last kept frame. Drop under a threshold. This is the sandbox-safe stand-in for scene detection.
3. Rough cost: 3 to 4 seconds of CPU per minute of 1080p recording at 2 Hz on Apple Silicon, before OCR. OCR is 100 to 200 ms per frame, so the feature-print gate pays for itself if it drops a third of frames.

Rejected: keyframe-only `AVAssetReader` (ScreenCaptureKit keyframe cadence is an encoder artifact, not a change signal) and CoreImage histogram difference (blind to text changes in a terminal).

The existing OCR-text similarity dedupe at 0.90 stays as the final gate for both sources.

## Structured output

Research pass on 2026-09-12 covered Docling, Marker, MinerU, olmOCR, Chandra, PyMuPDF4LLM, Unstructured, LlamaParse, Reducto, Chunkr, Nougat, Mistral OCR, DeepSeek-OCR, and Apple's Vision document APIs. Full report with 26 sources is in `docs/research/2026-09-12-structured-output.md`.

### What the field converged on

Every serious document parser emits Markdown as the LLM payload plus a JSON sidecar with block type and bounding box. Nobody ships plain lines. Measured evidence: Markdown costs 70% fewer tokens than HTML for the same content; Markdown tables beat CSV, JSON, and HTML on lookup accuracy per token in the one controlled test found; JSON and HTML as the primary payload cost 1.3x to 3x tokens with no measured accuracy gain. Nobody has measured formats on screenshots of code.

### Decision: plain text stays the payload, with three code-aware fixes

Cheapshot's users paste terminals, editors, chat windows, and dashboards, not scanned paper. What transfers, ranked by value to a coding agent:

1. **Indentation from bounding boxes.** Vision drops leading whitespace, so a Python screenshot loses its block structure. Fix: estimate cell width as the median of box width divided by character count across lines, then leading spaces = round((line minX - block minX) / cell width). Pure arithmetic on `VNRecognizedTextObservation`, unit-testable from synthetic boxes without Vision. macOS 13.
2. **Monospace detection and code fences.** If per-line cell width varies under 8% across a run of lines, the region is a terminal or editor. Wrap it in a fence and OCR that region with `usesLanguageCorrection = false` so tokens and hashes are not "corrected" into words. Same arithmetic as item 1. macOS 13.
3. **Line-addressable `--json`.** Extend the existing `--json` payload with `lines: [{n, text, bbox, confidence}]` so an agent can quote line 42 and the MCP `structuredContent` carries it. macOS 13.
4. Later: Markdown tables for column-aligned output such as `ls -l` and `kubectl get`, by clustering word minX into columns. On macOS 26, `RecognizeDocumentsRequest` returns `DocumentObservation` with `tables`, `lists`, and `detectedData`; use it behind an availability check, keep the 13 floor.
5. Later, video only: strip repeated chrome (lines whose text and box repeat in over 80% of frames become one `chrome:` header) and emit only added lines per kept frame with `@t=12.4s` markers. The feature-print dedupe in the Video section is the first half of this.

Items 1 to 3 add about one day to Phase 1 and become the fourth README edge after redaction, the ledger, and video: "keeps your indentation and fences your code". mac-ocr does neither.

### Do not adopt

Reading-order and multi-column solvers, formula recognition, header and footer classifiers trained on paper, DocTags, any VLM parser (kills the sandbox and the no-GPU premise), `VNDetectDocumentSegmentationRequest` (finds paper edges only), and HTML or JSON as the primary payload.

## PDF input

Added 2026-09-12 after Ryan pasted a Docling-based knowledge-base architecture (saved as `docs/research/2026-09-12-pdf-pipeline-notes.md`). That architecture is a Python pipeline with a parser, chunker, embeddings, vector and keyword search, object storage, and an orchestrator. None of it fits inside a sandboxed Swift engine, and the earlier research already ruled out VLM parsers for the same reason. So the split is: **cheapshot is the on-Mac lane that turns a PDF into redacted, page-addressed text; the knowledge base is a separate project that consumes that output.** Docling stays the right choice for that project on the Proxmox side.

### What cheapshot does with a PDF

`cheapshot report.pdf` and `cheapshot --pages 3-5 report.pdf`. Two lanes, chosen per page:

1. **Text lane.** `PDFKit` `PDFPage.attributedString`. Native text with fonts, so monospace detection and indentation come for free. Near-zero cost, macOS 10.4+, sandbox-safe.
2. **Scan lane.** If a page's text layer is under 20 characters, render the page at 2x with `PDFPage.draw(with:to:)` into a `CGImage` and run the same Vision OCR path as screenshots. The lane is recorded per page so a downstream consumer can route low-confidence pages for review.

Redaction, the ledger, and the code-aware output fixes apply unchanged. The ledger entry records an estimate of what a rendered page would cost as an image (the 2x render size through the same `(w * h) / 750` rule). Anthropic publishes no per-page token rate for `Read` on a PDF (Perplexity answer 4 in Open questions), so this is labelled an estimate, not a measured saving.

Output: the plain text payload gains `--- page N ---` separators. `--json` gains:

```json
{ "source": { "path": "report.pdf", "sha256": "ab12...", "pages": 42 },
  "pages": [ { "n": 3, "lane": "text", "lines": [ { "n": 1, "text": "...", "bbox": [72,136,523,150], "confidence": 1.0 } ] } ] }
```

The `sha256` and per-line `bbox` are the two things the pasted architecture needs from an extractor to build citations. Nothing else from its data contract belongs in cheapshot; chunk ids, embeddings, and section paths are the consumer's job.

### Tables

PDFKit exposes no table structure. On macOS 26, run `RecognizeDocumentsRequest` on the rendered page and emit each table twice, as the pasted notes recommend: a Markdown table in the text payload and `{columns, rows}` JSON in the sidecar under `pages[].tables`. On macOS 13, the column-clustering approach from the Structured output section applies. Both are in the "later" bucket with the screenshot table work.

### Hook and MCP

The PreToolUse matcher adds `.pdf`. The hook reads the `pages` argument from the tool input and passes it as `--pages`. For a PDF over 20 pages with no `pages` argument, the hook passes through with a stderr hint instead of dumping the whole document into context. `cheapshot_ocr` in the MCP server accepts PDF paths and an optional `pages` range with the same cap.

### App

Dropping a PDF on the menu bar icon behaves like dropping an image. Free tier, since it is OCR plus redaction.

### Not in scope

Docling, chunking, embeddings, vector or keyword search, retrieval tools, orchestration, object storage. If Ryan builds the knowledge base, cheapshot's `--json` is its input for Mac-side documents and screenshots, and Docling handles the rest. Do not add a `cheapshot index` or `cheapshot search` command.

## Accessibility

Added 2026-09-12 at Ryan's request. Accessibility is a requirement in every phase, not a polish item.

### CLI and docs (Phase 1 onward)

1. Output is plain text. No ANSI colour, no box-drawing characters, no spinners, no cursor tricks. Screen readers and agents both read the same bytes. Meaning never rides on colour alone; status lines say "saved 1496 tokens" in words.
2. Errors go to stderr as one plain sentence that names the file and the cause, and exit codes carry the outcome (0, 1, 2) so a script or a screen-reader user does not have to parse prose.
3. `--help` is a short, left-aligned list with consistent two-column alignment, readable line by line. No tables that only make sense visually.
4. Code fences and rebuilt indentation (Structured output) are plain characters, so they read correctly in a terminal screen reader and in an agent's context.
5. README: every image carries alt text that says what the image is for. `docs/licensing-animated.svg` keeps `role="img"`, a `<title>`, and its `prefers-reduced-motion` branch so the animation stops for users who ask the OS to reduce motion. Any future badge or chart ships with a text equivalent next to it.

### App (Phase 4)

1. VoiceOver: every menu item, toggle, button, and chart element has an accessibility label and, where the visual is a number, an accessibility value. The menu bar icon has a label that includes the current state ("Cheapshot, watching Desktop").
2. Keyboard: everything reachable by keyboard alone, including the first-launch folder picker flow, the ledger window, and the rules editor. The clipboard guard hotkey is rebindable and the default avoids conflicts with VoiceOver's own bindings.
3. The ledger chart has a table view alternative with the same numbers, and a one-sentence summary ("41,200 tokens saved this week") that VoiceOver reads first.
4. Notifications carry the useful text (token count, redaction count), not only a title, so they are meaningful when read aloud.
5. Respects Reduce Motion, Increase Contrast, and Reduce Transparency. Dynamic Type where SwiftUI supports it on macOS. Colour is never the only carrier of state; the paid and free tiers are distinguished by words.
6. App Store listing states these commitments in the accessibility section once the app ships.

## Build order, revised

Phase 0, half a day: create `Package.swift`, move `cheapshot.swift` into `Sources/CheapshotCore` and `Sources/cheapshot`, no behaviour change, commit. Homebrew formula becomes `swift build -c release`.

Phase 1, four and a half days: the brief's five audit items, each as a Core change with a test. Plus the `-fps_mode vfr` video fix and the filter chain above, the three code-aware output fixes (indentation, fences, line-addressable JSON), and PDF input (text lane and scan lane, `--pages`, `source.sha256` in `--json`). PDF tables stay in the later bucket. Add `--text` stdin mode and the 30-case golden suite. Add `--rules`, `--ledger --json`, `--ledger --migrate`. Move the ledger to the location rule above.

Phase 2, one day: relicense to MIT, Developer ID cert, release workflow, tap repo, tag v0.5.0.

Phase 3, two to three days: plugin with the image and PDF matcher, SKILL.md, MCP package, status line segment.

Phase 4, after CLI traction: private app repo. Order inside it: folder watcher and free tier first, then StoreKit, then clipboard guard, then video, then rules editor. Clipboard guard before video because it is the stronger reason to pay.

## Risks carried from the brief

1. claude-code#16592: pasted images bypass the hook. Mitigated by the app's clipboard guard, not by the CLI.
2. App Review may push back on a two-year non-renewing subscription. Fallback is in the brief.
3. MIT engine means anyone can build a rival menu bar app. Accepted: the app sells convenience and App Store distribution, not the engine.

## Open questions

1. Bundle and group identifiers: `dev.all-caps.cheapshot` uses a hyphen, which Apple allows but some tools mangle. Alternative `dev.allcaps.cheapshot`. Decide when the Developer ID cert is created.

### Perplexity answers folded in (2026-09-12)

Five questions were sent to Perplexity; the prompts are in `~/Dropbox/00-Agent-Markdown-Dropbox/_action/2026-09-12-perplexity-questions-for-the-cheapshot-spec.md`. Answers so far:

2. **App Review and StoreKit for a 2-year non-renewing subscription. Answered.** A 2-year non-renewing subscription is allowed; Apple documents the type as a limited-duration service with no published maximum, and the seven-day minimum in guideline 3.1.2(a) applies to auto-renewable products only. 3.1.2 does not literally require server-side restore, but Apple's subscription documentation makes the app responsible for cross-device availability and names a server-side account as the usual mechanism. `Transaction.all` is the customer's purchase history and, per the WWDC24 StoreKit session, includes non-renewing subscriptions; StoreKit does not compute an expiry for them. Decision stays: no server. The app ships a visible "Restore Purchases" action that calls `AppStore.sync()` then walks verified `Transaction.all`, computes `purchaseDate + 2 years` itself, honours revocation fields, and treats a repurchase before expiry as extending the end date. Verify in the StoreKit sandbox on two Macs before submission that a non-renewing purchase appears on the second Mac; the API reference page lists non-consumables and auto-renewing products explicitly and the non-renewing claim rests on the session, not the reference. If App Review objects to no-server restore, the fallback is unchanged: a one-year auto-renewing subscription at $2.49. Sources: developer.apple.com/help/app-store-connect/reference/in-app-purchase-types, developer.apple.com/app-store/review/guidelines/ (3.1.2), developer.apple.com/documentation/storekit/handling-subscriptions-billing, developer.apple.com/documentation/storekit/transaction/all, developer.apple.com/videos/play/wwdc2024/10061/.

3. **Can a non-sandboxed CLI write the App Group container? Answered: not reliably.** On macOS 15 and later, app-group containers get SIP-backed protection even when the owning app is not sandboxed. A process that is not a signed, entitled member of the group triggers a user authorization prompt on access and can be denied; Unix ownership and mode bits do not count. Membership is possible for a CLI signed by the same team with the exact `com.apple.security.application-groups` entitlement (the `<TEAMID>.` form needs no provisioning profile on macOS) and validated at runtime (`sudo launchctl procinfo <pid>` shows `entitlements validated`), and the directory must then be resolved through `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, never a hard-coded path. A Mac App Store app also may not install a CLI into shared locations, so the CLI stays a separate brew-distributed product either way. Effect on this spec: the ledger location rule lost its Group Containers step (see "Ledger location and sharing"); the app reads the CLI's ledger through a security-scoped bookmark by default, with the entitled-CLI route as the alternative to evaluate in Phase 4. Sources: developer.apple.com/documentation/xcode/configuring-app-groups, developer.apple.com/videos/play/wwdc2024/10123/ (app-group container protection), developer.apple.com/app-store/review/guidelines/ (2.4.5).

4. **Hook input for PDFs. Answered.** For `Read`, `tool_input` always carries an absolute `file_path` (Claude Code expands `~` and relative paths before the hook runs) plus optional `offset`, `limit`, and a `pages` string such as `"1-5"`; the Agent SDK TypeScript reference publishes the `pages?: string` field. The hook sees the requested input only, never the parsed text or rendered pages. A PDF `Read` returns a summary text block followed by a `document` block inside the tool result; Anthropic does not document the internal conversion or a fixed per-page token rate for Claude Code, and release notes only say `pages` constrains the range and that PDFs over 10 pages referenced with `@` can become a lightweight reference. Effect on this spec: the hook design stands (read `tool_input.pages`, pass it as `--pages`, pass through with a hint over 20 pages when no range is given, all with `jq -r '.tool_input.pages // empty'` so missing fields do not break it). The ledger's per-page number is an estimate of the image tokens a 2x render would cost and is labelled as such; the "real savings" wording in "PDF input" is softened to "an estimate of what a rendered page would cost". Sources: docs.claude.com/en/docs/claude-code/hooks (PreToolUse input, absolute file_path guarantee), the Agent SDK TypeScript reference for the Read tool input type, and the Claude Code changelog entries for `pages` and large `@` PDFs.

5. **Plugin install syntax. Answered; the layout stands.** `.claude-plugin/marketplace.json` sits at the repo root with required fields `name`, `owner.name`, and `plugins[]` each with `name` and `source` (a relative path such as `./plugin` for a plugin in the same repo). The plugin's own `.claude-plugin/` holds only `plugin.json`; `hooks/`, `skills/`, and `.mcp.json` live at the plugin root. `plugin.json` needs `name` and `description`, should carry `version` (it drives marketplace update behaviour), and points at components with `"hooks": "./hooks/hooks.json"` and `"mcpServers": "./.mcp.json"` (both may also be inline objects). `hooks.json` is the normal hooks format: `{"hooks": {"PreToolUse": [{"matcher": "Read", "hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/cheapshot-read.sh"}]}]}}`. `.mcp.json` is the normal `mcpServers` map; for `npx cheapshot-mcp` no plugin-root path is needed. Install is `claude plugin marketplace add all-caps-dev/cheapshot` then `claude plugin install cheapshot@all-caps-dev`, where `all-caps-dev` is the marketplace `name`; the documented primary form is the in-session `/plugin ...` pair. After editing the marketplace, `/plugin marketplace update` then `/reload-plugins`. Effect on this spec: the install line in "Plugin layout" gains the `@all-caps-dev` suffix and the `${CLAUDE_PLUGIN_ROOT}` rule; nothing in Phase 0 or 1 changes. Sources: docs.claude.com/en/docs/claude-code/plugin-marketplaces, docs.claude.com/en/docs/claude-code/plugins-reference, docs.claude.com/en/docs/claude-code/plugins, docs.claude.com/en/docs/claude-code/hooks.

6. **Release plumbing. Answered; three corrections for Phase 2.** (a) `mislav/bump-homebrew-formula-action` commits directly to the tap's base branch when `COMMITTER_TOKEN` can push there, and opens a PR from a fork only when it cannot; `create-pullrequest: true` or `false` forces either. For a personal tap with a write-scoped PAT that means direct commits, which is what the brief's workflow wants. Perplexity could only see v3.2 as the latest published release, so verify the `@v4` tag exists before the workflow relies on it, else pin `@v3`. (b) The formula line is `depends_on macos: :ventura` (keyword-argument DSL, marks macOS-only and Ventura as the minimum); the brief's `depends_on :macos => :ventura` is not the documented form. The formula also says `license "MIT"` per decision 2, not `BUSL-1.1`. (c) Homebrew's Support Tiers page lists Intel x86_64 on Big Sur through Tahoe as Tier 3 as of September 2026 (no Intel CI, no new Intel bottles, removal planned for September 2027 or later). The universal binary decision stands for the one-year window the brief named; the release workflow builds it with `swift build -c release --arch arm64 --arch x86_64` (the Makefile from Phase 0), not the brief's two `swiftc` invocations, and the README says Intel is best-effort. Sources: github.com/mislav/bump-homebrew-formula-action (README, `create-pullrequest`), docs.brew.sh/Formula-Cookbook (`depends_on macos:`), docs.brew.sh/Support-Tiers, brew.sh/2025/11/12/homebrew-5.0.0/.

All five questions are now answered. Answer 2 changed the ledger location rule; answers 4 and 6 correct Phase 2 and 3 details; answers 1 and 3 confirmed decisions with caveats recorded above.

Note for the ledger window: a user who never installs the CLI has only the app's own captures in the ledger. The window must read cleanly with a small or empty ledger and never show a "install the CLI" nag in the free tier.

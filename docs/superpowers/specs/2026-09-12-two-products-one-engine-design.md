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
  Sources/CheapshotCore/     OCR, redaction, rules, ledger, tokens, video
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
| `Tokens.image(width:height:)` and `Tokens.text(_:)` | Today's estimators | Unchanged. |
| `Ledger(at: URL)` with `append(Entry)` and `summary(days:) -> Summary` | JSONL, one line per run, `O_APPEND` single write | Location rule below. |
| `FrameSource` protocol, `FFmpegFrameSource`, `AVFoundationFrameSource` | Yield `(timestamp, CGImage)` for a video | See "Video". |
| `VideoTranscriber(source: FrameSource, dedupe: Double)` | Frames to OCR to deduped transcript with timestamps | Today's loop in `--video`, minus the `exit(0)` leak. |

### Ledger location and sharing

The sales pitch is "you saved N tokens this week". Most of those savings will come from the CLI hook, not from the app. So the app must read the CLI's ledger.

Rule: Core resolves the ledger directory in this order.

1. `$CHEAPSHOT_HOME/ledger.jsonl` if the variable is set.
2. `~/Library/Group Containers/<TEAMID>.dev.all-caps.cheapshot/ledger.jsonl` if that directory exists. The app creates it on first launch through its App Group entitlement. The CLI is not sandboxed, so it can write there directly.
3. `~/Library/Application Support/cheapshot/ledger.jsonl` otherwise.

The team ID prefix is a constant in Core. It is harmless in a FOSS repo; it only names a folder. Existing `~/.claude/cheapshot-ledger/*.tsv` files are imported once by `cheapshot --ledger --migrate` and left in place.

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

Install: `claude plugin marketplace add all-caps-dev/cheapshot` then `claude plugin install cheapshot`.

Hook behaviour:

1. Fires on `Read` where `file_path` ends in png, jpg, jpeg, webp, gif.
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
3. Create the App Group ledger directory so the CLI starts writing there too.

### Free tier

1. Watch the folder with `FSEvents` through the bookmark. On a new image: OCR, redact, put the text on the clipboard, notify with the token count. One toggle: "copy text automatically" versus "notify only".
2. Ledger window shows the last 7 days: images processed, tokens saved, redactions by rule.
3. Redaction on by default, built-in rules only.

### Paid tier, $4.99 for two years

1. **Clipboard guard.** This is the feature that closes the gap the CLI cannot: claude-code#16592 means a pasted screenshot is never seen by a hook. The app watches `NSPasteboard.general` for image data. When one lands, it OCRs it in the background and offers a global hotkey (default Cmd-Shift-V) that replaces the image on the clipboard with the redacted text and pastes it. The image is never auto-replaced; the user chooses per paste. That keeps image pastes into Figma or Slack working.
2. **Video transcripts.** Drop a screen recording on the menu bar icon, or pick from the folder watcher when a `.mov` appears. Uses `AVFoundationFrameSource`.
3. **Ledger history.** All time, per day chart, export as CSV.
4. **Custom redaction rules.** Editor with a live test field. Writes the same `rules.json` the CLI reads with `--rules`, at the App Group path, so the CLI picks them up too.

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

## Build order, revised

Phase 0, half a day: create `Package.swift`, move `cheapshot.swift` into `Sources/CheapshotCore` and `Sources/cheapshot`, no behaviour change, commit. Homebrew formula becomes `swift build -c release`.

Phase 1, four days: the brief's five audit items, each as a Core change with a test. Plus the `-fps_mode vfr` video fix and the filter chain above, and the three code-aware output fixes (indentation, fences, line-addressable JSON). Add `--text` stdin mode and the 30-case golden suite. Add `--rules`, `--ledger --json`, `--ledger --migrate`. Move the ledger to the location rule above.

Phase 2, one day: relicense to MIT, Developer ID cert, release workflow, tap repo, tag v0.5.0.

Phase 3, two to three days: plugin, SKILL.md, MCP package, status line segment.

Phase 4, after CLI traction: private app repo. Order inside it: folder watcher and free tier first, then StoreKit, then clipboard guard, then video, then rules editor. Clipboard guard before video because it is the stronger reason to pay.

## Risks carried from the brief

1. claude-code#16592: pasted images bypass the hook. Mitigated by the app's clipboard guard, not by the CLI.
2. App Review may push back on a two-year non-renewing subscription. Fallback is in the brief.
3. MIT engine means anyone can build a rival menu bar app. Accepted: the app sells convenience and App Store distribution, not the engine.

## Open questions

1. Bundle and group identifiers: `dev.all-caps.cheapshot` uses a hyphen, which Apple allows but some tools mangle. Alternative `dev.allcaps.cheapshot`. Decide when the Developer ID cert is created.

Note for the ledger window: a user who never installs the CLI has only the app's own captures in the ledger. The window must read cleanly with a small or empty ledger and never show a "install the CLI" nag in the free tier.

# Phase 0 and Phase 1: Core split and audit fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the single-file `cheapshot.swift` into a SwiftPM package with a `CheapshotCore` library, a thin CLI, and a test suite, then land every Phase 1 fix from the spec with a test each.

**Architecture:** `Sources/CheapshotCore` holds redaction, OCR, layout arithmetic, tokens, ledger, video, and PDF, and knows nothing about the command line. `Sources/CheapshotCLI` is a library holding argument parsing, the runner, and output formatting, so it can be unit-tested; `Sources/cheapshot` is a three-line `@main`. Tests use XCTest with synthetic inputs only; Vision output is never golden-tested.

**Tech Stack:** Swift 6.3.3 toolchain in Swift 5 language mode (`swift-tools-version:5.9`), SwiftPM, XCTest, Vision, AppKit, PDFKit, CryptoKit, ffmpeg 9 on PATH for the video test.

**Spec:** `docs/superpowers/specs/2026-09-12-two-products-one-engine-design.md` (wins over `docs/product-brief.md`; the brief's "Appendix: 01-code-audit" holds the line-numbered findings).

## Global Constraints

- Deployment target macOS 13. `Package.swift` declares `platforms: [.macOS(.v13)]`. The release binary is universal (arm64 and x86_64) and `otool -l` must show `minos 13.0` on both slices.
- Phase 0 and Phase 1 only. No plugin, no MCP server, no relicense, no app, no AVFoundation frame source, no PDF tables.
- Do not golden-test Vision OCR output. Test redaction, arg parsing, ledger, PDF text lane, and video frame counting with synthetic inputs. Vision may run in tests only on inputs whose OCR result is not asserted (a blank page).
- Core knows nothing about licenses, tiers, or the App Store. No "is this user paid" branches anywhere.
- Never push. One commit per task on `main`. Commits are SSH-signed through 1Password. If `git commit` fails with "failed to fill whole buffer", leave the work staged and report the exact `! git commit -F <file>` line for Ryan to run.
- Ledger location rule, in order: `$CHEAPSHOT_HOME/ledger.jsonl`; `~/Library/Application Support/cheapshot/ledger.jsonl` otherwise. (The spec's Group Containers step was removed on 2026-09-12 after Perplexity answer 2: a CLI outside the App Group gets a macOS 15 authorization prompt.) Append is one `write(2)` on a file opened `O_WRONLY|O_APPEND|O_CREAT`.
- Video filter chain after Phase 1, verbatim from the spec: `-an -sn -vf "fps=4,mpdecimate=hi=64*12:lo=64*5:frac=0.1,select=eq(n\,0)+gt(scene\,T),metadata=print:file=-" -fps_mode vfr -q:v 2 f_%05d.jpg`. Threshold `T` stays at the current default 0.25; retuning needs real recordings and is out of scope.
- Exit codes: 0 success, 1 when any input failed (including partial failure), 2 for usage errors (unknown flag, missing value, no inputs).
- `--json` payload keeps its top-level shape `{version, results, image_tokens, text_tokens}`. Failed inputs appear in `results` as `{"file": path, "error": message}`. Image results gain `lines: [{n, text, bbox, confidence}]`. PDF results gain `source: {path, sha256, pages}` and `pages: [{n, lane, lines}]`.
- `bbox` is `[x0, y0, x1, y1]` with a top-left origin: pixels for images and rendered PDF pages, PDF points for the PDF text lane.
- Version string stays `0.4.1` until the last task sets it to `0.5.0-dev`. Tagging v0.5.0 is Phase 2.
- Verified on this Mac before planning: `swift test` and `swift build -c release --arch arm64 --arch x86_64` work on Swift 6.3.3 with a tools-version 5.9 package, `Bundle.module` resources load in tests, and the new ffmpeg chain writes 3 JPEGs for 3 printed frames on the synthetic clip in Task 11 (the old chain wrote 39).

---

## File structure

```
Package.swift
Makefile
Sources/CheapshotCore/
  Version.swift                  public let cheapshotVersion
  Redaction/Validators.swift     luhn, aba, entropy, looksLikeSecret
  Redaction/Rule.swift           Rule, Rule.builtin
  Redaction/Redactor.swift       Redactor, RedactionReport
  Redaction/RuleFile.swift       RuleFile.load(url)
  OCR/ImageLoader.swift          CGImage from a path, pixel size
  OCR/OCR.swift                  OCR.recognize(image:minConfidence:languageCorrection:) -> OCRResult
  OCR/Layout.swift               indentation, monospace runs, fences, RenderedLine
  Tokens.swift                   Tokens.image(width:height:), Tokens.text(_:)
  Ledger/Ledger.swift            Ledger, LedgerEntry, LedgerSummary, location rule, O_APPEND
  Ledger/LedgerMigration.swift   Ledger.migrate(fromTSVDirectory:)
  Video/FrameSource.swift        FrameSource protocol, VideoFrame
  Video/FFmpegFrameSource.swift  ffmpeg adapter, temp dir it owns and deletes
  Video/VideoTranscriber.swift   frames -> OCR -> dedupe -> VideoTranscript
  PDF/PDFSource.swift            text lane, scan lane, sha256, --pages range
Sources/CheapshotCLI/
  Options.swift                  Options.parse([String]) throws -> Options, UsageError
  CLIIO.swift                    stdout/stderr/stdin/env injection for tests
  Runner.swift                   CLI.run(arguments:io:) async -> Int32
  Output.swift                   JSON payload building, text rendering, usage text
Sources/cheapshot/Cheapshot.swift   @main, calls CLI.run
Tests/CheapshotCoreTests/
  ValidatorsTests.swift, RedactorTests.swift, GoldenTests.swift, RuleFileTests.swift,
  LayoutTests.swift, TokensTests.swift, LedgerTests.swift, LedgerMigrationTests.swift,
  FFmpegFrameSourceTests.swift, PDFSourceTests.swift
  Golden/cases/NN-name.txt and Golden/expected/NN-name.txt  (30 pairs)
Tests/CheapshotCLITests/
  OptionsTests.swift, RunnerTests.swift
```

Phase 0 (Tasks 1 and 2) moves the code with no behaviour change. Phase 1 (Tasks 3 to 13) reshapes it into the structure above.

## Public API reference

Every later task uses exactly these names. If a task's code disagrees with this table, the table wins.

```swift
// Sources/CheapshotCore
public let cheapshotVersion: String

public struct Rule {
    public let name: String
    public let pattern: String
    public let options: NSRegularExpression.Options
    public let validator: ((String) -> Bool)?
    public init(name: String, pattern: String, options: NSRegularExpression.Options = [.caseInsensitive], validator: ((String) -> Bool)? = nil)
    public static let builtin: [Rule]
}
public enum Validators {
    public static func luhn(_ s: String) -> Bool
    public static func aba(_ s: String) -> Bool
    public static func entropy(_ s: String) -> Double
    public static func looksLikeSecret(_ s: String) -> Bool
}
public struct RedactionReport: Equatable { public var counts: [String: Int]; public var total: Int { get } }
public struct Redactor {
    public let rules: [Rule]
    public init(rules: [Rule] = Rule.builtin)
    public init(customRules: [Rule])              // custom first, then Rule.builtin
    public func redact(_ input: String) -> (text: String, report: RedactionReport)
}
public enum RuleFile {
    public struct LoadError: Error, Equatable, CustomStringConvertible { public let message: String }
    public static func load(_ url: URL) throws -> [Rule]
    public static func parse(_ data: Data) throws -> [Rule]
}

public struct OCRLine: Equatable { public var text: String; public var bbox: CGRect; public var confidence: Float }
public struct OCRResult: Equatable { public var lines: [OCRLine]; public var width: Int; public var height: Int }
public enum OCR {
    public struct Failure: Error { public let message: String }
    public static func recognize(image: CGImage, minConfidence: Float, languageCorrection: Bool = true) throws -> OCRResult
}
public enum ImageLoader {
    public static func load(path: String) -> CGImage?
    public static func pixelSize(path: String) -> (width: Int, height: Int)?
}
public struct RenderedLine: Equatable { public var n: Int; public var text: String; public var bbox: CGRect; public var confidence: Float; public var fenced: Bool }
public enum Layout {
    public static func render(_ lines: [OCRLine]) -> [RenderedLine]
    public static func text(_ lines: [RenderedLine]) -> String
    public static func monospaceRuns(_ lines: [OCRLine]) -> [Range<Int>]
    public static func cellWidth(_ line: OCRLine) -> CGFloat?
}
public enum Tokens {
    public static func image(width: Int, height: Int) -> Int
    public static func text(_ s: String) -> Int
}

public struct LedgerEntry: Codable, Equatable {
    public var ts: String; public var mode: String; public var inputs: Int
    public var imageTokens: Int; public var textTokens: Int; public var saved: Int; public var redactions: Int
    public init(ts: String = LedgerEntry.now(), mode: String, inputs: Int, imageTokens: Int, textTokens: Int, redactions: Int)
    public static func now() -> String
}
public struct LedgerSummary: Codable, Equatable { public var days: Int; public var runs: Int; public var inputs: Int; public var imageTokens: Int; public var textTokens: Int; public var saved: Int; public var redactions: Int; public var percent: Int }
public struct Ledger {
    public static let fileName: String                         // "ledger.jsonl"
    public let url: URL
    public init(at url: URL)
    public static func resolveURL(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> URL
    public func append(_ entry: LedgerEntry) throws
    public func entries() throws -> [LedgerEntry]
    public func summary(days: Int? = nil) throws -> LedgerSummary
    public func migrate(fromTSVDirectory dir: URL) throws -> Int
    public static func defaultTSVDirectory(home: String = NSHomeDirectory()) -> URL
    public func summaryText(_ s: LedgerSummary) -> String
}

public struct VideoFrame { public let time: TimeInterval; public let image: CGImage }
public protocol FrameSource {
    func frames(of video: URL, maxFrames: Int) throws -> AsyncThrowingStream<VideoFrame, Error>
}
public struct FFmpegFrameSource: FrameSource {
    public struct Failure: Error, CustomStringConvertible { public let message: String }
    public init(ffmpegPath: String? = nil, sceneThreshold: Double = 0.25, tempBase: URL = URL(fileURLWithPath: NSTemporaryDirectory()))
    public static func findFFmpeg(environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    public static func filterChain(threshold: Double) -> String
}
public struct VideoSegment: Equatable { public var time: TimeInterval; public var text: String }
public struct VideoTranscript { public var segments: [VideoSegment]; public var frameCount: Int; public var imageTokens: Int; public var redactions: RedactionReport }
public struct VideoTranscriber {
    public init(source: FrameSource, dedupe: Double = 0.90, minConfidence: Float = 0.3, redactor: Redactor? = Redactor())
    public func transcribe(_ video: URL, maxFrames: Int) async throws -> VideoTranscript
    public static func similarity(_ a: String, _ b: String) -> Double
    public static func stamp(_ seconds: TimeInterval) -> String
}

public enum PDFLane: String, Codable { case text, scan }
public struct PDFPageResult { public var n: Int; public var lane: PDFLane; public var lines: [RenderedLine]; public var width: Int; public var height: Int }
public struct PDFDocumentResult { public var path: String; public var sha256: String; public var pageCount: Int; public var pages: [PDFPageResult] }
public enum PDFSource {
    public struct Failure: Error, CustomStringConvertible { public let message: String }
    public static let scanLaneThreshold: Int                   // 20 characters
    public static func pages(of url: URL, range: ClosedRange<Int>?, minConfidence: Float) throws -> PDFDocumentResult
    public static func sha256(of url: URL) throws -> String
    public static func text(of result: PDFDocumentResult) -> String   // "--- page N ---" separators
}

// Sources/CheapshotCLI
public struct UsageError: Error, Equatable { public let message: String }
public struct Options: Equatable {
    public enum Command: Equatable {
        case help, version
        case ledger(json: Bool, migrate: Bool)
        case text(path: String)                 // "-" means stdin
        case video(path: String)
        case files([String])
        case newest(dir: String, count: Int)
        case cleanshot(count: Int)
    }
    public var command: Command
    public var redact: Bool = true, json: Bool = false, stats: Bool = false, noLedger: Bool = false
    public var minConfidence: Float = 0.3
    public var scene: Double = 0.25, maxFrames: Int = 200, dedupe: Double = 0.90
    public var rulesPath: String? = nil
    public var pages: ClosedRange<Int>? = nil
    public static func parse(_ args: [String]) throws -> Options
    public static func parsePages(_ s: String) throws -> ClosedRange<Int>
}
public struct CLIIO {
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var readStdin: () -> String
    public var environment: [String: String]
    public var home: String
    public static var standard: CLIIO { get }
}
public enum CLI {
    public static func run(arguments: [String], io: CLIIO = .standard) async -> Int32
}
public enum Output {
    public static func usage() -> String
    public static func json(_ object: Any) -> String
}
```

---

## Phase 0: package split, no behaviour change

### Task 1: Package.swift and the mechanical split

**Files:**
- Create: `Package.swift`
- Create: `Sources/CheapshotCore/Core.swift` (lines 1 to 287 of `cheapshot.swift`, made public)
- Create: `Sources/cheapshot/main.swift` (lines 289 to 464 of `cheapshot.swift`, unchanged apart from `import CheapshotCore`)
- Create: `Tests/CheapshotCoreTests/SmokeTests.swift`
- Delete: `cheapshot.swift`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `CheapshotCore` module exporting, unchanged in behaviour, `VERSION`, `Rule`, `RULES`, `passesLuhn`, `passesABA`, `entropy`, `looksLikeSecret`, `RedactionReport`, `redact(_:)`, `ocr(path:minConfidence:)`, `findFFmpeg()`, `sceneFrames(video:threshold:maxFrames:)`, `similarity(_:_:)`, `stamp(_:)`, `imageTokens(path:)`, `textTokens(_:)`, `ledgerAppend(...)`, `ledgerTotal()`. All become `public`. Task 3 onward replaces them.

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cheapshot",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CheapshotCore", targets: ["CheapshotCore"]),
        .executable(name: "cheapshot", targets: ["cheapshot"]),
    ],
    targets: [
        .target(
            name: "CheapshotCore",
            linkerSettings: [.linkedFramework("Vision"), .linkedFramework("AppKit")]
        ),
        .executableTarget(name: "cheapshot", dependencies: ["CheapshotCore"]),
        .testTarget(name: "CheapshotCoreTests", dependencies: ["CheapshotCore"]),
    ]
)
```

- [ ] **Step 2: Move the engine into Core**

Run:
```bash
mkdir -p Sources/CheapshotCore Sources/cheapshot Tests/CheapshotCoreTests
sed -n '1,287p' cheapshot.swift > Sources/CheapshotCore/Core.swift
{ echo 'import Foundation'; echo 'import AppKit'; echo 'import CheapshotCore'; echo; sed -n '289,464p' cheapshot.swift; } > Sources/cheapshot/main.swift
git rm -q cheapshot.swift
```

Then in `Sources/CheapshotCore/Core.swift` add `public` to every top-level declaration the CLI uses. The exact edits:

- `let VERSION` -> `public let VERSION`
- `struct Rule` -> `public struct Rule`; its three `let` fields -> `public let`; its `init` -> `public init`
- `let RULES` -> `public let RULES`
- `func passesLuhn`, `func passesABA`, `func entropy`, `func looksLikeSecret` -> `public func`
- `struct RedactionReport { var counts` -> `public struct RedactionReport { public var counts ... ; public init() {} }`
- `func redact` -> `public func redact`
- `func ocr` -> `public func ocr`
- `func findFFmpeg`, `func sceneFrames`, `func similarity`, `func stamp`, `func imageTokens`, `func textTokens`, `func ledgerAppend`, `func ledgerTotal` -> `public func`

The `main.swift` file keeps `usage()`, `popValue`, `newest`, `cleanshotDir`, and all top-level statements exactly as they were. Line 320 `var doRedact = true, asJSON = false, showStats = false` and everything else stays.

- [ ] **Step 3: Write the smoke test**

`Tests/CheapshotCoreTests/SmokeTests.swift`:
```swift
import XCTest
@testable import CheapshotCore

final class SmokeTests: XCTestCase {
    func testRedactEmail() {
        let (text, report) = redact("mail ryan@example.com now")
        XCTAssertEqual(text, "mail [EMAIL] now")
        XCTAssertEqual(report.counts["EMAIL"], 1)
    }

    func testTextTokens() {
        XCTAssertEqual(textTokens("12345678"), 2)
        XCTAssertEqual(textTokens(""), 1)
    }
}
```

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed|error" `
Expected: `Build complete!` and `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Behaviour check against the old binary**

Run:
```bash
git show HEAD:cheapshot.swift > /tmp/cs-old.swift && swiftc -O /tmp/cs-old.swift -o /tmp/cs-old -framework Vision -framework AppKit
/tmp/cs-old --help > /tmp/help-old.txt; .build/debug/cheapshot --help > /tmp/help-new.txt; diff /tmp/help-old.txt /tmp/help-new.txt && echo HELP_SAME
/tmp/cs-old --version; .build/debug/cheapshot --version
```
Expected: `HELP_SAME` and both print `0.4.1`.

- [ ] **Step 6: Update .gitignore and commit**

Append `.build/` and `*.xcodeproj` to `.gitignore`. Keep the existing `cheapshot` and `ocra` lines.

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "phase 0: split cheapshot.swift into CheapshotCore and a CLI target

No behaviour change. swift build and swift test work; the CLI's --help and
--version output are byte-identical to v0.4.1."
```

---

### Task 2: Makefile with a universal macOS 13 binary

**Files:**
- Create: `Makefile`
- Modify: `README.md` "Install" section (lines 18 to 23)

**Interfaces:**
- Produces: `make` builds `./cheapshot` universal; `make check` verifies both slices say `minos 13.0`; `make test` runs `swift test`; `make install` copies to `$(PREFIX)/bin`.

- [ ] **Step 1: Write the Makefile**

```make
# cheapshot: universal (arm64 + x86_64) release binary, macOS 13 floor.
PREFIX ?= /usr/local
PRODUCT = .build/apple/Products/Release/cheapshot

.PHONY: all build check test install clean

all: build check

build:
	swift build -c release --arch arm64 --arch x86_64
	cp $(PRODUCT) ./cheapshot

check:
	@lipo -info ./cheapshot | grep -q "x86_64 arm64" || lipo -info ./cheapshot | grep -q "arm64 x86_64" || (echo "not universal" && exit 1)
	@test "$$(otool -l ./cheapshot | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $$2; f=0}' | sort -u)" = "13.0" || (echo "minos is not 13.0 on every slice" && exit 1)
	@echo "ok: universal, minos 13.0"

test:
	swift test

install: build
	install -d $(PREFIX)/bin
	install -m 755 ./cheapshot $(PREFIX)/bin/cheapshot

clean:
	rm -rf .build ./cheapshot
```

Use a real tab before each recipe line.

- [ ] **Step 2: Run it**

Run: `make 2>&1 | tail -4`
Expected: last line `ok: universal, minos 13.0`.

Run: `./cheapshot --version`
Expected: `0.4.1`.

- [ ] **Step 3: Update README install**

Replace the Install block with:
```markdown
## Install

```bash
make            # universal binary at ./cheapshot, macOS 13 or newer
make install    # copies it to /usr/local/bin (PREFIX=... to change)
```

Needs the Xcode command line tools. `swift test` runs the test suite.
```

- [ ] **Step 4: Commit**

```bash
git add Makefile README.md
git commit -m "phase 0: Makefile builds a universal macOS 13 binary and checks minos"
```

---

## Phase 1: audit fixes, each as a Core change with a test

### Task 3: Rule with validators and an injectable Redactor

**Files:**
- Create: `Sources/CheapshotCore/Version.swift`
- Create: `Sources/CheapshotCore/Redaction/Validators.swift`
- Create: `Sources/CheapshotCore/Redaction/Rule.swift`
- Create: `Sources/CheapshotCore/Redaction/Redactor.swift`
- Modify: `Sources/CheapshotCore/Core.swift` (delete lines for VERSION, Rule, RULES, passesLuhn, passesABA, entropy, looksLikeSecret, RedactionReport, redact)
- Modify: `Sources/cheapshot/main.swift` (call sites)
- Modify: `Tests/CheapshotCoreTests/SmokeTests.swift` -> rename to `RedactorTests.swift`
- Create: `Tests/CheapshotCoreTests/ValidatorsTests.swift`

**Interfaces:**
- Produces: `Rule`, `Rule.builtin`, `Validators`, `RedactionReport`, `Redactor` exactly as in the API reference. `cheapshotVersion` replaces `VERSION`.
- The CLI (still the Phase 0 `main.swift`) calls `Redactor().redact(raw)` where it called `redact(raw)`, and `cheapshotVersion` where it used `VERSION`.

- [ ] **Step 1: Write the failing tests**

`Tests/CheapshotCoreTests/ValidatorsTests.swift`:
```swift
import XCTest
@testable import CheapshotCore

final class ValidatorsTests: XCTestCase {
    func testLuhn() {
        XCTAssertTrue(Validators.luhn("4111 1111 1111 1111"))
        XCTAssertFalse(Validators.luhn("4111-1111-1111-1112"))
        XCTAssertFalse(Validators.luhn("123456789012"))   // 12 digits, too short
    }

    func testABA() {
        XCTAssertTrue(Validators.aba("021000021"))
        XCTAssertFalse(Validators.aba("123456789"))
        XCTAssertFalse(Validators.aba("02100002"))
    }

    func testEntropy() {
        XCTAssertEqual(Validators.entropy(""), 0)
        XCTAssertEqual(Validators.entropy("aaaa"), 0)
        XCTAssertEqual(Validators.entropy("ab"), 1, accuracy: 0.0001)
    }

    func testLooksLikeSecret() {
        XCTAssertFalse(Validators.looksLikeSecret("https://example.com/AbCdEf"))
        XCTAssertFalse(Validators.looksLikeSecret("/Users/ryan/local-dev/Cheapshot"))
        XCTAssertTrue(Validators.looksLikeSecret("dGhpcyBpcyBhIHNlY3JldCB0b2tlbiBub2JvZHkgc2hvdWxkIHNlZQ=="))
    }
}
```

`Tests/CheapshotCoreTests/RedactorTests.swift` (replaces `SmokeTests.swift`):
```swift
import XCTest
@testable import CheapshotCore

final class RedactorTests: XCTestCase {
    func testBuiltinRedactsEmail() {
        let (text, report) = Redactor().redact("mail ryan@example.com now")
        XCTAssertEqual(text, "mail [EMAIL] now")
        XCTAssertEqual(report.counts["EMAIL"], 1)
        XCTAssertEqual(report.total, 1)
    }

    func testCardRuleUsesLuhnValidator() {
        XCTAssertEqual(Redactor().redact("card 4111 1111 1111 1111").text, "card [CARD]")
        XCTAssertEqual(Redactor().redact("card 4111-1111-1111-1112").text, "card 4111-1111-1111-1112")
    }

    func testCustomRulesRunFirst() {
        let custom = Rule(name: "TICKET", pattern: #"\bINT-\d{6}\b"#)
        let r = Redactor(customRules: [custom])
        XCTAssertEqual(r.rules.first?.name, "TICKET")
        XCTAssertEqual(r.rules.count, Rule.builtin.count + 1)
        XCTAssertEqual(r.redact("see INT-123456 and ryan@example.com").text, "see [TICKET] and [EMAIL]")
    }

    func testEmptyRulesIsIdentity() {
        XCTAssertEqual(Redactor(rules: []).redact("ryan@example.com").text, "ryan@example.com")
    }

    func testVersionConstant() {
        XCTAssertEqual(cheapshotVersion, "0.4.1")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test 2>&1 | grep -E "error:|Executed" | head`
Expected: compile errors, `Validators`, `Redactor`, `cheapshotVersion` not found.

- [ ] **Step 3: Write Version.swift and Validators.swift**

`Sources/CheapshotCore/Version.swift`:
```swift
public let cheapshotVersion = "0.4.1"
```

`Sources/CheapshotCore/Redaction/Validators.swift`:
```swift
import Foundation

public enum Validators {
    /// Luhn check so CARD only fires on a real card number.
    public static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    /// ABA routing numbers carry a checksum; validating it keeps ROUTING from eating every 9-digit number.
    public static func aba(_ s: String) -> Bool {
        let d = s.compactMap { $0.wholeNumberValue }
        guard d.count == 9 else { return false }
        let sum = 3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])
        return sum % 10 == 0
    }

    /// Shannon entropy, bits per character.
    public static func entropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        return freq.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }

    /// TOKEN is the catch-all for secrets with no recognizable prefix. Its character class
    /// contains "/" and ".", so without a gate it swallows every absolute path and screenshot
    /// filename. Measured on real input: paths and CleanShot filenames top out at 4.14 bits/char,
    /// prefix-less secrets start at 4.66. 4.4 sits in the gap.
    public static func looksLikeSecret(_ s: String) -> Bool {
        if s.contains("://") { return false }   // URL
        if s.hasPrefix("/")  { return false }   // absolute path
        return entropy(s) >= 4.4
    }
}
```

- [ ] **Step 4: Write Rule.swift**

`Sources/CheapshotCore/Redaction/Rule.swift`:
```swift
import Foundation

/// One redaction rule. `validator` runs on each regex hit and can veto it.
public struct Rule {
    public let name: String
    public let pattern: String
    public let options: NSRegularExpression.Options
    public let validator: ((String) -> Bool)?

    public init(name: String, pattern: String,
                options: NSRegularExpression.Options = [.caseInsensitive],
                validator: ((String) -> Bool)? = nil) {
        self.name = name; self.pattern = pattern; self.options = options; self.validator = validator
    }

    /// Ordered most specific first, so a key is not eaten by a looser rule.
    public static let builtin: [Rule] = [
        Rule(name: "AWS_KEY",     pattern: #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b"#, options: []),
        Rule(name: "GITHUB_PAT",  pattern: #"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b"#, options: []),
        Rule(name: "OPENAI_KEY",  pattern: #"\bsk-(?:proj-|ant-|live-)?[A-Za-z0-9_\-]{20,}\b"#, options: []),
        Rule(name: "SLACK_TOKEN", pattern: #"\bxox[abposr]-[A-Za-z0-9\-]{10,}\b"#, options: []),
        Rule(name: "JWT",         pattern: #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, options: []),
        Rule(name: "PRIVATE_KEY", pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, options: []),
        Rule(name: "BEARER",      pattern: #"\bBearer\s+[A-Za-z0-9._\-]{16,}"#),
        Rule(name: "EMAIL",       pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
        Rule(name: "SSN",         pattern: #"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#, options: []),
        Rule(name: "ROUTING",     pattern: #"\b\d{4}[ \-]?\d{4}[ \-]?\d\b"#, options: [], validator: Validators.aba),
        Rule(name: "CARD",        pattern: #"\b\d(?:[ \-]?\d){12,18}\b"#, options: [], validator: Validators.luhn),
        Rule(name: "BANK_ACCT",   pattern: #"(?<![\w\-/])\d{8,}(?![\w\-/])"#, options: []),
        Rule(name: "PHONE",       pattern: #"(?<!\d)(?:\+?1[ \-.])?\(?\d{3}\)?[ \-.]\d{3}[ \-.]\d{4}(?!\d)"#, options: []),
        Rule(name: "TOKEN",       pattern: #"(?<![A-Za-z0-9_\-+/=.])(?=[A-Za-z0-9_\-+/=.]*[a-z])(?=[A-Za-z0-9_\-+/=.]*[A-Z])[A-Za-z0-9_\-+/=.]{20,}"#, options: [], validator: Validators.looksLikeSecret),
        Rule(name: "IPV4",        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#, options: []),
    ]
}
```

EMAIL and BANK_ACCT are copied unchanged here on purpose; Task 4 changes them behind the golden suite.

- [ ] **Step 5: Write Redactor.swift**

`Sources/CheapshotCore/Redaction/Redactor.swift`:
```swift
import Foundation

public struct RedactionReport: Equatable {
    public var counts: [String: Int] = [:]
    public var total: Int { counts.values.reduce(0, +) }
    public init(counts: [String: Int] = [:]) { self.counts = counts }
}

public struct Redactor {
    public let rules: [Rule]
    private let compiled: [(Rule, NSRegularExpression)]

    public init(rules: [Rule] = Rule.builtin) {
        self.rules = rules
        self.compiled = rules.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern, options: rule.options)).map { (rule, $0) }
        }
    }

    /// Custom rules go first so they win over the built-ins.
    public init(customRules: [Rule]) {
        self.init(rules: customRules + Rule.builtin)
    }

    public func redact(_ input: String) -> (text: String, report: RedactionReport) {
        var text = input
        var report = RedactionReport()
        for (rule, re) in compiled {
            let ns = text as NSString
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }
            var result = ""
            var last = text.startIndex
            for m in matches {
                guard let r = Range(m.range, in: text) else { continue }
                let hit = String(text[r])
                if let v = rule.validator, !v(hit) { continue }
                result += text[last..<r.lowerBound] + "[\(rule.name)]"
                report.counts[rule.name, default: 0] += 1
                last = r.upperBound
            }
            result += text[last...]
            text = result
        }
        return (text, report)
    }
}
```

- [ ] **Step 6: Remove the old definitions and fix call sites**

In `Sources/CheapshotCore/Core.swift` delete: `let VERSION`, `struct Rule`, `let RULES`, `passesLuhn`, `passesABA`, `entropy`, `looksLikeSecret`, `struct RedactionReport`, `func redact`. Keep everything from `// MARK: - OCR` down.

In `Sources/cheapshot/main.swift`:
- every `VERSION` -> `cheapshotVersion` (usage text, `--version`, JSON payload)
- `redact(raw).0` -> `Redactor().redact(raw).text`
- `doRedact ? redact(raw) : (raw, RedactionReport())` -> `doRedact ? Redactor().redact(raw) : (raw, RedactionReport())`
- `report.counts.values.reduce(0, +)` -> `report.total`

- [ ] **Step 7: Run tests**

Run: `swift test 2>&1 | grep -E "error:|Executed"`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add -A Sources Tests
git commit -m "core: Rule with validators, injectable Redactor, cheapshotVersion

Luhn, ABA, and looksLikeSecret become validator closures on the rule instead
of name checks inside the loop. Redactor(customRules:) puts custom rules first."
```

---

### Task 4: BANK_ACCT context cue, EMAIL fix, and the 30-case golden suite

**Files:**
- Modify: `Sources/CheapshotCore/Redaction/Rule.swift` (EMAIL and BANK_ACCT lines)
- Modify: `Package.swift` (test resources)
- Create: `Tests/CheapshotCoreTests/GoldenTests.swift`
- Create: `Tests/CheapshotCoreTests/Golden/cases/*.txt` and `Tests/CheapshotCoreTests/Golden/expected/*.txt` (30 pairs)
- Modify: `README.md` redaction table rows for `EMAIL` and `BANK_ACCT`

**Interfaces:**
- Consumes: `Redactor().redact(_:)` from Task 3.
- Produces: the two new patterns. Every later redaction change must keep this suite green.

Expected outputs below were verified on this Mac against the current redactor with only these two patterns swapped.

- [ ] **Step 1: Add the resource declaration**

In `Package.swift` change the test target to:
```swift
.testTarget(name: "CheapshotCoreTests", dependencies: ["CheapshotCore"], resources: [.copy("Golden")]),
```

- [ ] **Step 2: Write the golden runner**

`Tests/CheapshotCoreTests/GoldenTests.swift`:
```swift
import XCTest
@testable import CheapshotCore

/// Each Golden/cases/NN-name.txt is redacted and compared to Golden/expected/NN-name.txt.
/// A trailing newline in either file is ignored. Every case is one test failure line.
final class GoldenTests: XCTestCase {
    func testGoldenCases() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Golden", withExtension: nil))
        let casesDir = root.appendingPathComponent("cases")
        let expectedDir = root.appendingPathComponent("expected")
        let names = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { $0.hasSuffix(".txt") }.sorted()
        XCTAssertEqual(names.count, 30, "expected 30 golden cases, found \(names.count)")
        let redactor = Redactor()
        for name in names {
            let input = try String(contentsOf: casesDir.appendingPathComponent(name), encoding: .utf8)
            let expected = try String(contentsOf: expectedDir.appendingPathComponent(name), encoding: .utf8)
            let got = redactor.redact(input.trimmingTrailingNewline()).text
            XCTAssertEqual(got, expected.trimmingTrailingNewline(), "golden case \(name)")
        }
    }
}

private extension String {
    func trimmingTrailingNewline() -> String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
```

- [ ] **Step 3: Write the 30 case and expected files**

Run this script from the repo root. Each block is `name`, then input lines, then `=>`, then expected lines.

```bash
mkdir -p Tests/CheapshotCoreTests/Golden/cases Tests/CheapshotCoreTests/Golden/expected
python3 - <<'PY'
import os
cases = r'''
01-aws-key
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
=>
AWS_ACCESS_KEY_ID=[AWS_KEY]
###
02-github-pat
token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
=>
token [GITHUB_PAT]
###
03-openai-project-key
OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz123456
=>
OPENAI_API_KEY=[OPENAI_KEY]
###
04-anthropic-key
sk-ant-api03-Zz9Yy8Xx7Ww6Vv5Uu4Tt3Ss2Rr1Qq0Pp
=>
[OPENAI_KEY]
###
05-slack-token
xoxb-123456789012-abcdefghijkl
=>
[SLACK_TOKEN]
###
06-jwt
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
=>
[JWT]
###
07-private-key
-----BEGIN RSA PRIVATE KEY-----
=>
[PRIVATE_KEY]
###
08-bearer
Authorization: Bearer abcdef0123456789abcdef
=>
Authorization: [BEARER]
###
09-email
contact ryan@example.com now
=>
contact [EMAIL] now
###
10-email-plus-subdomain
a.b+c@sub.example.co.uk
=>
[EMAIL]
###
11-ssn
SSN 123-45-6789
=>
SSN [SSN]
###
12-card-luhn-valid
card 4111 1111 1111 1111
=>
card [CARD]
###
13-card-luhn-invalid
card 4111-1111-1111-1112
=>
card 4111-1111-1111-1112
###
14-phone-parens
call (415) 555-2671
=>
call [PHONE]
###
15-routing-aba-valid
routing 021000021
=>
routing [ROUTING]
###
16-routing-bad-checksum
routing 123456789
=>
routing 123456789
###
17-ipv4
server 192.168.1.10 up
=>
server [IPV4] up
###
18-ipv4-invalid-octet
server 999.1.1.1 up
=>
server 999.1.1.1 up
###
19-absolute-path
/Users/ryan/local-dev/cheapshot/cheapshot.swift
=>
/Users/ryan/local-dev/cheapshot/cheapshot.swift
###
20-git-sha
commit 9ed9755a1b2c3d4e5f60718293a4b5c6d7e8f901
=>
commit 9ed9755a1b2c3d4e5f60718293a4b5c6d7e8f901
###
21-url
https://github.com/all-caps-dev/cheapshot/releases/download/v0.5.0/cheapshot.zip
=>
https://github.com/all-caps-dev/cheapshot/releases/download/v0.5.0/cheapshot.zip
###
22-epoch-survives
1694563200
=>
1694563200
###
23-bank-acct-cue
acct 12345678
=>
acct [BANK_ACCT]
###
24-bank-account-cue
account: 123456789012
=>
account: [BANK_ACCT]
###
25-micr-routing-then-account
021000021 123456789012
=>
[ROUTING] [BANK_ACCT]
###
26-cleanshot-filename
CleanShot 2026-09-12 at 10.22.33@2x.png
=>
CleanShot 2026-09-12 at 10.22.33@2x.png
###
27-build-number-survives
version 0.4.1 built 20260912
=>
version 0.4.1 built 20260912
###
28-elapsed-ns-survives
elapsed 123456789 ns
=>
elapsed 123456789 ns
###
29-token-catchall-and-hashes
dGhpcyBpcyBhIHNlY3JldCB0b2tlbiBub2JvZHkgc2hvdWxkIHNlZQ==
uuid 8f14e45f-ceea-467a-9575-62c8e4f7a1b2
sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
=>
[TOKEN]
uuid 8f14e45f-ceea-467a-9575-62c8e4f7a1b2
sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
###
30-multi-line-mixed
user ryan@example.com
key AKIAIOSFODNN7EXAMPLE
path /opt/homebrew/bin/ffmpeg
ts 2026-09-12T15:37:00Z
=>
user [EMAIL]
key [AWS_KEY]
path /opt/homebrew/bin/ffmpeg
ts 2026-09-12T15:37:00Z
'''
for block in cases.strip().split('###'):
    lines = block.strip('\n').split('\n')
    name = lines[0].strip()
    i = lines.index('=>')
    inp = '\n'.join(lines[1:i]) + '\n'
    exp = '\n'.join(lines[i+1:]) + '\n'
    open(f'Tests/CheapshotCoreTests/Golden/cases/{name}.txt', 'w').write(inp)
    open(f'Tests/CheapshotCoreTests/Golden/expected/{name}.txt', 'w').write(exp)
print(len(os.listdir('Tests/CheapshotCoreTests/Golden/cases')), 'cases')
PY
```
Expected: `30 cases`.

- [ ] **Step 4: Run and watch exactly five cases fail**

Run: `swift test --filter GoldenTests 2>&1 | grep -E "golden case|Executed"`
Expected failures: 16, 22, 26, 27, 28 (old BANK_ACCT and EMAIL over-match) and no others. Case 25 passes both before and after. If a different set fails, stop and compare against the "verified on this Mac" note above before touching anything.

- [ ] **Step 5: Change the two patterns**

In `Sources/CheapshotCore/Redaction/Rule.swift` replace the EMAIL line with:
```swift
        // Local part must contain a letter and the domain must not be a @2x/@3x scale suffix,
        // so "CleanShot 2026-09-12 at 10.22.33@2x.png" is not an address.
        Rule(name: "EMAIL",       pattern: #"\b[A-Za-z0-9._%+\-]*[A-Za-z][A-Za-z0-9._%+\-]*@(?!\d+x\.)[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
```
and the BANK_ACCT line with:
```swift
        // Bare digit runs are build numbers, epochs, and elapsed nanoseconds far more often than
        // account numbers. Require a context cue within 20 characters: an "acct"/"account"/"a/c"/
        // "iban"/"micr" word, or a ROUTING hit already redacted on the same line (MICR strip).
        // ICU allows lookbehind with a bounded maximum length, which {0,20} is.
        Rule(name: "BANK_ACCT",   pattern: #"(?<=(?:\b(?:acct|account|a/c|iban|micr)\b|\[ROUTING\])[^\n\d]{0,20})\d{8,17}(?![\w\-/])"#),
```
Note BANK_ACCT now uses the default `[.caseInsensitive]` options.

- [ ] **Step 6: Run the whole suite**

Run: `swift test 2>&1 | grep -E "error|failed|Executed"`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 7: Update the README table**

Replace the `EMAIL` row with `| \`EMAIL\` | addresses; a scale suffix like \`@2x.png\` is not one |` and the `BANK_ACCT` row with `| \`BANK_ACCT\` | 8 to 17 digits after an account cue (\`acct\`, \`account\`, \`a/c\`, \`iban\`, \`micr\`) or a redacted routing number; bare digit runs survive |`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/CheapshotCore/Redaction/Rule.swift Tests/CheapshotCoreTests README.md
git commit -m "redaction: BANK_ACCT needs a context cue, @2x.png is not an email, 30-case golden suite

Epochs, build numbers, and elapsed nanoseconds survive. Account numbers still
redact after acct/account/a/c/iban/micr or a redacted ROUTING on the same line."
```

---

### Task 5: `--rules` file loader

**Files:**
- Create: `Sources/CheapshotCore/Redaction/RuleFile.swift`
- Create: `Tests/CheapshotCoreTests/RuleFileTests.swift`

**Interfaces:**
- Produces: `RuleFile.load(_ url: URL) throws -> [Rule]` and `RuleFile.parse(_ data: Data) throws -> [Rule]`, `RuleFile.LoadError`. Task 7's runner wires `--rules`.
- File format, a JSON array: `[{"name": "TICKET", "pattern": "\\bINT-\\d{6}\\b", "caseInsensitive": true}]`. `caseInsensitive` defaults to true. Names are upper-cased for the `[NAME]` marker.

- [ ] **Step 1: Write the failing tests**

`Tests/CheapshotCoreTests/RuleFileTests.swift`:
```swift
import XCTest
@testable import CheapshotCore

final class RuleFileTests: XCTestCase {
    func testParsesRulesAndDefaults() throws {
        let json = #"[{"name":"ticket","pattern":"\\bINT-\\d{6}\\b"},{"name":"HOST","pattern":"corp\\.internal","caseInsensitive":false}]"#
        let rules = try RuleFile.parse(Data(json.utf8))
        XCTAssertEqual(rules.map(\.name), ["TICKET", "HOST"])
        XCTAssertEqual(rules[0].options, [.caseInsensitive])
        XCTAssertEqual(rules[1].options, [])
        XCTAssertEqual(Redactor(customRules: rules).redact("INT-123456 at corp.internal").text, "[TICKET] at [HOST]")
    }

    func testRejectsBadRegex() {
        let json = #"[{"name":"BAD","pattern":"("}]"#
        XCTAssertThrowsError(try RuleFile.parse(Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("BAD"), "error should name the rule: \(error)")
        }
    }

    func testRejectsNotAnArray() {
        XCTAssertThrowsError(try RuleFile.parse(Data(#"{"name":"X"}"#.utf8)))
    }

    func testLoadMissingFileThrows() {
        XCTAssertThrowsError(try RuleFile.load(URL(fileURLWithPath: "/nonexistent/rules.json")))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter RuleFileTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'RuleFile' in scope`.

- [ ] **Step 3: Write RuleFile.swift**

```swift
import Foundation

/// Reads a JSON array of {name, pattern, caseInsensitive} into rules. The CLI's --rules and
/// the app's rules editor share this format.
public enum RuleFile {
    public struct LoadError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    private struct Entry: Decodable {
        var name: String
        var pattern: String
        var caseInsensitive: Bool?
    }

    public static func load(_ url: URL) throws -> [Rule] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw LoadError(message: "cannot read rules file \(url.path): \(error.localizedDescription)") }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> [Rule] {
        let entries: [Entry]
        do { entries = try JSONDecoder().decode([Entry].self, from: data) }
        catch { throw LoadError(message: "rules file must be a JSON array of {name, pattern, caseInsensitive}: \(error.localizedDescription)") }
        return try entries.map { e in
            let opts: NSRegularExpression.Options = (e.caseInsensitive ?? true) ? [.caseInsensitive] : []
            do { _ = try NSRegularExpression(pattern: e.pattern, options: opts) }
            catch { throw LoadError(message: "rule \(e.name.uppercased()): invalid pattern \(e.pattern)") }
            return Rule(name: e.name.uppercased(), pattern: e.pattern, options: opts)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | grep -E "error|Executed"`
Expected: `Executed 14 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CheapshotCore/Redaction/RuleFile.swift Tests/CheapshotCoreTests/RuleFileTests.swift
git commit -m "core: RuleFile loads custom redaction rules from JSON"
```

---

### Task 6: Strict argument parser

**Files:**
- Create: `Sources/CheapshotCLI/Options.swift`
- Create: `Tests/CheapshotCLITests/OptionsTests.swift`
- Modify: `Package.swift` (add `CheapshotCLI` library target and `CheapshotCLITests`)

**Interfaces:**
- Produces: `Options`, `Options.Command`, `Options.parse(_:)`, `Options.parsePages(_:)`, `UsageError` exactly as in the API reference. Task 7 consumes them. Nothing in `Sources/cheapshot/main.swift` changes yet.

Behaviour fixed here (audit finding 4): `--min-conf shot.png` is an error instead of swallowing the filename; `--newest 3` means count 3 in the current directory; any leftover `--flag` is "unknown option", exit 2.

- [ ] **Step 1: Add the targets**

`Package.swift` targets become:
```swift
    targets: [
        .target(
            name: "CheapshotCore",
            linkerSettings: [.linkedFramework("Vision"), .linkedFramework("AppKit")]
        ),
        .target(name: "CheapshotCLI", dependencies: ["CheapshotCore"]),
        .executableTarget(name: "cheapshot", dependencies: ["CheapshotCore", "CheapshotCLI"]),
        .testTarget(name: "CheapshotCoreTests", dependencies: ["CheapshotCore"], resources: [.copy("Golden")]),
        .testTarget(name: "CheapshotCLITests", dependencies: ["CheapshotCLI", "CheapshotCore"]),
    ]
```

- [ ] **Step 2: Write the failing tests**

`Tests/CheapshotCLITests/OptionsTests.swift`:
```swift
import XCTest
@testable import CheapshotCLI

final class OptionsTests: XCTestCase {
    func testEmptyAndHelpAndVersion() throws {
        XCTAssertEqual(try Options.parse([]).command, .help)
        XCTAssertEqual(try Options.parse(["a.png", "-h"]).command, .help)
        XCTAssertEqual(try Options.parse(["--help"]).command, .help)
        XCTAssertEqual(try Options.parse(["--version"]).command, .version)
    }

    func testFilesAndFlags() throws {
        let o = try Options.parse(["--raw", "--json", "--stats", "--no-ledger", "a.png", "b.jpg"])
        XCTAssertEqual(o.command, .files(["a.png", "b.jpg"]))
        XCTAssertFalse(o.redact); XCTAssertTrue(o.json); XCTAssertTrue(o.stats); XCTAssertTrue(o.noLedger)
    }

    func testUnknownOptionIsUsageError() {
        XCTAssertThrowsError(try Options.parse(["--bogus"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "unknown option --bogus"))
        }
        XCTAssertThrowsError(try Options.parse(["a.png", "--jsn"]))
    }

    func testNoInputsIsUsageError() {
        XCTAssertThrowsError(try Options.parse(["--json"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "no input files"))
        }
    }

    func testMinConfNeedsAValue() throws {
        XCTAssertEqual(try Options.parse(["--min-conf", "0.5", "a.png"]).minConfidence, 0.5)
        XCTAssertThrowsError(try Options.parse(["--min-conf", "shot.png"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "--min-conf: not a number: shot.png"))
        }
        XCTAssertThrowsError(try Options.parse(["--min-conf"])) { e in
            XCTAssertEqual(e as? UsageError, UsageError(message: "--min-conf needs a value"))
        }
        XCTAssertThrowsError(try Options.parse(["--min-conf", "--json", "a.png"]))
    }

    func testNewestForms() throws {
        XCTAssertEqual(try Options.parse(["--newest"]).command, .newest(dir: ".", count: 1))
        XCTAssertEqual(try Options.parse(["--newest", "3"]).command, .newest(dir: ".", count: 3))
        XCTAssertEqual(try Options.parse(["--newest", "/tmp/shots"]).command, .newest(dir: "/tmp/shots", count: 1))
        XCTAssertEqual(try Options.parse(["--newest", "/tmp/shots", "2", "--json"]).command, .newest(dir: "/tmp/shots", count: 2))
    }

    func testCleanshotForms() throws {
        XCTAssertEqual(try Options.parse(["--cleanshot"]).command, .cleanshot(count: 1))
        XCTAssertEqual(try Options.parse(["--cleanshot", "3"]).command, .cleanshot(count: 3))
    }

    func testVideoOptions() throws {
        let o = try Options.parse(["--video", "v.mp4", "--scene", "0.3", "--max-frames", "10", "--dedupe", "0.8"])
        XCTAssertEqual(o.command, .video(path: "v.mp4"))
        XCTAssertEqual(o.scene, 0.3); XCTAssertEqual(o.maxFrames, 10); XCTAssertEqual(o.dedupe, 0.8)
        XCTAssertThrowsError(try Options.parse(["--video"]))
        XCTAssertThrowsError(try Options.parse(["--video", "v.mp4", "--max-frames", "ten"]))
    }

    func testTextMode() throws {
        XCTAssertEqual(try Options.parse(["--text", "-"]).command, .text(path: "-"))
        XCTAssertEqual(try Options.parse(["--text", "notes.txt", "--json"]).command, .text(path: "notes.txt"))
        XCTAssertThrowsError(try Options.parse(["--text"]))
        XCTAssertThrowsError(try Options.parse(["--text", "--json"]))
    }

    func testLedgerForms() throws {
        XCTAssertEqual(try Options.parse(["--ledger"]).command, .ledger(json: false, migrate: false))
        XCTAssertEqual(try Options.parse(["--ledger", "--json"]).command, .ledger(json: true, migrate: false))
        XCTAssertEqual(try Options.parse(["--ledger", "--migrate"]).command, .ledger(json: false, migrate: true))
        XCTAssertThrowsError(try Options.parse(["--migrate"]))
    }

    func testRulesAndPages() throws {
        let o = try Options.parse(["--rules", "r.json", "--pages", "1-2", "doc.pdf"])
        XCTAssertEqual(o.rulesPath, "r.json")
        XCTAssertEqual(o.pages, 1...2)
        XCTAssertEqual(try Options.parsePages("3"), 3...3)
        XCTAssertThrowsError(try Options.parsePages("2-1"))
        XCTAssertThrowsError(try Options.parsePages("0-1"))
        XCTAssertThrowsError(try Options.parsePages("x"))
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter OptionsTests 2>&1 | grep -E "error:" | head -3`
Expected: `no such module 'CheapshotCLI'` or `cannot find 'Options'`.

- [ ] **Step 4: Write Options.swift**

`Sources/CheapshotCLI/Options.swift`:
```swift
import Foundation

public struct UsageError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

public struct Options: Equatable {
    public enum Command: Equatable {
        case help, version
        case ledger(json: Bool, migrate: Bool)
        case text(path: String)          // "-" means stdin
        case video(path: String)
        case files([String])
        case newest(dir: String, count: Int)
        case cleanshot(count: Int)
    }

    public var command: Command
    public var redact = true, json = false, stats = false, noLedger = false
    public var minConfidence: Float = 0.3
    public var scene = 0.25, maxFrames = 200, dedupe = 0.90
    public var rulesPath: String? = nil
    public var pages: ClosedRange<Int>? = nil

    public init(command: Command) { self.command = command }

    public static func parsePages(_ s: String) throws -> ClosedRange<Int> {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts.last!),
              lo >= 1, hi >= lo else {
            throw UsageError(message: "--pages: expected N or N-M with N >= 1, got \(s)")
        }
        return lo...hi
    }

    public static func parse(_ args: [String]) throws -> Options {
        if args.isEmpty || args.contains("-h") || args.contains("--help") { return Options(command: .help) }
        if args.contains("--version") { return Options(command: .version) }

        var o = Options(command: .files([]))
        var positional: [String] = []
        var newest: (dir: String, count: Int)? = nil
        var cleanshot: Int? = nil
        var text: String? = nil
        var video: String? = nil
        var ledger = false, migrate = false
        var i = 0

        func value(_ flag: String) throws -> String {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw UsageError(message: "\(flag) needs a value") }
            i += 1
            return args[i]
        }
        func number<T: LosslessStringConvertible>(_ flag: String, _ type: T.Type) throws -> T {
            let v = try value(flag)
            guard let n = T(v) else { throw UsageError(message: "\(flag): not a number: \(v)") }
            return n
        }
        func nextIsInt() -> Int? {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
            return Int(args[i + 1])
        }

        while i < args.count {
            let a = args[i]
            switch a {
            case "--raw":       o.redact = false
            case "--json":      o.json = true
            case "--stats":     o.stats = true
            case "--no-ledger": o.noLedger = true
            case "--ledger":    ledger = true
            case "--migrate":   migrate = true
            case "--min-conf":  o.minConfidence = try number(a, Float.self)
            case "--scene":     o.scene = try number(a, Double.self)
            case "--max-frames": o.maxFrames = try number(a, Int.self)
            case "--dedupe":    o.dedupe = try number(a, Double.self)
            case "--rules":     o.rulesPath = try value(a)
            case "--pages":     o.pages = try parsePages(try value(a))
            case "--text":      text = try value(a)
            case "--video":     video = try value(a)
            case "--newest":
                var dir = ".", n = 1
                if let k = nextIsInt() {
                    n = k; i += 1
                } else if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    dir = args[i + 1]; i += 1
                    if let k = nextIsInt() { n = k; i += 1 }
                }
                newest = (dir, n)
            case "--cleanshot":
                var n = 1
                if let k = nextIsInt() { n = k; i += 1 }
                cleanshot = n
            default:
                if a.hasPrefix("--") { throw UsageError(message: "unknown option \(a)") }
                positional.append(a)
            }
            i += 1
        }

        if ledger { o.command = .ledger(json: o.json, migrate: migrate); return o }
        if migrate { throw UsageError(message: "--migrate needs --ledger") }
        if let t = text { o.command = .text(path: t); return o }
        if let v = video { o.command = .video(path: v); return o }
        if let n = newest { o.command = .newest(dir: n.dir, count: n.count); return o }
        if let n = cleanshot { o.command = .cleanshot(count: n); return o }
        guard !positional.isEmpty else { throw UsageError(message: "no input files") }
        o.command = .files(positional)
        return o
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test 2>&1 | grep -E "error|failed|Executed"`
Expected: two `Executed` lines (one per test bundle), both with 0 failures; OptionsTests has 11 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/CheapshotCLI/Options.swift Tests/CheapshotCLITests/OptionsTests.swift
git commit -m "cli: strict option parser; unknown flags and missing values are usage errors"
```

---

### Task 7: CLI runner with `--text`, `--rules`, JSON error entries, and exit codes

**Files:**
- Create: `Sources/CheapshotCLI/CLIIO.swift`
- Create: `Sources/CheapshotCLI/Output.swift`
- Create: `Sources/CheapshotCLI/Runner.swift`
- Create: `Sources/cheapshot/Cheapshot.swift`
- Delete: `Sources/cheapshot/main.swift`
- Create: `Tests/CheapshotCLITests/RunnerTests.swift`

**Interfaces:**
- Consumes: `Options` (Task 6); `Redactor`, `RuleFile`, `cheapshotVersion` (Tasks 3 to 5); the Phase 0 functions still in `Core.swift`: `ocr(path:minConfidence:)`, `imageTokens(path:)`, `textTokens(_:)`, `ledgerAppend(...)`, `ledgerTotal()`, `sceneFrames(...)`, `similarity`, `stamp`. Tasks 8, 10, 11 replace those calls.
- Produces: `CLIIO`, `CLI.run(arguments:io:) async -> Int32`, `Output.usage()`, `Output.json(_:)`. The executable is `@main` and calls `CLI.run`.

Behaviour fixed here (audit findings 3 and 8): a missing or unreadable input adds `{"file","error"}` to `results` and the exit code is 1 if any input failed; `--text -` reads stdin, `--text path` reads a file, both skip Vision and the ledger.

- [ ] **Step 1: Write the failing tests**

`Tests/CheapshotCLITests/RunnerTests.swift`:
```swift
import XCTest
@testable import CheapshotCLI

/// Captures everything the runner writes so tests never touch the real stdout or the real home.
struct Capture {
    var out = "", err = ""
    var stdin = ""
    var environment: [String: String] = [:]
    var home: String

    init(home: String) { self.home = home }
}

final class RunnerTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cheapshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func run(_ args: [String], stdin: String = "", env: [String: String] = [:]) async -> (code: Int32, out: String, err: String) {
        final class Box { var out = "", err = "" }
        let box = Box()
        var env = env
        env["CHEAPSHOT_HOME"] = env["CHEAPSHOT_HOME"] ?? tmp.path   // never write the real ledger
        let io = CLIIO(out: { box.out += $0 }, err: { box.err += $0 }, readStdin: { stdin },
                       environment: env, home: tmp.path)
        let code = await CLI.run(arguments: args, io: io)
        return (code, box.out, box.err)
    }

    func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    func testMissingFileIsAnErrorEntryAndExit1() async throws {
        let r = await run(["--json", "missing.png"])
        XCTAssertEqual(r.code, 1)
        let payload = try json(r.out)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["file"] as? String, "missing.png")
        XCTAssertNotNil(results[0]["error"] as? String)
        XCTAssertEqual(payload["version"] as? String, cheapshotVersionForTests)
    }

    func testMissingFileWithoutJSONStillExit1() async {
        let r = await run(["missing.png"])
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("missing.png"))
    }

    func testUnknownFlagExit2() async {
        let r = await run(["--bogus"])
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("unknown option --bogus"))
    }

    func testMinConfWithoutValueExit2() async {
        let r = await run(["--min-conf", "shot.png"])
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("--min-conf"))
    }

    func testTextStdinRedactsWithContextCueOnly() async {
        let r = await run(["--text", "-"], stdin: "acct 12345678\n1694563200\nCleanShot 2026 @2x.png\n")
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.out, "acct [BANK_ACCT]\n1694563200\nCleanShot 2026 @2x.png\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ledger.jsonl").path), "--text must not write the ledger")
    }

    func testTextFileAndJSON() async throws {
        let f = tmp.appendingPathComponent("in.txt")
        try "key AKIAIOSFODNN7EXAMPLE".write(to: f, atomically: true, encoding: .utf8)
        let r = await run(["--text", f.path, "--json"])
        XCTAssertEqual(r.code, 0)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        XCTAssertEqual(results[0]["text"] as? String, "key [AWS_KEY]")
        XCTAssertEqual((results[0]["redactions"] as? [String: Int])?["AWS_KEY"], 1)
        XCTAssertEqual(results[0]["image_tokens"] as? Int, 0)
    }

    func testTextRawSkipsRedaction() async {
        let r = await run(["--text", "-", "--raw"], stdin: "ryan@example.com")
        XCTAssertEqual(r.out, "ryan@example.com\n")
    }

    func testRulesFileApplies() async throws {
        let rules = tmp.appendingPathComponent("rules.json")
        try #"[{"name":"ticket","pattern":"\\bINT-\\d{6}\\b"}]"#.write(to: rules, atomically: true, encoding: .utf8)
        let r = await run(["--rules", rules.path, "--text", "-"], stdin: "INT-123456 ryan@example.com")
        XCTAssertEqual(r.out, "[TICKET] [EMAIL]\n")
    }

    func testBadRulesFileExit2() async {
        let r = await run(["--rules", "/nonexistent.json", "--text", "-"], stdin: "x")
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("rules"))
    }

    func testHelpAndVersion() async {
        let h = await run([])
        XCTAssertEqual(h.code, 0)
        XCTAssertTrue(h.out.contains("USAGE"))
        let v = await run(["--version"])
        XCTAssertEqual(v.out, cheapshotVersionForTests + "\n")
    }
}

import CheapshotCore
let cheapshotVersionForTests = cheapshotVersion
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter RunnerTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'CLIIO'` / `cannot find 'CLI'`.

- [ ] **Step 3: Write CLIIO.swift and Output.swift**

`Sources/CheapshotCLI/CLIIO.swift`:
```swift
import Foundation

/// Everything the runner touches outside its arguments, so tests can capture output and
/// redirect the home directory and the environment.
public struct CLIIO {
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var readStdin: () -> String
    public var environment: [String: String]
    public var home: String

    public init(out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                readStdin: @escaping () -> String, environment: [String: String], home: String) {
        self.out = out; self.err = err; self.readStdin = readStdin; self.environment = environment; self.home = home
    }

    public static var standard: CLIIO {
        CLIIO(out: { FileHandle.standardOutput.write(Data($0.utf8)) },
              err: { FileHandle.standardError.write(Data($0.utf8)) },
              readStdin: { String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" },
              environment: ProcessInfo.processInfo.environment,
              home: NSHomeDirectory())
    }
}
```

`Sources/CheapshotCLI/Output.swift`:
```swift
import Foundation
import CheapshotCore

public enum Output {
    public static func usage() -> String {
        """
        cheapshot \(cheapshotVersion) - on-device screenshot OCR for AI agents

        USAGE
          cheapshot <file.png|file.pdf> [more ...]
          cheapshot --newest [dir] [n]
          cheapshot --cleanshot [n]
          cheapshot --video <file.mp4>
          cheapshot --text <file|->        redact text instead of an image (- is stdin)
          cheapshot --ledger [--json] [--migrate]

        OPTIONS
          --raw             do not redact (redaction is ON by default)
          --json            emit JSON
          --stats           print token savings to stderr
          --min-conf <f>    confidence floor, default 0.3
          --rules <file>    extra redaction rules, JSON [{name, pattern, caseInsensitive}]
          --pages <N|N-M>   PDF page range, default all
          --scene <f>       video scene-change threshold, default 0.25
          --max-frames <n>  video frame cap, default 200
          --dedupe <f>      drop a screen this similar to the last, default 0.90
          --ledger          print cumulative savings across every run
          --no-ledger       do not record this run
          --version

        EXIT CODES
          0 ok   1 an input failed   2 usage error

        """
    }

    public static func json(_ object: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s + "\n"
    }
}
```

- [ ] **Step 4: Write Runner.swift**

`Sources/CheapshotCLI/Runner.swift`:
```swift
import Foundation
import AppKit
import CheapshotCore

public enum CLI {
    public static func run(arguments: [String], io: CLIIO = .standard) async -> Int32 {
        let opts: Options
        do { opts = try Options.parse(arguments) }
        catch let e as UsageError { io.err("cheapshot: \(e.message)\ntry: cheapshot --help\n"); return 2 }
        catch { io.err("cheapshot: \(error)\n"); return 2 }

        let redactor: Redactor?
        do { redactor = try makeRedactor(opts) }
        catch { io.err("cheapshot: \(error)\n"); return 2 }

        switch opts.command {
        case .help:    io.out(Output.usage()); return 0
        case .version: io.out(cheapshotVersion + "\n"); return 0
        case .ledger:  ledgerTotal(); return 0      // Task 8 replaces this with Ledger
        case .text(let path): return runText(opts, path: path, redactor: redactor, io: io)
        case .video(let path): return runVideo(opts, path: path, redactor: redactor, io: io)
        case .files(let paths): return runImages(opts, paths: paths, redactor: redactor, io: io)
        case .newest(let dir, let n): return runImages(opts, paths: newest(in: dir, count: n), redactor: redactor, io: io)
        case .cleanshot(let n): return runImages(opts, paths: newest(in: cleanshotDir(home: io.home), count: n), redactor: redactor, io: io)
        }
    }

    // MARK: - Setup

    static func makeRedactor(_ opts: Options) throws -> Redactor? {
        guard opts.redact else { return nil }
        guard let path = opts.rulesPath else { return Redactor() }
        return Redactor(customRules: try RuleFile.load(URL(fileURLWithPath: path)))
    }

    static func apply(_ redactor: Redactor?, _ text: String) -> (text: String, report: RedactionReport) {
        redactor?.redact(text) ?? (text, RedactionReport())
    }

    static func payload(_ results: [[String: Any]], imageTokens: Int, textTokens: Int) -> [String: Any] {
        ["version": cheapshotVersion, "results": results, "image_tokens": imageTokens, "text_tokens": textTokens]
    }

    static func statsLine(inputs: Int, noun: String, imageTokens: Int, textTokens: Int) -> String {
        let saved = max(0, imageTokens - textTokens)
        let pct = imageTokens > 0 ? Int(Double(saved) / Double(imageTokens) * 100) : 0
        return "cheapshot: \(inputs) \(noun)  \(imageTokens) image tokens -> \(textTokens) text tokens  (saved \(saved), \(pct)%)\n"
    }

    // MARK: - --text

    static func runText(_ opts: Options, path: String, redactor: Redactor?, io: CLIIO) -> Int32 {
        let raw: String
        if path == "-" {
            raw = io.readStdin()
        } else {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
                if opts.json { io.out(Output.json(payload([["file": path, "error": "cannot read"]], imageTokens: 0, textTokens: 0))) }
                io.err("cheapshot: cannot read \(path)\n")
                return 1
            }
            raw = s
        }
        let input = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        let (text, report) = apply(redactor, input)
        let tt = Tokens_text(text)
        if opts.json {
            io.out(Output.json(payload([["file": path, "text": text, "redactions": report.counts,
                                         "image_tokens": 0, "text_tokens": tt]], imageTokens: 0, textTokens: tt)))
        } else {
            io.out(text + "\n")
        }
        if opts.stats { io.err("cheapshot: \(report.total) redaction(s), \(tt) text tokens\n") }
        return 0
    }

    // MARK: - images

    static func runImages(_ opts: Options, paths: [String], redactor: Redactor?, io: CLIIO) -> Int32 {
        guard !paths.isEmpty else { io.err("cheapshot: no input images\n"); return 2 }
        var results: [[String: Any]] = []
        var totalImage = 0, totalText = 0, totalRedactions = 0, failed = 0

        for f in paths {
            guard FileManager.default.fileExists(atPath: f) else {
                failed += 1
                results.append(["file": f, "error": "no such file"])
                io.err("cheapshot: no such file \(f)\n")
                continue
            }
            guard let raw = ocr(path: f, minConfidence: opts.minConfidence) else {
                failed += 1
                results.append(["file": f, "error": "cannot read image"])
                io.err("cheapshot: cannot read \(f)\n")
                continue
            }
            let (text, report) = apply(redactor, raw)
            let it = imageTokens(path: f), tt = Tokens_text(text)
            totalImage += it; totalText += tt; totalRedactions += report.total
            results.append(["file": f, "text": text, "redactions": report.counts, "image_tokens": it, "text_tokens": tt])
            if !opts.json {
                if paths.count > 1 { io.out("== \((f as NSString).lastPathComponent)\n") }
                io.out(text + "\n")
            }
        }

        if opts.json { io.out(Output.json(payload(results, imageTokens: totalImage, textTokens: totalText))) }
        let ok = paths.count - failed
        if !opts.noLedger && ok > 0 {
            ledgerAppend(mode: "image", inputs: ok, imageTokens: totalImage, textTokens: totalText, redactions: totalRedactions)   // Task 8 replaces
        }
        if opts.stats { io.err(statsLine(inputs: ok, noun: "image(s)", imageTokens: totalImage, textTokens: totalText)) }
        return failed > 0 ? 1 : 0
    }

    // MARK: - video (Task 11 replaces the body with VideoTranscriber)

    static func runVideo(_ opts: Options, path: String, redactor: Redactor?, io: CLIIO) -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else { io.err("cheapshot: no such video \(path)\n"); return 2 }
        guard let (tmp, frames) = sceneFrames(video: path, threshold: opts.scene, maxFrames: opts.maxFrames), !frames.isEmpty else {
            io.err("cheapshot: no frames extracted\n"); return 1
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }   // runs now: this is a function, not exit(0)

        var kept: [(Double, String)] = []
        var lastText = ""
        var frameImageTokens = 0, redactions = 0
        for (t, f) in frames {
            frameImageTokens += imageTokens(path: f)
            guard let raw = ocr(path: f, minConfidence: opts.minConfidence) else { continue }
            let (text, report) = apply(redactor, raw)
            redactions += report.total
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if similarity(trimmed, lastText) >= opts.dedupe { continue }
            kept.append((t, trimmed)); lastText = trimmed
        }
        var body = ""
        for (t, text) in kept { body += "[\(stamp(t))]\n\(text)\n\n" }
        io.out(body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        let tt = Tokens_text(body)
        if !opts.noLedger { ledgerAppend(mode: "video", inputs: frames.count, imageTokens: frameImageTokens, textTokens: tt, redactions: redactions) }
        if opts.stats {
            io.err("cheapshot: \(frames.count) scene frames, \(kept.count) distinct screens  "
                   + statsLine(inputs: frames.count, noun: "frame(s)", imageTokens: frameImageTokens, textTokens: tt).dropFirst("cheapshot: ".count).description)
        }
        return 0
    }

    // MARK: - input discovery

    static func newest(in dir: String, count: Int) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let exts = ["png", "jpg", "jpeg", "webp", "gif", "pdf"]
        let candidates = items.filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
        let withDates: [(String, Date)] = candidates.compactMap {
            let p = (dir as NSString).appendingPathComponent($0)
            let d = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? nil
            return d.map { (p, $0) }
        }
        return withDates.sorted { $0.1 > $1.1 }.prefix(count).map { $0.0 }
    }

    /// CleanShot's export folder, else ~/Desktop (macOS's own screenshot default).
    static func cleanshotDir(home: String) -> String {
        UserDefaults(suiteName: "pl.maketheweb.cleanshotx")?.string(forKey: "exportPath") ?? (home + "/Desktop")
    }
}

// Until Task 10 moves the estimators into Tokens, alias the Phase 0 function under a name
// that will not collide with the local variables named textTokens.
func Tokens_text(_ s: String) -> Int { textTokens(s) }
```

`Sources/cheapshot/Cheapshot.swift`:
```swift
import Foundation
import CheapshotCLI

@main
struct Main {
    static func main() async {
        let code = await CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }
}
```

Delete `Sources/cheapshot/main.swift` (`git rm Sources/cheapshot/main.swift`). An `@main` type and a `main.swift` cannot coexist.

- [ ] **Step 5: Run tests and the acceptance commands**

Run: `swift test 2>&1 | grep -E "error|failed|Executed"`
Expected: 0 failures in both bundles.

Run:
```bash
swift build 2>&1 | tail -1
B=.build/debug/cheapshot
$B --json missing.png; echo "exit=$?"
$B --bogus; echo "exit=$?"
$B --min-conf shot.png; echo "exit=$?"
echo "acct 12345678" | $B --text -
echo "1694563200" | $B --text -
echo "CleanShot 2026 @2x.png" | $B --text -
```
Expected: JSON with `"error"` and `"file": "missing.png"`, `exit=1`; `unknown option --bogus`, `exit=2`; `--min-conf: not a number: shot.png`, `exit=2`; `acct [BANK_ACCT]`; `1694563200`; `CleanShot 2026 @2x.png`.

- [ ] **Step 6: Commit**

```bash
git add -A Sources Tests
git commit -m "cli: runner library with --text, --rules, JSON error entries, exit 1 on partial failure

The executable is now an @main shim over CheapshotCLI so the runner is unit-tested
with captured IO. Video temp dir is deleted by a real defer; CleanShot fallback is ~/Desktop."
```

---

### Task 8: JSONL ledger with the location rule, O_APPEND, `--ledger --json`, `--ledger --migrate`

**Files:**
- Create: `Sources/CheapshotCore/Ledger/Ledger.swift`
- Create: `Sources/CheapshotCore/Ledger/LedgerMigration.swift`
- Modify: `Sources/CheapshotCore/Core.swift` (delete `ledgerAppend`, `ledgerTotal`)
- Modify: `Sources/CheapshotCLI/Runner.swift` (ledger call sites)
- Create: `Tests/CheapshotCoreTests/LedgerTests.swift`
- Create: `Tests/CheapshotCoreTests/LedgerMigrationTests.swift`
- Modify: `Tests/CheapshotCLITests/RunnerTests.swift` (add two tests)
- Modify: `README.md` "Ledger" section

**Interfaces:**
- Produces: `Ledger`, `LedgerEntry`, `LedgerSummary` as in the API reference. Ledger line format, one JSON object per line with sorted keys: `{"image_tokens":1550,"inputs":1,"mode":"image","redactions":10,"saved":1496,"text_tokens":54,"ts":"2026-09-08T01:05:35Z"}`.
- The runner resolves the path once per run with `Ledger.resolveURL(environment: io.environment, home: io.home)`. `fileManager` stays a parameter for future rules; today it is unused.

Behaviour fixed here (audit finding 6): append is one `write(2)` on an `O_APPEND` descriptor, so concurrent runs never interleave; the file moves out of `~/.claude/`.

- [ ] **Step 1: Write the failing tests**

`Tests/CheapshotCoreTests/LedgerTests.swift`:
```swift
import XCTest
@testable import CheapshotCore

final class LedgerTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ledger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testResolveURLPrefersCheapshotHome() {
        let u = Ledger.resolveURL(environment: ["CHEAPSHOT_HOME": "/x/y"], home: tmp.path)
        XCTAssertEqual(u.path, "/x/y/ledger.jsonl")
    }

    func testResolveURLFallsBackToApplicationSupport() {
        let u = Ledger.resolveURL(environment: [:], home: tmp.path)
        XCTAssertEqual(u.path, tmp.path + "/Library/Application Support/cheapshot/ledger.jsonl")
    }

    func testAppendWritesOneSortedJSONLine() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("sub/ledger.jsonl"))
        try ledger.append(LedgerEntry(ts: "2026-09-08T01:05:35Z", mode: "image", inputs: 1, imageTokens: 1550, textTokens: 54, redactions: 10))
        let body = try String(contentsOf: ledger.url, encoding: .utf8)
        XCTAssertEqual(body, #"{"image_tokens":1550,"inputs":1,"mode":"image","redactions":10,"saved":1496,"text_tokens":54,"ts":"2026-09-08T01:05:35Z"}"# + "\n")
        XCTAssertEqual(try ledger.entries().count, 1)
        XCTAssertEqual(try ledger.entries()[0].saved, 1496)
    }

    func testSavedNeverNegative() {
        let e = LedgerEntry(mode: "image", inputs: 1, imageTokens: 10, textTokens: 50, redactions: 0)
        XCTAssertEqual(e.saved, 0)
    }

    func testConcurrentAppendsDoNotInterleave() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            try? ledger.append(LedgerEntry(mode: "image", inputs: i, imageTokens: 1000 + i, textTokens: 10, redactions: 0))
        }
        let lines = try String(contentsOf: ledger.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 64)
        XCTAssertEqual(try ledger.entries().count, 64, "every line must decode")
    }

    func testSummaryTotalsAndDayFilter() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        try ledger.append(LedgerEntry(ts: "2020-01-01T00:00:00Z", mode: "image", inputs: 1, imageTokens: 1000, textTokens: 100, redactions: 2))
        try ledger.append(LedgerEntry(mode: "video", inputs: 12, imageTokens: 2000, textTokens: 500, redactions: 1))
        let all = try ledger.summary()
        XCTAssertEqual(all.runs, 2); XCTAssertEqual(all.days, 2); XCTAssertEqual(all.inputs, 13)
        XCTAssertEqual(all.imageTokens, 3000); XCTAssertEqual(all.textTokens, 600); XCTAssertEqual(all.saved, 2400)
        XCTAssertEqual(all.redactions, 3); XCTAssertEqual(all.percent, 80)
        let week = try ledger.summary(days: 7)
        XCTAssertEqual(week.runs, 1); XCTAssertEqual(week.imageTokens, 2000)
    }

    func testSummaryOfMissingFileIsZero() throws {
        let s = try Ledger(at: tmp.appendingPathComponent("nope.jsonl")).summary()
        XCTAssertEqual(s.runs, 0); XCTAssertEqual(s.percent, 0)
    }

    func testSummaryText() {
        let s = LedgerSummary(days: 1, runs: 2, inputs: 3, imageTokens: 1000, textTokens: 100, saved: 900, redactions: 4, percent: 90)
        let text = Ledger(at: tmp).summaryText(s)
        XCTAssertTrue(text.contains("cheapshot ledger  (1 day)"))
        XCTAssertTrue(text.contains("saved          900  (90%)"))
    }
}
```

`Tests/CheapshotCoreTests/LedgerMigrationTests.swift`:
```swift
import XCTest
@testable import CheapshotCore

final class LedgerMigrationTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ledger-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("tsv"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testMigratesTSVOnceAndLeavesSourceInPlace() throws {
        let tsv = tmp.appendingPathComponent("tsv")
        try "2026-09-08T01:05:35Z\timage\t1\t1550\t54\t1496\t10\n2026-09-08T02:00:00Z\tvideo\t12\t2000\t500\t1500\t0\n"
            .write(to: tsv.appendingPathComponent("20260908.tsv"), atomically: true, encoding: .utf8)
        try "2026-09-09T01:00:00Z\timage\t2\t100\t10\t90\t1\nshort\tline\n"
            .write(to: tsv.appendingPathComponent("20260909.tsv"), atomically: true, encoding: .utf8)

        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        XCTAssertEqual(try ledger.migrate(fromTSVDirectory: tsv), 3)
        let entries = try ledger.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0], LedgerEntry(ts: "2026-09-08T01:05:35Z", mode: "image", inputs: 1, imageTokens: 1550, textTokens: 54, redactions: 10))
        XCTAssertEqual(entries[1].mode, "video")
        XCTAssertEqual(try ledger.migrate(fromTSVDirectory: tsv), 0, "second migrate is a no-op")
        XCTAssertEqual(try ledger.entries().count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tsv.appendingPathComponent("20260908.tsv").path), "TSV left in place")
    }

    func testMigrateWithNoTSVDirectoryIsZero() throws {
        let ledger = Ledger(at: tmp.appendingPathComponent("ledger.jsonl"))
        XCTAssertEqual(try ledger.migrate(fromTSVDirectory: tmp.appendingPathComponent("missing")), 0)
    }

    func testDefaultTSVDirectory() {
        XCTAssertEqual(Ledger.defaultTSVDirectory(home: "/h").path, "/h/.claude/cheapshot-ledger")
    }
}
```

Add to `Tests/CheapshotCLITests/RunnerTests.swift`:
```swift
    func testLedgerJSONOnEmptyLedger() async throws {
        let r = await run(["--ledger", "--json"])
        XCTAssertEqual(r.code, 0)
        let s = try json(r.out)
        XCTAssertEqual(s["runs"] as? Int, 0)
        XCTAssertEqual(s["saved"] as? Int, 0)
    }

    func testFailedRunWritesNoLedgerLine() async {
        _ = await run(["missing.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ledger.jsonl").path))
    }

    func testLedgerMigrateReportsCount() async throws {
        let tsv = tmp.appendingPathComponent(".claude/cheapshot-ledger")
        try FileManager.default.createDirectory(at: tsv, withIntermediateDirectories: true)
        try "2026-09-08T01:05:35Z\timage\t1\t1550\t54\t1496\t10\n".write(to: tsv.appendingPathComponent("20260908.tsv"), atomically: true, encoding: .utf8)
        let r = await run(["--ledger", "--migrate"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("imported 1"), r.out)
        let again = await run(["--ledger", "--migrate"])
        XCTAssertTrue(again.out.contains("imported 0"), again.out)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "LedgerTests|LedgerMigrationTests" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'Ledger' in scope`.

- [ ] **Step 3: Write Ledger.swift**

```swift
import Foundation

public struct LedgerEntry: Codable, Equatable {
    public var ts: String
    public var mode: String
    public var inputs: Int
    public var imageTokens: Int
    public var textTokens: Int
    public var saved: Int
    public var redactions: Int

    enum CodingKeys: String, CodingKey {
        case ts, mode, inputs, saved, redactions
        case imageTokens = "image_tokens"
        case textTokens = "text_tokens"
    }

    public init(ts: String = LedgerEntry.now(), mode: String, inputs: Int, imageTokens: Int, textTokens: Int, redactions: Int) {
        self.ts = ts; self.mode = mode; self.inputs = inputs
        self.imageTokens = imageTokens; self.textTokens = textTokens
        self.saved = max(0, imageTokens - textTokens); self.redactions = redactions
    }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func now() -> String { isoFormatter.string(from: Date()) }
    var date: Date? { LedgerEntry.isoFormatter.date(from: ts) }
}

public struct LedgerSummary: Codable, Equatable {
    public var days: Int, runs: Int, inputs: Int, imageTokens: Int, textTokens: Int, saved: Int, redactions: Int, percent: Int
    enum CodingKeys: String, CodingKey {
        case days, runs, inputs, saved, redactions, percent
        case imageTokens = "image_tokens"
        case textTokens = "text_tokens"
    }
    public init(days: Int, runs: Int, inputs: Int, imageTokens: Int, textTokens: Int, saved: Int, redactions: Int, percent: Int) {
        self.days = days; self.runs = runs; self.inputs = inputs; self.imageTokens = imageTokens
        self.textTokens = textTokens; self.saved = saved; self.redactions = redactions; self.percent = percent
    }
}

public struct LedgerError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// One JSON object per line. Appends are a single write(2) on an O_APPEND descriptor so
/// concurrent runs never interleave.
public struct Ledger {
    public static let fileName = "ledger.jsonl"

    public let url: URL
    public init(at url: URL) { self.url = url }

    /// Location rule from the spec: $CHEAPSHOT_HOME, else ~/Library/Application Support/cheapshot.
    /// The CLI never writes the App Group container: outside the group, macOS 15 prompts the user.
    public static func resolveURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory(),
                                  fileManager: FileManager = .default) -> URL {
        if let h = environment["CHEAPSHOT_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h).appendingPathComponent(fileName)
        }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/cheapshot/\(fileName)")
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    public func append(_ entry: LedgerEntry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try Ledger.encoder.encode(entry)
        data.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw LedgerError(message: "cannot open \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw LedgerError(message: "short write to \(url.path)") }
    }

    public func entries() throws -> [LedgerEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let body = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return body.split(separator: "\n").compactMap { try? decoder.decode(LedgerEntry.self, from: Data($0.utf8)) }
    }

    public func summary(days: Int? = nil) throws -> LedgerSummary {
        var all = try entries()
        if let days = days {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            all = all.filter { ($0.date ?? .distantPast) >= cutoff }
        }
        let dayCount = Set(all.map { String($0.ts.prefix(10)) }).count
        let img = all.reduce(0) { $0 + $1.imageTokens }
        let txt = all.reduce(0) { $0 + $1.textTokens }
        let saved = all.reduce(0) { $0 + $1.saved }
        return LedgerSummary(days: dayCount, runs: all.count,
                             inputs: all.reduce(0) { $0 + $1.inputs },
                             imageTokens: img, textTokens: txt, saved: saved,
                             redactions: all.reduce(0) { $0 + $1.redactions },
                             percent: img > 0 ? Int(Double(saved) / Double(img) * 100) : 0)
    }

    public func summaryText(_ s: LedgerSummary) -> String {
        """
        cheapshot ledger  (\(s.days) day\(s.days == 1 ? "" : "s"))
          runs           \(s.runs)
          inputs         \(s.inputs)
          image tokens   \(s.imageTokens)
          text tokens    \(s.textTokens)
          saved          \(s.saved)  (\(s.percent)%)
          redactions     \(s.redactions)

        """
    }
}
```

- [ ] **Step 4: Write LedgerMigration.swift**

```swift
import Foundation

extension Ledger {
    /// Where v0.4.x wrote its daily TSV files.
    public static func defaultTSVDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude/cheapshot-ledger")
    }

    var migrationMarker: URL { url.deletingLastPathComponent().appendingPathComponent("migrated-tsv.json") }

    /// Imports every `*.tsv` line (ISO time, mode, inputs, image tokens, text tokens, saved,
    /// redactions) once. Leaves the TSV files in place. Returns the number of lines imported;
    /// 0 when already migrated or when the directory does not exist.
    public func migrate(fromTSVDirectory dir: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        guard !FileManager.default.fileExists(atPath: migrationMarker.path) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tsv") }.sorted()
        var count = 0
        for f in files {
            let body = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for line in body.split(separator: "\n") {
                let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard c.count >= 7, let inputs = Int(c[2]), let img = Int(c[3]), let txt = Int(c[4]), let red = Int(c[6]) else { continue }
                try append(LedgerEntry(ts: c[0], mode: c[1], inputs: inputs, imageTokens: img, textTokens: txt, redactions: red))
                count += 1
            }
        }
        let marker: [String: Any] = ["from": dir.path, "count": count, "at": LedgerEntry.now()]
        try FileManager.default.createDirectory(at: migrationMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(to: migrationMarker)
        return count
    }
}
```

- [ ] **Step 5: Wire the runner and delete the old functions**

Delete `ledgerAppend` and `ledgerTotal` (and the `// MARK: - Ledger` block) from `Sources/CheapshotCore/Core.swift`.

In `Sources/CheapshotCLI/Runner.swift`:

Replace the `.ledger` case with:
```swift
        case .ledger(let json, let migrate): return runLedger(json: json, migrate: migrate, io: io)
```

Add:
```swift
    static func ledger(_ io: CLIIO) -> Ledger {
        Ledger(at: Ledger.resolveURL(environment: io.environment, home: io.home))
    }

    static func record(_ entry: LedgerEntry, _ opts: Options, _ io: CLIIO) {
        guard !opts.noLedger else { return }
        do { try ledger(io).append(entry) } catch { io.err("cheapshot: ledger not written: \(error)\n") }
    }

    static func runLedger(json: Bool, migrate: Bool, io: CLIIO) -> Int32 {
        let l = ledger(io)
        do {
            if migrate {
                let n = try l.migrate(fromTSVDirectory: Ledger.defaultTSVDirectory(home: io.home))
                io.out("cheapshot: imported \(n) ledger line(s) into \(l.url.path)\n")
                return 0
            }
            let s = try l.summary()
            if json {
                io.out(Output.json(["days": s.days, "runs": s.runs, "inputs": s.inputs, "image_tokens": s.imageTokens,
                                    "text_tokens": s.textTokens, "saved": s.saved, "redactions": s.redactions,
                                    "percent": s.percent, "path": l.url.path]))
            } else {
                io.out(l.summaryText(s))
            }
            return 0
        } catch { io.err("cheapshot: \(error)\n"); return 1 }
    }
```

Replace the image ledger call with:
```swift
        if ok > 0 {
            record(LedgerEntry(mode: "image", inputs: ok, imageTokens: totalImage, textTokens: totalText, redactions: totalRedactions), opts, io)
        }
```
and the video one with:
```swift
        record(LedgerEntry(mode: "video", inputs: frames.count, imageTokens: frameImageTokens, textTokens: tt, redactions: redactions), opts, io)
```

- [ ] **Step 6: Run tests**

Run: `swift test 2>&1 | grep -E "error|failed|Executed"`
Expected: 0 failures in both bundles.

Run: `CHEAPSHOT_HOME=/tmp/cs-ledger-check .build/debug/cheapshot --ledger --json && ls /tmp/cs-ledger-check 2>&1`
Expected: JSON with `"runs" : 0` and `"path" : "/tmp/cs-ledger-check/ledger.jsonl"`; the directory does not exist yet (nothing was appended).

- [ ] **Step 7: Update the README Ledger section**

Replace it with:
```markdown
## Ledger

Every run appends one JSON line to `~/Library/Application Support/cheapshot/ledger.jsonl`
(or `$CHEAPSHOT_HOME/ledger.jsonl` if that variable is set):

```
{"image_tokens":1550,"inputs":1,"mode":"image","redactions":10,"saved":1496,"text_tokens":54,"ts":"2026-09-08T01:05:35Z"}
```

`--ledger` totals it, `--ledger --json` prints the totals as JSON, `--no-ledger` skips
recording a run. Upgrading from 0.4.x: `cheapshot --ledger --migrate` imports the old
`~/.claude/cheapshot-ledger/*.tsv` files once and leaves them in place.
```

- [ ] **Step 8: Commit**

```bash
git add -A Sources Tests README.md
git commit -m "ledger: JSONL in Application Support (or CHEAPSHOT_HOME), O_APPEND single write, --json and --migrate"
```

---

### Task 9: Layout arithmetic: indentation, monospace runs, fences

**Files:**
- Create: `Sources/CheapshotCore/OCR/Layout.swift`
- Create: `Tests/CheapshotCoreTests/LayoutTests.swift`

**Interfaces:**
- Produces: `OCRLine`, `RenderedLine`, `Layout.render(_:)`, `Layout.text(_:)`, `Layout.monospaceRuns(_:)`, `Layout.cellWidth(_:)`, `Layout.sorted(_:)` (internal). Pure arithmetic on boxes, no Vision. Task 10 feeds it Vision lines; Task 12 feeds it PDF lines.
- Coordinates: `bbox` is pixels (or PDF points) with a top-left origin. Smaller `minY` is higher on the page.

Decisions, from the spec's "Structured output" section:
- Cell width of a line is `bbox.width / text.count`, ignored for lines under 4 characters (too noisy to vote).
- A monospace run is 3 or more consecutive voting lines whose cell widths stay within 8% of the run's median. Short lines inside a run join it without voting.
- Fenced runs get indentation: `round((line.minX - run.minX) / medianCellWidth)` spaces, capped at 40. Lines outside a run get no indentation: on proportional-font UI (chat, sidebars, right-aligned labels) the same arithmetic produces large spurious indents, and indentation only carries meaning where the font is fixed width. This is a one-line constant to revisit.

- [ ] **Step 1: Write the failing tests**

`Tests/CheapshotCoreTests/LayoutTests.swift`:
```swift
import XCTest
@testable import CheapshotCore

final class LayoutTests: XCTestCase {
    /// A monospace line: 8 px per character, 16 px tall, top-left origin.
    func mono(_ text: String, x: CGFloat, y: CGFloat, cell: CGFloat = 8) -> OCRLine {
        OCRLine(text: text, bbox: CGRect(x: x, y: y, width: cell * CGFloat(text.count), height: 16), confidence: 0.95)
    }

    func testCellWidth() {
        XCTAssertEqual(Layout.cellWidth(mono("abcdefgh", x: 0, y: 0)), 8)
        XCTAssertNil(Layout.cellWidth(mono("ab", x: 0, y: 0)), "lines under 4 chars do not vote")
        XCTAssertNil(Layout.cellWidth(OCRLine(text: "abcd", bbox: .zero, confidence: 1)))
    }

    func testMonospaceBlockGetsIndentationAndFence() {
        let lines = [
            mono("def main():", x: 100, y: 0),
            mono("x = compute()", x: 132, y: 16),      // 4 cells in
            mono("return x", x: 132, y: 32),
            mono("print(main())", x: 100, y: 48),
        ]
        let r = Layout.render(lines)
        XCTAssertEqual(r.map(\.text), ["def main():", "    x = compute()", "    return x", "print(main())"])
        XCTAssertEqual(r.map(\.n), [1, 2, 3, 4])
        XCTAssertTrue(r.allSatisfy(\.fenced))
        XCTAssertEqual(Layout.text(r), "```\ndef main():\n    x = compute()\n    return x\nprint(main())\n```")
    }

    func testProportionalLinesAreNotFencedOrIndented() {
        // Widths vary far more than 8% per character.
        let lines = [
            OCRLine(text: "iiiiiiiiii", bbox: CGRect(x: 0, y: 0, width: 30, height: 16), confidence: 1),
            OCRLine(text: "WWWWWWWWWW", bbox: CGRect(x: 40, y: 16, width: 140, height: 16), confidence: 1),
            OCRLine(text: "Hello there", bbox: CGRect(x: 80, y: 32, width: 70, height: 16), confidence: 1),
        ]
        let r = Layout.render(lines)
        XCTAssertEqual(Layout.monospaceRuns(lines), [])
        XCTAssertEqual(r.map(\.text), ["iiiiiiiiii", "WWWWWWWWWW", "Hello there"])
        XCTAssertFalse(r.contains(where: \.fenced))
        XCTAssertEqual(Layout.text(r), "iiiiiiiiii\nWWWWWWWWWW\nHello there")
    }

    func testMixedProseThenCode() {
        let lines = [
            OCRLine(text: "Here is the fix:", bbox: CGRect(x: 0, y: 0, width: 90, height: 16), confidence: 1),
            OCRLine(text: "Apply it and rerun.", bbox: CGRect(x: 0, y: 16, width: 140, height: 16), confidence: 1),
            mono("$ swift test", x: 0, y: 40),
            mono("Executed 3 tests", x: 0, y: 56),
            mono("with 0 failures", x: 0, y: 72),
        ]
        let r = Layout.render(lines)
        XCTAssertEqual(Layout.monospaceRuns(Layout.sorted(lines)), [2..<5])
        XCTAssertEqual(r.map(\.fenced), [false, false, true, true, true])
        XCTAssertEqual(Layout.text(r), "Here is the fix:\nApply it and rerun.\n```\n$ swift test\nExecuted 3 tests\nwith 0 failures\n```")
    }

    func testShortLinesJoinARunWithoutVoting() {
        let lines = [
            mono("import Foundation", x: 0, y: 0),
            mono("}", x: 0, y: 16),
            mono("func a() {}", x: 0, y: 32),
            mono("func b() {}", x: 0, y: 48),
        ]
        XCTAssertEqual(Layout.monospaceRuns(lines), [0..<4])
    }

    func testTwoVotingLinesAreNotARun() {
        let lines = [mono("func a() {}", x: 0, y: 0), mono("func b() {}", x: 0, y: 16)]
        XCTAssertEqual(Layout.monospaceRuns(lines), [])
    }

    func testSortedTopToBottomThenLeftToRight() {
        let lines = [
            mono("third", x: 0, y: 40),
            mono("first-right", x: 200, y: 2),
            mono("first-left", x: 0, y: 0),
            mono("second", x: 0, y: 20),
        ]
        XCTAssertEqual(Layout.sorted(lines).map(\.text), ["first-left", "first-right", "second", "third"])
        XCTAssertEqual(Layout.render(lines).map(\.n), [1, 2, 3, 4])
    }

    func testIndentIsCapped() {
        let lines = [mono("aaaa", x: 0, y: 0), mono("bbbb", x: 8 * 100, y: 16), mono("cccc", x: 0, y: 32)]
        XCTAssertEqual(Layout.render(lines)[1].text, String(repeating: " ", count: 40) + "bbbb")
    }

    func testEmpty() {
        XCTAssertEqual(Layout.render([]), [])
        XCTAssertEqual(Layout.text([]), "")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LayoutTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'Layout'` / `cannot find type 'OCRLine'`.

- [ ] **Step 3: Write Layout.swift**

```swift
import Foundation
import CoreGraphics

/// One recognized line. `bbox` is in pixels (or PDF points) with a top-left origin.
public struct OCRLine: Equatable {
    public var text: String
    public var bbox: CGRect
    public var confidence: Float
    public init(text: String, bbox: CGRect, confidence: Float) { self.text = text; self.bbox = bbox; self.confidence = confidence }
}

public struct OCRResult: Equatable {
    public var lines: [OCRLine]
    public var width: Int
    public var height: Int
    public init(lines: [OCRLine], width: Int, height: Int) { self.lines = lines; self.width = width; self.height = height }
}

/// A line after layout: numbered, indented, and flagged if it sits inside a code fence.
public struct RenderedLine: Equatable {
    public var n: Int
    public var text: String
    public var bbox: CGRect
    public var confidence: Float
    public var fenced: Bool
    public init(n: Int, text: String, bbox: CGRect, confidence: Float, fenced: Bool) {
        self.n = n; self.text = text; self.bbox = bbox; self.confidence = confidence; self.fenced = fenced
    }
}

/// Pure arithmetic on bounding boxes. Vision drops leading whitespace; a fixed-width font
/// has a constant per-character width, so runs of lines with the same cell width are code,
/// and their x offset divided by the cell width is the indentation.
public enum Layout {
    public static let monospaceTolerance: CGFloat = 0.08
    public static let minimumVotingLines = 3
    public static let minimumVotingChars = 4
    public static let maxIndent = 40

    public static func cellWidth(_ line: OCRLine) -> CGFloat? {
        let n = line.text.count
        guard n >= minimumVotingChars, line.bbox.width > 0 else { return nil }
        return line.bbox.width / CGFloat(n)
    }

    /// Top to bottom, then left to right. Two lines whose tops are within half a line height
    /// of each other are on the same row.
    static func sorted(_ lines: [OCRLine]) -> [OCRLine] {
        lines.sorted { a, b in
            let tolerance = min(a.bbox.height, b.bbox.height) * 0.5
            if abs(a.bbox.minY - b.bbox.minY) > tolerance { return a.bbox.minY < b.bbox.minY }
            return a.bbox.minX < b.bbox.minX
        }
    }

    static func median(_ xs: [CGFloat]) -> CGFloat {
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Runs of consecutive lines (in the given order) whose voting lines' cell widths stay within
    /// `monospaceTolerance` of the run's median. Returns runs with at least `minimumVotingLines` voters.
    public static func monospaceRuns(_ lines: [OCRLine]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = 0
        var voters: [CGFloat] = []

        func close(at end: Int) {
            if voters.count >= minimumVotingLines { runs.append(start..<end) }
            voters = []
        }

        for (i, line) in lines.enumerated() {
            guard let cw = cellWidth(line) else { continue }          // short line: joins, does not vote
            if voters.isEmpty {
                // Drop leading short lines from the run: start at the first voter.
                start = i
                voters = [cw]
                continue
            }
            let m = median(voters)
            if abs(cw - m) / m <= monospaceTolerance {
                voters.append(cw)
            } else {
                close(at: i)
                start = i
                voters = [cw]
            }
        }
        close(at: lines.count)
        // Trim trailing short lines only if they come after the last voter? They stay: a closing "}" is code.
        return runs
    }

    public static func render(_ lines: [OCRLine]) -> [RenderedLine] {
        let s = sorted(lines)
        var out = s.enumerated().map { i, l in
            RenderedLine(n: i + 1, text: l.text, bbox: l.bbox, confidence: l.confidence, fenced: false)
        }
        for run in monospaceRuns(s) {
            let cws = run.compactMap { cellWidth(s[$0]) }
            guard !cws.isEmpty else { continue }
            let cell = median(cws)
            let minX = run.map { s[$0].bbox.minX }.min() ?? 0
            for i in run {
                let indent = min(maxIndent, max(0, Int(((s[i].bbox.minX - minX) / cell).rounded())))
                out[i].text = String(repeating: " ", count: indent) + s[i].text
                out[i].fenced = true
            }
        }
        return out
    }

    /// Joins lines, wrapping each fenced stretch in ``` fences.
    public static func text(_ lines: [RenderedLine]) -> String {
        var parts: [String] = []
        var open = false
        for l in lines {
            if l.fenced && !open { parts.append("```"); open = true }
            if !l.fenced && open { parts.append("```"); open = false }
            parts.append(l.text)
        }
        if open { parts.append("```") }
        return parts.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter LayoutTests 2>&1 | grep -E "error|failed|Executed"`
Expected: `Executed 9 tests, with 0 failures`. If `testMixedProseThenCode` fails on the run range, check that the two prose lines have cell widths 90/16=5.6 and 140/19=7.4 (24% apart) so they never join the 8 px run.

- [ ] **Step 5: Commit**

```bash
git add Sources/CheapshotCore/OCR/Layout.swift Tests/CheapshotCoreTests/LayoutTests.swift
git commit -m "core: layout arithmetic; indentation and code fences from bounding boxes"
```

---

### Task 10: OCR returns lines with boxes; line-addressable `--json`; Tokens

**Files:**
- Create: `Sources/CheapshotCore/OCR/OCR.swift`
- Create: `Sources/CheapshotCore/OCR/ImageLoader.swift`
- Create: `Sources/CheapshotCore/Tokens.swift`
- Modify: `Sources/CheapshotCore/Core.swift` (delete `ocr`, `imageTokens`, `textTokens`, and the `// MARK: - OCR` and `// MARK: - Token accounting` blocks)
- Modify: `Sources/CheapshotCLI/Runner.swift` (image loop, remove `Tokens_text` shim)
- Create: `Tests/CheapshotCoreTests/TokensTests.swift`
- Modify: `Tests/CheapshotCLITests/RunnerTests.swift` (one test on a synthetic blank PNG)

**Interfaces:**
- Consumes: `Layout` (Task 9).
- Produces: `OCR.recognize(image:minConfidence:languageCorrection:) -> OCRResult`, `OCR.recognizeLayout(image:minConfidence:) -> [RenderedLine]`, `ImageLoader.load(path:)`, `ImageLoader.pixelSize(path:)`, `Tokens.image(width:height:)`, `Tokens.text(_:)`, and `Runner.lineJSON(_:)`.
- `--json` image results gain `"lines": [{"n": 1, "text": "...", "bbox": [x0, y0, x1, y1], "confidence": 0.97}]` with integer pixel coordinates. `lines[].text` is redacted per line with the same redactor.

Spec items implemented: indentation and fences in the plain payload (through `Layout`), monospace regions re-OCR'd with `usesLanguageCorrection = false`, and line-addressable JSON.

- [ ] **Step 1: Write the failing tests**

`Tests/CheapshotCoreTests/TokensTests.swift`:
```swift
import XCTest
@testable import CheapshotCore

final class TokensTests: XCTestCase {
    func testImageTokensUseTheDownscaleRule() {
        XCTAssertEqual(Tokens.image(width: 750, height: 1), 1)
        XCTAssertEqual(Tokens.image(width: 1000, height: 1000), 1333)
        XCTAssertEqual(Tokens.image(width: 3136, height: 1568), 1639, "long edge scaled to 1568 first")
        XCTAssertEqual(Tokens.image(width: 0, height: 0), 0)
    }

    func testTextTokens() {
        XCTAssertEqual(Tokens.text(""), 1)
        XCTAssertEqual(Tokens.text("12345678"), 2)
        XCTAssertEqual(Tokens.text("123456789"), 2)
        XCTAssertEqual(Tokens.text("1234567890"), 3)
    }
}
```

Add to `Tests/CheapshotCLITests/RunnerTests.swift`:
```swift
    /// A blank white PNG has no text. This asserts the JSON shape, not OCR content.
    func testBlankImageJSONHasLinesArrayAndTokens() async throws {
        let png = tmp.appendingPathComponent("blank.png")
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))

        let r = await run(["--json", png.path])
        XCTAssertEqual(r.code, 0, r.err)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        XCTAssertEqual(results[0]["file"] as? String, png.path)
        XCTAssertNotNil(results[0]["lines"] as? [[String: Any]])
        XCTAssertEqual(results[0]["image_tokens"] as? Int, 27)   // 200*100/750
        XCTAssertNotNil(results[0]["text"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ledger.jsonl").path), "successful run writes the ledger")
    }
```
Add `import ImageIO` and `import CoreGraphics` at the top of that file.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TokensTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'Tokens' in scope`.

- [ ] **Step 3: Write Tokens.swift and ImageLoader.swift**

`Sources/CheapshotCore/Tokens.swift`:
```swift
import Foundation

public enum Tokens {
    /// Anthropic's rule of thumb, (w * h) / 750, after the long-edge downscale to 1568 px.
    public static func image(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        var fw = Double(width), fh = Double(height)
        let maxEdge = 1568.0
        if max(fw, fh) > maxEdge { let s = maxEdge / max(fw, fh); fw *= s; fh *= s }
        return Int((fw * fh / 750.0).rounded())
    }

    /// About four characters per token, never zero.
    public static func text(_ s: String) -> Int { max(1, Int((Double(s.count) / 4.0).rounded())) }
}
```

`Sources/CheapshotCore/OCR/ImageLoader.swift`:
```swift
import Foundation
import AppKit

public enum ImageLoader {
    public static func load(path: String) -> CGImage? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    public static func pixelSize(path: String) -> (width: Int, height: Int)? {
        guard let img = NSImage(contentsOfFile: path), let rep = img.representations.first else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}
```

- [ ] **Step 4: Write OCR.swift**

```swift
import Foundation
import Vision
import CoreGraphics

public enum OCR {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Vision text recognition on one image. Boxes come back in pixels with a top-left origin.
    public static func recognize(image: CGImage, minConfidence: Float, languageCorrection: Bool = true) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        let lines = try perform(request, on: image, minConfidence: minConfidence, roi: nil)
        return OCRResult(lines: lines, width: image.width, height: image.height)
    }

    /// Full screenshot pipeline: recognize with correction on, find monospace runs, recognize each
    /// run's region again with correction off (so hashes and tokens are not "corrected" into words),
    /// then lay out with indentation and fences.
    public static func recognizeLayout(image: CGImage, minConfidence: Float) throws -> [RenderedLine] {
        let first = try recognize(image: image, minConfidence: minConfidence)
        var lines = Layout.sorted(first.lines)
        for run in Layout.monospaceRuns(lines).reversed() {      // reversed so earlier indices stay valid
            let union = run.reduce(CGRect.null) { $0.union(lines[$1].bbox) }
            let pad: CGFloat = 4
            let region = union.insetBy(dx: -pad, dy: -pad)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !region.isEmpty else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.regionOfInterest = normalized(region, width: image.width, height: image.height)
            guard let replacement = try? perform(request, on: image, minConfidence: minConfidence, roi: request.regionOfInterest),
                  !replacement.isEmpty else { continue }
            lines.replaceSubrange(run, with: Layout.sorted(replacement))
        }
        return Layout.render(lines)
    }

    static func perform(_ request: VNRecognizeTextRequest, on image: CGImage, minConfidence: Float, roi: CGRect?) throws -> [OCRLine] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { throw Failure(message: "vision: \(error.localizedDescription)") }
        var lines: [OCRLine] = []
        for o in request.results ?? [] {
            guard let top = o.topCandidates(1).first, top.confidence >= minConfidence else { continue }
            // With a regionOfInterest, Vision reports boxes relative to that region.
            var box = o.boundingBox
            if let roi = roi {
                box = CGRect(x: roi.minX + box.minX * roi.width, y: roi.minY + box.minY * roi.height,
                             width: box.width * roi.width, height: box.height * roi.height)
            }
            lines.append(OCRLine(text: top.string, bbox: pixels(box, width: image.width, height: image.height), confidence: top.confidence))
        }
        return lines
    }

    /// Vision: normalized, bottom-left origin. Ours: pixels, top-left origin.
    static func pixels(_ r: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
    }

    static func normalized(_ r: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: r.minX / w, y: (h - r.maxY) / h, width: r.width / w, height: r.height / h)
    }
}
```

- [ ] **Step 5: Delete the old functions and rewire the runner**

Delete `ocr`, `imageTokens`, `textTokens` from `Sources/CheapshotCore/Core.swift`. What remains there is the video block (`findFFmpeg`, `sceneFrames`, `similarity`, `stamp`); Task 11 removes those and the file.

In `Sources/CheapshotCLI/Runner.swift`:
- Delete the `Tokens_text` shim; replace every `Tokens_text(` with `Tokens.text(`.
- Add the helper:
```swift
    static func lineJSON(_ lines: [RenderedLine], redactor: Redactor?) -> [[String: Any]] {
        lines.map { l in
            ["n": l.n, "text": apply(redactor, l.text).text,
             "bbox": [Int(l.bbox.minX.rounded()), Int(l.bbox.minY.rounded()), Int(l.bbox.maxX.rounded()), Int(l.bbox.maxY.rounded())],
             "confidence": Double(l.confidence)]
        }
    }
```
- Replace the body of the per-file loop in `runImages` (from `guard let raw = ocr(...)` through the `results.append` line) with:
```swift
            guard let image = ImageLoader.load(path: f) else {
                failed += 1
                results.append(["file": f, "error": "cannot read image"])
                io.err("cheapshot: cannot read \(f)\n")
                continue
            }
            let rendered: [RenderedLine]
            do { rendered = try OCR.recognizeLayout(image: image, minConfidence: opts.minConfidence) }
            catch {
                failed += 1
                results.append(["file": f, "error": "\(error)"])
                io.err("cheapshot: \(f): \(error)\n")
                continue
            }
            let (text, report) = apply(redactor, Layout.text(rendered))
            let size = ImageLoader.pixelSize(path: f) ?? (image.width, image.height)
            let it = Tokens.image(width: size.width, height: size.height), tt = Tokens.text(text)
            totalImage += it; totalText += tt; totalRedactions += report.total
            results.append(["file": f, "text": text, "redactions": report.counts, "image_tokens": it, "text_tokens": tt,
                            "lines": lineJSON(rendered, redactor: redactor)])
```
- In `runVideo`, replace `frameImageTokens += imageTokens(path: f)` with `frameImageTokens += ImageLoader.pixelSize(path: f).map { Tokens.image(width: $0.width, height: $0.height) } ?? 0` and `guard let raw = ocr(path: f, ...)` with:
```swift
            guard let image = ImageLoader.load(path: f),
                  let rendered = try? OCR.recognizeLayout(image: image, minConfidence: opts.minConfidence) else { continue }
            let raw = Layout.text(rendered)
```

- [ ] **Step 6: Run tests and a manual check on a real screenshot**

Run: `swift test 2>&1 | grep -E "error|failed|Executed"`
Expected: 0 failures in both bundles.

Manual check (not a test; Vision output drifts): take any terminal screenshot on this Mac and run
`swift build && .build/debug/cheapshot --no-ledger --json <shot.png> | head -40`. Confirm the plain `text` starts with a fence, lines are in top-to-bottom order, `bbox` values are within the image size, and `n` is 1-based and increasing. If a fenced region comes back with lines out of order or boxes outside the image, the `regionOfInterest` box conversion in `perform` is wrong: Vision reports boxes relative to the region, and the conversion above assumes that.

- [ ] **Step 7: Commit**

```bash
git add -A Sources Tests
git commit -m "ocr: lines with boxes, code-aware layout, line-addressable --json, Tokens"
```

---

### Task 11: Video: FrameSource, FFmpegFrameSource with `-fps_mode vfr`, VideoTranscriber

**Files:**
- Create: `Sources/CheapshotCore/Video/FrameSource.swift`
- Create: `Sources/CheapshotCore/Video/FFmpegFrameSource.swift`
- Create: `Sources/CheapshotCore/Video/VideoTranscriber.swift`
- Delete: `Sources/CheapshotCore/Core.swift` (its last functions move here)
- Modify: `Sources/CheapshotCLI/Runner.swift` (`runVideo`, now async)
- Create: `Tests/CheapshotCoreTests/FFmpegFrameSourceTests.swift`
- Create: `Tests/CheapshotCoreTests/VideoTranscriberTests.swift`
- Modify: `README.md` "Video" section (one paragraph)

**Interfaces:**
- Consumes: `OCR.recognizeLayout`, `Layout.text`, `Tokens`, `Redactor`.
- Produces: `VideoFrame`, `FrameSource`, `FFmpegFrameSource`, `VideoSegment`, `VideoTranscript`, `VideoTranscriber` as in the API reference.

Behaviour fixed here (audit finding 5 and the spec's `-fps_mode vfr` bug): the image2 muxer no longer duplicates frames at constant rate, so `-frames:v` caps kept frames instead of input frames; the temp directory is owned by the source and deleted when the stream finishes; the ledger records redactions.

- [ ] **Step 1: Write the failing tests**

`Tests/CheapshotCoreTests/FFmpegFrameSourceTests.swift`:
```swift
import XCTest
@testable import CheapshotCore

/// Builds a 4 s, 10 fps clip with four solid-colour segments (three changes). Verified on
/// ffmpeg 9.0.1: the Phase 1 chain prints 3 frames (t = 0, 2, 3; the red->green change at t = 1
/// scores under 0.25) and writes exactly 3 files. The old chain wrote 39 files for 3 frames.
final class FFmpegFrameSourceTests: XCTestCase {
    var tmp: URL!
    var clip: URL!

    override func setUpWithError() throws {
        guard let ff = FFmpegFrameSource.findFFmpeg() else { throw XCTSkip("ffmpeg not installed") }
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ffsrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        clip = tmp.appendingPathComponent("clip.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "color=c=red:s=320x240:r=10:d=1",
                       "-f", "lavfi", "-i", "color=c=green:s=320x240:r=10:d=1",
                       "-f", "lavfi", "-i", "color=c=blue:s=320x240:r=10:d=1",
                       "-f", "lavfi", "-i", "color=c=white:s=320x240:r=10:d=1",
                       "-filter_complex", "[0][1][2][3]concat=n=4:v=1:a=0", "-pix_fmt", "yuv420p", clip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
    override func tearDownWithError() throws { if let tmp = tmp { try? FileManager.default.removeItem(at: tmp) } }

    func leftoverDirs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasPrefix("cheapshot-") }
    }

    func testThreeChangesYieldThreeFramesAndNoLeftoverDir() async throws {
        let source = FFmpegFrameSource(tempBase: tmp)
        var times: [TimeInterval] = []
        var sizes: [(Int, Int)] = []
        for try await frame in try source.frames(of: clip, maxFrames: 200) {
            times.append(frame.time); sizes.append((frame.image.width, frame.image.height))
        }
        XCTAssertEqual(times.count, 3, "times: \(times)")
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(sizes.allSatisfy { $0 == (320, 240) })
        XCTAssertEqual(try leftoverDirs(), [], "temp dir must be deleted when the stream finishes")
    }

    func testMaxFramesCapsKeptFrames() async throws {
        var n = 0
        for try await _ in try FFmpegFrameSource(tempBase: tmp).frames(of: clip, maxFrames: 2) { n += 1 }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(try leftoverDirs(), [])
    }

    func testMissingVideoThrowsAndLeavesNothing() async throws {
        do {
            for try await _ in try FFmpegFrameSource(tempBase: tmp).frames(of: tmp.appendingPathComponent("nope.mp4"), maxFrames: 5) {}
            XCTFail("expected a throw")
        } catch {}
        XCTAssertEqual(try leftoverDirs(), [])
    }

    func testFilterChainMatchesSpec() {
        XCTAssertEqual(FFmpegFrameSource.filterChain(threshold: 0.25),
                       "fps=4,mpdecimate=hi=64*12:lo=64*5:frac=0.1,select=eq(n\\,0)+gt(scene\\,0.25),metadata=print:file=-")
    }

    func testFindFFmpegFallsBackWhenPathIsEmpty() {
        XCTAssertNotNil(FFmpegFrameSource.findFFmpeg(environment: ["PATH": ""]))
    }

    func testMissingFFmpegThrows() {
        XCTAssertThrowsError(try FFmpegFrameSource(ffmpegPath: "/nonexistent/ffmpeg", tempBase: tmp).frames(of: clip, maxFrames: 1))
    }
}
```

`Tests/CheapshotCoreTests/VideoTranscriberTests.swift` (a fake source, so no ffmpeg and no Vision content assertions beyond "blank frames yield no segments"):
```swift
import XCTest
@testable import CheapshotCore

final class VideoTranscriberTests: XCTestCase {
    struct Blank: FrameSource {
        func frames(of video: URL, maxFrames: Int) throws -> AsyncThrowingStream<VideoFrame, Error> {
            AsyncThrowingStream { c in
                let ctx = CGContext(data: nil, width: 300, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
                let img = ctx.makeImage()!
                for t in [0.0, 2.0, 3.0] { c.yield(VideoFrame(time: t, image: img)) }
                c.finish()
            }
        }
    }

    func testBlankFramesCountTokensButYieldNoSegments() async throws {
        let t = try await VideoTranscriber(source: Blank()).transcribe(URL(fileURLWithPath: "/x.mp4"), maxFrames: 10)
        XCTAssertEqual(t.frameCount, 3)
        XCTAssertEqual(t.imageTokens, 3 * 60)   // 300*150/750 each
        XCTAssertEqual(t.segments, [])
    }

    func testSimilarityAndStamp() {
        XCTAssertEqual(VideoTranscriber.similarity("a b c", "a b c"), 1)
        XCTAssertEqual(VideoTranscriber.similarity("a b c d", "a b"), 0.5)
        XCTAssertEqual(VideoTranscriber.similarity("", ""), 1)
        XCTAssertEqual(VideoTranscriber.similarity("a", ""), 0)
        XCTAssertEqual(VideoTranscriber.stamp(75.4), "01:15")
        XCTAssertEqual(VideoTranscriber.stamp(0), "00:00")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "FFmpegFrameSourceTests|VideoTranscriberTests" 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'FFmpegFrameSource'`.

- [ ] **Step 3: Write FrameSource.swift**

```swift
import Foundation
import CoreGraphics

public struct VideoFrame {
    public let time: TimeInterval
    public let image: CGImage
    public init(time: TimeInterval, image: CGImage) { self.time = time; self.image = image }
}

/// Yields candidate frames in time order. The transcriber OCRs each and drops near-duplicates.
/// Image-typed, not path-typed: Vision wants a CGImage and the app has no temp dir to manage.
public protocol FrameSource {
    func frames(of video: URL, maxFrames: Int) throws -> AsyncThrowingStream<VideoFrame, Error>
}
```

- [ ] **Step 4: Write FFmpegFrameSource.swift**

```swift
import Foundation
import CoreGraphics
import ImageIO

/// CLI frame source. Runs ffmpeg once with scene detection into a temp directory this source
/// owns, then streams the JPEGs as CGImages one at a time and deletes the directory when the
/// stream ends. Not sandbox-safe; the app uses AVFoundation (later phase).
public struct FFmpegFrameSource: FrameSource {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public let ffmpegPath: String?
    public let sceneThreshold: Double
    public let tempBase: URL

    public init(ffmpegPath: String? = nil, sceneThreshold: Double = 0.25,
                tempBase: URL = URL(fileURLWithPath: NSTemporaryDirectory())) {
        self.ffmpegPath = ffmpegPath; self.sceneThreshold = sceneThreshold; self.tempBase = tempBase
    }

    /// The user's PATH first; then the usual install locations.
    public static func findFFmpeg(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let c = String(dir) + "/ffmpeg"
            if fm.isExecutableFile(atPath: c) { return c }
        }
        for c in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", NSHomeDirectory() + "/.local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where fm.isExecutableFile(atPath: c) { return c }
        return nil
    }

    /// fps=4 cuts filter work about 15x on 60 fps captures; mpdecimate drops static stretches
    /// before the scene metric runs; select keeps frame 0 plus every scene change.
    public static func filterChain(threshold: Double) -> String {
        "fps=4,mpdecimate=hi=64*12:lo=64*5:frac=0.1,select=eq(n\\,0)+gt(scene\\,\(threshold)),metadata=print:file=-"
    }

    public func frames(of video: URL, maxFrames: Int) throws -> AsyncThrowingStream<VideoFrame, Error> {
        guard let ff = ffmpegPath ?? Self.findFFmpeg(), FileManager.default.isExecutableFile(atPath: ff) else {
            throw Failure(message: "ffmpeg not found on PATH, /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, /usr/bin")
        }
        guard FileManager.default.fileExists(atPath: video.path) else { throw Failure(message: "no such video \(video.path)") }
        let dir = tempBase.appendingPathComponent("cheapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cleanup = { try? FileManager.default.removeItem(at: dir) }

        let extracted: [(TimeInterval, URL)]
        do { extracted = try extract(ffmpeg: ff, video: video, into: dir, maxFrames: maxFrames) }
        catch { cleanup(); throw error }

        // Unfolding streams load one JPEG per pull, so a 200-frame 1440p recording is never all in memory.
        var iterator = extracted.makeIterator()
        var finished = false
        return AsyncThrowingStream(unfolding: {
            while let (t, url) = iterator.next() {
                if let image = Self.loadJPEG(url) { return VideoFrame(time: t, image: image) }
            }
            if !finished { finished = true; cleanup() }
            return nil
        })
    }

    func extract(ffmpeg: String, video: URL, into dir: URL, maxFrames: Int) throws -> [(TimeInterval, URL)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", video.path,
                       "-an", "-sn",
                       "-vf", Self.filterChain(threshold: sceneThreshold),
                       "-fps_mode", "vfr",
                       "-frames:v", "\(maxFrames)",
                       "-q:v", "2",
                       dir.appendingPathComponent("f_%05d.jpg").path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { throw Failure(message: "could not launch \(ffmpeg): \(error.localizedDescription)") }
        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        p.waitUntilExit(); g.wait()
        if p.terminationStatus != 0 {
            let tail = (String(data: errData, encoding: .utf8) ?? "").split(separator: "\n").suffix(6).joined(separator: "\n")
            throw Failure(message: "ffmpeg exited \(p.terminationStatus)\n\(tail)")
        }

        // metadata=print emits "frame:N  pts:... pts_time:SECONDS" per kept frame, frame 0 included.
        var times: [TimeInterval] = []
        for line in (String(data: outData, encoding: .utf8) ?? "").split(separator: "\n") {
            guard let r = line.range(of: "pts_time:") else { continue }
            if let t = Double(line[r.upperBound...].prefix(while: { $0 != " " })) { times.append(t) }
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }.sorted()
        return files.enumerated().map { i, f in (i < times.count ? times[i] : TimeInterval(i), dir.appendingPathComponent(f)) }
    }

    static func loadJPEG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
```

- [ ] **Step 5: Write VideoTranscriber.swift**

```swift
import Foundation

public struct VideoSegment: Equatable {
    public var time: TimeInterval
    public var text: String
    public init(time: TimeInterval, text: String) { self.time = time; self.text = text }
}

public struct VideoTranscript {
    public var segments: [VideoSegment]
    public var frameCount: Int
    public var imageTokens: Int
    public var redactions: RedactionReport
}

/// Frames -> OCR -> redaction -> drop screens too similar to the last one -> timestamped segments.
public struct VideoTranscriber {
    public let source: FrameSource
    public let dedupe: Double
    public let minConfidence: Float
    public let redactor: Redactor?

    public init(source: FrameSource, dedupe: Double = 0.90, minConfidence: Float = 0.3, redactor: Redactor? = Redactor()) {
        self.source = source; self.dedupe = dedupe; self.minConfidence = minConfidence; self.redactor = redactor
    }

    public func transcribe(_ video: URL, maxFrames: Int) async throws -> VideoTranscript {
        var segments: [VideoSegment] = []
        var lastText = ""
        var frameCount = 0, imageTokens = 0
        var report = RedactionReport()
        for try await frame in try source.frames(of: video, maxFrames: maxFrames) {
            frameCount += 1
            imageTokens += Tokens.image(width: frame.image.width, height: frame.image.height)
            guard let rendered = try? OCR.recognizeLayout(image: frame.image, minConfidence: minConfidence) else { continue }
            var text = Layout.text(rendered)
            if let r = redactor {
                let (t, rep) = r.redact(text)
                text = t
                for (k, v) in rep.counts { report.counts[k, default: 0] += v }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if Self.similarity(trimmed, lastText) >= dedupe { continue }
            segments.append(VideoSegment(time: frame.time, text: trimmed))
            lastText = trimmed
        }
        return VideoTranscript(segments: segments, frameCount: frameCount, imageTokens: imageTokens, redactions: report)
    }

    /// Cheap token-set overlap. Screen recordings repeat; near-identical frames are dropped.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let sa = Set(a.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        let sb = Set(b.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        if sa.isEmpty && sb.isEmpty { return 1 }
        if sa.isEmpty || sb.isEmpty { return 0 }
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }

    public static func stamp(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
```

- [ ] **Step 6: Delete Core.swift and rewrite runVideo**

`git rm Sources/CheapshotCore/Core.swift` (everything in it now lives in the new files).

In `Sources/CheapshotCLI/Runner.swift`, the `.video` case becomes `return await runVideo(...)` and the function becomes:
```swift
    static func runVideo(_ opts: Options, path: String, redactor: Redactor?, io: CLIIO) async -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else { io.err("cheapshot: no such video \(path)\n"); return 2 }
        let source = FFmpegFrameSource(sceneThreshold: opts.scene)
        let transcriber = VideoTranscriber(source: source, dedupe: opts.dedupe, minConfidence: opts.minConfidence, redactor: redactor)
        let t: VideoTranscript
        do { t = try await transcriber.transcribe(URL(fileURLWithPath: path), maxFrames: opts.maxFrames) }
        catch { io.err("cheapshot: \(error)\n"); return 1 }
        guard t.frameCount > 0 else { io.err("cheapshot: no frames extracted\n"); return 1 }

        var body = ""
        for s in t.segments { body += "[\(VideoTranscriber.stamp(s.time))]\n\(s.text)\n\n" }
        let tt = Tokens.text(body)
        if opts.json {
            let segs = t.segments.map { ["time": $0.time, "stamp": VideoTranscriber.stamp($0.time), "text": $0.text] as [String: Any] }
            io.out(Output.json(payload([["file": path, "text": body.trimmingCharacters(in: .whitespacesAndNewlines),
                                         "segments": segs, "frames": t.frameCount, "redactions": t.redactions.counts,
                                         "image_tokens": t.imageTokens, "text_tokens": tt]],
                                       imageTokens: t.imageTokens, textTokens: tt)))
        } else {
            io.out(body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        }
        record(LedgerEntry(mode: "video", inputs: t.frameCount, imageTokens: t.imageTokens, textTokens: tt, redactions: t.redactions.total), opts, io)
        if opts.stats {
            let saved = max(0, t.imageTokens - tt)
            let pct = t.imageTokens > 0 ? Int(Double(saved) / Double(t.imageTokens) * 100) : 0
            io.err("cheapshot: \(t.frameCount) scene frames, \(t.segments.count) distinct screens  \(t.imageTokens) image tokens -> \(tt) text tokens  (saved \(saved), \(pct)%)\n")
        }
        return 0
    }
```

- [ ] **Step 7: Run tests and the acceptance check**

Run: `swift test 2>&1 | grep -E "error|failed|Executed"`
Expected: 0 failures in both bundles; the ffmpeg tests run (not skipped) on this Mac.

Run:
```bash
swift build 2>&1 | tail -1
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=red:s=320x240:r=10:d=1 -f lavfi -i color=c=green:s=320x240:r=10:d=1 -f lavfi -i color=c=blue:s=320x240:r=10:d=1 -f lavfi -i color=c=white:s=320x240:r=10:d=1 -filter_complex "[0][1][2][3]concat=n=4:v=1:a=0" -pix_fmt yuv420p /tmp/cs-clip.mp4
.build/debug/cheapshot --no-ledger --stats --video /tmp/cs-clip.mp4; echo "exit=$?"
ls "${TMPDIR:-/tmp}" | grep -c '^cheapshot-' 
```
Expected: stderr `cheapshot: 3 scene frames, 0 distinct screens ...`, `exit=0`, and `0` leftover directories.

- [ ] **Step 8: README Video paragraph**

After "Requires ffmpeg on your PATH." add: "Frames are sampled at 4 per second, static stretches are dropped before scene scoring, and only changed frames are written (`-fps_mode vfr`), so `--max-frames` counts kept frames, not input frames."

- [ ] **Step 9: Commit**

```bash
git add -A Sources Tests README.md
git commit -m "video: FrameSource protocol, ffmpeg adapter with -fps_mode vfr and the fps/mpdecimate chain, VideoTranscriber

The temp dir is owned by the source and deleted when the stream ends. The ledger
records redactions for video runs."
```

---

### Task 12: PDF input: text lane, scan lane, `--pages`, `source.sha256`

**Files:**
- Create: `Sources/CheapshotCore/PDF/PDFSource.swift`
- Modify: `Package.swift` (link PDFKit)
- Modify: `Sources/CheapshotCLI/Runner.swift` (PDF branch in `runImages`)
- Create: `Tests/CheapshotCoreTests/PDFSourceTests.swift`
- Modify: `Tests/CheapshotCLITests/RunnerTests.swift` (one PDF test)
- Modify: `README.md` (new "PDF" section after "Video")

**Interfaces:**
- Consumes: `OCR.recognizeLayout`, `Layout`, `RenderedLine`, `Tokens`.
- Produces: `PDFLane`, `PDFPageResult`, `PDFDocumentResult`, `PDFSource.pages(of:range:minConfidence:)`, `PDFSource.sha256(of:)`, `PDFSource.text(of:)` as in the API reference.
- `--json` result entry for a PDF: `{"file", "source": {"path", "sha256", "pages"}, "pages": [{"n", "lane", "lines": [...]}], "text", "redactions", "image_tokens", "text_tokens"}`. The `lines` objects are the same shape as image lines; text-lane confidence is 1.0 and bbox is in PDF points, top-left origin.
- Image tokens per page: the 2x render size through `Tokens.image`, for both lanes. That is what an agent pays when `Read` renders the page.

- [ ] **Step 1: Add PDFKit to the linker settings**

In `Package.swift`: `linkerSettings: [.linkedFramework("Vision"), .linkedFramework("AppKit"), .linkedFramework("PDFKit")]`.

- [ ] **Step 2: Write the failing tests**

`Tests/CheapshotCoreTests/PDFSourceTests.swift`:
```swift
import XCTest
import CoreGraphics
import CoreText
@testable import CheapshotCore

final class PDFSourceTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pdf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    enum Page { case text([String], font: String); case blank }

    /// A real PDF with a real text layer, drawn with CoreText so PDFKit can read it back.
    func makePDF(_ pages: [Page], name: String = "t.pdf") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in pages {
            ctx.beginPDFPage(nil)
            switch page {
            case .text(let lines, let fontName):
                let font = CTFontCreateWithName(fontName as CFString, 12, nil)
                var y: CGFloat = 720
                for l in lines {
                    let attr = NSAttributedString(string: l, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
                    ctx.textPosition = CGPoint(x: 72, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
                    y -= 16
                }
            case .blank:
                ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
                ctx.fill(CGRect(x: 72, y: 72, width: 200, height: 100))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func testTextLaneReadsLinesWithBoxesAndMonospaceFence() throws {
        let url = try makePDF([.text(["def main():", "return 1", "print(main())"], font: "Menlo")])
        let doc = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3)
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertEqual(doc.pages.count, 1)
        let p = doc.pages[0]
        XCTAssertEqual(p.n, 1)
        XCTAssertEqual(p.lane, .text)
        XCTAssertEqual(p.lines.map(\.text), ["def main():", "return 1", "print(main())"])
        XCTAssertEqual(p.lines.map(\.n), [1, 2, 3])
        XCTAssertTrue(p.lines.allSatisfy { $0.confidence == 1.0 })
        XCTAssertTrue(p.lines.allSatisfy(\.fenced), "Menlo is fixed pitch, so the lines are fenced")
        XCTAssertEqual(p.lines[0].bbox.minX, 72, accuracy: 3)
        XCTAssertLessThan(p.lines[0].bbox.minY, p.lines[1].bbox.minY, "top-left origin: first line has the smaller y")
        XCTAssertEqual(p.width, 1224); XCTAssertEqual(p.height, 1584)
        XCTAssertEqual(PDFSource.text(of: doc), "--- page 1 ---\n```\ndef main():\nreturn 1\nprint(main())\n```")
    }

    func testProportionalFontIsNotFenced() throws {
        let url = try makePDF([.text(["Quarterly report", "Revenue grew twelve percent."], font: "Helvetica")])
        let p = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).pages[0]
        XCTAssertEqual(p.lane, .text)
        XCTAssertFalse(p.lines.contains(where: \.fenced))
    }

    func testScanLaneForPageWithoutText() throws {
        let url = try makePDF([.blank])
        let p = try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).pages[0]
        XCTAssertEqual(p.lane, .scan)       // OCR content is not asserted; a grey box has no text
        XCTAssertEqual(p.width, 1224)
    }

    func testPageRangeAndValidation() throws {
        let url = try makePDF([.text(["one"], font: "Helvetica"), .text(["two two two two two"], font: "Helvetica"), .text(["three three three three"], font: "Helvetica")])
        let doc = try PDFSource.pages(of: url, range: 2...2, minConfidence: 0.3)
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertEqual(doc.pages.map(\.n), [2])
        XCTAssertThrowsError(try PDFSource.pages(of: url, range: 3...4, minConfidence: 0.3))
        XCTAssertThrowsError(try PDFSource.pages(of: tmp.appendingPathComponent("missing.pdf"), range: nil, minConfidence: 0.3))
    }

    func testSHA256() throws {
        let f = tmp.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try PDFSource.sha256(of: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let url = try makePDF([.blank], name: "s.pdf")
        XCTAssertEqual(try PDFSource.pages(of: url, range: nil, minConfidence: 0.3).sha256, try PDFSource.sha256(of: url))
    }
}
```

Add to `Tests/CheapshotCLITests/RunnerTests.swift`:
```swift
    func testPDFJSONHasSourceShaAndPageLanes() async throws {
        let url = tmp.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in ["acct 12345678 on page one", "page two has enough text to count"] {
            ctx.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let attr = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()

        let r = await run(["--pages", "1-2", url.path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let results = try XCTUnwrap(try json(r.out)["results"] as? [[String: Any]])
        let source = try XCTUnwrap(results[0]["source"] as? [String: Any])
        XCTAssertEqual((source["sha256"] as? String)?.count, 64)
        XCTAssertEqual(source["pages"] as? Int, 2)
        let pages = try XCTUnwrap(results[0]["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.map { $0["lane"] as? String }, ["text", "text"])
        XCTAssertEqual(pages.map { $0["n"] as? Int }, [1, 2])
        let text = try XCTUnwrap(results[0]["text"] as? String)
        XCTAssertTrue(text.contains("--- page 2 ---"))
        XCTAssertTrue(text.contains("acct [BANK_ACCT]"), text)
        let firstLine = try XCTUnwrap((pages[0]["lines"] as? [[String: Any]])?.first)
        XCTAssertEqual(firstLine["text"] as? String, "acct [BANK_ACCT] on page one", "lines are redacted too")
        XCTAssertEqual((results[0]["image_tokens"] as? Int), 2 * 2586)   // 1224x1584 -> long edge 1568 -> 1211x1568/750
    }
```
Add `import CoreText` at the top of that file.

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter PDFSourceTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'PDFSource'`.

- [ ] **Step 4: Write PDFSource.swift**

```swift
import Foundation
import PDFKit
import CryptoKit
import CoreGraphics
import AppKit

public enum PDFLane: String, Codable { case text, scan }

public struct PDFPageResult {
    public var n: Int
    public var lane: PDFLane
    public var lines: [RenderedLine]
    public var width: Int      // rendered pixel size at 2x, what an agent would pay for
    public var height: Int
}

public struct PDFDocumentResult {
    public var path: String
    public var sha256: String
    public var pageCount: Int
    public var pages: [PDFPageResult]
}

/// Two lanes per page. Text lane: PDFKit's text layer, with fonts, so fixed-pitch fonts fence
/// for free. Scan lane: when the text layer has under 20 characters, render at 2x and run the
/// same Vision path as screenshots.
public enum PDFSource {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static let scanLaneThreshold = 20
    public static let renderScale: CGFloat = 2

    public static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func pages(of url: URL, range: ClosedRange<Int>?, minConfidence: Float) throws -> PDFDocumentResult {
        guard let doc = PDFDocument(url: url) else { throw Failure(message: "cannot open PDF \(url.path)") }
        let count = doc.pageCount
        guard count > 0 else { throw Failure(message: "\(url.path) has no pages") }
        let r = range ?? 1...count
        guard r.lowerBound >= 1, r.upperBound <= count else {
            throw Failure(message: "--pages \(r.lowerBound)-\(r.upperBound) is outside 1-\(count) for \(url.lastPathComponent)")
        }
        var pages: [PDFPageResult] = []
        for n in r {
            guard let page = doc.page(at: n - 1) else { continue }
            pages.append(try process(page, n: n, minConfidence: minConfidence))
        }
        return PDFDocumentResult(path: url.path, sha256: try sha256(of: url), pageCount: count, pages: pages)
    }

    /// Plain payload with page separators.
    public static func text(of result: PDFDocumentResult) -> String {
        result.pages.map { "--- page \($0.n) ---\n" + Layout.text($0.lines) }.joined(separator: "\n\n")
    }

    static func process(_ page: PDFPage, n: Int, minConfidence: Float) throws -> PDFPageResult {
        let bounds = page.bounds(for: .mediaBox)
        let w = Int((bounds.width * renderScale).rounded()), h = Int((bounds.height * renderScale).rounded())
        let string = page.string ?? ""
        if string.filter({ !$0.isWhitespace }).count >= scanLaneThreshold {
            return PDFPageResult(n: n, lane: .text, lines: textLines(page, string: string, bounds: bounds), width: w, height: h)
        }
        let image = try render(page, bounds: bounds, width: w, height: h)
        let lines = try OCR.recognizeLayout(image: image, minConfidence: minConfidence)
        return PDFPageResult(n: n, lane: .scan, lines: lines, width: w, height: h)
    }

    /// One RenderedLine per non-blank line of the text layer, with its selection bounds
    /// converted to a top-left origin and `fenced` set when the first glyph's font is fixed pitch.
    static func textLines(_ page: PDFPage, string: String, bounds: CGRect) -> [RenderedLine] {
        var out: [RenderedLine] = []
        var location = 0
        for raw in string.split(separator: "\n", omittingEmptySubsequences: false) {
            let length = (String(raw) as NSString).length
            let range = NSRange(location: location, length: length)
            location += length + 1
            let text = String(raw).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var bbox = CGRect.zero
            var mono = false
            if let sel = page.selection(for: range) {
                let b = sel.bounds(for: page)
                bbox = CGRect(x: b.minX - bounds.minX, y: bounds.maxY - b.maxY, width: b.width, height: b.height)
                if let attr = sel.attributedString, attr.length > 0,
                   let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                    mono = font.isFixedPitch
                }
            }
            out.append(RenderedLine(n: out.count + 1, text: text, bbox: bbox, confidence: 1.0, fenced: mono))
        }
        return out
    }

    static func render(_ page: PDFPage, bounds: CGRect, width: Int, height: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "cannot allocate a \(width)x\(height) bitmap")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: renderScale, y: renderScale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { throw Failure(message: "cannot render page") }
        return image
    }
}
```

- [ ] **Step 5: Add the PDF branch to the runner**

In `runImages`, right after the `fileExists` guard and before `ImageLoader.load`, insert:
```swift
            if (f as NSString).pathExtension.lowercased() == "pdf" {
                let doc: PDFDocumentResult
                do { doc = try PDFSource.pages(of: URL(fileURLWithPath: f), range: opts.pages, minConfidence: opts.minConfidence) }
                catch {
                    failed += 1
                    results.append(["file": f, "error": "\(error)"])
                    io.err("cheapshot: \(error)\n")
                    continue
                }
                let (text, report) = apply(redactor, PDFSource.text(of: doc))
                let it = doc.pages.reduce(0) { $0 + Tokens.image(width: $1.width, height: $1.height) }
                let tt = Tokens.text(text)
                totalImage += it; totalText += tt; totalRedactions += report.total
                results.append(["file": f, "text": text, "redactions": report.counts, "image_tokens": it, "text_tokens": tt,
                                "source": ["path": doc.path, "sha256": doc.sha256, "pages": doc.pageCount],
                                "pages": doc.pages.map { ["n": $0.n, "lane": $0.lane.rawValue, "lines": lineJSON($0.lines, redactor: redactor)] as [String: Any] }])
                if !opts.json {
                    if paths.count > 1 { io.out("== \((f as NSString).lastPathComponent)\n") }
                    io.out(text + "\n")
                }
                continue
            }
```

- [ ] **Step 6: Run tests and the acceptance check**

Run: `swift test 2>&1 | grep -E "error|failed|Executed"`
Expected: 0 failures in both bundles. If `testTextLaneReadsLinesWithBoxesAndMonospaceFence` fails on `lines.map(\.text)`, print `page.string` for the test PDF: PDFKit may join or split lines differently from the draw order, and the fix is in `textLines`, not the test.

Run: `.build/debug/cheapshot --no-ledger --pages 1-2 <any real pdf> --json | head -30`
Expected: `"lane"` inside `pages` and a 64-character `"sha256"` under `source`.

- [ ] **Step 7: README PDF section**

After the Video section add:
```markdown
## PDF

`cheapshot report.pdf` and `cheapshot --pages 3-5 report.pdf`. Pages with a text layer are
read through PDFKit (the text lane, free, fonts kept so code is fenced); pages without one are
rendered at 2x and OCR'd like a screenshot (the scan lane). The plain output separates pages
with `--- page N ---`. `--json` adds `source.sha256` and `pages[].lane` so a downstream tool
can cite a page and route scanned pages for review. Redaction and the ledger apply as for
images; the ledger counts what an agent would pay to read each page as an image.
```

- [ ] **Step 8: Commit**

```bash
git add -A Package.swift Sources Tests README.md
git commit -m "pdf: text lane and scan lane, --pages, source.sha256 and pages[].lane in --json"
```

---

### Task 13: Docs, usage text, and version bump to 0.5.0-dev

**Files:**
- Modify: `Sources/CheapshotCore/Version.swift`
- Modify: `Tests/CheapshotCoreTests/RedactorTests.swift` (`testVersionConstant`)
- Modify: `README.md` "Use" and "Redaction" sections
- Modify: `docs/superpowers/plans/2026-09-12-phase-0-1-core-split-and-audit-fixes.md` (tick every box)

- [ ] **Step 1: Version**

`Sources/CheapshotCore/Version.swift`: `public let cheapshotVersion = "0.5.0-dev"`. Update `testVersionConstant` to expect `"0.5.0-dev"`.

- [ ] **Step 2: README "Use" section**

Replace the block with:
```markdown
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
```

- [ ] **Step 2b: Accessibility check (spec section "Accessibility")**

Confirm and fix if needed: every `<img>` and `![...]` in `README.md` has non-empty alt text; `docs/licensing-animated.svg` still contains `prefers-reduced-motion`, `role="img"`, and a `<title>` element (add `<title>Scan for commercial licensing</title>` as the first child of the root `<svg>` if it is missing); `Output.usage()` and every `io.err` message use plain words with no ANSI escapes or box-drawing characters (`grep -rn $'\x1b' Sources` returns nothing).

- [ ] **Step 3: Build, test, acceptance sweep**

Run:
```bash
make 2>&1 | tail -2
swift test 2>&1 | grep -E "error|failed|Executed"
./cheapshot --version
./cheapshot --json missing.png; echo "exit=$?"
./cheapshot --bogus; echo "exit=$?"
./cheapshot --min-conf shot.png; echo "exit=$?"
printf 'acct 12345678\n1694563200\nCleanShot 2026 @2x.png\n' | ./cheapshot --text -
CHEAPSHOT_HOME=/tmp/cs-accept ./cheapshot --stats --video /tmp/cs-clip.mp4; ls /tmp/cs-accept; ls "${TMPDIR:-/tmp}" | grep -c '^cheapshot-'
```
Expected: `ok: universal, minos 13.0`; 0 failures; `0.5.0-dev`; exit 1 with an error entry; exit 2 twice; the three text lines redacted only on the first; `/tmp/cs-accept/ledger.jsonl` exists with one `"mode":"video"` line; `0` leftover dirs.

- [ ] **Step 4: Tick the plan and commit**

Change every `- [ ]` in this plan file to `- [x]`.

```bash
git add -A
git commit -m "docs: README for 0.5.0-dev flags, exit codes, PDF, code-aware output; plan complete"
```

---

## Self-review notes (done while writing)

- Spec coverage: Phase 0 (Tasks 1, 2). Audit items 1 to 5 of the brief's Phase 1 (Tasks 2, 7, 4, 8, 11 and 7). `-fps_mode vfr` and the filter chain (Task 11). Indentation, fences, line-addressable JSON (Tasks 9, 10). `--text` and 30-case suite (Tasks 7, 4). `--rules` (Tasks 5, 7). Ledger location, `--ledger --json`, `--ledger --migrate` (Task 8). PDF lanes, `--pages`, `source.sha256` (Task 12). Not in scope and not planned: AVFoundation source, PDF tables, plugin, MCP, relicense, app.
- Deviation from spec, called out: indentation is applied inside monospace runs only (Task 9). The ledger location rule has two steps, not three; see the spec's Open questions entry for Perplexity answer 2.
- Type consistency: `RenderedLine` is shared by OCR (Task 10) and PDF (Task 12); `lineJSON` (Task 10) serialises both. `Tokens.text` replaces the Task 7 `Tokens_text` shim in Task 10. `record(...)` (Task 8) is used by Tasks 10 to 12.

# Cheapshot product brief

Written 2026-09-12 from four parallel research passes (code audit, distribution, agent integration, market scan). Full reports are appended below. Read this top section first; it is the whole decision.

## Decision (Ryan, 2026-09-12)

Two products, one engine.

1. **FOSS CLI + Claude Code plugin.** Free, the splash. This is where every developer and agent host meets cheapshot. The research verdict was "do not paywall the CLI"; that stands.
2. **Freemium Mac App Store app.** Signed, notarized, sandboxed, sold through Apple. A bare CLI cannot ship on the Mac App Store, so this is a menu bar app around the same Swift engine: watches the screenshots folder, OCRs on capture, clipboard guard before paste, ledger dashboard. Free tier: OCR + redaction. Paid tier: **$4.99 for a 2-year rolling license**, gating `--video` transcripts, ledger history, clipboard guard, custom redaction rules.

### Value proposition of the paid tier

The ledger is the sales pitch. The free tier already shows "you saved N image tokens this week." At API rates that is dollars; on a Max plan it is 5-hour-window headroom (claude-code#27869: one user burned 17% of a window in 5 calls on stale screenshots). $4.99 for two years is less than one afternoon of screenshot tokens, and the app shows the user that number before asking. Paywall copy writes itself: "Cheapshot saved you 41,200 tokens this week. $4.99 keeps the video transcripts and clipboard guard for two years."

Why $4.99 and not the $13 to $39 the comps charge: impulse price on the App Store, no decision cost, and the CLI being free means the app is competing with "just use the free one," not with Redaktr. Apple takes 15% under the Small Business Program, so $4.24 net; this is a volume play, not a margin play. Revisit after the first 1,000 installs.

StoreKit mapping: auto-renewing subscriptions cannot have a 2-year period (max 1 year). Use a **non-renewing subscription** product with a 2-year duration; the app stores the expiry from the transaction and re-prompts at 2 years. Restore across devices via the App Store receipt. Fallback if review pushes back: 1-year auto-renew at $2.49.

License note: BSL 1.1 is not OSI open source. "FOSS" means the CLI moves to MIT or Apache-2.0. The App Store app can stay closed; it is a separate target that links the same engine. Decide this before the first public release, not after.

App Store constraints to design around: sandbox needs a security-scoped bookmark for the screenshots folder (one folder picker on first launch); no shelling out to the CLI, the engine has to be a Swift module both targets import; Vision works fine in the sandbox.

Positioning line for the README: **Give your coding agent the words on your screen, not the pixels: on-device OCR that redacts secrets first and shows you the tokens it saved.**

## What the product actually is

1. A PreToolUse hook for Claude Code that intercepts `Read` on image files, denies it, and returns the redacted OCR text plus the token savings. The agent never has to decide to use cheapshot. This is the flagship.
2. A Claude Code plugin bundling that hook, a generic SKILL.md, and an MCP server. One `claude plugin add`.
3. A thin TypeScript MCP server (`npx cheapshot-mcp`) shelling out to the Swift binary, for Cursor, Codex CLI, Raycast.
4. `brew install all-caps-dev/tap/cheapshot`: universal, signed, notarized binary built by GitHub Actions on tag push.
5. The ledger, surfaced where the win is felt: status line segment, one-line stderr per hook fire, local SVG badge.

## Edges over the field

Redaction by default, the ledger, and `--video`. The closest rival, mac-ocr (508 stars, MIT, active), already sells "save vision tokens" and ships an agent skill, but has no redaction and no ledger. Lead with the edges, not with OCR.

## Known risk

claude-code#16592: hooks cannot see pasted images. The hook works on file-path `Read`s only. Pasted screenshots stay a manual step until Anthropic ships that.

## Build order (about 3 to 4 focused days to brew-installable, plus 2 to 3 for the plugin)

Phase 1, make it installable by a stranger:
1. Deployment target: build with `-target arm64-apple-macos13` and x86_64, `lipo` them. Makefile.
2. Exit 1 on partial failure; `{"file","error"}` entries in `--json`; reject unknown flags with exit 2; fix `--min-conf` and `--newest` arg swallowing.
3. `BANK_ACCT`: require a context cue or skip 10- and 13-digit runs. Also fix `@2x.png` -> `[EMAIL]`.
4. Video temp dir leak (`exit(0)` skips the `defer`); ledger `O_APPEND` atomic write; move ledger out of `~/.claude/` to `~/Library/Application Support/cheapshot/`; drop the `~/Dropbox/_Screenshots` fallback.
5. `--text` stdin mode plus a shell golden-file suite (30 cases) in CI. Do not golden-test OCR output.

Phase 2, ship:
1. Developer ID cert ($99/yr), App Store Connect API key.
2. `.github/workflows/release.yml` from the distribution report; secrets listed there.
3. Create `all-caps-dev/homebrew-tap` with the formula (license `BUSL-1.1`, not MIT).
4. Tag v0.5.0.

Phase 3, the plugin:
1. PreToolUse hook script + `CHEAPSHOT_PASSTHROUGH` escape hatch.
2. Generic SKILL.md (rewrite of the personal screenshot-ocr skill).
3. `cheapshot-mcp` TypeScript package with three tools: `cheapshot_ocr`, `cheapshot_video`, `cheapshot_ledger`.
4. Status line segment reading `--ledger --json`.

Phase 4, the App Store app (after the CLI has traction):
1. Split `cheapshot.swift` into a `CheapshotCore` Swift package (OCR, redaction, ledger) plus a thin CLI target. Same Package.swift feeds the app.
2. Menu bar app target: folder watcher, capture -> OCR -> redacted text on clipboard, ledger window.
3. StoreKit 2 one-time purchase gating video, ledger history, clipboard guard, custom rules.
4. App Store review: sandbox entitlements, security-scoped bookmark, privacy nutrition label ("no data collected" is true and is the selling point).

Later, ongoing: redaction rules (PASSWORD, BASIC_AUTH, GOOGLE_KEY, IBAN), `usesLanguageCorrection = false`, clipboard input, `--lang`.

---

# Appendix: 01-code-audit

# Code audit of cheapshot.swift (Fable, 2026-09-12)

Built with plain swiftc, probed redact() and the CLI. Nothing edited.

## Ranked findings
1. Binary only runs on macOS 26 arm64. swiftc with no -target stamps minos 26.0 (otool -l), single arch. Fix: `-target arm64-apple-macos13.0` and `-target x86_64-apple-macos13.0`, then lipo; Makefile or Package.swift. README.md:21.
2. BANK_ACCT eats every 8+ digit run: build numbers, epochs, elapsed ns, AWS account IDs, order numbers. cheapshot.swift:35. Fix: require context cue (acct, account, MICR glyph, preceding ROUTING hit on same line) or cap 8-17 digits and skip 10- and 13-digit runs.
3. Partial failure exits 0 and --json hides it. `cheapshot --json missing.png good.png` -> clean JSON, exit 0. :464, :437. Fix: exit 1 if failed > 0; append {"file","error"} to results.
4. Arg parsing silently misbehaves: `--min-conf shot.png` swallows filename; `--newest 3` treats 3 as dir; typo flags dropped at :413. :324-345, :405-413. Fix: reject leftover --* with "unknown option" exit 2; validate popValue parses; numeric --newest arg = n.
5. Video temp dir leaks: defer at :355 never fires because exit(0) at :385 does not unwind. Up to 200 PNGs per run in $TMPDIR/cheapshot-<uuid>. Also ledger records redactions: 0 at :376. Fix: explicit removeItem before exit, or refactor to a function returning status.
6. Ledger append not atomic, errors swallowed. FileHandle + seekToEndOfFile at :257 is not O_APPEND; concurrent fan-out runs clobber lines. Personal paths: ~/.claude/ at :248,263; ~/Dropbox/_Screenshots at :402. Fix: open(O_WRONLY|O_APPEND|O_CREAT) + one write(2); move ledger to ~/Library/Application Support/cheapshot/ (or $CHEAPSHOT_HOME); CleanShot fallback ~/Desktop.
7. Redaction FP/FN: `CleanShot ... @2x.png` -> `at [EMAIL]` (:31; require letter before @, exclude @2x/@3x). FN: `password: hunter2`, Basic auth, AIza Google keys, IBAN, IPv6, non-US phones. usesLanguageCorrection = true at :126 garbles secrets. Fix: add PASSWORD, BASIC_AUTH, GOOGLE_KEY (`AIza[0-9A-Za-z_\-]{35}`), IBAN; set usesLanguageCorrection = false or --no-correct.
8. No tests, no stdin. Add `--text` / `-` stdin mode at :315 that skips Vision and redacts text; then shell golden-file suite tests/cases/*.txt -> tests/expected/*.txt, CI on macos-latest. Do not golden-test OCR output (Vision drifts). swift test would need a library split; not worth it now.

## Product basics
--version and --help exist and are fine. Exit codes undocumented (0/1/2). No config file, no --lang (en-US at :124), no clipboard input (NSPasteboard would be the killer feature). Homebrew formula can call swiftc directly; Package.swift makes swift build and formula one-liners.

## Honest read
Builds cleanly, redactor holds up (paths, hashes, SHAs, versions, UUIDs survive), video path is novel. Blockers: deployment target (0.5d), exit code + unknown flags (0.5d), BANK_ACCT (0.5d + judgement), stdin + 30-case golden suite (1d), leak + ledger (0.5d), personal paths, Homebrew tap. About 3 to 4 focused days to "brew install and it works". Item 7 is an ongoing list.

---

# Appendix: 02-distribution

# Distribution (Fable, 2026-09-12)

Verified on this Mac (macOS 26.6.2, Swift 6.3.3) unless flagged. Repo is all-caps-dev/cheapshot, no tags, no releases. License is BSL 1.1 (the formula below must say that, not MIT).

## 1. Personal tap, prebuilt notarized binary (do first)
homebrew-core is closed: needs 90 forks / 90 watchers / 225 stars. Neither ryanilano/homebrew-tap nor all-caps-dev/homebrew-tap exists. Create all-caps-dev/homebrew-tap with Formula/cheapshot.rb:

```ruby
class Cheapshot < Formula
  desc "On-device screenshot OCR with redaction, for AI agents"
  homepage "https://github.com/all-caps-dev/cheapshot"
  url "https://github.com/all-caps-dev/cheapshot/releases/download/v0.5.0/cheapshot-v0.5.0-macos.zip"
  sha256 "REPLACED_BY_CI"
  license "BUSL-1.1"
  depends_on :macos => :ventura
  def install
    bin.install "cheapshot"
  end
  test do
    assert_match "cheapshot", shell_output("#{bin}/cheapshot --help", 1)
  end
end
```
Install: `brew install all-caps-dev/tap/cheapshot`. Formula downloads never get com.apple.quarantine, so Gatekeeper never assesses them. Prebuilt beats from-source (strangers would compile with whatever Xcode they have).

## 2. Sign and notarize (Developer ID, $99/yr)
Needed for the raw GitHub download, not for brew. Verified: ad-hoc-signed + quarantined CLI is `spctl: rejected` and blocks on a dialog; Sequoia removed Control-click Open, only exit is System Settings > Privacy & Security > Open Anyway. `security find-identity -v -p codesigning` shows 0 identities on this Mac today.
```bash
codesign --force --timestamp --options runtime --sign "Developer ID Application: NAME (TEAMID)" cheapshot
ditto -c -k --keepParent cheapshot cheapshot-v0.5.0-macos.zip
xcrun notarytool submit cheapshot-v0.5.0-macos.zip --key AuthKey.p8 --key-id KEYID --issuer ISSUER --wait
```
Bare executables cannot be stapled; Gatekeeper fetches the ticket online.

## 3. Release workflow (.github/workflows/release.yml)
Secrets: BUILD_CERTIFICATE_BASE64, P12_PASSWORD, KEYCHAIN_PASSWORD, ASC_KEY_BASE64, ASC_KEY_ID, ASC_ISSUER, COMMITTER_TOKEN (PAT repo+workflow, for the tap).
```yaml
on: { push: { tags: ['v*'] } }
jobs:
  release:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build universal
        run: |
          swiftc -O cheapshot.swift -o cheapshot-arm64 -framework Vision -framework AppKit -target arm64-apple-macos13
          swiftc -O cheapshot.swift -o cheapshot-x86 -framework Vision -framework AppKit -target x86_64-apple-macos13
          lipo -create cheapshot-arm64 cheapshot-x86 -output cheapshot
      - name: Import cert
        env: { BUILD_CERTIFICATE_BASE64: ${{ secrets.BUILD_CERTIFICATE_BASE64 }}, P12_PASSWORD: ${{ secrets.P12_PASSWORD }}, KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }} }
        run: |
          KC=$RUNNER_TEMP/app.keychain-db
          echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode -o $RUNNER_TEMP/cert.p12
          security create-keychain -p "$KEYCHAIN_PASSWORD" $KC
          security import $RUNNER_TEMP/cert.p12 -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k $KC
          security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" $KC
          security list-keychain -d user -s $KC
      - name: Sign, zip, notarize
        run: |
          codesign --force --timestamp --options runtime --sign "Developer ID Application" cheapshot
          ditto -c -k --keepParent cheapshot cheapshot-${{ github.ref_name }}-macos.zip
          echo -n "${{ secrets.ASC_KEY_BASE64 }}" | base64 --decode -o AuthKey.p8
          xcrun notarytool submit cheapshot-${{ github.ref_name }}-macos.zip --key AuthKey.p8 --key-id ${{ secrets.ASC_KEY_ID }} --issuer ${{ secrets.ASC_ISSUER }} --wait
      - uses: softprops/action-gh-release@v3
        with: { files: cheapshot-${{ github.ref_name }}-macos.zip }
  tap:
    needs: release
    runs-on: ubuntu-latest
    steps:
      - uses: mislav/bump-homebrew-formula-action@v4
        with:
          formula-name: cheapshot
          homebrew-tap: all-caps-dev/homebrew-tap
          base-branch: main
          download-url: https://github.com/all-caps-dev/cheapshot/releases/download/${{ github.ref_name }}/cheapshot-${{ github.ref_name }}-macos.zip
        env: { COMMITTER_TOKEN: ${{ secrets.COMMITTER_TOKEN }} }
```

## 4. Universal binary: yes, for one more year
Both cross-compiles succeed here (arm64 203 KB, x86_64 178 KB, fat 399 KB). Tahoe is the last Intel macOS; Homebrew moves Intel to Tier 3 in September 2026.

## 5. Framework gotchas
- Current README build stamps minos 26.0. Pass `-target arm64-apple-macos13`. VNRecognizeTextRequest is 10.15+; nothing needs above 13. macOS 13 build verified to OCR correctly.
- No entitlements needed.
- TCC: reading ~/Desktop or ~/Documents prompts Terminal/iTerm once. Over ssh or launchd: no prompt, "Operation not permitted" (fix: Full Disk Access for /usr/libexec/sshd-keygen-wrapper). One README line.

## Not verified
- Exact Tahoe dialog text (Ryan saw it: "Not Opened. Apple could not verify ... is free of malware").
- Whether bump-homebrew-formula-action commits directly or opens a PR.
- `depends_on :macos => :ventura` not brew-audited.

---

# Appendix: 03-agent-integration

# Agent integration (Fable, 2026-09-12)

Bottom line: ship the PreToolUse hook as the flagship, wrap it in a plugin with the skill, ship a thin TypeScript MCP server for every non-Claude-Code host. Do not go paid.

## MCP server
- TypeScript wrapper shelling out to the Swift binary (single source of truth for OCR+redaction). `npx cheapshot-mcp`. stdio only.
- Tools: cheapshot_ocr (paths | newest{dir,count}, raw, min_confidence) -> text + structuredContent (= --json payload); cheapshot_video (path, scene, max_frames, dedupe, raw); cheapshot_ledger (days). Ledger also as MCP resource cheapshot://ledger.
- Deliberately absent: list_rules tool, clipboard OCR tool.

## Claude Code, ranked
1. PreToolUse hook on Read for *.png|jpg|jpeg|webp|gif: run `cheapshot --json --stats`, return permissionDecision "deny" with reason = redacted text + "(1018 -> 37 tokens; re-Read with allow_image=true for layout)". Deny is the only way to keep image bytes out of context. Escape hatch CHEAPSHOT_PASSTHROUGH=1. Document injection risk (OCR text enters context).
2. Plugin bundling hook + generic SKILL.md (rewrite of ~/.claude/skills/screenshot-ocr, drop Ryan-specific paths, add --video) + MCP. One `claude plugin add`.
3. MCP alone: optional by construction, cross-host story only.

## Other hosts
- Cursor: .cursor/mcp.json npx entry + .cursor/rules "OCR before viewing".
- Codex CLI: ~/.codex/config.toml [mcp_servers.cheapshot] + AGENTS.md line.
- OpenClaw-style: ship skill dir + CLI on PATH.
- Raycast: script command wrapping --cleanshot; MCP registry entry.

## Ledger as feature
1. status line segment (`cheapshot: 41.2k saved`), 2. hook stderr one-liner per fire, 3. weekly summary once, 4. local SVG badge. Add `--ledger --json`. No dashboard.

## Free vs paid
Paid is a bad idea: paywall contradicts "no network, no API cost"; every gate fails (video = 60 lines over ffmpeg; MCP must be free; team ledger needs a server). BSL commercial license for redistribution, per product, is the only defensible line.

---

# Appendix: 04-market-scan

# Market scan (Fable, 2026-09-12)

Bottom line: the niche is nearly empty, not empty. Nobody ships on-device OCR + secret redaction + text output for agents as one CLI. Two neighbours are one feature away (mac-ocr, Redaktr); one enterprise cloud MCP (Strac) claims OCR+redact+agent.

## Direct competitors
| Tool | URL | Price | Traction | Does what cheapshot does not |
|---|---|---|---|---|
| mac-ocr (privatenumber) | https://github.com/privatenumber/mac-ocr | Free, MIT | 508 stars, pushed 2026-08-22 | PDFs, stdin/URL input, JSON bboxes, bundled agent skill. README: "instead of spending vision tokens... an agent can run mac-ocr locally." No redaction, no token stats. |
| ocrmac | https://github.com/straussmaximilian/ocrmac | Free | 544 stars | LiveText backend, Python API. No redaction. |
| macos-vision-ocr | https://github.com/bytefer/macos-vision-ocr | Free | 315 stars, stale | Batch + positional output. |
| ocrtool-mcp | https://github.com/ihugang/ocrtool-mcp | Free | 39 stars | MCP stdio server for Claude Desktop/Cursor/Cline. |
| Peekaboo | https://github.com/openclaw/Peekaboo | Free, MIT | 5,149 stars | Agent captures its own screenshots + VQA. Sends pixels. |
| Maus | https://www.mausformac.com/blog/screenshots-claude-tokens-ocr | Free / Pro $12.99 once | unknown | Auto-OCRs copied screenshots into clipboard history. GUI, no redaction. |
| Supamaus Lite | https://lite.supamaus.com/ | $15 launch, $50 after | unknown | Cursor-hover capture into Claude Code via local MCP. |
| deepseek-v4-vision-ocr skill | https://github.com/sjx417/deepseek-v4-vision-ocr | Free | 9 stars | Claude Code skill wrapping Tesseract. |

## Adjacent (redaction)
- Presidio Image Redactor https://microsoft.github.io/presidio/image-redactor/ : OCR + PII, outputs redacted image, no agent hook.
- Redaktr https://redaktr.app/ : $39 one-time, 3 Macs. On-device scan for keys/PII/faces, "clipboard guard" before pasting into Claude. Exports cleaned image, not text. Closest in spirit.
- Strac MCP DLP https://github.com/strac-io/strac-mcp-dlp : 7 stars. OCR + redact + MCP, server-side, enterprise pricing. Cloud, not on-device.
- agent-sweep https://github.com/Ishannaik/agent-sweep : 80 stars, redacts secrets from Claude Code histories after the fact.
- privacyscrubber-mcp, flare-redact: text only.
Verdict: on-device OCR + redaction + text-for-agents is unoccupied.

## Demand signal
1. anthropics/claude-code#27869: "consumed 17% of my 5-hour Max plan usage in just 5 API calls ... no warning that the context is bloated with old screenshot data." https://github.com/anthropics/claude-code/issues/27869
2. anthropics/claude-code#16592 (open, 14 reactions): "no programmatic way to access the raw image data ... from hooks, plugins, or skills." https://github.com/anthropics/claude-code/issues/16592  <- BLOCKS hook interception of PASTED images; file-path Reads still hookable.
3. openai/codex#33235: "Image-heavy multi-agent task replays inherited image context, causing 1.48B tokens, 70.73GB traffic." https://github.com/openai/codex/issues/33235
4. Maus blog: "20 screenshots of terminal output across an hour = 30,000+ tokens just on images."
5. Freshmii: "Screenshots are one of the easiest ways to leak something to an AI." https://freshmii.com/tools/screenshot-redactor/
Unverified: no Reddit thread found.

## Pricing comps
Maus Pro $12.99 once. Redaktr $39 once, 3 Macs. Supamaus Lite $15 launch / $50 list. CleanShot X $35 once + 1yr updates. ccusage: free, 25 sponsors vs $200/mo goal, 18.5k stars (sponsor income is small even for a hit).

## Verdict
1. A product, but small: the $13 to $39 one-time band is real, two Mac apps already in it.
2. Free OSS with a name is right; BSL already covers SaaS wrapping. $15 against 508-star MIT mac-ocr is a hard sell.
3. Defensible edges: redaction-by-default, the ledger, --video. Lead with them, not OCR.
4. Biggest risk: claude-code#16592, pasted images cannot be intercepted; cheapshot stays manual for pastes until that lands.
5. Positioning: "Give your coding agent the words on your screen, not the pixels: on-device OCR that redacts secrets first and shows you the tokens it saved."

---

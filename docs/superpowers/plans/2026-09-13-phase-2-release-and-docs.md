# cheapshot Phase 2: release plumbing and docs site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make cheapshot 0.5.0 shippable: MIT license, CI, a tag-triggered release workflow that signs, notarizes, publishes, and bumps a Homebrew tap, a Starlight docs site under `site/` deployed to GitHub Pages, a README shrunk to install plus one example per feature, and a runbook for the steps only Ryan can do.

**Architecture:** Nothing in `Sources/` changes. Everything lands as repo files: `LICENSE`, `.github/workflows/{ci,release,pages}.yml`, `packaging/homebrew/cheapshot.rb` (the formula's source of truth; the tap repo gets a copy), `site/` (Astro 7 + Starlight + lucode-starlight, content written from the README and the spec), and `docs/release.md` (the runbook). Every task is verifiable locally: YAML parses, the formula passes `ruby -c` and `brew style`, the site builds with `npm run build`, the README shrinks to a measured size.

**Tech Stack:** Swift 6.3 package (unchanged), GitHub Actions on `macos-latest` and `ubuntu-latest`, `softprops/action-gh-release`, `mislav/bump-homebrew-formula-action@v4`, `withastro/action@v6` + `actions/deploy-pages@v5`, Astro 7, `@astrojs/starlight` 0.42, `lucode-starlight`, Node 22+.

**Spec:** `docs/superpowers/specs/2026-09-12-two-products-one-engine-design.md`, sections "Decisions made in the brainstorm" (2: MIT), "Docs site", "Accessibility: CLI and docs", "Build order, revised: Phase 2", "Open questions: Perplexity answer 6 (release plumbing)". The product brief's "Appendix: 02-distribution" holds the original workflow draft; this plan applies the spec's corrections to it.

## Global Constraints

- Never push, never tag, never create a remote repo, never enable GitHub Pages, never touch certificates or secrets. Those are Ryan's hands and are written into `docs/release.md` (Task 8) with full URLs. Every commit stays local on `main`.
- Commit trailers on every commit:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01H5LsU8W6kZBsPzhsqK69NL`. SSH signing through 1Password; on "failed to fill whole buffer" leave the work staged and report the exact `! git commit -F <file>` line.
- License is MIT (spec decision 2). The formula says `license "MIT"`. No file in the repo may still say "Business Source" or "BUSL" after Task 1 except the git history and the spec/brief (historical record, frozen).
- Deployment target stays macOS 13; the release binary is universal and comes from `make build check` (never two `swiftc` runs). `make check` must print `ok: universal, minos 13.0`.
- Formula: `depends_on macos: :ventura` (keyword form), `license "MIT"`, test block asserts the version string. Intel is best-effort (Homebrew Tier 3 since September 2026) and the README says so in one clause.
- `mislav/bump-homebrew-formula-action` is pinned `@v4` (tags v4.0, v4.1, v4.2 verified on 2026-09-12) with `create-pullrequest: false` so it commits directly to the tap when `COMMITTER_TOKEN` can push.
- Docs site: Astro 7, `@astrojs/starlight`, `lucode-starlight`, Node `>=22.12.0`; lives under `site/`; `site: 'https://all-caps-dev.github.io'`, `base: '/cheapshot/'` at the top level of `defineConfig` (never under `vite:`). Deployed by `withastro/action@v6` + `actions/deploy-pages@v5` on push to `main` (paths: `site/**`). Pages content comes from the README and the spec; no page describes a feature that does not exist yet (claude-code and mcp pages arrive in Phase 3).
- Accessibility (spec "CLI and docs"): plain text CLI output unchanged; every image in README and site has non-empty alt text; site passes keyboard navigation and skip link (Starlight built-ins, verified in the built HTML), and the theme's text/background pairs pass WCAG AA via `~/.claude/skills/efficient-burn/scripts/contrast-ratio.sh`.
- README ends Phase 2 at install, one example per feature, exit codes, and a link to the site; under 90 lines.
- Version string stays `0.5.0-dev`. The `v0.5.0` tag is the last line of the runbook, after Ryan's secrets exist and the release workflow is green.
- Free before paid: the only network fetches are `npm install` and one `docs-mirror` of the Starlight docs if an implementer needs it.

---

## File structure

| Path | Responsibility |
|---|---|
| `LICENSE` | MIT text, copyright Ryan Ilano |
| `README.md` | Install, one example per feature, exit codes, link to the site (shrunk in Task 7) |
| `.github/workflows/ci.yml` | `swift test` and `make build check` on push and PR to main |
| `.github/workflows/release.yml` | On `v*` tag: build universal, sign, notarize, GitHub Release, bump the tap |
| `.github/workflows/pages.yml` | On push to main touching `site/**`: build and deploy the docs site |
| `packaging/homebrew/cheapshot.rb` | Formula source of truth; copied into `all-caps-dev/homebrew-tap/Formula/` by the runbook |
| `site/package.json`, `site/astro.config.mjs`, `site/tsconfig.json`, `site/.nvmrc` | Docs site scaffold |
| `site/src/content/docs/*.md` | One page per feature: index, install, use, redaction, ledger, video, pdf, research/video-frames, research/structured-output, research/pdf-pipeline, credits |
| `site/src/content.config.ts` | Starlight content collection |
| `site/public/.nojekyll`, `site/public/favicon.svg` | Pages plumbing |
| `docs/credits.md` | Credits source; the site's credits page is generated from it (Task 6 copies it) |
| `docs/release.md` | Runbook: every Ryan-hand step with its URL, then the tag |
| `.gitignore` | Adds `site/node_modules/`, `site/dist/`, `site/.astro/` |

---

### Task 1: Relicense to MIT

**Files:**
- Modify: `LICENSE` (replace whole file)
- Modify: `README.md:173-215` (License section and the Commercial licensing subsection)
- Delete: `docs/licensing-animated.svg`, `docs/licensing.png` (commercial-licensing QR art, no longer used)

**Interfaces:**
- Consumes: nothing.
- Produces: the string `MIT License` on line 1 of `LICENSE`; README "## License" section of exactly three lines that Task 7 keeps verbatim.

- [x] **Step 1: Write the check that must fail now**

Create `scripts/check-license.sh`:
```bash
#!/bin/sh
# Fails if any tracked file outside the frozen spec/brief still names the old license.
set -e
head -1 LICENSE | grep -q '^MIT License$' || { echo "LICENSE is not MIT"; exit 1; }
hits=$(git ls-files | grep -v -e '^docs/product-brief.md$' -e '^docs/superpowers/' | xargs grep -l -i -e 'Business Source' -e 'BUSL' 2>/dev/null || true)
test -z "$hits" || { echo "old license text in: $hits"; exit 1; }
test ! -e docs/licensing-animated.svg || { echo "licensing-animated.svg still present"; exit 1; }
echo "ok: MIT everywhere"
```
`chmod +x scripts/check-license.sh`.

- [x] **Step 2: Run it to verify it fails**

Run: `scripts/check-license.sh`
Expected: `LICENSE is not MIT`, exit 1.

- [x] **Step 3: Replace LICENSE**

Write `LICENSE` with exactly:
```
MIT License

Copyright (c) 2026 Ryan Ilano

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [x] **Step 4: Replace the README License section**

Delete everything from the line `## License` to the end of the file (it currently runs through the "Commercial licensing" subsection and the `<img src="docs/licensing-animated.svg" ...>` tag) and append:
```markdown
## License

MIT. See [LICENSE](LICENSE). The Mac App Store app that will sit on this engine is a separate, private repo; the engine and the CLI stay MIT.
```

- [x] **Step 5: Delete the QR art and re-run the check**

Run: `git rm -q docs/licensing-animated.svg docs/licensing.png && scripts/check-license.sh`
Expected: `ok: MIT everywhere`.

Also run: `grep -n "licensing" README.md docs/README.md 2>/dev/null` and remove any remaining reference to the deleted files (docs/README.md may index them).

- [x] **Step 6: Commit**

```bash
git add -A LICENSE README.md docs scripts/check-license.sh
git commit -m "license: MIT for the public engine and CLI (spec decision 2)"
```

---

### Task 2: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `scripts/check-workflows.sh`

**Interfaces:**
- Produces: `scripts/check-workflows.sh` that parses every workflow file and asserts the strings later tasks rely on; Tasks 3 and 5 extend its assertion list.

- [x] **Step 1: Write the check**

`scripts/check-workflows.sh`:
```bash
#!/bin/sh
# Parses every workflow and asserts the lines the plan depends on.
set -e
for f in .github/workflows/*.yml; do
  python3 -c "import sys,yaml; yaml.safe_load(open('$f'))" || { echo "$f does not parse"; exit 1; }
done
grep -q 'swift test' .github/workflows/ci.yml || { echo "ci.yml lacks swift test"; exit 1; }
grep -q 'make build check' .github/workflows/ci.yml || { echo "ci.yml lacks make build check"; exit 1; }
echo "ok: workflows parse and carry the required steps"
```
`chmod +x scripts/check-workflows.sh`. If `python3 -c "import yaml"` fails on this Mac, use `ruby -ryaml -e "YAML.load_file('$f')"` instead; Ruby ships with macOS.

- [x] **Step 2: Run it to verify it fails**

Run: `scripts/check-workflows.sh`
Expected: fails because `.github/workflows/` does not exist (glob yields the literal pattern and the parse errors), or `ci.yml lacks swift test`.

- [x] **Step 3: Write ci.yml**

```yaml
name: CI

on:
  push:
    branches: [main]
    paths-ignore: ['site/**', 'docs/**', '**.md']
  pull_request:
    branches: [main]
    paths-ignore: ['site/**', 'docs/**', '**.md']

permissions:
  contents: read

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Swift version
        run: swift --version
      - name: Tests
        run: swift test
      - name: Universal release build and gate
        run: make build check
```

- [x] **Step 4: Run the check**

Run: `scripts/check-workflows.sh`
Expected: `ok: workflows parse and carry the required steps`.

- [x] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml scripts/check-workflows.sh
git commit -m "ci: swift test and the universal-binary gate on every push and PR"
```

---

### Task 3: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `scripts/check-workflows.sh` (add assertions)

**Interfaces:**
- Consumes: `make build check` (Makefile), the seven repository secrets named in the runbook (Task 8): `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `ASC_KEY_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER`, `COMMITTER_TOKEN`.
- Produces: a GitHub Release asset named `cheapshot-<tag>-macos.zip` at `https://github.com/all-caps-dev/cheapshot/releases/download/<tag>/cheapshot-<tag>-macos.zip`, which the formula URL (Task 4) and the bump step both use.

- [x] **Step 1: Extend the check (fails first)**

Append to `scripts/check-workflows.sh` before the final `echo`:
```bash
r=.github/workflows/release.yml
grep -q "tags: \['v\*'\]" $r || { echo "release.yml does not trigger on v* tags"; exit 1; }
grep -q 'make build check' $r || { echo "release.yml must build with make, not swiftc"; exit 1; }
grep -q 'mislav/bump-homebrew-formula-action@v4' $r || { echo "bump action not pinned to v4"; exit 1; }
grep -q 'create-pullrequest: false' $r || { echo "bump action must commit directly"; exit 1; }
grep -q 'xcrun notarytool submit' $r || { echo "release.yml does not notarize"; exit 1; }
grep -q 'softprops/action-gh-release@v2' $r || { echo "release action not pinned to v2"; exit 1; }
grep -q 'homebrew-tap: all-caps-dev/homebrew-tap' $r || { echo "wrong tap"; exit 1; }
```

- [x] **Step 2: Run it to verify it fails**

Run: `scripts/check-workflows.sh`
Expected: `release.yml does not trigger on v* tags` (grep on a missing file), exit 1.

- [x] **Step 3: Verify the action tags exist, then write release.yml**

Run: `gh api repos/softprops/action-gh-release/tags --jq '.[].name' | head -3` and `gh api repos/mislav/bump-homebrew-formula-action/tags --jq '.[].name' | head -3`.
Expected: a `v2` (or `v2.x`) tag for action-gh-release and `v4.2` for the bump action. If action-gh-release has no v2 tag, pin the newest major it does have and update the check in Step 1 to match; record that in the report.

```yaml
name: Release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build universal binary and gate it
        run: make build check

      - name: Import the Developer ID certificate
        env:
          BUILD_CERTIFICATE_BASE64: ${{ secrets.BUILD_CERTIFICATE_BASE64 }}
          P12_PASSWORD: ${{ secrets.P12_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          KC="$RUNNER_TEMP/app.keychain-db"
          echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode -o "$RUNNER_TEMP/cert.p12"
          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
          security set-keychain-settings -lut 21600 "$KC"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
          security import "$RUNNER_TEMP/cert.p12" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KC"
          security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KC"
          security list-keychain -d user -s "$KC"

      - name: Sign, zip, notarize
        env:
          ASC_KEY_BASE64: ${{ secrets.ASC_KEY_BASE64 }}
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER: ${{ secrets.ASC_ISSUER }}
        run: |
          codesign --force --timestamp --options runtime --sign "Developer ID Application" cheapshot
          codesign --verify --verbose=2 cheapshot
          ditto -c -k --keepParent cheapshot "cheapshot-${{ github.ref_name }}-macos.zip"
          echo -n "$ASC_KEY_BASE64" | base64 --decode -o AuthKey.p8
          xcrun notarytool submit "cheapshot-${{ github.ref_name }}-macos.zip" \
            --key AuthKey.p8 --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait
          shasum -a 256 "cheapshot-${{ github.ref_name }}-macos.zip" | tee "cheapshot-${{ github.ref_name }}-macos.zip.sha256"

      - name: GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            cheapshot-${{ github.ref_name }}-macos.zip
            cheapshot-${{ github.ref_name }}-macos.zip.sha256
          generate_release_notes: true

  tap:
    needs: release
    runs-on: ubuntu-latest
    steps:
      - name: Bump the Homebrew formula
        uses: mislav/bump-homebrew-formula-action@v4
        with:
          formula-name: cheapshot
          formula-path: Formula/cheapshot.rb
          homebrew-tap: all-caps-dev/homebrew-tap
          base-branch: main
          create-pullrequest: false
          download-url: https://github.com/all-caps-dev/cheapshot/releases/download/${{ github.ref_name }}/cheapshot-${{ github.ref_name }}-macos.zip
          commit-message: |
            {{formulaName}} {{version}}

            Created by https://github.com/all-caps-dev/cheapshot/actions/runs/${{ github.run_id }}
        env:
          COMMITTER_TOKEN: ${{ secrets.COMMITTER_TOKEN }}
```

Notes for the implementer: the `--sign "Developer ID Application"` identity string works because the keychain holds exactly one such certificate; `notarytool --wait` fails the job on rejection, which is what we want; bare executables cannot be stapled, so there is no `stapler` step (Gatekeeper fetches the ticket online). Nothing in this workflow can be exercised locally; the runbook's dry-run section (Task 8) is where Ryan tests it with a `v0.5.0-rc1` tag.

- [x] **Step 4: Run the check**

Run: `scripts/check-workflows.sh`
Expected: `ok: workflows parse and carry the required steps`.

- [x] **Step 5: Commit**

```bash
git add .github/workflows/release.yml scripts/check-workflows.sh
git commit -m "release: tag-triggered universal build, sign, notarize, GitHub Release, tap bump"
```

---

### Task 4: Homebrew formula (source of truth in this repo)

**Files:**
- Create: `packaging/homebrew/cheapshot.rb`
- Create: `packaging/homebrew/README.md` (three lines: what this file is, where it is copied, who bumps it)
- Create: `scripts/check-formula.sh`

**Interfaces:**
- Consumes: the release asset URL shape from Task 3.
- Produces: the formula the runbook (Task 8) copies into `all-caps-dev/homebrew-tap/Formula/cheapshot.rb`.

- [x] **Step 1: Write the check (fails first)**

`scripts/check-formula.sh`:
```bash
#!/bin/sh
set -e
f=packaging/homebrew/cheapshot.rb
test -f "$f" || { echo "formula missing"; exit 1; }
ruby -c "$f" >/dev/null || { echo "formula does not parse"; exit 1; }
grep -q 'license "MIT"' "$f" || { echo "formula license is not MIT"; exit 1; }
grep -q 'depends_on macos: :ventura' "$f" || { echo "formula must use depends_on macos: :ventura"; exit 1; }
grep -q 'releases/download/v0.5.0/cheapshot-v0.5.0-macos.zip' "$f" || { echo "formula url is wrong"; exit 1; }
grep -q -- '--version' "$f" || { echo "formula test block must run --version"; exit 1; }
if command -v brew >/dev/null; then brew style "$f" || { echo "brew style failed"; exit 1; }; fi
echo "ok: formula"
```
`chmod +x scripts/check-formula.sh`.

- [x] **Step 2: Run it to verify it fails**

Run: `scripts/check-formula.sh`
Expected: `formula missing`, exit 1.

- [x] **Step 3: Write the formula**

`packaging/homebrew/cheapshot.rb`:
```ruby
class Cheapshot < Formula
  desc "On-device screenshot, video, and PDF OCR with redaction, for AI agents"
  homepage "https://github.com/all-caps-dev/cheapshot"
  url "https://github.com/all-caps-dev/cheapshot/releases/download/v0.5.0/cheapshot-v0.5.0-macos.zip"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on macos: :ventura

  def install
    bin.install "cheapshot"
  end

  test do
    assert_match "0.5.0", shell_output("#{bin}/cheapshot --version")
  end
end
```
The `sha256` placeholder is replaced by `bump-homebrew-formula-action` on the first tagged release; the runbook says so. `ffmpeg` is not a dependency: `--video` reports a plain error when ffmpeg is absent, and most users never call it.

`packaging/homebrew/README.md`:
```markdown
# Homebrew formula

`cheapshot.rb` is the source of truth. The runbook in `docs/release.md` copies it to `all-caps-dev/homebrew-tap/Formula/cheapshot.rb` once; after that, `release.yml` bumps `url` and `sha256` in the tap on every `v*` tag. Edit here first, then re-copy.
```

- [x] **Step 4: Run the check**

Run: `scripts/check-formula.sh`
Expected: `ok: formula`. If `brew style` complains about the placeholder sha256 length or a cop, fix the formula, never the check, and note the cop in the report.

- [x] **Step 5: Commit**

```bash
git add packaging scripts/check-formula.sh
git commit -m "packaging: Homebrew formula, MIT, macOS 13 floor, version test"
```

---

### Task 5: Docs site scaffold that builds

**Files:**
- Create: `site/package.json`, `site/astro.config.mjs`, `site/tsconfig.json`, `site/.nvmrc`, `site/src/content.config.ts`, `site/src/content/docs/index.md`, `site/src/content/docs/install.md`, `site/src/content/docs/use.md`, `site/public/.nojekyll`, `site/public/favicon.svg`
- Modify: `.gitignore` (append `site/node_modules/`, `site/dist/`, `site/.astro/`)
- Create: `scripts/check-site.sh`

**Interfaces:**
- Produces: `npm --prefix site run build` succeeds and writes `site/dist/index.html`; the sidebar in `astro.config.mjs` lists every page Task 6 adds, so Task 6 only adds files and sidebar entries.

- [x] **Step 1: Write the check (fails first)**

`scripts/check-site.sh`:
```bash
#!/bin/sh
set -e
cd site
test -f package.json || { echo "site/package.json missing"; exit 1; }
grep -q "base: '/cheapshot/'" astro.config.mjs || { echo "astro base must be /cheapshot/"; exit 1; }
grep -q "site: 'https://all-caps-dev.github.io'" astro.config.mjs || { echo "astro site origin wrong"; exit 1; }
if [ ! -d node_modules ]; then npm ci --no-audit --no-fund; fi
npm run build
test -f dist/index.html || { echo "no dist/index.html"; exit 1; }
test -f dist/.nojekyll || { echo "no dist/.nojekyll"; exit 1; }
grep -q 'href="#_top"' dist/install/index.html || grep -qi 'skip to content' dist/install/index.html || { echo "no skip link in built HTML"; exit 1; }
for p in $(cd src/content/docs && find . -name '*.md' | sed 's|^\./||; s|\.md$||; s|/index$||'); do
  case "$p" in index) t=dist/index.html;; *) t="dist/$p/index.html";; esac
  test -f "$t" || { echo "page $p did not build"; exit 1; }
done
echo "ok: site builds"
```
`chmod +x scripts/check-site.sh`.

- [x] **Step 2: Run it to verify it fails**

Run: `scripts/check-site.sh`
Expected: `site/package.json missing`, exit 1.

- [x] **Step 3: Scaffold**

`site/package.json`:
```json
{
  "name": "cheapshot-docs",
  "type": "module",
  "version": "0.0.1",
  "private": true,
  "engines": { "node": ">=22.12.0" },
  "scripts": {
    "dev": "astro dev",
    "build": "astro build",
    "preview": "astro preview",
    "astro": "astro"
  },
  "dependencies": {
    "@astrojs/starlight": "^0.42.0",
    "astro": "^7.3.0",
    "lucode-starlight": "^1.0.0"
  },
  "devDependencies": {
    "@astrojs/check": "^0.9.9",
    "typescript": "^6.0.3"
  }
}
```
`site/.nvmrc`: `22`. `site/tsconfig.json`: `{ "extends": "astro/tsconfigs/strict" }`.

`site/astro.config.mjs`:
```js
// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import lucode from 'lucode-starlight';

// GitHub Pages project site: origin + repo name. `base` stays at the top level.
export default defineConfig({
  site: 'https://all-caps-dev.github.io',
  base: '/cheapshot/',
  integrations: [
    starlight({
      title: 'cheapshot',
      description: 'On-device OCR for coding agents: the words on your screen, not the pixels, with secrets redacted first.',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/all-caps-dev/cheapshot' }],
      sidebar: [
        { label: 'Install', slug: 'install' },
        { label: 'Use', slug: 'use' },
        { label: 'Redaction', slug: 'redaction' },
        { label: 'Ledger', slug: 'ledger' },
        { label: 'Video', slug: 'video' },
        { label: 'PDF', slug: 'pdf' },
        {
          label: 'Research',
          items: [
            { label: 'Video frames', slug: 'research/video-frames' },
            { label: 'Structured output', slug: 'research/structured-output' },
            { label: 'PDF pipeline', slug: 'research/pdf-pipeline' },
          ],
        },
        { label: 'Credits', slug: 'credits' },
      ],
      plugins: [
        lucode({
          navLinks: [
            { label: 'Install', link: '/install/' },
            { label: 'Use', link: '/use/' },
            { label: 'Credits', link: '/credits/' },
          ],
          footerText: '© 2026 Ryan Ilano. MIT. [Source](https://github.com/all-caps-dev/cheapshot).',
        }),
      ],
    }),
  ],
});
```
If `lucode-starlight@1.x` rejects `navLinks` or `footerText` (its 1.0 API may differ from 0.1.6), first try `npm view lucode-starlight@1 readme | head -80` for the current option names and adapt; if that fails, pin `"lucode-starlight": "^0.1.6"` and note it in the report. Starlight alone (no lucode plugin) is the last fallback and is still spec-compliant, since the accessibility guarantees come from Starlight.

Until Task 6 lands, the sidebar entries for pages that do not exist yet make `astro build` fail. For this task only, keep the sidebar to `install` and `use`; Task 6 extends it as it adds each page.

`site/src/content.config.ts`:
```ts
import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

export const collections = {
  docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
};
```

`site/public/.nojekyll`: empty file. `site/public/favicon.svg`:
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" role="img" aria-label="cheapshot"><title>cheapshot</title><rect width="32" height="32" rx="6" fill="#111"/><text x="16" y="22" font-family="Menlo, monospace" font-size="18" text-anchor="middle" fill="#fff">c$</text></svg>
```

`site/src/content/docs/index.md`:
```markdown
---
title: cheapshot
description: On-device OCR for coding agents. The words on your screen, not the pixels, with secrets redacted first.
template: splash
hero:
  tagline: Give your coding agent the words on your screen, not the pixels. On-device OCR that redacts secrets first and shows you the tokens it saved.
  actions:
    - text: Install
      link: /cheapshot/install/
      icon: right-arrow
    - text: Source on GitHub
      link: https://github.com/all-caps-dev/cheapshot
      icon: external
      variant: minimal
---

cheapshot reads screenshots, screen recordings, and PDFs with Apple's Vision framework, redacts secrets before the text leaves your Mac, and keeps a ledger of the image tokens your agent did not have to pay for. No model in the loop. MIT.
```

`site/src/content/docs/install.md`: the README "Install" section verbatim, plus a Homebrew block:
```markdown
---
title: Install
description: Homebrew tap, or build the universal binary with make.
---

## Homebrew

```sh
brew install all-caps-dev/tap/cheapshot
```

Universal binary (Apple silicon and Intel), notarized, macOS 13 or later. Intel is best-effort: Homebrew moved x86_64 to Tier 3 in September 2026.

## From source

```sh
git clone https://github.com/all-caps-dev/cheapshot
cd cheapshot
make            # builds ./cheapshot and checks it is universal with a macOS 13 floor
sudo make install   # copies to /usr/local/bin
```

`make test` runs the suite. `--video` needs `ffmpeg` on the PATH (`brew install ffmpeg`); everything else is Apple frameworks only.
```

`site/src/content/docs/use.md`: the README "Use" block (the fenced command list) and the exit-codes line, verbatim, under `title: Use`, plus one paragraph per flag group taken from `cheapshot --help` output (run it and paste; do not invent flags).

- [x] **Step 4: Ignore build output and run the check**

Append to `.gitignore`:
```
site/node_modules/
site/dist/
site/.astro/
```
Run: `scripts/check-site.sh`
Expected: `ok: site builds`. First run installs packages; record the versions `npm ls --prefix site --depth=0` prints in the report.

- [x] **Step 5: Commit**

```bash
git add .gitignore site scripts/check-site.sh
git commit -m "site: Starlight docs scaffold under site/, builds for GitHub Pages at /cheapshot/"
```

---

### Task 6: Docs site content, deploy workflow, accessibility check

**Files:**
- Create: `site/src/content/docs/redaction.md`, `ledger.md`, `video.md`, `pdf.md`, `research/video-frames.md`, `research/structured-output.md`, `research/pdf-pipeline.md`, `credits.md`
- Modify: `site/astro.config.mjs` (sidebar back to the full list from Task 5 Step 3)
- Create: `.github/workflows/pages.yml`
- Modify: `scripts/check-workflows.sh` (pages assertions), `scripts/check-site.sh` (contrast and alt-text assertions)
- Modify: `docs/credits.md` (add the Phase 2 dependencies)

**Interfaces:**
- Consumes: Task 5's scaffold and check script.
- Produces: every sidebar slug has a page; `pages.yml` deploys on push to main; `scripts/check-site.sh` is the acceptance gate the final review and the runbook cite.

- [x] **Step 1: Extend the checks (fail first)**

Append to `scripts/check-workflows.sh` before the final `echo`:
```bash
p=.github/workflows/pages.yml
grep -q 'withastro/action@v6' $p || { echo "pages.yml must use withastro/action@v6"; exit 1; }
grep -q 'actions/deploy-pages@v5' $p || { echo "pages.yml must use deploy-pages@v5"; exit 1; }
grep -q "path: ./site" $p || { echo "pages.yml must point withastro/action at ./site"; exit 1; }
grep -q "'site/\*\*'" $p || { echo "pages.yml must trigger on site/** only"; exit 1; }
```
Append to `scripts/check-site.sh` before the final `echo` (still inside `site/`):
```bash
# every image in every page has alt text
if grep -rn '!\[\]' src/content/docs; then echo "image without alt text"; exit 1; fi
if grep -rn '<img' src/content/docs | grep -v 'alt="[^"]\+"'; then echo "img tag without alt"; exit 1; fi
# the theme's body text on its background passes AA in light and dark
cr=$HOME/.claude/skills/efficient-burn/scripts/contrast-ratio.sh
if [ -x "$cr" ]; then
  for pair in $(sed -n 's/^# contrast-pairs: *//p' ../docs/site-colors.txt); do
    fg=${pair%%/*}; bg=${pair##*/}
    "$cr" "$fg" "$bg" | grep -q 'AA.*pass' || { echo "contrast fails for $fg on $bg"; exit 1; }
  done
fi
```
Create `docs/site-colors.txt` after measuring the built CSS (Step 4).

- [x] **Step 2: Run the checks to verify they fail**

Run: `scripts/check-workflows.sh; scripts/check-site.sh`
Expected: `pages.yml must use withastro/action@v6`; then the site check fails on the missing sidebar pages once the sidebar is restored.

- [x] **Step 3: Write the pages**

Restore the full sidebar from Task 5 Step 3 in `astro.config.mjs`.

Each page has frontmatter `title` and `description` and is written from the README section of the same name and the spec; keep the README's wording where it exists, expand only with facts from `cheapshot --help`, the spec, and the research notes. No page mentions the plugin, the MCP server, or the app as available; the index page may say "Phase 3 adds a Claude Code plugin and an MCP server" in one sentence.

- `redaction.md`: the built-in rule table (name, what it matches, validator if any: read `Sources/CheapshotCore/Redaction/Rule.swift` for the names and the golden suite `Tests/CheapshotCoreTests/Golden/cases/` for examples), `--raw`, `--rules` file format `[{"name": "TICKET", "pattern": "\\bINT-\\d{6}\\b", "caseInsensitive": true}]`, custom rules run first, the note that no rule spans a line, the `--text -` stdin mode, and the injection note from the README ("The other thing it is for").
- `ledger.md`: the location rule (`$CHEAPSHOT_HOME/ledger.jsonl`, else `~/Library/Application Support/cheapshot/ledger.jsonl`), one JSON line example with the `mode` values `image`, `pdf`, `video`, `--ledger`, `--ledger --json`, `--ledger --migrate` and its marker, `--no-ledger`, and that PDF page numbers are estimates.
- `video.md`: `--video`, the ffmpeg chain verbatim from the spec (`fps=4,mpdecimate=hi=64*12:lo=64*5:frac=0.1,select=eq(n\,0)+gt(scene\,T),metadata=print:file=-` with `-fps_mode vfr`), `--scene`, `--max-frames`, `--dedupe`, the timestamped transcript shape, ffmpeg requirement.
- `pdf.md`: text lane and scan lane, `--pages N-M`, `--json` additions (`source.sha256`, `pages[].lane`, `width`, `height`, per-line `bbox` in PDF points for the text lane and pixels for the scan lane, unrotated page space for text-lane boxes), password-protected files are errors, `--- page N ---` separators.
- `research/video-frames.md`, `research/structured-output.md`, `research/pdf-pipeline.md`: `docs/research/2026-09-12-*.md` copied verbatim under a frontmatter block with `title` and `description`, plus one line at the top: "Research note from 2026-09-12, kept as written."
- `credits.md`: `docs/credits.md` body under frontmatter, after Step 5 updates the source.

- [x] **Step 4: Write pages.yml, measure colours**

`.github/workflows/pages.yml`:
```yaml
name: Docs site

on:
  push:
    branches: [main]
    paths: ['site/**', '.github/workflows/pages.yml']
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: withastro/action@v6
        with:
          path: ./site
          node-version: 22

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v5
```

Measure the theme: build the site, then in `site/dist/_astro/*.css` find the body text colour and page background for the light and dark palettes (Starlight variables `--sl-color-text` and `--sl-color-bg`, or lucode's overrides). Write `docs/site-colors.txt`:
```
# Body text on page background for the docs theme, light then dark. Measured from site/dist CSS on the date below.
# measured: 2026-09-13
# contrast-pairs: #RRGGBB/#RRGGBB #RRGGBB/#RRGGBB
```
with the real hex values. If a pair fails AA, override the failing variable in `site/src/styles/custom.css`, add it to `starlight({ customCss: ['./src/styles/custom.css'] })`, rebuild, re-measure.

- [x] **Step 5: Update docs/credits.md**

Under "## Docs site" add lines for `withastro/action`, `actions/deploy-pages`, `actions/checkout`, `softprops/action-gh-release`, and pin the measured `lucode-starlight` version. Under a new "## Distribution" heading list GitHub Actions, GitHub Pages, GitHub Releases, Apple notarization (`notarytool`). Then copy the body into `site/src/content/docs/credits.md`.

- [x] **Step 6: Run the checks**

Run: `scripts/check-workflows.sh && scripts/check-site.sh`
Expected: both print their `ok:` lines. Also run `npm --prefix site run preview -- --host 127.0.0.1 --port 4321 &` and `curl -s http://127.0.0.1:4321/cheapshot/pdf/ | grep -c '<h1'` (expect 1), then kill the preview.

- [x] **Step 7: Commit**

```bash
git add site docs/credits.md docs/site-colors.txt .github/workflows/pages.yml scripts
git commit -m "site: feature pages, research notes, credits; Pages deploy workflow; contrast and alt-text gates"
```

---

### Task 7: README shrinks to install, one example per feature, and a link

**Files:**
- Modify: `README.md`
- Create: `scripts/check-readme.sh`

**Interfaces:**
- Consumes: the site URL `https://all-caps-dev.github.io/cheapshot/` (Task 5), the License section from Task 1 (kept verbatim).

- [x] **Step 1: Write the check (fails first)**

`scripts/check-readme.sh`:
```bash
#!/bin/sh
set -e
n=$(wc -l < README.md)
test "$n" -le 90 || { echo "README is $n lines, limit 90"; exit 1; }
grep -q 'https://all-caps-dev.github.io/cheapshot/' README.md || { echo "README does not link the docs site"; exit 1; }
for h in '## Install' '## Use' '## Redaction' '## Video' '## PDF' '## Ledger' '## License'; do
  grep -q "^$h" README.md || { echo "README lacks section $h"; exit 1; }
done
grep -q 'brew install all-caps-dev/tap/cheapshot' README.md || { echo "README lacks the brew line"; exit 1; }
grep -q 'Exit codes: 0 ok, 1 an input failed' README.md || { echo "README lacks the exit-code line"; exit 1; }
if grep -n '!\[\]' README.md; then echo "image without alt text"; exit 1; fi
echo "ok: README $n lines"
```
`chmod +x scripts/check-readme.sh`.

- [x] **Step 2: Run it to verify it fails**

Run: `scripts/check-readme.sh`
Expected: `README is 1xx lines, limit 90` (or the missing site link), exit 1.

- [x] **Step 3: Rewrite the README**

Keep, in this order: the title and the positioning line ("Give your coding agent the words on your screen, not the pixels: on-device OCR that redacts secrets first and shows you the tokens it saved."), a two-sentence "Why", `## Install` (brew line, then `make` and `sudo make install`, one clause on Intel best-effort, one clause on ffmpeg for `--video`), `## Use` with exactly these examples:
```bash
cheapshot shot.png                 # OCR one file, redacted
cheapshot --json shot.png          # text, lines with boxes, redaction counts
cheapshot --cleanshot              # newest CleanShot capture (falls back to ~/Desktop)
cat notes.txt | cheapshot --text - # redact text, no OCR
```
then the line `Exit codes: 0 ok, 1 an input failed (its --json entry carries "error"), 2 usage error.`, then one example plus one sentence each for `## Redaction` (`--rules my-rules.json shot.png` and the JSON shape), `## Video` (`--video screen.mp4`), `## PDF` (`--pages 3-5 report.pdf`), `## Ledger` (`--ledger` and the location rule in one line), a `## Docs` section with the single link `https://all-caps-dev.github.io/cheapshot/` ("every flag, the rule table, the ledger format, and the research notes"), and the Task 1 `## License` section verbatim. Everything else moves to the site (it already lives there after Task 6); delete it from the README.

- [x] **Step 4: Run the check and the site check**

Run: `scripts/check-readme.sh && scripts/check-site.sh`
Expected: `ok: README NN lines` and `ok: site builds` (the site does not read the README at build time, but Task 6's pages were written from it; confirm nothing on the site links to a README anchor that no longer exists: `grep -rn 'README.md#' site/src` must be empty).

- [x] **Step 5: Commit**

```bash
git add README.md scripts/check-readme.sh
git commit -m "docs: README shrinks to install, one example per feature, and the site link"
```

---

### Task 8: Release runbook and the Phase 2 acceptance sweep

**Files:**
- Create: `docs/release.md`
- Create: `scripts/check-phase2.sh` (runs every check script)
- Modify: `docs/superpowers/plans/2026-09-13-phase-2-release-and-docs.md` (tick every box)

**Interfaces:**
- Consumes: every earlier task's check script.
- Produces: the list of Ryan-hand steps with URLs, in order, each with its verification, ending at the `v0.5.0` tag.

- [x] **Step 1: Write the aggregate check (fails first on nothing; it must pass)**

`scripts/check-phase2.sh`:
```bash
#!/bin/sh
set -e
scripts/check-license.sh
scripts/check-workflows.sh
scripts/check-formula.sh
scripts/check-readme.sh
scripts/check-site.sh
swift test 2>&1 | grep -E "Executed|error" | tail -2
make build check
test -f docs/release.md || { echo "runbook missing"; exit 1; }
grep -q 'git tag v0.5.0' docs/release.md || { echo "runbook lacks the tag step"; exit 1; }
echo "ok: phase 2"
```
`chmod +x scripts/check-phase2.sh`. Run it: expected failure `runbook missing`.

- [x] **Step 2: Write docs/release.md**

Plain writing, no em dashes, every step names RYAN or AGENT, has a verification, and carries the full URL. Content:

```markdown
# Release runbook: v0.5.0

Everything below is a hand step for Ryan unless marked AGENT. Do them in order. Nothing in this repo pushes, tags, or creates remote things on its own.

## 0. Preconditions (AGENT, done in Phase 2)
- `scripts/check-phase2.sh` prints `ok: phase 2` on a clean main.
- `main` is ahead of `origin/main` by the Phase 1 and Phase 2 commits, unpushed.

## 1. Push main (RYAN, 1 minute)
`git push origin main`. Verify: https://github.com/all-caps-dev/cheapshot/actions shows the CI workflow green.

## 2. Apple Developer Program for the LLC (RYAN, up to a week of waiting)
1. D-U-N-S lookup or request for `ALL CAPS RESEARCH & DESIGN LLC`, 418 Broadway Ste N, Albany NY 12207: https://developer.apple.com/enroll/duns-lookup/
2. Enroll as an organization with the LLC Apple Account: https://developer.apple.com/programs/enroll/ ($99/yr). Legal name must match the Articles exactly.
3. Verify: https://developer.apple.com/account shows the team with a Team ID.

## 3. Developer ID Application certificate (RYAN, 10 minutes)
1. On the mini, Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority, saved to disk.
2. https://developer.apple.com/account/resources/certificates/add > Developer ID Application > upload the request > download the .cer > double-click to install.
3. Verify: `security find-identity -v -p codesigning` lists `Developer ID Application: ALL CAPS RESEARCH & DESIGN LLC (TEAMID)`.
4. Export: Keychain Access > My Certificates > right-click the certificate > Export as .p12 with a password. Keep the password for step 5.

## 4. App Store Connect API key for notarization (RYAN, 5 minutes)
1. https://appstoreconnect.apple.com/access/integrations/api > Generate API Key, name `cheapshot-notary`, access Developer.
2. Download the `.p8` once (it cannot be downloaded again). Note the Key ID and the Issuer ID shown on that page.
3. Verify locally: `xcrun notarytool history --key AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER` returns without an auth error.

## 5. Repository secrets (RYAN, 5 minutes; paste values, never into chat)
Run from the folder holding the .p12 and .p8:
```sh
gh secret set BUILD_CERTIFICATE_BASE64 -R all-caps-dev/cheapshot -b "$(base64 -i cheapshot-devid.p12)"
gh secret set P12_PASSWORD -R all-caps-dev/cheapshot
gh secret set KEYCHAIN_PASSWORD -R all-caps-dev/cheapshot -b "$(openssl rand -hex 16)"
gh secret set ASC_KEY_BASE64 -R all-caps-dev/cheapshot -b "$(base64 -i AuthKey_KEYID.p8)"
gh secret set ASC_KEY_ID -R all-caps-dev/cheapshot -b "KEYID"
gh secret set ASC_ISSUER -R all-caps-dev/cheapshot -b "ISSUER"
```
Verify: `gh secret list -R all-caps-dev/cheapshot` shows six names.

## 6. Tap repo and committer token (RYAN, 10 minutes)
1. `gh repo create all-caps-dev/homebrew-tap --public --description "Homebrew tap for cheapshot" --clone`
2. `mkdir -p homebrew-tap/Formula && cp packaging/homebrew/cheapshot.rb homebrew-tap/Formula/ && (cd homebrew-tap && git add Formula && git commit -m "cheapshot 0.5.0 formula" && git push)`
3. Fine-grained PAT for the bump step: https://github.com/settings/personal-access-tokens/new , resource owner all-caps-dev, repository access only `homebrew-tap`, permissions Contents: read and write, Metadata: read. Expiry one year.
4. `gh secret set COMMITTER_TOKEN -R all-caps-dev/cheapshot` and paste the token.
Verify: `gh secret list -R all-caps-dev/cheapshot` shows seven names.

## 7. GitHub Pages (RYAN, 2 minutes)
https://github.com/all-caps-dev/cheapshot/settings/pages > Build and deployment > Source: GitHub Actions. Then https://github.com/all-caps-dev/cheapshot/actions/workflows/pages.yml > Run workflow. Verify: https://all-caps-dev.github.io/cheapshot/ loads, the sidebar has Install through Credits, and Tab from the top of the page reaches the "Skip to content" link first.

## 8. Dry run with a release candidate (RYAN, 15 minutes)
```sh
git tag v0.5.0-rc1 && git push origin v0.5.0-rc1
```
Watch https://github.com/all-caps-dev/cheapshot/actions/workflows/release.yml . Expected: the release job signs, notarizes (`status: Accepted`), and publishes https://github.com/all-caps-dev/cheapshot/releases/tag/v0.5.0-rc1 ; the tap job commits to homebrew-tap. Then on a second Mac or a fresh user: `brew install all-caps-dev/tap/cheapshot && cheapshot --version`. If anything fails, fix the workflow here, delete the rc release and tag (`gh release delete v0.5.0-rc1 -y && git push --delete origin v0.5.0-rc1 && git tag -d v0.5.0-rc1`), and repeat.

## 9. Version and tag (AGENT then RYAN)
1. AGENT: set `cheapshotVersion` to `0.5.0`, update `testVersionConstant`, `swift test`, commit `version: 0.5.0`. (The version string is `0.5.0-dev` until this step by spec.)
2. RYAN: `git push origin main && git tag v0.5.0 && git push origin v0.5.0`. Verify: the release page has `cheapshot-v0.5.0-macos.zip`, the tap formula's `url` points at v0.5.0 and its `sha256` is no longer the placeholder, and `brew upgrade cheapshot` on the test Mac reports 0.5.0.

## Open decision carried
Bundle id hyphen (dev.all-caps.cheapshot vs dev.allcaps.cheapshot) is not needed for the CLI; decide it when the app's App ID is created in Phase 4.
```

- [x] **Step 3: Run the aggregate check**

Run: `scripts/check-phase2.sh`
Expected: every `ok:` line, the test count, `ok: universal, minos 13.0`, `ok: phase 2`.

- [x] **Step 4: Tick the plan and commit**

Change every `- [ ]` at the start of a line in this plan file to `- [x]` (line-start checkboxes only; leave the two literal code spans alone).

```bash
git add docs/release.md scripts/check-phase2.sh docs/superpowers/plans/2026-09-13-phase-2-release-and-docs.md
git commit -m "docs: release runbook for v0.5.0 and the Phase 2 acceptance sweep; plan complete"
```

---

## Self-review notes (done while writing)

- Spec coverage: decision 2 MIT (Task 1); "Docs site" pages install, use, redaction, ledger, video, pdf, the research notes, credits (Tasks 5, 6); claude-code and mcp pages deferred to Phase 3 by ruling since the features do not exist; README shrink (Task 7); Perplexity answer 6 corrections a, b, c (Tasks 3, 4, 7); Accessibility "CLI and docs" 5 (alt text, checked in Tasks 6 and 7), Starlight keyboard and skip link (Task 5 check), contrast (Task 6); Build order Phase 2 items cert, workflow, tap, tag (Tasks 3, 4, 8 runbook). Credits page current (Task 6 Step 5).
- Not in this plan, by ruling: the bundle id decision (Phase 4), the deferred Phase 2 minors on the Roadmap board (each stays a card; none blocks a release), AVFoundation source, plugin, MCP.
- Type consistency: the release asset name `cheapshot-<tag>-macos.zip` is identical in release.yml (Task 3), the formula url (Task 4), and the runbook (Task 8). The site origin and base are identical in Task 5's config, Task 5's check, and Task 7's README link. Check-script names are referenced only after the task that creates them.
- Placeholder scan: the `sha256` placeholder in the formula is deliberate and documented; every other step carries its content.

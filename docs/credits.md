# Credits and thanks

Everything cheapshot stands on, with links. Add a line whenever a dependency, tool, or borrowed idea arrives.

## Runs on

- [Apple Vision](https://developer.apple.com/documentation/vision) for on-device text recognition (`VNRecognizeTextRequest`).
- [PDFKit](https://developer.apple.com/documentation/pdfkit) for the PDF text lane.
- [CryptoKit](https://developer.apple.com/documentation/cryptokit) for `source.sha256`.
- [FFmpeg](https://ffmpeg.org/) for scene detection in `--video` (`select`, `mpdecimate`, `metadata`, `-fps_mode vfr`).
- [Swift](https://www.swift.org/) and [Swift Package Manager](https://www.swift.org/documentation/package-manager/).
- [XCTest](https://developer.apple.com/documentation/xctest).

## Built with

- [Claude Code](https://claude.com/claude-code) and the [superpowers](https://github.com/obra/superpowers) skills (brainstorming, writing-plans, subagent-driven-development).
- [Perplexity](https://www.perplexity.ai/) for the five spec research questions.
- [Homebrew](https://brew.sh/) and [mislav/bump-homebrew-formula-action](https://github.com/mislav/bump-homebrew-formula-action) for distribution.
- [1Password](https://1password.com/) for SSH commit signing.

## Docs site

- [Astro](https://astro.build/) and [Starlight](https://starlight.astro.build/).
- [lucode-starlight](https://www.npmjs.com/package/lucode-starlight) 1.0.0, the theme.
- [ryanilano/subfolio-astro-docs](https://github.com/ryanilano/subfolio-astro-docs) for the config and Pages workflow.
- [withastro/action](https://github.com/withastro/action) builds and uploads the site.
- [actions/deploy-pages](https://github.com/actions/deploy-pages) publishes it to GitHub Pages.
- [actions/checkout](https://github.com/actions/checkout) in every workflow.

## Distribution

- [GitHub Actions](https://github.com/features/actions) builds, tests, signs, and notarizes.
- [GitHub Pages](https://pages.github.com/) hosts the docs site.
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github) carries the notarized zip.
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release) creates the release the docs link to.
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) with `notarytool`.

## Prior art and neighbours

- [mac-ocr](https://github.com/privatenumber/mac-ocr) by privatenumber: the closest neighbour, and the source of the "save vision tokens" framing.
- [ocrmac](https://github.com/straussmaximilian/ocrmac), [macos-vision-ocr](https://github.com/bytefer/macos-vision-ocr), [ocrtool-mcp](https://github.com/ihugang/ocrtool-mcp), [Peekaboo](https://github.com/openclaw/Peekaboo).
- [Maus](https://www.mausformac.com/), [Supamaus Lite](https://lite.supamaus.com/), [Redaktr](https://redaktr.app/): the Mac apps in the same space.
- [Presidio Image Redactor](https://microsoft.github.io/presidio/image-redactor/), [agent-sweep](https://github.com/Ishannaik/agent-sweep), [Strac MCP DLP](https://github.com/strac-io/strac-mcp-dlp).
- [ffmpeg-skill](https://github.com/MastroMimmo/ffmpeg-skill) by MastroMimmo, and [ffmpeg-analyse-video-skill](https://github.com/fabriqaai/ffmpeg-analyse-video-skill).

## Ideas borrowed

- Indentation from bounding boxes: [nikl, "We fine-tuned our OCR to read code"](https://dev.to/nikl/we-fine-tuned-our-ocr-to-read-code-heres-what-it-took-and-what-broke-4jb8) and the Tesseract discussion in [tesseract#2071](https://github.com/tesseract-ocr/tesseract/issues/2071).
- Markdown plus a JSON sidecar as the LLM payload: [Docling](https://github.com/docling-project/docling), [Marker](https://github.com/datalab-to/marker), [MinerU](https://github.com/opendatalab/MinerU), [olmOCR](https://github.com/allenai/olmocr), [Unstructured](https://docs.unstructured.io/open-source/concepts/document-elements), [Reducto](https://docs.reducto.ai/parse/overview), [Chunkr](https://github.com/lumina-ai-inc/chunkr).
- Token-format measurements: [formatarc, Markdown vs HTML for LLMs](https://formatarc.com/en/blog/markdown-vs-html-for-llms/) and [improvingagents.com, best input data format](https://www.improvingagents.com/blog/best-input-data-format-for-llms/).
- Frame dedupe by text hash: [US patent 11582509](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11582509).
- Apple's document APIs: [RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest), [DocumentObservation](https://developer.apple.com/documentation/vision/documentobservation), [WWDC25 session 272](https://developer.apple.com/videos/play/wwdc2025/272/), [VNGenerateImageFeaturePrintRequest](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest), [AVAssetImageGenerator](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator).

## Demand signals that shaped the product

- [anthropics/claude-code#27869](https://github.com/anthropics/claude-code/issues/27869) and [#16592](https://github.com/anthropics/claude-code/issues/16592).
- [openai/codex#33235](https://github.com/openai/codex/issues/33235).
- [Freshmii, screenshot redactor](https://freshmii.com/tools/screenshot-redactor/).

The full source lists live in `docs/research/`.

# Document-structuring frameworks vs plain OCR lines (Fable research agent, 2026-09-12)

Question: which document structuring frameworks output better data per token for LLM use, and what should cheapshot adopt. Decision taken from this report lives in docs/superpowers/specs/2026-09-12-two-products-one-engine-design.md, "Structured output".

## Framework table

| Framework | Output | Structure kept | Where | License | Token / accuracy claim |
|---|---|---|---|---|---|
| Docling (IBM) | Markdown, HTML, lossless JSON, DocTags | reading order, tables, code, formulas, bbox | local, CPU ok | MIT | Docling report has no token or accuracy numbers, only speed [1] |
| SmolDocling / DocTags | DocTags (XML-like) | layout, bbox, code keeps tabs and line breaks | local, 256M VLM | CC-BY paper; model Apache | "HTML or Markdown... increasing total tokens count", unquantified [2] |
| Marker (Datalab) | Markdown, JSON tree, HTML, chunks | tables, forms, code blocks, LaTeX, bbox | local, GPU or llama.cpp | code Apache 2.0, weights OpenRAIL-M (<$5M rev) | 76.0 olmOCR-bench [3] |
| MinerU 2.5 | Markdown, position-aware JSON | reading order, bbox, tables as HTML, LaTeX | local, CPU/MPS | Apache-based custom | 75.2 olmOCR-bench [4][5] |
| olmOCR 2 | Markdown, Dolma JSONL | reading order, headers/footers stripped | 7B VLM, 12 GB VRAM | Apache 2.0 | 82.4 olmOCR-bench, machine-checkable unit tests [5] |
| Chandra 2 (Datalab) | Markdown, HTML, JSON | layout, tables, forms | local VLM | OpenRAIL-M (<$2M) | 85.8 olmOCR-bench [6] |
| PyMuPDF4LLM | Markdown, JSON, text | headings, multi-column, tables, page chunks | local, C engine | AGPL / commercial | none measured [7] |
| Unstructured | JSON elements (Title, ListItem, Table, CodeSnippet...) with coordinates, text_as_html | element types, page, parent_id | local (Tesseract) or cloud | Apache 2.0 | none [8] |
| LlamaParse | Markdown, text, JSON, optional layout bbox | tables, headings | cloud only | proprietary, credits | none measured [9] |
| Reducto | JSON chunks; blocks with type, bbox, confidence; content as Markdown | layout-aware chunks | cloud only | proprietary | none in docs [10] |
| Chunkr | JSON segments with bbox, HTML, Markdown | segment types, reading order | self-host or cloud | AGPL-3.0 / commercial | none [11] |
| Nougat (Meta) | Mathpix Markdown | academic layout, LaTeX | local GPU | MIT code, CC-BY-NC weights | arXiv/PMC only [12] |
| Mistral OCR 3 | Markdown with HTML tables, JSON, bbox | tables, forms | cloud ($2/1k pages), self-host option | proprietary | 72.0 olmOCR-bench; "74% win rate" is self-reported [13][5] |
| DeepSeek-OCR | Markdown | layout | 3B local | MIT | 97% decode at <10x vision-token compression; about vision tokens, not text output [14] |

Pattern: every serious entrant converged on Markdown for the LLM plus a JSON sidecar with block type and bbox. Nobody ships plain lines.

## Apple on-device structured output

- `RecognizeDocumentsRequest` -> `[DocumentObservation]`: macOS 26.0 / iOS 26.0. `DocumentObservation.Container` exposes `paragraphs`, `tables`, `lists`, `barcodes`, `title`, `text`. `Container.Table` has `rows: [[Cell]]`, `columns`, `cell(row:col:)`; `Cell` has `rowRange`, `columnRange`, `content`. `Container.Text` has `transcript`, `lines`, `words`, `detectedData` (emails, phones, URLs, dates, currency, tracking numbers), `textAlignment`. `Container.List` has `items` and `Marker`. Options: `TextRecognitionOptions` (`customWords`, `useLanguageCorrection`, `minimumTextHeightFraction`). [15][16][17]
- No Markdown or JSON export from Apple; you serialize yourself. mac-ocr already does this on 26+. [20]
- `VideoProcessor` (macOS 15+) runs any Vision request over a movie at a chosen `Cadence`. [18]
- `VNDetectDocumentSegmentationRequest` (macOS 12+): returns only a quad and saliency mask. Useful for photos of screens, not screenshots. [19]
- `VNRecognizedTextObservation` (macOS 10.15+) and `VNRecognizedText.boundingBox(for:)` give per-line and per-range boxes. Apple says boxes are "not an exact fit", fine for indentation estimation, not pixel work.
- PDFKit `PDFPage.string` and `attributedString` extract the text layer with fonts, which gives free monospace detection for PDF input.
- All on-device, no entitlements, runs in the App Store sandbox.

## Token-efficiency evidence: measured vs claimed

Measured:
- Markdown vs HTML on one synthetic doc, tiktoken cl100k and o200k: -70.8% / -70.4% tokens; plain text -74.4%. [21]
- 1,000 records, 1,000 lookups, GPT-4.1-nano: Markdown-KV 60.7% at 52k tokens, Markdown table 51.9% at 25k, JSON 52.3% at 66k, HTML 53.6% at 75k, CSV 44.3% at 19k. Single model, single task, flat records. [22]
- High CER/WER accuracy does not predict RAG QA accuracy; structural errors cause retrieval failures at low CER. [23]
- olmOCR-bench scores above are measured, machine-checkable. [5]

Claimed only:
- DocTags "increasing total tokens count" vs Markdown has no number in the paper or model card. [2]
- Reducto, LlamaParse, Chunkr, Mistral "LLM-ready" / win-rate language has no public token or QA data.

Net: Markdown tables and light structure buy measurable accuracy over CSV-like dumps; JSON and HTML cost 1.3 to 3x tokens for no accuracy gain. Nobody has measured formats on screenshots of code.

## What transfers to screenshot OCR (ranked)

1. Indentation from bounding boxes. Generic OCR drops leading whitespace (Tesseract closed it "not planned" [24]); the fix used in practice is x-offset divided by estimated glyph width [25]. Swift: `cellWidth = median(obs.boundingBox.width / text.count)` over lines; `indent = round((obs.boundingBox.minX - blockMinX) / cellWidth)`. macOS 13.
2. Monospace block detection and code fences. If glyph width variance across a run of lines is near zero, it is a terminal or editor; wrap in a fence. Marker, Docling, Unstructured all emit a code element [3][8]. Swift: variance of per-line width/count under 8%, plus `useLanguageCorrection = false` for that region. macOS 13.
3. Markdown tables for column-aligned output (`ls -l`, `docker ps`, `kubectl get`). Measured Markdown-table win over CSV/HTML [22]. Swift on 13: cluster word minX across lines into columns (gap > 2 cells); on 26: `Container.Table.rows`.
4. Frame dedup and diff for recordings. Prior art uses pHash plus text hash to collapse near-identical frames, then fuzzy text diff between key frames [26]. Swift: `VNGenerateImageFeaturePrintRequest` distance (macOS 10.15) or dHash via CoreImage, then emit only added lines with `@t=12.4s` markers. macOS 13; `VideoProcessor` cadence on 15+.
5. Strip repeated chrome. olmOCR and MinerU remove headers/footers [4][5]. Swift: lines whose text and box repeat in >80% of frames (menu bar, tab strip, status bar) move to a one-line `chrome:` header. macOS 13.
6. Line-addressable sidecar. Every framework pairs Markdown with a JSON block list carrying bbox and type [10][11]. Swift: `--json` emitting `{line, text, bbox, block, frame}` so an agent can quote L42. macOS 13. On 26, add `detectedData` as tagged entities.

## Do not adopt

- Reading-order and multi-column solvers, LaTeX formula recognition, header/footer classifiers trained on paper, Nougat entirely. Screenshots are already single-column and axis-aligned.
- DocTags as an output format: unquantified token claim, and no coding agent reads it.
- Any VLM parser (olmOCR, Chandra, MinerU-VLM, DeepSeek-OCR): needs a GPU or multi-GB weights, kills the sandbox and the token-saving premise.
- `VNDetectDocumentSegmentationRequest` for screenshots; it only finds paper edges.
- HTML tables and full JSON as the primary payload: 1.3 to 3x tokens, no measured accuracy gain.

## Sources

1. https://arxiv.org/html/2501.17887
2. https://arxiv.org/html/2503.11576v1
3. https://github.com/datalab-to/marker
4. https://github.com/opendatalab/MinerU
5. https://github.com/allenai/olmocr
6. https://huggingface.co/datalab-to/chandra-ocr-2
7. https://pymupdf.readthedocs.io/en/latest/pymupdf4llm/index.html
8. https://docs.unstructured.io/open-source/concepts/document-elements
9. https://developers.llamaindex.ai/python/cloud/llamaparse/getting_started
10. https://docs.reducto.ai/parse/overview
11. https://github.com/lumina-ai-inc/chunkr
12. https://github.com/facebookresearch/nougat
13. https://mistral.ai/news/mistral-ocr-3
14. https://arxiv.org/abs/2510.18234
15. https://developer.apple.com/documentation/vision/recognizedocumentsrequest
16. https://developer.apple.com/documentation/vision/documentobservation
17. https://developer.apple.com/videos/play/wwdc2025/272/
18. https://developer.apple.com/documentation/vision/videoprocessor
19. https://developer.apple.com/documentation/vision/vndetectdocumentsegmentationrequest
20. https://github.com/privatenumber/mac-ocr
21. https://formatarc.com/en/blog/markdown-vs-html-for-llms/
22. https://www.improvingagents.com/blog/best-input-data-format-for-llms/
23. https://arxiv.org/abs/2605.00911
24. https://github.com/tesseract-ocr/tesseract/issues/2071
25. https://dev.to/nikl/we-fine-tuned-our-ocr-to-read-code-heres-what-it-took-and-what-broke-4jb8
26. https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11582509

Apple OS minimums were read from the developer.apple.com doc JSON endpoints: `RecognizeDocumentsRequest` and all `DocumentObservation` types list macOS 26.0, `VideoProcessor` macOS 15.0, `VNDetectDocumentSegmentationRequest` macOS 12.0.

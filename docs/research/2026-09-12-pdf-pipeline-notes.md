# PDF knowledge-base pipeline notes (pasted by Ryan, 2026-09-12, external source)

Architecture notes Ryan pasted into the cheapshot brainstorm. They describe a Docling-centred document pipeline for a local RAG knowledge base. The spec's "PDF input" section records which parts apply to cheapshot (PDF as an input type, page locators, SHA-256 provenance, tables as Markdown plus row JSON) and which belong to a separate knowledge-base project (parser, chunker, embeddings, search, storage, orchestration, retrieval tools). Kept verbatim below for that project.

---

For your stack, I'd use **Docling as the canonical PDF-to-structured-data layer**, then build a small "document contract" around its output for chunking, retrieval, citations, and agent tools. It is a strong fit for local/self-hosted workflows because it understands layout, reading order, tables, formulas, and OCR, and can export structured Markdown, JSON, and context-aware chunks rather than flattening a PDF into unreliable plain text. https://docling.ai/

## The practical framework

Think of a PDF pipeline as four distinct artifacts, not one text extraction step: Original PDF -> Structured document -> Agent chunks -> Search + tools.

| Layer | Canonical output | Why agents need it |
|---|---|---|
| Source preservation | Original PDF + SHA-256 hash | Audit, reprocess, prove where an answer came from |
| Document understanding | Docling JSON / DocLang | Pages, headings, reading order, tables, figures, captions, coordinates |
| Human-readable representation | Markdown | Inspect, version, diff, feed into coding/research workflows |
| Retrieval representation | Semantic chunks + metadata + embeddings | Retrieve just the relevant section with precise citations |
| Structured facts | JSON/CSV validated against schemas | Tables, requirements, entities, deadlines, specs, numeric values reliably queryable |

Key principle: do not treat Markdown or embeddings as the source of truth. Keep the parser's structured output as canonical, derive everything else from it, and preserve a link back to the PDF page and bounding region.

## Recommended architecture

### 1. Ingest and classify
Store the untouched source in versioned storage. Compute SHA-256. Detect native text vs scanned, table-heavy, slide-like, form, contract, paper, spec. Save filename, source URL, ingestion time, MIME type, page count, author and date. Classification picks the parsing profile.

### 2. Parse into a rich document model
Docling `DocumentConverter().convert(path)`, then `export_to_markdown()` and the JSON export. Pin the library version and wrap it behind a `parse_document()` interface. Retain the document object, not only the Markdown.

## Agent-friendly data contract
One JSON record per chunk: `chunk_id` (sha256 + section + chunk), `document_id`, `document_title`, `source` {filename, uri, sha256, page_start, page_end, locator {section_path, bbox}}, `content` {markdown, plain_text, content_type, tables, figures}, `retrieval` {embedding_text, token_count, parent_chunk_id, previous_chunk_id, next_chunk_id}, `provenance` {parser, parser_version, pipeline_profile, created_at, confidence}.

## Chunk by structure, not characters
Begin chunks at heading, paragraph group, list, table, figure and caption, callout. Carry the full heading path. Keep tables intact; extract Markdown or HTML for reading and row JSON for filtering. Store adjacent-chunk references. Prefix embeddings with title + section trail. Keep page ranges in every chunk. Unstructured's element-first partitioning is the comparable approach: https://docs.langchain.com/oss/python/integrations/document_loaders/unstructured_file

## Tables and images separately
Tables: faithful HTML or Markdown plus analytical JSON rows with column names, types, units, page, caption. Embed a readable summary plus headers; give the agent `get_table(table_id)`.
Figures: save the crop and coordinates, caption, nearby heading; generate descriptions only when useful and mark them derived; for architecture diagrams optionally extract nodes, edges, labels into graph JSON. Never quietly convert diagrams into authoritative text.

## Local-first stack
Parser Docling; OCR fallback OCRmyPDF or Tesseract; own Docling-aware chunker; local BGE, E5, or GTE embeddings; Qdrant or pgvector; PostgreSQL FTS, OpenSearch, or Meilisearch for keywords; MinIO or existing object store; Temporal, Prefect, n8n, or a durable queue; MCP server or narrow API tools as the agent interface.

Storage layout: `knowledge/documents/<sha256>/` with source.pdf, manifest.json, parsed.docling.json, document.md, chunks.jsonl, tables/ (html and json per table), figures/ (png and json), qa/extraction-report.json.

## Tools, not just a vector index
`search_documents(query, filters, top_k)`, `get_chunk`, `get_section`, `get_pages`, `get_table(table_id, format)`, `get_figure`, `find_exact(text, document_id)`, `cite(chunk_id)`. Flow: hybrid search, retrieve chunks with title, section path, page, score; expand the section; read table JSON if values are involved; answer with the page locator.

## Quality gates
Extraction completeness (character count, page coverage, missing pages); heading fidelity; table integrity (row and column counts, headers, numeric parsing, merged cells); OCR confidence routing; citation validity; retrieval evaluation with 30 to 100 questions; parser versioning; deduplication by hash plus near-duplicate detection. Make high-quality table reconstruction opt-in; it needs a table-recognition model: https://unstructured.readthedocs.io/en/main/introduction/overview.html

## Alternatives
Unstructured for mature connectors and semantic-element chunking. LlamaParse if a cloud API is acceptable: https://developers.llamaindex.ai/llamaparse/ . PyMuPDF or pdfplumber only as a fast native-text lane. Vision-language extraction selectively for scans, diagrams, damaged PDFs, with confidence and provenance flags.

## Opinionated starting point
PDF -> OCR preflight when needed -> Docling structured parse -> canonical JSON + Markdown + source assets -> heading-aware chunks and table JSON -> hybrid index -> MCP tools for search, section expansion, tables, citations -> evaluation set plus reprocessing and version controls.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { runCheapshot } from "./run.js";
import { ocrArgs, videoArgs, ledgerArgs, PAGE_CAP, type OcrInput, type VideoInput, type LedgerInput } from "./args.js";

export const VERSION = "0.1.0";

type Payload = Record<string, unknown>;
type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  structuredContent?: Payload;
  isError?: boolean;
};

function errorResult(message: string): ToolResult {
  return { content: [{ type: "text", text: message }], isError: true };
}

function parsePayload(stdout: string): Payload | undefined {
  try { return JSON.parse(stdout) as Payload; } catch { return undefined; }
}

/** The human text for an OCR or video payload: every result's text, with a file header when
 *  there is more than one, and the error line for a result that failed. */
function textOf(payload: Payload): string {
  const results = (payload.results as Array<Record<string, unknown>> | undefined) ?? [];
  const parts = results.map((r) => {
    const head = results.length > 1 ? `== ${String(r.file ?? "")}\n` : "";
    if (typeof r.error === "string") return `${head}${String(r.file ?? "")}: ${r.error}`;
    return head + String(r.text ?? "");
  });
  return parts.join("\n\n");
}

/** Runs the binary and shapes an OCR or video result. Exit 2 (usage) or non-JSON stdout is an error
 *  result carrying stderr; exit 1 (partial failure) keeps the payload and marks the result an error. */
async function runTool(args: string[]): Promise<ToolResult> {
  let run;
  try { run = await runCheapshot(args); }
  catch (e) { return errorResult(e instanceof Error ? e.message : String(e)); }
  const payload = parsePayload(run.stdout);
  if (run.code === 2 || payload === undefined) {
    return errorResult(run.stderr.trim() || `cheapshot exited ${run.code} with no JSON`);
  }
  return {
    content: [{ type: "text", text: textOf(payload) }],
    structuredContent: payload,
    isError: run.code !== 0 ? true : undefined,
  };
}

type Probed = { file: string; pages?: number };

/** A one page, no ledger probe of the given inputs (explicit paths or a --newest selection). Returns
 *  each result's file and, for a PDF, its page count. Undefined when the probe printed no JSON. */
async function probe(selector: string[]): Promise<Probed[] | undefined> {
  const run = await runCheapshot(["--json", "--no-ledger", "--pages", "1-1", ...selector]);
  const payload = parsePayload(run.stdout);
  if (payload === undefined) return undefined;
  const results = (payload.results as Array<Record<string, unknown>> | undefined) ?? [];
  return results
    .filter((r) => typeof r.file === "string")
    .map((r) => {
      const source = r.source as { pages?: number } | undefined;
      return { file: r.file as string, pages: typeof source?.pages === "number" ? source.pages : undefined };
    });
}

function overCap(p: Probed): string | undefined {
  if (p.pages === undefined || p.pages <= PAGE_CAP) return undefined;
  return `${p.file} has ${p.pages} pages. Pass pages (for example "1-5") to read a range; cheapshot_ocr does not dump more than ${PAGE_CAP} pages at once.`;
}

export function createServer(): McpServer {
  const server = new McpServer({ name: "cheapshot", version: VERSION });

  server.registerTool(
    "cheapshot_ocr",
    {
      title: "OCR an image or PDF",
      description:
        "Read the words in screenshots, images, or PDFs with on-device OCR. Secrets are redacted by default. " +
        "Returns the text and the cheapshot --json payload (results[].text, lines[] with bbox and confidence, " +
        `PDF source and pages) as structuredContent. A PDF over ${PAGE_CAP} pages needs a pages range.`,
      inputSchema: {
        paths: z.array(z.string()).optional().describe("Absolute paths to png, jpg, jpeg, webp, gif, or pdf files"),
        newest: z.object({
          dir: z.string().describe("Absolute path of the folder to scan. Required: the server's own working directory is arbitrary under an MCP host"),
          count: z.number().int().min(1).optional().describe("How many newest files, default 1"),
        }).optional().describe("Instead of paths: the newest image or PDF files in a folder"),
        raw: z.boolean().optional().describe("Skip redaction"),
        min_confidence: z.number().min(0).max(1).optional().describe("Confidence floor, default 0.3"),
        pages: z.string().optional().describe('PDF page range, "N" or "N-M"'),
      },
    },
    async (input: OcrInput): Promise<ToolResult> => {
      let args: string[];
      try { args = ocrArgs(input); } catch (e) { return errorResult(e instanceof Error ? e.message : String(e)); }
      if (input.pages !== undefined) return runTool(args);
      try {
        if (input.newest !== undefined && !(input.paths && input.paths.length > 0)) {
          // A --newest selection is resolved to explicit paths first, so a newest PDF over the cap is
          // refused instead of dumped, and the real run reads exactly the files the probe saw.
          const selector = ["--newest", input.newest.dir, ...(input.newest.count !== undefined ? [String(input.newest.count)] : [])];
          const found = await probe(selector);
          if (found === undefined) return errorResult(`cheapshot printed no JSON while listing the newest files in ${input.newest.dir}`);
          if (found.length === 0) return errorResult(`no image or PDF files found in ${input.newest.dir}`);
          for (const p of found) { const msg = overCap(p); if (msg !== undefined) return errorResult(msg); }
          args = ocrArgs({ ...input, newest: undefined, paths: found.map((p) => p.file) });
        } else {
          for (const path of input.paths ?? []) {
            if (!path.toLowerCase().endsWith(".pdf")) continue;
            const found = await probe([path]);
            for (const p of found ?? []) { const msg = overCap(p); if (msg !== undefined) return errorResult(msg); }
          }
        }
      } catch (e) { return errorResult(e instanceof Error ? e.message : String(e)); }
      return runTool(args);
    },
  );

  server.registerTool(
    "cheapshot_video",
    {
      title: "Transcribe a screen recording",
      description:
        "OCR the frames of a screen recording where the screen changed and return a timestamped transcript. " +
        "Needs ffmpeg on PATH. structuredContent is the cheapshot --json payload with segments[].",
      inputSchema: {
        path: z.string().describe("Absolute path to the video file"),
        scene: z.number().min(0).max(1).optional().describe("Scene change threshold, default 0.25"),
        max_frames: z.number().int().min(1).optional().describe("Frame cap, default 200"),
        dedupe: z.number().min(0).max(1).optional().describe("Drop a screen this similar to the last, default 0.90"),
        raw: z.boolean().optional().describe("Skip redaction"),
      },
    },
    async (input: VideoInput): Promise<ToolResult> => runTool(videoArgs(input)),
  );

  server.registerTool(
    "cheapshot_ledger",
    {
      title: "Tokens saved so far",
      description: "Cumulative savings from the cheapshot ledger: runs, inputs, image tokens, text tokens, saved, redactions, percent.",
      inputSchema: {
        days: z.number().int().min(1).optional().describe("Only the last n days; default all time"),
      },
    },
    async (input: LedgerInput): Promise<ToolResult> => {
      let run;
      try { run = await runCheapshot(ledgerArgs(input)); }
      catch (e) { return errorResult(e instanceof Error ? e.message : String(e)); }
      const payload = parsePayload(run.stdout);
      if (run.code !== 0 || payload === undefined) return errorResult(run.stderr.trim() || `cheapshot exited ${run.code}`);
      const s = payload as { saved?: number; percent?: number; runs?: number; inputs?: number; days?: number; window_days?: number };
      const window = s.window_days !== undefined ? `last ${s.window_days} days` : "all time";
      const text = `cheapshot saved ${s.saved ?? 0} tokens (${s.percent ?? 0}%) over ${s.runs ?? 0} runs and ${s.inputs ?? 0} inputs, ${window}.`;
      return { content: [{ type: "text", text }], structuredContent: payload };
    },
  );

  server.registerResource(
    "ledger",
    "cheapshot://ledger",
    { title: "cheapshot ledger", description: "Cumulative token savings, all time, as JSON.", mimeType: "application/json" },
    async (uri) => {
      let text: string;
      try {
        const run = await runCheapshot(ledgerArgs({}));
        if (run.code !== 0) text = JSON.stringify({ error: run.stderr.trim() || `cheapshot exited ${run.code}` });
        else text = parsePayload(run.stdout) === undefined ? JSON.stringify({ error: "cheapshot printed no JSON" }) : run.stdout.trim();
      } catch (e) {
        text = JSON.stringify({ error: e instanceof Error ? e.message : String(e) });
      }
      return { contents: [{ uri: uri.href, mimeType: "application/json", text }] };
    },
  );

  return server;
}

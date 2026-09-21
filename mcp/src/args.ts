/** Pure argument builders. Each returns the argv the binary gets, so they are testable with no process. */

export const PAGE_CAP = 20;

export interface OcrInput {
  paths?: string[];
  newest?: { dir: string; count?: number };
  raw?: boolean;
  min_confidence?: number;
  pages?: string;
}

export interface VideoInput {
  path: string;
  scene?: number;
  max_frames?: number;
  dedupe?: number;
  raw?: boolean;
}

export interface LedgerInput { days?: number; by_mode?: boolean; }

const PAGES = /^(\d+)(?:-(\d+))?$/;

export function parsePages(s: string): { lo: number; hi: number } {
  const m = PAGES.exec(s);
  if (!m) throw new Error(`pages must be N or N-M, got ${JSON.stringify(s)}`);
  const lo = Number(m[1]);
  const hi = m[2] === undefined ? lo : Number(m[2]);
  if (lo < 1 || hi < lo) throw new Error(`pages must be N or N-M with N >= 1, got ${JSON.stringify(s)}`);
  return { lo, hi };
}

export function ocrArgs(input: OcrInput): string[] {
  const hasPaths = Array.isArray(input.paths) && input.paths.length > 0;
  if (!hasPaths && !input.newest) throw new Error("cheapshot_ocr needs paths or newest");
  const args = ["--json"];
  if (input.raw) args.push("--raw");
  if (input.min_confidence !== undefined) args.push("--min-conf", String(input.min_confidence));
  if (input.pages !== undefined) { parsePages(input.pages); args.push("--pages", input.pages); }
  if (hasPaths) {
    args.push(...(input.paths as string[]));
  } else {
    const n = input.newest as { dir: string; count?: number };
    args.push("--newest", n.dir);
    if (n.count !== undefined) args.push(String(n.count));
  }
  return args;
}

export function videoArgs(input: VideoInput): string[] {
  const args = ["--json"];
  if (input.raw) args.push("--raw");
  if (input.scene !== undefined) args.push("--scene", String(input.scene));
  if (input.max_frames !== undefined) args.push("--max-frames", String(input.max_frames));
  if (input.dedupe !== undefined) args.push("--dedupe", String(input.dedupe));
  args.push("--video", input.path);
  return args;
}

export function ledgerArgs(input: LedgerInput): string[] {
  const args = ["--ledger", "--json"];
  if (input.days !== undefined) args.push("--days", String(input.days));
  if (input.by_mode) args.push("--by-mode");
  return args;
}

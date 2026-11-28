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

/** The environment variable a person sets to let the model ask for unredacted text (#290 item 3).
 *  It is read from the MCP server's own environment, which the model cannot change mid-session:
 *  it comes from the shell that started the host, or the "env" block of the MCP config. */
export const RAW_ENV = "CHEAPSHOT_ALLOW_RAW";

/** True only when a person has opted in to raw output for this server process. */
export function rawAllowed(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[RAW_ENV] === "1";
}

/** Refuses raw: true unless a person opted in. The caller of these tools is the model, and text it
 *  has read can steer it, so "skip redaction" must not be a choice the model makes on its own. */
export function assertRawAllowed(raw: boolean | undefined, env: NodeJS.ProcessEnv = process.env): void {
  if (raw && !rawAllowed(env)) {
    throw new Error(`raw is off: redaction can only be skipped when a person sets ${RAW_ENV}=1 in the environment ` +
      `that starts the cheapshot MCP server. Ask the user; do not retry without raw unless redacted text is enough.`);
  }
}

/** Every read passes this (Ryan, Q5: "A. Agents get all rules"): presets and switches in
 *  rules.json never apply to what the model reads. They switch rules off only for a person's own
 *  CLI runs, `redact`, --clipboard and the apps. A binary older than 0.7.0 does not know the flag;
 *  runCheapshot then runs the read once more without it (see run.ts). */
export const ALL_RULES = "--all-rules";

const PAGES = /^(\d+)(?:-(\d+))?$/;

export function parsePages(s: string): { lo: number; hi: number } {
  const m = PAGES.exec(s);
  if (!m) throw new Error(`pages must be N or N-M, got ${JSON.stringify(s)}`);
  const lo = Number(m[1]);
  const hi = m[2] === undefined ? lo : Number(m[2]);
  if (lo < 1 || hi < lo) throw new Error(`pages must be N or N-M with N >= 1, got ${JSON.stringify(s)}`);
  return { lo, hi };
}

/** Refuses a value the binary could read as an option. The caller of these tools is the model, and
 *  text it has read can steer it, so a path like "--raw" must never reach the command line (#290).
 *  Absolute paths never start with "-", and "-" (stdin) has no meaning for an MCP call. */
export function assertNotOption(what: string, value: string): void {
  if (value.startsWith("-")) throw new Error(`${what} must not start with "-", got ${JSON.stringify(value)}`);
}

/** newest.dir must be absolute. The binary reads a bare integer as a count, so "2024" would
 *  scan the cwd for the newest 2024 files instead of listing that directory (#15 review). */
export function assertAbsoluteDir(value: string): void {
  assertNotOption("newest.dir", value);
  if (!value.startsWith("/")) {
    throw new Error(`newest.dir must be an absolute path, got ${JSON.stringify(value)}`);
  }
}

export function ocrArgs(input: OcrInput, env: NodeJS.ProcessEnv = process.env): string[] {
  assertRawAllowed(input.raw, env);
  const hasPaths = Array.isArray(input.paths) && input.paths.length > 0;
  if (!hasPaths && !input.newest) throw new Error("cheapshot_ocr needs paths or newest");
  const args = ["--json", ALL_RULES];
  if (input.raw) args.push("--raw");
  if (input.min_confidence !== undefined) args.push("--min-conf", String(input.min_confidence));
  if (input.pages !== undefined) { parsePages(input.pages); args.push("--pages", input.pages); }
  if (hasPaths) {
    const paths = input.paths as string[];
    // assertNotOption is the guard: no path can start with "-", so none can parse as a flag.
    // No "--" marker is sent, because cheapshot binaries older than #290 reject "--" as an
    // unknown option, and the npm package and the brew binary update separately.
    for (const p of paths) assertNotOption("each path", p);
    args.push(...paths);
  } else {
    const n = input.newest as { dir: string; count?: number };
    assertAbsoluteDir(n.dir);
    args.push("--newest", n.dir);
    if (n.count !== undefined) args.push(String(n.count));
  }
  return args;
}

export function videoArgs(input: VideoInput, env: NodeJS.ProcessEnv = process.env): string[] {
  assertRawAllowed(input.raw, env);
  assertNotOption("path", input.path);
  const args = ["--json", ALL_RULES];
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

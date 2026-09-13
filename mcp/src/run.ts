import { execFile } from "node:child_process";

export interface RunResult { code: number; stdout: string; stderr: string; }

const MAX_OUTPUT = 64 * 1024 * 1024;

/** Runs the cheapshot binary found on PATH (or CHEAPSHOT_BIN) and captures everything. Never throws
 *  on a non-zero exit; the caller reads `code`. Throws only when the binary cannot be started. */
export function runCheapshot(args: string[]): Promise<RunResult> {
  const bin = process.env.CHEAPSHOT_BIN && process.env.CHEAPSHOT_BIN.length > 0 ? process.env.CHEAPSHOT_BIN : "cheapshot";
  return new Promise((resolve, reject) => {
    execFile(bin, args, { maxBuffer: MAX_OUTPUT, encoding: "utf8" }, (error, stdout, stderr) => {
      if (error && (error as NodeJS.ErrnoException).code === "ENOENT") {
        reject(new Error("cheapshot binary not found on PATH. Install it: brew install all-caps-dev/tap/cheapshot"));
        return;
      }
      const code = error && typeof (error as { code?: unknown }).code === "number" ? (error as { code: number }).code : error ? 1 : 0;
      resolve({ code, stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

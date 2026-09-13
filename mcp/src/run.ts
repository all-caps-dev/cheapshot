import { execFile } from "node:child_process";

export interface RunResult { code: number; stdout: string; stderr: string; }

const MAX_OUTPUT = 64 * 1024 * 1024;
const INSTALL = "Install it: brew install all-caps-dev/tap/cheapshot";

/** Runs the cheapshot binary found on PATH (or CHEAPSHOT_BIN) and captures everything. Never throws
 *  on a non-zero exit; the caller reads `code`. Throws only when the binary cannot be found. Any other
 *  spawn failure (EACCES, a signal) resolves with code 1 and the failure message appended to stderr. */
export function runCheapshot(args: string[]): Promise<RunResult> {
  const fromEnv = process.env.CHEAPSHOT_BIN && process.env.CHEAPSHOT_BIN.length > 0 ? process.env.CHEAPSHOT_BIN : undefined;
  const bin = fromEnv ?? "cheapshot";
  return new Promise((resolve, reject) => {
    execFile(bin, args, { maxBuffer: MAX_OUTPUT, encoding: "utf8" }, (error, stdout, stderr) => {
      const errCode = error ? (error as { code?: unknown }).code : undefined;
      if (errCode === "ENOENT") {
        const where = fromEnv === undefined ? "on PATH" : `at ${fromEnv} (CHEAPSHOT_BIN)`;
        reject(new Error(`cheapshot binary not found ${where}. ${INSTALL}`));
        return;
      }
      let err = String(stderr);
      let code = 0;
      if (error) {
        if (typeof errCode === "number") {
          code = errCode;
        } else {
          code = 1;
          const msg = error.message ?? String(error);
          err = err.length > 0 && !err.endsWith("\n") ? `${err}\n${msg}` : `${err}${msg}`;
        }
      }
      resolve({ code, stdout: String(stdout), stderr: err });
    });
  });
}

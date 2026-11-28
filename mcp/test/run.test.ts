import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runCheapshot } from "../src/run.js";

const here = path.dirname(fileURLToPath(import.meta.url));
// dist/test/run.test.js -> ../../test/fake-bin/cheapshot (tests run from dist/).
const fakeBin = path.resolve(here, "..", "..", "test", "fake-bin", "cheapshot");

beforeEach(() => {
  process.env.CHEAPSHOT_BIN = fakeBin;
  delete process.env.FAKE_EXIT;
});

test("run: exit 0 resolves with the JSON on stdout", async () => {
  const r = await runCheapshot(["--json", "/tmp/shot.png"]);
  assert.equal(r.code, 0);
  assert.equal(JSON.parse(r.stdout).results[0].file, "/tmp/shot.png");
  assert.equal(r.stderr, "");
});

test("run: FAKE_EXIT=3 surfaces the code and stderr, no throw", async () => {
  process.env.FAKE_EXIT = "3";
  const r = await runCheapshot(["--json", "/tmp/shot.png"]);
  assert.equal(r.code, 3);
  assert.match(r.stderr, /fake failure/);
});

test("run: a missing CHEAPSHOT_BIN rejects naming that path and the brew install", async () => {
  process.env.CHEAPSHOT_BIN = "/nonexistent/dir/cheapshot";
  await assert.rejects(runCheapshot(["--version"]), (e: unknown) => {
    const m = (e as Error).message;
    assert.match(m, /not found at \/nonexistent\/dir\/cheapshot \(CHEAPSHOT_BIN\)/);
    assert.match(m, /brew install all-caps-dev\/tap\/cheapshot/);
    return true;
  });
});

test("run: a bare cheapshot missing from PATH rejects with the PATH message", async () => {
  delete process.env.CHEAPSHOT_BIN;
  const savedPath = process.env.PATH;
  process.env.PATH = path.resolve(here, "no-such-dir");
  try {
    await assert.rejects(runCheapshot(["--version"]), /not found on PATH\. Install it: brew install/);
  } finally {
    process.env.PATH = savedPath;
  }
});

test("run: a non-ENOENT spawn failure resolves code 1 with the message in stderr", async () => {
  // A directory is found but cannot be executed (EACCES), a string error code, not ENOENT.
  process.env.CHEAPSHOT_BIN = path.dirname(fakeBin);
  const r = await runCheapshot(["--version"]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /EACCES|spawn/);
});

// CHE-62: a binary older than 0.7.0 rejects --all-rules. runCheapshot runs the read once more
// without it (such a binary cannot switch a built-in rule off), and only for that exact error.
test("run: an old binary is retried once without --all-rules", async () => {
  const fs = await import("node:fs");
  const os = await import("node:os");
  const log = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "cs-mcp-")), "argv.log");
  process.env.FAKE_LOG = log;
  process.env.FAKE_OLD = "1";
  try {
    const r = await runCheapshot(["--json", "--all-rules", "/tmp/shot.png"]);
    assert.equal(r.code, 0);
    assert.equal(JSON.parse(r.stdout).results[0].file, "/tmp/shot.png");
    assert.deepEqual(fs.readFileSync(log, "utf8").trim().split("\n"), ["--json --all-rules /tmp/shot.png", "--json /tmp/shot.png"]);
  } finally {
    delete process.env.FAKE_LOG;
    delete process.env.FAKE_OLD;
  }
});

test("run: a current binary takes --all-rules with no retry; other exit 2 errors are not retried", async () => {
  const fs = await import("node:fs");
  const os = await import("node:os");
  const log = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "cs-mcp-")), "argv.log");
  process.env.FAKE_LOG = log;
  try {
    const ok = await runCheapshot(["--json", "--all-rules", "/tmp/shot.png"]);
    assert.equal(ok.code, 0);
    assert.equal(fs.readFileSync(log, "utf8").trim().split("\n").length, 1);
    fs.writeFileSync(log, "");
    process.env.FAKE_EXIT = "2";
    process.env.FAKE_STDERR = "cheapshot: unknown option --all-rules-x";
    const bad = await runCheapshot(["--json", "--all-rules", "/tmp/shot.png"]);
    assert.equal(bad.code, 2);
    assert.equal(fs.readFileSync(log, "utf8").trim().split("\n").length, 1);
  } finally {
    delete process.env.FAKE_LOG;
    delete process.env.FAKE_STDERR;
    delete process.env.FAKE_EXIT;
  }
});

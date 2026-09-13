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

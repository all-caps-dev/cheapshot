import { test } from "node:test";
import assert from "node:assert/strict";
import { ocrArgs, videoArgs, ledgerArgs, PAGE_CAP } from "../src/args.js";

test("ocr: paths with defaults", () => {
  assert.deepEqual(ocrArgs({ paths: ["/tmp/a.png", "/tmp/b.jpg"] }), ["--json", "/tmp/a.png", "/tmp/b.jpg"]);
});

test("ocr: raw, min_confidence, pages", () => {
  assert.deepEqual(ocrArgs({ paths: ["/tmp/r.pdf"], raw: true, min_confidence: 0.5, pages: "3-5" }),
    ["--json", "--raw", "--min-conf", "0.5", "--pages", "3-5", "/tmp/r.pdf"]);
});

test("ocr: newest with dir and count", () => {
  assert.deepEqual(ocrArgs({ newest: { dir: "/Users/me/Desktop", count: 2 } }),
    ["--json", "--newest", "/Users/me/Desktop", "2"]);
});

test("ocr: neither paths nor newest is an error", () => {
  assert.throws(() => ocrArgs({}), /paths or newest/);
  assert.throws(() => ocrArgs({ paths: [] }), /paths or newest/);
});

test("ocr: pages must look like N or N-M", () => {
  assert.throws(() => ocrArgs({ paths: ["/tmp/r.pdf"], pages: "three" }), /pages/);
  assert.throws(() => ocrArgs({ paths: ["/tmp/r.pdf"], pages: "5-3" }), /pages/);
});

test("video: defaults and every flag", () => {
  assert.deepEqual(videoArgs({ path: "/tmp/s.mp4" }), ["--json", "--video", "/tmp/s.mp4"]);
  assert.deepEqual(videoArgs({ path: "/tmp/s.mp4", scene: 0.3, max_frames: 50, dedupe: 0.8, raw: true }),
    ["--json", "--raw", "--scene", "0.3", "--max-frames", "50", "--dedupe", "0.8", "--video", "/tmp/s.mp4"]);
});

test("ledger: with and without days", () => {
  assert.deepEqual(ledgerArgs({}), ["--ledger", "--json"]);
  assert.deepEqual(ledgerArgs({ days: 7 }), ["--ledger", "--json", "--days", "7"]);
});

test("ledger: by_mode adds the flag, and only when true", () => {
  assert.deepEqual(ledgerArgs({ by_mode: true }), ["--ledger", "--json", "--by-mode"]);
  assert.deepEqual(ledgerArgs({ by_mode: false }), ["--ledger", "--json"]);
  assert.deepEqual(ledgerArgs({ days: 7, by_mode: true }), ["--ledger", "--json", "--days", "7", "--by-mode"]);
});

test("page cap is 20", () => {
  assert.equal(PAGE_CAP, 20);
});

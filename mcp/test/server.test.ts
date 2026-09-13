import { test, before } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createServer } from "../src/server.js";

const here = path.dirname(fileURLToPath(import.meta.url));
// dist/test/server.test.js -> ../../test/fake-bin holds the fake binary (tests run from dist/).
const fakeBin = path.resolve(here, "..", "..", "test", "fake-bin");

type ToolResult = { content: Array<{ type: string; text?: string }>; structuredContent?: Record<string, unknown>; isError?: boolean };

async function connected(): Promise<Client> {
  const [ct, st] = InMemoryTransport.createLinkedPair();
  const server = createServer();
  await server.connect(st);
  const client = new Client({ name: "test", version: "0" });
  await client.connect(ct);
  return client;
}

before(() => {
  process.env.PATH = `${fakeBin}${path.delimiter}${process.env.PATH ?? ""}`;
  delete process.env.CHEAPSHOT_BIN;
});

test("lists the three tools and the ledger resource", async () => {
  const c = await connected();
  const tools = (await c.listTools()).tools.map((t) => t.name).sort();
  assert.deepEqual(tools, ["cheapshot_ledger", "cheapshot_ocr", "cheapshot_video"]);
  const res = (await c.listResources()).resources.map((r) => r.uri);
  assert.deepEqual(res, ["cheapshot://ledger"]);
});

test("cheapshot_ocr returns redacted text and the --json payload as structuredContent", async () => {
  const c = await connected();
  const r = (await c.callTool({ name: "cheapshot_ocr", arguments: { paths: ["/tmp/shot.png"] } })) as ToolResult;
  assert.equal(r.isError ?? false, false);
  assert.equal(r.content[0].type, "text");
  assert.match(r.content[0].text ?? "", /hello world\nkey \[AWS_KEY\]/);
  const sc = r.structuredContent as { version: string; results: Array<{ file: string; lines: unknown[] }>; image_tokens: number; text_tokens: number };
  assert.equal(sc.version, "0.5.0-dev");
  assert.equal(sc.image_tokens, 1018);
  assert.equal(sc.text_tokens, 37);
  assert.equal(sc.results[0].file, "/tmp/shot.png");
  assert.equal(sc.results[0].lines.length, 2);
});

test("cheapshot_ocr with pages on a pdf carries source and pages", async () => {
  const c = await connected();
  const r = (await c.callTool({ name: "cheapshot_ocr", arguments: { paths: ["/tmp/report.pdf"], pages: "1-3" } })) as ToolResult;
  const sc = r.structuredContent as { results: Array<{ source: { pages: number; sha256: string }; pages: Array<{ lane: string }> }> };
  assert.equal(sc.results[0].source.sha256, "ab12");
  assert.equal(sc.results[0].pages[0].lane, "text");
});

test("cheapshot_ocr refuses a big pdf with no pages", async () => {
  process.env.FAKE_PAGES = "42";
  try {
    const c = await connected();
    const r = (await c.callTool({ name: "cheapshot_ocr", arguments: { paths: ["/tmp/report.pdf"] } })) as ToolResult;
    assert.equal(r.isError, true);
    assert.match(r.content[0].text ?? "", /42 pages/);
    assert.match(r.content[0].text ?? "", /pages/);
  } finally {
    delete process.env.FAKE_PAGES;
  }
});

test("cheapshot_ocr with neither paths nor newest is an error result", async () => {
  const c = await connected();
  const r = (await c.callTool({ name: "cheapshot_ocr", arguments: {} })) as ToolResult;
  assert.equal(r.isError, true);
  assert.match(r.content[0].text ?? "", /paths or newest/);
});

test("cheapshot_ocr reports a binary failure as an error result", async () => {
  process.env.FAKE_EXIT = "1";
  try {
    const c = await connected();
    const r = (await c.callTool({ name: "cheapshot_ocr", arguments: { paths: ["/tmp/shot.png"] } })) as ToolResult;
    assert.equal(r.isError, true);
    assert.match(r.content[0].text ?? "", /fake failure/);
  } finally {
    delete process.env.FAKE_EXIT;
  }
});

test("cheapshot_video returns the transcript and segments", async () => {
  const c = await connected();
  const r = (await c.callTool({ name: "cheapshot_video", arguments: { path: "/tmp/screen.mp4", scene: 0.3 } })) as ToolResult;
  assert.equal(r.isError ?? false, false);
  assert.match(r.content[0].text ?? "", /\[00:12\]\ntests pass/);
  const sc = r.structuredContent as { results: Array<{ segments: unknown[]; frames: number }> };
  assert.equal(sc.results[0].segments.length, 2);
  assert.equal(sc.results[0].frames, 2);
});

test("cheapshot_ledger returns the summary", async () => {
  const c = await connected();
  const r = (await c.callTool({ name: "cheapshot_ledger", arguments: { days: 7 } })) as ToolResult;
  assert.equal(r.isError ?? false, false);
  assert.match(r.content[0].text ?? "", /41200/);
  const sc = r.structuredContent as { saved: number; window_days: number };
  assert.equal(sc.saved, 41200);
  assert.equal(sc.window_days, 7);
});

test("cheapshot://ledger resource is the summary as JSON", async () => {
  const c = await connected();
  const r = await c.readResource({ uri: "cheapshot://ledger" });
  const item = r.contents[0] as { uri: string; mimeType?: string; text?: string };
  assert.equal(item.uri, "cheapshot://ledger");
  assert.equal(item.mimeType, "application/json");
  assert.equal(JSON.parse(item.text ?? "{}").saved, 41200);
});

test("cheapshot_ocr newest without dir is an error result, never bare --newest", async () => {
  const c = await connected();
  const r = (await c.callTool({ name: "cheapshot_ocr", arguments: { newest: { count: 2 } } })) as ToolResult;
  assert.equal(r.isError, true);
  assert.match(r.content[0].text ?? "", /dir/);
});

#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createServer } from "./server.js";

const server = createServer();
const transport = new StdioServerTransport();
server.connect(transport).catch((e: unknown) => {
  process.stderr.write(`cheapshot-mcp: ${e instanceof Error ? e.message : String(e)}\n`);
  process.exit(1);
});

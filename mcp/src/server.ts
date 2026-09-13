import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

export const VERSION = "0.1.0";

export function createServer(): McpServer {
  return new McpServer({ name: "cheapshot", version: VERSION });
}

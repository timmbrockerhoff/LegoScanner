// Lokaler Server für Tests vom iPhone im selben WLAN: npm run dev
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

process.env.ANTHROPIC_API_KEY ??= readFileSync(`${homedir()}/.config/legoscanner/anthropic_api_key`, "utf8").trim();
const { POST } = await import("./api/identify.ts");

createServer(async (req, res) => {
  if (req.method !== "POST" || req.url !== "/api/identify") {
    res.writeHead(404).end();
    return;
  }
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const headers = new Headers(Object.entries(req.headers).map(([k, v]) => [k, String(v)]));
  const response = await POST(new Request("http://local/api/identify", { method: "POST", headers, body: Buffer.concat(chunks) }));
  res.writeHead(response.status, { "content-type": "application/json" }).end(await response.text());
  console.log(new Date().toLocaleTimeString("de-DE"), response.status, `${Buffer.concat(chunks).length} Bytes`);
}).listen(3000, "0.0.0.0", () => console.log("Backend läuft auf Port 3000"));

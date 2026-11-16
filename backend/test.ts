// Testsatz über die Batch-API (halber Preis, Ergebnis meist nach wenigen Minuten): npm test
// Bilder + richtige Antworten liegen in testdata/ (nicht im Repo: private Fotos).
// testdata/truth.json: { "bild.jpg": [["3795", "Yellow"], ...], "holz.jpg": [] }
// Bilder so wie die App sie schickt: Scanfeld, 768 px (Documents/scans aus dem Debug-Build).
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import Anthropic from "@anthropic-ai/sdk";

process.env.ANTHROPIC_API_KEY ??= readFileSync(`${homedir()}/.config/legoscanner/anthropic_api_key`, "utf8").trim();
const { request, parse } = await import("./api/identify.ts");
const client = new Anthropic();

const dir = new URL("./testdata/", import.meta.url);
const truth: Record<string, [string, string][]> = JSON.parse(readFileSync(new URL("truth.json", dir), "utf8"));
const files = Object.keys(truth);

const batch = await client.messages.batches.create({
  requests: files.map((file, i) => ({ custom_id: `bild-${i}`, params: request(readFileSync(new URL(file, dir)).toString("base64")) })),
});
console.log(`Batch ${batch.id} mit ${files.length} Bildern gestartet, warte …`);
while ((await client.messages.batches.retrieve(batch.id)).processing_status !== "ended") {
  await new Promise((resolve) => setTimeout(resolve, 15_000));
}

const results = new Map<string, Anthropic.Messages.MessageBatchResult>();
for await (const r of await client.messages.batches.results(batch.id)) results.set(r.custom_id, r.result);

let wanted = 0, partOk = 0, bothOk = 0, extra = 0, input = 0, cached = 0, output = 0;
files.forEach((file, i) => {
  const result = results.get(`bild-${i}`);
  if (result?.type !== "succeeded") return console.log(`✗ ${file.padEnd(20)} Fehler: ${result?.type}`);
  const { usage } = result.message;
  input += usage.input_tokens + (usage.cache_creation_input_tokens ?? 0);
  cached += usage.cache_read_input_tokens ?? 0;
  output += usage.output_tokens;
  const parts = parse(result.message);

  const left = [...parts];
  let fileOk = true;
  for (const [no, color] of truth[file]) {
    wanted++;
    let j = left.findIndex((p) => p.partNo === no && p.colorName === color);
    if (j >= 0) { partOk++; bothOk++; left.splice(j, 1); continue; }
    fileOk = false;
    j = left.findIndex((p) => p.partNo === no);
    if (j >= 0) { partOk++; left.splice(j, 1); }
  }
  // Teile unter 50 % zeigt die App nicht an → zählen nicht als erfunden
  const shownExtra = left.filter((p) => p.confidence >= 0.5).length;
  extra += shownExtra;
  if (shownExtra) fileOk = false;
  const found = parts.map((p) => `${p.partNo} ${p.colorName} ${Math.round(p.confidence * 100)}%`).join(", ") || "kein LEGO";
  console.log(`${fileOk ? "✓" : "✗"} ${file.padEnd(20)} ${found}`);
});
console.log(`\nTeil richtig: ${partOk}/${wanted} · Teil + Farbe: ${bothOk}/${wanted} · erfundene (≥ 50 %): ${extra}`);
// Opus 5.5: $4 / $20 pro Mio. Tokens, Cache-Lesen $0.20; Batch halbiert alles. Cache-Schreiben grob als Input gerechnet.
const dollars = (input * 4 + cached * 0.2 + output * 20) / 1e6 / 2;
console.log(`Kosten: ≈ ${(dollars * 100).toFixed(1)} Cent (${(dollars * 100 / files.length).toFixed(2)} Cent pro Bild)`);

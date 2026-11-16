// Neuere Anleitungen (etwa ab 2010): Teilekasten pro Schritt und Tütensymbole ablesen (Batch-API, halber Preis).
// Anders als instructions.ts (alte Anleitungen ohne Teilekästen) muss hier nichts aus Bildvergleichen erraten werden.
//
// node --experimental-strip-types callouts.ts <teileliste.named.csv> <anleitung.pdf> <seiten> <ausgabe.json> [modelle]
//   seiten: "14-247" oder "14,20,93"   modelle: "claude-opus-5-5:low,claude-sonnet-5-5:low" (Probelauf zum Vergleich)
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import Anthropic from "@anthropic-ai/sdk";

process.env.ANTHROPIC_API_KEY ??= readFileSync(`${homedir()}/.config/legoscanner/anthropic_api_key`, "utf8").trim();
const client = new Anthropic();
const [csvPath, pdfPath, pageArg, outPath, modelArg = "claude-opus-5-5:low"] = process.argv.slice(2);
const pages = pageArg.includes("-") && !pageArg.includes(",")
  ? (([a, b]) => Array.from({ length: b - a + 1 }, (_, i) => a + i))(pageArg.split("-").map(Number))
  : pageArg.split(",").map(Number);
const models = modelArg.split(",").map((m) => m.split(":") as [string, "low" | "medium" | "high"]);

const inventory = readFileSync(csvPath, "utf8").trim().split("\n").slice(1).map((line) => {
  const [qty, part, color, ...name] = line.split(";");
  return { key: `${part}|${color}`, qty: Number(qty), name: name.join(";") };
});

// Pro Seite: ganze Seite klein (Schrittnummern, Tütensymbol) + jeder Rahmen in hoher Auflösung (tools/callout_boxes.py).
// So sind die Teile im Kasten 3–4× größer als auf der verkleinerten Seite, und es kostet weniger.
const dir = mkdtempSync(join(tmpdir(), "callouts-"));
const python = `${homedir()}/LegoScanner-data/venv/bin/python`;
type Crops = { page: string; boxes: { file: string; x: number; y: number; w: number; h: number }[] };
const content = (n: number) => {
  const crops: Crops = JSON.parse(execFileSync(python, [new URL("tools/callout_boxes.py", import.meta.url).pathname, pdfPath, `${n}`, dir]).toString());
  const img = (file: string) => ({ type: "image" as const, source: { type: "base64" as const, media_type: "image/jpeg" as const, data: readFileSync(join(dir, file)).toString("base64") } });
  return [
    { type: "text" as const, text: `Seite ${n}, verkleinert (für Schrittnummern und Tütensymbol):` },
    img(crops.page),
    ...crops.boxes.flatMap((b, i) => [
      { type: "text" as const, text: `Rahmen ${i + 1} in hoher Auflösung (Lage auf der Seite: links ${Math.round(b.x * 100)} %, oben ${Math.round(b.y * 100)} %):` },
      img(b.file),
    ]),
  ];
};

const PROMPT = `Du liest eine Seite einer neueren LEGO-Bauanleitung. Jeder nummerierte Bauschritt hat oben links einen Teilekasten: Er zeigt alle Teile dieses Schritts mit Anzahl ("2x").

Du bekommst die Seite verkleinert und jeden Rahmen der Seite einzeln in hoher Auflösung. Teilekästen sind Rahmen mit Teilen und Mengenangaben ("2x"); lies die Teile dort ab. Rahmen ohne Mengenangaben (Bauhilfen, Unterbaugruppen, "6x so bauen") enthalten keine neuen Teile: ignorieren. Ein Teilekasten gehört zu der Schrittnummer, die direkt darunter steht. Tütenanfang: Steht neben dem Tütensymbol ein Kasten mit Teilen und Mengen (oft große Grundplatten), gib diese Teile als eigenen Schritt mit step = 0 an. Diese Teile nie weglassen.

Gib für jeden Schritt auf der Seite die Teile aus seinem Teilekasten an:
- step: die Schrittnummer
- parts: jedes Teil im Kasten als item = "Teilenummer|Farbe" aus der Teileliste unten, qty = die Zahl vor dem "x"
- Unterbaugruppen haben eigene Kästen und eigene Schrittnummern: genauso behandeln.
- Nur Teile aus der Teileliste unten nennen. Bei ähnlichen Teilen auf Form und Farbe im Kasten achten, nicht raten.

bag: Beginnt auf dieser Seite eine neue Tüte (Symbol einer Tüte mit großer Zahl), deren Nummer, sonst 0.
uncertain: kurze Notiz, wenn ein Teil im Kasten nicht sicher zuzuordnen war, sonst leer.

Teileliste des Sets (Anzahl;Teilenummer|Farbe;Name):
${inventory.map((i) => `${i.qty};${i.key};${i.name}`).join("\n")}`;

const SCHEMA = {
  type: "object",
  properties: {
    bag: { type: "integer" },
    steps: {
      type: "array",
      items: {
        type: "object",
        properties: {
          step: { type: "integer" },
          parts: {
            type: "array",
            items: {
              type: "object",
              properties: { item: { type: "string", enum: inventory.map((i) => i.key) }, qty: { type: "integer" } },
              required: ["item", "qty"],
              additionalProperties: false,
            },
          },
        },
        required: ["step", "parts"],
        additionalProperties: false,
      },
    },
    uncertain: { type: "string" },
  },
  required: ["bag", "steps", "uncertain"],
  additionalProperties: false,
};

const pageContent = new Map(pages.map((n) => [n, content(n)]));
const batch = await client.messages.batches.create({
  requests: models.flatMap(([model, effort]) => pages.map((n) => ({
    custom_id: `${model.replace(/[^a-z0-9]/gi, "")}-${effort}-${n}`,
    params: {
      model,
      max_tokens: 16000,
      output_config: { effort, format: { type: "json_schema" as const, schema: SCHEMA } },
      system: [{ type: "text" as const, text: PROMPT, cache_control: { type: "ephemeral" as const } }],
      messages: [{
        role: "user" as const,
        content: pageContent.get(n)!,
      }],
    },
  }))),
});
console.log(`Batch ${batch.id}: ${pages.length} Seiten × ${models.length} Modell(e), warte …`);
while ((await client.messages.batches.retrieve(batch.id)).processing_status !== "ended") {
  await new Promise((resolve) => setTimeout(resolve, 20_000));
}

// Preise pro Mio. Tokens (Eingabe, Ausgabe), Cache-Lesen 5 % der Eingabe; Batch halbiert alles.
const PRICE: Record<string, [number, number]> = { "claude-opus-5-5": [4, 20], "claude-sonnet-5-5": [3, 15] };
const results: Record<string, { page: number; bag: number; steps: { step: number; parts: { item: string; qty: number }[] }[]; uncertain: string }[]> = {};
const cost: Record<string, number> = {};
for await (const r of await client.messages.batches.results(batch.id)) {
  const [runModel, runEffort, page] = r.custom_id.split("-");
  const run = `${runModel}-${runEffort}`;
  if (r.result.type !== "succeeded") { console.log(`${r.custom_id}: ${r.result.type}`); continue; }
  const m = r.result.message;
  const [pin, pout] = PRICE[m.model.replace(/-\d{8}$/, "")] ?? PRICE["claude-opus-5-5"];
  const u = m.usage;
  cost[run] = (cost[run] ?? 0) + ((u.input_tokens + (u.cache_creation_input_tokens ?? 0)) * pin + (u.cache_read_input_tokens ?? 0) * pin * 0.05 + u.output_tokens * pout) / 1e6 / 2;
  const text = m.content.find((b) => b.type === "text");
  if (!text || text.type !== "text") { console.log(`${r.custom_id}: keine Antwort (${m.stop_reason})`); continue; }
  (results[run] ??= []).push({ page: Number(page), ...JSON.parse(text.text) });
}
for (const run of Object.keys(results)) results[run].sort((a, b) => a.page - b.page);
writeFileSync(outPath, JSON.stringify(results, null, 1));
for (const [run, list] of Object.entries(results)) {
  const parts = list.reduce((a, p) => a + p.steps.reduce((b, s) => b + s.parts.reduce((c, x) => c + x.qty, 0), 0), 0);
  console.log(`${run}: ${list.length} Seiten, ${list.reduce((a, p) => a + p.steps.length, 0)} Schritte, ${parts} Teile, ` +
    `Tüten ${list.filter((p) => p.bag).map((p) => `${p.bag}@S.${p.page}`).join(" ") || "–"}, ` +
    `≈ ${(cost[run] * 100).toFixed(1)} Cent (${(cost[run] * 100 / list.length).toFixed(2)} Cent/Seite)`);
}

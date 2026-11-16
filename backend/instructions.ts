// Bauanleitung → Teile pro Bauschritt (einmalig pro Set, über die Batch-API zum halben Preis).
// Alte Anleitungen (vor ~2010) haben keine Teilekästen pro Schritt: Claude vergleicht jeden Schritt mit dem vorigen.
// Kontrolle: Summe aller Schritte darf die BrickLink-Teileliste nicht überschreiten (und soll sie am Ende ergeben).
//
// node --experimental-strip-types instructions.ts <teileliste.named.csv> <anleitung.pdf> <von> <bis> <ausgabe.json> [fokus.json]
// Mit fokus.json (Teile, die ein erster Durchgang nicht gefunden hat): gründlicher Durchgang, Seite in zwei Hälften
// in doppelter Auflösung, Hinweis auf die fehlenden Teile.
// z. B. ~/LegoScanner-data/sets/10132-1.named.csv ~/LegoScanner-data/instructions/10132/4280197.pdf 3 13 tuete1.json
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import Anthropic from "@anthropic-ai/sdk";

process.env.ANTHROPIC_API_KEY ??= readFileSync(`${homedir()}/.config/legoscanner/anthropic_api_key`, "utf8").trim();
const client = new Anthropic();
const [csvPath, pdfPath, fromArg, toArg, outPath, focusPath] = process.argv.slice(2);
const focus: Record<string, number> | null = focusPath ? JSON.parse(readFileSync(focusPath, "utf8")) : null;
const from = Number(fromArg), to = Number(toArg);

// Teileliste: qty;part;color;name → Schlüssel "part|color" (nur diese Werte darf Claude nennen)
const inventory = readFileSync(csvPath, "utf8").trim().split("\n").slice(1).map((line) => {
  const [qty, part, color, name] = line.split(";");
  return { key: `${part}|${color}`, qty: Number(qty), name };
});
const keys = inventory.map((i) => i.key);

// Kalibrierung: 80 dpi → Seite ≈ 1560 px breit, genau die Größe, die Claude ohne Verkleinern nimmt (≈ 2.300 Tokens).
const dir = mkdtempSync(join(tmpdir(), "anleitung-"));
const page = (n: number) => {
  execFileSync("pdftoppm", ["-r", "80", "-jpeg", "-jpegopt", "quality=85", "-f", `${n}`, "-l", `${n}`, "-singlefile", pdfPath, join(dir, `s${n}`)]);
  return readFileSync(join(dir, `s${n}.jpg`)).toString("base64");
};
// Gründlicher Durchgang: linke und rechte Hälfte einzeln in ~160 dpi (je ≈ 1.560 px hoch, Claudes Höchstmaß)
const halves = (n: number) =>
  [0, 1].map((i) => {
    const file = join(dir, `h${n}_${i}.jpg`);
    execFileSync("pdftoppm", ["-r", "160", "-jpeg", "-jpegopt", "quality=88", "-f", `${n}`, "-l", `${n}`, "-singlefile", pdfPath, join(dir, `f${n}`)]);
    // Hälfte ausschneiden (mit 3 % Überlappung zur Mitte), längste Seite 1.568 px
    execFileSync(`${homedir()}/LegoScanner-data/venv/bin/python`, ["-c",
      `from PIL import Image; im=Image.open(${JSON.stringify(join(dir, `f${n}.jpg`))}); w,h=im.size; ` +
      `c=im.crop((0,0,int(w*0.53),h)) if ${i}==0 else im.crop((int(w*0.47),0,w,h)); c.thumbnail((1568,1568)); c.save(${JSON.stringify(file)}, quality=88)`]);
    return readFileSync(file).toString("base64");
  });

const PROMPT = `Du liest eine LEGO-Bauanleitung von 2004 und schreibst für jeden nummerierten Bauschritt auf, welche Teile in diesem Schritt neu verbaut werden.

Die Anleitung hat KEINE Teilekästen pro Schritt. Du erkennst die neuen Teile, indem du das Bild eines Schritts mit dem vorigen Schritt vergleichst (auf derselben Seite, oder beim ersten Schritt einer Seite mit dem letzten Schritt der vorigen Seite, die du ebenfalls bekommst).

Regeln:
- Nur Schritte der AKTUELLEN Seite auswerten. Die vorige Seite dient nur zum Vergleich.
- Gelbe Kästen zeigen eine Unterbaugruppe, die separat gebaut und im zugehörigen Schritt angebaut wird. Ihre Teile zählen zu diesem Schritt. "2x" im Kasten heißt: die Baugruppe zweimal bauen, also jedes Teil doppelt.
- Ein Kasten mit einem fertigen Modell oben links ist nur eine Vorschau, keine Teile.
- Zähle genau: Noppen zählen hilft bei Platten und Steinen (z. B. 1 x 4 gegen 1 x 6). Achte auf Teile, die teilweise verdeckt sind.
- Nenne nur Teile aus der Teileliste unten (Feld item = "Teilenummer|Farbe"). Bedruckte Teile und Aufkleber-Teile stehen dort mit eigener Nummer.
- Minifiguren, Schienen und Netzteil ignorieren.
- uncertain: kurze Notiz zu Stellen, die du nicht sicher erkennst (sonst leer).

Teileliste des Sets (Anzahl;Teilenummer|Farbe;Name):
${inventory.map((i) => `${i.qty};${i.key};${i.name}`).join("\n")}`;

const SCHEMA = {
  type: "object",
  properties: {
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
              properties: { item: { type: "string", enum: keys }, qty: { type: "integer" } },
              required: ["item", "qty"],
              additionalProperties: false,
            },
          },
          uncertain: { type: "string" },
        },
        required: ["step", "parts", "uncertain"],
        additionalProperties: false,
      },
    },
  },
  required: ["steps"],
  additionalProperties: false,
};

const pages = Array.from({ length: to - from + 1 }, (_, i) => from + i);
const batch = await client.messages.batches.create({
  requests: pages.map((n) => ({
    custom_id: `seite-${n}`,
    params: {
      model: "claude-opus-5-5",
      max_tokens: 32000,
      thinking: { type: "adaptive" as const },
      output_config: { effort: (focus ? "medium" : "high") as "medium" | "high", format: { type: "json_schema" as const, schema: SCHEMA } },
      system: [{ type: "text" as const, text: PROMPT, cache_control: { type: "ephemeral" as const } }],
      messages: [{
        role: "user" as const,
        content: [
          { type: "text" as const, text: `Vorige Seite ${n - 1} (nur zum Vergleich):` },
          { type: "image" as const, source: { type: "base64" as const, media_type: "image/jpeg" as const, data: page(n - 1) } },
          ...(focus
            ? [
                { type: "text" as const, text: `Aktuelle Seite ${n} in zwei Hälften in hoher Auflösung (links, dann rechts). Werte alle Schritte dieser Seite aus.` },
                ...halves(n).map((data) => ({ type: "image" as const, source: { type: "base64" as const, media_type: "image/jpeg" as const, data } })),
                { type: "text" as const, text: `Ein erster Durchgang hat diese Teile des Sets keinem Schritt zugeordnet (Teilenummer|Farbe: fehlende Anzahl). Achte besonders darauf, ob sie auf dieser Seite verbaut werden, z. B. verdeckt, klein oder in Unterbaugruppen:\n${Object.entries(focus).map(([k, q]) => `${k}: ${q}`).join("\n")}` },
              ]
            : [
                { type: "text" as const, text: `Aktuelle Seite ${n}: werte alle Schritte dieser Seite aus.` },
                { type: "image" as const, source: { type: "base64" as const, media_type: "image/jpeg" as const, data: page(n) } },
              ]),
        ],
      }],
    },
  })),
});
console.log(`Batch ${batch.id}: Seiten ${from}–${to}, warte …`);
while ((await client.messages.batches.retrieve(batch.id)).processing_status !== "ended") {
  await new Promise((resolve) => setTimeout(resolve, 20_000));
}

type Step = { page: number; step: number; parts: { item: string; qty: number }[]; uncertain: string };
const steps: Step[] = [];
let input = 0, cached = 0, output = 0;
for await (const r of await client.messages.batches.results(batch.id)) {
  const n = Number(r.custom_id.split("-")[1]);
  if (r.result.type !== "succeeded") { console.log(`Seite ${n}: ${r.result.type}`); continue; }
  const m = r.result.message;
  input += m.usage.input_tokens + (m.usage.cache_creation_input_tokens ?? 0);
  cached += m.usage.cache_read_input_tokens ?? 0;
  output += m.usage.output_tokens;
  const text = m.content.find((b) => b.type === "text");
  if (!text || text.type !== "text") { console.log(`Seite ${n}: keine Antwort (${m.stop_reason})`); continue; }
  for (const s of JSON.parse(text.text).steps) steps.push({ page: n, ...s });
}
steps.sort((a, b) => a.page - b.page || a.step - b.step);
writeFileSync(outPath, JSON.stringify(steps, null, 1));

// Summe gegen die Teileliste
const used = new Map<string, number>();
for (const s of steps) for (const p of s.parts) used.set(p.item, (used.get(p.item) ?? 0) + p.qty);
const over = [...used].filter(([k, q]) => q > (inventory.find((i) => i.key === k)?.qty ?? 0));
console.log(`${steps.length} Schritte, ${[...used.values()].reduce((a, b) => a + b, 0)} Teile.`);
console.log(over.length ? `Mehr als im Set: ${over.map(([k, q]) => `${k} ${q}/${inventory.find((i) => i.key === k)?.qty}`).join(", ")}` : "Keine Überzählung.");
for (const s of steps) if (s.uncertain) console.log(`  S. ${s.page} Schritt ${s.step}: ${s.uncertain}`);
const dollars = (input * 4 + cached * 0.2 + output * 20) / 1e6 / 2; // Batch halbiert
console.log(`Kosten: ≈ ${(dollars * 100).toFixed(0)} Cent`);

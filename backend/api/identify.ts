import Anthropic from "@anthropic-ai/sdk";
import bricklinkColors from "../data/bricklink_colors.json" with { type: "json" };

/** BrickLink-Farbname → BrickLink-Farb-ID (von bricklink.com/catalogColors.asp). */
const colorIds: Record<string, number> = bricklinkColors;
const colorNames = Object.keys(colorIds);

export type Part = {
  partNo: string; // BrickLink-Teilenummer
  name: string;
  colorName: string; // exakter BrickLink-Farbname
  colorId: number | null; // BrickLink-Farb-ID für Links/API
  confidence: number; // 0–1, nur das Teil (Form); die Farbe ändert der Nutzer bei Bedarf im Warenkorb
  box: { x: number; y: number; w: number; h: number }; // Anteile 0–1, Ursprung oben links
};

// Gemessen am 15.11.2026 (11 Testbilder): Opus 5.5 medium 8/9 richtig, Ø 5,2 s; Sonnet/Haiku ≤ 3/9.
const MODEL = "claude-opus-5-5";
const EFFORT = "medium" as const;

const PROMPT = `Du bist ein LEGO-Experte und identifizierst LEGO-Teile auf Fotos einer Handykamera.

Liste jedes echte LEGO-Element, das im Bild zu sehen ist, mit:
- bricklink_part: die Teilenummer aus dem BrickLink-Katalog (z. B. "3001", "3795", "60478"), ohne Farbzusatz
- name: der englische BrickLink-Katalogname
- bricklink_color: der BrickLink-Farbname (nur Werte aus der erlaubten Liste)
- confidence: 0 bis 1, wie sicher du dir bei der Teilenummer bist (nur die Form, nicht die Farbe)
- box: Lage im Bild als Anteile 0–1 (x, y = linke obere Ecke, w, h = Breite, Höhe)

Hinweise:
- Wichtigstes Ziel ist die exakte Teilenummer. Achte auf Details, die ähnliche Teile unterscheiden (Noppenzahl, Löcher, Achslöcher, Kanten, Aussparungen, Höhe Plate/Brick). Eine unsichere Farbe senkt die confidence nicht.
- Handyfotos haben Weißabgleich- und Belichtungsfehler. Beurteile die Farbe so, wie ein erfahrener Sammler das Teil benennen würde, nicht nach rohen Pixelwerten. Achte besonders auf ähnliche Farben (Dark Bluish Gray vs. Light Bluish Gray, Tan vs. Dark Tan, Sand Green vs. Dark Bluish Gray, Yellow vs. Neon Yellow).
- Holzmaserung, Tische, Tassen, Laptops und andere Gegenstände sind KEINE LEGO-Teile. Ist kein LEGO-Teil zu sehen, gib eine leere Liste zurück.
- Teile, die nur angeschnitten am Bildrand liegen, nur mit niedriger confidence.
- Nur Teile, die tatsächlich sichtbar sind; nichts erfinden.`;


const SCHEMA = {
  type: "object",
  properties: {
    parts: {
      type: "array",
      items: {
        type: "object",
        properties: {
          bricklink_part: { type: "string" },
          name: { type: "string" },
          bricklink_color: { type: "string", enum: colorNames }, // nur echte BrickLink-Farben
          confidence: { type: "number" },
          box: {
            type: "object",
            properties: { x: { type: "number" }, y: { type: "number" }, w: { type: "number" }, h: { type: "number" } },
            required: ["x", "y", "w", "h"],
            additionalProperties: false,
          },
        },
        required: ["bricklink_part", "name", "bricklink_color", "confidence", "box"],
        additionalProperties: false,
      },
    },
  },
  required: ["parts"],
  additionalProperties: false,
};

type RawPart = {
  bricklink_part: string;
  name: string;
  bricklink_color: string;
  confidence: number;
  box: { x: number; y: number; w: number; h: number };
};

const client = new Anthropic();

/** Anfrage an Claude für ein Foto (JPEG, Base64). Auch für Batch-Tests in test.ts. */
/** Teileliste der Sets, die der Nutzer gerade zusammensucht, als Kandidaten für Claude.
 *  Kommt vom eigenen /api/sets (im Vercel-Cache, kostet also nichts). */
async function candidates(setNos: string[], origin: string, appKey: string): Promise<string> {
  const lines = new Set<string>();
  for (const no of setNos.slice(0, 5)) {
    const response = await fetch(`${origin}/api/sets?no=${encodeURIComponent(no)}`, { headers: { "x-app-key": appKey } }).catch(() => null);
    if (!response?.ok) continue;
    const set: { parts: { part: string; color: string; name: string }[] } = await response.json();
    for (const p of set.parts) lines.add(`${p.part} | ${p.name} | ${p.color}`);
  }
  if (!lines.size) return "";
  return `Der Nutzer sucht die Teile dieser Sets aus einer gemischten Kiste zusammen. Fast alle Teile im Bild stammen aus dieser Liste (Teilenummer | Name | Farbe). Wähle bevorzugt daraus, auch die Farbe. Nur wenn ein Teil eindeutig nicht dazu passt, nenne ein anderes BrickLink-Teil.\n${[...lines].join("\n")}`;
}

export function request(jpegBase64: string, setHint = "") {
  return {
    model: MODEL,
    max_tokens: 16000,
    output_config: { effort: EFFORT, format: { type: "json_schema" as const, schema: SCHEMA } },
    // Fester Teil (Prompt + Farbliste im Schema) als System-Prompt mit Cache: kostet beim Wiederholen nur 5 %.
    // Kandidaten als zweiter Block mit eigenem Cache: gleich für alle Scans, solange dieselben Sets aktiv sind.
    system: [
      { type: "text" as const, text: PROMPT, cache_control: { type: "ephemeral" as const } },
      ...(setHint ? [{ type: "text" as const, text: setHint, cache_control: { type: "ephemeral" as const } }] : []),
    ],
    messages: [
      {
        role: "user" as const,
        content: [{ type: "image" as const, source: { type: "base64" as const, media_type: "image/jpeg" as const, data: jpegBase64 } }],
      },
    ],
  };
}

/** Claude-Antwort → erkannte LEGO-Teile. Leere Liste = kein LEGO im Bild. */
export function parse(message: { stop_reason: string | null; content: { type: string; text?: string }[] }): Part[] {
  if (message.stop_reason === "refusal") return [];
  const text = message.content.find((block) => block.type === "text")?.text;
  if (!text) throw new Error(`Keine Antwort (stop_reason ${message.stop_reason})`);
  const parts: RawPart[] = JSON.parse(text).parts;
  return parts.map((p) => ({
    partNo: p.bricklink_part,
    name: p.name,
    colorName: p.bricklink_color,
    colorId: colorIds[p.bricklink_color] ?? null,
    confidence: Math.min(1, Math.max(0, p.confidence)),
    box: p.box,
  }));
}

/** Foto (JPEG, Base64) → erkannte LEGO-Teile. */
export async function identify(jpegBase64: string, setHint = ""): Promise<Part[]> {
  const response = await client.beta.messages.create({
    ...request(jpegBase64, setHint),
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default", // lehnt das Modell ab (bei LEGO-Fotos unwahrscheinlich), übernimmt automatisch ein anderes
  });
  // Kosten im Vercel-Log: input/output-Tokens pro Anfrage
  console.log("usage", response.usage.input_tokens, response.usage.cache_creation_input_tokens, response.usage.cache_read_input_tokens, response.usage.output_tokens);
  return parse(response);
}

const MAX_BYTES = 4_000_000; // Vercel-Grenze für Anfragen: 4,5 MB

/** POST /api/identify — Body: JPEG-Bytes. Antwort: { parts, ms }. */
export async function POST(request: Request): Promise<Response> {
  // ponytail: gemeinsames App-Geheimnis, reicht für Tests. Vor dem App Store durch App Attest ersetzen.
  const appKey = process.env.APP_KEY;
  if (appKey && request.headers.get("x-app-key") !== appKey) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.length === 0 || bytes.length > MAX_BYTES) {
    return Response.json({ error: "Bild fehlt oder ist größer als 4 MB" }, { status: 400 });
  }
  const started = Date.now();
  try {
    // x-sets: "10132-1,6086-1" = Sets, die der Nutzer gerade zusammensucht
    const setNos = (request.headers.get("x-sets") ?? "").split(",").filter(Boolean);
    const setHint = setNos.length ? await candidates(setNos, new URL(request.url).origin, appKey ?? "") : "";
    const parts = await identify(Buffer.from(bytes).toString("base64"), setHint);
    return Response.json({ parts, ms: Date.now() - started });
  } catch (error) {
    console.error("identify fehlgeschlagen:", error);
    return Response.json({ error: "Erkennung fehlgeschlagen" }, { status: 502 });
  }
}

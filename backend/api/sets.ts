import set10132 from "../data/sets/10132-1.json" with { type: "json" };
import set21324 from "../data/sets/21324-1.json" with { type: "json" };
import omrIndex from "../data/omr_index.json" with { type: "json" };
import bricklinkRgb from "../data/bricklink_rgb.json" with { type: "json" };

// Bauabschnitte, einheitlich für alle Sets (die App zeigt sie immer gleich):
// 1. eigene Daten (Anleitung ausgelesen, tools/build_set.py), z. B. 10132
// 2. LDraw-Modellarchiv (OMR, ~1.500 Sets): Teilmodelle = Abschnitte, mit exakten Bauschritten, ohne KI
// 3. sonst ein Abschnitt „Ganzes Set“
// Teileliste immer von Rebrickable, mit BrickLink-Nummern für Teile und Farben.
const withSections: Record<string, unknown> = { "10132-1": set10132, "21324-1": set21324 };
const omr: Record<string, string> = omrIndex;
// BrickLink-Farb-ID → RGB (von Rebrickable): Die App erkennt die Form selbst und wählt die Farbe per Pixelvergleich
const rgb: Record<string, string> = bricklinkRgb;

const REBRICKABLE = "https://rebrickable.com/api/v3/lego";

type Ext = { ext_ids: number[]; ext_descrs: string[][] };
type RbPart = {
  quantity: number;
  is_spare: boolean;
  part: { part_num: string; name: string; part_cat_id?: number; external_ids?: { BrickLink?: string[]; LDraw?: string[] } };
  color: { name: string; external_ids?: { BrickLink?: Ext; LDraw?: Ext } };
};
type Item = { part: string; color: string; colorId: number | null; name: string; qty: number };
type Need = { part: string; color: string; qty: number };
type Section = { name: string; bag: string; pages: string; steps: { page: number; step: number; parts: Need[] }[]; parts: Need[] };

// Große Sets (über 5.000 Teile) brauchen viele Rebrickable-Seiten
export const maxDuration = 120;

async function rebrickable(path: string) {
  const key = process.env.REBRICKABLE_API_KEY;
  if (!key) throw new Error("REBRICKABLE_API_KEY fehlt");
  // Rebrickable bricht langsame Seiten nach ~30 s mit 502 ab und drosselt mit 429: kurz warten, bis zu 3-mal neu
  for (let attempt = 1; ; attempt++) {
    const response = await fetch(path.startsWith("http") ? path : `${REBRICKABLE}${path}`, {
      headers: { Authorization: `key ${key}` },
      signal: AbortSignal.timeout(20_000),
    }).catch((error) => error as Error);
    if (!(response instanceof Error)) {
      if (response.status === 404) return null;
      if (response.ok) return response.json();
    }
    const reason = response instanceof Error ? response.message : `Rebrickable ${response.status}`;
    const retryable = response instanceof Error || [429, 500, 502, 503, 504].includes(response.status);
    if (!retryable || attempt >= 3) throw new Error(reason);
    await new Promise((resolve) => setTimeout(resolve, 1500 * attempt));
  }
}

/** Set von Rebrickable → unser Format (BrickLink-Teilenummern und -Farben, Ersatzteile weggelassen). */
async function fromRebrickable(no: string) {
  const info = await rebrickable(`/sets/${encodeURIComponent(no)}/`);
  if (!info) return null;
  const parts = new Map<string, Item>();
  const ldraw = new Map<string, string>(); // "ldrawTeil|ldrawFarbe" → "BrickLink-Teil|BrickLink-Farbe"
  let next: string | null = `/sets/${encodeURIComponent(no)}/parts/?page_size=250&inc_part_details=1&inc_color_details=1`;
  while (next) {
    const page: { results: RbPart[]; next: string | null } = await rebrickable(next);
    for (const p of page.results) {
      if (p.is_spare || p.part.part_cat_id === 58) continue; // Ersatzteile und Aufkleberbögen (Kategorie 58) zählen nicht
      const part = p.part.external_ids?.BrickLink?.[0] ?? p.part.part_num;
      const bl = p.color.external_ids?.BrickLink;
      const color = bl?.ext_descrs?.[0]?.[0] ?? p.color.name;
      const key = `${part}|${color}`;
      const item = parts.get(key) ?? { part, color, colorId: bl?.ext_ids?.[0] ?? null, name: p.part.name, qty: 0 };
      item.qty += p.quantity;
      parts.set(key, item);
      for (const lp of [...(p.part.external_ids?.LDraw ?? []), p.part.part_num]) {
        for (const lc of p.color.external_ids?.LDraw?.ext_ids ?? []) ldraw.set(`${lp.toLowerCase()}|${lc}`, key);
      }
    }
    next = page.next;
  }
  const list = [...parts.values()].sort((a, b) => a.color.localeCompare(b.color) || a.name.localeCompare(b.name));
  let sections: Section[] | null = null;
  if (omr[info.set_num]) {
    try {
      const mpd = await fetch(omr[info.set_num]).then((r) => (r.ok ? r.text() : ""));
      sections = mpd ? sectionsFromMpd(mpd, list, ldraw) : null;
    } catch (error) {
      console.error("OMR fehlgeschlagen:", info.set_num, error);
    }
  }
  return {
    no: info.set_num,
    name: info.name,
    year: info.year,
    image: info.set_img_url ?? `https://img.bricklink.com/ItemImage/SN/0/${info.set_num}.png`,
    parts: list,
    sections: sections ?? [{ name: "Ganzes Set", bag: "", pages: "", steps: [], parts: list.map(({ part, color, qty }) => ({ part, color, qty })) }],
  };
}

/** LDraw-Modell (MPD) → Bauabschnitte. Jedes Teilmodell des Hauptmodells wird ein Abschnitt mit seinen Bauschritten.
 *  Teile werden über die LDraw-Nummern von Rebrickable auf die Teileliste abgebildet und nie über deren Menge hinaus
 *  gezählt. Was übrig bleibt (z. B. nicht modellierte Teile), kommt in „Weitere Teile“. */
export function sectionsFromMpd(mpd: string, inventory: Item[], ldraw: Map<string, string>): Section[] | null {
  const files = new Map<string, string[]>();
  let current: string[] | null = null;
  let first = "";
  for (const line of mpd.split(/\r?\n/)) {
    const m = line.match(/^0\s+FILE\s+(.+?)\s*$/i);
    if (m) {
      current = [];
      files.set(m[1].toLowerCase(), current);
      first ||= m[1].toLowerCase();
    } else if (/^0\s+NOFILE/i.test(line)) current = null;
    else current?.push(line);
  }
  if (!first) {
    first = "main";
    files.set(first, mpd.split(/\r?\n/));
  }

  type Placed = { part: string; color: number };
  // Ganzes Modell als eine Bau-Reihenfolge: Ein Teilmodell wird gebaut (seine Schritte), bevor es angebaut wird.
  const linear = (name: string, color: number, depth = 0): Placed[][] => {
    const out: Placed[][] = [];
    let step: Placed[] = [];
    for (const line of files.get(name) ?? []) {
      if (/^0\s+(ROT)?STEP\b/i.test(line)) {
        if (step.length) out.push(step);
        step = [];
        continue;
      }
      const f = line.trim().split(/\s+/);
      if (f[0] !== "1" || f.length < 15) continue;
      const c = Number(f[1]) === 16 ? color : Number(f[1]); // 16 = Farbe des übergeordneten Modells
      const ref = f.slice(14).join(" ").toLowerCase();
      if (files.has(ref) && depth < 10) out.push(...linear(ref, c, depth + 1));
      else step.push({ part: ref.replace(/\.dat$/, "").replace(/^.*[\\/]/, ""), color: c });
    }
    if (step.length) out.push(step);
    return out;
  };

  const left = new Map(inventory.map((i) => [`${i.part}|${i.color}`, i.qty]));
  // LDraw-Teil ohne Varianten-/Druckzusatz: "3062b" → "3062", "3626bp01" → "3626"
  const base = (part: string) => part.replace(/(p[a-z0-9]{1,4}|[a-d])$/, "").replace(/[a-d]$/, "");
  const byBase = new Map<string, string[]>(); // "basis|farbe" → Schlüssel der Teileliste
  const byPart = new Map<string, string[]>(); // "teil" → Schlüssel (alle Farben)
  for (const [k, key] of ldraw) {
    const [part, color] = k.split("|");
    byBase.set(`${base(part)}|${color}`, [...(byBase.get(`${base(part)}|${color}`) ?? []), key]);
    byPart.set(base(part), [...(byPart.get(base(part)) ?? []), key]);
  }
  const free = (key?: string) => (key && left.get(key) ? key : undefined);
  const take = (p: Placed): string | null => {
    // 1. exakt, 2. gleiche Form ohne Variante/Druck in gleicher Farbe,
    // 3. gleiche Form, falls sie noch in genau einer Farbe gebraucht wird (Farbcodes von LDraw und Rebrickable weichen
    //    bei alten Farben ab, z. B. altes Grau)
    const key =
      free(ldraw.get(`${p.part}|${p.color}`)) ??
      byBase.get(`${base(p.part)}|${p.color}`)?.find((k) => left.get(k)) ??
      (() => {
        const open = [...new Set(byPart.get(base(p.part)) ?? [])].filter((k) => left.get(k));
        return open.length === 1 ? open[0] : undefined;
      })();
    if (!key) return null;
    left.set(key, left.get(key)! - 1);
    return key;
  };
  const toNeeds = (keys: string[]): Need[] => {
    const counts = new Map<string, number>();
    for (const k of keys) counts.set(k, (counts.get(k) ?? 0) + 1);
    return [...counts].map(([k, qty]) => ({ part: k.split("|")[0], color: k.split("|")[1], qty }));
  };

  // Schritte auf die Teileliste abbilden (Minifiguren u. Ä. fallen weg, weil sie nicht in der Teileliste stehen)
  const steps = linear(first, 7).map((s) => s.map(take).filter((k): k is string => k !== null)).filter((s) => s.length);
  const total = steps.reduce((a, s) => a + s.length, 0);
  if (!total) return null;
  // In gleich große Abschnitte teilen, wie LEGOs nummerierte Tüten.
  // Kalibrierung: etwa 120 Teile pro Abschnitt, höchstens 12 Abschnitte.
  const count = Math.max(1, Math.min(12, Math.round(total / 120)));
  const sections: Section[] = [];
  let bucket: string[][] = [];
  let done = 0;
  const flush = () => {
    if (!bucket.length) return;
    const n = sections.length + 1;
    const stepNeeds = bucket.map((keys, i) => ({ page: 0, step: i + 1, parts: toNeeds(keys) }));
    sections.push({ name: `Abschnitt ${n}`, bag: "", pages: "", steps: stepNeeds, parts: toNeeds(bucket.flat()) });
    bucket = [];
  };
  for (const s of steps) {
    bucket.push(s);
    done += s.length;
    if (done >= (total * (sections.length + 1)) / count && sections.length < count - 1) flush();
  }
  flush();
  // Teile, die im Modell fehlen oder anders modelliert sind: eigener Abschnitt ohne Schritte
  const rest = [...left].filter(([, q]) => q > 0).flatMap(([k, q]) => Array(q).fill(k));
  if (rest.length) sections.push({ name: "Weitere Teile", bag: "", pages: "", steps: [], parts: toNeeds(rest) });
  return sections;
}

/** Bauanleitungen (PDF) von lego.com: pro Heft Titel, Größe, Adresse. Sehr alte Sets haben keine → leere Liste. */
async function instructions(no: string): Promise<{ title: string; size: string; url: string }[]> {
  const set = no.replace(/-1$/, "");
  try {
    const html = await fetch(`https://www.lego.com/de-de/service/building-instructions/${encodeURIComponent(set)}`, {
      headers: { "User-Agent": "Mozilla/5.0 (Macintosh)", "Accept-Language": "de-DE" },
      signal: AbortSignal.timeout(10_000),
    }).then((r) => (r.ok ? r.text() : ""));
    const list = html.split('data-test="bi-card"').slice(1).flatMap((card) => {
      const url = card.match(/href="(https:\/\/www\.lego\.com\/cdn\/product-assets\/product\.bi\.[a-z.]*pdf\/\d+\.pdf)"/)?.[1];
      if (!url) return [];
      const text = card.slice(0, 4000).replace(/<[^>]+>/g, "\n").split("\n").map((t) => t.trim()).filter(Boolean);
      const size = text.find((t) => /^[\d.,]+\s*[MK]B/i.test(t))?.replace(/\s*\(PDF\)/i, "") ?? "";
      const title = text.find((t) => /\(\d+\/\d+\)$/.test(t)) ?? text.find((t) => t !== ">" && !/^[\d.,]+\s*[MK]B/i.test(t)) ?? "Bauanleitung";
      return [{ title: title.replace(/&amp;/g, "&").replace(/&#x27;|&#39;/g, "'"), size, url }];
    });
    const part = (t: string) => Number(t.match(/\((\d+)\/\d+\)$/)?.[1] ?? 0);
    return [...new Map(list.map((i) => [i.url, i])).values()].sort((a, b) => part(a.title) - part(b.title));
  } catch {
    return [];
  }
}

/** GET /api/sets?no=10132 → Teileliste und Bauabschnitte. Vercel hält die Antwort eine Woche im Cache. */
export async function GET(request: Request): Promise<Response> {
  const appKey = process.env.APP_KEY;
  if (appKey && request.headers.get("x-app-key") !== appKey) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  const raw = (new URL(request.url).searchParams.get("no") ?? "").trim();
  if (!/^[\w.]{2,20}(-\d+)?$/.test(raw)) return Response.json({ error: "Ungültige Setnummer." }, { status: 400 });
  const no = raw.includes("-") ? raw : `${raw}-1`;
  try {
    const [found, manuals] = await Promise.all([withSections[no] ?? fromRebrickable(no), instructions(no)]);
    if (!found) return Response.json({ error: `Set ${raw} gibt es nicht.` }, { status: 404 });
    const base = found as { parts: { colorId: number | null }[] };
    const set = { ...base, parts: base.parts.map((p) => ({ ...p, rgb: p.colorId != null ? (rgb[String(p.colorId)] ?? null) : null })), instructions: manuals };
    // Öffentliche Katalogdaten: eine Woche im Vercel-Cache, danach im Hintergrund aufgefrischt
    return Response.json(set, { headers: { "Cache-Control": "public, s-maxage=604800, stale-while-revalidate=86400" } });
  } catch (error) {
    console.error("sets fehlgeschlagen:", error);
    return Response.json({ error: "Teileliste gerade nicht erreichbar." }, { status: 502 });
  }
}

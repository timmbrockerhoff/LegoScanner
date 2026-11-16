"""Set-Fabrik: ein Befehl macht aus einer Setnummer fertige Bauabschnitte (Tüten) fürs Backend.

  python3 tools/set_factory.py 21324              → zeigt Hefte, Art der Anleitung und geschätzte Kosten, startet nichts
  python3 tools/set_factory.py 21324 --ja         → liest aus (Batch-API, kostet Guthaben) und baut data/sets/21324-1.json
  python3 tools/set_factory.py 10132 --ja --tueten "Lok · Tüte 1:3-13,Tender · Tüte 2:14-18,…"
                                                  → alte Anleitung ohne Teilekästen: Tüten-Seiten von Hand angeben

Ablauf: Teileliste (eigenes /api/sets, Rebrickable) → Anleitungen von lego.com → neue oder alte Anleitung?
  neu (Teilekästen): callouts.ts liest Kästen + Tütensymbole, ein Durchgang (~0,64 Cent/Seite)
  alt (ohne Kästen): instructions.ts, zwei Durchgänge vereint (~6 Cent/Seite)
→ tools/build_set.py (Summe = Teileliste, Rest nach Teil/Farbe) → data/sets_index.json (alle Sets für das Backend).
Danach: Backend ausrollen (vercel deploy --prod --force, dann vercel cache purge --type cdn).
"""
import argparse
import csv
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
DATA = Path.home() / "LegoScanner-data"
PYTHON = str(DATA / "venv" / "bin" / "python")
API = "https://legoscanner-backend.vercel.app/api/sets"
CENT_NEW, CENT_OLD = 0.64, 6.0  # gemessen: 21324 (neu, Opus low + Kästen), 10132 (alt, zwei Durchgänge)


def run(cmd: list[str]) -> str:
    print("→", " ".join(cmd[:3]), "…", flush=True)
    return subprocess.run(cmd, check=True, capture_output=True, text=True, cwd=HERE).stdout


def pages_of(pdf: Path) -> int:
    info = subprocess.run(["pdfinfo", str(pdf)], capture_output=True, text=True).stdout
    return int(re.search(r"Pages:\s+(\d+)", info).group(1))


def is_modern(pdf: Path, pages: int) -> bool:
    """Neue Anleitung, wenn die meisten Stichprobenseiten einen kleinen Teilekasten oben haben."""
    hits = 0
    samples = [int(pages * f) for f in (0.2, 0.3, 0.4, 0.5, 0.6, 0.7)]
    for page in samples:
        boxes = json.loads(subprocess.run([PYTHON, str(HERE / "tools" / "callout_boxes.py"), str(pdf), str(page), "/tmp/set-factory"],
                                          capture_output=True, text=True).stdout)["boxes"]
        hits += any(b["w"] < 0.5 and b["y"] < 0.6 for b in boxes)
    return hits >= 4


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("--ja", action="store_true", help="wirklich auslesen (kostet Guthaben)")
    ap.add_argument("--tueten", help='alte Anleitung: "Name:von-bis,Name:von-bis" (Seiten im ersten Heft)')
    args = ap.parse_args()
    no = args.set if "-" in args.set else f"{args.set}-1"
    key = (Path.home() / ".config" / "legoscanner" / "app_key").read_text().strip()

    # 1. Teileliste und Hefte
    req = urllib.request.Request(f"{API}?no={no}", headers={"x-app-key": key})
    info = json.load(urllib.request.urlopen(req, timeout=120))
    folder = DATA / "instructions" / no.removesuffix("-1")
    folder.mkdir(parents=True, exist_ok=True)
    named = DATA / "sets" / f"{no}.named.csv"
    named.parent.mkdir(exist_ok=True)
    with named.open("w") as f:
        f.write("qty;part;color;name\n")
        for p in info["parts"]:
            f.write(f"{p['qty']};{p['part']};{p['color']};{p['name'].replace(';', ',')}\n")
    if not info.get("instructions"):
        sys.exit(f"{no} {info['name']}: keine digitale Anleitung bei LEGO. Es bleibt bei den vorhandenen Abschnitten.")

    pdfs = []
    for i, manual in enumerate(info["instructions"], 1):
        pdf = folder / Path(manual["url"]).name
        if not pdf.exists():
            urllib.request.urlretrieve(manual["url"], pdf)
        pdfs.append((i, pdf, pages_of(pdf)))
    modern = is_modern(pdfs[0][1], pdfs[0][2])
    total_pages = sum(p for _, _, p in pdfs)
    cost = total_pages * (CENT_NEW if modern else CENT_OLD) / 100
    print(f"{no} {info['name']}: {sum(p['qty'] for p in info['parts'])} Teile, {len(pdfs)} Heft(e), {total_pages} Seiten, "
          f"{'neue Anleitung mit Teilekästen' if modern else 'alte Anleitung ohne Teilekästen'}, geschätzt {cost:.2f} $")
    if not modern and not args.tueten:
        sys.exit("Alte Anleitung: Tüten-Seiten mit --tueten angeben (Tütensymbole erkennt das Skript nur in neuen Anleitungen).")
    if not args.ja:
        sys.exit("Nichts gestartet. Mit --ja auslesen.")

    # 2. Auslesen. Seiten mehrerer Hefte bekommen eindeutige Nummern: Heft 2, Seite 14 → 2014
    steps, bags = [], []
    for i, pdf, pages in pdfs:
        offset = (i - 1) * 1000
        if modern:
            out = folder / f"heft{i}.json"
            if not out.exists():
                run(["node", "--experimental-strip-types", "callouts.ts", str(named), str(pdf), f"2-{pages}", str(out), "claude-opus-5-5:low"])
            for page in next(iter(json.loads(out.read_text()).values())):
                if page["bag"]:
                    bags.append((offset + page["page"], page["bag"]))
                steps += [{"page": offset + page["page"], "step": s["step"], "parts": s["parts"]} for s in page["steps"]]
        else:
            first, second = folder / f"heft{i}_d1.json", folder / f"heft{i}_d2.json"
            if not first.exists():
                run(["node", "--experimental-strip-types", "instructions.ts", str(named), str(pdf), "2", str(pages), str(first)])
            if not second.exists():
                read: dict[str, int] = {}
                for s in json.loads(first.read_text()):
                    for p in s["parts"]:
                        read[p["item"]] = read.get(p["item"], 0) + p["qty"]
                inventory = {f"{r['part']}|{r['color']}": int(r["qty"]) for r in csv.DictReader(named.open(), delimiter=";")}
                focus = folder / f"heft{i}_fokus.json"
                focus.write_text(json.dumps({k: q - read.get(k, 0) for k, q in inventory.items() if q > read.get(k, 0)}))
                run(["node", "--experimental-strip-types", "instructions.ts", str(named), str(pdf), "2", str(pages), str(second), str(focus)])
            # beide Durchgänge vereinen: pro Schritt und Teil die größere Menge
            merged: dict[tuple, dict] = {}
            for src in (first, second):
                for s in json.loads(src.read_text()):
                    m = merged.setdefault((s["page"], s["step"]), {})
                    for p in s["parts"]:
                        m[p["item"]] = max(m.get(p["item"], 0), p["qty"])
            steps += [{"page": offset + pg, "step": st, "parts": [{"item": k, "qty": q} for k, q in parts.items()]}
                      for (pg, st), parts in sorted(merged.items())]
    flat = folder / "schritte.json"
    flat.write_text(json.dumps(steps))

    # 3. Abschnitte: eine pro Tüte (neue Anleitungen) oder wie angegeben (alte)
    sections = []
    if modern and bags:
        bags.sort()
        last = max(s["page"] for s in steps)
        for k, (start, bag) in enumerate(bags):
            end = bags[k + 1][0] - 1 if k + 1 < len(bags) else last
            begin = 0 if k == 0 else start
            sections.append(f"Abschnitt {k + 1}|Tüte {bag}|{begin}–{end}|{flat}")
    elif modern:  # keine Tüten erkannt: ein Abschnitt pro Heft
        sections = [f"Abschnitt {i}|Heft {i}|{(i - 1) * 1000}–{(i - 1) * 1000 + pages}|{flat}" for i, _, pages in pdfs]
    else:
        for k, spec in enumerate(args.tueten.split(","), 1):
            name, rng = spec.rsplit(":", 1)
            sections.append(f"Abschnitt {k}|{name.strip()}|{rng.replace('-', '–')}|{flat}")
    print(run([sys.executable, "tools/build_set.py", no, info["name"], str(info["year"]), str(named), *sections]).strip())
    rebuild_index()
    print("Fertig. Jetzt Backend ausrollen und den CDN-Cache leeren.")


def rebuild_index():
    """Alle aufbereiteten Sets in eine Datei, die api/sets.ts lädt."""
    index = {p.stem: json.loads(p.read_text()) for p in sorted((HERE / "data" / "sets").glob("*.json"))}
    (HERE / "data" / "sets_index.json").write_text(json.dumps(index, ensure_ascii=False))
    print(f"data/sets_index.json: {len(index)} Sets ({', '.join(index)})")


if __name__ == "__main__":
    if sys.argv[1:] == ["--index"]:
        rebuild_index()
    else:
        main()

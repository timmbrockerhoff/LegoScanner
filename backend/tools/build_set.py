"""Set-Daten fürs Backend bauen: BrickLink-Teileliste + Bauabschnitte aus der ausgelesenen Anleitung.

python3 tools/build_set.py 10132-1 "Motorisierter Hogwarts Express" 2004 \
    ~/LegoScanner-data/sets/10132-1.named.csv \
    "Abschnitt 1|Lok · Tüte 1|3–13|~/LegoScanner-data/instructions/10132/tuete1.json" \
    "Abschnitt 2|Tender · Tüte 2|14–18|…/tuete2-5.json" "Abschnitt 3|Passagierwaggon · Tüte 3|19–27|…/tuete2-5.json" "Abschnitt 4|Bahnhof · Tüten 4 + 5|28–50|…/tuete2-5.json"
→ data/sets/10132-1.json

Statt einer Schritt-Datei geht auch "teile:2865c01,2867c01": diese Teile vollständig (z. B. Schienen, die keiner Tüte angehören).
Seiten (z. B. "14–18") filtern die Schritte einer gemeinsamen Schritt-Datei auf diesen Abschnitt.
Ein Abschnitt ohne Schritt-Datei bekommt alle Teile, die übrig sind (Rest der Teileliste).
Bleiben nach allen Abschnitten Teile übrig (Lesefehler), kommen sie in „Weitere Teile“: Die Summe stimmt immer.
Ausgelesene Mengen werden auf die Teileliste begrenzt: ein Abschnitt kann nie mehr brauchen, als das Set hat.
"""
import csv
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
# Nicht scanbar oder kein Bauteil: Stickerbogen, Netzteile
SKIP = {"10132stk01", "70931", "70928", "70930", "71140"}

no, name, year, csv_path, *section_args = sys.argv[1:]
color_ids = json.loads((HERE / "data" / "bricklink_colors.json").read_text())

inventory = {}  # "part|color" → {part, color, colorId, name, qty}
for row in csv.DictReader(open(os.path.expanduser(csv_path)), delimiter=";"):
    if row["part"] in SKIP:
        continue
    key = f"{row['part']}|{row['color']}"
    item = inventory.setdefault(key, {"part": row["part"], "color": row["color"],
                                      "colorId": color_ids.get(row["color"]), "name": row["name"], "qty": 0})
    item["qty"] += int(row["qty"])

left = {k: v["qty"] for k, v in inventory.items()}
sections = []
for arg in section_args:
    title, bag, pages, steps_path = arg.split("|")
    steps = []
    if steps_path.startswith("teile:"):
        wanted = set(steps_path[6:].split(","))
        need = {k: q for k, q in left.items() if q and k.split("|")[0] in wanted}
        for k in need:
            left[k] = 0
    elif steps_path:
        lo, hi = (int(x) for x in pages.replace("–", "-").split("-")) if "-" in pages.replace("–", "-") else (0, 10**6)
        for s in json.load(open(os.path.expanduser(steps_path))):
            if not lo <= s["page"] <= hi:
                continue
            parts = []
            for p in s["parts"]:
                take = min(p["qty"], left.get(p["item"], 0))
                if take:
                    left[p["item"]] -= take
                    part, color = p["item"].split("|")
                    parts.append({"part": part, "color": color, "qty": take})
            if parts:
                steps.append({"page": s["page"], "step": s["step"], "parts": parts})
        need = {}
        for s in steps:
            for p in s["parts"]:
                k = f"{p['part']}|{p['color']}"
                need[k] = need.get(k, 0) + p["qty"]
    else:  # Rest
        need = {k: q for k, q in left.items() if q}
        left = {k: 0 for k in left}
    sections.append({
        "name": title, "bag": bag, "pages": pages, "steps": steps,
        "parts": [{"part": k.split("|")[0], "color": k.split("|")[1], "qty": q} for k, q in need.items()],
    })

# Übrige Teile (zu wenig gelesen) verteilen, ohne KI:
# 1. gleiches Teil + Farbe steht schon in einer Tüte → dorthin (im Verhältnis der gelesenen Mengen)
# 2. sonst nach Farbe: in die Tüte, in der die Farbe am häufigsten ist (Lok/Waggons rot-schwarz, Bahnhof grau/sandgrün …)
# Nur Tüten mit gelesenen Schritten nehmen teil. Verteilte Teile stehen in keinem Schritt („baubar bis“ bleibt ehrlich).
read = [sec for sec in sections if sec["steps"]]
estimated = 0
for k, q in list(left.items()):
    if not q or not read:
        continue
    part, color = k.split("|")
    holders = [(sec, next((p["qty"] for p in sec["parts"] if p["part"] == part and p["color"] == color), 0)) for sec in read]
    holders = [(sec, n) for sec, n in holders if n]
    if not holders:
        by_color = [(sec, sum(p["qty"] for p in sec["parts"] if p["color"] == color)) for sec in read]
        best = max(by_color, key=lambda x: x[1])
        holders = [best] if best[1] else []
    if not holders:
        continue
    total = sum(n for _, n in holders)
    for i, (sec, n) in enumerate(holders):
        share = q - sum(round(q * m / total) for _, m in holders[:-1]) if i == len(holders) - 1 else round(q * n / total)
        if share <= 0:
            continue
        hit = next((p for p in sec["parts"] if p["part"] == part and p["color"] == color), None)
        if hit:
            hit["qty"] += share
        else:
            sec["parts"].append({"part": part, "color": color, "qty": share})
        estimated += share
    left[k] = 0
print(f"nach Teil/Farbe verteilt: {estimated} Teile")

rest = {k: q for k, q in left.items() if q}
if rest:
    sections.append({"name": "Weitere Teile", "bag": "", "pages": "", "steps": [],
                     "parts": [{"part": k.split("|")[0], "color": k.split("|")[1], "qty": q} for k, q in rest.items()]})

out = {
    "no": no, "name": name, "year": int(year),
    "image": f"https://img.bricklink.com/ItemImage/SN/0/{no}.png",
    "parts": sorted(inventory.values(), key=lambda p: (p["color"], p["name"])),
    "sections": sections,
}
path = HERE / "data" / "sets" / f"{no}.json"
path.parent.mkdir(exist_ok=True)
path.write_text(json.dumps(out, ensure_ascii=False, indent=1))
total = sum(p["qty"] for p in out["parts"])
print(f"{path.name}: {total} Teile, " + ", ".join(f"{s['name']} {sum(p['qty'] for p in s['parts'])}" for s in sections))

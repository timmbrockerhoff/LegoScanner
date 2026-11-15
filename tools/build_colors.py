"""Baut LegoScanner/colors.json aus den freien Rebrickable-Downloads.

Läuft jede Woche automatisch per GitHub Actions (.github/workflows/colors.yml).
Die App lädt die neue Datei dann selbst von GitHub nach. Lokal: python3 tools/build_colors.py
BrickLink-IDs kommen aus tools/bricklink_colors.json (BrickLink-Name → [ID, offizieller
LEGO-Name], von bricklink.com/catalogColors.asp). Neue BrickLink-Farben dort nachtragen.
"""
import csv, datetime, gzip, io, json, pathlib, urllib.request
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent
CDN = "https://cdn.rebrickable.com/media/downloads/"


def rows(name):
    with urllib.request.urlopen(CDN + name + ".csv.gz") as r:
        return list(csv.DictReader(io.TextIOWrapper(gzip.GzipFile(fileobj=r), "utf-8")))


by_bl_name, by_lego_name = {}, {}
for bl_name, (bl_id, lego_name) in json.loads((ROOT / "tools/bricklink_colors.json").read_text()).items():
    by_bl_name[bl_name.lower()] = bl_id
    if lego_name:
        by_lego_name.setdefault(lego_name.lower(), bl_id)


def bricklink_id(rb_name):
    """Rebrickable nutzt meist BrickLink-Namen, manchmal den LEGO-Namen; "Opal" heißt bei BrickLink "Satin"."""
    n = rb_name.lower()
    return by_bl_name.get(n) or by_bl_name.get(n.replace("opal ", "satin ")) or by_lego_name.get(n)


colors, unmatched = {}, []
for c in rows("colors"):
    cid = int(c["id"])
    if cid < 0 or cid == 9999:  # [Unknown], [No Color]
        continue
    bl = bricklink_id(c["name"])
    if bl is None:
        unmatched.append(c["name"])
    colors[cid] = [c["name"], c["rgb"], c["is_trans"] == "True", bl]

# Beliebtheit = in wie vielen Inventaren (Sets/Minifigs) das Teil in der Farbe vorkommt
counts = Counter()
for p in rows("inventory_parts"):
    if p["is_spare"] == "False" and int(p["color_id"]) in colors:
        counts[(p["part_num"], int(p["color_id"]))] += 1

# parts: Teil → [Farb-ID, Anzahl, Farb-ID, Anzahl, …], häufigste zuerst
parts = {}
for (part, cid), n in counts.most_common():
    parts.setdefault(part, []).extend([cid, n])

out = ROOT / "LegoScanner/colors.json"
data = json.loads(json.dumps({"colors": colors, "parts": parts}))  # Schlüssel als Strings, wie in der Datei
old = json.loads(out.read_text()) if out.exists() else {}
# "updated" nur ändern, wenn sich wirklich etwas geändert hat → kein Commit, kein Download in der App
same = old.get("colors") == data["colors"] and old.get("parts") == data["parts"]
data["updated"] = old["updated"] if same and "updated" in old else datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
out.write_text(json.dumps(data, separators=(",", ":")))
print(("unverändert: " if same else "neu: ") + f"{len(colors)} Farben, {len(parts)} Teile → {out} ({out.stat().st_size // 1024} KB)")
if unmatched:
    print(f"{len(unmatched)} Farben ohne BrickLink-ID (Link öffnet dann ohne Farbe):", ", ".join(unmatched[:30]))

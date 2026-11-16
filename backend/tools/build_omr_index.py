"""Verzeichnis der LDraw-Modelle offizieller Sets (OMR) bauen: Setnummer → Modelldatei (.mpd).

python3 tools/build_omr_index.py  → data/omr_index.json  {"10019-1": "https://library.ldraw.org/media/omr_models/1317/10019-1.mpd", …}

Liest die öffentliche Liste library.ldraw.org/omr/sets Seite für Seite (eine pro Sekunde, schonend).
Vorschaubild und Modelldatei liegen unter derselben Nummer: …/omr_models/<id>/conversions/<set>-thumb.png → …/<id>/<set>.mpd
ponytail: pro Set nur das erste Modell der Liste (Alternativmodelle fehlen). Neu bauen, wenn das Archiv wächst.
"""
import json
import re
import time
import urllib.request
from pathlib import Path

BASE = "https://library.ldraw.org"
index: dict[str, str] = {}
page = 1
while True:
    req = urllib.request.Request(f"{BASE}/omr/sets?page={page}", headers={"User-Agent": "LegoScanner-OMR-Index/1.0"})
    html = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "ignore")
    found = re.findall(r"omr_models/(\d+)/conversions/([\w.\-]+?)-thumb\.png", html)
    if not found:
        break
    new = 0
    for media_id, stem in found:
        key = stem if re.search(r"-\d+$", stem) else f"{stem}-1"
        if key not in index:
            index[key] = f"{BASE}/media/omr_models/{media_id}/{stem}.mpd"
            new += 1
    print(f"Seite {page}: {len(found)} Einträge, {new} neu, gesamt {len(index)}", flush=True)
    if new == 0:
        break
    page += 1
    time.sleep(1)

out = Path(__file__).resolve().parent.parent / "data" / "omr_index.json"
out.write_text(json.dumps(dict(sorted(index.items())), indent=0))
print(f"{out.name}: {len(index)} Sets")

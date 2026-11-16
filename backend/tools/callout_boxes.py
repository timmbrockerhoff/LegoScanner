"""Teilekästen einer Anleitungsseite finden und in hoher Auflösung ausschneiden (ohne KI, reine Bildverarbeitung).

  ~/LegoScanner-data/venv/bin/python tools/callout_boxes.py <anleitung.pdf> <seite> <ausgabe-ordner>
  → <ordner>/s<seite>.jpg (ganze Seite klein) und s<seite>_k<n>.jpg (Kästen), Liste als JSON auf stdout

Neuere LEGO-Anleitungen rahmen die Teile jedes Schritts mit einem dünnen, hellen Rechteck ein. Gesucht werden lange
gerade helle Linien, die sich zu einem Rechteck schließen. ponytail: auf den hellen Rahmen dunkler Seiten (z. B. 21324)
und hellblaue Kästen heller Seiten ausgelegt; andere Layouts brauchen eigene Schwellen.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

pdf, page, out = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
DPI = 200  # Kästen werden groß genug, dass Fliese und Platte unterscheidbar sind

with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(["pdftoppm", "-r", str(DPI), "-png", "-f", str(page), "-l", str(page), "-singlefile", pdf, f"{tmp}/p"], check=True)
    img = Image.open(f"{tmp}/p.png").convert("RGB")

gray = np.asarray(img.convert("L")).astype(np.int16)
h, w = gray.shape
# Rahmenfarbe: deutlich heller als der Seitenhintergrund (Median der Seite)
background = int(np.median(np.concatenate([gray[:20, :20].ravel(), gray[-20:, -20:].ravel()])))  # Ecken = Seitenhintergrund
line = np.abs(gray - background) > 90
MIN = int(0.06 * w)  # Kalibrierung: Kastenkanten sind mindestens ~6 % der Seitenbreite lang


def runs(row: np.ndarray):
    """Zusammenhängende True-Stücke einer Zeile als (start, ende)."""
    padded = np.concatenate(([False], row, [False]))
    d = np.diff(padded.astype(np.int8))
    return list(zip(np.where(d == 1)[0], np.where(d == -1)[0]))


horizontal = [(y, a, b) for y in range(h) for a, b in runs(line[y]) if b - a >= MIN]
boxes = []
for i, (y0, a0, b0) in enumerate(horizontal):
    for y1, a1, b1 in horizontal[i + 1:]:
        if y1 - y0 < 25 or abs(a1 - a0) > 4 or abs(b1 - b0) > 4:
            continue
        left = line[y0:y1, max(a0, 0):a0 + 3].any(axis=1).mean()
        right = line[y0:y1, max(b0 - 3, 0):b0].any(axis=1).mean()
        if left > 0.9 and right > 0.9:
            boxes.append((a0, y0, b0, y1))
            break
# Doppelte (Linien sind 2–3 px dick) und ineinanderliegende Rahmen zusammenfassen
boxes.sort(key=lambda b: (b[2] - b[0]) * (b[3] - b[1]), reverse=True)
kept = []
for b in boxes:
    if not any(b[0] >= k[0] - 6 and b[1] >= k[1] - 6 and b[2] <= k[2] + 6 and b[3] <= k[3] + 6 for k in kept):
        kept.append(b)
# Seitengroße Rahmen (ganze Bildfläche) sind keine Teilekästen
kept = [b for b in kept if (b[2] - b[0]) < 0.9 * w and (b[3] - b[1]) < 0.9 * h]
# Kalibrierung: mindestens 4 % der Seitenhöhe hoch (dünne Streifen sind Modellkanten). Ob ein Rahmen eine Teileliste
# ist oder eine Bauhilfe (weißes Feld), entscheidet das Modell: Teilelisten tragen Mengen wie "2x".
kept = [b for b in kept if (b[3] - b[1]) >= 0.04 * h]
kept.sort(key=lambda b: (b[1] // 50, b[0]))  # Lesereihenfolge: oben nach unten, links nach rechts

small = img.resize((800, int(800 * h / w)))
small.save(out / f"s{page}.jpg", quality=85)
result = {"page": f"s{page}.jpg", "boxes": []}
for n, (x0, y0, x1, y1) in enumerate(kept, 1):
    crop = img.crop((max(x0 - 4, 0), max(y0 - 4, 0), min(x1 + 4, w), min(y1 + 4, h)))
    crop.thumbnail((900, 900))  # große Bauhilfe-Felder klein halten (Kosten), Teilekästen bleiben scharf
    name = f"s{page}_k{n}.jpg"
    crop.save(out / name, quality=90)
    result["boxes"].append({"file": name, "x": round(x0 / w, 3), "y": round(y0 / h, 3), "w": round((x1 - x0) / w, 3), "h": round((y1 - y0) / h, 3)})
print(json.dumps(result))

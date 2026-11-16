"""Beweistest: eigenes Fingerabdruck-Modell gegen Claude, auf echten iPhone-Scans.

  ~/LegoScanner-data/venv/bin/python render/eval_real.py <scans-ordner> <wahrheit.txt> <model-ordner> <set-teileliste.csv>

scans-ordner: Bilder aus der App (Documents/scans, Debug-Build), Dateiname <zeit>_<Claude-Ergebnis>.jpg
wahrheit.txt: pro Zeile die BrickLink-Teilenummer, in der Reihenfolge, in der die Teile gescannt wurden
              (Reihenfolge der Liste „Alle“ im Abschnitt). Leere Scans werden vorher aussortiert.
Set-Modus: Das Modell wählt nur unter den Teilen des Sets (wie später in der App).
"""
import csv
import re
import sys
from pathlib import Path

import torch
import torch.nn.functional as F
from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).parent))
from train import DEVICE, EVAL_TF, Fingerprint  # noqa: E402


def shape(no: str) -> str:
    """BrickLink- und LDraw-Nummern derselben Form vergleichbar machen: '3062b' → '3062', '3069bpb0005' → '3069'."""
    no = re.sub(r"(pb\d+[a-z]?|px\d+|p\d+[a-z]?|c\d\d)$", "", no.lower())
    return re.sub(r"[a-d]$", "", no)


def part_crop(img: Image.Image) -> Image.Image:
    """Ein Teil auf weißem Papier: alles, was deutlich dunkler oder farbiger als das Papier ist, quadratisch ausschneiden."""
    gray = ImageOps.autocontrast(img.convert("L"))
    small = gray.resize((128, 128))
    paper = sorted(small.getdata())[int(0.8 * 128 * 128)]  # hellster Großteil = Papier
    mask = [i for i, v in enumerate(small.getdata()) if v < paper - 40]
    if len(mask) < 20:
        return img
    xs, ys = [i % 128 for i in mask], [i // 128 for i in mask]
    sx, sy = img.width / 128, img.height / 128
    x0, x1, y0, y1 = min(xs) * sx, (max(xs) + 1) * sx, min(ys) * sy, (max(ys) + 1) * sy
    side = max(x1 - x0, y1 - y0) * 1.3
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    return img.crop((int(cx - side / 2), int(cy - side / 2), int(cx + side / 2), int(cy + side / 2)))


def main():
    scans_dir, truth_file, model_dir, set_csv = (Path(a).expanduser() for a in sys.argv[1:5])
    scans = sorted(p for p in scans_dir.glob("*.jpg") if not p.stem.endswith("_"))  # "_" am Ende = Claude fand nichts
    truth = [l.strip() for l in truth_file.read_text().splitlines() if l.strip()]
    if len(scans) != len(truth):
        print(f"Achtung: {len(scans)} Scans, aber {len(truth)} Zeilen Wahrheit. Ausgewertet wird das Kürzere.")

    state = torch.load(model_dir / "fingerprint.pt", map_location="cpu")
    model = Fingerprint()
    model.load_state_dict(state["model"])
    model = model.to(DEVICE).eval()
    classes, prototypes = state["classes"], state["prototypes"].to(DEVICE)

    set_shapes = {shape(r["part"]) for r in csv.DictReader(set_csv.open(), delimiter=";")}
    allowed = torch.tensor([shape(c) in set_shapes for c in classes], device=DEVICE)

    top1 = top3 = claude_ok = 0
    rows = []
    for path, want in zip(scans, truth):
        img = part_crop(Image.open(path).convert("RGB"))
        with torch.no_grad():
            emb = model(EVAL_TF(img).unsqueeze(0).to(DEVICE))
        sims = (emb @ prototypes.T).squeeze(0).masked_fill(~allowed, -2)
        best = sims.topk(3)
        guesses = [classes[i] for i in best.indices.tolist()]
        ok1, ok3 = shape(guesses[0]) == shape(want), any(shape(g) == shape(want) for g in guesses)
        claude = path.stem.split("_", 1)[1].split("_")[0] if "_" in path.stem else ""
        top1, top3, claude_ok = top1 + ok1, top3 + ok3, claude_ok + (shape(claude) == shape(want))
        rows.append(f"{'✓' if ok1 else ('~' if ok3 else '✗')} {want:10} Modell: {', '.join(guesses)} "
                    f"({best.values[0].item():.2f})   Claude: {claude or '–'}")
    n = len(rows)
    print("\n".join(rows))
    print(f"\n{n} echte Scans · eigenes Modell (Set-Modus): {top1}/{n} = {top1 / max(n, 1):.0%} richtig, "
          f"Top 3: {top3 / max(n, 1):.0%} · Claude: {claude_ok}/{n} = {claude_ok / max(n, 1):.0%}")


if __name__ == "__main__":
    main()

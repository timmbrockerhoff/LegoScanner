"""Phase 2, Prototyp: Fingerabdruck-Modell für LEGO-Teile, trainiert nur auf Renderings.

  ~/LegoScanner-data/venv/bin/python render/train.py ~/LegoScanner-data/train-10132 ~/LegoScanner-data/model-10132

Grundmodell DINOv2-small (Meta, Apache 2.0) + Kopf, der jedes Bild auf einen Fingerabdruck (256 Zahlen, Länge 1)
abbildet. Trainiert mit CosFace: Fingerabdrücke derselben Form rücken zusammen, verschiedene Formen auseinander.
Die Klassen-Gewichte sind am Ende die Fingerabdrücke der Teile (prototypes). Erkennung = nächster Fingerabdruck.

Farbe wird absichtlich verfälscht (Farbstich, manchmal Graustufen): Das Modell soll nur die Form lernen.
Die Farbe kommt im Set-Modus aus der Teileliste.
"""
import csv
import io
import json
import random
import sys
import time
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
import timm
from PIL import Image, ImageFilter
from torchvision import transforms as T

SIZE = 224
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"


def crop(img: Image.Image, box: tuple[float, float, float, float], train: bool) -> Image.Image:
    """Quadratischer Ausschnitt ums Teil, wie ihn später der Detektor liefert. Im Training mit Wackeln (Rand, Lage)."""
    w, h = img.size
    x, y, bw, bh = box[0] * w, box[1] * h, box[2] * w, box[3] * h
    side = max(bw, bh) * (random.uniform(1.1, 1.6) if train else 1.3)
    cx, cy = x + bw / 2, y + bh / 2
    if train:
        cx += random.uniform(-0.1, 0.1) * side
        cy += random.uniform(-0.1, 0.1) * side
    return img.crop((int(cx - side / 2), int(cy - side / 2), int(cx + side / 2), int(cy + side / 2)))


def camera_like(img: Image.Image) -> Image.Image:
    """Handykamera nachahmen: Unschärfe, Rauschen, JPEG-Kompression, kleine Auflösung."""
    if random.random() < 0.5:
        img = img.filter(ImageFilter.GaussianBlur(random.uniform(0.3, 1.2)))
    if random.random() < 0.5:  # Teil war klein im Bild: wenig Pixel
        small = random.randint(48, 160)
        img = img.resize((small, small), Image.BILINEAR).resize((SIZE, SIZE), Image.BILINEAR)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=random.randint(40, 90))
    return Image.open(buf).convert("RGB")


NORM = T.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225])
TRAIN_TF = T.Compose([
    T.Resize((SIZE, SIZE)),
    T.RandomRotation(180, fill=(220, 220, 220)),
    T.ColorJitter(0.4, 0.4, 0.6, 0.5),  # starker Farbstich: Form statt Farbe lernen
    T.RandomGrayscale(0.3),
    T.Lambda(camera_like),
    T.ToTensor(),
    NORM,
])
EVAL_TF = T.Compose([T.Resize((SIZE, SIZE)), T.ToTensor(), NORM])


class Renders(torch.utils.data.Dataset):
    def __init__(self, rows, classes, train):
        self.rows, self.index, self.train = rows, {c: i for i, c in enumerate(classes)}, train

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        path, part, box = self.rows[i]
        img = crop(Image.open(path).convert("RGB"), box, self.train)
        return (TRAIN_TF if self.train else EVAL_TF)(img), self.index[part]


class Fingerprint(nn.Module):
    """DINOv2-small → 256 Zahlen, Länge 1."""
    def __init__(self, dim=256):
        super().__init__()
        self.backbone = timm.create_model("vit_small_patch14_dinov2.lvd142m", pretrained=True, num_classes=0, img_size=SIZE)
        self.head = nn.Sequential(nn.Linear(self.backbone.num_features, 512), nn.GELU(), nn.Linear(512, dim))

    def forward(self, x):
        return F.normalize(self.head(self.backbone(x)), dim=-1)


class CosFace(nn.Module):
    """Pro Teil ein Fingerabdruck (Gewicht). Abstand zur richtigen Klasse muss um `margin` besser sein."""
    def __init__(self, dim, n, scale=30.0, margin=0.25):
        super().__init__()
        self.weight = nn.Parameter(torch.randn(n, dim) * 0.01)
        self.scale, self.margin = scale, margin

    def forward(self, emb, labels):
        cos = emb @ F.normalize(self.weight, dim=-1).T
        cos = cos - self.margin * F.one_hot(labels, cos.shape[1])
        return F.cross_entropy(self.scale * cos, labels)


def main():
    data, out = Path(sys.argv[1]).expanduser(), Path(sys.argv[2]).expanduser()
    epochs = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for name, part, _code, x, y, w, h in csv.reader((data / "labels.csv").open()):
        if (data / name).exists() and float(w) > 0.01 and float(h) > 0.01:
            rows.append((data / name, part, (float(x), float(y), float(w), float(h))))
    classes = sorted({r[1] for r in rows})
    # Je Teil die Bilder mit Nummer ≥ 90 zum Prüfen zurückhalten (nie im Training gesehen)
    train_rows = [r for r in rows if int(r[0].stem.rsplit("_", 1)[1]) < 90]
    val_rows = [r for r in rows if int(r[0].stem.rsplit("_", 1)[1]) >= 90]
    print(f"{len(classes)} Teile, {len(train_rows)} Trainings-, {len(val_rows)} Prüfbilder, Gerät {DEVICE}", flush=True)

    loader = torch.utils.data.DataLoader(Renders(train_rows, classes, True), batch_size=48, shuffle=True)
    model, loss_fn = Fingerprint().to(DEVICE), CosFace(256, len(classes)).to(DEVICE)
    # Grundmodell nur sanft anpassen (es kann schon viel), Kopf und Fingerabdrücke schneller lernen
    opt = torch.optim.AdamW([
        {"params": model.backbone.parameters(), "lr": 1e-5},
        {"params": list(model.head.parameters()) + list(loss_fn.parameters()), "lr": 1e-3},
    ], weight_decay=0.05)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=[1e-5, 1e-3], total_steps=epochs * len(loader))

    for epoch in range(epochs):
        model.train()
        started, total, n = time.time(), 0.0, 0
        for x, y in loader:
            x, y = x.to(DEVICE), y.to(DEVICE)
            loss = loss_fn(model(x), y)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            total, n = total + loss.item() * len(y), n + len(y)
        acc = evaluate(model, loss_fn, val_rows, classes)
        print(f"Epoche {epoch + 1}/{epochs}: Verlust {total / n:.3f}, Prüfbilder richtig {acc:.1%}, {time.time() - started:.0f} s", flush=True)

    prototypes = F.normalize(loss_fn.weight.detach(), dim=-1).cpu()
    torch.save({"model": model.state_dict(), "classes": classes, "prototypes": prototypes}, out / "fingerprint.pt")
    (out / "classes.json").write_text(json.dumps(classes))
    print("gespeichert:", out / "fingerprint.pt")


@torch.no_grad()
def evaluate(model, loss_fn, rows, classes):
    model.eval()
    proto = F.normalize(loss_fn.weight, dim=-1)
    loader = torch.utils.data.DataLoader(Renders(rows, classes, False), batch_size=64)
    right = count = 0
    for x, y in loader:
        pred = (model(x.to(DEVICE)) @ proto.T).argmax(1).cpu()
        right, count = right + (pred == y).sum().item(), count + len(y)
    return right / max(count, 1)


if __name__ == "__main__":
    main()

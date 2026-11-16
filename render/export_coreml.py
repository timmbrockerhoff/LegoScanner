"""Fingerabdruck-Modell → Core ML für die App (Neural Engine), dazu die Fingerabdrücke aller Teile als JSON.

  ~/LegoScanner-data/venv/bin/python render/export_coreml.py ~/LegoScanner-data/model-10132/fingerprint.pt LegoScanner/

Ergebnis: LegoFingerprint.mlpackage (Bild 224×224 → 256 Zahlen) und lego_fingerprints.json ({teil: [256 Zahlen]}).
In der App: Ausschnitt ums Teil → Modell → Fingerabdruck → nächster Fingerabdruck in der JSON = erkanntes Teil.
"""
import json
import sys
from pathlib import Path

import coremltools as ct
import torch
import torch.nn as nn

sys.path.insert(0, str(Path(__file__).parent))
from train import SIZE, Fingerprint  # noqa: E402


class WithNorm(nn.Module):
    """Normalisierung ins Modell, damit die App nur Pixel 0–255 hineingibt."""
    def __init__(self, model):
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1) * 255)
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1) * 255)

    def forward(self, x):
        return self.model((x - self.mean) / self.std)


def main():
    checkpoint, out = Path(sys.argv[1]).expanduser(), Path(sys.argv[2]).expanduser()
    state = torch.load(checkpoint, map_location="cpu")
    model = Fingerprint()
    model.load_state_dict(state["model"])
    wrapped = WithNorm(model).eval()
    example = torch.rand(1, 3, SIZE, SIZE) * 255
    traced = torch.jit.trace(wrapped, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="fingerprint")],
        compute_precision=ct.precision.FLOAT16,  # halb so groß, Neural Engine rechnet ohnehin in FP16
        minimum_deployment_target=ct.target.iOS18,
    )
    mlmodel.short_description = "LEGO-Teil (Ausschnitt 224×224) → Fingerabdruck (256 Zahlen)"
    mlmodel.save(out / "LegoFingerprint.mlpackage")

    prototypes = {c: [round(v, 5) for v in p.tolist()] for c, p in zip(state["classes"], state["prototypes"])}
    (out / "lego_fingerprints.json").write_text(json.dumps(prototypes))

    # Kontrolle: Core ML liefert (fast) dasselbe wie PyTorch
    from PIL import Image
    img = Image.fromarray((example[0].permute(1, 2, 0).numpy()).astype("uint8"))
    ml = torch.tensor(mlmodel.predict({"image": img})["fingerprint"]).flatten()
    pt = wrapped(torch.tensor(list(img.getdata()), dtype=torch.float32).view(1, SIZE, SIZE, 3).permute(0, 3, 1, 2)).flatten()
    print(f"gespeichert: {out / 'LegoFingerprint.mlpackage'}, {len(prototypes)} Teile; "
          f"Abweichung Core ML zu PyTorch: {torch.nn.functional.cosine_similarity(ml, pt, dim=0).item():.4f} (1 = gleich)")


if __name__ == "__main__":
    main()

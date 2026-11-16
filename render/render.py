"""Render-Fabrik, Prototyp: LDraw-Teile → beschriftete Trainingsbilder, die wie Handy-Scans aussehen.

Aufruf (Blender im Hintergrund):
  blender -b -P render/render.py -- --parts 3795 3001 --n 8 --out ~/LegoScanner-data/renders

LDraw-Bibliothek: ~/LegoScanner-data/ldraw (library.ldraw.org, CC BY 2.0).
Pro Bild: <teil>_<nr>.png + Zeile in labels.csv (Teil, LDraw-Farbe, Rahmen 0–1 im Bild).
"""
import argparse
import math
import os
import random
import sys
import time
from pathlib import Path

import bmesh
import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Quaternion, Vector

LDRAW = Path.home() / "LegoScanner-data" / "ldraw"
LDU = 0.0004  # 1 LDraw-Einheit = 0,4 mm, Blender rechnet in Metern

# ---------------------------------------------------------------- LDraw lesen

_index: dict[str, Path] = {}
_cache: dict[str, list] = {}
# Echte Teile tragen „LEGO“ auf jeder Noppe. LDraw hat dafür Noppen mit plastischem Logo.
LOGO = {"stud.dat": "stud-logo4.dat", "stud2.dat": "stud2-logo4.dat"}


def find(name: str) -> Path | None:
    """LDraw-Verweis (z. B. 's\\3795s01.dat') → Datei. Gesucht wird wie in LDraw üblich in parts/ und p/."""
    if not _index:
        for root in ("parts", "p", "p/48"):
            base = LDRAW / root
            for path in base.rglob("*.dat"):
                key = path.relative_to(base).as_posix().lower()
                _index.setdefault(key, path)
    key = name.replace("\\", "/").lower()
    return _index.get(LOGO.get(key, key))


def triangles(name: str) -> list:
    """Alle Dreiecke einer LDraw-Datei in ihren eigenen Koordinaten, Unterdateien aufgelöst (mit Cache)."""
    if name in _cache:
        return _cache[name]
    path = find(name)
    tris = []
    if path is None:
        print("LDraw: fehlt", name)
        _cache[name] = tris
        return tris
    for line in path.read_text(errors="ignore").splitlines():
        f = line.split()
        if not f:
            continue
        kind = f[0]
        if kind == "1" and len(f) >= 15:
            x, y, z, a, b, c, d, e, g, h, i, j = map(float, f[2:14])
            m = Matrix(((a, b, c, x), (d, e, g, y), (h, i, j, z), (0, 0, 0, 1)))
            for tri in triangles(" ".join(f[14:])):
                tris.append(tuple(m @ v for v in tri))
        elif kind == "3" and len(f) >= 11:
            p = list(map(float, f[2:11]))
            tris.append((Vector(p[0:3]), Vector(p[3:6]), Vector(p[6:9])))
        elif kind == "4" and len(f) >= 14:
            p = list(map(float, f[2:14]))
            q = [Vector(p[k:k + 3]) for k in (0, 3, 6, 9)]
            tris += [(q[0], q[1], q[2]), (q[0], q[2], q[3])]
    _cache[name] = tris
    return tris


def set_parts(csv_path: Path) -> dict[str, list[str]]:
    """BrickLink-Teileliste (qty;part;color) → LDraw-Teil → BrickLink-Farben, in denen es im Set vorkommt.
    Bedruckte Teile (pb…, px…, p01) und Baugruppen (c01) werden als Grundform gerendert: Für die Form zählt der Druck nicht."""
    import csv
    import re
    parts: dict[str, list[str]] = {}
    missing = []
    for row in csv.DictReader(csv_path.open(), delimiter=";"):
        no = row["part"]
        base = re.sub(r"(pb\d+[a-z]?|px\d+|p\d+|c\d\d)$", "", no)
        candidates = [no, base, re.sub(r"[abcu]$", "", base)]
        found = next((c for c in candidates if find(f"{c}.dat")), None)
        if found is None:
            missing.append(no)
        else:
            parts.setdefault(found, []).append(row["color"])
    print(f"SET {csv_path.stem}: {len(parts)} Formen in LDraw, fehlen: {' '.join(missing) or '-'}")
    return parts


def color_key(name: str) -> str:
    """BrickLink- und LDraw-Farbnamen vergleichbar machen: 'Dark_Bluish_Grey' = 'Dark Bluish Gray', 'Trans-Clear' = 'Trans_Clear'."""
    return name.replace("_", " ").replace("-", " ").lower().replace("grey", "gray")


COLOR_CODES: dict[str, int] = {}  # Farbname (color_key) → LDraw-Code
TRANSPARENT: set[int] = set()


def ldraw_colors() -> dict[int, tuple]:
    """LDraw-Farbcode → sRGB 0–1, aus LDConfig.ldr. Füllt nebenbei COLOR_CODES und TRANSPARENT."""
    colors = {}
    for line in (LDRAW / "LDConfig.ldr").read_text(errors="ignore").splitlines():
        f = line.split()
        if len(f) > 7 and f[:2] == ["0", "!COLOUR"] and "CODE" in f and "VALUE" in f:
            code = int(f[f.index("CODE") + 1])
            hexv = f[f.index("VALUE") + 1].lstrip("#")
            colors[code] = tuple(int(hexv[k:k + 2], 16) / 255 for k in (0, 2, 4))
            COLOR_CODES[color_key(f[2])] = code
            if "ALPHA" in f:
                TRANSPARENT.add(code)
    return colors


# Häufige Vollfarben (LDraw-Codes): Black, Blue, Green, Red, Yellow, White, Tan, Orange, Dark Brown, Reddish Brown,
# Light/Dark Bluish Gray, Medium Blue, Dark Tan, Sand Green, Lime, Dark Red, Medium Azure, Dark Blue, Bright Light Orange
COMMON = [0, 1, 2, 4, 14, 15, 19, 25, 308, 70, 71, 72, 73, 28, 378, 27, 320, 322, 272, 191]


def srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


# ---------------------------------------------------------------- Szene

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    # Absturz (SIGSEGV in MetalKernelPipeline::compile): Blender übersetzt im Hintergrund optimierte Kernel neu,
    # wenn sich die Szene ändert. Ohne diese Optimierung kein Absturz, Renderzeit kaum anders.
    prefs.kernel_optimization_level = "OFF"
    prefs.get_devices()
    for device in prefs.devices:
        device.use = True
    scene.cycles.device = "GPU"
    # Kalibrierung: 48 Samples + Entrauschen ≈ sauber genug für 512 px, Zeit pro Bild siehe Ausgabe.
    scene.cycles.samples = 48
    scene.cycles.use_denoising = True
    scene.render.resolution_x = scene.render.resolution_y = 512
    scene.render.image_settings.file_format = "PNG"
    scene.view_settings.view_transform = "AgX"  # filmisch wie eine Handykamera, keine ausgefressenen Lichter
    return scene


def build_part(name: str):
    tris = triangles(name)
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    # LDraw: -Y ist oben, rechtshändig → Blender: Z oben. (x, y, z) → (x, z, -y), dann in Meter.
    for tri in tris:
        verts = [bm.verts.new((v.x * LDU, v.z * LDU, -v.y * LDU)) for v in tri]
        try:
            bm.faces.new(verts)
        except ValueError:
            pass  # doppelte Fläche
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.01 * LDU)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(35))
    return obj


def plastic(rgb: tuple, transparent: bool = False):
    mat = bpy.data.materials.new("ABS")
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    if transparent:  # Fenster, Scheinwerfer: durchsichtig, Farbe färbt das Licht
        bsdf.inputs["Transmission Weight"].default_value = 0.95
    bsdf.inputs["Base Color"].default_value = (*[srgb_to_linear(c) for c in rgb], 1)
    bsdf.inputs["Roughness"].default_value = random.uniform(0.15, 0.4)  # neu glänzend bis abgegriffen
    bsdf.inputs["IOR"].default_value = 1.54  # ABS-Kunststoff
    return mat


def paper():
    """Weißes Druckerpapier (Standard-Testbedingung) mit leichtem Ton und Struktur."""
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    plane = bpy.context.object
    mat = bpy.data.materials.new("Papier")
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = nodes["Principled BSDF"]
    tone = random.uniform(0.78, 0.9)
    tint = random.uniform(-0.02, 0.02)
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 400
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (tone - 0.03, tone - 0.03 + tint, tone - 0.03 - tint, 1)
    ramp.color_ramp.elements[1].color = (tone, tone + tint, tone - tint, 1)
    links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.85
    plane.data.materials.append(mat)
    return plane


def lights():
    """Tageslicht vom Fenster: große weiche Fläche schräg, dazu Raumhelligkeit. Zufällig in Richtung, Stärke, Farbe."""
    world = bpy.data.worlds.new("Raum")
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = random.uniform(0.3, 0.8)
    bpy.context.scene.world = world
    bpy.ops.object.light_add(type="AREA")
    sun = bpy.context.object
    sun.visible_camera = False  # sonst ragt die Rückseite der Lichtfläche als schwarze Ecke ins Bild
    sun.data.size = random.uniform(0.5, 1.5)
    sun.data.energy = random.uniform(40, 120)
    kelvin = random.uniform(4500, 7000)  # Tageslicht, leicht warm bis kühl
    sun.data.color = (1.0, min(1, 0.85 + (kelvin - 4500) / 25000), min(1, 0.7 + (kelvin - 4500) / 8000))
    angle, height = random.uniform(0, 2 * math.pi), random.uniform(0.6, 1.2)
    sun.location = (math.cos(angle) * 1.0, math.sin(angle) * 1.0, height)
    sun.rotation_euler = (Vector((0, 0, 0)) - sun.location).to_track_quat("-Z", "Y").to_euler()


def stable_poses(obj) -> list[tuple[Vector, float]]:
    """Lagen, in denen das Teil auf dem Tisch liegen bleibt: Flächen der konvexen Hülle, über denen der Schwerpunkt steht.
    Gewicht = Flächeninhalt (große Auflageflächen sind wahrscheinlicher). Ersetzt feste Lagen, die es real nicht gibt
    (z. B. Stab auf der Spitze)."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.convex_hull(bm, input=bm.verts)
    hull = [f for f in bm.faces]
    bmesh.ops.triangulate(bm, faces=hull)
    tris = [[v.co.copy() for v in f.verts] for f in bm.faces if len(f.verts) == 3]
    bm.free()
    # Schwerpunkt der (vollen) Hülle über Tetraeder vom Ursprung. ponytail: echte Teile sind hohl, Schwerpunkt liegt
    # etwas tiefer; reicht, um Unmögliches auszuschließen.
    volume, com = 0.0, Vector()
    for a, b, c in tris:
        v = a.dot(b.cross(c)) / 6
        volume += v
        com += v * (a + b + c) / 4
    com = com / volume if abs(volume) > 1e-15 else sum((v for t in tris for v in t), Vector()) / (3 * len(tris))
    groups: dict[tuple, list] = {}
    for t in tris:
        n = (t[1] - t[0]).cross(t[2] - t[0])
        if n.length < 1e-12:
            continue
        n.normalize()
        if n.dot(t[0] - com) < 0:
            n = -n  # nach außen
        groups.setdefault(tuple(round(x, 2) for x in n), []).append(t)
    poses = []
    for key, group in groups.items():
        n = Vector(key).normalized()
        area = sum((t[1] - t[0]).cross(t[2] - t[0]).length / 2 for t in group)
        p = com - n * n.dot(com - group[0][0])  # Schwerpunkt senkrecht auf die Auflageebene
        for a, b, c in group:  # liegt der Fußpunkt in der Auflagefläche?
            v0, v1, v2 = b - a, c - a, p - a
            d00, d01, d11, d20, d21 = v0.dot(v0), v0.dot(v1), v1.dot(v1), v2.dot(v0), v2.dot(v1)
            den = d00 * d11 - d01 * d01
            if abs(den) < 1e-20:
                continue
            v, w = (d11 * d20 - d01 * d21) / den, (d00 * d21 - d01 * d20) / den
            if v >= 0 and w >= 0 and v + w <= 1:
                poses.append((n, area))
                break
    return poses


def place(obj):
    """Teil liegt auf dem Papier in einer stabilen Lage (zufällig nach Auflagefläche gewichtet), beliebig gedreht."""
    poses = stable_poses(obj) or [(Vector((0, 0, -1)), 1.0)]
    normal = random.choices([n for n, _ in poses], weights=[w for _, w in poses])[0]
    down = normal.rotation_difference(Vector((0, 0, -1)))  # Auflagefläche nach unten
    spin = Quaternion((0, 0, 1), random.uniform(0, 2 * math.pi))
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = spin @ down
    bpy.context.view_layer.update()
    # Echte Eckpunkte statt Hüllquader: sonst schwebt ein schräg liegendes Teil über dem Papier.
    pts = [obj.matrix_world @ v.co for v in obj.data.vertices]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    obj.location -= Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
    bpy.context.view_layer.update()
    return [obj.matrix_world @ Vector(c) for c in obj.bound_box]


def camera(corners):
    """Handy von oben, leicht schräg. Abstand so, dass das Teil 25–55 % der Bildbreite füllt (wie im Scanfeld)."""
    size = max((max(c[k] for c in corners) - min(c[k] for c in corners)) for k in range(3))
    bpy.ops.object.camera_add()
    cam = bpy.context.object
    # iPhone-Hauptkamera: kleiner Sensor (≈ 7 mm), daher wenig Unschärfe auch aus 10 cm. Bildwinkel ≈ 26 mm Kleinbild.
    cam.data.sensor_width = 7.0
    cam.data.clip_start = 0.001
    # Wie die App: echter Abstand 15–30 cm, das Teil wird per Ausschnitt groß (hier: längere Brennweite).
    # Früher ging die Kamera bei kleinen Teilen auf 3–5 cm heran → viel zu unscharf.
    fill = random.uniform(0.25, 0.55)  # Anteil des Teils an der Bildbreite (Ausschnitt ums Teil)
    distance = random.uniform(0.15, 0.30)
    cam.data.lens = cam.data.sensor_width * distance / (size / fill)
    tilt, turn = math.radians(random.uniform(0, 25)), random.uniform(0, 2 * math.pi)
    cam.location = (math.sin(tilt) * math.cos(turn) * distance, math.sin(tilt) * math.sin(turn) * distance,
                    math.cos(tilt) * distance)
    target = Vector((random.uniform(-0.15, 0.15) * size, random.uniform(-0.15, 0.15) * size, size * 0.2))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.dof.use_dof = True  # leichte Unschärfe wie beim Handy
    cam.data.dof.focus_distance = (target - cam.location).length
    # Echte Blende der iPhone-Hauptkamera: f/1.78 bei 6,9 mm → Öffnung ≈ 3,9 mm. Gleiche Öffnung = gleiche Unschärfe.
    cam.data.dof.aperture_fstop = cam.data.lens / 3.9
    bpy.context.scene.camera = cam
    return cam


def box_in_image(scene, cam, corners):
    pts = [world_to_camera_view(scene, cam, c) for c in corners]
    xs, ys = [p.x for p in pts], [1 - p.y for p in pts]  # Ursprung oben links wie in der App
    x0, y0, x1, y1 = max(0, min(xs)), max(0, min(ys)), min(1, max(xs)), min(1, max(ys))
    return round(x0, 4), round(y0, 4), round(x1 - x0, 4), round(y1 - y0, 4)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--parts", nargs="+", default=[])
    parser.add_argument("--set", help="BrickLink-Teileliste, z. B. ~/LegoScanner-data/sets/10132-1.csv")
    parser.add_argument("--n", type=int, default=8)
    parser.add_argument("--out", default=str(Path.home() / "LegoScanner-data" / "renders"))
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args(argv)

    random.seed(args.seed)
    out = Path(os.path.expanduser(args.out))
    out.mkdir(parents=True, exist_ok=True)
    colors = ldraw_colors()
    parts = {p: [] for p in args.parts}
    if args.set:
        parts |= set_parts(Path(os.path.expanduser(args.set)))
    labels_path = out / "labels.csv"
    labeled = {line.split(",", 1)[0] for line in labels_path.read_text().splitlines()} if labels_path.exists() else set()
    labels = labels_path.open("a")
    started = time.time()
    count = 0
    for part, set_colors in parts.items():
        # Kalibrierung: 70 % Originalfarbe aus dem Set (so sieht sie der Scanner), 30 % Zufall, damit das Modell
        # die Form lernt und nicht „schwarz + länglich = 3795“.
        originals = [COLOR_CODES[color_key(c)] for c in set_colors if color_key(c) in COLOR_CODES]
        if find(f"{part}.dat") is None:
            print("Teil nicht in LDraw:", part)
            continue
        for k in range(args.n):
            name = f"{part}_{k:03d}.png"
            if name in labeled and (out / name).exists():
                continue  # nach Abbruch einfach neu starten: Fertiges (Bild + Beschriftung) wird übersprungen
            scene = clear_scene()
            obj = build_part(f"{part}.dat")
            if originals and random.random() < 0.7:
                code = random.choice(originals)
            else:
                code = random.choice([c for c in COMMON if c in colors])
            obj.data.materials.append(plastic(colors[code], code in TRANSPARENT))
            corners = place(obj)
            paper()
            lights()
            cam = camera(corners)
            scene.render.filepath = str(out / name)
            bpy.ops.render.render(write_still=True)
            labels.write(",".join(map(str, (name, part, code, *box_in_image(scene, cam, corners)))) + "\n")
            labels.flush()  # sofort auf die Platte: nach einem Absturz fehlt sonst die Beschriftung
            count += 1
    labels.close()
    seconds = time.time() - started
    print(f"RENDER fertig: {count} Bilder in {seconds:.0f} s ({seconds / max(count, 1):.1f} s pro Bild) → {out}")


main()

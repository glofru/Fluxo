#!/usr/bin/env python3
"""Draw the Fluxo app icon layers with VectorCraft and export them.

The geometry is computed here and drawn by the headless VectorCraft CLI
(`vectorcraft-cli run`), which strokes and outlines the stream bands and cuts
the live corners of the play glyph. The script writes:

- Design/Icon/Fluxo.vectorcraft   the editable master document (one layer per icon layer)
- Design/Icon/Fluxo-flat.svg      every layer together, on the brand background (reference only)
- Design/Icon/Layers/<name>.svg   one SVG per icon layer, 1024 x 1024
- Fluxo/AppIcon.icon/Assets/      the same layer SVGs, used by the Icon Composer document

Usage:
    VECTORCRAFT_CLI=/path/to/vectorcraft-cli Design/Icon/generate_layers.py

vectorcraft-cli ships in the vectorcraft-cli-<version>-macos-universal.zip
release asset of https://github.com/storytold/vectorcraft (the .app does not
contain it). The script never opens a network port: headless mode runs the
engine in-process.
"""

from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DESIGN = ROOT / "Design" / "Icon"
LAYERS = DESIGN / "Layers"
ICON_ASSETS = ROOT / "Fluxo" / "AppIcon.icon" / "Assets"

CANVAS = 1024.0

# Brand palette (see README, "Brand").
INK = "#140F3C"        # Fluxo Ink: deepest background
VIOLET = "#6A4CFF"     # Fluxo Violet: primary, matches AccentColor
CYAN = "#3CD6FF"       # Signal Cyan: the leading stream band
LILAC = "#A08CFF"      # Lilac: the middle band
PINK = "#FF5C9E"       # Flux Pink: the trailing band
WHITE = "#FFFFFF"

# --- Stream bands -----------------------------------------------------------
# Three bands come in from the left edge (they start past it; the icon mask
# crops them), spread over most of the height, and gather into the flat back of
# the play glyph, where they end hidden under it: streams flowing into "play".
BAND_WIDTH = 80.0
BAND_START_X = -160.0
BAND_END_X = 420.0                 # just inside the glyph's flat side (x = 412)
GATHER_X = 400.0                   # where the bands are fully gathered
SPREAD_START = 215.0               # centre-to-centre distance at the left edge
SPREAD_GATHERED = 104.0            # centre-to-centre distance under the glyph
WAVE_LENGTH = 900.0
WAVE_AMPLITUDE = 56.0              # fades out as the bands gather
WAVE_PHASE_STEP = 0.06             # per band, in wavelengths: the bands drift apart a little
WAVE_AMPLITUDE_STEP = 0.15         # per band: the lower bands swing a little more
FADE_IN_OPACITY = 0.35             # opacity of each band at the left edge
FADE_IN_END_X = BAND_END_X - 120   # the bands are fully opaque from here
# (layer name, colour, position: -1 top, 0 middle, 1 bottom)
BANDS = [("stream-cyan", CYAN, -1), ("stream-lilac", LILAC, 0), ("stream-pink", PINK, 1)]

# --- Play glyph -------------------------------------------------------------
PLAY_HEIGHT = 500.0
PLAY_CORNER = 60.0                 # small enough to keep the flat side taller than the bands
PLAY_OPTICAL_SHIFT = 44.0          # moves the glyph right of centre, balancing the bands


def band_y(x: float, position: int) -> float:
    """The centre line of a band: a damped wave around a spread that narrows."""
    t = min(1.0, max(0.0, (x - BAND_START_X) / (GATHER_X - BAND_START_X)))
    eased = t * t * (3 - 2 * t)
    spread = SPREAD_START * (1 - eased) + SPREAD_GATHERED * eased
    phase = 2 * math.pi * position * WAVE_PHASE_STEP
    amplitude = WAVE_AMPLITUDE * (1 + position * WAVE_AMPLITUDE_STEP) * (1 - eased)
    return CANVAS / 2 + position * spread + amplitude * math.sin(2 * math.pi * x / WAVE_LENGTH + phase)


def band_path(position: int) -> str:
    """SVG path data of a band's centre line, as cubic Hermite segments."""
    segments = 80
    h = (BAND_END_X - BAND_START_X) / segments
    xs = [BAND_START_X + i * h for i in range(segments + 1)]

    def y(x: float) -> float:
        return band_y(x, position)

    def slope(x: float) -> float:
        return (y(x + 0.01) - y(x - 0.01)) / 0.02

    d = [f"M {xs[0]:.2f} {y(xs[0]):.2f}"]
    for a, b in zip(xs, xs[1:]):
        d.append(f"C {a + h / 3:.2f} {y(a) + slope(a) * h / 3:.2f} "
                 f"{b - h / 3:.2f} {y(b) - slope(b) * h / 3:.2f} {b:.2f} {y(b):.2f}")
    return " ".join(d)


def play_anchors() -> list[dict]:
    """An equilateral play triangle pointing right, optically centred."""
    side = PLAY_HEIGHT
    width = side * math.sqrt(3) / 2
    # The centroid of the triangle sits a third of its width from the flat side.
    cx = CANVAS / 2 + PLAY_OPTICAL_SHIFT
    left = cx - width / 3
    right = left + width
    top = CANVAS / 2 - side / 2
    bottom = CANVAS / 2 + side / 2
    return [{"x": round(left, 2), "y": round(top, 2)},
            {"x": round(right, 2), "y": CANVAS / 2},
            {"x": round(left, 2), "y": round(bottom, 2)}]


def master_steps() -> list[dict]:
    steps: list[dict] = [
        {"command": "file.new", "params": {"name": "Fluxo App Icon", "width": CANVAS, "height": CANVAS,
                                           "units": "Pixels", "backgroundContents": "transparent",
                                           "created": 0}},
        # The first layer of a new document: the reference background (hidden in the layer exports).
        {"command": "layer.setProps", "params": {"name": "background"}},
        {"command": "shape.rectangle", "params": {"x": 0, "y": 0, "width": CANVAS, "height": CANVAS}},
    ]
    steps.append({"command": "paint.setFill", "params": {
        "ids": ["$2.id"],
        "gradient": {"kind": "linear", "start": [CANVAS * 0.3, 0], "end": [CANVAS * 0.7, CANVAS],
                     "stops": [{"offset": 0, "color": VIOLET}, {"offset": 1, "color": INK}]}}})
    steps.append({"command": "paint.setStroke", "params": {"ids": ["$2.id"], "none": True}})

    # Bands, back to front: pink, lilac, cyan. Each is a stroked centre line,
    # outlined to a filled shape, with a fill that fades in from the left edge.
    for name, colour, position in reversed(BANDS):
        steps.append({"command": "layer.new", "params": {"name": name, "top": True}})
        steps.append({"command": "path.create", "params": {"d": band_path(position)}})
        line = f"${len(steps) - 1}.id"
        steps.append({"command": "paint.setFill", "params": {"ids": [line], "none": True}})
        steps.append({"command": "paint.setStroke", "params": {"ids": [line], "color": colour}})
        steps.append({"command": "stroke.set", "params": {"ids": [line], "weight": BAND_WIDTH, "cap": "butt",
                                                           "join": "round"}})
        steps.append({"command": "object.path.outlineStroke", "params": {}})
        band = f"${len(steps) - 1}.ids.0"
        steps.append({"command": "object.setProps", "params": {"id": band, "name": name}})
        steps.append({"command": "paint.setFill", "params": {"id": band, "gradient": {
            "kind": "linear", "start": [0, CANVAS / 2], "end": [FADE_IN_END_X, CANVAS / 2],
            "stops": [{"offset": 0, "color": colour, "opacity": FADE_IN_OPACITY},
                      {"offset": 1, "color": colour, "opacity": 1}]}}})

    steps.append({"command": "layer.new", "params": {"name": "play", "top": True}})
    steps.append({"command": "path.create", "params": {"anchors": play_anchors(), "closed": True}})
    ref = f"${len(steps) - 1}.id"
    steps.append({"command": "paint.setFill", "params": {"ids": [ref], "color": WHITE}})
    steps.append({"command": "paint.setStroke", "params": {"ids": [ref], "none": True}})
    steps.append({"command": "addon.pathtools.cornerSet", "params": {"ids": [ref], "radius": PLAY_CORNER}})
    steps.append({"command": "object.setProps", "params": {"id": ref, "name": "play"}})
    return steps


def run(cli: str, args: list[str]) -> list[dict]:
    env = dict(os.environ)
    env.setdefault("VECTORCRAFT_NO_PREFS", "1")
    env.setdefault("SOURCE_DATE_EPOCH", "0")
    proc = subprocess.run([cli, "run", *args], capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr)
        raise SystemExit(f"vectorcraft-cli failed ({proc.returncode})")
    return [json.loads(line) for line in proc.stdout.splitlines() if line.startswith("{")]


def layer_ids(cli: str, master: Path) -> dict[str, int]:
    """Map layer names to the ids the master document gives them."""
    result = run(cli, ["--in", str(master), "--cmd", "document.inspect", "--params", '{"depth": 1}'])
    tree = result[-1]["result"]
    layers = tree.get("layers") or tree.get("children") or []
    return {layer["name"]: layer["id"] for layer in layers}


def main() -> None:
    cli = os.environ.get("VECTORCRAFT_CLI") or shutil.which("vectorcraft-cli")
    if not cli:
        raise SystemExit("Set VECTORCRAFT_CLI to the vectorcraft-cli binary.")

    LAYERS.mkdir(parents=True, exist_ok=True)
    ICON_ASSETS.mkdir(parents=True, exist_ok=True)
    master = DESIGN / "Fluxo.vectorcraft"

    with tempfile.TemporaryDirectory() as tmp:
        steps_file = Path(tmp) / "steps.json"
        steps_file.write_text(json.dumps(master_steps()))
        run(cli, ["--commands", str(steps_file), "--export", str(master),
                  "--export", str(DESIGN / "Fluxo-flat.svg")])

    ids = layer_ids(cli, master)
    names = [name for name, _, _ in BANDS] + ["play"]
    for name in names:
        hide = [{"command": "layer.setProps", "params": {"id": ids[other], "visible": False}}
                for other in ids if other != name]
        with tempfile.TemporaryDirectory() as tmp:
            steps_file = Path(tmp) / "steps.json"
            steps_file.write_text(json.dumps(hide))
            out = LAYERS / f"{name}.svg"
            run(cli, ["--in", str(master), "--commands", str(steps_file),
                      "--cmd", "document.export", "--params",
                      json.dumps({"path": str(out), "format": "svg", "hiddenLayers": False,
                                  "includeArtboardFill": False})])
        shutil.copyfile(out, ICON_ASSETS / f"{name}.svg")
        print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

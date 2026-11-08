#!/usr/bin/env python3
"""Writes the FigCraft command script of "Dusk", the demo footage of the App Store screenshots.

The picture that plays in the player screenshots is drawn here (an original vector landscape in the brand palette:
a night sky with stars, a glowing sun and four layers of hills), so no test pattern, film or broadcast appears in
them. The geometry is computed from fixed seeds: the same script, the same picture.

    python3 -I dusk_footage.py <out.json>
    figcraft-cli run <out.json> --out dusk.figcraft && figcraft-cli render dusk.figcraft -o dusk.png --scale 2

demo-footage.sh runs this, then turns the picture into a slow, looping push-in served as live HLS on 127.0.0.1.
"""
import json
import math
import random
import sys

WIDTH, HEIGHT = 1920, 1080


def ridge(base, amplitude, seed, peaks):
    """SVG path of a line of hills: a sum of four sines, closed along the bottom of the frame."""
    rng = random.Random(seed)
    phases = [rng.uniform(0, 2 * math.pi) for _ in range(4)]
    frequencies = [peaks * 0.5, peaks * 1.1, peaks * 2.3, peaks * 5.1]
    amplitudes = [1.0, 0.55, 0.25, 0.08]
    steps = 160
    path = f"M 0 {HEIGHT} "
    for step in range(steps + 1):
        t = step / steps
        value = sum(a * math.sin(t * f * 2 * math.pi + p) for a, f, p in zip(amplitudes, frequencies, phases))
        value /= sum(amplitudes)
        path += f"L {WIDTH * t:.1f} {base - amplitude * (0.5 + 0.5 * value):.1f} "
    return path + f"L {WIDTH} {HEIGHT} Z"


def script():
    rng = random.Random(11)
    frame = {"$ref": "frame", "field": "id"}
    steps = [{
        "command": "frame.create", "as": "frame",
        "params": {"x": 0, "y": 0, "width": WIDTH, "height": HEIGHT, "name": "Dusk", "props": {
            "clip": True,
            "fills": [{"type": "linearGradient", "stops": ["#0A0720", "#281D69", "#6A4CFF", "#FF5C9E", "#FFB38A"],
                       "from": [0.5, 0], "to": [0.5, 0.7]}],
        }},
    }]
    for _ in range(110):
        x, y, size = rng.uniform(0, WIDTH), rng.uniform(0, HEIGHT * 0.4), rng.uniform(1.4, 3.4)
        opacity = round(rng.uniform(0.25, 0.9) * (1 - y / (HEIGHT * 0.45)), 2)
        steps.append({"command": "node.create", "params": {
            "type": "ellipse", "parent": frame, "x": x, "y": y, "width": size, "height": size, "select": False,
            "props": {"fill": "#FFFFFF", "opacity": opacity}}})
    cx, cy = WIDTH * 0.58, HEIGHT * 0.50
    steps.append({"command": "node.create", "params": {
        "type": "ellipse", "parent": frame, "x": cx - 330, "y": cy - 330, "width": 660, "height": 660, "select": False,
        "name": "Glow", "props": {"fill": "#FFC4DC", "opacity": 0.5, "effects": [{"type": "layerBlur", "radius": 150}]}}})
    steps.append({"command": "node.create", "params": {
        "type": "ellipse", "parent": frame, "x": cx - 100, "y": cy - 100, "width": 200, "height": 200, "select": False,
        "name": "Sun", "props": {
            "fills": [{"type": "linearGradient", "stops": ["#FFF7FA", "#FFC7DC"], "from": [0.5, 0], "to": [0.5, 1]}],
            "effects": [{"type": "dropShadow", "color": "#FFB0D0", "radius": 60, "offset": [0, 0], "spread": 0}]}}})
    hills = [
        (HEIGHT * 0.66, 190, 1, 1.2, ["#B9A6FF", "#8E6FF2"], 0.92),
        (HEIGHT * 0.74, 170, 2, 1.6, ["#7E5CF5", "#4A33B8"], 1),
        (HEIGHT * 0.84, 150, 3, 2.0, ["#3F2C9E", "#271B6E"], 1),
        (HEIGHT * 0.95, 120, 4, 2.6, ["#1B1450", "#0E0A2C"], 1),
    ]
    for index, (base, amplitude, seed, peaks, stops, opacity) in enumerate(hills):
        steps.append({"command": "vector.create", "params": {
            "path": ridge(base, amplitude, seed, peaks), "parent": frame, "x": 0, "y": 0, "closed": True,
            "select": False, "name": f"Hills {index + 1}", "props": {
                "fills": [{"type": "linearGradient", "stops": stops, "from": [0.5, 0], "to": [0.5, 1]}],
                "opacity": opacity}}})
    return steps


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: dusk_footage.py <out.json>")
    with open(sys.argv[1], "w", encoding="utf-8") as out:
        json.dump(script(), out)

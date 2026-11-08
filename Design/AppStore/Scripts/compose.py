#!/usr/bin/env python3
"""Composes the App Store screenshots of a platform and a language with FigCraft, from the app captures and copy.json.

    FIGCRAFT_CLI=/path/to/figcraft-cli python3 -I compose.py <iphone|ipad|mac|tv> <en|it> <captures folder> <out folder>

Writes <out>/Fluxo-<platform>-<language>.figcraft (the design source: one frame per screenshot, the captures embedded)
and <out>/<id>.png (the exports, at the App Store Connect size of the platform, opaque, optimized with pngquant).
Every frame is drawn by figcraft-cli from the command script this writes (<out folder>/.script.json, not kept): the
brand background, the three streams of the icon flowing from one screenshot into the next, the words, the device and
the glass labels. Text uses Inter (built into FigCraft, SIL Open Font License), with FIGCRAFT_NO_SYSTEM_FONTS=1, so
the exports are the same on every Mac. Needs pngquant, and ffmpeg for the crop of a callout (`inset`).
"""
import json
import math
import os
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COPY = os.path.join(HERE, "..", "copy.json")

# App Store Connect sizes (Screenshot specifications, November 2026): iPhone 6.9" portrait, iPad 13" portrait,
# Mac 16:10, Apple TV 4K.
CANVAS = {"iphone": (1320, 2868), "ipad": (2064, 2752), "mac": (2880, 1800), "tv": (3840, 2160)}

# The widest the layouts show a capture, in pixels: (portrait capture, landscape capture). compose_slide's sizes.
DISPLAY_WIDTH = {"iphone": (960, 1200), "ipad": (1620, 1880), "mac": (1850, 1850), "tv": (2280, 2280)}

# The brand palette (docs/interface.md, "Brand and app icon").
VIOLET, INK, NIGHT_TOP, NIGHT_BOTTOM = "#6A4CFF", "#140F3C", "#281D69", "#0A0720"
CYAN, LILAC, PINK = "#3CD6FF", "#A08CFF", "#FF5C9E"
FONT = "Inter"


def ref(name):
    return {"$ref": name, "field": "id"}


def png_size(path):
    with open(path, "rb") as file:
        head = file.read(24)
    return struct.unpack(">II", head[16:24])


class Script:
    def __init__(self):
        self.steps = []
        self.count = 0

    def add(self, command, params, name=None):
        step = {"command": command, "params": params}
        if name:
            step["as"] = name
        self.steps.append(step)

    def unique(self, prefix):
        self.count += 1
        return f"{prefix}{self.count}"

    def rect(self, parent, x, y, w, h, props, name=None, layer="Rectangle"):
        self.add("node.create", {"type": "rectangle", "parent": parent, "x": x, "y": y, "width": w, "height": h,
                                 "select": False, "name": layer, "props": props}, name)

    def ellipse(self, parent, x, y, w, h, props, layer="Glow"):
        self.add("node.create", {"type": "ellipse", "parent": parent, "x": x, "y": y, "width": w, "height": h,
                                 "select": False, "name": layer, "props": props})

    def text(self, parent, text, x, y, width, props, layer=None):
        params = {"parent": parent, "text": text, "x": x, "y": y, "width": width, "select": False,
                  "props": dict({"fontFamily": FONT}, **props)}
        if layer:
            params["name"] = layer
        self.add("text.create", params)


# MARK: - Background

def background(s, frame, index, width, height):
    """The night gradient, a violet glow behind the words, and the icon's three streams (cyan, lilac, pink) as one
    panorama across every screenshot of the set: each frame shows its part, so they flow into one another."""
    s.rect(frame, 0, 0, width, height, {"fills": [{"type": "linearGradient", "stops": [NIGHT_TOP, INK, NIGHT_BOTTOM],
                                                   "from": [0.5, 0], "to": [0.5, 1]}]}, layer="Background")
    unit = min(width, height)
    s.ellipse(frame, width * 0.5 - unit * 0.75, -unit * 0.55, unit * 1.5, unit * 1.0,
              {"fill": VIOLET, "opacity": 0.45, "effects": [{"type": "layerBlur", "radius": unit * 0.22}]}, layer="Glow")
    portrait = height > width
    # The streams: long waves in panorama coordinates (x from 0 to count * width), lower in portrait sets (behind the
    # device, under the words) and through the middle in landscape ones.
    base = height * (0.58 if portrait else 0.62)
    amplitude = height * (0.13 if portrait else 0.16)
    wavelength = width * 1.7
    for number, (color, offset, phase) in enumerate([(CYAN, -0.07, 0.0), (LILAC, 0.0, 0.9), (PINK, 0.07, 1.8)]):
        points = []
        start = index * width - width * 0.3
        steps = 48
        for step in range(steps + 1):
            gx = start + width * 1.6 * step / steps
            gy = base + height * offset + amplitude * math.sin(2 * math.pi * gx / wavelength + phase) \
                + amplitude * 0.35 * math.sin(2 * math.pi * gx / (wavelength * 0.45) + phase * 2)
            points.append((gx - index * width, gy))
        path = " ".join(f"{'M' if i == 0 else 'L'} {x:.1f} {y:.1f}" for i, (x, y) in enumerate(points))
        left = min(x for x, _ in points)
        top = min(y for _, y in points)
        for weight, opacity, blur in [(unit * 0.16, 0.42, unit * 0.09), (unit * 0.035, 0.75, unit * 0.012)]:
            s.add("vector.create", {"path": path, "parent": frame, "x": left, "y": top, "closed": False, "select": False,
                                    "name": f"Stream {number + 1}", "props": {
                                        "fill": "none", "stroke": color, "strokeWeight": weight, "strokeCap": "round",
                                        "opacity": opacity, "effects": [{"type": "layerBlur", "radius": blur}]}})


# MARK: - Words

def lines(text, size, width, em):
    """How many lines `text` wraps into at `size` in `width` (a greedy word wrap; `em` is the average character width
    of the face in ems: about 0.47 for Inter Bold with the titles' tight tracking, 0.49 for Inter Medium)."""
    count = 0
    for paragraph in text.split("\n"):
        count += 1
        used = 0.0
        for word in paragraph.split(" "):
            advance = (len(word) + (1 if used else 0)) * size * em
            if used and used + advance > width:
                count += 1
                used = len(word) * size * em
            else:
                used += advance
    return count


def words(s, frame, slide, language, x, y, width, scale, align="center", one_line=False, size=108):
    """Kicker, title and subtitle from `y`; returns the bottom of the subtitle (estimated with `lines`).
    `one_line`: the title's line breaks (written for portrait screenshots) become spaces. A title with line breaks
    keeps them: copy.json breaks titles where they read well."""
    kicker = pick(slide.get("kicker"), language)
    title = pick(slide["title"], language)
    subtitle = pick(slide.get("subtitle"), language)
    if one_line:
        title = title.replace("\n", " ")
    if kicker:
        s.text(frame, kicker, x, y, width, {"fontStyle": "Bold", "fontSize": 30 * scale, "letterSpacing": "14%",
                                             "fill": CYAN, "textAlign": align}, layer="Kicker")
        y += 64 * scale
    title_size = size * scale
    s.text(frame, title, x, y, width, {"fontStyle": "Bold", "fontSize": title_size, "lineHeight": "104%",
                                        "letterSpacing": "-2.5%", "fill": "#FFFFFF", "textAlign": align}, layer="Title")
    # A title broken by hand is estimated line by line with Inter Bold's measured width (0.44 em); one left to wrap,
    # with a margin (0.47), so the subtitle never runs into it.
    title_lines = lines(title, title_size, width, 0.44 if "\n" in title else 0.47)
    y += title_size * 1.04 * title_lines + 34 * scale
    if subtitle:
        inset = width * 0.05 if align == "center" else 0
        subtitle_width = width - 2 * inset
        s.text(frame, subtitle, x + inset, y, subtitle_width,
               {"fontStyle": "Medium", "fontSize": 42 * scale, "lineHeight": "132%", "fill": "#D6D0FF", "opacity": 0.9,
                "textAlign": align}, layer="Subtitle")
        y += 42 * scale * 1.32 * lines(subtitle, 42 * scale, subtitle_width, 0.49)
    return y


def pick(value, language):
    if value is None or isinstance(value, (str, int, float)):
        return value
    return value.get(language, value.get("en"))


def chips(s, frame, labels, x, y, width, scale, size=40, align="center"):
    """Glass capsules in rows that wrap, centered in `width`: a translucent fill, a light rim and FigCraft's glass."""
    row = s.unique("chips")
    s.add("node.create", {"type": "frame", "parent": frame, "x": x, "y": y, "width": width, "height": 10, "select": False,
                          "name": "Labels", "props": {
                              "fills": [], "layout": "horizontal", "wrap": True, "gap": 22 * scale, "crossGap": 22 * scale,
                              "mainAlign": "center" if align == "center" else "min", "sizingV": "hug"}}, row)
    for label in labels:
        chip = s.unique("chip")
        s.add("node.create", {"type": "frame", "parent": ref(row), "select": False, "name": label, "props": {
            "layout": "horizontal", "sizingH": "hug", "sizingV": "hug", "padding": [26 * scale, 44 * scale, 26 * scale, 44 * scale],
            "cornerRadius": 200 * scale,
            "fills": [{"type": "solid", "color": "#FFFFFF", "opacity": 0.12}],
            "strokes": [{"type": "solid", "color": "#FFFFFF", "opacity": 0.38}], "strokeWeight": 2 * scale, "strokeAlign": "inside",
            "effects": [{"type": "backgroundBlur", "radius": 30 * scale},
                        {"type": "dropShadow", "color": "#0A072066", "radius": 40 * scale, "offset": [0, 12 * scale], "spread": 0}]}}, chip)
        s.add("text.create", {"parent": ref(chip), "text": label, "x": 0, "y": 0, "select": False, "props": {
            "fontFamily": FONT, "fontStyle": "SemiBold", "fontSize": size * scale, "fill": "#FFFFFF", "textAutoResize": "widthAndHeight"}})


def bubble(s, frame, text, x, y, scale):
    """A glass speech bubble with a quote: what to ask Siri."""
    name = s.unique("bubble")
    s.add("node.create", {"type": "frame", "parent": frame, "x": x, "y": y, "select": False, "name": "Bubble", "props": {
        "layout": "horizontal", "sizingH": "hug", "sizingV": "hug", "padding": [34 * scale, 54 * scale, 34 * scale, 54 * scale],
        "cornerRadius": [60 * scale, 60 * scale, 60 * scale, 14 * scale],
        "fills": [{"type": "linearGradient", "stops": ["#8F7BFFE6", "#6A4CFFE6"], "from": [0, 0], "to": [1, 1]}],
        "strokes": [{"type": "solid", "color": "#FFFFFF", "opacity": 0.4}], "strokeWeight": 2 * scale, "strokeAlign": "inside",
        "effects": [{"type": "backgroundBlur", "radius": 30 * scale},
                    {"type": "dropShadow", "color": "#0A072099", "radius": 60 * scale, "offset": [0, 20 * scale], "spread": 0}]}}, name)
    s.add("text.create", {"parent": ref(name), "text": text, "x": 0, "y": 0, "select": False, "props": {
        "fontFamily": FONT, "fontStyle": "Bold", "fontSize": 50 * scale, "fill": "#FFFFFF", "textAutoResize": "widthAndHeight"}})


# MARK: - Devices

def screen_image(s, frame, capture, x, y, w, h, radius):
    screen = s.unique("screen")
    s.rect(frame, x, y, w, h, {"cornerRadius": radius, "fill": "#000000"}, screen, layer="Screen")
    s.add("image.place", {"path": capture, "target": ref(screen), "mode": "fill", "name": "Capture"})


def iphone(s, frame, capture, x, y, screen_width, landscape=False):
    """An iPhone 17 Pro Max: titanium band, black border, the capture, the Dynamic Island and the side buttons.
    Returns the outer box (x, y, width, height)."""
    pw, ph = png_size(capture)
    sw = screen_width
    sh = sw * ph / pw
    short = min(sw, sh)
    border, band = short * 0.026, short * 0.011
    radius = short * 0.13
    ow, oh = sw + 2 * (border + band), sh + 2 * (border + band)
    titanium = {"type": "linearGradient", "stops": ["#5C5676", "#26222F", "#4B4662"], "from": [0, 0], "to": [1, 1]}
    # Side buttons, behind the band.
    if not landscape:
        for side, top, length in [("left", 0.17, 0.045), ("left", 0.245, 0.075), ("left", 0.335, 0.075), ("right", 0.27, 0.11)]:
            bx = x - band * 0.45 if side == "left" else x + ow - band * 0.55
            s.rect(frame, bx, y + oh * top, band, oh * length, {"cornerRadius": band / 2, "fills": [titanium]}, layer="Button")
    else:
        for side, left, length in [("top", 0.17, 0.045), ("top", 0.245, 0.075), ("top", 0.335, 0.075), ("bottom", 0.27, 0.11)]:
            by = y - band * 0.45 if side == "top" else y + oh - band * 0.55
            s.rect(frame, x + ow * left, by, ow * length, band, {"cornerRadius": band / 2, "fills": [titanium]}, layer="Button")
    s.rect(frame, x, y, ow, oh, {"cornerRadius": radius + border + band, "fills": [titanium],
                                 "strokes": [{"type": "solid", "color": "#A9A3C4", "opacity": 0.55}], "strokeWeight": max(1.5, band * 0.18),
                                 "strokeAlign": "inside",
                                 "effects": [{"type": "dropShadow", "color": "#05031299", "radius": short * 0.12,
                                              "offset": [0, short * 0.05], "spread": 0}]}, layer="iPhone")
    s.rect(frame, x + band, y + band, sw + 2 * border, sh + 2 * border, {"cornerRadius": radius + border, "fill": "#030305"}, layer="Border")
    sx, sy = x + band + border, y + band + border
    screen_image(s, frame, capture, sx, sy, sw, sh, radius)
    island_long, island_short = short * 0.29, short * 0.085
    if not landscape:
        s.rect(frame, sx + (sw - island_long) / 2, sy + short * 0.027, island_long, island_short,
               {"cornerRadius": island_short / 2, "fill": "#000000"}, layer="Dynamic Island")
    else:
        s.rect(frame, sx + short * 0.027, sy + (sh - island_long) / 2, island_short, island_long,
               {"cornerRadius": island_short / 2, "fill": "#000000"}, layer="Dynamic Island")
    return x, y, ow, oh


def ipad(s, frame, capture, x, y, screen_width):
    """An iPad Pro 13-inch in space black: an even border, rounded corners, the front camera on the long edge."""
    pw, ph = png_size(capture)
    sw = screen_width
    sh = sw * ph / pw
    short = min(sw, sh)
    border, band = short * 0.032, short * 0.006
    radius = short * 0.03
    ow, oh = sw + 2 * (border + band), sh + 2 * (border + band)
    s.rect(frame, x, y, ow, oh, {"cornerRadius": radius + border + band,
                                 "fills": [{"type": "linearGradient", "stops": ["#4A4658", "#1F1C27", "#3E3A4C"], "from": [0, 0], "to": [1, 1]}],
                                 "strokes": [{"type": "solid", "color": "#A9A3C4", "opacity": 0.5}], "strokeWeight": max(1.5, band * 0.4),
                                 "strokeAlign": "inside",
                                 "effects": [{"type": "dropShadow", "color": "#05031299", "radius": short * 0.08,
                                              "offset": [0, short * 0.035], "spread": 0}]}, layer="iPad")
    s.rect(frame, x + band, y + band, sw + 2 * border, sh + 2 * border, {"cornerRadius": radius + border, "fill": "#030305"}, layer="Border")
    camera = border * 0.28
    if sw > sh:
        s.ellipse(frame, x + band + border / 2 - camera / 2, y + oh / 2 - camera / 2, camera, camera, {"fill": "#15141C"}, layer="Camera")
    else:
        s.ellipse(frame, x + ow / 2 - camera / 2, y + band + border / 2 - camera / 2, camera, camera, {"fill": "#15141C"}, layer="Camera")
    screen_image(s, frame, capture, x + band + border, y + band + border, sw, sh, radius)
    return x, y, ow, oh


def television(s, frame, capture, x, y, screen_width):
    """A thin-bezel TV on a low stand."""
    pw, ph = png_size(capture)
    sw = screen_width
    sh = sw * ph / pw
    border = sw * 0.008
    ow, oh = sw + 2 * border, sh + 2 * border
    s.rect(frame, x + ow * 0.36, y + oh - sw * 0.01, ow * 0.28, sw * 0.045,
           {"cornerRadius": sw * 0.006, "fills": [{"type": "linearGradient", "stops": ["#3A3648", "#15131C"], "from": [0.5, 0], "to": [0.5, 1]}]},
           layer="Stand")
    s.rect(frame, x + ow * 0.3, y + oh + sw * 0.03, ow * 0.4, sw * 0.008, {"cornerRadius": sw * 0.004, "fill": "#2A2734"}, layer="Base")
    s.rect(frame, x, y, ow, oh, {"cornerRadius": border * 1.6, "fill": "#050408",
                                 "strokes": [{"type": "solid", "color": "#8C86A8", "opacity": 0.5}], "strokeWeight": max(2, border * 0.15),
                                 "strokeAlign": "inside",
                                 "effects": [{"type": "dropShadow", "color": "#050312AA", "radius": sw * 0.05, "offset": [0, sw * 0.02], "spread": 0}]},
           layer="TV")
    screen_image(s, frame, capture, x + border, y + border, sw, sh, border * 0.4)
    return x, y, ow, oh


def macbook(s, frame, capture, x, y, screen_width):
    """A MacBook Pro: the display with its notch, then the aluminium base. The capture is the whole screen."""
    pw, ph = png_size(capture)
    sw = screen_width
    sh = sw * ph / pw
    border = sw * 0.018
    lid_w, lid_h = sw + 2 * border, sh + border * 2.2
    s.rect(frame, x, y, lid_w, lid_h, {"cornerRadius": border * 1.8, "fill": "#0B0A0F",
                                       "strokes": [{"type": "solid", "color": "#8F8AA6", "opacity": 0.6}], "strokeWeight": max(2, border * 0.12),
                                       "strokeAlign": "inside",
                                       "effects": [{"type": "dropShadow", "color": "#050312AA", "radius": sw * 0.05, "offset": [0, sw * 0.02], "spread": 0}]},
           layer="Display")
    screen_image(s, frame, capture, x + border, y + border, sw, sh, border * 0.5)
    notch_w, notch_h = sw * 0.11, border * 1.15
    s.rect(frame, x + lid_w / 2 - notch_w / 2, y + border - 1, notch_w, notch_h, {"cornerRadius": [0, 0, notch_h * 0.5, notch_h * 0.5], "fill": "#0B0A0F"}, layer="Notch")
    base_w, base_h = lid_w * 1.16, sw * 0.028
    bx = x - (base_w - lid_w) / 2
    by = y + lid_h - 1
    s.rect(frame, bx, by, base_w, base_h, {"cornerRadius": [base_h * 0.15, base_h * 0.15, base_h * 0.9, base_h * 0.9],
                                           "fills": [{"type": "linearGradient", "stops": ["#C9C6D6", "#8E8AA0", "#4E4A5E"], "from": [0.5, 0], "to": [0.5, 1]}]},
           layer="Base")
    s.rect(frame, x + lid_w / 2 - lid_w * 0.09, by, lid_w * 0.18, base_h * 0.32, {"cornerRadius": [0, 0, base_h * 0.3, base_h * 0.3], "fill": "#6E6A80"}, layer="Opening")
    return bx, y, base_w, lid_h + base_h


# MARK: - Layouts

def chip_rows(labels, width, scale, size=40):
    """How many rows `chips` wraps `labels` into, and their height (Inter SemiBold is about 0.56 em per character)."""
    if not labels:
        return 0, 0
    rows, used = 1, 0
    for label in labels:
        chip = (len(label) * size * 0.56 + 88) * scale
        if used and used + 22 * scale + chip > width:
            rows, used = rows + 1, 0
        used += (22 * scale if used else 0) + chip
    return rows, rows * (size * 1.21 + 52) * scale + (rows - 1) * 22 * scale


def compose_slide(s, frame, slide, language, platform, capture, width, height):
    layout = pick(slide.get("layout"), language) or "portrait"
    # A label whose language is null is left out in that language.
    labels = [label for label in (pick(chip, language) for chip in slide.get("chips", [])) if label]
    # name: (scale of the words, their margin, their top, screen width of a portrait device, of a landscape one)
    metrics = {"iphone": (1.0, 70, 150, 960, 1200), "ipad": (1.45, 120, 170, 1620, 1880)}
    if platform in metrics:
        scale, margin, top, portrait_width, landscape_width = metrics[platform]
        device = iphone if platform == "iphone" else ipad
        bottom = words(s, frame, slide, language, margin, top, width - 2 * margin, scale)
        pw, ph = png_size(capture)
        if layout == "landscape":
            # The device turned, then the labels, centered together in the room under the words.
            sw = landscape_width
            sh = sw * ph / pw
            edge = 0.037 if platform == "iphone" else 0.038
            ow, oh = sw + 2 * edge * sh, sh + 2 * edge * sh
            gap = 140 * scale
            _, labels_height = chip_rows(labels, width - 180 * scale, scale, size=50)
            y = bottom + max(160 * scale, (height - bottom - (oh + gap + labels_height)) / 2 - 40 * scale)
            device(s, frame, capture, (width - ow) / 2, y, sw, **({"landscape": True} if platform == "iphone" else {}))
            chips(s, frame, labels, 90 * scale, y + oh + gap, width - 180 * scale, scale, size=50)
            return
        if layout == "rise":
            rise(s, frame, slide, language, platform, capture, width, height, bottom, labels, scale)
            return
        sw = portrait_width
        ow = sw * (1.074 if platform == "iphone" else 1.076)
        if labels:
            # The labels under the words, the device under them (it bleeds at the bottom).
            chips(s, frame, labels, width * 0.06, bottom + 20 * scale, width * 0.88, scale)
            bottom += 20 * scale + chip_rows(labels, width * 0.88, scale)[1]
        box = device(s, frame, capture, (width - ow) / 2, max(bottom + 80 * scale, (800 if platform == "iphone" else 900)), sw)
        decorate(s, frame, slide, language, box, scale)
    elif platform == "mac":
        # The words on top (a title on one line), the labels under them, then the MacBook as large as the room
        # under them allows, centered.
        scale, margin, top = 1.1, 220, 90
        bottom = words(s, frame, slide, language, margin, top, width - 2 * margin, scale, one_line=True)
        if labels:
            chips(s, frame, labels, width * 0.1, bottom + 10 * scale, width * 0.8, scale)
            bottom += 10 * scale + chip_rows(labels, width * 0.8, scale)[1]
        pw, ph = png_size(capture)
        room = height - bottom - 90
        # The display (the screen and 3.96 % of border), then the base: 0.028 of the width.
        sw = min(2300, room / (ph / pw + 0.0676))
        mac_x, mac_y = (width - sw * 1.036) / 2, bottom + 60
        macbook(s, frame, capture, mac_x, mac_y, sw)
        inset = slide.get("inset")
        if inset:
            # The callout over the room the page shown leaves (`inset.at`: its center, fractions of the screen).
            border = sw * 0.018
            fx, fy = inset.get("at", [0.6, 0.7])
            callout(s, frame, inset, language, mac_x + border + fx * sw, mac_y + border + fy * sw * ph / pw, scale)
    else:
        # Apple TV: the words in a column on the left, centered on the TV, which takes the right.
        scale = 1.25
        column_x, column_w = 200, 1160
        pw, ph = png_size(capture)
        sw = 2280
        ow = sw * 1.016
        oh = sw * ph / pw + sw * 0.016 + sw * 0.054
        tv_y = (height - oh) / 2 + 30
        television(s, frame, capture, width - ow - 150, tv_y, sw)
        # The words' height first (a dry run), to center them.
        probe = Script()
        bottom = words(probe, frame, slide, language, column_x, 0, column_w, scale, align="left", size=104)
        labels_height = chip_rows(labels, column_w, scale)[1] + 40 * scale if labels else 0
        y = (height - (bottom + labels_height)) / 2
        bottom = words(s, frame, slide, language, column_x, y, column_w, scale, align="left", size=104)
        if labels:
            chips(s, frame, labels, column_x, bottom + 40 * scale, column_w, scale, align="left")


def rise(s, frame, slide, language, platform, capture, width, height, bottom, labels, scale):
    """The device larger, rising from the bottom edge, which cuts its screen where the capture's content ends
    (`rise.cut`, a fraction of the capture's height), so no empty part of the screen shows; the Siri bubble and the
    labels centered in the room between the words and the device. `rise.screen_width`: the screen's width;
    `rise.cover_from` (optional): from there to the cut the screen is drawn black, hiding the cut-off edge of what
    lies behind the content (the Shortcuts app under Siri's answer)."""
    config = slide["rise"]
    pw, ph = png_size(capture)
    sw = config["screen_width"]
    sh = sw * ph / pw
    # The screen's inset in the device: iphone() and ipad() (border and band, fractions of the short side).
    inset = sw * (0.026 + 0.011 if platform == "iphone" else 0.032 + 0.006)
    ow = sw + 2 * inset
    sy = height - config["cut"] * sh
    x, y = (width - ow) / 2, sy - inset
    (iphone if platform == "iphone" else ipad)(s, frame, capture, x, y, sw)
    if config.get("cover_from") is not None:
        top = sy + config["cover_from"] * sh
        s.rect(frame, x + inset, top, sw, height - top + 2, {"fill": "#000000"}, layer="Cover")
    quote = pick(slide.get("bubble"), language)
    size = config.get("chip_size", 40)
    bubble_height = (2 * 34 + 50 * 1.21) * scale if quote else 0
    labels_height = chip_rows(labels, width * 0.88, scale, size=size)[1]
    gap = 44 * scale if quote and labels else 0
    group_top = bottom + max(40 * scale, (y - bottom - (bubble_height + gap + labels_height)) / 2)
    if quote:
        # In a full-width row that centers it (auto layout measures the bubble).
        row = s.unique("bubblerow")
        s.add("node.create", {"type": "frame", "parent": frame, "x": 0, "y": group_top, "width": width, "height": 10,
                              "select": False, "name": "Bubble row", "props": {
                                  "fills": [], "layout": "horizontal", "mainAlign": "center", "sizingV": "hug"}}, row)
        bubble(s, ref(row), quote, 0, 0, scale)
    if labels:
        chips(s, frame, labels, width * 0.06, group_top + bubble_height + gap, width * 0.88, scale, size=size)


def callout(s, frame, inset, language, center_x, center_y, scale):
    """Another screen of the app, enlarged on a glass card over the device (the Mac shows one page at a time), where
    the page shown has room: `inset.image` is the capture already cropped to it (main() makes it), `inset.width` its
    width on the card, `inset.label` the glass label on the card's top edge. The card is centered on
    (`center_x`, `center_y`)."""
    pw, ph = png_size(inset["image"])
    iw = inset["width"]
    ih = iw * ph / pw
    pad = 16 * scale
    cx, cy = center_x - iw / 2 - pad, center_y - ih / 2 - pad
    card = s.unique("card")
    s.rect(frame, cx, cy, iw + 2 * pad, ih + 2 * pad, {
        "cornerRadius": 30 * scale,
        "fills": [{"type": "linearGradient", "stops": ["#A08CFF66", "#6A4CFF40"], "from": [0, 0], "to": [1, 1]}],
        "strokes": [{"type": "solid", "color": LILAC, "opacity": 0.85}], "strokeWeight": 3 * scale, "strokeAlign": "inside",
        "effects": [{"type": "backgroundBlur", "radius": 40 * scale},
                    {"type": "dropShadow", "color": "#050312DD", "radius": 110 * scale, "offset": [0, 36 * scale], "spread": 0}]},
        card, layer="Callout")
    screen_image(s, frame, inset["image"], cx + pad, cy + pad, iw, ih, 18 * scale)
    label = pick(inset.get("label"), language)
    if label:
        # A tab standing on the card's top edge at its left end, over the rim only, so it hides none of the page
        # (sized as chip_rows measures it).
        size = 26
        chip_width = (len(label) * size * 0.56 + 88) * scale
        chip_height = chip_rows([label], iw, scale, size=size)[1]
        chips(s, frame, [label], cx + 36 * scale, cy - chip_height + 4 * scale, chip_width + 40 * scale, scale, size=size, align="left")


def decorate(s, frame, slide, language, box, scale):
    """The Siri bubble over the left edge of the device, at `bubble_at` (per language: a fraction of the device's
    height where the capture has no content under it, or a negative number for above the device, when the capture
    has no room)."""
    x, y, w, h = box
    quote = pick(slide.get("bubble"), language)
    if quote:
        at = float(pick(slide.get("bubble_at", {}), language) or 0.42)
        # The bubble's height: its padding and one line of 50 px Inter Bold.
        top = y - (2 * 34 + 50 * 1.21 + 60) * scale if at < 0 else y + h * at
        bubble(s, frame, quote, x - 20 * scale, top, scale)


# MARK: - Main

def optimize(source, target, opaque=True):
    """pngquant (quality 80-98, the slowest and best search), then a check of the size and the absence of alpha."""
    subprocess.run(["pngquant", "--quality", "80-98", "--speed", "1", "--strip", "--force", "--output", target, source], check=True)
    if opaque:
        flatten(target)


def flatten(path):
    """App Store Connect refuses images with an alpha channel: rewrites a PNG whose palette has transparency (tRNS)
    without it. The exports are opaque everywhere, so only the chunk goes."""
    with open(path, "rb") as file:
        data = file.read()
    out, offset = bytearray(data[:8]), 8
    changed = False
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        chunk = data[offset:offset + 12 + length]
        offset += 12 + length
        if kind == b"tRNS":
            changed = True
            continue
        out += chunk
    if changed:
        with open(path, "wb") as file:
            file.write(out)


def storyboard(copy, platform):
    """The slides of a platform; a platform may take another's ("from"), without some ("skip"), with fields replaced
    ("override")."""
    entry = copy[platform]
    if isinstance(entry, list):
        return entry
    slides = []
    for slide in storyboard(copy, entry["from"]):
        if slide["id"] in entry.get("skip", []):
            continue
        slides.append(dict(slide, **entry.get("override", {}).get(slide["id"], {})))
    return slides


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: compose.py <iphone|ipad|mac|tv> <en|it> <captures folder> <out folder>")
    platform, language, captures, out = sys.argv[1:]
    cli = os.environ.get("FIGCRAFT_CLI") or shutil.which("figcraft-cli")
    if not cli:
        sys.exit("set FIGCRAFT_CLI to figcraft-cli")
    with open(COPY, encoding="utf-8") as file:
        slides = storyboard(json.load(file), platform)
    width, height = CANVAS[platform]
    os.makedirs(out, exist_ok=True)
    work = os.path.join(out, ".work")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)

    s = Script()
    for index, slide in enumerate(slides):
        source = os.path.join(captures, slide["capture"] + ".png")
        if not os.path.exists(source):
            sys.exit(f"missing capture {source}")
        # The captures go into the document at the size the exports show them (no wider than the device's screen in
        # the layout) and quantized: a fraction of the size, the same pixels in the exports.
        capture = os.path.join(work, slide["capture"] + ".png")
        if not os.path.exists(capture):
            pw, ph = png_size(source)
            target = DISPLAY_WIDTH[platform][1 if pw > ph else 0]
            scaled = source
            if pw > target:
                scaled = os.path.join(work, slide["capture"] + "-scaled.png")
                subprocess.run(["sips", "--resampleWidth", str(target), source, "--out", scaled], check=True, capture_output=True)
            optimize(scaled, capture, opaque=False)
        inset = slide.get("inset")
        if inset:
            # The callout's screen: cropped (x, y, width, height in the capture's pixels), at its size on the card.
            inset_source = os.path.join(captures, inset["capture"] + ".png")
            if not os.path.exists(inset_source):
                sys.exit(f"missing capture {inset_source}")
            x, y, w, h = inset["crop"]
            cropped = os.path.join(work, inset["capture"] + "-crop.png")
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", inset_source, "-vf",
                            f"crop={w}:{h}:{x}:{y},scale={int(inset['width'])}:-1:flags=lanczos", cropped], check=True)
            inset_image = os.path.join(work, inset["capture"] + "-inset.png")
            optimize(cropped, inset_image, opaque=False)
            slide = dict(slide, inset=dict(inset, image=inset_image))
        name = f"frame{index}"
        s.add("frame.create", {"x": index * (width + 240), "y": 0, "width": width, "height": height, "name": slide["id"],
                               "select": False, "props": {"clip": True, "fill": INK}}, name)
        frame = ref(name)
        background(s, frame, index, width, height)
        compose_slide(s, frame, slide, language, platform, capture, width, height)

    script = os.path.join(work, "script.json")
    with open(script, "w", encoding="utf-8") as file:
        json.dump(s.steps, file, ensure_ascii=False)
    document = os.path.join(out, f"Fluxo-{platform}-{language}.figcraft")
    env = dict(os.environ, FIGCRAFT_NO_SYSTEM_FONTS="1")
    run = subprocess.run([cli, "run", script, "--out", document], env=env, capture_output=True, text=True)
    failures = [line for line in run.stdout.splitlines() if '"ok":false' in line]
    if run.returncode != 0 or failures:
        sys.exit("figcraft-cli run failed:\n" + "\n".join(failures or [run.stderr]))
    exports = os.path.join(work, "exports")
    subprocess.run([cli, "export", document, "-o", exports + "/", "--format", "png"], env=env, check=True, capture_output=True)
    for slide in slides:
        raw = os.path.join(exports, slide["id"] + ".png")
        final = os.path.join(out, slide["id"] + ".png")
        optimize(raw, final)
        size = png_size(final)
        if size != (width, height):
            sys.exit(f"{final} is {size[0]} x {size[1]}, not {width} x {height}")
        print(f"{final} ({os.path.getsize(final) // 1024} KB)")
    shutil.rmtree(work)


if __name__ == "__main__":
    main()

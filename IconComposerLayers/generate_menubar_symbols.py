#!/usr/bin/env python3
"""Generate the menu bar icons as SF Symbols custom symbol templates.

Writes one `.symbolset` per menu bar icon into the app's asset catalog, drawn from the
36x36 sources next to this script:

    menubar_icon_brightness.svg         -> MenuBarIcon
    menubar_icon_brightness_active.svg  -> MenuBarIconActive
    menubar_icon_split.svg              -> MenuBarIconSplit
    menubar_icon_tahoe.svg              -> MenuBarIconClassic

The sources are built from a handful of primitives (a disc, round-capped strokes, a
rounded rectangle), so this script rebuilds those primitives as outlined paths rather
than parsing the SVGs. Change a shape here and in its source SVG together.

Each template is a variable (v3) template with the Ultralight-S, Regular-S and Black-S
interpolation sources plus an explicit Regular-M, the glyph the menu bar actually draws.
Every source comes out of the same construction, so they share one path structure and
interpolate cleanly into the other weights.

Usage: python3 IconComposerLayers/generate_menubar_symbols.py [asset catalog path]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CATALOG = os.path.join(HERE, "..", "Dimmerly", "Resources", "Assets.xcassets")

# Cap height of the system font at the template's 100 pt typesetting size.
CAP = 70.459

# Regular-M is sized so that at the default 13 pt symbol size, which is what MenuBarExtra
# asks AppKit to draw, the 36-unit source canvas comes out at 18 pt, exactly the size the
# old 18 pt template PNGs drew at. One source unit is therefore 0.5 pt at 13 pt.
M_PER_UNIT = 50.0 / 13.0
# The system derives the medium and large scales from the small sources by a fixed factor,
# measured at 1.28 (medium / small). Regular-S is drawn smaller by that factor so the
# derived medium glyphs of every weight line up with the explicit Regular-M.
S_PER_UNIT = M_PER_UNIT / 1.28

# How each weight differs from Regular, read off sun.max.fill's Ultralight-S, Regular-S
# and Black-S glyphs: disc radius, stroke width, disc-to-ray gap and ray length.
WEIGHTS = {
    "Ultralight": {"disc": 0.886, "stroke": 0.29, "gap": 1.63, "length": 1.23},
    "Regular": {"disc": 1.0, "stroke": 1.0, "gap": 1.0, "length": 1.0},
    "Black": {"disc": 1.127, "stroke": 1.645, "gap": 1.0, "length": 0.80},
}
SOURCES = [("Ultralight", "S"), ("Regular", "S"), ("Black", "S"), ("Regular", "M")]

# Apple's template layout: weight columns and scale baselines on a 3300x2200 artboard.
COLUMNS = {"Ultralight": 559.711, "Regular": 1449.84, "Black": 2933.4}
BASELINES = {"S": 696.0, "M": 1126.0, "L": 1556.0}
H_REFERENCE = (
    "M0.993654 0L3.63775 0L29.3281-67.1323L30.0303-67.1323L30.0303-70.459L28.1226-70.459Z"
    "M11.6885-24.4799L46.9815-24.4799L46.2315-26.7285L12.4385-26.7285Z"
    "M55.1196 0L57.7637 0L30.6382-70.459L29.4326-70.459L29.4326-67.1323Z"
)


def fmt(value):
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


# ---------------------------------------------------------------- path primitives
# A contour is (start point, [segments]); a segment is ("L", point) or
# ("C", control1, control2, point). Coordinates are source units, y pointing down.


def _signed_area(start, segments):
    points = [start]
    for segment in segments:
        if segment[0] == "L":
            points.append(segment[1])
            continue
        p0 = points[-1]
        c1, c2, p3 = segment[1], segment[2], segment[3]
        for i in range(1, 9):
            t = i / 8
            u = 1 - t
            points.append((
                u**3 * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t**3 * p3[0],
                u**3 * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t**3 * p3[1],
            ))
    area = 0.0
    for i, (x1, y1) in enumerate(points):
        x2, y2 = points[(i + 1) % len(points)]
        area += x1 * y2 - x2 * y1
    return area / 2


def _reversed(start, segments):
    nodes = [start] + [segment[-1] for segment in segments]
    out = []
    for i in range(len(segments) - 1, -1, -1):
        segment = segments[i]
        if segment[0] == "L":
            out.append(("L", nodes[i]))
        else:
            out.append(("C", segment[2], segment[1], nodes[i]))
    return nodes[-1], out


def _oriented(start, segments, outer=True):
    """Outer contours wind one way and holes the other, so nonzero filling cuts holes."""
    if (_signed_area(start, segments) > 0) != outer:
        return _reversed(start, segments)
    return start, segments


def _arc(center, radius, start_angle, end_angle, pieces):
    segments = []
    step = (end_angle - start_angle) / pieces
    handle = 4 / 3 * math.tan(step / 4) * radius
    for i in range(pieces):
        a0 = start_angle + i * step
        a1 = a0 + step
        p0 = (center[0] + radius * math.cos(a0), center[1] + radius * math.sin(a0))
        p1 = (center[0] + radius * math.cos(a1), center[1] + radius * math.sin(a1))
        c1 = (p0[0] - handle * math.sin(a0), p0[1] + handle * math.cos(a0))
        c2 = (p1[0] + handle * math.sin(a1), p1[1] - handle * math.cos(a1))
        segments.append(("C", c1, c2, p1))
    return segments


def circle(center, radius, outer=True):
    start = (center[0] + radius, center[1])
    return _oriented(start, _arc(center, radius, 0, 2 * math.pi, 4), outer)


def round_capped_line(p1, p2, width):
    """Outline of an SVG <line> stroked with stroke-linecap="round"."""
    r = width / 2
    angle = math.atan2(p2[1] - p1[1], p2[0] - p1[0])
    nx, ny = -math.sin(angle), math.cos(angle)
    start = (p1[0] + nx * r, p1[1] + ny * r)
    segments = [("L", (p2[0] + nx * r, p2[1] + ny * r))]
    segments += _arc(p2, r, angle + math.pi / 2, angle - math.pi / 2, 2)
    segments.append(("L", (p1[0] - nx * r, p1[1] - ny * r)))
    segments += _arc(p1, r, angle - math.pi / 2, angle - 3 * math.pi / 2, 2)
    return _oriented(start, segments)


def rounded_rect(x0, y0, x1, y1, radius, outer=True):
    segments = [("L", (x1 - radius, y0))]
    segments += _arc((x1 - radius, y0 + radius), radius, -math.pi / 2, 0, 1)
    segments.append(("L", (x1, y1 - radius)))
    segments += _arc((x1 - radius, y1 - radius), radius, 0, math.pi / 2, 1)
    segments.append(("L", (x0 + radius, y1)))
    segments += _arc((x0 + radius, y1 - radius), radius, math.pi / 2, math.pi, 1)
    segments.append(("L", (x0, y0 + radius)))
    segments += _arc((x0 + radius, y0 + radius), radius, math.pi, 3 * math.pi / 2, 1)
    return _oriented((x0 + radius, y0), segments, outer)


def left_half_disc(center, radius):
    top = (center[0], center[1] - radius)
    segments = _arc(center, radius, -math.pi / 2, -3 * math.pi / 2, 2)
    segments.append(("L", top))
    return _oriented(top, segments)


# ---------------------------------------------------------------- glyphs
# A glyph is a list of shapes, each written as its own <path>. Shapes may overlap each
# other; contours within one shape never do.

CENTER = (18.0, 18.0)
RAY_DIRECTIONS = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]


def sun(weight, disc_radius, ray_start, ray_end, ray_width, ring_width=None):
    """A disc (or a split ring) with eight round-capped rays. Ray start and end are the
    distances of the stroke's endpoints from the centre, as in the source SVGs."""
    f = WEIGHTS[weight]
    width = ray_width * f["stroke"]
    body_edge = disc_radius + (ring_width / 2 if ring_width else 0)
    gap = (ray_start - ray_width / 2 - body_edge) * f["gap"]
    length = (ray_end - ray_start) * f["length"]
    radius = disc_radius * f["disc"]
    if ring_width:
        ring = ring_width * f["stroke"]
        shapes = [
            [left_half_disc(CENTER, radius)],
            [circle(CENTER, radius + ring / 2), circle(CENTER, radius - ring / 2, outer=False)],
        ]
        body_edge = radius + ring / 2
    else:
        shapes = [[circle(CENTER, radius)]]
        body_edge = radius
    start = body_edge + gap + width / 2
    for dx, dy in RAY_DIRECTIONS:
        norm = math.hypot(dx, dy)
        ux, uy = dx / norm, dy / norm
        p1 = (CENTER[0] + ux * start, CENTER[1] + uy * start)
        p2 = (CENTER[0] + ux * (start + length), CENTER[1] + uy * (start + length))
        shapes.append([round_capped_line(p1, p2, width)])
    return shapes


def sun_idle(weight):
    # menubar_icon_brightness.svg
    return sun(weight, disc_radius=6.4, ray_start=10.4, ray_end=14.6, ray_width=2.4)


def sun_active(weight):
    # menubar_icon_brightness_active.svg: the same sun with its rays pulled in
    return sun(weight, disc_radius=6.4, ray_start=9.0, ray_end=12.4, ray_width=2.8)


def sun_split(weight):
    # menubar_icon_split.svg
    return sun(weight, disc_radius=6.4, ray_start=10.4, ray_end=14.6, ray_width=2.4, ring_width=1.9)


def classic(weight):
    # menubar_icon_tahoe.svg. Its 45%-opacity glow circle is left out: a monochrome
    # template symbol has no partial-opacity layer, and at menu bar size the glow only
    # ever showed as a faint sliver beside the disc.
    f = WEIGHTS[weight]
    w = 2.5 * f["stroke"]
    x0, y0, x1, y1, r = 3.5, 5.5, 32.5, 24.5, 4.5
    frame = [
        rounded_rect(x0 - w / 2, y0 - w / 2, x1 + w / 2, y1 + w / 2, r + w / 2),
        rounded_rect(x0 + w / 2, y0 + w / 2, x1 - w / 2, y1 - w / 2, r - w / 2, outer=False),
    ]
    disc = [circle((17.4, 14.9), 3.8 * f["disc"])]
    neck = [rounded_rect(16.2, 24.7, 19.8, 28.9, 1.4)]
    foot = [_oriented((11.4, 31.2), [
        ("C", (13.2, 29.9), (14.6, 28.7), (15.8, 27.4)),
        ("L", (20.2, 27.4)),
        ("C", (21.4, 28.7), (22.8, 29.9), (24.6, 31.2)),
        ("L", (24.6, 31.9)),
        ("L", (11.4, 31.9)),
        ("L", (11.4, 31.2)),
    ])]
    return [frame, disc, neck, foot]


SYMBOLS = {
    "MenuBarIcon": (sun_idle, "Dimmerly menu bar sun"),
    "MenuBarIconActive": (sun_active, "Dimmerly menu bar sun, active"),
    "MenuBarIconSplit": (sun_split, "Dimmerly menu bar sun, split"),
    "MenuBarIconClassic": (classic, "Dimmerly menu bar display, classic"),
}


# ---------------------------------------------------------------- template writer


def _bounds(shapes):
    xs, ys = [], []
    for shape in shapes:
        for start, segments in shape:
            for point in [start] + [p for segment in segments for p in segment[1:]]:
                xs.append(point[0])
                ys.append(point[1])
    return min(xs), min(ys), max(xs), max(ys)


def _path_data(shape, transform):
    out = []
    for start, segments in shape:
        x, y = transform(start)
        out.append(f"M{fmt(x)} {fmt(y)}")
        for segment in segments:
            points = [transform(p) for p in segment[1:]]
            out.append(segment[0] + " ".join(f"{fmt(x)} {fmt(y)}" for x, y in points))
        out.append("Z")
    return "".join(out)


def template(name):
    design, description = SYMBOLS[name]
    # Side bearings of the Regular glyph in its 36-unit canvas, kept for every weight so
    # the symbol is as wide as the old 18 pt image and centred the same way.
    regular = _bounds(design("Regular"))
    left_bearing, right_bearing = regular[0], 36.0 - regular[2]

    guides, symbols = [], []
    for scale, baseline in BASELINES.items():
        guides += [
            f'  <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 {fmt(baseline)})">',
            f'   <path d="{H_REFERENCE}"/>',
            "  </g>",
            f'  <line id="Baseline-{scale}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" '
            f'x1="263" x2="3036" y1="{fmt(baseline)}" y2="{fmt(baseline)}"/>',
            f'  <line id="Capline-{scale}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" '
            f'x1="263" x2="3036" y1="{fmt(baseline - CAP)}" y2="{fmt(baseline - CAP)}"/>',
        ]
    for weight, scale in SOURCES:
        shapes = design(weight)
        x_min, _, x_max, _ = _bounds(shapes)
        unit = M_PER_UNIT if scale == "M" else S_PER_UNIT
        width = (x_max - x_min + left_bearing + right_bearing) * unit
        origin = x_min - left_bearing
        x = COLUMNS[weight] - width / 2
        baseline = BASELINES[scale]

        def transform(point, unit=unit, origin=origin):
            # Centre the 36-unit canvas on the middle of the cap height, like system symbols.
            return (point[0] - origin) * unit, (point[1] - 18.0) * unit - CAP / 2

        symbols.append(f'  <g id="{weight}-{scale}" transform="matrix(1 0 0 1 {fmt(x)} {fmt(baseline)})">')
        symbols += [f'   <path d="{_path_data(shape, transform)}"/>' for shape in shapes]
        symbols.append("  </g>")
        for side, edge in (("left", x), ("right", x + width)):
            guides.append(
                f'  <line id="{side}-margin-{weight}-{scale}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
                f'x1="{fmt(edge)}" x2="{fmt(edge)}" y1="{fmt(baseline - 95)}" y2="{fmt(baseline + 24)}"/>')

    text = 'style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;"'
    return "\n".join([
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">',
        '<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">',
        " <!-- Generated by IconComposerLayers/generate_menubar_symbols.py. Edit the script, not this file. -->",
        ' <g id="Notes">',
        '  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>',
        f'  <text id="template-version" {text} transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>',
        f'  <text {text} transform="matrix(1 0 0 1 3036 1951)">Requires Xcode 13 or greater</text>',
        f'  <text id="descriptive-name" {text} transform="matrix(1 0 0 1 3036 1969)">{description}</text>',
        f'  <text {text} transform="matrix(1 0 0 1 3036 1987)">Typeset at 100 points</text>',
        " </g>",
        ' <g id="Guides">',
        *guides,
        " </g>",
        ' <g id="Symbols">',
        *symbols,
        " </g>",
        "</svg>",
        "",
    ])


CONTENTS = """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "symbols" : [
    {
      "filename" : "%s",
      "idiom" : "universal"
    }
  ]
}
"""


def main():
    catalog = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CATALOG
    for name in SYMBOLS:
        directory = os.path.join(catalog, f"{name}.symbolset")
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, f"{name}.svg"), "w") as handle:
            handle.write(template(name))
        with open(os.path.join(directory, "Contents.json"), "w") as handle:
            handle.write(CONTENTS % f"{name}.svg")


if __name__ == "__main__":
    main()

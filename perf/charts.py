#!/usr/bin/env python3
"""Draw the bar charts of the README's Performance section.

Each project gets one SVG with two panels. The clean build and the hub-abi
rebuild take minutes, and the other scenarios take seconds, so each group
gets its own scale. Otherwise the small edits would be too short to see.

Usage: perf/charts.py [OUTDIR]
"""

import argparse
import os
from html import escape

# Seconds of wall-clock time, from the benchmark's results tables.
PROJECTS = {
    "cabal": {
        "title": "The Cabal project",
        "subtitle": "Without cabal-testsuite",
        "results": {
            "cabal": {"clean": 108.6, "noop": 2.8, "hub-comment": 22.7, "hub-abi": 47.3, "leaf": 5.9},
            "buck2-component": {"clean": 90.9, "noop": 0.0, "hub-comment": 7.0, "hub-abi": 30.5, "leaf": 0.2},
            "buck2-module": {"clean": 70.0, "noop": 0.0, "hub-comment": 2.4, "hub-abi": 20.2, "leaf": 0.3},
            "repl": {"clean": 39.7, "noop": 0.9, "hub-comment": 1.7, "hub-abi": 5.7, "leaf": 0.9},
        },
    },
    "hls": {
        "title": "haskell-language-server",
        "subtitle": "About 240 library modules in some 35 libraries",
        "results": {
            "cabal": {"clean": 255.4, "noop": 16.1, "hub-comment": 116.4, "hub-abi": 212.8, "leaf": 23.0},
            "buck2-component": {"clean": 95.3, "noop": 0.0, "hub-comment": 13.1, "hub-abi": 62.9, "leaf": 2.8},
            "buck2-module": {"clean": 71.3, "noop": 0.0, "hub-comment": 3.1, "hub-abi": 45.6, "leaf": 1.1},
            "repl": {"clean": 73.5, "noop": 3.6, "hub-comment": 4.6, "hub-abi": 8.0, "leaf": 3.5},
        },
    },
    "amazonka": {
        "title": "amazonka",
        "subtitle": "amazonka-core, amazonka and 7 services: about 4,500 modules",
        "results": {
            "cabal": {"clean": 139.5, "noop": 3.3, "hub-comment": 17.9, "hub-abi": 246.0, "leaf": 6.9},
            "buck2-component": {"clean": 182.2, "noop": 0.0, "hub-comment": 9.4, "hub-abi": 238.6, "leaf": 0.5},
            "buck2-module": {"clean": 118.0, "noop": 0.0, "hub-comment": 2.4, "hub-abi": 217.5, "leaf": 0.4},
            "repl": {"clean": 89.6, "noop": 1.6, "hub-comment": 1.7, "hub-abi": 69.7, "leaf": 1.6},
        },
    },
}

SERIES = [
    ("cabal", "cabal", "#2a78d6"),
    ("buck2-component", "buck2, per component", "#eb6834"),
    ("buck2-module", "buck2, per module", "#1baf7a"),
    ("repl", "cabal repl", "#e87ba4"),
]

PANELS = [
    ("Full builds", [("clean", "clean", "build everything"), ("hub-abi", "hub-abi", "export added to a hub")]),
    (
        "Small edits",
        [
            ("noop", "noop", "nothing changed"),
            ("hub-comment", "hub-comment", "comment in a hub"),
            ("leaf", "leaf", "edit to a leaf module"),
        ],
    ),
]

SURFACE = "#ffffff"
TEXT = "#0b0b0b"
TEXT_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
BASELINE = "#c3c2b7"

BAR = 22
BAR_GAP = 3
GROUP_GAP = 30
PANEL_PAD = 18
AXIS_W = 44
PANEL_GAP = 36
LEFT = 24
TOP = 110
PLOT_H = 250
HEIGHT = TOP + PLOT_H + 64


def nice_max(v):
    """The smallest round number at least `v`, and the step between ticks."""
    for step in [0.5, 1, 2, 5, 10, 20, 25, 50, 100]:
        for ticks in range(2, 7):
            if step * ticks >= v:
                return step * ticks, step
    return v, v / 5


def fmt(v):
    if v == 0:
        return "0s"
    if v >= 10:
        return f"{v:.0f}s"
    return f"{v:.1f}s"


def bar_path(x, base, h, w, r=4):
    """A bar whose top corners are rounded and whose bottom sits on the baseline."""
    if h <= 0:
        return None
    r = min(r, h, w / 2)
    top = base - h
    return (
        f"M{x:.1f},{base:.1f} V{top + r:.1f} Q{x:.1f},{top:.1f} {x + r:.1f},{top:.1f} "
        f"H{x + w - r:.1f} Q{x + w:.1f},{top:.1f} {x + w:.1f},{top + r:.1f} V{base:.1f} Z"
    )


def chart(project, series):
    results = project["results"]
    n = len(series)
    group_w = n * BAR + (n - 1) * BAR_GAP
    out = []
    x = LEFT
    panel_boxes = []
    for title, groups in PANELS:
        vals = [results[k][g] for g, _, _ in groups for k, _, _ in series]
        top, step = nice_max(max(vals))
        plot_w = len(groups) * group_w + (len(groups) - 1) * GROUP_GAP + 2 * PANEL_PAD
        panel_boxes.append((x, title, groups, top, step, plot_w))
        x += AXIS_W + plot_w + PANEL_GAP
    width = x - PANEL_GAP + LEFT

    out.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:.0f} {HEIGHT}" '
        f'font-family="system-ui, -apple-system, Segoe UI, sans-serif">'
    )
    out.append(f'  <rect x="0" y="0" width="{width:.0f}" height="{HEIGHT}" fill="{SURFACE}" />')
    out.append(f'  <text x="{LEFT}" y="32" font-size="19" font-weight="600" fill="{TEXT}">{escape(project["title"])}</text>')
    out.append(f'  <text x="{LEFT}" y="52" font-size="12.5" fill="{TEXT_2}">{escape(project["subtitle"])} &#8212; wall-clock seconds, unoptimised, 8 jobs</text>')

    lx = LEFT
    for _, label, colour in series:
        out.append(f'  <rect x="{lx}" y="66" width="10" height="10" rx="2" fill="{colour}" />')
        out.append(f'  <text x="{lx + 16}" y="75" font-size="12.5" fill="{TEXT_2}">{escape(label)}</text>')
        lx += 16 + 7.2 * len(label) + 18

    base = TOP + PLOT_H
    for px, title, groups, top, step, plot_w in panel_boxes:
        x0 = px + AXIS_W
        out.append(f'  <text x="{x0}" y="{TOP - 14}" font-size="13" font-weight="600" fill="{TEXT}">{escape(title)}</text>')
        out.append(f'  <g stroke="{GRID}" stroke-width="1">')
        ticks = []
        t = 0.0
        while t <= top + 1e-9:
            y = base - PLOT_H * t / top
            ticks.append((t, y))
            out.append(f'    <line x1="{x0}" y1="{y:.1f}" x2="{x0 + plot_w}" y2="{y:.1f}" />')
            t += step
        out.append("  </g>")
        out.append(f'  <g font-size="11" fill="{MUTED}" text-anchor="end">')
        for t, y in ticks:
            label = f"{t:g}"
            out.append(f'    <text x="{x0 - 8}" y="{y + 3.5:.1f}">{label}</text>')
        out.append("  </g>")
        out.append(f'  <line x1="{x0}" y1="{base}" x2="{x0 + plot_w}" y2="{base}" stroke="{BASELINE}" stroke-width="1" />')

        gx = x0 + PANEL_PAD
        for g, name, desc in groups:
            bx = gx
            for k, label, colour in series:
                v = results[k][g]
                h = PLOT_H * v / top
                path = bar_path(bx, base, h, BAR)
                if path:
                    tip = escape(f"{label}, {g}: {v}s")
                    out.append(f'  <path d="{path}" fill="{colour}"><title>{tip}</title></path>')
                out.append(
                    f'  <text x="{bx + BAR / 2:.1f}" y="{base - h - 6:.1f}" font-size="10.5" text-anchor="middle" '
                    f'fill="{TEXT_2}" font-variant-numeric="tabular-nums">{fmt(v)}</text>'
                )
                bx += BAR + BAR_GAP
            mid = gx + group_w / 2
            out.append(f'  <text x="{mid:.1f}" y="{base + 20}" font-size="12.5" text-anchor="middle" fill="{TEXT}">{escape(name)}</text>')
            out.append(f'  <text x="{mid:.1f}" y="{base + 36}" font-size="11" text-anchor="middle" fill="{TEXT_2}">{escape(desc)}</text>')
            gx += group_w + GROUP_GAP
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir", nargs="?", default=os.path.dirname(os.path.abspath(__file__)))
    args = ap.parse_args()
    for name, project in PROJECTS.items():
        with open(os.path.join(args.outdir, name + ".svg"), "w") as f:
            f.write(chart(project, SERIES))


if __name__ == "__main__":
    main()

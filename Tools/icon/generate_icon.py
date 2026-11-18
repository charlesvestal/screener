#!/usr/bin/env -S uv run --with pillow --with numpy python3
"""Generates Screener's app icon: a rounded display/tablet silhouette with a
bold diagonal "beam" motif, in a deep-indigo-to-teal gradient. Original
artwork — no Apple or third-party imagery, and deliberately distinct from
Apple's Screen Sharing icon and the Screens app icon (neither of which uses
a diagonal beam-through-a-tablet motif).

Usage:
    uv run --with pillow python3 Tools/icon/generate_icon.py [output.png] [--variant light|dark|tinted]

Produces a single 1024x1024 opaque (no-alpha) PNG per variant. Run with no
args to (re)generate all three into Screener/Assets.xcassets/AppIcon.appiconset/.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

SIZE = 1024
SS = 4            # supersample factor for smooth anti-aliased edges
CANVAS = SIZE * SS


def lerp_color(a: tuple[int, int, int], b: tuple[int, int, int], t: np.ndarray) -> np.ndarray:
    a_arr = np.array(a, dtype=np.float32)
    b_arr = np.array(b, dtype=np.float32)
    return a_arr[None, None, :] + (b_arr - a_arr)[None, None, :] * t[:, :, None]


def diagonal_gradient(size: int, c0: tuple[int, int, int], c1: tuple[int, int, int]) -> Image.Image:
    """A top-left -> bottom-right linear gradient, c0 to c1."""
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    t = (xs + ys) / (2 * (size - 1))
    t = np.clip(t, 0.0, 1.0)
    rgb = lerp_color(c0, c1, t).astype(np.uint8)
    return Image.fromarray(rgb, mode="RGB")


def rounded_mask(size: int, margin: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([margin, margin, size - 1 - margin, size - 1 - margin], radius=radius, fill=255)
    return mask


def beam_mask(size: int, center_offset: float, width: float, extend: float = 1.6) -> Image.Image:
    """A bold diagonal stripe (a thick line, 45 degrees) through the canvas
    center, offset perpendicular to the diagonal by `center_offset` and
    `width` wide, as a soft-free polygon (crisp since we supersample)."""
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    cx = cy = size / 2
    # Direction along the beam (NW->SE) and its perpendicular, both unit length.
    along = (1 / math.sqrt(2), 1 / math.sqrt(2))
    perp = (-along[1], along[0])
    L = size * extend
    ox, oy = perp[0] * center_offset, perp[1] * center_offset
    p0 = (cx - along[0] * L + ox, cy - along[1] * L + oy)
    p1 = (cx + along[0] * L + ox, cy + along[1] * L + oy)
    half_w = width / 2
    poly = [
        (p0[0] + perp[0] * half_w, p0[1] + perp[1] * half_w),
        (p1[0] + perp[0] * half_w, p1[1] + perp[1] * half_w),
        (p1[0] - perp[0] * half_w, p1[1] - perp[1] * half_w),
        (p0[0] - perp[0] * half_w, p0[1] - perp[1] * half_w),
    ]
    d.polygon(poly, fill=255)
    return mask


# Per-variant palette. "light"/"dark" are the iOS 18+ alternate appearances;
# "tinted" is desaturated per HIG (the system still applies its own tint, but
# the base art should read in grayscale-ish tones).
PALETTES = {
    "light": dict(
        background=(18, 14, 36),          # deep indigo-black
        display0=(47, 32, 128),           # indigo
        display1=(16, 170, 150),          # teal
        beam=(255, 255, 255),
        beam_alpha=0.92,
        echo_alpha=0.30,
    ),
    "dark": dict(
        background=(8, 6, 18),            # darker still, for the dark appearance
        display0=(36, 24, 98),
        display1=(13, 138, 122),
        beam=(255, 255, 255),
        beam_alpha=0.88,
        echo_alpha=0.26,
    ),
    "tinted": dict(
        background=(30, 30, 34),          # neutral — the system applies its tint
        display0=(90, 90, 98),
        display1=(150, 150, 156),
        beam=(255, 255, 255),
        beam_alpha=0.85,
        echo_alpha=0.22,
    ),
}


def render(variant: str) -> Image.Image:
    p = PALETTES[variant]
    canvas = Image.new("RGB", (CANVAS, CANVAS), p["background"])

    # The display: a big rounded square, like a tablet silhouette, holding
    # the diagonal gradient.
    margin = int(CANVAS * 0.095)
    radius = int(CANVAS * 0.19)
    disp_mask = rounded_mask(CANVAS, margin, radius)
    gradient = diagonal_gradient(CANVAS, p["display0"], p["display1"])
    canvas.paste(gradient, (0, 0), disp_mask)

    # The beam: one bold stripe plus a fainter echo above it, suggesting a
    # signal — both clipped to the display so they read as "coming through"
    # the screen, not floating outside it.
    width = CANVAS * 0.17
    main = beam_mask(CANVAS, center_offset=CANVAS * 0.05, width=width)
    echo = beam_mask(CANVAS, center_offset=-CANVAS * 0.16, width=width * 0.62)

    def composite_tint(mask: Image.Image, color: tuple[int, int, int], alpha: float) -> None:
        clipped = Image.new("L", (CANVAS, CANVAS), 0)
        clipped.paste(mask, (0, 0), disp_mask)
        # scale mask by alpha
        arr = np.array(clipped, dtype=np.float32) * alpha
        alpha_mask = Image.fromarray(arr.astype(np.uint8), mode="L")
        tint = Image.new("RGB", (CANVAS, CANVAS), color)
        canvas.paste(tint, (0, 0), alpha_mask)

    composite_tint(echo, p["beam"], p["echo_alpha"])
    composite_tint(main, p["beam"], p["beam_alpha"])

    out = canvas.resize((SIZE, SIZE), Image.LANCZOS)
    # Guarantee a fully opaque RGB PNG (no alpha channel at all).
    return out.convert("RGB")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("output", nargs="?", help="Write a single PNG here (implies --variant).")
    ap.add_argument("--variant", choices=["light", "dark", "tinted"], default="light")
    args = ap.parse_args()

    if args.output:
        img = render(args.variant)
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        img.save(out_path, "PNG")
        print(f"wrote {out_path} ({args.variant})")
        return

    repo_root = Path(__file__).resolve().parents[2]
    appiconset = repo_root / "Screener" / "Assets.xcassets" / "AppIcon.appiconset"
    appiconset.mkdir(parents=True, exist_ok=True)
    names = {"light": "icon-1024.png", "dark": "icon-1024-dark.png", "tinted": "icon-1024-tinted.png"}
    for variant, name in names.items():
        img = render(variant)
        dest = appiconset / name
        img.save(dest, "PNG")
        print(f"wrote {dest}")


if __name__ == "__main__":
    main()

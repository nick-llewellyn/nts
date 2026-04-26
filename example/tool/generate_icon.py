#!/usr/bin/env python3
"""Rasterize the `nts` example app icon.

Mirrors the geometry of `assets/icon/source.svg` (the canonical
hand-authored vector source) using Pillow primitives so we don't
depend on an external SVG rasterizer (`rsvg-convert`, `magick`)
being installed on the toolchain. Outputs three PNGs that drive
`flutter_launcher_icons`:

  * `assets/icon/icon.png`              -- 1024x1024 full-bleed
  * `assets/icon/icon_foreground.png`   -- 1024x1024 transparent
                                           foreground for Android
                                           adaptive icons (logo
                                           inset to ~66% so it
                                           survives every OEM mask)
  * `assets/icon/icon_background.png`   -- 1024x1024 solid plate

Run inside a venv that has Pillow installed:

    python3 -m venv /tmp/icongen
    /tmp/icongen/bin/pip install Pillow
    /tmp/icongen/bin/python tool/generate_icon.py
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

# Geometry constants (1024-canvas units), kept in sync with source.svg.
SIZE = 1024
BG = (63, 81, 181, 255)          # brand indigo #3F51B5
SHIELD = (255, 255, 255, 255)
HANDS = (26, 35, 126, 255)       # darker brand indigo #1A237E

# Shield outline. Top corners rounded with quadratic curves; bottom
# tapers into a curved point built from two cubic Beziers that meet
# at (512, 870). See source.svg for the human-readable path.
SHIELD_TOP_LEFT = (280, 240)
SHIELD_TOP_RIGHT = (744, 240)
SHIELD_BOTTOM = (512, 870)


def _quad(p0, p1, p2, n=24):
    """Sample a quadratic Bezier as a list of (x, y) tuples."""
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        x = u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0]
        y = u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]
        out.append((x, y))
    return out


def _cubic(p0, p1, p2, p3, n=48):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        x = (u * u * u * p0[0]
             + 3 * u * u * t * p1[0]
             + 3 * u * t * t * p2[0]
             + t * t * t * p3[0])
        y = (u * u * u * p0[1]
             + 3 * u * u * t * p1[1]
             + 3 * u * t * t * p2[1]
             + t * t * t * p3[1])
        out.append((x, y))
    return out


def _shield_polygon():
    pts = []
    # Top-left rounded shoulder: (280,240) curving to (340,180)
    pts += _quad((280, 240), (280, 180), (340, 180))
    # Top straight edge to (684,180)
    pts.append((684, 180))
    # Top-right rounded shoulder
    pts += _quad((684, 180), (744, 180), (744, 240))
    # Right side down to (744,540)
    pts.append((744, 540))
    # Right curve into the bottom point
    pts += _cubic((744, 540), (744, 700), (640, 820), (512, 870))
    # Left curve back up to (280,540)
    pts += _cubic((512, 870), (384, 820), (280, 700), (280, 540))
    return pts


def _draw_logo(draw: ImageDraw.ImageDraw):
    draw.polygon(_shield_polygon(), fill=SHIELD)
    # Clock hands: 10:10 pose, originating at (512, 540).
    draw.line([(512, 540), (412, 430)], fill=HANDS, width=44)
    draw.line([(512, 540), (650, 380)], fill=HANDS, width=36)
    # Centre pin + inner highlight.
    draw.ellipse([(486, 514), (538, 566)], fill=HANDS)
    draw.ellipse([(502, 530), (522, 550)], fill=SHIELD)


def main():
    out_dir = Path(__file__).resolve().parents[1] / "assets" / "icon"
    out_dir.mkdir(parents=True, exist_ok=True)

    # Full-bleed icon (iOS / generic).
    full = Image.new("RGBA", (SIZE, SIZE), BG)
    _draw_logo(ImageDraw.Draw(full))
    full.save(out_dir / "icon.png", "PNG")

    # Transparent foreground for Android adaptive icons. The launcher
    # mask hides the outer ~33% of the canvas, so we render the logo
    # at higher resolution then paste it scaled into the central
    # safe-zone (~66% of the canvas) on a transparent background.
    logo_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    _draw_logo(ImageDraw.Draw(logo_layer))
    fg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    inset = int(SIZE * 0.66)
    scaled = logo_layer.resize((inset, inset), Image.LANCZOS)
    offset = (SIZE - inset) // 2
    fg.paste(scaled, (offset, offset), scaled)
    fg.save(out_dir / "icon_foreground.png", "PNG")

    # Solid background plate.
    bg = Image.new("RGBA", (SIZE, SIZE), BG)
    bg.save(out_dir / "icon_background.png", "PNG")

    print(f"wrote {out_dir}/icon.png")
    print(f"wrote {out_dir}/icon_foreground.png")
    print(f"wrote {out_dir}/icon_background.png")


if __name__ == "__main__":
    main()

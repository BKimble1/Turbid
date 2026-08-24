#!/usr/bin/env python3
"""Draw the App Store icon.

An archive without a 1024x1024 icon is rejected by App Store Connect with a
`CFBundleIconName` error, and a simulator build only warns about it — so a
missing icon is a problem nobody sees until the upload fails. This draws one,
deterministically, from the app's own palette.

    python3 -m pip install Pillow
    python3 Tools/make_app_icon.py

Requirements it satisfies: 1024x1024, PNG, sRGB, fully opaque, square corners
and no alpha channel. The system applies the rounded mask itself; baking one in
produces a dark halo.
"""

from __future__ import annotations

import math
import os
import sys

SIZE = 1024
# `Theme.Palette` in dark appearance: the ground the app is drawn on, and the
# cyan the interface uses for anything optical.
NAVY_DEEP = (0x06, 0x0A, 0x12)
NAVY = (0x0A, 0x0F, 0x1A)
CYAN = (0x4F, 0xD8, 0xE8)
CYAN_DIM = (0x1B, 0x4E, 0x5C)


def draw(path: str) -> None:
    try:
        from PIL import Image, ImageDraw, ImageFilter
    except ImportError:
        print("app icon SKIPPED  (pip install Pillow)")
        return

    image = Image.new("RGB", (SIZE, SIZE), NAVY)
    pixels = image.load()

    # A soft radial lift towards the centre, so the ground is not a flat block.
    centre = SIZE / 2
    longest = math.hypot(centre, centre)
    for y in range(SIZE):
        for x in range(SIZE):
            distance = math.hypot(x - centre, y - centre) / longest
            fade = max(0.0, 1.0 - distance * 1.25)
            pixels[x, y] = tuple(
                int(deep + (near - deep) * fade)
                for deep, near in zip(NAVY_DEEP, NAVY)
            )

    # The beam: a wedge of light crossing the sample from the upper left, drawn
    # on its own layer and blurred so it reads as light rather than as a shape.
    beam = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(beam).polygon(
        [(0, 0.20 * SIZE), (0, 0.36 * SIZE), (SIZE, 0.78 * SIZE), (SIZE, 0.54 * SIZE)],
        fill=70,
    )
    beam = beam.filter(ImageFilter.GaussianBlur(SIZE * 0.045))
    image = Image.composite(Image.new("RGB", (SIZE, SIZE), CYAN), image, beam)

    draw_on = ImageDraw.Draw(image)

    # The sample: a ring, not a disc. A disc would read as a full moon; a ring
    # reads as something you look through.
    radius = SIZE * 0.30
    ring = SIZE * 0.055
    draw_on.ellipse(
        [centre - radius, centre - radius, centre + radius, centre + radius],
        outline=CYAN,
        width=int(ring),
    )
    # An inner ring at low contrast, for depth.
    inner = radius - ring * 1.45
    draw_on.ellipse(
        [centre - inner, centre - inner, centre + inner, centre + inner],
        outline=CYAN_DIM,
        width=int(SIZE * 0.016),
    )

    # Suspended particles, on a fixed spiral so the icon is reproducible.
    for index in range(9):
        angle = index * 2.399963  # the golden angle, in radians
        spread = inner * 0.82 * math.sqrt((index + 0.5) / 9)
        x = centre + math.cos(angle) * spread
        y = centre + math.sin(angle) * spread
        dot = SIZE * (0.011 + 0.005 * ((index % 3) / 2))
        draw_on.ellipse([x - dot, y - dot, x + dot, y + dot], fill=CYAN)

    image.save(path, "PNG", optimize=True)
    print(f"app icon written  ({path}, {SIZE}x{SIZE}, no alpha)")


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    target = os.path.join(root, "Turbid", "Resources", "Assets.xcassets",
                          "AppIcon.appiconset", "AppIcon.png")
    draw(target)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Generate the iOS app icon into App/Assets.xcassets/AppIcon.appiconset.

TestFlight rejects a build whose asset catalog has no AppIcon, so the output is
committed rather than remembered -- same convention as the control-centre app,
where the icon is generated from the PWA's own generator.

This one is a placeholder with a point to make: a dark, quiet tile with a
speech bubble and a dot, drawn from geometry so it is the same file on every
machine and every CI run. Replace the drawing when there is a real mark; keep
the pipeline.

    python3 scripts/make-icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "App" / "Assets.xcassets" / "AppIcon.appiconset"

# Deep slate with a hint of teal: reads as "the house machine", not as a
# vendor's brand colour, and it keeps the SF Symbols in the app the only accent.
TOP = (16, 22, 28)
BOTTOM = (26, 44, 52)
INK = (238, 244, 246)
ACCENT = (108, 196, 178)


def gradient() -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE), TOP)
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        colour = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
        draw.line([(0, y), (SIZE, y)], fill=colour)
    return img


def bubble(draw: ImageDraw.ImageDraw) -> None:
    """A speech bubble with a tail, drawn as a stroked rounded rect."""
    margin = int(SIZE * 0.22)
    box = [margin, margin, SIZE - margin, int(SIZE * 0.70)]
    radius = int((box[3] - box[1]) * 0.34)
    width = int(SIZE * 0.045)
    draw.rounded_rectangle(box, radius=radius, outline=INK, width=width)

    # The tail: a small wedge off the lower-left, same stroke weight.
    tail_top = (box[0] + radius, box[3] - width // 2)
    tail_tip = (box[0] + int(radius * 0.35), int(box[3] + SIZE * 0.085))
    tail_right = (box[0] + int(radius * 1.55), box[3] - width // 2)
    draw.line([tail_top, tail_tip, tail_right], fill=INK, width=width, joint="curve")


def dot(draw: ImageDraw.ImageDraw) -> None:
    """The one accent: a dot where the message would be."""
    r = int(SIZE * 0.075)
    cx, cy = SIZE // 2, int(SIZE * 0.455)
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=ACCENT)


def main() -> None:
    img = gradient().convert("RGBA")
    draw = ImageDraw.Draw(img)
    bubble(draw)
    dot(draw)

    OUT.mkdir(parents=True, exist_ok=True)
    icon = img.resize((SIZE, SIZE), Image.LANCZOS)
    icon.save(OUT / "icon-1024.png", optimize=True)
    print(f"wrote {OUT / 'icon-1024.png'}")


if __name__ == "__main__":
    main()

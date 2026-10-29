#!/usr/bin/env python3
"""Generate the iOS app icon into App/Assets.xcassets/AppIcon.appiconset.

TestFlight rejects a build whose asset catalog has no AppIcon, so the output is
committed rather than remembered -- same convention as the control-centre app,
where the icon is generated from the PWA's own generator.

The mark: a chat bubble that is also a cat. The bubble body carries two ears
and a tail that curl out of the same silhouette, and inside it the typing
indicator -- two ink dots and one teal, the app's whole "someone is thinking"
moment in three circles. Everything is drawn from geometry at 4x and reduced
with LANCZOS, so it is the same file on every machine and every CI run.

    python3 scripts/make-icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SS = SIZE * 4  # supersample canvas; the downsample is the antialias

# Deep slate with a hint of teal: reads as "the house machine", not as a
# vendor's brand colour, and it keeps the SF Symbols in the app the only accent.
TOP = (16, 22, 28)
BOTTOM = (26, 44, 52)
INK = (238, 244, 246)
ACCENT = (108, 196, 178)
DARK = (22, 28, 34)


def gradient() -> Image.Image:
    img = Image.new("RGB", (SS, SS), TOP)
    draw = ImageDraw.Draw(img)
    for y in range(SS):
        t = y / (SS - 1)
        colour = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
        draw.line([(0, y), (SS, y)], fill=colour)
    return img


def main() -> None:
    img = gradient()
    draw = ImageDraw.Draw(img)

    # The bubble body. Everything cat-shaped is drawn BEHIND it, so the ears
    # and the tail fuse into one outline instead of showing stroke seams.
    bw, bh = int(SS * 0.60), int(SS * 0.47)
    cx, cy = SS // 2, int(SS * 0.505)
    box = [cx - bw // 2, cy - bh // 2, cx + bw // 2, cy + bh // 2]
    radius = int(bh * 0.36)

    # The tail: an arc whose ends hide under the bubble, so it reads as
    # growing out of the lower-right corner.
    tail_w = int(SS * 0.052)
    draw.arc(
        [box[2] - int(SS * 0.16), box[3] - int(SS * 0.17),
         box[2] + int(SS * 0.15), box[3] + int(SS * 0.14)],
        210, 355, fill=INK, width=tail_w,
    )

    # The ears: plain triangles standing on the top edge, their bases tucked
    # under the corner radius so no notch shows.
    ear_w, ear_h = int(bw * 0.24), int(bh * 0.30)
    for side in (-1, 1):
        ex = cx + side * int(bw * 0.27)
        base = box[1] + radius // 3
        draw.polygon(
            [(ex - ear_w // 2, base), (ex, base - ear_h), (ex + ear_w // 2, base)],
            fill=INK,
        )

    draw.rounded_rectangle(box, radius=radius, fill=INK)

    # The typing indicator: the message itself. Side dots ink, the middle one
    # the accent -- the only teal on the tile, where the dot was before.
    r_small, r_big = int(SS * 0.030), int(SS * 0.042)
    gap = int(SS * 0.110)
    for dx, r, colour in ((-gap, r_small, DARK), (0, r_big, ACCENT), (gap, r_small, DARK)):
        draw.ellipse([cx + dx - r, cy - r, cx + dx + r, cy + r], fill=colour)

    OUT.mkdir(parents=True, exist_ok=True)
    icon = img.resize((SIZE, SIZE), Image.LANCZOS)
    icon.save(OUT / "icon-1024.png", optimize=True)
    print(f"wrote {OUT / 'icon-1024.png'}")


OUT = Path(__file__).resolve().parent.parent / "App" / "Assets.xcassets" / "AppIcon.appiconset"


if __name__ == "__main__":
    main()

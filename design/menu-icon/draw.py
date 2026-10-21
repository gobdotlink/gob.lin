#!/usr/bin/env python3
"""The menu-bar goblin. Edit the map, then run: python3 design/menu-icon/draw.py

One character is one pixel; dots are transparent. Writes four PNGs into
Sources/GoblinApp/Assets: the 22 px map, the same map doubled for Retina, and both
again for dark menu bars: no outer edge, and each green one step lighter. Requires Pillow.
"""
from pathlib import Path

from PIL import Image

ASSETS = Path(__file__).resolve().parents[2] / "Sources/GoblinApp/Assets"

# Sampled from goblin-shut.png.
PALETTE = {
    "K": (8, 17, 15, 255),     # ink
    "D": (21, 60, 35, 255),    # deepest green
    "S": (40, 91, 41, 255),    # shadow
    "G": (78, 146, 47, 255),   # leaf green
    "L": (148, 217, 68, 255),  # light green
    "O": (232, 108, 8, 255),   # orange
    "A": (255, 170, 19, 255),  # amber
    "T": (255, 247, 202, 255), # teeth
}

PIXELS = """
......................
...K..............K...
...LK.....KK.....KL...
...LGK...KGGK...KGL...
...KLGK.KGGGGK.KLGK...
...KLGSKGGGGGGKSGLK...
...KGSGGGGGGGGGGSGK...
....KSGGSGGGGSGGSK....
....KSGLLSGGSLLGSK....
....KSKGLLSSLLGKSK....
.....KOAKLGGLKAOK.....
.....KOOAKGGKAOOK.....
.....KSGSKGGKSGSK.....
......KGSKGGKSGK......
......KGTKKKKTGK......
.......KTTTTTTK.......
.......KSTTTTSK.......
........KGGGGK........
.........KGGK.........
.........KGGK.........
..........KK..........
......................
"""


# Dark menu bars: the bar itself is the outline, and shadows lift so they don't sink into it.
LIFT = {"D": PALETTE["S"], "S": PALETTE["G"], "G": PALETTE["L"]}


def draw(rows: list[str], dark: bool) -> Image.Image:
    def solid(x: int, y: int) -> bool:
        return 0 <= y < len(rows) and 0 <= x < len(rows[y]) and rows[y][x] != "."

    image = Image.new("RGBA", (22, 22), (0, 0, 0, 0))
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == ".":
                continue
            edge = not all(solid(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
            if not dark:
                image.putpixel((x, y), PALETTE[ch])
            elif not (ch == "K" and edge):
                image.putpixel((x, y), LIFT.get(ch, PALETTE[ch]))
    return image


if __name__ == "__main__":
    rows = PIXELS.strip("\n").split("\n")
    assert len(rows) == 22 and all(len(r) == 22 for r in rows), "The map must be 22 × 22"
    for suffix, dark in (("", False), ("-dark", True)):
        image = draw(rows, dark)
        image.save(ASSETS / f"goblin-menu{suffix}.png")
        image.resize((44, 44), Image.NEAREST).save(ASSETS / f"goblin-menu{suffix}@2x.png")

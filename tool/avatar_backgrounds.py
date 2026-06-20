"""
Replaces the baked-in checkerboard / flat-gray background that Nano
Banana Pro emits with a warm SA-palette solid background, matching
the polished look of Cape Malay Spice Queen.

Detects "background-ish" pixels (grayscale + brightness near the
corner sample), keeps only the connected component touching the
border, and recolours those pixels. Subject pixels (skin, chef coat,
hijab embroidery, etc.) are left alone.

Run from project root:
    python tool/avatar_backgrounds.py
"""
import hashlib
import os
import sys

import cv2
import numpy as np
from PIL import Image

AVATAR_DIR = "assets/avatars"

# Soft SA-warm palette (RGB tuples). Each avatar deterministically
# picks one based on its filename hash so the picker grid feels
# varied but each chef always looks the same.
PALETTE = [
    (245, 197, 107),  # Warm gold (matches Cape Malay Spice Queen)
    (245, 184, 154),  # Soft peach
    (180, 210, 178),  # Sage green
    (240, 224, 196),  # Cream
    (232, 162, 144),  # Warm coral
    (186, 212, 224),  # Soft sky blue
    (220, 196, 232),  # Pastel lilac
    (250, 215, 160),  # Honey
]

# Files we deliberately leave alone — already polished or special.
SKIP = {"SumaraiJack.png", "Melrose.png"}


def pick_color(name: str) -> tuple[int, int, int]:
    digest = hashlib.md5(name.encode()).hexdigest()
    return PALETTE[int(digest, 16) % len(PALETTE)]


def background_mask(rgb: np.ndarray) -> np.ndarray:
    """True where the image is the baked-in transparency placeholder
    (light checkerboard, mid-grey checkerboard, or a solid grey/white
    block) AND that region is connected to a border pixel."""
    h, w = rgb.shape[:2]

    # Sample the four corners to learn what "background" looks like.
    corner_samples = np.concatenate([
        rgb[:32, :32].reshape(-1, 3),
        rgb[:32, -32:].reshape(-1, 3),
        rgb[-32:, :32].reshape(-1, 3),
        rgb[-32:, -32:].reshape(-1, 3),
    ])
    bg_min = int(corner_samples.min())
    bg_max = int(corner_samples.max())

    # Background candidates: roughly grayscale AND brightness close to
    # the corner range. Some wiggle room either side so anti-aliased
    # edges of checkerboard squares survive the mask.
    r, g, b = rgb[..., 0].astype(int), rgb[..., 1].astype(int), rgb[..., 2].astype(int)
    is_gray = (np.abs(r - g) < 10) & (np.abs(g - b) < 10) & (np.abs(r - b) < 10)
    brightness = rgb.mean(axis=-1)
    in_range = (brightness >= bg_min - 12) & (brightness <= bg_max + 12)

    candidate = (is_gray & in_range).astype(np.uint8)

    # Close small gaps so the checkerboard grid is one continuous mask
    # instead of disconnected squares — otherwise connected-component
    # analysis would think each square is its own region.
    kernel = np.ones((5, 5), np.uint8)
    candidate = cv2.morphologyEx(candidate, cv2.MORPH_CLOSE, kernel, iterations=2)

    # Keep only connected components that touch the border.
    n, labels = cv2.connectedComponents(candidate)
    keep = set()
    for x in range(w):
        keep.add(labels[0, x]); keep.add(labels[h - 1, x])
    for y in range(h):
        keep.add(labels[y, 0]); keep.add(labels[y, w - 1])
    keep.discard(0)  # 0 = "not in mask"

    mask = np.isin(labels, list(keep))
    return mask


def process(path: str):
    img = Image.open(path)
    name = os.path.basename(path)

    # Work in RGB; alpha channel (if any) gets thrown away — we're
    # replacing transparency with a solid colour anyway.
    rgb = np.array(img.convert("RGB"))
    mask = background_mask(rgb)

    pct = 100 * mask.mean()
    if pct < 3:
        print(f"  skip {name} (no background detected — pct={pct:.1f}%)")
        return

    target = pick_color(name)
    out = rgb.copy()
    out[mask] = target

    # Mild edge-feathering so the subject doesn't have a hard cookie-
    # cutter halo against the new background.
    soft = mask.astype(np.uint8) * 255
    soft = cv2.GaussianBlur(soft, (5, 5), 0)
    alpha = (soft / 255.0)[..., None]
    blended = (out * alpha + rgb * (1 - alpha)).astype(np.uint8)

    Image.fromarray(blended).save(path, optimize=True)
    print(f"  {name:42s} bg={pct:5.1f}%  color=rgb{target}")


def main():
    files = sorted(f for f in os.listdir(AVATAR_DIR)
                   if f.lower().endswith(".png") and f not in SKIP)
    if not files:
        print("No avatar PNGs found.")
        sys.exit(1)
    print(f"Processing {len(files)} avatars …")
    for f in files:
        process(os.path.join(AVATAR_DIR, f))
    print("Done.")


if __name__ == "__main__":
    main()

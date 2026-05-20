#!/usr/bin/env python3
"""
Remove a baked-in teal dashed "guide" frame from Zoomies PNG icon assets.

Heuristic: teal/cyan-ish pixels on strong edges; inpaint by walking toward image center
until leaving the defect mask (works for thin strokes around central artwork).
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


def _frame_band_mask(h: int, w: int) -> np.ndarray:
    """
    Normalized bands around the baked-in dashed square (tuned on 1024×1024).
    Excludes most of the cat/pocket interior so we do not eat real artwork edges.
    """
    yy, xx = np.mgrid[0:h, 0:w]
    fx = xx.astype(np.float64) / max(w - 1, 1)
    fy = yy.astype(np.float64) / max(h - 1, 1)
    # Keep strips tight to the actual dashed square (~147–156 and ~868–877 at 1024px).
    left = (0.133 <= fx) & (fx <= 0.166) & (0.155 <= fy) & (fy <= 0.852)
    right = (0.842 <= fx) & (fx <= 0.878) & (0.155 <= fy) & (fy <= 0.852)
    top = (0.138 <= fx) & (fx <= 0.862) & (0.158 <= fy) & (fy <= 0.198)
    bottom = (0.138 <= fx) & (fx <= 0.862) & (0.808 <= fy) & (fy <= 0.868)
    return left | right | top | bottom


def _horizontal_frame_bands(h: int, w: int) -> np.ndarray:
    """Top and bottom strips only (dashed line along long edges, away from vertical whisker crossings)."""
    yy, xx = np.mgrid[0:h, 0:w]
    fx = xx.astype(np.float64) / max(w - 1, 1)
    fy = yy.astype(np.float64) / max(h - 1, 1)
    top = (0.138 <= fx) & (fx <= 0.862) & (0.158 <= fy) & (fy <= 0.198)
    bottom = (0.138 <= fx) & (fx <= 0.862) & (0.808 <= fy) & (fy <= 0.868)
    return top | bottom


def dashed_frame_mask(rgb: np.ndarray) -> np.ndarray:
    """Bool mask HxW — pixels that look like the dashed teal stroke."""
    h, w = rgb.shape[:2]
    a = rgb.astype(np.float32)
    gray = a.mean(axis=2)
    gx = np.abs(gray[:, 2:] - gray[:, :-2])
    gx = np.pad(gx, ((0, 0), (1, 1)), mode="edge")
    gy = np.abs(gray[2:, :] - gray[:-2, :])
    gy = np.pad(gy, ((1, 1), (0, 0)), mode="edge")
    mag = gx + gy
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    teal = (g > 85) & (b > 85) & (r < g - 25) & (r < b - 15)
    edges = mag > 70
    # Do not treat orange cat fur / whisker shading as cyan stroke.
    not_fur = ~((r > 125) & (r > g + 18) & (r > b + 8))
    return _frame_band_mask(h, w) & teal & edges & not_fur


def horizontal_dash_mask_loose(rgb: np.ndarray) -> np.ndarray:
    """Top/bottom dash remnants — looser color gate, horizontal strips only."""
    h, w = rgb.shape[:2]
    a = rgb.astype(np.float32)
    gray = a.mean(axis=2)
    gx = np.abs(gray[:, 2:] - gray[:, :-2])
    gx = np.pad(gx, ((0, 0), (1, 1)), mode="edge")
    gy = np.abs(gray[2:, :] - gray[:-2, :])
    gy = np.pad(gy, ((1, 1), (0, 0)), mode="edge")
    mag = gx + gy
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    teal = (g > 72) & (b > 72) & (r < g - 15) & (r < b - 10)
    edges = mag > 50
    not_fur = ~((r > 125) & (r > g + 18) & (r > b + 8))
    return _horizontal_frame_bands(h, w) & teal & edges & not_fur


def dilate_mask(mask: np.ndarray, size: int) -> np.ndarray:
    im = Image.fromarray(mask.astype(np.uint8) * 255)
    # MaxFilter expands True regions; size must be odd
    if size % 2 == 0:
        size += 1
    dil = np.array(im.filter(ImageFilter.MaxFilter(size))) > 127
    return dil


def inpaint_toward_center(rgb: np.ndarray, mask: np.ndarray) -> np.ndarray:
    h, w = rgb.shape[:2]
    cy, cx = (h - 1) / 2.0, (w - 1) / 2.0
    # Expanded obstacle: rays stop once they leave this region (includes dash + halo).
    obstacle = mask | dilate_mask(mask, 5)
    out = rgb.copy()
    # Only replace labeled dash pixels — never the dilated halo (avoids eating whiskers/fur).
    ys, xs = np.where(mask)
    for y, x in zip(ys, xs):
        dx, dy = cx - x, cy - y
        norm = (dx * dx + dy * dy) ** 0.5
        if norm < 1e-6:
            continue
        dx, dy = dx / norm, dy / norm
        filled = False
        for step in range(2, min(h, w)):
            ny = int(round(y + dy * step))
            nx = int(round(x + dx * step))
            if ny < 0 or ny >= h or nx < 0 or nx >= w:
                break
            if not obstacle[ny, nx]:
                out[y, x] = rgb[ny, nx]
                filled = True
                break
        if not filled:
            out[y, x] = rgb[y, x]
    return out


def process_png(path: Path) -> None:
    im = Image.open(path).convert("RGB")
    arr = np.array(im)
    for _ in range(5):
        mask = dashed_frame_mask(arr)
        if not mask.any():
            break
        nxt = inpaint_toward_center(arr, mask)
        if np.array_equal(nxt, arr):
            break
        arr = nxt
    # Long top/bottom edges: allow a looser gate (vertical strips skipped — fewer whisker crossings).
    for _ in range(4):
        mask = horizontal_dash_mask_loose(arr)
        if not mask.any():
            break
        nxt = inpaint_toward_center(arr, mask)
        if np.array_equal(nxt, arr):
            break
        arr = nxt
    Image.fromarray(arr).save(path, optimize=True)


def main() -> None:
    paths = [Path(p) for p in sys.argv[1:]]
    if not paths:
        print("Usage: fix_icon_dashed_frame.py <png> [png ...]", file=sys.stderr)
        sys.exit(1)
    for p in paths:
        if not p.is_file():
            print(f"Missing: {p}", file=sys.stderr)
            sys.exit(1)
        process_png(p)
        print(f"OK {p}")


if __name__ == "__main__":
    main()

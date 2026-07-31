"""Which way do MCNK height samples run? Decided by continuity, not by belief.

/raijin navgrid verify came back at 20% within 3yd, median error 8yd, worst 118 -
scatter with a heavy tail, not a constant offset. That pattern, plus matching at
all rather than never, is the signature of a TRANSPOSE: samples near the diagonal
land right and everything else is reflected across it.

There is an offline oracle for this that needs no game running. Adjacent MCNK
chunks SHARE AN EDGE, and the terrain is continuous across it - the last column of
one chunk is physically the same ground as the first column of its neighbour. Under
the correct (row,col) -> (x,y) mapping those samples agree to within centimetres.
Under a transposed one they are comparing an edge against a perpendicular edge and
the mismatch is large. So: score each candidate by edge discontinuity and take the
one the terrain itself endorses.
"""
from __future__ import annotations

import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from adt_extract import Client, UNIT, parse_adt      # noqa: E402

CANDIDATES = {
    # name: (x_step_uses, y_step_uses)   -- which loop index drives which axis
    "row->x, col->y  (current)": lambda r, c: (r, c),
    "row->y, col->x  (transposed)": lambda r, c: (c, r),
}


def build(mcnks, pick):
    """world (x,y) -> z for every outer sample, under one candidate mapping."""
    pts = {}
    for m in mcnks:
        bx, by, bz = m["x"], m["y"], m["z"]
        h = m["h"]
        for row in range(9):
            for col in range(9):
                a, b = pick(row, col)
                x = bx - a * UNIT
                y = by - b * UNIT
                pts[(round(x, 2), round(y, 2))] = bz + h[row * 17 + col]
    return pts


def discontinuity(pts):
    """Median |dz| between horizontally adjacent samples.

    Real terrain is smooth at 4.17yd spacing, so a correct mapping yields a small
    median. A transposed one stitches perpendicular edges together and the seams
    show up as a much larger typical step.
    """
    keyed = {}
    for (x, y), z in pts.items():
        keyed[(round(x / UNIT), round(y / UNIT))] = z
    steps = []
    for (kx, ky), z in keyed.items():
        for dk in ((1, 0), (0, 1)):
            nz = keyed.get((kx + dk[0], ky + dk[1]))
            if nz is not None:
                steps.append(abs(nz - z))
    if not steps:
        return None, 0
    return statistics.median(steps), len(steps)


def main(argv) -> int:
    mapname = argv[1] if len(argv) > 1 else "Azeroth"
    print("indexing archives...")
    c = Client()
    tiles = c.tiles(mapname)
    # Tiles with real relief - a flat ocean tile cannot distinguish anything.
    picks = [t for t in tiles if t[0] in (28, 31, 32) and t[1] in (28, 31, 48)][:4]
    if not picks:
        picks = tiles[len(tiles) // 2: len(tiles) // 2 + 3]

    totals = {k: [] for k in CANDIDATES}
    for tx, ty, real in picks:
        data = c.read(real)
        if not data:
            continue
        mcnks = parse_adt(data)
        if len(mcnks) < 64:
            continue
        row = []
        for name, pick in CANDIDATES.items():
            med, n = discontinuity(build(mcnks, pick))
            if med is None:
                continue
            totals[name].append(med)
            row.append(f"{name.split()[0]}={med:6.3f}")
        print(f"  tile {tx:>2},{ty:<2}  " + "   ".join(row))

    print("\nmedian step between adjacent samples (smaller = the terrain is continuous):")
    best, bestv = None, None
    for name, vals in totals.items():
        if not vals:
            continue
        m = statistics.median(vals)
        print(f"   {name:<32} {m:.4f} yd")
        if bestv is None or m < bestv:
            best, bestv = name, m
    print(f"\nWINNER: {best}")
    other = [v for k, v in totals.items() if k != best and v]
    if other and bestv:
        ratio = statistics.median(other[0]) / max(bestv, 1e-9)
        print(f"the rejected mapping is {ratio:.1f}x more discontinuous - "
              f"{'decisive' if ratio > 1.5 else 'NOT decisive, look elsewhere'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

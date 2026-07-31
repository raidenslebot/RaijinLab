"""Which way do liquid sub-rectangles run? Decided by physics, not by belief.

MH2O stores a liquid layer as a sub-rectangle inside an MCNK: an (xo, yo) offset
and a (w, h) extent over the chunk's 8x8 cells. Which of those axes maps to which
world direction is a convention, and the obvious test cannot see it: a fully
flooded ocean tile is transpose-symmetric, so it scores identically either way.
That is exactly the check that passed at 100% and proved nothing about this.

But water is LEVEL, and it cannot sit below the ground it covers. So a wrong
mapping does something physically impossible - it floods cells whose terrain is
ABOVE the liquid surface, i.e. it puts a lake on a hillside. Count those
violations for each candidate and the terrain answers.

Only PARTIAL layers can discriminate: a layer covering the whole chunk is
symmetric under transposition, so those are excluded and reported separately.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from adt_extract import Client, parse_adt, parse_mh2o     # noqa: E402


def subcell_terrain(h, a, b):
    """Mean terrain height of the 8x8 sub-cell (a, b), from the 9x9 outer grid.

    Sub-cell (a, b) is bounded by outer samples (a..a+1, b..b+1); averaging the
    four corners is the honest estimate of the ground under it.
    """
    tot = 0.0
    for r in (a, a + 1):
        for c in (b, b + 1):
            tot += h[r * 17 + c]
    return tot / 4.0


def main(argv) -> int:
    mapname = argv[1] if len(argv) > 1 else "Azeroth"
    print("indexing archives...")
    c = Client()
    tiles = c.tiles(mapname)

    # Coastal / lake tiles: partial water is what discriminates.
    picks = [t for t in tiles if 27 <= t[0] <= 34 and 27 <= t[1] <= 50][:40]
    BIG = 4.0            # yd: unmistakably a flooded hillside, not a shoreline
    viol = {"as-is (xo->-X, yo->-Y)": 0, "swapped (xo->-Y, yo->-X)": 0}
    depth = {"as-is (xo->-X, yo->-Y)": 0.0, "swapped (xo->-Y, yo->-X)": 0.0}
    total = 0
    partial_layers = full_layers = 0

    for tx, ty, real in picks:
        data = c.read(real)
        if not data:
            continue
        layers = parse_mh2o(data)
        if not layers:
            continue
        mcnks = parse_adt(data)
        by_idx = {}
        for m in mcnks:
            by_idx[m["iy"] * 16 + m["ix"]] = m
        for idx, insts in enumerate(layers):
            m = by_idx.get(idx)
            if not m or not insts:
                continue
            for inst in insts:
                w, h_ = inst["w"] or 8, inst["h"] or 8
                if inst["xo"] == 0 and inst["yo"] == 0 and w >= 8 and h_ >= 8:
                    full_layers += 1
                    continue          # symmetric under transpose: proves nothing
                partial_layers += 1
                lvl = inst["max"]
                base_z = m["z"]
                for a in range(inst["xo"], min(8, inst["xo"] + w)):
                    for b in range(inst["yo"], min(8, inst["yo"] + h_)):
                        total += 1
                        # as-is: the sub-rect's first axis indexes MCVT rows
                        z1 = base_z + subcell_terrain(m["h"], a, b)
                        # swapped: it indexes columns instead
                        z2 = base_z + subcell_terrain(m["h"], b, a)
                        # THRESHOLD MATTERS. At >0.5yd both orientations scored
                        # ~50%, which is not a tie between two conventions - it is
                        # NOISE AROUND ZERO DEPTH. Partial layers are shoreline
                        # chunks by definition, where the water surface meets the
                        # ground, so "terrain above water" there is a coin flip
                        # whichever way the axes run. The oracle had no signal.
                        #
                        # A wrong mapping does something much louder: it floods a
                        # hillside. Only count terrain standing WELL proud of the
                        # surface, which a shoreline cannot produce and a
                        # transposed lake edge produces constantly.
                        if z1 > lvl + BIG:
                            viol["as-is (xo->-X, yo->-Y)"] += 1
                        if z2 > lvl + BIG:
                            viol["swapped (xo->-Y, yo->-X)"] += 1
                        depth["as-is (xo->-X, yo->-Y)"] += (lvl - z1)
                        depth["swapped (xo->-Y, yo->-X)"] += (lvl - z2)

    print(f"partial layers: {partial_layers}   full-chunk layers skipped: {full_layers}")
    if total == 0:
        print("no partial liquid layers found - cannot discriminate here")
        return 1
    print(f"sub-cells tested: {total}\n")
    print(f"terrain standing >{BIG:.0f}yd ABOVE the water surface (a flooded hillside):")
    ranked = sorted(viol.items(), key=lambda kv: kv[1])
    for name, v in ranked:
        print(f"   {name:<28} {v:6d}  ({100.0 * v / total:5.1f}%)")
    print(chr(10) + "mean depth under the surface (higher = water sits on lower ground):")
    for name, d in sorted(depth.items(), key=lambda kv: -kv[1]):
        print(f"   {name:<28} {d / total:+7.2f} yd")
    best, bv = ranked[0]
    worst, wv = ranked[-1]
    print(f"\nWINNER: {best}")
    if wv == 0:
        print("both are clean - this data cannot tell them apart")
    else:
        ratio = wv / max(bv, 1)
        print(f"the rejected mapping is {ratio:.1f}x more impossible - "
              f"{'decisive' if ratio > 1.5 else 'NOT decisive, look elsewhere'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

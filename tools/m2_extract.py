"""Doodad collision - the trees and rocks a character actually snags on.

Terrain, buildings and water are in the grid. What is left is the clutter: 110296
M2 models placed across the maps, and they are the single most common thing to
walk into. A tree is not in the heightmap and not a WMO, so right now the grid
says "open ground" for every one of them.

THE BOUNDING BOX IS THE WRONG TOOL HERE, for the same reason it was wrong for
buildings but worse: an M2's bounding box includes the CANOPY. Blocking it would
make a forest solid when you can walk freely under the branches. M2 files carry a
separate COLLISION MESH for exactly this - a handful of triangles around the trunk
- and models with no collision mesh at all (grass, flowers, small clutter) are
genuinely non-blocking, so an empty result is the correct answer rather than a
parse failure.

VERIFIED IN MODEL SPACE FIRST, like the WMO parser: every M2 declares its own
collision_box, and the collision vertices must lie inside it. A parser reading at
the wrong offset yields finite, plausible coordinates scattered outside that box,
which is otherwise invisible.

    python tools/m2_extract.py --sample 12
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from adt_extract import Client                      # noqa: E402

# WotLK M2 header (magic 'MD20'). Offsets that matter here:
#   0xBC  collision_box            (CAaBox: min vec3, max vec3)
#   0xD4  collision_sphere_radius
#   0xD8  collisionIndices         (M2Array: count, offset)
#   0xE0  collisionPositions       (M2Array)
#   0xE8  collisionFaceNormals     (M2Array)
OFS_COLLISION_BOX = 0xBC
OFS_COLL_INDICES = 0xD8
OFS_COLL_POSITIONS = 0xE0


def parse_m2(data: bytes) -> dict | None:
    """Collision mesh in model space, or None when the file is not a WotLK M2."""
    if len(data) < 0xF0 or data[:4] != b"MD20":
        return None
    bmin = struct.unpack_from("<3f", data, OFS_COLLISION_BOX)
    bmax = struct.unpack_from("<3f", data, OFS_COLLISION_BOX + 12)
    n_idx, ofs_idx = struct.unpack_from("<2I", data, OFS_COLL_INDICES)
    n_pos, ofs_pos = struct.unpack_from("<2I", data, OFS_COLL_POSITIONS)

    verts, tris = [], []
    if n_pos and ofs_pos and ofs_pos + n_pos * 12 <= len(data):
        verts = [struct.unpack_from("<3f", data, ofs_pos + i * 12) for i in range(n_pos)]
    if n_idx and ofs_idx and ofs_idx + n_idx * 2 <= len(data):
        idx = struct.unpack_from("<%dH" % n_idx, data, ofs_idx)
        for i in range(0, len(idx) - 2, 3):
            a, b, c = idx[i], idx[i + 1], idx[i + 2]
            if a < len(verts) and b < len(verts) and c < len(verts):
                tris.append((a, b, c))
    return {"box": (bmin, bmax), "verts": verts, "tris": tris,
            "n_idx": n_idx, "n_pos": n_pos}


def check(c: Client, path: str) -> dict | None:
    """Parse one model and test its vertices against its OWN declared box."""
    raw = c.read(path)
    if not raw:
        # Placements reference .mdx even when the archive stores .m2.
        alt = path[:-4] + ".m2" if path.lower().endswith((".mdx", ".mdl")) else None
        if alt:
            raw = c.read(alt)
        if not raw:
            return None
    m = parse_m2(raw)
    if not m:
        return None
    bmin, bmax = m["box"]
    lo = [min(bmin[k], bmax[k]) for k in range(3)]
    hi = [max(bmin[k], bmax[k]) for k in range(3)]
    outside = 0
    pad = 0.5
    for v in m["verts"]:
        for k in range(3):
            if v[k] < lo[k] - pad or v[k] > hi[k] + pad:
                outside += 1
                break
    return {"path": path, "verts": len(m["verts"]), "tris": len(m["tris"]),
            "outside": outside, "box": (lo, hi)}


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("model", nargs="?")
    ap.add_argument("--sample", type=int, default=12)
    args = ap.parse_args(argv[1:])

    print("indexing archives...")
    c = Client()

    if args.model:
        r = check(c, args.model)
        print(r if r else "not found / not an MD20")
        return 0 if r else 1

    models = [real for key, (_a, real) in c.index.items() if key.endswith(".m2")]
    models.sort()
    step = max(1, len(models) // args.sample)
    picked = models[::step][:args.sample]
    print(f"{len(models)} M2 models; verifying {len(picked)}\n")

    with_coll = no_coll = bad = 0
    for mp in picked:
        r = check(c, mp)
        if not r:
            print(f"  {mp[-56:]:<56} unreadable")
            continue
        if r["verts"] == 0:
            no_coll += 1
            tag = "no collision mesh (correctly non-blocking)"
        elif r["outside"]:
            bad += 1
            tag = f"|BAD| {r['outside']} verts OUTSIDE the declared box"
        else:
            with_coll += 1
            tag = "inside its declared box"
        print(f"  {mp[-56:]:<56} v={r['verts']:<5} t={r['tris']:<5} {tag}")

    print(f"\nwith collision: {with_coll}   without: {no_coll}   MISFITS: {bad}")
    if bad:
        print("a misfit means the parser is reading at the wrong offset - "
              "the coordinates are plausible but wrong, which is invisible downstream")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

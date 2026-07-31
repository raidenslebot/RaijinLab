"""Real collision geometry for buildings, out of the client's WMO files.

The navgrid currently marks a building's AXIS-ALIGNED BOUNDING BOX as STRUCTURE -
a hint, because an AABB cannot tell a wall from the floor it encloses. Marking it
solid measured 82% of a tile blocked from five buildings, which would make every
town unreachable. The real answer is per-triangle collision, and it is in the WMO
group files.

VERIFICATION ORDER IS THE POINT. Placement transforms (MODF rotation + the ADT
coordinate permutation) are where this kind of extraction usually goes silently
wrong, and a mis-transformed building looks entirely plausible - just in the wrong
place. So this stage verifies the parser in MODEL SPACE, where there is an
independent check available: every group file carries its own bounding box, and
the root carries the whole-object box. If the triangles we extract do not fill the
box the file itself declares, the parse is wrong and no amount of correct
placement will save it.

    python tools/wmo_extract.py --sample 8      # verify the parser
    python tools/wmo_extract.py <path.wmo>      # one object
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from adt_extract import Client, chunks          # noqa: E402

# MOPY per-triangle flags (2 bytes per triangle: flags, material id).
F_NOCAMCOLLIDE = 0x02
F_DETAIL = 0x04
F_COLLISION = 0x08
F_RENDER = 0x20
MAT_COLLISION_ONLY = 0xFF        # invisible collision-only geometry


def collidable(flags: int, mat: int) -> bool:
    """Which triangles actually stop a character.

    Collision-only geometry (material 0xFF) and anything explicitly flagged
    COLLISION are solid. DETAIL triangles are decoration - grass, clutter, trim -
    and are deliberately non-collidable; treating them as walls is how an
    extractor ends up sealing doorways shut.
    """
    if mat == MAT_COLLISION_ONLY:
        return True
    if flags & F_COLLISION:
        return True
    if flags & F_DETAIL:
        return False
    return bool(flags & F_RENDER) or flags == 0


def parse_root(data: bytes) -> dict | None:
    """MOHD header plus the per-group bounding boxes from MOGI."""
    out = {"groups": []}
    for magic, body, size in chunks(data):
        if magic == "MOHD":
            v = struct.unpack_from("<7I2I6fI", data, body)
            out["n_groups"] = v[1]
            out["bbox"] = (v[9:12], v[12:15])
        elif magic == "MOGI":
            for i in range(size // 32):
                o = body + i * 32
                flags = struct.unpack_from("<I", data, o)[0]
                lo = struct.unpack_from("<3f", data, o + 4)
                hi = struct.unpack_from("<3f", data, o + 16)
                out["groups"].append({"flags": flags, "lo": lo, "hi": hi})
    return out if "n_groups" in out else None


def parse_group(data: bytes) -> dict | None:
    """One group file: collidable triangles in MODEL space.

    MOGP is a chunk whose body starts with a 68-byte header and is then followed
    by the real sub-chunks (MOPY / MOVI / MOVT / ...), so the sub-chunk walk has
    to start past that header rather than at the body.
    """
    for magic, body, size in chunks(data):
        if magic != "MOGP":
            continue
        flags = struct.unpack_from("<I", data, body + 8)[0]
        lo = struct.unpack_from("<3f", data, body + 12)
        hi = struct.unpack_from("<3f", data, body + 24)

        mopy = movi = movt = None
        for sm, sb, ss in chunks(data, body + 68, body + size):
            if sm == "MOPY":
                mopy = (sb, ss)
            elif sm == "MOVI":
                movi = (sb, ss)
            elif sm == "MOVT":
                movt = (sb, ss)
        if not (mopy and movi and movt):
            return {"flags": flags, "lo": lo, "hi": hi, "tris": [], "verts": [],
                    "n_tri": 0, "n_solid": 0}

        n_tri = mopy[1] // 2
        n_vert = movt[1] // 12
        verts = [struct.unpack_from("<3f", data, movt[0] + i * 12) for i in range(n_vert)]
        tris = []
        for i in range(n_tri):
            tf, tm = struct.unpack_from("<BB", data, mopy[0] + i * 2)
            if not collidable(tf, tm):
                continue
            a, b, c = struct.unpack_from("<3H", data, movi[0] + i * 6)
            if a < n_vert and b < n_vert and c < n_vert:
                tris.append((a, b, c))
        return {"flags": flags, "lo": lo, "hi": hi, "verts": verts, "tris": tris,
                "n_tri": n_tri, "n_solid": len(tris)}
    return None


def group_paths(root: str, n: int) -> list[str]:
    stem = root[:-4] if root.lower().endswith(".wmo") else root
    return [f"{stem}_{i:03d}.wmo" for i in range(n)]


def check(c: Client, root_path: str, verbose: bool = True) -> dict | None:
    raw = c.read(root_path)
    if not raw:
        return None
    root = parse_root(raw)
    if not root:
        return None

    tot_tri = tot_solid = 0
    fits = misfits = 0
    vlo = [1e9] * 3
    vhi = [-1e9] * 3
    for gi, gp in enumerate(group_paths(root_path, root["n_groups"])):
        gdata = c.read(gp)
        if not gdata:
            continue
        g = parse_group(gdata)
        if not g:
            continue
        tot_tri += g["n_tri"]
        tot_solid += g["n_solid"]
        # INDEPENDENT CHECK: the vertices we parsed must lie inside the bounding
        # box the group file declares for itself. A parser reading at the wrong
        # offset produces coordinates that are finite and plausible but scattered
        # far outside that box - which is otherwise invisible.
        if g["verts"]:
            for v in g["verts"]:
                for k in range(3):
                    vlo[k] = min(vlo[k], v[k])
                    vhi[k] = max(vhi[k], v[k])
            pad = 1.0
            inside = all(g["lo"][k] - pad <= vlo[k] and vhi[k] <= g["hi"][k] + pad
                         for k in range(3)) if gi == 0 else True
            ok = all(min(g["lo"][k], g["hi"][k]) - pad <= min(v[k] for v in g["verts"])
                     and max(v[k] for v in g["verts"]) <= max(g["lo"][k], g["hi"][k]) + pad
                     for k in range(3))
            if ok:
                fits += 1
            else:
                misfits += 1
    return {"path": root_path, "groups": root["n_groups"], "tri": tot_tri,
            "solid": tot_solid, "fits": fits, "misfits": misfits,
            "bbox": root.get("bbox")}


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("wmo", nargs="?")
    ap.add_argument("--sample", type=int, default=0)
    args = ap.parse_args(argv[1:])

    print("indexing archives...")
    c = Client()

    if args.wmo:
        r = check(c, args.wmo)
        print(r if r else "not found / unparseable")
        return 0 if r else 1

    roots = [real for key, (_a, real) in c.index.items()
             if key.endswith(".wmo") and "_0" not in key.rsplit("\\", 1)[-1]]
    roots.sort()
    n = args.sample or 8
    step = max(1, len(roots) // n)
    picked = roots[::step][:n]
    print(f"{len(roots)} root WMOs; verifying {len(picked)}\n")

    tot_fit = tot_mis = 0
    for rp in picked:
        r = check(c, rp)
        if not r:
            print(f"  {rp[-58:]:<58} unreadable")
            continue
        tot_fit += r["fits"]
        tot_mis += r["misfits"]
        pct = (100.0 * r["solid"] / r["tri"]) if r["tri"] else 0.0
        print(f"  {rp[-58:]:<58} grp={r['groups']:<3} tri={r['tri']:<7} "
              f"solid={r['solid']:<7} ({pct:4.0f}%)  bbox {'OK' if r['misfits'] == 0 else 'MISFIT'}")
    print(f"\ngroups whose vertices fit their declared bbox: {tot_fit}   misfits: {tot_mis}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

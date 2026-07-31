"""Resolve the WMO placement transform by MEASUREMENT, not by guessing.

Placing a building requires a convention: which axis the MODF rotation turns
about, what offset it carries, and how placement space maps to world space. Every
source states one, they disagree, and a wrong choice is invisible - the building
is entirely plausible, just in the wrong place or facing the wrong way.

But an independent oracle exists. MODF carries the placed object's own AXIS-ALIGNED
BOUNDING BOX. So the transform is not a matter of opinion: apply a candidate to
the model-space vertices, and the result must land inside the box the file itself
declares. Score every candidate, and let the archives answer.

    python tools/wmo_place.py Azeroth --tile 32 48
"""
from __future__ import annotations

import argparse
import math
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from adt_extract import Client, chunks         # noqa: E402
from wmo_extract import parse_root, parse_group, group_paths   # noqa: E402


def modf_entries(data: bytes) -> list[dict]:
    """MODF placements, keeping the RAW values - conversion is what we are testing."""
    out = []
    for magic, body, size in chunks(data):
        if magic != "MODF":
            continue
        for i in range(size // 64):
            o = body + i * 64
            v = struct.unpack_from("<II3f3f3f3fHHHH", data, o)
            out.append({"nameId": v[0], "pos": v[2:5], "rot": v[5:8],
                        "lo": v[8:11], "hi": v[11:14]})
    return out


def wmo_names(data: bytes) -> list[str]:
    """MWMO is a blob of NUL-terminated paths; MWID indexes into it."""
    blob = None
    offs = []
    for magic, body, size in chunks(data):
        if magic == "MWMO":
            blob = data[body:body + size]
        elif magic == "MWID":
            offs = list(struct.unpack_from("<%dI" % (size // 4), data, body))
    if blob is None:
        return []
    out = []
    for o in offs:
        end = blob.find(b"\x00", o)
        out.append(blob[o:end if end >= 0 else len(blob)].decode("latin-1"))
    return out


def model_points(c: Client, path: str, cap: int = 4000):
    """Collidable vertices in model space, sub-sampled - the bbox only needs the
    extremes, and a cathedral has tens of thousands of triangles."""
    raw = c.read(path)
    if not raw:
        return None
    root = parse_root(raw)
    if not root:
        return None
    pts = []
    for gp in group_paths(path, root["n_groups"]):
        g = c.read(gp)
        if not g:
            continue
        parsed = parse_group(g)
        if not parsed or not parsed["tris"]:
            continue
        used = set()
        for tri in parsed["tris"]:
            used.update(tri)
        vs = parsed["verts"]
        for i in used:
            if i < len(vs):
                pts.append(vs[i])
        if len(pts) > cap:
            break
    return pts or None


def rot_y(v, deg):
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    return (v[0] * ca + v[2] * sa, v[1], -v[0] * sa + v[2] * ca)


def rot_z(v, deg):
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    return (v[0] * ca - v[1] * sa, v[0] * sa + v[1] * ca, v[2])


# Candidate conventions. Each maps a model-space vertex into the space the MODF
# bounds are expressed in; the winner is decided by fit, not by preference.
# The first round measured a best fit of 0.51 - barely above identity (0.43).
# That is the measurement rejecting the whole HYPOTHESIS SPACE, not just picking
# badly within it: every candidate assumed model space and placement space share
# axes. WMO model vertices are Z-up in their own frame while placement is stored
# Y-up, so an axis permutation has to come FIRST and the rotation applies after.
def perm_xzy(v):  return (v[0], v[2], -v[1])
def perm_xzy2(v): return (v[0], -v[2], v[1])
def perm_id(v):   return v

CANDIDATES = {}
for pname, pfn in (("id", perm_id), ("xz-y", perm_xzy), ("x-zy", perm_xzy2)):
    for rname, rdeg in (("R0", None), ("Ry", 0.0), ("Ry-270", -270.0),
                        ("Ry+90", 90.0), ("Rz", None)):
        def make(pf=pfn, rn=rname, off=rdeg):
            if rn == "R0":
                return lambda v, e: pf(v)
            if rn == "Rz":
                return lambda v, e: rot_z(pf(v), e["rot"][1])
            return lambda v, e: rot_y(pf(v), e["rot"][1] + off)
        CANDIDATES[pname + "/" + rname] = make()


def score(pts, e, fn) -> float:
    """Fraction of the model's extent that lands inside the declared box.

    1.0 means the transformed model fills its own bounding box exactly - which is
    what a correct transform must do, since the box was computed FROM the placed
    model by the tools that built the file.
    """
    lo = [min(e["lo"][k], e["hi"][k]) for k in range(3)]
    hi = [max(e["lo"][k], e["hi"][k]) for k in range(3)]
    tlo = [1e18] * 3
    thi = [-1e18] * 3
    for v in pts:
        w = fn(v, e)
        for k in range(3):
            p = w[k] + e["pos"][k]
            tlo[k] = min(tlo[k], p)
            thi[k] = max(thi[k], p)
    # overlap volume / union volume, per axis then averaged
    tot = 0.0
    for k in range(3):
        inter = max(0.0, min(hi[k], thi[k]) - max(lo[k], tlo[k]))
        union = max(hi[k], thi[k]) - min(lo[k], tlo[k])
        tot += (inter / union) if union > 1e-6 else 1.0
    return tot / 3.0


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("map")
    ap.add_argument("--tile", nargs=2, type=int, required=True)
    ap.add_argument("--max", type=int, default=10)
    args = ap.parse_args(argv[1:])

    print("indexing archives...")
    c = Client()
    real = None
    for tx, ty, name in c.tiles(args.map):
        if (tx, ty) == (args.tile[0], args.tile[1]):
            real = name
            break
    if not real:
        print("tile not present")
        return 1
    data = c.read(real)
    names = wmo_names(data)
    ents = modf_entries(data)
    print(f"{real}: {len(ents)} placements, {len(names)} wmo names\n")

    totals = {k: 0.0 for k in CANDIDATES}
    counted = 0
    for e in ents[:args.max]:
        if e["nameId"] >= len(names):
            continue
        path = names[e["nameId"]]
        pts = model_points(c, path)
        if not pts:
            continue
        counted += 1
        row = []
        for k, fn in CANDIDATES.items():
            sc = score(pts, e, fn)
            totals[k] += sc
            row.append(f"{k}={sc:.2f}")
        best_here = max(CANDIDATES, key=lambda k: score(pts, e, CANDIDATES[k]))
        print(f"  {path.rsplit(chr(92), 1)[-1][:34]:<34} rot={e['rot'][1]:7.1f}  "
              f"best={best_here} ({score(pts, e, CANDIDATES[best_here]):.2f})")

    if not counted:
        print("no placements with readable geometry")
        return 1
    print(f"\nmean fit over {counted} placements:")
    for k, v in sorted(totals.items(), key=lambda kv: -kv[1]):
        print(f"   {k:<16} {v / counted:.3f}")
    best = max(totals, key=lambda k: totals[k])
    print(f"\nWINNER: {best}   (1.000 = the transformed model exactly fills its "
          f"declared bounding box)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

"""Resolve the M2 doodad placement transform. Oracle: things rest on the ground.

MODF gave buildings an independent check - each placement carries its own bounding
box, so a candidate transform could be scored against it. MDDF carries NO bounding
box, so that oracle does not exist for doodads and the same measurement cannot be
reused.

But a different one does. A tree, rock or barrel SITS ON THE TERRAIN. Under the
correct transform the base of its collision mesh lands at roughly the ground height
beneath it; under a wrong one it floats or sinks by metres, and the error is
scattered rather than constant. So: place each doodad by every candidate, measure
base-minus-terrain, and take the transform the world rests on.

Deliberately reported as MEDIAN and spread, not mean - a handful of genuinely
floating props (hanging signs, birds) would drag a mean and hide the answer.
"""
from __future__ import annotations

import argparse
import statistics
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from adt_extract import Client, ORIGIN, UNIT, chunks, parse_adt   # noqa: E402
from m2_extract import parse_m2                                   # noqa: E402
from wmo_place import rot_y                                       # noqa: E402


def mddf_entries(data: bytes) -> list[dict]:
    """MDDF: 36 bytes - nameId, uniqueId, pos[3], rot[3] degrees, scale, flags.
    scale is fixed point with 1024 == 1.0."""
    out = []
    for magic, body, size in chunks(data):
        if magic != "MDDF":
            continue
        for i in range(size // 36):
            o = body + i * 36
            v = struct.unpack_from("<II3f3f2H", data, o)
            out.append({"nameId": v[0], "pos": v[2:5], "rot": v[5:8],
                        "scale": v[8] / 1024.0})
    return out


def m2_names(data: bytes) -> list[str]:
    blob, offs = None, []
    for magic, body, size in chunks(data):
        if magic == "MMDX":
            blob = data[body:body + size]
        elif magic == "MMID":
            offs = list(struct.unpack_from("<%dI" % (size // 4), data, body))
    if blob is None:
        return []
    out = []
    for o in offs:
        end = blob.find(b"\x00", o)
        out.append(blob[o:end if end >= 0 else len(blob)].decode("latin-1"))
    return out


def terrain_lookup(mcnks):
    """(x, y) -> z for every outer sample, keyed to the sample lattice."""
    grid = {}
    for m in mcnks:
        bx, by, bz = m["x"], m["y"], m["z"]
        h = m["h"]
        for row in range(9):
            for col in range(9):
                x = bx - row * UNIT
                y = by - col * UNIT
                grid[(round(x / UNIT), round(y / UNIT))] = bz + h[row * 17 + col]
    return grid


def ground_at(grid, x, y):
    """Nearest terrain sample, searching a small neighbourhood.

    Demanding an EXACT lattice hit measured only 10 doodads out of hundreds: a
    prop almost never stands precisely on a 4.17yd sample point, so nearly every
    lookup returned nothing and the comparison was starved of data. An oracle that
    silently discards 97% of its evidence produces a confident-looking dead heat.
    """
    kx, ky = round(x / UNIT), round(y / UNIT)
    best = None
    for dx in (0, -1, 1):
        for dy in (0, -1, 1):
            z = grid.get((kx + dx, ky + dy))
            if z is not None and (best is None or abs(z) < 1e9):
                if best is None:
                    best = z
    return best


# Candidates. The WMO transform is the leading hypothesis - both live in ADT
# placement space - but it is tested, not assumed.
def perm_xzy(v):  return (v[0], v[2], -v[1])
def perm_id(v):   return v

CANDIDATES = {
    "xz-y / Ry(rot.y+90)":  lambda v, e: rot_y(perm_xzy(v), e["rot"][1] + 90.0),
    "xz-y / Ry(rot.y)":     lambda v, e: rot_y(perm_xzy(v), e["rot"][1]),
    "xz-y / no rotation":   lambda v, e: perm_xzy(v),
    "identity / Ry(rot.y)": lambda v, e: rot_y(perm_id(v), e["rot"][1]),
    "identity / none":      lambda v, e: perm_id(v),
}


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("map", nargs="?", default="Azeroth")
    ap.add_argument("--tiles", type=int, default=4)
    ap.add_argument("--max", type=int, default=400)
    args = ap.parse_args(argv[1:])

    print("indexing archives...")
    c = Client()
    # PICK TILES BY DOODAD DENSITY, not by index range. The first attempt took
    # the lowest-numbered tiles in a bounding box and measured TEN doodads across
    # six tiles - because those are map-edge wilderness with none at all, while
    # 32,48 alone holds 1579. The comparison was starved by tile selection and
    # reported a confident dead heat; the parser was never the problem.
    cand = [t for t in c.tiles(args.map) if 25 <= t[0] <= 40 and 25 <= t[1] <= 55]
    scored = []
    for tx, ty, real in cand:
        d = c.read(real)
        if d:
            scored.append((len(mddf_entries(d)), tx, ty, real))
    scored.sort(reverse=True)
    tiles = [(tx, ty, real) for _n, tx, ty, real in scored[:args.tiles]]
    print(f"  densest tiles: " + ", ".join(f"{t[0]},{t[1]}" for t in tiles[:6]))

    errs = {k: [] for k in CANDIDATES}
    model_cache: dict[str, object] = {}
    checked = 0

    for tx, ty, real in tiles:
        data = c.read(real)
        if not data:
            continue
        mcnks = parse_adt(data)
        if not mcnks:
            continue
        grid = terrain_lookup(mcnks)
        names = m2_names(data)
        for e in mddf_entries(data):
            if checked >= args.max:
                break
            if e["nameId"] >= len(names):
                continue
            path = names[e["nameId"]]
            key = path.lower()
            if key not in model_cache:
                raw = c.read(path)
                if not raw and path.lower().endswith((".mdx", ".mdl")):
                    raw = c.read(path[:-4] + ".m2")
                model_cache[key] = parse_m2(raw) if raw else None
            m = model_cache[key]
            if not m or not m["verts"]:
                continue

            for name, fn in CANDIDATES.items():
                lo_z = None
                wx = wy = None
                for v in m["verts"]:
                    t = fn(v, e)
                    px = t[0] * e["scale"] + e["pos"][0]
                    py = t[1] * e["scale"] + e["pos"][1]
                    pz = t[2] * e["scale"] + e["pos"][2]
                    # placement space -> world (same conversion as MODF)
                    ax, ay, az = ORIGIN - pz, ORIGIN - px, py
                    if lo_z is None or az < lo_z:
                        lo_z, wx, wy = az, ax, ay
                if lo_z is None:
                    continue
                g = ground_at(grid, wx, wy)
                if g is not None:
                    errs[name].append(abs(lo_z - g))
            checked += 1

    if not checked:
        print("no placeable doodads with collision meshes found")
        return 1
    print(f"doodads measured: {checked}\n")
    print("distance from the collision-mesh BASE to the terrain under it:")
    ranked = []
    for name, vals in errs.items():
        if not vals:
            continue
        med = statistics.median(vals)
        within = 100.0 * sum(1 for v in vals if v <= 2.0) / len(vals)
        ranked.append((med, within, name))
    ranked.sort()
    for med, within, name in ranked:
        print(f"   {name:<24} median {med:7.2f} yd   {within:5.1f}% within 2yd")
    best = ranked[0]
    print(f"\nWINNER: {best[2]}   (median {best[0]:.2f} yd off the ground)")
    if len(ranked) > 1:
        ratio = ranked[1][0] / max(best[0], 1e-6)
        print(f"next best is {ratio:.1f}x worse - "
              f"{'decisive' if ratio > 1.5 else 'NOT decisive, look elsewhere'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

"""Turn the client's terrain into a walkability grid the bot can path on.

The addon's world model is built from raycasts, so it only knows what it has
looked at and guesses past render range. This produces the opposite: exact ground
truth for a whole zone, computed once, offline.

Two sources, both already in the ADT - no WMO or M2 file parsing needed for a
first pass:

  * MCVT heightmaps          -> ground height and SLOPE (can I run up this?)
  * MODF building placements -> axis-aligned bounds of every WMO on the tile
                                (a building blocks ground the heightmap happily
                                calls walkable, which is exactly the "runs
                                straight at obstacles" failure)

Resolution is a knob, not a constant. The raw data is 4.17yd; pathing does not
need that, and the export size is quadratic in it, so the default coarsens to
something a client can hold for a whole continent while staying finer than the
character's own collision radius.

    python tools/build_navgrid.py Azeroth --tile 32 48
    python tools/build_navgrid.py Azeroth --bounds 30 46 34 50 --out build/
"""
from __future__ import annotations

import argparse
import math
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from adt_extract import (Client, TILE, UNIT, ORIGIN, chunks,  # noqa: E402
                         parse_adt, sample_grid, parse_mh2o, mclq_level)
from wmo_extract import parse_root, parse_group, group_paths   # noqa: E402
from wmo_place import modf_entries, wmo_names, rot_y           # noqa: E402
from m2_extract import parse_m2                              # noqa: E402
from m2_place import mddf_entries, m2_names                  # noqa: E402

# Resolved by measurement in tools/wmo_place.py (fit 0.869 vs 0.433 identity):
# permute (x,y,z) -> (x,z,-y), rotate about Y by rot.y + 90, translate by pos.
def place(v, e):
    pv = (v[0], v[2], -v[1])
    r = rot_y(pv, e["rot"][1] + 90.0)
    return (r[0] + e["pos"][0], r[1] + e["pos"][1], r[2] + e["pos"][2])


# A WALL BLOCKS; A FLOOR DOES NOT - a floor IS the ground. This is the whole
# reason the AABB approach measured 82% of a tile blocked from five buildings:
# a bounding box cannot tell the two apart, so it condemned every interior floor
# and courtyard. A triangle whose normal is mostly horizontal is a vertical
# surface, i.e. something you walk into. Anything flatter is something you walk
# ON, and marking it solid is what would seal a town shut.
WALL_NORMAL_MAX_Z = 0.5          # |nz| below this => vertical enough to be a wall
CHARACTER_HEIGHT = 2.0           # yd of clearance a wall must actually obstruct
# yd a floor may sit above the terrain and still be the surface reached from
# here. Beyond a storey it is a roof or upper deck, not this cell's ground.
# yd a standable surface may sit above terrain and still be the ground you
# reach from here. Raised from 12 after the verify outlier at (1688,1546)
# turned out to be a doodad surface 16.5yd up that the cap had rejected.
# HOW FAR ABOVE THE TERRAIN A STANDABLE SURFACE MAY STILL BE RECORDED.
#
# This was 24.0, which silently deleted every ELEVATED structure: a tower, an
# upper storey, anything built on a raised foundation. Measured live, the
# character stood on a floor at z=93.9 while the terrain beneath was 54.8 - a
# 39yd rise, so that floor was never recorded, the mesh answered about the
# ground far below, and the bot walked into walls of a floor plan it was not on.
# The frame trace showed the cell 3yd ahead reading solid on 165 of 243 frames
# while it kept walking.
#
# There is no reason for a small cap. Buildings are as tall as they are, the
# layer block is sparse (only cells with a second surface cost anything), and a
# surface the generator found is a surface the character can be standing on.
FLOOR_MAX_RISE = 200.0

_model_cache = {}


def collision_tris(c, path):
    """Collision triangles in model space, cached - a tile reuses the same
    building many times and re-reading a cathedral per instance is absurd."""
    hit = _model_cache.get(path)
    if hit is not None:
        return hit
    tris = []
    raw = c.read(path)
    root = parse_root(raw) if raw else None
    if root:
        for gp in group_paths(path, root["n_groups"]):
            gd = c.read(gp)
            if not gd:
                continue
            g = parse_group(gd)
            if not g or not g["tris"]:
                continue
            vs = g["verts"]
            for a, b, cc in g["tris"]:
                if a < len(vs) and b < len(vs) and cc < len(vs):
                    tris.append((vs[a], vs[b], vs[cc]))
    _model_cache[path] = tris
    return tris


# Doodads: the trees, rocks, logs and fences a character actually snags on, and
# the last large category invisible to the grid.
#
# THE BOUNDING BOX IS ESPECIALLY WRONG HERE - an M2's box includes the CANOPY, so
# blocking it would make a forest solid when you can walk freely under branches.
# M2 files carry a separate COLLISION MESH (a few triangles around the trunk) for
# exactly this, and models with none - grass, flowers, small clutter - are
# genuinely non-blocking, so an empty result is the right answer, not a failure.
#
# TRANSFORM, and the honest limits of how it was established:
#   * The AXIS PERMUTATION (x,y,z)->(x,z,-y) is confirmed by measurement in
#     tools/m2_place.py: 0.68yd median ground contact over 600 doodads against
#     1.37yd for identity, 76% vs 61% within 2yd.
#   * The YAW IS NOT RESOLVED BY THAT ORACLE AND CANNOT BE. Rotation about the
#     vertical axis does not change where an object touches the ground, so all
#     rotation candidates score identically (0.68 / 0.69 / 0.71) - a structural
#     blind spot, not a weak signal. It is taken from the WMO transform, which
#     shares this placement space and WAS independently verified against MODF
#     bounding boxes. Consistency with a verified sibling beats a coin flip, but
#     it is inference, not measurement: an elongated prop (a log, a fence) may
#     have its footprint rotated until an in-game check says otherwise. Round
#     props - most trees and rocks - are insensitive to this either way.
#   * THE BLAST RADIUS IS MEASURED, not hand-waved: rebuilding a tile with the
#     yaw rotated 90 degrees changes only 0.35% (tile 32,48) to 1.75% (31,49) of
#     cells, because collision meshes are largely radially symmetric at 4yd. Those
#     cells are STRUCTURE - a cost hint that defers to live raycasts - not hard
#     blocks, so a wrong yaw misprices a fraction of a percent of the grid and
#     live sensing corrects it. An unverified assumption with a measured bound is
#     a different thing from an unverified assumption.
_m2_cache = {}


def doodad_tris(c, path):
    key = path.lower()
    hit = _m2_cache.get(key)
    if hit is not None:
        return hit
    raw = c.read(path)
    if not raw and key.endswith((".mdx", ".mdl")):
        raw = c.read(path[:-4] + ".m2")
    m = parse_m2(raw) if raw else None
    tris = []
    if m and m["tris"]:
        vs = m["verts"]
        for a, b, cc in m["tris"]:
            tris.append((vs[a], vs[b], vs[cc]))
    _m2_cache[key] = tris
    return tris


def place_doodad(v, e):
    pv = (v[0], v[2], -v[1])
    r = rot_y(pv, e["rot"][1] + 90.0)
    sc = e["scale"]
    return (r[0] * sc + e["pos"][0], r[1] * sc + e["pos"][1], r[2] * sc + e["pos"][2])


def tri_cells(pts, n, x0, y0, res):
    """Cells a triangle ACTUALLY covers - not the cells of its bounding box.

    THE BUG THIS REPLACES. Both rasterisers walked the triangle's axis-aligned
    bounding box and marked every cell in it. For a wall spanning a room
    diagonally that rectangle is the WHOLE ROOM, so the interior was stamped
    BLOCKED by the wall that merely borders it. Measured in the shipped data: a
    5x5 cell area where the character was standing read `blocked` with zero
    floors, while 71 cells within 4 yards carried the real floor at ~94 - floors
    survived only at the edges of the blotted rectangle.

    A cell is covered if its CENTRE lies inside the triangle, or if the triangle
    passes within half a cell of that centre. The second half matters for walls:
    projected to 2D a wall is a sliver, and a strict inside-test would leave gaps
    a route could squeeze through. Conservative in the safe direction - a wall
    slightly too thick beats a wall with holes - while no longer claiming the
    empty room behind it.
    """
    (ax, ay), (bx, by), (cx, cy) = (pts[0][0], pts[0][1]), (pts[1][0], pts[1][1]), (pts[2][0], pts[2][1])
    gx0 = max(0, int((min(ax, bx, cx) - x0) / res) - 1)
    gx1 = min(n - 1, int((max(ax, bx, cx) - x0) / res) + 1)
    gy0 = max(0, int((min(ay, by, cy) - y0) / res) - 1)
    gy1 = min(n - 1, int((max(ay, by, cy) - y0) / res) + 1)
    d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
    reach = res * 0.5
    r2 = reach * reach

    def seg_d2(px, py, x1, y1, x2, y2):
        dx, dy = x2 - x1, y2 - y1
        L = dx * dx + dy * dy
        if L <= 1e-12:
            return (px - x1) ** 2 + (py - y1) ** 2
        t = ((px - x1) * dx + (py - y1) * dy) / L
        if t < 0.0:
            t = 0.0
        elif t > 1.0:
            t = 1.0
        qx, qy = x1 + t * dx, y1 + t * dy
        return (px - qx) ** 2 + (py - qy) ** 2

    out = []
    for gy in range(gy0, gy1 + 1):
        py = y0 + gy * res + res * 0.5
        for gx in range(gx0, gx1 + 1):
            px = x0 + gx * res + res * 0.5
            inside = False
            if abs(d) > 1e-12:
                w1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / d
                w2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / d
                w3 = 1.0 - w1 - w2
                inside = (w1 >= 0.0 and w2 >= 0.0 and w3 >= 0.0)
            if not inside:
                if not (seg_d2(px, py, ax, ay, bx, by) <= r2
                        or seg_d2(px, py, bx, by, cx, cy) <= r2
                        or seg_d2(px, py, cx, cy, ax, ay) <= r2):
                    continue
            out.append(gy * n + gx)
    return out


def rasterise_doodads(c, data, grid, zs, n, x0, y0, res, surfaces):
    """Mark cells a doodad's collision mesh obstructs, and record the surfaces
    you can stand ON.

    A doodad is not only an obstacle. A rock, a platform, a crate, a fallen log
    all present a horizontal collision face that the client's own raycast lands
    on - which is why the worst remaining verify outlier was a CLUTTER cell where
    the grid reported terrain at 123.6 and the client reported 140.1. There was no
    building anywhere near it. Buildings got floor handling and doodads did not,
    for no reason other than that I only thought of buildings.
    """
    names = m2_names(data)
    ents = mddf_entries(data)
    marked = 0
    for e in ents:
        if e["nameId"] >= len(names):
            continue
        tris = doodad_tris(c, names[e["nameId"]])
        if not tris:
            continue
        for tri in tris:
            w = [place_doodad(v, e) for v in tri]
            pts = [(ORIGIN - t[2], ORIGIN - t[0], t[1]) for t in w]
            zlo = min(pt[2] for pt in pts)
            zhi = max(pt[2] for pt in pts)
            ux = (pts[1][0] - pts[0][0], pts[1][1] - pts[0][1], pts[1][2] - pts[0][2])
            vx = (pts[2][0] - pts[0][0], pts[2][1] - pts[0][1], pts[2][2] - pts[0][2])
            dnz = ux[0] * vx[1] - ux[1] * vx[0]
            dnx = ux[1] * vx[2] - ux[2] * vx[1]
            dny = ux[2] * vx[0] - ux[0] * vx[2]
            dln = math.sqrt(dnx * dnx + dny * dny + dnz * dnz) or 1.0
            horizontal = abs(dnz / dln) >= WALL_NORMAL_MAX_Z
            fz = (zlo + zhi) * 0.5
            # The cells this triangle ACTUALLY covers. Walking its bounding box
            # stamped whole rooms with the wall that merely borders them.
            for k in tri_cells(pts, n, x0, y0, res):
                    if horizontal and grid[k] != UNKNOWN:
                        rise = fz - zs[k]
                        if 0.3 < rise < FLOOR_MAX_RISE:
                            # EVERY STANDABLE SURFACE, NOT THE LOWEST.
                            # Keeping only the lowest collapsed a multi-storey
                            # building to its ground floor and DISCARDED the
                            # floor the character was standing on - so the mesh
                            # answered with the ground plan while the bot was
                            # upstairs, and it walked into walls that were not
                            # on its floor. Distinct floors are >1yd apart;
                            # anything closer is the same surface sampled twice.
                            prev = surfaces.get(k)
                            if prev is None:
                                surfaces[k] = [fz]
                            elif all(abs(fz - z) > 1.0 for z in prev):
                                prev.append(fz)
                        continue
                    # Skip cells already decided: UNKNOWN has no ground, BLOCKED
                    # is a real wall, and STRUCTURE is already marked - without
                    # the last one every triangle re-marks the same cell and the
                    # counter reports 17173 marks for 753 actual cells.
                    if grid[k] in (UNKNOWN, BLOCKED, STRUCTURE):
                        continue
                    # Only where it obstructs the character's own height band. A
                    # root at ankle level is steppable; a branch overhead is not a
                    # wall. Without this a tree canopy would block its whole
                    # footprint exactly like the AABB it replaces.
                    if zhi >= zs[k] + 0.4 and zlo <= zs[k] + CHARACTER_HEIGHT:
                        # STRUCTURE, NOT BLOCKED - and this is a resolution
                        # judgement, not timidity. A tree trunk is ~1yd across;
                        # an 8yd cell is not. Marking the cell solid because a
                        # trunk touches it made 20% of Elwynn impassable, which
                        # is the same over-blocking that a WMO bounding box
                        # produced for towns: real geometry, wrong granularity.
                        # A character walks BETWEEN trees, so a forest is
                        # expensive terrain, not a wall - priced here and
                        # deferred to live raycasts, which see the actual trunk.
                        grid[k] = STRUCTURE
                        marked += 1
    return marked


def rasterise_wmos(c, data, grid, zs, n, x0, y0, res, surfaces):
    """Mark cells that a real wall passes through. Returns (walls, floors)."""
    names = wmo_names(data)
    ents = modf_entries(data)
    walls = floors = 0
    for e in ents:
        if e["nameId"] >= len(names):
            continue
        for tri in collision_tris(c, names[e["nameId"]]):
            w = [place(v, e) for v in tri]
            # world conversion: placement space -> world (see the MODF trap)
            pts = [(ORIGIN - t[2], ORIGIN - t[0], t[1]) for t in w]
            ux = (pts[1][0] - pts[0][0], pts[1][1] - pts[0][1], pts[1][2] - pts[0][2])
            vx = (pts[2][0] - pts[0][0], pts[2][1] - pts[0][1], pts[2][2] - pts[0][2])
            nz = ux[0] * vx[1] - ux[1] * vx[0]
            nx = ux[1] * vx[2] - ux[2] * vx[1]
            ny = ux[2] * vx[0] - ux[0] * vx[2]
            ln = math.sqrt(nx * nx + ny * ny + nz * nz)
            if ln < 1e-6:
                continue
            vertical = abs(nz / ln) < WALL_NORMAL_MAX_Z
            zlo = min(pt[2] for pt in pts)
            zhi = max(pt[2] for pt in pts)
            if not vertical:
                # A FLOOR IS WALKABLE GROUND, AND IT IS THE GROUND THE CHARACTER
                # ACTUALLY STANDS ON. These triangles were counted and discarded,
                # so inside a building the grid reported the terrain BENEATH the
                # structure - measured against the client as a mean error of
                # 10.92yd on wall/structure cells, by far the largest class left.
                # Raise the cell to the floor when the floor is above the terrain
                # and within a storey of it: higher than that is a roof or an
                # upper deck, which is not the surface you reach from here.
                floors += 1
                fz = (zlo + zhi) * 0.5
                fgx0 = max(0, int((min(pt[0] for pt in pts) - x0) / res))
                fgx1 = min(n - 1, int((max(pt[0] for pt in pts) - x0) / res))
                fgy0 = max(0, int((min(pt[1] for pt in pts) - y0) / res))
                fgy1 = min(n - 1, int((max(pt[1] for pt in pts) - y0) / res))
                for gy in range(fgy0, fgy1 + 1):
                    for gx in range(fgx0, fgx1 + 1):
                        k = gy * n + gx
                        if grid[k] == UNKNOWN:
                            continue
                        rise = fz - zs[k]
                        if 0.3 < rise < FLOOR_MAX_RISE:
                            # LOWEST qualifying surface wins, not the last one
                            # processed. A multi-storey building offers several
                            # floors over the same cell and only the bottom one is
                            # the surface you reach from outside; taking whichever
                            # triangle happened to come last picks an upper deck
                            # at random.
                            # Same rule as the WMO pass: keep EVERY distinct
                            # standable surface. The old comment here explained
                            # that only the bottom deck is reachable from
                            # outside - true, and that is why the base layer is
                            # the lowest, but the upper decks are exactly what a
                            # character standing on one needs the mesh to know.
                            prev = surfaces.get(k)
                            if prev is None:
                                surfaces[k] = [fz]
                            elif all(abs(fz - z) > 1.0 for z in prev):
                                prev.append(fz)
                continue
            if (zhi - zlo) < CHARACTER_HEIGHT * 0.5:
                continue                 # a kerb is not a wall
            # The cells this triangle ACTUALLY covers. Walking its bounding box
            # stamped whole rooms with the wall that merely borders them.
            for k in tri_cells(pts, n, x0, y0, res):
                    # Only obstruct where the wall actually spans the character's
                    # height above the ground here; a high arch is not a wall.
                    if zhi >= zs[k] and zlo <= zs[k] + CHARACTER_HEIGHT:
                        if grid[k] != BLOCKED:
                            grid[k] = BLOCKED
                            walls += 1
    return walls, floors



# Walkable slope. WoW slides you off anything steeper than ~50deg; Ascension
# alters movement, so this is a tunable rather than a law.
MAX_WALK_SLOPE = 50.0
# Water shallower than this is wadeable and stays WALK; deeper forces swimming.
SWIM_DEPTH = 1.5
# LiquidType.dbc: 3 = magma, 4 = slime. Swimming in either kills, so they block.
LETHAL_LIQUIDS = {3, 4}
# yd of terrain-above-water tolerated before the liquid mapping is called wrong.
# Shorelines legitimately sit near zero depth; a flooded hillside does not.
WATER_SANITY = 4.0
Z_BIAS_Q = 4000          # quarter-yards added so packed heights stay non-negative
# 4yd matches the source sample spacing (4.17yd), so this is the maximum fidelity
# the ADT heightmaps can give. Held back at 8yd until the Lua load cost was
# MEASURED rather than assumed: decode is 5.0ms vs 2.0ms, and a tile is 533yd
# wide, so that is one frame roughly every 75 seconds of running. The residual it
# targets is real and specific - steep terrain carried mean 2.31yd error and 5 of
# the 8 remaining outliers, which only finer cells can fix.
DEFAULT_RES = 4.0            # yd between grid samples

# Grid codes, one byte each - deliberately small, since the whole point is that a
# continent has to fit somewhere.
UNKNOWN, WALK, STEEP, BLOCKED, WATER, STRUCTURE, TIGHT = 0, 1, 2, 3, 4, 5, 6

# THE BODY HAS WIDTH, AND THAT IS WHY IT SNAGS.
#
# A cell whose CENTRE is clear is not somewhere the character can stand: it
# occupies a radius, so ground within one body-radius of a wall is unusable, and
# a route through it scrapes the corner. This is the standard navmesh erosion
# step and it is what separates "a path exists on the grid" from "a body can
# walk it" - without it every doorway edge, fence post and crate corner is a
# snag, however fine the resolution.
#
# Eroded cells are marked TIGHT rather than deleted: they are real floor, just
# not floor a body can occupy, and a consumer that wants the truth can still see
# it. The planner treats TIGHT as impassable.
AGENT_RADIUS = 0.55              # yd; WoW player collision radius, measured side


def erode_for_body(grid, n, res, radius=AGENT_RADIUS):
    """Mark walkable cells within one body radius of solid geometry as TIGHT.

    EUCLIDEAN, in YARDS - not a count of cells. Chebyshev cell-counting erodes
    ceil(radius/res) cells in every direction, which at 0.5yd resolution is a
    full 1.0yd (1.4yd on the diagonal) instead of 0.55 - that is not "slightly
    conservative", it is enough to seal a real doorway and make rooms
    unreachable. The eroded band must be the body's actual radius at ANY
    resolution, so the test is a true distance.
    """
    if radius <= 0:
        return 0
    r = int(math.ceil(radius / res))
    if r <= 0:
        return 0
    # precompute the disc once: offsets whose CELL CENTRE lies within radius
    disc = []
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if math.sqrt((dx * res) ** 2 + (dy * res) ** 2) <= radius:
                disc.append((dx, dy))
    solid = [k for k, v in enumerate(grid) if v in (BLOCKED, STRUCTURE)]
    hit = set()
    for k in solid:
        gy, gx = divmod(k, n)
        for dx, dy in disc:
            yy, xx = gy + dy, gx + dx
            if 0 <= yy < n and 0 <= xx < n:
                j = yy * n + xx
                if grid[j] in (WALK, WATER):
                    hit.add(j)
    for j in hit:
        grid[j] = TIGHT
    return len(hit)


def parse_modf(data: bytes) -> list[dict]:
    """WMO placements with their bounding boxes.

    MODF entry (64 bytes): nameId, uniqueId, pos[3], rot[3], lower[3], upper[3],
    flags, doodadSet, nameSet, scale. The bounds are already world-space and
    axis-aligned, which is all a blocking test needs.
    """
    out = []
    for magic, body, size in chunks(data):
        if magic != "MODF":
            continue
        n = size // 64
        for i in range(n):
            o = body + i * 64
            vals = struct.unpack_from("<II3f3f3f3fHHHH", data, o)
            lo, hi = vals[8:11], vals[11:14]
            # MODF bounds are in ADT PLACEMENT SPACE, not world space: the origin
            # is the map corner (32*TILE) and the axes are permuted - stored
            # (x, y, z) maps to world (32*TILE - z, 32*TILE - x, y). Using the raw
            # values as world coordinates puts every building tens of thousands of
            # yards away, so nothing ever intersects the tile and the whole
            # blocking pass silently does nothing (blocked=0 with 22 WMOs on the
            # tile - the tell that the conversion is missing, not that the data is).
            wx0, wx1 = ORIGIN - max(lo[2], hi[2]), ORIGIN - min(lo[2], hi[2])
            wy0, wy1 = ORIGIN - max(lo[0], hi[0]), ORIGIN - min(lo[0], hi[0])
            out.append({"x0": wx0, "x1": wx1, "y0": wy0, "y1": wy1,
                        "z0": min(lo[1], hi[1]), "z1": max(lo[1], hi[1])})
    return out


def build_tile(c: Client, mapname: str, tx: int, ty: int, res: float):
    """Return (grid, meta) for one ADT tile, or None when the tile is absent."""
    real = None
    for a_tx, a_ty, name in c.tiles(mapname):
        if (a_tx, a_ty) == (tx, ty):
            real = name
            break
    if real is None:
        return None
    data = c.read(real)
    if not data:
        return None

    mcnks = parse_adt(data)
    if not mcnks:
        return None
    pts = sample_grid(mcnks)
    wmos = parse_modf(data)

    # Tile origin: X index runs along world -Y, Y index along world -X. Verified
    # against the MCNK embedded positions in adt_extract.
    x1 = ORIGIN - ty * TILE
    y1 = ORIGIN - tx * TILE
    x0, y0 = x1 - TILE, y1 - TILE

    n = int(math.ceil(TILE / res))

    # BILINEAR FROM THE SAMPLE LATTICE, not the nearest sample.
    #
    # Two bugs died here in sequence. First the cell kept the LOWEST sample, which
    # cost a systematic downward bias of ~(slope x cell size) - measured against
    # the client as median 1.09yd but MEAN 2.94, the signature of a bias rather
    # than noise. Nearest-to-centre fixed that (median 0.51, bias +0.42, symmetric).
    #
    # But nearest-sample cannot go FINER than the source: MCVT samples are 4.17yd
    # apart, so at 4yd cells roughly 6.6% of cells contain no sample at all and
    # become holes - going finer made the grid strictly worse, which is the
    # opposite of the intent. Interpolating the height FIELD instead of picking
    # from it fills every cell at any resolution and is closer to the truth at all
    # of them, since the terrain between samples really is a bilinear patch.
    lattice = {}
    for x, y, z in pts:
        lattice[(round(x / UNIT), round(y / UNIT))] = z

    def sample_at(wx, wy):
        """Bilinear over the 4.17yd MCVT lattice; nearest as the fallback so a
        cell at the tile edge still gets ground rather than a hole."""
        fx, fy = wx / UNIT, wy / UNIT
        ix, iy = math.floor(fx), math.floor(fy)
        tx_, ty_ = fx - ix, fy - iy
        h00 = lattice.get((ix, iy))
        h10 = lattice.get((ix + 1, iy))
        h01 = lattice.get((ix, iy + 1))
        h11 = lattice.get((ix + 1, iy + 1))
        if None not in (h00, h10, h01, h11):
            return ((h00 * (1 - tx_) + h10 * tx_) * (1 - ty_)
                    + (h01 * (1 - tx_) + h11 * tx_) * ty_)
        best, bd = None, None
        for dx in (0, 1, -1):
            for dy in (0, 1, -1):
                v = lattice.get((ix + dx, iy + dy))
                if v is not None:
                    d = dx * dx + dy * dy
                    if bd is None or d < bd:
                        best, bd = v, d
        return best

    heights = {}
    for gy in range(n):
        for gx in range(n):
            cx = x0 + (gx + 0.5) * res
            cy = y0 + (gy + 0.5) * res
            z = sample_at(cx, cy)
            if z is not None:
                heights[gy * n + gx] = z

    grid = bytearray([UNKNOWN]) * (n * n)
    zs = [0.0] * (n * n)
    for k, z in heights.items():
        zs[k] = z
        grid[k] = WALK

    # Slope from the assembled grid rather than the raw samples: this is the
    # resolution the planner will actually use, so it is the resolution the
    # walkability decision has to be made at.
    steep = 0
    for gy in range(n):
        for gx in range(n):
            k = gy * n + gx
            if grid[k] != WALK:
                continue
            worst = 0.0
            for dx, dy in ((1, 0), (0, 1), (-1, 0), (0, -1)):
                nx, ny = gx + dx, gy + dy
                if 0 <= nx < n and 0 <= ny < n:
                    nk = ny * n + nx
                    if grid[nk] != UNKNOWN:
                        worst = max(worst, math.degrees(
                            math.atan2(abs(zs[nk] - zs[k]), res)))
            if worst > MAX_WALK_SLOPE:
                grid[k] = STEEP
                steep += 1

    # WATER. The verify instrument's residual worst-cases are exactly here -
    # TraceGround hits the water surface while the terrain data holds the lake
    # bed - and unmarked water is a navigation hazard: the planner would happily
    # route a corpse run straight through a lake at running cost. Depth decides:
    # wadeable stays WALK, swim-depth becomes WATER (priced, not forbidden -
    # refusing water turns every river into a wall), magma and slime BLOCK.
    #
    # Sub-rect axes within a chunk (xo/yo vs row/col) are the one convention here
    # that is NOT yet independently verified; ocean tiles validate the gross
    # mapping (a full tile is transpose-symmetric) and the depth test filters
    # shore cells, but a lake edge may be off by up to one chunk until an
    # in-game check says otherwise.
    layers = parse_mh2o(data)
    water = 0
    bad_depth, depths = 0, []
    for m in mcnks:
        idx = m["iy"] * 16 + m["ix"]
        insts = (layers[idx] if layers and idx < 256 else [])
        if not insts:
            lvl = mclq_level(data, m)
            # NO INVENTED LEVEL. This used to assume sea level (0.0) for any chunk
            # carrying the ocean flag but no readable MCLQ - and a chunk flagged
            # ocean at 200yd elevation then "flooded" to depth -200. The
            # generator's own physics check caught it on 15 of 721 tiles, all
            # inland. A flag saying "there is liquid here" is not a statement of
            # WHERE its surface is; absence of a level is not evidence of sea
            # level. Unknown level -> no water marked -> live sensing decides.
            if lvl is not None:
                lethal = bool(m["flags"] & 0x30)   # magma / slime chunk flags
                insts = [{"type": 3 if lethal else 1, "min": lvl, "max": lvl,
                          "xo": 0, "yo": 0, "w": 8, "h": 8}]
        for inst in insts:
            lvl = inst["max"]
            lethal = inst["type"] in LETHAL_LIQUIDS
            w = inst["w"] or 8
            h = inst["h"] or 8
            for a in range(inst["xo"], min(8, inst["xo"] + w)):
                for b in range(inst["yo"], min(8, inst["yo"] + h)):
                    # AXES SWAPPED, resolved by tools/water_orient.py. The
                    # sub-rect's first axis indexes MCVT COLUMNS, not rows. The
                    # ocean test could never see this - a fully flooded tile is
                    # transpose-symmetric and scored 100% either way. Physics
                    # could: water cannot sit below the ground it covers, and the
                    # as-is mapping gave a MEAN DEPTH OF -10.02yd (water ten yards
                    # under the terrain) against +0.05 for this one.
                    wx = m["x"] - (b + 0.5) * UNIT
                    wy = m["y"] - (a + 0.5) * UNIT
                    gx = int((wx - x0) / res)
                    gy = int((wy - y0) / res)
                    if 0 <= gx < n and 0 <= gy < n:
                        k = gy * n + gx
                        if grid[k] == UNKNOWN:
                            continue
                        depth = lvl - zs[k]
                        # SELF-CHECK AT THE POINT OF PRODUCTION. Water cannot sit
                        # below the ground it covers, so a strongly negative depth
                        # means the liquid mapping is wrong - which is exactly the
                        # bug that shipped here once (mean depth -10yd, invisible
                        # because ocean tiles are transpose-symmetric and scored
                        # 100% either way). The generator now says so instead of
                        # quietly emitting a world with lakes on hillsides.
                        if depth < -WATER_SANITY:
                            bad_depth += 1
                        depths.append(depth)
                        if lethal and depth > -0.5:
                            grid[k] = BLOCKED
                        elif depth > SWIM_DEPTH and grid[k] in (WALK, STEEP):
                            grid[k] = WATER
                            water += 1

    # REAL PER-FACE COLLISION, replacing the bounding-box hint. The AABB could
    # only ever say "a building is somewhere in here"; the geometry says which
    # cells a wall actually crosses, so a town is now routable THROUGH rather
    # than merely around.
    # Collected from both passes, applied once: the LOWEST standable surface
    # above the terrain in each cell is the ground the character reaches.
    surfaces: dict[int, float] = {}
    blocked, _floors = rasterise_wmos(c, data, grid, zs, n, x0, y0, res, surfaces)
    doodads = rasterise_doodads(c, data, grid, zs, n, x0, y0, res, surfaces)
    raised = 0
    extra: dict[int, list[float]] = {}
    for k, zl in surfaces.items():
        if grid[k] not in (UNKNOWN, BLOCKED):
            zl.sort()
            zs[k] = zl[0]              # base layer stays the lowest floor
            if len(zl) > 1:
                extra[k] = zl[1:]      # upper floors, in ascending order
            raised += 1

    # RECOUNT FROM THE FINAL GRID. The running totals above describe intermediate
    # states - structure marking overwrites cells already counted as steep - so
    # shipping them would mean the metadata disagrees with the data it labels.
    # Counts a consumer cannot verify against the payload are worse than absent.
    tight = erode_for_body(grid, n, res)

    walk = sum(1 for v in grid if v == WALK)
    steep = sum(1 for v in grid if v == STEEP)
    blocked = sum(1 for v in grid if v == BLOCKED)
    soft = sum(1 for v in grid if v == STRUCTURE)
    water = sum(1 for v in grid if v == WATER)
    meta = {"map": mapname, "tx": tx, "ty": ty, "n": n, "res": res,
            # WHAT THIS CHECK CAN AND CANNOT DO - and the distinction cost a
            # round trip to learn. It flags an INDIVIDUAL tile whose liquid is
            # grossly inconsistent with its own terrain (it found 33,44 at median
            # -10.6 with no water marked). It CANNOT detect a global axis-
            # convention error: measured per tile, the impossible-cell fraction
            # for the correct mapping reaches 0.31 while the swapped mapping drops
            # to 0.02, so the distributions overlap completely and no threshold
            # separates them. Swapped is consistently worse per tile, but only by
            # margins that vanish against real terrain variation.
            #
            # An earlier attempt to silence false positives by switching from mean
            # to median DISARMED it entirely - it stopped detecting the swapped
            # axes at all. Making a check quieter is not the same as making it
            # right, and a guard that no longer fires is worse than none.
            #
            # THE CONVENTION GUARD IS tools/water_orient.py, which compares
            # candidates in AGGREGATE (-10.02yd vs +0.05yd mean depth) and is
            # decisive where this is blind. Run it after touching liquid mapping.
            #
            # MEDIAN, not mean. A liquid layer's sub-rectangle covers the BANKS
            # of a lake as well as its surface, and terrain there is legitimately
            # above the water - a few tall banks drag a mean negative and the
            # check fired on 15 of 721 tiles that were entirely correct, including
            # one with no water marked at all. The median asks the diagnostic
            # question instead: is the covered area MOSTLY above the surface,
            # which is what a wrong mapping actually produces.
            "water": water, "bad_depth": bad_depth, "doodads": doodads,
            "soft": soft, "raised": raised,
            "mean_depth": (sorted(depths)[len(depths) // 2] if depths else 0.0),
            "x0": x0, "y0": y0, "wmos": len(wmos),
            "walk": walk, "steep": steep, "blocked": blocked,
            "zmin": min(zs) if zs else 0, "zmax": max(zs) if zs else 0,
            # UPPER FLOORS. Cell index -> ascending heights above the base layer.
            # Without these a multi-storey building collapses to its ground plan.
            "layers": extra}
    return grid, zs, meta


def emit_lua(grid, zs, m) -> str:
    """Emit a tile the addon can load at runtime.

    Codes are run-length encoded ("<letter><count>", a=UNKNOWN..f=STRUCTURE); a
    walkability grid is hugely run-length redundant and this stays readable by eye.

    HEIGHTS ARE PER CELL, DELTA ENCODED - and the previous version's per-RUN
    average is why /raijin navgrid verify measured only 20% of points within 3yd,
    median error 8yd, worst 118. The comment justifying it claimed "a run of one
    terrain code is nearly always near-flat"; that is simply false. Runs follow
    row-major order, so a single run of WALK cells can span an entire hillside,
    and the stored average is then wrong by the relief across it. Short runs and
    flat ground matched, which is exactly the partial agreement that was measured.

    Deltas keep it compact without lying: adjacent cells differ by a few quarter
    yards, so most values are one or two characters.
    """
    runs = []
    cur, n = grid[0], 0
    for v in grid:
        if v == cur:
            n += 1
        else:
            runs.append(chr(97 + cur) + str(n))
            cur, n = v, 1
    runs.append(chr(97 + cur) + str(n))

    # quarter-yard integers, delta encoded against the running value
    out, prev = [], 0
    for i, v in enumerate(grid):
        q = int(round(zs[i] * 4)) if v != 0 else prev
        out.append(str(q - prev))
        prev = q

    L = []
    L.append("-- RaijinLab navgrid tile - generated by tools/build_navgrid.py")
    L.append("-- codes: a=unknown b=walk c=steep d=blocked e=water f=structure g=tight")
    L.append("-- tight: real floor within one body-radius of geometry - a body does not fit")
    L.append("-- cd: one letter per cell, cell i is byte i - no decoding")
    L.append("-- zq: two base-32 digits per cell; z = zmin + value * zstep")
    L.append("-- lay: upper floors as cell:quarter-yards (multi-storey buildings)")
    L.append("return {")
    L.append('  map = "%s", tx = %d, ty = %d,' % (m["map"], m["tx"], m["ty"]))
    L.append("  n = %d, res = %g," % (m["n"], m["res"]))
    L.append("  x0 = %.3f, y0 = %.3f," % (m["x0"], m["y0"]))
    # One count per CODE. A single "structure" field meant walls and doodad
    # clutter shared a number while living in different codes, so a consumer
    # could not verify either against the payload - and the round-trip test
    # caught exactly that.
    L.append("  walk = %d, steep = %d, blocked = %d, structure = %d, water = %d," % (
        m["walk"], m["steep"], m["blocked"], m.get("soft", 0), m.get("water", 0)))
    # ---------------------------------------------------------------------
    # THE PAYLOAD IS INDEXED, NOT DECODED.
    #
    # The old format made the CLIENT rebuild the tile: run-length codes had to be
    # expanded (37,506 runs -> 15ms) and heights were one delta PER CELL, so a
    # 0.5yd tile cost 1,138,489 gmatch+tonumber steps - measured at 338ms, i.e.
    # 95% of a 400ms load, and the reason the game sat under 1 fps.
    #
    # None of that work is necessary. Both arrays are fixed-width strings the
    # addon indexes with string.byte and nothing else, built HERE where the cost
    # is paid once, offline, by a machine that is not rendering a game.
    #
    #   cd : one printable letter per cell (a..g), so cell i is byte i.
    #   zq : two base-32 digits per cell = 1024 steps across THIS TILE'S OWN
    #        relief. Tile ranges run ~220yd, giving ~0.21yd - finer than the
    #        0.5yd cells the heights describe, so this is not a precision loss;
    #        it is precision matched to the grid instead of wasted on absolutes.
    #        zmin/zstep travel with the tile, so decoding is two byte reads and
    #        one multiply-add.
    #
    # Load cost becomes the chunk parse alone (~11ms). Same data, same detail.
    ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUV"      # 32 printable, escape-free
    cd = "".join(chr(97 + v) for v in grid)

    zmin = min(zs) if zs else 0.0
    zmax = max(zs) if zs else 0.0
    span = zmax - zmin
    zstep = (span / 1023.0) if span > 1e-6 else 1.0
    zq = []
    for z in zs:
        q = int(round((z - zmin) / zstep))
        if q < 0:
            q = 0
        elif q > 1023:
            q = 1023
        zq.append(ALPHA[(q >> 5) & 31] + ALPHA[q & 31])

    L.append('  cd = "%s",' % cd)
    L.append('  zmin = %.4f, zstep = %.8f,' % (zmin, zstep))
    L.append('  zq = "%s",' % "".join(zq))
    # UPPER FLOORS. Lost once already when the payload section was rewritten,
    # which silently stripped every multi-storey building from the .lua fallback
    # while the .dat kept them - the two formats must describe the same world.
    lay = m.get("layers") or {}
    if lay:
        parts = []
        for k in sorted(lay):
            for z in lay[k]:
                parts.append("%d:%d" % (k, int(round(z * 4))))
        L.append('  lay = "%s",' % " ".join(parts))
    L.append("}")
    return chr(10).join(L) + chr(10)


def emit_raw(grid, zs, m) -> str:
    """The same tile as DATA, not as code.

    The Lua form costs ~11ms per tile purely to `loadstring` 3.3MB of source -
    the payload is two enormous string literals and the parser has to scan every
    byte of them. Nothing about a walkability grid needs to be executable.

    This is a flat file: one header line of small numbers, then each block on its
    own line as `key:payload`. Loading is ReadFile plus a handful of string.find
    and string.sub calls - microseconds - and a data file can no longer be code,
    which removes the reason the Lua loader needed an empty environment.
    """
    ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
    cd = "".join(chr(97 + v) for v in grid)
    zmin = min(zs) if zs else 0.0
    zmax = max(zs) if zs else 0.0
    span = zmax - zmin
    zstep = (span / 1023.0) if span > 1e-6 else 1.0
    zq = []
    for z in zs:
        q = int(round((z - zmin) / zstep))
        q = 0 if q < 0 else (1023 if q > 1023 else q)
        zq.append(ALPHA[(q >> 5) & 31] + ALPHA[q & 31])
    # UPPER FLOORS AS FIXED-WIDTH, SORTED RECORDS.
    #
    # "cell:qz cell:qz ..." had to be gmatch'd into nested tables at load -
    # 15,678 records on a church tile, and once the codes and heights stopped
    # needing a pass this became the ENTIRE remaining load cost (~29ms).
    #
    # Each record is 7 base-32 chars: 5 for the cell index (25 bits, covers
    # 1,138,489 cells) and 2 for the height on this tile's own zmin/zstep scale.
    # Sorted by cell, so a query binary-searches the string in place and loading
    # costs nothing at all.
    lay = m.get("layers") or {}
    recs = []
    for k in sorted(lay):
        for z in sorted(lay[k]):
            q = int(round((z - zmin) / zstep))
            q = 0 if q < 0 else (1023 if q > 1023 else q)
            recs.append(
                ALPHA[(k >> 20) & 31] + ALPHA[(k >> 15) & 31] + ALPHA[(k >> 10) & 31]
                + ALPHA[(k >> 5) & 31] + ALPHA[k & 31]
                + ALPHA[(q >> 5) & 31] + ALPHA[q & 31])
    parts = recs
    zqs = "".join(zq)
    lays = "".join(parts)
    # THE HEADER DECLARES THE BLOCK LENGTHS, so the reader never searches.
    # Without them the loader had to string.find each block and then its
    # terminating newline - scanning past a 1.1MB codes block to reach the 2.2MB
    # heights block, and measuring SLOWER (30ms) than parsing the Lua form it
    # replaced. The sizes are known here for free; shipping them turns loading
    # into three string.sub calls at computed offsets.
    head = ("RLNAV2 map=%s tx=%d ty=%d n=%d res=%g x0=%.3f y0=%.3f "
            "zmin=%.4f zstep=%.8f cdlen=%d zqlen=%d laylen=%d"
            % (m["map"], m["tx"], m["ty"], m["n"], m["res"], m["x0"], m["y0"],
               zmin, zstep, len(cd), len(zqs), len(lays)))
    return chr(10).join((head, cd, zqs, lays)) + chr(10)


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("map")
    ap.add_argument("--tile", nargs=2, type=int, metavar=("X", "Y"))
    ap.add_argument("--bounds", nargs=4, type=int, metavar=("X0", "Y0", "X1", "Y1"))
    ap.add_argument("--res", type=float, default=DEFAULT_RES)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--deploy", action="store_true",
                    help="write straight to where the addon reads tiles in game")
    ap.add_argument("--around", nargs=3, type=float, metavar=("X", "Y", "R"),
                    help="world position + radius in tiles, instead of indices")
    args = ap.parse_args(argv[1:])

    print("indexing archives...")
    c = Client()
    tiles = c.tiles(args.map)
    if not tiles:
        print(f"no terrain for {args.map!r}")
        return 1

    LIVE = Path("C:/Ascension/Launcher/resources/ascension-live/Logs/navgrid")
    if args.deploy and not args.out:
        args.out = LIVE

    want = [(t[0], t[1]) for t in tiles]
    if args.around:
        # Pick tiles by WORLD POSITION - the useful way to ask, since that is what
        # a log line gives you. Same axis swap as everywhere: X index runs along
        # world -Y, Y index along world -X.
        wx, wy, rad = args.around
        cy = int((ORIGIN - wx) // TILE)
        cx = int((ORIGIN - wy) // TILE)
        r = int(rad)
        print(f"  world ({wx:.0f},{wy:.0f}) -> tile ({cx},{cy}), radius {r}")
        want = [(tx, ty) for tx, ty in want
                if abs(tx - cx) <= r and abs(ty - cy) <= r]
    elif args.tile:
        want = [(args.tile[0], args.tile[1])]
    elif args.bounds:
        x0, y0, x1, y1 = args.bounds
        want = [(tx, ty) for tx, ty in want if x0 <= tx <= x1 and y0 <= ty <= y1]

    print(f"{args.map}: building {len(want)} tile(s) at {args.res}yd resolution")
    tot_walk = tot_steep = tot_blocked = tot_bytes = tot_bad = 0
    built = 0
    for tx, ty in want:
        r = build_tile(c, args.map, tx, ty, args.res)
        if not r:
            continue
        grid, _zs, m = r
        packed = zlib.compress(bytes(grid), 9)
        tot_walk += m["walk"]; tot_steep += m["steep"]; tot_blocked += m["blocked"]
        tot_bad += m.get("bad_depth", 0)
        if m.get("mean_depth", 0.0) < -WATER_SANITY:
            print(f"  |WARN| {tx},{ty} mean water depth {m['mean_depth']:+.1f}yd - "
                  f"the liquid mapping is putting water UNDER the terrain")
        tot_bytes += len(packed)
        built += 1
        if built <= 8:
            print(f"  {tx:>2},{ty:<2} {m['n']}x{m['n']}  walk={m['walk']:<5} "
                  f"steep={m['steep']:<5} block={m['blocked']:<5} water={m.get('water', 0):<5} "
              f"dood={m.get('doodads', 0):<5} floor={m.get('raised', 0):<5} "
                  f"z {m['zmin']:7.1f}..{m['zmax']:7.1f}  {len(packed):>6}B packed")
        if args.out:
            args.out.mkdir(parents=True, exist_ok=True)
            # RAW is what the addon loads (ReadFile + string.sub, microseconds).
            # The .lua form is kept for tooling and for any client still on the
            # old loader; the addon prefers .dat and falls back automatically.
            # newline="\n" is load-bearing, not style. The default translates
            # every \n to \r\n on Windows, which pushed each declared block
            # length one byte out: the reader sliced one byte long, the first
            # layer cell decoded to -37,945,344, and 9,828 of 31,220 records came
            # out non-monotonic so the binary search silently missed. Written as
            # a real newline in the source it is a SyntaxError instead - which is
            # how the last "rebuild" managed to print ALL FOUR CONTINENTS
            # COMPLETE and exit 0 while building nothing at all.
            (args.out / f"{args.map}_{tx}_{ty}.dat").write_text(
                emit_raw(grid, _zs, m), encoding="ascii", newline="\n")
            (args.out / f"{args.map}_{tx}_{ty}.lua").write_text(
                emit_lua(grid, _zs, m), encoding="ascii", newline="\n")

    if built == 0:
        print("  nothing built")
        return 1
    print(f"\n{built} tiles | walk={tot_walk} steep={tot_steep} blocked={tot_blocked}")
    print(f"packed: {tot_bytes/1024:.1f} KiB  ({tot_bytes/built:.0f} B/tile)")
    print(f"whole-map estimate: {tot_bytes/built*len(tiles)/1024/1024:.1f} MiB "
          f"for {len(tiles)} tiles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

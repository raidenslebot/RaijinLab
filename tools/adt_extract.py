"""Read the client's real terrain out of the MPQ archives.

The addon currently learns the world one raycast at a time, which is why it can
only reason about what it can see and has to guess past render range. The client
already knows: every ADT tile carries an exact heightmap, and the archives on disk
hold 17634 of them across 267 maps.

This extracts that into a walkability grid - height and slope per sample - which
is the ground truth a real path planner needs. Offline, once, instead of
rediscovering the same hillside on every character.

    python tools/adt_extract.py Azeroth --tile 32 48     # one tile, verbose
    python tools/adt_extract.py Azeroth --out build/     # whole map

COORDINATES. WoW's map is a 64x64 grid of 533.33yd tiles with the origin at the
CENTRE of tile (32,32), and the axes are rotated relative to the tile indices:
a tile's X index runs along world -Y, and its Y index along world -X. Getting this
backwards silently produces a mirrored world that looks plausible, so the MCNK's
own embedded position is used as the authority and the computed value only checks
it.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

DATA = Path(r"C:\Ascension\Launcher\resources\ascension-live\Data")

TILE = 533.33333          # yd per ADT tile
CHUNK = TILE / 16.0       # yd per MCNK (33.333)
UNIT = CHUNK / 8.0        # yd between height samples (4.1666)
ORIGIN = 32.0 * TILE      # world coordinate of tile index 0

# A slope the character can actually run up. WoW's walkable limit is ~50 degrees;
# past that you slide. Kept as a tunable because Ascension alters movement.
MAX_WALK_SLOPE = 50.0


def archives() -> list[Path]:
    order = ["common.MPQ", "common-2.MPQ", "expansion.MPQ", "lichking.MPQ",
             "patch.MPQ", "patch-2.MPQ", "patch-3.MPQ", "patch-4.MPQ", "patch-5.MPQ"]
    base = [DATA / n for n in order if (DATA / n).exists()]
    extra = sorted(p for p in DATA.glob("patch-*.MPQ") if p.name not in order)
    return base + extra


class Client:
    """The archive stack, resolved the way the client resolves it: later patches
    override earlier ones, so the LAST archive defining a path wins."""

    def __init__(self):
        from mpyq import MPQArchive
        self.index: dict[str, object] = {}
        self.open: list = []
        for path in archives():
            try:
                a = MPQArchive(str(path))
                raw = a.read_file("(listfile)")
                if not raw:
                    continue
            except Exception:                          # noqa: BLE001
                continue
            self.open.append(a)
            names = raw.decode("latin-1", errors="replace").replace("\r\n", "\n").split("\n")
            for n in names:
                n = n.strip()
                if n:
                    self.index[n.lower().replace("/", "\\")] = (a, n)

    def read(self, path: str) -> bytes | None:
        hit = self.index.get(path.lower().replace("/", "\\"))
        if not hit:
            return None
        a, real = hit
        try:
            return a.read_file(real)
        except Exception:                              # noqa: BLE001
            return None

    def tiles(self, mapname: str) -> list[tuple[int, int, str]]:
        out = []
        pre = f"world\\maps\\{mapname.lower()}\\{mapname.lower()}_"
        for key, (_a, real) in self.index.items():
            if key.startswith(pre) and key.endswith(".adt"):
                stem = key[len(pre):-4]
                bits = stem.split("_")
                if len(bits) == 2 and all(b.lstrip("-").isdigit() for b in bits):
                    out.append((int(bits[0]), int(bits[1]), real))
        return sorted(out)


def chunks(buf: bytes, start: int = 0, end: int | None = None):
    """Walk an ADT's FourCC chunk list. Magic is stored REVERSED on disk."""
    end = len(buf) if end is None else end
    off = start
    while off + 8 <= end:
        magic = buf[off:off + 4][::-1].decode("latin-1", errors="replace")
        size = struct.unpack_from("<I", buf, off + 4)[0]
        body = off + 8
        if body + size > end:
            break
        yield magic, body, size
        off = body + size


def parse_adt(data: bytes) -> list[dict]:
    """Return one entry per MCNK: its world position and 145 height samples.

    MCVT stores 9x9 outer and 8x8 inner samples interleaved, as deltas from the
    MCNK's own base Z.
    """
    out = []
    for magic, body, size in chunks(data):
        if magic != "MCNK":
            continue
        # MCNK header: flags@0x00, indexX@0x04, indexY@0x08, ofsHeight@0x14,
        # ofsLiquid@0x60, sizeLiquid@0x64, position(x,y,z)@0x68
        flags = struct.unpack_from("<I", data, body + 0x00)[0]
        ix, iy = struct.unpack_from("<2I", data, body + 0x04)
        ofs_height = struct.unpack_from("<I", data, body + 0x14)[0]
        ofs_liquid, size_liquid = struct.unpack_from("<2I", data, body + 0x60)
        px, py, pz = struct.unpack_from("<3f", data, body + 0x68)
        if ofs_height == 0:
            continue
        # ofsHeight is relative to the start of the MCNK chunk (its magic), and
        # points at the MCVT sub-chunk header.
        mcvt = body - 8 + ofs_height
        if mcvt + 8 + 145 * 4 > len(data):
            continue
        tag = data[mcvt:mcvt + 4][::-1].decode("latin-1", errors="replace")
        if tag != "MCVT":
            continue
        heights = struct.unpack_from("<145f", data, mcvt + 8)
        out.append({"x": px, "y": py, "z": pz, "h": heights,
                    "ix": ix, "iy": iy, "flags": flags,
                    "mcnk_body": body, "ofs_liquid": ofs_liquid,
                    "size_liquid": size_liquid})
    return out


def sample_grid(mcnks: list[dict]) -> list[tuple[float, float, float]]:
    """World-space (x, y, z) for every OUTER height sample.

    Only the 9x9 outer grid is used: the 8x8 inner samples sit at cell centres and
    add resolution we do not need for walkability, at 44% more points.
    """
    pts = []
    for c in mcnks:
        base_x, base_y, base_z = c["x"], c["y"], c["z"]
        h = c["h"]
        for row in range(9):
            for col in range(9):
                v = h[row * 17 + col]      # 17 = 9 outer + 8 inner per row pair
                # Within an MCNK, sample (row, col) steps along -X and -Y.
                pts.append((base_x - row * UNIT, base_y - col * UNIT, base_z + v))
    return pts


def slope_of(pts: list[tuple[float, float, float]]) -> tuple[float, float]:
    """Max and mean slope in degrees across neighbouring samples."""
    import math
    if len(pts) < 2:
        return 0.0, 0.0
    by_key = {}
    for x, y, z in pts:
        by_key[(round(x / UNIT), round(y / UNIT))] = z
    worst, total, n = 0.0, 0.0, 0
    for (kx, ky), z in by_key.items():
        for dk in ((1, 0), (0, 1)):
            nz = by_key.get((kx + dk[0], ky + dk[1]))
            if nz is not None:
                deg = math.degrees(math.atan2(abs(nz - z), UNIT))
                worst = max(worst, deg)
                total += deg
                n += 1
    return worst, (total / n if n else 0.0)


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("map")
    ap.add_argument("--tile", nargs=2, type=int, metavar=("X", "Y"))
    ap.add_argument("--limit", type=int, default=6)
    args = ap.parse_args(argv[1:])

    print("indexing archives...")
    c = Client()
    print(f"  {len(c.index)} unique paths across {len(c.open)} archives")

    tiles = c.tiles(args.map)
    if not tiles:
        print(f"no ADT tiles for map {args.map!r}")
        return 1
    print(f"{args.map}: {len(tiles)} tiles, x {min(t[0] for t in tiles)}..{max(t[0] for t in tiles)}"
          f"  y {min(t[1] for t in tiles)}..{max(t[1] for t in tiles)}")

    if args.tile:
        tiles = [t for t in tiles if (t[0], t[1]) == (args.tile[0], args.tile[1])]
        if not tiles:
            print("that tile is not present")
            return 1

    shown = 0
    for tx, ty, real in tiles:
        if shown >= args.limit:
            break
        data = c.read(real)
        if not data:
            continue
        mcnks = parse_adt(data)
        if not mcnks:
            print(f"  {tx:>2},{ty:<2} no MCNK heights (empty/water tile?)")
            continue
        pts = sample_grid(mcnks)
        zs = [p[2] for p in pts]
        worst, mean = slope_of(pts)
        # Cross-check the embedded position against the documented tile mapping:
        # a mismatch means the coordinate convention is wrong, which produces a
        # mirrored world that still looks plausible.
        exp_x = ORIGIN - ty * TILE
        exp_y = ORIGIN - tx * TILE
        got_x = max(p[0] for p in pts)
        got_y = max(p[1] for p in pts)
        ok = abs(got_x - exp_x) < TILE and abs(got_y - exp_y) < TILE
        print(f"  {tx:>2},{ty:<2} mcnk={len(mcnks):<4} pts={len(pts):<6} "
              f"z {min(zs):8.1f}..{max(zs):8.1f}  slope max={worst:5.1f} mean={mean:4.1f}  "
              f"origin {'OK' if ok else 'MISMATCH'} ({got_x:.0f},{got_y:.0f} vs {exp_x:.0f},{exp_y:.0f})")
        shown += 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))


def parse_mh2o(data: bytes):
    """WotLK liquid data: 256 per-chunk entries (offset_instances, layer_count,
    offset_attributes), offsets relative to the MH2O body. Each 24-byte instance:
    liquidType, LVF, minLevel, maxLevel, xOff, yOff, width, height, ofsMask,
    ofsVerts. Returns a 256-list of instance lists, or None when absent."""
    for magic, body, size in chunks(data):
        if magic != "MH2O":
            continue
        out = [[] for _ in range(256)]
        for i in range(256):
            off_inst, layers, _attr = struct.unpack_from("<3I", data, body + i * 12)
            if off_inst == 0 or layers == 0:
                continue
            for L in range(min(layers, 4)):
                o = body + off_inst + L * 24
                if o + 24 > len(data):
                    break
                lt, _lvf, mn, mx, xo, yo, w, h, _om, _ov = struct.unpack_from(
                    "<HH2f4B2I", data, o)
                out[i].append({"type": lt, "min": mn, "max": mx,
                               "xo": xo, "yo": yo, "w": w, "h": h})
        return out
    return None


def mclq_level(data: bytes, m: dict):
    """Pre-WotLK per-MCNK liquid, kept as a fallback: some converted tiles still
    carry MCLQ instead of MH2O. Reads only the min/max level floats; the 9x9
    vertex grid is skipped, so the whole chunk is treated as one water level.
    Handles both raw and chunk-headered MCLQ (the magic is optional on disk)."""
    if m["size_liquid"] <= 8 or m["ofs_liquid"] == 0:
        return None
    o = m["mcnk_body"] - 8 + m["ofs_liquid"]
    if o + 16 > len(data):
        return None
    tag = data[o:o + 4][::-1]
    if tag == b"MCLQ":
        o += 8
    mn, mx = struct.unpack_from("<2f", data, o)
    if mx < -100000 or mx > 100000:
        return None
    return mx

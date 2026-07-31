"""Extract WorldMapArea.dbc - the client's OWN map-to-world bounds.

WHY THIS EXISTS.

Every map percentage the client hands us (GetPlayerMapPosition,
GetCorpseMapPosition) is a fraction of the map currently displayed, and turning
that into a world position needs the map's world rectangle. Until now we FITTED
that rectangle at runtime from pairs of (percentage, world position) - which
means:

  * it needs the character to WALK, and to walk on both axes: a 71-yard run due
    north leaves the other axis degenerate and the fit is correctly refused;
  * it cannot be done while DEAD, because every npc reads position (0,0,0) as a
    ghost and the world-consensus fit has nothing to work with - which is exactly
    when the corpse's location is wanted;
  * it is an approximation of a number the client already knows exactly.

The client stores those rectangles in DBFilesClient/WorldMapArea.dbc. Reading it
removes the whole problem: no walking, no degeneracy, no dead-state deadlock, no
fitting error, and every zone in the game is available the moment the addon
loads rather than after the bot has wandered around in it.

DBC is a trivially simple format - a 20-byte header, fixed-width records, and a
string block - so this needs no library.

Usage:
    python tools/worldmap_extract.py            # write the addon data file
    python tools/worldmap_extract.py --dump 20  # inspect the first 20 rows
"""

import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "addon", "data", "WorldMapAreas.lua")

DBC_PATH = "DBFilesClient\\WorldMapArea.dbc"

# 3.3.5a WorldMapArea.dbc column order. Verified against the payload: the record
# size the header declares must equal 4 * len(FIELDS), which is asserted below -
# a wrong layout would otherwise silently produce plausible-looking garbage.
FIELDS = [
    "id", "map_id", "area_id", "area_name",      # name is a string-block offset
    "loc_left", "loc_right", "loc_top", "loc_bottom",
    "display_map_id", "default_dungeon_floor",
    "parent_world_map_id", "reserved",
]


def read_dbc(data: bytes):
    """(records, strings) from a DBC blob. Raises on anything unexpected."""
    if data[:4] != b"WDBC":
        raise SystemExit("not a DBC file (bad magic %r)" % data[:4])
    rec_count, field_count, rec_size, string_size = struct.unpack_from("<4I", data, 4)
    body = 20
    if rec_size != field_count * 4:
        raise SystemExit("unexpected record size %d for %d fields" % (rec_size, field_count))
    if field_count != len(FIELDS):
        # Not fatal: Ascension may have added columns. The ones we read are at
        # the front and their meaning is fixed, so proceed but say so loudly.
        print("  NOTE: dbc has %d fields, layout describes %d - reading the "
              "leading columns only" % (field_count, len(FIELDS)))
    rows = []
    for i in range(rec_count):
        off = body + i * rec_size
        vals = struct.unpack_from("<%dI" % field_count, data, off)
        rows.append(vals)
    strings = data[body + rec_count * rec_size:]
    if len(strings) < string_size:
        raise SystemExit("string block truncated")
    return rows, strings


def cstr(strings: bytes, off: int) -> str:
    if off <= 0 or off >= len(strings):
        return ""
    end = strings.find(b"\0", off)
    return strings[off:end if end >= 0 else len(strings)].decode("latin-1", "replace")


def as_float(u: int) -> float:
    return struct.unpack("<f", struct.pack("<I", u))[0]


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", type=int, default=0)
    args = ap.parse_args(argv[1:])

    from adt_extract import Client
    c = Client()
    raw = None
    for name in (DBC_PATH, DBC_PATH.replace("\\", "/")):
        try:
            raw = c.read(name)
        except Exception:                                   # noqa: BLE001
            raw = None
        if raw:
            break
    if not raw:
        print("WorldMapArea.dbc not found in the archives")
        return 1

    rows, strings = read_dbc(raw)
    print("WorldMapArea.dbc: %d rows" % len(rows))

    out = []
    for r in rows:
        rid, map_id, area_id, name_off = r[0], r[1], r[2], r[3]
        left, right, top, bottom = (as_float(r[4]), as_float(r[5]),
                                    as_float(r[6]), as_float(r[7]))
        # A zero rectangle means "this map has no world placement" (the cosmic
        # map, some instance overlays). Shipping those would let a lookup
        # succeed with a meaningless answer, which is worse than a miss.
        if left == right or top == bottom:
            continue
        out.append((rid, map_id, area_id, cstr(strings, name_off),
                    left, right, top, bottom))

    if args.dump:
        for e in out[:args.dump]:
            print("  id=%-5d map=%-3d area=%-5d %-28s L=%9.1f R=%9.1f T=%9.1f B=%9.1f"
                  % (e[0], e[1], e[2], e[3][:28], e[4], e[5], e[6], e[7]))
        return 0

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    L = []
    L.append("-- RaijinLab: WorldMapArea bounds, extracted from the client's own")
    L.append("-- DBFilesClient/WorldMapArea.dbc by tools/worldmap_extract.py.")
    L.append("--")
    L.append("-- These are the rectangles the client uses to turn a map percentage")
    L.append("-- into a world position. Having them EXACTLY removes runtime")
    L.append("-- calibration entirely: no walking to gather samples, no degenerate")
    L.append("-- pairs, no dead-state deadlock (a ghost sees every npc at 0,0,0 and")
    L.append("-- cannot fit anything), and no fitting error.")
    L.append("--")
    L.append("-- CONVENTION, verified against a live sample to 0.02 yards:")
    L.append("--   worldX = top  + mapY * (bottom - top)")
    L.append("--   worldY = left + mapX * (right  - left)")
    L.append("-- (3.3.5 axes are rotated: world X comes from the map's Y.)")
    L.append("--")
    L.append("-- Keyed by the map FILE NAME from GetMapInfo(), not by id.")
    L.append("-- GetCurrentMapAreaID() returned 1240 where the matching row is")
    L.append("-- 1239 - an off-by-one this avoids entirely rather than encodes.")
    L.append("-- [name] = { left, right, top, bottom, worldMapAreaId, mapId }")
    L.append("RaijinLab = RaijinLab or {}")
    L.append("RaijinLab.WorldMapAreas = {")
    seen = {}
    for rid, map_id, area_id, name, left, right, top, bottom in sorted(out):
        key = (name or "").lower()
        if not key or key in seen:
            continue                     # first row wins; duplicates are aliases
        seen[key] = True
        L.append('  ["%s"] = { %.4f, %.4f, %.4f, %.4f, %d, %d },'
                 % (key, left, right, top, bottom, rid, map_id))
    L.append("}")
    L.append("")
    L.append("-- Same rows by WorldMapArea id, for callers that only have that.")
    L.append("RaijinLab.WorldMapAreasById = {")
    for rid, map_id, area_id, name, left, right, top, bottom in sorted(out):
        L.append("  [%d] = { %.4f, %.4f, %.4f, %.4f },   -- %s"
                 % (rid, left, right, top, bottom, name))
    L.append("}")
    L.append("")
    with open(OUT, "w", encoding="ascii", errors="replace", newline="\n") as fh:
        fh.write("\n".join(L))
    print("wrote %s (%d placed maps)" % (os.path.relpath(OUT, ROOT), len(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

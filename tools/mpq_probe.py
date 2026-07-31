"""Can we read the client's own map geometry? Everything downstream depends on it.

The addon currently learns terrain by raycasting what it can see, which is why
navigation guesses past render range. The client ships the truth: ADT terrain,
WMO buildings and M2 doodads live in the MPQ archives on disk. If we can read
those we can build a real navmesh offline, once, instead of rediscovering the
world one raycast at a time.

    python tools/mpq_probe.py            # what is in the archives
    python tools/mpq_probe.py <MapName>  # tiles for one map
"""
from __future__ import annotations

import sys
from pathlib import Path

DATA = Path(r"C:\Ascension\Launcher\resources\ascension-live\Data")

# Later patches override earlier archives, so read order matters: the LAST
# archive to define a path wins, exactly as the client resolves it.
ORDER = ["common.MPQ", "common-2.MPQ", "expansion.MPQ", "lichking.MPQ",
         "patch.MPQ", "patch-2.MPQ", "patch-3.MPQ", "patch-4.MPQ", "patch-5.MPQ"]


def archives() -> list[Path]:
    found = [DATA / n for n in ORDER if (DATA / n).exists()]
    # Ascension ships many custom patches; take them in sorted order after the
    # stock ones so custom maps and edited terrain win.
    extra = sorted(p for p in DATA.glob("patch-*.MPQ") if p.name not in ORDER)
    return found + extra


def open_archive(path: Path):
    from mpyq import MPQArchive
    return MPQArchive(str(path))


def listfile(a) -> list[str]:
    try:
        raw = a.read_file("(listfile)")
    except Exception:                                 # noqa: BLE001
        return []
    if not raw:
        return []
    text = raw.decode("latin-1", errors="replace")
    return [ln.strip() for ln in text.replace("\r\n", "\n").split("\n") if ln.strip()]


def main(argv) -> int:
    want_map = argv[1] if len(argv) > 1 else None
    total_adt = 0
    per_map: dict[str, int] = {}
    wmo = m2 = 0

    for path in archives():
        try:
            a = open_archive(path)
        except Exception as e:                        # noqa: BLE001
            print(f"  {path.name:<18} OPEN FAILED: {str(e)[:70]}")
            continue
        names = listfile(a)
        if not names:
            print(f"  {path.name:<18} no (listfile) - contents not enumerable")
            continue
        adts = [n for n in names if n.lower().endswith(".adt")]
        wmo += sum(1 for n in names if n.lower().endswith(".wmo"))
        m2 += sum(1 for n in names if n.lower().endswith((".m2", ".mdx")))
        total_adt += len(adts)
        for n in adts:
            parts = n.replace("/", "\\").split("\\")
            if len(parts) >= 3:
                per_map[parts[2]] = per_map.get(parts[2], 0) + 1
        print(f"  {path.name:<18} files={len(names):<7} adt={len(adts)}")

    print(f"\ntotal ADT tiles: {total_adt}   WMO: {wmo}   M2/MDX: {m2}")
    print(f"maps with terrain: {len(per_map)}")
    for name, n in sorted(per_map.items(), key=lambda kv: -kv[1])[:14]:
        print(f"   {name:<28} {n} tiles")

    if want_map:
        print(f"\n--- extracting one tile of {want_map} ---")
        for path in reversed(archives()):
            try:
                a = open_archive(path)
            except Exception:                         # noqa: BLE001
                continue
            for n in listfile(a):
                low = n.lower().replace("/", "\\")
                if low.endswith(".adt") and f"\\{want_map.lower()}\\" in low:
                    data = a.read_file(n)
                    if data:
                        print(f"   {n}  ({len(data)} bytes) from {path.name}")
                        print(f"   magic={data[:4]!r}  (ADT chunks are FourCC, reversed)")
                        return 0
        print("   not found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

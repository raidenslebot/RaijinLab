"""RE round 4: find the client's actual cast-facing check.

- Find xrefs to GetFacing (0x6E6FC0) — the function the client calls when it
  needs the player's facing for a cast check.
- Find the atan2 helper and 'HasInArc' style code near the cast check.
"""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32, CsError

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

TEXT_START, TEXT_END = 0x401000, 0x9DE3B2


def va_to_off(va):
    return pe.get_offset_from_rva(va - base)


def dump(va, before=12, after=140, label=""):
    try:
        off = va_to_off(va)
    except Exception:
        print(f"  (cannot map {hex(va)})")
        return
    start = max(0, off - before)
    code = data[start:off + after]
    for ins in md.disasm(code, va - before):
        print(f"    {hex(ins.address)}: {ins.mnemonic:8s} {ins.op_str}")


def xrefs_to(va):
    ab = (va & 0xFFFFFFFF).to_bytes(4, "little")
    refs = []
    i = 0
    while True:
        i = data.find(ab, i)
        if i == -1:
            break
        rva = pe.get_rva_from_offset(i)
        if TEXT_START <= rva < TEXT_END:
            refs.append(base + rva)
        i += 1
    return refs


GETFACING = 0x6E6FC0
print("=== xrefs to GetFacing 0x6E6FC0 ===")
refs = xrefs_to(GETFACING)
print("count:", len(refs))
for r in refs[:40]:
    print(f"  {hex(r)}")

print()
print("=== dump around first few call sites ===")
for r in refs[:6]:
    print(f"--- {hex(r)} ---")
    dump(r - 24, 24, 60)
    print()

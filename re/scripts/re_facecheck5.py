"""RE round 5: find the client's actual facing check for casting.

SPELL_FAILED_NOT_INFRONT enum = 21 in 3.3.5. The debug string table at
0xA43000 has the name; find code that references the NOT_INFRONT name entry
(0xA43044-ish) and then find the spell-failure path. Also disassemble the
vtable GetFacing callers.
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


def read_cstr(va, maxlen=80):
    try:
        off = va_to_off(va)
    except Exception:
        return None
    end = data.find(b"\x00", off, off + maxlen)
    if end == -1:
        return None
    try:
        return data[off:end].decode("ascii", "replace")
    except Exception:
        return None


def dump(va, before=16, after=160, label=""):
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


# 1. Map the SPELL_FAILED name table: 0xA43000 region. Find the pointer to
# "NOT_INFRONT" (0xA43049) - any code that references the failure enum 21
# (0x15) near a facing read is the check.
print("=== NOT_INFRONT name ptr refs (0xA43044) ===")
for cand in (0xA43044, 0xA43049, 0xA43040):
    refs = xrefs_to(cand)
    print(f"  refs to {hex(cand)} ({read_cstr(cand)!r}): {[hex(r) for r in refs[:20]]}")

# 2. The client's cast check: Spell::CheckCast in 3.3.5 has a facing check.
# Look for the classic pattern: get target, compute angle, compare to facing.
# The facing check in 3.3.5 client typically compares against M_PI (3.14159)
# or a half-arc. Search for functions that call the vtable GetFacing slot
# 0x14C. Hard via byte scan; instead find atan2 imports used near facing.
# 3.3.5 atan2 thunk - find by searching for the double 3.141592653589793 in
# .text (M_PI used in facing checks).
print()
print("=== M_PI constant references (float 3.1415927) in .text ===")
import struct
pi = struct.pack("<f", 3.1415927)
refs = []
i = 0
while True:
    i = data.find(pi, i)
    if i == -1:
        break
    rva = pe.get_rva_from_offset(i)
    if TEXT_START <= rva < TEXT_END:
        refs.append(base + rva)
    i += 1
print("  M_PI(3.1415927) floats in .text:", len(refs), [hex(r) for r in refs[:30]])

# 3. Half-arc 90deg = 1.5707963
halfpi = struct.pack("<f", 1.5707963)
refs = []
i = 0
while True:
    i = data.find(halfpi, i)
    if i == -1:
        break
    rva = pe.get_rva_from_offset(i)
    if TEXT_START <= rva < TEXT_END:
        refs.append(base + rva)
    i += 1
print("  1.5707963 floats in .text:", len(refs), [hex(r) for r in refs[:30]])

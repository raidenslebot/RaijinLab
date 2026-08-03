"""RE the client's REAL cast-facing check (SPELL_FAILED_NOT_INFRONT).

The user's hard truth: the client NEVER auto-faces and DOES refuse
"target needs to be in front of you" (SPELL_FAILED_NOT_INFRONT) on casts.
This script:
  1. verifies GetFacing (claimed 0x6E6FC0 -> fld [ecx+0x7AC]; ret)
  2. finds SPELL_FAILED_NOT_INFRONT string + its error text
  3. traces xrefs to the string to find the exact facing-check function
  4. disassembles that function to learn the REAL arc / how it compares
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


def dump(va, before=16, after=96, label=""):
    try:
        off = va_to_off(va)
    except Exception:
        print(f"  (cannot map {hex(va)})")
        return
    start = max(0, off - before)
    code = data[start:off + after]
    try:
        for ins in md.disasm(code, va - before):
            print(f"    {hex(ins.address)}: {ins.mnemonic:8s} {ins.op_str}")
    except CsError as e:
        print(f"    disasm err {e}")


def find_str(s):
    b = s.encode("ascii")
    hits = []
    i = data.find(b)
    while i != -1:
        hits.append(base + pe.get_rva_from_offset(i))
        i = data.find(b, i + 1)
    return hits


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


print("=== 1. GetFacing @ claimed 0x6E6FC0 ===")
dump(0x6E6FC0, 0, 24, "GetFacing")
print()

print("=== 1b. CGUnit_C__GetFacing @ 0x7B9DE0 (discovery_raw) ===")
dump(0x7B9DE0, 0, 48, "CGUnit GetFacing")
print()

print("=== 2. SPELL_FAILED_NOT_INFRONT string refs ===")
for s in ["NOT_INFRONT", "target needs to be in front", "must be in front",
          "facing the wrong way", "in front of you"]:
    hits = find_str(s)
    print(f"  {s!r}: {[hex(h) for h in hits[:6]]}")

# The classic 3.3.5 error string: "Your target needs to be in front of you."
# SPELL_FAILED_NOT_INFRONT enum value = 21 in 3.3.5.
# Try the localized enum string used by the client's spell failure table.
for s in ["Target needs to be in front of you", "Your target needs to be in front of you",
          "You are facing the wrong way"]:
    hits = find_str(s)
    print(f"  full: {s!r}: {[hex(h) for h in hits[:6]]}")
print()

print("=== 3. xrefs to SPELL_FAILED_NOT_INFRONT string 0xA4303C ===")
refs = xrefs_to(0xA4303C)
print("  refs:", [hex(r) for r in refs[:20]])
for r in refs[:4]:
    print(f"  --- before xref {hex(r)} ---")
    dump(r - 8, 8, 96, f"before {hex(r)}")
print()

print("=== 4. search for HasInArc-like math: atan2 call sites near facing reads ===")
# Common client pattern: fld [ecx+0x7AC] then a call to atan2 (0x8E5C10 etc).
# Instead scan for the vtable GetFacing offset usage 0x14C in call sites.
refs_14c = xrefs_to(0x14C)  # offset constant, too noisy; skip
print("  (offset 0x14C refs skipped - too noisy)")

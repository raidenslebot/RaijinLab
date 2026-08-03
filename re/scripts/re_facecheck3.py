"""RE round 2: find the strings near 0xA4280A / 0xA43049 and trace xrefs to the
real cast-facing check that emits SPELL_FAILED_NOT_INFRONT."""
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


def read_cstr(va, maxlen=200):
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


def dump(va, before=16, after=120, label=""):
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


print("=== strings near NOT_INFRONT refs ===")
for va in (0xA4280A, 0xA43049):
    s = read_cstr(va - 0x40)
    print(f"  {hex(va)} -> {s!r}")
    print(f"  cstr@: {read_cstr(va)!r}")
    print(f"  xrefs: {[hex(r) for r in xrefs_to(va)[:20]]}")
    print()

# Also dump what is around 0xA4303C (the enum used in original script)
print("=== around 0xA4303C ===")
for off in range(0, 0x80, 0x10):
    s = read_cstr(0xA43000 + off)
    if s and len(s) > 2:
        print(f"  0xA43000+{off:02x}: {s!r}")

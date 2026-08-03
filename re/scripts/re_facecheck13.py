"""RE round 13: dump the FULL real GetFacing 0x731260 to find the actual
facing field it reads and returns."""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True


def va_to_off(va):
    return pe.get_offset_from_rva(va - base)


def dump(va, length=600, label=""):
    try:
        off = va_to_off(va)
    except Exception:
        print(f"  (cannot map {hex(va)})")
        return
    code = data[off:off + length]
    print(f"  -- {label} {hex(va)} ({length}b) --")
    for ins in md.disasm(code, va):
        # annotate fld / fstp / ret
        ann = ""
        if ins.mnemonic.startswith("fld") or ins.mnemonic.startswith("fstp") \
           or ins.mnemonic == "ret":
            ann = "   <<<<"
        print(f"    {hex(ins.address)}: {ins.mnemonic:8s} {ins.op_str}{ann}")


print("=== REAL GetFacing 0x731260 (full) ===")
dump(0x731260, 700, "GetFacing-real")

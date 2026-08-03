"""RE round 14: continue 0x731260 from 0x7314a9 to find where it reads the
facing field and returns it. Focus on fld/fstp near the end + the main return."""
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


def dump(va, length=420, label=""):
    try:
        off = va_to_off(va)
    except Exception:
        print(f"  (cannot map {hex(va)})")
        return
    code = data[off:off + length]
    print(f"  -- {label} {hex(va)} --")
    for ins in md.disasm(code, va):
        ann = ""
        if ins.mnemonic.startswith("fld") or ins.mnemonic.startswith("fstp") \
           or ins.mnemonic == "ret":
            ann = "   <<<<"
        print(f"    {hex(ins.address)}: {ins.mnemonic:8s} {ins.op_str}{ann}")


print("=== 0x731260 tail (from 0x7314a9) ===")
dump(0x7314a9, 420, "tail")

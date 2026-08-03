"""RE round 8: disassemble the GetPlayerFacing handler 0x60A490 to find the EXACT
facing field/pointer the client uses."""
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


def dump(va, before=8, after=220, label=""):
    try:
        off = va_to_off(va)
    except Exception:
        print(f"  (cannot map {hex(va)})")
        return
    start = max(0, off - before)
    code = data[start:off + after]
    for ins in md.disasm(code, va - before):
        print(f"    {hex(ins.address)}: {ins.mnemonic:8s} {ins.op_str}")


print("=== GetPlayerFacing handler 0x60A490 ===")
dump(0x60A490, 0, 260)
print()

# Follow the call targets to find which vtable/field is read
print("=== also dump 0x60A490 fully up to 0x500 bytes ===")
dump(0x60A490, 0, 500)

"""RE round 11: disassemble ClntObjMgrObjectPtr (0x4D4DB0) to learn the real
signature. The client's GetPlayerFacing calls it with 5 args:
    push 0x1231; push 0xa22cd4; push 1; push hi; push lo; call 0x4d4db0
The runtime calls it with 3 args (lo, hi, mask). If the real function uses
more args, the runtime's call returns a different/wrong object.
"""
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


def dump(va, before=8, after=320, label=""):
    try:
        off = va_to_off(va)
    except Exception:
        print(f"  (cannot map {hex(va)})")
        return
    start = max(0, off - before)
    code = data[start:off + after]
    print(f"  -- {label} {hex(va)} --")
    for ins in md.disasm(code, va - before):
        print(f"    {hex(ins.address)}: {ins.mnemonic:8s} {ins.op_str}")


print("=== ClntObjMgrObjectPtr 0x4D4DB0 (full, 320 bytes) ===")
dump(0x4D4DB0, 0, 320, "ObjectPtr")

print()
print("=== 0x4D4BB0 hash (pre type-mask, thiscall) ===")
dump(0x4D4BB0, 0, 160, "HashLookup")

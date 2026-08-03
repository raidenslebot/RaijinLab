"""RE round 10: disassemble GetPlayerFacing handler 0x60A490 in full to learn
the EXACT player-pointer resolution the client uses (camera -> GUID ->
ClntObjMgrObjectPtr), then confirm 0x7AC via the vtable slot 0x34."""
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


def dump(va, before=8, after=200, label=""):
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


# GetPlayerFacing handler from the command table
print("=== GetPlayerFacing handler 0x60A490 (full) ===")
dump(0x60A490, 0, 240, "GetPlayerFacing")
print()

# GetCamera thunk 0x4F5960 - returns camera ptr in eax
print("=== GetCamera 0x4F5960 ===")
dump(0x4F5960, 0, 40, "GetCamera")
print()

# ClntObjMgrObjectPtr 0x4D4DB0 - global object lookup
print("=== ClntObjMgrObjectPtr 0x4D4DB0 (prologue) ===")
dump(0x4D4DB0, 0, 60, "ClntObjMgrObjectPtr")

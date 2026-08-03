"""RE round 12: disassemble the REAL GetFacing (vtable byte+0x34 = slot 0x0D
= 0x731260). The client's GetPlayerFacing does:
    mov edx, [eax]        ; vtable
    mov eax, [edx + 0x34] ; vtable BYTE offset 0x34 = slot 0x0D
    call eax              ; -> the real GetFacing
My earlier RE wrongly treated 0x34 as a slot index; it is a BYTE offset.
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


def dump(va, before=8, after=96, label=""):
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


print("=== REAL GetFacing: vtable[0x0D] = 0x731260 ===")
dump(0x731260, 0, 64, "GetFacing-real")
print()

# Verify the vtable slot again - confirm 0x731260 sits at vtable byte 0x34
off = va_to_off(0xA32744)
import struct
for k in range(0x30, 0x40, 4):
    v = struct.unpack("<I", data[off + k:off + k + 4])[0]
    print(f"  vtable 0xA32744 +0x{k:02x} (slot {k//4:02x}): 0x{v:08X}")

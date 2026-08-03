"""RE round 15: complete 0x731260 (last ~80 bytes) + find the fld [reg+off]
that returns the facing. Also check what 0x4D3790 does (the first call)."""
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


def dump(va, length, label=""):
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


print("=== 0x731260 very end (0x7315e0-0x731630) ===")
dump(0x7315e0, 100, "end")

print()
print("=== 0x4D3790 (first call in GetFacing) ===")
dump(0x4D3790, 80, "0x4D3790")

print()
print("=== candidate simple getters near 0x6E6FC0 (slot 0x0D of another vtable) ===")
# Check the OTHER vtable 0xA34EA8-ish: refs were 0xa32814 and 0xa34edc
# vtable containing 0xa34edc at byte 0x34 => vtable start 0xa34ea8
off = va_to_off(0xA34EA8)
import struct
print("  vtable 0xA34EA8 slots 0x0-0x14:")
for k in range(0, 0x54, 4):
    v = struct.unpack("<I", data[off + k:off + k + 4])[0]
    print(f"    v+0x{k:02x} (slot {k//4:02x}): 0x{v:08X}")

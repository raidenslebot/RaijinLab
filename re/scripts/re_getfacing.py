"""Verify GetFacing (0x6E6FC0) — what field does it actually read? And dump
the player vtable region (0xA34EA8) around slot 0x0D to confirm."""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

def va_to_off(va):
    return pe.get_offset_from_rva(va - base)

def disasm(va, n, label=""):
    print(f"\n=== {label or hex(va)} ===")
    off = va_to_off(va)
    count = 0
    for insn in md.disasm(data[off:], va):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        count += 1
        if count >= n:
            break

disasm(0x6E6FC0, 30, "GetFacing 0x6E6FC0 (what field?)")

# dump player vtable 0xA34EA8 slot 0x0D (offset 0x34)
print("\n=== player vtable 0xA34EA8 slots ===")
off = va_to_off(0xA34EA8)
import struct
for i in range(0x0B, 0x10):
    v = struct.unpack_from('<I', data, off + i*4)[0]
    print(f"  slot {i:#04x} (off {i*4:#04x}): 0x{v:08X}")

"""Find the 0x50500000 source + disassemble the final pre-commit gate 0x80c790.
0x50500000 is what Spell_C's eax holds when it returns al=0 (refused)."""
from pathlib import Path
import pefile
import struct
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

def va_to_off(va):
    return pe.get_offset_from_rva(va - base)

def dump_range(start, end, label=""):
    print(f"\n=== {label or hex(start)} .. {hex(end)} ===")
    off = va_to_off(start)
    for insn in md.disasm(data[off:off + (end - start)], start):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")

# Search .text for the dword 0x50500000 (and related masks)
print("=== .text search for 0x50500000 / 0xF0500000 / 0x50000000 ===")
text_off = pe.get_offset_from_rva(0x401000 - base)
text_len = 0x9DE3B2 - 0x401000
text = data[text_off:text_off+text_len]
for val in (0x50500000, 0xF0500000, 0x50000000, 0x00500000):
    pat = struct.pack('<I', val)
    idx = 0; n = 0
    while True:
        idx = text.find(pat, idx)
        if idx < 0: break
        if n < 12:
            print(f"  0x{val:08X} at code va {hex(0x401000 + idx)}")
        n += 1; idx += 1
    print(f"  0x{val:08X}: {n} total")

dump_range(0x80C790, 0x80C950, "0x80C790 final pre-commit gate")

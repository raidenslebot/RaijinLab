"""Disassemble 0x801650 — the function that computes a spell's numeric
min/max range — to find the correct SpellRange table + offsets."""
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

va = 0x801650
off = va_to_off(va)
count = 0
for insn in md.disasm(data[off:off+700], va):
    print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
    count += 1
    if count >= 130:
        break

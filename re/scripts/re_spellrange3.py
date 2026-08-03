"""Disassemble the GetSpellInfo handler 0x540B80..0x540D60 aligned, hunting for
numeric range reads (the min/max range values pushed to Lua)."""
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

va = 0x540B80
off = va_to_off(va)
for insn in md.disasm(data[off:off+1000], va):
    op = insn.op_str
    interesting = ("ad489" in op or "0xad48" in op or insn.mnemonic == "fld"
                   or insn.mnemonic == "fstp" or insn.mnemonic == "div"
                   or insn.mnemonic == "call" or "0x84e3" in op
                   or "84e3" in op)
    if insn.address >= 0x540BE9 or interesting:
        print(f"  {hex(insn.address)}: {insn.mnemonic} {op}")

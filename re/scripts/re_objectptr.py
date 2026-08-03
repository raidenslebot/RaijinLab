"""Disassemble ObjectPtr 0x4D4DB0 — how many args does it READ from the stack?
If it reads 4-5 args, CallObjectPtr3 (3 pushes) leaves garbage in the upper
slots and resolves the WRONG object (explaining face=0 while the client reads
a real facing)."""
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

va = 0x4D4DB0
off = va_to_off(va)
count = 0
print(f"=== ObjectPtr 0x4D4DB0 ===")
for insn in md.disasm(data[off:], va):
    print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
    count += 1
    if count >= 120 or insn.mnemonic == "ret":
        break

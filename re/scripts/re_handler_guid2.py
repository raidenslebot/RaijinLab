"""Dump the CastSpellByID handler 0x53E060..0x53E180 FULLY (the function that
calls 0x80DA40 at 0x53E177), showing how [ebp-8]/[ebp-4] are set and whether
they are GUID values or pointers."""
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

start = 0x53E060
end = 0x53E185
off = va_to_off(start)
print(f"=== CastSpellByID handler {hex(start)}..{hex(end)} FULL ===")
for insn in md.disasm(data[off:va_to_off(end)], start):
    mark = "   <== CALL 0x80DA40" if insn.address + insn.size == 0x53E177 else ""
    print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}{mark}")

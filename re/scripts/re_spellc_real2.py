"""Disassemble 0x80CCE0 from instruction ~200 onward, hunting for every use of
[ebp+0x14] / [ebp+0x18] (the target GUID args) and [ebp+0x1C]/[ebp+0x20].
Also print any reference to the args in a compact way."""
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

va = 0x80CCE0
off = va_to_off(va)
insns = []
for insn in md.disasm(data[off:], va):
    insns.append(insn)
    if len(insns) >= 700:
        break

# print all instructions that reference the arg offsets or that are calls,
# from instruction 180 to the end, to find GUID arg usage.
for i, insn in enumerate(insns):
    if i < 175:
        continue
    op = insn.op_str
    interesting = ("ebp + 0x14" in op or "ebp + 0x18" in op or "ebp + 0x10" in op
                   or "ebp + 0x1c" in op or "ebp + 0x20" in op
                   or insn.mnemonic in ("call", "ret"))
    if interesting:
        print(f"  {hex(insn.address)}: {insn.mnemonic} {op}")

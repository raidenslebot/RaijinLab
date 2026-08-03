"""Dump the REST of 0x60ABF0 (from instruction 90 on) to find GUID-string
(0x...) handling and the string constants it compares against."""
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

def get_cstr(va, maxlen=40):
    off = va_to_off(va)
    out = bytearray()
    for i in range(maxlen):
        b = data[off+i]
        if b == 0:
            break
        out.append(b)
    try:
        return out.decode('latin1')
    except Exception:
        return repr(bytes(out))

# Print the string constants referenced in 0x60ABF0
for s in (0x9F6F4C, 0xA22DA8, 0x9FF164):
    print(f"str@{hex(s)}: {get_cstr(s)!r}")

va = 0x60ABF0
off = va_to_off(va)
insns = []
for insn in md.disasm(data[off:], va):
    insns.append(insn)
    if len(insns) >= 260:
        break

for i, insn in enumerate(insns):
    if i < 88:
        continue
    op = insn.op_str
    interesting = ("0x76e780" in op or "0x" in op and ("push" == insn.mnemonic)
                   or insn.mnemonic == "call" or insn.mnemonic == "ret"
                   or "strtoul" in op or "0x60a" in op)
    if insn.mnemonic == "push" or insn.mnemonic == "call" or insn.mnemonic == "ret" or "76e780" in op:
        print(f"  {hex(insn.address)}: {insn.mnemonic} {op}")

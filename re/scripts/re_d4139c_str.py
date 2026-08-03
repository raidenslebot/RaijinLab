"""Dump the strings referenced by the canCast fail path (0x9E1AD0, 0x9E0E50,
0x9E3E90) to identify what [0xD4139C] is, and disassemble 0x5191C0 (canCast)
fully."""
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

def get_cstr(va, maxlen=120):
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

for s in (0x9E1AD0, 0x9E0E50, 0x9E3E90, 0x9E14FF, 0x9FF09C):
    print(f"str@{hex(s)}: {get_cstr(s)!r}")

print("\n=== canCast 0x5191C0 full ===")
off = va_to_off(0x5191C0)
for i, insn in enumerate(md.disasm(data[off:off+0x500], 0x5191C0)):
    print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
    if i > 180:
        break

from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

path = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = path.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

def dis(va, n=40):
    off = pe.get_offset_from_rva(va - base)
    chunk = data[off:off+120]
    print(f"=== {hex(va)} ===")
    for i, insn in enumerate(md.disasm(chunk, va)):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if i >= n: break

# Enum full + callback call site
dis(0x4D4B30, 50)
print()
# RegisterFunction full
dis(0x817F90, 30)
print()
# lua_setfield
dis(0x84F7A0, 15)
print()
# crash stack RAs
for va in [0x772AB5, 0x8889CE, 0x52B36A]:
    try:
        dis(va - 16, 12)
    except Exception as e:
        print(va, e)

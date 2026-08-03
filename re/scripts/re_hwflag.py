"""Find references to HardwareEventFlag 0x00C21000 in the game and classify
how the cast/action security check reads it. This determines what the runtime
must set (or patch) for casts to be untainted."""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

HW = 0x00C21000
TC = 0x00D4139C
b = HW.to_bytes(4, "little")
b2 = TC.to_bytes(4, "little")

refs = []
i = 0
while True:
    i = data.find(b, i)
    if i == -1: break
    rva = pe.get_rva_from_offset(i)
    if 0x401000 <= rva < 0x9DE3B2:
        refs.append(base + rva)
    i += 1
print("HardwareEventFlag refs in .text:", len(refs))

# Group by function region — print the ones near the cast code (0x80xxxx)
cast_near = [r for r in refs if 0x800000 <= (r-base) <= 0x830000]
print("in 0x80-0x83 cast region:", [hex(r) for r in cast_near])

# Only refs inside code (.text 0x401000-0x9DE3B2), skip data above
code_refs = [r for r in refs if 0x00401000 <= (r - base) < 0x009DE3B2]
print("CODE refs to HW flag:", [hex(r) for r in code_refs])

# print first 15 code refs with surrounding disasm
for va in code_refs[:15]:
    start = va - 24
    soff = pe.get_offset_from_rva(start - base)
    print(f"\n-- {hex(va)} --")
    for insn in md.disasm(data[soff:soff+80], start):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")

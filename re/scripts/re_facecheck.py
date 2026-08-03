"""Find client facing/LOS error strings and disassemble the facing cast check."""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

def find_all(needle):
    b = needle.encode("ascii")
    hits = []
    i = data.find(b)
    while i != -1:
        rva = pe.get_rva_from_offset(i)
        hits.append(base + rva)
        i = data.find(b, i + 1)
    return hits

# xrefs to the string constant 0xa4303c (SPELL_FAILED_NOT_INFRONT)
tgt = 0xa4303c
addr_bytes = tgt.to_bytes(4, "little")
refs = []
i = 0
while True:
    i = data.find(addr_bytes, i)
    if i == -1:
        break
    rva = pe.get_rva_from_offset(i)
    if 0x401000 <= rva < 0x9DE3B2:
        refs.append(base + rva)
    i += 1
print("xrefs to SPELL_FAILED_NOT_INFRONT string:", [hex(r) for r in refs])
for r in refs[:6]:
    dump(r - 8, 20, 200, f"before xref {hex(r)}")

def xrefs_to(va, maxlen=0x200000):
    """Find call/jmp/push references to VA in .text by scanning for the address bytes."""
    addr_bytes = (va).to_bytes(4, "little")
    refs = []
    i = 0
    while True:
        i = data.find(addr_bytes, i)
        if i == -1:
            break
        rva = pe.get_rva_from_offset(i)
        if 0x401000 <= rva < 0x9DE3B2:
            refs.append(base + rva)
        i += 1
    return refs

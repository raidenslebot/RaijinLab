"""Find every 4-byte pointer to 0x00512B00 across the ENTIRE binary (data refs,
vtable entries, handler tables) and disassemble around the recursion sites
0x855B33 / 0x84EC46 / 0x8549A9 to identify the frame functions."""
import struct
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

def rva_of_off(off):
    for sec in pe.sections:
        if sec.PointerToRawData <= off < sec.PointerToRawData + sec.SizeOfRawData:
            return sec.VirtualAddress + (off - sec.PointerToRawData)
    return None

print("=== data refs to 0x00512B00 ===")
raw = struct.pack('<I', 0x00512B00)
idx = 0
found = []
while True:
    idx = data.find(raw, idx)
    if idx < 0:
        break
    rva = rva_of_off(idx)
    secname = "?"
    for sec in pe.sections:
        if sec.PointerToRawData <= idx < sec.PointerToRawData + sec.SizeOfRawData:
            secname = sec.Name.decode().rstrip('\0')
            break
    found.append((base + (rva or 0), secname, idx))
    idx += 1
for va, secname, off in found:
    print(f"  ptr 0x{va:08X} ({secname}) fileoff 0x{off:X}")
print(f"total: {len(found)}")

def fn_start(va):
    off = va_to_off(va)
    lo = max(0x400, off - 0x4000)
    best = None
    for i in range(off - 5, lo, -1):
        if data[i] == 0x55 and data[i+1] == 0x8B and data[i+2] == 0xEC:
            best = i
    if best is None:
        return None
    rva = rva_of_off(best)
    return base + rva if rva else None

def disasm(va, n, label=""):
    print(f"\n=== {label or hex(va)} ===")
    off = va_to_off(va)
    count = 0
    for insn in md.disasm(data[off:], va):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        count += 1
        if count >= n:
            break

for site in (0x855B33, 0x84EC46, 0x8549A9, 0x8569A9):
    s = fn_start(site)
    print(f"\n### function containing {hex(site)} starts at {hex(s) if s else '?'}")
    if s:
        disasm(s, 14, f"prologue of fn@{hex(s)}")

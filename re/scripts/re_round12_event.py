"""Round 12: find who fires PLAYER_TARGET_CHANGED (string at 0xA2295C) and how.
If the target frame only updates on that event, suppressing it during our cast
window makes the unitframe NOT reflect the transient victim -> no flash."""
from pathlib import Path
import pefile
import struct

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase

def sec(name):
    for s in pe.sections:
        if s.Name.rstrip(b'\x00') == name:
            return s
    return None

text = sec(b'.text')
tstart = text.VirtualAddress + base
toff = text.PointerToRawData
tsize = text.Misc_VirtualSize
tb = data[toff:toff+tsize]

# refs to string 0xA2295C
print("=== refs to string 0xA2295C (PLAYER_TARGET_CHANGED) ===")
pat = struct.pack('<I', 0x00A2295C)
count = 0
for i in range(len(tb) - 4):
    if tb[i:i+4] == pat:
        va = tstart + i
        prev = tb[i-1] if i > 0 else 0
        print(f"  {hex(va)}: prev=0x{prev:02X} (push string / lea)")
        count += 1
        if count >= 15:
            break
print(f"  (total {count})")

# Also check what UnitGUID("target") reads — find the string "target" near UnitGUID.
# The known handler for target guid in 3.3.5 reads 0xBD07B0. Check the reader at
# 0x513930 (0xA1 = mov eax,[0xBD07B0]) — dump context.
print("\n=== disasm around 0x513930 (bd07b0 reader) ===")
from capstone import Cs, CS_ARCH_X86, CS_MODE_32
md = Cs(CS_ARCH_X86, CS_MODE_32)
for start, n, label in [(0x513900, 40, "0x513900"), (0x5282A0, 40, "0x5282A0")]:
    print(f"--- {label} ---")
    off = pe.get_offset_from_rva(start - base)
    for insn in md.disasm(data[off:], start):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        n -= 1
        if n <= 0:
            break

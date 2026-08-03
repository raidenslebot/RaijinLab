"""Round 15: the 0x512B07 SHIELD reveals the walk ALWAYS passes
esi=0xD3C00E14 as the GUID-struct pointer to 0x512B00 (constant across 129
AVs). Find what stores 0xD3C00E14 (who writes/reads it) and what the region
around it is. Also dump the walk's GUID-struct source.
"""
from pathlib import Path
import pefile
import struct
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

def va_to_off(va):
    return pe.get_offset_from_rva(va - base)

def disasm(va, n, label=""):
    print(f"\n=== {label or hex(va)} ===")
    off = va_to_off(va)
    count = 0
    try:
        for insn in md.disasm(data[off:], va):
            print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
            count += 1
            if count >= n:
                break
    except Exception as e:
        print("  err", e)

# 1. Is 0xD3C00E14 inside a mapped PE section?
print("=== section map ===")
for s in pe.sections:
    name = s.Name.rstrip(b'\x00').decode('latin1')
    va_lo = s.VirtualAddress + base
    va_hi = va_lo + max(s.Misc_VirtualSize, s.SizeOfRawData)
    print(f"  {name:10s} VA {hex(va_lo)}..{hex(va_hi)}")
    if va_lo <= 0xD3C00E14 < va_hi:
        print(f"    ^ 0xD3C00E14 is INSIDE this section")
print(f"  image base {hex(base)} size 0x{pe.OPTIONAL_HEADER.SizeOfImage:X}")

# 2. refs to absolute 0xD3C00E14 in .text
text = None
for s in pe.sections:
    if s.Name.rstrip(b'\x00') == b'.text':
        text = s
        break
if text:
    tstart = text.VirtualAddress + base
    toff = text.PointerToRawData
    tsize = text.Misc_VirtualSize
    tb = data[toff:toff+tsize]
    print("\n=== refs to 0xD3C00E14 in .text ===")
    pat = struct.pack('<I', 0xD3C00E14)
    cnt = 0
    for i in range(len(tb) - 4):
        if tb[i:i+4] == pat:
            va = tstart + i
            prev = tb[i-1] if i > 0 else 0
            print(f"  {hex(va)}: prev=0x{prev:02X}")
            cnt += 1
            if cnt >= 25:
                break
    print(f"  (total {cnt})")

# 3. What's around 0xD3C00E14 as data? Dump the raw section bytes at that RVA.
print("\n=== raw bytes at 0xD3C00E14 ===")
rva = 0xD3C00E14 - base
try:
    off = pe.get_offset_from_rva(rva)
    raw = data[off:off+64]
    print("  ", raw.hex(' '))
    # interpret as pointers
    for i in range(0, 64, 4):
        v = struct.unpack('<I', raw[i:i+4])[0]
        print(f"   +0x{i:02X} = 0x{v:08X}")
except Exception as e:
    print("  err", e)

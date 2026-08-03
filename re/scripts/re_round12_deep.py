"""Round 12 deep: understand the crash mechanism.

1. 0x621070 — the 'register resolved object as target' called by helper 0x512AB0.
   Does it update the unitframe? What are its args?
2. [CGGameUI+0x3CC] — the flag that gates 0x621070 in 0x512AB0. Find writers.
3. The callback helper fn@0x851C30 (contains call dword ptr [ebp+0xC] at 0x855B30)
   — find its callers to locate where 0x512B00 could be passed as the callback.
4. Re-verify 0x524BF0 target setter — what exactly it writes (bd07b0 vs CGGameUI+0x328).
"""
from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

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
        print("  (disasm err)", e)

disasm(0x621070, 60, "0x621070 registration (called from helper 0x512AB0)")

# Find writers to [0xBD0774]+0x3CC -> absolute 0xBDA000? BD0774+3CC = BDA000
# Actually 0xBD0774 + 0x3CC = 0xBDA000. Scan .text for references to BDA000.
print("\n=== refs to [CGGameUI+0x3CC] (0xBDA000) ===")
import struct
text = None
for s in pe.sections:
    if s.Name.rstrip(b'\x00') == b'.text':
        text = s
        break
if text:
    tstart = text.VirtualAddress + base
    tend = tstart + text.Misc_VirtualSize
    off = text.PointerToRawData
    size = text.Misc_VirtualSize
    tb = data[off:off+size]
    pat = struct.pack('<I', 0xBDA000)
    hits = 0
    for i in range(len(tb) - 4):
        if tb[i:i+4] == pat:
            va = tstart + i
            print(f"  ref to 0xBDA000 at {hex(va)}")
            hits += 1
            if hits >= 20:
                break
    if hits == 0:
        print("  (none found as absolute dword; trying 0xBDA000 as disp32 in modrm)")

# Find callers of fn@0x851C30: scan for call rel32 to 0x851C30
print("\n=== direct callers of fn@0x851C30 ===")
def find_calls(target_va):
    res = []
    if text is None:
        return res
    tstart = text.VirtualAddress + base
    tend = tstart + text.Misc_VirtualSize
    off = text.PointerToRawData
    size = text.Misc_VirtualSize
    tb = data[off:off+size]
    for i in range(len(tb) - 5):
        if tb[i] == 0xE8:  # call rel32
            rel = struct.unpack('<i', tb[i+1:i+5])[0]
            va = tstart + i
            if va + 5 + rel == target_va:
                res.append(va)
    return res

for c in find_calls(0x851C30):
    print(f"  call 0x851C30 at {hex(c)}")

# 0x524BF0 target setter — verify what it writes (bd07b0? CGGameUI? 0x80BC80? 0x7FD620?)
disasm(0x524BF0, 110, "0x524BF0 target setter (lo,hi)")

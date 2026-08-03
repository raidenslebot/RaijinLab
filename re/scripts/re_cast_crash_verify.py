"""Verify the exact cast path ground truth for the 0x512B07 crash:

1. Find the full CastSpellByID handler function containing the 0x80DA40 call
   at 0x53E177; show where [ebp-4]/[ebp-8] (target GUID) get written.
2. Disassemble the real Spell_C logic 0x80CCE0 head to see how it consumes
   the GUID args (arg3/arg4 after the player-object arg1).
"""
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

def disasm(va, n, label=""):
    print(f"\n=== {label or hex(va)} ===")
    off = va_to_off(va)
    count = 0
    for insn in md.disasm(data[off:], va):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        count += 1
        if count >= n:
            break

def find_fn_start(va):
    """Scan backward from va for 'push ebp; mov ebp, esp' (55 8B EC)."""
    off = va_to_off(va)
    lo = max(0x400, off - 0x4000)
    best = None
    for i in range(off - 5, lo, -1):
        if data[i] == 0x55 and data[i+1] == 0x8B and data[i+2] == 0xEC:
            best = i
    if best is None:
        return None
    return base + pe.get_rva_from_offset(best) + 0x1000  # ??? wrong

def rva_of_off(off):
    for sec in pe.sections:
        if sec.PointerToRawData <= off < sec.PointerToRawData + sec.SizeOfRawData:
            return sec.VirtualAddress + (off - sec.PointerToRawData)
    return None

def fn_start(va):
    off = va_to_off(va)
    lo = max(0x400, off - 0x6000)
    best = None
    for i in range(off - 5, lo, -1):
        if data[i] == 0x55 and data[i+1] == 0x8B and data[i+2] == 0xEC:
            best = i
    if best is None:
        return None
    rva = rva_of_off(best)
    return base + rva if rva else None

print("== 1. CastSpellByID handler (call to 0x80DA40 at 0x53E177) ==")
start = fn_start(0x53E177)
print("function start:", hex(start) if start else "not found")
if start:
    off = va_to_off(start)
    for insn in md.disasm(data[off:off + (0x53E177 - start) + 8], start):
        mark = "   <== CALL 0x80DA40" if insn.address == 0x53E177 else ""
        if 0x53DD00 <= insn.address <= 0x53E177 or "ebp - 4" in insn.op_str or "ebp - 8" in insn.op_str or "esp" in insn.op_str:
            print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}{mark}")

print("\n== 2. Real Spell_C logic 0x80CCE0 head (GUID arg usage) ==")
disasm(0x80CCE0, 90, "0x80CCE0 real Spell_C head")

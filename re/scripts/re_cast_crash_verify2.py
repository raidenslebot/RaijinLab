"""Tighter verification for the 0x512B07 crash cast path.

A) The CastSpellByID FrameScript handler: nearest prologue before 0x53E100,
   then dump the whole function to 0x53E180 showing where [ebp-4]/[ebp-8] (the
   target GUID halves) are written and how 0x80DA40 is called.
B) The real Spell_C logic 0x80CCE0: how it consumes arg3/arg4 (the GUID
   halves at [ebp+0x10]/[ebp+0x14] after the player-obj arg1).
"""
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

def disasm_range(start, end, label, filt=None):
    print(f"\n=== {label} ({hex(start)}..{hex(end)}) ===")
    off = va_to_off(start)
    for insn in md.disasm(data[off:off + (end - start)], start):
        if filt and not filt(insn):
            continue
        mark = ""
        if insn.address + insn.size == 0x53E177:
            mark = "   <== CALL 0x80DA40"
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}{mark}")

# A) find the real handler start: nearest push ebp; mov ebp,esp before 0x53E100
def fn_start_before(va, maxback=0x2000):
    off = va_to_off(va)
    lo = max(0x400, off - maxback)
    best = None
    for i in range(off - 5, lo, -1):
        if data[i] == 0x55 and data[i+1] == 0x8B and data[i+2] == 0xEC:
            best = i
    if best is None:
        return None
    rva = rva_of_off(best)
    return base + rva if rva else None

start = fn_start_before(0x53E100, 0x2000)
print("handler fn start (nearest prologue before 0x53E100):", hex(start) if start else None)
if start:
    # show only the tail: from start+something. Dump full function but filter
    # to interesting instructions: writes to [ebp-4]/[ebp-8], calls, and the tail.
    def interesting(insn):
        op = insn.op_str
        if "ebp - 4" in op or "ebp - 8" in op or "ebp - 0xc" in op:
            return True
        if insn.mnemonic == "call" or insn.mnemonic == "jmp":
            return True
        if insn.address >= 0x53DF80:
            return True
        return False
    disasm_range(start, 0x53E180, "CastSpellByID handler (filtered)", filt=interesting)

# B) real Spell_C logic head
def disasm(va, n, label=""):
    print(f"\n=== {label or hex(va)} ===")
    off = va_to_off(va)
    count = 0
    for insn in md.disasm(data[off:], va):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        count += 1
        if count >= n:
            break

disasm(0x80CCE0, 120, "0x80CCE0 real Spell_C logic")

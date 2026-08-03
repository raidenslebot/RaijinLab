"""Find the REAL CastSpellByID handler function (the one containing 0x53E177)
and dump how it sets up the args for the 0x80DA40 call — specifically whether
[ebp-8]/[ebp-4] are GUID VALUES or POINTERS to a GUID struct."""
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

# The call to 0x80DA40 is at 0x53E177. Find the function prologue that starts
# the handler by scanning backward from 0x53E100 for a clean
#   push ebp; mov ebp, esp; sub esp, <small>
# We know from re_csbid_head that the code AT 0x53E100 is mid-function
# (it's a loop). The prologue must be before that.
off_e100 = va_to_off(0x53E100)
candidates = []
for i in range(off_e100 - 4, off_e100 - 0x1000, -1):
    if data[i] == 0x55 and data[i+1] == 0x8B and data[i+2] == 0xEC:
        rva = rva_of_off(i)
        if rva:
            candidates.append(base + rva)
            if len(candidates) >= 6:
                break

print("prologue candidates before 0x53E100:")
for c in candidates:
    print("  ", hex(c))

# pick the closest candidate below 0x53E100
start = candidates[-1] if candidates else None
print("chosen handler start:", hex(start) if start else None)

if start:
    off = va_to_off(start)
    end = 0x53E180
    print(f"\n=== handler {hex(start)}..{hex(end)} (full) ===")
    for insn in md.disasm(data[off:va_to_off(end)], start):
        op = insn.op_str
        mark = ""
        if insn.address + insn.size == 0x53E177:
            mark = "   <== CALL 0x80DA40"
        if insn.address >= 0x53DF00 or "ebp - 4" in op or "ebp - 8" in op or insn.mnemonic == "call":
            print(f"  {hex(insn.address)}: {insn.mnemonic} {op}{mark}")

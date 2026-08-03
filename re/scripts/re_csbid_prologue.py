"""Scan for writes to [ebp-4]/[ebp-8] in the CastSpellByID handler.
Find the function prologue by searching backwards for push ebp; mov ebp,esp."""
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

def dump_range(start, end, label=""):
    print(f"\n=== {label or hex(start)} .. {hex(end)} ===")
    off = va_to_off(start)
    for insn in md.disasm(data[off:off + (end - start)], start):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")

# Look for the prologue: scan backward from 0x53e177 in 0x100 steps
for start in (0x53E080, 0x53E000, 0x53DF80, 0x53DF00):
    off = va_to_off(start)
    blob = data[off:va_to_off(0x53E180)-off]
    for insn in md.disasm(blob, start):
        if insn.mnemonic == "push" and insn.op_str == "ebp":
            print(f"  candidate prologue at {hex(insn.address)}")
            break

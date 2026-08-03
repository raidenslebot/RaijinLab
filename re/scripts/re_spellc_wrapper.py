"""Disassemble 0x80DA40 (the Spell_C wrapper we actually call) to verify its exact
argument convention. If arg1 is dereferenced as a pointer, our (spellId,0,lo,hi,0)
call is wrong and Spell_C silently no-ops."""
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

def dump(va, n=90, maxlen=900, label=""):
    print(f"\n=== {label or hex(va)} ===")
    try:
        off = va_to_off(va)
    except Exception:
        print("  <no mapping>"); return
    for i, insn in enumerate(md.disasm(data[off:off+maxlen], va)):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if i >= n: break

dump(0x80DA40, 110, 1100, "Spell_C wrapper 0x80DA40 (what SafeNativeCast calls)")

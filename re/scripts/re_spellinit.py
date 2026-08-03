"""Disassemble 0x4cfd20 (spell lookup/init called by Spell_C 0x80CCE0).
If it returns 0, Spell_C silently no-ops. Also dump 0x80CCE0's full flow
to see the early-exit conditions."""
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

def dump(va, n=120, maxlen=1400, label=""):
    print(f"\n=== {label or hex(va)} ===")
    try:
        off = va_to_off(va)
    except Exception:
        print("  <no mapping>"); return
    for i, insn in enumerate(md.disasm(data[off:off+maxlen], va)):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if i >= n: break

dump(0x4CFD20, 130, 1600, "0x4CFD20 spell lookup/init (return 0 => no cast)")

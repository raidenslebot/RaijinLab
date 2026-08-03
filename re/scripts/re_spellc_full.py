"""Full disassembly of 0x80CCE0 (Spell_C real logic) + wrapper helpers.
Goal: find EVERY early-exit after the lookup/flag gates, and understand
what 0x4d3790/0x4d4db0 produce (the playerObj arg to 0x80CCE0)."""
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
    nbytes = end - start
    for insn in md.disasm(data[off:off+nbytes], start):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")

# Full Spell_C logic: 0x80CCE0 .. 0x80DA21 (the je targets land at 0x80DA21)
dump_range(0x80CCE0, 0x80DA22, "0x80CCE0 Spell_C full body")

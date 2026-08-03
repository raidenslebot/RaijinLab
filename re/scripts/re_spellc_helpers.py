"""Disassemble the Spell_C wrapper's player-object derivation:
0x4d3790 (active player?) and 0x4d4db0 (object-by-guid?), plus the
entry block of 0x80CCE0 that the previous full dump omitted."""
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

dump_range(0x4D3790, 0x4D37D0, "0x4D3790 (wrapper arg1 source)")
dump_range(0x4D4DB0, 0x4D4E50, "0x4D4DB0 (object by guid?)")
dump_range(0x80CCE0, 0x80CDB0, "0x80CCE0 entry (missing head)")

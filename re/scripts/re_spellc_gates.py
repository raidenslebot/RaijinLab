"""Disassemble the Spell_C immediate gate helpers:
0x74ba40 (called on player/target before main body; non-zero => FAIL)
0x74b8b0 (called on player; non-zero => effect-validation branch)
0x805010 (target resolution when guidHi==0)"""
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

dump_range(0x74BA40, 0x74BB40, "0x74BA40 (gate on player/target; !=0 => fail)")
dump_range(0x74B8B0, 0x74B9B0, "0x74B8B0 (gate on player; !=0 => effect branch)")
dump_range(0x805010, 0x805090, "0x805010 (target resolve when guidHi==0)")

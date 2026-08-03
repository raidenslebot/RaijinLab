"""Disassemble the three 'spell usability' gates that precede the main cast
gates: 0x53bd10 (spell known?), 0x8009b0 (usable?), 0x5191c0 (can-cast state?)."""
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

dump_range(0x53BD10, 0x53BE10, "0x53BD10 (spellId) - spell known/learned?")
dump_range(0x8009B0, 0x800A70, "0x8009B0 (&spellObj) - usable?")
dump_range(0x5191C0, 0x519280, "0x5191C0 (mode) - can-cast state?")

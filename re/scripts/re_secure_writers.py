"""Disassemble the writers of the secure-execution flag 0xbd1af0:
0x530450..0x530700 (the secure-action message system) and 0x6df300..0x6df340."""
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

dump_range(0x530450, 0x530740, "0x530450..0x530740 secure-action message system")
dump_range(0x6DF300, 0x6DF360, "0x6DF300 (0xbd1af0 writer)")
dump_range(0x6E16F0, 0x6E1730, "0x6E16F0 (0xbd1af0 ref)")

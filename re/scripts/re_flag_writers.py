"""Disassemble the writers of 0xbd1af0 (0x6df316, 0x6e1706)."""
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

dump_range(0x6DF2E0, 0x6DF340, "0x6DF2E0 (0xbd1af0 writer at 0x6df316)")
dump_range(0x6E16E0, 0x6E1730, "0x6E16E0 (0xbd1af0 ref at 0x6e1706)")

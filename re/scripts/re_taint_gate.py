"""Disassemble 0x5222B0 (cast-origin security check; returning 0 marks casts
insecure -> blocked-action dialog after 10) and 0x530840 (the dialog/msg show)."""
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

dump_range(0x5222B0, 0x522380, "0x5222B0(5) - cast-origin security check")
dump_range(0x530840, 0x530930, "0x530840(0x3b) - blocked-action dialog/message")

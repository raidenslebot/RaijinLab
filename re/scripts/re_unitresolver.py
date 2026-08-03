"""Disassemble 0x60ABF0 (unit-string resolver used by TargetUnit's 0x520190)
head to confirm it handles GUID strings ('0x...') as well as named tokens."""
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

def disasm(va, n, label=""):
    print(f"\n=== {label or hex(va)} ===")
    off = va_to_off(va)
    count = 0
    for insn in md.disasm(data[off:], va):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        count += 1
        if count >= n:
            break

disasm(0x60ABF0, 80, "0x60ABF0 unit-string resolver")

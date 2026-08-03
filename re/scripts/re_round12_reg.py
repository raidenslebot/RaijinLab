"""Round 12: analyze 0x80BC80 (core target registration) and 0x7FD620 (the
check in 0x524BF0 before registration), and find what fires the unitframe
update. Also look at the full 0x524BF0 set path tail (bd07b0 write, events)."""
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
    try:
        for insn in md.disasm(data[off:], va):
            print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
            count += 1
            if count >= n:
                break
    except Exception as e:
        print("  (disasm err)", e)

disasm(0x80BC80, 90, "0x80BC80 core target registration (obj, arg)")
disasm(0x7FD620, 50, "0x7FD620 check before registration")
# tail of 0x524BF0 set path (continue from 0x524D35)
disasm(0x524D30, 90, "0x524BF0 set-path tail")

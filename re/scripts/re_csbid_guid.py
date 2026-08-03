"""Find where [ebp-4]/[ebp-8] (the target GUID) are set in the CastSpellByID
handler that calls 0x80DA40 at 0x53e177. Scan backwards from 0x53e177."""
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

# The handler body: scan for the function prologue before 0x53e177
dump_range(0x53DD00, 0x53E100, "searching for [ebp-4]/[ebp-8] writes")

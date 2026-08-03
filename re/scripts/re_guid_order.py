"""Disassemble 0x72c2b0 (cast-spell-on-unit helper) to determine arg order
of the two guid words, and scan for writes to [ebp-4]/[ebp-8] in the
CastSpellByID handler (0x53D000..0x53E177) to see the raw write patterns."""
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

dump_range(0x72C2B0, 0x72C3A0, "0x72C2B0 (player, a, b, c) - guid word order")

# Scan the handler region for writes to [ebp-4] / [ebp-8]
print("\n=== [ebp-4]/[ebp-8] writes in 0x53D000..0x53E177 ===")
off = va_to_off(0x53D000)
end_off = va_to_off(0x53E177)
for insn in md.disasm(data[off:end_off-off], 0x53D000):
    if "[ebp - 4]" in insn.op_str and insn.mnemonic.startswith("mov"):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
    if "[ebp - 8]" in insn.op_str and insn.mnemonic.startswith("mov"):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")

"""GetTime: 0x86ae20 -> 0x86adc0. Find the actual global read."""
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

def off_to_va(off):
    return base + pe.get_rva_from_offset(off)

def dump(va, n=30, maxlen=250, label=""):
    print(f"\n=== {label or hex(va)} ===")
    try:
        off = va_to_off(va)
    except Exception:
        print("  <no mapping>")
        return
    chunk = data[off:off+maxlen]
    for i, insn in enumerate(md.disasm(chunk, va)):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if i >= n:
            break

dump(0x0086adc0, 30, 250, "0x86adc0 GetTime real")

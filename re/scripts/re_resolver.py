"""Disassemble the module/export resolver functions used by the crash site."""
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

def dump(va, n=80, maxlen=700, label=""):
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

dump(0x6b372e, 60, 500, "0x6B372E module lookup (called with 'mscoree.dll')")
dump(0x41c654, 80, 700, "0x41C654 export resolver (called with module,'CorExitProcess')")

from pathlib import Path
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

path = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = path.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase
md = Cs(CS_ARCH_X86, CS_MODE_32)

def dis(va, n=25):
    off = pe.get_offset_from_rva(va - base)
    chunk = data[off:off+80]
    print(f"=== {hex(va)} bytes {chunk[:16].hex()} ===")
    for i, insn in enumerate(md.disasm(chunk, va)):
        print(f"  {hex(insn.address)}: {insn.mnemonic} {insn.op_str}")
        if i >= n: break

for va in [0x4D3790, 0x4D4D70, 0x4D4DB0, 0x4D4B30, 0x727400, 0x611130]:
    try:
        dis(va, 20)
    except Exception as e:
        print(va, e)

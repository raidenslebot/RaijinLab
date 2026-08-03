"""Disassemble the game frames around the 0x66AAF090 crash (ret=0x40CF09/0x40D16E/0x40D15D)."""
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

def dump(va, n=60, maxlen=500, label=""):
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

def cstr(off, maxlen=200):
    end = data.find(b"\x00", off, off + maxlen)
    if end == -1:
        end = off + maxlen
    return data[off:end].decode("ascii", "replace")

for va in (0x9e30f4, 0x9e30e4, 0x9e0b04, 0x9e0af8, 0x9e0b0c, 0x9e0b08, 0xaaf270):
    try:
        off = va_to_off(va)
        print(f"{hex(va)}: {cstr(off)!r}")
    except Exception as e:
        print(f"{hex(va)}: <no mapping {e}>")

for va, label in ((0x9df1b0, "0x9df1b0 table"), (0xb2ed98, "0xb2ed98 getfn"),
                  (0xdd0468, "0xdd0468 list_end"), (0xdd0464, "0xdd0464 list_start"),
                  (0xb31248, "0xb31248 flag"), (0xb31244, "0xb31244 flag2")):
    try:
        off = va_to_off(va)
        val = int.from_bytes(data[off:off+4], "little")
        print(f"{label} {hex(va)} = {hex(val)}")
    except Exception as e:
        print(f"{label}: <no mapping {e}>")

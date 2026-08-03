"""Find indirect references to 0x512B00 (the crash function) — it has no
direct callers, so it must be stored in a function-pointer table. Scan all
readable sections for the 4-byte VA and identify the table + its dispatcher."""
import struct
from capstone import *
from capstone.x86 import *

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(EXE, 'rb').read()
IMAGE_BASE = 0x400000

def va2fo(va):
    return 0x400 + (va - IMAGE_BASE - 0x1000)

TARGET = 0x00512B00
pat = struct.pack('<I', TARGET)

# Section map (headers at 0xF8... read from PE)
import pefile
pe = pefile.PE(EXE)
sections = []
for s in pe.sections:
    name = s.Name.rstrip(b'\x00').decode('latin1')
    va = s.VirtualAddress + IMAGE_BASE
    vsz = s.Misc_VirtualSize
    fo = s.PointerToRawData
    rawsz = s.SizeOfRawData
    sections.append((name, va, vsz, fo, rawsz))
    print(f"section {name:8s} VA=0x{va:08X} vsz=0x{vsz:X} FO=0x{fo:X} raw=0x{rawsz:X}")

print("\n=== dword refs to 0x512B00 (function pointer tables) ===")
for name, va, vsz, fo, rawsz in sections:
    if name in ('.text', '.pdata', '.reloc'):
        continue
    for i in range(fo, fo + rawsz - 3):
        if data[i:i+4] == pat:
            off_in_sec = i - fo
            print(f"  {name}: file 0x{i:X} -> VA 0x{va + off_in_sec:08X}")

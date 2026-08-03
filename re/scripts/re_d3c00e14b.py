"""Round 15b: check .data committed vs virtual size; find stored VALUE
0xD3C00E14 anywhere in the image; and find the walk's GUID-struct source."""
from pathlib import Path
import pefile
import struct

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase

print("=== section sizes ===")
for s in pe.sections:
    name = s.Name.rstrip(b'\x00').decode('latin1')
    vsz = s.Misc_VirtualSize
    rsz = s.SizeOfRawData
    va_lo = s.VirtualAddress + base
    print(f"  {name:8s} VA {hex(va_lo):10s} VirtSize=0x{vsz:08X} RawSize=0x{rsz:08X} "
          f"committed_end=0x{va_lo + rsz:08X} virt_end=0x{va_lo + vsz:08X}")
    if name == '.data':
        print(f"    0xD3C00E14 committed? {va_lo + rsz > 0xD3C00E14}")

# 2. search the whole file for the 4-byte VALUE 0xD3C00E14
print("\n=== stored value 0xD3C00E14 anywhere ===")
pat = struct.pack('<I', 0xD3C00E14)
hits = 0
for i in range(len(data) - 4):
    if data[i:i+4] == pat:
        # map file offset to VA
        for s in pe.sections:
            if s.PointerToRawData <= i < s.PointerToRawData + s.SizeOfRawData:
                va = s.VirtualAddress + base + (i - s.PointerToRawData)
                print(f"  file+0x{i:X} = VA 0x{va:08X} ({s.Name.rstrip(b'\\x00').decode('latin1')})")
                hits += 1
                break
        if hits >= 20:
            break
print(f"  (total {hits})")

# 3. search for stored value 0xD3C00E14-4 and +4 variants (GUID struct pointers nearby)
print("\n=== stored values near 0xD3C00E14 (0xD3C00E10 / 0xD3C00E18) ===")
for val in (0xD3C00E10, 0xD3C00E18, 0xD3C00E0C, 0xD3C00E1C):
    pat = struct.pack('<I', val)
    n = 0
    for i in range(len(data) - 4):
        if data[i:i+4] == pat:
            n += 1
    print(f"  0x{val:08X}: {n} occurrences")

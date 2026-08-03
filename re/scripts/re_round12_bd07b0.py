"""Round 12: find all refs to 0xBD07B0 (kClientTargetGuid) and to the
PLAYER_TARGET_CHANGED event string. Determine whether the unitframe polls
0xBD07B0 directly or updates only via the target-changed event (which would
make a RAW write to 0xBD07B0 invisible to the UI)."""
from pathlib import Path
import pefile
import struct

ASC = Path(r"C:\Ascension\Launcher\resources\ascension-live\Ascension.exe")
data = ASC.read_bytes()
pe = pefile.PE(data=data)
base = pe.OPTIONAL_HEADER.ImageBase

def sec(name):
    for s in pe.sections:
        if s.Name.rstrip(b'\x00') == name:
            return s
    return None

text = sec(b'.text')
rdata = sec(b'.rdata')

# 1. Find all code refs to absolute 0xBD07B0 (mov reg,[0xBD07B0] / cmp [0xBD07B0],reg)
print("=== refs to 0xBD07B0 in .text ===")
tstart = text.VirtualAddress + base
toff = text.PointerToRawData
tsize = text.Misc_VirtualSize
tb = data[toff:toff+tsize]
pat = struct.pack('<I', 0x00BD07B0)
count = 0
for i in range(len(tb) - 4):
    if tb[i:i+4] == pat:
        va = tstart + i
        # classify: preceding byte determines modrm: 0x3B (cmp r,[abs]) 0x8B (mov r,[abs]) 0x89/0xA3 (mov [abs],r)
        prev = tb[i-1] if i > 0 else 0
        kind = 'other'
        if prev == 0x3B: kind = 'CMP reg,[abs]'
        elif prev == 0x8B: kind = 'MOV reg,[abs]  (READ)'
        elif prev in (0x89, 0x87, 0x01, 0x03, 0x23): kind = 'WRITE-ish'
        elif prev == 0x0F and i > 1 and tb[i-2] == 0x3D: kind = 'CMP [abs],imm'
        print(f"  {hex(va)}: prev=0x{prev:02X} {kind}")
        count += 1
        if count >= 30:
            break
print(f"  (total shown {count})")

# 2. find the PLAYER_TARGET_CHANGED string
print("\n=== PLAYER_TARGET_CHANGED string ===")
needle = b'PLAYER_TARGET_CHANGED'
idx = data.find(needle)
if idx >= 0:
    # map file offset to VA
    for s in pe.sections:
        if s.PointerToRawData <= idx < s.PointerToRawData + s.SizeOfRawData:
            va = s.VirtualAddress + base + (idx - s.PointerToRawData)
            print(f"  string at VA {hex(va)}")
            break
else:
    print("  (not found)")

# 3. refs to CGGameUI+0x328 = 0xBD0774+0x328 = 0xBDA09C
print("\n=== refs to 0xBDA09C (CGGameUI+0x328 target guidLo) ===")
pat2 = struct.pack('<I', 0x00BDA09C)
count = 0
for i in range(len(tb) - 4):
    if tb[i:i+4] == pat2:
        va = tstart + i
        print(f"  {hex(va)}")
        count += 1
        if count >= 20:
            break
print(f"  (total shown {count})")

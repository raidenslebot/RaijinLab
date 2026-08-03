"""Search .text for ANY reference to 0x512B00 (raw dword) and disassemble the
crash stack frames to understand the recursion."""
import struct
from capstone import *
from capstone.x86 import *

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(EXE, 'rb').read()
IMAGE_BASE = 0x400000

def va2fo(va):
    return 0x400 + (va - IMAGE_BASE - 0x1000)

md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

TARGET = 0x00512B00
pat = struct.pack('<I', TARGET)

print("=== raw dword refs to 0x512B00 in .text ===")
count = 0
for i in range(0x400, 0x400 + 0x5DD400 - 3):
    if data[i:i+4] == pat:
        va = 0x401000 + (i - 0x400)
        print(f"  file 0x{i:X} -> VA 0x{va:08X}")
        count += 1
        if count > 40:
            print("  ... (truncated)")
            break
if count == 0:
    print("  none")

print("\n=== crash stack frames (recursion analysis) ===")
# The repeating cycle: 85898A 8567E7 84EC46 855B33 8569A9 84EC9F 8549A9 85651C
frames = [0x00858A16, 0x008567E7, 0x0084EC46, 0x00855B33, 0x008569A9,
          0x0084EC9F, 0x008549A9, 0x0085651C, 0x0085898A]
for rc in frames:
    # disassemble backwards a bit and find the call instruction ending at rc
    start = rc - 0x20
    code = data[va2fo(start):va2fo(rc + 1)]
    for ins in md.disasm(code, start):
        if ins.address + ins.size == rc:
            print(f"0x{rc:08X}: {ins.mnemonic} {ins.op_str}")
            break

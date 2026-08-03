"""Find all references to [0xd380a4] (the counter the tick fn increments) to
understand its purpose, and search for indirect call patterns to 0x7E5120."""
import struct
from capstone import *

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(EXE, 'rb').read()
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000
TEXT_SIZE = 0x5DD400
md = Cs(CS_ARCH_X86, CS_MODE_32)

COUNTER = 0x00D380A4
TARGET = 0x7E5120


def va2fo(va):
    return 0x400 + (va - IMAGE_BASE - 0x1000)

text = data[TEXT_OFF:TEXT_OFF + TEXT_SIZE]

# find E8 calls that pass the counter address or reference it
# Pattern: FF 05 A4 80 D3 00 (inc dword [counter]) anywhere
inc_hits = []
mov_hits = []
i = 0
while i < len(text) - 6:
    if text[i] == 0xFF and text[i+1] == 0x05 and text[i+2:i+6] == struct.pack('<I', COUNTER):
        inc_hits.append(TEXT_VA + i)
    if text[i] == 0xA1 and text[i+1:i+5] == struct.pack('<I', COUNTER):
        mov_hits.append(TEXT_VA + i)
    if text[i] == 0x8B and text[i+1] == 0x0D and text[i+2:i+6] == struct.pack('<I', COUNTER):
        mov_hits.append(TEXT_VA + i)
    if text[i] == 0x8B and text[i+1] == 0x15 and text[i+2:i+6] == struct.pack('<I', COUNTER):
        mov_hits.append(TEXT_VA + i)
    i += 1

print('inc dword [0xd380a4] hits:', ['0x%08X' % h for h in inc_hits])
print('mov-from counter hits:', ['0x%08X' % h for h in mov_hits])

# disassemble each hit's surrounding context (the enclosing function)
for h in (inc_hits + mov_hits)[:8]:
    fo = va2fo(h)
    code = data[fo - 16:fo + 48]
    print('\n=== context around 0x%08X ===' % h)
    for ins in md.disasm(code, h - 16):
        marker = '  <== REF' if ins.address == h else ''
        print('0x%08X %s %s%s' % (ins.address, ins.mnemonic, ins.op_str, marker))

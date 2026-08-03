"""Find callers of crash fn 0x512B00 and understand what it is.
The crash is Lua calling 0x512B00 with a corrupted arg (garbage GUID pointer).
Find who registers/calls 0x512B00 and whether it's cast-related."""
import struct
from capstone import *

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(EXE, 'rb').read()
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400


def fo2va(fo):
    return IMAGE_BASE + 0x1000 + (fo - 0x400)


def va2fo(va):
    return 0x400 + (va - IMAGE_BASE - 0x1000)


md = Cs(CS_ARCH_X86, CS_MODE_32)
TARGET = 0x512B00
text = data[TEXT_OFF:TEXT_OFF + 0x5DD400]

# find E8 calls to TARGET
callers = []
i = 0
while i < len(text) - 5:
    if text[i] == 0xE8:
        rel = struct.unpack_from('<i', text, i + 1)[0]
        src = fo2va(i)
        dst = src + 5 + rel
        if dst == TARGET:
            callers.append(src)
        i += 5
        continue
    i += 1
print('E8 callers of 0x512B00:', ['0x%08X' % c for c in callers])

# also FF 15 / FF 25 (indirect), and pointer refs in .rdata/.data
# find 4-byte pointer to TARGET in any section
raw_ptr = struct.pack('<I', TARGET)
hits = []
idx = 0
while True:
    idx = data.find(raw_ptr, idx)
    if idx < 0:
        break
    # file offset -> translate roughly: .text at 0x400.., .rdata at 0x5DD800
    if 0x400 <= idx < 0x5DD800:
        pass
    hits.append(idx)
    idx += 1
print('raw ptr refs (file offsets):', ['0x%X' % h for h in hits[:10]])

# disassemble the two callers found (enclosing function)
for c in callers[:4]:
    fo = va2fo(c - 8)
    code = data[fo:fo + 40]
    print('\n=== around caller 0x%08X ===' % c)
    for ins in md.disasm(code, c - 8):
        m = '  <== CALL' if ins.address == c else ''
        print('0x%08X %s %s%s' % (ins.address, ins.mnemonic, ins.op_str, m))

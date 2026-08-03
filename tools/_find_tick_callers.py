"""Find callers of 0x7E5120 and disassemble the enclosing functions to
determine whether it's a safe per-frame point to call Spell_C from."""
import struct
from capstone import *

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(EXE, 'rb').read()
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000
TEXT_SIZE = 0x5DD400
md = Cs(CS_ARCH_X86, CS_MODE_32)


def va2fo(va):
    return 0x400 + (va - IMAGE_BASE - 0x1000)


def fo2va(fo):
    return IMAGE_BASE + 0x1000 + (fo - 0x400)


TARGET = 0x7E5120
text = data[TEXT_OFF:TEXT_OFF + TEXT_SIZE]

# Find direct E8 calls to TARGET
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

print('direct E8 callers of 0x7E5120:', len(callers))
for c in callers:
    print('  0x%08X' % c)

# Also find indirect callers via E8 to thunks that jmp to it, and FF 15/FF 25
# Scan for jmp targets
jmp_srcs = {}
i = 0
while i < len(text) - 5:
    if text[i] == 0xE9:
        rel = struct.unpack_from('<i', text, i + 1)[0]
        src = fo2va(i)
        dst = src + 5 + rel
        if dst == TARGET:
            jmp_srcs.setdefault(dst, []).append(src)
        i += 5
        continue
    i += 1
if jmp_srcs:
    print('direct E9 jmps to 0x7E5120:')
    for dst, srcs in jmp_srcs.items():
        for s in srcs:
            print('  0x%08X -> 0x%08X' % (s, dst))

# Disassemble the region AROUND each caller (enclosing function context)
for c in callers[:6]:
    # print 40 bytes before and 30 after the call site
    start = c - 24
    fo = va2fo(start)
    code = data[fo:fo + 70]
    print('\n=== context around caller 0x%08X ===' % c)
    for ins in md.disasm(code, start):
        marker = '  <== CALL' if ins.address == c else ''
        print('0x%08X %s %s%s' % (ins.address, ins.mnemonic, ins.op_str, marker))

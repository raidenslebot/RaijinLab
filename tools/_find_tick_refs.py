"""Find ALL references to 0x7E5120 (data refs, jmp thunks, pointer tables)
to determine how it's reached and from what context."""
import struct
from capstone import *

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(EXE, 'rb').read()
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000
TEXT_SIZE = 0x5DD400
RDATA_VA = IMAGE_BASE + 0x5DF000
DATA_VA = IMAGE_BASE + 0x6B6000
md = Cs(CS_ARCH_X86, CS_MODE_32)
TARGET = 0x7E5120


def va2fo(va):
    return 0x400 + (va - IMAGE_BASE - 0x1000)

# 1) E9 jmps in .text to target
text = data[TEXT_OFF:TEXT_OFF + TEXT_SIZE]
jmp_callers = []
i = 0
while i < len(text) - 5:
    if text[i] == 0xE9:
        rel = struct.unpack_from('<i', text, i + 1)[0]
        src = TEXT_VA + i
        dst = src + 5 + rel
        if dst == TARGET:
            jmp_callers.append(src)
        i += 5
        continue
    i += 1
print('E9 jmps to target:', ['0x%08X' % c for c in jmp_callers])

# 2) scan .rdata + .data for a 4-byte pointer to TARGET
def scan_ptr(off_start, off_end, name):
    hits = []
    p = struct.pack('<I', TARGET)
    idx = 0
    while True:
        idx = data.find(p, off_start, off_end)
        if idx < 0:
            break
        hits.append(0x400000 + 0x1000 + (idx - 0x400) if 0x400 <= idx < 0x400+TEXT_SIZE else
                    (RDATA_VA + (idx - (TEXT_OFF + TEXT_SIZE)) if 0x400+TEXT_SIZE <= idx < 0x400+TEXT_SIZE+0x2E800 else
                     DATA_VA + (idx - (0x400 + TEXT_SIZE + 0x2E800))))
        off_start = idx + 1
    print('%s ptr hits: %s' % (name, ['0x%08X' % h for h in hits[:20]]))
    return hits

rdata_off = TEXT_OFF + TEXT_SIZE
rdata_sz = 0x5DD800 - TEXT_OFF - TEXT_SIZE  # .rdata file off starts 0x5DD800
scan_ptr(rdata_off, rdata_off + 0x2E800, 'RDATA')

# 3) disassemble the jmp thunk region and its callers
for c in jmp_callers:
    # find callers of the thunk 0x7E5140 style (the jmp is likely an alias)
    pass

# 4) Look at the whole region around target - maybe it's a small dispatcher table
fo = va2fo(TARGET)
print('\nbytes at target region:')
code = data[fo - 32:fo + 32]
for ins in md.disasm(code, TARGET - 32):
    print('0x%08X %s %s' % (ins.address, ins.mnemonic, ins.op_str))

"""Prove the decoder bug on the actual hook target 0x7E5120."""
import struct
from capstone import *

exe = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(exe, 'rb').read()
IMAGE_BASE = 0x400000


def va2fo(va):
    return 0x400 + (va - IMAGE_BASE - 0x1000)


va = 0x7E5120
fo = va2fo(va)
raw = data[fo:fo + 16]
md = Cs(CS_ARCH_X86, CS_MODE_32)
print('bytes at 0x7E5120:', ' '.join('%02X' % b for b in raw))
for i in md.disasm(raw, va):
    print('  capstone: 0x%08X  len=%d  %s %s' % (i.address, i.size, i.mnemonic, i.op_str))
    if i.size >= 5:
        break


# Replicate the C++ decoder's default-case logic for op=0x83
def my_len(buf):
    i = 0
    op = buf[0]
    m = buf[1]
    extra = 2
    if (m & 0xC0) == 0x40:
        extra += 1
    elif (m & 0xC0) == 0x80:
        extra += 4
    elif (m & 0xC0) == 0x00:
        rm = m & 0x07
        if rm == 0x04:
            extra += 1
        elif rm == 0x05:
            extra += 4
    return i + extra


print()
print('MY DECODER returns length:', my_len(raw))
print('CAPSTONE says the add instruction is 7 bytes (83 05 disp32 imm8)')
print('=> my decoder returns 6 => trampoline copies 6 bytes, drops the imm8,')
print('   jmps back to target+6 (mid-instruction!) => GARBAGE EXECUTION')

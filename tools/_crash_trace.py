"""Trace how Lua reaches crash fn 0x512B00 via the indirect call at frame 0x00855B33.
Find the enclosing function and the Lua API name it dispatches."""
import struct
from capstone import *

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(EXE, 'rb').read()
IMAGE_BASE = 0x400000


def va2fo(va):
    return 0x400 + (va - IMAGE_BASE - 0x1000)


md = Cs(CS_ARCH_X86, CS_MODE_32)

# The crash frame-1 ret is 0x008567E7 (caller of 0x512B00).
# frame-3 ret 0x00855B33 is `call [ebp+0xC]` (indirect Lua dispatch).
# Find the function containing 0x00855B33 - scan backward for function prologue.
def find_fn_start(va):
    fo = va2fo(va)
    # scan backward up to 0x1000 bytes for push ebp; mov ebp,esp or similar
    lo = max(0x400, fo - 0x2000)
    code = data[lo:fo]
    for i in range(len(code) - 1, -1, -1):
        # prologue: 55 8B EC  (push ebp; mov ebp,esp)  or 55 89 E5
        if code[i] == 0x55 and code[i+1] == 0x8B and code[i+2] == 0xEC:
            return va2fo_offset(lo + i)

def va2fo_offset(fo):
    return IMAGE_BASE + 0x1000 + (fo - 0x400)

# Just disassemble around 0x008567E7 (the direct caller of 0x512B00) to see
# how it computes the argument.
print("=== around direct caller 0x008567E7 of 0x512B00 ===")
fo = va2fo(0x8567C0)
code = data[fo:va2fo(0x856800)]
for ins in md.disasm(code, 0x8567C0):
    m = '  <== call 0x512B00' if (ins.address + ins.size == 0x8567E7) else ''
    print('0x%08X %s %s%s' % (ins.address, ins.mnemonic, ins.op_str, m))

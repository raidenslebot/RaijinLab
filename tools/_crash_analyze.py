"""Analyze crash 0x512B07: disassemble the crash site and the constant ebx=0x00809000.
Every crash shows ebx=0x00809000 — a fixed data pointer. Understand the code path."""
import struct
from capstone import *

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
data = open(EXE, 'rb').read()
IMAGE_BASE = 0x400000


def va2fo(va):
    return 0x400 + (va - IMAGE_BASE - 0x1000)


md = Cs(CS_ARCH_X86, CS_MODE_32)

# Crash eip + ret addresses from all crashes:
#   eip=0x00512B07  (mov eax,[esi] / [esi+4] with esi=garbage)
#   frames: 0x00858A16 0x008567E7 0x0084EC46 0x00855B33 0x008569A9 0x0084EC9F
#           0x008549A9 0x0085651C 0x0085898A
# ebx=0x00809000 constant.

print("=== crash site 0x512B07 ===")
code = data[va2fo(0x512AE0):va2fo(0x512B40)]
for ins in md.disasm(code, 0x512AE0):
    print('0x%08X %s %s' % (ins.address, ins.mnemonic, ins.op_str))

print("\n=== 0x00809000 region (constant ebx) - is it data? ---")
# ebx=0x00809000 is a VA; check if it's in .data/.rdata and readable
# .data VA=0x6B6000 so 0x00809000 is below that => .rdata or .text
# .rdata VA=0x5DF000, size 0xD7000 -> 0x5DF000..0x6B6000. 0x00809000 is
# BELOW 0x5DF000 so it's in .text range (0x401000..0x5DF3B3).
print("0x00809000 is in .text range (0x401000-0x5DF3B3)")
# disassemble around 0x00809000 too
print("\n=== 0x00809000 context (what fn does ebx point into?) ===")
code2 = data[va2fo(0x809000 - 0x40):va2fo(0x809000 + 0x20)]
for ins in md.disasm(code2, 0x809000 - 0x40):
    print('0x%08X %s %s' % (ins.address, ins.mnemonic, ins.op_str))

print("\n=== frame return addresses (Lua VM) ===")
for rc in [0x00858A16, 0x008567E7, 0x0084EC46, 0x00855B33, 0x008569A9, 0x0084EC9F, 0x008549A9, 0x0085651C, 0x0085898A]:
    c3 = data[va2fo(rc - 0x10):va2fo(rc + 4)]
    ins = list(md.disasm(c3, rc - 0x10))
    # print the instruction ending at rc (the call/ret)
    for i in ins:
        if i.address + i.size == rc:
            print('0x%08X: %s %s' % (rc, i.mnemonic, i.op_str))
            break

"""Disassemble the crash caller chain for 0x512B00 (the 0x512B07 GUID
resolver). The stack shows a recursive chain: 0x856370 calls itself through
0x857ca0/0x856760/0x855af0/0x856970/0x84ec50 with indirect calls. Find what
data structure holds the GUID pointer that becomes garbage (esi=0x97034201)."""
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

def dis(va, nbytes=0x80, label=""):
    print(f"\n=== {label} 0x{va:08X} ===")
    fo = va2fo(va)
    code = data[fo:fo+nbytes]
    for ins in md.disasm(code, va):
        print('0x%08X %s %s' % (ins.address, ins.mnemonic, ins.op_str))

# The crash chain from the stack (repeating 8-frame cycle):
#   frame0 0x00858A16 call 0x856370   <- return into 0x856370's caller? No:
#   actually these are RETURN addresses after `call` instructions, so each
#   frame's address is where execution resumes after a call. frame0 = return
#   addr of whoever called the function that called 0x512B00 indirectly.
dis(0x856370, 0x120, "caller-of-crash (recursive walk)")
dis(0x857ca0, 0x80, "called from 8567E7")
dis(0x512ab0, 0x60, "helper called with guidPtr+obj (512B2A)")

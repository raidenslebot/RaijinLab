"""Generate a Capstone reference of instruction lengths over Ascension.exe .text
so the COMPILED C++ Lde decoder (Lde.h) can be verified against ground truth.

Writes tools/_lde_ref.bin: for each capstone instruction, 4-byte little-endian
VA + 1-byte length (packed 5 bytes/entry). Then a C++ harness compiled from the
REAL Lde.h walks the same .text and compares.
"""
import struct
import sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000
TEXT_SIZE = 0x5DD400
OUT = r'C:\Ascension\Workspace\RaijinLab\tools\_lde_ref.bin'


def main():
    data = open(EXE, 'rb').read()
    text = data[TEXT_OFF:TEXT_OFF + TEXT_SIZE]
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    insns = list(md.disasm(text, TEXT_VA))
    with open(OUT, 'wb') as f:
        for ins in insns:
            f.write(struct.pack('<IB', ins.address, ins.size))
    print('wrote %d entries -> %s' % (len(insns), OUT))


if __name__ == '__main__':
    sys.exit(main())

"""Disassemble Spell_C and its real logic to understand how the cast victim is
resolved — specifically whether Spell_C writes the passed GUID to 0xBD07B0
(the client selection / commit-gate pending-cast pair), which is the force-acquire.

Writes: tools/_disasm_cast.txt  (and prints a summary)
Usage: python tools/_disasm_cast.py [start_va] [len]
"""
import sys

from capstone import Cs, CS_ARCH_X86, CS_MODE_32

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000
TEXT_SIZE = 0x5DD400

TARGETS = [
    (0x0080DA40, 0x140, 'Spell_C_CastSpell (entry)'),
    (0x0080CCE0, 0x580, 'Spell_C real logic (full to ret)'),
]
# where to search within the real logic: 0xBD07B0 write, GUID param use
GUID_LO = 0x00BD07B0
GUID_HI = 0x00BD07B4


def va_to_fo(va):
    return va - IMAGE_BASE - 0x1000 + TEXT_OFF


def disasm_range(data, start_va, length):
    fo = va_to_fo(start_va)
    if fo < 0 or fo >= len(data):
        print('  va 0x%08X out of range' % start_va)
        return
    chunk = data[fo:fo + length]
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True
    lines = []
    for ins in md.disasm(chunk, start_va):
        lines.append((ins.address, ins.mnemonic, ins.op_str, ins.bytes))
    return lines


def main():
    out = []
    data = open(EXE, 'rb').read()
    for start_va, length, label in TARGETS:
        out.append('=' * 78)
        out.append('%s  start=0x%08X len=0x%X' % (label, start_va, length))
        out.append('=' * 78)
        lines = disasm_range(data, start_va, length)
        if not lines:
            out.append('  (no disasm)')
        for addr, mn, op, byt in lines:
            # annotate GUID-global references
            ann = ''
            if ('0xbd07b0' in op.lower() or '0xbd07b4' in op.lower()
                    or '@0xbd07b0' in op.lower()):
                ann = '   <=== SELECTION / COMMIT-GATE GUID'
            out.append('0x%08X  %-8s %-34s ; %s%s'
                       % (addr, mn, op, ' '.join('%02X' % b for b in byt), ann))
    txt = '\n'.join(out)
    path = r'C:\Ascension\Workspace\RaijinLab\tools\_disasm_cast.txt'
    with open(path, 'w') as f:
        f.write(txt)
    print(txt)


if __name__ == '__main__':
    main()

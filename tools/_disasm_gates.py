"""One-off: disassemble the post-gate Spell_C gates + the sibling 0x80DA80 path.
Usage: python tools/_disasm_gates.py
"""
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000
TEXT_SIZE = 0x5DD400

TARGETS = [
    (0x00805F60, 0x60,  'gate 0x805f60 (post-sync, called 0x80D34B)'),
    (0x00809000, 0x140, 'gate 0x809000 (called 0x80D36D; !=0 -> FAIL 0x80d385)'),
    (0x008091D0, 0x1C0, 'gate 0x8091d0 (called 0x80D452; ==0 -> FAIL 0x80d249)'),
    (0x008093D0, 0x1C0, 'gate 0x8093d0 (called 0x80D46F; ==0 -> FAIL 0x80d249)'),
    (0x00809610, 0x90,  'gate 0x809610 (called 0x80D6AD)'),
    (0x00809A60, 0x60,  'fn 0x809a60 (called 0x80D3CE)'),
    (0x00739650, 0x160, 'gate 0x739650 (called 0x80D6D1; ==0 -> FAIL 0x80d249)'),
    (0x0080C790, 0x240, 'FINAL 0x80c790 (called 0x80D727; !=0 -> SUCCESS 0x80d8ef)'),
    (0x0080DA80, 0x280, 'SIBLING 0x80DA80 (action-bar/keybind cast path)'),
]


def va_to_fo(va):
    return va - IMAGE_BASE - 0x1000 + TEXT_OFF


def main():
    data = open(EXE, 'rb').read()
    out = []
    for start_va, length, label in TARGETS:
        fo = va_to_fo(start_va)
        out.append('=' * 78)
        out.append('%s  start=0x%08X len=0x%X' % (label, start_va, length))
        out.append('=' * 78)
        if fo < 0 or fo >= len(data):
            out.append('  (out of range)')
            continue
        chunk = data[fo:fo + length]
        md = Cs(CS_ARCH_X86, CS_MODE_32)
        md.detail = True
        for ins in md.disasm(chunk, start_va):
            out.append('0x%08X  %-8s %s' % (ins.address, ins.mnemonic, ins.op_str))
        out.append('')
    open(r'C:\Ascension\Workspace\RaijinLab\tools\_disasm_gates.txt', 'w',
         encoding='utf-8').write('\n'.join(out))
    print('wrote tools/_disasm_gates.txt (%d lines)' % len(out))


if __name__ == '__main__':
    main()

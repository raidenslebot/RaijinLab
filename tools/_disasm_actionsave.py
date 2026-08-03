"""Disassemble the client's action-state save/zero/restore pair (0x48EC20 /
0x493180) — the exact pattern SafeNativeCast tries to replicate around Spell_C
— plus 0x513530 (the function canCast's failure cases call, 0x513530(0,0)),
to understand when [0xD4139C] (kActionStateGlob) is really zero at canCast.

Writes: tools/_disasm_actionsave.txt
"""
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000

TARGETS = [
    (0x0048EC20, 0x120, 'action save/zero (0x48EC20)'),
    (0x00493180, 0x120, 'action restore (0x493180)'),
    (0x00513530, 0x120, 'canCast-fail helper (0x513530)'),
]

WATCH = {
    0x00D4139C: 'kActionStateGlob',
    0x00D413A0: 'kActionDepthGlob',
    0x00D413A4: 'kActionRestoreFlagGlob',
}


def va_to_fo(va):
    return va - IMAGE_BASE - 0x1000 + TEXT_OFF


def main():
    data = open(EXE, 'rb').read()
    out = []
    for start_va, length, label in TARGETS:
        out.append('=' * 78)
        out.append('%s  start=0x%08X len=0x%X' % (label, start_va, length))
        out.append('=' * 78)
        fo = va_to_fo(start_va)
        chunk = data[fo:fo + length]
        md = Cs(CS_ARCH_X86, CS_MODE_32)
        md.detail = True
        for ins in md.disasm(chunk, start_va):
            op = ins.op_str.lower()
            ann = ''
            for addr, name in WATCH.items():
                if ('0x%x' % addr) in op or ('0x%08x' % addr) in op:
                    ann += '   <=== %s' % name
            out.append('0x%08X  %-8s %-34s ; %s%s'
                       % (ins.address, ins.mnemonic, ins.op_str,
                          ' '.join('%02X' % b for b in ins.bytes), ann))
    txt = '\n'.join(out)
    path = r'C:\Ascension\Workspace\RaijinLab\tools\_disasm_actionsave.txt'
    with open(path, 'w') as f:
        f.write(txt)
    print(txt)


if __name__ == '__main__':
    main()

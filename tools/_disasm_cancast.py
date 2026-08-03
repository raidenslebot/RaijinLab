"""Disassemble canCast (0x5191C0) to find exactly which state field makes it
return 0 — the last gate before Spell_C's silent refusal (0x80D249, al=0).

Round 32 probe: CastProbe ... bd078c=6D01E9D8 bd124c=00000001  (al=0 persists).
Every other gate passed (entry=1, gate=0, desc40 lands, r8 resolves).

Writes: tools/_disasm_cancast.txt
"""
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

EXE = r'C:\Ascension\Launcher\resources\ascension-live\Ascension.exe'
IMAGE_BASE = 0x400000
TEXT_OFF = 0x400
TEXT_VA = IMAGE_BASE + 0x1000
TEXT_SIZE = 0x5DD400

TARGETS = [
    (0x005191C0, 0x500, 'canCast(2/6)  0x5191C0'),
    (0x0080D1F0, 0x90,  'Spell_C fail epilogue (0x80D249 area)'),
]

# addresses / offsets of interest for annotation
WATCH_GLOBALS = {
    0x00D4139C: 'kActionStateGlob (busy gate)',
    0x00D413A0: 'kActionDepthGlob',
    0x00D413A4: 'kActionRestoreFlagGlob',
    0x00BD078C: 'ClntObjMgr/state object',
    0x00BD07B0: 'kClientTargetGuid (selection)',
    0x00D3F604: 'blocked-cast counter',
}
WATCH_OFFSETS = {0x124C: 'obj+124C (probe=1)', 0x1250: 'obj+1250', 0x18: 'rec+18'}


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
            for addr, name in WATCH_GLOBALS.items():
                if ('0x%x' % addr) in op or ('0x%08x' % addr) in op:
                    ann += '   <=== %s' % name
            for off, name in WATCH_OFFSETS.items():
                if ('0x%x]' % off) in op or ('+ 0x%x]' % off) in op:
                    ann += '   <=== %s' % name
            out.append('0x%08X  %-8s %-34s ; %s%s'
                       % (ins.address, ins.mnemonic, ins.op_str,
                          ' '.join('%02X' % b for b in ins.bytes), ann))
    txt = '\n'.join(out)
    path = r'C:\Ascension\Workspace\RaijinLab\tools\_disasm_cancast.txt'
    with open(path, 'w') as f:
        f.write(txt)
    print(txt)


if __name__ == '__main__':
    main()
